package require Tcl 9
package require Tk

# ::csm::app - startup wiring. Constructs Scan, Toolbar, SessionList, Viewer,
# Search. No splash: the empty UI renders immediately and rows stream in via
# the Scan coroutine. Status-bar shows scanning progress while in flight.
#
# Layout is a fixed horizontal split: the session list on the left (browser
# and search-result index in one), the reading view docked on the right. A
# single click in the list opens the session in the viewer, anchored.

namespace eval ::csm::app {
    variable Scan
    variable Search
    variable Toolbar
    variable SessionList
    variable Viewer
    variable StatusVar
    variable Root
    variable PW            ;# the horizontal paned window
    variable ViewFrame     ;# the viewer's container, added to PW on first open
    variable ViewerShown   ;# 0 until the reading view is first revealed
    variable Running       ;# last polled uuid -> path running set
    variable RunTimer      ;# after-id of the running-poll loop
}

proc ::csm::app::start {root {initial_criteria {}}} {
    variable Scan
    variable Search
    variable Toolbar
    variable SessionList
    variable Viewer
    variable StatusVar
    variable Root
    variable PW
    variable ViewFrame
    variable ViewerShown
    variable Running

    set Root $root
    set StatusVar ""
    set ViewerShown 0
    set Running [dict create]

    wm title . "Claude Session Manager"
    wm protocol . WM_DELETE_WINDOW [namespace code quit]

    ttk::frame .top
    pack .top -side top -fill both -expand 1

    set Toolbar [::csm::ui::Toolbar new .top.tb $::env(PWD)]
    pack .top.tb -side top -fill x

    set PW .top.pw
    ttk::panedwindow $PW -orient horizontal
    pack $PW -side top -fill both -expand 1

    set list_frame $PW.list
    ttk::frame $list_frame
    set SessionList [::csm::ui::SessionList new $list_frame.s \
        [namespace code resolve_folder] \
        [namespace code lookup_session] \
        [namespace code on_open] \
        [namespace code on_move_request] \
        [namespace code on_drop_move] \
        [namespace code on_bookmark_toggle] \
        [namespace code on_scan_path] \
        [namespace code on_search_cancel]]
    pack $list_frame.s -side top -fill both -expand 1
    $PW add $list_frame -weight 2

    # The reading view is built now but stays out of the paned window until a
    # session or snippet is clicked, so the window opens as just the list.
    set ViewFrame $PW.view
    ttk::frame $ViewFrame
    set Viewer [::csm::ui::Viewer new $ViewFrame.v]
    pack $ViewFrame.v -side top -fill both -expand 1

    ttk::label .top.status -textvariable [namespace which -variable StatusVar] \
        -anchor w -relief sunken
    pack .top.status -side bottom -fill x

    set Scan [::csm::Scan new \
        [namespace code on_scan_row] \
        [namespace code on_scan_done] \
        [namespace code on_scan_progress]]

    set Search [::csm::Search new $Scan \
        [namespace code on_search_match] \
        [namespace code on_search_progress] \
        [namespace code on_search_done]]

    $Toolbar subscribe [namespace code on_filter]
    foreach c $initial_criteria {
        $Toolbar add_criterion_row [dict get $c type] [dict get $c value]
    }
    $Toolbar publish

    bind . <Control-q> [namespace code quit]

    run_tick
}

# ---- running poll ------------------------------------------------------

# Re-read the live-session registry and re-derive every row's running
# state, then re-arm. 2s keeps the markers current without busy-polling;
# the cost is O(running sessions), independent of the on-disk corpus.
proc ::csm::app::run_tick {} {
    variable SessionList
    variable Running
    variable RunTimer
    set Running [::csm::live::running_uuids]
    $SessionList reconcile_running $Running
    set RunTimer [after 2000 [namespace code run_tick]]
}

# ---- toolbar callback --------------------------------------------------

proc ::csm::app::on_filter {snapshot} {
    variable Scan
    variable Search
    variable SessionList
    variable Running

    set has_criteria [::csm::ui::any_criteria $snapshot]

    $SessionList apply_filter $snapshot

    # Under running-only the reconciler builds the view straight from the
    # live registry (it scans any running file it needs on demand), so the
    # windowed replay/extend is skipped. Otherwise replay the memoised rows
    # that match the new snapshot - Scan's coroutine skips memoised paths, so
    # without this the list stays empty whenever the snapshot was previously
    # seen (e.g. 24h to 7d) - then extend for newly-windowed files. With
    # criteria active the list is built from matches, but the scan still runs
    # so Search has a corpus and lookup_session resolves rows.
    set running_only [expr {[dict exists $snapshot running_only]
                            ? [dict get $snapshot running_only] : 0}]
    if {!$running_only} {
        foreach row [$Scan query $snapshot] {
            $SessionList on_scan_row $row
        }
        $Scan extend $snapshot
    }

    # Seed running markers now, in the same event-loop turn, so there is no
    # flash of the pre-reconcile state.
    $SessionList reconcile_running $Running

    if {$has_criteria} {
        $SessionList set_query \
            [::csm::ui::regex_values $snapshot] [dict get $snapshot case]
        $Search start $snapshot
    } else {
        $Search cancel
    }
}

# ---- scan callbacks ----------------------------------------------------

proc ::csm::app::on_scan_row {row} {
    variable SessionList
    $SessionList on_scan_row $row
}

proc ::csm::app::on_scan_progress {done total} {
    variable StatusVar
    if {$done < $total} {
        set StatusVar "Scanning $done / $total…"
    }
}

proc ::csm::app::on_scan_done {scanned} {
    variable StatusVar
    if {$scanned == 0} {
        set StatusVar ""
    } else {
        set StatusVar "Scanned $scanned new sessions."
    }
}

# ---- search callbacks --------------------------------------------------

proc ::csm::app::on_search_match {match} {
    variable SessionList
    $SessionList add_match $match
}

proc ::csm::app::on_search_progress {done total matches} {
    variable SessionList
    $SessionList set_progress $done $total $matches
}

proc ::csm::app::on_search_done {total matches} {
    variable SessionList
    $SessionList set_done $total $matches
}

proc ::csm::app::on_search_cancel {} {
    variable Search
    $Search cancel
}

# ---- open in the docked viewer -----------------------------------------

# A single click in the list lands here: render the whole session on the
# right and anchor it to lineno (0 = top).
proc ::csm::app::on_open {path lineno} {
    variable Viewer
    variable StatusVar
    variable PW
    variable ViewFrame
    variable ViewerShown
    if {!$ViewerShown} {
        $PW add $ViewFrame -weight 3
        set ViewerShown 1
    }
    $Viewer show $path $lineno
    if {$lineno > 0} {
        set StatusVar "$path  (line $lineno)"
    } else {
        set StatusVar $path
    }
}

# ---- move callbacks ----------------------------------------------------

# paths is a list of session paths to move to a single destination. The
# dialog excludes the source's own folder only when exactly one session is
# moved; a group may span folders, so no folder is excluded then.
proc ::csm::app::on_move_request {paths} {
    variable Scan
    set current_folder ""
    if {[llength $paths] == 1} {
        set row [$Scan lookup [lindex $paths 0]]
        if {$row eq ""} return
        set current_folder [dict get $row folder]
    }
    ::csm::ui::move_dialog::open . [llength $paths] $current_folder \
        [list [namespace current]::on_picker_done $paths]
}

proc ::csm::app::on_picker_done {paths dst_cwd} {
    do_move_batch $paths $dst_cwd
}

# Drop-move resolves the dropped-on folder basename to its real cwd via the
# canonical resolver. A drop onto a folder that cannot be resolved (its
# underlying project directory is gone or ambiguous) is refused rather than
# silently moving into an orphan.
proc ::csm::app::on_drop_move {paths target_folder_basename} {
    variable Scan
    set dst_cwd [$Scan resolve_folder $target_folder_basename]
    if {$dst_cwd eq ""} {
        tk_messageBox -icon error -title "Move session" \
            -message "Cannot resolve destination folder: $target_folder_basename"
        return
    }
    do_move_batch $paths $dst_cwd
}

# Move every path to dst_cwd, then report any failures in one dialog so a
# batch does not spray a messagebox per session. Successful moves have
# already updated the list.
proc ::csm::app::do_move_batch {paths dst_cwd} {
    set failures [list]
    foreach src_path $paths {
        if {[catch {move_one $src_path $dst_cwd} err]} {
            lappend failures "[file tail $src_path]: $err"
        }
    }
    if {[llength $failures] > 0} {
        tk_messageBox -icon error -title "Move session" \
            -message "Move failed:\n[join $failures \n]"
    }
}

# Move one session into dst_cwd and relocate it in the list. A session
# already in the destination's encoded folder is a silent no-op - the only
# "succeed without effect" path. A filesystem failure throws (the error
# reaches do_move_batch).
proc ::csm::app::move_one {src_path dst_cwd} {
    variable SessionList
    variable Scan
    set src_basename [file tail [file dirname $src_path]]
    if {![catch {::csm::path::encode_cwd $dst_cwd} dst_basename]
        && $dst_basename eq $src_basename} {
        return
    }
    set new_path [::csm::path::move_session $src_path $dst_cwd]
    set new_folder [::csm::path::encode_cwd $dst_cwd]
    $Scan relocate_row $src_path $new_path
    $SessionList relocate_card $src_path $new_path $new_folder
}

# ---- bookmark callbacks ------------------------------------------------

# Toggle the +x bookmark bit on the session file. Path comes fresh from the
# clicked session, so it is current; a moved/deleted file fails the sink
# guard and is reported rather than crashing. The bit is the truth: flip it,
# refresh the cached field, then re-derive that one row's marker immediately
# so the user sees it without waiting for a tick.
proc ::csm::app::on_bookmark_toggle {path} {
    variable Scan
    variable SessionList
    if {[file executable $path]} {
        set rc [catch {::csm::path::clear_bookmark $path} err]
    } else {
        set rc [catch {::csm::path::set_bookmark $path} err]
    }
    if {$rc} {
        tk_messageBox -icon error -title "Bookmark" \
            -message "Bookmark failed: $err"
        return
    }
    $Scan set_bookmark_field $path
    $SessionList reconcile_one $path
}

# Synchronously scan one file into Rows, for the reconciler to surface a
# running session that the windowed scan has not reached.
proc ::csm::app::on_scan_path {path} {
    variable Scan
    return [$Scan scan_path $path]
}

# ---- shared helpers exposed to UI components --------------------------

proc ::csm::app::resolve_folder {folder} {
    variable Scan
    return [$Scan resolve_folder $folder]
}

proc ::csm::app::lookup_session {path} {
    variable Scan
    return [$Scan lookup $path]
}

proc ::csm::app::quit {} {
    variable Search
    variable Scan
    variable RunTimer
    if {[info exists RunTimer]} { after cancel $RunTimer }
    if {[info exists Search] && $Search ne ""} { catch {$Search destroy} }
    if {[info exists Scan]   && $Scan ne ""}   { catch {$Scan destroy} }
    exit 0
}
