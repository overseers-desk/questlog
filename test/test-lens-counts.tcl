#!/usr/bin/env tclsh9.0
# lens_counts in lib/sessionlist.tcl: shown/total/excluded for the active lenses.
# A lens filters loaded rows only, so a true member the search never loaded is
# invisible; lens_counts is the pure arithmetic that surfaces that cut. The
# caller hands it the membership the lenses jointly claim (full_set, uuid-keyed)
# gathered outside the search, which with two lenses on is the intersection of
# their sets (lens_members); excluded counts members absent from the loaded rows
# and never a loaded row a lens merely hides. No lens on, or no membership
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

# ---- active_lenses: which lenses the caller narrates -------------------------
proc lenses {listview} {
    return [::questlog::sessionlist::active_lenses [dict create listview $listview]]
}
check lens_none  {} [lenses {}]
check lens_run   running    [lenses {running_only 1}]
check lens_bm    bookmarked [lenses {bookmarked_only 1}]
check lens_model model      [lenses {model_excluded {{Opus 4.8}}}]
# Each lens latches on its own, so every combination is reachable, and the caller
# is told about all of them - naming one and dropping the other would leave the
# reader a count measured against a lens the words never mention.
check lens_both  {running bookmarked} [lenses {running_only 1 bookmarked_only 1}]
check lens_all   {running bookmarked model} \
    [lenses {running_only 1 bookmarked_only 1 model_excluded {{Opus 4.8}}}]
# A snapshot with no listview key at all is a lens-free one, not an error.
check lens_bare  {} [::questlog::sessionlist::active_lenses [dict create since 7d]]

# ---- member_lenses: the lenses that can say what the search left on disk ------
# The model lens is not one of them: a row's model is known only once its
# transcript is parsed, and a filter parses nothing, so it can claim no member it
# cannot see.
proc mlenses {listview} {
    return [::questlog::sessionlist::member_lenses [dict create listview $listview]]
}
check member_none  {} [mlenses {}]
check member_model {} [mlenses {model_excluded {{Opus 4.8}}}]
check member_run   running [mlenses {running_only 1 model_excluded {{Opus 4.8}}}]
check member_both  {running bookmarked} [mlenses {running_only 1 bookmarked_only 1}]

# ---- lens_members: two lenses on means the INTERSECTION of their sets ---------
# aaaa is running and bookmarked; bbbb runs without a bookmark; cccc is a
# bookmark that is not running. Under both lenses only aaaa is a member: the list
# would show bbbb or cccc under neither, so neither is something the search cut.
set RUN [dict create aaaa [dict create path a.jsonl cwd /p/a] \
                     bbbb [dict create path b.jsonl cwd /p/b]]
set BM  [dict create aaaa [dict create path a.jsonl] \
                     cccc [dict create path c.jsonl]]
proc members {args} { return [::questlog::sessionlist::lens_members $args] }
check members_none  {} [::questlog::sessionlist::lens_members {}]
check members_one   {aaaa bbbb} [dict keys [members $RUN]]
check members_both  aaaa        [dict keys [members $RUN $BM]]
# The intersected member keeps what either set knew of it: the cwd the registry
# records names the session for the banner without opening its transcript.
check members_keep_cwd /p/a [dict get [members $RUN $BM] aaaa cwd]
# Disjoint sets intersect to nothing, and no cut is claimed at all.
check members_disjoint {} [members [dict create bbbb {}] [dict create cccc {}]]

# ---- both lenses on: the cut is measured against the intersection -------------
# The loaded rows hold aaaa (running, bookmarked) and bbbb (running, not
# bookmarked). dddd is running and bookmarked but was never loaded - it is the
# one member the search cut. The two rows the lenses hide (bbbb) and the running
# session that carries no bookmark (eeee, not a member at all) must not swell
# that count: if they did, the banner would report sessions the search never
# withheld from this view.
set snap [dict create listview [dict create running_only 1 bookmarked_only 1]]
set both_rows [list [dict create uuid aaaa bookmarked 1] \
                    [dict create uuid bbbb bookmarked 0]]
set live [dict create aaaa p bbbb p dddd p eeee p]
set full [members [dict create aaaa {} bbbb {} dddd {} eeee {}] \
                  [dict create aaaa {} cccc {} dddd {}]]
check both_membership {aaaa dddd} [dict keys $full]
set c [counts $snap $both_rows $full $live]
check both_shown    1 [dict get $c shown]      ;# aaaa alone: bbbb is not bookmarked
check both_total    2 [dict get $c total]      ;# aaaa and dddd, not the four running
check both_excluded 1 [dict get $c excluded]   ;# dddd
check both_named    dddd [excluded $snap $both_rows $full]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
