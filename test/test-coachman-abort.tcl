#!/usr/bin/env tclsh9.0
# Tests for coachman's abort: an outside kill of an in-flight run. The
# call is driven through a coroutine (the mode that holds a deadman
# handle) against a hanging fake, and abort fires from an after-event,
# the way a GUI cancel or a job-loop shutdown would reach it. Run:
#   tclsh9.0 test/test-coachman-abort.tcl
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
proc read_file {path} {
    set fd [open $path r]
    set s [read $fd]
    close $fd
    return $s
}
proc write_file {path content} {
    set fd [open $path w]
    puts -nonewline $fd $content
    close $fd
}

set QUIET [logger::init coachman-test-quiet]
${QUIET}::setlevel critical

# The fake: scenario hang emits an init event then silence far past the
# test's lifetime; limit reports a usage-window block every time.
proc write_fake {dir} {
    set path [file join $dir claude]
    write_file $path {#!/usr/bin/env tclsh9.0
set fd [open $::env(FAKE_ARGV_LOG) a]
puts $fd $::argv
close $fd
switch -- $::env(FAKE_SCENARIO) {
    hang {
        puts {{"type":"system","subtype":"init","session_id":"sid-hang"}}
        flush stdout
        after 30000
    }
    limit {
        puts {{"type":"system","subtype":"init","session_id":"sid-limit"}}
        puts {{"type":"result","subtype":"success","is_error":true,"result":"You have hit your usage limit; resets 3am (UTC)"}}
    }
}
}
    file attributes $path -permissions 0o755
    return $path
}

# A TERM-ignoring fake, for the abort-vs-stall race: the stall watchdog's
# TERM records its cause first and the child lives on until the KILL at
# the end of deadman's grace period, the window the abort lands in.
proc write_trap_fake {dir} {
    set path [file join $dir claude-trap]
    write_file $path {#!/bin/sh
echo "$@" >> "$FAKE_ARGV_LOG"
echo {{"type":"system","subtype":"init","session_id":"sid-trap"}}
trap '' TERM
sleep 30
}
    file attributes $path -permissions 0o755
    return $path
}

oo::class create AbortHarness {
    superclass coachman::Harness
    method log_service {} { return $::QUIET }
    method claude_bin {} { return $::FAKE }
}

set dir [file tempdir]
set FAKE [write_fake $dir]
set logd [file join $dir logs]
set pdir [file join $dir row-1]
file mkdir $pdir
set ::env(FAKE_ARGV_LOG) [file join $dir argv.log]
set ::env(FAKE_SCENARIO) hang

set h [AbortHarness new $pdir $logd]
# The stall clock and the cost poll stay out of the way: the abort is
# the only kill in this test.
$h set_stall_timeout 30
$h set_worker_cost_cap 0

check "abort with nothing running is a no-op" [$h abort] 0

# Drive the call in a coroutine so _invoke holds the deadman handle and
# the event loop stays free for the after-event that aborts it.
set ::abort_ret ""
set ::call_rc ""
coroutine runner apply {{h logd} {
    set ::call_rc [$h call research [file join $logd r.log] "p"]
    set ::call_done 1
}} $h $logd
after 300 [list apply {h {
    set ::abort_ret [$h abort]
}} $h]
vwait ::call_done

check "abort on a live run returns 1" $::abort_ret 1
check "the aborted call returns 2" $::call_rc 2
check "fail_cause names the abort" \
    [string match "*aborted by caller*" [$h fail_cause]] 1
check "the abort is not retried" \
    [llength [split [string trim [read_file $::env(FAKE_ARGV_LOG)]] \n]] 1
check "the handle is cleared: abort after the kill is a no-op" [$h abort] 0

# ---- abort that loses the kill race still ends the run --------------------

# A TERM-ignoring child: the stall watchdog fires first and records the
# stall cause; the abort lands in the grace window before the KILL, so
# deadman's first-cause-wins rule hands the kill to the stall. The abort
# mark, not the recorded cause, is the contract: the run ends with the
# abort's fail_cause and no fresh-session stall retries.
set TRAP [write_trap_fake $dir]
oo::class create TrapHarness {
    superclass coachman::Harness
    method log_service {} { return $::QUIET }
    method claude_bin {} { return $::TRAP }
}
set pdir2 [file join $dir row-2]
file mkdir $pdir2
set ::env(FAKE_ARGV_LOG) [file join $dir argv-race.log]
set h2 [TrapHarness new $pdir2 $logd]
$h2 set_stall_timeout 0.3
$h2 set_worker_cost_cap 0
set ::race_ret ""
set ::race_rc ""
coroutine race_runner apply {{h logd} {
    set ::race_rc [$h call research [file join $logd race.log] "p"]
    set ::race_done 1
}} $h2 $logd
# 1s: past the stall TERM at 0.3s, well inside the 10s grace window.
after 1000 [list apply {h {
    set ::race_ret [$h abort]
}} $h2]
vwait ::race_done
check "abort in the race window still returns 1" $::race_ret 1
check "the race-losing abort still ends the run with 2" $::race_rc 2
check "fail_cause names the abort, not the stall" \
    [string match "*aborted by caller*" [$h2 fail_cause]] 1
check "no stall retries ran over the abort" \
    [llength [split [string trim [read_file $::env(FAKE_ARGV_LOG)]] \n]] 1

# ---- abort during the usage-window sleep ----------------------------------

# Between attempts there is no child and no handle; the abort marks the
# run and wakes the sleeping coroutine at once instead of letting it
# sleep out the reset and retry.
oo::class create SleepHarness {
    superclass coachman::Harness
    method log_service {} { return $::QUIET }
    method claude_bin {} { return $::FAKE }
    method _credit_wait_secs {msg} { return 30 }
}
set pdir3 [file join $dir row-3]
file mkdir $pdir3
set ::env(FAKE_ARGV_LOG) [file join $dir argv-sleep.log]
set ::env(FAKE_SCENARIO) limit
set h3 [SleepHarness new $pdir3 $logd]
set ::sleep_ret ""
set ::sleep_rc ""
set t0 [clock milliseconds]
coroutine sleep_runner apply {{h logd} {
    set ::sleep_rc [$h call draft [file join $logd draft.log] "p"]
    set ::sleep_done 1
}} $h3 $logd
after 300 [list apply {h {
    set ::sleep_ret [$h abort]
}} $h3]
vwait ::sleep_done
set elapsed [expr {[clock milliseconds] - $t0}]
check "abort during the sleep returns 1" $::sleep_ret 1
check "the woken run ends with 2" $::sleep_rc 2
check "fail_cause names the abort" \
    [string match "*aborted by caller*" [$h3 fail_cause]] 1
check "the sleep was woken, not slept out" [expr {$elapsed < 5000}] 1
check "no retry followed the woken abort" \
    [llength [split [string trim [read_file $::env(FAKE_ARGV_LOG)]] \n]] 1

# ---- sleep_wake funnels double wakes ---------------------------------------

# The reset timer and abort can both try to wake the sleeping coroutine
# (timer fires, queues its callback, abort runs before the callback does);
# the funnel makes the first arrival clear the state so the second no-ops,
# instead of a stray resume landing on the coroutine's next yield.
set h5 [SleepHarness new $pdir3 $logd]
set ::wakes 0
coroutine wake_probe apply {{} {
    yield
    incr ::wakes
    yield
    incr ::wakes
}}
oo::objdefine $h5 method arm_sleep {co} {
    my variable SleepCoro SleepTimer
    set SleepCoro $co
    set SleepTimer [after 100000 nothing]
}
$h5 arm_sleep wake_probe
$h5 sleep_wake
$h5 sleep_wake
after 50 [list set ::wake_settle 1]
vwait ::wake_settle
check "the first wake resumes the coroutine once" $::wakes 1
check "the second wake is a no-op" $::wakes 1
rename wake_probe {}

file delete -force $dir

if {$failures == 0} {
    puts "\nAll tests passed."
} else {
    puts "\n$failures test(s) failed."
    exit 1
}
