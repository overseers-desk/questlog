#!/usr/bin/env tclsh9.0
# Unit tests for the `questlog show` headless transcript: the emitter's record-
# number anchors (off for the GUI, on for the CLI) and the show subcommand's
# path-or-uuid resolution. The emitter (::questlog::markdown::export_session) is
# the same one the GUI copy/export-markdown actions use, so these also guard that
# shared renderer. Headless, no Tk. Run:
#   tclsh9.0 test/test-cli-show.tcl
package require Tcl 9

set ROOT [file dirname [file dirname [file normalize [info script]]]]
set ::questlog_config_only 1; source [file join $ROOT questlog]
source [file join $ROOT lib path.tcl]
package require logman
source [file join $ROOT lib match.tcl]
source [file join $ROOT lib markdown.tcl]
source [file join $ROOT cli main.tcl]
# format_tool_use_full reads no caps, but inject them the way the launcher does
# so the test exercises the same configured matcher the app runs with.
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

# ---- the transcript and its anchors ---------------------------------------

# Four physical lines: two text turns, a compaction boundary, one text turn.
# No timestamps, so no idle-gap divider fires; the only divider is the compact
# boundary, on line 3, which carries no record number.
set fixture [join {
    {{"type":"user","message":{"content":"hello"}}}
    {{"type":"assistant","message":{"content":[{"type":"text","text":"hi there"}]}}}
    {{"type":"system","subtype":"compact_boundary"}}
    {{"type":"assistant","message":{"content":[{"type":"text","text":"after compact"}]}}}
} "\n"]
set f [file join /tmp questlog-show-[pid].jsonl]
write_file $f $fixture

set plain [join {
    "**USER**\n\nhello"
    "**ASSISTANT**\n\nhi there"
    "## --- /compact ---"
    "**ASSISTANT**\n\nafter compact"
} "\n\n"]
check "export_session: anchors off is the clean transcript" \
    [::questlog::markdown::export_session $f 0] $plain
check "export_session: default is anchors off" \
    [::questlog::markdown::export_session $f] $plain

set anchored [join {
    "**\[#1] USER**\n\nhello"
    "**\[#2] ASSISTANT**\n\nhi there"
    "## --- /compact ---"
    "**\[#4] ASSISTANT**\n\nafter compact"
} "\n\n"]
check "export_session: anchors on prefix turns with their record number" \
    [::questlog::markdown::export_session $f 1] $anchored

# Tool activity folds inline (the viewer's behaviour); the rendered call names
# its tool, so a show consumer sees it rather than a silent drop.
set toolfix [file join /tmp questlog-show-tool-[pid].jsonl]
write_file $toolfix \
    {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}}
check "export_session: a tool_use turn folds the call inline" \
    [string match {*Bash*} [::questlog::markdown::export_session $toolfix]] 1

# ---- show's identifier resolution -----------------------------------------

check "resolve_session: an existing file path is taken as-is" \
    [::questlog::cli::main::resolve_session $f] $f

# A bare uuid resolves against the projects store. Override projects_root to a
# temp tree (the test-scan idiom) and build it through _real_file, since
# lib/path.tcl guards file mkdir/delete outside its own namespace.
set proot /tmp/questlog-show-projects
::questlog::path::_real_file delete -force $proot
proc ::questlog::path::projects_root {} { return /tmp/questlog-show-projects }
set uuid 11111111-2222-3333-4444-555555555555
set sessdir [file join $proot -home-user-proj]
::questlog::path::_real_file mkdir $sessdir
set sesspath [file join $sessdir $uuid.jsonl]
write_file $sesspath $fixture
check "resolve_session: a bare uuid resolves to its session file" \
    [::questlog::cli::main::resolve_session $uuid] $sesspath

::questlog::path::_real_file delete -force $f $toolfix $proot

if {$failures == 0} {
    puts "\nAll tests passed."
} else {
    puts "\n$failures test(s) failed."
    exit 1
}
