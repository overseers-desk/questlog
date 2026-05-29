#!/usr/bin/env tclsh9.0
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT lib jsonl.tcl]
# extract_blocks calls ::questlog::search::format_tool_use; source search.tcl
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
set user_tool_result [::questlog::jsonl::parse_line {{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"README.md\nfms\nlib"}]}}}]
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
# current dict contract (pat_hit, read_hit, wrote_hit, edited_hit booleans).
# hit_flags returns a list of the set boolean keys for compact assertions.
# mk_clauses builds a clauses dict with all required keys defaulted.
proc hit_flags {result} {
    set out [list]
    foreach k {pat_hit read_hit wrote_hit edited_hit} {
        if {[dict get $result $k]} { lappend out $k }
    }
    return $out
}
proc mk_clauses {args} {
    set c [dict create terms {} nocase 1 patterns {} \
        paths_read {} paths_wrote {} paths_edited {}]
    foreach {k v} $args { dict set c $k $v }
    return $c
}

check hits_mixed        {pat_hit read_hit edited_hit} \
    [hit_flags [::questlog::search::record_hits $r_mixed \
        [mk_clauses patterns {first} paths_read {/a/r.tcl /a/b.tcl} paths_edited {/a/b.tcl}]]]
check hits_edit_only    {edited_hit} \
    [hit_flags [::questlog::search::record_hits $r_edit \
        [mk_clauses paths_edited {/a/b.tcl}]]]
check hits_read_not_edit {} \
    [hit_flags [::questlog::search::record_hits $r_read \
        [mk_clauses paths_edited {/a/r.tcl}]]]

# Path criteria match by path suffix: a bare or partial filename matches
# the file in any directory; a non-suffix fragment does not (ends-with,
# not contains).
set r_spar [::questlog::jsonl::parse_line {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/a/spar-manager.spar-dispatcher-initcmd.tcl","old_string":"x","new_string":"y"}}]}}}]
check hits_suffix_basename  {edited_hit} \
    [hit_flags [::questlog::search::record_hits $r_edit \
        [mk_clauses paths_edited {b.tcl}]]]
check hits_partial_basename {edited_hit} \
    [hit_flags [::questlog::search::record_hits $r_spar \
        [mk_clauses paths_edited {spar-dispatcher-initcmd.tcl}]]]
check hits_not_substring    {} \
    [hit_flags [::questlog::search::record_hits $r_spar \
        [mk_clauses paths_edited {spar-manager}]]]

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
