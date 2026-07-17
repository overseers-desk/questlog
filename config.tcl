package require Tcl 9

# ::questlog::config - the single home for every tunable value.
#
# The numbers that govern the trade-off between scan/search throughput and UI
# responsiveness used to sit as bare literals at the point of use: the yield
# cadence in scan.tcl, the debounce interval in toolbar.tcl, the worker counts
# in search.tcl and cost.tcl. To find the best feel meant hunting each one.
# Here every knob is named once, with a
# line saying what it does and which way it leans, so the whole tuning surface
# is read and changed in one file.
#
# Same shape as ::questlog::ui::theme: a single dict and a `get` accessor that
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
    # Chunk size sets the first-paint latency too: rows stream into the list
    # between chunks, so at the ~13ms of scan_one per file measured here, 20
    # puts the first rows on screen a quarter-second after the scan starts and
    # bounds mid-scan input stalls near that. 200 held the window frozen and empty for the whole pass.
    dict set Config scan_yield_files   20
    # Resume policy for the browse scan between chunks. timer = resume after
    # scan_resume_ms (steady progress); idle = resume only when the event loop
    # is otherwise idle (yields hard to input, may pause under continuous typing;
    # also lets any `update idletasks` in a handler drain the whole remaining
    # scan). At 20-file chunks idle measures the same as timer for paint
    # latency, so timer stays the default.
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
    # fallback when the core count cannot be detected. QUESTLOG_THREADS
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
    # Under a non-default sort, a late metric (cost/turns/duration/A/H) reorders
    # the list, which means a full re-render. Debounce that re-render by this
    # many ms: each arrival resets the timer, so a metric flood resolves to one
    # rebuild when arrivals pause and the list stays still (in arrival order)
    # while they stream, instead of wiping on every coalesced batch.
    dict set Config resort_debounce_ms 250
    # Composing-time cap for the human side of the duration split, in minutes.
    # A gap that ends at a human record (a typed prompt, a dialog answer)
    # counts as human time up to this cap; a longer gap means the user was
    # away, and the excess counts as nobody's time.
    dict set Config cost_human_gap_cap_min 5

    # ---- search render -----------------------------------------------------
    # How found sessions reach the list as a search runs. coalesced = buffer the
    # per-file results and render them folder-grouped when the event loop next
    # goes idle, so typing always preempts and a broad term cannot freeze the
    # list; immediate = render each session as it arrives (still one anchored
    # pass per session, never per match).
    dict set Config search_render coalesced
    # Caps each idle render slice to this many ms, yielding between slices, so a
    # query matching every file in the since bound cannot block input beyond this on
    # any machine. 0 renders the whole idle batch in one pass (faster overall,
    # but an ~800ms hitch on a very broad term).
    dict set Config search_render_slice_ms 50

    # ---- polling -----------------------------------------------------------
    # Re-poll interval for the live-session registry (running markers). The cost
    # is O(running sessions), independent of the on-disk corpus.
    dict set Config running_poll_ms 2000

    # ---- recency presets ---------------------------------------------------
    # The recency filter. since_presets is the set the toolbar's radio offers;
    # since_default is the one a fresh GUI launch starts on; "all" means no
    # bound. A since value (a preset, or an open --since duration) is turned
    # into a cutoff by ::questlog::filter::parse_since.
    dict set Config since_presets {24h 7d 30d all}
    dict set Config since_default 7d

    # ---- minimum turns -----------------------------------------------------
    # The "min turns" scope filter. The scanner counts a session's user turns
    # up to turn_count_cap (so a row's recorded nturns saturates there, and the
    # spinbox max is this cap); the spinbox spans 1..turn_count_cap.
    # min_turns_default is the GUI's startup value - 2 keeps the old "exclude
    # one-turn sessions" default - while 1 means no filter (include all).
    dict set Config turn_count_cap   9
    dict set Config min_turns_default 2

    # ---- display caps ------------------------------------------------------
    # Tail bytes read for the most-recent agentName/aiTitle rename records.
    dict set Config tail_window_bytes 65536
    # A search-hit snippet leads with the matched term: snippet_lead characters
    # of context (with a leading "…") sit before the hit, snippet_trail after.
    # Asymmetric so the term stays on screen when the one-line snippet row is
    # clipped to the column width (the row neither wraps nor scrolls sideways).
    dict set Config snippet_lead  16
    dict set Config snippet_trail 144
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
    # Minutes of silence that mark a secondary idle-gap divider in the viewer.
    dict set Config viewer_idle_gap_min 10

    # ---- drag-to-move ------------------------------------------------------
    # Pointer travel before a press becomes a drag; autoscroll tick interval
    # while dragging in an edge band; the edge band depth top and bottom.
    dict set Config drag_threshold_px  6
    dict set Config drag_autoscroll_ms 60
    dict set Config drag_edge_band_px  16

    # ---- debug -------------------------------------------------------------
    # 1 iff the launcher saw -debug 1: turns on the opt-in diagnostic log
    # (::questlog::debug), off by default so a normal run writes nothing. The
    # launcher overwrites this from the command line before the ui/ layer loads.
    dict set Config debug_enabled 0
}

# Value for a key. Errors loudly on an unknown key rather than returning a
# default, so a typo surfaces at startup, not as a silent wrong setting.
proc ::questlog::config::get {key} {
    variable Config
    return [dict get $Config $key]
}
