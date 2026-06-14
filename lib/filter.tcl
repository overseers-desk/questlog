package require Tcl 9

# ::questlog::filter - the single home for snapshot row-level matching.
#
# Whether a session row passes the toolbar's snapshot (recency bound, one_turn,
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
    namespace export parse_since cutoff_for ceiling_for since_label time_locale \
        row_under_match row_matches
}

# The one home that interprets a since or until value, for every consumer (the
# headless CLI, the GUI time row, cutoff_for, ceiling_for, and since_label).
# Classifies a spec into a
# typed normal form and throws on a malformed one:
#   ""  or "all"          -> {none}           no bound
#   <int><m|h|d|w>        -> {rel <secs>}     a relative window
#   YYYY-MM-DD            -> {abs <epoch>}    an absolute date, local start-of-day
# ISO dates only: the dash makes them unambiguous against the relative form, and
# they are a single spaceless CLI token. The regex pre-gates clock scan so only a
# structurally valid string reaches it; the catch turns an impossible date
# (2026-02-30, 2026-13-01) into a clean error rather than a clock stack trace.
proc ::questlog::filter::parse_since {spec} {
    if {$spec eq "" || $spec eq "all"} { return {none} }
    if {[regexp {^([0-9]+)([mhdw])$} $spec -> n unit]} {
        return [list rel [expr {$n * [dict get {m 60 h 3600 d 86400 w 604800} $unit]}]]
    }
    if {[regexp {^[0-9]{4}-[0-9]{2}-[0-9]{2}$} $spec]} {
        if {[catch {clock scan $spec -format "%Y-%m-%d"} epoch]} {
            error "invalid since date: $spec"
        }
        return [list abs $epoch]
    }
    error "invalid since: $spec"
}

# Epoch cutoff for a snapshot's since bound. 0 means no bound ("all", or the
# default when the key is absent); since on-disk mtimes are always positive a 0
# cutoff filters nothing. The one cutoff computation, consumed by row_matches
# here and by Scan's list_paths_for; both exclude a row when mtime <= cutoff, so
# the abs branch returns epoch-1 to keep a session at exactly local midnight of
# the chosen date (mtime >= epoch). That -1 is tied to the <= test at those two
# call sites; change one and revisit this.
proc ::questlog::filter::cutoff_for {snapshot} {
    set since [dict getdef $snapshot since [::questlog::config::get since_default]]
    lassign [parse_since $since] kind val
    switch -- $kind {
        none { return 0 }
        rel  { return [expr {[clock seconds] - $val}] }
        abs  { return [expr {$val - 1}] }
    }
}

# Epoch ceiling for a snapshot's until (upper) bound, the mirror of cutoff_for.
# "" means no ceiling - the until key absent, or "all" - so a "" return filters
# nothing. A row is excluded when its mtime is past the ceiling (mtime > ceiling),
# so the ceiling is the last instant kept. A relative until is that instant ago; an
# absolute until covers the whole named day, so the abs branch returns the second
# before the next local midnight (clock add ... 1 day is DST-safe, unlike a flat
# +86400). Unlike cutoff_for there is no config default: the upper bound is a
# CLI-only filter, absent by default rather than falling back to a configured one.
proc ::questlog::filter::ceiling_for {snapshot} {
    set until [dict getdef $snapshot until ""]
    lassign [parse_since $until] kind val
    switch -- $kind {
        none { return "" }
        rel  { return [expr {[clock seconds] - $val}] }
        abs  { return [expr {[clock add $val 1 day] - 1}] }
    }
}

# The local locale Tcl should use to render a date, resolved POSIX-style from the
# LC_TIME category rather than Tcl's -locale current (which reads LANG and would
# show, say, Spanish on a machine whose LANG is es_ES but LC_TIME en_AU). The
# .ENCODING suffix is stripped because -locale en_AU.UTF-8 falls back to C while
# -locale en_AU resolves. The one home for the date locale, used by since_label
# and the GUI calendar's month header.
proc ::questlog::filter::time_locale {} {
    foreach var {LC_ALL LC_TIME LANG} {
        if {[info exists ::env($var)] && $::env($var) ne ""} {
            return [lindex [split $::env($var) .] 0]
        }
    }
    return C
}

# The one display-string home for a since value, shown by the GUI custom member.
# "all" for no bound; a relative window as its largest exact unit, pluralised
# ("6 hours", "2 weeks"); an absolute date rendered in the user's locale via the
# %x convention ("since 1/04/2026" under en_AU). The leading space %x pads the
# day with is trimmed. Relative labels stay English (there is no message
# catalogue, and only the date was asked to track locale).
proc ::questlog::filter::since_label {spec} {
    lassign [parse_since $spec] kind val
    switch -- $kind {
        none { return all }
        abs  { return "since [string trim [clock format $val -format %x -locale [time_locale]]]" }
        rel  {
            foreach {unit secs} {week 604800 day 86400 hour 3600 minute 60} {
                if {$val % $secs == 0} {
                    set n [expr {$val / $secs}]
                    return "$n $unit[expr {$n == 1 ? {} : {s}}]"
                }
            }
            return "$val seconds"
        }
    }
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
# row past either recency bound, so a bookmarked row survives an mtime outside the
# since cutoff or the until ceiling, and a bookmarked_only filter, that a plain
# row would not.
proc ::questlog::filter::row_matches {snapshot row} {
    set bk [dict getdef $row bookmarked 0]
    if {[dict getdef $snapshot bookmarked_only 0] && !$bk} { return 0 }
    if {[dict get $row mtime] <= [cutoff_for $snapshot] && !$bk} { return 0 }
    set ceiling [ceiling_for $snapshot]
    if {$ceiling ne "" && [dict get $row mtime] > $ceiling && !$bk} { return 0 }
    if {[dict getdef $snapshot one_turn 1] && ![dict get $row is_multi]} { return 0 }
    set under [dict getdef $snapshot under {}]
    if {[llength $under] > 0 && ![row_under_match $row $under]} { return 0 }
    return 1
}
