package require Tcl 9
package require json

# ::questlog::match - the pure record-matching and snippet-formatting logic of
# search, shared verbatim by the main interpreter and the search worker threads.
#
# A worker is a separate interp with no reach into the parent's procs, so this
# logic used to be hand-copied into a worker script string kept "in sync" with
# the originals by comment. Instead both sides source this one file (with
# lib/jsonl.tcl, which it leans on for the block/tool walk), so there is one
# copy and no drift. Nothing here touches Tk, TclOO or Thread; scan_file reads a
# file and json-parses lines, the rest is string work on already-parsed records.
#
# The four display caps the matchers honour live in ::questlog::config, which a
# worker cannot read, so they are injected once through set_caps - from config
# in the main interp, from prelude literals in a worker - and read back through
# cap. config.tcl stays the authored home; Caps is a derived snapshot.

namespace eval ::questlog::match {
    variable Caps [dict create]
    namespace export clean_text snippet_window format_tool_use record_hits \
        clean_preview scan_file
}

proc ::questlog::match::set_caps {capdict} {
    variable Caps
    set Caps $capdict
}

proc ::questlog::match::cap {key} {
    variable Caps
    return [dict get $Caps $key]
}

# Whitespace-collapse and length-cap a content string for display.
proc ::questlog::match::clean_text {s {limit -1}} {
    if {$limit < 0} { set limit [::questlog::match::cap content_cap] }
    set s [regsub -all {[\s]+} $s " "]
    set s [string trim $s]
    if {[string length $s] > $limit} {
        set s "[string range $s 0 [expr {$limit - 1}]]…"
    }
    return $s
}

# Collapse whitespace and strip simple JSON escapes from a first-prompt preview.
# Uncapped: the session list renders the preview with -wrap none and clips it to
# the subject column, so a byte cap here would only be a worse approximation of
# the same clipping.
proc ::questlog::match::clean_preview {s} {
    set s [regsub -all {[\s]+} $s " "]
    set s [string map [list "\\\"" "\"" "\\\\" "\\" "\\n" " " "\\t" " "] $s]
    return [string trim $s]
}

# A short window of $s centred on the first match of $pat, with leading and
# trailing "…" where text is elided. re_opts carries the search flags (e.g.
# -nocase) the caller already uses for matching. The whole matched span is
# always inside the window so the display can re-find and embolden it. If the
# pattern does not match (it should, since the caller only calls this on a
# hit) the head-capped clean_text is returned as a safe fallback.
proc ::questlog::match::snippet_window {s pat re_opts {radius -1}} {
    if {$radius < 0} { set radius [::questlog::match::cap snippet_radius] }
    set s [string trim [regsub -all {[\s]+} $s " "]]
    if {[catch {regexp -indices {*}$re_opts -- $pat $s m} ok] || !$ok} {
        return [::questlog::match::clean_text $s]
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
proc ::questlog::match::format_tool_use {name input} {
    if {[catch {dict size $input}]} { return "${name}()" }
    set keys [dict keys $input]
    if {[llength $keys] == 0} { return "${name}()" }
    set ordered [::questlog::match::_order_tool_keys $name $keys]
    set parts [list]
    foreach k $ordered {
        set v [dict get $input $k]
        # Tcl's value duck-typing means a parsed JSON string and a
        # parsed JSON object are indistinguishable here; treat every
        # value as a display string. Whitespace-collapse and cap.
        set v [regsub -all {[\s]+} $v " "]
        # Paths render whole; only bulky fields are capped.
        set pcap [::questlog::match::cap tool_param_cap]
        if {$k ni {file_path notebook_path} && [string length $v] > $pcap} {
            set v "[string range $v 0 [expr {$pcap - 1}]]…"
        }
        lappend parts "${k}=${v}"
    }
    set s "${name}([join $parts {, }])"
    set rcap [::questlog::match::cap tool_render_cap]
    if {[string length $s] > $rcap} { set s "[string range $s 0 [expr {$rcap - 1}]]…" }
    return $s
}

proc ::questlog::match::_order_tool_keys {name keys} {
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

# op_toolset op - the tool names a file `op` matches. `wrote` is the created-
# or-edited merge the GUI presents; the finer `write` and `edit` are the ops the
# CLI keeps; `either` is the union. An unknown op falls back to the union, the
# widest set.
proc ::questlog::match::op_toolset {op} {
    switch -- $op {
        read    { return {Read} }
        write   { return {Write} }
        edit    { return {Edit MultiEdit NotebookEdit} }
        wrote   { return {Write Edit MultiEdit NotebookEdit} }
        default { return {Read Write Edit MultiEdit NotebookEdit} }
    }
}

# btype_in_scope btype scope - 1 iff a block of this type is inside the search
# scope. `text` is what was said (user + assistant), `tool-call` what was
# invoked, `tool-output` what came back; `anywhere` (and any unknown scope) is
# every line type.
proc ::questlog::match::btype_in_scope {btype scope} {
    switch -- $scope {
        text        { return [expr {$btype in {user assistant}}] }
        tool-call   { return [expr {$btype eq "tool_use"}] }
        tool-output { return [expr {$btype eq "tool_result"}] }
        default     { return 1 }
    }
}

# record_hits rec clauses - the evidence a parsed record gives for each clause.
# Returns a dict:
#   hits      list of {btype content} snippets to flush if the session passes
#   rec_text  concatenated text of the in-scope blocks of this record (for the
#             cross-record "all search terms appear somewhere" check)
#   pat_hit   1 iff any regex pattern matched any block in this record
#   file_hit  1 iff any {op path} file value matched a tool_use here, by the
#             op's tool set and a path suffix
#   tool_hit  1 iff any {name key} tool value matched a tool_use here, by name
#             with the key empty or a substring of the invocation text
proc ::questlog::match::record_hits {rec clauses} {
    set patterns [dict get $clauses patterns]
    set terms    [dict get $clauses terms]
    set nocase   [dict get $clauses nocase]
    set scope    [dict get $clauses scope]
    set files    [dict get $clauses files]
    set tools    [dict get $clauses tools]

    set hits [list]
    set rec_text ""
    set pat_hit 0
    set file_hit 0
    set tool_hit 0

    set need_blocks [expr {[llength $terms] > 0 || [llength $patterns] > 0}]
    if {$need_blocks} {
        set blocks [::questlog::jsonl::extract_blocks $rec]
        foreach {btype content} $blocks {
            # Regex is the structured pattern row and matches anywhere; the
            # search terms honour the scope selector that rides on the search box.
            foreach p $patterns {
                if {[regexp -- $p $content]} {
                    set pat_hit 1
                    lappend hits [list $btype \
                        [::questlog::match::snippet_window $content $p ""]]
                }
            }
            if {![::questlog::match::btype_in_scope $btype $scope]} continue
            append rec_text " " $content
            foreach t $terms {
                set needle [expr {$nocase ? [string tolower $t] : $t}]
                set hay    [expr {$nocase ? [string tolower $content] : $content}]
                if {[string first $needle $hay] >= 0} {
                    set re_opts [expr {$nocase ? "-nocase" : ""}]
                    lappend hits [list $btype \
                        [::questlog::match::snippet_window $content $t $re_opts]]
                }
            }
        }
    }

    set need_tools [expr {[llength $files] > 0 || [llength $tools] > 0}]
    if {$need_tools} {
        set tooluses [::questlog::jsonl::record_tool_uses $rec]
        # File values OR within the one file row: a hit on any {op path} sets
        # file_hit. The path is matched by suffix, so a bare filename finds it in
        # any directory; `file` rides only on the file-touching tools.
        foreach fv $files {
            lassign $fv op val
            set toolset [::questlog::match::op_toolset $op]
            foreach t $tooluses {
                if {[dict get $t name] ni $toolset} continue
                set tp [dict get $t path]
                set off [expr {[string length $tp] - [string length $val]}]
                if {$off >= 0 && [string range $tp $off end] eq $val} {
                    set file_hit 1
                    lappend hits [list tool_use \
                        [::questlog::match::clean_text [dict get $t rendered]]]
                    break
                }
            }
        }
        # Tool values OR within the one tool row: a use of the named tool whose
        # invocation text contains the key (empty key = any use of that tool).
        foreach tv $tools {
            lassign $tv tname key
            foreach t $tooluses {
                if {[dict get $t name] ne $tname} continue
                if {$key eq "" || [string first $key [dict get $t text]] >= 0} {
                    set tool_hit 1
                    lappend hits [list tool_use \
                        [::questlog::match::clean_text [dict get $t rendered]]]
                    break
                }
            }
        }
    }

    return [dict create hits $hits rec_text $rec_text \
        pat_hit $pat_hit file_hit $file_hit tool_hit $tool_hit]
}

# Scan one session file against a built clauses dict. Pure except for reading
# $path. Returns {row matches}:
#   row     the publish_row dict (path/mtime/size/folder/uuid/first_ts/
#           is_multi/first_user/bookmarked/cwd_hint), or "" if $path could not
#           be opened or the scan was cancelled.
#   matches list of matchcore dicts {path lineoff ts btype content folder} in
#           line order, non-empty only if every clause is satisfied somewhere in
#           the file. is_first is the caller's to derive (per session, across
#           files), so it is not set here.
#
# tick is an optional command prefix invoked every yield_lines lines with the
# current line number appended; if it returns truthy the scan aborts and returns
# {"" {}}. The threaded path passes no tick (the worker's cancellation is the
# epoch drop on arrival); the coroutine path passes a tick that yields and
# reports epoch change, so a re-typed search lands without finishing a big file.
proc ::questlog::match::scan_file {path clauses {tick ""} {yield_lines 0}} {
    set terms    [dict get $clauses terms]
    set patterns [dict get $clauses patterns]
    set files    [dict get $clauses files]
    set tools    [dict get $clauses tools]
    set nocase   [dict get $clauses nocase]

    # Per-line pre-filter literals: a record needs parsing only when its raw
    # text contains a candidate substring for at least one clause. A file value
    # contributes its path; a tool value its key, or its tool name when the key
    # is empty (the name appears verbatim in the tool_use JSON), so a "used this
    # tool" clause still skips lines that cannot contribute.
    set path_substrs [list]
    foreach fv $files { lappend path_substrs [lindex $fv 1] }
    foreach tv $tools {
        lassign $tv tname key
        lappend path_substrs [expr {$key ne "" ? $key : $tname}]
    }
    set term_needles [list]
    foreach t $terms {
        lappend term_needles [expr {$nocase ? [string tolower $t] : $t}]
    }

    set folder [file tail [file dirname $path]]
    # A subagent transcript lives at <folder>/<uuid>/subagents/agent-<id>.jsonl.
    # Its hits belong to the parent session, so attribute the row and every match
    # to the parent's folder and path; the list groups them under it (issue #13).
    set is_child 0
    set parent_path ""
    set parent_uuid ""
    if {$folder eq "subagents"} {
        set is_child 1
        set sessdir [file dirname [file dirname $path]]
        set parent_uuid [file tail $sessdir]
        set folder [file tail [file dirname $sessdir]]
        set parent_path [file join [file dirname $sessdir] $parent_uuid.jsonl]
    }
    set users 0
    set first_user ""
    set cwd_hint ""
    set first_ts ""
    set lineno 0
    set seen_terms [dict create]
    set all_terms_seen [expr {[llength $terms] == 0}]
    set pat_sat  [expr {[llength $patterns] == 0}]
    set file_sat [expr {[llength $files]    == 0}]
    set tool_sat [expr {[llength $tools]    == 0}]
    set buffer [list]
    set seen [dict create]
    if {[catch {open $path r} fh]} { return [list "" {}] }
    chan configure $fh -encoding utf-8 -profile replace
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
        if {$candidate && ![catch {::json::json2dict $line} rec]} {
            set r [::questlog::match::record_hits $rec $clauses]
            if {[dict get $r pat_hit]}  { set pat_sat 1 }
            if {[dict get $r file_hit]} { set file_sat 1 }
            if {[dict get $r tool_hit]} { set tool_sat 1 }
            if {!$all_terms_seen} {
                set rec_text [dict get $r rec_text]
                if {$nocase} { set rec_text [string tolower $rec_text] }
                foreach t $terms n $term_needles {
                    if {[dict exists $seen_terms $t]} continue
                    if {[string first $n $rec_text] >= 0} { dict set seen_terms $t 1 }
                }
                if {[dict size $seen_terms] == [llength $terms]} { set all_terms_seen 1 }
            }
            foreach hit [dict get $r hits] {
                lassign $hit btype content
                set key "$lineno $btype $content"
                if {[dict exists $seen $key]} continue
                dict set seen $key 1
                lappend buffer [list $lineno $btype $content]
            }
        }
        if {$tick ne "" && $yield_lines > 0 && $lineno % $yield_lines == 0} {
            if {[{*}$tick $lineno]} { close $fh; return [list "" {}] }
        }
    }
    close $fh
    if {[catch {file mtime $path} mt]} { set mt 0 }
    if {[catch {file size  $path} sz]} { set sz 0 }
    # Does this session have subagents? Computed here too (not only in
    # scan_one), so a search row carries the flag: it both drives the chevron on
    # a session whose subagents did not match (case A) and keeps publish_row from
    # overwriting the browse flag when search republishes the row.
    set has_sub 0
    if {!$is_child} {
        set sa_uuid [file rootname [file tail $path]]
        set sa_dir [file join [file dirname $path] $sa_uuid subagents]
        set has_sub [expr {[file isdirectory $sa_dir]
            && [llength [glob -nocomplain -directory $sa_dir -- agent-*.jsonl]] > 0}]
    }
    set row [dict create \
        path $path \
        mtime $mt \
        size $sz \
        folder $folder \
        uuid [file rootname [file tail $path]] \
        first_ts $first_ts \
        is_multi [expr {$users >= 2}] \
        first_user [::questlog::match::clean_preview $first_user] \
        bookmarked [file executable $path] \
        has_subagents $has_sub \
        is_child $is_child \
        parent_path $parent_path \
        parent_uuid $parent_uuid \
        cwd_hint $cwd_hint]
    set matches [list]
    if {$all_terms_seen && $pat_sat && $file_sat
        && $tool_sat && [llength $buffer] > 0} {
        set agent_id [file rootname [file tail $path]]
        foreach ev $buffer {
            lassign $ev evlineno evbtype evcontent
            lappend matches [dict create path $path lineoff $evlineno \
                ts $first_ts btype $evbtype content $evcontent folder $folder \
                is_child $is_child parent_path $parent_path \
                parent_uuid $parent_uuid agent_id $agent_id]
        }
    }
    return [list $row $matches]
}
