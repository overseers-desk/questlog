#!/usr/bin/env wish9.0
# Unit test for the A/H column: machine time over human time, shown as a scalar
# multiplier. The column cell is one decimal below 10 and whole from 10 up, and
# stays blank unless both figures exist and human time is above zero. Sorting is
# by the multiplier with blank rows sunk to the bottom, and the header reads A/H.

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
foreach f {config.tcl lib/cost.tcl ui/theme.tcl lib/path.tcl lib/scope.tcl \
           lib/listfilter.tcl lib/jsonl.tcl lib/match.tcl ui/terminal.tcl \
           ui/live.tcl lib/scan.tcl lib/search.tcl ui/drag.tcl ui/toolbar.tcl \
           ui/sessions.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

set SAND [file join [pwd] _ah_sandbox]
::questlog::path::_real_file delete -force $SAND
set ::env(HOME) $SAND

proc noop {args} {}
set SL [::questlog::ui::SessionList new .s noop noop noop noop noop noop \
            noop noop noop noop noop noop noop]

set fails 0
proc check {name got want} {
    if {$got eq $want} {
        puts "ok   - $name"
    } else {
        puts "FAIL - $name"
        puts "       got:  $got"
        puts "       want: $want"
        incr ::fails
    }
}

# A row as the model holds it: machine active time in duration_secs, capped
# human composing time in human_secs. The cell reads the ah column off meta_cells.
proc ah_cell {SL args} {
    return [dict get [$SL meta_cells [dict create {*}$args]] ah]
}

# ---- cell formatting -------------------------------------------------------
# 3600 machine over 300 human is 12x, whole from 10 up.
check "cell 3600/300 is whole 12" \
    [ah_cell $SL duration_secs 3600 human_secs 300] "12"
# 700 over 200 is 3.5x, one decimal below 10.
check "cell 700/200 is 3.5" \
    [ah_cell $SL duration_secs 700 human_secs 200] "3.5"

# ---- blank rule ------------------------------------------------------------
check "cell blank when human is 0" \
    [ah_cell $SL duration_secs 700 human_secs 0] ""
check "cell blank when human missing" \
    [ah_cell $SL duration_secs 700] ""
check "cell blank when duration missing" \
    [ah_cell $SL human_secs 200] ""

# ---- sort key --------------------------------------------------------------
# The multiplier is the sort value; the three blank shapes drop to the -1 sentinel.
check "sort key 3600/300 is 12.0" \
    [$SL sort_key [dict create duration_secs 3600 human_secs 300] ah] 12.0
check "sort key 700/200 is 3.5" \
    [$SL sort_key [dict create duration_secs 700 human_secs 200] ah] 3.5
check "sort key -1 when human 0" \
    [$SL sort_key [dict create duration_secs 700 human_secs 0] ah] -1
check "sort key -1 when human missing" \
    [$SL sort_key [dict create duration_secs 700] ah] -1
check "sort key -1 when duration missing" \
    [$SL sort_key [dict create human_secs 200] ah] -1

# Descending sort by the multiplier orders by machine/human, blanks last.
set rows [list \
    [dict create id big  duration_secs 3600 human_secs 300] \
    [dict create id mid  duration_secs 700  human_secs 200] \
    [dict create id low  duration_secs 100  human_secs 200] \
    [dict create id none duration_secs 700  human_secs 0]]
set keyed [list]
foreach r $rows {
    lappend keyed [list [dict get $r id] [$SL sort_key $r ah]]
}
set order [lmap p [lsort -real -decreasing -index 1 $keyed] { lindex $p 0 }]
check "descending A/H sort orders by multiplier, blank last" \
    $order {big mid low none}

# ---- header ----------------------------------------------------------------
foreach col [::questlog::ui::session_columns] {
    lassign $col id label
    if {$id eq "ah"} { set header $label }
}
check "the header cell reads A/H" $header "A/H"

::questlog::path::_real_file delete -force $SAND
if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
