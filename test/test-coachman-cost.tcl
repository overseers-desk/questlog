#!/usr/bin/env tclsh9.0
# Tests for coachman's default cost meter: the tallyman-backed
# session_cost_usd over a fixture transcripts tree, the refusal when no
# rates resolve, and the rates table shipped beside the module. Run:
#   tclsh9.0 test/test-coachman-cost.tcl
package require Tcl 9
package require json

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require coachman

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
proc near {got want} { return [expr {abs($got - $want) < 0.001}] }

set QUIET [logger::init coachman-test-quiet]
${QUIET}::setlevel critical

# The meter under test, its filesystem and rates both pointed at fixtures.
oo::class create MeterHarness {
    superclass coachman::Harness
    method log_service {} { return $::QUIET }
    method transcripts_root {} { return $::TROOT }
    method cost_rates {} { return $::TRATES }
}

set dir [file tempdir]
set ::TROOT [file join $dir transcripts]
set proj [file join $::TROOT proj-x]
file mkdir $proj

# Parent transcript: 1M input tokens on testmodel. Subagent beside it:
# 500k output tokens. At in 10 / out 20 per Mtok that is 10 + 10 dollars.
set fd [open [file join $proj sid-c.jsonl] w]
puts $fd {{"type":"user","timestamp":"2026-06-01T10:00:00.000Z","message":{"role":"user","content":"go"}}}
puts $fd {{"type":"assistant","requestId":"r1","timestamp":"2026-06-01T10:00:05.000Z","message":{"model":"testmodel","usage":{"input_tokens":1000000,"output_tokens":0}}}}
close $fd
set subdir [file join $proj sid-c subagents]
file mkdir $subdir
set fd [open [file join $subdir agent-1.jsonl] w]
puts $fd {{"type":"assistant","isSidechain":true,"requestId":"r2","timestamp":"2026-06-01T10:01:00.000Z","message":{"model":"testmodel","usage":{"input_tokens":0,"output_tokens":500000}}}}
close $fd

set pdir [file join $dir row-1]
file mkdir $pdir
set h [MeterHarness new $pdir $dir]

set ::TRATES [dict create testmodel {{2026-01-01 10.0 20.0 5.0 1.0}}]
check "the meter prices the parent plus its subagents" \
    [near [$h session_cost_usd sid-c] 20.0] 1
check "the meter reads 0 before the transcript appears" \
    [$h session_cost_usd sid-none] 0.0

# A model billed by prompt length pays each request's own card, the
# subagent's long request included: 50k input on the small card (in 1 per
# Mtok, $0.05) and 100,001 on the large (in 10 per Mtok, $1.00001).
set fd [open [file join $proj sid-t.jsonl] w]
puts $fd {{"type":"assistant","requestId":"r3","timestamp":"2026-06-01T10:00:05.000Z","message":{"model":"tiered","usage":{"input_tokens":50000,"output_tokens":0}}}}
close $fd
set subdir [file join $proj sid-t subagents]
file mkdir $subdir
set fd [open [file join $subdir agent-1.jsonl] w]
puts $fd {{"type":"assistant","isSidechain":true,"requestId":"r4","timestamp":"2026-06-01T10:01:00.000Z","message":{"model":"tiered","usage":{"input_tokens":100001,"output_tokens":0}}}}
close $fd
set ::TRATES [dict create tiered {{2026-01-01 1 2 3 4 0} {2026-01-01 10 20 30 40 100001}}]
check "the meter prices a long subagent request on its own card" \
    [near [$h session_cost_usd sid-t] 1.05] 1

# A cache write kept for an hour pays the row's hour rate: of 1M writes,
# 600k at 3 per Mtok and 400k kept an hour at 6, $4.20.
set fd [open [file join $proj sid-h.jsonl] w]
puts $fd {{"type":"assistant","requestId":"r5","timestamp":"2026-06-01T10:00:05.000Z","message":{"model":"hourly","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":1000000,"cache_creation":{"ephemeral_5m_input_tokens":600000,"ephemeral_1h_input_tokens":400000}}}}}
close $fd
set ::TRATES [dict create hourly {{2026-01-01 1 2 3 4 0 6}}]
check "the meter prices an hour-kept cache write at the hour rate" \
    [near [$h session_cost_usd sid-h] 4.2] 1

# An unpriced model is a blank, not a false figure: the meter reads 0.
set ::TRATES [dict create othermodel {{2026-01-01 10.0 20.0 5.0 1.0}}]
check "an unpriced model reads 0, not a wrong price" \
    [$h session_cost_usd sid-c] 0.0

# No rates at all: pricing refuses rather than reading a false 0 that
# would leave an armed cap untrippable.
set ::TRATES {}
check "empty rates refuse to price" [catch {$h session_cost_usd sid-c}] 1

# The default cost_rates resolves the table shipped beside the module.
oo::class create DefaultHarness {
    superclass coachman::Harness
    method log_service {} { return $::QUIET }
}
set h2 [DefaultHarness new $pdir $dir]
check "the shipped anthropic-rates.tcl resolves beside the module" \
    [expr {[dict size [$h2 cost_rates]] > 0}] 1

file delete -force $dir

if {$failures == 0} {
    puts "\nAll tests passed."
} else {
    puts "\n$failures test(s) failed."
    exit 1
}
