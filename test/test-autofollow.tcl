#!/usr/bin/env wish9.0
# The tail-follow contract: with -autofollow on and the reader at the tail, a
# bracketed streaming insert keeps the view latched to the tail; the latch
# releases the moment the reader scrolls away; <<AtBottom>>/<<LeftBottom>> fire
# on the host frame at the boundary; `follow` re-latches. With -autofollow off
# (the default) the reader's line never moves, wherever they are.

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add $ROOT
package require streamtree
set ::env(STREAMTREE_AUDIT) 1

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name\n  expected: $expected\n  actual:   $actual"
        incr ::fails
    } else { puts "ok:   $name" }
}
proc at_bottom {} { return [expr {[lindex [$::T yview] 1] >= 0.999}] }
proc top_line {} { return [lindex [split [$::T index @0,0] .] 0] }

pack [ttk::frame .f] -fill both -expand 1
set d [::streamtree::StreamTree new]
$d setup .f
set T .f.body.t
set n 0
proc pour {count} {
    global d n
    $d anchor_save
    for {set i 0} {$i < $count} {incr i} {
        $d insert "" row "r[incr n]" [dict create label "row $n"]
    }
    $d anchor_restore
}
set events {}
bind .f <<AtBottom>>   {lappend events atbottom}
bind .f <<LeftBottom>> {lappend events leftbottom}

pour 60
update
check "long pour leaves the top-pinned reader at the top" 1 [expr {[top_line] <= 1}]

# Default (-autofollow off): reader at the tail stays on their line, so the
# tail grows away below them.
$T yview moveto 1
update
set line0 [top_line]
pour 10
update
check "autofollow off: the reader's line holds through a tail append" $line0 [top_line]
check "autofollow off: the view is no longer at the tail" 0 [at_bottom]

# Autofollow on: latch at the tail, stream, still at the tail.
$d configure -autofollow 1
set events {}
$d follow
update
check "follow jumps to the tail" 1 [at_bottom]
check "reaching the tail fires <<AtBottom>> on the host frame" atbottom [lindex $events 0]
pour 10
update
check "autofollow on: the view keeps following streamed appends" 1 [at_bottom]
check "no boundary event while latched at the tail" 1 [llength $events]

# The latch releases when the reader scrolls away.
set events {}
$T yview moveto 0.3
update
check "leaving the tail fires <<LeftBottom>>" leftbottom [lindex $events 0]
set line1 [top_line]
pour 10
update
check "scrolled away: the reader's line holds, no yank to the tail" $line1 [top_line]
check "scrolled away: the view stays off the tail" 0 [at_bottom]

check "no audit trip" 0 [expr {[info exists ::STREAMTREE_AUDIT_TRIPPED] ? 1 : 0}]
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
