#!/usr/bin/env tclsh9.0
# lens_counts in lib/sessionlist.tcl: shown/total/excluded for an active lens.
# A lens filters loaded rows only, so a true member the search never loaded is
# invisible; lens_counts is the pure arithmetic that surfaces that cut. The
# caller hands it the lens's whole membership (full_set, uuid-keyed) gathered
# outside the search; excluded counts members absent from the loaded rows and
# never a loaded row the lens merely hides. No lens on, or no membership
# context, means no cut reported.
# Tk-free: hand-built snapshot, row and set dicts drive lens_counts directly.
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
proc counts {snapshot rows full_set {running_set {}}} {
    return [::questlog::sessionlist::lens_counts $snapshot $rows $full_set $running_set]
}

set A [dict create uuid aaaa bookmarked 1 model claude-opus-4-8]
set B [dict create uuid bbbb bookmarked 0 model claude-sonnet-5]
set rows [list $A $B]

# ---- no lens active: no cut, even with an unloaded member in full_set -------
set snap [dict create listview [dict create]]
set c [counts $snap $rows [dict create aaaa 1 dddd 1]]
check no_lens_shown    2 [dict get $c shown]
check no_lens_total    2 [dict get $c total]
check no_lens_excluded 0 [dict get $c excluded]

# ---- Running lens, every running session loaded: excluded 0 -----------------
set snap [dict create listview [dict create running_only 1]]
set live [dict create aaaa p]
set c [counts $snap $rows [dict create aaaa 1] $live]
check run_all_loaded_shown    1 [dict get $c shown]
check run_all_loaded_total    1 [dict get $c total]
check run_all_loaded_excluded 0 [dict get $c excluded]

# ---- Running lens, a running session the search never loaded ----------------
set live [dict create aaaa p dddd p]
set c [counts $snap $rows [dict create aaaa 1 dddd 1] $live]
check run_cut_shown    1 [dict get $c shown]
check run_cut_total    2 [dict get $c total]
check run_cut_excluded 1 [dict get $c excluded]

# ---- empty full_set: no cut reported even with the lens on ------------------
set c [counts $snap $rows [dict create] [dict create aaaa p]]
check no_context_shown    1 [dict get $c shown]
check no_context_total    0 [dict get $c total]
check no_context_excluded 0 [dict get $c excluded]

# ---- a loaded row the lens hides is not a cut --------------------------------
# Bookmarked lens: B is loaded and hidden (not bookmarked); full_set holds one
# member the search missed. Only the missing member counts as excluded.
set snap [dict create listview [dict create bookmarked_only 1]]
set c [counts $snap $rows [dict create aaaa 1]]
check bm_hide_shown    1 [dict get $c shown]
check bm_hide_excluded 0 [dict get $c excluded]
set c [counts $snap $rows [dict create aaaa 1 eeee 1]]
check bm_cut_shown    1 [dict get $c shown]
check bm_cut_total    2 [dict get $c total]
check bm_cut_excluded 1 [dict get $c excluded]

# ---- lens_excluded names the same cut lens_counts counts --------------------
# The banner must NAME what the strip counts, so the two readings are one: the
# excluded count is the length of the excluded list, always.
proc excluded {snapshot rows full_set} {
    return [::questlog::sessionlist::lens_excluded $snapshot $rows $full_set]
}
set snap [dict create listview [dict create running_only 1]]
set live [dict create aaaa p dddd p ffff p]
check named_cut [list dddd ffff] [excluded $snap $rows $live]
check named_cut_agrees_with_count \
    [dict get [counts $snap $rows $live [dict create aaaa p dddd p ffff p]] excluded] \
    [llength [excluded $snap $rows $live]]
check named_no_lens {} [excluded [dict create listview {}] $rows $live]
check named_no_context {} [excluded $snap $rows [dict create]]

# ---- active_lens: which lens the caller narrates and gathers a set for -------
check lens_none  "" [::questlog::sessionlist::active_lens [dict create listview {}]]
check lens_run   running \
    [::questlog::sessionlist::active_lens [dict create listview {running_only 1}]]
check lens_bm    bookmarked \
    [::questlog::sessionlist::active_lens [dict create listview {bookmarked_only 1}]]
check lens_model model \
    [::questlog::sessionlist::active_lens [dict create listview {model {Opus 4.8}}]]
# A snapshot with no listview key at all is a lens-free one, not an error.
check lens_bare  "" [::questlog::sessionlist::active_lens [dict create since 7d]]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
