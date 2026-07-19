#!/usr/bin/env tclsh9.0
# Unit tests for coachman's pure parsers: the usage-limit reset scrape, the
# stream-json result and session-id readers, the whole-transcript assistant
# text recovery, and the marker cutter. No child process runs. Run:
#   tclsh9.0 test/test-coachman-parse.tcl
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

set QUIET [logger::init coachman-test-quiet]
${QUIET}::setlevel critical

# Probe exposes the unexported parser methods; its prompt dir carries a
# meta.env so the constructor's watchdog tuning is covered on the way.
oo::class create Probe {
    superclass coachman::Harness
    method log_service {} { return $::QUIET }
    method credit_wait {msg} { return [my _credit_wait_secs $msg] }
    method classify {msg} { return [my _classify_usage_limit $msg] }
    method stream_result {f} { return [my _stream_result $f] }
    method extract_sid {f} { return [my _extract_session_id $f] }
}

set dir [file tempdir]
set prompt_dir [file join $dir probe-slug]
file mkdir $prompt_dir
set fd [open [file join $prompt_dir meta.env] w]
puts $fd "WORKER_COST_CAP_USD=3.5"
puts $fd "STALL_TIMEOUT_SECS=7"
close $fd
set h [Probe new $prompt_dir $dir]

# ---- constructor + meta.env ----------------------------------------------

check "slug is the prompt dir's tail"    [$h slug] probe-slug
check "meta.env tunes the cost cap"      [$h cost_cap] 3.5
check "meta.env tunes the stall timeout" [$h stall_timeout] 7

# Junk numerics in meta.env keep the defaults rather than detonating as
# an expr error at the first cap comparison.
set pdir2 [file join $dir probe-junk]
file mkdir $pdir2
set fd [open [file join $pdir2 meta.env] w]
puts $fd "WORKER_COST_CAP_USD=ten dollars"
puts $fd "STALL_TIMEOUT_SECS=soon"
close $fd
set hj [Probe new $pdir2 $dir]
check "a non-numeric cap keeps the default"   [$hj cost_cap] 10.0
check "a non-numeric stall keeps the default" [$hj stall_timeout] 600

# ---- _credit_wait_secs ----------------------------------------------------

# The reset scrape sleeps until the stated wall-clock time plus a 2-minute
# margin, so the exact figure depends on "now": assert the bounds (never
# under a minute, never past a day plus the margin), not the value.
set w [$h credit_wait "You have hit your usage limit; resets 3am (UTC)"]
check "parseable reset waits at least a minute" [expr {$w >= 60}] 1
check "parseable reset waits at most a day"     [expr {$w <= 86520}] 1
set w [$h credit_wait "You have hit your usage limit; resets 11:30pm (Australia/Brisbane)"]
check "minutes and a zone parse"                [expr {$w >= 60 && $w <= 86520}] 1
check "the middot session-limit form parses" \
    [expr {[set w [$h credit_wait "hit your session limit · resets 10pm (Australia/Brisbane)"]] >= 60 && $w <= 86520}] 1
check "a 24-hour reset time parses" \
    [expr {[set w [$h credit_wait "se reinicia 22:00 (Europe/Madrid)"]] >= 60 && $w <= 86520}] 1
check "a Spanish a.m. reset time parses" \
    [expr {[set w [$h credit_wait "se reinicia 3 a. m. (UTC)"]] >= 60 && $w <= 86520}] 1
check "no reset time gives empty, not an hour" \
    [$h credit_wait "You have hit your limit and that is that"] ""
check "unknown zone gives empty" \
    [$h credit_wait "resets 3am (Neverland/Nowhere)"] ""

# ---- _classify_usage_limit ------------------------------------------------

# A parseable reset time is the whole test for waitable: English and
# Spanish rolling windows wait; a limit-scented message with no clock
# reset (reworded window, or a monthly/spend/fast limit an hourly retry
# would never clear) is suspected and fails loud; anything else is none.
check "English rolling window is waitable" \
    [lindex [$h classify "5-hour limit reached - resets 3am (UTC)"] 0] wait
check "Spanish rolling window is waitable" \
    [lindex [$h classify "Límite de 5 horas alcanzado - se reinicia 3am (UTC)"] 0] wait
check "a monthly limit is suspected, not waited" \
    [lindex [$h classify "You've hit your monthly limit, it resets next month."] 0] suspected
check "a fast limit is suspected" \
    [lindex [$h classify "You've hit your fast limit"] 0] suspected
check "a bare Spanish limit is suspected" \
    [lindex [$h classify "Límite de uso alcanzado"] 0] suspected
check "an ordinary error is not a limit" \
    [lindex [$h classify "Error: the file was not found"] 0] none

# ---- stream readers + transcript recovery ---------------------------------

# A transcript whose product (marker-delimited) sits in an assistant turn,
# displaced from the envelope's result by a later turn, with a half-written
# trailing line: the shape the verdict rule exists for.
set jf [file join $dir stream.json]
set fd [open $jf w]
puts $fd {{"type":"system","subtype":"init","session_id":"sid-123"}}
puts $fd {{"type":"assistant","message":{"content":[{"type":"text","text":"PRODUCT_START\nline one\nline two\nPRODUCT_END"}]}}}
puts $fd {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}}
puts $fd {{"type":"assistant","message":{"content":[{"type":"text","text":"afterword"}]}}}
puts $fd {{"type":"result","subtype":"success","is_error":false,"result":"afterword","total_cost_usd":0.1,"session_id":"sid-123"}}
puts -nonewline $fd "\{\"type\":\"result\",\"half"
close $fd

set r [$h stream_result $jf]
check "stream_result finds the result object" [dict get $r result] "afterword"
check "stream_result tolerates a half-written trailing line" [dict get $r type] result
check "extract_sid reads the init event" [$h extract_sid $jf] sid-123

set txt [coachman::transcript_assistant_text $jf]
check "assistant text concatenates text blocks only, in order" \
    [string match "PRODUCT_START*PRODUCT_END\nafterword" $txt] 1
check "extract_between cuts the marker-delimited product" \
    [coachman::extract_between $txt PRODUCT_START PRODUCT_END] "line one\nline two"
check "extract_between empty when the start marker is absent" \
    [coachman::extract_between $txt NOPE PRODUCT_END] ""
check "extract_between empty when the end marker comes first" \
    [coachman::extract_between "E\nx\nS" S E] ""
check "assistant text empty on a missing file" \
    [coachman::transcript_assistant_text [file join $dir absent.json]] ""

# A killed turn: the init event landed, the result never did.
set jf2 [file join $dir trunc.json]
set fd [open $jf2 w]
puts $fd {{"type":"system","subtype":"init","session_id":"sid-t"}}
close $fd
check "stream_result empty when the turn never closed" [$h stream_result $jf2] {}
check "extract_sid still recovers from the init event" [$h extract_sid $jf2] sid-t

$h destroy
file delete -force $dir

if {$failures == 0} {
    puts "\nAll tests passed."
} else {
    puts "\n$failures test(s) failed."
    exit 1
}
