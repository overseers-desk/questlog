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
    namespace export toggle row_visible lens_counts lens_excluded active_lens
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

# What an active lens shows versus what it truly contains. A lens only filters
# rows the search loaded, so a genuine member the search's window skipped is
# invisible and, unsaid, reads as "nothing there". rows is the loaded row list;
# full_set is the lens's whole membership as a uuid-keyed dict the caller
# gathers outside the search (the live poll for running_only, a bookmark sweep
# for bookmarked_only), {} when it has none. Returns shown (loaded rows the
# toggles admit, asked of row_visible so this count and the list agree), total
# (full_set's size) and excluded (members with no loaded row - the search's
# cut, not rows a lens hides: hiding a loaded row is the lens working). With no
# lens on, or an empty full_set, excluded is 0; a caller without membership
# context must not be told a cut exists.
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
    if {[active_lens $snapshot] eq "" || ![dict size $full_set]} { return [list] }
    set loaded [dict create]
    foreach row $rows { dict set loaded [dict getdef $row uuid ""] 1 }
    set out [list]
    foreach uuid [dict keys $full_set] {
        if {![dict exists $loaded $uuid]} { lappend out $uuid }
    }
    return $out
}

# Which lens is narrowing the list: running, bookmarked, model, or "" when none
# is. The name a caller narrates ("Running - showing 1 of 2") and the one it
# gathers a membership for. Running and bookmarked are one single-select segment
# group, so at most one of them is ever set; the model lens rides alongside
# either, and is named only when neither segment is.
proc ::questlog::sessionlist::active_lens {snapshot} {
    if {[toggle $snapshot running_only 0]} { return running }
    if {[toggle $snapshot bookmarked_only 0]} { return bookmarked }
    if {[toggle $snapshot model ""] ne ""} { return model }
    return ""
}
