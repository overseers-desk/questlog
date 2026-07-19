#!/usr/bin/env tclsh9.0
# Tests for coachman::tool_use_counts: the post-hoc tool_use audit over
# a session's transcripts, counting by tool name and by a named tool's
# input field, across the parent and its subagent transcripts. Run:
#   tclsh9.0 test/test-coachman-audit.tcl
package require Tcl 9
package require json

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require coachman

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

# Fixture: a parent transcript with two Skill calls (linkedin twice) and
# a Bash call, plus a subagent transcript beside it with one Skill call
# (facebook). A non-tool line and a half-written line ride along so the
# prefilter and the parse guard both see traffic.
set dir [file tempdir]
set root [file join $dir transcripts]
set proj [file join $root proj-x]
file mkdir $proj
set fd [open [file join $proj sid-a.jsonl] w]
puts $fd {{"type":"user","message":{"role":"user","content":"go"}}}
puts $fd {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"linkedin"}}]}}}
puts $fd {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}},{"type":"tool_use","name":"Skill","input":{"skill":"linkedin"}}]}}}
puts -nonewline $fd "\{\"type\":\"assistant\",\"half"
close $fd
set subdir [file join $proj sid-a subagents]
file mkdir $subdir
set fd [open [file join $subdir agent-1.jsonl] w]
puts $fd {{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"facebook"}}]}}}
close $fd

set by_name [coachman::tool_use_counts sid-a $root]
check "counts by name span parent and subagents" \
    [lsort -stride 2 $by_name] {Bash 1 Skill 3}

set by_skill [coachman::tool_use_counts sid-a $root Skill skill]
check "a named tool counts by the chosen input field" \
    [lsort -stride 2 $by_skill] {facebook 1 linkedin 2}
check "an uninvoked value reads as absent, not zero" \
    [dict exists $by_skill youtube] 0

check "a named tool alone counts under its own name" \
    [coachman::tool_use_counts sid-a $root Bash] {Bash 1}

set code [catch {coachman::tool_use_counts sid-none $root} msg opts]
check "a missing transcript raises" $code 1
check "the raise carries the NO_TRANSCRIPT errorcode" \
    [dict get $opts -errorcode] {COACHMAN NO_TRANSCRIPT}

file delete -force $dir

if {$failures == 0} {
    puts "\nAll tests passed."
} else {
    puts "\n$failures test(s) failed."
    exit 1
}
