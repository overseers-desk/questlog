#!/usr/bin/env tclsh9.0
# Unit tests for lib/cost.tcl: the per-session turn count and duration that the
# cost second pass computes alongside token cost. Covers the pure duration
# helpers and the worker's compute_cost over a fixture, with no Tk. Run:
#   tclsh9.0 test/test-cost.tcl
package require Tcl 9
package require json

set ROOT [file dirname [file dirname [file normalize [info script]]]]
namespace eval ::questlog::cost {}
source [file join $ROOT config.tcl]
source [file join $ROOT lib jsonl.tcl]
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

# split_secs partitions the wall clock by the class of the record ending each
# gap: machine gaps count in full, human gaps count as composing time up to
# the cap (here passed as 300s), neutral gaps count for neither side. So a
# resume long after the last reply credits at most one cap of human time.
check "split_secs sums machine gaps inside a turn" \
    [::questlog::cost::split_secs {{0 human} {10 machine} {40 machine}} 300] {40 0}
check "split_secs credits a short human gap in full" \
    [::questlog::cost::split_secs {{0 human} {10 machine} {130 human}} 300] {10 120}
check "split_secs clips a long human gap to the cap" \
    [::questlog::cost::split_secs {{0 human} {10 machine} {1000000 human} {1000030 machine}} 300] {40 300}
check "split_secs credits a neutral gap to neither side" \
    [::questlog::cost::split_secs {{0 human} {10 machine} {500 neutral} {510 machine}} 300] {20 0}
check "split_secs sorts before summing" \
    [::questlog::cost::split_secs {{10 machine} {0 human}} 300] {10 0}
check "split_secs blank under two stamps" \
    [::questlog::cost::split_secs {{0 human}} 300] {{} {}}

check "fmt_dur under an hour"   [::questlog::cost::fmt_dur 2588] "43:08"
check "fmt_dur pads minutes"    [::questlog::cost::fmt_dur 125]  "02:05"
check "fmt_dur past an hour"    [::questlog::cost::fmt_dur 3909] "1:05:09"
check "fmt_dur blank on empty"  [::questlog::cost::fmt_dur ""]   ""
check "fmt_dur blank on -1"     [::questlog::cost::fmt_dur -1]   ""

# ---- model label ---------------------------------------------------------

# A model id reduces to a "Family Ver" label; a dated suffix is ignored and an
# unrecognised or empty id reads blank.
check "fmt_model opus"          [::questlog::cost::fmt_model claude-opus-4-8] "Opus 4.8"
check "fmt_model sonnet"        [::questlog::cost::fmt_model claude-sonnet-4-6] "Sonnet 4.6"
check "fmt_model haiku dated"   [::questlog::cost::fmt_model claude-haiku-4-5-20251001] "Haiku 4.5"
check "fmt_model sonnet 5"      [::questlog::cost::fmt_model claude-sonnet-5] "Sonnet 5"
check "fmt_model fable 5"       [::questlog::cost::fmt_model claude-fable-5] "Fable 5"
check "fmt_model single ver dated" [::questlog::cost::fmt_model claude-sonnet-5-20260101] "Sonnet 5"
check "fmt_model blank on empty" [::questlog::cost::fmt_model ""] ""
check "fmt_model blank on unknown" [::questlog::cost::fmt_model unknown] ""

# model_label is what the row (and so the Model column and the toolbar's model
# lens) is keyed by: the fmt_model reading where there is one, the id itself
# where there is not, so a model questlog cannot price is still named and still
# selectable. Only an empty id yields an empty label.
check "model_label known id"     [::questlog::cost::model_label claude-opus-4-8] "Opus 4.8"
check "model_label dated id"     [::questlog::cost::model_label claude-sonnet-5-20260101] "Sonnet 5"
check "model_label local model"  [::questlog::cost::model_label qwen3-coder] "qwen3-coder"
check "model_label local dated"  [::questlog::cost::model_label devstral-20260101] "devstral"
check "model_label empty on empty" [::questlog::cost::model_label ""] ""

# model_family is the opus/sonnet/haiku/fable token, lowercased, that fmt_model
# recognises, or "" for an old-scheme or local id: it drives the viewer's
# per-turn chip, so "known family" must agree with fmt_model's Family Ver label.
check "model_family opus"        [::questlog::cost::model_family claude-opus-4-8] "opus"
check "model_family sonnet"      [::questlog::cost::model_family claude-sonnet-5] "sonnet"
check "model_family haiku dated" [::questlog::cost::model_family claude-haiku-4-5-20251001] "haiku"
check "model_family fable"       [::questlog::cost::model_family claude-fable-5] "fable"
check "model_family local model" [::questlog::cost::model_family qwen3-coder] ""
check "model_family old scheme"  [::questlog::cost::model_family claude-3-5-sonnet-20241022] ""
check "model_family empty"       [::questlog::cost::model_family ""] ""

# ---- compute_cost: turns + timestamps over a fixture ---------------------

# Three typed prompts ("role":"user","content":"…"), one tool-result user
# record whose content is an array (must NOT count as a turn), two assistant
# records, spanning 10:00:00 to 10:43:08. Of that 43:08 span, the gaps before
# the second (10:10:00->10:20:00) and third (10:30:00->10:43:08) prompts are
# the session waiting for the user, leaving 20:00 of machine work; each of
# the two waits credits the 5-minute composing cap, 10:00 of human time.
set fd [file tempfile fix]
puts $fd {{"type":"user","timestamp":"2026-04-25T10:00:00.000Z","message":{"role":"user","content":"first prompt"}}}
puts $fd {{"type":"assistant","timestamp":"2026-04-25T10:00:05.000Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":50}}}}
puts $fd {{"type":"user","timestamp":"2026-04-25T10:10:00.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"ls output"}]}}}
puts $fd {{"type":"user","timestamp":"2026-04-25T10:20:00.000Z","message":{"role":"user","content":"second prompt"}}}
puts $fd {{"type":"assistant","timestamp":"2026-04-25T10:30:00.000Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":200,"output_tokens":80}}}}
# A subagent's assistant record (isSidechain) on a different model must NOT win
# the parent's Model label: the last non-sidechain model stays opus. Sharing the
# prior record's timestamp keeps last_ts and the active span unchanged.
puts $fd {{"type":"assistant","isSidechain":true,"timestamp":"2026-04-25T10:30:00.000Z","message":{"model":"claude-haiku-4-5","usage":{"input_tokens":10,"output_tokens":5}}}}
puts $fd {{"type":"user","timestamp":"2026-04-25T10:43:08.000Z","message":{"role":"user","content":"third prompt"}}}
close $fd

set r [::questlog::cost::parse_file $fix]
check "turns counts typed prompts, not tool results" [dict get $r turns] 3
check "last_model is the last non-sidechain assistant model" \
    [dict get $r last_model] claude-opus-4-8
check "first_ts is the earliest record"  [dict get $r first_ts] 2026-04-25T10:00:00.000Z
check "last_ts is the latest record"      [dict get $r last_ts]  2026-04-25T10:43:08.000Z
set cost_dict [::questlog::cli::cost::compute_sync $fix]
check "machine duration from the fixture (waits before prompts excluded)" \
    [::questlog::cost::fmt_dur [dict get $cost_dict duration_secs]] "20:00"
check "human time from the fixture (two waits, each capped)" \
    [::questlog::cost::fmt_dur [dict get $cost_dict human_secs]] "10:00"
check "cost dict carries the formatted model label" \
    [dict get $cost_dict model] "Opus 4.8"
file delete $fix

# ---- compute_cost: record-class fixture -----------------------------------

# One line per record shape the classifier must handle. A file-history-
# snapshot's nested timestamp must not enter the timeline (else the five days
# before the first prompt would count as work, and first_ts would predate the
# session). An AskUserQuestion answer is a tool_result yet human: the dialog
# sat open 17 hours, credited as one 5-minute cap. An ordinary tool_result is
# machine. away_summary, <synthetic> fillers and <task-notification> records
# are neutral: written while the user is away or at the moment of return.
# queue-operation: enqueue is the user typing, remove is queue management.
# Machine: 10 + 30 + 30 + 60 = 02:10. Human: 300 + 60 + 100 = 07:40.
# Turns: the two typed prompts only. Model: <synthetic> must not blank it.
set fd [file tempfile fix]
puts $fd {{"type":"file-history-snapshot","messageId":"m1","isSnapshotUpdate":false,"snapshot":{"timestamp":"2026-04-20T10:00:00.000Z","files":{}}}}
puts $fd {{"type":"user","timestamp":"2026-04-25T10:00:00.000Z","message":{"role":"user","content":"do the thing"}}}
puts $fd {{"type":"assistant","timestamp":"2026-04-25T10:00:10.000Z","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"toolu_ask1","name":"AskUserQuestion","input":{}}],"usage":{"input_tokens":10,"output_tokens":5}}}}
puts $fd {{"type":"user","timestamp":"2026-04-26T03:00:10.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_ask1","content":"Option A"}]}}}
puts $fd {{"type":"assistant","timestamp":"2026-04-26T03:00:40.000Z","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"toolu_bash1","name":"Bash","input":{}}],"usage":{"input_tokens":20,"output_tokens":10}}}}
puts $fd {{"type":"user","timestamp":"2026-04-26T03:01:10.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_bash1","content":"ok"}]}}}
puts $fd {{"type":"system","subtype":"away_summary","timestamp":"2026-04-26T04:01:10.000Z","content":"Goal: the thing. Next: commit."}}
puts $fd {{"type":"assistant","timestamp":"2026-04-26T20:00:00.000Z","message":{"model":"<synthetic>","content":[{"type":"text","text":"No response requested."}]}}}
puts $fd {{"type":"queue-operation","operation":"enqueue","timestamp":"2026-04-26T20:01:00.000Z","content":"and fix the test"}}
puts $fd {{"type":"queue-operation","operation":"remove","timestamp":"2026-04-26T20:02:00.000Z"}}
puts $fd {{"type":"user","timestamp":"2026-04-26T21:00:00.000Z","message":{"role":"user","content":"<task-notification>task b1 done</task-notification>"}}}
puts $fd {{"type":"user","timestamp":"2026-04-26T21:01:40.000Z","message":{"role":"user","content":"now commit"}}}
close $fd

set r [::questlog::cost::parse_file $fix]
check "turns counts written prompts, not harness-tagged user records" \
    [dict get $r turns] 2
check "first_ts ignores the snapshot's nested timestamp" \
    [dict get $r first_ts] 2026-04-25T10:00:00.000Z
check "a trailing <synthetic> record does not blank the model" \
    [dict get $r last_model] claude-opus-4-8
set cost_dict [::questlog::cli::cost::compute_sync $fix]
check "machine time: tool runs and queue management only" \
    [::questlog::cost::fmt_dur [dict get $cost_dict duration_secs]] "02:10"
check "human time: capped dialog answer + enqueue + final prompt" \
    [::questlog::cost::fmt_dur [dict get $cost_dict human_secs]] "07:40"
file delete $fix

# ---- accrue_window: cost windowed by each message's own timestamp ---------
# Needs the rate table and the window-edge helpers, same as the CLI run path.
source [file join $ROOT lib filter.tcl]
::questlog::cost::load_rates $ROOT
proc near {got want} { return [expr {abs($got - $want) < 0.001}] }
proc write_lines {lines} {
    set fd [file tempfile p]
    foreach l $lines { puts $fd $l }
    close $fd
    return $p
}
# Window edges exactly as run computes them, from the user's --since/--until.
proc win {since until} {
    set s [dict create since $since until $until]
    return [list [::questlog::filter::cutoff_for $s] [::questlog::filter::ceiling_for $s]]
}

# Three single-request days at the opus-4-8 rate (in 5 / out 25 per Mtok, from
# data/anthropic-rates.csv, effective 2026-05-28). 10:00Z keeps each record in
# its own local day in every plausible timezone.
set fixA [write_lines {
    {{"type":"user","timestamp":"2026-06-01T10:00:00.000Z","message":{"role":"user","content":"day one"}}}
    {{"type":"assistant","requestId":"r1","timestamp":"2026-06-01T10:00:05.000Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":0}}}}
    {{"type":"user","timestamp":"2026-06-02T10:00:00.000Z","message":{"role":"user","content":"day two"}}}
    {{"type":"assistant","requestId":"r2","timestamp":"2026-06-02T10:00:05.000Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":0,"output_tokens":1000000}}}}
    {{"type":"user","timestamp":"2026-06-02T10:01:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"landed"}]}}}
    {{"type":"user","timestamp":"2026-06-03T10:00:00.000Z","message":{"role":"user","content":"day three"}}}
    {{"type":"assistant","requestId":"r3","timestamp":"2026-06-03T10:00:05.000Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":2000000,"output_tokens":0}}}}
}]

lassign [win 2026-06-02 2026-06-02] lo hi
set a [::questlog::cost::accrue_window $fixA $lo $hi]
check "accrue: only the in-window request is priced (out 1M @ 25)" [near [dict get $a cost_usd] 25.0] 1
check "accrue: in-window output tokens" [dict get $a output_tokens] 1000000
check "accrue: out-of-window day's tokens excluded" [dict get $a input_tokens] 0
check "accrue: turns count in-window typed prompts only (not tool_result)" [dict get $a turns] 1

# Open upper edge: from 06-02 onward includes 06-02 ($25) and 06-03 ($10).
lassign [win 2026-06-02 all] lo hi
set a [::questlog::cost::accrue_window $fixA $lo $hi]
check "accrue: open hi includes every later day (25 + 10)" [near [dict get $a cost_usd] 35.0] 1
check "accrue: open hi turns" [dict get $a turns] 2

# A window before any activity: no in-window spend, the caller's drop signal.
lassign [win 2026-05-01 2026-05-01] lo hi
set a [::questlog::cost::accrue_window $fixA $lo $hi]
check "accrue: empty window has no model breakdown" [dict size [dict get $a model_breakdown]] 0
check "accrue: empty window turns 0" [dict get $a turns] 0
file delete $fixA

# Straddle + missing-timestamp. r4's two records sit either side of the upper
# edge with the larger usage on the later one; anchored by its earliest record,
# r4 is counted once, in full (500k in), in the window of its anchor. r5 carries
# usage but no timestamp, so it can never be placed in time.
set fixB [write_lines {
    {{"type":"assistant","requestId":"r4","timestamp":"2026-06-02T10:00:00.000Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":100000,"output_tokens":0}}}}
    {{"type":"assistant","requestId":"r4","timestamp":"2026-06-03T10:00:00.000Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":500000,"output_tokens":0}}}}
    {{"type":"assistant","requestId":"r5","message":{"model":"claude-opus-4-8","usage":{"input_tokens":9000000,"output_tokens":0}}}}
}]
lassign [win 2026-06-02 2026-06-02] lo hi
set a [::questlog::cost::accrue_window $fixB $lo $hi]
check "accrue: straddling request counted in full at its anchor (500k @ 5)" [near [dict get $a cost_usd] 2.5] 1
check "accrue: timestamp-less request excluded" [dict get $a input_tokens] 500000
# The same request seen from the later day: its anchor is out, so it is excluded.
lassign [win 2026-06-03 2026-06-03] lo hi
set a [::questlog::cost::accrue_window $fixB $lo $hi]
check "accrue: request not double-counted in the later window" [dict size [dict get $a model_breakdown]] 0
file delete $fixB

if {$failures == 0} {
    puts "\nAll tests passed."
} else {
    puts "\n$failures test(s) failed."
    exit 1
}
