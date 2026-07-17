package require Tcl 9

# ::questlog::scope - the single home for snapshot row-level matching.
#
# Whether a session row passes the toolbar's snapshot SCOPE - the since/until
# recency bounds, the subtree scope, and the min-turns floor - is one
# question with one answer, asked by both the model (Scan, when it decides
# which memoised rows the snapshot admits) and the view (SessionList, when it
# reconciles which rows stay shown). The cutoff computation and the
# subtree-scope predicate used to live in both, so the model logic was mirrored
# into the view. These procs are that one answer; Scan and SessionList call
# them rather than each carrying a copy. The view filters (running, bookmarked,
# model) are a separate question with a separate home, the list engine's
# attribute filters: they shape which in-scope rows the list shows, not which
# rows are in scope at all.
#
# A namespace of pure predicates, not a class: the snapshot is an immutable
# dict the toolbar publishes and the row is a dict passed in, so there is no
# joint state that co-evolves and no named global to absorb - the issue-67
# criteria all fail, and a few procs over two dicts beat a class.

namespace eval ::questlog::scope {
    namespace export parse_since cutoff_for ceiling_for since_label time_locale \
        row_subtree_match row_matches folder_subtree_candidate
}

# The one home that interprets a since or until value, for every consumer (the
# headless CLI, the GUI time row, cutoff_for, ceiling_for, and since_label).
# Classifies a spec into a
# typed normal form and throws on a malformed one:
#   ""  or "all"          -> {none}             no bound
#   <int><m|h|d|w>        -> {rel <secs>}       a relative window
#   YYYY-MM-DD            -> {abs <epoch>}      a date, day-granular (local
#                                               start-of-day; until covers the day)
#   YYYY-MM-DDTHH:MM[:SS] -> {absdt <epoch>}    a precise instant (local; the T may
#                                               also be a space if the token is quoted)
# ISO forms only: the dash makes them unambiguous against the relative form. A bare
# date stays day-granular (start-of-day floor, whole-day ceiling) so the common case
# is unchanged; adding a time pins the bound to the second, which is what an audit
# needs to reproduce an exact window. The regex pre-gates clock scan so only a
# structurally valid string reaches it; the catch turns an impossible value
# (2026-02-30, 25:00) into a clean error rather than a clock stack trace.
proc ::questlog::scope::parse_since {spec} {
    if {$spec eq "" || $spec eq "all"} { return {none} }
    if {[regexp {^([0-9]+)([mhdw])$} $spec -> n unit]} {
        return [list rel [expr {$n * [dict get {m 60 h 3600 d 86400 w 604800} $unit]}]]
    }
    if {[regexp {^([0-9]{4}-[0-9]{2}-[0-9]{2})[ T]([0-9]{2}:[0-9]{2}(?::[0-9]{2})?)$} \
            $spec -> d t]} {
        set fmt [expr {[string length $t] == 5 ? "%Y-%m-%d %H:%M" : "%Y-%m-%d %H:%M:%S"}]
        if {[catch {clock scan "$d $t" -format $fmt} epoch]} {
            error "invalid since datetime: $spec"
        }
        return [list absdt $epoch]
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
# cutoff excludes nothing. The one cutoff computation, consumed by row_matches
# here and by Scan's list_paths_for; both exclude a row when mtime <= cutoff, so
# the abs/absdt branch returns epoch-1 to keep a session at exactly the chosen
# instant (local midnight for a bare date, the named second for a datetime: mtime
# >= epoch). That -1 is tied to the <= test at those two call sites; change one and
# revisit this.
proc ::questlog::scope::cutoff_for {snapshot} {
    set since [dict getdef $snapshot since [::questlog::config::get since_default]]
    lassign [parse_since $since] kind val
    switch -- $kind {
        none  { return 0 }
        rel   { return [expr {[clock seconds] - $val}] }
        abs   { return [expr {$val - 1}] }
        absdt { return [expr {$val - 1}] }
    }
}

# Epoch ceiling for a snapshot's until (upper) bound, the mirror of cutoff_for.
# "" means no ceiling - the until key absent, or "all" - so a "" return excludes
# nothing. A row is excluded when its mtime is past the ceiling (mtime > ceiling),
# so the ceiling is the last instant kept. A relative until is that instant ago; a
# bare-date until covers the whole named day, so the abs branch returns the second
# before the next local midnight (clock add ... 1 day is DST-safe, unlike a flat
# +86400). A datetime until is the exact named instant, kept whole - no day
# expansion - which is what brackets a precise window. Unlike cutoff_for there is no
# config default: the upper bound is a CLI-only scope bound, absent by default rather
# than falling back to a configured one.
proc ::questlog::scope::ceiling_for {snapshot} {
    set until [dict getdef $snapshot until ""]
    lassign [parse_since $until] kind val
    switch -- $kind {
        none  { return "" }
        rel   { return [expr {[clock seconds] - $val}] }
        abs   { return [expr {[clock add $val 1 day] - 1}] }
        absdt { return $val }
    }
}

# The local locale Tcl should use to render a date, resolved POSIX-style from the
# LC_TIME category rather than Tcl's -locale current (which reads LANG and would
# show, say, Spanish on a machine whose LANG is es_ES but LC_TIME en_AU). The
# .ENCODING suffix is stripped because -locale en_AU.UTF-8 falls back to C while
# -locale en_AU resolves. The one home for the date locale, used by since_label
# and the GUI calendar's month header.
proc ::questlog::scope::time_locale {} {
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
proc ::questlog::scope::since_label {spec} {
    lassign [parse_since $spec] kind val
    switch -- $kind {
        none  { return all }
        abs   { return "since [string trim [clock format $val -format %x -locale [time_locale]]]" }
        absdt { return "since [string trim [clock format $val -format {%x %H:%M:%S} -locale [time_locale]]]" }
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

# 1 iff the project folder named $fname could hold a session in the subtree of
# one of the directories in subtree_list, judged from its encoded name alone
# (no file read). This is the test that restricts which folders the scanner
# walks. encode_cwd maps every non-alphanumeric to "-", so a folder in the
# subtree of $u encodes to encode_cwd($u) (the subtree root itself) or
# encode_cwd($u)-... (a descendant); the "$enc-*" boundary excludes a
# same-prefix sibling (encode_cwd(.../code/app) does not match .../code/apptest).
# The encoding is lossy - .../proj/sub and .../proj-sub both encode to
# ...-proj-sub - so this can over-include a hyphenated sibling repo;
# row_subtree_match settles that per row. The pair: this narrows the walk for
# speed, row_subtree_match confirms each row.
proc ::questlog::scope::folder_subtree_candidate {fname subtree_list} {
    foreach u $subtree_list {
        set enc [::questlog::path::encode_cwd $u]
        if {$fname eq $enc || [string match "$enc-*" $fname]} { return 1 }
    }
    return 0
}

# 1 iff the row is in the subtree of any directory in subtree_list. Residence
# decides: folder_cwd - the directory the row's project folder resolves to,
# stamped by Scan's stamp_subtree, since the resolver and its cache live there -
# is compared against each subtree dir. When residence is known it is
# authoritative: a session moved into an out-of-scope project folder is out
# even though its recorded cwd is in scope, and one moved into an in-scope
# folder is in - the move feature files sessions, and filing is what the scope
# reads. Fallbacks, each naming its fault:
#   - folder_cwd "" or absent (the project directory no longer exists, or the
#     encoded basename is ambiguous, so residence is unknowable): the recorded
#     cwd_hint decides - this keeps sessions of a deleted repo findable by
#     their old path.
#   - cwd_hint also empty (a transcript that never recorded a cwd): the
#     encoded folder name against the subtree dirs, the last honest evidence.
proc ::questlog::scope::row_subtree_match {row subtree_list} {
    set folder_cwd [dict getdef $row folder_cwd ""]
    if {$folder_cwd ne ""} {
        return [in_subtree_of $folder_cwd $subtree_list]
    }
    set cwd_hint [dict getdef $row cwd_hint ""]
    if {$cwd_hint ne ""} {
        return [in_subtree_of $cwd_hint $subtree_list]
    }
    return [folder_subtree_candidate [dict get $row folder] $subtree_list]
}

# 1 iff $path equals a directory in subtree_list or extends it past a "/".
# Literal prefix compare, not string match: a glob metacharacter in a
# directory name ([, ?, *) is a character here, never a pattern.
proc ::questlog::scope::in_subtree_of {path subtree_list} {
    foreach u $subtree_list {
        set u [string trimright $u /]
        if {$path eq $u
            || [string equal -length [string length "$u/"] "$u/" $path]} {
            return 1
        }
    }
    return 0
}

# 1 iff a row is in a snapshot's row-level SCOPE: the since cutoff, the until
# ceiling, the subtree scope, and the min-turns floor. A bookmark is a session
# attribute the view toggles read (bookmarked_only), never a window exemption:
# a since/until window means exactly what it says, bookmarked or not, so a
# CLI cost audit over a window is exact. The
# min-turns floor drops a session whose recorded nturns is below the threshold
# (default 1 = no floor). Both row builders record nturns - scan_one (browse,
# capped at turn_count_cap) and scan_file (search, the full count) - so the floor
# scopes browse and search alike; a row that somehow lacks nturns defaults to the
# threshold and passes. The view filters are applied separately, by the list
# engine's attribute filters.
proc ::questlog::scope::row_matches {snapshot row} {
    if {[dict get $row mtime] <= [cutoff_for $snapshot]} { return 0 }
    set ceiling [ceiling_for $snapshot]
    if {$ceiling ne "" && [dict get $row mtime] > $ceiling} { return 0 }
    set subtree [dict getdef $snapshot subtree {}]
    if {[llength $subtree] > 0 && ![row_subtree_match $row $subtree]} { return 0 }
    set min_turns [dict getdef $snapshot min_turns 1]
    if {$min_turns > 1 && [dict getdef $row nturns $min_turns] < $min_turns} { return 0 }
    return 1
}
