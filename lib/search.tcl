package require Tcl 9
package require TclOO
package require json

namespace eval ::questlog::search {}

# Whether the Thread package loads on this host, checked once and cached.
# Thread is the designed dependency of the GUI (search fan-out, cost tpool),
# but some hosts lack it (a from-source Tcl 9 built without the Thread
# extension; the Debian and Ubuntu packages ship it alongside tcl9.0, and the
# self-contained image links it statically). The app then runs single-threaded: search on
# the coroutine path, the cost pass on the main thread, and a banner says so
# unless QUESTLOG_THREADS=0 acknowledges the mode.
proc ::questlog::search::thread_available {} {
    variable ThreadAvailable
    if {![info exists ThreadAvailable]} {
        set ThreadAvailable [expr {![catch {package require Thread}]}]
    }
    return $ThreadAvailable
}

# The QUESTLOG_THREADS override, validated: a non-negative integer is the
# search worker count (0 = the single-thread coroutine path, and it also
# silences the missing-Thread banner); unset or malformed returns "". The one
# home for reading the variable, shared by pick_thread_count and the banner.
proc ::questlog::search::env_threads {} {
    if {[info exists ::env(QUESTLOG_THREADS)]} {
        set v $::env(QUESTLOG_THREADS)
        if {[string is integer -strict $v] && $v >= 0} { return $v }
    }
    return ""
}

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
    snippet_lead    [::questlog::config::get snippet_lead] \
    snippet_trail   [::questlog::config::get snippet_trail] \
    tool_param_cap  [::questlog::config::get tool_param_cap] \
    tool_render_cap [::questlog::config::get tool_render_cap]]]
"
}

# Tokenise the search field's contents. Space-separated; double-quoted runs
# preserve a phrase. Trailing/leading whitespace ignored. Empty input yields
# an empty list.
proc ::questlog::search::search_terms {s} {
    set out [list]
    set buf ""
    set in_quotes 0
    foreach ch [split $s ""] {
        if {$ch eq "\""} { set in_quotes [expr {!$in_quotes}]; continue }
        if {$ch eq " " && !$in_quotes} {
            if {$buf ne ""} { lappend out $buf; set buf "" }
            continue
        }
        append buf $ch
    }
    if {$buf ne ""} { lappend out $buf }
    return $out
}

# parse_regions spec - the block-type set a region-spec selects. spec is a
# comma-joined list of region tokens (user, assistant, tool-use, tool-result,
# any); each token may be any unambiguous prefix, so `assi` resolves to
# assistant. `any`, an empty spec, or any token resolving to `any` returns the
# empty list, which the matcher reads as unrestricted (every block type,
# including the system/compaction blocks the four named regions exclude). An
# unknown token, or an ambiguous prefix (t, to, tool, tool-, a), throws and names
# the candidates - never a silent default. The one home for the region
# vocabulary the CLI colon-qualifier and the GUI scope selector both parse; the
# hyphenated tokens map to the jsonl block types.
proc ::questlog::search::parse_regions {spec} {
    set canon {user assistant tool-use tool-result any}
    set to_btype {user user  assistant assistant  tool-use tool_use  tool-result tool_result}
    set out [list]
    foreach tok [split [string trim $spec] ,] {
        set tok [string trim $tok]
        if {$tok eq ""} continue
        if {$tok in $canon} {
            set hit $tok
        } else {
            set cands [list]
            foreach c $canon {
                if {[string equal -length [string length $tok] $tok $c]} { lappend cands $c }
            }
            if {[llength $cands] == 0} {
                error "unknown region '$tok' (want: [join $canon {, }])"
            }
            if {[llength $cands] > 1} {
                error "ambiguous region '$tok' (matches: [join $cands {, }])"
            }
            set hit [lindex $cands 0]
        }
        if {$hit eq "any"} { return {} }
        lappend out [dict get $to_btype $hit]
    }
    return [lsort -unique $out]
}

# build_clauses snapshot - normalise the toolbar's snapshot into the matcher's
# {leaves tree nocase} form. The search terms become keyword leaves carrying the
# scope's region set, ANDed together; the regex patterns, the {op path} file
# values and the {name key} tool values each become a leaf, ORed within their
# kind, and those OR-groups AND with the terms. This is the GUI's existing
# meaning - all terms, and one of each filled-in filter - expressed as one tree.
# File pairs keep only a non-empty path, tool pairs a non-empty name; empty
# entries are stripped.
proc ::questlog::search::build_clauses {snapshot} {
    set search ""
    if {[dict exists $snapshot search]} { set search [dict get $snapshot search] }
    set terms [::questlog::search::search_terms $search]
    set search_case 0
    if {[dict exists $snapshot search_case]} {
        set search_case [dict get $snapshot search_case]
    }
    set regions  [::questlog::search::parse_regions [dict getdef $snapshot search_regions any]]
    set patterns [::questlog::search::trim_values [dict getdef $snapshot pattern {}]]
    set files    [::questlog::search::trim_pairs  [dict getdef $snapshot file {}] 1]
    set tools    [::questlog::search::trim_pairs  [dict getdef $snapshot tool {}] 0]

    set leaves [list]
    set andnodes [list]
    foreach t $terms {
        lappend andnodes [::questlog::match::tnode_leaf [llength $leaves]]
        lappend leaves [::questlog::match::kw_leaf $t $regions 0]
    }
    foreach {kind src} [list regex $patterns file $files tool $tools] {
        set ornodes [list]
        foreach v $src {
            set id [llength $leaves]
            switch -- $kind {
                regex { lappend leaves [::questlog::match::rx_leaf $v {} 0] }
                file  { lappend leaves [::questlog::match::tool_leaf file [lindex $v 0] [lindex $v 1] 0] }
                tool  { lappend leaves [::questlog::match::tool_leaf tool [lindex $v 0] [lindex $v 1] 0] }
            }
            lappend ornodes [::questlog::match::tnode_leaf $id]
        }
        if {[llength $ornodes] > 0} { lappend andnodes [::questlog::match::tnode_or $ornodes] }
    }
    return [dict create leaves $leaves \
        tree [::questlog::match::tnode_and $andnodes] \
        nocase [expr {!$search_case}]]
}

proc ::questlog::search::trim_values {vs} {
    set out [list]
    foreach v $vs { if {$v ne ""} { lappend out $v } }
    return $out
}

# Keep only pairs whose element at $keep is non-empty: a file pair {op path}
# survives a non-empty path (keep 1); a tool pair {name key} a non-empty name
# (keep 0). The matcher iterates the survivors directly.
proc ::questlog::search::trim_pairs {pairs keep} {
    set out [list]
    foreach p $pairs { if {[lindex $p $keep] ne ""} { lappend out $p } }
    return $out
}

# Map a CLI / launcher `tool:<selector>` token to a clause. Returns {file <op>}
# when the selector is a file op (read / write / edit / file), else {tool <name>}
# with the tool name canonicalised - the known built-ins title-cased, an unknown
# selector (an MCP tool, or an exact name) passing through verbatim. The caller
# appends the user's value: a path suffix for file, a key for tool. One home for
# the selector vocabulary the headless CLI and the GUI launcher both parse.
proc ::questlog::search::tool_selector {selector} {
    set file_ops {read read  write write  edit edit  file either}
    set tool_names {bash Bash  grep Grep  glob Glob  read Read  write Write \
        edit Edit  multiedit MultiEdit  notebookedit NotebookEdit \
        websearch WebSearch  webfetch WebFetch  task Task  agent Agent \
        taskcreate TaskCreate  taskupdate TaskUpdate  taskget TaskGet \
        tasklist TaskList  todowrite TodoWrite  skill Skill}
    if {[dict exists $file_ops $selector]} {
        return [list file [dict get $file_ops $selector]]
    }
    return [list tool [dict getdef $tool_names [string tolower $selector] $selector]]
}

# clauses_any clauses - 1 iff there is at least one leaf clause. Used by the
# matcher to early-exit when the user clears every filter. A region set rides on
# each keyword leaf and is never a clause of its own.
proc ::questlog::search::clauses_any {clauses} {
    return [expr {[llength [dict get $clauses leaves]] > 0}]
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
    # (sourced via worker_prelude) and fan its row and full match list back to
    # the main thread in one message per file, so a session's matches arrive
    # together and render in a single pass.
    proc worker_run {main_tid obj_cmd epoch paths clauses} {
        set matches_in_slice 0
        foreach path $paths {
            # One hostile file must not kill the slice: without the
            # terminating on_worker_done the main thread would wait forever.
            # Log, count as unmatched, keep scanning.
            if {[catch {::questlog::match::scan_file $path $clauses} r]} {
                puts stderr "questlog: search worker: $path: $r"
                continue
            }
            lassign $r row matches
            if {$row eq ""} continue
            thread::send -async $main_tid \
                [list ::questlog::search::dispatch $obj_cmd on_worker_file $epoch $row $matches]
            incr matches_in_slice [llength $matches]
        }
        thread::send -async $main_tid \
            [list ::questlog::search::dispatch $obj_cmd on_worker_done \
                 $epoch [llength $paths] $matches_in_slice]
    }
    thread::wait
}

# ::questlog::Search - clause-tree search across session logs, threaded
# fan-out by default; QUESTLOG_THREADS tunes the worker count, or 0
# selects the single-thread coroutine path.
#
# The criteria are a flat list of leaf clauses and a boolean tree over them. A
# leaf is a keyword or regex needle in an optional region set (user, assistant,
# tool_use, tool_result; empty = anywhere), or a structured {op path} file value
# or {name key} tool value. Each leaf is session-satisfied once a record matches
# it; a session qualifies when the tree (adjacency AND, --or, --not) holds over
# those per-leaf truths. A regex matches a content block in its regions; a file
# value matches a tool_use whose tool name is in the op's set and whose path ends
# with the value, so a bare filename matches that file in any directory; a tool
# value matches a use of the named tool whose invocation text contains the key
# (empty key = any use).
#
# Per file: pre-filter each raw line by any leaf's literal (the needle for a
# keyword, the pattern run for regex, the path/key/name for a tool leaf) so the
# JSON parse is skipped on lines that cannot contribute; on a candidate line,
# parse once and score each leaf via leaf_record_hit, marking leaves satisfied
# and buffering the snippets of positively-used leaves. At end of file, if the
# tree holds, deliver the file's row and its match list (in line order) together
# through OnFile; each match is a dict {path lineoff ts btype content folder}.
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
    variable OnFile
    variable OnProgress
    variable OnDone
    variable Active
    variable Workers           ;# tids of in-flight worker threads
    variable WorkersRemaining  ;# slices yet to report on_worker_done
    variable YieldClock        ;# clock-ms of the coroutine path's last yield
    variable Snapshot          ;# the snapshot this run searches under (scope gate)

    constructor {scan on_file on_progress on_done} {
        set Scan $scan
        set Epoch 0
        set MatchedSessions [dict create]
        set Counts [dict create done 0 total 0 matches 0]
        set OnFile $on_file
        set OnProgress $on_progress
        set OnDone $on_done
        set Active 0
        set Workers [list]
        set WorkersRemaining 0
        set Snapshot [dict create]
    }

    # 1 iff a matched row passes the snapshot's row-level SCOPE - the full
    # filter::row_matches predicate (subtree scope plus the min-turns floor;
    # since/until are already pruned by list_paths_for, and row_matches re-checks
    # them harmlessly with the bookmark pin). subtree is the scope filter
    # list_paths_for cannot fully pre-prune: since/until are mtime bounds it
    # already applies, but subtree membership is a per-row question. The GUI
    # search corpus once skipped this, so a subtree-scoped search
    # returned sessions from other folders. Bookmarked, running, and the
    # bookmarked-only/running-only toggles are session-list view toggles, not
    # search scope, so they are deliberately not applied here. The row arrives
    # from scan_file without a residence stamp (workers never resolve folders),
    # so stamp it here on the main thread before the predicate reads it.
    method row_in_scope {row} {
        return [::questlog::filter::row_matches $Snapshot [$Scan stamp_subtree $row]]
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
        set Snapshot $snapshot
        set N [my pick_thread_count]
        if {$N > 0} {
            my start_threaded $snapshot $N
            return
        }
        my cancel
        set clauses [::questlog::search::build_clauses $snapshot]
        if {![::questlog::search::clauses_any $clauses]} {
            # An empty clause set completes instantly: fire the callbacks the
            # way the empty-corpus path does, so a caller awaiting OnDone (the
            # status line, the spinner) never waits on a search that will not
            # run - a whitespace-only query used to hang the "Searching..."
            # state forever here.
            after 1 [list {*}$OnProgress 0 0 0]
            after 1 [list {*}$OnDone 0 0]
            return
        }
        set my_epoch [incr Epoch]
        set Active 1
        set MatchedSessions [dict create]
        set Counts [dict create done 0 total 0 matches 0]
        set co ::questlog::search::coro_$my_epoch
        coroutine $co [namespace which my] run_search $my_epoch $snapshot
    }

    # Worker count for a search. 0 when the Thread package is unavailable
    # (the coroutine path is the only one that runs); otherwise threaded by
    # default, with QUESTLOG_THREADS overriding - a non-negative integer sets
    # the count, 0 forces the single-thread coroutine path. An unset or
    # malformed value falls back to default_thread_count.
    method pick_thread_count {} {
        if {![::questlog::search::thread_available]} { return 0 }
        set v [::questlog::search::env_threads]
        if {$v ne ""} { return $v }
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
        # Search only interactive (cli) sessions, no subagents: the automation
        # exhaust (sdk-cli) is ~70x the file count and is not what a person
        # searches for. A future toggle that re-admits sdk-cli would flip the
        # two trailing flags back to `1 0` (include_subagents on, cli_only off).
        set paths [$Scan list_paths_for $snapshot 0 1]
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
            # An error inside (one hostile file) is confined to that file: it
            # logs, counts as unmatched, and the search still completes.
            if {[catch {::questlog::match::scan_file $path $clauses $tick $yl} r]} {
                puts stderr "questlog: search: $path: $r"
                set r [list "" {}]
            }
            lassign $r row matches
            if {$my_epoch != $Epoch} return
            # row "" means the file could not be opened (a cancel mid-file is
            # caught by the epoch check above); count it and move on.
            if {$row eq ""} {
                incr count
                dict set Counts done $count
                continue
            }
            # Publish row data back to Scan as a free side-effect. Subagent
            # files are not browse sessions, so their rows are never published
            # (the list owns the child model); their matches still flow to OnFile.
            if {![dict getdef $row is_child 0]} { $Scan publish_row $row }
            # A session qualifies only when every clause is satisfied (scan_file
            # returns no matches otherwise); deliver the whole match list at once
            # so the session renders in one pass.
            if {[llength $matches] > 0 && [my row_in_scope $row] \
                && ![dict exists $MatchedSessions $path]} {
                dict set MatchedSessions $path 1
                dict incr Counts matches [llength $matches]
                {*}$OnFile $matches
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

    method start_threaded {snapshot N} {
        set Snapshot $snapshot
        package require Thread
        my cancel
        set clauses [::questlog::search::build_clauses $snapshot]
        if {![::questlog::search::clauses_any $clauses]} {
            # Same instant completion as the coroutine path's empty-clause exit.
            after 1 [list {*}$OnProgress 0 0 0]
            after 1 [list {*}$OnDone 0 0]
            return
        }
        set my_epoch [incr Epoch]
        set Active 1
        set MatchedSessions [dict create]
        set Counts [dict create done 0 total 0 matches 0]

        # cli-only, no subagents (see the coroutine path's note above).
        set paths   [$Scan list_paths_for $snapshot 0 1]
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

    # Receives one found file from a worker: its row (published to Scan for
    # memoisation and the cost-pass side-effect) and its full match list,
    # delivered together so the session renders in a single pass. Disjoint
    # slices mean each path arrives once; the MatchedSessions guard makes that
    # authoritative rather than relying on it.
    method on_worker_file {epoch row matches} {
        if {$epoch != $Epoch} return
        # Subagent files are not browse sessions: their rows are not published
        # (the list owns the child model); their matches still flow to OnFile.
        if {![dict getdef $row is_child 0]} { $Scan publish_row $row }
        dict incr Counts done
        set d [dict get $Counts done]
        set t [dict get $Counts total]
        if {$d % [::questlog::config::get search_progress_files] == 0} {
            {*}$OnProgress $d $t [dict get $Counts matches]
        }
        if {[llength $matches] == 0} return
        if {![my row_in_scope $row]} return
        set path [dict get $row path]
        if {[dict exists $MatchedSessions $path]} return
        dict set MatchedSessions $path 1
        dict incr Counts matches [llength $matches]
        {*}$OnFile $matches
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
