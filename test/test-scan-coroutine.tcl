#!/usr/bin/env tclsh9.0
# Verify coroutine-based scanning: chunked yielding, epoch cancellation.

package require Tcl 9
package require TclOO
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
set ::questlog_config_only 1; source [file join $ROOT questlog]
source [file join $ROOT lib path.tcl]
source [file join $ROOT lib jsonl.tcl]
source [file join $ROOT lib match.tcl]
source [file join $ROOT lib scan.tcl]

proc ::questlog::path::projects_root {} { return /tmp/questlog-test-coro }

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
::questlog::path::_real_file delete -force /tmp/questlog-test-coro
::questlog::path::_real_file mkdir /tmp/questlog-test-coro/-home-test-code-many
for {set i 0} {$i < 300} {incr i} {
    set fh [open [format /tmp/questlog-test-coro/-home-test-code-many/sess-%04d.jsonl $i] w]
    puts $fh "{\"type\":\"user\",\"message\":{\"content\":\"prompt $i\"},\"cwd\":\"/home/test/code/many\",\"timestamp\":\"2026-04-25T10:00:00.000Z\"}"
    puts $fh "{\"type\":\"assistant\",\"message\":{\"content\":\"reply $i\"}}"
    puts $fh "{\"type\":\"user\",\"message\":{\"content\":\"again $i\"}}"
    close $fh
}

# Test 1: full scan completes via coroutine.
set ::done 0
set ::row_count 0
set ::seen [dict create]
proc on_row {row}      { incr ::row_count; dict set ::seen [dict get $row path] 1 }
proc on_done {scanned} { set ::done 1 }

set s [::questlog::Scan new on_row on_done]
$s extend [dict create since all]
vwait ::done
check coro_scanned_all 300 $::row_count

# Test 2: epoch cancellation. Mid-flight extend cancels the previous coro.
# Build another 200 files in a second folder to lengthen the path list.
::questlog::path::_real_file mkdir /tmp/questlog-test-coro/-home-test-code-second
for {set i 0} {$i < 200} {incr i} {
    set fh [open [format /tmp/questlog-test-coro/-home-test-code-second/sess-%04d.jsonl $i] w]
    puts $fh "{\"type\":\"user\",\"message\":{\"content\":\"second prompt $i\"},\"cwd\":\"/home/test/code/second\"}"
    puts $fh "{\"type\":\"user\",\"message\":{\"content\":\"second again $i\"}}"
    close $fh
}

# Test 2: epoch cancellation. Mid-flight extend cancels the previous coro.
# The invariant we test is that after rapid back-to-back extends, the stream
# still ends up consistent - every path globbed by the final extend has been
# published to the consumer. The intermediate cancellation must not leak a
# partial state.
set ::done 0
set ::row_count 0
set ::seen [dict create]
$s extend [dict create since all]
after 5 [list $s extend [dict create since all]]
after 10 [list $s extend [dict create since all]]
vwait ::done
# Drain residual events.
update
check second_folder_visible 1 \
    [dict exists $::seen /tmp/questlog-test-coro/-home-test-code-second/sess-0000.jsonl]
check first_folder_visible 1 \
    [dict exists $::seen /tmp/questlog-test-coro/-home-test-code-many/sess-0000.jsonl]

$s destroy
::questlog::path::_real_file delete -force /tmp/questlog-test-coro

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
