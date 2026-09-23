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
    variable ScanPending      ;# browse rows buffered for an idle sliced flush
    variable ScanFlushTimer   ;# after-id of the pending scan-render flush, or ""
    variable VisibleCost      ;# shown rows' cost jobs awaiting a pool slot
    variable DeferredCost     ;# hidden rows', fed only once VisibleCost is
                              ;# empty. Both reservoirs feed through feed_cost,
                              ;# which keeps the pool queue shallow: the pool
                              ;# is FIFO and the arrival poll's scan jobs share
                              ;# it, so a scan job posted mid-pass waits behind
                              ;# at most one batch of transcript parses
    variable CostEpoch        ;# Epoch to drop stale results after a filter change
    variable StatusMode       ;# browse|scanning|searching|search_done|search_cancelled
    variable SearchSummary    ;# persistent terminal search line, "" when no criteria active
    variable ViewerPath       ;# opened-session path line; overrides every mode, "" when none
    variable ProgressLine     ;# in-flight "Scanning…" / "Searching…" text, owned by the mode
    variable ScanActive       ;# 1 while the corpus scan coroutine is in flight
    variable SearchActive     ;# 1 while a search is in flight
    variable CostOutstanding  ;# cost jobs posted but not yet returned (the cost pass is live when > 0)
    variable PrevSnapshot     ;# the last published snapshot: skips a no-op rebuild, and is what the scan callbacks read any_criteria against
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
    variable RunTimer
    variable CurrentQuery
    variable SidebarCollapsed
    variable SidebarSash
    variable CostPending
    variable CostFlushTimer
    variable SearchPending
    variable SearchFlushTimer
    variable ScanPending
    variable ScanFlushTimer
    variable CostEpoch
    variable StatusMode
    variable SearchSummary
    variable ViewerPath
    variable ProgressLine
    variable ScanActive
    variable SearchActive
    variable CostOutstanding
    variable PrevSnapshot

    set Root $root
    set StatusMode browse
    set SearchSummary ""
    set ViewerPath ""
    set ProgressLine ""
    set ScanActive 0
    set SearchActive 0
    set CostOutstanding 0
    # The first publish has nothing to diff against, so it always takes the heavy path.
    set PrevSnapshot {}
    set StatusVar [bounds_status]
    set CurrentQuery {}
    set SidebarCollapsed 0
    set SidebarSash 0.58
    set CostPending [dict create]
    set CostFlushTimer ""
    set SearchPending [list]
    set SearchFlushTimer ""
    set ScanPending [list]
    set ScanFlushTimer ""
    set VisibleCost [list]
    set DeferredCost [list]
    set CostEpoch 0

    # Tk defines <<ContextMenu>> as the right button, Button-3 on every
    # windowing system, and stops there. macOS has a second secondary click,
    # Control+click, which Finder honours and a Mac reader expects here; opt
    # that sequence in so it reaches the same menu.
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
    # toolbar bounds the list (master), not the viewer (detail), so it lives
    # inside this column rather than spanning the window.
    set list_frame $PW.list
    set ListFrame $list_frame
    ttk::frame $list_frame
    set Toolbar [::questlog::ui::Toolbar new $list_frame.tb [::questlog::path::launch_cwd]]
    pack $list_frame.tb -side top -fill x
    human_gap_menu [$Toolbar more_menu]
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

    # peek 0: the GUI's scanner never reads a transcript to name a folder; the
    # pool pass warms the resolver cache from every row's cwd_hint, and
    # restamp_subtree settles the stragglers when a subtree bound is active.
    set Scan [::questlog::Scan new \
        [namespace code on_scan_row] \
        [namespace code on_scan_done] \
        [namespace code on_scan_progress] \
        [namespace code scan_is_typing] \
        [namespace code known_mtime] 0]

    set Search [::questlog::Search new $Scan \
        [namespace code on_search_file] \
        [namespace code on_search_progress] \
        [namespace code on_search_done]]

    # Rate table for the main-thread pricing of worker cost results. The worker
    # pool itself is built after the first paint, below.
    ::questlog::cost::load_rates $Root

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
    # The menu's advertised keys (issue #53): Return opens the selected session,
    # Ctrl+R copies its resume command. Ctrl+R is the chosen copy-resume key -
    # the app's keys are all Control-based, and R reads as "resume". Both honour
    # the sole selection and no-op otherwise, so the accelerator hints stay true.
    bind . <Return> [list $SessionList open_selected]
    bind . <Control-r> [list $SessionList copy_selected_resume]

    maybe_show_onboarding

    # Paint the assembled skeleton before any corpus work begins, so the window
    # is on screen in a fraction of a second and the session rows stream into it.
    # The first map is idle-priority work; left to compete with the scan's
    # millisecond resume timer (and, on a host without the Thread package, the
    # main-thread cost parse) it is starved until the whole pass drains, and the
    # window then appears all at once, finished. This one pump maps it first.
    update idletasks

    # The worker pool, built between the paint above and the scan the publish
    # below starts: its workers' initcmd blocks the main thread (~100-150ms),
    # which after the pump is invisible, and the scan needs the pool live.
    ::questlog::jobpool::init $Root

    # No default `subtree`: the list opens across every project, and a bound is
    # added only when the user asks for one. A launch-cwd default bounded the list
    # to wherever questlog happened to be started - often the home directory, a
    # parent of everything - which both assumed the user keeps code under home and
    # silenced any bound they then added (subtree entries are OR'd, so a home
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
    variable RunTimer
    variable Scan
    variable PrevSnapshot
    set running [::questlog::ui::live::running_uuids]
    # Poll the projects tree for arrivals the live registry never reports,
    # BEFORE reconcile. The poll publishes through on_scan_row, whose tail
    # leaves the list widget -state disabled (the widget-state trap at
    # sessions.tcl:2882), so it must not run nested inside reconcile; and
    # running it first lets an imported row settle its running glyph and
    # phantom drop in the same tick.
    $Scan poll_arrivals
    $SessionList reconcile_running $running
    # A live session appends in place, moving its file mtime but not its
    # folder's, so poll_arrivals's directory gate never re-reads it: force the
    # bounded-tail re-scan of each modelled running path whose file moved.
    # After reconcile, so freshen_attached reads the fresh running set.
    # Browse-only like reconcile's import (on_scan_row bails under criteria).
    if {![::questlog::ui::any_criteria $PrevSnapshot]} {
        dict for {uuid path} $running {
            if {![$SessionList has_session $path]} continue
            if {[catch {file mtime $path} m]} continue
            if {$m eq [$SessionList stored_mtime $path]} continue
            $Scan scan_path $path
        }
    }
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

# The membership the active filters claim, gathered outside the search and
# handed to the list, which counts it against the rows it did load and says
# the cut (the filter-cut section of ui/sessions.tcl). Running comes free from
# the live registry; Bookmarked is a stat sweep of the corpus - cheap, but
# never on the filter's own path, so toggling stays an instant in-place
# re-filter and the count lands a moment behind it. The model filter has no
# membership outside the loaded rows, so member_filters leaves it out.
# filter_members reduces the sets to what the filters jointly claim (the
# intersection when both are on). Which filters are on comes from the list's own
# filter state (attr_filter_all), not the toolbar's published snapshot.
proc ::questlog::ui::app::refresh_filter_members {} {
    variable SessionList
    set sets [list]
    foreach f [::questlog::listfilter::member_filters [$SessionList attr_filter_all]] {
        switch -- $f {
            running    { lappend sets [::questlog::ui::live::running_sessions] }
            bookmarked { lappend sets [bookmarked_members] }
        }
    }
    $SessionList set_filter_members [::questlog::listfilter::filter_members $sets]
}

# A strip filter moved. The list has already re-derived the view in place and
# holds the new filter state; gather membership now so the count lands with the
# toggle. No bounds or search changed, so nothing re-scans. The handback carries
# the state, but refresh_filter_members reads it from the list (the poll and the
# scan-done recount call it with no state in hand), so the arg is unused here.
proc ::questlog::ui::app::on_filter_change {state} {
    refresh_filter_members
}

# Every bookmarked session on disk, uuid -> {path}: one glob per project
# folder and one stat per file, window or no window. It opens nothing and
# resolves no folder - this runs on the filter fast path and every poll tick,
# and a filter may not read a transcript; the one or two members the banner
# NAMES resolve later through the no-read resolver (member_name).
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

# Bound the search to one folder (the list's folder right-click): push the
# folder's project cwd into the toolbar's subtree facet and publish. subtree is
# one of the keys bounds_equal reads, so the new snapshot forces the full rebuild
# in on_filter rather than the view-only fast path. A folder whose directory is
# gone bounds by the path it had (its sessions are stamped with it); one the
# resolver cannot place resolves to "" and bounds nothing.
proc ::questlog::ui::app::on_folder_bound {folder} {
    variable Toolbar
    set cwd [folder_cwd $folder]
    if {$cwd eq ""} return
    $Toolbar add_value subtree [::questlog::path::canon_dir $cwd]
}

# ---- toolbar callback --------------------------------------------------

# The snapshot keys that define the search and bounds - every key the toolbar now
# publishes. Two publishes equal across all of them changed nothing that decides
# which sessions load, so on_filter can skip the rebuild.
proc ::questlog::ui::app::bounds_equal {a b} {
    foreach k {search search_case search_regions file tool pattern subtree since until} {
        if {[dict getdef $a $k {}] ne [dict getdef $b $k {}]} { return 0 }
    }
    return 1
}

proc ::questlog::ui::app::on_filter {snapshot} {
    variable Scan
    variable Search
    variable SessionList
    variable CurrentQuery
    variable StatusMode
    variable SearchSummary
    variable ViewerPath
    variable ProgressLine
    variable ScanActive
    variable SearchActive
    variable PrevSnapshot

    # A republish whose bounds and search keys all match the last one changed
    # nothing that decides which sessions load, so the rebuild below would only
    # reproduce what is already shown. Skip it, keeping the list and its
    # selection; the turns floor is a view key, so its move re-derives the
    # view over the loaded rows in place, no rescan. The list-strip filters
    # do not ride the snapshot at all: they re-filter in place through
    # on_filter_change.
    if {$PrevSnapshot ne {} && [bounds_equal $PrevSnapshot $snapshot]} {
        if {[dict getdef $snapshot turns_view 1] != [dict getdef $PrevSnapshot turns_view 1]} {
            $SessionList set_turns_view [dict getdef $snapshot turns_view 1]
        }
        set PrevSnapshot $snapshot
        return
    }

    set has_criteria [::questlog::ui::any_criteria $snapshot]
    ::questlog::debug::log search "on_filter begin: search='[dict get $snapshot search]' has_criteria=$has_criteria"
    # A new filter or search supersedes the opened-session path on the bar.
    set ViewerPath ""
    # Record the snapshot this load is based on before the scan starts, so the
    # scan callbacks that ask whether criteria are active (any_criteria on
    # PrevSnapshot, the scan-progress clobber guard) read this snapshot, not the
    # one it replaced.
    set PrevSnapshot $snapshot

    # A new filter/search invalidates the previous result set; drop any buffered
    # per-file results and cancel a pending flush before the list is cleared, so
    # a stale session never renders into the fresh list. The cost pass is
    # cancelled too, for another reason: its queued jobs are full-transcript
    # parses that share the FIFO pool with the coming re-scan's chunks. Left
    # alive, they starve the fresh rows for minutes (the list sat blank after
    # a search was typed and deleted). The epoch bump turns the backlog into
    # no-ops; re-arriving rows re-queue their own pricing.
    cancel_cost
    discard_search_buffer
    discard_scan_buffer
    $SessionList apply_filter $snapshot

    # apply_filter wiped the store, so the scan re-streams the new bounds from
    # disk (a population change pays population's price through the stream).
    set ScanActive 1
    $SessionList scan_begin
    $Scan extend $snapshot

    # Seed running markers now, in the same event-loop turn, so there is no
    # flash of the pre-reconcile state.
    $SessionList reconcile_running [::questlog::ui::live::running_uuids]

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
    # A new bounds or search loads a different set of rows, so what the filter is
    # missing has changed even though the filter has not.
    refresh_filter_members
}

# ---- scan callbacks ----------------------------------------------------

# Browse rows buffer here and render in timer-scheduled slices (the browse
# twin of on_search_file/flush_search): a worker flood can outpace the widget,
# and per-arrival rendering would hold the event loop for the flood's
# duration. The arm is a 0ms timer, not idle: worker arrivals are events,
# which precede idle, so an idle-armed first paint starves behind the
# arrival stream and drifts past the 1s gate.
proc ::questlog::ui::app::on_scan_row {row} {
    variable ScanPending
    variable ScanFlushTimer
    lappend ScanPending $row
    if {$ScanFlushTimer eq ""} {
        set ScanFlushTimer [after 0 [namespace code flush_scan]]
    }
}

# Render the buffered browse rows in one batch bracket, stopping at the
# scan_render_slice_ms wall-clock budget and re-arming to finish, so typing
# always preempts between slices. slice 0 drains everything in one pass - the
# synchronous callers (on_scan_path, on_scan_done) use it because their
# contract is a store that is current when they return.
proc ::questlog::ui::app::flush_scan {{slice 1}} {
    variable SessionList
    variable PrevSnapshot
    variable ScanPending
    variable ScanFlushTimer
    variable VisibleCost
    variable DeferredCost
    if {$ScanFlushTimer ne ""} { after cancel $ScanFlushTimer; set ScanFlushTimer "" }
    if {[llength $ScanPending] == 0} return
    set slice_ms [expr {$slice ? [::questlog::config::get scan_render_slice_ms] : 0}]
    set deadline [expr {[clock milliseconds] + $slice_ms}]
    set costing [expr {![::questlog::ui::any_criteria $PrevSnapshot]}]
    set i 0
    $SessionList begin_batch
    foreach row $ScanPending {
        $SessionList add_scan_row $row
        incr i
        # Under criteria the stream attaches nothing (hydration prices what
        # it models); otherwise queue a cost task only when the store does
        # not already price this row - a changed file re-enters costless and
        # is re-priced.
        if {$costing} {
            set path [dict get $row path]
            if {![dict exists $row cost_usd] && [$SessionList has_session $path] \
                && [$SessionList sget $path cost] eq ""} {
                if {[$SessionList sflag $path hidden]} {
                    # A hidden row's cost feeds only the aggregates, so it
                    # waits for the visible reservoir to empty.
                    lappend DeferredCost $path
                } else {
                    lappend VisibleCost $path
                }
            }
        }
        if {$slice_ms > 0 && [clock milliseconds] >= $deadline} break
    }
    $SessionList end_batch
    feed_cost
    set ScanPending [lrange $ScanPending $i end]
    if {[llength $ScanPending] > 0} {
        set ScanFlushTimer [after 0 [namespace code flush_scan]]
    }
}

# Drop buffered browse rows and cancel a pending flush, when the load they
# belong to is invalidated (a bounds change wipes the store before rescanning).
proc ::questlog::ui::app::discard_scan_buffer {} {
    variable ScanPending
    variable ScanFlushTimer
    if {$ScanFlushTimer ne ""} { after cancel $ScanFlushTimer; set ScanFlushTimer "" }
    set ScanPending [list]
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

# The single writer of the bottom bar's text. An opened session's path comes
# first; otherwise the text follows StatusMode: the in-flight ProgressLine
# while scanning or searching, the persistent SearchSummary once a search has
# finished or been cancelled, and the resting bounds line while browsing. Every
# callback that changes a mode or a stored line ends by calling this, so the bar
# is always whatever the current state says it is and nothing leaks across.
proc ::questlog::ui::app::refresh_status {} {
    variable StatusVar
    variable StatusMode
    variable SearchSummary
    variable ViewerPath
    variable ProgressLine
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
# sessions sit on disk in bounds, so a first-time reader never has to ask where
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
    variable PrevSnapshot
    if {[::questlog::ui::any_criteria $PrevSnapshot]} return
    if {$done < $total} {
        set StatusMode scanning
        set ProgressLine "Scanning $done / $total…"
        refresh_status
    }
}

# Scan finished. While browsing, return to the resting bounds line; under active
# criteria leave the mode (searching/search_done) untouched so a background-scan
# completion never wipes the search summary.
proc ::questlog::ui::app::on_scan_done {scanned} {
    variable StatusMode
    variable PrevSnapshot
    variable ScanActive
    variable SessionList
    # The pass is over, so the store must be whole before the wrap-up below
    # reads it (the filter recount, and any caller awaiting done).
    flush_scan 0
    # Under a subtree bound, settle the rows the read-free resolver could not
    # place when they streamed: the pass has warmed the resolver cache from
    # every row's cwd_hint, so residence is answerable now, and a row admitted
    # on its own cwd_hint that residence contradicts is dropped.
    if {[llength [dict getdef $PrevSnapshot subtree {}]] > 0} { restamp_subtree }
    feed_cost
    set ScanActive 0
    $SessionList scan_end
    if {![::questlog::ui::any_criteria $PrevSnapshot]} { set StatusMode browse }
    refresh_status
    update_spinner
    # The loaded set is final, so recount what the filter is missing from it now,
    # rather than leave a mid-scan count standing until the next poll tick.
    $SessionList refresh_filter_note
}

# Re-stamp residence on every stored row the streaming pass left unplaced
# (folder_cwd ""), against the resolver cache the pass has since warmed, and
# forget the rows the subtree bound no longer admits. Only the subtree bound
# reads folder_cwd, so this runs only when one is active.
proc ::questlog::ui::app::restamp_subtree {} {
    variable SessionList
    variable Scan
    variable PrevSnapshot
    $SessionList begin_batch
    foreach path [$SessionList all_session_paths] {
        if {[$SessionList sget $path folder_cwd] ne ""} continue
        set cwd [$Scan folder_cwd [$SessionList sget $path folder]]
        if {$cwd eq ""} continue
        $SessionList sset $path folder_cwd [file normalize $cwd]
        if {![::questlog::scan::row_in_bounds $PrevSnapshot \
                [$SessionList payload_bounds_row $path]]} {
            $SessionList forget_session $path
        }
    }
    $SessionList end_batch
}

# ---- search callbacks --------------------------------------------------

# A found session's matches arrive together (one message per file). Under
# search_render=coalesced (the default) they are buffered and rendered in a
# folder-grouped pass when the event loop next goes idle, so typing always
# preempts and a broad term cannot freeze the list; immediate renders each
# session as it arrives (still one anchored pass per session, never per match).
proc ::questlog::ui::app::on_search_file {row matches} {
    variable SessionList
    variable SearchPending
    variable SearchFlushTimer
    if {[::questlog::config::get search_render] eq "immediate"} {
        $SessionList add_session_matches $matches $row
        return
    }
    lappend SearchPending [list $row $matches]
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
        lassign [lindex $SearchPending 0] row matches
        $SessionList render_session_matches $matches $row
        set SearchPending [lrange $SearchPending 1 end]
        if {$slice_ms > 0 && [clock milliseconds] >= $deadline} break
    }
    $SessionList end_batch
    if {[llength $SearchPending] > 0} {
        set SearchFlushTimer [after idle [namespace code flush_search]]
    }
}

# Order two buffered per-file entries by their folder, so a flush updates a
# folder's sessions as one group. An encoded name sorts before the names it
# prefixes, so a parent's group lands before its children's when both are in
# the buffer; the list needs no such order (ensure_folder hangs a late parent
# over the children already there), it only saves it the re-hang.
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
    variable SessionList
    # The name comes from the list's store, which holds it for every scanned
    # row. A subagent transcript is opened by its own path and has no row there,
    # so the strip reads it off the file instead.
    if {[$SessionList session_node $path] ne ""} {
        set name [$SessionList sget $path slug]
    } else {
        set name [::questlog::rename::current_ai_title $path]
    }
    $Viewer show $path $lineno $CurrentQuery $name
    if {$lineno > 0} {
        set ViewerPath "$path  (line $lineno)"
    } else {
        set ViewerPath $path
    }
    refresh_status
}

# ---- move callbacks ----------------------------------------------------

# paths is a list of session paths to move to a single destination. The
# dialog offers the list's folders and excludes the source's own only when
# exactly one session is moved; a group may span folders, so no folder is
# excluded then.
proc ::questlog::ui::app::on_move_request {paths} {
    variable SessionList
    set current_folder ""
    if {[llength $paths] == 1} {
        set p [lindex $paths 0]
        if {[$SessionList session_node $p] eq ""} return
        set current_folder [$SessionList sget $p folder]
    }
    ::questlog::ui::move_dialog::open . [llength $paths] $current_folder \
        [$SessionList folder_roster] \
        [list [namespace current]::on_picker_done $paths] \
        [list [namespace current]::live_move_names $paths]
}

proc ::questlog::ui::app::on_picker_done {paths dst_cwd} {
    do_move_batch $paths $dst_cwd
}

# The display names of the would-be-moved sessions that are running right now,
# re-read from the list's running set each call so the move dialog re-enables
# when one quits. A live session cannot be moved; the move dialog blocks on this.
proc ::questlog::ui::app::live_move_names {paths} {
    variable SessionList
    set out [list]
    foreach p $paths {
        if {![$SessionList is_running [file rootname [file tail $p]]]} continue
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
# canonical resolver. A drop onto a folder without a directory to move into
# (its basename ambiguous, or its project directory gone: the resolver then
# answers the path the folder had, which is no directory) is refused rather
# than silently moving into an orphan, each with its own reason.
proc ::questlog::ui::app::on_drop_move {paths target_folder_basename} {
    variable Scan
    set dst_cwd [$Scan resolve_folder $target_folder_basename]
    if {![file isdirectory $dst_cwd]} {
        ::questlog::ui::error_box -title "Move session" -message [expr {$dst_cwd eq "" \
            ? "Cannot resolve destination folder: $target_folder_basename" \
            : "The destination's directory no longer exists: $dst_cwd"}]
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
        ::questlog::ui::error_box -title "Move session" \
            -message "Move failed:\n[join $failures \n]"
    }
}

# Move one session into dst_cwd and relocate it in the list. A session whose
# folder cwd is already dst_cwd is a silent no-op - the only
# "succeed without effect" path. A filesystem failure throws (the error
# reaches do_move_batch).
proc ::questlog::ui::app::move_one {src_path dst_cwd} {
    variable SessionList
    variable Viewer
    variable ViewerPath
    # A live session must not be moved: renaming its jsonl out from under the
    # running process splits the transcript. The move dialog disables Move while
    # any are live; this guards the drag path too (and a race in either).
    if {[$SessionList is_running [file rootname [file tail $src_path]]]} {
        error "session is live; close it before moving"
    }
    set src_cwd [::questlog::path::canon_dir [$SessionList sget $src_path folder_cwd]]
    if {$src_cwd ne "" && $src_cwd eq [::questlog::path::canon_dir $dst_cwd]} {
        return
    }
    set new_folder [::questlog::path::encode_cwd $dst_cwd]
    if {$new_folder eq [file tail [file dirname $src_path]]} {
        # encode_cwd is lossy, so a different dst_cwd can share the session's
        # on-disk dir: nothing to rename, relocate_card's re-stamp is the move.
        set new_path $src_path
    } else {
        set new_path [::questlog::path::move_session $src_path $dst_cwd]
    }
    $SessionList relocate_card $src_path $new_path $new_folder $dst_cwd
    # When the open session is the one moved, follow it in the viewer too, so its
    # ⋯ verbs act on the new location instead of the vanished old path (Move would
    # no-op, Bookmark/Rename would throw). A subagent transcript of the moved
    # parent counts: its sidecar dir relocated with the parent, so a child open in
    # the viewer must repoint to its new path under the parent's new residence.
    # The bottom bar's path line tracks the same move.
    if {[info exists Viewer] && $Viewer ne ""} {
        set vp [$Viewer current_path]
        set base_old [file rootname $src_path]
        set new_vp ""
        if {$vp eq $src_path} {
            set new_vp $new_path
        } elseif {[string match "$base_old/*" $vp]} {
            set new_vp "[file rootname $new_path][string range $vp [string length $base_old] end]"
        }
        if {$new_vp ne ""} {
            $Viewer relocate $new_vp
            set ViewerPath $new_vp
            refresh_status
        }
    }
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
        ::questlog::ui::error_box -title "Bookmark" \
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
        ::questlog::ui::error_box -title "Bookmark" \
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
    # The viewer's strip states the name too; a rename of the session on screen
    # is news for both places, not just the row.
    variable Viewer
    if {[$Viewer current_path] eq $path} { $Viewer set_name $slug }
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
# rescheduling until the dialog is destroyed. The list's running set is replaced
# wholesale each poll tick, so re-reading it here picks up a session that quits
# while the dialog is open and re-enables OK (and the Return accelerator) with
# no reopen.
proc ::questlog::ui::app::track_rename_ok {dlg uuid} {
    variable SessionList
    variable RenamePoll
    if {![winfo exists $dlg]} { set RenamePoll ""; return }
    if {[$SessionList is_running $uuid]} {
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
    # scan_path publishes through the buffered stream, but this seam's callers
    # (the running reconciler, show_excluded) read the store synchronously
    # after it returns, so drain the buffer before handing the row back.
    set row [$Scan scan_path $path]
    flush_scan 0
    return $row
}

# A session's subagents as child row dicts, for the list to render under it on
# expand (issue #13). A pure read; children live only in the list's model.
proc ::questlog::ui::app::on_subagents {path} {
    variable Scan
    return [$Scan subagents_for $path]
}

# Queue the cost second pass for one subagent file, at the head of the
# visible reservoir: the next free pool slot takes it, and it rides the
# feeder's cap like every other cost job (the list fires this for each
# modelled child row, so a corpus-wide render is another flood). The result
# returns through on_cost_result, and the session list's refresh_cost routes
# it to the child row.
proc ::questlog::ui::app::on_subagent_cost {path} {
    variable VisibleCost
    set VisibleCost [linsert $VisibleCost 0 $path]
    feed_cost
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
    #    those results. The pool goes with it.
    cancel_cost
    ::questlog::jobpool::release
    # 4. Objects last; their leash destructors cancel their own arms.
    if {[info exists Search] && $Search ne ""} { catch {$Search destroy} }
    if {[info exists Scan]   && $Scan ne ""}   { catch {$Scan destroy} }
    exit 0
}

# ---- the human-gap rule ------------------------------------------------

# The toolbar's ⋯ menu carries the human-gap rule (lib/cost.tcl human_gap) as
# two cascades of presets: how long a pause before a prompt still counts in
# full, and what a longer one is worth. The menu offers presets only, as the
# time row does although --since takes any duration; a --human-gap value set
# outside them shows as no entry ticked. The rule lives in config, where the
# cost pass reads it.
proc ::questlog::ui::app::human_gap_menu {m} {
    variable GapThreshold [::questlog::config::get cost_human_gap_threshold_min]
    variable GapCredit    [::questlog::config::get cost_human_gap_credit_min]
    foreach {key label var presets} [list \
            threshold "A pause counts in full up to" GapThreshold {5 10 15 20 30 45 60 90 120} \
            credit    "A longer pause counts as"     GapCredit    {0 1 2 5}] {
        menu $m.$key -tearoff 0
        $m add cascade -label $label -menu $m.$key
        foreach n $presets {
            $m.$key add radiobutton -label "$n min" -value $n \
                -variable [namespace which -variable $var] \
                -command [namespace code set_human_gap]
        }
    }
}

# A moved rule re-prices every row: human time is derived from the transcript's
# stamps at pricing and the store holds only the result. The in-flight pass is
# abandoned first, so a reply priced under the old rule cannot land after one
# priced under the new.
proc ::questlog::ui::app::set_human_gap {} {
    variable GapThreshold
    variable GapCredit
    variable SessionList
    variable VisibleCost
    variable DeferredCost
    dict set ::questlog::config::Config cost_human_gap_threshold_min $GapThreshold
    dict set ::questlog::config::Config cost_human_gap_credit_min $GapCredit
    cancel_cost
    foreach path [$SessionList all_session_paths] {
        if {[$SessionList sflag $path hidden]} {
            lappend DeferredCost $path
        } else {
            lappend VisibleCost $path
        }
    }
    feed_cost
}

# ---- background cost queue ---------------------------------------------

proc ::questlog::ui::app::start_cost_one {path} {
    variable CostEpoch
    variable CostOutstanding
    if {![::questlog::jobpool::available]} {
        # No worker pool (Thread package unavailable): parse on the main
        # thread, the same synchronous path the CLI uses (cli/cost.tcl), so
        # per-session cost still shows. The parse does not yield, so the UI
        # stalls for its duration; the stutter the banner warns about.
        on_cost_worker_result $path $CostEpoch [::questlog::cost::parse_file $path]
        return
    }
    incr CostOutstanding
    update_spinner
    ::questlog::jobpool::post [list job_cost $path [thread::id] $CostEpoch \
        [list ::questlog::ui::app::on_cost_worker_result]]
}

# An epoch bump abandons every still-queued job. The local epoch makes arrived
# replies drop without decrementing, so the counter zeroes here in lockstep;
# the pool's shared epoch makes still-queued jobs no-op before reading a file.
proc ::questlog::ui::app::cancel_cost {} {
    variable CostEpoch
    variable CostOutstanding
    variable VisibleCost
    variable DeferredCost
    incr CostEpoch
    set CostOutstanding 0
    set VisibleCost [list]
    set DeferredCost [list]
    if {[::questlog::jobpool::available]} { ::questlog::jobpool::bump cost }
    update_spinner
}

# Feed queued cost jobs to the pool, visible reservoir first, keeping at most
# a pool-width batch outstanding. The pool queue is FIFO and the arrival
# poll's scan jobs share it, so a deep queued cost backlog would hold a live
# session's row update behind whole-transcript parses; a shallow queue caps
# that wait at one batch. The +2 margin keeps workers from idling between a
# reply and its top-up. Fired from every scan flush, at scan end and (with
# the pool live) on every cost reply; without the pool each posted job
# completes synchronously, so one call drains both reservoirs.
proc ::questlog::ui::app::feed_cost {} {
    variable CostOutstanding
    variable VisibleCost
    variable DeferredCost
    set cap [expr {[::questlog::config::get pool_workers] + 2}]
    while {$CostOutstanding < $cap} {
        if {[llength $VisibleCost] > 0} {
            set VisibleCost [lassign $VisibleCost path]
        } elseif {[llength $DeferredCost] > 0} {
            set DeferredCost [lassign $DeferredCost path]
        } else break
        start_cost_one $path
    }
}

proc ::questlog::ui::app::on_cost_worker_result {path epoch result} {
    variable CostEpoch
    variable CostOutstanding
    if {$epoch != $CostEpoch} return
    # Decrement for every live-epoch reply, success or failure, before the ok
    # gate, so a failed cost parse still retires its job and the counter drains.
    if {$CostOutstanding > 0} { incr CostOutstanding -1 }
    if {[::questlog::jobpool::available]} { feed_cost }
    update_spinner
    if {![dict get $result ok]} return

    set cost_dict [::questlog::cost::build_cost_dict $result]
    on_cost_result $path $cost_dict
}
