package require Tcl 9
package require Tk
package require tkdown 2.1
package require showman

# Round-robin interleave of per-term hit-position lists, already ordered
# rarest-term-first by the caller. Returns a flat list: the first hit of each
# term in rarity order, then the second of each, and so on, dropping any
# position already taken (a query term that is a substring of another at the
# same spot). Every matched term is thus represented before any term repeats,
# so a distinctive low-frequency term leads the match index instead of being
# buried under a common word. Pure; unit-tested.
proc ::questlog::ui::rarity_round_robin {term_positions} {
    set out [list]
    set seen [dict create]
    set max 0
    foreach positions $term_positions {
        set n [llength $positions]
        if {$n > $max} { set max $n }
    }
    for {set r 0} {$r < $max} {incr r} {
        foreach positions $term_positions {
            if {$r >= [llength $positions]} continue
            set p [lindex $positions $r]
            if {[dict exists $seen $p]} continue
            dict set seen $p 1
            lappend out $p
        }
    }
    return $out
}

# ::questlog::ui::Viewer - read-only segmented session viewer.
#
# A single instance docked in the right pane. `show path lineno` loads a
# session and anchors to a line; calling it again replaces the content.
# Rendering the whole file before scrolling is what keeps the view still, so
# it never grows or jumps under the reader. Renders one jsonl as a flat
# sequence of turns broken into sections by:
#   primary:   compact_boundary records.
#   secondary: idle gaps over the -idle_gap threshold (minutes).
# Recap markers (long assistant turn after an idle gap) are tertiary cues
# and not dividers.
#
# Search-within: Ctrl-F focuses an entry; Return advances to the next match.

oo::class create ::questlog::ui::Viewer {
    superclass ::showman::Showman
    mixin leash
    variable Top
    variable Empty            ;# centered empty-state frame, shown until first load
    variable Shown            ;# 0 until the first session replaces the empty state
    variable Path
    variable Records
    variable Sections        ;# list of dicts: {kind label start_idx end_idx}
    variable Text             ;# the text widget
    variable Sb               ;# the transcript's scrollbar (alias, like Text)
    variable NameLabel        ;# header label showing the loaded session's name
    variable NameFull         ;# full session name, kept for re-elision and the hover reveal
    variable NameCut          ;# 1 while the strip is showing less than the whole name
    variable PathLabel        ;# header label showing the loaded session's cwd
    variable IdLabel          ;# header label showing the abbreviated session id
    variable ActionMenu       ;# the "⋯" head-strip menu (Font, and Stage 2 actions)
    variable Uuid             ;# loaded session's uuid (basename of the jsonl)
    variable Cwd              ;# loaded session's working directory (first_cwd)
    variable CwdFull          ;# full ~-collapsed cwd string, kept for re-elision on resize
    variable Find             ;# find overlay frame
    variable FindExcerpt      ;# streamdoc's index -> excerpt for its find_extra hits
    variable FindMatches      ;# list of indices of all current matches
    variable FindCur          ;# 0-based hit last shown (-1 = none shown yet); the
                              ;# readout and the band highlight both read it, and
                              ;# find_next steps it (the sole find/step cursor)
    variable LineMap          ;# dict: jsonl line offset (1-based) -> text index
    variable Menu             ;# right-click context menu
    variable MenuTarget       ;# dict capturing the clicked target
    variable Bodies           ;# dict: jsonl line -> raw body (for Copy message)
    variable TurnList         ;# listbox of per-turn rows (alias of BandDesc turns list)
    variable MatchList        ;# listbox of per-match rows (alias of BandDesc matches list)
    variable MatchLabels      ;# per-match one-line excerpt, parallel to FindMatches
    variable BandMatchSet     ;# the FindMatches the match listbox was last filled
                              ;# from; select_band_row compares against it so a
                              ;# Ctrl-F recollect that left the band stale is skipped
    variable ToolList         ;# listbox of per-call rows (alias of BandDesc tools list)
    variable ToolLines        ;# {jsonl line, ordinal in record} of each call, parallel to the ToolList rows
    variable QuoteList        ;# listbox of per-quote rows (alias of BandDesc quotes list)
    variable QuoteIdx         ;# text index of each quote block, parallel to QuoteList rows
    variable QuoteBodies      ;# raw de-quoted text of each quote, parallel to QuoteIdx (for copy)
    variable CurTs            ;# ISO stamp of the record being rendered, read for a quote row
    variable Roles            ;# dict: jsonl line -> uppercased role, for row colour
    # Turns/CurTurn: a read-computed compatibility surface over the streamdoc
    # base class's region store (one region per turn). A read trace (constructor)
    # regenerates both from region_info on every read - the base class's marks
    # are the truth, these exist for outside readers (the fold tests, the
    # bench) that grew up on the hand-kept registry this replaced:
    #   {id line hdr body end label ts folded shown counts stub}
    # hdr/body/end/stub as text indices (end "" while the turn is open, stub
    # "" while it has no summary line); line/label/ts/counts from the
    # region's payload.
    variable Turns
    variable CurTurn          ;# index of the open turn, -1 outside one
    # Hover copy affordance: one shared ⧉ button, built once as a child of $Text
    # and placed on demand at the top-right of whatever user/assistant message
    # the pointer is over - the discoverable twin of the right-click "Copy
    # message". It is shown with `place` and hidden with `place forget`, never
    # `window create`d into the text: an embedded window swallows the wheel as
    # the pointer crosses it (the defect the quote de-widgetisation cured), so
    # this button forwards the wheel to $Text's yview by hand. CopyLine is the
    # jsonl line it would copy ("" while hidden); CopyFirst/CopyLast cache the
    # message's text-line span so a Motion within one message does not re-place
    # per pixel; CopyFbTok holds the ✓-acknowledgement restore timer's token.
    variable CopyBtn
    variable CopyLine
    variable CopyFirst
    variable CopyLast
    variable CopyFbTok
    # Docked index band above the transcript: one collapsible pane whose content
    # switches between the match index and the tool-call timeline. Docked, it
    # takes its height from the split and never covers the reading view.
    variable Band             ;# the band frame, the body split's top pane while open
    variable BandTab          ;# "turns"|"matches"|"tools"|"quotes": which list the band shows
    variable BandOpen         ;# 1 while the band pane is present (taking transcript height)
    variable BandSash         ;# band pixel height remembered at band_hide and
                              ;# restored on reopen ("" until the first close of
                              ;# the run)
    variable BandCount        ;# band-header count label
    variable FoldBar          ;# band-header fold-all/expand-all affordance, shown only on the Turns tab
    # BandDesc: ordered dict key -> per-tab descriptor, one entry per band tab in
    # canonical left-to-right order (turns, matches, tools, quotes). Each descriptor
    # carries the tab's header label (tab), head-strip count label (btn), listbox
    # (list) and its scrollbar (sb), the current count string (count, "" while the
    # tab is empty), its singular/plural unit words (unit, a {singular plural}
    # pair), auto (1 only for matches, whose refresh auto-opens the band), and
    # onselect (the <<ListboxSelect>> handler method). Every per-tab loop -- widget
    # creation in build, set_tab, update_band_tabs, update_band_glyphs, and
    # refresh_band_control -- walks this one dict, so a new tab is one more entry
    # here, not a fourth parallel set of vars. (tabtext/stem are build-time helpers
    # for the label text and the historical short widget path names.)
    variable BandDesc
    variable OnToggle         ;# cb: () -> ask the app to fold/unfold the list pane
    variable OnMove           ;# cb: [list path] -> app move router (⋯ menu)
    variable OnBookmark       ;# cb: path -> app bookmark router (⋯ menu)
    variable OnRename         ;# cb: path -> app rename router (⋯ menu)
    variable CollapseBtn      ;# the header toggle label
    variable IconOpen         ;# toggle photo, list shown (solid left pane)
    variable IconClosed       ;# toggle photo, list hidden (dim left pane)
    variable Query            ;# the active search ({terms .. nocase ..} or {}), re-applied after a streamed turn
    variable LoadedLines      ;# count of physical jsonl lines consumed, so a streamed turn tails only the new ones
    variable RenderModel      ;# trailing render state: model id of the last chipped assistant record, reset per turn; drives the per-turn model chip
    # Resume prompt bar: a one-shot `claude -p --resume` for the loaded session,
    # summoned like Find, its turn streamed back into the transcript.
    variable Prompt           ;# the bar frame, packed at the viewer bottom on demand
    variable PromptEntry      ;# the prompt entry widget
    variable PromptVar        ;# entry text
    variable PermVar          ;# picked permission mode (readonly|edits|edits-git|full)
    variable PromptSend       ;# the Send button
    variable PromptStatus     ;# bar status label (running / error)
    variable OnRefresh        ;# cb: path -> app re-scans the row after a streamed turn lands
    variable Pipe             ;# the running claude -p pipe channel, "" when idle
    variable Tick             ;# leash token of the jsonl tail tick while streaming
    variable WatchTok         ;# leash token of the file-growth watch tick (empty until shown)
    variable WatchSize        ;# file size at the last settled look, so growth is a bare stat compare
    variable WatchDirty       ;# 1 while external growth has landed but the catch-up index pass has not
    variable Running          ;# 1 while a streamed turn renders into the current view
    variable Detached         ;# 1 when the user navigated away mid-stream (drain only, do not render)
    variable RunPath          ;# the jsonl the running turn targets, for the row refresh
    variable ErrBuf           ;# merged stdout+stderr of the running turn, shown on failure

    constructor {parent {on_toggle ""} {on_move ""} {on_bookmark ""} {on_rename ""} {on_refresh ""}} {
        set Top $parent
        set Shown 0
        set Path ""
        set Records [list]
        set Sections [list]
        set LineMap [dict create]
        set MenuTarget [dict create]
        set Bodies [dict create]
        set MatchLabels [list]
        set BandMatchSet [list]
        set ToolLines [list]
        set QuoteIdx [list]
        set QuoteBodies [list]
        set CurTs ""
        set Roles [dict create]
        set Turns [list]
        set CurTurn -1
        set CopyLine ""
        set CopyFirst 0
        set CopyLast 0
        set CopyFbTok ""
        set BandTab "matches"
        set BandOpen 0
        set BandSash ""
        set OnToggle $on_toggle
        set OnMove $on_move
        set OnBookmark $on_bookmark
        set OnRename $on_rename
        set OnRefresh $on_refresh
        set Uuid ""
        set Cwd ""
        set CwdFull ""
        set Query ""
        set LoadedLines 0
        set RenderModel ""
        set PromptVar ""
        set PermVar readonly
        set Pipe ""
        set Tick ""
        set WatchTok ""
        set WatchSize 0
        set WatchDirty 0
        set Running 0
        set Detached 0
        set RunPath ""
        set ErrBuf ""
        my build
        # Base-class host wiring: showman (and streamdoc under it) drives
        # the transcript widget built above (the shared Text), keeps a tail
        # reader latched across streamed appends, and its first reset seeds
        # the region store and the render/find/live state.
        my configure -autofollow 1 \
            -idle_gap [::questlog::config::get viewer_idle_gap_min]
        my reset
        foreach v {Turns CurTurn} {
            trace add variable [my varname $v] read [list [self] turns_surface]
        }
    }

    # Load a session and anchor to a line (1-based; 0 means top). Replaces
    # whatever was shown before. `query` is the active search ({terms <list>
    # nocase 0|1}, or {}); its terms are matched literally, highlighted, and
    # listed in the docked match index band. `name` is the session's name for
    # the strip; the caller holds it already (the list keeps it in its store),
    # and the strip shows the cwd alone when there is none.
    method show {jsonl_path {scroll_to_line 0} {query {}} {name ""}} {
        # Leaving a session mid-stream detaches its turn (it finishes on disk and
        # reloads on next open) and folds the prompt bar away, like find_hide.
        # The bar is reset for the new session; a detached run never touches
        # it, so its eventual finish cannot re-enable or clear the wrong session.
        my resume_detach
        my prompt_hide
        my set_prompt_enabled 1
        my prompt_status ""
        # The hover-copy cache is line numbers into the OLD session; a stale
        # button would copy an arbitrary record of the new one. Today every
        # show is a pointer click that already fired <Leave>, but the widget
        # invariant must not lean on where the pointer happens to be.
        my copy_hide
        # Typed-but-unsent prompt text belongs to the session it was typed
        # under, not the next one shown.
        set PromptVar ""
        if {!$Shown} {
            grid remove $Empty
            grid $Text -row 0 -column 0 -sticky nsew
            grid $Sb   -row 0 -column 1 -sticky ns
            set Shown 1
        }
        set Path $jsonl_path
        set Query $query
        set Records [list]
        set LineMap [dict create]
        set LoadedLines 0
        set Uuid [file rootname [file tail $Path]]
        set Cwd [::logman::first_cwd $Path]
        # Show the working directory the session ran in (it survives a move,
        # unlike the encoded project folder the jsonl sits under). Fall back to
        # the jsonl's own directory when the file records no cwd.
        set shown_dir [expr {$Cwd ne "" ? $Cwd : [file dirname $Path]}]
        set CwdFull [::questlog::path::pretty_home $shown_dir]
        my elide_cwd
        my set_name $name
        $IdLabel configure -text \
            "[string range $Uuid 0 3]…[string range $Uuid end-3 end]"
        my find_hide 0
        # Seed the growth watch from the size load is about to read. Taken
        # before load so under-reading is the safe direction: the next watch
        # tick pays one idempotent zero-record append_new rather than missing
        # a byte a slow disk had not flushed yet.
        set WatchSize [expr {[catch {file size $Path} sz] ? 0 : $sz}]
        set WatchDirty 0
        my load
        my render
        my index_matches $query
        my index_tool_calls
        my refresh_quote_control
        my index_turns
        my add_endhint
        if {$scroll_to_line > 0} {
            my scroll_to_line $scroll_to_line
        } else {
            $Text see 1.0
        }
        # Arm (or re-arm) the growth watch for this session. Forgetting any
        # prior token before arming leaves exactly one live watch after a
        # session switch.
        if {$WatchTok ne ""} { my forget $WatchTok }
        set WatchTok [my later [::questlog::config::get viewer_watch_ms] \
            [list [self] watch_tick]]
    }

    method build {} {
        ttk::frame $Top
        # Path strip: an info strip embedded at the top of the viewer block,
        # flush against the body (no separator, minimal pad), like the strip
        # atop a text editor. A plain frame/label carries a subtle background
        # tint so it reads as part of the pane rather than a control bar.
        set strip [::questlog::ui::theme::c strip]
        # The docked band's tabs all share one shape (a head-strip count, a header
        # tab, a listbox+scrollbar, a count string). BandDesc is the ordered
        # key->descriptor dict that drives every per-tab loop below; the loops here
        # fill in each descriptor's widget paths (tab/btn/list/sb). Canonical order
        # is turns, matches, tools, quotes (Turns leftmost). tabtext is the header
        # label; stem keeps the historical short widget names (matchlist/toolsb/...);
        # unit is the {singular plural} count word; auto=1 (matches only) auto-opens
        # the band on refresh, and the Turns tab is deliberately auto 0 so a session
        # click never surfaces it - it is a reach-for index; onselect is the
        # <<ListboxSelect>> handler.
        set BandDesc [dict create \
            turns   [dict create tabtext "Turns" stem turn \
                         unit {turn turns} auto 0 onselect turn_list_select \
                         count ""] \
            matches [dict create tabtext "Matches" stem match \
                         unit {match matches} auto 1 onselect match_list_select \
                         count ""] \
            tools   [dict create tabtext "Tools" stem tool \
                         unit {{tool call} {tool calls}} auto 0 \
                         onselect tool_list_select count ""] \
            quotes  [dict create tabtext "Quotes" stem quote \
                         unit {quote quotes} auto 0 onselect quote_list_select \
                         count ""]]
        frame $Top.head -background $strip
        pack $Top.head -side top -fill x
        # The session's name, the thing that identifies it to a reader, ahead of
        # the cwd it ran in. Both labels expand, so they share the strip's slack
        # and give way together as the pane narrows; both cut their text
        # themselves, Tk labels having no ellipsis of their own. -width 1 is what
        # makes the sharing even: a label asks for the width of its text, so two
        # expanders would divide the slack left over after the longer one was
        # served whole - and a label that cuts its own text to fit then asks for
        # less on the next pass, and less again, until it has cut itself down to
        # the ellipsis. Asking for one character each, they split the strip.
        label $Top.head.name -text "" -background $strip -anchor w -font QLBold \
            -width 1 -foreground [::questlog::ui::theme::c sessionhead]
        pack $Top.head.name -side left -padx {6 0} -pady 1 -fill x -expand 1
        set NameLabel $Top.head.name
        set NameFull ""
        set NameCut 0
        bind $NameLabel <Configure> [list [self] elide_name]
        bind $NameLabel <Enter> [list [self] reveal_name]
        bind $NameLabel <Leave> [list ::questlog::ui::reveal::hide]
        label $Top.head.path -text "no session selected" -background $strip \
            -anchor w -width 1 -font QLMono \
            -foreground [::questlog::ui::theme::c muted]
        pack $Top.head.path -side left -padx 6 -pady 1 -fill x -expand 1
        set PathLabel $Top.head.path
        # The cwd can outrun the strip; Tk labels do not ellipsize, so re-elide
        # it on every resize (elide_cwd keeps the ~ head and the leaf, dropping
        # the middle), restoring detail when the pane widens.
        bind $PathLabel <Configure> [list [self] elide_cwd]
        # Abbreviated session id (first4…last4 of the uuid), click-to-copy the
        # full id. Fixed width on the right, packed before the on-demand counts
        # and never forgotten so the expanding cwd cannot squeeze it out.
        label $Top.head.sid -text "" -background $strip -cursor hand2 \
            -font QLMono -foreground [::questlog::ui::theme::c sessionhead]
        set IdLabel $Top.head.sid
        pack $IdLabel -side right -padx 6 -before $Top.head.path
        bind $IdLabel <Button-1> [list [self] copy_uuid]
        # Head-strip index counts, one per band tab: a count on the right of the
        # strip that opens the docked band (built below) on its own tab and
        # collapses it when clicked again. Each carries its count even while the
        # band is collapsed; glyph ▾ closed, ▴ open. Packed on demand by
        # refresh_band_control (through the per-tab wrappers) and absent when the
        # tab has nothing to show: no search (matches), no tool calls (tools), or
        # no quoted passages (quotes). Widget path $Top.head.<key>.
        foreach key [dict keys $BandDesc] {
            set btn $Top.head.$key
            label $btn -text "" -background $strip \
                -foreground [::questlog::ui::theme::c sessionhead] -cursor hand2
            bind $btn <Button-1> [list [self] band_toggle $key]
            dict set BandDesc $key btn $btn
        }
        # Overflow menu at the right of the head strip: a plain "⋯" label
        # affordance (matching the strip's flat look) holding the reading-font
        # picker, and in Stage 2 the session action set. Packed first on the
        # right and never forgotten, so the match/tool count re-pack dance keeps
        # it rightmost. The on-demand counts pack to its left when active.
        label $Top.head.actions -text "⋯" -background $strip \
            -foreground [::questlog::ui::theme::c sessionhead] -cursor hand2
        pack $Top.head.actions -side right -padx 6 -before $Top.head.sid
        bind $Top.head.actions <Button-1> [list [self] actions_menu_popup]
        set ActionMenu $Top.actionsmenu
        menu $ActionMenu -tearoff 0

        # Sidebar toggle at the far left of the strip (Ctrl+B's mouse twin). The
        # design icon (the session-viewer screen in screens.jsx) is a panel outline with a
        # filled left pane and a divider; the left pane is solid when the list is
        # shown and dim when hidden, so the icon states the current mode. Two
        # photos, swapped by set_collapsed. It is the always-visible hint that
        # the list is foldable and reopenable. Core Tk 9 decodes SVG with no
        # extension; if a build cannot, make_toggle_icon returns "" and a text
        # glyph stands in.
        set IconOpen   [my make_toggle_icon [::questlog::ui::theme::c muted] \
                            [::questlog::ui::theme::c muted]]
        set IconClosed [my make_toggle_icon [::questlog::ui::theme::c muted] \
                            [::questlog::ui::theme::c faint]]
        set CollapseBtn $Top.head.collapse
        if {$IconOpen ne ""} {
            label $CollapseBtn -image $IconOpen -background $strip -cursor hand2
        } else {
            label $CollapseBtn -text "◫" -background $strip -cursor hand2 \
                -foreground [::questlog::ui::theme::c muted]
        }
        pack $CollapseBtn -side left -padx {6 2} -before $Top.head.name
        bind $CollapseBtn <Button-1> [list [self] do_toggle]

        # Body: a vertical paned split. The docked index band is its top pane
        # (weight 0, inserted only while open) above the transcript frame
        # (weight 1). Forgetting the band pane gives every pixel back to the
        # transcript; while open, the sash between them is the visible divider
        # the user drags to re-split the height.
        ttk::panedwindow $Top.body -orient vertical
        pack $Top.body -side top -fill both -expand 1
        set main $Top.body.main
        ttk::frame $main
        $Top.body add $main -weight 1
        # text widget - no ttk equivalent.
        text $main.t -wrap word -yscrollcommand [list $main.sb set] \
            -state disabled -padx 10 -pady 6 -borderwidth 0 -highlightthickness 0
        ttk::scrollbar $main.sb -orient vertical -command [list [self] scroll_to]
        grid $main.t  -row 0 -column 0 -sticky nsew
        grid $main.sb -row 0 -column 1 -sticky ns
        grid columnconfigure $main 0 -weight 1
        grid rowconfigure    $main 0 -weight 1
        set Text $main.t
        set Sb $main.sb

        # Empty state: a centered prompt for the open gesture, gridded into the
        # same cell as the text so the head+body silhouette is identical
        # whether empty or loaded. Shown at launch (the text and its scrollbar
        # start grid-removed); the first `show` swaps them in.
        ttk::frame $main.empty
        grid $main.empty -row 0 -column 0 -columnspan 2 -sticky nsew
        grid rowconfigure    $main.empty {0 2} -weight 1
        grid columnconfigure $main.empty {0 2} -weight 1
        ttk::frame $main.empty.box
        ttk::label $main.empty.box.msg -justify center -font QLBold \
            -foreground [::questlog::ui::theme::c section] \
            -text "Click a session to show it here"
        ttk::label $main.empty.box.sub -justify center -wraplength 340 \
            -foreground [::questlog::ui::theme::c muted] \
            -text "A single click loads the transcript here. After a search, the match index up top jumps to each hit."
        pack $main.empty.box.msg -side top -pady {0 6}
        pack $main.empty.box.sub -side top
        grid $main.empty.box -row 1 -column 1
        set Empty $main.empty
        grid remove $main.t $main.sb

        # Docked index band. One collapsible pane above the transcript whose
        # content switches between the match index and the tool-call timeline.
        # The body split's top pane while open (band_show inserts it, band_hide
        # forgets it, giving every pixel back to the transcript), and full-width
        # so the reading column keeps its width (the win over a side column).
        # Its listboxes share the band's content cell; set_tab grids one and
        # removes the rest.
        # The header carries the Turns|Matches|Tools|Quotes tabs, the active count,
        # the Turns-tab fold-all/expand-all affordance, and ✕.
        # A classic tk frame/label set tinted with the head strip's background,
        # not ttk (clam ignores -background on ttk frames), so the head strip and
        # band read as one contiguous chrome zone over the transcript.
        set Band $Top.body.band
        frame $Band -background $strip
        frame $Band.hdr -background $strip
        frame $Band.hdr.tabs -background $strip
        # Header tabs, one per band tab. update_band_tabs later re-packs whichever
        # have rows in canonical order; this creation pack only fixes their initial
        # left-to-right sequence (BandDesc order). Widget path $Band.hdr.tabs.<key>.
        set first 1
        foreach key [dict keys $BandDesc] {
            set tab $Band.hdr.tabs.$key
            label $tab -text [dict get $BandDesc $key tabtext] -background $strip \
                -cursor hand2 -foreground [::questlog::ui::theme::c muted] \
                -font QLMonoBold
            bind $tab <Button-1> [list [self] set_tab $key]
            pack $tab -side left -padx [expr {$first ? "0" : "10 0"}]
            set first 0
            dict set BandDesc $key tab $tab
        }
        set BandCount $Band.hdr.count
        label $BandCount -text "" -background $strip \
            -foreground [::questlog::ui::theme::c sessionhead]
        label $Band.hdr.close -text "✕" -background $strip \
            -foreground [::questlog::ui::theme::c muted] -cursor hand2
        bind $Band.hdr.close <Button-1> [list [self] band_hide]
        pack $Band.hdr.tabs  -side left -padx 8 -pady 2
        pack $BandCount      -side left -padx 6
        pack $Band.hdr.close -side right -padx 8
        # Fold-all / expand-all affordance, a right-aligned pair shown only while
        # the Turns tab is the front tab (set_tab packs it there and forgets it on
        # every other tab). Faint mono labels in the tabs' key, subtler than a tab
        # so they read as a control not a fourth heading; a click drives the fold
        # primitives over every turn. Built here (unpacked, so it stays hidden until
        # the Turns tab is chosen) and parked just left of the ✕.
        set FoldBar $Band.hdr.foldbar
        frame $FoldBar -background $strip
        label $FoldBar.fold -text "fold all" -background $strip -cursor hand2 \
            -font QLMono -foreground [::questlog::ui::theme::c faint]
        label $FoldBar.expand -text "expand all" -background $strip -cursor hand2 \
            -font QLMono -foreground [::questlog::ui::theme::c faint]
        bind $FoldBar.fold   <Button-1> [list [self] fold_all]
        bind $FoldBar.expand <Button-1> [list [self] expand_all]
        pack $FoldBar.fold   -side left -padx {0 8}
        pack $FoldBar.expand -side left
        # One listbox + scrollbar per band tab, all sharing the band's content
        # cell (set_tab grids the active one and removes the rest). Each tab's
        # producer fills its rows: the turn index "time · first prompt line"
        # coloured like a user label, a jump list over the turn registry (the
        # reading model's unit, foldable to a table of contents); the match index
        # "ROLE · …excerpt… · line N" coloured by role; the tool timeline (the
        # did-versus-claimed audit, issue #15) "time · tool · path" in chronological
        # order; the quote index "time · first quoted line" -- a quick jump list to
        # an assistant's quoted passages (their text is plain tagged text now, found
        # by $Text search like any prose, so this is a convenience index, not the
        # only way in). A row click jumps the reading view to its target. The
        # widget paths keep the historical stems ($Band.matchlist/$Band.matchsb ...).
        foreach key [dict keys $BandDesc] {
            set stem [dict get $BandDesc $key stem]
            set lb $Band.${stem}list
            set sb $Band.${stem}sb
            listbox $lb -height 1 -width 44 -activestyle none \
                -borderwidth 0 -highlightthickness 0 \
                -yscrollcommand [list $sb set]
            ttk::scrollbar $sb -orient vertical -command [list $lb yview]
            bind $lb <<ListboxSelect>> \
                [list [self] [dict get $BandDesc $key onselect]]
            dict set BandDesc $key list $lb
            dict set BandDesc $key sb $sb
        }
        # Convenience aliases so methods that touch only one list (index_turns,
        # turn_list_select, match_list_select, index_tool_calls, quote_list_select,
        # render, on_block) need no descriptor lookup.
        set TurnList  [dict get $BandDesc turns list]
        set MatchList [dict get $BandDesc matches list]
        set ToolList  [dict get $BandDesc tools list]
        set QuoteList [dict get $BandDesc quotes list]
        grid $Band.hdr -row 0 -column 0 -columnspan 2 -sticky ew
        grid columnconfigure $Band 0 -weight 1
        grid rowconfigure    $Band 1 -weight 1
        # The band starts collapsed: it joins the body split only in band_show.

        # Tags.
        # Section header (the "▼ date" line): grey, monospace, not bold.
        $Text tag configure section-header -font QLMono \
            -spacing1 10 -spacing3 4 -foreground [::questlog::ui::theme::c section]
        $Text tag configure divider -justify center -font QLMono \
            -foreground [::questlog::ui::theme::c muted] -spacing1 6 -spacing3 6
        $Text tag configure compact-divider -justify center -font QLMono \
            -foreground [::questlog::ui::theme::c compact] -spacing1 8 -spacing3 8
        # Colour marks only the role label (monospace bold, design role fg); the
        # message body is neutral ink, so the transcript reads as prose with a
        # coloured speaker tag, not a wall of tinted text.
        $Text tag configure lbl-user      -foreground [::questlog::ui::theme::c user]      -font QLMonoBold -lmargin1 10 -lmargin2 10 -spacing1 6
        $Text tag configure lbl-assistant -foreground [::questlog::ui::theme::c assistant] -font QLMonoBold -lmargin1 10 -lmargin2 10 -spacing1 6
        $Text tag configure lbl-system    -foreground [::questlog::ui::theme::c tool]      -font QLMonoBold -lmargin1 10 -lmargin2 10 -spacing1 6
        $Text tag configure lbl-tool_result -foreground [::questlog::ui::theme::c tool_result] -font QLMonoBold -lmargin1 10 -lmargin2 10 -spacing1 6
        # Per-turn model chip: a small tinted run (coloured dot + short label over
        # a pale tint) on the assistant header line, one per family plus a neutral
        # `other`. model-<fam> carries the label/tint, modeldot-<fam> the dot's own
        # ink over the same tint. The shared `modelchip` marker tag (applied at
        # insert_model_chip, carrying no appearance and no -elide, per the turn-tag
        # rule below) exists only so search skips the chip run.
        foreach suf {opus sonnet haiku fable other} {
            $Text tag configure model-$suf -font QLMonoBold \
                -background [::questlog::ui::theme::c model_${suf}_bg] \
                -foreground [::questlog::ui::theme::c model_$suf]
            $Text tag configure modeldot-$suf -font QLMonoBold \
                -background [::questlog::ui::theme::c model_${suf}_bg] \
                -foreground [::questlog::ui::theme::c model_${suf}_dot]
        }
        # Body prose follows QLBody, the proportional reading font switched at
        # runtime; fenced code keeps QLMono so it stays aligned regardless of
        # the reading font. Without an explicit -font the text widget would
        # render both in its TkFixedFont default.
        $Text tag configure body          -font QLBody -foreground [::questlog::ui::theme::c body] -spacing2 3 -spacing3 6
        $Text tag configure code          -font QLMono -foreground [::questlog::ui::theme::c body] -spacing2 3 -spacing3 6
        # Detail-block faces, one per block kind insert_blocks renders: tool
        # calls, tool results and the [image] placeholder in mono, thinking in
        # the italic reading face, all muted so detail reads apart from prose;
        # dk-chrome is the separately-inserted visual lead-in ([thinking] ).
        # They share body/code's left margins so columns align, but carry no
        # -spacing1/2/3. (Probed on Tk 9.0.3: a fully elided line contributes
        # no spacing either way, so this is caution, not load-bearing - kept
        # because a spacing-free detail line costs nothing and asks nothing of
        # the elide renderer.)
        foreach dk {dk-tool_use dk-tool_result dk-image dk-chrome} {
            $Text tag configure $dk -font QLMono \
                -foreground [::questlog::ui::theme::c muted] \
                -lmargin1 10 -lmargin2 10
        }
        $Text tag configure dk-thinking -font QLBodyItalic \
            -foreground [::questlog::ui::theme::c muted] -lmargin1 10 -lmargin2 10
        # Turn chrome. foldglyph paints the ▾/▸ heading a turn's header line;
        # it now holds the line's first character, so it must carry the label
        # row's -spacing1 and margins or every header would lose them. turnhdr
        # is the whole header line's click zone and deliberately sets no
        # appearance: it overlays the lbl-* role colours and, configured later,
        # would outrank them. stub is the faint one-line detail summary closing
        # a turn ("▸ · 7 tool calls · 2 thinking"); it sits inside the fold
        # range, so like the dk-* faces it carries no -spacing1/2/3 (spacing
        # would seam at the elide boundary when its turn folds). The per-turn
        # f#N/d#N elide tags are the base class's, configured at region_open in
        # that order, so a detail char's d#N outranks its f#N.
        $Text tag configure foldglyph -font QLMonoBold \
            -foreground [::questlog::ui::theme::c muted] \
            -lmargin1 10 -lmargin2 10 -spacing1 6
        $Text tag configure stub -font QLMono \
            -foreground [::questlog::ui::theme::c faint] -lmargin1 10 -lmargin2 10
        # editchip is the drafts note riding a user header line ("· 2 edits"),
        # sited like the assistant header's model chip: after the role label,
        # before the message. It sets no spacing or margin - it never holds a
        # display line's first character, and a -spacing1 here would fight the
        # label row's.
        $Text tag configure editchip -font QLMono \
            -foreground [::questlog::ui::theme::c faint]
        # `quote` lies over an assistant blockquote (tkdown's -quotetags). The
        # ⧉ glyph heading the block carries it without tkdown's td-quote, so
        # it holds the inset itself; no spacing, so the block reads as one.
        # Configured before tkdown's faces so inline emphasis inside a quote
        # still wins on -font.
        $Text tag configure quote -font QLBody \
            -foreground [::questlog::ui::theme::c body] -lmargin1 24 -lmargin2 24 \
            -spacing2 0 -spacing3 0
        # tkdown's td-* faces carry only a -font; colour and margins keep
        # coming from the body tag, which stays on every prose run (tags stack,
        # and the later tags win on -font). td-code is separate from the block
        # code tag so block-fence spacing and inline spans stay decoupled.
        # tags binds the <Configure> that re-fits the tables to the pane.
        ::tkdown::tags $Text [dict create \
            body QLBody bold QLBodyBold italic QLBodyItalic \
            bolditalic QLBodyBoldItalic mono QLMono] \
            -margin 10 -quotetags quote -on_block [list [self] on_block]
        $Text tag configure td-link -foreground [::questlog::ui::theme::c user] -underline 1
        $Text tag configure td-grid -background [::questlog::ui::theme::c faint]
        $Text tag configure td-spot -background [::questlog::ui::theme::c find]
        $Text tag configure td-rule -background [::questlog::ui::theme::c faint]
        # The quote block's muted chrome: td-quotebar tints the per-line ▏ rule,
        # `qcopy` the ⧉ copy glyph heading the block. Configured after `quote` so
        # their muted ink outranks its body ink where they stack. qcopy also
        # carries the hand cursor, but a cursor is a per-widget option, not
        # per-tag, so flip $Text's cursor as the pointer crosses the glyph and
        # restore the reading view's default (an I-beam) on the way out. A click
        # on the glyph copies the quote (quote_copy_at resolves which one).
        $Text tag configure td-quotebar -foreground [::questlog::ui::theme::c muted]
        $Text tag configure qcopy    -foreground [::questlog::ui::theme::c muted]
        set qcursor [$Text cget -cursor]
        $Text tag bind qcopy <Enter> [list $Text configure -cursor hand2]
        $Text tag bind qcopy <Leave> [list $Text configure -cursor $qcursor]
        $Text tag bind qcopy <ButtonRelease-1> [list [self] quote_copy_at %x %y]
        # Turn header and stub clicks: fold toggle and detail toggle. Tag
        # bindings fire on disabled text (the sessions list relies on the same
        # fact), and the handlers resolve which turn from the click index, so
        # these two global tags serve every turn - no per-turn bindings.
        # ButtonRelease, guarded in the handlers against a live selection, so a
        # drag-select that merely ends on a header cannot toggle it.
        foreach zone {turnhdr stub} {
            $Text tag bind $zone <Enter> [list $Text configure -cursor hand2]
            $Text tag bind $zone <Leave> [list $Text configure -cursor $qcursor]
        }
        $Text tag bind turnhdr <ButtonRelease-1> [list [self] turnhdr_click %x %y]
        $Text tag bind stub    <ButtonRelease-1> [list [self] stub_click %x %y]
        # Ctrl-C copies what the reader can see: -displaychars drops elided
        # detail from the selection, so a copy over a turn cannot smuggle its
        # hidden tool output along. The break stops the Text class binding from
        # then re-copying the raw characters. X11 PRIMARY (middle-click paste)
        # stays unfiltered - accepted; the explicit copy is the contract.
        bind $Text <<Copy>> "[list [self] copy_selection]; break"
        $Text tag configure recap     -background [::questlog::ui::theme::c recap]
        $Text tag configure find      -background [::questlog::ui::theme::c find]
        # End-of-session hint: a centred, deeply inset cue that the reader can
        # send one more prompt. The wide left/right margin (derived from the mono
        # font so it scales with the reading size) sets it apart from the
        # full-width transcript, so it does not read as session content.
        set hintpad [expr {[font measure QLMono "0"] * 8}]
        $Text tag configure endhint -justify center -font QLMono \
            -foreground [::questlog::ui::theme::c muted] \
            -lmargin1 $hintpad -lmargin2 $hintpad -rmargin $hintpad \
            -spacing1 [font metrics QLMono -linespace] -spacing3 6

        # Right-click copy (issue #4).
        my build_menu
        bind $Text <<ContextMenu>> [list [self] on_right %x %y %X %Y]

        # A key acts from where the reader is looking. Every motion key the Text
        # class defines (the arrows, Home, End, Prior, Next, and the Control-key
        # twins Tk adds while tk_strictMotif is off) ends in tk::TextSetCursor,
        # which does `see insert`. Nobody types into a transcript, so its insert
        # mark sits where the render left it, on the last line of the session.
        # Left alone, one arrow press throws the reader from the message they
        # were on to the end of the transcript. Re-seating the mark before the
        # class handler runs turns the same keys into paging from the viewport,
        # which is what a reading pane wants them to be.
        bind $Text <KeyPress> +[list [self] park_cursor]

        # Hover copy button: one shared ⧉ affordance riding the top-right of the
        # message under the pointer (copy_motion places it, copy_hide forgets
        # it). A child of $Text but never `window create`d into it, so the text
        # never treats it as an embedded window and it consumes no text index; it
        # is positioned purely by `place`. -takefocus 0 keeps it out of the tab
        # ring, and it stays narrow (a single glyph). Its face reads the theme
        # palette (the colour SSOT) but the style is defined here, co-located with
        # its sole user: a flat chip in the reading background so it sits over the
        # transcript as a light affordance, its muted glyph brightening to ink
        # under the pointer (clam honours -background on a borderless ttk::button,
        # the LV.TButton precedent).
        set cbg [$Text cget -background]
        ttk::style configure Copy.TButton -background $cbg \
            -foreground [::questlog::ui::theme::c muted] \
            -borderwidth 0 -relief flat -shiftrelief 0 -padding {2 0}
        ttk::style map Copy.TButton \
            -background [list active $cbg pressed $cbg] \
            -foreground [list active [::questlog::ui::theme::c ink] \
                              pressed [::questlog::ui::theme::c ink]]
        set CopyBtn $Text.copybtn
        ttk::button $CopyBtn -style Copy.TButton -text "⧉" -width 2 \
            -takefocus 0 -cursor hand2 -command [list [self] copy_hovered]
        # Wheel forwarding (load-bearing): a `place`d button over $Text still eats
        # wheel events like any widget, so scroll $Text exactly as its
        # Text-class binding would, through scroll_to so that, like a wheel
        # on $Text itself, it lets go of the tail latch. Tk 9 delivers the wheel - on X11 too - as
        # <MouseWheel> with %D, scaled by tk::ScaleNum and divided by -4.0 into
        # pixels; text.tcl binds only <MouseWheel>/<TouchpadScroll> (no
        # <Button-4/5>), so mirroring those two is what "as the Text class would"
        # means here. The trailing break stops the button's own class bindings
        # from also firing.
        # Each forward starts by dropping the button itself: the scroll slides
        # new text under the pointer, and a button left placed would sit over
        # content it does not copy (the transcript-side wheel hide below cannot
        # cover this path - the event never reaches $Text).
        bind $CopyBtn <MouseWheel> \
            "[list [self] copy_hide]; [list [self] scroll_to] scroll \[expr {\[tk::ScaleNum %D\] / -4.0}\] pixels; break"
        bind $CopyBtn <Shift-MouseWheel> \
            "[list [self] copy_hide]; tk::MouseWheel $Text x \[tk::ScaleNum %D\] -4.0 pixels; break"
        bind $CopyBtn <TouchpadScroll> \
            "[list [self] copy_hide]; lassign \[tk::PreciseScrollDeltas %D\] cbdx cbdy;\
             if {\$cbdy != 0} {[list [self] scroll_to] scroll \[tk::ScaleNum \[expr {-\$cbdy}\]\] pixels};\
             break"
        # Show/hide as the pointer crosses the transcript: Motion resolves the
        # message under it and places the button; leaving $Text hides it unless
        # the pointer landed on the button itself; a wheel or resize over the
        # transcript would strand a placed button, so drop it (the next Motion
        # re-places it). A scrollbar drag is covered by <Leave> (the pointer
        # leaves $Text for the scrollbar). copy_motion carries no break, so the
        # text's own motion handling still runs.
        bind $Text <Motion>    [list [self] copy_motion %x %y]
        bind $Text <Leave>     [list [self] copy_leave]
        bind $Text <Configure> +[list [self] copy_hide]
        foreach ev {<MouseWheel> <Shift-MouseWheel> <TouchpadScroll> \
                    <Button-4> <Button-5>} {
            bind $Text $ev +[list [self] copy_hide]
        }

        # The base class's find bar, placed by place_find.
        my build_find
        $Find.pos configure -foreground [::questlog::ui::theme::c muted]
        # Summon Find from anywhere in the window, not only when the transcript
        # holds focus; find_show guards on a shown session.
        bind [winfo toplevel $Top] <Control-f> [list [self] find_show]

        # Resume prompt bar (hidden until summoned). Two stacked rows: the
        # permission chips above the entry, every choice one click with no menu
        # to open. prompt_show packs it at the bottom, so the options sit just
        # above the entry as it rises into view.
        set Prompt $Top.prompt
        ttk::frame $Prompt
        ttk::frame $Prompt.opts
        ttk::label $Prompt.opts.lbl -text "Permissions:"
        pack $Prompt.opts.lbl -side left -padx {4 6}
        foreach {val text} {
            readonly  "read-only"
            edits     "accept edits"
            edits-git "accept edits + git"
            full      "full access"
        } {
            set w $Prompt.opts.[string map {- _} $val]
            ttk::radiobutton $w -text $text \
                -variable [my varname PermVar] -value $val
            pack $w -side left -padx {0 8}
        }
        pack $Prompt.opts -side top -fill x -pady {2 0}
        ttk::frame $Prompt.row
        ttk::label $Prompt.row.lbl -text "Resume:"
        set PromptEntry $Prompt.row.e
        ttk::entry $PromptEntry -textvariable [my varname PromptVar]
        set PromptSend $Prompt.row.send
        ttk::button $PromptSend -text "Send" -command [list [self] resume_submit]
        set PromptStatus $Prompt.row.status
        ttk::label $PromptStatus -text "" -foreground [::questlog::ui::theme::c muted]
        ttk::button $Prompt.row.close -text "✕" -command [list [self] prompt_hide]
        pack $Prompt.row.lbl   -side left -padx 4
        pack $PromptEntry      -side left -fill x -expand 1
        pack $PromptSend       -side left -padx 2
        pack $PromptStatus     -side left -padx 6
        pack $Prompt.row.close -side left -padx 2
        pack $Prompt.row -side top -fill x
        bind $PromptEntry <Return> [list [self] resume_submit]
        bind $PromptEntry <Escape> [list [self] prompt_hide]
        # Ctrl-Return summons the bar from anywhere in the window, not only when
        # the transcript holds focus: bind on the toplevel, which is in every
        # widget's bindtags, so a key event reaches it whatever has focus.
        # prompt_show no-ops until a session is shown.
        bind [winfo toplevel $Top] <Control-Return> [list [self] prompt_show]
    }

    # Build a sidebar-toggle photo from the design's inline SVG (screens.jsx),
    # scaled to the strip's text height so it stays crisp on scaled displays.
    # Returns "" if this Tk build cannot decode SVG, so the caller can fall back.
    method make_toggle_icon {stroke leftfill} {
        set h [expr {int([font metrics QLMono -linespace] * 0.9)}]
        if {$h < 11} { set h 11 }
        set svg "<svg width=\"14\" height=\"11\" viewBox=\"0 0 14 11\">\
<rect x=\"0.6\" y=\"0.6\" width=\"12.8\" height=\"9.8\" rx=\"1.6\" fill=\"none\" stroke=\"$stroke\" stroke-width=\"1\"/>\
<rect x=\"0.6\" y=\"0.6\" width=\"4.4\" height=\"9.8\" rx=\"1.6\" fill=\"$leftfill\"/>\
<line x1=\"5\" y1=\"0.6\" x2=\"5\" y2=\"10.4\" stroke=\"$stroke\" stroke-width=\"1\"/></svg>"
        if {[catch {image create photo -data $svg \
                -format [list svg -scaletoheight $h]} img]} {
            return ""
        }
        return $img
    }

    method do_toggle {} { if {$OnToggle ne ""} { {*}$OnToggle } }

    # Reflect the list pane's state in the toggle icon: solid left pane when the
    # list is shown, dim when it is hidden. A no-op under the text-glyph fallback.
    method set_collapsed {collapsed} {
        if {![winfo exists $CollapseBtn]} return
        if {[$CollapseBtn cget -image] eq ""} return
        $CollapseBtn configure -image [expr {$collapsed ? $IconClosed : $IconOpen}]
    }

    # The path of the session currently shown, "" when the pane is empty. The app
    # asks this to tell whether a move it just made touched the open session.
    method current_path {} { return $Path }

    # The open session's jsonl moved on disk (a list move of the shown session):
    # follow it so the ⋯ verbs (Move/Bookmark/Rename act on $Path) and the growth
    # watch hit the new location. Content is unchanged, so nothing re-renders.
    method relocate {new_path} {
        if {$Path eq ""} return
        set Path $new_path
    }

    # Pop the platform font chooser, seeded with the body's current font. It is
    # a single shared modeless dialog, not a widget; its -command fires with the
    # chosen font appended when the reader confirms.
    method choose_font {} {
        tk fontchooser configure -parent $Top -title "Reading font" \
            -font QLBody -command [list [self] on_font_chosen]
        tk fontchooser show
    }

    # Copy the loaded session's full id to the clipboard (the id label shows
    # only the abbreviated first4…last4 form).
    method copy_uuid {} { if {$Uuid ne ""} { my clipboard_set $Uuid } }

    # The "⋯" overflow menu: the shared session action set for the loaded
    # session, then the viewer-local reading-font picker below a separator.
    # "Open in viewer" is omitted (the session is already shown). The folder is
    # the encoded basename of the jsonl's parent, the same value app::move_one
    # derives, so Reveal and the bookmark work without an app round-trip. Rename
    # is always enabled in the menu; the app's rename dialog disables its OK
    # button while the session is running.
    method actions_menu_popup {} {
        if {$Path eq ""} return
        set folder [file tail [file dirname $Path]]
        set ctx [dict create \
            target [dict create path $Path uuid $Uuid cwd $Cwd folder $folder] \
            parent $Top \
            clipboard [list [self] clipboard_set] \
            on_move $OnMove \
            on_bookmark $OnBookmark \
            on_rename $OnRename \
            state [dict create \
                is_bookmarked [file executable $Path] \
                has_cwd [file isdirectory $Cwd] \
                has_folder [expr {$folder ne ""}]]]
        set idx [::questlog::ui::session_actions::populate $ActionMenu $ctx]
        ::questlog::ui::session_actions::apply_state \
            $ActionMenu $idx [dict get $ctx state]
        # Fold-all / expand-all over the turn registry; the band-header pair on the
        # Turns tab is their twin. Disabled when the session rendered no turns, so
        # they read as unavailable rather than silently doing nothing.
        $ActionMenu add separator
        set tstate [expr {[my region_count] ? "normal" : "disabled"}]
        $ActionMenu add command -label "Fold all turns" -state $tstate \
            -command [list [self] fold_all]
        $ActionMenu add command -label "Expand all turns" -state $tstate \
            -command [list [self] expand_all]
        $ActionMenu add separator
        $ActionMenu add command -label "Continue with one prompt…" \
            -command [list [self] prompt_show]
        $ActionMenu add command -label "Font…" -command [list [self] choose_font]
        tk_popup $ActionMenu {*}[winfo pointerxy .]
    }

    # Fit the name into the strip. Cut from the tail, unlike the cwd's interior
    # elision: a name reads left to right and its opening words are what tell two
    # sessions apart. Bound to the label's <Configure>, so widening the pane
    # restores it. The whole name stays one hover away (reveal_name).
    method elide_name {} {
        if {![winfo exists $NameLabel]} return
        if {$NameFull eq ""} {
            $NameLabel configure -text ""
            set NameCut 0
            return
        }
        set avail [expr {[winfo width $NameLabel] - 12}]
        if {$avail <= 1} return
        if {[font measure QLBold $NameFull] <= $avail} {
            $NameLabel configure -text $NameFull
            set NameCut 0
            return
        }
        set cut $NameFull
        while {$cut ne "" && [font measure QLBold "$cut…"] > $avail} {
            set cut [string range $cut 0 end-1]
        }
        $NameLabel configure -text "$cut…"
        set NameCut 1
    }

    # The shown session's name, from open or from a rename that renamed the one
    # on screen. The strip is the only place the viewer states it, so it is the
    # only thing to update.
    method set_name {name} {
        set NameFull $name
        my elide_name
    }

    # The strip cuts the name to the room it has; the whole of it reveals on the
    # same panel the list's rows use. A name shown whole reveals nothing, as a
    # list row that fits wires nothing.
    method reveal_name {} {
        if {!$NameCut} return
        ::questlog::ui::reveal::show $NameFull
    }

    # Fit the cwd into the strip. Tk labels do not ellipsize, so when the full
    # ~-collapsed cwd overruns the available width we drop interior components,
    # keeping the head (the ~ anchor) and as many trailing components (the leaf
    # is what identifies the project) as fit: ~/code/…/leaf/dir. Bound to the
    # label's <Configure>, so widening the pane restores detail.
    method elide_cwd {} {
        if {![winfo exists $PathLabel]} return
        if {$CwdFull eq ""} return
        set avail [expr {[winfo width $PathLabel] - 12}]
        if {$avail <= 1} return
        if {[font measure QLMono $CwdFull] <= $avail} {
            $PathLabel configure -text $CwdFull
            return
        }
        set comps [split $CwdFull /]
        if {[lindex $comps 0] eq ""} {
            set comps [lreplace $comps 0 1 "/[lindex $comps 1]"]
        }
        set head [lindex $comps 0]
        set rest [lrange $comps 1 end]
        # Grow the kept tail until one more component would overflow.
        set best "$head/…/[lindex $rest end]"
        for {set k 1} {$k <= [llength $rest]} {incr k} {
            set tail [lrange $rest end-[expr {$k-1}] end]
            set cand "$head/…/[join $tail /]"
            if {[font measure QLMono $cand] > $avail} break
            set best $cand
        }
        $PathLabel configure -text $best
    }

    # Apply a chosen font to the reading body. Reconfiguring the named QLBody
    # reflows every body-tagged run; fenced code (QLMono) is untouched.
    method on_font_chosen {fontspec args} {
        ::questlog::ui::theme::set_body_font $fontspec
        # The named-font reflow updates the glyphs but not the table cells'
        # fixed -height, computed from display lines at the previous size.
        ::tkdown::refit $Text
    }

    method load {} {
        set fh [open $Path r]
        chan configure $fh -encoding utf-8 -profile replace
        set lineno 0
        while {[chan gets $fh line] >= 0} {
            incr lineno
            if {$line eq ""} continue
            set rec [::logman::parse_line $line]
            if {$rec eq ""} {
                # A newline-less final line that does not parse is the tail
                # claude is mid-write on: uncount it so append_new re-reads
                # it once the writer completes it (counted here, it would sit
                # under LoadedLines and the finished record would be skipped
                # forever - append_new never counts such a tail). A complete
                # garbage line stays counted and skipped, as ever.
                if {[chan eof $fh]} { incr lineno -1 }
                continue
            }
            dict set rec _line $lineno
            lappend Records $rec
        }
        close $fh
        set LoadedLines $lineno
    }

    method render {} {
        # The record walk is the base class's render_records: its reset wipes
        # the buffer, every region's marks and the per-turn f#N/d#N elide tag
        # families (tkdown sweeps its own per-table tags), then re-renders
        # the loaded records and leaves the final turn open (a session can
        # always grow), its detail summary the trailing content line
        # append_new's door knows to pop and recount. The app-side caches the
        # render hooks refill are cleared here first. Quotes are captured
        # during render (on_block), so a wholesale re-render clears them; a
        # streamed turn appends without re-render.
        set Roles [dict create]
        set Bodies [dict create]
        $QuoteList delete 0 end
        set QuoteIdx [list]
        set QuoteBodies [list]
        set RenderModel ""
        my render_records $Records
    }

    # The base class's per-record hook, after the role label and before the
    # body: the app caches (Bodies($line) is the raw extract_text the copy
    # affordances lift, Roles($line) colours the index rows, CurTs is the
    # stamp a quote box in this record reads), then the model chip on the
    # assistant header line - the first assistant of each turn always chips
    # (the turn boundary reset RenderModel to ""), a later assistant chips
    # again only when its model differs (a mid-turn /model change).
    method on_label_rendered {rec lineno body label ts_iso} {
        dict set Bodies $lineno $body
        dict set Roles $lineno $label
        set CurTs $ts_iso
        set edits [dict getdef $rec _edits 0]
        if {$edits > 0} { my insert_edit_chip $edits }
        if {[dict getdef $rec type ""] eq "assistant"} {
            set mdl [::logman::record_model $rec]
            if {$mdl ne "" && $mdl ne $RenderModel} {
                my insert_model_chip $mdl
                set RenderModel $mdl
            }
        }
    }

    # Layer over the base class's turn-aware record walk: reset the chip's
    # model at each turn boundary so the first assistant of every turn
    # re-chips even when unchanged from the prior turn; a same-model streamed
    # continuation inside a turn is not re-chipped. The turn model itself
    # (region close/open, the tool_result detail cover) is the base class's.
    method render_record_turned {rec last_ts in_section} {
        if {[::logman::opens_turn $rec]} { set RenderModel "" }
        return [next $rec $last_ts $in_section]
    }

    # Append jsonl lines written since the last load/append (a streamed turn
    # growing the file) to the end of the transcript, through the base class's
    # append_records so the new turns look exactly like a fresh load. Re-reads from the top and
    # skips already-rendered lines; cheap enough for one active stream. A line
    # without a trailing newline is the partial tail claude is mid-write on, so
    # it is left for the next pass. Auto-scrolls only if the reader was already
    # at the bottom. Returns the number of records appended.
    method append_new {} {
        if {$Path eq "" || ![winfo exists $Text]} { return 0 }
        if {[catch {open $Path r} fh]} { return 0 }
        chan configure $fh -encoding utf-8 -profile replace
        set lineno 0
        set recs [list]
        while {1} {
            if {[chan gets $fh line] < 0} break
            if {[chan eof $fh]} break
            incr lineno
            if {$lineno <= $LoadedLines} continue
            if {$line eq ""} continue
            set rec [::logman::parse_line $line]
            if {$rec eq ""} continue
            dict set rec _line $lineno
            lappend recs $rec
        }
        close $fh
        set LoadedLines $lineno
        # Records are read before the widget is touched, so the common empty
        # tick (the 300 ms cadence outruns claude's writes) mutates nothing -
        # in particular it does not churn the open turn's stub line. A tick
        # with a held-back turn start standing is the exception: it carries no
        # new records but has the hold to release, so it goes through.
        if {![llength $recs] && ![llength [my pending]]} { return 0 }
        # The summary pop inside the door deletes a mid-document line, so
        # every text line number at or under it shifts - including the
        # hover-copy cache, whose stale window otherwise makes the ⧉ copy the
        # message ABOVE the one under a parked pointer, every 300 ms tick.
        # Invalidate it first; the next Motion re-resolves against the
        # settled transcript.
        my copy_hide
        # New content makes any endhint stale; clearing it here (a no-op on
        # the streaming path, where resume_submit already did) keeps the
        # trailing-line invariant local: records append to the transcript
        # itself, with the open turn's summary as the last content line the
        # door knows to pop.
        my clear_endhint
        # The base class appends them in one batch: it anchors the reader once
        # (the autofollow latch keeps a tail reader at the tail), the door
        # pops the open turn's summary so the records land inside the turn,
        # and append_close re-covers a fold held during the stream and
        # re-appends the summary with the caught-up counts.
        return [my append_records $recs]
    }

    # Add the centred end-of-session hint at the very bottom, once. Kept out of
    # the match index by being added after indexing, and out of later searches
    # by content_end. Cleared before a turn streams in (clear_endhint) so new
    # content appends below the last turn, not below the hint.
    method add_endhint {} {
        if {!$Shown} return
        if {[llength [$Text tag ranges endhint]]} return
        $Text configure -state normal
        $Text insert end "\nContinue with one more prompt\n" endhint
        $Text insert end "Ctrl-Enter, or the ⋯ menu\n" endhint
        $Text configure -state disabled
    }

    method clear_endhint {} {
        set r [$Text tag ranges endhint]
        if {![llength $r]} return
        $Text configure -state normal
        $Text delete [lindex $r 0] [lindex $r end]
        $Text configure -state disabled
    }

    # ---- turn folding and detail hiding: the app skin over showman -----
    #
    # The showman base class owns the turn model - the click handlers,
    # the stub summary hook, the record walk - and streamdoc under it owns
    # the regions (one per turn), their boundary marks and both elide layers,
    # f#N the fold and d#N the detail in that priority order, so nothing in
    # the viewer mutates a tag's -elide. The priority rule still binds the
    # app's own tags: none laid over a turn (body/dk-*/find/sel/tbl) may set
    # an explicit -elide, or it would override the fold; all of them leave it
    # unset, which never does.
    #
    # What lives here is the app skin: the names the rest of the app and the
    # tests call (thin delegates), hover-copy invalidation on the mass
    # toggles and jumps, and the Turns/CurTurn read surface.

    # Folding the open turn folds to its region's end mark, which the endhint
    # sits inside while one stands: the hint elides with the body and returns
    # on expand. Accepted; a streamed append clears the hint before content
    # lands, so only the parked-with-hint case shows it.
    method turn_fold {n} { my fold $n }
    method turn_at {idx} { return [my region_at $idx] }
    method details_show {n} { my detail_show $n }
    method details_hide {n} { my detail_hide $n }

    # Both mass toggles drop the hover-copy button: the relayout slides new
    # text under the pointer, and a placed button would float over a message
    # it does not copy until the next Motion.
    method fold_all {} { my copy_hide; next }
    method expand_all {} { my copy_hide; next }

    # Every jump runs through the base class's reveal, which calls this first.
    # The jump is layout churn like any other: the scroll slides new text
    # under a pointer resting on the transcript (a find-entry Return jumps
    # without moving the mouse), and a placed copy button would float over a
    # message it does not name - so drop it first, the next Motion re-places
    # it.
    method on_reveal {idx} {
        my copy_hide
        next $idx
    }

    # Regenerate the Turns/CurTurn read surface from the base class's region
    # store (the read trace target; see the variable comment). Writes fire
    # no trace, so this cannot recurse.
    method turns_surface {args} {
        set out [list]
        set cur -1
        for {set n 0} {$n < [my region_count]} {incr n} {
            set info [my region_info $n]
            set p [dict get $info payload]
            if {[dict get $info open]} { set cur $n }
            lappend out [dict create id $n \
                line [dict get $p line] \
                hdr [dict get $info start] \
                body [$Text index "[dict get $info start] +1line linestart"] \
                end [expr {[dict get $info open] ? "" : [dict get $info end]}] \
                label [dict get $p label] ts [dict get $p ts] \
                folded [dict get $info folded] shown [dict get $info shown] \
                counts [dict get $p counts] stub [dict get $info summary]]
        }
        set Turns $out
        set CurTurn $cur
    }

    # The <<Copy>> filter: join the selection's *visible* characters
    # (-displaychars drops elided detail) across however many sel ranges
    # stand. What lands on the clipboard is what the reader saw.
    method copy_selection {} {
        set parts [list]
        foreach {a b} [$Text tag ranges sel] {
            lappend parts [$Text get -displaychars $a $b]
        }
        if {[llength $parts]} { my clipboard_set [join $parts "\n"] }
    }

    # ---- one-prompt resume (streamed) --------------------------------------

    # Summon the prompt bar at the viewer bottom and focus the entry. Mirrors
    # find_show; the permission chips sit just above the entry as it appears.
    method prompt_show {} {
        if {!$Shown} return
        pack $Prompt -side bottom -fill x
        focus $PromptEntry
    }

    # Fold the bar away. A no-op while a turn streams into this view, so the ✕
    # cannot drop the running indicator; navigating away detaches first, which
    # clears the guard.
    method prompt_hide {} {
        if {$Running && !$Detached} return
        pack forget $Prompt
    }

    method set_prompt_enabled {on} {
        set st [expr {$on ? "normal" : "disabled"}]
        $PromptEntry configure -state $st
        $PromptSend configure -state $st
        foreach val {readonly edits edits-git full} {
            $Prompt.opts.[string map {- _} $val] configure -state $st
        }
    }

    method prompt_status {msg} {
        if {[winfo exists $PromptStatus]} { $PromptStatus configure -text $msg }
    }

    # Launch one non-interactive `claude -p --resume` turn for the loaded
    # session and stream it back in. Refuses if a turn is already running here,
    # the prompt is empty, or the session is live in an interactive resume
    # elsewhere (which would write the same jsonl underneath us).
    method resume_submit {} {
        # One pipe at a time: a prior resume still draining (even detached, on
        # a session navigated away from) blocks a new one until it exits. Say
        # so - a Send that silently does nothing reads as a dead button.
        if {$Running} { my prompt_status "still streaming a previous resume"; return }
        if {$Path eq "" || $Uuid eq ""} return
        set prompt [string trim $PromptVar]
        if {$prompt eq ""} return
        if {[dict exists [::questlog::ui::live::running_uuids] $Uuid]} {
            my prompt_status "session is already running"
            return
        }
        set flags [::questlog::ui::terminal::permission_flags $PermVar]
        set inner [::questlog::ui::terminal::oneshot_command \
            $Cwd $Uuid $prompt $flags]
        if {[catch {open [list |bash -c "$inner 2>&1"] r} pipe]} {
            my prompt_status "launch failed: $pipe"
            return
        }
        set Pipe $pipe
        set Running 1
        set Detached 0
        set RunPath $Path
        set ErrBuf ""
        my clear_endhint
        chan configure $Pipe -blocking 0 -buffering line
        chan event $Pipe readable [list [self] resume_drain]
        my set_prompt_enabled 0
        my prompt_status "running…"
        set Tick [my later 300 [list [self] resume_tick]]
    }

    # Drain the pipe's merged output (kept for a failure message) and finish on
    # EOF. Non-blocking: a -1 while the channel is blocked just means no full
    # line yet, so wait for the next event.
    method resume_drain {} {
        if {$Pipe eq ""} return
        while {1} {
            set n [chan gets $Pipe line]
            if {$n >= 0} { append ErrBuf $line "\n"; continue }
            if {[chan blocked $Pipe]} return
            break
        }
        my resume_finish
    }

    # While streaming, tail the jsonl into the view on a short cadence so the
    # turn appears as it is written.
    method resume_tick {} {
        my append_new
        if {$Running && !$Detached} {
            set Tick [my later 300 [list [self] resume_tick]]
        } else {
            set Tick ""
        }
    }

    # The file-growth watch: one stat per tick against the open session's file,
    # so an external writer (a claude process outside questlog, a syncthing
    # replace) reaches the view without a switch away and back. Distinct from
    # resume_tick's 300 ms interactive cadence; while that pipe owns the tail
    # (Running, not Detached) this steps aside and only re-arms.
    method watch_tick {} {
        if {$Running && !$Detached} {
            set WatchTok [my later [::questlog::config::get viewer_watch_ms] \
                [list [self] watch_tick]]
            return
        }
        if {[catch {file size $Path} size]} {
            # The file may be mid-replace; a genuine deletion is the session
            # list's phantom sweep to notice, not this tick's. Just re-arm.
            set WatchTok [my later [::questlog::config::get viewer_watch_ms] \
                [list [self] watch_tick]]
            return
        }
        if {$size > $WatchSize} {
            # Growth: tail the new records. Advance the settled size first, so a
            # newline-less partial tail (append_new leaves it uncounted, growing
            # the size but yielding zero records) does not re-run every tick.
            # Only a nonzero append marks the catch-up index pass as owed.
            # A tick that only held a trailing turn start back renders nothing
            # and so appends nothing, but the quiescence branch still owes it a
            # release, so the hold marks the catch-up owed too.
            set WatchSize $size
            if {[my append_new] > 0 || [llength [my pending]]} { set WatchDirty 1 }
        } elseif {$size == $WatchSize && $WatchDirty} {
            # The file stopped growing, so a turn start held back at the tail is
            # settled: nothing further is coming to supersede it. Release it
            # before the index pass, so the indexes below see its turn.
            if {[llength [my pending]]} { my append_new }
            # Quiescence after growth: run the same catch-up pass resume_finish
            # runs, so the match/tool/quote/turn indexes and the endhint track
            # the appended records, and refresh the session's list row.
            my index_matches $Query
            my index_tool_calls
            my refresh_quote_control
            my index_turns
            my add_endhint
            if {$OnRefresh ne ""} { {*}$OnRefresh $Path }
            set WatchDirty 0
        } elseif {$size < $WatchSize} {
            # The file shrank: it was replaced or truncated (a sync). Reload it
            # under the reader, keeping the prompt bar and session identity.
            my reload
            set WatchSize $size
            set WatchDirty 0
        }
        set WatchTok [my later [::questlog::config::get viewer_watch_ms] \
            [list [self] watch_tick]]
    }

    # Re-read the open session's file after an external replace or truncate.
    # The document-path work of `show` without its session-switch resets, so
    # PromptVar, the prompt bar state, Uuid and Cwd survive a file swapped under
    # the reader. render begins by resetting the base class, so re-entry is safe;
    # the quote lists, RenderTs/RenderInSection and LineMap it also wipes need
    # no separate reset here. The scroll position is preserved across the swap.
    method reload {} {
        my copy_hide
        set yv [lindex [$Text yview] 0]
        my find_hide 0
        set Records [list]
        set LineMap [dict create]
        set LoadedLines 0
        my load
        my render
        my index_matches $Query
        my index_tool_calls
        my refresh_quote_control
        my index_turns
        my add_endhint
        $Text yview moveto $yv
    }

    # Stop rendering a running stream into this view without killing claude: the
    # turn finishes on disk and reloads on next open. The pipe keeps draining
    # (so claude is not blocked on a full stdout buffer) until EOF, when
    # resume_finish reaps it and refreshes the row.
    method resume_detach {} {
        if {!$Running || $Detached} return
        set Detached 1
        if {$Tick ne ""} { my forget $Tick; set Tick "" }
    }

    # The turn's process has closed its output. Reap it for the exit status, do
    # a final tail and bar reset unless detached to another view, and refresh
    # the streamed session's list row so its cost and activity catch up.
    method resume_finish {} {
        if {$Pipe eq ""} return
        if {$Tick ne ""} { my forget $Tick; set Tick "" }
        catch {chan event $Pipe readable {}}
        set status 0
        if {[catch {close $Pipe} err]} { set status 1; append ErrBuf $err "\n" }
        set Pipe ""
        set was_detached $Detached
        set rpath $RunPath
        set Running 0
        set Detached 0
        if {!$was_detached} {
            my append_new
            my index_matches $Query
            my index_tool_calls
            my refresh_quote_control
            my index_turns
            my add_endhint
            my set_prompt_enabled 1
            if {$status} {
                my prompt_status \
                    "claude error: [string range [string trim $ErrBuf] end-80 end]"
            } else {
                my prompt_status ""
                set PromptVar ""
            }
        }
        if {$OnRefresh ne "" && $rpath ne ""} {
            {*}$OnRefresh $rpath
        }
        # A detached finish frees the pipe for whichever session is shown now;
        # a "still streaming a previous resume" refusal may be standing in its
        # status, and leaving it there reads as a Send still refused.
        if {$was_detached} { my prompt_status "" }
    }

    # Insert the model chip on the current header line: a tinted run of a coloured
    # dot and a short "Family Ver" label. The family maps to a model-<fam>/
    # modeldot-<fam> tint pair (unknown/local ids fall to `other`); the label is
    # fmt_model's reading, or model_label's id fallback when fmt_model blanks a
    # local id. Every piece also carries the shared `modelchip` marker tag (no
    # appearance, no -elide) so index_matches/find_excerpt can skip the chip run.
    # The drafts note on a user header line: the message shown is the one the
    # user settled on, and this says how many earlier drafts it replaced. The
    # drafts themselves are not rendered anywhere, so this is the only trace
    # they leave. Carries the `editchip` marker so index_matches/find_excerpt
    # skip the run: a search for "edits" must not light every edited turn.
    method insert_edit_chip {n} {
        $Text insert [my door] "· $n edit[expr {$n == 1 ? {} : {s}}]  " editchip
    }

    method insert_model_chip {model} {
        set fam [::questlog::cost::model_family $model]
        set suf [expr {$fam ne "" ? $fam : "other"}]
        set label [::questlog::cost::fmt_model $model]
        if {$label eq ""} { set label [::questlog::cost::model_label $model] }
        $Text insert [my door] " "        [list modelchip model-$suf]
        $Text insert [my door] "●"   [list modelchip modeldot-$suf]
        $Text insert [my door] " $label " [list modelchip model-$suf]
        $Text insert [my door] "  "        modelchip
    }

    # tkdown's -on_block: index each assistant quote for the Quotes tab and
    # head it with the ⧉ copy glyph. ponytail: a bare index (not a Tk mark),
    # the same assumption LineMap makes - the transcript only appends at end
    # or wholesale-reloads, never splices mid-way; move both to marks
    # together if that ever changes.
    method on_block {kind start end text} {
        if {$kind ne "quote"} return
        set at [$Text index $start]
        lappend QuoteIdx $at
        lappend QuoteBodies $text
        $QuoteList insert end "[my tool_time $CurTs] · [my quote_preview $text]"
        $QuoteList itemconfigure end -foreground [::questlog::ui::theme::c assistant]
        $Text insert $at "⧉ " {qcopy quote}
    }

    # Copy a quote's raw de-quoted text when its ⧉ glyph is clicked. A
    # drag-select that merely releases over the glyph must not copy, so bail
    # while a selection stands. The glyph sits on the quote's first line, whose
    # start is exactly the index recorded in QuoteIdx, so the click's line start
    # picks out which quote to copy.
    method quote_copy_at {x y} {
        if {[$Text tag ranges sel] ne ""} return
        set i [lsearch -exact $QuoteIdx [$Text index "@$x,$y linestart"]]
        if {$i < 0} return
        my clipboard_set [lindex $QuoteBodies $i]
    }

    # Seat the insert mark on the first visible line when it has drifted out of
    # view, which a render, a wheel scroll or a find jump all leave it. A mark
    # still on screen is where the previous keystroke put it, so it stays: that
    # is what lets a run of arrow presses walk instead of resetting each time.
    method park_cursor {} {
        if {[$Text bbox insert] eq ""} { $Text mark set insert @0,0 }
    }

    method build_menu {} {
        set Menu $Top.cmenu
        menu $Menu -tearoff 0
        $Menu add command -label "Copy message" \
            -command [list [self] menu_copy_message]
    }

    method clipboard_set {s} { clipboard clear; clipboard append $s }

    # Right-click a turn to copy its whole body. The explicit copy affordance
    # for the viewer (issue #4); per-quote copy is the ⧉ glyph heading each
    # quote block.
    method on_right {x y X Y} {
        set line [my line_at [$Text index @$x,$y]]
        if {$line eq ""} return
        set MenuTarget [dict create line $line]
        tk_popup $Menu $X $Y
    }

    method menu_copy_message {} {
        if {![dict exists $MenuTarget line]} return
        set line [dict get $MenuTarget line]
        if {[dict exists $Bodies $line]} {
            my clipboard_set [dict get $Bodies $line]
        }
    }

    # The jsonl line whose rendered body holds a text index: the mapped
    # anchor with the greatest index at or before idx.
    method line_at {idx} {
        set best ""
        set bestpos ""
        dict for {lineno pos} $LineMap {
            # Only messages that rendered a text body can be copied; empty
            # records (e.g. tool-only turns) get an anchor but no Bodies entry.
            if {![dict exists $Bodies $lineno]} continue
            if {[$Text compare $pos <= $idx]} {
                if {$bestpos eq "" || [$Text compare $pos > $bestpos]} {
                    set best $lineno
                    set bestpos $pos
                }
            }
        }
        return $best
    }

    # ---- hover copy button -------------------------------------------------
    #
    # The shared ⧉ button (built once in build) rides the top-right of whatever
    # user/assistant message the pointer is over, the discoverable twin of the
    # right-click "Copy message" and the quote glyph. It copies Bodies($line) -
    # the record's raw extract_text, the whole message regardless of fold or
    # detail state - deliberately unlike copy_selection, which is filtered to the
    # reader's visible characters. Tool-result and system records get no button
    # (the role gate below), matching neither being prose a reader means to lift.

    # The pointer moved over the transcript at widget-local x,y. A cheap gate
    # first: while the pointer stays within the cached message's text-line span
    # the button is already in the right place, so do nothing (no re-place per
    # pixel). Otherwise resolve the message under the pointer and place the
    # button only over a user or assistant one. The end-of-session hint is chrome
    # below the content (content_end), not a message, so it takes no button;
    # neither does a spot that resolves to no bodied line (a section header or
    # divider between turns, where line_at finds nothing at or above it).
    method copy_motion {x y} {
        set idx [$Text index @$x,$y]
        set line [lindex [split $idx .] 0]
        if {$CopyLine ne "" && $line >= $CopyFirst && $line < $CopyLast} return
        set ce [my content_end]
        if {$ce ne "end" && [$Text compare $idx >= $ce]} { my copy_hide; return }
        set ml [my line_at $idx]
        if {$ml eq ""} { my copy_hide; return }
        if {[dict getdef $Roles $ml ""] ni {USER ASSISTANT}} { my copy_hide; return }
        # The message spans from its own anchor to the next bodied record's
        # anchor - its own detail blocks render in between, under the same
        # record - or the content boundary for the last message. The span is
        # cached in text-line numbers for the Motion gate above.
        set start [dict get $LineMap $ml]
        set end [my next_body_index $start]
        set CopyLine $ml
        set CopyFirst [lindex [split [$Text index $start] .] 0]
        set CopyLast  [lindex [split [$Text index $end] .] 0]
        my copy_place $start
    }

    # The text index of the message following the one anchored at $start: the
    # nearest LineMap anchor strictly after it, else the content boundary (before
    # the endhint, or the transcript end when no hint stands).
    method next_body_index {start} {
        set best ""
        dict for {lineno pos} $LineMap {
            if {[$Text compare $pos > $start]} {
                if {$best eq "" || [$Text compare $pos < $best]} { set best $pos }
            }
        }
        if {$best ne ""} { return $best }
        set ce [my content_end]
        return [expr {$ce eq "end" ? [$Text index end] : $ce}]
    }

    # Place the button with its north-east corner 8px in from the right edge,
    # aligned to the top of the message's first line when that line is on screen.
    # When the reader has scrolled past the head of a long message that line's
    # bbox is empty, so ride the viewport's top edge instead - the button stays
    # visible at the top of the message it copies.
    method copy_place {start} {
        set bb [$Text bbox $start]
        set y [expr {$bb ne "" ? [lindex $bb 1] : 2}]
        place $CopyBtn -in $Text -relx 1.0 -x -8 -y $y -anchor ne
    }

    method copy_hide {} {
        if {$CopyLine eq ""} return
        place forget $CopyBtn
        set CopyLine ""
        set CopyFirst 0
        set CopyLast 0
        # A hidden button holds no acknowledgement: cancel a pending ✓ restore
        # and put the glyph back, or the next hover (a session switch away)
        # opens on a stale check mark.
        if {$CopyFbTok ne ""} { my forget $CopyFbTok; set CopyFbTok "" }
        $CopyBtn configure -text "⧉"
    }

    # Leaving the transcript hides the button - but crossing onto the button
    # itself also fires $Text <Leave> (a parent-to-child boundary crossing), so
    # defer the decision to idle and keep the button when the pointer settled on
    # it. A miniature of the overlay_check the quote boxes once carried.
    method copy_leave {} { my later idle [list [self] copy_leave_check] }
    method copy_leave_check {} {
        if {$CopyLine eq "" || ![winfo exists $CopyBtn]} return
        if {[winfo containing {*}[winfo pointerxy $CopyBtn]] eq $CopyBtn} return
        my copy_hide
    }

    # The button's action: copy the cached message's whole body. Bodies is the
    # record's raw extract_text - the full message, hidden detail included -
    # unlike the visibility-filtered copy_selection. A brief ✓ acknowledges the
    # copy, then the glyph returns; the button is a real widget, not text in the
    # transcript, so this flip splices no bare index.
    method copy_hovered {} {
        if {$CopyLine eq "" || ![dict exists $Bodies $CopyLine]} return
        my clipboard_set [dict get $Bodies $CopyLine]
        if {$CopyFbTok ne ""} { my forget $CopyFbTok }
        $CopyBtn configure -text "✓"
        set CopyFbTok [my later 700 [list [self] copy_feedback_reset]]
    }
    method copy_feedback_reset {} {
        set CopyFbTok ""
        if {[winfo exists $CopyBtn]} { $CopyBtn configure -text "⧉" }
    }

    # Scroll the reading view to a jsonl line. A directly mapped line (a turn
    # that rendered a text body) is shown as-is. A line with no anchor falls
    # back to the nearest mapped line at or before it: tool-use-only turns
    # render no prose and so get no LineMap entry, yet a tool-call timeline row
    # must still land the reader on the turn that issued it, which is the turn
    # whose body precedes the call in the transcript.
    method scroll_to_line {lineno} {
        if {[dict exists $LineMap $lineno]} {
            ::questlog::debug::log scroll "want $lineno exact hit"
            my reveal [dict get $LineMap $lineno]
            return
        }
        set best ""
        set bestln -1
        dict for {ln idx} $LineMap {
            if {$ln <= $lineno && $ln > $bestln} {
                set bestln $ln
                set best $idx
            }
        }
        ::questlog::debug::log scroll \
            "want $lineno no exact entry, nearest preceding=$bestln found=[expr {$best ne ""}]"
        if {$best ne ""} { my reveal $best }
    }

    method place_find {frame} { pack $frame -side bottom -fill x }

    method find_show {} {
        if {!$Shown} return
        next
    }

    method find_hide {{restore 1}} {
        next
        # Closing the overlay ends the transient Ctrl-F term. A term other than
        # the opening search retargets all three readers while it is live (issue
        # #51); once it is gone the two persistent readers - the Matches band and
        # the head-strip count - return to the session's own search set, so the
        # accepted costs of a retarget hold only while a different term is live.
        # Re-applying the opening query is the one act that refills them both. The
        # load path passes restore 0: it clears leftover find state before it
        # renders and re-indexes the new session itself.
        if {$restore} { my index_matches $Query }
    }

    # The base class's find hooks. On a recollect: a term other than the one
    # the band shows collected a different population, so retarget all three
    # readers on it (issue #51). Refilling the Matches band rows and the
    # head-strip count from the recollected set makes the band's rows the
    # live set, so select_band_row's exact-set gate then passes and its
    # highlight tracks the step. An identical set (a first Next on the search
    # term already shown) leaves the band untouched, keeping its rarest-first
    # order and open state. On a step: move the band highlight with it.
    method on_find_collected {} {
        if {$FindMatches ne $BandMatchSet} { my refill_match_band }
    }
    method on_find_stepped {i} { my select_band_row $i }

    # Move the docked match band's highlight to the hit we stepped to. Act only
    # when the band's rows are the very set we are stepping: a Ctrl-F retarget
    # refills the band from the recollected set before stepping (find_next), so
    # the gate normally passes and the highlight tracks. It stays as a guard for
    # any moment the band's rows (BandMatchSet, recorded by refresh_match_control)
    # and FindMatches fall out of step, when moving the selection would land the
    # highlight on an unrelated row. The selection is set
    # programmatically, which does not fire <<ListboxSelect>>, so a band click
    # still drives one jump and stepping still moves the highlight once, with no
    # feedback loop between the two.
    method select_band_row {i} {
        if {$FindMatches ne $BandMatchSet} return
        if {$i < 0 || $i >= [llength $FindMatches]} return
        $MatchList selection clear 0 end
        $MatchList selection set $i
        $MatchList see $i
    }

    # The base skips stub and fold-glyph hits; the chip's words ("Opus",
    # "Sonnet", version digits) are equally chrome, not transcript - a search
    # for a family word or version number must never light every chip.
    method find_chrome_tags {} { return [list stub foldglyph modelchip editchip] }

    # Re-fill the Matches band and the head-strip count from the current
    # FindMatches (a Ctrl-F recollect, not a search): rebuild the parallel
    # per-match excerpts in document order, then hand to refresh_match_control,
    # which records the band's set (BandMatchSet), fills the rows and sizes the
    # count. An empty set collapses the band and hides the count, so the readers
    # follow a term that matched nothing as faithfully as one that matched.
    method refill_match_band {} {
        set MatchLabels [list]
        foreach m $FindMatches { lappend MatchLabels [my find_excerpt $m] }
        my refresh_match_control
    }

    # ---- match index (seeded from the search query) ------------------

    # Highlight every literal occurrence of the search terms in the rendered
    # transcript, remember them ordered rarest-keyword-first (one hit of each
    # term before any term repeats), and open the band on its match index. Terms
    # are matched literally (the search bar is Google-style, not
    # regex; the toolbar's pattern row is the separate regex restriction and is
    # not highlighted here). An empty query (a session opened while browsing)
    # clears the highlight and hides the index. Shares the `find` tag and
    # FindMatches/FindCur with the Ctrl-F overlay, so stepping is unified.
    method index_matches {query} {
        $Text tag remove find 1.0 end
        ::tkdown::table_spotlight $Text ""
        set FindMatches [list]
        set FindCur -1
        set MatchLabels [list]
        set terms [expr {[dict exists $query terms] ? [dict get $query terms] : {}}]
        set nocase [expr {[dict exists $query nocase] ? [dict get $query nocase] : 0}]

        # Collect each distinct term's occurrences in document order, table
        # hits included. A term repeated in the query is counted once.
        set per_term [list]
        set seen_terms [dict create]
        foreach term $terms {
            if {$term eq ""} continue
            if {[dict exists $seen_terms $term]} continue
            dict set seen_terms $term 1
            set positions [my collect $term $nocase]
            if {[llength $positions] > 0} { lappend per_term $positions }
            if {[::questlog::debug::enabled]} {
                ::questlog::debug::log index \
                    "term=[list $term] occurrences=[llength $positions]"
            }
        }

        # Order terms rarest-first (fewest occurrences, ties broken by the
        # earlier first occurrence), then interleave round-robin so every term
        # is represented once before any repeats. A distinctive low-frequency
        # term thus leads the index instead of being buried under a common one.
        set ordered [lsort -command [list [self] cmp_term_rarity] $per_term]
        foreach m [::questlog::ui::rarity_round_robin $ordered] {
            lappend FindMatches $m
            lappend MatchLabels [my find_excerpt $m]
        }
        if {[::questlog::debug::enabled]} {
            ::questlog::debug::log index "terms=[llength $terms]\
                matched_terms=[llength $per_term] total_matches=[llength $FindMatches]"
        }
        # The set was just (re)built: nothing is shown yet, so FindCur stays at
        # its reset -1. refresh_match_control (through refresh_band_control)
        # pre-selects band row 0 and the readout anticipates "1 of M"; the first
        # Next then surfaces hit 0 to match.
        my refresh_match_control
        my update_find_readout
    }

    # lsort comparator over per-term position lists: fewer occurrences first,
    # ties broken by the earlier first occurrence in the document.
    method cmp_term_rarity {a b} {
        set la [llength $a]
        set lb [llength $b]
        if {$la != $lb} { return [expr {$la < $lb ? -1 : 1}] }
        return [my cmp_index [lindex $a 0] [lindex $b 0]]
    }

    # A one-line, whitespace-collapsed excerpt of the match's line, for the
    # match index row.
    method find_excerpt {idx} {
        # A find_extra hit (a table's cell, a link's url) excerpts from the
        # text it recorded: a table's index holds only its window char.
        if {[dict exists $FindExcerpt [$Text index $idx]]} {
            set line [next $idx]
        } else {
            # A hit on a record's first line would excerpt the role label too,
            # and the row already leads with the role - "ASSISTANT ·
            # ...ASSISTANT Write(" read twice. Start the excerpt where the
            # content does: past the fold glyph and the label, when the line
            # opens with them. modelchip trails the role label on an assistant
            # header line, and editchip does the same on a user one, so both
            # are skipped after the lbl-* tags: each pass advances $s past a
            # chrome run that starts exactly where the previous one left off.
            set s [$Text index "$idx linestart"]
            foreach chrome {foldglyph lbl-user lbl-assistant lbl-system
                            lbl-tool_result modelchip editchip} {
                set r [$Text tag nextrange $chrome $s "$s lineend"]
                if {[llength $r] && [$Text compare [lindex $r 0] == $s]} {
                    set s [lindex $r 1]
                }
            }
            set line [$Text get $s "$s lineend"]
        }
        set line [regsub -all {\s+} [string trim $line] " "]
        if {[string length $line] > 60} { set line "[string range $line 0 59]…" }
        return $line
    }

    # Fill the match listbox from the current matches (coloured by role), then
    # hand off to refresh_band_control, which sizes the count and -- matches being
    # the one auto-opening tab -- opens the band on Matches. With no matches (a
    # session opened while browsing) the count is hidden and the band, if it was
    # showing matches, collapses. Auto-opening on every populate is what lands a
    # session click on the index when a search is active, with no second gesture.
    method refresh_match_control {} {
        $MatchList delete 0 end
        # Record exactly which match set these rows were built from, so
        # select_band_row can tell when a later Ctrl-F recollect has left the band
        # showing a stale population and skip moving the highlight then.
        set BandMatchSet $FindMatches
        set i 0
        foreach m $FindMatches lab $MatchLabels {
            set ln [my line_at $m]
            set ty [expr {[dict exists $Roles $ln] ? [dict get $Roles $ln] : ""}]
            if {[::questlog::debug::enabled]} {
                ::questlog::debug::log match \
                    "row $i at $m resolved line=[list $ln] role=[list $ty]"
            }
            set tail [expr {$ln eq "" ? "" : " · line $ln"}]
            $MatchList insert end "$ty · …$lab…$tail"
            $MatchList itemconfigure $i -foreground [my role_color $ty]
            incr i
        }
        my refresh_band_control matches [llength $FindMatches]
    }

    # Row foreground by role, echoing the rendered transcript's role colours.
    method role_color {ty} {
        switch -- $ty {
            USER          { return [::questlog::ui::theme::c user] }
            ASSISTANT     { return [::questlog::ui::theme::c assistant] }
            "TOOL RESULT" { return [::questlog::ui::theme::c tool_result] }
            default       { return [::questlog::ui::theme::c tool] }
        }
    }

    # ---- docked band: open/collapse and tab switching --------------------

    # Switch the band's content without changing its open/collapsed state: grid
    # the chosen list into the content cell and remove the rest; the active
    # list's rows set the band's requested height, the first-open sash
    # position. Re-derives the tab styling and the
    # head-strip glyphs. Loop-driven off BandDesc: every tab is one dict entry
    # carrying its {tab btn list sb count unit auto onselect} descriptor, so a new
    # tab needs no new branch here (nor in update_band_tabs/update_band_glyphs).
    method set_tab {tab} {
        set BandTab $tab
        dict for {key d} $BandDesc {
            grid remove [dict get $d list] [dict get $d sb]
        }
        set d [dict get $BandDesc $tab]
        grid [dict get $d list] -row 1 -column 0 -sticky nsew
        grid [dict get $d sb]   -row 1 -column 1 -sticky ns
        # The fold-all/expand-all pair belongs to the Turns tab alone; re-pack it
        # left of the ✕ there (the close stays packed, so -side right lands the
        # bar just inside it) and forget it on every other tab.
        pack forget $FoldBar
        if {$tab eq "turns"} { pack $FoldBar -side right -padx 8 }
        my update_band_tabs
        my update_band_glyphs
    }

    # Open the band on the given tab: insert it as the pane above the
    # transcript. The sash placement is deferred to idle (the pane has no
    # laid-out height inside this call); a band already open only switches
    # tabs, so a search refresh never moves a sash the user has dragged.
    method band_show {tab} {
        if {!$BandOpen} {
            set BandOpen 1
            $Top.body insert 0 $Band -weight 0
            my later idle [list [self] band_place_sash]
        }
        my set_tab $tab
    }

    # Collapse the band: forgetting the pane gives every pixel back to the
    # transcript. The band's pixel height is remembered for the reopen - an
    # absolute height, unlike the sidebar fold's fraction (app.tcl), because
    # the body's own height moves as the band pane comes and goes (the
    # toplevel re-requests around it), and a fraction captured and restored
    # against those two different heights drifts the sash.
    method band_hide {} {
        if {$BandOpen && [$Top.body sashpos 0] > 0} {
            set BandSash [$Top.body sashpos 0]
        }
        set BandOpen 0
        $Top.body forget $Band
        my update_band_glyphs
    }

    # Place the band/transcript sash once the paned window has laid the band
    # out (deferred from band_show): back at the remembered height, or at
    # the band's requested height (header + list rows) on the run's first
    # open. Guarded like app.tcl's restore_sash, so a hide that lands before
    # the idle fires leaves it a no-op.
    method band_place_sash {} {
        if {!$BandOpen} return
        if {[winfo height $Top.body] <= 1} return
        if {$BandSash ne ""} {
            $Top.body sashpos 0 $BandSash
        } else {
            $Top.body sashpos 0 [winfo reqheight $Band]
        }
    }

    # The head-strip counts route here. Clicking the count of the tab already
    # open collapses the band; clicking the other count swaps the front tab and
    # leaves it open; otherwise open on that tab.
    method band_toggle {tab} {
        if {$BandOpen && $BandTab eq $tab} {
            my band_hide
        } elseif {$BandOpen} {
            my set_tab $tab
        } else {
            my band_show $tab
        }
    }

    # Show only the tabs whose list has rows, mark the active one, and carry the
    # active tab's count in the band header. Forget them all first, then re-pack
    # the present ones in canonical BandDesc order, so a tab that was hidden for
    # the prior session never re-packs after its sibling. A tab has rows exactly
    # when its descriptor count is non-empty (refresh_band_control sets count ""
    # for an empty list), so that one field drives visibility.
    method update_band_tabs {} {
        set active   [::questlog::ui::theme::c sessionhead]
        set inactive [::questlog::ui::theme::c faint]
        dict for {key d} $BandDesc {
            pack forget [dict get $d tab]
        }
        set first 1
        dict for {key d} $BandDesc {
            if {[dict get $d count] eq ""} continue
            set lab [dict get $d tab]
            pack $lab -side left -padx [expr {$first ? "0" : "10 0"}]
            set first 0
            $lab configure \
                -foreground [expr {$BandTab eq $key ? $active : $inactive}]
        }
        $BandCount configure -text [dict get $BandDesc $BandTab count]
    }

    # Keep the ▾/▴ glyph on each head-strip count: ▴ on the count whose tab is the
    # open front tab, ▾ otherwise. Each count may be unpacked (its list is empty),
    # so skip a tab whose descriptor count is "" rather than touch a stub label.
    method update_band_glyphs {} {
        dict for {key d} $BandDesc {
            set count [dict get $d count]
            if {$count eq ""} continue
            set glyph [expr {$BandOpen && $BandTab eq $key ? "▴" : "▾"}]
            [dict get $d btn] configure -text "$glyph $count"
        }
    }

    # The shared tail of every refresh_*_control: given a tab key and its row
    # count n (its listbox already filled by the caller), size and expose the tab
    # or hide it. Empty (n == 0): forget the head count, clear the descriptor
    # count, collapse the band if this very tab was the open front tab, and re-run
    # update_band_tabs so the header drops the tab. Non-empty: size the listbox to
    # min(n, 8) rows, set the count string from the unit words, and reserve the
    # count's width on the right of the strip before the path re-packs to fill the
    # rest (so a long file path clips rather than squeezing the count out; the
    # re-pack fixes the order regardless of which packed first). The one behaviour
    # that varies by tab is auto: the matches tab (auto 1) pre-selects its first
    # row and auto-opens the band on itself, which is what lands a session click on
    # the index after a search; the opt-in tabs (auto 0) only refresh the header
    # and glyphs, leaving the band as it was.
    method refresh_band_control {key n} {
        set d    [dict get $BandDesc $key]
        set btn  [dict get $d btn]
        set lb   [dict get $d list]
        set auto [dict get $d auto]
        if {$n == 0} {
            pack forget $btn
            dict set BandDesc $key count ""
            if {$BandOpen && $BandTab eq $key} { my band_hide }
            my update_band_tabs
            return
        }
        $lb configure -height [expr {min($n, 8)}]
        $lb selection clear 0 end
        if {$auto} { $lb selection set 0 }
        set unit [dict get $d unit]
        dict set BandDesc $key count "$n [lindex $unit [expr {$n == 1 ? 0 : 1}]]"
        pack forget $PathLabel
        pack $btn -side right -padx 6
        pack $PathLabel -side left -padx 6 -pady 1 -fill x -expand 1
        if {$auto} {
            my band_show $key
        } else {
            my update_band_tabs
            my update_band_glyphs
        }
    }

    # Jump from a clicked row.
    method match_list_select {} {
        set sel [$MatchList curselection]
        if {$sel eq ""} return
        my jump_to_match [lindex $sel 0]
    }

    method jump_to_match {i} {
        if {$i < 0 || $i >= [llength $FindMatches]} return
        my reveal [lindex $FindMatches $i]
        # A band click (or a direct jump) lands ON hit i: mark it current, keep
        # the band highlight on it, and refresh the readout. Setting the selection
        # programmatically does not re-fire <<ListboxSelect>>, so this does not
        # loop back through match_list_select.
        set FindCur $i
        my select_band_row $i
        my update_find_readout
    }

    # ---- tool-call timeline (the did-versus-claimed audit, issue #15) ----

    # Walk the loaded Records in document order, collect every assistant
    # tool_use block as one timeline row "time · tool · path", and fill the
    # head-strip count. Records are already in chronological order, so the
    # walk needs no sort. Each row remembers its record's jsonl line and the
    # call's ordinal within the record (in ToolLines, parallel to the listbox
    # rows) so a click jumps the reading view to that call. With no tool calls
    # both the band's Tools tab and the head count stay hidden.
    method index_tool_calls {} {
        set ToolLines [list]
        $ToolList delete 0 end
        foreach rec $Records {
            set lineno [dict get $rec _line]
            set when [my tool_time [::logman::record_timestamp $rec]]
            set k 0
            foreach use [::logman::record_tool_uses $rec] {
                set name [dict get $use name]
                set path [dict get $use path]
                set row "$when · $name"
                if {$path ne ""} { append row " · $path" }
                $ToolList insert end $row
                $ToolList itemconfigure end -foreground [::questlog::ui::theme::c tool]
                lappend ToolLines [list $lineno $k]
                incr k
            }
        }
        my refresh_tool_control
    }

    # A record timestamp as a short local clock time for a timeline row. Seconds
    # are kept (unlike the section header's %H:%M) so calls within the same
    # minute stay distinguishable in order. Empty stamp renders as a placeholder
    # rather than a misleading time.
    method tool_time {ts_iso} {
        set epoch [my parse_iso $ts_iso]
        if {$epoch == 0} { return "--:--:--" }
        return [clock format $epoch -format "%H:%M:%S"]
    }

    # Expose the Tools entry point from the collected calls (index_tool_calls has
    # already filled the rows). Opt-in, not auto (descriptor auto is 0): with
    # calls this makes the Tools tab and count available but leaves the band as it
    # was, so the matches that index_matches auto-opened (it runs first) stay in
    # front; with no calls the count is hidden and a band already on Tools
    # collapses. All that lives in refresh_band_control.
    method refresh_tool_control {} {
        my refresh_band_control tools [llength $ToolLines]
    }

    # Jump to the clicked call's own line and put it on the top edge. The call
    # sits in its turn's hidden detail, so the reveal opens that detail; topping
    # the view keeps the call off the bottom edge where a least-scroll stops
    # when the view comes from below, under the earlier detail just uncovered.
    method tool_list_select {} {
        set sel [$ToolList curselection]
        if {$sel eq ""} return
        lassign [lindex $ToolLines [lindex $sel 0]] lineno k
        set call [my tool_use_index $lineno $k]
        if {$call eq ""} { my scroll_to_line $lineno; return }
        my reveal $call top
    }

    # ---- quote index (jump to an assistant's quoted passage) --------------

    # A one-line label for a quote row: the first non-empty de-quoted line,
    # whitespace-collapsed and clipped, so a draft's opening reads in the list.
    method quote_preview {dequoted} {
        foreach ln [split $dequoted "\n"] {
            set ln [regsub -all {\s+} [string trim $ln] " "]
            if {$ln ne ""} {
                return [expr {[string length $ln] > 60 \
                    ? "[string range $ln 0 59]…" : $ln}]
            }
        }
        return "(quote)"
    }

    # Expose the head-strip count from the quotes collected during render (their
    # rows were filled by on_block). Opt-in like the tool audit (auto 0):
    # it never opens the band, only makes the Quotes tab and count available; with
    # no quotes both stay hidden. refresh_band_control does the work.
    method refresh_quote_control {} {
        my refresh_band_control quotes [llength $QuoteIdx]
    }

    # Jump the reading view to the clicked quote's box.
    method quote_list_select {} {
        set sel [$QuoteList curselection]
        if {$sel eq ""} return
        my reveal [lindex $QuoteIdx [lindex $sel 0]]
    }

    # ---- turns index (jump to a turn's header) ----------------------------

    # Fill the Turns listbox from the base class's region store, one row per turn
    # "N · time · first prompt line" coloured like a user label (a turn opens
    # on a user prompt). N is the turn's 1-based number, so a reader can jump
    # to "turn 12" by the number they'd say aloud. The label was captured at
    # region_open (the prompt's first line, in the payload); collapse its
    # whitespace and clip it the way the
    # match and quote rows clip, so a long or ragged opening still reads as one
    # tidy row. Called from show and, after a streamed turn lands, from
    # resume_finish - the store is the one source of truth, so a refill always
    # tracks region_count. Unlike the quote rows (appended live during render)
    # turn rows are not maintained incrementally, so this rebuilds them
    # wholesale.
    method index_turns {} {
        $TurnList delete 0 end
        for {set n 0} {$n < [my region_count]} {incr n} {
            set p [my payload $n]
            set label [regsub -all {\s+} [string trim [dict get $p label]] " "]
            if {[string length $label] > 60} {
                set label "[string range $label 0 59]…"
            }
            $TurnList insert end \
                "[expr {$n + 1}] · [my tool_time [dict get $p ts]] · $label"
            $TurnList itemconfigure end -foreground [::questlog::ui::theme::c user]
        }
        my refresh_turn_control
    }

    # Expose the head-strip Turns count from the region store (index_turns
    # has filled the rows). Opt-in like the tool and quote audits (descriptor
    # auto is 0): it makes the Turns tab and count available but never opens
    # the band on its own - the Turns index is reached for, not surfaced by a
    # session click. With no turns the count is hidden and a band already on
    # Turns collapses; refresh_band_control does the work.
    method refresh_turn_control {} {
        my refresh_band_control turns [my region_count]
    }

    # Jump the reading view to a clicked turn's header. A header line is never
    # elided (the fold hides from the body down, keeping the header as the
    # fold's visible handle), so the reveal here only unfolds a folded target
    # and scrolls - it spills no detail. The jump still routes through
    # reveal rather than a bare `see`, because that one-gate rule is the
    # whole discipline: every transcript jump lands through the primitive that
    # knows how to make an elided target visible, even where this particular
    # target can never be elided.
    method turn_list_select {} {
        set sel [$TurnList curselection]
        if {$sel eq ""} return
        my reveal [dict get [my region_info [lindex $sel 0]] start]
    }
}
