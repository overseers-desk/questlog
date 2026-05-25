#!/usr/bin/env tclsh9.0
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT lib path.tcl]

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name"
        puts "  expected: $expected"
        puts "  actual:   $actual"
        incr ::fails
    } else {
        puts "ok:   $name"
    }
}

# encode_cwd: simple inverse of slashes-to-dashes.
check encode_simple   "-home-weiwu-code-foo"        [::fms::path::encode_cwd "/home/weiwu/code/foo"]

# pretty_home: abbreviate $HOME, leave non-home paths alone.
set ::env(HOME) /home/alice
check pretty_under   "~/code/foo"        [::fms::path::pretty_home "/home/alice/code/foo"]
check pretty_exact   "~"                 [::fms::path::pretty_home "/home/alice"]
check pretty_other   "/tmp/x"            [::fms::path::pretty_home "/tmp/x"]
check pretty_prefix  "/home/aliceland/x" [::fms::path::pretty_home "/home/aliceland/x"]

# set_bookmark / clear_bookmark: the +x bit toggles, other mode bits are
# preserved, and a missing path errors.
set bf /tmp/fms-test-bookmark.jsonl
set fh [open $bf w]; puts $fh "{}"; close $fh
::fms::path::_real_file attributes $bf -permissions 0o644
check book_initial_exec 0 [file executable $bf]
set m0 [::fms::path::_real_file attributes $bf -permissions]
::fms::path::set_bookmark $bf
check book_set_exec 1 [file executable $bf]
set m1 [::fms::path::_real_file attributes $bf -permissions]
check book_only_x_changed [expr {$m0 & ~0o100}] [expr {$m1 & ~0o100}]
::fms::path::clear_bookmark $bf
check book_clear_exec 0 [file executable $bf]
::fms::path::_real_file delete $bf
check book_missing_errors 1 [catch {::fms::path::set_bookmark /tmp/fms-no-such-session.jsonl}]

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
