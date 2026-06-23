package require Tcl 9
package require TclOO

# ::questlog::Scan - in-memory, coroutine-driven, memoised session scanner.
#
# Replaces the previous sqlite-cached design. Each launch builds the row
# table fresh by line-streaming each jsonl with Tcl regex (no jq, no
# subprocess). Within one process the table is memoised across recency-bound
# changes: tightening the since bound filters in O(rows), widening it scans
# only the delta.
#
# Single-instance by current convention, not by structural constraint.
# The class earns its existence under issue 67 on (a) named globals
# absorbed (Rows, Folders, Epoch, Snapshot, callbacks), (b) joint state
# (epoch and rows co-evolve as the coroutine drains), (c) tell-don't-ask
# (no caller pokes Rows directly; mutation routes through publish_row).
#
# Cancellation uses a generation token. `incr Epoch` invalidates any
# in-flight coroutine; the coroutine compares its captured epoch after
# every yield and exits cleanly when stale. No `rename`, no race.

namespace eval ::questlog::scan {}

# Comparator for lsort -command. Sorts row-dict elements by mtime.
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

# Resume a coroutine from an `after` callback. The coroutine command deletes
# itself when it returns, so a resume scheduled before a cancel can fire after
# the coroutine is already gone; skip it then. An error the coroutine itself
# raises is deliberately NOT caught here - it reaches bgerror and is seen,
# instead of dying silently and hanging the vwait that awaits the scan. A bare
# `catch` around the resume swallowed both, turning a real fault into a freeze.
proc ::questlog::resume_coro {co} {
    if {[llength [info commands $co]]} { $co }
}

# Re-enter a Scan's schedule_resume from a deferred-poll `after`, but only while
# the object still exists - so a poll pending when the Scan is destroyed (app
# quit mid-typing) no-ops instead of calling a dead method command.
proc ::questlog::resume_or_poll {obj co} {
    if {[llength [info commands $obj]]} { $obj schedule_resume $co }
}

oo::class create ::questlog::Scan {
    variable Rows         ;# dict: path -> row dict
    variable Folders      ;# dict: folder basename -> resolved display path
    variable Epoch        ;# generation counter; inc to cancel
    variable Snapshot     ;# last snapshot the coroutine started under
    variable OnRow        ;# cb {row}
    variable OnDone       ;# cb {scanned}
    variable OnProgress   ;# cb {done total} or {}
    variable Active       ;# 1 while a coroutine is running
    variable IsTyping     ;# cb -> 1 while the user is typing, or {} for never
    variable Kind         ;# dict: path -> {mtime kind}; memoised session origin
                          ;# (cli|sdk), so the search corpus filter pays one head
                          ;# read per file once, not on every query

    constructor {on_row on_done {on_progress {}} {is_typing {}}} {
        set Rows [dict create]
        set Folders [dict create]
        set Epoch 0
        set Snapshot [dict create]
        set OnRow $on_row
        set OnDone $on_done
        set OnProgress $on_progress
        set Active 0
        set IsTyping $is_typing
        set Kind [dict create]
    }

    # Session origin from the opening record. An sdk-cli session (a skill or
    # Agent-SDK spawn) opens with a queue-operation record; an interactive cli
    # session opens with a mode / permission-mode record. One line is enough.
    # Memoised by mtime so a rewritten file reclassifies. scan_one fills this
    # cache for free as it reads each head, so a warm corpus answers without a
    # second read; an unscanned path (a wider search window than the browse
    # scan covered) is classified here on demand. Returns cli|sdk.
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
                if {[regexp {"type":"queue-operation"} $line]} { set kind sdk }
                break
            }
            close $fh
        }
        dict set Kind $path [list $m $kind]
        return $kind
    }

    # Cancel any in-flight scan. Stale coroutine drains itself at the
    # next yield boundary.
    method cancel {} {
        incr Epoch
        set Active 0
    }

    # extend snapshot - start a new scan coroutine. Cancels any previous
    # coroutine via the epoch token.
    method extend {snapshot} {
        my cancel
        set Snapshot $snapshot
        set my_epoch [incr Epoch]
        set Active 1
        set co ::questlog::scan::coro_$my_epoch
        coroutine $co [namespace which my] run_scan $my_epoch
    }

    # Coroutine body. Public so [namespace which my] resolves it.
    method run_scan {my_epoch} {
        # Yield once at the top so the caller's vwait is established
        # before any callback (OnRow / OnDone) fires. Otherwise short
        # scans complete synchronously inside `coroutine` and the
        # caller's vwait blocks forever waiting for a write that
        # already happened.
        after 1 [list ::questlog::resume_coro [info coroutine]]
        yield
        if {$my_epoch != $Epoch} return
        set count 0
        set scanned 0
        set paths [my list_paths_for $Snapshot]
        set total [llength $paths]
        foreach path $paths {
            if {$my_epoch != $Epoch} return
            set existing_mtime ""
            if {[dict exists $Rows $path]} {
                set existing_mtime [dict get $Rows $path mtime]
            }
            set live_mtime [file mtime $path]
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
    # resume on idle or after scan_resume_ms.
    method schedule_resume {co} {
        if {[::questlog::config::get scan_while_typing] == 0
            && $IsTyping ne "" && [{*}$IsTyping]} {
            after [::questlog::config::get typing_poll_ms] \
                [list ::questlog::resume_or_poll [self] $co]
            return
        }
        if {[::questlog::config::get scan_resume] eq "idle"} {
            after idle [list ::questlog::resume_coro $co]
        } else {
            after [::questlog::config::get scan_resume_ms] \
                [list ::questlog::resume_coro $co]
        }
    }

    # Build the candidate path list for a snapshot.
    # Depth-2 glob for the browse list: <folder>/<uuid>/subagents/ holds
    # internal subagent records (not user sessions) and is never a browse row;
    # the chevron surfaces them lazily on expand (subagents_for). The search
    # corpus is the one consumer that needs them up front, so include_subagents
    # appends each kept session's subagent files (issue #13, search case B/C).
    # Pre-sorted by mtime DESC so consumers see rows in display order.
    # cli_only drops sdk-cli (skill / Agent-SDK) sessions from the result, so the
    # search corpus is the interactive sessions a person would browse, not the
    # automation exhaust that dwarfs them (~70x the file count). This is the one
    # switch that would let a future toggle re-admit sdk-cli to search: flip
    # cli_only off (and include_subagents back on) to restore the full corpus.
    method list_paths_for {snapshot {include_subagents 0} {cli_only 0}} {
        set root [::questlog::path::projects_root]
        if {![file isdirectory $root]} { return [list] }
        set cutoff [::questlog::filter::cutoff_for $snapshot]
        set ceiling [::questlog::filter::ceiling_for $snapshot]
        # `under` is the scan's root, not a post-filter: when it is set, walk only
        # the folders whose encoded name places them at or below an under
        # directory, so sessions outside the scope are never enumerated or opened.
        # The name test can over-include a hyphenated sibling (encode_cwd is
        # lossy); row_under_match confirms each kept row from its real cwd. Empty
        # under walks every folder (the show-all path).
        set under [dict getdef $snapshot under {}]
        set pairs [list]
        foreach folder [glob -nocomplain -directory $root -type d -- *] {
            if {[llength $under] > 0 \
                && ![::questlog::filter::folder_under_candidate [file tail $folder] $under]} continue
            foreach f [glob -nocomplain -directory $folder -- *.jsonl] {
                set m [file mtime $f]
                # A bookmarked (+x) file is kept regardless of either bound so it
                # always enters Rows and can be surfaced as a pin.
                if {$m <= $cutoff && ![file executable $f]} continue
                if {$ceiling ne "" && $m > $ceiling && ![file executable $f]} continue
                lappend pairs [list $f $m]
                # A subagent belongs to its parent session, so it enters the
                # search corpus whenever the parent is within the since bound,
                # regardless of its own mtime.
                if {$include_subagents} {
                    set uuid [file rootname [file tail $f]]
                    set subdir [file join $folder $uuid subagents]
                    foreach sf [glob -nocomplain -directory $subdir -- agent-*.jsonl] {
                        lappend pairs [list $sf [file mtime $sf]]
                    }
                }
            }
        }
        # Sort by mtime DESC.
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
    # Children never enter Rows (they are not browse sessions); the list owns
    # their model and their cost is computed on render, like a parent's.
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
            # Origin from the opening record (see session_kind): a queue-operation
            # opener marks an sdk-cli spawn, anything else an interactive cli.
            if {$kind eq ""} {
                set kind [expr {[regexp {"type":"queue-operation"} $line] ? "sdk" : "cli"}]
            }
            if {$cwd eq "" && [regexp {"cwd":"([^"]+)"} $line -> m]} {
                set cwd $m
            }
            if {$first_ts eq "" && [regexp {"timestamp":"([^"]+)"} $line -> m]} {
                set first_ts $m
            }
            # User-record predicate - same heuristic as cs-grep.
            if {[regexp {"type":"user"} $line] && [regexp {"content":"([^"]+)"} $line -> uc]} {
                incr users
                if {$users == 1} { set first $uc }
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
            is_multi [expr {$users >= 2}] \
            nturns [expr {min($users, $cap)}] \
            kind [expr {$kind eq "" ? "cli" : $kind}] \
            first_user $first_clean \
            slug $slug \
            ai_title $ai_title \
            has_subagents $has_sub \
            bookmarked [file executable $path] \
            cwd_hint $cwd]
    }

    # Merge a cost result into the row. Called from the main thread when
    # the cost-pass worker thread completes a file. Quiet no-op if the
    # row is absent (race with a delete). Does not fire OnRow: cost
    # arrivals route through the cost callback so the UI knows it is a
    # field update, not a fresh row that needs adding.
    method update_cost {path cost_dict} {
        if {![dict exists $Rows $path]} return
        set row [dict get $Rows $path]
        dict for {k v} $cost_dict { dict set row $k $v }
        dict set Rows $path $row
    }

    # Publish a row. Used by run_scan and by Search (which produces row
    # data as a free side-effect of its own pass). Last-write-wins; the
    # content from either consumer is the same row.
    method publish_row {row} {
        set path [dict get $row path]
        # Search republishes this row from scan_file without cost fields. When
        # the file is unchanged (same mtime as the cached row that carries a
        # cost), carry the computed cost across, so the republish neither clobbers
        # it nor re-triggers the cost pass for every matched session. A changed
        # mtime means the cost is stale, so it is left to be recomputed.
        if {![dict exists $row cost_usd] && [dict exists $Rows $path]} {
            set old [dict get $Rows $path]
            if {[dict exists $old cost_usd]
                && [dict getdef $old mtime ""] eq [dict getdef $row mtime ""]} {
                foreach k {cost_usd input_tokens output_tokens \
                           cache_write_tokens cache_read_tokens model_breakdown \
                           model turns duration_secs human_secs} {
                    if {[dict exists $old $k]} { dict set row $k [dict get $old $k] }
                }
            }
        }
        dict set Rows $path $row
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

    # Filter rows by a snapshot. Used by the session list and Search to read
    # the current memoised view. The snapshot row-level predicate lives in
    # ::questlog::filter (shared with SessionList); this adds only the optional
    # folder-scoped narrowing. Returns a list of row dicts, mtime DESC.
    method query {snapshot {folder ""}} {
        set out [list]
        dict for {path row} $Rows {
            if {![::questlog::filter::row_matches $snapshot $row]} continue
            if {$folder ne "" && [dict get $row folder] ne $folder} continue
            lappend out $row
        }
        return [lsort -decreasing -command ::questlog::scan::cmp_mtime $out]
    }

    # The single canonical folder-basename -> cwd resolver. Every label
    # and every command that needs the project directory goes through
    # here. Returns an extant absolute directory path, or "" when the
    # folder cannot be resolved (its directory is gone, or the basename
    # is genuinely ambiguous). Never returns a fictional path.
    #
    #   1. Folders cache - already resolved this process.
    #   2. peek_folder_cwd - the cwd recorded inside an honest jsonl,
    #      trusted only if it still names a real directory.
    #   3. candidate_cwds_for - filesystem walk; trusted iff exactly one
    #      directory matches the basename.
    #   4. "" - unresolvable. Not cached: a directory created or restored
    #      later in this process should get a fresh chance.
    method resolve_folder {folder} {
        if {[dict exists $Folders $folder]} { return [dict get $Folders $folder] }
        set cwd [my peek_folder_cwd $folder]
        if {$cwd ne "" && [file isdirectory $cwd]} {
            dict set Folders $folder $cwd
            return $cwd
        }
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

    # Rows is memoised and never pruned when a file is deleted, so a returned
    # row may describe a jsonl that no longer exists on disk (e.g. a Resume-
    # forked session quit before any input, which Claude leaves no file for).
    # Callers that decide visibility must existence-check the path themselves
    # rather than trust a non-empty row here - see reconcile_running.
    method lookup {path} {
        if {[dict exists $Rows $path]} { return [dict get $Rows $path] }
        return ""
    }

    # Scan a single file synchronously and publish it. Used by the running
    # reconciler to bring a freshly-started (or outside the since bound, but live)
    # session into Rows on demand. Returns the row, or {} if unreadable.
    method scan_path {path} {
        set row [my scan_one $path]
        if {[dict size $row] > 0} { my publish_row $row }
        return $row
    }

    # Re-derive a row's bookmarked flag from disk truth after a toggle.
    # The +x bit is authoritative; this only refreshes the cached field so
    # query/filter see it. The visible glyph is refreshed separately by
    # the session list (reconcile_one). Routed through Scan to keep Rows
    # mutation in one place (no caller pokes Rows directly).
    method set_bookmark_field {path} {
        if {![dict exists $Rows $path]} return
        set row [dict get $Rows $path]
        dict set row bookmarked [file executable $path]
        dict set Rows $path $row
    }

    # Re-key a row after the underlying jsonl was renamed into a new
    # project folder. The row's path and folder are updated; mtime/size
    # are re-read because the rename preserves them but we want any
    # subsequent extend pass to see a consistent state. OnRow fires so
    # the session list can re-insert under the new folder. The caller is
    # responsible for removing the old entry from the UI first - OnRow
    # has no "forget" channel.
    method relocate_row {old_path new_path} {
        if {![dict exists $Rows $old_path]} { return }
        set row [dict get $Rows $old_path]
        dict set row path $new_path
        dict set row folder [file tail [file dirname $new_path]]
        if {[catch {file mtime $new_path} mtime]} { set mtime 0 }
        if {[catch {file size  $new_path} size]}  { set size 0 }
        dict set row mtime $mtime
        dict set row size $size
        # The +x bit is preserved by rename; re-read so the cached field
        # stays honest even if it changed out of band.
        dict set row bookmarked [file executable $new_path]
        dict unset Rows $old_path
        dict set Rows $new_path $row
        # Do not seed Folders[$new_folder] from the row's cwd_hint - the
        # hint records where the conversation ran, not what the folder
        # represents. After a move those disagree. Leave Folders alone;
        # resolve_folder will recover the new folder's identity from the
        # filesystem (candidate_cwds_for) on first lookup.
        if {$OnRow ne ""} { {*}$OnRow $row }
    }

    method destroy {} {
        my cancel
        next
    }
}
