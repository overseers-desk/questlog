#!/usr/bin/env wish9.0
# The toolbar's View row: the lenses over the rows already loaded.
#
# Two things are under test. First, Running and Bookmarked latch independently:
# either can be on without the other, and BOTH can be on at once, which the
# snapshot must carry as running_only 1 and bookmarked_only 1 together - that is
# the state the list reads as "running AND bookmarked". Neither one on is every
# loaded row, so the rest state is what says "all". Second, the model lens offers
# the models the loaded rows actually carry (read through the provider the app
# wires to the session list) plus "any model", and the pick lands in the
# snapshot's listview/model key that lib/sessionlist.tcl row_visible reads.
#
# The snapshot is the whole contract: the keys the list's predicate reads are
# asserted here, and the predicate itself in test-model-filter.

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add $ROOT
package require leash
foreach f {config.tcl lib/debug.tcl lib/cost.tcl ui/theme.tcl lib/path.tcl \
           lib/filter.tcl lib/sessionlist.tcl lib/search.tcl ui/toolbar.tcl} {
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

proc lv {key} {
    return [::questlog::sessionlist::toggle $::Published $key ""]
}

# ---- the two lenses latch independently -------------------------------------

# At rest: neither lens is on, and the list shows everything it loaded.
$TB set_lens running 0
$TB set_lens bookmarked 0
check "at rest: running_only off"    0 [lv running_only]
check "at rest: bookmarked_only off" 0 [lv bookmarked_only]

$TB set_lens running 1
check "Running on: running_only set"       1 [lv running_only]
check "Running on: bookmarked_only clear"  0 [lv bookmarked_only]

# Bookmarked joins Running rather than replacing it: the snapshot carries both,
# and the list shows the rows that are running AND bookmarked.
$TB set_lens bookmarked 1
check "both on: running_only set"    1 [lv running_only]
check "both on: bookmarked_only set" 1 [lv bookmarked_only]

# Releasing one leaves the other pressed.
$TB set_lens running 0
check "Running released: running_only clear" 0 [lv running_only]
check "Bookmarked stays on"                  1 [lv bookmarked_only]

$TB set_lens bookmarked 0
check "both released: running_only off"    0 [lv running_only]
check "both released: bookmarked_only off" 0 [lv bookmarked_only]

# The toggles are what the reader clicks, so the widgets themselves must reach
# the both-on state: invoking each in turn presses both, and the snapshot the
# clicks publish says so.
.tb.view.lens.running invoke
.tb.view.lens.bookmarked invoke
check "clicking both: running_only set"    1 [lv running_only]
check "clicking both: bookmarked_only set" 1 [lv bookmarked_only]
check "and both toggles render pressed" {1 1} \
    [list [.tb.view.lens.running instate selected] \
          [.tb.view.lens.bookmarked instate selected]]
.tb.view.lens.running invoke
.tb.view.lens.bookmarked invoke
check "clicking again releases both" {0 0} [list [lv running_only] [lv bookmarked_only]]

# ---- the model lens ----------------------------------------------------------

# The lens is empty until a model is picked, so a fresh snapshot filters nothing.
check "no model picked: lens empty" "" [lv model]

# The app wires the provider to the session list's loaded_models; here it stands
# in for one, carrying a local model the rate table does not know beside the two
# it does.
proc loaded_models {} { return {{Opus 4.8} {Sonnet 5} qwen3-coder} }
$TB set_models_provider loaded_models

# The menu is rebuilt from the provider at post time, so a model that arrives
# with the cost pass needs no rebuild of the row: "any model" first, then the
# models the rows carry, the unpriced one among them.
set m .tb.view.model.m
$TB refresh_model_menu $m
set labels {}
for {set i 0} {$i <= [$m index end]} {incr i} { lappend labels [$m entrycget $i -label] }
check "menu offers any + the models the rows carry" \
    {{any model} {Opus 4.8} {Sonnet 5} qwen3-coder} $labels

# Picking one puts the row's own model label in the snapshot - the value
# row_visible compares a row against.
$TB set_model "Sonnet 5"
check "picked model reaches the snapshot" "Sonnet 5" [lv model]
check "picking a model leaves the toggles alone" 0 [lv running_only]

# An unpriced local model is pickable like any other; its rows are reachable.
$TB set_model qwen3-coder
check "local model reaches the snapshot" "qwen3-coder" [lv model]

# "any model" clears the lens.
$TB set_model ""
check "any model clears the lens" "" [lv model]

# ---- the lenses are view-only ------------------------------------------------

# None of the above touches a scope or search key, which is what buys the fast
# path in app.tcl (scope_equal): the list re-filters in place and keeps its
# selection instead of re-reading the corpus.
$TB set_lens running 1
$TB set_lens bookmarked 1
$TB set_model "Opus 4.8"
foreach k {search search_case search_regions file tool pattern subtree since min_turns} {
    check "view change leaves $k at its default" \
        [dict get [dict create search "" search_case 0 search_regions any file {} \
                   tool {} pattern {} subtree {} \
                   since [::questlog::config::get since_default] \
                   min_turns [::questlog::config::get min_turns_default]] $k] \
        [dict get $::Published $k]
}

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
