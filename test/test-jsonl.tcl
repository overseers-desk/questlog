#!/usr/bin/env tclsh9.0
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT lib jsonl.tcl]
# extract_blocks calls ::fms::search::format_tool_use; source search.tcl
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
set user_str [::fms::jsonl::parse_line {{"type":"user","message":{"content":"hello world"}}}]
set user_arr [::fms::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"text","text":"first"},{"type":"tool_use","name":"Bash"},{"type":"text","text":"second"}]}}}]
set qop      [::fms::jsonl::parse_line {{"type":"queue-operation","content":"x"}}]
set lp       [::fms::jsonl::parse_line {{"type":"last-prompt","lastPrompt":"resume?"}}]
set comp     [::fms::jsonl::parse_line {{"type":"system","subtype":"compact_boundary","content":"Conversation compacted"}}]
set sys_other [::fms::jsonl::parse_line {{"type":"system","content":"misc"}}]

check extract_user_string         "hello world" [::fms::jsonl::extract_text $user_str]
check extract_assistant_array     "first\nsecond" [::fms::jsonl::extract_text $user_arr]
check extract_queue_op            "x"    [::fms::jsonl::extract_text $qop]
check extract_last_prompt         "resume?" [::fms::jsonl::extract_text $lp]
check extract_system              "Conversation compacted" [::fms::jsonl::extract_text $comp]

check is_compact_yes              1     [::fms::jsonl::is_compact_boundary $comp]
check is_compact_no_other_system  0     [::fms::jsonl::is_compact_boundary $sys_other]
check is_compact_no_user          0     [::fms::jsonl::is_compact_boundary $user_str]

# extract_blocks: walks a record into typed {btype content} pairs.
set user_tool_result [::fms::jsonl::parse_line {{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"README.md\nfms\nlib"}]}}}]
set assist_tool_use  [::fms::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls /tmp","description":"list"}}]}}}]
set assist_mixed     [::fms::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"text","text":"first"},{"type":"tool_use","name":"Read","input":{"file_path":"/etc/hosts"}},{"type":"text","text":"second"}]}}}]
set sys_metadata     [::fms::jsonl::parse_line {{"type":"system","subtype":"turn_duration","durationMs":1000}}]
set attachment       [::fms::jsonl::parse_line {{"type":"attachment","data":"…"}}]
set tool_result_arr  [::fms::jsonl::parse_line {{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"tool_reference","tool_name":"WebSearch"},{"type":"tool_reference","tool_name":"WebFetch"}]}]}}}]

check blocks_user_string {user {hello world}}                  [::fms::jsonl::extract_blocks $user_str]
check blocks_user_tool_result {tool_result {README.md
fms
lib}}                                                          [::fms::jsonl::extract_blocks $user_tool_result]
check blocks_assistant_tool_use {tool_use {Bash(command=ls /tmp, description=list)}} \
    [::fms::jsonl::extract_blocks $assist_tool_use]
check blocks_assistant_mixed {assistant first tool_use Read(file_path=/etc/hosts) assistant second} \
    [::fms::jsonl::extract_blocks $assist_mixed]
check blocks_system_with_content {system misc}                 [::fms::jsonl::extract_blocks $sys_other]
check blocks_system_metadata_empty {}                           [::fms::jsonl::extract_blocks $sys_metadata]
check blocks_last_prompt {user resume?}                         [::fms::jsonl::extract_blocks $lp]
check blocks_queue_op {system x}                                [::fms::jsonl::extract_blocks $qop]
check blocks_attachment_empty {}                                [::fms::jsonl::extract_blocks $attachment]
check blocks_tool_result_array {tool_result {WebSearch WebFetch}} \
    [::fms::jsonl::extract_blocks $tool_result_arr]

# record_tool_uses: structural tool/path extraction for read/write/edit
# criteria. Assert name:path pairs; the rendered string is exercised by
# the extract_blocks tests above. NotebookEdit carries notebook_path.
proc np {rec} {
    set out [list]
    foreach t [::fms::jsonl::record_tool_uses $rec] {
        lappend out "[dict get $t name]:[dict get $t path]"
    }
    return $out
}
set r_edit  [::fms::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"replace_all":false,"file_path":"/a/b.tcl","old_string":"x","new_string":"y"}}]}}}]
set r_multi [::fms::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"MultiEdit","input":{"file_path":"/a/c.tcl","edits":[]}}]}}}]
set r_nb    [::fms::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"NotebookEdit","input":{"notebook_path":"/a/n.ipynb","new_source":"z"}}]}}}]
set r_write [::fms::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/a/w.tcl","content":"c"}}]}}}]
set r_read  [::fms::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a/r.tcl"}}]}}}]
set r_mixed [::fms::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"text","text":"first"},{"type":"tool_use","name":"Edit","input":{"file_path":"/a/b.tcl","old_string":"x","new_string":"y"}},{"type":"tool_use","name":"Read","input":{"file_path":"/a/r.tcl"}},{"type":"text","text":"second"}]}}}]

check tools_edit         {Edit:/a/b.tcl}            [np $r_edit]
check tools_multiedit    {MultiEdit:/a/c.tcl}       [np $r_multi]
check tools_notebookedit {NotebookEdit:/a/n.ipynb}  [np $r_nb]
check tools_write        {Write:/a/w.tcl}           [np $r_write]
check tools_read         {Read:/a/r.tcl}            [np $r_read]
check tools_mixed        {Edit:/a/b.tcl Read:/a/r.tcl} [np $r_mixed]
check tools_user_empty   {}                         [np $user_str]

# record_hits: per-record evidence for AND-scope criteria. Assert
# idx:btype, the part the session-scope conjunction turns on.
proc ib {rec criteria re_opts} {
    set out [list]
    foreach h [::fms::search::record_hits $rec $criteria $re_opts] {
        lassign $h idx btype content
        lappend out "$idx:$btype"
    }
    return $out
}
set crit [list \
    {type edit value /a/b.tcl} \
    {type read value /a/r.tcl} \
    {type read value /a/b.tcl} \
    {type regex value first}]
check hits_mixed         {0:tool_use 1:tool_use 3:assistant} [ib $r_mixed $crit -nocase]
check hits_edit_only     {0:tool_use} [ib $r_edit [list {type edit value /a/b.tcl}] -nocase]
check hits_read_not_edit {}           [ib $r_read [list {type edit value /a/r.tcl}] -nocase]

# Path criteria match by path suffix: a bare or partial filename matches
# the file in any directory; a non-suffix fragment does not (ends-with,
# not contains).
set r_spar [::fms::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/a/spar-manager.spar-dispatcher-initcmd.tcl","old_string":"x","new_string":"y"}}]}}}]
check hits_suffix_basename  {0:tool_use} [ib $r_edit [list {type edit value b.tcl}] -nocase]
check hits_partial_basename {0:tool_use} [ib $r_spar [list {type edit value spar-dispatcher-initcmd.tcl}] -nocase]
check hits_not_substring    {}           [ib $r_spar [list {type edit value spar-manager}] -nocase]

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
