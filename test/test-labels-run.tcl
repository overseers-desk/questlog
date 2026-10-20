#!/usr/bin/env tclsh9.0
# labels::run against a fake claude binary: the argv it is given, the model's
# fields merged with the computed ones, and the failed record on a non-zero exit
# and on output that is not JSON. Run: tclsh9.0 test/test-labels-run.tcl
package require Tcl 9

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
source [file join $ROOT lib path.tcl]
source [file join $ROOT lib match.tcl]
source [file join $ROOT lib labels.tcl]

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
proc write_file {path content} {
    set fd [open $path w]
    puts -nonewline $fd $content
    close $fd
}

# write_fake - a stand-in claude CLI: writes its argv to FAKE_ARGV_LOG, then
# plays the scenario named by FAKE_SCENARIO.
proc write_fake {dir} {
    set path [file join $dir claude]
    write_file $path {#!/usr/bin/env tclsh9.0
set fd [open $::env(FAKE_ARGV_LOG) w]
puts $fd $::argv
close $fd
switch -- $::env(FAKE_SCENARIO) {
    ok {
        puts {{"type":"result","is_error":false,"result":"```json\n{\"waiting_on\":\"ruling\",\"question\":\"A or B?\",\"next_step\":\"Apply A.\",\"blocker\":\"\"}\n```"}}
    }
    exit1 { puts stderr "boom"; exit 1 }
    garbage { puts "not json at all" }
}
}
    ::questlog::path::_real_file attributes $path -permissions 0755
    return $path
}

set tmp [::questlog::path::_real_file tempdir]
set ::env(XDG_STATE_HOME) [file join $tmp state]
set ::env(FAKE_ARGV_LOG) [file join $tmp argv]
set ::questlog::labels::claude_bin [write_fake $tmp]

set jsonl [file join $tmp s.jsonl]
write_file $jsonl [join {
    {{"type":"user","cwd":"/w","message":{"role":"user","content":"fix the parser"}}}
    {{"type":"assistant","message":{"model":"claude-sonnet-4-5","role":"assistant","content":[{"type":"text","text":"Shall I apply A?"}],"usage":{"input_tokens":1000,"cache_read_input_tokens":19000,"cache_creation_input_tokens":0,"output_tokens":5}},"requestId":"r1"}}
    {{"type":"custom-title","agentName":"parser fix"}}
} \n]\n

proc run_one {scenario uuid} {
    set ::env(FAKE_SCENARIO) $scenario
    set ::got ""
    ::questlog::labels::run $::jsonl $uuid {apply {{uuid rec} {set ::got [list $uuid $rec]}}}
    after 10000 {set ::got timeout}
    vwait ::got
    return $::got
}

lassign [run_one ok u1] uuid rec
set argv [string trim [read [set fd [open $::env(FAKE_ARGV_LOG)]]]][close $fd]
check "callback uuid" $uuid u1
check "argv -p" [lindex $argv 0] -p
check "argv output format" [lrange $argv 1 2] {--output-format json}
check "argv model" [lrange $argv 3 4] {--model sonnet}
check "prompt carries the first user prompt" \
    [string match "*fix the parser*" [lindex $argv 5]] 1
check "status" [dict get $rec status] ok
check "waiting_on" [dict get $rec waiting_on] ruling
check "question" [dict get $rec question] "A or B?"
check "next_step" [dict get $rec next_step] "Apply A."
check "blocker" [dict get $rec blocker] ""
check "title" [dict get $rec title] "parser fix"
check "ctx_pct" [dict get $rec ctx_pct] 10
check "src_size" [dict get $rec src_size] [file size $jsonl]
check "written to the store" [dict get [::questlog::labels::read u1] waiting_on] ruling
check "fresh after labelling" [::questlog::labels::stale [::questlog::labels::read u1] $jsonl] 0

foreach scen {exit1 garbage} {
    lassign [run_one $scen u-$scen] uuid rec
    check "$scen: failed" [dict get $rec status] failed
    check "$scen: error set" [expr {[dict getdef $rec error ""] ne ""}] 1
    check "$scen: stored" [dict get [::questlog::labels::read u-$scen] status] failed
}

::questlog::path::_real_file delete -force $tmp
exit $failures
