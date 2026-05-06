package require Tcl 9
package require TclOO

namespace eval ::csm::search {}

# Worker→main delivery shim. Async messages may arrive after the Search
# object is destroyed; resolve the object command lazily and swallow.
proc ::csm::search::dispatch {obj_cmd args} {
    if {[info commands $obj_cmd] eq ""} return
    if {[catch {{*}$obj_cmd {*}$args} err]} {
        puts stderr "csm::search::dispatch: $err"
    }
}

# Body sourced into each worker thread. Mirrors run_search's per-file inner
# loop and clean_preview/snippet_of helpers — duplicated rather than shared
# because Tcl threads carry separate interpreters with no shared procs.
set ::csm::search::WorkerScript {
    package require Tcl 9
    package require Thread

    proc clean_preview {s} {
        set s [regsub -all {[\s]+} $s " "]
        set s [string map [list "\\\"" "\"" "\\\\" "\\" "\\n" " " "\\t" " "] $s]
        if {[string length $s] > 80} { set s "[string range $s 0 79]…" }
        return [string trim $s]
    }
    proc snippet_of {line} {
        set t ""
        if {[regexp {"content":"([^"]+)"} $line -> t]} {
        } elseif {[regexp {"text":"([^"]+)"} $line -> t]} {
        } elseif {[regexp {"lastPrompt":"([^"]+)"} $line -> t]} {
        } else { set t $line }
        set t [regsub -all {[\s]+} $t " "]
        if {[string length $t] > 200} { set t "[string range $t 0 199]…" }
        return [string trim $t]
    }
    proc worker_run {main_tid obj_cmd epoch paths patterns re_opts} {
        set matches_in_slice 0
        foreach path $paths {
            set folder [file tail [file dirname $path]]
            set users 0
            set first_user ""
            set cwd_hint ""
            set first_ts ""
            set lineno 0
            set seen_match_in_file 0
            if {[catch {open $path r} fh]} { continue }
            chan configure $fh -encoding utf-8
            while {[chan gets $fh line] >= 0} {
                incr lineno
                if {$line eq ""} continue
                if {$cwd_hint eq "" && [regexp {"cwd":"([^"]+)"} $line -> m]} { set cwd_hint $m }
                if {$first_ts eq "" && [regexp {"timestamp":"([^"]+)"} $line -> m]} { set first_ts $m }
                if {[regexp {"type":"user"} $line] && [regexp {"content":"([^"]+)"} $line -> uc]} {
                    incr users
                    if {$users == 1} { set first_user $uc }
                }
                set all_match 1
                foreach pat $patterns {
                    if {$pat eq ""} continue
                    if {![regexp {*}$re_opts -- $pat $line]} { set all_match 0; break }
                }
                if {$all_match} {
                    set is_first [expr {!$seen_match_in_file}]
                    set seen_match_in_file 1
                    set snip [snippet_of $line]
                    thread::send -async $main_tid \
                        [list ::csm::search::dispatch $obj_cmd on_worker_match \
                             $epoch $is_first $path $lineno $first_ts $snip $folder]
                    incr matches_in_slice
                }
            }
            close $fh
            if {[catch {file mtime $path} mt]} { set mt 0 }
            if {[catch {file size  $path} sz]} { set sz 0 }
            set row [dict create \
                path $path \
                mtime $mt \
                size $sz \
                folder $folder \
                uuid [file rootname [file tail $path]] \
                first_ts $first_ts \
                is_multi [expr {$users >= 2}] \
                first_user [clean_preview $first_user] \
                cwd_hint $cwd_hint]
            thread::send -async $main_tid \
                [list ::csm::search::dispatch $obj_cmd on_worker_row $epoch $row]
        }
        thread::send -async $main_tid \
            [list ::csm::search::dispatch $obj_cmd on_worker_done \
                 $epoch [llength $paths] $matches_in_slice]
    }
    thread::wait
}

# ::csm::Search - coroutine-driven regex search across session logs.
#
# Replaces the bash-worker version. Iterates the same depth-2 glob as
# Scan, line-streams each candidate, applies the user's regex per line.
# Independent of Scan's Rows dict - never blocks waiting for a sibling
# scan to complete. As a free side-effect of reading each file it
# computes the same row data (multi-turn, first prompt, cwd_hint, first
# timestamp) and publishes back to Scan via Scan.publish_row, so the
# tree benefits from search work too.
#
# Cancellation via the same epoch-token pattern as Scan: incr Epoch,
# coroutine checks at every yield boundary and exits cleanly when stale.

oo::class create ::csm::Search {
    variable Scan
    variable Epoch
    variable MatchedSessions   ;# dict path -> 1 (first-match-per-session)
    variable Counts            ;# dict done total matches
    variable OnMatch
    variable OnProgress
    variable OnDone
    variable Active
    variable Workers           ;# tids of in-flight worker threads
    variable WorkersRemaining  ;# slices yet to report on_worker_done

    constructor {scan on_match on_progress on_done} {
        set Scan $scan
        set Epoch 0
        set MatchedSessions [dict create]
        set Counts [dict create done 0 total 0 matches 0]
        set OnMatch $on_match
        set OnProgress $on_progress
        set OnDone $on_done
        set Active 0
        set Workers [list]
        set WorkersRemaining 0
    }

    method cancel {} {
        incr Epoch
        set Active 0
        if {[info exists Workers] && [llength $Workers] > 0} {
            foreach tid $Workers { catch {thread::release $tid} }
            set Workers [list]
            set WorkersRemaining 0
        }
    }

    # start snapshot - cancel any in-flight, start new search coroutine.
    # Empty pattern list is a no-op; caller publishes only when non-empty.
    # When CSM_SEARCH_THREADS=N (N>0), fan out across N worker threads
    # instead of running the single coroutine.
    method start {snapshot} {
        set N [my pick_thread_count]
        if {$N > 0} {
            my start_threaded $snapshot $N
            return
        }
        my cancel
        set patterns [my dict_or $snapshot regex {}]
        if {[llength $patterns] == 0} return
        set my_epoch [incr Epoch]
        set Active 1
        set MatchedSessions [dict create]
        set Counts [dict create done 0 total 0 matches 0]
        set co ::csm::search::coro_$my_epoch
        coroutine $co [namespace which my] run_search $my_epoch $snapshot
    }

    method pick_thread_count {} {
        if {![info exists ::env(CSM_SEARCH_THREADS)]} { return 0 }
        set v $::env(CSM_SEARCH_THREADS)
        if {![string is integer -strict $v]} { return 0 }
        if {$v < 1} { return 0 }
        return $v
    }

    method run_search {my_epoch snapshot} {
        # Yield once so callers establishing vwait before our callbacks
        # see them. Same pattern as Scan.run_scan.
        after 1 [list catch [list [info coroutine]]]
        yield
        if {$my_epoch != $Epoch} return

        set patterns [my dict_or $snapshot regex {}]
        set case     [my dict_or $snapshot case 0]
        set re_opts  [expr {$case ? "" : "-nocase"}]

        set paths [$Scan list_paths_for $snapshot]
        set total [llength $paths]
        dict set Counts total $total
        set count 0
        foreach path $paths {
            if {$my_epoch != $Epoch} return
            set folder [file tail [file dirname $path]]
            set users 0
            set first_user ""
            set cwd_hint ""
            set first_ts ""
            set first_match_done 0
            set lineno 0
            if {[catch {open $path r} fh]} {
                incr count
                continue
            }
            chan configure $fh -encoding utf-8
            set yield_clock [clock milliseconds]
            while {[chan gets $fh line] >= 0} {
                incr lineno
                if {$line eq ""} continue
                if {$cwd_hint eq "" && [regexp {"cwd":"([^"]+)"} $line -> m]} {
                    set cwd_hint $m
                }
                if {$first_ts eq "" && [regexp {"timestamp":"([^"]+)"} $line -> m]} {
                    set first_ts $m
                }
                if {[regexp {"type":"user"} $line] && [regexp {"content":"([^"]+)"} $line -> uc]} {
                    incr users
                    if {$users == 1} { set first_user $uc }
                }
                # User-supplied regex match - line must satisfy every pattern (AND).
                set all_match 1
                foreach pat $patterns {
                    if {$pat eq ""} continue
                    if {![regexp {*}$re_opts -- $pat $line]} {
                        set all_match 0
                        break
                    }
                }
                if {$all_match} {
                    set is_first [expr {![dict exists $MatchedSessions $path]}]
                    dict set MatchedSessions $path 1
                    set snippet [my snippet_of $line]
                    set ts_for_match [expr {$first_ts ne "" ? $first_ts : ""}]
                    {*}$OnMatch $is_first $path $lineno $ts_for_match $snippet $folder
                    dict incr Counts matches
                }
                # Yield mid-file so a cancel issued by a fresh keystroke
                # lands without waiting for the rest of a large log.
                if {$lineno % 500 == 0 && [clock milliseconds] - $yield_clock > 30} {
                    if {$my_epoch != $Epoch} { close $fh; return }
                    after 1 [list catch [list [info coroutine]]]
                    yield
                    if {$my_epoch != $Epoch} { close $fh; return }
                    set yield_clock [clock milliseconds]
                }
            }
            close $fh
            # Publish row data back to Scan as a free side-effect.
            if {[catch {file mtime $path} mt]}  { set mt 0 }
            if {[catch {file size  $path} sz]}  { set sz 0 }
            set row [dict create \
                path $path \
                mtime $mt \
                size $sz \
                folder $folder \
                uuid [file rootname [file tail $path]] \
                first_ts $first_ts \
                is_multi [expr {$users >= 2}] \
                first_user [$Scan clean_preview $first_user] \
                cwd_hint $cwd_hint]
            $Scan publish_row $row
            incr count
            dict set Counts done $count
            if {$count % 50 == 0} {
                {*}$OnProgress $count $total [dict get $Counts matches]
                after 1 [list catch [list [info coroutine]]]
                yield
                if {$my_epoch != $Epoch} return
            }
        }
        {*}$OnProgress $total $total [dict get $Counts matches]
        set Active 0
        {*}$OnDone $total [dict get $Counts matches]
    }

    # snippet_of line - extract the matched text content for display.
    # The line is a JSON record; we want a readable substring around the
    # match. Keep it short and let the result-pane truncate further.
    method snippet_of {line} {
        # Try to extract just the textual content of the record.
        set t ""
        if {[regexp {"content":"([^"]+)"} $line -> t]} {
        } elseif {[regexp {"text":"([^"]+)"} $line -> t]} {
        } elseif {[regexp {"lastPrompt":"([^"]+)"} $line -> t]} {
        } else {
            set t $line
        }
        set t [regsub -all {[\s]+} $t " "]
        if {[string length $t] > 200} {
            set t "[string range $t 0 199]…"
        }
        return [string trim $t]
    }

    method dict_or {d k default} {
        if {[dict exists $d $k]} { return [dict get $d $k] }
        return $default
    }

    # Threaded fan-out driver. Splits paths into N slices, spawns one
    # worker thread per slice, and lets workers stream matches/rows back
    # via thread::send -async. Stale messages (epoch mismatch) are
    # dropped on arrival, so cancellation costs only the in-flight
    # worker work — no shared cancellation state needed.
    method start_threaded {snapshot N} {
        package require Thread
        my cancel
        set patterns [my dict_or $snapshot regex {}]
        if {[llength $patterns] == 0} return
        set my_epoch [incr Epoch]
        set Active 1
        set MatchedSessions [dict create]
        set Counts [dict create done 0 total 0 matches 0]

        set case    [my dict_or $snapshot case 0]
        set re_opts [expr {$case ? "" : "-nocase"}]
        set paths   [$Scan list_paths_for $snapshot]
        set total   [llength $paths]
        dict set Counts total $total

        if {$total == 0} {
            after 1 [list {*}$OnProgress 0 0 0]
            after 1 [list {*}$OnDone 0 0]
            set Active 0
            return
        }

        if {$N > $total} { set N $total }
        set per [expr {($total + $N - 1) / $N}]
        set slices [list]
        for {set i 0} {$i < $total} {incr i $per} {
            set j [expr {$i + $per - 1}]
            if {$j >= $total} { set j [expr {$total - 1}] }
            lappend slices [lrange $paths $i $j]
        }

        set Workers [list]
        set WorkersRemaining [llength $slices]
        set main_tid [thread::id]
        set obj_cmd  [self]
        foreach slice $slices {
            set tid [thread::create $::csm::search::WorkerScript]
            lappend Workers $tid
            thread::send -async $tid \
                [list worker_run $main_tid $obj_cmd $my_epoch $slice $patterns $re_opts]
        }
    }

    # Receives a match from a worker. Re-derives is_first on the main
    # side so the per-session-first-hit invariant is authoritative here
    # rather than relying on disjoint slicing.
    method on_worker_match {epoch worker_first path lineno ts snippet folder} {
        if {$epoch != $Epoch} return
        set is_first [expr {![dict exists $MatchedSessions $path]}]
        dict set MatchedSessions $path 1
        {*}$OnMatch $is_first $path $lineno $ts $snippet $folder
        dict incr Counts matches
    }

    method on_worker_row {epoch row} {
        if {$epoch != $Epoch} return
        $Scan publish_row $row
        dict incr Counts done
        set d [dict get $Counts done]
        set t [dict get $Counts total]
        if {$d % 50 == 0} {
            {*}$OnProgress $d $t [dict get $Counts matches]
        }
    }

    method on_worker_done {epoch slice_size slice_matches} {
        if {$epoch != $Epoch} return
        incr WorkersRemaining -1
        if {$WorkersRemaining <= 0} {
            set t [dict get $Counts total]
            set m [dict get $Counts matches]
            {*}$OnProgress $t $t $m
            set Active 0
            foreach tid $Workers { catch {thread::release $tid} }
            set Workers [list]
            {*}$OnDone $t $m
        }
    }

    method destroy {} {
        my cancel
        next
    }
}
