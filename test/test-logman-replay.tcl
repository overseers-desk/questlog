#!/usr/bin/env tclsh9.0
# The streaming conversation replayer: logman's dialogue-view proving consumer.
# A transcript streams through line by line and only the human/AI conversation
# comes out as markdown - no tool uses, no tool results, no thinking, no
# sidechain records, no compact summaries, no meta records, and none of the
# harness echoes that are command OUTPUT (captured stdout, caveats) or
# background-task notifications. A slash command the user ran IS kept, unwrapped
# from its <command-message>/<command-name>/<command-args> harness wrapper to the
# "/name args" the user typed. The whole selection is one call to
# ::logman::dialogue_body, so this driver is a screenful; if it ever grows past
# one, that is a finding about the module's face.
# Run:
#   tclsh9.0 test/test-logman-replay.tcl
package require Tcl 9

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require logman

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

# The replayer. Reads a channel of JSONL lines, emits markdown: a human line
# under **USER:**, the assistant's prose under **ASSISTANT:**. logman::dialogue_body
# owns the whole selection and the slash-command unwrap; this driver only labels.
proc replay {chan} {
    set out [list]
    while {[gets $chan line] >= 0} {
        if {$line eq ""} continue
        set rec [::logman::parse_line $line]
        if {$rec eq ""} continue
        set body [::logman::dialogue_body $rec]
        if {$body eq ""} continue
        set who [expr {[::logman::record_role_label $rec] eq "ASSISTANT" ? "ASSISTANT" : "USER"}]
        lappend out "**$who:**\n$body"
    }
    return [join $out "\n\n"]
}

# A fixture transcript carrying every shape the replay must pass or drop.
set lines {
    {{"type":"user","message":{"role":"user","content":"hello there"},"timestamp":"2026-07-21T10:00:00.000Z"}}
    {{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"pondering"},{"type":"text","text":"hi, checking the file"},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/a/b.txt"}}]},"timestamp":"2026-07-21T10:00:05.000Z"}}
    {{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"file body"}]},"timestamp":"2026-07-21T10:00:06.000Z"}}
    {{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"the file says hello"}]},"timestamp":"2026-07-21T10:00:08.000Z"}}
    {{"type":"user","isSidechain":true,"message":{"role":"user","content":"subagent brief"}}}
    {{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"subagent reply"}]}}}
    {{"type":"user","message":{"role":"user","content":"<command-message>otter</command-message>\n<command-name>/otter</command-name>\n<command-args>capture foo</command-args>"}}}
    {{"type":"user","message":{"role":"user","content":"<local-command-stdout>captured 12 rows</local-command-stdout>"}}}
    {{"type":"user","message":{"role":"user","content":"<task-notification>background task done</task-notification>"}}}
    {{"type":"user","isMeta":true,"message":{"role":"user","content":"harness meta note"}}}
    {{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"summary of it all"}}}
    {{"type":"user","message":{"role":"user","content":[{"type":"text","text":"typed with a picture"},{"type":"image"}]},"timestamp":"2026-07-21T10:01:00.000Z"}}
}
set path [file join [file tempdir] logman-replay.jsonl]
set fd [open $path w]
foreach l $lines { puts $fd $l }
close $fd

set fd [open $path r]
set md [replay $fd]
close $fd

check "both plain prompts replay" \
    [list [string match "*hello there*" $md] [string match "*typed with a picture*" $md]] {1 1}
check "assistant prose replays, in order" \
    [regexp {\*\*ASSISTANT:\*\*\nhi, checking the file.*\*\*ASSISTANT:\*\*\nthe file says hello} $md] 1
check "slash command kept, unwrapped to what the user typed" \
    [string match "*/otter capture foo*" $md] 1
check "the slash-command wrapper tags are gone" \
    [list [string match "*command-message*" $md] [string match "*command-args*" $md]] {0 0}
check "three human turns labelled" \
    [regexp -all {\*\*USER:\*\*} $md] 3
foreach {name needle} {
    "tool use dropped"          "Read("
    "tool result dropped"       "file body"
    "thinking dropped"          "pondering"
    "sidechain dropped"         "subagent"
    "command output dropped"    "captured 12 rows"
    "task notification dropped" "background task"
    "meta record dropped"       "harness meta"
    "compact summary dropped"   "summary of it all"
} {
    check $name [string match "*$needle*" $md] 0
}

file delete $path
exit $failures
