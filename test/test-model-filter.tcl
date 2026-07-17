#!/usr/bin/env tclsh9.0
# The model lens in lib/sessionlist.tcl: a pure view filter over rows already
# loaded, the third clause of row_visible beside bookmarked_only and
# running_only. Its state is model_excluded, the labels the reader shut off: a
# row hides when its model is known AND on that list, so one model can be
# excluded while the rest stay, and a label first seen after the reader chose
# shows by default. A row whose model is empty or absent stays, because the
# cost pass fills models in after the row lands and hiding on absence would
# flicker the list as it does.
# Tk-free: hand-built snapshot and row dicts drive row_visible directly.
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT lib sessionlist.tcl]

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
proc visible {snapshot row {running_set {}}} {
    return [::questlog::sessionlist::row_visible $snapshot $row $running_set]
}

set opus    [dict create uuid aaaa model {Opus 4.8}]
set sonnet  [dict create uuid bbbb model {Sonnet 5}]
set blank   [dict create uuid cccc model ""]
set pending [dict create uuid dddd]   ;# no model key: cost pass has not landed

# ---- nothing excluded: every row shows, whatever its model says --------------
set snap [dict create listview [dict create]]
check nothing_excluded_opus   1 [visible $snap $opus]
check nothing_excluded_sonnet 1 [visible $snap $sonnet]
check nothing_excluded_blank  1 [visible $snap $blank]
check nothing_excluded_absent 1 [visible $snap $pending]
# A snapshot without the listview sub-key at all behaves the same, as does an
# explicit empty exclusion list.
check no_listview   1 [visible [dict create] $opus]
check empty_list_off 1 [visible \
    [dict create listview [dict create model_excluded {}]] $sonnet]

# ---- one label excluded: only the known carrier hides -----------------------
set snap [dict create listview [dict create model_excluded [list {Sonnet 5}]]]
check excluded_hides   0 [visible $snap $sonnet]
check others_stay      1 [visible $snap $opus]
check blank_stays      1 [visible $snap $blank]
check absent_stays     1 [visible $snap $pending]

# ---- exclusion is per label: several labels, several cuts --------------------
set snap [dict create listview \
    [dict create model_excluded [list {Sonnet 5} {Opus 4.8}]]]
check both_excluded_a 0 [visible $snap $opus]
check both_excluded_b 0 [visible $snap $sonnet]
check unknown_survives_full_cut 1 [visible $snap $pending]

# ---- a label no row carries cuts nothing (a late-loading model shows) --------
set snap [dict create listview [dict create model_excluded [list {Haiku 4.5}]]]
check absent_label_cuts_nothing_a 1 [visible $snap $opus]
check absent_label_cuts_nothing_b 1 [visible $snap $sonnet]

# ---- composes with bookmarked_only: both clauses must admit the row ---------
set snap [dict create listview \
    [dict create model_excluded [list {Sonnet 5}] bookmarked_only 1]]
check bm_and_kept      1 [visible $snap [dict merge $opus {bookmarked 1}]]
check bm_but_excluded  0 [visible $snap [dict merge $sonnet {bookmarked 1}]]
check kept_not_bm      0 [visible $snap $opus]

# ---- composes with running_only: liveness and the exclusion both gate --------
set live [dict create aaaa p bbbb p]
set snap [dict create listview \
    [dict create model_excluded [list {Sonnet 5}] running_only 1]]
check run_and_kept     1 [visible $snap $opus $live]
check run_but_excluded 0 [visible $snap $sonnet $live]
check kept_not_run     0 [visible $snap $opus]

# ---- all three lenses at once: every clause must admit the row ---------------
# Running and Bookmarked latch independently, so both can be on, and the row
# that shows is running AND bookmarked AND not shut off. Running alone is not
# enough, and neither is the bookmark: the clauses AND, they do not widen each
# other.
set snap [dict create listview [dict create \
    model_excluded [list {Sonnet 5}] running_only 1 bookmarked_only 1]]
check all_three_admit   1 [visible $snap [dict merge $opus {bookmarked 1}] $live]
check running_not_bm    0 [visible $snap $opus $live]
check bm_not_running    0 [visible $snap [dict merge $opus {bookmarked 1}]]
check excluded_despite_both 0 \
    [visible $snap [dict merge $sonnet {bookmarked 1}] $live]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
