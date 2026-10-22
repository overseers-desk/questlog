#!/usr/bin/env wish9.0
# A subagent's own transcript opens its turns. Claude Code marks every record
# of <sid>/subagents/agent-<id>.jsonl isSidechain, the mark that in a parent's
# file sets a subagent's interleaved records apart from the parent's turns.
# Read from the subagent's own file the brief opens a turn; read from a parent
# file the interleaved sidechain records still open none. Both fixtures go
# through parse_line with their path, as the viewer and the markdown export
# read them, and render into a bare showman view.
#
# Runs under wish (it builds a Tk view); run-audit routes it to wish9.0 on
# the private Xvfb.

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require showman

set fails 0
proc check {name got want} {
    if {$got eq $want} {
        puts "ok   - $name"
    } else {
        puts "FAIL - $name"
        puts "       got:  $got"
        puts "       want: $want"
        incr ::fails
    }
}

set TMP [file join [file tempdir] ql-subagent-turns-[pid]]
set PROJ [file join $TMP -home-test-proj]
file mkdir [file join $PROJ sid-1 subagents]

proc jfile {path lines} {
    set fh [open $path w]
    chan configure $fh -encoding utf-8
    foreach l $lines { puts $fh [string trim $l] }
    close $fh
}

# The records of one file, read as the viewer reads them.
proc read_recs {path} {
    set fh [open $path r]
    chan configure $fh -encoding utf-8
    set recs [list]
    set n 0
    while {[chan gets $fh line] >= 0} {
        incr n
        set rec [::logman::parse_line $line $path]
        if {$rec eq ""} continue
        dict set rec _line $n
        lappend recs $rec
    }
    close $fh
    return $recs
}

# The turns a showman view opens over a file's records.
set Views 0
proc turns_of {path} {
    set f .v[incr ::Views]
    ttk::frame $f
    set v [::showman::Showman new $f]
    $v render_records [::logman::mark_turns [read_recs $path]]
    update idletasks
    set n [$v region_count]
    $v destroy
    destroy $f
    return $n
}

# A subagent's file: its brief (string content, no promptSource), a tool call,
# its result, the closing reply; every record sidechain.
set SUB [file join $PROJ sid-1 subagents agent-a1.jsonl]
set SUB_LINES {
    {{"parentUuid":null,"isSidechain":true,"agentId":"a1","type":"user","message":{"role":"user","content":"Repository: /tmp/x. Find the bug."},"uuid":"s1","timestamp":"2026-10-01T10:00:00Z"}}
    {{"parentUuid":"s1","isSidechain":true,"agentId":"a1","type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}],"stop_reason":"tool_use"},"uuid":"s2","timestamp":"2026-10-01T10:00:05Z"}}
    {{"parentUuid":"s2","isSidechain":true,"agentId":"a1","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"README"}]},"uuid":"s3","timestamp":"2026-10-01T10:00:06Z"}}
    {{"parentUuid":"s3","isSidechain":true,"agentId":"a1","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Found it."}],"stop_reason":"end_turn"},"uuid":"s4","timestamp":"2026-10-01T10:00:10Z"}}
}
jfile $SUB $SUB_LINES

# An old-format parent file: two typed prompts of its own, a subagent's run
# interleaved as sidechain records between the first prompt's Task call and
# its result.
set PARENT [file join $PROJ sid-1.jsonl]
jfile $PARENT {
    {{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"Spawn a helper."},"uuid":"p1","timestamp":"2026-10-01T09:59:00Z"}}
    {{"parentUuid":"p1","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tk","name":"Task","input":{"prompt":"Find the bug."}}]},"uuid":"p2","timestamp":"2026-10-01T09:59:05Z"}}
    {{"parentUuid":null,"isSidechain":true,"type":"user","message":{"role":"user","content":"Repository: /tmp/x. Find the bug."},"uuid":"s1","timestamp":"2026-10-01T10:00:00Z"}}
    {{"parentUuid":"s1","isSidechain":true,"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]},"uuid":"s2","timestamp":"2026-10-01T10:00:05Z"}}
    {{"parentUuid":"s2","isSidechain":true,"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"README"}]},"uuid":"s3","timestamp":"2026-10-01T10:00:06Z"}}
    {{"parentUuid":"s3","isSidechain":true,"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Found it."}]},"uuid":"s4","timestamp":"2026-10-01T10:00:10Z"}}
    {{"parentUuid":"p2","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tk","content":"Found it."}]},"uuid":"p3","timestamp":"2026-10-01T10:00:11Z"}}
    {{"parentUuid":"p3","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"The helper found it."}]},"uuid":"p4","timestamp":"2026-10-01T10:00:15Z"}}
    {{"parentUuid":"p4","isSidechain":false,"type":"user","message":{"role":"user","content":"Thanks, now fix it."},"uuid":"p5","timestamp":"2026-10-01T10:01:00Z"}}
    {{"parentUuid":"p5","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Fixed."}]},"uuid":"p6","timestamp":"2026-10-01T10:01:05Z"}}
}

check "a subagent's own file opens one turn, at its brief" [turns_of $SUB] 1
set brief [lindex [read_recs $SUB] 0]
check "the brief read from its own file is a turn start" \
    [::logman::is_turn_start $brief] 1
check "the brief read from its own file is a dialogue prompt" \
    [::logman::is_dialogue_prompt $brief] 1
check "the same brief read without its path keeps the mark" \
    [::logman::is_turn_start [::logman::parse_line \
        [string trim [lindex $SUB_LINES 0]]]] 0
check "a parent file opens only its own two turns" [turns_of $PARENT] 2

file delete -force $TMP
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
