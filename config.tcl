package require Tcl 9

# ::questlog::config - the single home for every tunable value.
#
# The numbers that govern the trade-off between scan/search throughput and UI
# responsiveness used to sit as bare literals at the point of use: the yield
# cadence in scan.tcl, the debounce interval in toolbar.tcl, the worker counts
# in search.tcl and cost.tcl, the time-window hour map in three places. To find
# the best feel meant hunting each one. Here every knob is named once, with a
# line saying what it does and which way it leans, so the whole tuning surface
# is read and changed in one file.
#
# Same shape as ::questlog::theme: a single dict and a `get` accessor that
# errors loudly on an unknown key, so a typo surfaces at startup. No class -
# pure data with a reader, like theme.tcl and path.tcl.
#
# Each value is the authored home; consumers read it through `get`. The two
# isolated worker interpreters (search and cost) cannot reach this namespace,
# so the few caps they need are passed in to them as parameters rather than
# re-stated, keeping this the one source.

namespace eval ::questlog::config {
    variable Config [dict create]

    # ---- search trigger ----------------------------------------------------
    # live = the search runs when typing pauses (debounced); enter = the search
    # runs only on Return. live trades a little background work for not having
    # to press Enter; enter keeps pure typing free of any search work.
    dict set Config search_trigger     live
    # Idle after the last keystroke before a live search fires. Larger = fewer
    # searches while typing fast, at the cost of a longer wait to see results.
    dict set Config search_debounce_ms 200

    # ---- browse scan -------------------------------------------------------
    # Files scanned per chunk before the coroutine yields to the event loop.
    # Larger = faster scan, coarser yielding (longer the UI can stall per chunk).
    dict set Config scan_yield_files   200
    # Resume policy for the browse scan between chunks. timer = resume after
    # scan_resume_ms (steady progress); idle = resume only when the event loop
    # is otherwise idle (yields hard to input, may pause under continuous typing).
    dict set Config scan_resume        timer
    dict set Config scan_resume_ms     1
    # 0 = pause the browse scan while the user is actively typing in the search
    # field, so keystrokes own the main thread; 1 = let the scan run regardless.
    dict set Config scan_while_typing  0
    # While a resume is deferred for typing, how often to recheck whether typing
    # has stopped.
    dict set Config typing_poll_ms     60

    # ---- search coroutine / threads ----------------------------------------
    # Lines between wall-clock checks, and the main-thread budget per burst: the
    # search coroutine yields every search_yield_lines lines once it has held the
    # thread for more than search_yield_ms. search_yield_ms is the real cap on
    # how long a search burst can block input.
    dict set Config search_yield_lines    500
    dict set Config search_yield_ms       30
    # Files between progress-callback emissions.
    dict set Config search_progress_files 50
    # Inter-chunk resume delay for the search coroutine path.
    dict set Config search_resume_ms      1
    # Threaded fan-out worker count: cores - reserve, clamped to [min, max];
    # fallback when the core count cannot be detected. QUESTLOG_SEARCH_THREADS
    # overrides this at launch (0 forces the single-thread coroutine path).
    dict set Config search_threads_fallback 4
    dict set Config search_threads_reserve  2
    dict set Config search_threads_min      1
    dict set Config search_threads_max      8

    # ---- cost pass ---------------------------------------------------------
    # The tpool that computes per-session token cost off the main thread.
    dict set Config cost_workers_min 0
    dict set Config cost_workers_max 4
    # immediate = apply each cost result to the list as it arrives; coalesced =
    # batch arrivals and apply them in one pass every cost_coalesce_ms, so a
    # flood of results does not churn the list during interaction.
    dict set Config cost_render      coalesced
    dict set Config cost_coalesce_ms 80

    # ---- search render -----------------------------------------------------
    # How found sessions reach the list as a search runs. coalesced = buffer the
    # per-file results and render them folder-grouped when the event loop next
    # goes idle, so typing always preempts and a broad term cannot freeze the
    # list; immediate = render each session as it arrives (still one anchored
    # pass per session, never per match).
    dict set Config search_render coalesced
    # Caps each idle render slice to this many ms, yielding between slices, so a
    # query matching every file in the window cannot block input beyond this on
    # any machine. 0 renders the whole idle batch in one pass (faster overall,
    # but an ~800ms hitch on a very broad term).
    dict set Config search_render_slice_ms 50

    # ---- polling -----------------------------------------------------------
    # Re-poll interval for the live-session registry (running markers). The cost
    # is O(running sessions), independent of the on-disk corpus.
    dict set Config running_poll_ms 2000

    # ---- time windows ------------------------------------------------------
    # The recency filter. window_hours maps each option to its hour count;
    # window_options is the set the toolbar offers; window_default is the one a
    # fresh launch starts on. all means no time bound.
    dict set Config window_hours   {24h 24 7d 168 30d 720}
    dict set Config window_options {24h 7d 30d all}
    dict set Config window_default 7d

    # ---- display caps ------------------------------------------------------
    # Tail bytes read for the most-recent agentName/aiTitle rename records.
    dict set Config tail_window_bytes 65536
    # Characters of context shown either side of a search hit in a snippet.
    dict set Config snippet_radius 80
    # Length caps for displayed strings: a matched content block, a rendered
    # tool call, and one tool parameter value. The first-prompt preview is left
    # uncapped; the session list clips it to the subject column at render.
    dict set Config content_cap     300
    dict set Config tool_render_cap 250
    dict set Config tool_param_cap  60
    # Snippets shown per matching session card.
    dict set Config snippets_per_session 3
    # Snippets shown per matching subagent (a session's child rows). Lower than
    # snippets_per_session so a parent with several matching subagents is not
    # buried under their evidence: one representative line per subagent, with the
    # subagent's own label carrying the rest of the identification.
    dict set Config snippets_per_subagent 1
    # A viewer blockquote longer than this gets a Collapse toggle.
    dict set Config blockquote_preview_lines 6
    # Minutes of silence that mark a secondary idle-gap divider in the viewer.
    dict set Config viewer_idle_gap_min 10
    # Viewer copy-box width fit: default columns when the pixel width is unknown,
    # the pixel margin subtracted before dividing by the font width, and the
    # column floor.
    dict set Config textbox_default_cols 80
    dict set Config textbox_margin_px    60
    dict set Config textbox_min_cols     10

    # ---- drag-to-move ------------------------------------------------------
    # Pointer travel before a press becomes a drag; autoscroll tick interval
    # while dragging in an edge band; the edge band depth top and bottom.
    dict set Config drag_threshold_px  6
    dict set Config drag_autoscroll_ms 60
    dict set Config drag_edge_band_px  16
}

# Value for a key. Errors loudly on an unknown key rather than returning a
# default, so a typo surfaces at startup, not as a silent wrong setting.
proc ::questlog::config::get {key} {
    variable Config
    return [dict get $Config $key]
}
