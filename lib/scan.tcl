package require Tcl 9
package require TclOO

# ::questlog::Scan - in-memory, coroutine-driven, memoised session scanner.
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

namespace eval ::questlog::scan {}

# Comparator for lsort -command. Sorts row-dict elements by mtime.
proc ::questlog::scan::cmp_mtime {a b} {
    set ma [dict get $a mtime]
    set mb [dict get $b mtime]
    if {$ma < $mb} { return -1 }
    if {$ma > $mb} { return 1 }
    return 0
}

# Resume a coroutine from an `after` callback. The coroutine command deletes
# itself when it returns, so a resume scheduled before a cancel can fire after
# the coroutine is already gone; skip it then. An error the coroutine itself
# raises is deliberately NOT caught here - it reaches bgerror and is seen,
# instead of dying silently and hanging the vwait that awaits the scan. A bare
# `catch` around the resume swallowed both, turning a real fault into a freeze.
proc ::questlog::resume_coro {co} {
    if {[llength [info commands $co]]} { $co }
}

oo::class create ::questlog::Scan {
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
        set co ::questlog::scan::coro_$my_epoch
        coroutine $co [namespace which my] run_scan $my_epoch
    }

    # Coroutine body. Public so [namespace which my] resolves it.
    method run_scan {my_epoch} {
        # Yield once at the top so the caller's vwait is established
        # before any callback (OnRow / OnDone) fires. Otherwise short
        # scans complete synchronously inside `coroutine` and the
        # caller's vwait blocks forever waiting for a write that
        # already happened.
        after 1 [list ::questlog::resume_coro [info coroutine]]
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
            if {$count % [::questlog::config::get scan_yield_files] == 0} {
                if {$OnProgress ne ""} { {*}$OnProgress $count $total }
                after [::questlog::config::get scan_resume_ms] [list ::questlog::resume_coro [info coroutine]]
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
        set root [::questlog::path::projects_root]
        if {![file isdirectory $root]} { return [list] }
        set window [my dict_or $snapshot window [::questlog::config::get window_default]]
        set cutoff 0
        if {$window ne "all"} {
            set hours [dict get [::questlog::config::get window_hours] $window]
            set cutoff [expr {[clock seconds] - $hours*3600}]
        }
        set pairs [list]
        foreach folder [glob -nocomplain -directory $root -type d -- *] {
            foreach f [glob -nocomplain -directory $folder -- *.jsonl] {
                set m [file mtime $f]
                # A bookmarked (+x) file is kept regardless of the window
                # so it always enters Rows and can be surfaced as a pin.
                if {$m <= $cutoff && ![file executable $f]} continue
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
    # predicate, the first user prompt preview, the cwd hint, the first
    # timestamp, and the slug Claude Code writes for the session. Pure:
    # no shared state, returns a fresh dict. The caller decides whether
    # to publish.
    #
    # Two-phase read. The forward scan keeps its existing early break on
    # users/cwd/first_ts. Slug records (agentName, aiTitle) are NOT read
    # forward: Claude Code appends rename records at the end of the file,
    # so the first occurrence is always the original auto title, never
    # the rename. After the forward break, a tail scan over the last
    # ~64 KB takes the LAST agentName and the LAST aiTitle, which is the
    # window the most recent rename and its mirrored agent-name record
    # live in. Slug priority is unchanged: agentName wins over aiTitle.
    method scan_one {path} {
        if {[catch {open $path r} fh]} { return [dict create] }
        # -profile replace: the tail scan below seeks to an arbitrary byte
        # offset that can split a multibyte character, and a session file may
        # hold malformed UTF-8; under Tcl 9 strict decoding `chan gets` would
        # otherwise throw on the partial or invalid sequence and abort the scan.
        chan configure $fh -encoding utf-8 -profile replace
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
            }
            if {$users >= 2 && $cwd ne "" && $first_ts ne ""} break
        }
        # Tail scan. Seek to max(current_pos, size - 64KB) so a short file
        # is read whole and a long file pays only the tail. Skip the first
        # (probably partial) line after the seek when seeking mid-file.
        set agent_name ""
        set ai_title ""
        if {[catch {file size $path} fsz]} { set fsz 0 }
        set tail_start [expr {$fsz - [::questlog::config::get tail_window_bytes]}]
        set pos [chan tell $fh]
        if {$tail_start > $pos} {
            chan seek $fh $tail_start
            chan gets $fh _
        }
        while {[chan gets $fh line] >= 0} {
            if {$line eq ""} continue
            if {[regexp {"agentName":"([^"]+)"} $line -> m]} {
                set agent_name $m
            }
            if {[regexp {"aiTitle":"([^"]+)"} $line -> m]} {
                set ai_title $m
            }
        }
        close $fh
        if {[catch {file mtime $path} mtime]} { set mtime 0 }
        set size $fsz
        set folder [file tail [file dirname $path]]
        set uuid   [file rootname [file tail $path]]
        set first_clean [my clean_preview $first]
        set slug [expr {$agent_name ne "" ? $agent_name : $ai_title}]
        return [dict create \
            path $path \
            mtime $mtime \
            size $size \
            folder $folder \
            uuid $uuid \
            first_ts $first_ts \
            is_multi [expr {$users >= 2}] \
            first_user $first_clean \
            slug $slug \
            ai_title $ai_title \
            bookmarked [file executable $path] \
            cwd_hint $cwd]
    }

    # Collapse whitespace and strip simple JSON escapes. No length cap:
    # the session list renders the prompt with -wrap none so overflow is
    # clipped by the widget edge in the right font's actual width, and the
    # full prompt is read in the viewer a click opens. A byte-count
    # truncation here would just be a worse approximation of the same clipping.
    method clean_preview {s} {
        set s [regsub -all {[\s]+} $s " "]
        set s [string map [list "\\\"" "\"" "\\\\" "\\" "\\n" " " "\\t" " "] $s]
        return [string trim $s]
    }

    # Merge a cost result into the row. Called from the main thread when
    # the cost-pass worker thread completes a file. Quiet no-op if the
    # row is absent (race with a delete). Does not fire OnRow: cost
    # arrivals route through the cost callback so the UI knows it is a
    # field update, not a fresh row that needs adding.
    method update_cost {path cost_dict} {
        if {![dict exists $Rows $path]} return
        set row [dict get $Rows $path]
        dict for {k v} $cost_dict { dict set row $k $v }
        dict set Rows $path $row
    }

    # Publish a row. Used by run_scan and by Search (which produces row
    # data as a free side-effect of its own pass). Last-write-wins; the
    # content from either consumer is the same row.
    method publish_row {row} {
        set path [dict get $row path]
        dict set Rows $path $row
        set folder [dict get $row folder]
        set cwd [dict get $row cwd_hint]
        # cwd_hint is the cwd the conversation ran in, read from the file.
        # For an un-moved session that equals the folder's own identity
        # (encode_cwd(cwd_hint) == folder); for a session moved into this
        # folder the two disagree and trusting cwd_hint would label the
        # folder with the source project's name. Seed the Folders cache
        # only when the hint is self-consistent AND still points at an
        # extant directory, so the cache never holds a fictional path.
        if {$cwd ne "" && ![dict exists $Folders $folder]
            && [::questlog::path::encode_cwd $cwd] eq $folder
            && [file isdirectory $cwd]} {
            dict set Folders $folder $cwd
        }
        if {$OnRow ne ""} { {*}$OnRow $row }
    }

    # Filter rows by a snapshot. Used by the session list and Search to read
    # the current memoised view. Returns a list of row dicts, mtime DESC.
    method query {snapshot {folder ""}} {
        set window [my dict_or $snapshot window [::questlog::config::get window_default]]
        set one_turn [my dict_or $snapshot one_turn 1]
        set under    [my dict_or $snapshot under {}]
        set bookmarked_only [my dict_or $snapshot bookmarked_only 0]
        set cutoff 0
        if {$window ne "all"} {
            set hours [dict get [::questlog::config::get window_hours] $window]
            set cutoff [expr {[clock seconds] - $hours*3600}]
        }
        set under_folders [list]
        set under_paths   [list]
        foreach u $under {
            lappend under_folders [::questlog::path::encode_cwd $u]
            lappend under_paths   [string trimright $u /]
        }
        set out [list]
        dict for {path row} $Rows {
            set bk [my dict_or $row bookmarked 0]
            if {$bookmarked_only && !$bk} continue
            # A bookmark pins the row past the time window; running is the
            # reconciler's job, not the query's.
            if {[dict get $row mtime] <= $cutoff && !$bk} continue
            if {$one_turn && ![dict get $row is_multi]} continue
            set f [dict get $row folder]
            if {$folder ne "" && $f ne $folder} continue
            if {[llength $under_folders] > 0} {
                if {![my row_under_match $row $under_folders $under_paths]} continue
            }
            lappend out $row
        }
        return [lsort -decreasing -command ::questlog::scan::cmp_mtime $out]
    }

    # Mirror of SessionList.row_under_match. Match by encoded folder name
    # for an exact-cwd hit; for a parent-folder hit fall back to the
    # cwd_hint string and check it starts with the under path.
    method row_under_match {row folders paths} {
        set f [dict get $row folder]
        if {$f in $folders} { return 1 }
        set cwd_hint [my dict_or $row cwd_hint ""]
        if {$cwd_hint eq ""} { return 0 }
        foreach u $paths {
            if {$cwd_hint eq $u || [string match "$u/*" $cwd_hint]} { return 1 }
        }
        return 0
    }

    # The single canonical folder-basename -> cwd resolver. Every label
    # and every command that needs the project directory goes through
    # here. Returns an extant absolute directory path, or "" when the
    # folder cannot be resolved (its directory is gone, or the basename
    # is genuinely ambiguous). Never returns a fictional path.
    #
    #   1. Folders cache - already resolved this process.
    #   2. peek_folder_cwd - the cwd recorded inside an honest jsonl,
    #      trusted only if it still names a real directory.
    #   3. candidate_cwds_for - filesystem walk; trusted iff exactly one
    #      directory matches the basename.
    #   4. "" - unresolvable. Not cached: a directory created or restored
    #      later in this process should get a fresh chance.
    method resolve_folder {folder} {
        if {[dict exists $Folders $folder]} { return [dict get $Folders $folder] }
        set cwd [my peek_folder_cwd $folder]
        if {$cwd ne "" && [file isdirectory $cwd]} {
            dict set Folders $folder $cwd
            return $cwd
        }
        set cands [::questlog::path::candidate_cwds_for $folder]
        if {[llength $cands] == 1} {
            set cwd [lindex $cands 0]
            dict set Folders $folder $cwd
            return $cwd
        }
        return ""
    }

    # The first cwd recorded in any jsonl under $folder, returned only
    # when encode_cwd of it agrees with $folder - so a session that was
    # moved into the folder cannot mislabel it. The caller decides
    # whether the path still exists.
    method peek_folder_cwd {folder} {
        set dir [file join [::questlog::path::projects_root] $folder]
        if {![file isdirectory $dir]} { return "" }
        foreach f [glob -nocomplain -directory $dir -- *.jsonl] {
            set cwd [::questlog::jsonl::first_cwd $f]
            if {$cwd ne "" && [::questlog::path::encode_cwd $cwd] eq $folder} {
                return $cwd
            }
        }
        return ""
    }

    # Rows is memoised and never pruned when a file is deleted, so a returned
    # row may describe a jsonl that no longer exists on disk (e.g. a Resume-
    # forked session quit before any input, which Claude leaves no file for).
    # Callers that decide visibility must existence-check the path themselves
    # rather than trust a non-empty row here - see reconcile_running.
    method lookup {path} {
        if {[dict exists $Rows $path]} { return [dict get $Rows $path] }
        return ""
    }

    # Scan a single file synchronously and publish it. Used by the running
    # reconciler to bring a freshly-started (or out-of-window but live)
    # session into Rows on demand. Returns the row, or {} if unreadable.
    method scan_path {path} {
        set row [my scan_one $path]
        if {[dict size $row] > 0} { my publish_row $row }
        return $row
    }

    # Re-derive a row's bookmarked flag from disk truth after a toggle.
    # The +x bit is authoritative; this only refreshes the cached field so
    # query/filter see it. The visible glyph is refreshed separately by
    # the session list (reconcile_one). Routed through Scan to keep Rows
    # mutation in one place (no caller pokes Rows directly).
    method set_bookmark_field {path} {
        if {![dict exists $Rows $path]} return
        set row [dict get $Rows $path]
        dict set row bookmarked [file executable $path]
        dict set Rows $path $row
    }

    # Re-key a row after the underlying jsonl was renamed into a new
    # project folder. The row's path and folder are updated; mtime/size
    # are re-read because the rename preserves them but we want any
    # subsequent extend pass to see a consistent state. OnRow fires so
    # the session list can re-insert under the new folder. The caller is
    # responsible for removing the old entry from the UI first - OnRow
    # has no "forget" channel.
    method relocate_row {old_path new_path} {
        if {![dict exists $Rows $old_path]} { return }
        set row [dict get $Rows $old_path]
        dict set row path $new_path
        dict set row folder [file tail [file dirname $new_path]]
        if {[catch {file mtime $new_path} mtime]} { set mtime 0 }
        if {[catch {file size  $new_path} size]}  { set size 0 }
        dict set row mtime $mtime
        dict set row size $size
        # The +x bit is preserved by rename; re-read so the cached field
        # stays honest even if it changed out of band.
        dict set row bookmarked [file executable $new_path]
        dict unset Rows $old_path
        dict set Rows $new_path $row
        # Do not seed Folders[$new_folder] from the row's cwd_hint - the
        # hint records where the conversation ran, not what the folder
        # represents. After a move those disagree. Leave Folders alone;
        # resolve_folder will recover the new folder's identity from the
        # filesystem (candidate_cwds_for) on first lookup.
        if {$OnRow ne ""} { {*}$OnRow $row }
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
