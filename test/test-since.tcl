#!/usr/bin/env tclsh9.0
package require Tcl 9
package require TclOO
set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT config.tcl]
source [file join $ROOT lib path.tcl]
source [file join $ROOT lib filter.tcl]
source [file join $ROOT lib jsonl.tcl]
source [file join $ROOT lib match.tcl]
source [file join $ROOT lib scan.tcl]

# Synthetic projects tree under /tmp/questlog-test-since.
proc ::questlog::path::projects_root {} { return /tmp/questlog-test-since }

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name  expected=<$expected>  actual=<$actual>"
        incr ::fails
    } else {
        puts "ok:   $name"
    }
}

# ---- parse_since: the one home for a duration spec ------------------
check parse_24h   86400   [::questlog::filter::parse_since 24h]
check parse_7d    604800  [::questlog::filter::parse_since 7d]
check parse_30d   2592000 [::questlog::filter::parse_since 30d]
check parse_2w    1209600 [::questlog::filter::parse_since 2w]
check parse_90m   5400    [::questlog::filter::parse_since 90m]
check parse_empty ""      [::questlog::filter::parse_since ""]
check parse_all   ""      [::questlog::filter::parse_since all]
check parse_bad_unit  1 [catch {::questlog::filter::parse_since 3x}]
check parse_bad_word  1 [catch {::questlog::filter::parse_since abc}]
check parse_bad_order 1 [catch {::questlog::filter::parse_since d7}]

# ---- cutoff_for: "all" => no bound; a duration => now - secs --------
check cutoff_all 0 [::questlog::filter::cutoff_for [dict create since all]]
set now [clock seconds]
set c7 [::questlog::filter::cutoff_for [dict create since 7d]]
check cutoff_7d_within 1 [expr {abs(($now - 604800) - $c7) <= 2}]

# ---- list_paths_for: a since bound prunes the scan corpus ----------
::questlog::path::_real_file delete -force /tmp/questlog-test-since
::questlog::path::_real_file mkdir /tmp/questlog-test-since/-home-test-code-foo

set recent /tmp/questlog-test-since/-home-test-code-foo/recent.jsonl
set fh [open $recent w]
puts $fh {{"type":"user","message":{"content":"recent"},"cwd":"/home/test/code/foo"}}
close $fh

set old /tmp/questlog-test-since/-home-test-code-foo/old.jsonl
set fh [open $old w]
puts $fh {{"type":"user","message":{"content":"old"},"cwd":"/home/test/code/foo"}}
close $fh
file mtime $old [expr {[clock seconds] - 40*24*3600}]

set s [::questlog::Scan new {} {}]
set lp7 [$s list_paths_for [dict create since 7d]]
check since_7d_keeps_recent 1 [expr {$recent in $lp7}]
check since_7d_drops_old    0 [expr {$old in $lp7}]
set lpall [$s list_paths_for [dict create since all]]
check since_all_keeps_recent 1 [expr {$recent in $lpall}]
check since_all_keeps_old    1 [expr {$old in $lpall}]
$s destroy

::questlog::path::_real_file delete -force /tmp/questlog-test-since

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
