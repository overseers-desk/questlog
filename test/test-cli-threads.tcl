#!/usr/bin/env tclsh9.0
# The CLI's threaded file pass (issue #17) must answer exactly as the
# single-thread path does. cli/main.tcl now matches and prices files on a
# fixed-size worker pool; QUESTLOG_THREADS=0 forces the old inline path, and a
# host without Thread degrades to it silently. This runs the real questlog
# binary over a fixture corpus in both modes and asserts byte-identical output
# across --json, a keyword query, --markdown, --shortstat and --accrued-cost, so
# the parallel pass cannot drift from the serial one unnoticed. Run:
#   tclsh9.0 test/test-cli-threads.tcl
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
set QL [file join $ROOT questlog]

set SAND [file join [pwd] _clithreads_sandbox]
file delete -force $SAND
set PROJ [file join $SAND .claude projects -home-user-proj]
file mkdir $PROJ

proc write_session {path prompts ts} {
    set fh [open $path w]
    chan configure $fh -encoding utf-8 -translation lf
    set t 0
    foreach p $prompts {
        puts $fh "{\"type\":\"user\",\"cwd\":\"/home/user/proj\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"role\":\"user\",\"content\":\"$p\"}}"
        puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":120,\"output_tokens\":60}}}"
        incr t
    }
    close $fh
}

# A spread of sessions: enough to clear the pool's small-result guard (2 files
# per worker) so the threaded path really runs, one carrying a subagent, and a
# keyword ("betaword") that a query can select on.
for {set i 1} {$i <= 20} {incr i} {
    set p [file join $PROJ [format s%02d $i].jsonl]
    set day [expr {($i % 27) + 1}]
    write_session $p [list "alpha task $i" "betaword detail $i"] \
        [format "2026-06-%02dT10:00" $day]
    file mtime $p [clock scan [format "2026-06-%02d 10:05:00" $day] -gmt 1]
}
set SUB [file join $PROJ s01 subagents]
file mkdir $SUB
write_session [file join $SUB agent-1.jsonl] {"betaword subwork"} "2026-06-11T10:00"

set fails 0
proc check {name got want} {
    if {$got eq $want} {
        puts "ok   - $name"
    } else {
        puts "FAIL - $name (got <$got> want <$want>)"
        incr ::fails
    }
}

set ::env(HOME) $SAND
proc ql {mode args} {
    global QL
    if {$mode eq "serial"} { set ::env(QUESTLOG_THREADS) 0 } else { unset -nocomplain ::env(QUESTLOG_THREADS) }
    set rc [catch {exec tclsh9.0 $QL {*}$args} out]
    unset -nocomplain ::env(QUESTLOG_THREADS)
    if {$rc} { return "ERROR: $out" }
    return $out
}

foreach {label args} {
    json          {--json --since all}
    json_query    {--json --since all --keyword betaword}
    markdown      {--markdown --since all}
    shortstat     {--shortstat --since all}
    accrued       {--shortstat --accrued-cost --since 400d}
} {
    set threaded [ql threaded {*}$args]
    set serial   [ql serial   {*}$args]
    check "threaded == serial: $label" $threaded $serial
    check "non-empty result: $label" [expr {[string length $threaded] > 2 && ![string match ERROR:* $threaded]}] 1
}

# The keyword query really did select on the corpus (both modes), so the
# equivalence above is over a non-trivial match, not two empty answers.
check "query found the keyword sessions" \
    [expr {[regexp -all -- {"uuid"} [ql threaded --json --since all --keyword betaword]] > 0}] 1

file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
