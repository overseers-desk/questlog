#!/usr/bin/env wish9.0
# StreamTree's deferred work is leashed: a resort or relayout still pending when
# the object is destroyed must be cancelled, not fire into a dead command.
#
# StreamTree arms two timers - the debounced resort (schedule_resort, a leash
# token in ResortTimer) and the coalesced relayout idle (on_text_configure) - both
# now through the leash mixin's `my later`. leash's destructor cancels whatever is
# still pending, so destroying an instance with either armed can no longer resume
# into "invalid command name ::oo::ObjNN" (the use-after-free at the level of names
# that leash-1.0.tm exists to retire). See GitHub issue #40.
#
# This test arms both timers and checks the pair of cases: while the object is
# alive the arms fire, and once it is destroyed the same arms fire nothing and
# raise no background error.

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name\n  expected: $expected\n  actual:   $actual"
        incr ::fails
    } else { puts "ok:   $name" }
}

# Background errors (a timer firing into a dead command surfaces here) are captured
# rather than shown, so the dead-object case can assert none were raised.
set ::BGERR [list]
proc capture_bgerror {msg} { lappend ::BGERR $msg }
interp bgerror {} capture_bgerror

set RESORTDELAY 50

# The private timer state, read straight out of the object's instance namespace -
# the same slots schedule_resort / on_text_configure write, no accessor method
# needed. ResortTimer holds a leash token (or "") and RelayoutPending a 0/1 flag.
proc peek {h var} { return [set [info object namespace $h]::$var] }

# A plain StreamTree instance drives this test - its default hooks render a row
# from the payload's label, which is all a timer test needs. Two one-off overrides
# count the methods the timers reach (do_resort, relayout), chaining on with
# `next`; this per-object instrumentation follows the objdefine pattern in
# test-streamtree-attrs.tcl rather than earning a whole subclass.
proc build_probe {w} {
    frame $w
    pack $w
    set h [::streamtree::StreamTree new]
    $h configure -resortdelay $::RESORTDELAY
    oo::objdefine $h {
        method do_resort {} { incr ::RESORTS; next }
        method relayout {} { incr ::RELAYOUTS; next }
    }
    $h setup $w
    # A fresh tree has no sortable column, so SortKey is "" - not "date", so the
    # sort is non-default and schedule_resort arms rather than no-opping.
    set root [$h insert "" folder root {label Root}]
    $h expand $root
    $h insert $root item a {label a}
    $h insert $root item b {label b}
    update
    return $h
}

# Arm both deferred paths: a distinct width arms the coalesced relayout idle, and
# schedule_resort arms the debounced resort timer under the non-default sort.
proc arm_both {h} {
    $h on_text_configure 12345
    $h schedule_resort
}

# Pump the event loop long enough for an idle handler and the resort timer to come
# due, then return. vwait processes idles and due timers alike.
proc pump {} {
    set ::woke 0
    after [expr {$::RESORTDELAY + 200}] {set ::woke 1}
    vwait ::woke
}

# ---- alive: the arms are real and fire ----------------------------------
#
# Proves the two timers genuinely arm and resume, so the dead-object case below is
# not vacuously green (nothing armed would also fire nothing).
wm deiconify .
set h1 [build_probe .p1]
# Reset after the build settles: setup itself relayouts, so only the armed timers
# below should show in the counts.
set ::RESORTS 0
set ::RELAYOUTS 0
arm_both $h1
check "a live resort arms a leash token" 1 [expr {[peek $h1 ResortTimer] ne ""}]
check "a live relayout marks itself pending" 1 [peek $h1 RelayoutPending]
pump
check "the resort fired while the object was alive" 1 $::RESORTS
check "the relayout fired while the object was alive" 1 [expr {$::RELAYOUTS >= 1}]
$h1 destroy

# ---- destroyed: the pending arms fire nothing, and raise nothing ---------
#
# The heart of issue #40: arm both, destroy with both pending, pump past the
# delay. With the raw `after` the resort timer would resume into the destroyed
# object's `my` command (a background error); leashed, the destructor cancels it.
set h2 [build_probe .p2]
set ::RESORTS 0
set ::RELAYOUTS 0
set ::BGERR [list]
arm_both $h2
check "both timers are pending before destroy" 1 \
    [expr {[peek $h2 ResortTimer] ne "" && [peek $h2 RelayoutPending]}]
set cmd $h2
$h2 destroy
check "the object command is gone after destroy" "" [info commands $cmd]
pump
check "no resort fired into the dead object" 0 $::RESORTS
check "no relayout fired into the dead object" 0 $::RELAYOUTS
check "no background error was raised" {} $::BGERR

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
