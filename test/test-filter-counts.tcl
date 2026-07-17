#!/usr/bin/env tclsh9.0
# The pure filter arithmetic in lib/sessionlist.tcl: which filters are active,
# which can name a cut, the membership two of them jointly claim, and the cut
# itself. Every proc reads the engine's filter state dict (attr_filter_all shape:
# running 0|1, bookmarked 0|1, model {excluded labels}) - the one filter state,
# no snapshot mirror.
#
# A filter filters loaded rows only, so a true member the search never loaded is
# invisible; filter_cut is the arithmetic that surfaces that cut. The caller hands
# it the membership the filters jointly claim (full_set, uuid-keyed) gathered
# outside the search, which with two filters on is the intersection of their sets
# (filter_members), and the uuids the list has loaded. The cut is a member absent
# from the loaded set, never a loaded row a filter merely hides. No filter on, or
# no membership context, means no cut reported.
# Tk-free: hand-built state, loaded-uuid and set dicts drive the procs directly.
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
proc cut {state loaded full_set} {
    return [::questlog::sessionlist::filter_cut $state $loaded $full_set]
}

# The list has loaded aaaa and bbbb.
set loaded [dict create aaaa 1 bbbb 1]

# ---- no filter active: no cut, even with an unloaded member in full_set -------
check no_filter_cut {} [cut [dict create] $loaded [dict create aaaa 1 dddd 1]]

# ---- Running filter, every running session loaded: no cut -------------------
set run [dict create running 1]
check run_all_loaded_cut {} [cut $run $loaded [dict create aaaa 1]]

# ---- Running filter, a running session the search never loaded --------------
# dddd is claimed by the filter's membership but no loaded row carries it.
check run_cut [list dddd] [cut $run $loaded [dict create aaaa 1 dddd 1]]

# ---- empty full_set: no cut reported even with the filter on ----------------
check no_context_cut {} [cut $run $loaded [dict create]]

# ---- a loaded row the filter hides is not a cut -----------------------------
# The Bookmarked filter hides bbbb (not bookmarked), but bbbb IS loaded, so it is
# the filter working, not a cut. Only a member with no loaded row is cut.
set bm [dict create bookmarked 1]
check bm_hide_no_cut {} [cut $bm $loaded [dict create aaaa 1]]
check bm_cut [list eeee] [cut $bm $loaded [dict create aaaa 1 eeee 1]]

# ---- filter_cut names each missing member, in full_set order ----------------
check names_two_cut [list dddd ffff] \
    [cut $run $loaded [dict create aaaa 1 dddd 1 ffff 1]]

# ---- active_filters: which filters the caller narrates ----------------------
proc filters {state} { return [::questlog::sessionlist::active_filters $state] }
check filter_none  {} [filters [dict create]]
check filter_run   running    [filters [dict create running 1]]
check filter_bm    bookmarked [filters [dict create bookmarked 1]]
check filter_model model      [filters [dict create model {{Opus 4.8}}]]
# Each filter latches on its own, so every combination is reachable, and the
# caller is told about all of them - naming one and dropping the other would leave
# the reader a count measured against a filter the words never mention.
check filter_both  {running bookmarked} [filters [dict create running 1 bookmarked 1]]
check filter_all   {running bookmarked model} \
    [filters [dict create running 1 bookmarked 1 model {{Opus 4.8}}]]
# A flag of 0 and an empty model list are off, not on.
check filter_off {} [filters [dict create running 0 bookmarked 0 model {}]]

# ---- member_filters: the filters that can say what the search left on disk ----
# The model filter is not one of them: a row's model is known only once its
# transcript is parsed, and a filter parses nothing, so it can claim no member it
# cannot see.
proc mfilters {state} { return [::questlog::sessionlist::member_filters $state] }
check member_none  {} [mfilters [dict create]]
check member_model {} [mfilters [dict create model {{Opus 4.8}}]]
check member_run   running [mfilters [dict create running 1 model {{Opus 4.8}}]]
check member_both  {running bookmarked} [mfilters [dict create running 1 bookmarked 1]]

# ---- filter_members: two filters on means the INTERSECTION of their sets ------
# aaaa is running and bookmarked; bbbb runs without a bookmark; cccc is a
# bookmark that is not running. Under both filters only aaaa is a member: the list
# would show bbbb or cccc under neither, so neither is something the search cut.
set RUN [dict create aaaa [dict create path a.jsonl cwd /p/a] \
                     bbbb [dict create path b.jsonl cwd /p/b]]
set BM  [dict create aaaa [dict create path a.jsonl] \
                     cccc [dict create path c.jsonl]]
proc members {args} { return [::questlog::sessionlist::filter_members $args] }
check members_none  {} [::questlog::sessionlist::filter_members {}]
check members_one   {aaaa bbbb} [dict keys [members $RUN]]
check members_both  aaaa        [dict keys [members $RUN $BM]]
# The intersected member keeps what either set knew of it: the cwd the registry
# records names the session for the banner without opening its transcript.
check members_keep_cwd /p/a [dict get [members $RUN $BM] aaaa cwd]
# Disjoint sets intersect to nothing, and no cut is claimed at all.
check members_disjoint {} [members [dict create bbbb {}] [dict create cccc {}]]

# ---- both filters on: the cut is measured against the intersection ------------
# The list has loaded aaaa and bbbb. dddd is running and bookmarked but was never
# loaded - it is the one member the search cut. eeee is running and carries no
# bookmark, so the intersection never claims it: it must not swell the cut.
set state [dict create running 1 bookmarked 1]
set full [members [dict create aaaa {} bbbb {} dddd {} eeee {}] \
                  [dict create aaaa {} cccc {} dddd {}]]
check both_membership {aaaa dddd} [dict keys $full]
check both_cut [list dddd] [cut $state $loaded $full]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
