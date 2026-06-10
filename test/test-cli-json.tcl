#!/usr/bin/env tclsh9.0
# Unit tests for cli/main.tcl: the --json serializer's cost rendering. The cost
# module returns -1.0 for a session with no priced usage (only <synthetic>
# records, or no assistant turns); the GUI shows that as a blank cell. JSON must
# say null for the same "no figure" sense rather than leak the -1.0 sentinel as
# a negative cost. Run:
#   tclsh9.0 test/test-cli-json.tcl
package require Tcl 9
package require json

set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT cli main.tcl]
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

# ---- format_cost: the single home of the "unknown cost -> null" mapping ----

check "format_cost: -1.0 sentinel is null" \
    [::questlog::cli::main::format_cost -1.0] "null"
check "format_cost: blank is null" \
    [::questlog::cli::main::format_cost ""] "null"
check "format_cost: a genuine zero passes through" \
    [::questlog::cli::main::format_cost 0.0] "0.0"
check "format_cost: a real figure passes through" \
    [::questlog::cli::main::format_cost 0.123456] "0.123456"

# ---- format_secs: blank seconds (under two timestamps) -> null -------------

check "format_secs: blank is null" \
    [::questlog::cli::main::format_secs ""] "null"
check "format_secs: a figure passes through" \
    [::questlog::cli::main::format_secs 600] "600"

# ---- format_json: the sentinel never reaches the wire ----------------------

# One folder, one session priced at -1.0 (no rate matched) carrying one subagent
# also at -1.0, plus a second session with a real figure. The serialized output
# must show null for the two sentinels, the number for the real one, and parse.
# Duration and human time follow the same blank->null rule: s1 carries a blank
# human_secs and its subagent a blank duration_secs; s2 carries real figures.
set folders [dict create proj-folder [dict create \
    project_path /home/user/proj \
    sessions [list \
        [dict create uuid s1 path /p/s1.jsonl title "Unnamed Session" \
            first_ts 2026-06-02T12:00:00.000Z cost_usd -1.0 turns 1 \
            duration_secs 1 human_secs "" matches {} subagents [list \
                [dict create agent_id a1 agent_type Explore description "scout" \
                    cost_usd -1.0 turns 1 duration_secs "" human_secs "" matches {}]]] \
        [dict create uuid s2 path /p/s2.jsonl title "Real Work" \
            first_ts 2026-06-02T13:00:00.000Z cost_usd 0.4216 turns 5 \
            duration_secs 600 human_secs 120 matches {} subagents {}]]]]

set out [::questlog::cli::main::format_json $folders]

check "format_json: no -1 sentinel survives" \
    [regexp -- {-1} $out] 0
check "format_json: session sentinel becomes null" \
    [regexp -- {"uuid":"s1".*?"cost_usd":null} $out] 1
check "format_json: subagent sentinel becomes null" \
    [regexp -- {"agent_id":"a1".*?"cost_usd":null} $out] 1
check "format_json: real figure passes through" \
    [regexp -- {"uuid":"s2".*?"cost_usd":0.4216} $out] 1
check "format_json: blank human time becomes null" \
    [regexp -- {"uuid":"s1".*?"human_secs":null} $out] 1
check "format_json: blank subagent duration becomes null" \
    [regexp -- {"agent_id":"a1".*?"duration_secs":null} $out] 1
check "format_json: human time figure passes through" \
    [regexp -- {"uuid":"s2".*?"human_secs":120} $out] 1
check "format_json: output is valid JSON" \
    [expr {![catch {::json::json2dict $out}]}] 1

if {$failures == 0} {
    puts "\nAll tests passed."
} else {
    puts "\n$failures test(s) failed."
    exit 1
}
