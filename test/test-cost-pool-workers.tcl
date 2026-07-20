#!/usr/bin/env tclsh9.0
# The cost tpool must parallelise, not funnel (issue #56). A min-0 pool spawns
# one worker for the first post and never grows, so every parse runs in series
# through that single thread; the fix is a fixed-size pool (minworkers =
# maxworkers = cost_workers). This drives the pool the app builds - the config
# seam feeding a min=max tpool - and asserts N concurrent jobs land on N distinct
# threads, so the funnelling regression cannot return unnoticed. Run:
#   tclsh9.0 test/test-cost-pool-workers.tcl
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
set ::questlog_config_only 1; source [file join $ROOT questlog]

set fails 0
proc check {name got want} {
    if {$got eq $want} {
        puts "ok   - $name"
    } else {
        puts "FAIL - $name (got <$got> want <$want>)"
        incr ::fails
    }
}

if {[catch {package require Thread}]} {
    puts "skip: Thread package unavailable"
    exit 0
}

set n [::questlog::config::get cost_workers]
# The seam the fix turns on: a fixed-size pool needs at least two workers to
# parallelise at all. A min-0 default (the bug) is exactly what this guards.
check "cost_workers is a parallel width" [expr {$n >= 2}] 1

# Build the pool the way spawn_cost_pool does - minworkers = maxworkers = n - and
# run n jobs that each hold their worker long enough to overlap. A funnelling
# pool completes them in series on one thread; a parallel pool spreads them.
set pool [tpool::create -minworkers $n -maxworkers $n -initcmd {
    proc job {} { after 300; return [thread::id] }
}]
set t0 [clock milliseconds]
set pending [list]
for {set i 0} {$i < $n} {incr i} { lappend pending [tpool::post -nowait $pool {job}] }
set tids [dict create]
while {[llength $pending]} {
    foreach h [tpool::wait $pool $pending pending] { dict set tids [tpool::get $pool $h] 1 }
}
set wall [expr {[clock milliseconds] - $t0}]
tpool::release $pool

check "n jobs run on n distinct workers" [dict size $tids] $n
# Parallel, not serial: n * 300ms in series would be well past 2 * 300ms.
check "the pass overlaps rather than funnels" [expr {$wall < $n * 300 - 200}] 1

if {$fails > 0} { puts "$fails failures"; exit 1 }
puts "all tests passed"
exit 0
