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

# The fake: an init event, then silence far past the test's lifetime.
proc write_fake {dir} {
    set path [file join $dir claude]
    write_file $path {#!/usr/bin/env tclsh9.0
set fd [open $::env(FAKE_ARGV_LOG) a]
puts $fd $::argv
close $fd
puts {{"type":"system","subtype":"init","session_id":"sid-hang"}}
flush stdout
after 30000
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

file delete -force $dir

if {$failures == 0} {
    puts "\nAll tests passed."
} else {
    puts "\n$failures test(s) failed."
    exit 1
}
