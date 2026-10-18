#!/usr/bin/env tclsh9.0
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
set ::questlog_config_only 1; source [file join $ROOT questlog]
package require logman
# extract_blocks routes tool_use blocks through ::questlog::match; source it and
# inject the caps the launcher does, so the redacted_thinking assertion below
# exercises the same extract_blocks the app runs.
source [file join $ROOT lib match.tcl]
::questlog::match::set_caps [dict create \
    content_cap     [::questlog::config::get content_cap] \
    snippet_lead    [::questlog::config::get snippet_lead] \
    snippet_trail   [::questlog::config::get snippet_trail] \
    tool_param_cap  [::questlog::config::get tool_param_cap] \
    tool_render_cap [::questlog::config::get tool_render_cap]]

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name"
        puts "  expected: <$expected>"
        puts "  actual:   <$actual>"
        incr ::fails
    } else {
        puts "ok:   $name"
    }
}

# is_turn_start takes a PARSED record; feed it literal JSON through parse_line.
proc ts {json} {
    return [::logman::is_turn_start [::logman::parse_line $json]]
}

# ---- is_turn_start: the viewer's turn predicate ----------------------------
# When the harness stamps promptSource, that field is the authority: typed and
# suggestion_accepted open a turn; queued (a prompt injected into a running
# turn), sdk and system harness injections do not. origin is never consulted -
# typed with or without an origin key both open a turn.
check turn_ps_typed_with_origin 1 [ts \
    {{"type":"user","promptSource":"typed","origin":"cli","message":{"role":"user","content":"do the thing"}}}]
check turn_ps_typed_no_origin 1 [ts \
    {{"type":"user","promptSource":"typed","message":{"role":"user","content":"do the thing"}}}]
check turn_ps_suggestion 1 [ts \
    {{"type":"user","promptSource":"suggestion_accepted","message":{"role":"user","content":"accepted"}}}]
check turn_ps_queued 0 [ts \
    {{"type":"user","promptSource":"queued","message":{"role":"user","content":"queued mid-turn"}}}]
check turn_ps_sdk 0 [ts \
    {{"type":"user","promptSource":"sdk","message":{"role":"user","content":"sdk injection"}}}]
check turn_ps_system 0 [ts \
    {{"type":"user","promptSource":"system","message":{"role":"user","content":"system injection"}}}]

# Old-format jsonl with no promptSource: fall back to record shape. A plain
# typed prompt (string or text/image-first block array) opens a turn.
check turn_absent_string 1 [ts \
    {{"type":"user","message":{"role":"user","content":"just typed this"}}}]
check turn_absent_array_text 1 [ts \
    {{"type":"user","message":{"role":"user","content":[{"type":"text","text":"see this"},{"type":"image","source":{}}]}}}]
check turn_absent_array_image 1 [ts \
    {{"type":"user","message":{"role":"user","content":[{"type":"image","source":{}},{"type":"text","text":"caption"}]}}}]

# A tool_result carrier (also role:user), the meta/summary/sidechain flags, and
# the harness interrupt record never open a turn.
check turn_absent_tool_result 0 [ts \
    {{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"ok"}]}}}]
check turn_absent_ismeta 0 [ts \
    {{"type":"user","isMeta":true,"message":{"role":"user","content":"meta note"}}}]
check turn_absent_compact_summary 0 [ts \
    {{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"summary"}}}]
check turn_absent_sidechain 0 [ts \
    {{"type":"user","isSidechain":true,"message":{"role":"user","content":"sidechain prompt"}}}]
check turn_absent_interrupt 0 [ts \
    {{"type":"user","interruptedMessageId":"m1","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}}]

# The harness omits interruptedMessageId on a stable minority of interruption
# notices right across 2.1.x, and the notice then arrives shaped exactly like a
# typed prompt: one text block, no promptSource, no meta marker. Both wordings
# of the literal are rejected on the body alone.
check turn_interrupt_no_key 0 [ts \
    {{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}}]
check turn_interrupt_no_key_tool_use 0 [ts \
    {{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}}]
# A prompt that merely mentions the notice is still a prompt: the literal has
# to open the body.
check turn_interrupt_quoted_mid_body 1 [ts \
    {{"type":"user","message":{"role":"user","content":"why does it say [Request interrupted by user] here?"}}}]

# The harness echoes the user never typed: string content leading with any
# of these opens no turn.
check turn_echo_command 0 [ts \
    {{"type":"user","message":{"role":"user","content":"<command-name>/foo</command-name>"}}}]
check turn_echo_stdout 0 [ts \
    {{"type":"user","message":{"role":"user","content":"<local-command-stdout>ran</local-command-stdout>"}}}]
check turn_echo_caveat 0 [ts \
    {{"type":"user","message":{"role":"user","content":"<local-command-caveat>caveat</local-command-caveat>"}}}]
check turn_echo_task_note 0 [ts \
    {{"type":"user","message":{"role":"user","content":"<task-notification>done</task-notification>"}}}]
# A shell-out's captured output, the analogue of <local-command-stdout>. The
# command line itself (<bash-input>) is left alone: the user did type it.
check turn_echo_bash_stdout 0 [ts \
    {{"type":"user","message":{"role":"user","content":"<bash-stdout>ok</bash-stdout><bash-stderr></bash-stderr>"}}}]
check turn_echo_bash_stderr 0 [ts \
    {{"type":"user","message":{"role":"user","content":"<bash-stderr>boom</bash-stderr>"}}}]

# Non-user types are never turn starts; nor is a user record with no message.
check turn_assistant 0 [ts \
    {{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}}]
check turn_system 0 [ts \
    {{"type":"system","content":"Conversation compacted"}}]
check turn_last_prompt 0 [ts \
    {{"type":"last-prompt","lastPrompt":"resume?"}}]
check turn_user_no_message 0 [ts {{"type":"user"}}]

# ---- mark_turn_runs: drafts of one message are one turn --------------------
# A message edited before the assistant replied leaves one record per draft.
# The run collapses to its last member; the earlier drafts are stamped
# _superseded and the survivor carries the count it replaced.
proc mk {args} {
    set out {}
    foreach j $args { lappend out [::logman::parse_line $j] }
    return $out
}
proc P {text} {
    return "{\"type\":\"user\",\"promptSource\":\"typed\",\"message\":{\"role\":\"user\",\"content\":\"$text\"}}"
}
set A {{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"reply"}]}}}
# Stamps of a marked list, one word per record: "-" plain, "s" superseded,
# "eN" the survivor of a run of N drafts.
proc stamps {recs} {
    set out {}
    foreach r $recs {
        if {[dict exists $r _superseded]} { lappend out s
        } elseif {[dict exists $r _edits]} { lappend out e[dict get $r _edits]
        } else { lappend out - }
    }
    return $out
}

check run_single_prompt {- -} \
    [stamps [::logman::mark_turn_runs [mk [P "one"] $A]]]
check run_two_drafts {s e1 -} \
    [stamps [::logman::mark_turn_runs [mk [P "draf"] [P "draft"] $A]]]
check run_four_drafts {s s s e3 -} \
    [stamps [::logman::mark_turn_runs [mk [P a] [P b] [P c] [P d] $A]]]
# An assistant record between two prompts ends the run: the message was
# answered, so it was final. Two turns, no edits.
check run_answered_between {- - - -} \
    [stamps [::logman::mark_turn_runs [mk [P "one"] $A [P "two"] $A]]]
# A run open at end of list still collapses - nothing after it can reopen it.
check run_open_at_end {- s e1} \
    [stamps [::logman::mark_turn_runs [mk $A [P "draf"] [P "draft"]]]]
# The interruption marker is not a draft: it opens no turn, so it neither
# collapses nor adds to the count. Here the two real prompts still pair.
check run_interrupt_not_a_draft {- s - e1 -} \
    [stamps [::logman::mark_turn_runs [mk $A [P "draf"] \
        {{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}} \
        [P "draft"] $A]]]
# A bodiless turn start renders no header, so the renderer opens no region for
# it; the grouping applies the same gate and leaves it out of the run.
check run_empty_body_not_a_draft {- - -} \
    [stamps [::logman::mark_turn_runs [mk $A [P ""] [P "real"]]]]
# Records that are neither prompts nor assistant replies sit inside the run
# without breaking it: the harness writes them while the user is still typing.
check run_chrome_does_not_break {s - e1 -} \
    [stamps [::logman::mark_turn_runs [mk [P "draf"] \
        {{"type":"system","content":"<local-command-stdout>renamed</local-command-stdout>"}} \
        [P "draft"] $A]]]

# ---- extract_blocks: redacted_thinking arm ---------------------------------
# A redacted_thinking block now emits a thinking pair with the placeholder,
# parity with extract_array_text; the block was silently dropped before.
check blocks_assistant_redacted_thinking {thinking {[redacted thinking]}} \
    [::logman::extract_blocks [::logman::parse_line \
        {{"type":"assistant","message":{"content":[{"type":"redacted_thinking"}]}}}]]

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
