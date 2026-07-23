#!/usr/bin/env tclsh9.0
# CLI-level tests for the satisfied-and-capped retirement (lib/match.tcl,
# plumbed from cli/main.tcl). --limit-matches caps the snippets a session emits,
# and scan_file may retire its leaf walk once a file has buffered that cap of raw
# hits. --dialogue is the carve-out: limit_matches drops tool/thinking hits
# BEFORE counting toward the cap, so the caps are NOT injected under dialogue and
# a user/assistant hit that trails earlier tool hits still emits. Both cases run
# the real ./questlog --json subprocess over a fixture corpus. Run:
#   tclsh9.0 test/test-cli-caps.tcl
package require Tcl 9
package require json

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]

# Isolated corpus; HOME points the exec'd CLI at it.
set TMP /tmp/questlog-caps-test
set CORPUS [file join $TMP .claude projects]
set ::env(HOME) $TMP
file delete -force $TMP
set FOLDER [file join $CORPUS -home-test-code-proj]
file mkdir $FOLDER

set fails 0
proc check {name expected actual} {
    if {$expected eq $actual} {
        puts "ok:   $name"
    } else {
        puts "FAIL: $name"
        puts "      expected: $expected"
        puts "      actual:   $actual"
        incr ::fails
    }
}

proc write_lines {path lines} {
    set fh [open $path w]
    chan configure $fh -encoding utf-8 -translation lf
    foreach l $lines { puts $fh $l }
    close $fh
    file mtime $path [clock seconds]
}

# The session's own matches under the first (only) folder.
proc session_matches {json} {
    set folders [::json::json2dict $json]
    set folder [lindex $folders 0]
    set sess [lindex [dict get $folder sessions] 0]
    return [dict get $sess matches]
}
proc run_cli {argv} {
    global ROOT
    return [exec [file join $ROOT questlog] --json {*}$argv 2> /dev/null]
}

# ---- --limit-matches caps the emitted snippets ------------------------------
# Five assistant turns all say "shibboleth"; --limit-matches 1 emits exactly one.
set multi [file join $FOLDER 11111111-1111-1111-1111-111111111111.jsonl]
write_lines $multi [list \
    {{"type":"user","cwd":"/home/test/code/proj","timestamp":"2026-06-20T10:00:00.000Z","message":{"content":"open the session"}}} \
    {{"type":"assistant","timestamp":"2026-06-20T10:00:01.000Z","message":{"content":"shibboleth one"}}} \
    {{"type":"assistant","timestamp":"2026-06-20T10:00:02.000Z","message":{"content":"shibboleth two"}}} \
    {{"type":"assistant","timestamp":"2026-06-20T10:00:03.000Z","message":{"content":"shibboleth three"}}} \
    {{"type":"assistant","timestamp":"2026-06-20T10:00:04.000Z","message":{"content":"shibboleth four"}}} \
    {{"type":"assistant","timestamp":"2026-06-20T10:00:05.000Z","message":{"content":"shibboleth five"}}}]
set m [session_matches [run_cli [list --keyword shibboleth --since all --limit-matches 1]]]
check limit_matches_one 1 [llength $m]
# The one emitted is the earliest hit (the line-2 assistant turn).
check limit_matches_earliest 2 [dict get [lindex $m 0] line]

# ---- --dialogue keeps a user/assistant hit trailing earlier tool hits -------
# The needle first appears in tool_use blocks (lines 2-3), then in a user turn
# (line 4). Under --dialogue the tool hits are dropped and the user hit is what
# --limit-matches 1 must deliver: it emits only because the caps are withheld
# under dialogue, so scan_file never retires on the earlier tool hits.
set dlg [file join $FOLDER 22222222-2222-2222-2222-222222222222.jsonl]
write_lines $dlg [list \
    {{"type":"user","cwd":"/home/test/code/proj","timestamp":"2026-06-20T11:00:00.000Z","message":{"content":"start"}}} \
    {{"type":"assistant","timestamp":"2026-06-20T11:00:01.000Z","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"grep watchword src"}}]}}} \
    {{"type":"assistant","timestamp":"2026-06-20T11:00:02.000Z","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"grep watchword lib"}}]}}} \
    {{"type":"user","timestamp":"2026-06-20T11:00:03.000Z","message":{"role":"user","content":"the watchword is spoken here"}}}]
# Without dialogue the earliest hits are the two tool_use blocks.
set nd [session_matches [run_cli [list --keyword watchword --since all]]]
check dialogue_control_first_is_tool tool_use [dict get [lindex $nd 0] type]
# Under dialogue, --limit-matches 1 still yields the user turn (line 4).
set d [session_matches [run_cli [list --keyword watchword --since all --dialogue --limit-matches 1]]]
check dialogue_one 1 [llength $d]
check dialogue_user_survives user [dict get [lindex $d 0] type]
check dialogue_user_line 4 [dict get [lindex $d 0] line]

file delete -force $TMP

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
