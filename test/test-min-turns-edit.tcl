#!/usr/bin/env wish9.0
# The min-turns editor's uncommitted edit.
#
# min turns is the one criterion in the bar that is TYPED into a widget the bar
# owns, rather than typed into an add editor and committed as a chip. Two rules
# meet there, and both have to hold at once:
#
#   1. a half-typed floor is not a criterion. It is published only when it is
#      committed (Return, FocusOut, a spinbox arrow), so a "1" on the way to "15"
#      never re-runs the search over a floor nobody asked for;
#   2. a half-typed floor is not lost either. An editor is a function of the
#      model, so the bar redraws this row whenever anything else in it moves - a
#      tail facet revealed, a value dropped, a collapse - and re-reading the model
#      over the top of a typed value would silently revert it. The chip editors
#      keep their text in AddText for exactly this reason; this one keeps it in
#      the spinbox, and reads the model back only when the model itself moved.
#
# Rule 1 without rule 2 is the regression this test exists to catch: type 5, touch
# anything else in the bar, and the spinbox is back to 2 with no word said.

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
foreach f {config.tcl lib/debug.tcl lib/cost.tcl ui/theme.tcl lib/path.tcl \
           lib/scope.tcl lib/listfilter.tcl lib/search.tcl ui/toolbar.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name"
        puts "  expected: <$expected>"
        puts "  actual:   <$actual>"
        incr ::fails
    } else {
        puts "ok:   $name"
    }
}

set TB [::questlog::ui::Toolbar new .tb /tmp]
pack .tb -fill x
update

set ::Published {}
$TB subscribe [list apply {{snap} {set ::Published $snap}}]

# The bar rests collapsed; the editor rows exist only while it is expanded, so
# open the min-turns editor the way a user would before reaching into it.
$TB begin_edit min_turns
update

# The spinbox, at the path the querybuilder module documents for a control facet's
# editor area: <bar>.body.rows.ed_<id>.
set SB .tb.crit.bar.body.rows.ed_min_turns.sb
check editor_is_there 1 [winfo exists $SB]
check opens_on_the_default 2 [$SB get]

# Typing is an edit of the widget, not a commit: no Return, no focus change, no
# arrow. This is what a hand mid-number looks like.
proc type {n} {
    $::SB delete 0 end
    $::SB insert 0 $n
    update
}

# Return commits, and a key event reaches a widget only through the focus, so the
# commit takes the caret first - which is where it is in the hand's version of
# this: the number was just typed there.
proc commit {} {
    focus -force $::SB
    update
    event generate $::SB <Return>
    update
}

# ---- rule 1: a typed floor is not published until it is committed -----------

set ::Published [$TB snapshot]
type 5
check typed_floor_is_not_published 2 [dict get [$TB snapshot] min_turns]
check and_the_spinbox_shows_what_was_typed 5 [$SB get]

# ---- rule 2: a redraw elsewhere in the bar leaves it standing ---------------

# Reveal a tail facet: the rail loses the "+ regex" button and the bar grows an
# editor row, so every row is drawn again - including this one.
$TB begin_edit pattern
update
check typed_floor_survives_a_tail_reveal 5 [$SB get]
check and_it_is_still_unpublished 2 [dict get [$TB snapshot] min_turns]

# A whole-model write from outside (here the cut banner's widen escape, dropping
# the since bound) redraws the bar top to bottom. min turns did not move, so the
# typed value must not either.
$TB widen since
update
check typed_floor_survives_a_set_model 5 [$SB get]
check the_widen_took_effect all [dict get [$TB snapshot] since]

# ---- the commit still commits ----------------------------------------------

commit
check committed_floor_is_published 5 [dict get [$TB snapshot] min_turns]
check and_it_reached_the_subscriber 5 [dict get $::Published min_turns]
check and_the_spinbox_still_shows_it 5 [$SB get]

# ---- and a floor the MODEL moves still reaches the spinbox ------------------
#
# The other half of the invariant: the editor must follow the model when the
# model genuinely changes under it. Widen the min-turns criterion away and the
# spinbox goes back to the floor that excludes nothing.

$TB widen min_turns
update
check widen_clears_the_floor 1 [dict get [$TB snapshot] min_turns]
check and_the_spinbox_follows_the_model 1 [$SB get]

# A typed value out of range is clamped on commit, not on the way in: the cap is
# what the model gets, and the field is rewritten to it rather than left showing
# the number that was refused.
type 99
commit
check out_of_range_commit_is_clamped 9 [dict get [$TB snapshot] min_turns]
check and_the_field_shows_the_clamp 9 [$SB get]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
