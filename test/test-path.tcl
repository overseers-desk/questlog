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
check encode_simple   "-home-weiwu-code-foo"        [::questlog::path::encode_cwd "/home/weiwu/code/foo"]

# pretty_home: abbreviate $HOME, leave non-home paths alone.
set ::env(HOME) /home/alice
check pretty_under   "~/code/foo"        [::questlog::path::pretty_home "/home/alice/code/foo"]
check pretty_exact   "~"                 [::questlog::path::pretty_home "/home/alice"]
check pretty_other   "/tmp/x"            [::questlog::path::pretty_home "/tmp/x"]
check pretty_prefix  "/home/aliceland/x" [::questlog::path::pretty_home "/home/aliceland/x"]

# set_bookmark / clear_bookmark: the +x bit toggles, other mode bits are
# preserved, and a missing path errors.
set bf /tmp/questlog-test-bookmark.jsonl
set fh [open $bf w]; puts $fh "{}"; close $fh
::questlog::path::_real_file attributes $bf -permissions 0o644
check book_initial_exec 0 [file executable $bf]
set m0 [::questlog::path::_real_file attributes $bf -permissions]
::questlog::path::set_bookmark $bf
check book_set_exec 1 [file executable $bf]
set m1 [::questlog::path::_real_file attributes $bf -permissions]
check book_only_x_changed [expr {$m0 & ~0o100}] [expr {$m1 & ~0o100}]
::questlog::path::clear_bookmark $bf
check book_clear_exec 0 [file executable $bf]
::questlog::path::_real_file delete $bf
check book_missing_errors 1 [catch {::questlog::path::set_bookmark /tmp/questlog-no-such-session.jsonl}]

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
