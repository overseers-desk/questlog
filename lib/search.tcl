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

# build_clauses snapshot - normalise the toolbar's snapshot into the form
# the matcher consumes: tokenised search terms, the regex patterns from the
# pattern row, and the path lists from the read/wrote/edited rows. Each
# value list is the user's input with empty entries stripped.
proc ::fms::search::build_clauses {snapshot} {
    set search ""
    if {[dict exists $snapshot search]} { set search [dict get $snapshot search] }
    set terms [::fms::ui::search_terms $search]
    set search_case 0
    if {[dict exists $snapshot search_case]} {
        set search_case [dict get $snapshot search_case]
    }
    set out [dict create \
        terms        $terms \
        nocase       [expr {!$search_case}] \
        patterns     [::fms::search::trim_values [dict_or $snapshot pattern {}]] \
        paths_read   [::fms::search::trim_values [dict_or $snapshot read    {}]] \
        paths_wrote  [::fms::search::trim_values [dict_or $snapshot wrote   {}]] \
        paths_edited [::fms::search::trim_values [dict_or $snapshot edited  {}]]]
    return $out
}

proc ::fms::search::trim_values {vs} {
    set out [list]
    foreach v $vs { if {$v ne ""} { lappend out $v } }
    return $out
}

proc ::fms::search::dict_or {d k default} {
    if {[dict exists $d $k]} { return [dict get $d $k] }
    return $default
}

# clauses_any clauses - 1 iff any clause has at least one value. Used by
# the matcher to early-exit when the user clears every filter.
proc ::fms::search::clauses_any {clauses} {
    foreach k {terms patterns paths_read paths_wrote paths_edited} {
        if {[llength [dict get $clauses $k]] > 0} { return 1 }
    }
    return 0
}

# record_hits rec clauses - the evidence a parsed record gives for each
# clause. Returns a dict:
#   hits        list of {btype content} snippets to flush if the session passes
#   rec_text    concatenated text of every block in this record (for the
#               cross-record "all search terms appear somewhere" check)
#   pat_hit     1 iff any pattern matched any block in this record
#   read_hit    1 iff a Read tool_use referenced a path in paths_read
#   wrote_hit   1 iff a Write tool_use referenced a path in paths_wrote
#   edited_hit  1 iff an Edit/MultiEdit/NotebookEdit referenced a path in paths_edited
# The worker thread carries its own copy of this proc; the two must stay in sync.
proc ::fms::search::record_hits {rec clauses} {
    set patterns     [dict get $clauses patterns]
    set terms        [dict get $clauses terms]
    set nocase       [dict get $clauses nocase]
    set paths_read   [dict get $clauses paths_read]
    set paths_wrote  [dict get $clauses paths_wrote]
    set paths_edited [dict get $clauses paths_edited]

    set hits [list]
    set rec_text ""
    set pat_hit 0
    set read_hit 0
    set wrote_hit 0
    set edited_hit 0

    set need_blocks [expr {[llength $terms] > 0 || [llength $patterns] > 0}]
    if {$need_blocks} {
        set blocks [::fms::jsonl::extract_blocks $rec]
        foreach {btype content} $blocks {
            append rec_text " " $content
            foreach p $patterns {
                if {[regexp -- $p $content]} {
                    set pat_hit 1
                    lappend hits [list $btype \
                        [::fms::search::snippet_window $content $p ""]]
                }
            }
            foreach t $terms {
                set needle [expr {$nocase ? [string tolower $t] : $t}]
                set hay    [expr {$nocase ? [string tolower $content] : $content}]
                if {[string first $needle $hay] >= 0} {
                    set re_opts [expr {$nocase ? "-nocase" : ""}]
                    lappend hits [list $btype \
                        [::fms::search::snippet_window $content $t $re_opts]]
                }
            }
        }
    }

    set need_tools [expr {[llength $paths_read]   > 0
                        || [llength $paths_wrote]  > 0
                        || [llength $paths_edited] > 0}]
    if {$need_tools} {
        set tools [::fms::jsonl::record_tool_uses $rec]
        set toolsets [dict create \
            read   {Read} \
            wrote  {Write} \
            edited {Edit MultiEdit NotebookEdit}]
        foreach {kind paths_var} {read paths_read wrote paths_wrote edited paths_edited} {
            set paths [set $paths_var]
            if {[llength $paths] == 0} continue
            set toolset [dict get $toolsets $kind]
            foreach t $tools {
                if {[dict get $t name] ni $toolset} continue
                set tp [dict get $t path]
                foreach val $paths {
                    set off [expr {[string length $tp] - [string length $val]}]
                    if {$off >= 0 && [string range $tp $off end] eq $val} {
                        switch -- $kind {
                            read   { set read_hit 1 }
                            wrote  { set wrote_hit 1 }
                            edited { set edited_hit 1 }
                        }
                        lappend hits [list tool_use \
                            [::fms::search::clean_text [dict get $t rendered] 300]]
                        break
                    }
                }
            }
        }
    }

    return [dict create hits $hits rec_text $rec_text \
        pat_hit $pat_hit read_hit $read_hit \
        wrote_hit $wrote_hit edited_hit $edited_hit]
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
    proc record_hits {rec clauses} {
        set patterns     [dict get $clauses patterns]
        set terms        [dict get $clauses terms]
        set nocase       [dict get $clauses nocase]
        set paths_read   [dict get $clauses paths_read]
        set paths_wrote  [dict get $clauses paths_wrote]
        set paths_edited [dict get $clauses paths_edited]

        set hits [list]
        set rec_text ""
        set pat_hit 0
        set read_hit 0
        set wrote_hit 0
        set edited_hit 0

        set need_blocks [expr {[llength $terms] > 0 || [llength $patterns] > 0}]
        if {$need_blocks} {
            set blocks [extract_blocks $rec]
            foreach {btype content} $blocks {
                append rec_text " " $content
                foreach p $patterns {
                    if {[regexp -- $p $content]} {
                        set pat_hit 1
                        lappend hits [list $btype [snippet_window $content $p ""]]
                    }
                }
                foreach t $terms {
                    set needle [expr {$nocase ? [string tolower $t] : $t}]
                    set hay    [expr {$nocase ? [string tolower $content] : $content}]
                    if {[string first $needle $hay] >= 0} {
                        set re_opts [expr {$nocase ? "-nocase" : ""}]
                        lappend hits [list $btype [snippet_window $content $t $re_opts]]
                    }
                }
            }
        }

        set need_tools [expr {[llength $paths_read]   > 0
                            || [llength $paths_wrote]  > 0
                            || [llength $paths_edited] > 0}]
        if {$need_tools} {
            set tools [record_tool_uses $rec]
            set toolsets [dict create \
                read   {Read} \
                wrote  {Write} \
                edited {Edit MultiEdit NotebookEdit}]
            foreach {kind paths_var} {read paths_read wrote paths_wrote edited paths_edited} {
                set paths [set $paths_var]
                if {[llength $paths] == 0} continue
                set toolset [dict get $toolsets $kind]
                foreach t $tools {
                    if {[dict get $t name] ni $toolset} continue
                    set tp [dict get $t path]
                    foreach val $paths {
                        set off [expr {[string length $tp] - [string length $val]}]
                        if {$off >= 0 && [string range $tp $off end] eq $val} {
                            switch -- $kind {
                                read   { set read_hit 1 }
                                wrote  { set wrote_hit 1 }
                                edited { set edited_hit 1 }
                            }
                            lappend hits [list tool_use \
                                [clean_text [dict get $t rendered] 300]]
                            break
                        }
                    }
                }
            }
        }

        return [dict create hits $hits rec_text $rec_text \
            pat_hit $pat_hit read_hit $read_hit \
            wrote_hit $wrote_hit edited_hit $edited_hit]
    }

    proc worker_run {main_tid obj_cmd epoch paths clauses} {
        set terms        [dict get $clauses terms]
        set patterns     [dict get $clauses patterns]
        set paths_read   [dict get $clauses paths_read]
        set paths_wrote  [dict get $clauses paths_wrote]
        set paths_edited [dict get $clauses paths_edited]
        set nocase       [dict get $clauses nocase]

        set path_substrs [concat $paths_read $paths_wrote $paths_edited]
        set term_needles [list]
        foreach t $terms {
            lappend term_needles [expr {$nocase ? [string tolower $t] : $t}]
        }

        set matches_in_slice 0
        foreach path $paths {
            set folder [file tail [file dirname $path]]
            set users 0
            set first_user ""
            set cwd_hint ""
            set first_ts ""
            set lineno 0
            set seen_terms [dict create]
            set all_terms_seen [expr {[llength $terms] == 0}]
            set pat_sat    [expr {[llength $patterns]     == 0}]
            set read_sat   [expr {[llength $paths_read]   == 0}]
            set wrote_sat  [expr {[llength $paths_wrote]  == 0}]
            set edited_sat [expr {[llength $paths_edited] == 0}]
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
                if {[llength $term_needles] > 0} {
                    set hay [expr {$nocase ? [string tolower $line] : $line}]
                    foreach n $term_needles {
                        if {[string first $n $hay] >= 0} { set candidate 1; break }
                    }
                }
                if {!$candidate} {
                    foreach p $patterns {
                        if {[regexp -- $p $line]} { set candidate 1; break }
                    }
                }
                if {!$candidate} {
                    foreach s $path_substrs {
                        if {[string first $s $line] >= 0} { set candidate 1; break }
                    }
                }
                if {!$candidate} continue
                if {[catch {::json::json2dict $line} rec]} continue
                set r [record_hits $rec $clauses]
                if {[dict get $r pat_hit]}    { set pat_sat 1 }
                if {[dict get $r read_hit]}   { set read_sat 1 }
                if {[dict get $r wrote_hit]}  { set wrote_sat 1 }
                if {[dict get $r edited_hit]} { set edited_sat 1 }
                if {!$all_terms_seen} {
                    set rec_text [dict get $r rec_text]
                    if {$nocase} { set rec_text [string tolower $rec_text] }
                    foreach t $terms n $term_needles {
                        if {[dict exists $seen_terms $t]} continue
                        if {[string first $n $rec_text] >= 0} {
                            dict set seen_terms $t 1
                        }
                    }
                    if {[dict size $seen_terms] == [llength $terms]} {
                        set all_terms_seen 1
                    }
                }
                foreach hit [dict get $r hits] {
                    lassign $hit btype content
                    set key "$lineno $btype $content"
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
            if {$all_terms_seen && $pat_sat && $read_sat
                && $wrote_sat && $edited_sat && [llength $buffer] > 0} {
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
        set clauses [::fms::search::build_clauses $snapshot]
        if {![::fms::search::clauses_any $clauses]} return
        set my_epoch [incr Epoch]
        set Active 1
        set MatchedSessions [dict create]
        set Counts [dict create done 0 total 0 matches 0]
        set co ::fms::search::coro_$my_epoch
        coroutine $co [namespace which my] run_search $my_epoch $snapshot
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

        set clauses [::fms::search::build_clauses $snapshot]
        set terms        [dict get $clauses terms]
        set patterns     [dict get $clauses patterns]
        set paths_read   [dict get $clauses paths_read]
        set paths_wrote  [dict get $clauses paths_wrote]
        set paths_edited [dict get $clauses paths_edited]
        set nocase       [dict get $clauses nocase]

        # Per-line pre-filter literals: a record needs parsing only when its
        # raw text contains a candidate substring for at least one clause.
        # Terms are checked with case respected; when nocase, the line is
        # lower-cased once per line.
        set path_substrs [concat $paths_read $paths_wrote $paths_edited]
        set term_needles [list]
        foreach t $terms {
            lappend term_needles [expr {$nocase ? [string tolower $t] : $t}]
        }

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
            set seen_terms [dict create]
            set all_terms_seen [expr {[llength $terms] == 0}]
            set pat_sat    [expr {[llength $patterns]     == 0}]
            set read_sat   [expr {[llength $paths_read]   == 0}]
            set wrote_sat  [expr {[llength $paths_wrote]  == 0}]
            set edited_sat [expr {[llength $paths_edited] == 0}]
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
                if {[llength $term_needles] > 0} {
                    set hay [expr {$nocase ? [string tolower $line] : $line}]
                    foreach n $term_needles {
                        if {[string first $n $hay] >= 0} { set candidate 1; break }
                    }
                }
                if {!$candidate} {
                    foreach p $patterns {
                        if {[regexp -- $p $line]} { set candidate 1; break }
                    }
                }
                if {!$candidate} {
                    foreach s $path_substrs {
                        if {[string first $s $line] >= 0} { set candidate 1; break }
                    }
                }
                if {$candidate && ![catch {::json::json2dict $line} rec]} {
                    set r [::fms::search::record_hits $rec $clauses]
                    if {[dict get $r pat_hit]}    { set pat_sat 1 }
                    if {[dict get $r read_hit]}   { set read_sat 1 }
                    if {[dict get $r wrote_hit]}  { set wrote_sat 1 }
                    if {[dict get $r edited_hit]} { set edited_sat 1 }
                    if {!$all_terms_seen} {
                        set rec_text [dict get $r rec_text]
                        if {$nocase} { set rec_text [string tolower $rec_text] }
                        foreach t $terms n $term_needles {
                            if {[dict exists $seen_terms $t]} continue
                            if {[string first $n $rec_text] >= 0} {
                                dict set seen_terms $t 1
                            }
                        }
                        if {[dict size $seen_terms] == [llength $terms]} {
                            set all_terms_seen 1
                        }
                    }
                    foreach hit [dict get $r hits] {
                        lassign $hit btype content
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
            # A session qualifies only when every clause is satisfied;
            # flush its buffered evidence in line order, the first row
            # marking the session for the consumers.
            if {$all_terms_seen && $pat_sat && $read_sat
                && $wrote_sat && $edited_sat && [llength $buffer] > 0} {
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
        set clauses [::fms::search::build_clauses $snapshot]
        if {![::fms::search::clauses_any $clauses]} return
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
        foreach slice $slices {
            set tid [thread::create $::fms::search::WorkerScript]
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
