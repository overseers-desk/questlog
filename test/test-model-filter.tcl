#!/usr/bin/env tclsh9.0
# The model lens in lib/sessionlist.tcl: a pure view filter over rows already
# loaded, the third clause of row_visible beside bookmarked_only and
# running_only. Set, it hides a row whose model is known and different; a row
# whose model is empty or absent stays, because the cost pass fills models in
# after the row lands and hiding on absence would flicker the list as it does.
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

set opus    [dict create uuid aaaa model claude-opus-4-8]
set sonnet  [dict create uuid bbbb model claude-sonnet-5]
set blank   [dict create uuid cccc model ""]
set pending [dict create uuid dddd]   ;# no model key: cost pass has not landed

# ---- no model filter: every row shows, whatever its model says --------------
set snap [dict create listview [dict create]]
check no_filter_opus   1 [visible $snap $opus]
check no_filter_sonnet 1 [visible $snap $sonnet]
check no_filter_blank  1 [visible $snap $blank]
check no_filter_absent 1 [visible $snap $pending]
# A snapshot without the listview sub-key at all behaves the same.
check no_listview      1 [visible [dict create] $opus]

# ---- filter set: only a known mismatch hides ---------------------------------
set snap [dict create listview [dict create model claude-opus-4-8]]
check match_shows    1 [visible $snap $opus]
check mismatch_hides 0 [visible $snap $sonnet]
check blank_stays    1 [visible $snap $blank]
check absent_stays   1 [visible $snap $pending]

# ---- composes with bookmarked_only: both clauses must admit the row ---------
set snap [dict create listview [dict create model claude-opus-4-8 bookmarked_only 1]]
check bm_and_match   1 [visible $snap [dict merge $opus {bookmarked 1}]]
check bm_wrong_model 0 [visible $snap [dict merge $sonnet {bookmarked 1}]]
check match_not_bm   0 [visible $snap $opus]

# ---- composes with running_only: liveness and model both gate ---------------
set live [dict create aaaa p bbbb p]
set snap [dict create listview [dict create model claude-opus-4-8 running_only 1]]
check run_and_match   1 [visible $snap $opus $live]
check run_wrong_model 0 [visible $snap $sonnet $live]
check match_not_run   0 [visible $snap $opus]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
