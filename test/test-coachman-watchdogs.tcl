#!/usr/bin/env tclsh9.0
# Watchdog tests against a fake claude that hangs: the stall kill and its
# fresh-session retry ceiling, the deliberate budget kill, and the bounded
# finalise_resume recovery that follows one. Run:
#   tclsh9.0 test/test-coachman-watchdogs.tcl
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

# The fake: an init event, then silence past any test timeout (scenario
# stall), or a clean success (scenario ok) for the finalise resume.
proc write_fake {dir} {
    set path [file join $dir claude]
    write_file $path {#!/usr/bin/env tclsh9.0
set fd [open $::env(FAKE_ARGV_LOG) a]
puts $fd $::argv
close $fd
switch -- $::env(FAKE_SCENARIO) {
    ok {
        puts {{"type":"system","subtype":"init","session_id":"sid-fin"}}
        puts {{"type":"result","subtype":"success","is_error":false,"result":"finalised","total_cost_usd":0.05,"session_id":"sid-fin"}}
    }
    stall {
        puts {{"type":"system","subtype":"init","session_id":"sid-stall"}}
        flush stdout
        after 10000
    }
}
}
    file attributes $path -permissions 0o755
    return $path
}

set dir [file tempdir]
set FAKE [write_fake $dir]
set logd [file join $dir logs]

# ---- stall kill: return 2 after the fresh-session retry ceiling -----------

oo::class create StallHarness {
    superclass coachman::Harness
    method log_service {} { return $::QUIET }
    method claude_bin {} { return $::FAKE }
}

set pdir [file join $dir row-stall]
file mkdir $pdir
set ::env(FAKE_ARGV_LOG) [file join $dir argv-stall.log]
set ::env(FAKE_SCENARIO) stall
set h [StallHarness new $pdir $logd]
$h set_stall_timeout 0.4
# With a cost cap armed, deadman runs the stall check on the cap's poll
# tick (30s cadence), far past this sub-second timeout; cap 0 drops the
# poll so the stall clock ticks at its own remaining-allowance cadence.
$h set_worker_cost_cap 0
set rc [$h call research [file join $logd research.log] "p"]
check "a stalled child fails with 2" $rc 2
check "fail_cause says stalled" [string match "*stalled*" [$h fail_cause]] 1
check "one stall buys two fresh-session retries" \
    [llength [split [string trim [read_file $::env(FAKE_ARGV_LOG)]] \n]] 3

# ---- budget kill: return 3, then finalise_resume recovers the spend -------

# The meter reads a test global, so the kill and the recovery are
# deterministic: 99 (over the 10 default cap) during the run, 5 (under the
# raised cap) during the finalise.
oo::class create CostHarness {
    superclass coachman::Harness
    method log_service {} { return $::QUIET }
    method claude_bin {} { return $::FAKE }
    method session_cost_usd {sid} { return $::FAKE_COST }
    method _cost_poll_ms {} { return 100 }
}

set pdir2 [file join $dir row-cost]
file mkdir $pdir2
set ::env(FAKE_ARGV_LOG) [file join $dir argv-cost.log]
set ::env(FAKE_SCENARIO) stall
set ::FAKE_COST 99.0
set h2 [CostHarness new $pdir2 $logd]
$h2 set_stall_timeout 30
set rc [$h2 call research [file join $logd research2.log] "p"]
check "the budget kill returns 3" $rc 3
check "fail_cause names the cap" [string match "*cost cap*" [$h2 fail_cause]] 1
check "the killed session's id was still captured" [$h2 session_id] sid-stall

set ::env(FAKE_SCENARIO) ok
set ::FAKE_COST 5.0
set rc [$h2 finalise_resume finalise [file join $logd fin.log] "Finalise only."]
check "finalise_resume closes cleanly" $rc 0
check "the cap is raised by the default headroom" [$h2 cost_cap] 12.0
check "the finalise product lands" [read_file [file join $logd fin.log]] "finalised"
set last [lindex [split [string trim [read_file $::env(FAKE_ARGV_LOG)]] \n] end]
check "the finalise resumes the killed session" \
    [expr {[lsearch -exact $last sid-stall] >= 0}] 1

# Without a captured session there is nothing to resume.
set pdir3 [file join $dir row-nosid]
file mkdir $pdir3
set h3 [CostHarness new $pdir3 $logd]
check "finalise_resume without a session returns 1" \
    [$h3 finalise_resume finalise [file join $logd fin3.log] "p"] 1

file delete -force $dir

if {$failures == 0} {
    puts "\nAll tests passed."
} else {
    puts "\n$failures test(s) failed."
    exit 1
}
