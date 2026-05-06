#!/usr/bin/env tclsh9.0
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT lib jsonl.tcl]
# extract_blocks calls ::csm::search::format_tool_use; source search.tcl
# so the dependency resolves at runtime.
source [file join $ROOT lib search.tcl]

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

# extract_blocks: walks a record into typed {btype content} pairs.
set user_tool_result [::csm::jsonl::parse_line {{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"README.md\ncsm\nlib"}]}}}]
set assist_tool_use  [::csm::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls /tmp","description":"list"}}]}}}]
set assist_mixed     [::csm::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"text","text":"first"},{"type":"tool_use","name":"Read","input":{"file_path":"/etc/hosts"}},{"type":"text","text":"second"}]}}}]
set sys_metadata     [::csm::jsonl::parse_line {{"type":"system","subtype":"turn_duration","durationMs":1000}}]
set attachment       [::csm::jsonl::parse_line {{"type":"attachment","data":"…"}}]
set tool_result_arr  [::csm::jsonl::parse_line {{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"tool_reference","tool_name":"WebSearch"},{"type":"tool_reference","tool_name":"WebFetch"}]}]}}}]

check blocks_user_string {user {hello world}}                  [::csm::jsonl::extract_blocks $user_str]
check blocks_user_tool_result {tool_result {README.md
csm
lib}}                                                          [::csm::jsonl::extract_blocks $user_tool_result]
check blocks_assistant_tool_use {tool_use {Bash(command=ls /tmp, description=list)}} \
    [::csm::jsonl::extract_blocks $assist_tool_use]
check blocks_assistant_mixed {assistant first tool_use Read(file_path=/etc/hosts) assistant second} \
    [::csm::jsonl::extract_blocks $assist_mixed]
check blocks_system_with_content {system misc}                 [::csm::jsonl::extract_blocks $sys_other]
check blocks_system_metadata_empty {}                           [::csm::jsonl::extract_blocks $sys_metadata]
check blocks_last_prompt {user resume?}                         [::csm::jsonl::extract_blocks $lp]
check blocks_queue_op {system x}                                [::csm::jsonl::extract_blocks $qop]
check blocks_attachment_empty {}                                [::csm::jsonl::extract_blocks $attachment]
check blocks_tool_result_array {tool_result {WebSearch WebFetch}} \
    [::csm::jsonl::extract_blocks $tool_result_arr]

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
