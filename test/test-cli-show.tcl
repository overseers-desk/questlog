#!/usr/bin/env tclsh9.0
# Unit tests for the `questlog show` headless transcript: the emitter's record-
# number anchors (off for the GUI, on for the CLI) and the show subcommand's
# path-or-uuid resolution. The emitter (::questlog::markdown::export_session) is
# the same one the GUI copy/export-markdown actions use, so these also guard that
# shared renderer. Headless, no Tk. Run:
#   tclsh9.0 test/test-cli-show.tcl
package require Tcl 9

set ROOT [file dirname [file dirname [file normalize [info script]]]]
set ::questlog_config_only 1; source [file join $ROOT questlog]
source [file join $ROOT lib path.tcl]
package require logman
source [file join $ROOT lib match.tcl]
source [file join $ROOT lib markdown.tcl]
source [file join $ROOT cli main.tcl]
# format_tool_use_full reads no caps, but inject them the way the launcher does
# so the test exercises the same configured matcher the app runs with.
::questlog::match::set_caps [dict create \
    content_cap     [::questlog::config::get content_cap] \
    snippet_lead    [::questlog::config::get snippet_lead] \
    snippet_trail   [::questlog::config::get snippet_trail] \
    tool_param_cap  [::questlog::config::get tool_param_cap] \
    tool_render_cap [::questlog::config::get tool_render_cap]]

set failures 0
proc check {name got want} {
    if {$got eq $want} {
        puts "ok   - $name"
    } else {
        puts "FAIL - $name"
        puts "       got:  $got"
        puts "       want: $want"
        incr ::failures
    }
}

proc write_file {path text} {
    set fh [open $path w]
    chan configure $fh -encoding utf-8
    puts -nonewline $fh $text
    close $fh
}

# ---- the transcript and its anchors ---------------------------------------

# Four physical lines: two text turns, a compaction boundary, one text turn.
# No timestamps, so no idle-gap divider fires; the only divider is the compact
# boundary, on line 3, which carries no record number.
set fixture [join {
    {{"type":"user","message":{"content":"hello"}}}
    {{"type":"assistant","message":{"content":[{"type":"text","text":"hi there"}]}}}
    {{"type":"system","subtype":"compact_boundary"}}
    {{"type":"assistant","message":{"content":[{"type":"text","text":"after compact"}]}}}
} "\n"]
set f [file join /tmp questlog-show-[pid].jsonl]
write_file $f $fixture

set plain [join {
    "**USER**\n\nhello"
    "**ASSISTANT**\n\nhi there"
    "## --- /compact ---"
    "**ASSISTANT**\n\nafter compact"
} "\n\n"]
check "export_session: anchors off is the clean transcript" \
    [::questlog::markdown::export_session $f 0] $plain
check "export_session: default is anchors off" \
    [::questlog::markdown::export_session $f] $plain

set anchored [join {
    "**\[#1] USER**\n\nhello"
    "**\[#2] ASSISTANT**\n\nhi there"
    "## --- /compact ---"
    "**\[#4] ASSISTANT**\n\nafter compact"
} "\n\n"]
check "export_session: anchors on prefix turns with their record number" \
    [::questlog::markdown::export_session $f 1] $anchored

# Tool activity folds inline (the viewer's behaviour); the rendered call names
# its tool, so a show consumer sees it rather than a silent drop.
set toolfix [file join /tmp questlog-show-tool-[pid].jsonl]
write_file $toolfix \
    {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}}
check "export_session: a tool_use turn folds the call inline" \
    [string match {*Bash*} [::questlog::markdown::export_session $toolfix]] 1

# Drafts of a message edited before the assistant answered are one turn in the
# viewer, so this mirror shows the same one: the settled draft, its anchor its
# own record number, with no heading for the drafts it replaced.
set draftfix [file join /tmp questlog-show-drafts-[pid].jsonl]
write_file $draftfix [join {
    {{"type":"user","promptSource":"typed","message":{"role":"user","content":"how do I frobn"}}}
    {{"type":"user","promptSource":"typed","message":{"role":"user","content":"how do I frobnicate?"}}}
    {{"type":"assistant","message":{"content":[{"type":"text","text":"gently"}]}}}
} "\n"]
check "export_session: a superseded draft gets no heading" \
    [::questlog::markdown::export_session $draftfix 1] \
    [join {"**\[#2] USER**\n\nhow do I frobnicate?" "**\[#3] ASSISTANT**\n\ngently"} "\n\n"]
check "export_session: the dialogue view drops it too" \
    [::questlog::markdown::export_session $draftfix 0 1] \
    [join {"**USER**\n\nhow do I frobnicate?" "**ASSISTANT**\n\ngently"} "\n\n"]

# A prompt typed while Claude works: the queue's enqueue and remove are
# bookkeeping, the attachment is what the model received, and the last-prompt
# snapshot echoes it. One USER block, at the attachment's record.
set queuefix [file join /tmp questlog-show-queue-[pid].jsonl]
write_file $queuefix [join {
    {{"type":"user","promptSource":"typed","message":{"role":"user","content":"go"}}}
    {{"type":"queue-operation","operation":"enqueue","content":"also this"}}
    {{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}}
    {{"type":"queue-operation","operation":"remove","reason":"absorbed_mid_turn"}}
    {{"type":"attachment","attachment":{"type":"queued_command","prompt":"also this","commandMode":"prompt"}}}
    {{"type":"last-prompt","lastPrompt":"also this"}}
} "\n"]
check "export_session: a queued prompt is one USER block at its attachment" \
    [::questlog::markdown::export_session $queuefix 1] \
    [join {"**\[#1] USER**\n\ngo" "**\[#3] ASSISTANT**\n\nworking" "**\[#5] USER**\n\nalso this"} "\n\n"]

# Claude Code's notices inside a turn: each exports as a SYSTEM line with its
# raw text folded under it; the caveat and the command echo are the folded
# text alone.
set notefix [file join /tmp questlog-show-notice-[pid].jsonl]
write_file $notefix [join {
    {{"type":"user","uuid":"p1","promptSource":"typed","message":{"role":"user","content":"go"}}}
    {{"type":"user","uuid":"t1","parentUuid":"p1","promptSource":"system","message":{"role":"user","content":"<task-notification><status>completed</status><summary>Agent \"a\" finished</summary></task-notification>"}}}
    {{"type":"user","uuid":"k1","parentUuid":"t1","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>Caveat</local-command-caveat>"}}}
    {{"type":"user","uuid":"c1","parentUuid":"k1","message":{"role":"user","content":"<command-name>/model</command-name>"}}}
    {{"type":"user","uuid":"o1","parentUuid":"c1","message":{"role":"user","content":"<local-command-stdout>Set model to Opus</local-command-stdout>"}}}
} "\n"]
set notes [::questlog::markdown::export_session $notefix 0]
check "export_session: notices are SYSTEM lines, raw text under <details>" \
    [list [regexp -all {\*\*SYSTEM\*\*} $notes] [regexp -all {<details><summary>notice</summary>} $notes] \
        [string match "*\*\*SYSTEM\*\*\n\n✓ Agent \"a\" finished\n\n<details>*" $notes] \
        [string match "*\*\*SYSTEM\*\*\n\n/model · Set model to Opus\n\n<details>*" $notes] \
        [string match {*<command-name>/model*} $notes]] {2 4 1 1 1}

# ---- dialogue view: the conversation only ---------------------------------

# A slash command, an assistant turn mixing thinking + prose + a tool call, the
# tool's result, and a plain assistant turn. Dialogue mode keeps the command
# (unwrapped) and both prose replies; it drops the thinking, the call and the
# result.
set dlgfix [file join /tmp questlog-show-dlg-[pid].jsonl]
write_file $dlgfix [join {
    {{"type":"user","message":{"content":"<command-message>x</command-message>\n<command-name>/x</command-name>\n<command-args>go</command-args>"}}}
    {{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"working"},{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}}
    {{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"tool output here"}]}}}
    {{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}}
} "\n"]
set dlg [::questlog::markdown::export_session $dlgfix 1 1]
check "dialogue: the slash command is a clean user turn" \
    [string match {*/x go*} $dlg] 1
check "dialogue: assistant prose kept, both turns" \
    [list [string match {*working*} $dlg] [string match {*done*} $dlg]] {1 1}
check "dialogue: thinking, tool call and tool result dropped" \
    [list [string match {*hmm*} $dlg] [string match {*Bash*} $dlg] \
          [string match {*tool output here*} $dlg]] {0 0 0}
check "dialogue: the wrapper tags are gone" \
    [string match {*command-name*} $dlg] 0

# ---- rolled-back branches fold into <details> ----------------------------

# The user rewound past "first?" (answered) and asked "second?" from the same
# point. The abandoned exchange keeps its anchors inside a <details> block whose
# summary is the viewer's header phrase; the surviving turn follows it.
set ::env(TZ) UTC
set rbfix [file join /tmp questlog-show-rb-[pid].jsonl]
write_file $rbfix [join {
    {{"type":"user","uuid":"p1","parentUuid":null,"timestamp":"2026-10-17T13:00:00.000Z","promptSource":"typed","message":{"role":"user","content":"start"}}}
    {{"type":"assistant","uuid":"a1","parentUuid":"p1","timestamp":"2026-10-17T13:01:00.000Z","message":{"content":[{"type":"text","text":"ready"}]}}}
    {{"type":"user","uuid":"p2","parentUuid":"a1","timestamp":"2026-10-17T13:02:00.000Z","promptSource":"typed","message":{"role":"user","content":"first? <b>"}}}
    {{"type":"assistant","uuid":"a2","parentUuid":"p2","timestamp":"2026-10-17T13:03:00.000Z","message":{"content":[{"type":"text","text":"abandoned answer"}]}}}
    {{"type":"user","uuid":"p3","parentUuid":"a1","timestamp":"2026-10-17T13:04:00.000Z","promptSource":"typed","message":{"role":"user","content":"second?"}}}
    {{"type":"assistant","uuid":"a3","parentUuid":"p3","timestamp":"2026-10-17T13:05:00.000Z","message":{"content":[{"type":"text","text":"kept answer"}]}}}
} "\n"]
check "export_session: a rolled-back branch is a <details> block" \
    [::questlog::markdown::export_session $rbfix 1] [join {
        "**\[#1] USER**\n\nstart"
        "**\[#2] ASSISTANT**\n\nready"
        "<details><summary>ROLLED BACK · 1 turn · 13:02–13:03 · \"first? &lt;b&gt;\"</summary>"
        "**\[#3] USER**\n\nfirst? <b>"
        "**\[#4] ASSISTANT**\n\nabandoned answer"
        "</details>"
        "**\[#5] USER**\n\nsecond?"
        "**\[#6] ASSISTANT**\n\nkept answer"
    } "\n\n"]
check "export_session: the dialogue view wraps it too" \
    [string match "*<details>*abandoned answer*</details>*kept answer" \
        [::questlog::markdown::export_session $rbfix 0 1]] 1

# ---- show's identifier resolution -----------------------------------------

check "resolve_session: an existing file path is taken as-is" \
    [::questlog::cli::main::resolve_session $f] $f

# A bare uuid resolves against the projects store. Override projects_root to a
# temp tree (the test-scan idiom) and build it through _real_file, since
# lib/path.tcl guards file mkdir/delete outside its own namespace.
set proot /tmp/questlog-show-projects-[pid]
::questlog::path::_real_file delete -force $proot
proc ::questlog::path::projects_root {} { return $::proot }
set uuid 11111111-2222-3333-4444-555555555555
set sessdir [file join $proot -home-user-proj]
::questlog::path::_real_file mkdir $sessdir
set sesspath [file join $sessdir $uuid.jsonl]
write_file $sesspath $fixture
check "resolve_session: a bare uuid resolves to its session file" \
    [::questlog::cli::main::resolve_session $uuid] $sesspath

::questlog::path::_real_file delete -force $f $toolfix $dlgfix $queuefix $notefix $rbfix $proot

if {$failures == 0} {
    puts "\nAll tests passed."
} else {
    puts "\n$failures test(s) failed."
    exit 1
}
