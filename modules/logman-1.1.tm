# logman - the record semantics of Claude Code session transcripts (JSONL):
# the one home for what a line of the stream means. Two faces on purpose:
# line-level regexes (is_user_turn, first_cwd) for consumers that never parse,
# parsed-dict twins (is_turn_start, ...) for consumers that hold a record.
# Record-at-a-time with no whole-file state: streamable.
package require Tcl 9
package require json

namespace eval ::logman {
    namespace export extract_text extract_blocks record_tool_uses \
        is_compact_boundary record_timestamp parse_iso fmt_gap first_cwd \
        is_user_turn is_hidden_record format_tool_use_full order_tool_keys \
        is_turn_start record_role_label record_model context_window transcript_step \
        is_dialogue_prompt command_text dialogue_body
}

# Parse one JSONL line into a Tcl dict. Returns "" on parse failure.
proc ::logman::parse_line {line} {
    if {[catch {::json::json2dict $line} d]} { return "" }
    return $d
}

# 1 iff this raw line is a real user turn: a user record carrying a typed
# prompt, not a harness-written echo. The message holds "role":"user" with
# either a string "content" or a block array whose FIRST block is a prompt
# block (text or image, the forms a typed prompt with a pasted image takes) -
# a tool_result record is also role:user but its array opens with a
# tool_result block, so it stays excluded. The string content must not be one
# of the harness echoes the user never typed - a slash-command expansion, its
# captured stdout or caveat, or a background-task notification. The one home
# for the turn predicate: the scanner counts nturns with it and the cost pass
# counts turns with it, so the min-turns floor and the displayed Turns count
# agree. A line-level regex, no parse: it runs over every line of every
# session file.
proc ::logman::is_user_turn {line} {
    return [expr {[regexp {"role":"user","content":(?:"|\[\{"type":"(?:text|image)")} $line] \
        && ![regexp {"content":"<(?:command-name|local-command-stdout|local-command-caveat|task-notification)>} $line]}]
}

# The speaker label a record shows in the reading view and the markdown
# export: USER / ASSISTANT / TOOL RESULT / SYSTEM. A type:user record whose
# content opens with a tool_result block is a tool result, not a typed prompt
# (the Anthropic API rides tool_result blocks in a user-role message), so it
# reads TOOL RESULT. The one home for the label, so the viewer and the export
# never disagree; the parsed-record twin of is_user_turn's tool_result
# carve-out.
# ponytail: the other harness echoes is_user_turn also excludes (<command-name>,
# <local-command-stdout>, caveats, <task-notification>) still read USER; add one
# string-prefix branch here if that is ever wanted - one fix serves both surfaces.
proc ::logman::record_role_label {rec} {
    switch -- [dict getdef $rec type ""] {
        user      { return [expr {[is_tool_result_record $rec] ? "TOOL RESULT" : "USER"}] }
        assistant { return "ASSISTANT" }
        default   { return "SYSTEM" }
    }
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
    # Old-format fallback: exclude the tool_result carrier, meta/summary/
    # sidechain records, and the harness "[Request interrupted by user]" record
    # (which carries interruptedMessageId), before reading content shape.
    if {[is_tool_result_record $rec]}            { return 0 }
    if {[dict getdef $rec isMeta 0]}             { return 0 }
    if {[dict getdef $rec isCompactSummary 0]}   { return 0 }
    if {[dict getdef $rec isSidechain 0]}        { return 0 }
    if {[dict exists $rec interruptedMessageId]} { return 0 }
    set c [dict get $msg content]
    if {[is_string_content $c]} {
        foreach pre {<command-name> <local-command-stdout> <local-command-caveat> <task-notification>} {
            if {[string match "$pre*" $c]} { return 0 }
        }
        return 1
    }
    set bt [dict getdef [lindex $c 0] type ""]
    return [expr {$bt eq "text" || $bt eq "image"}]
}

# Extract the canonical text body of a record.
#   user/assistant: .message.content if string,
#                   else for each array element: .text if .type=="text",
#                   .content if .type=="tool_result" and .content is string.
#   queue-operation: .content
#   last-prompt:    .lastPrompt
#   system:         .content (catches "Conversation compacted")
#   anything else:  ""
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
        queue-operation - system {
            return [dict getdef $rec content ""]
        }
        last-prompt {
            return [dict getdef $rec lastPrompt ""]
        }
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
#   system / queue-operation (.content):  {system $content}
#   last-prompt:                          {user $lastPrompt}
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
        system - queue-operation {
            set c [dict getdef $rec content ""]
            if {$c ne ""} { lappend out system $c }
        }
        last-prompt {
            set c [dict getdef $rec lastPrompt ""]
            if {$c ne ""} { lappend out user $c }
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
# harness bookkeeping. The one home for that selection, so the reading export,
# the query emitters and the replay consumer share a single definition of what
# "dialogue" is rather than each re-deriving it.

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
#                     attachments, meta and summary records)
# The label a consumer pairs with this body is record_role_label's, the same
# USER / ASSISTANT the full reading view uses.
proc ::logman::dialogue_body {rec} {
    if {[dict getdef $rec type ""] eq "assistant"} {
        if {[dict getdef $rec isSidechain 0]} { return "" }
        set parts [list]
        foreach {btype content} [extract_blocks $rec] {
            if {$btype eq "assistant"} { lappend parts $content }
        }
        return [join $parts "\n"]
    }
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
# concerns stay upstream too: the viewer drops last-prompt records (the
# markdown export instead renders them as SYSTEM turns) and tracks an
# in_section flag before ever reaching here; this step is agnostic to both.
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
        set rec [parse_line $line]
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
# context_window with match 1.
proc ::logman::turn_at {line lineno match} {
    set rec [parse_line $line]
    if {$rec eq ""} { return "" }
    set body [extract_text $rec]
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
# the file cannot be opened.
proc ::logman::context_window {path hitline before after} {
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
            set turn [turn_at $line $lineno 0]
            if {$turn eq ""} continue
            lappend pre $turn
            if {[llength $pre] > $before} { set pre [lrange $pre 1 end] }
        } elseif {$lineno == $hitline} {
            # The hit's own record is always emitted, in full, even if its body
            # is unusual - it is the centre of the window. (In practice it has a
            # body: it carried the matched block.)
            set rec [parse_line $line]
            if {$rec ne ""} {
                set anchor [dict create line $lineno \
                    role [record_role_label $rec] text [extract_text $rec] match 1]
            }
            if {$after <= 0} break
        } else {
            set turn [turn_at $line $lineno 0]
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
