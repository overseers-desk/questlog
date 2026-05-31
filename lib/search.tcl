package require Tcl 9
package require TclOO
package require json

namespace eval ::questlog::search {}

# Worker→main delivery shim. Async messages may arrive after the Search
# object is destroyed; resolve the object command lazily and swallow.
proc ::questlog::search::dispatch {obj_cmd args} {
    if {[info commands $obj_cmd] eq ""} return
    if {[catch {{*}$obj_cmd {*}$args} err]} {
        puts stderr "questlog::search::dispatch: $err"
    }
}

# The worker init prelude, built in the main interp where config and the repo
# root are reachable. A worker is a separate interp; it sources the same
# lib/jsonl.tcl and lib/match.tcl the main interp uses (so the matching logic
# has one home, not a hand-synced copy) and then receives the display caps as a
# set_caps snapshot, since it cannot reach ::questlog::config itself. config.tcl
# stays the one home for the numbers; the worker carries a derived copy.
proc ::questlog::search::worker_prelude {root} {
    return "source [list [file join $root lib jsonl.tcl]]
source [list [file join $root lib match.tcl]]
::questlog::match::set_caps [list [dict create \
    content_cap     [::questlog::config::get content_cap] \
    snippet_radius  [::questlog::config::get snippet_radius] \
    tool_param_cap  [::questlog::config::get tool_param_cap] \
    tool_render_cap [::questlog::config::get tool_render_cap]]]
"
}

# build_clauses snapshot - normalise the toolbar's snapshot into the form
# the matcher consumes: tokenised search terms, the regex patterns from the
# pattern row, and the path lists from the read/wrote/edited rows. Each
# value list is the user's input with empty entries stripped.
proc ::questlog::search::build_clauses {snapshot} {
    set search ""
    if {[dict exists $snapshot search]} { set search [dict get $snapshot search] }
    set terms [::questlog::ui::search_terms $search]
    set search_case 0
    if {[dict exists $snapshot search_case]} {
        set search_case [dict get $snapshot search_case]
    }
    set out [dict create \
        terms        $terms \
        nocase       [expr {!$search_case}] \
        patterns     [::questlog::search::trim_values [dict_or $snapshot pattern {}]] \
        paths_read   [::questlog::search::trim_values [dict_or $snapshot read    {}]] \
        paths_wrote  [::questlog::search::trim_values [dict_or $snapshot wrote   {}]] \
        paths_edited [::questlog::search::trim_values [dict_or $snapshot edited  {}]]]
    return $out
}

proc ::questlog::search::trim_values {vs} {
    set out [list]
    foreach v $vs { if {$v ne ""} { lappend out $v } }
    return $out
}

proc ::questlog::search::dict_or {d k default} {
    if {[dict exists $d $k]} { return [dict get $d $k] }
    return $default
}

# clauses_any clauses - 1 iff any clause has at least one value. Used by
# the matcher to early-exit when the user clears every filter.
proc ::questlog::search::clauses_any {clauses} {
    foreach k {terms patterns paths_read paths_wrote paths_edited} {
        if {[llength [dict get $clauses $k]] > 0} { return 1 }
    }
    return 0
}

# Body sourced into each worker thread. A worker is a separate interp, so it
# sources lib/jsonl.tcl and lib/match.tcl (prepended by worker_prelude) and
# calls the same matching procs the main interp does; only worker_run, which
# fans results back over thread::send, is worker-specific.
set ::questlog::search::WorkerScript {
    package require Tcl 9
    package require Thread
    package require json

    # Scan each file in the slice with the shared ::questlog::match::scan_file
    # (sourced via worker_prelude) and fan its row and any matches back to the
    # main thread; is_first is re-derived main-side in on_worker_match.
    proc worker_run {main_tid obj_cmd epoch paths clauses} {
        set matches_in_slice 0
        foreach path $paths {
            lassign [::questlog::match::scan_file $path $clauses] row matches
            if {$row eq ""} continue
            thread::send -async $main_tid \
                [list ::questlog::search::dispatch $obj_cmd on_worker_row $epoch $row]
            foreach mc $matches {
                thread::send -async $main_tid \
                    [list ::questlog::search::dispatch $obj_cmd on_worker_match $epoch $mc]
                incr matches_in_slice
            }
        }
        thread::send -async $main_tid \
            [list ::questlog::search::dispatch $obj_cmd on_worker_done \
                 $epoch [llength $paths] $matches_in_slice]
    }
    thread::wait
}

# ::questlog::Search - typed-criteria search across session logs, threaded
# fan-out by default; QUESTLOG_SEARCH_THREADS tunes the worker count, or 0
# selects the single-thread coroutine path.
#
# A search is a list of criteria, each {type regex|read|write|edit value}.
# A session qualifies when every criterion is satisfied somewhere in it
# (AND at session scope). A regex criterion is satisfied by a content
# block matching its pattern; a read/write/edit criterion by a tool_use
# whose tool name is in the type's set and whose file path ends with the
# value, so a bare filename matches that file in any directory.
#
# Per file: pre-filter each raw line by any criterion's literal (the
# pattern for regex, the path substring for a path type) so the JSON parse
# is skipped on lines that cannot contribute; on a candidate line, parse
# once and collect the record's hits via record_hits, marking criteria
# satisfied and buffering evidence rows. At end of file, if every
# criterion is satisfied, flush the buffered rows in line order through
# OnMatch as match-record dicts {is_first path lineoff ts btype content
# folder}; the first row of a session carries is_first 1.
#
# Side effect: as a free byproduct of reading each file, the row data
# (multi-turn predicate, first prompt, cwd_hint, first timestamp) is
# published to Scan via Scan.publish_row, so the tree benefits.
#
# Cancellation: each start increments Epoch; in-flight async dispatches
# carrying a stale epoch are dropped on arrival.

oo::class create ::questlog::Search {
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
    variable YieldClock        ;# clock-ms of the coroutine path's last yield

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

    method start {snapshot} {
        set N [my pick_thread_count]
        if {$N > 0} {
            my start_threaded $snapshot $N
            return
        }
        my cancel
        set clauses [::questlog::search::build_clauses $snapshot]
        if {![::questlog::search::clauses_any $clauses]} return
        set my_epoch [incr Epoch]
        set Active 1
        set MatchedSessions [dict create]
        set Counts [dict create done 0 total 0 matches 0]
        set co ::questlog::search::coro_$my_epoch
        coroutine $co [namespace which my] run_search $my_epoch $snapshot
    }

    # Worker count for a search. Threaded by default; QUESTLOG_SEARCH_THREADS
    # overrides - a non-negative integer sets the count, 0 forces the
    # single-thread coroutine path. An unset or malformed value falls back to
    # default_thread_count.
    method pick_thread_count {} {
        if {[info exists ::env(QUESTLOG_SEARCH_THREADS)]} {
            set v $::env(QUESTLOG_SEARCH_THREADS)
            if {[string is integer -strict $v] && $v >= 0} { return $v }
        }
        return [my default_thread_count]
    }

    # Best-effort core count, less two to leave the UI and a margin, clamped to
    # a sane band. Detection failure falls back to a modest 4.
    method default_thread_count {} {
        set cores 0
        if {![catch {exec nproc} out] && [string is integer -strict [string trim $out]]} {
            set cores [string trim $out]
        } elseif {![catch {exec sysctl -n hw.ncpu} out]
                  && [string is integer -strict [string trim $out]]} {
            set cores [string trim $out]
        }
        if {$cores < 2} { return [::questlog::config::get search_threads_fallback] }
        set n [expr {$cores - [::questlog::config::get search_threads_reserve]}]
        set lo [::questlog::config::get search_threads_min]
        set hi [::questlog::config::get search_threads_max]
        if {$n < $lo} { set n $lo }
        if {$n > $hi} { set n $hi }
        return $n
    }

    method run_search {my_epoch snapshot} {
        # Yield once so callers establishing vwait before our callbacks
        # see them. Same pattern as Scan.run_scan.
        after [::questlog::config::get search_resume_ms] [list ::questlog::resume_coro [info coroutine]]
        yield
        if {$my_epoch != $Epoch} return

        set clauses [::questlog::search::build_clauses $snapshot]
        set paths [$Scan list_paths_for $snapshot]
        set total [llength $paths]
        dict set Counts total $total
        set count 0
        set YieldClock [clock milliseconds]
        set tick [list [self] scan_tick $my_epoch]
        set yl [::questlog::config::get search_yield_lines]
        foreach path $paths {
            if {$my_epoch != $Epoch} return
            # The shared per-file scanner; the tick yields mid-file so a cancel
            # (a fresh Enter or filter change) lands without finishing a big log.
            lassign [::questlog::match::scan_file $path $clauses $tick $yl] row matches
            if {$my_epoch != $Epoch} return
            # row "" means the file could not be opened (a cancel mid-file is
            # caught by the epoch check above); count it and move on.
            if {$row eq ""} {
                incr count
                dict set Counts done $count
                continue
            }
            # Publish row data back to Scan as a free side-effect.
            $Scan publish_row $row
            # A session qualifies only when every clause is satisfied (scan_file
            # returns no matches otherwise); flush them in line order, is_first
            # marking the first hit per session for the consumers.
            foreach mc $matches {
                set is_first [expr {![dict exists $MatchedSessions $path]}]
                dict set MatchedSessions $path 1
                dict set mc is_first $is_first
                {*}$OnMatch $mc
                dict incr Counts matches
            }
            incr count
            dict set Counts done $count
            if {$count % [::questlog::config::get search_progress_files] == 0} {
                {*}$OnProgress $count $total [dict get $Counts matches]
                after [::questlog::config::get search_resume_ms] [list ::questlog::resume_coro [info coroutine]]
                yield
                if {$my_epoch != $Epoch} return
            }
        }
        {*}$OnProgress $total $total [dict get $Counts matches]
        set Active 0
        {*}$OnDone $total [dict get $Counts matches]
    }

    # Tick handed to scan_file, called every search_yield_lines lines. The
    # wall-clock gate keeps a hot file from yielding on every chunk; once
    # search_yield_ms has passed since the last yield, hand control back to the
    # event loop so a re-typed search can cancel, then report whether this
    # coroutine's epoch went stale (1 aborts the scan).
    method scan_tick {my_epoch lineno} {
        if {[clock milliseconds] - $YieldClock <= [::questlog::config::get search_yield_ms]} {
            return 0
        }
        if {$my_epoch != $Epoch} { return 1 }
        after [::questlog::config::get search_resume_ms] [list ::questlog::resume_coro [info coroutine]]
        yield
        set YieldClock [clock milliseconds]
        return [expr {$my_epoch != $Epoch}]
    }

    method dict_or {d k default} {
        if {[dict exists $d $k]} { return [dict get $d $k] }
        return $default
    }

    method start_threaded {snapshot N} {
        package require Thread
        my cancel
        set clauses [::questlog::search::build_clauses $snapshot]
        if {![::questlog::search::clauses_any $clauses]} return
        set my_epoch [incr Epoch]
        set Active 1
        set MatchedSessions [dict create]
        set Counts [dict create done 0 total 0 matches 0]

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
        set wscript "[::questlog::search::worker_prelude $::ROOT]$::questlog::search::WorkerScript"
        foreach slice $slices {
            set tid [thread::create $wscript]
            lappend Workers $tid
            thread::send -async $tid \
                [list worker_run $main_tid $obj_cmd $my_epoch $slice $clauses]
        }
    }

    # Receives a typed match from a worker. Re-derives is_first on the
    # main side so the per-session-first-hit invariant is authoritative
    # here rather than relying on disjoint slicing.
    method on_worker_match {epoch matchcore} {
        if {$epoch != $Epoch} return
        set path [dict get $matchcore path]
        set is_first [expr {![dict exists $MatchedSessions $path]}]
        dict set MatchedSessions $path 1
        dict set matchcore is_first $is_first
        {*}$OnMatch $matchcore
        dict incr Counts matches
    }

    method on_worker_row {epoch row} {
        if {$epoch != $Epoch} return
        $Scan publish_row $row
        dict incr Counts done
        set d [dict get $Counts done]
        set t [dict get $Counts total]
        if {$d % [::questlog::config::get search_progress_files] == 0} {
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
