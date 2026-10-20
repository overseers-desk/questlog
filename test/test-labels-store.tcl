#!/usr/bin/env tclsh9.0
# The labels store: write and read back, staleness on mtime and size, and the
# failed-record shape. Run: tclsh9.0 test/test-labels-store.tcl
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

set tmp [::questlog::path::_real_file tempdir]
set ::env(XDG_STATE_HOME) [file join $tmp state]
check "dir under XDG_STATE_HOME" [::questlog::labels::dir] \
    [file join $tmp state questlog labels]
check "missing record reads empty" [::questlog::labels::read nosuch] ""

set jsonl [file join $tmp s.jsonl]
set fh [open $jsonl w]
puts $fh {{"type":"user","message":{"role":"user","content":"hi"}}}
close $fh

set rec [dict create title "a \"quoted\" name" ctx_pct 42 \
    src_mtime [file mtime $jsonl] src_size [file size $jsonl] \
    status ok state needs_answer question "which one?" next_step "pick" blocker "" successor ""]
::questlog::labels::write u1 $rec
set back [::questlog::labels::read u1]
check "round trip" [lsort -stride 2 $back] [lsort -stride 2 $rec]
check "fresh record is not stale" [::questlog::labels::stale $back $jsonl] 0
check "ok record without state is stale" \
    [::questlog::labels::stale [dict remove $back state] $jsonl] 1
check "empty record is stale" [::questlog::labels::stale "" $jsonl] 1

file mtime $jsonl [expr {[file mtime $jsonl] + 10}]
check "mtime change is stale" [::questlog::labels::stale $back $jsonl] 1
dict set back src_mtime [file mtime $jsonl]
check "matching mtime again fresh" [::questlog::labels::stale $back $jsonl] 0
dict set back src_size [expr {[file size $jsonl] + 1}]
check "size change is stale" [::questlog::labels::stale $back $jsonl] 1

::questlog::labels::write u2 {status failed error "claude failed: boom"}
set f [::questlog::labels::read u2]
check "failed status" [dict get $f status] failed
check "failed error" [dict get $f error] "claude failed: boom"

::questlog::path::_real_file delete -force $tmp
exit $failures
