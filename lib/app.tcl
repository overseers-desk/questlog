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
}

proc ::csm::app::start {root} {
    variable Scan
    variable Search
    variable Toolbar
    variable Tree
    variable Results
    variable StatusVar
    variable PW
    variable ResultsVisible
    variable Root

    set Root $root
    set ResultsVisible 0
    set StatusVar ""

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
        [namespace code on_scope_change]]
    pack $tree_frame.t -side top -fill both -expand 1
    $PW add $tree_frame -weight 3

    set res_frame $PW.res
    ttk::frame $res_frame
    set Results [::csm::ui::Results new $res_frame.r \
        [namespace code resolve_folder] \
        [namespace code on_search_cancel] \
        [namespace code on_result_select] \
        [namespace code on_result_open]]
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
    $Toolbar publish

    bind . <Control-q> [namespace code quit]
}

# ---- toolbar callback --------------------------------------------------

proc ::csm::app::on_filter {snapshot} {
    variable Scan
    variable Search
    variable Tree
    variable Results
    variable PW
    variable ResultsVisible

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

    # Replay already-memoised rows that match the new snapshot - Scan's
    # coroutine skips memoised paths, so without this the tree stays
    # empty whenever the snapshot was previously seen (e.g. 24h → 7d).
    foreach row [$Scan query $snapshot] {
        $Tree on_scan_row $row
    }

    # Then extend in case the new window includes files not yet scanned.
    $Scan extend $snapshot

    if {$has_regex} {
        $Results clear
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

proc ::csm::app::on_search_match {is_first path lineoff ts snippet folder} {
    variable Tree
    variable Results
    $Tree update_match $is_first $path $lineoff $ts $snippet $folder
    $Results add_match $is_first $path $lineoff $ts $snippet $folder
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
    if {[info exists Search] && $Search ne ""} { catch {$Search destroy} }
    if {[info exists Scan]   && $Scan ne ""}   { catch {$Scan destroy} }
    exit 0
}
