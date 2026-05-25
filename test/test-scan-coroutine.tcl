#!/usr/bin/env tclsh9.0
# Verify coroutine-based scanning: chunked yielding, epoch cancellation.

package require Tcl 9
package require TclOO
set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT lib path.tcl]
source [file join $ROOT lib scan.tcl]

proc ::fms::path::projects_root {} { return /tmp/fms-test-coro }

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name  expected=<$expected>  actual=<$actual>"
        incr ::fails
    } else {
        puts "ok:   $name"
    }
}

# Build a 300-file synthetic tree (exceeds the 200-record yield boundary).
::fms::path::_real_file delete -force /tmp/fms-test-coro
::fms::path::_real_file mkdir /tmp/fms-test-coro/-home-test-code-many
for {set i 0} {$i < 300} {incr i} {
    set fh [open [format /tmp/fms-test-coro/-home-test-code-many/sess-%04d.jsonl $i] w]
    puts $fh "{\"type\":\"user\",\"message\":{\"content\":\"prompt $i\"},\"cwd\":\"/home/test/code/many\",\"timestamp\":\"2026-04-25T10:00:00.000Z\"}"
    puts $fh "{\"type\":\"assistant\",\"message\":{\"content\":\"reply $i\"}}"
    puts $fh "{\"type\":\"user\",\"message\":{\"content\":\"again $i\"}}"
    close $fh
}

# Test 1: full scan completes via coroutine.
set ::done 0
set ::row_count 0
proc on_row {row}      { incr ::row_count }
proc on_done {scanned} { set ::done 1 }

set s [::fms::Scan new on_row on_done]
$s extend [dict create window all one_turn 0]
vwait ::done
check coro_scanned_all 300 $::row_count

# Test 2: epoch cancellation. Mid-flight extend cancels the previous coro.
# Build another 200 files in a second folder to lengthen the path list.
::fms::path::_real_file mkdir /tmp/fms-test-coro/-home-test-code-second
for {set i 0} {$i < 200} {incr i} {
    set fh [open [format /tmp/fms-test-coro/-home-test-code-second/sess-%04d.jsonl $i] w]
    puts $fh "{\"type\":\"user\",\"message\":{\"content\":\"second prompt $i\"},\"cwd\":\"/home/test/code/second\"}"
    puts $fh "{\"type\":\"user\",\"message\":{\"content\":\"second again $i\"}}"
    close $fh
}

# Test 2: epoch cancellation. Mid-flight extend cancels the previous coro.
# The invariant we test is that after rapid back-to-back extends, the dict
# still ends up consistent - every path globbed by the final extend is
# either already memoised or scanned. The intermediate cancellation must
# not leak a partial state.
set ::done 0
set ::row_count 0
$s extend [dict create window all one_turn 0]
after 5 [list $s extend [dict create window all one_turn 0]]
after 10 [list $s extend [dict create window all one_turn 0]]
vwait ::done
# Drain residual events.
update
check second_folder_visible 1 \
    [expr {[$s lookup /tmp/fms-test-coro/-home-test-code-second/sess-0000.jsonl] ne ""}]
check first_folder_visible 1 \
    [expr {[$s lookup /tmp/fms-test-coro/-home-test-code-many/sess-0000.jsonl] ne ""}]

$s destroy
::fms::path::_real_file delete -force /tmp/fms-test-coro

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
