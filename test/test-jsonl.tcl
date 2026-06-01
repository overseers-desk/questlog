#!/usr/bin/env tclsh9.0
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT config.tcl]
source [file join $ROOT lib jsonl.tcl]
# extract_blocks/record_hits live in ::questlog::match, which reads the display
# caps from ::questlog::config; source it and inject the caps the way the
# launcher does.
source [file join $ROOT lib match.tcl]
::questlog::match::set_caps [dict create \
    content_cap     [::questlog::config::get content_cap] \
    snippet_radius  [::questlog::config::get snippet_radius] \
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
check extract_assistant_array     "first\nsecond" [::questlog::jsonl::extract_text $user_arr]
check extract_queue_op            "x"    [::questlog::jsonl::extract_text $qop]
check extract_last_prompt         "resume?" [::questlog::jsonl::extract_text $lp]
check extract_system              "Conversation compacted" [::questlog::jsonl::extract_text $comp]

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

# record_hits: per-record evidence for search criteria. Asserts against the
# dict contract (pat_hit, file_hit, tool_hit booleans). hit_flags returns the
# set boolean keys for compact assertions; nhits counts emitted snippets, for
# the scope tests where the flags are not the subject. mk_clauses builds a
# clauses dict with all required keys defaulted.
proc hit_flags {result} {
    set out [list]
    foreach k {pat_hit file_hit tool_hit} {
        if {[dict get $result $k]} { lappend out $k }
    }
    return $out
}
proc nhits {result} { return [llength [dict get $result hits]] }
proc mk_clauses {args} {
    set c [dict create terms {} nocase 1 patterns {} scope anywhere files {} tools {}]
    foreach {k v} $args { dict set c $k $v }
    return $c
}

check hits_mixed         {pat_hit file_hit} \
    [hit_flags [::questlog::match::record_hits $r_mixed \
        [mk_clauses patterns {first} files {{read /a/r.tcl} {wrote /a/b.tcl}}]]]
check hits_file_edit     {file_hit} \
    [hit_flags [::questlog::match::record_hits $r_edit \
        [mk_clauses files {{wrote /a/b.tcl}}]]]
check hits_wrote_not_read {} \
    [hit_flags [::questlog::match::record_hits $r_read \
        [mk_clauses files {{wrote /a/r.tcl}}]]]

# `either` spans read and write; `wrote` is created-or-edited (Write + Edit +
# MultiEdit + NotebookEdit); the finer CLI ops `write` and `edit` each match
# only their own tools.
check hits_either_read    {file_hit} \
    [hit_flags [::questlog::match::record_hits $r_read \
        [mk_clauses files {{either /a/r.tcl}}]]]
check hits_either_edit    {file_hit} \
    [hit_flags [::questlog::match::record_hits $r_edit \
        [mk_clauses files {{either /a/b.tcl}}]]]
check hits_write_not_edit {} \
    [hit_flags [::questlog::match::record_hits $r_edit \
        [mk_clauses files {{write /a/b.tcl}}]]]
check hits_edit_not_write {} \
    [hit_flags [::questlog::match::record_hits $r_write \
        [mk_clauses files {{edit /a/w.tcl}}]]]

# tool values match by tool name; an empty key means any use, a non-empty key
# is a substring of the invocation text - which catches a Bash redirect target.
set r_grep [::questlog::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Grep","input":{"pattern":"NEEDLE","path":"/a"}}]}}}]
set r_bashredir [::questlog::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"python gen.py > sub/out.json"}}]}}}]
check hits_tool_any        {tool_hit} \
    [hit_flags [::questlog::match::record_hits $r_grep \
        [mk_clauses tools {{Grep {}}}]]]
check hits_tool_key        {tool_hit} \
    [hit_flags [::questlog::match::record_hits $r_grep \
        [mk_clauses tools {{Grep NEEDLE}}]]]
check hits_tool_key_miss   {} \
    [hit_flags [::questlog::match::record_hits $r_grep \
        [mk_clauses tools {{Grep ZZZ}}]]]
check hits_tool_redirect   {tool_hit} \
    [hit_flags [::questlog::match::record_hits $r_bashredir \
        [mk_clauses tools {{Bash out.json}}]]]
check hits_tool_wrong_name {} \
    [hit_flags [::questlog::match::record_hits $r_grep \
        [mk_clauses tools {{Bash NEEDLE}}]]]

# File paths match by suffix: a bare or partial filename matches the file in any
# directory; a non-suffix fragment does not (ends-with, not contains).
set r_spar [::questlog::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/a/spar-manager.spar-dispatcher-initcmd.tcl","old_string":"x","new_string":"y"}}]}}}]
check hits_suffix_basename  {file_hit} \
    [hit_flags [::questlog::match::record_hits $r_edit \
        [mk_clauses files {{wrote b.tcl}}]]]
check hits_partial_basename {file_hit} \
    [hit_flags [::questlog::match::record_hits $r_spar \
        [mk_clauses files {{wrote spar-dispatcher-initcmd.tcl}}]]]
check hits_not_substring    {} \
    [hit_flags [::questlog::match::record_hits $r_spar \
        [mk_clauses files {{wrote spar-manager}}]]]

# Search scope gates the terms (and the snippets they emit) by block type;
# regex stays unscoped because the scope selector belongs to the search box.
set r_scope [::questlog::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"text","text":"alpha says hello"},{"type":"tool_use","name":"Bash","input":{"command":"echo bravo"}}]}}}]
check scope_text_in_text     1 [expr {[nhits [::questlog::match::record_hits $r_scope [mk_clauses terms alpha scope text]]] > 0}]
check scope_text_not_call    0 [expr {[nhits [::questlog::match::record_hits $r_scope [mk_clauses terms alpha scope tool-call]]] > 0}]
check scope_call_in_call     1 [expr {[nhits [::questlog::match::record_hits $r_scope [mk_clauses terms bravo scope tool-call]]] > 0}]
check scope_call_not_text    0 [expr {[nhits [::questlog::match::record_hits $r_scope [mk_clauses terms bravo scope text]]] > 0}]
check scope_output_in_result 1 [expr {[nhits [::questlog::match::record_hits $user_tool_result [mk_clauses terms questlog scope tool-output]]] > 0}]
check scope_output_not_text  0 [expr {[nhits [::questlog::match::record_hits $user_tool_result [mk_clauses terms questlog scope text]]] > 0}]
check scope_regex_unscoped   {pat_hit} \
    [hit_flags [::questlog::match::record_hits $r_scope [mk_clauses patterns alpha scope tool-call]]]

# segment_blockquotes: split a body into ordered {kind text} segments,
# de-quoting one leading "> "/">" per blockquote line, strict blank split.
check seg_plain      {{normal hello}} \
    [::questlog::jsonl::segment_blockquotes "hello"]
check seg_pure_quote {{quote {To: a@b
body}}} \
    [::questlog::jsonl::segment_blockquotes "> To: a@b\n> body"]
check seg_mixed      {{normal intro:} {quote {line one
line two}} {normal outro}} \
    [::questlog::jsonl::segment_blockquotes "intro:\n> line one\n> line two\noutro"]
check seg_bare_gt    {{quote {has space
no space}}} \
    [::questlog::jsonl::segment_blockquotes "> has space\n>no space"]
check seg_blank_split {{quote first} {normal {}} {quote second}} \
    [::questlog::jsonl::segment_blockquotes "> first\n\n> second"]

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
