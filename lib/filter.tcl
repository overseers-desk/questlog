package require Tcl 9

# ::questlog::filter - the single home for snapshot row-level matching.
#
# Whether a session row passes the toolbar's snapshot (time window, one_turn,
# bookmarked_only, and the under-scope) is one question with one answer, asked
# by both the model (Scan, when it filters its memoised rows) and the view
# (SessionList, when it reconciles which rows stay shown). The cutoff
# computation and the under-scope predicate used to live in both, so the model
# logic was mirrored into the view. These procs are that one answer; Scan and
# SessionList call them rather than each carrying a copy.
#
# A namespace of pure predicates, not a class: the snapshot is an immutable
# dict the toolbar publishes and the row is a dict passed in, so there is no
# joint state that co-evolves and no named global to absorb - the issue-67
# criteria all fail, and a few procs over two dicts beat a class.

namespace eval ::questlog::filter {
    namespace export cutoff_for row_under_match row_matches
}

# Epoch cutoff for a snapshot's time window. 0 means no bound (window "all"),
# and since on-disk mtimes are always positive a 0 cutoff filters nothing.
proc ::questlog::filter::cutoff_for {snapshot} {
    set window [dict getdef $snapshot window [::questlog::config::get window_default]]
    if {$window eq "all"} { return 0 }
    set hours [dict get [::questlog::config::get window_hours] $window]
    return [expr {[clock seconds] - $hours*3600}]
}

# 1 iff the row's cwd is at or below any folder in under_list. An exact-cwd hit
# is matched by the row's encoded folder name; a parent-folder hit falls back to
# the recorded cwd_hint string and checks it starts with the under path.
proc ::questlog::filter::row_under_match {row under_list} {
    set folder [dict get $row folder]
    set cwd_hint [dict getdef $row cwd_hint ""]
    foreach u $under_list {
        if {$folder eq [::questlog::path::encode_cwd $u]} { return 1 }
        if {$cwd_hint ne ""} {
            set u [string trimright $u /]
            if {$cwd_hint eq $u || [string match "$u/*" $cwd_hint]} { return 1 }
        }
    }
    return 0
}

# 1 iff a row passes a snapshot's row-level filters. A bookmark (+x) pins the
# row past the time window, so a bookmarked row survives an out-of-window mtime
# and a bookmarked_only filter that a plain row would not.
proc ::questlog::filter::row_matches {snapshot row} {
    set bk [dict getdef $row bookmarked 0]
    if {[dict getdef $snapshot bookmarked_only 0] && !$bk} { return 0 }
    if {[dict get $row mtime] <= [cutoff_for $snapshot] && !$bk} { return 0 }
    if {[dict getdef $snapshot one_turn 1] && ![dict get $row is_multi]} { return 0 }
    set under [dict getdef $snapshot under {}]
    if {[llength $under] > 0 && ![row_under_match $row $under]} { return 0 }
    return 1
}
