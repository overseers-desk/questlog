package require Tcl 9
package require Tk

# ::csm::ui::drag - shared press-motion-release machinery used by the
# tree and results panes to drag a session onto a target folder row in
# the tree. The drop target is a ttk::treeview; an F:* iid under the
# pointer is the candidate. Press-and-release without motion is a click
# and the caller is told so via the return value of release.
#
# State is a single namespace dict; one drag at a time. No class
# because there is no joint state across operations.

namespace eval ::csm::ui::drag {
    variable State [dict create]
    variable Threshold 6
    variable ScrollMs 60
}

# Begin tracking a potential drag.
# source: widget where the press occurred (used for grab + cursor).
# target: the ttk::treeview we drop onto.
# press_x, press_y: %X %Y root coords from the press event.
# payload: opaque value handed back to on_drop.
# on_drop: cmd prefix; called as `{*}$on_drop $payload $target_folder`
# when release lands on an F:* row.
proc ::csm::ui::drag::watch {source target press_x press_y payload on_drop} {
    variable State
    set State [dict create \
        source $source target $target \
        x0 $press_x y0 $press_y \
        active 0 candidate "" \
        autoscroll "" \
        payload $payload on_drop $on_drop]
    if {[lsearch -exact [$target tag names] drop-candidate] < 0} {
        $target tag configure drop-candidate -background "#cce5ff"
    }
}

proc ::csm::ui::drag::motion {X Y} {
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
    set tgt [dict get $State target]
    set under [winfo containing $X $Y]
    set old_candidate [dict get $State candidate]
    set new_candidate ""
    if {$under eq $tgt} {
        set tx [expr {$X - [winfo rootx $tgt]}]
        set ty [expr {$Y - [winfo rooty $tgt]}]
        set iid [$tgt identify item $tx $ty]
        if {[string match "F:*" $iid]} { set new_candidate $iid }
        set h [winfo height $tgt]
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
        if {$old_candidate ne ""} { $tgt tag remove drop-candidate $old_candidate }
        if {$new_candidate ne ""} { $tgt tag add    drop-candidate $new_candidate }
        dict set State candidate $new_candidate
    }
}

# Finish a drag. Returns 1 if a drag was active (drop handler dispatched
# if the cursor was over a folder row; suppressed otherwise). Returns 0
# if motion never crossed the threshold, in which case the caller should
# run its normal click handler.
proc ::csm::ui::drag::release {X Y} {
    variable State
    if {[dict size $State] == 0} { return 0 }
    set src [dict get $State source]
    set tgt [dict get $State target]
    set was_active [dict get $State active]
    set candidate [dict get $State candidate]
    set payload [dict get $State payload]
    set on_drop [dict get $State on_drop]
    cancel_scroll
    if {$was_active} {
        grab release $src
        $src configure -cursor ""
    }
    if {$candidate ne ""} {
        $tgt tag remove drop-candidate $candidate
    }
    set State [dict create]
    if {$was_active && $candidate ne ""} {
        set folder [string range $candidate 2 end]
        {*}$on_drop $payload $folder
    }
    return $was_active
}

proc ::csm::ui::drag::schedule_scroll {direction} {
    variable State
    variable ScrollMs
    if {[dict size $State] == 0} return
    set existing [dict get $State autoscroll]
    if {$existing ne ""} return
    set id [after $ScrollMs [list ::csm::ui::drag::scroll_tick $direction]]
    dict set State autoscroll $id
}

proc ::csm::ui::drag::scroll_tick {direction} {
    variable State
    variable ScrollMs
    if {[dict size $State] == 0} return
    if {![dict get $State active]} return
    set tgt [dict get $State target]
    $tgt yview scroll $direction units
    set id [after $ScrollMs [list ::csm::ui::drag::scroll_tick $direction]]
    dict set State autoscroll $id
}

proc ::csm::ui::drag::cancel_scroll {} {
    variable State
    if {[dict size $State] == 0} return
    set id [dict get $State autoscroll]
    if {$id ne ""} {
        after cancel $id
        dict set State autoscroll ""
    }
}
