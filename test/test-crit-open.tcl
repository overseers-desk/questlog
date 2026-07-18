#!/usr/bin/env wish9.0
# The criteria bar's opening face, and the count it carries.
#
# Two things the toolbar asks of the querybuilder bar it hosts, both host-side
# and neither the module's own default:
#
#   1. the bar opens collapsed. Its resting face is the chip summary - the seeded
#      window and turn floor shown as chips under the disclosure - and it expands
#      only when the user goes to edit a criterion. The module opens expanded, as
#      every other host wants; the toolbar calls collapse after setup.
#   2. the heading count is what the user has added. It sums the values of the
#      four content criteria (folder, file, regex, tool) and leaves the standing
#      window and turn floor out, so a bare launch - where the seed is in force
#      but the user has chosen nothing - shows no count, and three file values
#      read "3 active". The toolbar names the four in -countables.
#
# Also a label the design words: the folder row's tag reads "folder" over the
# connective "ran under".

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

set TB  [::questlog::ui::Toolbar new .tb /tmp]
pack .tb -fill x
update
set BAR  [lindex [info class instances ::querybuilder::QueryBuilder] 0]
set BODY .tb.crit.bar.body

# ---- rule 1: the bar opens collapsed to its chip summary --------------------

check "the bar opens collapsed" 0 [$BAR expanded]
check "its resting face is the chip strip, not the editor rows" {1 0} \
    [list [winfo exists $BODY.strip] [winfo exists $BODY.rows]]
check "the seeded window and turn floor show there as chips" {1 1} \
    [list [winfo exists $BODY.strip.tag_since] [winfo exists $BODY.strip.tag_min_turns]]

# ---- rule 2: the count is the values the user added, over the content facets -

check "a bare launch shows no count: the seed is in force, but the user chose nothing" \
    "Restrict to sessions that…" [.tb.crit.bar.head.hd cget -text]

foreach p {/tmp/aaa.tcl /tmp/bbb.tcl /tmp/ccc.tcl} {
    $TB add_value file [list either $p]
}
update
check "three file values reach the snapshot" 3 [llength [dict get [$TB snapshot] file]]
check "and the heading counts them, and only them, as three" \
    "Restrict to sessions that…   3 active" [.tb.crit.bar.head.hd cget -text]

# The window and floor still hold their seeded value; they simply do not count.
check "the standing window is still in force" 7d [dict get [$TB snapshot] since]
check "and the turn floor is too" 2 [dict get [$TB snapshot] min_turns]

# ---- the design's words on the folder row and the model filter ---------------

$BAR expand
update
check "the folder row's tag reads 'folder'" folder [$BODY.rows.tag_subtree cget -text]
check "over the connective 'ran under'" "ran under" [$BODY.rows.conn_subtree cget -text]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
