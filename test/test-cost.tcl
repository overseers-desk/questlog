#!/usr/bin/env tclsh9.0
# Unit tests for lib/cost.tcl: the per-session turn count and duration that the
# cost second pass computes alongside token cost. Covers the pure duration
# helpers and the worker's compute_cost over a fixture, with no Tk. Run:
#   tclsh9.0 test/test-cost.tcl
package require Tcl 9
package require json

set ROOT [file dirname [file dirname [file normalize [info script]]]]
namespace eval ::questlog::cost {}
source [file join $ROOT lib cost.tcl]
# compute_cost lives in the worker prelude; eval it here to test it directly.
eval $::questlog::cost::WorkerScript

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

# ---- duration helpers ----------------------------------------------------

check "dur_secs span" \
    [::questlog::cost::dur_secs 2026-04-25T10:00:00.000Z 2026-04-25T10:43:08.000Z] 2588
check "dur_secs blank when end precedes start" \
    [::questlog::cost::dur_secs 2026-04-25T10:43:08.000Z 2026-04-25T10:00:00.000Z] ""
check "dur_secs blank on a missing bound" \
    [::questlog::cost::dur_secs "" 2026-04-25T10:00:00.000Z] ""

check "fmt_dur under an hour"   [::questlog::cost::fmt_dur 2588] "43:08"
check "fmt_dur pads minutes"    [::questlog::cost::fmt_dur 125]  "02:05"
check "fmt_dur past an hour"    [::questlog::cost::fmt_dur 3909] "1:05:09"
check "fmt_dur blank on empty"  [::questlog::cost::fmt_dur ""]   ""
check "fmt_dur blank on -1"     [::questlog::cost::fmt_dur -1]   ""

# ---- compute_cost: turns + timestamps over a fixture ---------------------

# Three typed prompts ("role":"user","content":"…"), one tool-result user
# record whose content is an array (must NOT count as a turn), two assistant
# records, spanning 10:00:00 to 10:43:08.
set fd [file tempfile fix]
puts $fd {{"type":"user","timestamp":"2026-04-25T10:00:00.000Z","message":{"role":"user","content":"first prompt"}}}
puts $fd {{"type":"assistant","timestamp":"2026-04-25T10:00:05.000Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":50}}}}
puts $fd {{"type":"user","timestamp":"2026-04-25T10:10:00.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"ls output"}]}}}
puts $fd {{"type":"user","timestamp":"2026-04-25T10:20:00.000Z","message":{"role":"user","content":"second prompt"}}}
puts $fd {{"type":"assistant","timestamp":"2026-04-25T10:30:00.000Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":200,"output_tokens":80}}}}
puts $fd {{"type":"user","timestamp":"2026-04-25T10:43:08.000Z","message":{"role":"user","content":"third prompt"}}}
close $fd

set r [compute_cost $fix]
check "turns counts typed prompts, not tool results" [dict get $r turns] 3
check "first_ts is the earliest record"  [dict get $r first_ts] 2026-04-25T10:00:00.000Z
check "last_ts is the latest record"      [dict get $r last_ts]  2026-04-25T10:43:08.000Z
check "duration from the fixture" \
    [::questlog::cost::fmt_dur \
        [::questlog::cost::dur_secs [dict get $r first_ts] [dict get $r last_ts]]] "43:08"
file delete $fix

if {$failures == 0} {
    puts "\nAll tests passed."
} else {
    puts "\n$failures test(s) failed."
    exit 1
}
