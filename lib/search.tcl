package require Tcl 9
package require TclOO
package require json

namespace eval ::csm::search {}

# Worker→main delivery shim. Async messages may arrive after the Search
# object is destroyed; resolve the object command lazily and swallow.
proc ::csm::search::dispatch {obj_cmd args} {
    if {[info commands $obj_cmd] eq ""} return
    if {[catch {{*}$obj_cmd {*}$args} err]} {
        puts stderr "csm::search::dispatch: $err"
    }
}

# Whitespace-collapse and length-cap a content string for display.
proc ::csm::search::clean_text {s {limit 300}} {
    set s [regsub -all {[\s]+} $s " "]
    set s [string trim $s]
    if {[string length $s] > $limit} {
        set s "[string range $s 0 [expr {$limit - 1}]]…"
    }
    return $s
}

# Render a tool_use block as "Name(key=value, ...)". Most informative key
# first when the tool is one we know; otherwise dict insertion order.
proc ::csm::search::format_tool_use {name input} {
    if {[catch {dict size $input}]} { return "${name}()" }
    set keys [dict keys $input]
    if {[llength $keys] == 0} { return "${name}()" }
    set ordered [::csm::search::_order_tool_keys $name $keys]
    set parts [list]
    foreach k $ordered {
        set v [dict get $input $k]
        # Tcl's value duck-typing means a parsed JSON string and a
        # parsed JSON object are indistinguishable here; treat every
        # value as a display string. Whitespace-collapse and cap.
        set v [regsub -all {[\s]+} $v " "]
        if {[string length $v] > 60} { set v "[string range $v 0 59]…" }
        lappend parts "${k}=${v}"
    }
    set s "${name}([join $parts {, }])"
    if {[string length $s] > 250} { set s "[string range $s 0 249]…" }
    return $s
}

proc ::csm::search::_order_tool_keys {name keys} {
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

# Body sourced into each worker thread. Tcl threads carry separate
# interpreters with no access to procs defined in the parent, so
# extract_blocks, format_tool_use, clean_text and the jsonl helpers are
# duplicated here. Both copies must stay in sync.
set ::csm::search::WorkerScript {
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
            if {[string length $v] > 60} { set v "[string range $v 0 59]…" }
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
                if {!$all_match} continue
                if {[catch {::json::json2dict $line} rec]} continue
                foreach {btype bcontent} [extract_blocks $rec] {
                    set has_hit 0
                    foreach pat $patterns {
                        if {$pat eq ""} continue
                        if {[regexp {*}$re_opts -- $pat $bcontent]} { set has_hit 1; break }
                    }
                    if {!$has_hit} continue
                    set is_first [expr {!$seen_match_in_file}]
                    set seen_match_in_file 1
                    set bcontent [clean_text $bcontent 300]
                    thread::send -async $main_tid \
                        [list ::csm::search::dispatch $obj_cmd on_worker_match \
                             $epoch $is_first $path $lineno $first_ts \
                             $btype $bcontent $folder]
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

# ::csm::Search - regex search across session logs, coroutine by default,
# threaded fan-out when CSM_SEARCH_THREADS is set.
#
# Match flow per session line: pre-filter with the user's AND-combined
# regex against the raw line, parse JSON only on lines that pass the
# pre-filter, walk the record's content blocks, and emit one match event
# per block whose cleaned content contains at least one of the patterns.
# The block type (user/assistant/tool_use/tool_result/system) and the
# cleaned content travel together so the renderer can show typed rows.
#
# Side effect: as a free byproduct of reading each file, the row data
# (multi-turn predicate, first prompt, cwd_hint, first timestamp) is
# published to Scan via Scan.publish_row, so the tree benefits.
#
# Cancellation: each start increments Epoch; in-flight async dispatches
# carrying a stale epoch are dropped on arrival.

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
                set all_match 1
                foreach pat $patterns {
                    if {$pat eq ""} continue
                    if {![regexp {*}$re_opts -- $pat $line]} {
                        set all_match 0
                        break
                    }
                }
                if {$all_match} {
                    if {![catch {::json::json2dict $line} rec]} {
                        foreach {btype bcontent} [::csm::jsonl::extract_blocks $rec] {
                            set has_hit 0
                            foreach pat $patterns {
                                if {$pat eq ""} continue
                                if {[regexp {*}$re_opts -- $pat $bcontent]} {
                                    set has_hit 1
                                    break
                                }
                            }
                            if {!$has_hit} continue
                            set is_first [expr {![dict exists $MatchedSessions $path]}]
                            dict set MatchedSessions $path 1
                            set bcontent [::csm::search::clean_text $bcontent 300]
                            set ts_for_match [expr {$first_ts ne "" ? $first_ts : ""}]
                            {*}$OnMatch $is_first $path $lineno $ts_for_match \
                                $btype $bcontent $folder
                            dict incr Counts matches
                        }
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

    method dict_or {d k default} {
        if {[dict exists $d $k]} { return [dict get $d $k] }
        return $default
    }

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

    # Receives a typed match from a worker. Re-derives is_first on the
    # main side so the per-session-first-hit invariant is authoritative
    # here rather than relying on disjoint slicing.
    method on_worker_match {epoch worker_first path lineno ts btype content folder} {
        if {$epoch != $Epoch} return
        set is_first [expr {![dict exists $MatchedSessions $path]}]
        dict set MatchedSessions $path 1
        {*}$OnMatch $is_first $path $lineno $ts $btype $content $folder
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
