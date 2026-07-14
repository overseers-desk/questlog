#!/usr/bin/env tclsh9.0
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT config.tcl]
source [file join $ROOT lib jsonl.tcl]
# extract_blocks/leaf_record_hit live in ::questlog::match, which reads the
# display caps from ::questlog::config; source it and inject the caps the way the
# launcher does.
source [file join $ROOT lib match.tcl]
::questlog::match::set_caps [dict create \
    content_cap     [::questlog::config::get content_cap] \
    snippet_lead    [::questlog::config::get snippet_lead] \
    snippet_trail   [::questlog::config::get snippet_trail] \
    tool_param_cap  [::questlog::config::get tool_param_cap] \
    tool_render_cap [::questlog::config::get tool_render_cap]]

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
set user_str [::questlog::jsonl::parse_line {{"type":"user","message":{"content":"hello world"}}}]
set user_arr [::questlog::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"text","text":"first"},{"type":"tool_use","name":"Bash"},{"type":"text","text":"second"}]}}}]
set qop      [::questlog::jsonl::parse_line {{"type":"queue-operation","content":"x"}}]
set lp       [::questlog::jsonl::parse_line {{"type":"last-prompt","lastPrompt":"resume?"}}]
set comp     [::questlog::jsonl::parse_line {{"type":"system","subtype":"compact_boundary","content":"Conversation compacted"}}]
set sys_other [::questlog::jsonl::parse_line {{"type":"system","content":"misc"}}]

check extract_user_string         "hello world" [::questlog::jsonl::extract_text $user_str]
check extract_assistant_array     "first\nBash()\nsecond" [::questlog::jsonl::extract_text $user_arr]
check extract_queue_op            "x"    [::questlog::jsonl::extract_text $qop]
check extract_last_prompt         "resume?" [::questlog::jsonl::extract_text $lp]
check extract_system              "Conversation compacted" [::questlog::jsonl::extract_text $comp]

# New extractor behaviours: tool_use, thinking, image, tool_result.is_error.
set assist_tool_use_only_full [::questlog::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls -la"}}]}}}]
set assist_text_plus_tool     [::questlog::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"text","text":"ok"},{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}}]
set assist_thinking           [::questlog::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"pondering"}]}}}]
set assist_redacted_thinking  [::questlog::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"redacted_thinking"}]}}}]
set user_image                [::questlog::jsonl::parse_line {{"type":"user","message":{"content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}}}]
set tool_result_error         [::questlog::jsonl::parse_line {{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"oops"}]}}}]
set tool_result_image         [::questlog::jsonl::parse_line {{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}]}}}]

check extract_tool_use_only_full   "Bash(command=ls -la)"      [::questlog::jsonl::extract_text $assist_tool_use_only_full]
check extract_text_plus_tool_use   "ok\nBash(command=ls)"      [::questlog::jsonl::extract_text $assist_text_plus_tool]
check extract_thinking             "\[thinking\] pondering"    [::questlog::jsonl::extract_text $assist_thinking]
check extract_redacted_thinking    "\[redacted thinking\]"     [::questlog::jsonl::extract_text $assist_redacted_thinking]
check extract_user_image           "\[image\]"                  [::questlog::jsonl::extract_text $user_image]
check extract_tool_result_error    "ERROR: oops"               [::questlog::jsonl::extract_text $tool_result_error]
check extract_tool_result_image    "\[image\]"                  [::questlog::jsonl::extract_text $tool_result_image]

check is_compact_yes              1     [::questlog::jsonl::is_compact_boundary $comp]
check is_compact_no_other_system  0     [::questlog::jsonl::is_compact_boundary $sys_other]
check is_compact_no_user          0     [::questlog::jsonl::is_compact_boundary $user_str]

# extract_blocks: walks a record into typed {btype content} pairs.
set user_tool_result [::questlog::jsonl::parse_line {{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"README.md\nquestlog\nlib"}]}}}]
set assist_tool_use  [::questlog::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls /tmp","description":"list"}}]}}}]
set assist_mixed     [::questlog::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"text","text":"first"},{"type":"tool_use","name":"Read","input":{"file_path":"/etc/hosts"}},{"type":"text","text":"second"}]}}}]
set sys_metadata     [::questlog::jsonl::parse_line {{"type":"system","subtype":"turn_duration","durationMs":1000}}]
set attachment       [::questlog::jsonl::parse_line {{"type":"attachment","data":"…"}}]
set tool_result_arr  [::questlog::jsonl::parse_line {{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"tool_reference","tool_name":"WebSearch"},{"type":"tool_reference","tool_name":"WebFetch"}]}]}}}]

check blocks_user_string {user {hello world}}                  [::questlog::jsonl::extract_blocks $user_str]
check blocks_user_tool_result {tool_result {README.md
questlog
lib}}                                                          [::questlog::jsonl::extract_blocks $user_tool_result]
check blocks_assistant_tool_use {tool_use {Bash(command=ls /tmp, description=list)}} \
    [::questlog::jsonl::extract_blocks $assist_tool_use]
check blocks_assistant_mixed {assistant first tool_use Read(file_path=/etc/hosts) assistant second} \
    [::questlog::jsonl::extract_blocks $assist_mixed]
check blocks_system_with_content {system misc}                 [::questlog::jsonl::extract_blocks $sys_other]
check blocks_system_metadata_empty {}                           [::questlog::jsonl::extract_blocks $sys_metadata]
check blocks_last_prompt {user resume?}                         [::questlog::jsonl::extract_blocks $lp]
check blocks_queue_op {system x}                                [::questlog::jsonl::extract_blocks $qop]
check blocks_attachment_empty {}                                [::questlog::jsonl::extract_blocks $attachment]
check blocks_tool_result_array {tool_result {WebSearch WebFetch}} \
    [::questlog::jsonl::extract_blocks $tool_result_arr]

# New extract_blocks behaviours: uncapped tool_use renderer, thinking, image.
check blocks_assistant_tool_use_full {tool_use {Bash(command=ls -la)}} \
    [::questlog::jsonl::extract_blocks $assist_tool_use_only_full]
check blocks_assistant_thinking {thinking pondering} \
    [::questlog::jsonl::extract_blocks $assist_thinking]
check blocks_assistant_image {image {[image]}} \
    [::questlog::jsonl::extract_blocks [::questlog::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}}}]]
check blocks_user_image {image {[image]}} \
    [::questlog::jsonl::extract_blocks $user_image]

# record_tool_uses: structural tool/path extraction for read/write/edit
# criteria. Assert name:path pairs; the rendered string is exercised by
# the extract_blocks tests above. NotebookEdit carries notebook_path.
proc np {rec} {
    set out [list]
    foreach t [::questlog::jsonl::record_tool_uses $rec] {
        lappend out "[dict get $t name]:[dict get $t path]"
    }
    return $out
}
set r_edit  [::questlog::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"replace_all":false,"file_path":"/a/b.tcl","old_string":"x","new_string":"y"}}]}}}]
set r_multi [::questlog::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"MultiEdit","input":{"file_path":"/a/c.tcl","edits":[]}}]}}}]
set r_nb    [::questlog::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"NotebookEdit","input":{"notebook_path":"/a/n.ipynb","new_source":"z"}}]}}}]
set r_write [::questlog::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/a/w.tcl","content":"c"}}]}}}]
set r_read  [::questlog::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a/r.tcl"}}]}}}]
set r_mixed [::questlog::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"text","text":"first"},{"type":"tool_use","name":"Edit","input":{"file_path":"/a/b.tcl","old_string":"x","new_string":"y"}},{"type":"tool_use","name":"Read","input":{"file_path":"/a/r.tcl"}},{"type":"text","text":"second"}]}}}]

check tools_edit         {Edit:/a/b.tcl}            [np $r_edit]
check tools_multiedit    {MultiEdit:/a/c.tcl}       [np $r_multi]
check tools_notebookedit {NotebookEdit:/a/n.ipynb}  [np $r_nb]
check tools_write        {Write:/a/w.tcl}           [np $r_write]
check tools_read         {Read:/a/r.tcl}            [np $r_read]
check tools_mixed        {Edit:/a/b.tcl Read:/a/r.tcl} [np $r_mixed]
check tools_user_empty   {}                         [np $user_str]

# leaf_record_hit: per-record evidence for one leaf clause. sat tells whether the
# leaf matches the record; nh counts the snippets it would contribute. Leaves are
# built with the match-layer constructors - the one home for the leaf shape - so
# these tests pin the same dicts the CLI and GUI builders produce. nocase 1
# throughout (keyword case is exercised elsewhere).
proc sat {leaf rec} { return [dict get [::questlog::match::leaf_record_hit $leaf $rec 1] sat] }
proc nh  {leaf rec} { return [llength [dict get [::questlog::match::leaf_record_hit $leaf $rec 1] hits]] }
proc kw  {needle {regions {}}} { return [::questlog::match::kw_leaf $needle $regions 0] }
proc rx  {needle {regions {}}} { return [::questlog::match::rx_leaf $needle $regions 0] }
proc fl  {op path}  { return [::questlog::match::tool_leaf file $op $path 0] }
proc tl  {name key} { return [::questlog::match::tool_leaf tool $name $key 0] }

check hits_regex_first   1 [sat [rx first] $r_mixed]
check hits_file_read     1 [sat [fl read /a/r.tcl] $r_mixed]
check hits_file_wrote    1 [sat [fl wrote /a/b.tcl] $r_mixed]
check hits_file_edit     1 [sat [fl wrote /a/b.tcl] $r_edit]
check hits_wrote_not_read 0 [sat [fl wrote /a/r.tcl] $r_read]

# `either` spans read and write; `wrote` is created-or-edited (Write + Edit +
# MultiEdit + NotebookEdit); the finer CLI ops `write` and `edit` each match
# only their own tools.
check hits_either_read    1 [sat [fl either /a/r.tcl] $r_read]
check hits_either_edit    1 [sat [fl either /a/b.tcl] $r_edit]
check hits_write_not_edit 0 [sat [fl write /a/b.tcl] $r_edit]
check hits_edit_not_write 0 [sat [fl edit /a/w.tcl] $r_write]

# tool values match by tool name; an empty key means any use, a non-empty key
# is a substring of the invocation text - which catches a Bash redirect target.
set r_grep [::questlog::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Grep","input":{"pattern":"NEEDLE","path":"/a"}}]}}}]
set r_bashredir [::questlog::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"python gen.py > sub/out.json"}}]}}}]
check hits_tool_any        1 [sat [tl Grep {}] $r_grep]
check hits_tool_key        1 [sat [tl Grep NEEDLE] $r_grep]
check hits_tool_key_miss   0 [sat [tl Grep ZZZ] $r_grep]
check hits_tool_redirect   1 [sat [tl Bash out.json] $r_bashredir]
check hits_tool_wrong_name 0 [sat [tl Bash NEEDLE] $r_grep]

# File paths match from the right: a bare or partial filename matches the file in
# any directory; a fragment that is not a tail does not (ends-with, not contains).
set r_spar [::questlog::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/a/spar-manager.spar-dispatcher-initcmd.tcl","old_string":"x","new_string":"y"}}]}}}]
check hits_tail_basename    1 [sat [fl wrote b.tcl] $r_edit]
check hits_partial_basename 1 [sat [fl wrote spar-dispatcher-initcmd.tcl] $r_spar]
check hits_not_substring    0 [sat [fl wrote spar-manager] $r_spar]

# A region set on a keyword or regex leaf gates which block types it matches
# (empty = anywhere). Unlike the old scope, a regex now honours its regions too:
# alpha is found anywhere but not when the leaf is scoped to tool_use.
set r_scope [::questlog::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"text","text":"alpha says hello"},{"type":"tool_use","name":"Bash","input":{"command":"echo bravo"}}]}}}]
check region_text_in_text     1 [sat [kw alpha {user assistant}] $r_scope]
check region_text_not_use     0 [sat [kw alpha {tool_use}] $r_scope]
check region_use_in_use       1 [sat [kw bravo {tool_use}] $r_scope]
check region_use_not_text     0 [sat [kw bravo {user assistant}] $r_scope]
check region_result_in_result 1 [sat [kw questlog {tool_result}] $user_tool_result]
check region_result_not_text  0 [sat [kw questlog {user assistant}] $user_tool_result]
check region_regex_any        1 [sat [rx alpha {}] $r_scope]
check region_regex_scoped_out 0 [sat [rx alpha {tool_use}] $r_scope]

# ---- is_user_turn: the turn-count predicate over raw lines -----------------
# String content counts; a block-array prompt (text or image first) counts; a
# tool_result record - also role:user, array content - does not; the harness
# echoes the user never typed do not.
check turn_string 1 [::questlog::jsonl::is_user_turn \
    {{"type":"user","message":{"role":"user","content":"do the thing"},"timestamp":"t"}}]
check turn_array_text 1 [::questlog::jsonl::is_user_turn \
    {{"type":"user","message":{"role":"user","content":[{"type":"text","text":"see this"},{"type":"image","source":{}}]}}}]
check turn_array_image 1 [::questlog::jsonl::is_user_turn \
    {{"type":"user","message":{"role":"user","content":[{"type":"image","source":{}},{"type":"text","text":"caption"}]}}}]
check turn_tool_result 0 [::questlog::jsonl::is_user_turn \
    {{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"ok"}]}}}]
check turn_command_echo 0 [::questlog::jsonl::is_user_turn \
    {{"type":"user","message":{"role":"user","content":"<command-name>/foo</command-name>"}}}]
check turn_task_note 0 [::questlog::jsonl::is_user_turn \
    {{"type":"user","message":{"role":"user","content":"<task-notification>done</task-notification>"}}}]

# ---- record_role_label: the speaker heading for viewer and export ----------
# A typed prompt (string or block-array) is USER; a tool_result record - also
# role:user - is TOOL RESULT, not USER; assistant is ASSISTANT; anything else
# is SYSTEM. Takes a parsed record, so route each line through parse_line.
check label_string "USER" [::questlog::jsonl::record_role_label \
    [::questlog::jsonl::parse_line \
    {{"type":"user","message":{"role":"user","content":"do the thing"}}}]]
check label_array_text "USER" [::questlog::jsonl::record_role_label \
    [::questlog::jsonl::parse_line \
    {{"type":"user","message":{"role":"user","content":[{"type":"text","text":"see this"}]}}}]]
check label_tool_result "TOOL RESULT" [::questlog::jsonl::record_role_label \
    [::questlog::jsonl::parse_line \
    {{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"ok"}]}}}]]
check label_assistant "ASSISTANT" [::questlog::jsonl::record_role_label \
    [::questlog::jsonl::parse_line \
    {{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}}]]
check label_system "SYSTEM" [::questlog::jsonl::record_role_label \
    [::questlog::jsonl::parse_line \
    {{"type":"system","content":"Conversation compacted"}}]]

# ---- record_model: the model id an assistant record chips with -------------
# An assistant record returns its message.model; a <synthetic> filler, a
# sidechain (subagent) record and any non-assistant record return "", so none
# of them chips in the viewer. Takes a parsed record, so route through parse_line.
check model_assistant "claude-opus-4-8" [::questlog::jsonl::record_model \
    [::questlog::jsonl::parse_line \
    {{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-8","content":[{"type":"text","text":"hi"}]}}}]]
check model_synthetic "" [::questlog::jsonl::record_model \
    [::questlog::jsonl::parse_line \
    {{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"No response requested."}]}}}]]
check model_sidechain "" [::questlog::jsonl::record_model \
    [::questlog::jsonl::parse_line \
    {{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-4-5","content":[{"type":"text","text":"sub"}]}}}]]
check model_user "" [::questlog::jsonl::record_model \
    [::questlog::jsonl::parse_line \
    {{"type":"user","message":{"role":"user","content":"do the thing"}}}]]

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
