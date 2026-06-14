#!/usr/bin/env tclsh9.0
# End-to-end test for `--accrued-cost`: drive the real launcher over a sandbox
# corpus (HOME points at a synthetic ~/.claude/projects tree) and check that
# cost is windowed by each message's own timestamp, not the whole transcript.
# No Tk: --json/--shortstat run headless. Run: tclsh9.0 test/test-accrued.tcl
package require Tcl 9
package require json

set ROOT [file dirname [file dirname [file normalize [info script]]]]
set QL   [file join $ROOT questlog]
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
proc near {got want} { return [expr {$got ne "null" && $got ne "" && abs($got - $want) < 0.001}] }

# ---- sandbox corpus ------------------------------------------------------
set HOME /tmp/questlog-test-accrued
file delete -force $HOME
set PROJ [file join $HOME .claude projects -tmp-proj]
file mkdir $PROJ

# Opus-4-8 input rate is 5/Mtok (data/anthropic-rates.csv). 10:00Z keeps each
# record in its own local day in any plausible timezone. Window under test is
# 2026-06-01 .. 2026-06-05; "in" dates sit on 06-03, "out" (revival) on 06-12.
# Natural file mtime is today, which clears the 06-01 since floor, so selection
# keeps every fixture and the windowing alone decides what counts.
proc assistant {req day in} {
    return "{\"type\":\"assistant\",\"requestId\":\"$req\",\"timestamp\":\"2026-06-${day}T10:00:00.000Z\",\"message\":{\"model\":\"claude-opus-4-8\",\"usage\":{\"input_tokens\":$in,\"output_tokens\":0}}}"
}
proc prompt {day text} {
    return "{\"type\":\"user\",\"timestamp\":\"2026-06-${day}T10:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"$text\"}}"
}
proc write_session {uuid lines} {
    set fh [open [file join $::PROJ $uuid.jsonl] w]
    foreach l $lines { puts $fh $l }
    close $fh
}
proc write_subagent {uuid agent lines} {
    set d [file join $::PROJ $uuid subagents]
    file mkdir $d
    set fh [open [file join $d agent-$agent.jsonl] w]
    foreach l $lines { puts $fh $l }
    close $fh
}

# AAAA: wholly in-window (06-03), $5; carries a unique word for the clause test.
write_session AAAA [list [prompt 03 "review the wombatxyz module"] [assistant a1 03 1000000]]
# BBBB: in-window 06-03 ($2) then revived 06-12 ($5 out of window) -> accrued $2.
write_session BBBB [list [prompt 03 "start"] [assistant b1 03 400000] \
                         [prompt 12 "revisit"] [assistant b2 12 1000000]]
# CCCC: only out-of-window activity (06-12) -> passes the floor, 0 in-window, dropped.
write_session CCCC [list [prompt 12 "later only"] [assistant c1 12 1000000]]
# DDDD: parent out-of-window (06-12, $0 in-window) but an in-window subagent
# (06-03, $3) -> parent kept as a container.
write_session DDDD [list [prompt 12 "spawn"] [assistant d1 12 1000000]]
write_subagent DDDD 1 [list [prompt 03 "child work"] [assistant d1s 03 600000]]

# ---- run A: windowed json, no clauses ------------------------------------
set out [exec env HOME=$HOME $QL --json --accrued-cost --since 2026-06-01 --until 2026-06-05]
set cost [dict create]
set subs [dict create]
foreach fdata [::json::json2dict $out] {
    foreach s [dict get $fdata sessions] {
        dict set cost [dict get $s uuid] [dict get $s cost_usd]
        dict set subs [dict get $s uuid] [dict get $s subagents]
    }
}
check "AAAA present, whole session is in-window (\$5)" [near [dict getdef $cost AAAA null] 5.0] 1
check "BBBB present, only the in-window day counts (\$2, not \$7)" [near [dict getdef $cost BBBB null] 2.0] 1
check "CCCC dropped: passes the floor but nothing in the window" [dict exists $cost CCCC] 0
check "DDDD kept as container though its own window cost is nil" [dict exists $cost DDDD] 1
check "DDDD parent carries no in-window spend" [expr {[dict getdef $cost DDDD null] in {null 0 0.0}}] 1
check "DDDD in-window subagent counted (\$3)" \
    [near [dict get [lindex [dict get $subs DDDD] 0] cost_usd] 3.0] 1

# ---- run A totals via shortstat ------------------------------------------
set ss [exec env HOME=$HOME $QL --shortstat --accrued-cost --since 2026-06-01 --until 2026-06-05]
regexp {sessions\s+(\d+)} $ss -> n_sess
regexp {total cost\s+\$([0-9.]+)} $ss -> tot
check "shortstat sessions = 3 (AAAA, BBBB, DDDD; CCCC dropped)" $n_sess 3
check "shortstat total = 5 + 2 + 3 = \$10" [near $tot 10.0] 1

# ---- run B: clauses still filter -----------------------------------------
set ss [exec env HOME=$HOME $QL --shortstat --accrued-cost --since 2026-06-01 --until 2026-06-05 --keyword wombatxyz]
regexp {sessions\s+(\d+)} $ss -> n_sess
regexp {total cost\s+\$([0-9.]+)} $ss -> tot
check "clause narrows to the one matching session" $n_sess 1
check "clause-scoped windowed total = \$5" [near $tot 5.0] 1

file delete -force $HOME
if {$failures == 0} {
    puts "\nAll tests passed."
} else {
    puts "\n$failures test(s) failed."
    exit 1
}
