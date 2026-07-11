package require Tcl 9

# ::questlog::sessionlist - the session-list view toggles.
#
# The left pane's view controls - running_only, bookmarked_only, and the model
# lens - choose which subset of the result set the list SHOWS. They are not
# search and not scope: changing one narrows or widens what is displayed; it
# does not re-run a search or change which sessions are eligible. They live
# under the snapshot's
# `listview` sub-key, and this namespace is their one predicate home - the
# analogue, for the view question, of ::questlog::filter::row_matches (which
# answers the scope question, including the min-turns floor that was once a view
# toggle). The browse stream and the in-place reducer both ask row_visible, so
# the model and the rendered view never disagree on what the toggles admit.
#
# A namespace of pure predicates over (snapshot, row), not a class: the same
# issue-67 reasoning as ::questlog::filter - no joint state, no named global,
# tell-don't-ask all fail.

namespace eval ::questlog::sessionlist {
    namespace export toggle row_visible lens_counts lens_excluded \
        active_lenses member_lenses lens_members
}

# One list-view toggle's value from a snapshot, with the toggle's own default
# when the `listview` sub-key (or the toggle within it) is absent - a snapshot
# built before a toggle existed, or a headless caller that sets none. The single
# place that knows the toggles are nested under `listview`.
proc ::questlog::sessionlist::toggle {snapshot name dflt} {
    return [dict getdef [dict getdef $snapshot listview {}] $name $dflt]
}

# 1 iff a row passes the session-list view toggles. bookmarked_only keeps only a
# bookmarked (+x) row; running_only keeps only a row whose uuid is live in
# running_set. running_set is the caller's running uuid->1 dict; it is consulted
# only under running_only, so {} is the right value when the caller has no
# liveness context and the toggle is off. model, when set, hides a row whose
# model is known and different; a row with no model yet (the cost pass has not
# filled it, or a search row that never carries one) stays visible, or the list
# would flicker as the cost pass lands. Both sides of that comparison are the
# model LABEL, what ::questlog::cost::model_label renders ("Opus 4.8", or a local
# id it cannot price, trimmed of any date suffix), not the raw id from the
# transcript: the row carries the label the list shows and the lens offers the
# labels the loaded rows carry, so two ids differing only by a date are one model.
proc ::questlog::sessionlist::row_visible {snapshot row {running_set {}}} {
    if {[toggle $snapshot bookmarked_only 0] && ![dict getdef $row bookmarked 0]} { return 0 }
    if {[toggle $snapshot running_only 0]
        && ![dict exists $running_set [dict getdef $row uuid ""]]} { return 0 }
    set want [toggle $snapshot model ""]
    if {$want ne ""} {
        set have [dict getdef $row model ""]
        if {$have ne "" && $have ne $want} { return 0 }
    }
    return 1
}

# What the active lenses show versus what they truly contain. A lens only filters
# rows the search loaded, so a genuine member the search's window skipped is
# invisible and, unsaid, reads as "nothing there". rows is the loaded row list;
# full_set is the membership the active lenses jointly claim, as a uuid-keyed
# dict the caller gathers outside the search (lens_members, from the live poll
# for running_only and a bookmark sweep for bookmarked_only), {} when it has
# none. Returns shown (loaded rows the toggles admit), total (full_set's size)
# and excluded (members with no loaded row - the search's cut, not rows a lens
# hides: hiding a loaded row is the lens working). With no lens on, or an empty
# full_set, excluded is 0; a caller without membership context must not be told a
# cut exists.
#
# shown counts what the list HOLDS and the lenses ADMIT, which is not the same as
# what is painted, and the difference is deliberate. A folder the reader has
# folded still holds its rows and the lenses still admit them, so they still
# count: folders open collapsed, so a count of painted rows would read 0 over a
# freshly loaded list and would then move every time the reader folded something,
# which says nothing about either the lens or the search's cut. Those two are what
# the number is for, and folding is the reader's own business.
proc ::questlog::sessionlist::lens_counts {snapshot rows full_set {running_set {}}} {
    set shown 0
    foreach row $rows {
        if {[row_visible $snapshot $row $running_set]} { incr shown }
    }
    return [dict create shown $shown total [dict size $full_set] \
        excluded [llength [lens_excluded $snapshot $rows $full_set]]]
}

# The same cut as lens_counts' excluded, by name: the uuids in full_set that no
# loaded row carries. A caller that must NAME what it is missing (the banner
# offering to load it) needs them, and a caller that must count them asks
# lens_counts, which counts these - one reading of what the search left behind,
# not two. Empty with no lens on, or with no membership context.
proc ::questlog::sessionlist::lens_excluded {snapshot rows full_set} {
    if {![llength [active_lenses $snapshot]] || ![dict size $full_set]} { return [list] }
    set loaded [dict create]
    foreach row $rows { dict set loaded [dict getdef $row uuid ""] 1 }
    set out [list]
    foreach uuid [dict keys $full_set] {
        if {![dict exists $loaded $uuid]} { lappend out $uuid }
    }
    return $out
}

# Which lenses are narrowing the list, in the order a caller words them: running,
# bookmarked, model. Empty when none is, and the list shows every row it loaded.
# Each lens latches on its own, so any combination is reachable and the list then
# shows the rows that pass all of them (row_visible ANDs the clauses): running and
# bookmarked both on means running AND bookmarked, one set of rows, not two.
proc ::questlog::sessionlist::active_lenses {snapshot} {
    set out [list]
    if {[toggle $snapshot running_only 0]}    { lappend out running }
    if {[toggle $snapshot bookmarked_only 0]} { lappend out bookmarked }
    if {[toggle $snapshot model ""] ne ""}    { lappend out model }
    return $out
}

# The active lenses that HAVE a membership outside the search - the ones a caller
# can gather a full set for, and so the only ones that can say what the search
# left on disk. Running is the live registry, bookmarked is the +x bit; the model
# lens has neither, because a row's model is known only once its transcript is
# parsed, and a filter reads no transcript. So the model lens hides loaded rows
# like any other and claims nothing about what it cannot see.
proc ::questlog::sessionlist::member_lenses {snapshot} {
    set out [list]
    foreach lens [active_lenses $snapshot] {
        if {$lens in {running bookmarked}} { lappend out $lens }
    }
    return $out
}

# The membership the active lenses jointly claim, out of the sets the caller
# gathered for member_lenses (a list of uuid-keyed dicts, in that order).
#
# With both lenses on, a row must be running AND bookmarked to show, so the
# membership is the INTERSECTION: a session that is running but not bookmarked is
# not a member of what the list is showing, and counting it would tell the reader
# the search cut a member it never held. One set is its own membership; no set at
# all is an empty membership, and a caller with none must not be told a cut
# exists. A uuid in several sets keeps every key any of them recorded, so a
# running bookmark still carries the cwd the registry knows for free (which names
# it without opening its transcript) alongside the path the sweep found on disk.
proc ::questlog::sessionlist::lens_members {sets} {
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
