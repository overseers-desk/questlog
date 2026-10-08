#!/usr/bin/env tclsh9.0
# The pool scan must be indistinguishable from the coroutine scan at the row
# stream: same rows, same publish order (the in-order chunk release is what
# streamtree's skipped default-sort resort relies on). Plus: a cancel mid-pass
# publishes nothing after the bump, and a hostile path (opens fail) skips
# without killing its chunk. Run:
#   tclsh9.0 test/test-scan-workers.tcl
package require Tcl 9
package require TclOO
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
set ::questlog_config_only 1; source [file join $ROOT questlog]
source [file join $ROOT lib path.tcl]
package require logman
source [file join $ROOT lib match.tcl]
source [file join $ROOT lib scan.tcl]
source [file join $ROOT lib search.tcl]
source [file join $ROOT lib jobpool.tcl]

if {[catch {package require Thread}]} {
    puts "skip: Thread package unavailable"
    exit 0
}

set FIX /tmp/questlog-test-workers-[pid]
proc ::questlog::path::projects_root {} { return $::FIX }

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name  expected=<$expected>  actual=<$actual>"
        incr ::fails
    } else {
        puts "ok:   $name"
    }
}

# ---- fixture: enough sessions to span several 2-path chunks -------------
::questlog::path::_real_file delete -force $FIX
::questlog::path::_real_file mkdir $FIX/-home-test-code-foo $FIX/-home-test-code-bar
for {set i 0} {$i < 7} {incr i} {
    set folder [expr {$i % 2 ? "-home-test-code-foo" : "-home-test-code-bar"}]
    set cwd [expr {$i % 2 ? "/home/test/code/foo" : "/home/test/code/bar"}]
    set fh [open $FIX/$folder/s$i.jsonl w]
    puts $fh "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"prompt $i\"},\"cwd\":\"$cwd\",\"timestamp\":\"2026-04-25T10:0$i:00.000Z\"}"
    puts $fh {{"type":"assistant","message":{"content":"reply"},"timestamp":"2026-04-25T10:09:00.000Z"}}
    close $fh
}
# An unreadable file: enumerated, unopenable, must be skipped by both paths.
set fh [open $FIX/-home-test-code-foo/hostile.jsonl w]
puts $fh {{"type":"user","message":{"role":"user","content":"never read"}}}
close $fh
::questlog::path::_real_file attributes $FIX/-home-test-code-foo/hostile.jsonl -permissions 0o000

dict set ::questlog::config::Config scan_chunk_files 2
set snapshot [dict create since all]

# One pass, one throwaway Scan; returns the published rows in publish order.
proc run_pass {} {
    set ::rows [list]
    set ::done ""
    set ::progress [list]
    set s [::questlog::Scan new \
        {apply {{row} { lappend ::rows $row }}} \
        {apply {{n} { set ::done $n }}} \
        {apply {{done total} { lappend ::progress "$done/$total" }}}]
    $s extend $::snapshot
    vwait ::done
    $s destroy
    return $::rows
}

::questlog::jobpool::init $ROOT
set pool_rows [run_pass]
set pool_progress $::progress
::questlog::jobpool::release
set ::env(QUESTLOG_THREADS) 0
set coro_rows [run_pass]
unset ::env(QUESTLOG_THREADS)

check "both passes published every session" 7 [llength $coro_rows]
check "pool pass row count matches" [llength $coro_rows] [llength $pool_rows]
check "identical rows in identical publish order" $coro_rows $pool_rows
# Eight paths (the hostile one counts): a 6-path first chunk, then one of 2.
check "pool progress counts the paths each chunk released" \
    {0/8 6/8 8/8} [lrange $pool_progress 0 2]

# ---- cancel mid-pass ----------------------------------------------------
::questlog::jobpool::init $ROOT
set ::rows [list]
set ::done ""
set s [::questlog::Scan new \
    {apply {{row} { lappend ::rows $row }}} \
    {apply {{n} { set ::done $n }}}]
$s extend $snapshot
$s cancel
after 500 {set ::settled 1}; vwait ::settled
check "a cancelled pool pass publishes nothing" 0 [llength $::rows]
check "and never reports done" "" $::done
$s destroy
::questlog::jobpool::release

::questlog::path::_real_file delete -force $FIX
if {$fails > 0} { puts "$fails failures"; exit 1 }
puts "all tests passed"
exit 0
