package require Tcl 9
package require Tk

# ::questlog::ui::app - startup wiring. Constructs Scan, Toolbar, SessionList, Viewer,
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

namespace eval ::questlog::ui::app {
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
    variable RenamePoll    ;# after-id of the rename dialog's running-state poll
    variable RenameEntry   ;# -textvariable backing the rename dialog's entry
    variable RenameOutcome ;# ok|cancel sentinel the rename dialog vwaits on
    variable CurrentQuery  ;# {terms <list> nocase 0|1} of the active search, or {}
    variable SidebarCollapsed ;# 1 while the list column is folded away (transient)
    variable SidebarSash      ;# remembered divider position as a fraction of width
    variable CostPending      ;# path -> cost_dict buffered for a coalesced render flush
    variable CostFlushTimer   ;# after-id of the pending cost flush, or ""
    variable SearchPending    ;# list of per-file match lists buffered for an idle flush
    variable SearchFlushTimer ;# after-id of the pending search-render flush, or ""
    variable CostPool         ;# Thread pool for background cost calculation
    variable CostEpoch        ;# Epoch to drop stale results after a filter change
    variable CostWorkerScript ;# Script evaluated in each cost worker
    variable StatusMode       ;# browse|scanning|searching|search_done|search_cancelled
    variable SearchSummary    ;# persistent terminal search line, "" when no criteria active
    variable ViewerPath       ;# opened-session path line; overrides every mode, "" when none
    variable CriteriaActive   ;# 1 while search criteria are active (mirror of the snapshot)
    variable ProgressLine     ;# in-flight "Scanning…" / "Searching…" text, owned by the mode
    variable PeekText         ;# a hover reveal that overrides the mode until unpeeked, "" at rest
    variable ScanActive       ;# 1 while the corpus scan coroutine is in flight
    variable SearchActive     ;# 1 while a search is in flight
    variable CostOutstanding  ;# cost jobs posted but not yet returned (the cost pass is live when > 0)
    variable PrevSnapshot     ;# the last published snapshot, to skip a rebuild on a no-op republish
    variable FilterState      ;# the strip's filter state, as the list last handed it back; the poll gathers membership for these filters
}

proc ::questlog::ui::app::start {root {seed {}}} {
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
    variable RunTimer
    variable CurrentQuery
    variable SidebarCollapsed
    variable SidebarSash
    variable CostPending
    variable CostFlushTimer
    variable SearchPending
    variable SearchFlushTimer
    variable CostPool
    variable CostEpoch
    variable CostWorkerScript
    variable StatusMode
    variable SearchSummary
    variable ViewerPath
    variable CriteriaActive
    variable ProgressLine
    variable PeekText
    variable ScanActive
    variable SearchActive
    variable CostOutstanding
    variable PrevSnapshot
    variable FilterState

    set Root $root
    set StatusMode browse
    set SearchSummary ""
    set ViewerPath ""
    set CriteriaActive 0
    set ProgressLine ""
    set PeekText ""
    set ScanActive 0
    set SearchActive 0
    set CostOutstanding 0
    # The first publish has nothing to diff against, so it always takes the heavy path.
    set PrevSnapshot {}
    # No filter is on until the reader flips one on the strip, so the poll gathers
    # no membership until the list hands a filter change back through on_filter_change.
    set FilterState {}
    set StatusVar [bounds_status]
    set Running [dict create]
    set CurrentQuery {}
    set SidebarCollapsed 0
    set SidebarSash 0.58
    set CostPending [dict create]
    set CostFlushTimer ""
    set SearchPending [list]
    set SearchFlushTimer ""
    set CostPool ""
    set CostEpoch 0
    set CostWorkerScript {
        package require Tcl 9
        package require Thread
        proc dispatch_main {path tid epoch} {
            set r [::questlog::cost::parse_file $path]
            thread::send -async $tid \
                [list ::questlog::ui::app::on_cost_worker_result $path $epoch $r]
        }
    }

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

    # Thread is the designed dependency (search fan-out, cost tpool); a host
    # without it still runs, single-threaded: search on the coroutine path,
    # the cost pass on the main thread, which can stutter the window during a
    # big parse. This banner says so, with the remedy. QUESTLOG_THREADS=0
    # acknowledges single-thread mode and silences it.
    set tv [::questlog::search::env_threads]
    if {![::questlog::search::thread_available] && ($tv eq "" || $tv != 0)} {
        ttk::label .top.threadnotice -style Notice.TLabel -anchor w -text \
            "Thread package missing: running single-threaded. Search is\
            slower and the window may stutter during the cost pass. Install\
            it (Debian/Ubuntu: tcl9.0-thread), or set QUESTLOG_THREADS=0 to\
            hide this notice."
        pack .top.threadnotice -side top -fill x
    }

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
        [namespace code folder_cwd] \
        [namespace code on_open] \
        [namespace code on_move_request] \
        [namespace code on_drop_move] \
        [namespace code on_bookmark_toggle] \
        [namespace code on_bookmark_set] \
        [namespace code on_rename_request] \
        [namespace code on_scan_path] \
        [namespace code on_search_cancel] \
        [namespace code on_subagents] \
        [namespace code on_subagent_cost] \
        [namespace code on_widen] \
        [namespace code status_peek] \
        [namespace code status_unpeek] \
        [namespace code on_folder_bound] \
        [namespace code on_filter_change]]
    pack $list_frame.s -side top -fill both -expand 1
    $PW add $list_frame -weight 58

    # Viewer pane: a full-height peer of the list, present from launch. It
    # shows a centered empty state until the first session is previewed.
    set ViewFrame $PW.view
    ttk::frame $ViewFrame
    set Viewer [::questlog::ui::Viewer new $ViewFrame.v \
        [namespace code toggle_sidebar] \
        [namespace code on_move_request] \
        [namespace code on_bookmark_toggle] \
        [namespace code on_rename_request] \
        [namespace code on_scan_path]]
    pack $ViewFrame.v -side top -fill both -expand 1
    $PW add $ViewFrame -weight 42

    # -weight only distributes resize delta, not the initial sash; set the
    # ~58/42 split once the window has a real width. A one-shot <Map> that
    # unbinds itself, so a later user drag (including collapsing the viewer
    # to the edge) is never snapped back.
    bind $PW <Map> [namespace code [list init_sash %W]]

    # Bottom strip: a sunken status label that fills the width, with an
    # indeterminate progress bar docked at the right that update_spinner packs
    # only while work is in flight (gone at rest, so the label reclaims the row).
    # Indeterminate, not determinate: the cost pass has no denominator and the
    # liveness predicate spans scan, search and cost; the numeric counts already
    # live in the text.
    ttk::frame .top.statusbar
    pack .top.statusbar -side bottom -fill x
    ttk::progressbar .top.statusbar.spin -mode indeterminate -length 90
    ttk::label .top.statusbar.status -textvariable [namespace which -variable StatusVar] \
        -anchor w -relief sunken
    pack .top.statusbar.status -side left -fill x -expand 1

    set Scan [::questlog::Scan new \
        [namespace code on_scan_row] \
        [namespace code on_scan_done] \
        [namespace code on_scan_progress] \
        [namespace code scan_is_typing] \
        [namespace code known_mtime]]

    set Search [::questlog::Search new $Scan \
        [namespace code on_search_file] \
        [namespace code on_search_progress] \
        [namespace code on_search_done]]

    # Cost scanner: rate table + tpool for the second-pass per-session
    # token sum. Load rates first so the first worker has them; init the
    # pool before any on_scan_row fires.
    ::questlog::cost::load_rates $Root
    init_cost_pool

    # The launcher normalised the command line's query into toolbar clause kinds
    # (file/tool/pattern/subtree) with their values - a {op path} or {name key}
    # pair for file and tool - so seed the toolbar directly, BEFORE subscribing:
    # each add_value publishes, and a subscriber attached first would start one
    # scan-and-search per seeded criterion instead of one for the launch.
    foreach c [dict getdef $seed criteria {}] {
        $Toolbar add_value [lindex $c 0] [lindex $c 1]
    }
    $Toolbar subscribe [namespace code on_filter]
    # The rest of the query: --since pre-selects the time radio, --keyword fills
    # the search field, --case sets the Aa toggle. Applied before the first
    # publish so the opening search runs with them already in place.
    if {[dict getdef $seed since ""] ne ""} { $Toolbar set_window [dict get $seed since] }
    if {[dict getdef $seed search ""] ne ""} { $Toolbar set_search [dict get $seed search] }
    if {[dict getdef $seed case 0]} { $Toolbar set_case 1 }

    bind . <Control-q> [namespace code quit]
    bind . <Control-b> [namespace code toggle_sidebar]

    maybe_show_onboarding

    # Paint the assembled skeleton before any corpus work begins, so the window
    # is on screen in a fraction of a second and the session rows stream into it.
    # The first map is idle-priority work; left to compete with the scan's
    # millisecond resume timer (and, on a host without the Thread package, the
    # main-thread cost parse) it is starved until the whole pass drains, and the
    # window then appears all at once, finished. This one pump maps it first.
    update idletasks

    # No default `subtree`: the list opens across every project, and a scope is
    # added only when the user asks for one. A launch-cwd default scoped the list
    # to wherever questlog happened to be started - often the home directory, a
    # parent of everything - which both assumed the user keeps code under home and
    # silenced any scope they then added (subtree entries are OR'd, so a home
    # entry kept the whole corpus in view until it was removed).
    $Toolbar publish

    # The running-session poll's first tick reads the live set and scans each
    # live session; without the Thread package its cost parse runs on the main
    # thread. Defer it off the first-paint path so the mapped window is drawn and
    # interactive before it runs; it then re-arms itself on its own cadence.
    # Recorded in RunTimer like every re-arm, so a quit landing before the
    # first tick has an id to cancel.
    set RunTimer [after idle [namespace code run_tick]]
}

# First-launch welcome strip across the top of the window, shown until the
# reader dismisses it. It teaches what the app reads and that nothing leaves
# the machine; the dismissal is remembered by a single XDG state flag, the
# app's only cross-launch state.
proc ::questlog::ui::app::maybe_show_onboarding {} {
    if {[::questlog::ui::state::flag_get onboarded]} return
    set b .top.onboard
    if {[winfo exists $b]} return
    # Plain tk frame/label so -background takes (ttk would ignore it).
    frame $b -background [::questlog::ui::theme::c onboard_bg]
    label $b.icon -text "?" -width 2 -font QLBold \
        -background [::questlog::ui::theme::c onboard_accent] -foreground white
    frame $b.txt -background [::questlog::ui::theme::c onboard_bg]
    label $b.txt.h -anchor w -font QLBold \
        -background [::questlog::ui::theme::c onboard_bg] \
        -foreground [::questlog::ui::theme::c onboard_fg] \
        -text "This is your Claude Code session history"
    label $b.txt.s -anchor w \
        -background [::questlog::ui::theme::c onboard_bg] \
        -foreground [::questlog::ui::theme::c onboard_sub] \
        -text "questlog reads ~/.claude/projects on this machine; nothing leaves it."
    pack $b.txt.h -side top -anchor w
    pack $b.txt.s -side top -anchor w
    ttk::button $b.got -text "Got it" -command [namespace code dismiss_onboarding]
    pack $b.icon -side left -padx {10 8} -pady 8
    pack $b.txt -side left -fill x -expand 1 -pady 6
    pack $b.got -side right -padx 10 -pady 8
    pack $b -side top -fill x -before .top.pw
}

proc ::questlog::ui::app::dismiss_onboarding {} {
    ::questlog::ui::state::flag_set onboarded
    if {[winfo exists .top.onboard]} { destroy .top.onboard }
}

# Fold the list column away so the viewer fills the window (Ctrl+B, or the
# viewer header's toggle), and unfold it back. `forget` keeps the column and its
# contents alive, so unfold is instant with no rescan; the divider is remembered
# as a fraction of the paned width, so a resize while folded does not misplace
# it on unfold. Transient: the app always opens unfolded.
proc ::questlog::ui::app::toggle_sidebar {} {
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
        after idle [list ::questlog::ui::app::restore_sash $SidebarSash]
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
proc ::questlog::ui::app::restore_sash {frac} {
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
proc ::questlog::ui::app::init_sash {pw} {
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
proc ::questlog::ui::app::run_tick {} {
    variable SessionList
    variable Running
    variable RunTimer
    set Running [::questlog::ui::live::running_uuids]
    $SessionList reconcile_running $Running
    # The same tick refreshes the membership the active filters claim, so a session
    # that starts running outside the search's window is counted (and named) within
    # one poll of starting, rather than staying silently absent.
    refresh_filter_members
    # Heartbeat backstop: if a done-signal is ever missed, the next tick settles
    # the spinner once the liveness flags have all cleared.
    update_spinner
    set RunTimer [after [::questlog::config::get running_poll_ms] [namespace code run_tick]]
}

# ---- what the active filters hold, beyond what the search loaded ----------

# The membership the active filters claim, gathered outside the search and handed
# to the list, which counts it against the rows it did load and says the cut (see
# the filter-cut section of ui/sessions.tcl). Running is free: the live registry
# knows every session running on this machine, whatever window the search ran
# with. Bookmarked is the file's +x bit, so its membership is a stat sweep of the
# corpus - cheap, but never on the filter's own path: it runs here, on the poll and
# on a filter change, so toggling a filter stays an instant in-place re-filter and
# the count lands a moment behind it. The model filter has no membership outside the
# loaded rows (a row's model is known only once its transcript is parsed), so
# member_filters leaves it out and the strip claims nothing for it.
#
# Each filter gathers its own set; filter_members reduces them to the membership the
# filters jointly claim, which with both on is the intersection - the sessions the
# list would show if the search had loaded them, and nothing else.
#
# Which filters are on comes from FilterState, the strip state the list hands
# back through on_filter_change: the filters are the strip's now, not the toolbar's,
# so the toolbar's published snapshot carries none of them.
proc ::questlog::ui::app::refresh_filter_members {} {
    variable SessionList
    variable FilterState
    set sets [list]
    foreach f [::questlog::listfilter::member_filters $FilterState] {
        switch -- $f {
            running    { lappend sets [::questlog::ui::live::running_sessions] }
            bookmarked { lappend sets [bookmarked_members] }
        }
    }
    $SessionList set_filter_members [::questlog::listfilter::filter_members $sets]
}

# A strip filter moved. The list has already re-derived the view in place and
# handed the new filter state back here; remember it so the poll gathers
# membership for the same filters, then gather now so the count lands with the
# toggle. No scope or search changed, so nothing re-scans.
proc ::questlog::ui::app::on_filter_change {state} {
    variable FilterState
    set FilterState $state
    refresh_filter_members
}

# Every bookmarked session on disk, uuid -> {path}: one glob per project folder
# and one stat per session file. The +x bit is the bookmark, so this is the
# Bookmarked filter's whole membership, window or no window.
#
# It opens nothing and resolves no folder. This runs on the filter fast path and
# again on every poll tick while the filter is on, and a filter may not read a
# transcript - so no cwd is stamped here. The one or two members the banner
# NAMES get their project out of the no-read resolver, and only then (member_name
# in ui/sessions.tcl).
proc ::questlog::ui::app::bookmarked_members {} {
    set out [dict create]
    set root [::questlog::path::projects_root]
    if {![file isdirectory $root]} { return $out }
    foreach folder [glob -nocomplain -directory $root -type d -- *] {
        foreach path [glob -nocomplain -directory $folder -- *.jsonl] {
            if {![file executable $path]} continue
            dict set out [file rootname [file tail $path]] [dict create path $path]
        }
    }
    return $out
}

# The cut banner's widen escape: relax the criterion that left the named session
# on disk. The criterion is the toolbar's own state, so the toolbar drops it and
# publishes; the list then rebuilds on the resulting snapshot like it does for any
# other filter change, and the session loads with the rest.
proc ::questlog::ui::app::on_widen {criterion} {
    variable Toolbar
    $Toolbar widen $criterion
}

# Scope the search to one folder (the list's folder right-click): push the
# folder's project cwd into the toolbar's subtree facet and publish. subtree is
# one of the keys bounds_equal reads, so the new snapshot forces the full rebuild
# in on_filter rather than the view-only fast path. A folder whose directory is
# gone resolves to "" and scopes nothing.
proc ::questlog::ui::app::on_folder_bound {folder} {
    variable Toolbar
    set cwd [folder_cwd $folder]
    if {$cwd eq ""} return
    $Toolbar add_value subtree [::questlog::path::canon_dir $cwd]
}

# ---- toolbar callback --------------------------------------------------

# The snapshot keys that define the search and scope - every key the toolbar now
# publishes. Two publishes equal across all of them changed nothing that decides
# which sessions load, so on_filter can skip the rebuild.
proc ::questlog::ui::app::bounds_equal {a b} {
    foreach k {search search_case search_regions file tool pattern subtree since until min_turns} {
        if {[dict getdef $a $k {}] ne [dict getdef $b $k {}]} { return 0 }
    }
    return 1
}

proc ::questlog::ui::app::on_filter {snapshot} {
    variable Scan
    variable Search
    variable SessionList
    variable Running
    variable CurrentQuery
    variable StatusMode
    variable SearchSummary
    variable ViewerPath
    variable CriteriaActive
    variable ProgressLine
    variable ScanActive
    variable SearchActive
    variable PrevSnapshot

    # A republish whose scope and search keys all match the last one changed
    # nothing that decides which sessions load, so the rebuild below would only
    # reproduce what is already shown. Skip it, keeping the list and its selection.
    # The list-view filters do not ride the snapshot: they live on the list strip
    # and re-filter the loaded rows in place, telling the app through on_filter_change.
    if {$PrevSnapshot ne {} && [bounds_equal $PrevSnapshot $snapshot]} {
        set PrevSnapshot $snapshot
        return
    }

    set has_criteria [::questlog::ui::any_criteria $snapshot]
    ::questlog::debug::log search "on_filter begin: search='[dict get $snapshot search]' has_criteria=$has_criteria"
    # A new filter or search supersedes the opened-session path on the bar and
    # records whether the search modes own it (the scan-progress clobber guard).
    set ViewerPath ""
    set CriteriaActive $has_criteria

    # A new filter/search invalidates the previous result set; drop any buffered
    # per-file results and cancel a pending flush before the list is cleared, so
    # a stale session never renders into the fresh list.
    discard_search_buffer
    $SessionList apply_filter $snapshot

    # Replay the store's retained rows that match the new snapshot - Scan
    # itself remembers no rows (its differential skip answers through
    # known_mtime), so without this the list stays empty whenever the
    # snapshot was previously seen (e.g. 24h to 7d) - then extend for
    # newly-windowed files. apply_filter above retired every loaded row into
    # the store's detached retention (its clear runs retire_all, not a wipe);
    # replay_bounds re-attaches the ones the new scope admits, applying the
    # same pure predicate
    # (::questlog::scan::row_in_bounds over payload_bounds_row's fields) that
    # on_scan_row applies as its admission gate. No disk: the widget's node
    # store is the memo, session data's one in-memory home. Model membership
    # is the scope's question alone; the list-view filters only decide which
    # in-model rows paint (the engine's attr_admits), so a scope change under
    # running-only repopulates like any other and untoggling shows the full
    # corpus instantly. With criteria active the list is built from matches
    # (replay_bounds attaches nothing), but the scan still runs so Search has
    # a corpus to stage rows from.
    $SessionList replay_bounds
    set ScanActive 1
    $Scan extend $snapshot

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
        set StatusMode searching
        set SearchSummary ""
        set ProgressLine "Searching…"
        set SearchActive 1
        ::questlog::debug::log search "SEARCH START: scanning corpus for '[dict get $snapshot search]'"
        $Search start $snapshot
    } else {
        set CurrentQuery {}
        $Search cancel
        set SearchActive 0
        set StatusMode browse
        set SearchSummary ""
    }
    refresh_status
    update_spinner
    set PrevSnapshot $snapshot
    # A new scope or search loads a different set of rows, so what the filter is
    # missing has changed even though the filter has not.
    refresh_filter_members
}

# ---- scan callbacks ----------------------------------------------------

proc ::questlog::ui::app::on_scan_row {row} {
    variable SessionList
    $SessionList on_scan_row $row
    # Queue a cost task only when the store does not already price this row.
    # A scan row carries no cost fields of its own (and a search republish
    # of an unchanged file carries nothing the store lacks), so the store's
    # copy - written by the row landing just above - is what says whether the
    # pass already ran; a changed file re-enters costless and is re-priced.
    set path [dict get $row path]
    if {![dict exists $row cost_usd] && [$SessionList stored_cost $path] eq ""} {
        start_cost_one $path
    }
}

# Cost-pass worker callback. SessionList::refresh_cost is the only path that
# touches the store's cost fields, the rendered meta region, folder aggregate,
# and total.
#
# Under cost_render=coalesced (the default) the visible render is buffered and
# flushed in one pass every cost_coalesce_ms, so a flood of worker results does
# not churn the list (each render is a main-thread text mutation) while the user
# interacts. immediate restores the per-result render.
proc ::questlog::ui::app::on_cost_result {path cost_dict} {
    variable SessionList
    variable CostPending
    variable CostFlushTimer
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
proc ::questlog::ui::app::flush_cost {} {
    variable SessionList
    variable CostPending
    variable CostFlushTimer
    set CostFlushTimer ""
    set batch $CostPending
    set CostPending [dict create]
    $SessionList refresh_cost_batch $batch
}

# The single writer of the bottom bar's text. A hover peek overrides
# everything; then an opened session's path; otherwise the text follows
# StatusMode: the in-flight ProgressLine
# while scanning or searching, the persistent SearchSummary once a search has
# finished or been cancelled, and the resting scope line while browsing. Every
# callback that changes a mode or a stored line ends by calling this, so the bar
# is always whatever the current state says it is and nothing leaks across.
proc ::questlog::ui::app::refresh_status {} {
    variable StatusVar
    variable StatusMode
    variable SearchSummary
    variable ViewerPath
    variable ProgressLine
    variable PeekText
    # A hover reveal sits above every mode: while a peek is up the bar shows it
    # verbatim. A mode change arriving mid-peek still runs its refresh_status and
    # updates the stored lines (ProgressLine, SearchSummary, ...) - it just does
    # not paint here - so status_unpeek can re-derive from the machine's current
    # state rather than restoring a snapshot taken when the peek began.
    if {$PeekText ne ""} {
        set StatusVar $PeekText
        return
    }
    if {$ViewerPath ne ""} {
        set StatusVar $ViewerPath
        return
    }
    switch -- $StatusMode {
        scanning - searching { set StatusVar $ProgressLine }
        search_done - search_cancelled { set StatusVar $SearchSummary }
        default { set StatusVar [bounds_status] }
    }
}

# The narrow peek/restore pair the session list hovers a clipped snippet
# through. peek shows $text on the bar over whatever the mode would otherwise
# show; unpeek clears the flag and lets refresh_status re-derive the standing
# text from the machine's current state. The list owns neither StatusVar nor the
# label - it goes through these so the mode's other writers stay coherent.
proc ::questlog::ui::app::status_peek {text} {
    variable PeekText
    set PeekText $text
    refresh_status
}
proc ::questlog::ui::app::status_unpeek {} {
    variable PeekText
    set PeekText ""
    refresh_status
}

# Show the progress bar while any background work runs (scan, search, or the
# cost pass), hide it at rest. The single liveness authority: every site that
# flips one of the three flags calls this, and run_tick calls it too so a missed
# done-signal cannot leave the bar spinning. Packed -before the status label so
# the bar reserves the right edge and the label fills the rest.
proc ::questlog::ui::app::update_spinner {} {
    variable ScanActive
    variable SearchActive
    variable CostOutstanding
    set spin .top.statusbar.spin
    # The widget command doubles as the existence test: [winfo exists] would
    # itself error once quit has destroyed the window, winfo included.
    if {![llength [info commands $spin]]} return
    set busy [expr {$ScanActive || $SearchActive || $CostOutstanding > 0}]
    set shown [expr {[winfo manager $spin] ne ""}]
    # Act on transitions only: start/stop schedule recurring timers, so calling
    # start on an already-running bar (the cost flood does this) would stack them.
    if {$busy && !$shown} {
        pack $spin -side right -padx 4 -pady 1 -before .top.statusbar.status
        $spin start 12
    } elseif {!$busy && $shown} {
        $spin stop
        pack forget $spin
    }
}

# The bottom status bar's resting line: where questlog reads from and how many
# sessions sit on disk in scope, so a first-time reader never has to ask where
# the list comes from. A noun phrase, not a verb, so the resting bar does not
# read as work in progress (the spinner, not the wording, signals activity). The
# browse default behind refresh_status. (No "this Mac": the design's wording is
# from a macOS mock; questlog is the native Linux tool.)
proc ::questlog::ui::app::bounds_status {} {
    set pretty [::questlog::path::pretty_home [::questlog::path::projects_root]]
    return "$pretty · Claude Code CLI sessions · [corpus_count] total"
}

# Count the session files across every project folder, independent of the
# toolbar window: a directory walk over <projects_root>/*/*.jsonl with no file
# reads, cheap enough to recompute whenever the resting line is shown.
proc ::questlog::ui::app::corpus_count {} {
    set root [::questlog::path::projects_root]
    if {![file isdirectory $root]} { return 0 }
    set n 0
    foreach folder [glob -nocomplain -directory $root -type d -- *] {
        incr n [llength [glob -nocomplain -directory $folder -- *.jsonl]]
    }
    return $n
}

# The corpus scan runs even while a search is active (it builds Search's corpus),
# so its progress must not stamp "Scanning…" over the search text the user came
# for: under active criteria the search owns the bar and scan progress is silent.
proc ::questlog::ui::app::on_scan_progress {done total} {
    variable StatusMode
    variable ProgressLine
    variable CriteriaActive
    if {$CriteriaActive} return
    if {$done < $total} {
        set StatusMode scanning
        set ProgressLine "Scanning $done / $total…"
        refresh_status
    }
    # Paint what this chunk added before the next one runs. Scanned rows land
    # in the widget as they publish, but their repaint is idle-priority,
    # and the cost pass keeps the event queue fed (worker results and their
    # coalesce timers are events, which precede idle), so on a busy corpus the
    # first paint otherwise drifts past the 1s gate (measured 1.15-1.25s)
    # instead of landing near the chunk boundary.
    # scan_resume is a timer, so this drains pending redraws only, never the
    # scan itself.
    update idletasks
}

# Scan finished. While browsing, return to the resting scope line; under active
# criteria leave the mode (searching/search_done) untouched so a background-scan
# completion never wipes the search summary.
proc ::questlog::ui::app::on_scan_done {scanned} {
    variable StatusMode
    variable CriteriaActive
    variable ScanActive
    variable SessionList
    set ScanActive 0
    if {!$CriteriaActive} { set StatusMode browse }
    refresh_status
    update_spinner
    # The loaded set is final, so recount what the filter is missing from it now,
    # rather than leave a mid-scan count standing until the next poll tick.
    $SessionList refresh_filter_note
}

# ---- search callbacks --------------------------------------------------

# A found session's matches arrive together (one message per file). Under
# search_render=coalesced (the default) they are buffered and rendered in a
# folder-grouped pass when the event loop next goes idle, so typing always
# preempts and a broad term cannot freeze the list; immediate renders each
# session as it arrives (still one anchored pass per session, never per match).
proc ::questlog::ui::app::on_search_file {matches} {
    variable SessionList
    variable SearchPending
    variable SearchFlushTimer
    if {[::questlog::config::get search_render] eq "immediate"} {
        $SessionList add_session_matches $matches
        return
    }
    lappend SearchPending $matches
    if {$SearchFlushTimer eq ""} {
        set SearchFlushTimer [after idle [namespace code flush_search]]
    }
}

# Render the buffered sessions when idle, folder-grouped, bracketed by one
# anchor_save/restore for the whole slice. When search_render_slice_ms > 0 the
# slice stops at that wall-clock budget and re-arms at idle to finish, so even a
# match-every-file query never blocks input beyond one budget; 0 renders the
# whole buffer in one idle pass.
proc ::questlog::ui::app::flush_search {} {
    variable SessionList
    variable SearchPending
    variable SearchFlushTimer
    set SearchFlushTimer ""
    if {[llength $SearchPending] == 0} return
    set SearchPending [lsort -command ::questlog::ui::app::cmp_search_folder $SearchPending]
    set slice_ms [::questlog::config::get search_render_slice_ms]
    set deadline [expr {[clock milliseconds] + $slice_ms}]
    $SessionList begin_batch
    while {[llength $SearchPending] > 0} {
        $SessionList render_session_matches [lindex $SearchPending 0]
        set SearchPending [lrange $SearchPending 1 end]
        if {$slice_ms > 0 && [clock milliseconds] >= $deadline} break
    }
    $SessionList end_batch
    if {[llength $SearchPending] > 0} {
        set SearchFlushTimer [after idle [namespace code flush_search]]
    }
}

# Order two buffered per-file entries by their folder, so a flush updates a
# folder's sessions as one group.
proc ::questlog::ui::app::cmp_search_folder {a b} {
    return [string compare \
        [dict get [lindex $a 0] folder] [dict get [lindex $b 0] folder]]
}

# Drop buffered per-file results and cancel a pending flush, when the result set
# is invalidated (a new search, a filter change, a cancel, quit).
proc ::questlog::ui::app::discard_search_buffer {} {
    variable SearchPending
    variable SearchFlushTimer
    if {$SearchFlushTimer ne ""} { after cancel $SearchFlushTimer; set SearchFlushTimer "" }
    set SearchPending [list]
}

proc ::questlog::ui::app::on_search_progress {done total matches} {
    variable SessionList
    variable StatusMode
    variable ProgressLine
    $SessionList set_progress $done $total $matches
    set StatusMode searching
    set ProgressLine "Searching $done / $total · $matches matches"
    refresh_status
}

# Search finished: a persistent, past-tense summary on the bar the user watches,
# so a zero-match search reads as a finished answer rather than as ongoing work.
# It stays until the criteria change (which returns the bar to browse).
proc ::questlog::ui::app::on_search_done {total matches} {
    variable SessionList
    variable StatusMode
    variable SearchSummary
    variable SearchActive
    $SessionList set_done $total $matches
    set SearchActive 0
    set StatusMode search_done
    if {$matches == 0} {
        set SearchSummary "No matches · searched $total Claude Code CLI sessions"
    } else {
        set SearchSummary "Found $matches matches · searched $total Claude Code CLI sessions"
    }
    refresh_status
    update_spinner
}

proc ::questlog::ui::app::on_search_cancel {} {
    variable Search
    variable StatusMode
    variable SearchSummary
    variable SearchActive
    $Search cancel
    discard_search_buffer
    set SearchActive 0
    set StatusMode search_cancelled
    set SearchSummary "Search cancelled"
    refresh_status
    update_spinner
}

# ---- open in the docked viewer -----------------------------------------

# A click (or a snippet/menu open) in the list lands here: render the whole
# session in the viewer pane and anchor it to lineno (0 = top), replacing the
# empty state. The active search query rides along so the viewer can index the
# matches in-transcript.
proc ::questlog::ui::app::on_open {path lineno} {
    variable Viewer
    variable ViewerPath
    variable CurrentQuery
    $Viewer show $path $lineno $CurrentQuery
    if {$lineno > 0} {
        set ViewerPath "$path  (line $lineno)"
    } else {
        set ViewerPath $path
    }
    refresh_status
}

# ---- move callbacks ----------------------------------------------------

# paths is a list of session paths to move to a single destination. The
# dialog excludes the source's own folder only when exactly one session is
# moved; a group may span folders, so no folder is excluded then.
proc ::questlog::ui::app::on_move_request {paths} {
    variable SessionList
    set current_folder ""
    if {[llength $paths] == 1} {
        set p [lindex $paths 0]
        if {[$SessionList session_node $p] eq ""} return
        set current_folder [$SessionList sget $p folder]
    }
    ::questlog::ui::move_dialog::open . [llength $paths] $current_folder \
        [list [namespace current]::on_picker_done $paths] \
        [list [namespace current]::live_move_names $paths]
}

proc ::questlog::ui::app::on_picker_done {paths dst_cwd} {
    do_move_batch $paths $dst_cwd
}

# The display names of the would-be-moved sessions that are running right now,
# re-read from the live set each call so the move dialog re-enables when one
# quits. A live session cannot be moved; the move dialog blocks on this.
proc ::questlog::ui::app::live_move_names {paths} {
    variable Running
    variable SessionList
    set out [list]
    foreach p $paths {
        if {![dict exists $Running [file rootname [file tail $p]]]} continue
        set name ""
        if {[$SessionList session_node $p] ne ""} {
            set name [$SessionList sget $p slug]
            if {$name eq ""} { set name [$SessionList sget $p first_user] }
        }
        if {$name eq ""} { set name [file rootname [file tail $p]] }
        lappend out $name
    }
    return $out
}

# Drop-move resolves the dropped-on folder basename to its real cwd via the
# canonical resolver. A drop onto a folder that cannot be resolved (its
# underlying project directory is gone or ambiguous) is refused rather than
# silently moving into an orphan.
proc ::questlog::ui::app::on_drop_move {paths target_folder_basename} {
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
proc ::questlog::ui::app::do_move_batch {paths dst_cwd} {
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
proc ::questlog::ui::app::move_one {src_path dst_cwd} {
    variable SessionList
    variable Running
    # A live session must not be moved: renaming its jsonl out from under the
    # running process splits the transcript. The move dialog disables Move while
    # any are live; this guards the drag path too (and a race in either).
    if {[dict exists $Running [file rootname [file tail $src_path]]]} {
        error "session is live; close it before moving"
    }
    set src_basename [file tail [file dirname $src_path]]
    if {![catch {::questlog::path::encode_cwd $dst_cwd} dst_basename]
        && $dst_basename eq $src_basename} {
        return
    }
    set new_path [::questlog::path::move_session $src_path $dst_cwd]
    set new_folder [::questlog::path::encode_cwd $dst_cwd]
    $SessionList relocate_card $src_path $new_path $new_folder $dst_cwd
}

# ---- bookmark callbacks ------------------------------------------------

# Toggle the +x bookmark bit on the session file. Path comes fresh from the
# clicked session, so it is current; a moved/deleted file fails the sink
# guard and is reported rather than crashing. The bit is the truth: flip it,
# then reconcile_one re-derives the store's cached field and that one row's
# marker immediately so the user sees it without waiting for a tick.
proc ::questlog::ui::app::on_bookmark_toggle {path} {
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
    $SessionList reconcile_one $path
}

# Bookmark a whole selection. The bit is the truth: add it to every session
# unless they all already carry it, in which case remove it from all (the same
# tri-state the multi menu's label states). Failures are collected and reported
# once. Each successful flip refreshes its cached field and re-derives that
# row's marker, like the single toggle.
proc ::questlog::ui::app::on_bookmark_set {paths} {
    variable SessionList
    set add 0
    foreach p $paths { if {![file executable $p]} { set add 1; break } }
    set failures [list]
    foreach p $paths {
        set op [expr {$add ? "set_bookmark" : "clear_bookmark"}]
        if {[catch {::questlog::path::$op $p} err]} {
            lappend failures "[file tail $p]: $err"
            continue
        }
        $SessionList reconcile_one $p
    }
    if {[llength $failures] > 0} {
        tk_messageBox -icon error -title "Bookmark" \
            -message "Bookmark failed:\n[join $failures \n]"
    }
}

# Rename, GUI side. The rename itself is a path-only domain op in lib/rename.tcl,
# reachable from the CLI too; here is only the GUI - collect the new title in a
# modal dialog, apply it, then ask the list to refresh the row if it happens to
# be showing it. Both the list menu and the viewer ⋯ menu route here via OnRename.
proc ::questlog::ui::app::on_rename_request {path} {
    variable Scan
    variable SessionList
    # Current title and uuid come from the file (scan_one is a pure read), the
    # source of truth, so the dialog prefill never depends on the view's model.
    set row [$Scan scan_one $path]
    set current [dict getdef $row slug ""]
    set uuid    [dict getdef $row uuid [file rootname [file tail $path]]]
    set entered [prompt_rename $current $uuid]
    if {$entered eq "<cancelled>"} return
    set slug [::questlog::rename::apply $path $entered]
    # Re-scan into the model so the new title is fresh everywhere: the rename
    # appended records and moved the mtime, so the published row freshens the
    # store's copy, and a session that is renamed, quit, then run again
    # re-surfaces under its new title. refresh_row then redraws the row if it
    # is currently shown.
    on_scan_path $path
    $SessionList refresh_row $path $slug
}

# Modal one-field title dialog. Returns the entered text on OK, or "<cancelled>"
# on Cancel / Escape / close ("<cancelled>" is a sentinel rather than {} so an OK
# with an empty entry - which means "revert to auto" - stays distinguishable).
# While the session runs OK is disabled (the dialog still opens, current title
# visible); OK re-enables live the instant the session stops, so a dialog held
# open across a quit needs no reopening.
proc ::questlog::ui::app::prompt_rename {current uuid} {
    variable RenameEntry
    variable RenameOutcome
    variable RenamePoll
    set dlg .renameDialog
    if {[winfo exists $dlg]} { destroy $dlg }
    toplevel $dlg
    wm title $dlg "Set session title"
    wm transient $dlg .
    wm resizable $dlg 1 0
    set RenameEntry $current
    set RenameOutcome ""
    ttk::label $dlg.lbl \
        -text "Title (kebab-case; empty reverts to Claude's auto title):"
    ttk::entry $dlg.ent -textvariable [namespace which -variable RenameEntry]
    ttk::frame $dlg.bf
    ttk::button $dlg.bf.ok -text "OK" \
        -command [list set [namespace which -variable RenameOutcome] ok]
    ttk::button $dlg.bf.cancel -text "Cancel" \
        -command [list set [namespace which -variable RenameOutcome] cancel]
    pack $dlg.lbl -padx 12 -pady {12 4} -anchor w -fill x
    pack $dlg.ent -padx 12 -pady 4 -fill x
    pack $dlg.bf  -padx 12 -pady {4 12} -anchor e -fill x
    pack $dlg.bf.cancel -side right -padx 4
    pack $dlg.bf.ok     -side right -padx 4
    bind $dlg.ent <Escape> [list $dlg.bf.cancel invoke]
    wm protocol $dlg WM_DELETE_WINDOW \
        [list set [namespace which -variable RenameOutcome] cancel]
    # OK tracks the live running state, not a snapshot: while the session runs
    # the title write is held back (OK disabled, Return unbound) so it never
    # interleaves with claude's own appends, and OK re-enables the instant the
    # session stops, even with the dialog already open.
    set RenamePoll ""
    track_rename_ok $dlg $uuid
    focus $dlg.ent
    $dlg.ent selection range 0 end
    grab set $dlg
    vwait [namespace which -variable RenameOutcome]
    if {$RenamePoll ne ""} { after cancel $RenamePoll }
    set outcome $RenameOutcome
    set value   $RenameEntry
    catch {grab release $dlg}
    destroy $dlg
    if {$outcome ne "ok"} { return "<cancelled>" }
    return $value
}

# Keep the rename dialog's OK button in step with the live running state,
# rescheduling until the dialog is destroyed. Running is the app's running set,
# replaced wholesale each poll tick, so re-reading it here picks up a session
# that quits while the dialog is open and re-enables OK (and the Return
# accelerator) with no reopen.
proc ::questlog::ui::app::track_rename_ok {dlg uuid} {
    variable Running
    variable RenamePoll
    if {![winfo exists $dlg]} { set RenamePoll ""; return }
    if {[dict exists $Running $uuid]} {
        $dlg.bf.ok state disabled
        bind $dlg.ent <Return> {}
    } else {
        $dlg.bf.ok state !disabled
        bind $dlg.ent <Return> [list $dlg.bf.ok invoke]
    }
    set RenamePoll [after 300 [list [namespace current]::track_rename_ok $dlg $uuid]]
}

# Synchronously scan one file and publish it through the row stream, for the
# reconciler to surface a running session that the windowed scan has not
# reached.
proc ::questlog::ui::app::on_scan_path {path} {
    variable Scan
    return [$Scan scan_path $path]
}

# A session's subagents as child row dicts, for the list to render under it on
# expand (issue #13). A pure read; children live only in the list's model.
proc ::questlog::ui::app::on_subagents {path} {
    variable Scan
    return [$Scan subagents_for $path]
}

# Trigger the cost second pass for one subagent file. The result returns
# through on_cost_result, and the session list's refresh_cost routes it to
# the child row.
proc ::questlog::ui::app::on_subagent_cost {path} {
    start_cost_one $path
}

# ---- shared helpers exposed to UI components --------------------------

# The project directory behind a folder basename, for the widgets that display
# it: the folder headings, the context menu, the cut banner's names. The list
# redraws on paths that must not touch disk, so this is Scan's no-read resolver
# (the Folders cache and the filesystem walk) and not resolve_folder, which peeks
# inside a transcript. A folder it cannot resolve shows as its basename, which is
# all a transcript read would have yielded for it anyway.
proc ::questlog::ui::app::folder_cwd {folder} {
    variable Scan
    return [$Scan folder_cwd $folder]
}

# The scan's differential-skip memory: the mtime the session list's store
# holds for a path ("" when it holds none). Scan re-reads only paths whose
# live mtime differs, so an unchanged corpus re-extends without disk reads;
# the lib never references the ui directly, the prefix is injected at
# construction.
proc ::questlog::ui::app::known_mtime {path} {
    variable SessionList
    return [$SessionList stored_mtime $path]
}

# Typing predicate the browse Scan consults for its resume policy: true while
# the user is mid-keystroke in the search field. Delegates to the Toolbar, which
# records the keystroke deadline; the lib never references the ui directly, the
# prefix is injected at construction.
proc ::questlog::ui::app::scan_is_typing {} {
    variable Toolbar
    return [$Toolbar is_typing]
}

proc ::questlog::ui::app::quit {} {
    variable Search
    variable Scan
    # Teardown runs in dependency order, because exit is not instant: Tcl
    # finalization can service the event queue on the way out, so anything
    # still armed would fire into whatever is already gone.
    # 1. The window: whatever fires during widget teardown finds every
    #    object it names still alive.
    catch {destroy .}
    # 2. Every pending after, wholesale: the named timers (RunTimer, the
    #    flush timers), anything armed without a recorded id, and anything
    #    the widget teardown just armed.
    foreach id [after info] { after cancel $id }
    # 3. Stop the cost pass before the window's objects go: a worker result
    #    still in flight would otherwise reach on_cost_result after the
    #    session list is gone. The epoch bump makes on_worker_result drop
    #    those results.
    cancel_cost
    # 4. Objects last; their leash destructors cancel their own arms.
    if {[info exists Search] && $Search ne ""} { catch {$Search destroy} }
    if {[info exists Scan]   && $Scan ne ""}   { catch {$Scan destroy} }
    exit 0
}

# ---- background cost queue ---------------------------------------------

proc ::questlog::ui::app::init_cost_pool {} {
    variable CostPool
    variable CostWorkerScript
    variable Root
    set CostPool ""
    # Without Thread there is no pool; start_cost_one parses on the main
    # thread instead.
    if {![::questlog::search::thread_available]} return
    # The worker runs parse_file, which delegates token parsing to the tallyman
    # module; the module search path is registered so cost.tcl's
    # `package require tallyman` resolves in the fresh worker interp.
    set initcmd "::tcl::tm::path add [list [file join $Root modules]]
::tcl::tm::path add [list [file join $Root vendor]]
source [list [file join $Root lib cost.tcl]]\n$CostWorkerScript"
    set CostPool [tpool::create \
        -minworkers [::questlog::config::get cost_workers_min] \
        -maxworkers [::questlog::config::get cost_workers_max] \
        -initcmd $initcmd]
}

proc ::questlog::ui::app::start_cost_one {path} {
    variable CostPool
    variable CostEpoch
    variable CostOutstanding
    if {$CostPool eq ""} {
        # No worker pool (Thread package unavailable): parse on the main
        # thread, the same synchronous path the CLI uses (cli/cost.tcl), so
        # per-session cost still shows. The parse does not yield, so the UI
        # stalls for its duration; the stutter the banner warns about.
        on_cost_worker_result $path $CostEpoch [::questlog::cost::parse_file $path]
        return
    }
    incr CostOutstanding
    update_spinner
    tpool::post -nowait $CostPool [list dispatch_main $path [thread::id] $CostEpoch]
}

# An epoch bump abandons every still-queued job: their replies will arrive under
# the old epoch and be dropped without decrementing, so zero the counter here in
# lockstep. Only jobs posted under the new epoch count from now on.
proc ::questlog::ui::app::cancel_cost {} {
    variable CostEpoch
    variable CostOutstanding
    incr CostEpoch
    set CostOutstanding 0
    update_spinner
}

proc ::questlog::ui::app::on_cost_worker_result {path epoch result} {
    variable CostEpoch
    variable CostOutstanding
    if {$epoch != $CostEpoch} return
    # Decrement for every live-epoch reply, success or failure, before the ok
    # gate, so a failed cost parse still retires its job and the counter drains.
    if {$CostOutstanding > 0} { incr CostOutstanding -1 }
    update_spinner
    if {![dict get $result ok]} return

    set cost_dict [::questlog::cost::build_cost_dict $result]
    on_cost_result $path $cost_dict
}
