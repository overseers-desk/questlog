# logman - the record semantics of Claude Code session transcripts (JSONL):
# the one home for what a line of the stream means. Two faces on purpose:
# line-level regexes (is_user_turn, first_cwd) for consumers that never parse,
# parsed-dict twins (is_turn_start, ...) for consumers that hold a record.
# Record-at-a-time and streamable, except the turn reading (mark_turns and its
# parts), which needs the whole list.
package require Tcl 9
package require json

namespace eval ::logman {
    namespace export extract_text extract_blocks record_tool_uses \
        is_compact_boundary record_timestamp parse_iso fmt_gap first_cwd \
        is_user_turn is_hidden_record format_tool_use_full order_tool_keys \
        is_turn_start opens_turn mark_turn_runs count_turn_line note_line \
        kept_turns is_assistant_line is_request_log \
        record_parent mark_branches mark_turns branch_phrase \
        record_role_label record_model notice mark_commands \
        context_window transcript_step is_dialogue_prompt command_text dialogue_body
}

# Parse one JSONL line into a Tcl dict. Returns "" on parse failure. A
# queued_command attachment, a prompt the model received mid-turn, parses as
# the queued user record it stands for, so every reader draws it as one.
#
# isSidechain marks a subagent's records, which old parent files interleave
# with the parent's own and the turn and tree gates skip. A subagent's own
# file (<sid>/subagents/agent-<id>.jsonl) marks every record so, the
# subagent being that file's own context; a reader passing such a path gets
# its records unmarked, so they read as the file's own turns.
proc ::logman::parse_line {line {path ""}} {
    if {[catch {::json::json2dict $line} d]} { return "" }
    if {$path ne "" && [file tail [file dirname $path]] eq "subagents"} {
        dict unset d isSidechain
    }
    if {[dict getdef $d type ""] eq "attachment"
            && [dict getdef $d attachment type ""] eq "queued_command"} {
        set d [dict replace $d type user promptSource queued message \
            [dict create role user content [dict getdef $d attachment prompt ""]]]
    }
    return $d
}

# 1 iff this raw line is the request log Claude Code writes beside the
# transcript since 2.1.300 (api-request, api-request-blob, api-request-shape):
# each model request and the messages it sent, stamped a few milliseconds after
# the record it was sent for. It is no part of the conversation, and the raw
# reads that would find a prompt or a timestamp in it skip it.
proc ::logman::is_request_log {line} {
    return [string match "\{\"type\":\"api-request*" $line]
}

# 1 iff this raw line is a real user turn: a user record carrying a typed
# prompt, not a harness-written echo. The message holds "role":"user" with
# either a string "content" or a block array whose FIRST block is a prompt
# block (text or image, the forms a typed prompt with a pasted image takes) -
# a tool_result record is also role:user but its array opens with a
# tool_result block, so it stays excluded. The string content must not be one
# of the harness echoes the user never typed - a slash-command expansion, its
# captured stdout or caveat, a shell-out's captured output, or a background-task
# notification - and the record must carry neither the meta marker nor the
# interruption marker, both of which wear a prompt's shape. The one home
# for the turn predicate: the scanner counts nturns with it and the cost pass
# counts turns with it, so the min-turns floor and the displayed Turns count
# agree. A line-level regex, no parse: it runs over every line of every
# session file.
proc ::logman::is_user_turn {line} {
    # fast reject: this literal is the head of the regexp below, so a line
    # lacking it cannot match - a necessary condition, string-cheaper than regexp.
    if {[string first {"role":"user","content":} $line] < 0} { return 0 }
    # The request log embeds whole API messages, prompts among them; the
    # parsed twin never reads it as a record.
    if {[is_request_log $line]} { return 0 }
    # Harness records wearing a typed prompt's shape, rejected on the keys the
    # parsed twin reads so the two predicates agree on what the harness wrote.
    # isMeta covers the injections (hook feedback, skill bodies, /context
    # reports, session-name reminders) and is written both compact and spaced.
    # The last two are the interruption marker: interruptedMessageId marks most
    # of them, and the body literal catches the rest. Each regexp sits behind a
    # string-first gate, so a line without the key pays only the scan.
    if {[string first {"isMeta"} $line] >= 0
        && [regexp {"isMeta":\s*true} $line]}               { return 0 }
    if {[string first {"interruptedMessageId"} $line] >= 0} { return 0 }
    if {[string first {"type":"text","text":"[Request interrupted by user} \
            $line] >= 0}                                    { return 0 }
    return [expr {[regexp {"role":"user","content":(?:"|\[\{"type":"(?:text|image)")} $line] \
        && ![regexp {"content":"<(?:command-name|local-command-stdout|local-command-caveat|task-notification|bash-stdout|bash-stderr)>} $line]}]
}

# The speaker label a record shows in the reading view and the markdown
# export: USER / ASSISTANT / TOOL RESULT / SYSTEM. A type:user record whose
# content opens with a tool_result block is a tool result, not a typed prompt
# (the Anthropic API rides tool_result blocks in a user-role message), so it
# reads TOOL RESULT. The one home for the label, so the viewer and the export
# never disagree; the parsed-record twin of is_user_turn's tool_result
# carve-out. A notice Claude Code wrote (notice) reads SYSTEM.
proc ::logman::record_role_label {rec} {
    if {[llength [notice $rec]]} { return SYSTEM }
    switch -- [dict getdef $rec type ""] {
        user      { return [expr {[is_tool_result_record $rec] ? "TOOL RESULT" : "USER"}] }
        assistant { return [expr {[dict getdef $rec isApiErrorMessage 0] ? "SYSTEM" : "ASSISTANT"}] }
        default   { return "SYSTEM" }
    }
}

# A notice Claude Code wrote into the transcript, in its one-line form: {} when
# rec is none, else {line}, where an empty line leaves the whole record to its
# turn's detail. A record that opens a turn is the user's, never a notice. A
# command's output reads as the command with its output's first line, through
# the stamps mark_commands leaves on the pair.
proc ::logman::notice {rec} {
    if {[dict getdef $rec type ""] ni {user system} || [opens_turn $rec]} { return {} }
    if {[dict exists $rec _echo]} { return [list ""] }
    if {[dict exists $rec _command]} {
        regexp {<local-command-stdout>(.*?)(</local-command-stdout>|$)} \
            [extract_text $rec] -> out
        return [list "[dict get $rec _command] · [excerpt $out]"]
    }
    if {[dict exists $rec refusedMessageId]} { return [list "stopped by safeguards"] }
    set text [extract_text $rec]
    set n "[string length $text] chars"
    if {[dict getdef $rec isCompactSummary 0]} { return [list "compact summary · $n"] }
    if {[dict exists $rec scheduledTaskId]} { return [list "scheduled task · [excerpt $text]"] }
    if {[string match <task-notification>* $text]} {
        set line "task notification"
        regexp {<summary>(.*?)</summary>} $text -> line
        return [list "[expr {[string match *<status>completed</status>* $text] ? "✓" : "✗"}] [excerpt $line]"]
    }
    if {[regexp {<cross-session-message[^>]*from-name="([^"]*)"[^>]*>(.*)} $text -> who body]} {
        return [list "message from $who · [excerpt $body]"]
    }
    if {![dict getdef $rec isMeta 0]} { return {} }
    if {[string match <local-command-caveat>* $text]} { return [list ""] }
    if {[regexp {^([A-Za-z]+) hook feedback:} $text -> event]
            || ([string match <system-reminder>* $text]
                && [regexp {([A-Za-z]+) hook additional context} $text -> event])} {
        return [list "hook $event · $n"]
    }
    if {[string match <system-reminder>* $text]} { return [list "reminder · $n"] }
    if {[regexp {^Base directory for this skill: (\S+)} $text -> dir]} {
        return [list "skill [file tail $dir] · $n"]
    }
    return {}
}

# The first non-blank line of text, terminal colour codes stripped, cut to max
# characters.
proc ::logman::excerpt {text {max 100}} {
    regsub -all {\x1b\[[0-9;]*m} $text "" text
    foreach line [split $text \n] {
        set line [string trim $line]
        if {$line eq ""} continue
        if {[string length $line] > $max} {
            set line "[string range $line 0 [expr {$max - 2}]]…"
        }
        return $line
    }
    return ""
}

# Stamp each local command's echo _echo and the output record hanging from it
# _command, the command and its arguments, for notice to read as one line. A
# command echo with no output after it (a skill or prompt the user ran) keeps
# no stamp.
proc ::logman::mark_commands {recs} {
    set echoes [dict create]
    set i -1
    foreach rec $recs {
        incr i
        if {[dict getdef $rec type ""] ni {user system}} continue
        set text [extract_text $rec]
        if {[string match <command-* $text] && [set cmd [command_text $text]] ne ""} {
            dict set echoes [dict getdef $rec uuid ""] [list $i $cmd]
        } elseif {[string match <local-command-stdout>* $text]
                  && [dict exists $echoes [record_parent $rec]]} {
            lassign [dict get $echoes [record_parent $rec]] e cmd
            lset recs $e [dict replace [lindex $recs $e] _echo 1]
            lset recs $i [dict replace $rec _command $cmd]
        }
    }
    return $recs
}

# 1 iff a parsed record is a tool_result carrier: type:user with block-array
# content whose first block type is tool_result. The parsed-dict counterpart of
# the regex in is_user_turn; reuses is_string_content to tell an array from a
# plain string, the same discrimination extract_blocks makes.
proc ::logman::is_tool_result_record {rec} {
    if {[dict getdef $rec type ""] ne "user"} { return 0 }
    if {![dict exists $rec message]}          { return 0 }
    set msg [dict get $rec message]
    if {![dict exists $msg content]}          { return 0 }
    set c [dict get $msg content]
    if {[is_string_content $c]}               { return 0 }
    return [expr {[dict getdef [lindex $c 0] type ""] eq "tool_result"}]
}

# 1 iff a parsed record is hidden from the transcript reading: a compact
# summary, or display prose the harness marks isVisibleInTranscriptOnly.
proc ::logman::is_hidden_record {rec} {
    return [expr {[dict getdef $rec isCompactSummary 0] ||
                  [dict getdef $rec isVisibleInTranscriptOnly 0]}]
}

# 1 iff a parsed record starts a turn in the double-ESC-rollback sense: one
# genuine typed prompt and everything until the next one. The turn predicate
# for the viewer's turn model, the parsed-record twin of is_user_turn. It reads
# lower than is_user_turn on purpose. is_user_turn is a line regex the scanner
# and cost pass run over every line to count nturns and hold the min-turns
# floor, so it counts every role:user prompt shape - a queued or sdk prompt
# among them. This one folds the viewer's turns to what the rollback list shows,
# so a queued/sdk/system prompt injected into a running turn stays inside it and
# does not open one: the Turns tab can read a smaller count than the list row's
# Turns column, by design. When the harness stamps promptSource that field is
# the authority; origin is not consulted, because claude >=2.1.177 writes
# promptSource with no origin key on some genuine typed prompts. Absent
# promptSource (old jsonl) falls back to record shape.
proc ::logman::is_turn_start {rec} {
    if {[dict getdef $rec type ""] ne "user"} { return 0 }
    if {![dict exists $rec message]}          { return 0 }
    set msg [dict get $rec message]
    if {![dict exists $msg content]}          { return 0 }
    if {[dict exists $rec promptSource]} {
        set ps [dict get $rec promptSource]
        return [expr {$ps eq "typed" || $ps eq "suggestion_accepted"}]
    }
    # Old-format fallback: exclude the tool_result carrier and the meta/
    # summary/sidechain records before reading content shape.
    if {[is_tool_result_record $rec]}            { return 0 }
    if {[dict getdef $rec isMeta 0]}             { return 0 }
    if {[dict getdef $rec isCompactSummary 0]}   { return 0 }
    if {[dict getdef $rec isSidechain 0]}        { return 0 }
    if {[dict exists $rec interruptedMessageId]} { return 0 }
    set c [dict get $msg content]
    # The harness interruption marker. interruptedMessageId marks most of them
    # and is checked above, but the harness omits it on a stable minority right
    # across 2.1.x, and the marker then reaches here shaped like a typed prompt
    # (one text block). Its body is a fixed literal, so match that too.
    set head [expr {[is_string_content $c]
                    ? $c : [dict getdef [lindex $c 0] text ""]}]
    if {[string first {[Request interrupted by user} $head] == 0} { return 0 }
    if {[is_string_content $c]} {
        foreach pre {<command-name> <local-command-stdout> <local-command-caveat>
                     <task-notification> <bash-stdout> <bash-stderr>} {
            if {[string match "$pre*" $c]} { return 0 }
        }
        return 1
    }
    set bt [dict getdef [lindex $c 0] type ""]
    return [expr {$bt eq "text" || $bt eq "image"}]
}

# 1 iff this raw line is an assistant record. Run on every line of every
# session file, so it is written cheapest-first: one string scan rejects the
# lines that say nothing about an assistant, a second settles the compact
# serialisation every current writer emits, and the regexp is reached only by
# the spaced form, which two files in the corpus use.
proc ::logman::is_assistant_line {line} {
    if {[string first {assistant} $line] < 0} { return 0 }
    return [expr {[string first {"type":"assistant"} $line] >= 0
        || [regexp {"type":\s*"assistant"} $line]}]
}

# 1 iff this raw line counts as a turn, holding the run rule mark_turn_runs
# holds: a prompt counts only where an assistant record has been written since
# the last counted prompt, so the drafts of a message edited before the
# assistant answered count once between them. statevar names a variable the
# caller carries across one file's lines; this proc seeds and maintains it, and
# a fresh (unset) one starts a file.
#
# The counting twin of mark_turn_runs. The startup scan counts with it as it
# reads, for the min-turns floor, and kept_turns applies the same rule to the
# lines note_line noted, for the Turns column; the two are kept in step by
# test-branches. It counts the first draft of a run where the grouping shows
# the last, which no total can tell apart, and that way it needs no lookahead -
# this runs a line at a time over every line of every session file. It cannot
# tell a turn a rewind abandoned, which only the whole file shows, so the
# scan's count can run above the Turns column on a rewound session until the
# cost pass lands.
proc ::logman::count_turn_line {line statevar} {
    upvar 1 $statevar settled
    if {![info exists settled]} { set settled 1 }
    if {[is_assistant_line $line]} {
        set settled 1
        return 0
    }
    if {!$settled || ![is_user_turn $line]} { return 0 }
    set settled 0
    return 1
}

# Note one raw line of a file, in order, into statevar (a variable the caller
# carries across the file; a fresh one starts it): the line's place in the uuid
# tree and the two facts count_turn_line reads, an assistant record and a turn.
# Which turns a rewind abandoned only the whole file can tell, so the count waits
# for kept_turns at its end. tag rides with the line's turn into that count (a
# time window's in or out). The cost pass counts this way; the startup scan is
# spared the tree and keeps count_turn_line's running count.
proc ::logman::note_line {line statevar {tag 1}} {
    upvar 1 $statevar facts
    if {![info exists facts]} { set facts [list] }
    set a [is_assistant_line $line]
    set t [expr {!$a && [is_user_turn $line]}]
    lassign [line_tree $line] u p side
    if {$u ne "" || $a || $t} { lappend facts [list $u $p $a $t $side $tag] }
}

# A raw line's {uuid parent sidechain}, read off the serialization Claude Code
# writes instead of a parse: a record opens with its parentUuid (a compaction
# boundary's null one continued by logicalParentUuid), and its own uuid is the
# one followed by its timestamp, else (a system record) the first on the line.
# Every record of a corpus-wide check read so. A line of any other shape gives
# {"" "" 0} and stands outside the tree.
proc ::logman::line_tree {line} {
    if {[string range $line 0 13] ne "\{\"parentUuid\":"} { return {"" "" 0} }
    set p ""
    if {[string index $line 14] eq "\""} {
        set p [string range $line 15 [expr {[string first "\"" $line 15] - 1}]]
    } else {
        regexp {"logicalParentUuid":"([^"]+)"} $line -> p
    }
    set u ""
    set i 0
    while {[set j [string first {","timestamp":"} $line $i]] >= 0} {
        set k [string last {"uuid":"} $line $j]
        if {$k >= 0 && [string first "\"" $line [expr {$k + 8}]] == $j} {
            set u [string range $line [expr {$k + 8}] [expr {$j - 1}]]
            break
        }
        set i [expr {$j + 1}]
    }
    if {$u eq ""} {
        set k [string first {"uuid":"} $line]
        if {$k >= 0} {
            set u [string range $line [expr {$k + 8}] \
                [expr {[string first "\"" $line [expr {$k + 8}]] - 1}]]
        }
    }
    set side [expr {[string first {"isSidechain":true} [string range $line 0 200]] >= 0}]
    return [list $u $p $side]
}

# The tags of the turns the conversation kept, in file order: count_turn_line's
# rule applied to the lines note_line noted over a whole file (statevar), the
# turns of every branch a rewind abandoned left out.
proc ::logman::kept_turns {statevar} {
    upvar 1 $statevar facts
    if {![info exists facts]} { return {} }
    set skip [dict create]
    foreach run [rolled_back $facts] {
        lassign $run lo hi
        for {set k $lo} {$k <= $hi} {incr k} { dict set skip $k 1 }
    }
    set settled 1
    set tags {}
    set i -1
    foreach f $facts {
        incr i
        if {[dict exists $skip $i]} continue
        lassign $f - - a t - tag
        if {$a} {
            set settled 1
        } elseif {$t && $settled} {
            lappend tags $tag
            set settled 0
        }
    }
    return $tags
}

# 1 iff this record is the one a turn's header line is drawn for: a turn start
# carrying a body to draw. A bodiless record has no header line to open a turn
# at, so ungated it would close the running turn and orphan everything after it
# into always-visible preamble. The one home for the pair, so the grouping, the
# renderer and the streaming hold-back cannot drift apart on what a turn is.
proc ::logman::opens_turn {rec} {
    return [expr {[is_turn_start $rec] && [extract_text $rec] ne ""}]
}

# Group a record list into turns and stamp the grouping onto the records.
#
# A user who edits a message before the assistant answers leaves one record per
# draft, each a turn start in its own right. They are one turn: the message was
# not final until the last of them. So a maximal run of turn starts with no
# assistant record between them collapses, and the run's last member is the
# turn. Every earlier member gets _superseded 1 and renders nothing; the
# survivor gets _edits N, the count of drafts it replaced, absent at N = 0.
# A rolled-back branch's boundary (mark_branches' stamps) ends a run too: a
# prompt left unanswered at the end of a branch is not a draft of the prompt
# that replaced the branch.
#
# The turn test is opens_turn, the same gate the renderer draws a header on, so
# the grouping cannot disagree with what opens a region.
#
# Stamped rather than returned as a grouping, because a consumer walks the same
# flat list either way and the stamps ride through the existing per-record
# path. Whole list in, whole list out: the run's extent is knowable only at the
# record that ends it, so a streaming consumer holds back its trailing turn
# start until the next batch settles it (showman's append path does).
proc ::logman::mark_turn_runs {recs} {
    set runs {}
    set cur {}
    set i -1
    foreach rec $recs {
        incr i
        if {[dict getdef $rec type ""] eq "assistant"
                || [dict exists $rec _branch_open]} {
            if {[llength $cur] > 1} { lappend runs $cur }
            set cur {}
        }
        if {[opens_turn $rec]} { lappend cur $i }
        if {[dict exists $rec _branch_close]} {
            if {[llength $cur] > 1} { lappend runs $cur }
            set cur {}
        }
    }
    if {[llength $cur] > 1} { lappend runs $cur }
    foreach run $runs {
        foreach i [lrange $run 0 end-1] {
            lset recs $i [dict replace [lindex $recs $i] _superseded 1]
        }
        set last [lindex $run end]
        lset recs $last [dict replace [lindex $recs $last] \
            _edits [expr {[llength $run] - 1}]]
    }
    return $recs
}

# The record a record hangs from in the transcript's uuid tree, "" at a root.
# A compaction boundary has a null parentUuid and names the record it continues
# in logicalParentUuid; reading through it keeps the history before a /compact
# on one path with the history after.
proc ::logman::record_parent {rec} {
    set p [dict getdef $rec parentUuid ""]
    if {$p in {"" null}} { set p [dict getdef $rec logicalParentUuid ""] }
    if {$p eq "null"} { return "" }
    return $p
}

# Stamp the branches a rewind left behind.
#
# A rewind (Esc Esc in Claude Code) abandons the turns after the chosen point,
# and the model never sees them again. The file keeps them: the next record
# continues from the record before them, so they stand as a side branch of the
# uuid tree, written before the path that replaced them. The surviving path is
# the chain from the file's last record back to the root. A child of a record
# on it is a rolled-back branch when it is off the path and its subtree holds
# an assistant reply and a turn: without a reply it is an edit draft, which
# mark_turn_runs collapses, and without a turn a parallel tool result or a
# harness note. A branch may hold a rewind of its own, found by the same rule
# against the branch's own last record.
#
# A branch is one run of the list, from its head to the last record of its
# subtree; records inside the run that are not in the subtree (notes without a
# uuid, attachments the harness re-parented) travel with it. A run that holds
# a turn from outside its subtree is left unmarked, so a live prompt is never
# folded away; no session has shown one.
#
# Stamps: _branch_open, a dict holding the branch's depth (1 off the surviving
# path, 2 inside such a branch, and so on), on the run's first record;
# _branch_close N on its last record, N branches ending there; _branch_depth on
# every record of the run, the innermost run's depth. Sidechain records and
# records without a uuid stay out of the tree.
proc ::logman::mark_branches {recs} {
    set facts [list]
    foreach rec $recs {
        lappend facts [list [dict getdef $rec uuid ""] [record_parent $rec] \
            [expr {[dict getdef $rec type ""] eq "assistant"}] [opens_turn $rec] \
            [dict getdef $rec isSidechain 0]]
    }
    foreach run [rolled_back $facts] {
        lassign $run lo hi depth
        lset recs $lo [dict replace [lindex $recs $lo] \
            _branch_open [dict create depth $depth]]
        set r [lindex $recs $hi]
        dict incr r _branch_close
        lset recs $hi $r
        for {set k $lo} {$k <= $hi} {incr k} {
            lset recs $k [dict replace [lindex $recs $k] _branch_depth $depth]
        }
    }
    return $recs
}

# The rolled-back runs of a file described as facts, one per record in file
# order, {uuid parent assistant turn sidechain ...}: {lo hi depth} positions,
# outer runs before the runs inside them. The one home of the branch rule,
# which mark_branches feeds from parsed records and note_line from raw lines.
proc ::logman::rolled_back {facts} {
    set pos [dict create]
    set kids [dict create]
    set par [dict create]
    set leaf ""
    set i -1
    foreach f $facts {
        incr i
        lassign $f u p - - side
        if {$u eq "" || $side} continue
        dict set pos $u $i
        dict set par $u $p
        dict lappend kids $p $u
        set leaf $u
    }
    if {$leaf eq ""} { return {} }
    return [lsort -integer -index 0 [branch_runs $facts $pos $kids $par $leaf "" 1]]
}

# The rolled-back runs, as {lo hi depth} positions in facts, hanging off the
# path from leaf back to stop (a branch head, or "" for the root).
proc ::logman::branch_runs {facts pos kids par leaf stop depth} {
    set path [dict create]
    set u $leaf
    while {$u ne "" && ![dict exists $path $u]} {
        dict set path $u 1
        if {$u eq $stop || ![dict exists $par $u]} break
        set u [dict get $par $u]
    }
    set runs {}
    foreach u [dict keys $path] {
        foreach c [dict getdef $kids $u {}] {
            if {[dict exists $path $c]} continue
            set at [dict create]
            set reply 0
            set turn 0
            foreach s [subtree $kids $c] {
                set k [dict get $pos $s]
                dict set at $k 1
                lassign [lindex $facts $k] - - a t
                if {$a} { set reply 1 }
                if {$t} { set turn 1 }
            }
            if {!$reply || !$turn} continue
            set ks [lsort -integer [dict keys $at]]
            set lo [lindex $ks 0]
            set hi [lindex $ks end]
            set foreign 0
            for {set k $lo} {$k <= $hi} {incr k} {
                if {[dict exists $at $k]} continue
                lassign [lindex $facts $k] fu - - t side
                if {$t && !$side && $fu ne ""} {
                    set foreign 1
                    break
                }
            }
            if {$foreign} continue
            lappend runs [list $lo $hi $depth]
            lappend runs {*}[branch_runs $facts $pos $kids $par \
                [lindex [lindex $facts $hi] 0] $c [expr {$depth + 1}]]
        }
    }
    return $runs
}

# Every uuid under u in the tree, u first.
proc ::logman::subtree {kids u} {
    set out [list $u]
    set seen [dict create $u 1]
    for {set k 0} {$k < [llength $out]} {incr k} {
        foreach c [dict getdef $kids [lindex $out $k] {}] {
            if {[dict exists $seen $c]} continue
            dict set seen $c 1
            lappend out $c
        }
    }
    return $out
}

# The turn reading of a whole record list, as the session viewer and the
# markdown export draw it: each local command paired with its output
# (mark_commands), the rolled-back branches (mark_branches), then the drafts
# (mark_turn_runs), then each branch's facts for its header, filled into
# its _branch_open dict beside depth:
#   turns   its own turns as they render, a branch inside it counting apart
#   prompt  the first non-blank line of the first of those turns
#   t0 t1   its first and last timestamps
#   inner   the branches directly inside it
proc ::logman::mark_turns {recs} {
    set recs [mark_turn_runs [mark_branches [mark_commands $recs]]]
    set open {}
    set i -1
    foreach rec $recs {
        incr i
        if {[dict exists $rec _branch_open]} {
            if {[llength $open]} {
                set top [lindex $open end]
                dict incr top inner
                lset open end $top
            }
            set b [dict get $rec _branch_open]
            dict set b at $i
            lappend open [dict merge \
                [dict create turns 0 prompt "" t0 "" t1 "" inner 0] $b]
        }
        if {[llength $open]} {
            set ts [record_timestamp $rec]
            if {$ts ne ""} {
                for {set k 0} {$k < [llength $open]} {incr k} {
                    set b [lindex $open $k]
                    if {[dict get $b t0] eq ""} { dict set b t0 $ts }
                    dict set b t1 $ts
                    lset open $k $b
                }
            }
            set top [lindex $open end]
            if {[opens_turn $rec] && ![dict exists $rec _superseded]
                    && [dict get $rec _branch_depth] == [dict get $top depth]} {
                dict incr top turns
                if {[dict get $top prompt] eq ""} {
                    dict set top prompt [excerpt [extract_text $rec]]
                }
                lset open end $top
            }
        }
        for {set n [dict getdef $rec _branch_close 0]} {$n > 0} {incr n -1} {
            set b [lindex $open end]
            set open [lrange $open 0 end-1]
            set at [dict get $b at]
            lset recs $at [dict replace [lindex $recs $at] \
                _branch_open [dict remove $b at]]
        }
    }
    return $recs
}

# Extract the canonical text body of a record.
#   user/assistant: .message.content if string,
#                   else for each array element: .text if .type=="text",
#                   .content if .type=="tool_result" and .content is string.
#   system:         .content (catches "Conversation compacted")
#   anything else:  "" (queue-operation and last-prompt records among them: the
#                   prompt they echo has its own record)
proc ::logman::extract_text {rec} {
    set t [dict getdef $rec type ""]
    switch -- $t {
        user - assistant {
            if {![dict exists $rec message]} { return "" }
            set msg [dict get $rec message]
            if {![dict exists $msg content]} { return "" }
            set c [dict get $msg content]
            # Heuristic: a JSON array always parses to a list whose first
            # element is itself a dict-shaped value.
            if {[is_string_content $c]} { return $c }
            return [extract_array_text $c]
        }
        system  { return [dict getdef $rec content ""] }
        default { return "" }
    }
}

# .message.content as parsed by tcllib's json package: a JSON string is a
# Tcl string; a JSON array is a Tcl list of dict-shaped strings. Tell them
# apart by the test "the value, treated as a list, has at least one element
# that is a valid dict with a 'type' key".
proc ::logman::is_string_content {c} {
    if {$c eq ""} { return 1 }
    # If it is not a well-formed list, it is a string.
    if {[catch {llength $c} n]} { return 1 }
    if {$n == 0} { return 1 }
    # A list of content blocks: every element is a dict with key "type".
    foreach el $c {
        if {[catch {dict exists $el type} ok] || !$ok} { return 1 }
    }
    return 0
}

proc ::logman::extract_array_text {blocks} {
    set out [list]
    foreach blk $blocks {
        set bt [dict getdef $blk type ""]
        switch -- $bt {
            text {
                lappend out [dict getdef $blk text ""]
            }
            tool_result {
                # Route through tool_result_text so is_error and image inner
                # blocks are honoured in the reading body too.
                set bc [tool_result_text $blk]
                if {$bc ne ""} { lappend out $bc }
            }
            tool_use {
                set name  [dict getdef $blk name ""]
                set input [dict getdef $blk input [dict create]]
                lappend out [format_tool_use_full $name $input]
            }
            thinking {
                set tx [dict getdef $blk thinking ""]
                if {$tx ne ""} { lappend out "\[thinking\] $tx" }
            }
            redacted_thinking {
                lappend out "\[redacted thinking\]"
            }
            image {
                lappend out "\[image\]"
            }
        }
    }
    return [join $out "\n"]
}

# Walk a record's content blocks and emit one {btype content} pair per
# block worth showing. Pure function on a parsed record dict.
#
#   user (string content):                {user $string}
#   user (array of tool_result blocks):   {tool_result <text>}* (one per block)
#   user (array of text blocks):          {user <text>}*
#   assistant (array of text blocks):     {assistant <text>}*
#   assistant (array of tool_use blocks): {tool_use <NAME(args)>}*
#   system (.content):                    {system $content}
#   anything else (attachment, file-history-snapshot, etc.): empty list.
#
# tool_use blocks pass through format_tool_use_full, the uncapped renderer;
# the search snippet and the viewer body agree character-for-character.
# thinking/image blocks emit their own
# btypes so search regions can be extended to them later.
proc ::logman::extract_blocks {rec} {
    set out [list]
    set t [dict getdef $rec type ""]
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
                    set bt [dict getdef $blk type ""]
                    if {$bt eq "tool_result"} {
                        set bc [tool_result_text $blk]
                        if {$bc ne ""} { lappend out tool_result $bc }
                    } elseif {$bt eq "text"} {
                        lappend out user [dict getdef $blk text ""]
                    } elseif {$bt eq "image"} {
                        lappend out image "\[image\]"
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
                    set bt [dict getdef $blk type ""]
                    if {$bt eq "text"} {
                        lappend out assistant [dict getdef $blk text ""]
                    } elseif {$bt eq "tool_use"} {
                        set name  [dict getdef $blk name ""]
                        set input [dict getdef $blk input [dict create]]
                        lappend out tool_use [format_tool_use_full $name $input]
                    } elseif {$bt eq "thinking"} {
                        set tx [dict getdef $blk thinking ""]
                        if {$tx ne ""} { lappend out thinking $tx }
                    } elseif {$bt eq "redacted_thinking"} {
                        lappend out thinking "\[redacted thinking\]"
                    } elseif {$bt eq "image"} {
                        lappend out image "\[image\]"
                    }
                }
            }
        }
        system {
            set c [dict getdef $rec content ""]
            if {$c ne ""} { lappend out system $c }
        }
    }
    return $out
}

proc ::logman::tool_result_text {blk} {
    set is_err [dict getdef $blk is_error 0]
    if {![dict exists $blk content]} {
        return [expr {$is_err ? "ERROR:" : ""}]
    }
    set c [dict get $blk content]
    if {[is_string_content $c]} {
        if {$is_err} {
            return [expr {$c eq "" ? "ERROR:" : "ERROR: $c"}]
        }
        return $c
    }
    set parts [list]
    foreach inner $c {
        set it [dict getdef $inner type ""]
        switch -- $it {
            text            { lappend parts [dict getdef $inner text ""] }
            tool_reference  { lappend parts [dict getdef $inner tool_name ""] }
            image           { lappend parts "\[image\]" }
        }
    }
    set joined [join $parts " "]
    if {$is_err} {
        return [expr {$joined eq "" ? "ERROR:" : "ERROR: $joined"}]
    }
    return $joined
}

# --- dialogue view -----------------------------------------------------------
# The human<->AI conversation with the machinery removed: what the user typed
# and what the assistant said back, no tool calls, tool results, thinking, or
# harness bookkeeping. The one home for that selection, so the reading export
# and the query emitters share a single definition of what "dialogue" is rather
# than each re-deriving it.

# 1 iff rec is a prompt the human typed, kept in the dialogue view. A user
# record carrying real typed content: the tool_result carrier, the meta /
# summary / sidechain records and the interrupted marker are out, as in
# is_turn_start, but a queued prompt IS kept here (the dialogue wants every
# human line, not only the ones that open a rollback turn). A slash-command
# invocation the user ran is kept and dialogue_body unwraps it; only the harness
# echoes that are command OUTPUT, not input - its captured stdout, its caveat, a
# background-task notification - are dropped.
proc ::logman::is_dialogue_prompt {rec} {
    if {[dict getdef $rec type ""] ne "user"} { return 0 }
    if {![dict exists $rec message]}          { return 0 }
    set msg [dict get $rec message]
    if {![dict exists $msg content]}          { return 0 }
    if {[is_tool_result_record $rec]}            { return 0 }
    if {[dict getdef $rec isMeta 0]}             { return 0 }
    if {[is_hidden_record $rec]}                 { return 0 }
    if {[dict getdef $rec isSidechain 0]}        { return 0 }
    if {[dict exists $rec interruptedMessageId]} { return 0 }
    set c [dict get $msg content]
    if {[is_string_content $c]} {
        foreach pre {<local-command-stdout> <local-command-caveat> <task-notification>} {
            if {[string match "$pre*" $c]} { return 0 }
        }
        return 1
    }
    set bt [dict getdef [lindex $c 0] type ""]
    return [expr {$bt eq "text" || $bt eq "image"}]
}

# The clean text a slash-command invocation stands for: the command name and its
# arguments, with the <command-message>/<command-name>/<command-args> wrapper the
# harness writes stripped off. The command-name carries the leading slash
# (/compact, /magazines:otter-ai); the short <command-message> label is a
# fallback for a record that somehow lacks the name. "" when the content holds no
# command tags, so a plain prompt falls through untouched.
proc ::logman::command_text {content} {
    if {![regexp {<command-name>(.*?)</command-name>} $content -> name]} {
        if {![regexp {<command-message>(.*?)</command-message>} $content -> name]} {
            return ""
        }
    }
    set args ""
    regexp {<command-args>(.*?)</command-args>} $content -> args
    return [string trim "[string trim $name] [string trim $args]"]
}

# The dialogue body of a record, or "" to drop it from the human<->AI view:
#   a human prompt -> the typed text, a slash command unwrapped to its "/name
#                     args" form (command_text)
#   an assistant   -> its spoken text blocks joined; thinking, tool_use and any
#                     sidechain (subagent) reply are dropped
#   anything else  -> "" (tool results, system notes, last-prompt snapshots,
#                     other attachments, meta and summary records)
# The label a consumer pairs with this body is record_role_label's, the same
# USER / ASSISTANT the full reading view uses.
#
# roles narrows the view to one side of it: a list drawn from {user assistant},
# where the empty list keeps both. One side alone is the reading a study of the
# human's part wants, where the assistant's prose outweighs the prompts by an
# order of magnitude and is read back selectively, by the record numbers the
# kept turns carry.
proc ::logman::dialogue_body {rec {roles {}}} {
    if {[dict getdef $rec type ""] eq "assistant"} {
        if {[llength $roles] && "assistant" ni $roles} { return "" }
        if {[dict getdef $rec isSidechain 0]} { return "" }
        set parts [list]
        foreach {btype content} [extract_blocks $rec] {
            if {$btype eq "assistant"} { lappend parts $content }
        }
        return [join $parts "\n"]
    }
    if {[llength $roles] && "user" ni $roles} { return "" }
    if {![is_dialogue_prompt $rec]} { return "" }
    set c [dict get [dict get $rec message] content]
    if {[is_string_content $c]} {
        set cmd [command_text $c]
        return [expr {$cmd ne "" ? $cmd : $c}]
    }
    set parts [list]
    foreach {btype content} [extract_blocks $rec] {
        if {$btype eq "user" || $btype eq "image"} { lappend parts $content }
    }
    return [join $parts "\n"]
}

# Walk an assistant record's tool_use blocks. Returns one dict per block:
#   {name <tool>  path <file_path|notebook_path|"">  rendered <NAME(args)>
#    text <uncapped argument values, whitespace-collapsed>}
# Path is the file the built-in tool acted on, read off the parsed input
# rather than the rendered string, so it carries the full untruncated path
# and the NotebookEdit notebook_path; the `file` criterion matches it by
# suffix. `text` is the uncapped join of the input values, which the `tool`
# criterion matches a key against by substring - so a key past tool_render_cap
# is still found, and a path inside a Bash redirect (`gen.py > out.json`) is
# caught. `rendered` is the format_tool_use_full display form. Empty for
# non-assistant records.
proc ::logman::record_tool_uses {rec} {
    set out [list]
    if {[dict getdef $rec type ""] ne "assistant"} { return $out }
    if {![dict exists $rec message]} { return $out }
    set msg [dict get $rec message]
    if {![dict exists $msg content]} { return $out }
    set c [dict get $msg content]
    if {[is_string_content $c]} { return $out }
    foreach blk $c {
        if {[dict getdef $blk type ""] ne "tool_use"} continue
        set name  [dict getdef $blk name ""]
        set input [dict getdef $blk input [dict create]]
        set path ""
        set vals [list]
        if {![catch {dict size $input}]} {
            if {[dict exists $input file_path]} {
                set path [dict get $input file_path]
            } elseif {[dict exists $input notebook_path]} {
                set path [dict get $input notebook_path]
            }
            # Uncapped searchable text: the values only (not the keys, which
            # would match every use of a tool). Tcl's value duck-typing renders
            # a nested object as a string, same as format_tool_use treats it.
            foreach k [dict keys $input] {
                lappend vals [regsub -all {[\s]+} [dict get $input $k] " "]
            }
        }
        lappend out [dict create name $name path $path \
                         rendered [format_tool_use_full $name $input] \
                         text [string trim [join $vals " "]]]
    }
    return $out
}

# The uncapped NAME(key=value, ...) rendering of a tool_use block, whitespace-
# collapsed: the one renderer every surface shares. A capped display variant
# belongs to the consumer, ordering keys through order_tool_keys.
proc ::logman::format_tool_use_full {name input} {
    if {[catch {dict size $input}]} { return "${name}()" }
    set keys [dict keys $input]
    if {[llength $keys] == 0} { return "${name}()" }
    set ordered [order_tool_keys $name $keys]
    set parts [list]
    foreach k $ordered {
        set v [dict get $input $k]
        set v [regsub -all {[\s]+} $v " "]
        lappend parts "${k}=${v}"
    }
    return "${name}([join $parts {, }])"
}

# Key display order: the identifying argument first, the rest in stream order.
proc ::logman::order_tool_keys {name keys} {
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

# 1 iff this is a compaction boundary: type=system AND subtype=compact_boundary.
proc ::logman::is_compact_boundary {rec} {
    if {[dict getdef $rec type ""] ne "system"} { return 0 }
    if {[dict getdef $rec subtype ""] ne "compact_boundary"} { return 0 }
    return 1
}

# ISO timestamp string from a record (.timestamp). Empty if absent.
proc ::logman::record_timestamp {rec} {
    return [dict getdef $rec timestamp ""]
}

# The model id an assistant record was produced by, or "" when there is none to
# chip. Only an assistant record carries a model; a sidechain (subagent) record
# and a harness-written <synthetic> filler are excluded, mirroring the cost
# pass's last_model guard, so neither ever chips in the viewer.
proc ::logman::record_model {rec} {
    if {[dict getdef $rec type ""] ne "assistant"} { return "" }
    if {[dict getdef $rec isSidechain 0]}          { return "" }
    if {![dict exists $rec message]}               { return "" }
    set m [dict getdef [dict get $rec message] model ""]
    if {$m eq "" || $m eq "<synthetic>"}           { return "" }
    return $m
}

# Epoch seconds from a Claude ISO timestamp, 0 on an empty or unparseable
# stamp. The session viewer's section dividers and the markdown export both
# segment on the same clock, so this is their one parser.
# Claude stamps millisecond precision (2026-05-24T22:29:21.279Z); clock scan
# has no fractional-second specifier, so the fraction is dropped before the Z
# and the second-resolution remainder is parsed as UTC.
proc ::logman::parse_iso {ts_iso} {
    if {$ts_iso eq ""} { return 0 }
    regsub {\.[0-9]+Z$} $ts_iso {Z} ts_iso
    if {[catch {clock scan $ts_iso -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1} e]} {
        return 0
    }
    return $e
}

# A silence span in minutes rendered for an idle-gap divider ("12 min",
# "2 hr 5 min", "3 day(s)"). Shared by the viewer's divider and the markdown
# export so a gap reads identically in both.
proc ::logman::fmt_gap {minutes} {
    if {$minutes < 60} { return "${minutes} min" }
    if {$minutes < 60*24} {
        set h [expr {$minutes / 60}]
        set m [expr {$minutes % 60}]
        if {$m == 0} { return "${h} hr" }
        return "${h} hr $m min"
    }
    set d [expr {$minutes / (60*24)}]
    return "${d} day(s)"
}

# A rolled-back branch's header phrase from its _branch_open facts (mark_turns):
# 3 turns · 13:08–13:20 · 1 rollback inside · "do it…". The session viewer's
# ROLLED BACK line and the markdown export's summary both draw it, so they read
# alike. Times are local; a span that crosses midnight dates both ends.
proc ::logman::branch_phrase {b} {
    set n [dict get $b turns]
    set parts [list "$n turn[expr {$n == 1 ? "" : "s"}]"]
    set e0 [parse_iso [dict get $b t0]]
    set e1 [parse_iso [dict get $b t1]]
    if {$e0 > 0 && $e1 > 0} {
        set f [expr {[clock format $e0 -format %Y-%m-%d] eq [clock format $e1 -format %Y-%m-%d]
            ? "%H:%M" : "%d %b %H:%M"}]
        set s0 [clock format $e0 -format $f]
        set s1 [clock format $e1 -format $f]
        lappend parts [expr {$s0 eq $s1 ? $s0 : "$s0–$s1"}]
    }
    set k [dict get $b inner]
    if {$k} { lappend parts "$k rollback[expr {$k == 1 ? "" : "s"}] inside" }
    set p [excerpt [dict get $b prompt] 48]
    if {$p ne ""} { lappend parts "\"$p\"" }
    return [join $parts " · "]
}

# The one home for the per-record transcript cues. The session viewer
# (::questlog::ui::Viewer render_record) and the markdown export
# (::questlog::markdown::export_session) both walk a session jsonl a record at a
# time and both draw the same three cues off it - a compaction boundary, an
# empty-body clock advance, and an idle gap between content records. This proc
# is the single classifier both fold over (issue #31), so a change to when a
# divider fires lands on both surfaces at once.
#
# Given a parsed record, `last_ts` (the epoch of the most recent CONTENT record,
# 0 when none has been seen yet), and the idle-gap threshold in minutes, return
# {events new_last_ts}. `events` is an ordered list of typed items, emitted in
# the order a consumer must render them:
#   {compact}       the record is a compaction boundary. Sole event; the clock
#                   resets (new_last_ts is 0) so the first content record after a
#                   compaction never reads as an idle gap from before it.
#   {gap <minutes>} an idle gap fired: `last_ts` and this record are both stamped
#                   and the silence between them reached the threshold. Emitted
#                   BEFORE the body so a consumer draws the divider above the
#                   turn. A gap fires only between content records - a first
#                   record (last_ts 0) or an unstamped record on either side
#                   never gaps.
#   {body <text>}   the record's extract_text body, non-empty. The turn itself.
# A record with an empty extract_text body emits NO events but still advances the
# clock when it carries a timestamp (new_last_ts becomes its epoch), so a gap is
# measured from the last real message either side of the quiet metadata records.
#
# The step owns only classification and the clock. It never formats: the
# consumers own every label, divider glyph and heading - the viewer's centred
# "─── /compact ───" / "─── N later ───" and its section headers, the export's
# "## --- /compact ---" / "## --- N later ---" - and each formats a gap through
# fmt_gap itself from the raw minute count this step hands back. Consumer-only
# concerns stay upstream too: the viewer tracks an in_section flag before ever
# reaching here, and this step is agnostic to it.
proc ::logman::transcript_step {rec last_ts idle_gap} {
    set events [list]
    set ts_epoch [parse_iso [record_timestamp $rec]]

    # Compaction boundary: the primary cue. It is tested before the body so a
    # boundary whose own content is empty still resets the clock rather than
    # slipping through the empty-body path.
    if {[is_compact_boundary $rec]} {
        return [list [list [list compact]] 0]
    }

    # A record extract_text draws no text from (a file-history snapshot, an
    # attachment, a permission-mode note) is not a turn: no event, but its stamp
    # still moves the clock so an idle gap spans it.
    set body [extract_text $rec]
    if {$body eq ""} {
        if {$ts_epoch > 0} { set last_ts $ts_epoch }
        return [list $events $last_ts]
    }

    # Idle gap, between content records only. Integer minutes, floored, exactly
    # as both consumers compute it.
    if {$last_ts > 0 && $ts_epoch > 0} {
        set gap [expr {($ts_epoch - $last_ts) / 60}]
        if {$gap >= $idle_gap} {
            lappend events [list gap $gap]
        }
    }
    lappend events [list body $body]
    if {$ts_epoch > 0} { set last_ts $ts_epoch }
    return [list $events $last_ts]
}

# Last non-empty assistant text body in a session jsonl. Empty string if
# the file holds no parseable assistant record with renderable content. A
# final turn consisting solely of tool_use blocks now returns the rendered
# Tool(args) line(s), since extract_array_text emits those too.
proc ::logman::last_assistant_text {path} {
    set last ""
    if {[catch {open $path r} fh]} { return "" }
    chan configure $fh -encoding utf-8 -profile replace
    while {[chan gets $fh line] >= 0} {
        if {$line eq ""} continue
        set rec [parse_line $line $path]
        if {$rec eq ""} continue
        if {[dict getdef $rec type ""] ne "assistant"} continue
        set body [extract_text $rec]
        if {$body ne ""} { set last $body }
    }
    close $fh
    return $last
}

# First "cwd" value recorded in a session jsonl. Empty string if the
# file cannot be opened or holds no record with a cwd. A line-level
# regex, not a full parse: cwd appears on most record types and the
# first hit is enough.
proc ::logman::first_cwd {path} {
    if {[catch {open $path r} fh]} { return "" }
    chan configure $fh -encoding utf-8 -profile replace
    set cwd ""
    while {[chan gets $fh line] >= 0} {
        if {$line eq ""} continue
        if {[regexp {"cwd":"([^"]+)"} $line -> m]} {
            set cwd $m
            break
        }
    }
    close $fh
    return $cwd
}

# One {line role text match} turn dict for a raw line, or "" when the line is
# blank, unparseable, or renders to an empty body. An empty body is a record
# extract_text draws no text from (a file-history snapshot, an empty-content
# record), which the reading-view export skips too, so it is not a context
# "message". match is 0 for a neighbour; the hit's own record is built inline in
# context_window with match 1. path is the file the line came from, for
# parse_line.
proc ::logman::turn_at {line lineno match {dialogue 0} {roles {}} {path ""}} {
    set rec [parse_line $line $path]
    if {$rec eq ""} { return "" }
    set body [expr {$dialogue ? [dialogue_body $rec $roles] : [extract_text $rec]}]
    if {$body eq ""} { return "" }
    return [dict create line $lineno role [record_role_label $rec] \
        text $body match $match]
}

# The reading-view turns immediately around a search hit, for grep-style context
# (-A/-B/-C). Returns an ordered list of {line role text match} dicts, earliest
# first: up to `before` renderable records above `hitline`, the hit's own record
# (match 1, shown in full), then up to `after` renderable records below it.
# Blank, unparseable and empty-body records are counted in the physical line
# number but not toward the before/after tallies, so "3 before" is three visible
# messages, not three raw lines. `hitline` is the physical line (blanks counted)
# that scan_file numbered, so it addresses the same record. Built from the same
# parse_line/record_role_label/extract_text primitives as the whole-session
# export, so a windowed turn reads as it does in `questlog show`. Empty list if
# the file cannot be opened. With dialogue true each turn's body comes from
# dialogue_body instead, so a non-dialogue neighbour (a tool result, a system
# note) drops from the window and a kept turn carries only its prose - the
# machinery is stripped inside the turn, not just whole tool turns removed.
# roles rides on to dialogue_body: one side of the conversation alone, or both
# for the empty list. The hit's own record is the window's centre and is emitted
# whatever roles says, so a window never comes back headless.
proc ::logman::context_window {path hitline before after {dialogue 0} {roles {}}} {
    if {[catch {open $path r} fh]} { return [list] }
    chan configure $fh -encoding utf-8 -profile replace
    set lineno 0
    set pre [list]
    set anchor ""
    set post [list]
    while {[chan gets $fh line] >= 0} {
        incr lineno
        if {$lineno < $hitline} {
            if {$before <= 0} continue
            set turn [turn_at $line $lineno 0 $dialogue $roles $path]
            if {$turn eq ""} continue
            lappend pre $turn
            if {[llength $pre] > $before} { set pre [lrange $pre 1 end] }
        } elseif {$lineno == $hitline} {
            # The hit's own record is always emitted, in full, even if its body
            # is unusual - it is the centre of the window. (In practice it has a
            # body: it carried the matched block.)
            set rec [parse_line $line $path]
            if {$rec ne ""} {
                set body [expr {$dialogue ? [dialogue_body $rec] : [extract_text $rec]}]
                set anchor [dict create line $lineno \
                    role [record_role_label $rec] text $body match 1]
            }
            if {$after <= 0} break
        } else {
            set turn [turn_at $line $lineno 0 $dialogue $roles $path]
            if {$turn eq ""} continue
            lappend post $turn
            if {[llength $post] >= $after} break
        }
    }
    close $fh
    set out [list]
    lappend out {*}$pre
    if {$anchor ne ""} { lappend out $anchor }
    lappend out {*}$post
    return $out
}
