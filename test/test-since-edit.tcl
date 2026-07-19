#!/usr/bin/env wish9.0
# The time row's typed windows.
#
# Issue #36: the fixed 24h/7d/30d radios became two typed windows - a count of
# hours and a count of days - plus "all" and the custom member. A count is a
# spinbox the bar owns, so the two rules the min-turns floor answers meet here
# too:
#
#   1. a half-typed count is not a criterion. It is published only when it is
#      committed (Return, an arrow, or its unit radio), so a digit on the way to a
#      number never re-runs the search;
#   2. a half-typed count is not lost either. The row is redrawn whenever anything
#      else in the bar moves, and re-reading the model over a typed value would
#      revert it - so the model is read back only when the model itself moved.
#
# And the placement rule the issue turns on: a whole number of hours or days is
# expressed inline by the spinboxes, so it is not parked as a redundant custom
# member; weeks, minutes and dates still are.

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
foreach f {config.tcl lib/debug.tcl lib/cost.tcl ui/theme.tcl lib/path.tcl \
           lib/scan.tcl lib/listfilter.tcl lib/search.tcl ui/toolbar.tcl} {
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

# The bar rests collapsed; open the time editor the way a user would.
$TB begin_edit since
update

set ED .tb.crit.bar.body.rows.ed_since
set HN $ED.n_hours
set DN $ED.n_days

# ---- the row's shape: two counts, two units, all, and a custom opener --------

check hours_spinbox_is_there 1 [winfo exists $HN]
check days_spinbox_is_there  1 [winfo exists $DN]
check hours_unit_radio       1 [winfo exists $ED.u_hours]
check days_unit_radio        1 [winfo exists $ED.u_days]
check all_radio              1 [winfo exists $ED.rall]
check custom_opener          1 [winfo exists $ED.custom.open]
# The 30d preset is gone; there are no old preset radios left behind.
check no_preset_radios {0 0 0} \
    [list [winfo exists $ED.r24h] [winfo exists $ED.r7d] [winfo exists $ED.r30d]]

# ---- the default (7d) reconstructs into the days window ----------------------

check opens_on_the_days_default 7 [$DN get]
check hours_seed_is_its_default 24 [$HN get]
check default_since_is_7d 7d [dict get [$TB snapshot] since]

proc type {w n} { $w delete 0 end; $w insert 0 $n; update }
proc commit {w} { focus -force $w; update; event generate $w <Return>; update }

# ---- rule 1: a typed count is not published until it is committed ------------

set ::Published [$TB snapshot]
type $DN 12
check typed_count_is_not_published 7d [dict get [$TB snapshot] since]
check and_the_spinbox_shows_what_was_typed 12 [$DN get]

# ---- rule 2: a redraw elsewhere leaves the typed count standing --------------

$TB begin_edit pattern
update
check typed_count_survives_a_tail_reveal 12 [$DN get]
check and_it_is_still_unpublished 7d [dict get [$TB snapshot] since]

# Committing the days count publishes it and reaches the subscriber.
commit $DN
check committed_days_is_published 12d [dict get [$TB snapshot] since]
check and_it_reached_the_subscriber 12d [dict get $::Published since]

# ---- editing the hours count selects the hours window -----------------------

type $HN 48
commit $HN
check hours_commit_selects_hours 48h [dict get [$TB snapshot] since]
# The days count is remembered, not lost, when the hours window takes over.
check days_count_is_remembered 12 [$DN get]

# ---- the all member drops the bound -----------------------------------------

$ED.rall invoke
update
check all_drops_the_bound all [dict get [$TB snapshot] since]

# ---- a bad count snaps to 1 on commit, and the field is rewritten -----------

type $HN xyz
commit $HN
check garbage_count_snaps_to_one 1h [dict get [$TB snapshot] since]
check and_the_field_shows_the_clamp 1 [$HN get]

# ---- placement: hours/days are inline, weeks/dates are the custom member -----

check hd_is_inline    1 [$TB is_inline_since 24h]
check days_is_inline  1 [$TB is_inline_since 30d]
check all_is_inline   1 [$TB is_inline_since all]
check weeks_not_inline 0 [$TB is_inline_since 2w]
check minutes_not_inline 0 [$TB is_inline_since 90m]
check date_not_inline 0 [$TB is_inline_since 2026-04-01]

# A launch --since of a whole-day count lands in the days window, no custom member.
$TB set_window 5d
$TB publish_now
update
check launch_days_lands_inline 5d [dict get [$TB snapshot] since]
check no_custom_member_for_5d 1 [winfo exists $ED.custom.open]

# A launch --since of weeks lands as the custom member instead.
$TB set_window 2w
$TB publish_now
update
check launch_weeks_is_custom 2w [dict get [$TB snapshot] since]
check custom_member_radio_is_there 1 [winfo exists $ED.custom.r]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
