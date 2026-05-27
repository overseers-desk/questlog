package require Tcl 9
package require Tk

# ::questlog::ui::drag - shared press-motion-release machinery for dragging a
# session onto a target folder. The widget that owns the drag supplies two
# callbacks so this module needs no knowledge of how targets are drawn:
#   hit   X Y      -> an opaque candidate id under the pointer, or "" for none
#   paint old new  -> clear the old candidate's highlight, mark the new one
# A press-and-release without motion is a click; the caller learns this from
# the return value of release and runs its own click handler.
#
# State is a single namespace dict; one drag at a time. No class because
# there is no joint state across operations.

namespace eval ::questlog::ui::drag {
    variable State [dict create]
    variable Threshold 6
    variable ScrollMs 60
}

# Begin tracking a potential drag.
#   source: widget where the press occurred (grab, cursor, autoscroll target).
#   press_x, press_y: %X %Y root coords from the press event.
#   payload: opaque value handed back to on_drop (e.g. the session paths).
#   on_drop: cmd prefix; called {*}$on_drop $payload $candidate on a release
#            over a candidate.
#   hit, paint: the target-resolution callbacks described above.
proc ::questlog::ui::drag::watch {source press_x press_y payload on_drop hit paint} {
    variable State
    set State [dict create \
        source $source \
        x0 $press_x y0 $press_y \
        active 0 candidate "" \
        autoscroll "" \
        payload $payload on_drop $on_drop hit $hit paint $paint]
}

proc ::questlog::ui::drag::motion {X Y} {
    variable State
    variable Threshold
    if {[dict size $State] == 0} return
    if {![dict get $State active]} {
        set dx [expr {abs($X - [dict get $State x0])}]
        set dy [expr {abs($Y - [dict get $State y0])}]
        if {$dx < $Threshold && $dy < $Threshold} return
        dict set State active 1
        set src [dict get $State source]
        grab set $src
        $src configure -cursor fleur
    }
    set src [dict get $State source]
    set old_candidate [dict get $State candidate]
    set new_candidate ""
    set under [winfo containing $X $Y]
    if {$under eq $src} {
        set new_candidate [{*}[dict get $State hit] $X $Y]
        set ty [expr {$Y - [winfo rooty $src]}]
        set h  [winfo height $src]
        if {$ty < 16} {
            schedule_scroll -1
        } elseif {$ty > $h - 16} {
            schedule_scroll 1
        } else {
            cancel_scroll
        }
    } else {
        cancel_scroll
    }
    if {$new_candidate ne $old_candidate} {
        {*}[dict get $State paint] $old_candidate $new_candidate
        dict set State candidate $new_candidate
    }
}

# Finish a drag. Returns 1 if a drag was active (the drop handler is
# dispatched when the cursor was over a candidate, suppressed otherwise).
# Returns 0 if motion never crossed the threshold, telling the caller to run
# its normal click handler.
proc ::questlog::ui::drag::release {X Y} {
    variable State
    if {[dict size $State] == 0} { return 0 }
    set src [dict get $State source]
    set was_active [dict get $State active]
    set candidate [dict get $State candidate]
    set payload [dict get $State payload]
    set on_drop [dict get $State on_drop]
    set paint [dict get $State paint]
    cancel_scroll
    if {$was_active} {
        grab release $src
        $src configure -cursor ""
    }
    if {$candidate ne ""} { {*}$paint $candidate "" }
    set State [dict create]
    if {$was_active && $candidate ne ""} {
        {*}$on_drop $payload $candidate
    }
    return $was_active
}

proc ::questlog::ui::drag::schedule_scroll {direction} {
    variable State
    variable ScrollMs
    if {[dict size $State] == 0} return
    set existing [dict get $State autoscroll]
    if {$existing ne ""} return
    set id [after $ScrollMs [list ::questlog::ui::drag::scroll_tick $direction]]
    dict set State autoscroll $id
}

proc ::questlog::ui::drag::scroll_tick {direction} {
    variable State
    variable ScrollMs
    if {[dict size $State] == 0} return
    if {![dict get $State active]} return
    set src [dict get $State source]
    $src yview scroll $direction units
    set id [after $ScrollMs [list ::questlog::ui::drag::scroll_tick $direction]]
    dict set State autoscroll $id
}

proc ::questlog::ui::drag::cancel_scroll {} {
    variable State
    if {[dict size $State] == 0} return
    set id [dict get $State autoscroll]
    if {$id ne ""} {
        after cancel $id
        dict set State autoscroll ""
    }
}
