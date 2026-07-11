#!/usr/bin/env tclsh9.0
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT config.tcl]
source [file join $ROOT lib jsonl.tcl]
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
    return [::questlog::jsonl::is_turn_start [::questlog::jsonl::parse_line $json]]
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

# The four harness echoes the user never typed: string content leading with any
# of these opens no turn.
check turn_echo_command 0 [ts \
    {{"type":"user","message":{"role":"user","content":"<command-name>/foo</command-name>"}}}]
check turn_echo_stdout 0 [ts \
    {{"type":"user","message":{"role":"user","content":"<local-command-stdout>ran</local-command-stdout>"}}}]
check turn_echo_caveat 0 [ts \
    {{"type":"user","message":{"role":"user","content":"<local-command-caveat>caveat</local-command-caveat>"}}}]
check turn_echo_task_note 0 [ts \
    {{"type":"user","message":{"role":"user","content":"<task-notification>done</task-notification>"}}}]

# Non-user types are never turn starts; nor is a user record with no message.
check turn_assistant 0 [ts \
    {{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}}]
check turn_system 0 [ts \
    {{"type":"system","content":"Conversation compacted"}}]
check turn_last_prompt 0 [ts \
    {{"type":"last-prompt","lastPrompt":"resume?"}}]
check turn_user_no_message 0 [ts {{"type":"user"}}]

# ---- extract_blocks: redacted_thinking arm ---------------------------------
# A redacted_thinking block now emits a thinking pair with the placeholder,
# parity with extract_array_text; the block was silently dropped before.
check blocks_assistant_redacted_thinking {thinking {[redacted thinking]}} \
    [::questlog::jsonl::extract_blocks [::questlog::jsonl::parse_line \
        {{"type":"assistant","message":{"content":[{"type":"redacted_thinking"}]}}}]]

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
