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
# folder->cwd resolver cache (Folders) with its per-pass negative twin
# (NegFolders), the session-origin cache (Kind), both used headlessly by
# the CLI, and the arrival poll's directory-mtime memo (DirMtime).
#
# A class under the issue-67 trial: named globals absorbed, joint
# epoch/coroutine state, and rows leave tell-don't-ask through publish_row.
#
# Cancellation uses a generation token. `incr Epoch` invalidates any
# in-flight coroutine; the coroutine compares its captured epoch after
# every yield and exits cleanly when stale. No `rename`, no race.

namespace eval ::questlog::scan {}

# Resume a coroutine from an `after` callback. The coroutine command deletes
# itself when it returns, so a resume scheduled before a cancel can fire after
# the coroutine is already gone; skip it then. An error the coroutine itself
# raises is deliberately NOT caught here - it reaches bgerror and is seen,
# instead of dying silently and hanging the vwait that awaits the scan. A bare
# `catch` around the resume swallowed both, turning a real fault into a freeze.
proc ::questlog::resume_coro {co} {
    if {[llength [info commands $co]]} { $co }
}

# Worker->main delivery shim for the pool scan, the twin of
# ::questlog::search::dispatch: async messages may arrive after the Scan
# object is destroyed, so resolve the object command lazily and swallow.
proc ::questlog::scan::dispatch {obj_cmd args} {
    if {[info commands $obj_cmd] eq ""} return
    if {[catch {{*}$obj_cmd {*}$args} err]} {
        puts stderr "questlog::scan::dispatch: $err"
    }
}

# The pool worker's chunk job, evaluated in each jobpool worker interp (the
# prelude has loaded match.tcl there). Reads every path in its slice with the
# same extractor the coroutine path uses and sends the rows home in one async
# message. Exactly one message per chunk, sent on the abort path too, so the
# main thread's in-order chunk accounting can never wait on a hole. The shared
# tsv epoch is checked before each file: a cancelled pass stops reading within
# one file, and whatever partial rows exist still travel (the main-thread
# epoch gate drops them).
set ::questlog::scan::WorkerScript {
    proc scan_rows {epoch paths clauses} {
        set rows [list]
        foreach path $paths {
            if {[tsv::get questlog scan_epoch] != $epoch} break
            if {[catch {::questlog::match::scan_file $path $clauses} res]} continue
            lassign $res row _
            if {$row eq ""} continue
            # The subagent glob and sidecar reads ride the worker too, so the
            # consumer's eager child enumeration opens nothing on the main
            # thread; rows from other producers carry no children key and the
            # consumer falls back to its enumeration seam.
            if {[dict getdef $row has_subagents 0]
                && ![catch {::questlog::match::subagent_rows $path} kids]} {
                dict set row children $kids
            }
            lappend rows $row
        }
        return $rows
    }
    proc job_scan_chunk {main_tid obj_cmd epoch seq paths clauses} {
        thread::send -async $main_tid [list ::questlog::scan::dispatch $obj_cmd \
            on_worker_chunk $epoch $seq [scan_rows $epoch $paths $clauses]]
    }
    proc job_scan_arrivals {main_tid obj_cmd epoch paths clauses} {
        thread::send -async $main_tid [list ::questlog::scan::dispatch $obj_cmd \
            on_worker_arrivals $epoch [scan_rows $epoch $paths $clauses]]
    }
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
# model) are a separate question with a separate home, the streamtree base
# class's attribute filters: they shape which in-bounds rows the list shows,
# not which rows are in bounds at all.
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
#   - folder_cwd "" or absent (the encoded basename is ambiguous and no
#     transcript names it, so residence is unknowable): the recorded cwd_hint
#     decides. A deleted repo's folder resolves to its recorded path, so its
#     sessions stay findable by that path through the field itself.
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
# (default 1 = no floor). The one extractor (scan_file, browse and search alike)
# records nturns capped at turn_count_cap, so the floor bounds both passes
# identically; a row that somehow lacks nturns defaults to the threshold and
# passes. The view filters are applied separately, by the streamtree base
# class's attribute filters.
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
    variable NegFolders   ;# dict used as a set: folder basenames that failed to
                          ;# resolve during the current scan pass. Reset at the
                          ;# top of each pass (run_scan), so an unresolvable folder
                          ;# is peeked once per pass, not once per row, while a
                          ;# directory restored between passes still gets a fresh
                          ;# chance. Deliberately NOT reset by a single-path scan
                          ;# (the reconciler, the CLI gap-fill): those repeat, and
                          ;# a per-call reset would hand the per-row peek cost back
                          ;# to them; their heal arrives with the next pass.
    variable DirMtime     ;# dict: dir path -> last-seen mtime; the arrival
                          ;# poll's disk-derived memo. An absent entry (or "")
                          ;# reads as changed, so a folder learned this tick is
                          ;# globbed next tick.
    variable PoolEpoch    ;# the tsv scan epoch of the live pool pass, or ""
                          ;# when none: the main-thread half of the two-sided
                          ;# gate (workers check tsv, arrivals check this)
    variable ChunkBuf     ;# dict: chunk seq -> rows, held only until the chunk
                          ;# can be released in order; forward-once, never read
                          ;# back, cleared on cancel - not a second row home
    variable NextChunk    ;# the next chunk seq the in-order release expects
    variable ChunksTotal  ;# chunks posted for the live pass
    variable PathsTotal   ;# paths posted for the live pass (progress span)
    variable Scanned      ;# rows published by the live pass
    variable ChunkEnds    ;# per chunk seq, the paths done once it releases
    variable Peek         ;# 1 = resolve_folder may read a transcript to name a
                          ;# folder (peek_folder_cwd), the exact answer the CLI
                          ;# wants; 0 = cache and filesystem walk only, the GUI's
                          ;# posture (no main-thread transcript read; the pool
                          ;# pass warms the cache from every row's cwd_hint, and
                          ;# the app restamps under a subtree bound at scan end)

    constructor {on_row on_done {on_progress {}} {is_typing {}} {known_mtime {}} {peek 1}} {
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
        set NegFolders [dict create]
        set DirMtime [dict create]
        set PoolEpoch ""
        set ChunkBuf [dict create]
        set NextChunk 0
        set ChunksTotal 0
        set PathsTotal 0
        set Scanned 0
        set ChunkEnds [list]
        set Peek $peek
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
                set kind [::questlog::match::opener_kind $line]
                break
            }
            close $fh
        }
        dict set Kind $path [list $m $kind]
        return $kind
    }

    # A stale coroutine drains itself at its next yield boundary; a pool pass
    # is cut on both sides, the shared tsv epoch (queued jobs no-op before
    # reading a file) and PoolEpoch (in-flight arrivals drop on the doorstep).
    method cancel {} {
        incr Epoch
        set Active 0
        if {$PoolEpoch ne ""} {
            ::questlog::jobpool::bump scan
            set PoolEpoch ""
            set ChunkBuf [dict create]
        }
    }

    method extend {snapshot} {
        my cancel
        set Snapshot $snapshot
        if {[my use_pool]} {
            my start_threaded
            return
        }
        set my_epoch [incr Epoch]
        set Active 1
        my coro coro_$my_epoch [namespace which my] run_scan $my_epoch
    }

    # Whether this pass runs on the worker pool. The coroutine body below is
    # the single-thread fallback, kept whole: QUESTLOG_THREADS=0, a host that
    # never built the pool (Thread missing, the headless CLI) and a consumer
    # that never loaded the jobpool layer (standalone tests) all land there.
    # A live pool implies the Thread package and the search layer are loaded.
    method use_pool {} {
        if {[info commands ::questlog::jobpool::available] eq ""} { return 0 }
        if {![::questlog::jobpool::available]} { return 0 }
        if {[::questlog::search::env_threads] eq "0"} { return 0 }
        return 1
    }

    # The pool pass. Chunks are contiguous slices of the mtime-sorted path
    # list and are released strictly in seq order by on_worker_chunk, which
    # reproduces the exact publish order of the sequential coroutine walk:
    # streamtree skips its resort under the default sort on that promise.
    # The differential skip runs here against the mtimes the enumeration
    # already holds, so an unchanged corpus posts nothing.
    method start_threaded {} {
        set Active 1
        set PoolEpoch [::questlog::jobpool::bump scan]
        set NegFolders [dict create]
        set ChunkBuf [dict create]
        set NextChunk 0
        set Scanned 0
        set clauses [my browse_clauses]
        set paths [list]
        foreach pair [my list_pairs_for $Snapshot] {
            lassign $pair path m
            if {$KnownMtime ne "" && [{*}$KnownMtime $path] eq $m} continue
            lappend paths $path
        }
        set PathsTotal [llength $paths]
        set per [::questlog::config::get scan_chunk_files]
        set chunks [list]
        # The first chunk is deliberately small: chunk 0 gates the first paint
        # (in-order release), so the first rows land after a handful of reads
        # instead of a full-width chunk of the corpus's newest, largest files.
        set first [expr {min(6, [llength $paths])}]
        if {$first > 0} { lappend chunks [lrange $paths 0 [expr {$first - 1}]] }
        for {set i $first} {$i < [llength $paths]} {incr i $per} {
            lappend chunks [lrange $paths $i [expr {$i + $per - 1}]]
        }
        set ChunkEnds [list]
        set n 0
        foreach c $chunks { lappend ChunkEnds [incr n [llength $c]] }
        set ChunksTotal [llength $chunks]
        if {$ChunksTotal == 0} {
            # Deferred, never synchronous inside extend: a caller's
            # `extend; vwait done` must establish its vwait first.
            my later 1 [list [self] pool_scan_done $PoolEpoch]
            return
        }
        set tid [thread::id]
        set seq 0
        foreach c $chunks {
            ::questlog::jobpool::post [list job_scan_chunk \
                $tid [self] $PoolEpoch $seq $c $clauses]
            incr seq
        }
        if {$OnProgress ne ""} { {*}$OnProgress 0 $PathsTotal }
    }

    # One chunk home from a worker. Release in seq order: buffer until the
    # gap before it closes, then publish every buffered chunk in sequence.
    method on_worker_chunk {epoch seq rows} {
        if {$PoolEpoch eq "" || $epoch != $PoolEpoch} return
        dict set ChunkBuf $seq $rows
        while {[dict exists $ChunkBuf $NextChunk]} {
            foreach row [dict get $ChunkBuf $NextChunk] {
                my publish_row $row
                incr Scanned
            }
            dict unset ChunkBuf $NextChunk
            incr NextChunk
            if {$OnProgress ne ""} {
                {*}$OnProgress [lindex $ChunkEnds $NextChunk-1] $PathsTotal
            }
        }
        if {$NextChunk == $ChunksTotal} { my pool_scan_done $PoolEpoch }
    }

    method pool_scan_done {epoch} {
        if {$PoolEpoch eq "" || $epoch != $PoolEpoch} return
        set PoolEpoch ""
        set Active 0
        if {$OnProgress ne ""} { {*}$OnProgress $PathsTotal $PathsTotal }
        if {$OnDone ne ""} { {*}$OnDone $Scanned }
    }

    # The empty clause set that makes scan_file the browse extractor, with the
    # extraction caps stamped on (a worker cannot reach config; scan_one reads
    # them from the clause dict for the same reason).
    method browse_clauses {} {
        return [dict create leaves {} tree {t and nodes {}} nocase 1 \
            turn_count_cap  [::questlog::config::get turn_count_cap] \
            tail_window_bytes [::questlog::config::get tail_window_bytes] \
            first_user_cap  [::questlog::config::get first_user_cap]]
    }

    # Arrival rows from a poll's chunk job: publish straight through - no
    # in-order accounting, a poll is one chunk. Gated on the live tsv epoch,
    # so arrivals queued before an extend's bump die on the doorstep (the new
    # pass re-enumerates their files anyway).
    method on_worker_arrivals {epoch rows} {
        if {$epoch != [::questlog::jobpool::epoch scan]} return
        foreach row $rows { my publish_row $row }
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
        # A negative resolution is only valid within one pass: reset the memo so
        # a folder restored between passes is peeked afresh.
        set NegFolders [dict create]
        set scanned 0
        set paths [my list_paths_for $Snapshot]
        set total [llength $paths]
        set count 0
        foreach path $paths {
            if {$my_epoch != $Epoch} return
            # The differential skip's memory is the consumer's: KnownMtime asks
            # what mtime it holds for this path, and an unchanged file is not
            # re-read. Scan itself remembers nothing row-shaped, so without
            # the callback every path scans.
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
        return [lmap p [my list_pairs_for $snapshot $include_subagents $cli_only] {
            lindex $p 0
        }]
    }

    # The same enumeration as {path mtime} pairs, for the pool pass, whose
    # differential skip compares against the mtime this walk already statted
    # rather than statting every file a second time.
    method list_pairs_for {snapshot {include_subagents 0} {cli_only 0}} {
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
        set out [lsort -integer -decreasing -index 1 $pairs]
        if {$cli_only} {
            set keep [list]
            foreach p $out {
                if {[my session_kind [lindex $p 0]] eq "cli"} { lappend keep $p }
            }
            set out $keep
        }
        return $out
    }

    # The subagents of one session, as child row dicts, mtime DESC. The pool
    # scan attaches these to each row in the worker (the `children` key), so
    # this main-thread seam serves the consumers outside that stream: the CLI,
    # a search-attached row, and the reconcile paths. The extraction itself
    # lives in ::questlog::match beside the row extractor, one home for both
    # interps. Children never enter the row stream (they are not browse
    # sessions); the list owns their model.
    method subagents_for {parent_path} {
        return [::questlog::match::subagent_rows $parent_path]
    }

    # The browse row for one session file: the multi-turn count, the first user
    # prompt preview, the cwd hint, the first timestamp, the origin, and the slug
    # Claude Code writes for the session. Pure: no shared state, returns a fresh
    # dict, or an empty dict when the file could not be opened.
    #
    # One extractor serves browse and search (issue #30): this delegates to
    # ::questlog::match::scan_file with an empty clause set, so the row shape is
    # built in exactly one place and cannot drift from the search row. An empty
    # clause set is the browse signal - scan_file then stops its forward pass
    # early (turn_count_cap turns, cwd, first_ts in hand) and reads the title from
    # a tail window, the same fast browse read this method used to carry inline,
    # so a large transcript is not read end to end just to list it. The caps
    # ride in on the clause dict (browse_clauses) because scan_file reads them
    # from there (a search worker cannot reach config).
    method scan_one {path} {
        lassign [::questlog::match::scan_file $path [my browse_clauses]] row _
        if {$row eq ""} { return [dict create] }
        return $row
    }

    # Publish a row into the stream. Used by run_scan and by Search (which
    # produces row data as a free side-effect of its own pass). The row's one
    # retained home is the consumer's; here the row only feeds Scan's own
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
        # only when the hint is self-consistent, so the cache never holds a
        # fictional path. A self-consistent hint whose directory is gone is
        # still the folder's path, the one that says where it hung.
        if {$cwd ne "" && ![dict exists $Folders $folder]
            && [::questlog::path::encode_cwd $cwd] eq $folder} {
            dict set Folders $folder $cwd
        }
        if {$OnRow ne ""} { {*}$OnRow $row }
    }

    # Stamp a row with folder_cwd: the directory its project folder resolves
    # to, normalized so a symlinked recorded spelling compares equal to a
    # canon_dir-normalized subtree bound (a directory that is gone normalizes
    # as far as its living prefix reaches), or "" when the folder is
    # unresolvable (the encoded basename is ambiguous and no transcript names
    # it). row_subtree_match reads the field as the residence
    # authority; the stamping lives here because Scan owns the resolver and
    # its cache, which keeps ::questlog::scan pure over its dicts. A ""
    # stamp is not re-tried until the file is rescanned; resolve_folder
    # memoises a failure only for the current pass, so a directory restored
    # later heals on the next scan of the row.
    method stamp_subtree {row} {
        if {[dict exists $row folder_cwd]} { return $row }
        set cwd [my resolve_folder [dict get $row folder]]
        if {$cwd ne ""} { set cwd [file normalize $cwd] }
        dict set row folder_cwd $cwd
        return $row
    }

    # The single canonical folder-basename -> cwd resolver. Every label
    # and every command that needs the project directory goes through
    # here or through folder_cwd below. Returns the folder's absolute
    # directory path: an extant one, or the path its transcripts record when
    # that directory is gone, so the session list can hang the folder under
    # its nearest living ancestor and a subtree bound over that ancestor still
    # admits its sessions; a caller that needs the directory itself asks
    # `file isdirectory`. Returns "" when the folder cannot be placed (the
    # basename is genuinely ambiguous and no transcript names it). Never
    # returns a fictional path.
    #
    #   1. Folders cache - already resolved this process.
    #   2. NegFolders memo - already failed this pass; "" without re-peeking.
    #   3. peek_folder_cwd - the cwd recorded inside an honest jsonl. This
    #      step READS TRANSCRIPTS, which is why it is a scan-path step and why
    #      resolve_folder itself must never be called from a UI path
    #      (call folder_cwd instead).
    #   4. folder_cwd - the Folders cache and the filesystem walk.
    #   5. "" - unresolvable. Memoised in NegFolders for the rest of this pass,
    #      so a folder of N sessions whose transcripts all point elsewhere pays
    #      one peek per pass rather than one per row; the memo is dropped at
    #      the next pass boundary, so a directory created later still gets a
    #      fresh chance.
    method resolve_folder {folder} {
        if {[dict exists $Folders $folder]} { return [dict get $Folders $folder] }
        if {[dict exists $NegFolders $folder]} { return "" }
        if {$Peek} {
            set cwd [my peek_folder_cwd $folder]
            if {$cwd ne ""} {
                dict set Folders $folder $cwd
                return $cwd
            }
        }
        set cwd [my folder_cwd $folder]
        if {$cwd eq ""} { dict set NegFolders $folder 1 }
        return $cwd
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
            set cwd [::logman::first_cwd $f]
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

    # Poll the projects tree for jsonl files that appeared without a live-
    # registry entry - a session started under a different CLAUDE_CONFIG_DIR,
    # or a file synced in by syncthing - which the running reconciler never
    # sees. Detection comes from the tree itself, cheaply, and each in-window
    # arrival is published through scan_path -> on_scan_row like any browse row.
    # Returns the number of files scanned.
    #
    # Cost bound per tick: one stat of the projects root plus one stat per
    # project folder; a glob plus one stat per jsonl only in a folder whose
    # mtime changed; a file read only for an in-window file the store lacks at
    # that mtime. K simultaneous in-window arrivals cost K synchronous single-
    # file scans in one tick (at scan_one's measured per-file cost, see the
    # scan_yield_files note in ::questlog::config), accepted until observed otherwise.
    method poll_arrivals {} {
        # Never interleave with the running scan coroutine; a missed tick self-
        # corrects because absent memo entries read as changed next time.
        if {$Active} { return 0 }
        set root [::questlog::path::projects_root]
        if {![file isdirectory $root]} { return 0 }
        set cutoff [::questlog::scan::cutoff_for $Snapshot]
        set ceiling [::questlog::scan::ceiling_for $Snapshot]
        set scanned 0
        # Root pass: the root's mtime moves when a project folder is added or
        # removed. On a change (or a never-seen root), learn the new folders
        # (an absent memo reads as changed, so the folder pass globs them) and
        # forget folders that no longer stat. The same-second clause matches
        # the folder pass: a folder created in the same second the root memo
        # was taken leaves the root's second-granular mtime equal to the memo,
        # and without it that folder stays unknown until the root moves again.
        set rootm ""
        catch {file mtime $root} rootm
        if {![dict exists $DirMtime $root] || [dict get $DirMtime $root] ne $rootm
            || $rootm >= [clock seconds] - 2} {
            foreach child [glob -nocomplain -directory $root -type d -- *] {
                if {![dict exists $DirMtime $child]} { dict set DirMtime $child "" }
            }
            foreach dir [dict keys $DirMtime] {
                if {$dir eq $root} continue
                if {[catch {file mtime $dir}]} { dict unset DirMtime $dir }
            }
            dict set DirMtime $root $rootm
        }
        # Folder pass: a folder counts as changed when its mtime moved OR is
        # within the same-second guard window. File mtimes are second-granular,
        # so a second file landing in the same second as the memoised stat would
        # otherwise stay invisible forever; re-globbing a just-hot dir once more
        # per tick costs one glob.
        foreach dir [dict keys $DirMtime] {
            if {$dir eq $root} continue
            if {[catch {file mtime $dir} m]} { dict unset DirMtime $dir; continue }
            set memo [dict get $DirMtime $dir]
            if {$m eq $memo && $m < [clock seconds] - 2} continue
            foreach f [glob -nocomplain -directory $dir -- *.jsonl] {
                if {[catch {file mtime $f} fm]} continue
                if {$fm <= $cutoff} continue
                if {$ceiling ne "" && $fm > $ceiling} continue
                set known ""
                if {[llength $KnownMtime]} { set known [{*}$KnownMtime $f] }
                if {$known eq "" || $known ne $fm} {
                    lappend arrivals $f
                    incr scanned
                }
            }
            dict set DirMtime $dir $m
        }
        if {![info exists arrivals]} { return 0 }
        # With the pool live, the K arrivals read in a worker and publish
        # through on_worker_arrivals when the rows come home; without it, the
        # synchronous single-file scan as before.
        if {[my use_pool]} {
            ::questlog::jobpool::post [list job_scan_arrivals [thread::id] [self] \
                [::questlog::jobpool::epoch scan] $arrivals [my browse_clauses]]
        } else {
            foreach f $arrivals { my scan_path $f }
        }
        return $scanned
    }

}
