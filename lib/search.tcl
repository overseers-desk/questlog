package require Tcl 9
package require TclOO
package require json

namespace eval ::fms::search {}

# Worker→main delivery shim. Async messages may arrive after the Search
# object is destroyed; resolve the object command lazily and swallow.
proc ::fms::search::dispatch {obj_cmd args} {
    if {[info commands $obj_cmd] eq ""} return
    if {[catch {{*}$obj_cmd {*}$args} err]} {
        puts stderr "fms::search::dispatch: $err"
    }
}

# Whitespace-collapse and length-cap a content string for display.
proc ::fms::search::clean_text {s {limit 300}} {
    set s [regsub -all {[\s]+} $s " "]
    set s [string trim $s]
    if {[string length $s] > $limit} {
        set s "[string range $s 0 [expr {$limit - 1}]]…"
    }
    return $s
}

# A short window of $s centred on the first match of $pat, with leading and
# trailing "…" where text is elided. re_opts carries the search flags (e.g.
# -nocase) the caller already uses for matching. The whole matched span is
# always inside the window so the display can re-find and embolden it. If the
# pattern does not match (it should, since the caller only calls this on a
# hit) the head-capped clean_text is returned as a safe fallback.
proc ::fms::search::snippet_window {s pat re_opts {radius 80}} {
    set s [string trim [regsub -all {[\s]+} $s " "]]
    if {[catch {regexp -indices {*}$re_opts -- $pat $s m} ok] || !$ok} {
        return [::fms::search::clean_text $s 300]
    }
    lassign $m a b
    set len [string length $s]
    set start [expr {$a - $radius}]
    set end   [expr {$b + $radius}]
    if {$start < 0}        { set start 0 }
    if {$end > $len - 1}   { set end [expr {$len - 1}] }
    set win [string range $s $start $end]
    if {$start > 0}        { set win "…$win" }
    if {$end < $len - 1}   { set win "$win…" }
    return $win
}

# Render a tool_use block as "Name(key=value, ...)". Most informative key
# first when the tool is one we know; otherwise dict insertion order.
proc ::fms::search::format_tool_use {name input} {
    if {[catch {dict size $input}]} { return "${name}()" }
    set keys [dict keys $input]
    if {[llength $keys] == 0} { return "${name}()" }
    set ordered [::fms::search::_order_tool_keys $name $keys]
    set parts [list]
    foreach k $ordered {
        set v [dict get $input $k]
        # Tcl's value duck-typing means a parsed JSON string and a
        # parsed JSON object are indistinguishable here; treat every
        # value as a display string. Whitespace-collapse and cap.
        set v [regsub -all {[\s]+} $v " "]
        # Paths render whole; only bulky fields are capped.
        if {$k ni {file_path notebook_path} && [string length $v] > 60} {
            set v "[string range $v 0 59]…"
        }
        lappend parts "${k}=${v}"
    }
    set s "${name}([join $parts {, }])"
    if {[string length $s] > 250} { set s "[string range $s 0 249]…" }
    return $s
}

proc ::fms::search::_order_tool_keys {name keys} {
    set preferred [dict create \
        Bash       {command} \
        Read       {file_path} \
        Edit       {file_path old_string new_string} \
        Write      {file_path content} \
        Grep       {pattern path} \
        Glob       {pattern path} \
        Task       {subagent_type prompt} \
        Agent      {subagent_type prompt} \
        TaskCreate {subject description} \
        TaskUpdate {taskId status}]
    if {![dict exists $preferred $name]} { return $keys }
    set out [list]
    foreach k [dict get $preferred $name] {
        if {$k in $keys} { lappend out $k }
    }
    foreach k $keys {
        if {$k ni $out} { lappend out $k }
    }
    return $out
}

# record_hits rec criteria re_opts - the evidence a parsed record gives for
# each criterion. Returns a flat list of {idx btype content} triples, idx
# being the criterion's position in $criteria. A regex criterion matches
# block text; a read/write/edit criterion matches a tool_use whose tool
# name is in the type's set and whose file path ends with the criterion
# value, so a bare or partial filename matches that file in any directory
# and a full path matches exactly. Content is cleaned for display. The
# worker thread carries its own copy of this proc; the two must stay in sync.
proc ::fms::search::record_hits {rec criteria re_opts} {
    set toolsets {read Read write Write edit {Edit MultiEdit NotebookEdit}}
    set hits [list]
    set have_blocks 0; set blocks {}
    set have_tools 0;  set tools {}
    set idx -1
    foreach c $criteria {
        incr idx
        set type [dict get $c type]
        set val  [dict get $c value]
        if {$val eq ""} continue
        if {$type eq "regex"} {
            if {!$have_blocks} {
                set blocks [::fms::jsonl::extract_blocks $rec]
                set have_blocks 1
            }
            foreach {btype content} $blocks {
                if {[regexp {*}$re_opts -- $val $content]} {
                    lappend hits [list $idx $btype \
                        [::fms::search::snippet_window $content $val $re_opts]]
                }
            }
        } else {
            if {!$have_tools} {
                set tools [::fms::jsonl::record_tool_uses $rec]
                set have_tools 1
            }
            set toolset [dict get $toolsets $type]
            foreach t $tools {
                set tp [dict get $t path]
                set off [expr {[string length $tp] - [string length $val]}]
                if {[dict get $t name] in $toolset && $off >= 0
                    && [string range $tp $off end] eq $val} {
                    lappend hits [list $idx tool_use \
                        [::fms::search::clean_text [dict get $t rendered] 300]]
                }
            }
        }
    }
    return $hits
}

# Body sourced into each worker thread. Tcl threads carry separate
# interpreters with no access to procs defined in the parent, so
# extract_blocks, format_tool_use, clean_text and the jsonl helpers are
# duplicated here. Both copies must stay in sync.
set ::fms::search::WorkerScript {
    package require Tcl 9
    package require Thread
    package require json

    proc dict_get_or {d k default} {
        if {[dict exists $d $k]} { return [dict get $d $k] }
        return $default
    }

    proc clean_preview {s} {
        set s [regsub -all {[\s]+} $s " "]
        set s [string map [list "\\\"" "\"" "\\\\" "\\" "\\n" " " "\\t" " "] $s]
        if {[string length $s] > 80} { set s "[string range $s 0 79]…" }
        return [string trim $s]
    }

    proc clean_text {s {limit 300}} {
        set s [regsub -all {[\s]+} $s " "]
        set s [string trim $s]
        if {[string length $s] > $limit} {
            set s "[string range $s 0 [expr {$limit - 1}]]…"
        }
        return $s
    }

    # Worker copy of ::fms::search::snippet_window; keep in sync.
    proc snippet_window {s pat re_opts {radius 80}} {
        set s [string trim [regsub -all {[\s]+} $s " "]]
        if {[catch {regexp -indices {*}$re_opts -- $pat $s m} ok] || !$ok} {
            return [clean_text $s 300]
        }
        lassign $m a b
        set len [string length $s]
        set start [expr {$a - $radius}]
        set end   [expr {$b + $radius}]
        if {$start < 0}        { set start 0 }
        if {$end > $len - 1}   { set end [expr {$len - 1}] }
        set win [string range $s $start $end]
        if {$start > 0}        { set win "…$win" }
        if {$end < $len - 1}   { set win "$win…" }
        return $win
    }

    proc is_string_content {c} {
        if {$c eq ""} { return 1 }
        if {[catch {llength $c} n]} { return 1 }
        if {$n == 0} { return 1 }
        foreach el $c {
            if {[catch {dict exists $el type} ok] || !$ok} { return 1 }
        }
        return 0
    }

    proc tool_result_text {blk} {
        if {![dict exists $blk content]} { return "" }
        set c [dict get $blk content]
        if {[is_string_content $c]} { return $c }
        set parts [list]
        foreach inner $c {
            set it [dict_get_or $inner type ""]
            switch -- $it {
                text            { lappend parts [dict_get_or $inner text ""] }
                tool_reference  { lappend parts [dict_get_or $inner tool_name ""] }
            }
        }
        return [join $parts " "]
    }

    proc _order_tool_keys {name keys} {
        set preferred [dict create \
            Bash       {command} \
            Read       {file_path} \
            Edit       {file_path old_string new_string} \
            Write      {file_path content} \
            Grep       {pattern path} \
            Glob       {pattern path} \
            Task       {subagent_type prompt} \
            Agent      {subagent_type prompt} \
            TaskCreate {subject description} \
            TaskUpdate {taskId status}]
        if {![dict exists $preferred $name]} { return $keys }
        set out [list]
        foreach k [dict get $preferred $name] {
            if {$k in $keys} { lappend out $k }
        }
        foreach k $keys {
            if {$k ni $out} { lappend out $k }
        }
        return $out
    }

    proc format_tool_use {name input} {
        if {[catch {dict size $input}]} { return "${name}()" }
        set keys [dict keys $input]
        if {[llength $keys] == 0} { return "${name}()" }
        set ordered [_order_tool_keys $name $keys]
        set parts [list]
        foreach k $ordered {
            set v [dict get $input $k]
            set v [regsub -all {[\s]+} $v " "]
            if {$k ni {file_path notebook_path} && [string length $v] > 60} {
                set v "[string range $v 0 59]…"
            }
            lappend parts "${k}=${v}"
        }
        set s "${name}([join $parts {, }])"
        if {[string length $s] > 250} { set s "[string range $s 0 249]…" }
        return $s
    }

    proc extract_blocks {rec} {
        set out [list]
        set t [dict_get_or $rec type ""]
        switch -- $t {
            user {
                if {![dict exists $rec message]} { return $out }
                set msg [dict get $rec message]
                if {![dict exists $msg content]} { return $out }
                set c [dict get $msg content]
                if {[is_string_content $c]} {
                    lappend out user $c
                } else {
                    foreach blk $c {
                        set bt [dict_get_or $blk type ""]
                        if {$bt eq "tool_result"} {
                            set bc [tool_result_text $blk]
                            if {$bc ne ""} { lappend out tool_result $bc }
                        } elseif {$bt eq "text"} {
                            lappend out user [dict_get_or $blk text ""]
                        }
                    }
                }
            }
            assistant {
                if {![dict exists $rec message]} { return $out }
                set msg [dict get $rec message]
                if {![dict exists $msg content]} { return $out }
                set c [dict get $msg content]
                if {[is_string_content $c]} {
                    lappend out assistant $c
                } else {
                    foreach blk $c {
                        set bt [dict_get_or $blk type ""]
                        if {$bt eq "text"} {
                            lappend out assistant [dict_get_or $blk text ""]
                        } elseif {$bt eq "tool_use"} {
                            set nm [dict_get_or $blk name ""]
                            set ip [dict_get_or $blk input [dict create]]
                            lappend out tool_use [format_tool_use $nm $ip]
                        }
                    }
                }
            }
            system - queue-operation {
                set c [dict_get_or $rec content ""]
                if {$c ne ""} { lappend out system $c }
            }
            last-prompt {
                set c [dict_get_or $rec lastPrompt ""]
                if {$c ne ""} { lappend out user $c }
            }
        }
        return $out
    }

    proc record_tool_uses {rec} {
        set out [list]
        if {[dict_get_or $rec type ""] ne "assistant"} { return $out }
        if {![dict exists $rec message]} { return $out }
        set msg [dict get $rec message]
        if {![dict exists $msg content]} { return $out }
        set c [dict get $msg content]
        if {[is_string_content $c]} { return $out }
        foreach blk $c {
            if {[dict_get_or $blk type ""] ne "tool_use"} continue
            set name  [dict_get_or $blk name ""]
            set input [dict_get_or $blk input [dict create]]
            set path ""
            if {![catch {dict size $input}]} {
                if {[dict exists $input file_path]} {
                    set path [dict get $input file_path]
                } elseif {[dict exists $input notebook_path]} {
                    set path [dict get $input notebook_path]
                }
            }
            lappend out [dict create name $name path $path \
                             rendered [format_tool_use $name $input]]
        }
        return $out
    }

    # Worker copy of ::fms::search::record_hits; keep in sync.
    proc record_hits {rec criteria re_opts} {
        set toolsets {read Read write Write edit {Edit MultiEdit NotebookEdit}}
        set hits [list]
        set have_blocks 0; set blocks {}
        set have_tools 0;  set tools {}
        set idx -1
        foreach c $criteria {
            incr idx
            set type [dict get $c type]
            set val  [dict get $c value]
            if {$val eq ""} continue
            if {$type eq "regex"} {
                if {!$have_blocks} { set blocks [extract_blocks $rec]; set have_blocks 1 }
                foreach {btype content} $blocks {
                    if {[regexp {*}$re_opts -- $val $content]} {
                        lappend hits [list $idx $btype [snippet_window $content $val $re_opts]]
                    }
                }
            } else {
                if {!$have_tools} { set tools [record_tool_uses $rec]; set have_tools 1 }
                set toolset [dict get $toolsets $type]
                foreach t $tools {
                    set tp [dict get $t path]
                    set off [expr {[string length $tp] - [string length $val]}]
                    if {[dict get $t name] in $toolset && $off >= 0 \
                        && [string range $tp $off end] eq $val} {
                        lappend hits [list $idx tool_use [clean_text [dict get $t rendered] 300]]
                    }
                }
            }
        }
        return $hits
    }

    proc worker_run {main_tid obj_cmd epoch paths criteria re_opts} {
        set matches_in_slice 0
        foreach path $paths {
            set folder [file tail [file dirname $path]]
            set users 0
            set first_user ""
            set cwd_hint ""
            set first_ts ""
            set lineno 0
            set ncrit [llength $criteria]
            set sat [lrepeat $ncrit 0]
            set buffer [list]
            set seen [dict create]
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
                set candidate 0
                foreach c $criteria {
                    set val [dict get $c value]
                    if {$val eq ""} continue
                    if {[dict get $c type] eq "regex"} {
                        if {[regexp {*}$re_opts -- $val $line]} { set candidate 1; break }
                    } elseif {[string first $val $line] >= 0} {
                        set candidate 1; break
                    }
                }
                if {!$candidate} continue
                if {[catch {::json::json2dict $line} rec]} continue
                foreach hit [record_hits $rec $criteria $re_opts] {
                    lassign $hit idx btype content
                    set sat [lreplace $sat $idx $idx 1]
                    set key "$lineno $btype $content"
                    if {[dict exists $seen $key]} continue
                    dict set seen $key 1
                    lappend buffer [list $lineno $btype $content]
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
                bookmarked [file executable $path] \
                cwd_hint $cwd_hint]
            thread::send -async $main_tid \
                [list ::fms::search::dispatch $obj_cmd on_worker_row $epoch $row]
            set all 1
            foreach s $sat { if {!$s} { set all 0; break } }
            if {$all && [llength $buffer] > 0} {
                foreach ev $buffer {
                    lassign $ev evlineno evbtype evcontent
                    set matchcore [dict create path $path lineoff $evlineno \
                        ts $first_ts btype $evbtype content $evcontent folder $folder]
                    thread::send -async $main_tid \
                        [list ::fms::search::dispatch $obj_cmd on_worker_match \
                             $epoch $matchcore]
                    incr matches_in_slice
                }
            }
        }
        thread::send -async $main_tid \
            [list ::fms::search::dispatch $obj_cmd on_worker_done \
                 $epoch [llength $paths] $matches_in_slice]
    }
    thread::wait
}

# ::fms::Search - typed-criteria search across session logs, coroutine by
# default, threaded fan-out when FMS_SEARCH_THREADS is set.
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

oo::class create ::fms::Search {
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

    method start {snapshot} {
        set N [my pick_thread_count]
        if {$N > 0} {
            my start_threaded $snapshot $N
            return
        }
        my cancel
        set criteria [my active_criteria $snapshot]
        if {[llength $criteria] == 0} return
        set my_epoch [incr Epoch]
        set Active 1
        set MatchedSessions [dict create]
        set Counts [dict create done 0 total 0 matches 0]
        set co ::fms::search::coro_$my_epoch
        coroutine $co [namespace which my] run_search $my_epoch $snapshot
    }

    # The snapshot's criteria with empty values dropped. A criterion is
    # {type regex|read|write|edit  value <string>}.
    method active_criteria {snapshot} {
        set out [list]
        foreach c [my dict_or $snapshot criteria {}] {
            if {[dict get $c value] ne ""} { lappend out $c }
        }
        return $out
    }

    method pick_thread_count {} {
        if {![info exists ::env(FMS_SEARCH_THREADS)]} { return 0 }
        set v $::env(FMS_SEARCH_THREADS)
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

        set criteria [my active_criteria $snapshot]
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
            set lineno 0
            set ncrit [llength $criteria]
            set sat [lrepeat $ncrit 0]
            set buffer [list]
            set seen [dict create]
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
                set candidate 0
                foreach c $criteria {
                    set val [dict get $c value]
                    if {$val eq ""} continue
                    if {[dict get $c type] eq "regex"} {
                        if {[regexp {*}$re_opts -- $val $line]} { set candidate 1; break }
                    } elseif {[string first $val $line] >= 0} {
                        set candidate 1; break
                    }
                }
                if {$candidate && ![catch {::json::json2dict $line} rec]} {
                    foreach hit [::fms::search::record_hits $rec $criteria $re_opts] {
                        lassign $hit idx btype content
                        set sat [lreplace $sat $idx $idx 1]
                        set key "$lineno $btype $content"
                        if {[dict exists $seen $key]} continue
                        dict set seen $key 1
                        lappend buffer [list $lineno $btype $content]
                    }
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
                bookmarked [file executable $path] \
                cwd_hint $cwd_hint]
            $Scan publish_row $row
            # A session qualifies only when every criterion is satisfied
            # somewhere in it; then flush its buffered evidence in line
            # order, the first row marking the session for the consumers.
            set all 1
            foreach s $sat { if {!$s} { set all 0; break } }
            if {$all && [llength $buffer] > 0} {
                foreach ev $buffer {
                    lassign $ev evlineno evbtype evcontent
                    set is_first [expr {![dict exists $MatchedSessions $path]}]
                    dict set MatchedSessions $path 1
                    {*}$OnMatch [dict create is_first $is_first path $path \
                        lineoff $evlineno ts $first_ts btype $evbtype \
                        content $evcontent folder $folder]
                    dict incr Counts matches
                }
            }
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

    method dict_or {d k default} {
        if {[dict exists $d $k]} { return [dict get $d $k] }
        return $default
    }

    method start_threaded {snapshot N} {
        package require Thread
        my cancel
        set criteria [my active_criteria $snapshot]
        if {[llength $criteria] == 0} return
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
            set tid [thread::create $::fms::search::WorkerScript]
            lappend Workers $tid
            thread::send -async $tid \
                [list worker_run $main_tid $obj_cmd $my_epoch $slice $criteria $re_opts]
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
