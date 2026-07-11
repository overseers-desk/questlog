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
    namespace export toggle row_visible
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
# would flicker as the cost pass lands.
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
