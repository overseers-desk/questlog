#!/usr/bin/env wish9.0
# What the toolbar publishes. The toolbar owns the search and the bounds (the
# criteria bar) and nothing
# else: every control change publishes the whole snapshot, and that snapshot
# carries the search and bounds keys and no view-filter key at all. The filters are
# the list strip's, driven through the streamtree attribute controls and covered
# in test-filter-strip; the toolbar never sees them.

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
wm withdraw .

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

# The subscriber the app is: every control change publishes the whole snapshot.
set ::Published {}
$TB subscribe [list apply {{snap} {set ::Published $snap}}]

# ---- the publish contract: the search and bounds keys, and no view-filter key ----

# The snapshot carries exactly the search and bounds keys - what the toolbar owns.
# The filters (running/bookmarked/model) are the list strip's, so no listview key
# rides here for a reader to mistake for a bound or a search.
set snap [$TB snapshot]
check "the snapshot has no view-filter key" 0 [dict exists $snap listview]
check "it publishes the search key" 1 [dict exists $snap search]
check "it publishes the bounds keys" {1 1 1 1} \
    [list [dict exists $snap subtree] [dict exists $snap file] \
          [dict exists $snap since] [dict exists $snap min_turns]]

# ---- search and bounds controls publish -----------------------------------------

# The Aa toggle publishes with the case bit flipped; nothing else moves, and still
# no view-filter key rides the publish. The toggle is the search field module's,
# at the widget path it documents.
.tb.search.case invoke
check "Aa toggle publishes search_case set" 1 [dict get $::Published search_case]
check "and the publish still carries no view-filter key" 0 [dict exists $::Published listview]
.tb.search.case invoke
check "releasing Aa publishes search_case clear" 0 [dict get $::Published search_case]

# The regions picker publishes the region-spec the search terms must appear in.
# Driven through the module's own menu: entry 2 is "tool calls", the tool-use
# region.
.tb.search.scope.m invoke 2
check "the region pick publishes search_regions" tool-use [dict get $::Published search_regions]

# The typed search text publishes on the one publish path (Return / a launch seed).
$TB set_search "needle"
$TB publish_now
check "the search text reaches the snapshot" needle [dict get $::Published search]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
