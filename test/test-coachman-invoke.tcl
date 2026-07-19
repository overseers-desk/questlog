#!/usr/bin/env tclsh9.0
# Integration tests for coachman's invoke/classify path against a fake
# claude binary: success, the failure codes, argv assembly, first-wins
# session capture, the ledger, and the usage-limit retry. Run:
#   tclsh9.0 test/test-coachman-invoke.tcl
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
proc near {got want} { return [expr {abs($got - $want) < 0.001}] }
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
proc argv_lines {log} {
    return [split [string trim [read_file $log]] \n]
}

set QUIET [logger::init coachman-test-quiet]
${QUIET}::setlevel critical

# write_fake - a stand-in claude CLI: appends its argv to FAKE_ARGV_LOG,
# then plays the scenario named by FAKE_SCENARIO. With FAKE_STEP set the
# scenario is a colon-separated list consumed one name per invocation, so
# a retry path can meet a different answer than the first attempt.
proc write_fake {dir} {
    set path [file join $dir claude]
    write_file $path {#!/usr/bin/env tclsh9.0
set fd [open $::env(FAKE_ARGV_LOG) a]
puts $fd $::argv
close $fd
set scen $::env(FAKE_SCENARIO)
if {[info exists ::env(FAKE_STEP)]} {
    set n 0
    if {[file exists $::env(FAKE_STEP)]} {
        set f [open $::env(FAKE_STEP) r]
        set n [string trim [read $f]]
        close $f
    }
    set f [open $::env(FAKE_STEP) w]
    puts -nonewline $f [expr {$n + 1}]
    close $f
    set scen [lindex [split $scen :] $n]
}
switch -- $scen {
    ok {
        puts {{"type":"system","subtype":"init","session_id":"sid-fake"}}
        puts {{"type":"assistant","message":{"content":[{"type":"text","text":"PRODUCT_START\nthe goods\nPRODUCT_END"}]}}}
        puts {{"type":"result","subtype":"success","is_error":false,"result":"the product","total_cost_usd":0.42,"session_id":"sid-fake"}}
    }
    second {
        puts {{"type":"system","subtype":"init","session_id":"sid-second"}}
        puts {{"type":"result","subtype":"success","is_error":false,"result":"another product","total_cost_usd":0.03,"session_id":"sid-second"}}
    }
    silent {
        puts {{"type":"system","subtype":"init","session_id":"sid-silent"}}
    }
    errshape {
        puts {{"type":"system","subtype":"init","session_id":"sid-err"}}
        puts {{"type":"result","subtype":"error_during_execution","is_error":false}}
    }
    limit {
        puts {{"type":"system","subtype":"init","session_id":"sid-limit"}}
        puts {{"type":"result","subtype":"success","is_error":true,"result":"You have hit your usage limit; resets 3am (UTC)"}}
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

# The subclass under test: the fake binary via the claude_bin seam, a quiet
# logger, and a zero usage-limit wait so the retry path runs in test time.
oo::class create FakeHarness {
    superclass coachman::Harness
    method log_service {} { return $::QUIET }
    method claude_bin {} { return $::FAKE }
    method _credit_wait_secs {msg} { return 0 }
}

set dir [file tempdir]
set FAKE [write_fake $dir]
set logd [file join $dir logs]
set pdir [file join $dir row-1]
file mkdir $pdir

# ---- success: product, ledger, session capture, argv ----------------------

set ::env(FAKE_ARGV_LOG) [file join $dir argv-ok.log]
set ::env(FAKE_SCENARIO) ok
unset -nocomplain ::env(FAKE_STEP)
set h [FakeHarness new $pdir $logd]
set rc [$h call build [file join $logd build.log] "Write me a haiku."]
check "success returns 0" $rc 0
check "the product lands in log_file" [read_file [file join $logd build.log]] "the product"
check "session id is captured from the init event" [$h session_id] sid-fake
check "the ledger prices the stage" [near [$h cost_total] 0.42] 1
check "the transcript recovers the marker-delimited product" \
    [coachman::extract_between \
        [coachman::transcript_assistant_text [file join $logd build.log.json]] \
        PRODUCT_START PRODUCT_END] "the goods"

set a [lindex [argv_lines $::env(FAKE_ARGV_LOG)] 0]
check "the model rides first after -p, defaulting to sonnet" [lrange $a 0 2] {-p --model sonnet}
check "permission args precede the variadic-safe boolean flags" \
    [lindex $a 3] --dangerously-skip-permissions
check "stream-json output is requested" [expr {[lsearch -exact $a --output-format] >= 0}] 1
check "the prompt is the final argument" [lindex $a end] "Write me a haiku."

# ---- first-wins session capture -------------------------------------------

set ::env(FAKE_SCENARIO) second
set rc [$h call review [file join $logd review.log] "Review it."]
check "a later call still runs" $rc 0
check "session capture is first-wins" [$h session_id] sid-fake
check "the ledger sums both stages" [near [$h cost_total] 0.45] 1

# A new harness on the same slug owns the ledger afresh.
set h2 [FakeHarness new $pdir $logd]
check "a new harness truncates its slug's ledger" [near [$h2 cost_total] 0.0] 1

# ---- caller model override ------------------------------------------------

set ::env(FAKE_ARGV_LOG) [file join $dir argv-model.log]
set ::env(FAKE_SCENARIO) ok
$h2 call m [file join $logd m.log] "p" --model opus
set a [lindex [argv_lines $::env(FAKE_ARGV_LOG)] 0]
check "a caller --model overrides the sonnet default" [lrange $a 0 2] {-p --model opus}
check "the model pair is not repeated" [llength [lsearch -all -exact $a --model]] 1

# ---- failure classification -----------------------------------------------

set ::env(FAKE_ARGV_LOG) [file join $dir argv-silent.log]
set ::env(FAKE_SCENARIO) silent
set h3 [FakeHarness new $pdir $logd]
set rc [$h3 call fetch [file join $logd fetch.log] "p"]
check "a closed stream with no result returns 2" $rc 2
check "fail_cause names the missing result" \
    [string match "*ended without result*" [$h3 fail_cause]] 1

set ::env(FAKE_SCENARIO) errshape
set rc [$h3 call fetch2 [file join $logd fetch2.log] "p"]
check "a result object without a result field returns 1" $rc 1

# resume before any successful call is a caller error, not a code.
set h4 [FakeHarness new $pdir $logd]
check "resume before call errors" \
    [catch {$h4 resume fix [file join $logd fix.log] "p"}] 1

# ---- an armed cap refuses to run unmetered --------------------------------

# The default meter with no rates is a cap the harness cannot enforce, so
# call refuses at entry. A zero cap needs no meter, and a host that brings
# its own session_cost_usd passes the guard without rates.
oo::class create UnmeteredHarness {
    superclass FakeHarness
    method cost_rates {} { return {} }
}
set ::env(FAKE_ARGV_LOG) [file join $dir argv-unmetered.log]
set ::env(FAKE_SCENARIO) ok
set h6 [UnmeteredHarness new $pdir $logd]
check "an armed cap with no rates refuses the call" \
    [catch {$h6 call u [file join $logd u.log] "p"}] 1
$h6 set_worker_cost_cap 0
check "a zero cap needs no meter and runs" \
    [$h6 call u [file join $logd u.log] "p"] 0
oo::class create OwnMeterHarness {
    superclass UnmeteredHarness
    method session_cost_usd {sid} { return 0.0 }
}
set h7 [OwnMeterHarness new $pdir $logd]
check "a host meter passes the guard without rates" \
    [$h7 call o [file join $logd o.log] "p"] 0

# ---- usage-limit block: waited out and retried on the same session --------

set ::env(FAKE_ARGV_LOG) [file join $dir argv-limit.log]
set ::env(FAKE_SCENARIO) limit:ok
set ::env(FAKE_STEP) [file join $dir step1]
set h5 [FakeHarness new $pdir $logd]
set rc [$h5 call draft [file join $logd draft.log] "p"]
check "a usage-limit block is waited out and retried to success" $rc 0
check "the blocked session's id is the captured one" [$h5 session_id] sid-limit
set lines [argv_lines $::env(FAKE_ARGV_LOG)]
check "the block cost one extra invocation" [llength $lines] 2
check "the retry resumes the blocked session" \
    [expr {[lsearch -exact [lindex $lines 1] --resume] >= 0}] 1
check "the resumed id is the one the init event named" \
    [expr {[lsearch -exact [lindex $lines 1] sid-limit] >= 0}] 1
unset ::env(FAKE_STEP)

file delete -force $dir

if {$failures == 0} {
    puts "\nAll tests passed."
} else {
    puts "\n$failures test(s) failed."
    exit 1
}
