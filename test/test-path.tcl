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

# decode_folder: lossy fallback only.
check decode_simple   "/home/weiwu/code/foo"        [::csm::path::decode_folder "-home-weiwu-code-foo"]
check decode_no_dash  "/home/weiwu/code/contact/graph" \
    [::csm::path::decode_folder "-home-weiwu-code-contact-graph"]   ;# lossy: contact-graph collapses

# encode_cwd: simple inverse of slashes-to-dashes.
check encode_simple   "-home-weiwu-code-foo"        [::csm::path::encode_cwd "/home/weiwu/code/foo"]

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
