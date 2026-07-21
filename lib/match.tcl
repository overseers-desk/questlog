package require Tcl 9
package require json
package require must
package require logman

# ::questlog::match - the pure record-matching and snippet-formatting logic of
# search, shared verbatim by the main interpreter and the search worker threads.
#
# A worker is a separate interp with no reach into the parent's procs, so both
# sides source this one file: one copy, no drift. The record semantics come
# from the logman module, resolved identically on both sides. Nothing here
# touches Tk, TclOO or Thread; scan_file reads a file and json-parses lines,
# the rest is string work on already-parsed records.
#
# The five display caps the matchers honour live in ::questlog::config, which a
# worker cannot read, so they are injected once through set_caps - from config
# in the main interp, from prelude literals in a worker - and read back through
# cap. ::questlog::config stays the authored home; Caps is a derived snapshot.

namespace eval ::questlog::match {
    variable Caps [dict create]
    namespace export clean_text snippet_window format_tool_use \
        clean_preview scan_file leaf_record_hit \
        leaf_name_hit eval_tree btype_in_regions
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

# Session origin from a single opening-record line: an sdk-cli spawn (a skill or
# Agent-SDK run) opens with a queue-operation record, anything else is an
# interactive cli session. The one home for the queue-operation marker, shared by
# scan_file's forward pass (which already holds the first line) and Scan's
# session_kind (which reads just the head of a file). Returns cli|sdk. Lives here
# so a search worker, which sources match.tcl but not scan.tcl, can classify too.
proc ::questlog::match::opener_kind {line} {
    return [expr {[regexp {"type":"queue-operation"} $line] ? "sdk" : "cli"}]
}

# Read from the channel's current position to EOF and return the LAST agentName
# and aiTitle seen, as {agent_name ai_title}; "" for either that never appears.
# The single home for the slug field regexes and their last-wins rule, used by
# scan_file's browse tail read and its full-file fallback.
proc ::questlog::match::last_titles {fh} {
    set agent_name ""
    set ai_title ""
    while {[chan gets $fh line] >= 0} {
        if {$line eq ""} continue
        if {[regexp {"agentName":"([^"]+)"} $line -> m]} { set agent_name $m }
        if {[regexp {"aiTitle":"([^"]+)"} $line -> m]} { set ai_title $m }
    }
    return [list $agent_name $ai_title]
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

# Render a tool_use block as "Name(key=value, ...)", capped for the timeline:
# logman::format_tool_use_full's capped twin, differing only in truncation.
proc ::questlog::match::format_tool_use {name input} {
    if {[catch {dict size $input}]} { return "${name}()" }
    set keys [dict keys $input]
    if {[llength $keys] == 0} { return "${name}()" }
    set ordered [::logman::order_tool_keys $name $keys]
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
# so an unqualified needle searches everywhere.
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
# contribute. A keyword or regex leaf walks the record's content blocks narrowed
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
            foreach {btype content} [::logman::extract_blocks $rec] {
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
            foreach {btype content} [::logman::extract_blocks $rec] {
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
            foreach t [::logman::record_tool_uses $rec] {
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

# leaf_name_hit leaf names nocase - the evidence a session's name history gives
# for one leaf clause. names is a dict of worn-name -> the line it first appeared
# on. Only a keyword or regex leaf whose region set carries `names` looks here;
# every other leaf returns no evidence, so scan_file can score each leaf against
# the names blindly. Returns {sat hits}: sat is 1 iff the needle matches a name
# the session has worn, and hits is the {lineno names content} snippets it would
# contribute, windowed on the match the way a body hit is so the result can
# re-find and embolden it. A name match is per-session, not per-record - the whole
# title history is one haystack - so it is scored once, at end of file, and folded
# into the same per-leaf satisfaction the body walk builds. nocase governs keyword
# matching only; a regex carries its own case, exactly as leaf_record_hit does.
proc ::questlog::match::leaf_name_hit {leaf names nocase} {
    set kind [dict get $leaf kind]
    if {$kind ni {keyword regex}}          { return [dict create sat 0 hits {}] }
    if {"names" ni [dict get $leaf regions]} { return [dict create sat 0 hits {}] }
    set hits [list]
    set sat 0
    set needle [dict get $leaf needle]
    if {$kind eq "keyword"} {
        set n [expr {$nocase ? [string tolower $needle] : $needle}]
        dict for {name lineno} $names {
            set hay [expr {$nocase ? [string tolower $name] : $name}]
            if {[string first $n $hay] >= 0} {
                set sat 1
                lappend hits [list $lineno names \
                    [::questlog::match::snippet_window_lit $name $needle $nocase]]
            }
        }
    } else {
        dict for {name lineno} $names {
            if {[regexp -- $needle $name]} {
                set sat 1
                lappend hits [list $lineno names \
                    [::questlog::match::snippet_window $name $needle ""]]
            }
        }
    }
    return [dict create sat $sat hits $hits]
}

# The one session-row extractor (issue #30), reading a file once for both the
# browse and the search pass. Returns {row matches}:
#   row     the unified row dict - path mtime size folder uuid first_ts nturns
#           kind first_user slug ai_title has_subagents bookmarked cwd_hint
#           is_child parent_path parent_uuid - or "" if $path could not be opened
#           or the scan was cancelled. is_first is the caller's to derive (per
#           session, across files), so it is not set here.
#   matches list of matchcore dicts {path lineoff ts btype content folder
#           is_child parent_path parent_uuid agent_id} in line order, non-empty
#           only when the clause tree is satisfied.
#
# One extractor, one row shape: the browse and search passes cannot drift because
# they build the same dict at the same join. The read strategy branches on
# whether there are clauses to match:
#   - Search (leaves present): a row pass reads the whole file, collecting the
#     name history (the current title falls out of the last agentName/aiTitle
#     it sees) and, under the file-level pre-gate, which gate literals the file
#     holds. The parse pass covers the candidate lines: combined with the row
#     pass when the gate cannot exclude, as a seek-0 re-read inside the same
#     call for a file the gate keeps, and not at all in a file it rules out -
#     which is most of a big corpus when a rare literal sits under AND. The
#     caller still gets a complete row from the one call either way.
#   - Browse (no leaves): stop the forward pass once the row's early fields are in
#     hand (turn_count_cap turns, cwd, first_ts) and read the title from a tail
#     window (whole-file fallback), so a large transcript is not read end to end
#     just to list it. This is the path Scan.scan_one delegates to.
# turn_count_cap and tail_window_bytes ride in on the clauses dict, built in the
# main interp where config is reachable, so a search worker - which cannot read
# config - caps nturns identically. An absent cap (a hand-built empty clauses)
# means no cap and no early break.
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
    set matching [expr {[llength $leaves] > 0}]
    set cap [dict getdef $clauses turn_count_cap 0]

    # Per-line pre-gate (search only): a record is parsed only when its raw text
    # could satisfy at least one leaf. The raw line is JSON-encoded, so only a
    # needle the encoder never alters - printable ASCII minus `"` and `\` -
    # can be soundly tested against it. A needle outside that class (a quote,
    # a backslash, anything non-ASCII, which the writer may store as \uXXXX)
    # makes every line a candidate. A regex leaf is gated by its required
    # literal factor (must::factor); a pattern yielding none, or a factor
    # outside the raw-safe class, also makes every line a candidate, and a
    # (?i) factor is tested against the lowered line whatever the global
    # case mode, since a regex carries its own case.
    # Correctness over the fast path: gating on an untestable leaf produced
    # silent false negatives, and a --not over one inverted them into false
    # positives - which is why a negated leaf's literal still joins the gate.
    # A keyword leaf contributes its needle; a tool leaf its path/key, or its
    # tool name when the key is empty (the name appears verbatim in the
    # tool_use JSON).
    # The same literals drive the file-level pre-gate: each file must satisfy
    # the whole tree by itself (the caller drops a matchless file when clauses
    # are active), so a positive leaf whose literal appears on no raw line of
    # the file cannot be satisfied here, and when that already fails the tree
    # the parse pass is skipped for the file wholesale. leafgate maps each
    # leaf to its {literal fold} pair in glits, -1 when it has none; a negated
    # leaf stays possible whatever the file shows, since absence of its
    # literal argues for it, not against.
    set kw_needles  [list]   ;# raw-safe keyword needles, lowercased when nocase
    set lit_substrs [list]   ;# raw-safe tool path/key/name and case-exact
                             ;# regex factors, matched raw
    set fold_lits   [list]   ;# (?i) regex factors, matched on the lowered line
    set always_candidate 0   ;# 1 = a leaf exists that no raw gate can test
    set leafgate [list]      ;# per leaf: its glits index, -1 = untestable
    set glits [list]         ;# distinct {literal fold} pairs the file gate seeks
    set gidx [dict create]
    set raw_safe {^[\x20-\x21\x23-\x5B\x5D-\x7E]+$}
    if {$matching} {
        foreach leaf $leaves {
            set glit ""
            set gfold 0
            switch -- [dict get $leaf kind] {
                keyword {
                    set nd [dict get $leaf needle]
                    if {[regexp $raw_safe $nd]} {
                        set glit [expr {$nocase ? [string tolower $nd] : $nd}]
                        set gfold $nocase
                        lappend kw_needles $glit
                    } else {
                        set always_candidate 1
                    }
                }
                regex {
                    # must's contract leaves the haystack's representation to
                    # the caller: the factor is sought in the JSON-encoded
                    # raw line, so only one the encoder writes verbatim can
                    # gate here.
                    lassign [::must::factor [dict get $leaf needle]] fac ffold
                    if {$fac ne "" && ![regexp $raw_safe $fac]} { set fac "" }
                    if {$fac eq ""} {
                        set always_candidate 1
                    } else {
                        set glit $fac
                        set gfold $ffold
                        if {$ffold} {
                            lappend fold_lits $fac
                        } else {
                            lappend lit_substrs $fac
                        }
                    }
                }
                tool {
                    set val [dict get $leaf value]
                    if {[dict get $leaf sel] eq "file"} {
                        set lit $val
                    } else {
                        set lit [expr {$val ne "" ? $val : [dict get $leaf spec]}]
                    }
                    if {[regexp $raw_safe $lit]} {
                        set glit $lit
                        lappend lit_substrs $lit
                    } else {
                        set always_candidate 1
                    }
                }
            }
            if {$glit eq ""} {
                lappend leafgate -1
            } else {
                set pair [list $glit $gfold]
                if {![dict exists $gidx $pair]} {
                    dict set gidx $pair [llength $glits]
                    lappend glits $pair
                }
                lappend leafgate [dict get $gidx $pair]
            }
        }
    }
    # The gate can only exclude when some positive leaf is testable.
    set gate_on 0
    for {set lid 0} {$lid < [llength $leaves]} {incr lid} {
        if {[lindex $leafgate $lid] >= 0
                && ![dict get [lindex $leaves $lid] neg]} {
            set gate_on 1
            break
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
    set kind ""
    set agent_name ""
    set ai_title ""
    set lineno 0
    set nleaves [llength $leaves]
    set leafsat [dict create]
    for {set lid 0} {$lid < $nleaves} {incr lid} { dict set leafsat $lid 0 }
    set buffer [list]
    set seen [dict create]
    set names [dict create]
    if {[catch {open $path r} fh]} { return [list "" {}] }
    chan configure $fh -encoding utf-8 -profile replace
    # The row work and the leaf work share one loop body, driven by do_row /
    # do_leaves. One combined pass is the norm; under the file gate the row
    # pass runs first alone, noting which gate literals the file holds, and
    # the parse pass runs (a seek-0 second read) only when the tree is still
    # satisfiable - so a hopeless file is read once, with no json2dict at all.
    set do_row 1
    set do_leaves [expr {$matching && !$gate_on}]
    set gfound [lrepeat [llength $glits] 0]
    set gremain [llength $glits]
    while 1 {
        while {[chan gets $fh line] >= 0} {
            incr lineno
            if {$line eq ""} continue
            # Origin from the opening record, via the shared opener_kind rule.
            if {$do_row && $kind eq ""} { set kind [::questlog::match::opener_kind $line] }
            if {$do_row && $cwd_hint eq ""
                    && [regexp {"cwd":"([^"]+)"} $line -> m]} { set cwd_hint $m }
            if {$do_row && $first_ts eq ""
                    && [regexp {"timestamp":"([^"]+)"} $line -> m]} { set first_ts $m }
            if {$do_row && $gate_on && $gremain > 0} {
                set lhay ""
                for {set gi 0} {$gi < [llength $glits]} {incr gi} {
                    if {[lindex $gfound $gi]} continue
                    lassign [lindex $glits $gi] glit gfold
                    if {$gfold} {
                        if {$lhay eq ""} { set lhay [string tolower $line] }
                        set ghit [expr {[string first $glit $lhay] >= 0}]
                    } else {
                        set ghit [expr {[string first $glit $line] >= 0}]
                    }
                    if {$ghit} {
                        lset gfound $gi 1
                        incr gremain -1
                    }
                }
            }
            if {$do_row && $matching} {
                # The session's worn names accumulate across the whole file (a rename
                # appends, so the set is only complete at EOF), each kept with the line
                # it first appeared on so a `names` hit can anchor; the LAST agentName
                # and aiTitle are the session's current title (slug > ai_title). The
                # string-first gate keeps the regex off the lines with no title field;
                # customTitle is skipped - it feeds Claude Code's own picker, not the
                # name the list shows.
                if {[string first {"agentName":"} $line] >= 0
                        && [regexp {"agentName":"([^"]+)"} $line -> m]} {
                    set agent_name $m
                    if {![dict exists $names $m]} { dict set names $m $lineno }
                }
                if {[string first {"aiTitle":"} $line] >= 0
                        && [regexp {"aiTitle":"([^"]+)"} $line -> m]} {
                    set ai_title $m
                    if {![dict exists $names $m]} { dict set names $m $lineno }
                }
            }
            if {$do_row && [::logman::is_user_turn $line]} {
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
            if {!$matching} {
                # Browse: the early break scan_one relied on - once turn_count_cap
                # turns, the cwd and the first timestamp are known, the tail read
                # below supplies the title, so the middle of a big file is skipped.
                if {$cap > 0 && $users >= $cap && $cwd_hint ne "" && $first_ts ne ""} break
                continue
            }
            if {$do_leaves} {
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
                if {!$candidate && [llength $fold_lits] > 0} {
                    set fhay [string tolower $line]
                    foreach s $fold_lits {
                        if {[string first $s $fhay] >= 0} { set candidate 1; break }
                    }
                }
                if {$candidate && ![catch {::json::json2dict $line} rec]} {
                    # Each leaf is session-satisfied once any record matches it in
                    # its regions; buffer the snippets only of positively-used
                    # leaves, so a negated leaf's incidental matches never pollute
                    # the result pane.
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
            }
            if {$tick ne "" && $yield_lines > 0 && $lineno % $yield_lines == 0} {
                if {[{*}$tick $lineno]} { close $fh; return [list "" {}] }
            }
        }
        if {!$gate_on || $do_leaves} break
        # End of the gated row pass: a positive leaf whose literal the file never
        # showed cannot be satisfied; when that already fails the tree, the parse
        # pass has nothing to find and the loop ends with the row alone. The tail
        # below then evaluates the tree over untouched leafsat and yields no
        # matches - the same {row {}} a scanned-and-unsatisfied file returns.
        set possible [dict create]
        for {set lid 0} {$lid < $nleaves} {incr lid} {
            set gi [lindex $leafgate $lid]
            dict set possible $lid [expr {$gi < 0
                || [dict get [lindex $leaves $lid] neg] || [lindex $gfound $gi]}]
        }
        if {![::questlog::match::eval_tree $tree $possible]} break
        chan seek $fh 0
        set lineno 0
        set do_row 0
        set do_leaves 1
    }
    # Title: the search pass has the current agentName/aiTitle from its whole-file
    # forward sweep; the browse pass early-broke, so it reads them from a tail
    # window (with a whole-file fallback when the latest title sits further back
    # than tail_window_bytes or before the forward break). Slug priority is
    # agentName over aiTitle, unchanged.
    if {!$matching} {
        if {[catch {file size $path} fsz]} { set fsz 0 }
        set tail_start [expr {$fsz - [dict getdef $clauses tail_window_bytes 0]}]
        set pos [chan tell $fh]
        if {$tail_start > $pos} {
            chan seek $fh $tail_start
            chan gets $fh _
        }
        lassign [::questlog::match::last_titles $fh] agent_name ai_title
        if {$agent_name eq "" && $ai_title eq ""} {
            chan seek $fh 0
            lassign [::questlog::match::last_titles $fh] agent_name ai_title
        }
    }
    close $fh
    if {[catch {file mtime $path} mt]} { set mt 0 }
    if {[catch {file size  $path} sz]} { set sz 0 }
    # Does this session have subagents? A cheap directory probe drives the list's
    # chevron on a session whose subagents did not themselves match (case A), and
    # keeps a republish from clearing the flag.
    set has_sub 0
    if {!$is_child} {
        set sa_uuid [file rootname [file tail $path]]
        set sa_dir [file join [file dirname $path] $sa_uuid subagents]
        set has_sub [expr {[file isdirectory $sa_dir]
            && [llength [glob -nocomplain -directory $sa_dir -- agent-*.jsonl]] > 0}]
    }
    set slug [expr {$agent_name ne "" ? $agent_name : $ai_title}]
    set row [dict create \
        path $path \
        mtime $mt \
        size $sz \
        folder $folder \
        uuid [file rootname [file tail $path]] \
        first_ts $first_ts \
        nturns [expr {$cap > 0 ? min($users, $cap) : $users}] \
        kind [expr {$kind eq "" ? "cli" : $kind}] \
        first_user [::questlog::match::clean_preview $first_user] \
        slug $slug \
        ai_title $ai_title \
        has_subagents $has_sub \
        bookmarked [file executable $path] \
        is_child $is_child \
        parent_path $parent_path \
        parent_uuid $parent_uuid \
        cwd_hint $cwd_hint]
    # Browse: no clauses, so no match walk - the row is the whole answer.
    if {!$matching} { return [list $row {}] }
    # The name history is a per-session haystack: a leaf whose regions include
    # `names` is satisfied when the needle matches any name the session has worn,
    # scored once now that every worn name is collected. Its positive hits buffer
    # beside the body hits so the result shows which name matched; a negated leaf
    # marks satisfaction without buffering, the same carve-out the body walk makes.
    for {set lid 0} {$lid < $nleaves} {incr lid} {
        set leaf [lindex $leaves $lid]
        set nr [::questlog::match::leaf_name_hit $leaf $names $nocase]
        if {![dict get $nr sat]} continue
        dict set leafsat $lid 1
        if {[dict get $leaf neg]} continue
        foreach hit [dict get $nr hits] {
            lassign $hit hlineno hbtype hcontent
            set key "$hlineno $hbtype $hcontent"
            if {[dict exists $seen $key]} continue
            dict set seen $key 1
            lappend buffer [list $hlineno $hbtype $hcontent]
        }
    }
    # Body hits buffer in line order; a name hit anchors on an early title line, so
    # order the buffer by physical line before it becomes the match list. lsort is
    # stable, so equal-line body hits keep their block order.
    set buffer [lsort -integer -index 0 $buffer]

    # The session qualifies when the boolean tree holds over the per-leaf
    # satisfaction, each leaf's raw sat XORed with its neg. A satisfied tree with
    # no buffered snippet (a purely negative query, no positive leaf to show)
    # yields no matches, the same as a clause with no positive evidence today.
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
