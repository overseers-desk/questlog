#!/usr/bin/env tclsh9.0
# Unit tests for ::logman::context_window - the grep-style before/after
# reader (-A/-B/-C) that pulls the reading-view turns around a search hit. It is
# built from the same parse_line/record_role_label/extract_text primitives as the
# whole-session markdown export, so these also guard that a windowed turn reads
# the way `questlog show` renders it. Headless, no Tk. Run:
#   tclsh9.0 test/test-context-window.tcl
package require Tcl 9

set ROOT [file dirname [file dirname [file normalize [info script]]]]
set ::questlog_config_only 1; source [file join $ROOT questlog]
package require logman
source [file join $ROOT lib match.tcl]
# extract_text renders tool_use blocks through format_tool_use_full, which reads
# the display caps; inject them the way the launcher does.
::questlog::match::set_caps [dict create \
    content_cap     [::questlog::config::get content_cap] \
    snippet_lead    [::questlog::config::get snippet_lead] \
    snippet_trail   [::questlog::config::get snippet_trail] \
    tool_param_cap  [::questlog::config::get tool_param_cap] \
    tool_render_cap [::questlog::config::get tool_render_cap]]

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

proc write_file {path text} {
    set fh [open $path w]
    chan configure $fh -encoding utf-8
    puts -nonewline $fh $text
    close $fh
}

# A window projected to "line:role:match" tokens, the identity of each turn.
proc winproj {turns} {
    set parts [list]
    foreach t $turns {
        lappend parts "[dict get $t line]:[dict get $t role]:[dict get $t match]"
    }
    return [join $parts " "]
}

# Eight physical lines. Line 3 is blank and line 4/7 are file-history snapshots
# (empty body): both are counted in the physical line number but skipped as
# context, so the renderable neighbours of the line-5 hit are lines 1, 2, 6, 8.
set fixture [join {
    {{"type":"user","message":{"content":"first"}}}
    {{"type":"assistant","message":{"content":[{"type":"text","text":"second"}]}}}
    {}
    {{"type":"file-history-snapshot"}}
    {{"type":"user","message":{"content":"hit here needle"}}}
    {{"type":"assistant","message":{"content":[{"type":"text","text":"sixth"}]}}}
    {{"type":"file-history-snapshot"}}
    {{"type":"user","message":{"content":"eighth"}}}
} "\n"]
set f [file join /tmp questlog-ctx-[pid].jsonl]
write_file $f $fixture

check "window: before/after span renderable neighbours, blanks and empty bodies skipped" \
    [winproj [::logman::context_window $f 5 2 2]] \
    "1:USER:0 2:ASSISTANT:0 5:USER:1 6:ASSISTANT:0 8:USER:0"

check "window: the hit's own record carries match 1 and its full body" \
    [dict get [lindex [::logman::context_window $f 5 1 1] 1] text] \
    "hit here needle"

check "window: before=1/after=1 takes the nearest renderable turn each side" \
    [winproj [::logman::context_window $f 5 1 1]] \
    "2:ASSISTANT:0 5:USER:1 6:ASSISTANT:0"

check "window: after=0 stops at the hit (no trailing turns)" \
    [winproj [::logman::context_window $f 5 2 0]] \
    "1:USER:0 2:ASSISTANT:0 5:USER:1"

check "window: before=0 drops leading turns" \
    [winproj [::logman::context_window $f 5 0 2]] \
    "5:USER:1 6:ASSISTANT:0 8:USER:0"

check "window: a hit on the first line has no before-context" \
    [winproj [::logman::context_window $f 1 2 1]] \
    "1:USER:1 2:ASSISTANT:0"

check "window: a hit on the last line yields fewer after-turns than asked" \
    [winproj [::logman::context_window $f 8 0 3]] \
    "8:USER:1"

check "window: an unreadable file is an empty window, not an error" \
    [::logman::context_window /tmp/questlog-ctx-nonexistent-[pid].jsonl 1 2 2] \
    ""

# --- dialogue windows: the machinery is stripped inside a kept turn ---------
# A hit flanked by an assistant record mixing thinking + prose + a tool call in
# one line, and a tool_result record. Plainly all three turns show and the
# assistant turn carries its thinking and tool-call text; under dialogue the
# tool_result neighbour drops and the assistant turn is reduced to its prose.
set dfix [join {
    {{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"secretthought"},{"type":"text","text":"the prose"},{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}}
    {{"type":"user","message":{"content":"the hit needle"}}}
    {{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"tooloutput"}]}}}
} "\n"]
set df [file join /tmp questlog-ctx-dlg-[pid].jsonl]
write_file $df $dfix

set plainwin [::logman::context_window $df 2 1 1]
check "plain window keeps the tool_result neighbour" \
    [winproj $plainwin] "1:ASSISTANT:0 2:USER:1 3:TOOL RESULT:0"
check "plain window's assistant turn carries the machinery text" \
    [list [string match {*secretthought*} [dict get [lindex $plainwin 0] text]] \
          [string match {*Bash*} [dict get [lindex $plainwin 0] text]]] {1 1}

set dwin [::logman::context_window $df 2 1 1 1]
check "dialogue window drops the tool_result neighbour" \
    [winproj $dwin] "1:ASSISTANT:0 2:USER:1"
check "dialogue window's assistant turn is prose only" \
    [list [dict get [lindex $dwin 0] text] \
          [string match {*secretthought*} [dict get [lindex $dwin 0] text]] \
          [string match {*Bash*} [dict get [lindex $dwin 0] text]]] {{the prose} 0 0}

file delete -force $df $f

if {$failures == 0} {
    puts "\nAll tests passed."
} else {
    puts "\n$failures test(s) failed."
    exit 1
}
