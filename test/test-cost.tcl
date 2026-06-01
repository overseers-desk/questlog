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
source [file join $ROOT cli cost.tcl]
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

# active_secs sums the gaps between records but drops the gap that precedes a
# typed human prompt (the assistant had finished and the session sat idle), so
# resuming a session long after the last reply adds nothing to the duration.
check "active_secs sums the gaps inside a turn" \
    [::questlog::cost::active_secs {{0 1} {10 0} {40 0}}] 40
check "active_secs drops the gap before a human prompt" \
    [::questlog::cost::active_secs {{0 1} {10 0} {1000 1} {1015 0}}] 25
check "active_secs drops a long resume gap" \
    [::questlog::cost::active_secs {{0 1} {5 0} {1000000 1} {1000030 0}}] 35
check "active_secs sorts before summing" \
    [::questlog::cost::active_secs {{10 0} {0 1}}] 10
check "active_secs blank under two stamps" \
    [::questlog::cost::active_secs {{0 1}}] ""

check "fmt_dur under an hour"   [::questlog::cost::fmt_dur 2588] "43:08"
check "fmt_dur pads minutes"    [::questlog::cost::fmt_dur 125]  "02:05"
check "fmt_dur past an hour"    [::questlog::cost::fmt_dur 3909] "1:05:09"
check "fmt_dur blank on empty"  [::questlog::cost::fmt_dur ""]   ""
check "fmt_dur blank on -1"     [::questlog::cost::fmt_dur -1]   ""

# ---- compute_cost: turns + timestamps over a fixture ---------------------

# Three typed prompts ("role":"user","content":"…"), one tool-result user
# record whose content is an array (must NOT count as a turn), two assistant
# records, spanning 10:00:00 to 10:43:08. Of that 43:08 span, the gaps before
# the second (10:10:00->10:20:00) and third (10:30:00->10:43:08) prompts are
# the user sitting idle, leaving 20:00 of active work.
set fd [file tempfile fix]
puts $fd {{"type":"user","timestamp":"2026-04-25T10:00:00.000Z","message":{"role":"user","content":"first prompt"}}}
puts $fd {{"type":"assistant","timestamp":"2026-04-25T10:00:05.000Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":50}}}}
puts $fd {{"type":"user","timestamp":"2026-04-25T10:10:00.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"ls output"}]}}}
puts $fd {{"type":"user","timestamp":"2026-04-25T10:20:00.000Z","message":{"role":"user","content":"second prompt"}}}
puts $fd {{"type":"assistant","timestamp":"2026-04-25T10:30:00.000Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":200,"output_tokens":80}}}}
puts $fd {{"type":"user","timestamp":"2026-04-25T10:43:08.000Z","message":{"role":"user","content":"third prompt"}}}
close $fd

set r [::questlog::cost::parse_file $fix]
check "turns counts typed prompts, not tool results" [dict get $r turns] 3
check "first_ts is the earliest record"  [dict get $r first_ts] 2026-04-25T10:00:00.000Z
check "last_ts is the latest record"      [dict get $r last_ts]  2026-04-25T10:43:08.000Z
set cost_dict [::questlog::cli::cost::compute_sync $fix]
check "active duration from the fixture (idle gaps before prompts dropped)" \
    [::questlog::cost::fmt_dur [dict get $cost_dict duration_secs]] "20:00"
file delete $fix

if {$failures == 0} {
    puts "\nAll tests passed."
} else {
    puts "\n$failures test(s) failed."
    exit 1
}
