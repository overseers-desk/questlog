package require Tcl 9
package require Tk

# ::csm::app - startup wiring. Constructs Scan, Toolbar, Tree, Results,
# Search. No splash: the empty UI renders immediately and rows stream in
# via the Scan coroutine. Status-bar shows scanning progress while in
# flight.

namespace eval ::csm::app {
    variable Scan
    variable Search
    variable Toolbar
    variable Tree
    variable Results
    variable StatusVar
    variable PW
    variable ResultsVisible
    variable Root
    variable Running       ;# last polled uuid -> path running set
    variable RunTimer      ;# after-id of the running-poll loop
}

proc ::csm::app::start {root {initial_patterns {}}} {
    variable Scan
    variable Search
    variable Toolbar
    variable Tree
    variable Results
    variable StatusVar
    variable PW
    variable ResultsVisible
    variable Root
    variable Running

    set Root $root
    set ResultsVisible 0
    set StatusVar ""
    set Running [dict create]

    wm title . "Claude Session Manager"
    wm protocol . WM_DELETE_WINDOW [namespace code quit]

    ttk::frame .top
    pack .top -side top -fill both -expand 1

    set Toolbar [::csm::ui::Toolbar new .top.tb $::env(PWD)]
    pack .top.tb -side top -fill x

    set PW .top.pw
    ttk::panedwindow $PW -orient vertical
    pack $PW -side top -fill both -expand 1

    set tree_frame $PW.tree
    ttk::frame $tree_frame
    set Tree [::csm::ui::Tree new $tree_frame.t \
        [namespace code resolve_folder] \
        [namespace code lookup_session] \
        [namespace code on_session_select] \
        [namespace code on_session_open] \
        [namespace code on_scope_change] \
        [namespace code on_move_request] \
        [namespace code on_drop_move] \
        [namespace code on_bookmark_toggle] \
        [namespace code on_scan_path]]
    pack $tree_frame.t -side top -fill both -expand 1
    $PW add $tree_frame -weight 3

    set res_frame $PW.res
    ttk::frame $res_frame
    set Results [::csm::ui::Results new $res_frame.r \
        [namespace code resolve_folder] \
        [namespace code on_search_cancel] \
        [namespace code on_result_select] \
        [namespace code on_result_open] \
        [namespace code on_move_request] \
        [namespace code on_drop_move] \
        [$Tree tv_path]]
    pack $res_frame.r -side top -fill both -expand 1

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
    foreach pat $initial_patterns { $Toolbar add_row $pat }
    $Toolbar publish

    bind . <Control-q> [namespace code quit]

    run_tick
}

# ---- running poll ------------------------------------------------------

# Re-read the live-session registry and re-derive every row's running
# state, then re-arm. 2s keeps the markers current without busy-polling;
# the cost is O(running sessions), independent of the on-disk corpus.
proc ::csm::app::run_tick {} {
    variable Tree
    variable Running
    variable RunTimer
    set Running [::csm::live::running_uuids]
    $Tree reconcile_running $Running
    set RunTimer [after 2000 [namespace code run_tick]]
}

# ---- toolbar callback --------------------------------------------------

proc ::csm::app::on_filter {snapshot} {
    variable Scan
    variable Search
    variable Tree
    variable Results
    variable PW
    variable ResultsVisible
    variable Running

    set has_regex [::csm::ui::any_pattern $snapshot]
    if {$has_regex && !$ResultsVisible} {
        $PW add $PW.res -weight 2
        set ResultsVisible 1
    } elseif {!$has_regex && $ResultsVisible} {
        $PW forget $PW.res
        $Results clear
        set ResultsVisible 0
    }

    $Tree apply_filter $snapshot

    # Under running-only the reconciler builds the view straight from the
    # live registry (it scans any running file it needs on demand), so the
    # windowed replay/extend is skipped. Otherwise replay the memoised
    # rows that match the new snapshot - Scan's coroutine skips memoised
    # paths, so without this the tree stays empty whenever the snapshot was
    # previously seen (e.g. 24h to 7d) - then extend for newly-windowed
    # files.
    set running_only [expr {[dict exists $snapshot running_only]
                            ? [dict get $snapshot running_only] : 0}]
    if {!$running_only} {
        foreach row [$Scan query $snapshot] {
            $Tree on_scan_row $row
        }
        $Scan extend $snapshot
    }

    # Seed running markers and membership now, in the same event-loop turn,
    # so there is no flash of the pre-reconcile state.
    $Tree reconcile_running $Running

    if {$has_regex} {
        $Results clear
        $Results set_query \
            [dict get $snapshot regex] [dict get $snapshot case]
        $Search start $snapshot
    } else {
        $Search cancel
    }
}

# ---- scan callbacks ----------------------------------------------------

proc ::csm::app::on_scan_row {row} {
    variable Tree
    $Tree on_scan_row $row
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

proc ::csm::app::on_search_match {is_first path lineoff ts btype content folder} {
    variable Tree
    variable Results
    $Tree update_match $is_first $path $lineoff $ts $content $folder
    $Results add_match $is_first $path $lineoff $ts $btype $content $folder
}

proc ::csm::app::on_search_progress {done total matches} {
    variable Results
    $Results set_progress $done $total $matches
}

proc ::csm::app::on_search_done {total matches} {
    variable Results
    $Results set_done $total $matches
}

proc ::csm::app::on_search_cancel {} {
    variable Search
    $Search cancel
}

# ---- tree / results callbacks ------------------------------------------

proc ::csm::app::on_session_select {path} {
    variable StatusVar
    set StatusVar $path
}

proc ::csm::app::on_session_open {path} {
    ::csm::ui::Viewer new $path 0
}

proc ::csm::app::on_scope_change {type key} {
    variable Results
    $Results set_scope $type $key
}

proc ::csm::app::on_result_select {path lineoff} {
    variable Tree
    variable StatusVar
    $Tree select_path $path
    set StatusVar "$path  (line $lineoff)"
}

proc ::csm::app::on_result_open {path lineoff} {
    ::csm::ui::Viewer new $path $lineoff
}

# ---- move callbacks ----------------------------------------------------

proc ::csm::app::on_move_request {src_path} {
    variable Scan
    set row [$Scan lookup $src_path]
    if {$row eq ""} return
    set current_folder [dict get $row folder]
    ::csm::ui::move_dialog::open . $src_path $current_folder \
        [list [namespace current]::on_picker_done $src_path]
}

proc ::csm::app::on_picker_done {src_path dst_cwd} {
    do_move $src_path $dst_cwd
}

# Drop-move resolves the dropped-on folder basename to its real cwd via
# the canonical resolver. A drop onto a folder that cannot be resolved
# (its underlying project directory is gone or ambiguous) is refused
# rather than silently moving into an orphan.
proc ::csm::app::on_drop_move {src_path target_folder_basename} {
    variable Scan
    set dst_cwd [$Scan resolve_folder $target_folder_basename]
    if {$dst_cwd eq ""} {
        tk_messageBox -icon error -title "Move session" \
            -message "Cannot resolve destination folder: $target_folder_basename"
        return
    }
    do_move $src_path $dst_cwd
}

proc ::csm::app::do_move {src_path dst_cwd} {
    variable Tree
    variable Results
    variable Scan
    # Silent no-op when src is already in the destination's encoded
    # folder - the only "succeed without effect" path. Everything else
    # either succeeds with effects or fails with a messagebox.
    set src_basename [file tail [file dirname $src_path]]
    if {![catch {::csm::path::encode_cwd $dst_cwd} dst_basename]
        && $dst_basename eq $src_basename} {
        return
    }
    if {[catch {::csm::path::move_session $src_path $dst_cwd} new_path]} {
        tk_messageBox -icon error -title "Move session" \
            -message "Move failed: $new_path"
        return
    }
    set new_folder [::csm::path::encode_cwd $dst_cwd]
    $Tree relocate_session $src_path $new_path
    $Scan relocate_row $src_path $new_path
    $Results relocate_card $src_path $new_path $new_folder
}

# ---- bookmark callbacks ------------------------------------------------

# Toggle the +x bookmark bit on the session file. Path comes fresh from
# the clicked iid, so it is current; a moved/deleted file fails the sink
# guard and is reported rather than crashing (mirrors do_move). The bit is
# the truth: flip it, refresh the cached field, then re-derive that one
# row's marker immediately so the user sees it without waiting for a tick.
proc ::csm::app::on_bookmark_toggle {path} {
    variable Scan
    variable Tree
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
    $Tree reconcile_one $path
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
