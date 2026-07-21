package require Tcl 9

# ::questlog::listfilter - the session list's view-filter arithmetic.
#
# The left pane's view filters - Running, Bookmarked and the Model filter - live
# on the list strip and are owned and evaluated by the streamtree base class,
# the one filter evaluator: its AttrFilter holds the state, attr_admits answers
# whether a node passes. This namespace holds only the pure arithmetic the base
# class does not do: which filters are active, which of them can name what the
# search left on disk, the membership two filters jointly claim, and the cut -
# the members no loaded row carries. Each reads the base class's filter state
# dict (attr_filter_all shape: running 0|1, bookmarked 0|1, model {excluded
# labels}) and answers without touching Tk or a node.
#
# A namespace of pure functions over that state, not a class: the same issue-67
# reasoning as ::questlog::scan - no joint state, no named global, tell-don't-ask
# all fail.

namespace eval ::questlog::listfilter {
    namespace export active_filters member_filters filter_members filter_cut
}

# Which filters are narrowing the list, in the order a caller words them: running,
# bookmarked, model. Empty when none is, and the list shows every row it loaded.
# Each filter latches on its own, so any combination is reachable and the list
# then shows the rows that pass all of them: running and bookmarked both on means
# running AND bookmarked, one set of rows, not two. A bool filter is on when its
# flag is 1, the model filter when its excluded-label list is non-empty.
proc ::questlog::listfilter::active_filters {state} {
    set out [list]
    if {[dict getdef $state running 0]}          { lappend out running }
    if {[dict getdef $state bookmarked 0]}       { lappend out bookmarked }
    if {[llength [dict getdef $state model {}]]} { lappend out model }
    return $out
}

# The active filters that HAVE a membership outside the search - the ones a caller
# can gather a full set for, and so the only ones that can say what the search
# left on disk. Running is the live registry, bookmarked is the +x bit; the model
# filter has neither, because a row's model is known only once its transcript is
# parsed, and a filter reads no transcript. So the model filter hides loaded rows
# like any other and claims nothing about what it cannot see.
proc ::questlog::listfilter::member_filters {state} {
    set out [list]
    foreach f [active_filters $state] {
        if {$f in {running bookmarked}} { lappend out $f }
    }
    return $out
}

# The membership the active filters jointly claim, out of the sets the caller
# gathered for member_filters (a list of uuid-keyed dicts, in that order).
#
# With both filters on, a row must be running AND bookmarked to show, so the
# membership is the INTERSECTION: a session that is running but not bookmarked is
# not a member of what the list is showing, and counting it would tell the reader
# the search cut a member it never held. One set is its own membership; no set at
# all is an empty membership, and a caller with none must not be told a cut
# exists. A uuid in several sets keeps every key any of them recorded, so a
# running bookmark still carries the cwd the registry knows for free (which names
# it without opening its transcript) alongside the path the sweep found on disk.
proc ::questlog::listfilter::filter_members {sets} {
    if {![llength $sets]} { return [dict create] }
    set out [lindex $sets 0]
    foreach s [lrange $sets 1 end] {
        set both [dict create]
        dict for {uuid m} $out {
            if {[dict exists $s $uuid]} {
                dict set both $uuid [dict merge $m [dict get $s $uuid]]
            }
        }
        set out $both
    }
    return $out
}

# The cut: the uuids in full_set that no loaded row carries - the members a filter
# truly contains that the search never read. A caller that must NAME what it is
# missing (the banner offering to load it) needs them, and a caller that must
# count them takes the length. loaded is the uuid-keyed dict of what the list
# holds; full_set is the membership the active filters jointly claim. Empty with
# no filter on, or with no membership context: a caller with neither must not be
# told a cut exists, and a loaded row a filter merely hides is the filter working,
# never a cut.
proc ::questlog::listfilter::filter_cut {state loaded full_set} {
    if {![llength [active_filters $state]] || ![dict size $full_set]} { return [list] }
    set out [list]
    foreach uuid [dict keys $full_set] {
        if {![dict exists $loaded $uuid]} { lappend out $uuid }
    }
    return $out
}
