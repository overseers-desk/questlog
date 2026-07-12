#!/usr/bin/env wish9.0
# A standalone demo of the StreamDoc widget: a streaming document of foldable
# regions drawn in one Tk text widget. It loads only the streamdoc module and
# a host supplies content and look through the door, the hooks and plain tag
# configuration - no other application code is involved.
#
# Run it with bare wish:   wish9.0 examples/streamdoc-demo.tcl
#
# Try: turn on "Stream steps" and watch regions pour in while you read -
# scroll anywhere and your line holds. Click a step's header to fold it, its
# summary line to reveal the hidden checks. "Follow tail" latches the view to
# the bottom (the tail -f contract) until you scroll away.

package require Tcl 9
package require Tk

set HERE [file dirname [file normalize [info script]]]
::tcl::tm::path add [file dirname $HERE]
package require streamdoc

font create DocBody {*}[font actual TkTextFont]
font create DocHead {*}[font actual TkTextFont] -weight bold

# A toy build feed: each step is a region whose header folds it, whose noisy
# checks hide behind a summary line, with chrome dividers between steps.
oo::class create DemoFeed {
    superclass ::streamdoc::StreamDoc
    variable Text

    constructor {parent} {
        my configure -font DocBody
        ttk::frame $parent.bar
        pack $parent.bar -side top -fill x
        ttk::label $parent.bar.t -text "StreamDoc demo - streaming foldable regions"
        pack $parent.bar.t -side left -padx 6 -pady 4
        pack [ttk::frame $parent.doc] -fill both -expand 1
        my setup $parent.doc
        $Text tag configure hdr -font DocHead -spacing1 8 -spacing3 2
        $Text tag configure chrome -foreground #8a8a8a -justify center
        $Text tag configure summary -foreground #8a8a8a
        $Text tag configure detail -foreground #4a6a8a \
            -lmargin1 18 -lmargin2 18
        $Text tag bind hdr <Button-1> [list [self] hdr_click %x %y]
        $Text tag bind summary <Button-1> [list [self] summary_click %x %y]
    }

    # ---- engine hooks ----
    method summary_text {payload} {
        set c [dict getdef $payload checks 0]
        if {!$c} { return "" }
        return "· $c check[expr {$c == 1 ? "" : "s"}] hidden"
    }

    # ---- host wiring: clicks resolve to a region through region_at ----
    method hdr_click {x y} {
        set n [my region_at [$Text index @$x,$y]]
        if {$n >= 0} { my toggle $n }
    }
    method summary_click {x y} {
        set n [my region_at [$Text index @$x,$y]]
        if {$n >= 0} { my detail_toggle $n }
    }

    # ---- the feed: one tick opens, extends, or closes a region ----
    variable StepN LinesLeft
    method tick {} {
        if {![info exists StepN]} { set StepN 0 }
        my batch {
            if {[my live] < 0} {
                set m [my append_open]
                if {$StepN > 0} { my emit $m "· · ·\n" chrome }
                my append_close $m
                set r [my region_open [dict create checks 0]]
                set m [my append_open]
                my emit $m "▾ Step [incr StepN]\n" hdr
                my append_close $m
                set LinesLeft [expr {3 + int(rand() * 4)}]
            } else {
                set r [my live]
                set m [my append_open]
                if {rand() < 0.4} {
                    my emit $m "  check [format %04x [expr {int(rand()*65536)}]] passed\n" \
                        [list detail [my detail_tag $r]]
                    set p [my payload $r]
                    my payload_set $r [dict create \
                        checks [expr {[dict getdef $p checks 0] + 1}]]
                } else {
                    my emit $m "  working at [clock format [clock seconds] -format %T]\n" {}
                }
                my append_close $m
                if {[incr LinesLeft -1] <= 0} { my region_close }
            }
        }
    }
}

pack [ttk::frame .f] -fill both -expand 1
.f configure -width 680 -height 480
set d [DemoFeed new .f]

# Seed a couple of steps so the fold gestures have targets before streaming.
for {set i 0} {$i < 8} {incr i} { $d tick }
while {[$d live] >= 0} { $d tick }

set ::streaming 0
set ::following 0
proc stream_tick {} {
    if {!$::streaming} return
    $::d tick
    after 500 stream_tick
}
proc follow_toggle {} {
    $::d configure -autofollow $::following
    if {$::following} { $::d follow }
}
ttk::checkbutton .f.bar.stream -text "Stream steps" -variable ::streaming \
    -command stream_tick
ttk::checkbutton .f.bar.follow -text "Follow tail" -variable ::following \
    -command follow_toggle
ttk::button .f.bar.fold -text "Fold all" -command {$::d fold_all}
ttk::button .f.bar.exp  -text "Expand all" -command {$::d expand_all}
ttk::label .f.bar.at -text ""
pack .f.bar.at .f.bar.follow .f.bar.stream .f.bar.exp .f.bar.fold \
    -side right -padx 4
bind .f.doc <<AtBottom>>   {.f.bar.at configure -text "at tail"}
bind .f.doc <<LeftBottom>> {.f.bar.at configure -text ""}
update
wm title . "StreamDoc demo"
