package require Tcl 9
package require TclOO

# ::csm::Scan - in-memory, coroutine-driven, memoised session scanner.
#
# Replaces the previous sqlite-cached design. Each launch builds the row
# table fresh by line-streaming each jsonl with Tcl regex (no jq, no
# subprocess). Within one process the table is memoised across toolbar
# window changes - shrinking the window filters in O(rows), growing
# scans only the delta.
#
# Single-instance by current convention, not by structural constraint.
# The class earns its existence under issue 67 on (a) named globals
# absorbed (Rows, Folders, Epoch, Snapshot, callbacks), (b) joint state
# (epoch and rows co-evolve as the coroutine drains), (c) tell-don't-ask
# (no caller pokes Rows directly; mutation routes through publish_row).
#
# Cancellation uses a generation token. `incr Epoch` invalidates any
# in-flight coroutine; the coroutine compares its captured epoch after
# every yield and exits cleanly when stale. No `rename`, no race.

namespace eval ::csm::scan {}

# Comparator for lsort -command. Sorts row-dict elements by mtime.
proc ::csm::scan::cmp_mtime {a b} {
    set ma [dict get $a mtime]
    set mb [dict get $b mtime]
    if {$ma < $mb} { return -1 }
    if {$ma > $mb} { return 1 }
    return 0
}

oo::class create ::csm::Scan {
    variable Rows         ;# dict: path -> row dict
    variable Folders      ;# dict: folder basename -> resolved display path
    variable Epoch        ;# generation counter; inc to cancel
    variable Snapshot     ;# last snapshot the coroutine started under
    variable OnRow        ;# cb {row}
    variable OnDone       ;# cb {scanned}
    variable OnProgress   ;# cb {done total} or {}
    variable Active       ;# 1 while a coroutine is running

    constructor {on_row on_done {on_progress {}}} {
        set Rows [dict create]
        set Folders [dict create]
        set Epoch 0
        set Snapshot [dict create]
        set OnRow $on_row
        set OnDone $on_done
        set OnProgress $on_progress
        set Active 0
    }

    # Cancel any in-flight scan. Stale coroutine drains itself at the
    # next yield boundary.
    method cancel {} {
        incr Epoch
        set Active 0
    }

    # extend snapshot - start a new scan coroutine. Cancels any previous
    # coroutine via the epoch token.
    method extend {snapshot} {
        my cancel
        set Snapshot $snapshot
        set my_epoch [incr Epoch]
        set Active 1
        set co ::csm::scan::coro_$my_epoch
        coroutine $co [namespace which my] run_scan $my_epoch
    }

    # Coroutine body. Public so [namespace which my] resolves it.
    method run_scan {my_epoch} {
        # Yield once at the top so the caller's vwait is established
        # before any callback (OnRow / OnDone) fires. Otherwise short
        # scans complete synchronously inside `coroutine` and the
        # caller's vwait blocks forever waiting for a write that
        # already happened.
        after 1 [list catch [list [info coroutine]]]
        yield
        if {$my_epoch != $Epoch} return
        set count 0
        set scanned 0
        set paths [my list_paths_for $Snapshot]
        set total [llength $paths]
        foreach path $paths {
            if {$my_epoch != $Epoch} return
            set existing_mtime ""
            if {[dict exists $Rows $path]} {
                set existing_mtime [dict get $Rows $path mtime]
            }
            set live_mtime [file mtime $path]
            if {$existing_mtime ne $live_mtime} {
                set row [my scan_one $path]
                if {[dict size $row] > 0} {
                    my publish_row $row
                    incr scanned
                }
            }
            incr count
            if {$count % 200 == 0} {
                if {$OnProgress ne ""} { {*}$OnProgress $count $total }
                after 1 [list catch [list [info coroutine]]]
                yield
                if {$my_epoch != $Epoch} return
            }
        }
        if {$OnProgress ne ""} { {*}$OnProgress $total $total }
        set Active 0
        if {$OnDone ne ""} { {*}$OnDone $scanned }
    }

    # Build the candidate path list for a snapshot.
    # Depth-2 glob only - never recurses into <folder>/<uuid>/subagents/
    # which holds internal subagent records (not user sessions).
    # Pre-sorted by mtime DESC so consumers see rows in display order.
    method list_paths_for {snapshot} {
        set root [::csm::path::projects_root]
        if {![file isdirectory $root]} { return [list] }
        set window [my dict_or $snapshot window 7d]
        set cutoff 0
        if {$window ne "all"} {
            set hours [dict get {24h 24 7d 168 30d 720} $window]
            set cutoff [expr {[clock seconds] - $hours*3600}]
        }
        set proc_prefix "$::env(HOME)/.claude-procedural/"
        set pairs [list]
        foreach folder [glob -nocomplain -directory $root -type d -- *] {
            foreach f [glob -nocomplain -directory $folder -- *.jsonl] {
                set m [file mtime $f]
                if {$m <= $cutoff} continue
                # Procedural-path guard via the lossy decode of the
                # folder basename. The procedural convention places
                # such folders under ~/.claude-procedural/, which the
                # lossy decode preserves.
                set decoded [::csm::path::decode_folder [file tail $folder]]
                if {[string match "${proc_prefix}*" $decoded]} continue
                lappend pairs [list $f $m]
            }
        }
        # Sort by mtime DESC.
        set sorted [lsort -integer -decreasing -index 1 $pairs]
        set out [list]
        foreach p $sorted { lappend out [lindex $p 0] }
        return $out
    }

    # scan_one path - read the file line by line, extract the multi-turn
    # predicate, the first user prompt preview, the cwd hint, and the
    # first timestamp. Pure: no shared state, returns a fresh dict.
    # The caller decides whether to publish.
    method scan_one {path} {
        if {[catch {open $path r} fh]} { return [dict create] }
        chan configure $fh -encoding utf-8
        set users 0
        set first ""
        set cwd ""
        set first_ts ""
        while {[chan gets $fh line] >= 0} {
            if {$line eq ""} continue
            if {$cwd eq "" && [regexp {"cwd":"([^"]+)"} $line -> m]} {
                set cwd $m
            }
            if {$first_ts eq "" && [regexp {"timestamp":"([^"]+)"} $line -> m]} {
                set first_ts $m
            }
            # User-record predicate - same heuristic as cs-grep.
            if {[regexp {"type":"user"} $line] && [regexp {"content":"([^"]+)"} $line -> uc]} {
                incr users
                if {$users == 1} { set first $uc }
                if {$users >= 2 && $cwd ne "" && $first_ts ne ""} break
            }
        }
        close $fh
        if {[catch {file mtime $path} mtime]}  { set mtime 0 }
        if {[catch {file size  $path} size]}   { set size 0 }
        set folder [file tail [file dirname $path]]
        set uuid   [file rootname [file tail $path]]
        set first_clean [my clean_preview $first]
        return [dict create \
            path $path \
            mtime $mtime \
            size $size \
            folder $folder \
            uuid $uuid \
            first_ts $first_ts \
            is_multi [expr {$users >= 2}] \
            first_user $first_clean \
            cwd_hint $cwd]
    }

    # Collapse whitespace, strip simple JSON escapes, truncate to ~80 chars.
    method clean_preview {s} {
        set s [regsub -all {[\s]+} $s " "]
        set s [string map [list "\\\"" "\"" "\\\\" "\\" "\\n" " " "\\t" " "] $s]
        if {[string length $s] > 80} {
            set s [string range $s 0 79]…
        }
        return [string trim $s]
    }

    # Publish a row. Used by run_scan and by Search (which produces row
    # data as a free side-effect of its own pass). Last-write-wins; the
    # content from either consumer is the same row.
    method publish_row {row} {
        set path [dict get $row path]
        dict set Rows $path $row
        set folder [dict get $row folder]
        set cwd [dict get $row cwd_hint]
        if {$cwd ne "" && ![dict exists $Folders $folder]} {
            dict set Folders $folder $cwd
        }
        if {$OnRow ne ""} { {*}$OnRow $row }
    }

    # Filter rows by a snapshot. Used by Tree/Results/Search to read the
    # current memoised view. Returns a list of row dicts, mtime DESC.
    method query {snapshot {folder ""}} {
        set window [my dict_or $snapshot window 7d]
        set one_turn [my dict_or $snapshot one_turn 1]
        set cwd_only [my dict_or $snapshot cwd_only 0]
        set cwd      [my dict_or $snapshot cwd ""]
        set cutoff 0
        if {$window ne "all"} {
            set hours [dict get {24h 24 7d 168 30d 720} $window]
            set cutoff [expr {[clock seconds] - $hours*3600}]
        }
        set cwd_folder ""
        if {$cwd_only && $cwd ne ""} {
            set cwd_folder [::csm::path::encode_cwd $cwd]
        }
        set out [list]
        dict for {path row} $Rows {
            if {[dict get $row mtime] <= $cutoff} continue
            if {$one_turn && ![dict get $row is_multi]} continue
            set f [dict get $row folder]
            if {$folder ne "" && $f ne $folder} continue
            if {$cwd_folder ne "" && $f ne $cwd_folder} continue
            lappend out $row
        }
        return [lsort -decreasing -command ::csm::scan::cmp_mtime $out]
    }

    method resolve_folder {folder} {
        if {[dict exists $Folders $folder]} { return [dict get $Folders $folder] }
        return [::csm::path::decode_folder $folder]
    }

    method lookup {path} {
        if {[dict exists $Rows $path]} { return [dict get $Rows $path] }
        return ""
    }

    method dict_or {d k default} {
        if {[dict exists $d $k]} { return [dict get $d $k] }
        return $default
    }

    method destroy {} {
        my cancel
        next
    }
}
