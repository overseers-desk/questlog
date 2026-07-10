#!/usr/bin/env tclsh9.0
# The leash discipline: a class body must not arm deferred work through the
# raw primitives. A raw [after] or [coroutine] naming an object outlives the
# object and fires into a dead command; [my later] and [my coro] are the
# sanctioned verbs, and their arms die with the object (see leash-1.0.tm).
# This test is the enforcement half of that rule: it scans every class-bearing
# file under lib/ and ui/ and fails on a raw arm, so the crash class cannot
# be reintroduced by an edit that never read the module. [after cancel]
# and [after info] stay legal - they release, not arm.
#
# Vendored .tm modules are not scanned: they version independently and
# leash-1.0.tm itself is the one sanctioned home of the raw primitives.
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]

set fails 0

# An arming use: `after` followed by milliseconds, "idle", or a computed
# delay ($var or [expr]). `after cancel` / `after info` do not match.
set arm_after {(?:^|[\[\{ \t])after[ \t]+(?:idle\y|\d|\$|\[)}
set arm_coro  {(?:^|[\[\{ \t])coroutine[ \t]}

foreach f [concat [glob -nocomplain $ROOT/lib/*.tcl] \
               [glob -nocomplain $ROOT/ui/*.tcl]] {
    set fh [open $f r]
    set src [read $fh]
    close $fh
    if {![string match *oo::class* $src]} continue
    set lineno 0
    foreach line [split $src \n] {
        incr lineno
        # Strip comments: a raw arm in prose is not an arm.
        regsub {^\s*#.*} $line "" code
        regsub {;#.*} $code "" code
        foreach {pat verb} [list $arm_after "my later" $arm_coro "my coro"] {
            if {[regexp $pat $code]} {
                puts "FAIL: [file tail $f]:$lineno arms a raw deferred call"
                puts "  $line"
                puts "  a class arms through \"$verb\" (leash-1.0.tm), so the"
                puts "  work dies with the object instead of outliving it"
                incr fails
            }
        }
    }
}

if {$fails} {
    puts "$fails raw arms"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
