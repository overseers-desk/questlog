#!/usr/bin/env tclsh9.0
# Tests for the run_fix_loop skeleton over a fake claude: validate, resume
# with the failure fed back, accept on no hard error, escalate the third
# attempt to opus, and report when the retries run dry. Run:
#   tclsh9.0 test/test-coachman-fixloop.tcl
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

proc write_fake {dir} {
    set path [file join $dir claude]
    write_file $path {#!/usr/bin/env tclsh9.0
set fd [open $::env(FAKE_ARGV_LOG) a]
puts $fd $::argv
close $fd
puts {{"type":"system","subtype":"init","session_id":"sid-fix"}}
puts {{"type":"result","subtype":"success","is_error":false,"result":"rewritten","total_cost_usd":0.01,"session_id":"sid-fix"}}
}
    file attributes $path -permissions 0o755
    return $path
}

# The subclass supplies the validator and prompt builder the run_fix_loop
# contract names. The validator fails (one hard error beside a warning)
# until FAIL_UNTIL validations have run, then passes with the warning
# alone, so severity filtering is covered on the way.
oo::class create FixHarness {
    superclass coachman::Harness
    method log_service {} { return $::QUIET }
    method claude_bin {} { return $::FAKE }
    method check_product {attempt} {
        lappend ::val_calls $attempt
        set issues [list [dict create severity warning code cosmetic message "meh"]]
        if {[llength $::val_calls] <= $::FAIL_UNTIL} {
            lappend issues [dict create severity error code bad_field message "field is bad"]
        }
        return $issues
    }
    method build_fix {attempt hard error_text} {
        set ::seen_error $error_text
        return "Fix attempt $attempt"
    }
    method after_resume {} { incr ::resumes_seen }
    method report_fix_failure {hard max_fix} { set ::reported [llength $hard] }
}

set dir [file tempdir]
set FAKE [write_fake $dir]
set logd [file join $dir logs]
set pdir [file join $dir row-1]
file mkdir $pdir

# ---- one failed validation, fixed on resume -------------------------------

set ::env(FAKE_ARGV_LOG) [file join $dir argv-a.log]
set ::val_calls {}
set ::resumes_seen 0
set ::seen_error ""
set ::FAIL_UNTIL 1
set h [FixHarness new $pdir $logd]
check "the seeding call succeeds" [$h call build [file join $logd build.log] "p"] 0
check "the loop accepts once the hard error clears" \
    [$h run_fix_loop check_product build_fix] 0
check "the validator ran on attempts 1 and 2" $::val_calls {1 2}
check "the fix prompt carried the formatted hard error" \
    $::seen_error "- \[bad_field\] field is bad"
check "after_resume fired once" $::resumes_seen 1
check "a warning alone does not loop the worker" \
    [expr {$::FAIL_UNTIL < [llength $::val_calls]}] 1

# ---- retries run dry: escalation and the failure report -------------------

set ::env(FAKE_ARGV_LOG) [file join $dir argv-b.log]
set ::val_calls {}
set ::resumes_seen 0
set ::reported 0
set ::FAIL_UNTIL 99
set h2 [FixHarness new $pdir $logd]
check "the seeding call succeeds" [$h2 call build [file join $logd build2.log] "p"] 0
check "the loop reports 1 when the retries run dry" \
    [$h2 run_fix_loop check_product build_fix] 1
check "the validator ran per attempt and once finally" $::val_calls {1 2 3 final}
check "report_fix_failure received the surviving hard errors" $::reported 1
set lines [split [string trim [read_file $::env(FAKE_ARGV_LOG)]] \n]
check "the loop cost the call plus three fix resumes" [llength $lines] 4
check "attempts 1 and 2 stay on the default model" \
    [lrange [lindex $lines 1] 0 2] {-p --model sonnet}
check "attempt 3 escalates to opus" [lrange [lindex $lines 3] 0 2] {-p --model opus}
check "every fix resumes the seeded session" \
    [expr {[lsearch -exact [lindex $lines 3] --resume] >= 0}] 1

file delete -force $dir

if {$failures == 0} {
    puts "\nAll tests passed."
} else {
    puts "\n$failures test(s) failed."
    exit 1
}
