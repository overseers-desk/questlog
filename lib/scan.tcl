package require Tcl 9
package require TclOO
package require leash

# ::questlog::Scan - coroutine-driven session-row stream producer.
#
# Each row is built fresh by line-streaming its jsonl with Tcl regex (no jq,
# no subprocess, no on-disk cache) and published through OnRow; the consumer
# retains what it wants (in the GUI, the session list's node store is the one
# in-memory home of session data). The differential skip asks the consumer
# through the known_mtime callback, so an unchanged corpus re-extends without
# re-reading a file. Scan keeps only disk-derived memos of its own: the
# folder->cwd resolver cache (Folders) and the session-origin cache (Kind),
# both used headlessly by the CLI.
#
# A class under the issue-67 trial: named globals absorbed, joint
# epoch/coroutine state, and rows leave tell-don't-ask through publish_row.
#
# Cancellation uses a generation token. `incr Epoch` invalidates any
# in-flight coroutine; the coroutine compares its captured epoch after
# every yield and exits cleanly when stale. No `rename`, no race.

namespace eval ::questlog::scan {}

proc ::questlog::scan::cmp_mtime {a b} {
    set ma [dict get $a mtime]
    set mb [dict get $b mtime]
    if {$ma < $mb} { return -1 }
    if {$ma > $mb} { return 1 }
    return 0
}

# Read from the channel's current position to EOF and return the LAST agentName
# and aiTitle seen, as {agent_name ai_title}; "" for either that never appears.
# The single home for the slug field regexes and their last-wins rule, shared by
# scan_one's tail read and its full-file fallback.
proc ::questlog::scan::last_titles {fh} {
    set agent_name ""
    set ai_title ""
    while {[chan gets $fh line] >= 0} {
        if {$line eq ""} continue
        if {[regexp {"agentName":"([^"]+)"} $line -> m]} { set agent_name $m }
        if {[regexp {"aiTitle":"([^"]+)"} $line -> m]} { set ai_title $m }
    }
    return [list $agent_name $ai_title]
}

# Session origin from a single opening-record line: an sdk-cli spawn (a skill
# or Agent-SDK run) opens with a queue-operation record, anything else is an
# interactive cli session. The one home for the queue-operation marker, shared
# by session_kind (which reads the head of a file) and scan_one (which already
# holds the line in its forward pass). Returns cli|sdk.
proc ::questlog::scan::opener_kind {line} {
    return [expr {[regexp {"type":"queue-operation"} $line] ? "sdk" : "cli"}]
}

# Resume a coroutine from an `after` callback. The coroutine command deletes
# itself when it returns, so a resume scheduled before a cancel can fire after
# the coroutine is already gone; skip it then. An error the coroutine itself
# raises is deliberately NOT caught here - it reaches bgerror and is seen,
# instead of dying silently and hanging the vwait that awaits the scan. A bare
# `catch` around the resume swallowed both, turning a real fault into a freeze.
proc ::questlog::resume_coro {co} {
    if {[llength [info commands $co]]} { $co }
}

# ---- bounds ----

# ::questlog::scan - the single home for snapshot row-level matching.
#
# Whether a session row passes the toolbar's snapshot BOUNDS - the since/until
# recency bounds, the subtree bound, and the min-turns floor - is one
# question with one answer, asked by both the model (Scan, when it decides
# which memoised rows the snapshot admits) and the view (SessionList, when it
# reconciles which rows stay shown). These procs are that one answer; Scan and
# SessionList call them rather than each carrying a copy of the cutoff
# computation and the subtree predicate. The view filters (running, bookmarked,
# model) are a separate question with a separate home, the list engine's
# attribute filters: they shape which in-bounds rows the list shows, not which
# rows are in bounds at all.
#
# A namespace of pure predicates, not a class: the issue-67 criteria all
# fail, and a few procs over two dicts beat a class.

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
proc ::questlog::scan::parse_since {spec} {
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
# cutoff excludes nothing. The one cutoff computation, consumed by row_in_bounds
# here and by Scan's list_paths_for; both exclude a row when mtime <= cutoff, so
# the abs/absdt branch returns epoch-1 to keep a session at exactly the chosen
# instant (local midnight for a bare date, the named second for a datetime: mtime
# >= epoch). That -1 is tied to the <= test at those two call sites; change one and
# revisit this.
proc ::questlog::scan::cutoff_for {snapshot} {
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
# config default: the upper bound is a CLI-only bound, absent by default rather
# than falling back to a configured one.
proc ::questlog::scan::ceiling_for {snapshot} {
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
proc ::questlog::scan::time_locale {} {
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
proc ::questlog::scan::since_label {spec} {
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
proc ::questlog::scan::folder_subtree_candidate {fname subtree_list} {
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
# authoritative: a session moved into an out-of-bounds project folder is out
# even though its recorded cwd is in bounds, and one moved into an in-bounds
# folder is in - the move feature files sessions, and filing is what the bounds
# read. Fallbacks, each naming its fault:
#   - folder_cwd "" or absent (the project directory no longer exists, or the
#     encoded basename is ambiguous, so residence is unknowable): the recorded
#     cwd_hint decides - this keeps sessions of a deleted repo findable by
#     their old path.
#   - cwd_hint also empty (a transcript that never recorded a cwd): the
#     encoded folder name against the subtree dirs, the last honest evidence.
proc ::questlog::scan::row_subtree_match {row subtree_list} {
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
proc ::questlog::scan::in_subtree_of {path subtree_list} {
    foreach u $subtree_list {
        set u [string trimright $u /]
        if {$path eq $u
            || [string equal -length [string length "$u/"] "$u/" $path]} {
            return 1
        }
    }
    return 0
}

# 1 iff a row is in a snapshot's row-level BOUNDS: the since cutoff, the until
# ceiling, the subtree bound, and the min-turns floor. A bookmark is a session
# attribute the bookmarked view filter reads, never a window exemption:
# a since/until window means exactly what it says, bookmarked or not, so a
# CLI cost audit over a window is exact. The
# min-turns floor drops a session whose recorded nturns is below the threshold
# (default 1 = no floor). Both row builders record nturns - scan_one (browse,
# capped at turn_count_cap) and scan_file (search, the full count) - so the floor
# bounds browse and search alike; a row that somehow lacks nturns defaults to the
# threshold and passes. The view filters are applied separately, by the list
# engine's attribute filters.
proc ::questlog::scan::row_in_bounds {snapshot row} {
    if {[dict get $row mtime] <= [cutoff_for $snapshot]} { return 0 }
    set ceiling [ceiling_for $snapshot]
    if {$ceiling ne "" && [dict get $row mtime] > $ceiling} { return 0 }
    set subtree [dict getdef $snapshot subtree {}]
    if {[llength $subtree] > 0 && ![row_subtree_match $row $subtree]} { return 0 }
    set min_turns [dict getdef $snapshot min_turns 1]
    if {$min_turns > 1 && [dict getdef $row nturns $min_turns] < $min_turns} { return 0 }
    return 1
}

oo::class create ::questlog::Scan {
    mixin leash
    variable Folders      ;# dict: folder basename -> resolved display path
    variable Epoch        ;# generation counter; inc to cancel
    variable Snapshot     ;# last snapshot the coroutine started under
    variable OnRow        ;# cb {row}
    variable OnDone       ;# cb {scanned}
    variable OnProgress   ;# cb {done total} or {}
    variable Active       ;# 1 while a coroutine is running
    variable IsTyping     ;# cb -> 1 while the user is typing, or {} for never
    variable KnownMtime   ;# cb {path} -> the consumer's stored mtime for a
                          ;# scanned path, or "" when it holds none; the
                          ;# differential skip's memory. {} scans every path.
    variable Kind         ;# dict: path -> {mtime kind}; memoised session origin
                          ;# (cli|sdk), so the search corpus gate pays one head
                          ;# read per file once, not on every query

    constructor {on_row on_done {on_progress {}} {is_typing {}} {known_mtime {}}} {
        set Folders [dict create]
        set Epoch 0
        set Snapshot [dict create]
        set OnRow $on_row
        set OnDone $on_done
        set OnProgress $on_progress
        set Active 0
        set IsTyping $is_typing
        set KnownMtime $known_mtime
        set Kind [dict create]
    }

    # Session origin from the opening record, classified by the shared
    # opener_kind rule. One line is enough. Memoised by mtime so a rewritten
    # file reclassifies. scan_one fills this cache for free as it reads each
    # head, so a warm corpus answers without a second read; an unscanned path
    # (a wider search window than the browse scan covered) is classified here
    # on demand. Returns cli|sdk.
    method session_kind {path} {
        if {[catch {file mtime $path} m]} { return cli }
        if {[dict exists $Kind $path] && [lindex [dict get $Kind $path] 0] == $m} {
            return [lindex [dict get $Kind $path] 1]
        }
        set kind cli
        if {![catch {open $path r} fh]} {
            chan configure $fh -encoding utf-8 -profile replace
            while {[chan gets $fh line] >= 0} {
                if {$line eq ""} continue
                set kind [::questlog::scan::opener_kind $line]
                break
            }
            close $fh
        }
        dict set Kind $path [list $m $kind]
        return $kind
    }

    # A stale coroutine drains itself at its next yield boundary.
    method cancel {} {
        incr Epoch
        set Active 0
    }

    method extend {snapshot} {
        my cancel
        set Snapshot $snapshot
        set my_epoch [incr Epoch]
        set Active 1
        my coro coro_$my_epoch [namespace which my] run_scan $my_epoch
    }

    # Coroutine body. Public so [namespace which my] resolves it.
    method run_scan {my_epoch} {
        # Yield once at the top so the caller's vwait is established
        # before any callback (OnRow / OnDone) fires. Otherwise short
        # scans complete synchronously inside `coroutine` and the
        # caller's vwait blocks forever waiting for a write that
        # already happened.
        my later 1 [list ::questlog::resume_coro [info coroutine]]
        yield
        if {$my_epoch != $Epoch} return
        set count 0
        set scanned 0
        set paths [my list_paths_for $Snapshot]
        set total [llength $paths]
        foreach path $paths {
            if {$my_epoch != $Epoch} return
            # The differential skip's memory is the consumer's: KnownMtime asks
            # what mtime it holds for this path, and an unchanged file is not
            # re-read. Scan itself remembers nothing row-shaped, so without the
            # callback every path scans.
            set existing_mtime ""
            if {$KnownMtime ne ""} {
                set existing_mtime [{*}$KnownMtime $path]
            }
            # The file can vanish between list_paths_for's glob and this stat
            # (Claude Code prunes transcripts past cleanupPeriodDays; users
            # delete sessions); a dead path is skipped, not fatal to the scan.
            if {[catch {file mtime $path} live_mtime]} { incr count; continue }
            if {$existing_mtime ne $live_mtime} {
                set row [my scan_one $path]
                if {[dict size $row] > 0} {
                    my publish_row $row
                    incr scanned
                }
            }
            incr count
            if {$count % [::questlog::config::get scan_yield_files] == 0} {
                if {$OnProgress ne ""} { {*}$OnProgress $count $total }
                my schedule_resume [info coroutine]
                yield
                if {$my_epoch != $Epoch} return
            }
        }
        if {$OnProgress ne ""} { {*}$OnProgress $total $total }
        set Active 0
        if {$OnDone ne ""} { {*}$OnDone $scanned }
    }

    # Schedule the coroutine's mid-loop resume per the configured policy. The
    # top-of-run resume stays a plain timer (it establishes the caller's vwait);
    # only the chunk boundary routes here. When scan_while_typing is off and the
    # injected predicate reports the user is mid-keystroke, defer by re-polling
    # this method - never resuming a stale coroutine - until typing stops; then
    # resume on idle or after scan_resume_ms. Every arm is leashed, so a poll
    # or resume pending when the Scan is destroyed dies with it.
    method schedule_resume {co} {
        if {![llength [info commands $co]]} return
        if {[::questlog::config::get scan_while_typing] == 0
            && $IsTyping ne "" && [{*}$IsTyping]} {
            my later [::questlog::config::get typing_poll_ms] \
                [list [self] schedule_resume $co]
            return
        }
        if {[::questlog::config::get scan_resume] eq "idle"} {
            my later idle [list ::questlog::resume_coro $co]
        } else {
            my later [::questlog::config::get scan_resume_ms] \
                [list ::questlog::resume_coro $co]
        }
    }

    # Build the candidate path list for a snapshot.
    # Depth-2 glob for the browse list: <folder>/<uuid>/subagents/ holds
    # internal subagent records (not user sessions) and is never a browse row;
    # the chevron surfaces them lazily on expand (subagents_for). The search
    # corpus needs them up front, so include_subagents appends each kept
    # session's subagent files (issue #13, search case B/C) - GUI search and
    # the CLI both pass it, so whatever the list can show, a search can find.
    # Pre-sorted by mtime DESC so consumers see rows in display order.
    # cli_only drops sdk-cli (skill / Agent-SDK) sessions from the result; no
    # shipped consumer passes it - sdk sessions are browse rows and search
    # rows alike - it is the switch a future automation-exhaust toggle would
    # flip (the sdk file count dwarfs interactive ~70x).
    method list_paths_for {snapshot {include_subagents 0} {cli_only 0}} {
        set root [::questlog::path::projects_root]
        if {![file isdirectory $root]} { return [list] }
        set cutoff [::questlog::scan::cutoff_for $snapshot]
        set ceiling [::questlog::scan::ceiling_for $snapshot]
        # `subtree` is the scan's root, not an after-the-fact cut: when it is set, walk
        # only the folders whose encoded name places them at or below a subtree
        # directory, so sessions outside the bounds are never enumerated or opened.
        # The name test can over-include a hyphenated sibling (encode_cwd is
        # lossy); row_subtree_match confirms each kept row. An empty subtree
        # walks every folder (the show-all path).
        set subtree [dict getdef $snapshot subtree {}]
        set pairs [list]
        foreach folder [glob -nocomplain -directory $root -type d -- *] {
            if {[llength $subtree] > 0 \
                && ![::questlog::scan::folder_subtree_candidate [file tail $folder] $subtree]} continue
            foreach f [glob -nocomplain -directory $folder -- *.jsonl] {
                # Vanished between glob and stat (transcript pruning): skip.
                if {[catch {file mtime $f} m]} continue
                if {$m <= $cutoff} continue
                if {$ceiling ne "" && $m > $ceiling} continue
                lappend pairs [list $f $m]
                # A subagent belongs to its parent session, so it enters the
                # search corpus whenever the parent is within the since bound,
                # regardless of its own mtime.
                if {$include_subagents} {
                    set uuid [file rootname [file tail $f]]
                    set subdir [file join $folder $uuid subagents]
                    foreach sf [glob -nocomplain -directory $subdir -- agent-*.jsonl] {
                        if {[catch {file mtime $sf} sm]} continue
                        lappend pairs [list $sf $sm]
                    }
                }
            }
        }
        set sorted [lsort -integer -decreasing -index 1 $pairs]
        set out [list]
        foreach p $sorted { lappend out [lindex $p 0] }
        if {$cli_only} {
            set keep [list]
            foreach p $out {
                if {[my session_kind $p] eq "cli"} { lappend keep $p }
            }
            set out $keep
        }
        return $out
    }

    # The subagents of one session, as child row dicts, built on demand when the
    # list expands a session's chevron. Pure: globs the session's subagents dir,
    # stats and reads the small meta sidecar of each, and returns them mtime DESC.
    # Children never enter the row stream (they are not browse sessions); the
    # list owns their model and their cost is computed on render, like a
    # parent's.
    method subagents_for {parent_path} {
        set uuid [file rootname [file tail $parent_path]]
        set subdir [file join [file dirname $parent_path] $uuid subagents]
        set out [list]
        foreach f [glob -nocomplain -directory $subdir -- agent-*.jsonl] {
            lappend out [my subagent_row $f]
        }
        return [lsort -decreasing -command ::questlog::scan::cmp_mtime $out]
    }

    # One subagent's row dict, from its file path. The parent identity is the
    # directory structure (<root>/<folder>/<uuid>/subagents/agent-<id>.jsonl), so
    # everything is derived from the path; the label fields come from the meta
    # sidecar Claude writes beside the transcript (agentType, description). Read
    # with simple field regex, the same idiom scan_one uses on the jsonl itself.
    method subagent_row {child_path} {
        set subdir   [file dirname $child_path]   ;# <root>/<folder>/<uuid>/subagents
        set sessdir  [file dirname $subdir]       ;# <root>/<folder>/<uuid>
        set parent_uuid [file tail $sessdir]
        set folder   [file tail [file dirname $sessdir]]
        set parent_path [file join [file dirname $sessdir] $parent_uuid.jsonl]
        set agent_id [file rootname [file tail $child_path]]
        if {[catch {file mtime $child_path} mtime]} { set mtime 0 }
        if {[catch {file size  $child_path} size]}  { set size 0 }
        set agent_type ""
        set description ""
        set meta [file rootname $child_path].meta.json
        if {![catch {open $meta r} fh]} {
            chan configure $fh -encoding utf-8 -profile replace
            set blob [read $fh]
            close $fh
            regexp {"agentType":"([^"]*)"} $blob -> agent_type
            regexp {"description":"([^"]*)"} $blob -> description
        }
        return [dict create \
            path $child_path \
            mtime $mtime \
            size $size \
            folder $folder \
            parent_path $parent_path \
            parent_uuid $parent_uuid \
            agent_id $agent_id \
            agent_type $agent_type \
            description $description \
            is_child 1]
    }

    # scan_one path - read the file line by line, extract the multi-turn
    # predicate, the first user prompt preview, the cwd hint, the first
    # timestamp, and the slug Claude Code writes for the session. Pure:
    # no shared state, returns a fresh dict. The caller decides whether
    # to publish.
    #
    # The slug read has a fast path and a fallback. The forward scan keeps
    # its early break on users/cwd/first_ts. The slug (agentName, aiTitle) is
    # the LAST occurrence, not the first: Claude Code rewrites the title
    # through a session's life and a rename appends fresh records at EOF, so
    # only the final occurrence is current. The fast path reads it from a tail
    # scan over the last ~64 KB, which holds the latest title whenever Claude
    # wrote one recently. When that window holds no title - a long session
    # whose last title record is more than ~64 KB back, or a short one whose
    # only title precedes the forward break - a full forward sweep recovers
    # it. Slug priority is unchanged: agentName wins over aiTitle.
    method scan_one {path} {
        if {[catch {open $path r} fh]} { return [dict create] }
        # -profile replace: the tail scan below seeks to an arbitrary byte
        # offset that can split a multibyte character, and a session file may
        # hold malformed UTF-8; under Tcl 9 strict decoding `chan gets` would
        # otherwise throw on the partial or invalid sequence and abort the scan.
        chan configure $fh -encoding utf-8 -profile replace
        set users 0
        set first ""
        set cwd ""
        set first_ts ""
        set kind ""
        set cap [::questlog::config::get turn_count_cap]
        while {[chan gets $fh line] >= 0} {
            if {$line eq ""} continue
            # Origin from the opening record, via the shared opener_kind rule.
            if {$kind eq ""} {
                set kind [::questlog::scan::opener_kind $line]
            }
            if {$cwd eq "" && [regexp {"cwd":"([^"]+)"} $line -> m]} {
                set cwd $m
            }
            if {$first_ts eq "" && [regexp {"timestamp":"([^"]+)"} $line -> m]} {
                set first_ts $m
            }
            # A real user turn (the shared is_user_turn predicate): count it,
            # and take the first one's content as the first-prompt preview.
            if {[::questlog::jsonl::is_user_turn $line]} {
                incr users
                # First-prompt preview, the same two-form capture as scan_file:
                # string content with escaped pairs kept whole, else the first
                # text block of a block-array prompt.
                if {$users == 1} {
                    if {![regexp {"content":"((?:[^"\\]|\\.)*)"} $line -> first]} {
                        regexp {"text":"((?:[^"\\]|\\.)*)"} $line -> first
                    }
                }
            }
            if {$users >= $cap && $cwd ne "" && $first_ts ne ""} break
        }
        # Tail scan. Seek to max(current_pos, size - 64KB) so a short file
        # is read whole and a long file pays only the tail. Skip the first
        # (probably partial) line after the seek when seeking mid-file.
        if {[catch {file size $path} fsz]} { set fsz 0 }
        set tail_start [expr {$fsz - [::questlog::config::get tail_window_bytes]}]
        set pos [chan tell $fh]
        if {$tail_start > $pos} {
            chan seek $fh $tail_start
            chan gets $fh _
        }
        lassign [::questlog::scan::last_titles $fh] agent_name ai_title
        # Fallback: an empty tail window means the latest title sits further
        # back than tail_window_bytes (a long, busy session) or before the
        # forward break (a short one). Re-read the whole file for it. Only
        # sessions the tail missed pay this sweep; a title inside the window
        # never reaches here.
        if {$agent_name eq "" && $ai_title eq ""} {
            chan seek $fh 0
            lassign [::questlog::scan::last_titles $fh] agent_name ai_title
        }
        close $fh
        if {[catch {file mtime $path} mtime]} { set mtime 0 }
        set size $fsz
        set folder [file tail [file dirname $path]]
        set uuid   [file rootname [file tail $path]]
        set first_clean [::questlog::match::clean_preview $first]
        set slug [expr {$agent_name ne "" ? $agent_name : $ai_title}]
        # Does this session have subagents? A cheap directory probe (no file
        # reads): the chevron in the list is drawn from this flag, and the
        # children themselves are enumerated lazily on expand (subagents_for).
        set subdir [file join [file dirname $path] $uuid subagents]
        set has_sub [expr {[file isdirectory $subdir]
            && [llength [glob -nocomplain -directory $subdir -- agent-*.jsonl]] > 0}]
        return [dict create \
            path $path \
            mtime $mtime \
            size $size \
            folder $folder \
            uuid $uuid \
            first_ts $first_ts \
            nturns [expr {min($users, $cap)}] \
            kind [expr {$kind eq "" ? "cli" : $kind}] \
            first_user $first_clean \
            slug $slug \
            ai_title $ai_title \
            has_subagents $has_sub \
            bookmarked [file executable $path] \
            cwd_hint $cwd]
    }

    # Publish a row into the stream. Used by run_scan and by Search (which
    # produces row data as a free side-effect of its own pass). The row's one
    # retained home is the consumer's; here the row only feeds the two
    # disk-derived memos on its way out. A scan_file republish (the search
    # path) carries neither the cost fields nor the tail-read identity fields
    # (slug, ai_title, kind).
    method publish_row {row} {
        set row [my stamp_subtree $row]
        set path [dict get $row path]
        # Carry the origin classification into the search-corpus cache for free;
        # scan_file republishes (the search path) carry no kind, so guard on it.
        if {[dict exists $row kind]} {
            dict set Kind $path [list [dict getdef $row mtime 0] [dict get $row kind]]
        }
        set folder [dict get $row folder]
        set cwd [dict get $row cwd_hint]
        # cwd_hint is the cwd the conversation ran in, read from the file.
        # For an un-moved session that equals the folder's own identity
        # (encode_cwd(cwd_hint) == folder); for a session moved into this
        # folder the two disagree and trusting cwd_hint would label the
        # folder with the source project's name. Seed the Folders cache
        # only when the hint is self-consistent AND still points at an
        # extant directory, so the cache never holds a fictional path.
        if {$cwd ne "" && ![dict exists $Folders $folder]
            && [::questlog::path::encode_cwd $cwd] eq $folder
            && [file isdirectory $cwd]} {
            dict set Folders $folder $cwd
        }
        if {$OnRow ne ""} { {*}$OnRow $row }
    }

    # Stamp a row with folder_cwd: the directory its project folder resolves
    # to, normalized so a symlinked recorded spelling compares equal to a
    # canon_dir-normalized subtree bound, or "" when the folder is
    # unresolvable (its directory is gone, or the encoded basename is
    # ambiguous). row_subtree_match reads the field as the residence
    # authority; the stamping lives here because Scan owns the resolver and
    # its cache, which keeps ::questlog::scan pure over its dicts. A ""
    # stamp is not re-tried until the file is rescanned - resolve_folder
    # itself never caches a failure, so a directory restored later heals on
    # the next scan of the row.
    method stamp_subtree {row} {
        if {[dict exists $row folder_cwd]} { return $row }
        set cwd [my resolve_folder [dict get $row folder]]
        if {$cwd ne ""} { set cwd [file normalize $cwd] }
        dict set row folder_cwd $cwd
        return $row
    }

    # The single canonical folder-basename -> cwd resolver. Every label
    # and every command that needs the project directory goes through
    # here or through folder_cwd below. Returns an extant absolute
    # directory path, or "" when the folder cannot be resolved (its
    # directory is gone, or the basename is genuinely ambiguous). Never
    # returns a fictional path.
    #
    #   1. Folders cache - already resolved this process.
    #   2. peek_folder_cwd - the cwd recorded inside an honest jsonl,
    #      trusted only if it still names a real directory. This step
    #      READS TRANSCRIPTS, which is why it is a scan-path step and why
    #      resolve_folder itself must never be called from a UI path
    #      (call folder_cwd instead).
    #   3. folder_cwd - the Folders cache and the filesystem walk.
    #   4. "" - unresolvable. Not cached: a directory created or restored
    #      later in this process should get a fresh chance.
    method resolve_folder {folder} {
        if {[dict exists $Folders $folder]} { return [dict get $Folders $folder] }
        set cwd [my peek_folder_cwd $folder]
        if {$cwd ne "" && [file isdirectory $cwd]} {
            dict set Folders $folder $cwd
            return $cwd
        }
        return [my folder_cwd $folder]
    }

    # The resolver without step 2: the Folders cache, then the filesystem walk. It
    # opens no transcript, so a UI path that wants a folder's cwd only to NAME it
    # can have one without a redraw becoming a disk read - which is the whole line
    # between a filter and a search, and the reason the session list and the
    # bookmark sweep are wired to this and not to resolve_folder.
    #
    # A walk that lands on exactly one directory is as good an answer as a peeked
    # one, and is cached the same way. The only answer this gives up on is the one
    # where the basename is ambiguous and a recorded cwd would break the tie - and
    # there, a folder the scan has touched already has its peeked answer sitting in
    # the cache, so the label is the same either way.
    method folder_cwd {folder} {
        if {[dict exists $Folders $folder]} { return [dict get $Folders $folder] }
        set cands [::questlog::path::candidate_cwds_for $folder]
        if {[llength $cands] == 1} {
            set cwd [lindex $cands 0]
            dict set Folders $folder $cwd
            return $cwd
        }
        return ""
    }

    # The first cwd recorded in any jsonl under $folder, returned only
    # when encode_cwd of it agrees with $folder - so a session that was
    # moved into the folder cannot mislabel it. The caller decides
    # whether the path still exists.
    method peek_folder_cwd {folder} {
        set dir [file join [::questlog::path::projects_root] $folder]
        if {![file isdirectory $dir]} { return "" }
        foreach f [glob -nocomplain -directory $dir -- *.jsonl] {
            set cwd [::questlog::jsonl::first_cwd $f]
            if {$cwd ne "" && [::questlog::path::encode_cwd $cwd] eq $folder} {
                return $cwd
            }
        }
        return ""
    }

    # Scan a single file synchronously and publish it through the stream.
    # Used by the running reconciler to surface a freshly-started (or outside
    # the since bound, but live) session on demand, and by the CLI to fill a
    # row a matcher pass left incomplete. Returns the row, or {} if unreadable.
    method scan_path {path} {
        set row [my scan_one $path]
        if {[dict size $row] > 0} {
            set row [my stamp_subtree $row]
            my publish_row $row
        }
        return $row
    }

}
