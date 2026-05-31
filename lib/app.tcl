package require Tcl 9
package require Tk

# ::questlog::app - startup wiring. Constructs Scan, Toolbar, SessionList, Viewer,
# Search. No splash: the empty UI renders immediately and rows stream in via
# the Scan coroutine. Status-bar shows scanning progress while in flight.
#
# Layout is a horizontal split with two full-height peers: the list column on
# the left (the search/criteria toolbar above the session list, which is
# browser and search-result index in one) and the viewer pane on the right.
# Both are present from launch; the viewer shows a centered empty state until a
# session is opened. A click in the list opens the session in the viewer pane
# (anchored). The split defaults to ~58/42 in the list's favour and the sash is
# draggable.

namespace eval ::questlog::app {
    variable Scan
    variable Search
    variable Toolbar
    variable SessionList
    variable Viewer
    variable StatusVar
    variable Root
    variable PW            ;# the horizontal paned window
    variable ListFrame     ;# the list column, forgotten/re-inserted on fold
    variable ViewFrame     ;# the viewer's container, present in the PW from launch
    variable Running       ;# last polled uuid -> path running set
    variable RunTimer      ;# after-id of the running-poll loop
    variable CurrentQuery  ;# {terms <list> nocase 0|1} of the active search, or {}
    variable SidebarCollapsed ;# 1 while the list column is folded away (transient)
    variable SidebarSash      ;# remembered divider position as a fraction of width
    variable CostPending      ;# path -> cost_dict buffered for a coalesced render flush
    variable CostFlushTimer   ;# after-id of the pending cost flush, or ""
}

proc ::questlog::app::start {root {initial_criteria {}} {init_window ""} {init_search ""}} {
    variable Scan
    variable Search
    variable Toolbar
    variable SessionList
    variable Viewer
    variable StatusVar
    variable Root
    variable PW
    variable ListFrame
    variable ViewFrame
    variable Running
    variable CurrentQuery
    variable SidebarCollapsed
    variable SidebarSash
    variable CostPending
    variable CostFlushTimer

    set Root $root
    set StatusVar ""
    set Running [dict create]
    set CurrentQuery {}
    set SidebarCollapsed 0
    set SidebarSash 0.58
    set CostPending [dict create]
    set CostFlushTimer ""

    # The <<ContextMenu>> virtual event already covers Button-2 on Aqua and
    # Button-3 on X11/Windows. Tk does not include Control-Click in it on
    # macOS, so opt in here — Finder treats Ctrl+click as a secondary click,
    # and users expect the same in this app.
    if {[tk windowingsystem] eq "aqua"} {
        event add <<ContextMenu>> <Control-Button-1>
    }

    wm title . "questlog"
    # Dock/taskbar icon, rendered from the app's SVG at a few sizes so the
    # window manager has a crisp source on scaled displays. -default carries it
    # to dialogs too. Cosmetic, so a decode failure must not block startup.
    # Sizes stay under 256: Tk 9.0.2 overflows the _NET_WM_ICON length at
    # exactly 256x256 (65536 px) and writes an empty property.
    catch {
        set fh [open [file join $Root assets questlog.svg] r]
        set svg [read $fh]
        close $fh
        set icons {}
        foreach px {192 128 64} {
            lappend icons [image create photo \
                -data $svg -format [list svg -scaletoheight $px]]
        }
        wm iconphoto . -default {*}$icons
    }
    wm protocol . WM_DELETE_WINDOW [namespace code quit]

    ttk::frame .top
    pack .top -side top -fill both -expand 1

    set PW .top.pw
    ttk::panedwindow $PW -orient horizontal
    pack $PW -side top -fill both -expand 1

    # List column: the search/criteria toolbar above the session list. The
    # toolbar scopes the list (master), not the viewer (detail), so it lives
    # inside this column rather than spanning the window.
    set list_frame $PW.list
    set ListFrame $list_frame
    ttk::frame $list_frame
    set Toolbar [::questlog::ui::Toolbar new $list_frame.tb [::questlog::path::launch_cwd]]
    pack $list_frame.tb -side top -fill x
    set SessionList [::questlog::ui::SessionList new $list_frame.s \
        [namespace code resolve_folder] \
        [namespace code lookup_session] \
        [namespace code on_open] \
        [namespace code on_move_request] \
        [namespace code on_drop_move] \
        [namespace code on_bookmark_toggle] \
        [namespace code on_scan_path] \
        [namespace code on_search_cancel] \
        [namespace code on_show_all]]
    pack $list_frame.s -side top -fill both -expand 1
    $PW add $list_frame -weight 58

    # Viewer pane: a full-height peer of the list, present from launch. It
    # shows a centered empty state until the first session is previewed.
    set ViewFrame $PW.view
    ttk::frame $ViewFrame
    set Viewer [::questlog::ui::Viewer new $ViewFrame.v [namespace code toggle_sidebar]]
    pack $ViewFrame.v -side top -fill both -expand 1
    $PW add $ViewFrame -weight 42

    # -weight only distributes resize delta, not the initial sash; set the
    # ~58/42 split once the window has a real width. A one-shot <Map> that
    # unbinds itself, so a later user drag (including collapsing the viewer
    # to the edge) is never snapped back.
    bind $PW <Map> [namespace code [list init_sash %W]]

    ttk::label .top.status -textvariable [namespace which -variable StatusVar] \
        -anchor w -relief sunken
    pack .top.status -side bottom -fill x

    set Scan [::questlog::Scan new \
        [namespace code on_scan_row] \
        [namespace code on_scan_done] \
        [namespace code on_scan_progress] \
        [namespace code scan_is_typing]]

    set Search [::questlog::Search new $Scan \
        [namespace code on_search_match] \
        [namespace code on_search_progress] \
        [namespace code on_search_done]]

    # Cost scanner: rate table + tpool for the second-pass per-session
    # token sum. Load rates first so the first worker has them; init the
    # pool before any on_scan_row fires.
    ::questlog::cost::load_rates $Root
    ::questlog::cost::init [namespace code on_cost_result]

    $Toolbar subscribe [namespace code on_filter]
    # cli::parse already normalised each criterion to a canonical toolbar clause
    # kind (pattern/read/wrote/edited), so seed the toolbar directly.
    foreach c $initial_criteria {
        $Toolbar add_value [dict get $c type] [dict get $c value]
    }
    # Launch pre-fills: --window pre-selects the time radio, --search pre-fills
    # the search field. Applied before the first publish so the opening search
    # runs with them already in place.
    if {$init_window ne ""} { $Toolbar set_window $init_window }
    if {$init_search ne ""} { $Toolbar set_search $init_search }

    # Launch from inside a known project: seed an `under` chip with that
    # folder and flag it as auto-applied, so the Show-all banner can
    # reveal that the result set is being narrowed on the user's behalf.
    # Skipped when CLI criteria or a --search query were given, since the user
    # is then asking for a specific query rather than a default scope.
    if {[llength $initial_criteria] == 0 && $init_search eq ""} {
        set launch_cwd [::questlog::path::launch_cwd]
        set folder [::questlog::path::encode_cwd $launch_cwd]
        set proj [file join [::questlog::path::projects_root] $folder]
        if {[file isdirectory $proj]} {
            $Toolbar seed_under $launch_cwd
        }
    }
    $Toolbar publish

    bind . <Control-q> [namespace code quit]
    bind . <Control-b> [namespace code toggle_sidebar]

    maybe_show_onboarding
    run_tick
}

# First-launch welcome strip across the top of the window, shown until the
# reader dismisses it. It teaches what the app reads and that nothing leaves
# the machine; the dismissal is remembered by a single XDG state flag, the
# app's only cross-launch state.
proc ::questlog::app::maybe_show_onboarding {} {
    if {[::questlog::state::flag_get onboarded]} return
    set b .top.onboard
    if {[winfo exists $b]} return
    # Plain tk frame/label so -background takes (ttk would ignore it).
    frame $b -background [::questlog::theme::c onboard_bg]
    label $b.icon -text "?" -width 2 -font QLBold \
        -background [::questlog::theme::c onboard_accent] -foreground white
    frame $b.txt -background [::questlog::theme::c onboard_bg]
    label $b.txt.h -anchor w -font QLBold \
        -background [::questlog::theme::c onboard_bg] \
        -foreground [::questlog::theme::c onboard_fg] \
        -text "This is your Claude Code session history"
    label $b.txt.s -anchor w \
        -background [::questlog::theme::c onboard_bg] \
        -foreground [::questlog::theme::c onboard_sub] \
        -text "questlog reads ~/.claude/projects on this machine; nothing leaves it."
    pack $b.txt.h -side top -anchor w
    pack $b.txt.s -side top -anchor w
    ttk::button $b.got -text "Got it" -command [namespace code dismiss_onboarding]
    pack $b.icon -side left -padx {10 8} -pady 8
    pack $b.txt -side left -fill x -expand 1 -pady 6
    pack $b.got -side right -padx 10 -pady 8
    pack $b -side top -fill x -before .top.pw
}

proc ::questlog::app::dismiss_onboarding {} {
    ::questlog::state::flag_set onboarded
    if {[winfo exists .top.onboard]} { destroy .top.onboard }
}

# Fold the list column away so the viewer fills the window (Ctrl+B, or the
# viewer header's toggle), and unfold it back. `forget` keeps the column and its
# contents alive, so unfold is instant with no rescan; the divider is remembered
# as a fraction of the paned width, so a resize while folded does not misplace
# it on unfold. Transient: the app always opens unfolded.
proc ::questlog::app::toggle_sidebar {} {
    variable PW
    variable ListFrame
    variable Viewer
    variable Toolbar
    variable SidebarCollapsed
    variable SidebarSash
    # While the search field has focus, Control-b is the entry's own cursor-left;
    # leave it to the entry rather than folding the pane.
    if {[$Toolbar owns_focus]} return
    if {$SidebarCollapsed} {
        $PW insert 0 $ListFrame -weight 58
        set SidebarCollapsed 0
        after idle [list ::questlog::app::restore_sash $SidebarSash]
        $Viewer set_collapsed 0
    } else {
        set w [winfo width $PW]
        if {$w > 1} { set SidebarSash [expr {double([$PW sashpos 0]) / $w}] }
        $PW forget $ListFrame
        set SidebarCollapsed 1
        $Viewer set_collapsed 1
        focus [$Viewer textwidget]
    }
}

# Re-place the divider after the re-inserted column has been laid out (its width
# is not final in the same event-loop turn as the insert). Guarded so a fold
# that happened before this idle fired leaves it a no-op.
proc ::questlog::app::restore_sash {frac} {
    variable PW
    variable ListFrame
    variable SidebarCollapsed
    if {$SidebarCollapsed} return
    if {![winfo exists $ListFrame]} return
    update idletasks
    set w [winfo width $PW]
    if {$w <= 1} return
    $PW sashpos 0 [expr {int($frac * $w)}]
}

# Place the sash at ~58% once the paned window is mapped (its width is 1
# before that). Self-unbinds so a later manual drag is never overridden.
proc ::questlog::app::init_sash {pw} {
    bind $pw <Map> {}
    update idletasks
    set w [winfo width $pw]
    if {$w <= 1} { set w [winfo reqwidth $pw] }
    $pw sashpos 0 [expr {int($w * 0.58)}]
}

# ---- running poll ------------------------------------------------------

# Re-read the live-session registry and re-derive every row's running
# state, then re-arm. 2s keeps the markers current without busy-polling;
# the cost is O(running sessions), independent of the on-disk corpus.
proc ::questlog::app::run_tick {} {
    variable SessionList
    variable Running
    variable RunTimer
    set Running [::questlog::live::running_uuids]
    $SessionList reconcile_running $Running
    set RunTimer [after [::questlog::config::get running_poll_ms] [namespace code run_tick]]
}

# ---- toolbar callback --------------------------------------------------

proc ::questlog::app::on_filter {snapshot} {
    variable Scan
    variable Search
    variable SessionList
    variable Running
    variable CurrentQuery

    set has_criteria [::questlog::ui::any_criteria $snapshot]

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
        set terms [::questlog::ui::highlight_terms $snapshot]
        set nocase [expr {![dict get $snapshot search_case]}]
        $SessionList set_query $terms $nocase
        # Cache the query so a session opened from this result set carries it
        # into the viewer's match index. highlight_terms returns only the
        # literal search terms; read/write/edit clauses match files, not text,
        # so they contribute no in-transcript highlight.
        set CurrentQuery [dict create terms $terms nocase $nocase]
        $Search start $snapshot
    } else {
        set CurrentQuery {}
        $Search cancel
    }
}

# ---- scan callbacks ----------------------------------------------------

proc ::questlog::app::on_scan_row {row} {
    variable SessionList
    $SessionList on_scan_row $row
    # Queue a cost task only for rows that don't yet carry one. A
    # memoised row republished on a filter change already has its cost.
    if {![dict exists $row cost_usd]} {
        ::questlog::cost::start_one [dict get $row path]
    }
}

# Cost-pass worker callback. Merge into the in-memory row immediately so Rows
# stays current for lookups and memoisation, then render the visible card.
# SessionList::refresh_cost is the only path that touches the rendered meta
# region, folder aggregate, and total.
#
# Under cost_render=coalesced (the default) the visible render is buffered and
# flushed in one pass every cost_coalesce_ms, so a flood of worker results does
# not churn the list (each render is a main-thread text mutation) while the user
# interacts. immediate restores the per-result render.
proc ::questlog::app::on_cost_result {path cost_dict} {
    variable Scan
    variable SessionList
    variable CostPending
    variable CostFlushTimer
    $Scan update_cost $path $cost_dict
    if {[::questlog::config::get cost_render] eq "immediate"} {
        $SessionList refresh_cost $path $cost_dict
        return
    }
    dict set CostPending $path $cost_dict
    if {$CostFlushTimer eq ""} {
        set CostFlushTimer [after [::questlog::config::get cost_coalesce_ms] \
            [namespace code flush_cost]]
    }
}

# Drain the buffered cost results in one render pass. Keyed by path, so repeated
# results for one session within a window collapse to the last.
proc ::questlog::app::flush_cost {} {
    variable SessionList
    variable CostPending
    variable CostFlushTimer
    set CostFlushTimer ""
    set batch $CostPending
    set CostPending [dict create]
    $SessionList refresh_cost_batch $batch
}

proc ::questlog::app::on_scan_progress {done total} {
    variable StatusVar
    if {$done < $total} {
        set StatusVar "Scanning $done / $total…"
    }
}

proc ::questlog::app::on_scan_done {scanned} {
    variable StatusVar
    if {$scanned == 0} {
        set StatusVar ""
    } else {
        set StatusVar "Scanned $scanned new sessions."
    }
}

# ---- search callbacks --------------------------------------------------

proc ::questlog::app::on_search_match {match} {
    variable SessionList
    $SessionList add_match $match
}

proc ::questlog::app::on_search_progress {done total matches} {
    variable SessionList
    $SessionList set_progress $done $total $matches
}

proc ::questlog::app::on_search_done {total matches} {
    variable SessionList
    $SessionList set_done $total $matches
}

proc ::questlog::app::on_search_cancel {} {
    variable Search
    $Search cancel
}

# The Show-all banner in SessionList calls this when the user clicks
# Show all. Drop the auto-applied under chip; the toolbar will republish
# the snapshot and the banner will hide on the next apply_filter.
proc ::questlog::app::on_show_all {} {
    variable Toolbar
    $Toolbar clear_under_auto
}

# ---- open in the docked viewer -----------------------------------------

# A click (or a snippet/menu open) in the list lands here: render the whole
# session in the viewer pane and anchor it to lineno (0 = top), replacing the
# empty state. The active search query rides along so the viewer can index the
# matches in-transcript.
proc ::questlog::app::on_open {path lineno} {
    variable Viewer
    variable StatusVar
    variable CurrentQuery
    $Viewer show $path $lineno $CurrentQuery
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
proc ::questlog::app::on_move_request {paths} {
    variable Scan
    set current_folder ""
    if {[llength $paths] == 1} {
        set row [$Scan lookup [lindex $paths 0]]
        if {$row eq ""} return
        set current_folder [dict get $row folder]
    }
    ::questlog::ui::move_dialog::open . [llength $paths] $current_folder \
        [list [namespace current]::on_picker_done $paths]
}

proc ::questlog::app::on_picker_done {paths dst_cwd} {
    do_move_batch $paths $dst_cwd
}

# Drop-move resolves the dropped-on folder basename to its real cwd via the
# canonical resolver. A drop onto a folder that cannot be resolved (its
# underlying project directory is gone or ambiguous) is refused rather than
# silently moving into an orphan.
proc ::questlog::app::on_drop_move {paths target_folder_basename} {
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
proc ::questlog::app::do_move_batch {paths dst_cwd} {
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
proc ::questlog::app::move_one {src_path dst_cwd} {
    variable SessionList
    variable Scan
    set src_basename [file tail [file dirname $src_path]]
    if {![catch {::questlog::path::encode_cwd $dst_cwd} dst_basename]
        && $dst_basename eq $src_basename} {
        return
    }
    set new_path [::questlog::path::move_session $src_path $dst_cwd]
    set new_folder [::questlog::path::encode_cwd $dst_cwd]
    $Scan relocate_row $src_path $new_path
    $SessionList relocate_card $src_path $new_path $new_folder
}

# ---- bookmark callbacks ------------------------------------------------

# Toggle the +x bookmark bit on the session file. Path comes fresh from the
# clicked session, so it is current; a moved/deleted file fails the sink
# guard and is reported rather than crashing. The bit is the truth: flip it,
# refresh the cached field, then re-derive that one row's marker immediately
# so the user sees it without waiting for a tick.
proc ::questlog::app::on_bookmark_toggle {path} {
    variable Scan
    variable SessionList
    if {[file executable $path]} {
        set rc [catch {::questlog::path::clear_bookmark $path} err]
    } else {
        set rc [catch {::questlog::path::set_bookmark $path} err]
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
proc ::questlog::app::on_scan_path {path} {
    variable Scan
    return [$Scan scan_path $path]
}

# ---- shared helpers exposed to UI components --------------------------

proc ::questlog::app::resolve_folder {folder} {
    variable Scan
    return [$Scan resolve_folder $folder]
}

proc ::questlog::app::lookup_session {path} {
    variable Scan
    return [$Scan lookup $path]
}

# Typing predicate the browse Scan consults for its resume policy: true while
# the user is mid-keystroke in the search field. Delegates to the Toolbar, which
# records the keystroke deadline; the lib never references the ui directly, the
# prefix is injected at construction.
proc ::questlog::app::scan_is_typing {} {
    variable Toolbar
    return [$Toolbar is_typing]
}

proc ::questlog::app::quit {} {
    variable Search
    variable Scan
    variable RunTimer
    variable CostFlushTimer
    if {[info exists RunTimer]} { after cancel $RunTimer }
    if {[info exists CostFlushTimer] && $CostFlushTimer ne ""} {
        after cancel $CostFlushTimer
    }
    # Stop the cost pass before tearing down Scan: a worker result still in
    # flight would otherwise reach on_cost_result -> $Scan update_cost after the
    # object is gone. The epoch bump makes on_worker_result drop those results.
    ::questlog::cost::cancel
    if {[info exists Search] && $Search ne ""} { catch {$Search destroy} }
    if {[info exists Scan]   && $Scan ne ""}   { catch {$Scan destroy} }
    exit 0
}
