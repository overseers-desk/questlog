#!/usr/bin/env tclsh9.0
# Verify the running-session liveness predicate: a record counts as live
# only when its pid is alive AND /proc/<pid>/stat field 22 matches the
# recorded procStart (so a recycled pid is rejected).

package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT lib path.tcl]
source [file join $ROOT lib live.tcl]

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name  expected=<$expected>  actual=<$actual>"
        incr ::fails
    } else {
        puts "ok:   $name"
    }
}

# Read field 22 (start_time) of a pid the same way live.tcl does, so the
# synthetic record we write for our own process carries a matching value.
proc real_procstart {pid} {
    set fh [open /proc/$pid/stat r]
    set s [read $fh]
    close $fh
    set rest [string range $s [expr {[string last ) $s] + 2}] end]
    return [lindex $rest 19]
}

set me [pid]
set mystart [real_procstart $me]
# A pid above any plausible pid_max: /proc entry never exists -> dead.
set deadpid 2147480000

# ---- direct predicate ----------------------------------------------
check alive_match    1 [::csm::live::proc_alive_matching $me $mystart]
check alive_mismatch 0 [::csm::live::proc_alive_matching $me 0]
check dead_pid       0 [::csm::live::proc_alive_matching $deadpid $mystart]

# ---- running_uuids over a synthetic registry -----------------------
set ::env(HOME) /tmp/csm-test-live-home
::csm::path::_real_file delete -force /tmp/csm-test-live-home
set sdir /tmp/csm-test-live-home/.claude/sessions
::csm::path::_real_file mkdir $sdir

proc write_rec {fname pid uuid cwd procstart} {
    global sdir
    set fh [open [file join $sdir $fname] w]
    puts $fh "{\"pid\":$pid,\"sessionId\":\"$uuid\",\"cwd\":\"$cwd\",\"procStart\":\"$procstart\"}"
    close $fh
}

write_rec alive.json $me      alive-uuid /home/test/code/foo $mystart
write_rec dead.json  $deadpid dead-uuid  /home/test/code/bar 12345
write_rec reuse.json $me      reuse-uuid /home/test/code/baz 0   ;# pid alive, wrong start

set running [::csm::live::running_uuids]
check alive_present 1 [dict exists $running alive-uuid]
check dead_absent   0 [dict exists $running dead-uuid]
check reuse_absent  0 [dict exists $running reuse-uuid]
check alive_path \
    /tmp/csm-test-live-home/.claude/projects/-home-test-code-foo/alive-uuid.jsonl \
    [dict get $running alive-uuid]

::csm::path::_real_file delete -force /tmp/csm-test-live-home

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
