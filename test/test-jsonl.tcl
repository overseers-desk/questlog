#!/usr/bin/env tclsh9.0
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT lib jsonl.tcl]

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name"
        puts "  expected: <$expected>"
        puts "  actual:   <$actual>"
        incr ::fails
    } else {
        puts "ok:   $name"
    }
}

# Build records the way ::json::json2dict would (already done by parse_line).
set user_str [::csm::jsonl::parse_line {{"type":"user","message":{"content":"hello world"}}}]
set user_arr [::csm::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"text","text":"first"},{"type":"tool_use","name":"Bash"},{"type":"text","text":"second"}]}}}]
set qop      [::csm::jsonl::parse_line {{"type":"queue-operation","content":"x"}}]
set lp       [::csm::jsonl::parse_line {{"type":"last-prompt","lastPrompt":"resume?"}}]
set comp     [::csm::jsonl::parse_line {{"type":"system","subtype":"compact_boundary","content":"Conversation compacted"}}]
set sys_other [::csm::jsonl::parse_line {{"type":"system","content":"misc"}}]

check extract_user_string         "hello world" [::csm::jsonl::extract_text $user_str]
check extract_assistant_array     "first\nsecond" [::csm::jsonl::extract_text $user_arr]
check extract_queue_op            "x"    [::csm::jsonl::extract_text $qop]
check extract_last_prompt         "resume?" [::csm::jsonl::extract_text $lp]
check extract_system              "Conversation compacted" [::csm::jsonl::extract_text $comp]

check is_compact_yes              1     [::csm::jsonl::is_compact_boundary $comp]
check is_compact_no_other_system  0     [::csm::jsonl::is_compact_boundary $sys_other]
check is_compact_no_user          0     [::csm::jsonl::is_compact_boundary $user_str]

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
