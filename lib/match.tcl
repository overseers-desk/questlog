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
# The five display caps the matchers honour live in ::questlog::config, which a
# worker cannot read, so they are injected once through set_caps - from config
# in the main interp, from prelude literals in a worker - and read back through
# cap. config.tcl stays the authored home; Caps is a derived snapshot.

namespace eval ::questlog::match {
    variable Caps [dict create]
    namespace export clean_text snippet_window format_tool_use \
        format_tool_use_full clean_preview scan_file leaf_record_hit \
        eval_tree btype_in_regions
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

# A short window of $s that leads with the first match of $pat: snippet_lead
# characters of context precede the matched span and snippet_trail follow it,
# with a leading and/or trailing "…" where text is elided. Leading with the hit
# keeps it on screen when the one-line snippet row is clipped to the column
# width (the row does not wrap or scroll sideways). re_opts carries the search
# flags (e.g. -nocase) the caller already uses for matching. The whole matched
# span is inside the window so the display can re-find and embolden it. If the
# pattern does not match (it should, since the caller only calls this on a hit)
# the head-capped clean_text is returned as a safe fallback.
proc ::questlog::match::snippet_window {s pat re_opts {lead -1} {trail -1}} {
    if {$lead  < 0} { set lead  [::questlog::match::cap snippet_lead] }
    if {$trail < 0} { set trail [::questlog::match::cap snippet_trail] }
    set s [string trim [regsub -all {[\s]+} $s " "]]
    if {[catch {regexp -indices {*}$re_opts -- $pat $s m} ok] || !$ok} {
        return [::questlog::match::clean_text $s]
    }
    lassign $m a b
    return [::questlog::match::window_at $s $a $b $lead $trail]
}

# The keyword twin of snippet_window: the needle is a literal, located with
# string first over the whitespace-collapsed haystack (case-folded when
# nocase), never run as a regex - so a needle that happens to look like one
# (a.c, C++) windows on its real occurrence instead of a pattern match or the
# head-capped fallback.
proc ::questlog::match::snippet_window_lit {s needle nocase {lead -1} {trail -1}} {
    if {$lead  < 0} { set lead  [::questlog::match::cap snippet_lead] }
    if {$trail < 0} { set trail [::questlog::match::cap snippet_trail] }
    set s [string trim [regsub -all {[\s]+} $s " "]]
    set needle [regsub -all {[\s]+} $needle " "]
    set hay [expr {$nocase ? [string tolower $s] : $s}]
    set n   [expr {$nocase ? [string tolower $needle] : $needle}]
    set a [string first $n $hay]
    if {$a < 0} { return [::questlog::match::clean_text $s] }
    set b [expr {$a + [string length $n] - 1}]
    return [::questlog::match::window_at $s $a $b $lead $trail]
}

# Shared window body: snippet_lead chars of context before span [a,b] and
# snippet_trail after it, elision ellipses on the clipped sides. The whole
# span stays inside the window so the display can re-find and embolden it.
proc ::questlog::match::window_at {s a b lead trail} {
    set len [string length $s]
    set start [expr {$a - $lead}]
    set end   [expr {$b + $trail}]
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

# Uncapped variant of format_tool_use for the reading body, where the full
# command must be visible (the timeline still uses the capped form). Same key
# ordering and whitespace collapse, no tool_param_cap / tool_render_cap.
proc ::questlog::match::format_tool_use_full {name input} {
    if {[catch {dict size $input}]} { return "${name}()" }
    set keys [dict keys $input]
    if {[llength $keys] == 0} { return "${name}()" }
    set ordered [::questlog::match::_order_tool_keys $name $keys]
    set parts [list]
    foreach k $ordered {
        set v [dict get $input $k]
        set v [regsub -all {[\s]+} $v " "]
        lappend parts "${k}=${v}"
    }
    return "${name}([join $parts {, }])"
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

# btype_in_regions btype regions - 1 iff a block of this type is inside the
# region set. regions is a list of block types (user, assistant, tool_use,
# tool_result); the empty list is unrestricted - any block type, including the
# system/compaction blocks the four named regions exclude. Empty is the default,
# so an unqualified needle searches everywhere, as the old "anywhere" scope did.
proc ::questlog::match::btype_in_regions {btype regions} {
    return [expr {$regions eq "" || $btype in $regions}]
}

# A content condition is one leaf clause: a keyword or regex needle in an
# optional region set, or a structured tool/file condition. neg negates the
# leaf (a --not in front of it). These constructors are the one home for the
# leaf shape leaf_record_hit reads and the CLI and GUI builders write.
proc ::questlog::match::kw_leaf {needle regions neg} {
    return [dict create kind keyword needle $needle regions $regions neg $neg]
}
proc ::questlog::match::rx_leaf {needle regions neg} {
    return [dict create kind regex needle $needle regions $regions neg $neg]
}
proc ::questlog::match::tool_leaf {sel spec value neg} {
    return [dict create kind tool sel $sel spec $spec value $value neg $neg]
}

# Leaf clauses combine by a boolean tree: a leaf node names a leaf by id, and
# and/or nodes carry child nodes. The CLI builds OR-of-ANDs (its flag algebra:
# adjacency ANDs, --or splits); the GUI builds AND-of-ORs (search terms AND,
# each add-rail category ORs within itself). One evaluator serves both.
proc ::questlog::match::tnode_leaf {id}    { return [dict create t leaf id $id] }
proc ::questlog::match::tnode_and  {nodes} { return [dict create t and nodes $nodes] }
proc ::questlog::match::tnode_or   {nodes} { return [dict create t or nodes $nodes] }

# eval_tree node effsat - evaluate the boolean tree against effsat, a dict of
# leaf-id -> effective truth (the leaf's session satisfaction already XORed with
# its neg). An empty `and` is vacuously true; an empty `or` is false.
proc ::questlog::match::eval_tree {node effsat} {
    switch -- [dict get $node t] {
        leaf { return [dict get $effsat [dict get $node id]] }
        and {
            foreach c [dict get $node nodes] {
                if {![::questlog::match::eval_tree $c $effsat]} { return 0 }
            }
            return 1
        }
        or {
            foreach c [dict get $node nodes] {
                if {[::questlog::match::eval_tree $c $effsat]} { return 1 }
            }
            return 0
        }
    }
}

# leaf_record_hit leaf rec nocase - the evidence one parsed record gives for one
# leaf clause. Returns {sat hits}: sat is 1 iff the leaf matches somewhere in
# this record, and hits is the list of {btype content} snippets it would
# contribute. A keyword or regex leaf walks the record's content blocks filtered
# by its region set (empty = anywhere); a tool leaf walks the record's tool_uses
# - a file leaf by the op's tool set and a path tail, a tool leaf by name with
# an empty or substring key. nocase governs keyword matching only; a regex
# carries its own case (folding someone's pattern would be wrong).
proc ::questlog::match::leaf_record_hit {leaf rec nocase} {
    set hits [list]
    set sat 0
    switch -- [dict get $leaf kind] {
        keyword {
            set needle  [dict get $leaf needle]
            set regions [dict get $leaf regions]
            set n [expr {$nocase ? [string tolower $needle] : $needle}]
            foreach {btype content} [::questlog::jsonl::extract_blocks $rec] {
                if {![::questlog::match::btype_in_regions $btype $regions]} continue
                set hay [expr {$nocase ? [string tolower $content] : $content}]
                if {[string first $n $hay] >= 0} {
                    set sat 1
                    lappend hits [list $btype \
                        [::questlog::match::snippet_window_lit $content $needle $nocase]]
                }
            }
        }
        regex {
            set pat     [dict get $leaf needle]
            set regions [dict get $leaf regions]
            foreach {btype content} [::questlog::jsonl::extract_blocks $rec] {
                if {![::questlog::match::btype_in_regions $btype $regions]} continue
                if {[regexp -- $pat $content]} {
                    set sat 1
                    lappend hits [list $btype \
                        [::questlog::match::snippet_window $content $pat ""]]
                }
            }
        }
        tool {
            set sel  [dict get $leaf sel]
            set spec [dict get $leaf spec]
            set val  [dict get $leaf value]
            foreach t [::questlog::jsonl::record_tool_uses $rec] {
                if {$sel eq "file"} {
                    # The path is matched from the right, so a bare filename
                    # finds it in any directory; `file` rides only on the
                    # file-touching tools the op selects. The tail must sit on a
                    # name boundary - the whole path, or preceded by "/" or "." -
                    # so main.tcl never matches domain.tcl mid-word, while a
                    # dotted partial (spar-dispatcher-initcmd.tcl inside
                    # spar-manager.spar-dispatcher-initcmd.tcl) and a needle
                    # opening with "." (an extension search) still land.
                    if {[dict get $t name] ni [::questlog::match::op_toolset $spec]} continue
                    set tp [dict get $t path]
                    set off [expr {[string length $tp] - [string length $val]}]
                    if {$off >= 0 && [string range $tp $off end] eq $val
                        && ($off == 0 || [string index $tp $off-1] in {/ .}
                            || [string index $val 0] eq ".")} {
                        set sat 1
                        lappend hits [list tool_use \
                            [::questlog::match::clean_text [dict get $t rendered]]]
                        break
                    }
                } else {
                    # A use of the named tool whose invocation text contains the
                    # key (an empty key = any use of that tool).
                    if {[dict get $t name] ne $spec} continue
                    if {$val eq "" || [string first $val [dict get $t text]] >= 0} {
                        set sat 1
                        lappend hits [list tool_use \
                            [::questlog::match::clean_text [dict get $t rendered]]]
                        break
                    }
                }
            }
        }
    }
    return [dict create sat $sat hits $hits]
}

# Scan one session file against a built clauses dict. Pure except for reading
# $path. Returns {row matches}:
#   row     the publish_row dict (path/mtime/size/folder/uuid/first_ts/
#           nturns/first_user/bookmarked/cwd_hint), or "" if $path could not
#           be opened or the scan was cancelled.
#   matches list of matchcore dicts {path lineoff ts btype content folder} in
#           line order, non-empty only if the clause tree is satisfied for the
#           session. is_first is the caller's to derive (per session, across
#           files), so it is not set here.
#
# tick is an optional command prefix invoked every yield_lines lines with the
# current line number appended; if it returns truthy the scan aborts and returns
# {"" {}}. The threaded path passes no tick (the worker's cancellation is the
# epoch drop on arrival); the coroutine path passes a tick that yields and
# reports epoch change, so a re-typed search lands without finishing a big file.
proc ::questlog::match::scan_file {path clauses {tick ""} {yield_lines 0}} {
    set leaves [dict get $clauses leaves]
    set tree   [dict get $clauses tree]
    set nocase [dict get $clauses nocase]

    # Per-line pre-filter: a record is parsed only when its raw text could
    # satisfy at least one leaf. The raw line is JSON-encoded, so only a
    # needle the encoder never alters - printable ASCII minus `"` and `\` -
    # can be soundly tested against it. A needle outside that class (a quote,
    # a backslash, anything non-ASCII, which the writer may store as \uXXXX)
    # and any regex pattern (whose anchors and classes would see the encoded
    # text, not the content) instead make every line a candidate. Correctness
    # over the fast path: gating on an untestable leaf produced silent false
    # negatives, and a --not over one inverted them into false positives.
    # A keyword leaf contributes its needle; a tool leaf its path/key, or its
    # tool name when the key is empty (the name appears verbatim in the
    # tool_use JSON).
    set kw_needles  [list]   ;# raw-safe keyword needles, lowercased when nocase
    set lit_substrs [list]   ;# raw-safe tool path/key/name, matched raw
    set always_candidate 0   ;# 1 = a leaf exists that no raw gate can test
    set raw_safe {^[\x20-\x21\x23-\x5B\x5D-\x7E]+$}
    foreach leaf $leaves {
        switch -- [dict get $leaf kind] {
            keyword {
                set nd [dict get $leaf needle]
                if {[regexp $raw_safe $nd]} {
                    lappend kw_needles [expr {$nocase ? [string tolower $nd] : $nd}]
                } else {
                    set always_candidate 1
                }
            }
            regex { set always_candidate 1 }
            tool {
                set val [dict get $leaf value]
                if {[dict get $leaf sel] eq "file"} {
                    set lit $val
                } else {
                    set lit [expr {$val ne "" ? $val : [dict get $leaf spec]}]
                }
                if {[regexp $raw_safe $lit]} {
                    lappend lit_substrs $lit
                } else {
                    set always_candidate 1
                }
            }
        }
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
    set nleaves [llength $leaves]
    set leafsat [dict create]
    for {set lid 0} {$lid < $nleaves} {incr lid} { dict set leafsat $lid 0 }
    set buffer [list]
    set seen [dict create]
    if {[catch {open $path r} fh]} { return [list "" {}] }
    chan configure $fh -encoding utf-8 -profile replace
    while {[chan gets $fh line] >= 0} {
        incr lineno
        if {$line eq ""} continue
        if {$cwd_hint eq "" && [regexp {"cwd":"([^"]+)"} $line -> m]} { set cwd_hint $m }
        if {$first_ts eq "" && [regexp {"timestamp":"([^"]+)"} $line -> m]} { set first_ts $m }
        if {[::questlog::jsonl::is_user_turn $line]} {
            incr users
            # First-prompt preview: string content captured with escaped pairs
            # kept whole (clean_preview unescapes them); a block-array prompt
            # carries its words in its first text block instead.
            if {$users == 1} {
                if {![regexp {"content":"((?:[^"\\]|\\.)*)"} $line -> first_user]} {
                    regexp {"text":"((?:[^"\\]|\\.)*)"} $line -> first_user
                }
            }
        }
        set candidate $always_candidate
        if {!$candidate && [llength $kw_needles] > 0} {
            set hay [expr {$nocase ? [string tolower $line] : $line}]
            foreach n $kw_needles {
                if {[string first $n $hay] >= 0} { set candidate 1; break }
            }
        }
        if {!$candidate} {
            foreach s $lit_substrs {
                if {[string first $s $line] >= 0} { set candidate 1; break }
            }
        }
        if {$candidate && ![catch {::json::json2dict $line} rec]} {
            # Each leaf is session-satisfied once any record matches it in its
            # regions; buffer the snippets only of positively-used leaves, so a
            # negated leaf's incidental matches never pollute the result pane.
            for {set lid 0} {$lid < $nleaves} {incr lid} {
                set leaf [lindex $leaves $lid]
                set lr [::questlog::match::leaf_record_hit $leaf $rec $nocase]
                if {![dict get $lr sat]} continue
                dict set leafsat $lid 1
                if {[dict get $leaf neg]} continue
                foreach hit [dict get $lr hits] {
                    lassign $hit btype content
                    set key "$lineno $btype $content"
                    if {[dict exists $seen $key]} continue
                    dict set seen $key 1
                    lappend buffer [list $lineno $btype $content]
                }
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
        nturns $users \
        first_user [::questlog::match::clean_preview $first_user] \
        bookmarked [file executable $path] \
        has_subagents $has_sub \
        is_child $is_child \
        parent_path $parent_path \
        parent_uuid $parent_uuid \
        cwd_hint $cwd_hint]
    # The session qualifies when the boolean tree holds over the per-leaf
    # satisfaction, each leaf's raw sat XORed with its neg. A satisfied tree with
    # no buffered snippet (a purely negative query, no positive leaf to show)
    # yields no matches, the same as a filter with no positive evidence today.
    set effsat [dict create]
    for {set lid 0} {$lid < $nleaves} {incr lid} {
        dict set effsat $lid \
            [expr {[dict get $leafsat $lid] ^ [dict get [lindex $leaves $lid] neg]}]
    }
    set matches [list]
    if {[::questlog::match::eval_tree $tree $effsat] && [llength $buffer] > 0} {
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
