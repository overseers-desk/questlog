package require Tcl 9
package require Tk
package require tkdown

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
#   secondary: idle gaps over IdleGap minutes.
# Recap markers (long assistant turn after an idle gap) are tertiary cues
# and not dividers.
#
# Search-within: Ctrl-F focuses an entry; Return advances to the next match.

oo::class create ::questlog::ui::Viewer {
    mixin leash
    variable Top
    variable Empty            ;# centered empty-state frame, shown until first load
    variable Shown            ;# 0 until the first session replaces the empty state
    variable Path
    variable Records
    variable Sections        ;# list of dicts: {kind label start_idx end_idx}
    variable Text             ;# the text widget
    variable PathLabel        ;# header label showing the loaded session's cwd
    variable IdLabel          ;# header label showing the abbreviated session id
    variable ActionMenu       ;# the "⋯" head-strip menu (Font, and Stage 2 actions)
    variable Uuid             ;# loaded session's uuid (basename of the jsonl)
    variable Cwd              ;# loaded session's working directory (first_cwd)
    variable CwdFull          ;# full ~-collapsed cwd string, kept for re-elision on resize
    variable Find             ;# find overlay frame
    variable FindVar
    variable FindMatches      ;# list of indices of all current matches
    variable FindIdx
    variable IdleGap          ;# minutes
    variable LineMap          ;# dict: jsonl line offset (1-based) -> text index
    variable Menu             ;# right-click context menu
    variable MenuTarget       ;# dict capturing the clicked target
    variable Bodies           ;# dict: jsonl line -> raw body (for Copy message)
    variable TurnList         ;# listbox of per-turn rows (alias of BandDesc turns list)
    variable MatchList        ;# listbox of per-match rows (alias of BandDesc matches list)
    variable MatchLabels      ;# per-match one-line excerpt, parallel to FindMatches
    variable ToolList         ;# listbox of per-call rows (alias of BandDesc tools list)
    variable ToolLines        ;# jsonl line of each call, parallel to the ToolList rows
    variable QuoteList        ;# listbox of per-quote rows (alias of BandDesc quotes list)
    variable QuoteIdx         ;# text index of each quote block, parallel to QuoteList rows
    variable QuoteBodies      ;# raw de-quoted text of each quote, parallel to QuoteIdx (for copy)
    variable CurTs            ;# ISO stamp of the record being rendered, read for a quote row
    variable Roles            ;# dict: jsonl line -> uppercased role, for row colour
    # The turn registry: one dict per turn in document order,
    #   {id line hdr body end label ts folded shown counts stub}
    # where line is the turn-start record's jsonl line, hdr/body/end/stub are
    # bare text indices (hdr the header line, body the fold-range start, end ""
    # while the turn is open, stub "" while the turn has no detail blocks),
    # label/ts feed the future Turns tab, folded/shown are the fold and
    # details-visible states, and counts is the per-kind detail tally the stub
    # line prints. Bare indices ride the same append-only invariant LineMap
    # and QuoteIdx rely on.
    variable Turns
    variable CurTurn          ;# index into Turns of the open turn, -1 outside one
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
    # switches between the match index and the tool-call timeline. It replaces the
    # two floating panels that used to cover the reading view.
    variable Band             ;# the band frame, gridded in the body's row 0
    variable BandTab          ;# "matches"|"tools"|"quotes": which list the band shows
    variable BandOpen         ;# 1 while the band is gridded (taking transcript height)
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
    variable RenderTs         ;# trailing render state: epoch of the last content turn, carried into append_new
    variable RenderInSection  ;# trailing render state: 1 while a section header is open
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
    variable Running          ;# 1 while a streamed turn renders into the current view
    variable Detached         ;# 1 when the user navigated away mid-stream (drain only, do not render)
    variable RunPath          ;# the jsonl the running turn targets, for the row refresh
    variable ErrBuf           ;# merged stdout+stderr of the running turn, shown on failure

    constructor {parent {on_toggle ""} {on_move ""} {on_bookmark ""} {on_rename ""} {on_refresh ""}} {
        set Top $parent
        set Shown 0
        set Path ""
        set IdleGap [::questlog::config::get viewer_idle_gap_min]
        set FindVar ""
        set FindMatches [list]
        set FindIdx 0
        set Records [list]
        set Sections [list]
        set LineMap [dict create]
        set MenuTarget [dict create]
        set Bodies [dict create]
        set MatchLabels [list]
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
        set RenderTs 0
        set RenderInSection 0
        set PromptVar ""
        set PermVar readonly
        set Pipe ""
        set Tick ""
        set Running 0
        set Detached 0
        set RunPath ""
        set ErrBuf ""
        my build
    }

    # Load a session and anchor to a line (1-based; 0 means top). Replaces
    # whatever was shown before. `query` is the active search ({terms <list>
    # nocase 0|1}, or {}); its terms are matched literally, highlighted, and
    # listed in the docked match index band.
    method show {jsonl_path {scroll_to_line 0} {query {}}} {
        # Leaving a session mid-stream detaches its turn (it finishes on disk and
        # reloads on next open) and folds the prompt bar away, like find_hide.
        # The bar is reset for the new session; a detached run no longer touches
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
            grid $Text        -row 1 -column 0 -sticky nsew
            grid $Top.body.sb -row 1 -column 1 -sticky ns
            set Shown 1
        }
        set Path $jsonl_path
        set Query $query
        set Records [list]
        set LineMap [dict create]
        set LoadedLines 0
        set Uuid [file rootname [file tail $Path]]
        set Cwd [::questlog::jsonl::first_cwd $Path]
        # Show the working directory the session ran in (it survives a move,
        # unlike the encoded project folder the jsonl sits under). Fall back to
        # the jsonl's own directory when the file records no cwd.
        set shown_dir [expr {$Cwd ne "" ? $Cwd : [file dirname $Path]}]
        set CwdFull [::questlog::path::pretty_home $shown_dir]
        my elide_cwd
        $IdLabel configure -text \
            "[string range $Uuid 0 3]…[string range $Uuid end-3 end]"
        my find_hide
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
        label $Top.head.path -text "no session selected" -background $strip \
            -anchor w -font QLMono -foreground [::questlog::ui::theme::c muted]
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
        # design icon (screens.jsx SessionViewer) is a panel outline with a
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
        pack $CollapseBtn -side left -padx {6 2} -before $Top.head.path
        bind $CollapseBtn <Button-1> [list [self] do_toggle]

        ttk::frame $Top.body
        pack $Top.body -side top -fill both -expand 1
        # Two body rows: the docked index band (row 0, natural height, gridded
        # only while open) sits above the transcript (row 1, absorbs all height).
        # Row 0 carries no weight and no minsize, so `grid remove`-ing the band
        # collapses its row to nothing and the transcript reclaims the space.
        # text widget - no ttk equivalent.
        text $Top.body.t -wrap word -yscrollcommand [list $Top.body.sb set] \
            -state disabled -padx 10 -pady 6 -borderwidth 0 -highlightthickness 0
        ttk::scrollbar $Top.body.sb -orient vertical -command [list $Top.body.t yview]
        grid $Top.body.t  -row 1 -column 0 -sticky nsew
        grid $Top.body.sb -row 1 -column 1 -sticky ns
        grid columnconfigure $Top.body 0 -weight 1
        grid rowconfigure    $Top.body 0 -weight 0
        grid rowconfigure    $Top.body 1 -weight 1
        set Text $Top.body.t

        # Empty state: a centered prompt for the open gesture, gridded into the
        # same body cell as the text so the head+body silhouette is identical
        # whether empty or loaded. Shown at launch (the text and its scrollbar
        # start grid-removed); the first `show` swaps them in.
        ttk::frame $Top.body.empty
        grid $Top.body.empty -row 1 -column 0 -columnspan 2 -sticky nsew
        grid rowconfigure    $Top.body.empty {0 2} -weight 1
        grid columnconfigure $Top.body.empty {0 2} -weight 1
        ttk::frame $Top.body.empty.box
        ttk::label $Top.body.empty.box.msg -justify center -font QLBold \
            -foreground [::questlog::ui::theme::c section] \
            -text "Click a session to show it here"
        ttk::label $Top.body.empty.box.sub -justify center -wraplength 340 \
            -foreground [::questlog::ui::theme::c muted] \
            -text "A single click loads the transcript here. After a search, the match index up top jumps to each hit."
        pack $Top.body.empty.box.msg -side top -pady {0 6}
        pack $Top.body.empty.box.sub -side top
        grid $Top.body.empty.box -row 1 -column 1
        set Empty $Top.body.empty
        grid remove $Top.body.t $Top.body.sb

        # Docked index band. One collapsible pane above the transcript whose
        # content switches between the match index and the tool-call timeline.
        # Gridded into the body's row 0 (no weight, no minsize) so collapsing it
        # gives every pixel back to the transcript, and full-width so the reading
        # column keeps its width (the win over a side column). Its listboxes
        # share the band's content cell; set_tab grids one and removes the rest.
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
        # render, insert_quote_text) need no descriptor lookup.
        set TurnList  [dict get $BandDesc turns list]
        set MatchList [dict get $BandDesc matches list]
        set ToolList  [dict get $BandDesc tools list]
        set QuoteList [dict get $BandDesc quotes list]
        grid $Band.hdr -row 0 -column 0 -columnspan 2 -sticky ew
        grid columnconfigure $Band 0 -weight 1
        grid rowconfigure    $Band 1 -weight 1
        # Dock the band in the body's top row, then collapse it: ew (not nsew) so
        # it hugs its content height rather than stretching over the transcript.
        grid $Band -row 0 -column 0 -columnspan 2 -sticky ew
        grid remove $Band

        # A read-only reading view that supports drag-select and copy. The one
        # Text class gesture it suppresses is <B1-Leave>, the sole entry into
        # tk::TextAutoScan: a leave event delivered here while a button-1 press
        # owned by another widget is still down would start an autoscan loop
        # that no release is routed back to cancel, scrolling the view to the
        # end and greying it over on its own. Breaking <B1-Leave> blocks that
        # loop; <B1-Motion> selection, double/triple-click, Ctrl-C copy, and the
        # default <B1-Enter>/<ButtonRelease-1> CancelRepeat all stay in place.
        bind $Text <B1-Leave> break

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
        # Body prose follows QLBody, the proportional reading font switched at
        # runtime; fenced code keeps QLMono so it stays aligned regardless of
        # the reading font. Without an explicit -font the text widget would
        # render both in its TkFixedFont default.
        $Text tag configure body          -font QLBody -foreground [::questlog::ui::theme::c body] -lmargin1 10 -lmargin2 10 -spacing2 3 -spacing3 6
        $Text tag configure code          -font QLMono -foreground [::questlog::ui::theme::c body] -lmargin1 10 -lmargin2 10 -spacing2 3 -spacing3 6
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
        # t#N/d#N elide tags are configured at turn_open, in that order, so a
        # detail char's d#N outranks its t#N.
        $Text tag configure foldglyph -font QLMonoBold \
            -foreground [::questlog::ui::theme::c muted] \
            -lmargin1 10 -lmargin2 10 -spacing1 6
        $Text tag configure stub -font QLMono \
            -foreground [::questlog::ui::theme::c faint] -lmargin1 10 -lmargin2 10
        # Assistant blockquotes are plain tagged text, not embedded widgets:
        # `quote` is the inset block face (reading font, body ink, a deep left
        # margin so the block reads set in from the prose). Configured before
        # tkdown's faces so inline emphasis inside a quote still wins on -font;
        # its muted chrome tags (quotebar, qcopy) are configured just after, so
        # their ink wins over the block's body ink where they stack.
        $Text tag configure quote -font QLBody \
            -foreground [::questlog::ui::theme::c body] -lmargin1 24 -lmargin2 24
        # tkdown's td-* faces carry only a -font; colour and margins keep
        # coming from the body tag, which stays on every prose run (tags stack,
        # and the later tags win on -font). td-code is separate from the block
        # code tag so block-fence spacing and inline spans stay decoupled.
        ::tkdown::tags $Text [dict create \
            body QLBody bold QLBodyBold italic QLBodyItalic \
            bolditalic QLBodyBoldItalic mono QLMono]
        # The quote block's muted chrome: `quotebar` tints the per-line ▏ rule,
        # `qcopy` the ⧉ copy glyph heading the block. Configured after `quote` so
        # their muted ink outranks its body ink where they stack. qcopy also
        # carries the hand cursor, but a cursor is a per-widget option, not
        # per-tag, so flip $Text's cursor as the pointer crosses the glyph and
        # restore the reading view's default (an I-beam) on the way out. A click
        # on the glyph copies the quote (quote_copy_at resolves which one).
        $Text tag configure quotebar -foreground [::questlog::ui::theme::c muted]
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

        # Right-click copy (issue #4); the <Configure> refit keeps rendered
        # markdown tables' tab stops sized to the reading font.
        my build_menu
        bind $Text <<ContextMenu>> [list [self] on_right %x %y %X %Y]
        bind $Text <Configure>     [list [self] on_resize]

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
        # wheel events like any widget, so scroll $Text's yview exactly as its
        # Text-class binding would. Tk 9 delivers the wheel - on X11 too - as
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
            "[list [self] copy_hide]; tk::MouseWheel $Text y \[tk::ScaleNum %D\] -4.0 pixels; break"
        bind $CopyBtn <Shift-MouseWheel> \
            "[list [self] copy_hide]; tk::MouseWheel $Text x \[tk::ScaleNum %D\] -4.0 pixels; break"
        bind $CopyBtn <TouchpadScroll> \
            "[list [self] copy_hide]; lassign \[tk::PreciseScrollDeltas %D\] cbdx cbdy;\
             if {\$cbdy != 0} {$Text yview scroll \[tk::ScaleNum \[expr {-\$cbdy}\]\] pixels};\
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

        # Find overlay (hidden initially).
        set Find $Top.find
        ttk::frame $Find
        ttk::label $Find.lbl -text "Find:"
        ttk::entry $Find.e -textvariable [my varname FindVar] -width 30
        ttk::button $Find.next -text "Next" -command [list [self] find_next]
        ttk::button $Find.close -text "✕" -command [list [self] find_hide]
        pack $Find.lbl -side left -padx 4
        pack $Find.e   -side left -fill x -expand 1
        pack $Find.next  -side left -padx 2
        pack $Find.close -side left -padx 2

        # The text widget takes focus when clicked, so bind the find keys
        # there rather than on the (focus-less) container frame.
        # Summon Find from anywhere in the window, not only when the transcript
        # holds focus (see the Ctrl-Return note below); find_show guards on a
        # shown session. Escape stays on the transcript: it closes Find when the
        # reader presses it there, and the find entry has its own Escape.
        bind [winfo toplevel $Top] <Control-f> [list [self] find_show]
        bind $Text <Escape>     [list [self] find_hide]
        bind $Find.e <Escape>   [list [self] find_hide]
        bind $Find.e <Return>   [list [self] find_next]

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

    # The reading text, so the app can move focus here when it folds the list.
    method textwidget {} { return $Text }

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
                has_cwd [expr {$Cwd ne ""}] \
                has_folder [expr {$folder ne ""}]]]
        set idx [::questlog::ui::session_actions::populate $ActionMenu $ctx]
        ::questlog::ui::session_actions::apply_state \
            $ActionMenu $idx [dict get $ctx state]
        # Fold-all / expand-all over the turn registry; the band-header pair on the
        # Turns tab is their twin. Disabled when the session rendered no turns, so
        # they read as unavailable rather than silently doing nothing.
        $ActionMenu add separator
        set tstate [expr {[llength $Turns] ? "normal" : "disabled"}]
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
        # The named-font reflow updates the glyphs but not the boxes' fixed
        # -height, computed from display lines at the previous size; re-fit.
        my on_resize
    }

    method load {} {
        set fh [open $Path r]
        chan configure $fh -encoding utf-8 -profile replace
        set lineno 0
        while {[chan gets $fh line] >= 0} {
            incr lineno
            if {$line eq ""} continue
            set rec [::questlog::jsonl::parse_line $line]
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
        $Text configure -state normal
        $Text delete 1.0 end
        set Roles [dict create]
        set Bodies [dict create]
        # The per-document t#N/d#N tag families survive `delete 1.0 end` as
        # configured-but-empty tags and would pile up across loads; drop them
        # wholesale. tkdown sweeps its own per-table tags the same way.
        foreach tag [$Text tag names] {
            if {[string match {t#*} $tag] || [string match {d#*} $tag]} {
                $Text tag delete $tag
            }
        }
        ::tkdown::forget $Text
        set Turns [list]
        set CurTurn -1
        # Quotes are captured during render (insert_quote_text), so a wholesale
        # re-render clears them here; a streamed turn appends without re-render.
        $QuoteList delete 0 end
        set QuoteIdx [list]
        set QuoteBodies [list]
        set RenderTs 0
        set RenderInSection 0
        foreach rec $Records {
            lassign [my render_record_turned $rec $RenderTs $RenderInSection] \
                RenderTs RenderInSection
        }
        # The final turn stays open (a session can always grow); it still shows
        # its detail stub, appended as the trailing content line where
        # append_new knows to pop and recount it.
        my stub_sync
        $Text configure -state disabled
    }

    # Render one record at the end of the transcript and return the trailing
    # {last_ts in_section} state it advances: last_ts is the epoch of the most
    # recent content turn (for idle-gap detection), in_section is 1 while a
    # section header is open. Pulled out of render so the wholesale fill and the
    # streamed append (append_new) make identical divider and header decisions.
    # The per-record cues - compact boundary, empty-body clock advance, idle
    # gap - come from ::questlog::jsonl::transcript_step, the one classifier
    # this method and the markdown export both fold over (issue #31), so a
    # divider rule can no longer land in one surface and miss the other. The
    # step owns classification and the clock only: every glyph and tag, the
    # in_section tracking, the section headers and the label/body rendering
    # stay here. The caller holds $Text in -state normal.
    method render_record {rec last_ts in_section} {
        set t [dict getdef $rec type ""]
        # last-prompt records are repeated, truncated harness snapshots of the
        # most recent user prompt: the harness writes the same value many times,
        # and it echoes the real user turn already shown. Not part of the
        # conversation, so this viewer-side pre-filter drops them upstream of
        # the step - a deliberate fork from the markdown export, which renders
        # them as SYSTEM turns and lets them advance the clock; converging the
        # two is a separate decision nobody has made (the step's contract
        # comment records the divergence).
        if {$t eq "last-prompt"} { return [list $last_ts $in_section] }
        set lineno [dict get $rec _line]

        # The step hands back this record's cues in render order; the switch
        # owns their look. A compact boundary is the primary divider - the
        # step's returned clock is 0, and the section closes so the next turn
        # opens under a fresh header. An idle gap is the secondary divider,
        # already ordered above its turn's body. The body event says THAT the
        # record renders and supplies the flat extract_text copy (the
        # Bodies($line) contract below); HOW it renders stays keyed off the
        # record itself. A record yielding no body event draws nothing - the
        # step advanced the clock over it, so a gap still spans quiet metadata
        # records.
        lassign [::questlog::jsonl::transcript_step $rec $last_ts $IdleGap] \
            events last_ts
        set body ""
        foreach ev $events {
            switch -- [lindex $ev 0] {
                compact {
                    $Text insert end "─── /compact ───\n" compact-divider
                    set in_section 0
                }
                gap {
                    $Text insert end \
                        "─── [my fmt_gap [lindex $ev 1]] later ───\n" divider
                    set in_section 0
                }
                body {
                    set body [lindex $ev 1]
                }
            }
        }
        if {[::questlog::debug::enabled]} {
            ::questlog::debug::log render "line $lineno type=$t\
                empty=[expr {$body eq ""}]\
                tools=[llength [::questlog::jsonl::record_tool_uses $rec]]"
        }
        if {$body eq ""} { return [list $last_ts $in_section] }

        set ts_iso [::questlog::jsonl::record_timestamp $rec]
        if {!$in_section} {
            $Text insert end "[my section_header $ts_iso]\n" section-header
            set in_section 1
        }

        # Map this jsonl line to the current text index.
        set start_idx [$Text index "end-1l linestart"]
        dict set LineMap $lineno $start_idx
        dict set Bodies $lineno $body
        set CurTs $ts_iso        ;# a quote box in this record reads its time from here
        set label [::questlog::jsonl::record_role_label $rec]
        dict set Roles $lineno $label
        # Label -> tag: lowercased with spaces to underscores (TOOL RESULT ->
        # lbl-tool_result). The four lbl-* tags are configured in build.
        # A turn-start record's label line is its turn's header: the fold glyph
        # heads it, and turn_open (via render_record_turned) later tags the
        # whole line turnhdr. The glyph rides in front of the label, so
        # start_idx above still names the line and LineMap/Bodies/Roles keep
        # their meaning untouched.
        if {[::questlog::jsonl::is_turn_start $rec]} {
            $Text insert end "▾ " {foldglyph turnhdr}
        }
        $Text insert end "$label  " "lbl-[string map {{ } _} [string tolower $label]]"
        # Assistant and tool_result records render one content block at a time
        # so each tool_use/thinking/image block is its own dk-* tagged region
        # (a region detail-hiding can elide without touching the prose around
        # it); prompts and system records keep the flat extract_text body.
        # start_idx above is the record's whole extent either way, label line
        # included, which is what a hidden tool_result record will cover.
        if {$t eq "assistant" || [::questlog::jsonl::is_tool_result_record $rec]} {
            my insert_blocks $rec
        } else {
            my insert_body $t $body
        }

        # The clock already advanced inside the step; last_ts is its return.
        return [list $last_ts $in_section]
    }

    # Turn-aware wrapper around render_record, the one entry both the
    # wholesale fill and the streamed append use, so the turn registry is
    # maintained identically in both. A turn-start record (is_turn_start; the
    # rollback-list notion of a turn, so queued/sdk prompts stay inside the
    # running one) first closes the open turn - the closing stub must land
    # before render_record emits the new turn's gap divider or section header,
    # keeping the stub inside the old turn and the between-turns chrome
    # always visible - then renders and opens its own. Every other record
    # renders into the running turn: a tool_result record is detail in its
    # entirety (label line and trailing separator included, so hiding it
    # leaves no residue), and a folded open turn tag-adds t#N over the fresh
    # lines at once, so a fold taken mid-stream holds as content arrives. A
    # compact boundary closes nothing: the conversation resumes mid-turn.
    method render_record_turned {rec last_ts in_section} {
        # A turn start is gated on a body: a typed record whose extract_text
        # is empty would render no header line to open a turn at, and closing
        # the running turn for it would orphan everything after into
        # always-visible preamble. Such a record is treated as any other
        # bodiless one - the clock advances, the open turn keeps owning what
        # follows.
        if {[::questlog::jsonl::is_turn_start $rec]
                && [::questlog::jsonl::extract_text $rec] ne ""} {
            my turn_close
            lassign [my render_record $rec $last_ts $in_section] \
                last_ts in_section
            # Belt and braces alongside the gate above: should the body still
            # have rendered no line (no LineMap entry), head no turn.
            if {[dict exists $LineMap [dict get $rec _line]]} {
                my turn_open $rec
            }
            return [list $last_ts $in_section]
        }
        set before [$Text index "end-1l linestart"]
        lassign [my render_record $rec $last_ts $in_section] last_ts in_section
        if {$CurTurn >= 0 && [$Text compare $before < "end-1l linestart"]} {
            if {[::questlog::jsonl::is_tool_result_record $rec]} {
                set lineno [dict get $rec _line]
                if {[dict exists $LineMap $lineno]} {
                    $Text tag add d#$CurTurn [dict get $LineMap $lineno] \
                        [$Text index "end-1l linestart"]
                }
            }
            if {[dict get [lindex $Turns $CurTurn] folded]} {
                $Text tag add t#$CurTurn $before [$Text index "end-1l linestart"]
            }
        }
        return [list $last_ts $in_section]
    }

    # Append jsonl lines written since the last load/append (a streamed turn
    # growing the file) to the end of the transcript, reusing render_record so
    # the new turns look exactly like a fresh load. Re-reads from the top and
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
            set rec [::questlog::jsonl::parse_line $line]
            if {$rec eq ""} continue
            dict set rec _line $lineno
            lappend recs $rec
        }
        close $fh
        set LoadedLines $lineno
        # Records are read before the widget is touched, so the common empty
        # tick (the 300 ms cadence outruns claude's writes) mutates nothing -
        # in particular it does not churn the open turn's stub line.
        if {![llength $recs]} { return 0 }
        # The stub pop below deletes a mid-document line, so every text line
        # number at or under it shifts - including the hover-copy cache, whose
        # stale window otherwise makes the ⧉ copy the message ABOVE the one
        # under a parked pointer, every 300 ms tick. Invalidate it first; the
        # next Motion re-resolves against the settled transcript.
        my copy_hide
        set at_bottom [expr {[lindex [$Text yview] 1] >= 0.999}]
        # New content makes any endhint stale; clearing it here (a no-op on
        # the streaming path, where resume_submit already did) keeps the two
        # trailing-line invariants local: records append to the transcript
        # itself, and the open turn's stub really is the last content line
        # when popped below.
        my clear_endhint
        $Text configure -state normal
        # Pop the open turn's stub so the new records land inside the turn,
        # not under its summary; stub_sync below re-appends it with the
        # caught-up counts - the one legal rewrite window the
        # stub-immutability rule leaves open.
        if {$CurTurn >= 0} {
            set T [lindex $Turns $CurTurn]
            if {[dict get $T stub] ne ""} {
                set s [dict get $T stub]
                $Text delete $s "$s +1line linestart"
                dict set T stub ""
                lset Turns $CurTurn $T
            }
        }
        foreach rec $recs {
            lappend Records $rec
            lassign [my render_record_turned $rec $RenderTs $RenderInSection] \
                RenderTs RenderInSection
        }
        my stub_sync
        $Text configure -state disabled
        if {$at_bottom} { $Text see end }
        return [llength $recs]
    }

    # The boundary between session content and the trailing end-of-session
    # hint: searches and the match index stop here so the hint's words are not
    # treated as transcript matches. Returns "end" when no hint is present.
    method content_end {} {
        set r [$Text tag ranges endhint]
        if {[llength $r]} { return [lindex $r 0] }
        return "end"
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

    # ---- streamdoc surface: turn folding and detail hiding -----------------
    #
    # The primitives below are the only code in the viewer allowed to mutate a
    # tag's -elide (and the glyph/stub text mirroring it). Everything else asks
    # through them, so a future extraction into a streamdoc megawidget (the
    # streamtree precedent) is a packaging exercise, not surgery.
    #
    # Two per-turn tag families, each holding an explicit -elide 0/1 at all
    # times:
    #   t#N  the fold range [hdr +1line linestart, end linestart): whole
    #        logical lines only, never the header's own newline - eliding it
    #        would visually join adjacent headers when everything is folded
    #   d#N  the turn's detail blocks, hidden (1) by default
    # turn_open configures t#N strictly before its d#N, so d#N holds the
    # higher tag priority: where both cover a char (a detail block inside a
    # turn) the d#N elide wins, and unfolding a turn does not spill its hidden
    # detail. turn_fold forces d#N back to 1, stating the same rule from the
    # other side: re-folding re-hides whatever was revealed. The priority
    # rule cuts both ways: no tag created after a turn's t#/d# (or raised
    # above them) may set an explicit -elide of its own, or it would override
    # the fold - today's body/dk-*/find/sel/tbl tags all leave -elide unset,
    # which never overrides.
    #
    # The stub line ("▸ · 7 tool calls · 2 thinking") is tagged {stub t#N},
    # never d#N: it is the visible toggle for the hidden detail, and it folds
    # away with its turn. Its text is immutable once mid-document (a length
    # change would splice every bare index after it): while its turn is open it
    # is the trailing content line and stub_sync may delete and re-append it;
    # once closed only its 1-char glyph may change, via swap_glyph.

    # Open a turn at the record that just rendered: registry entry, elide tags
    # (t#N then d#N - the priority order above), and the turnhdr click zone
    # over the whole header line.
    method turn_open {rec} {
        set n [llength $Turns]
        set lineno [dict get $rec _line]
        set hdr [dict get $LineMap $lineno]
        $Text tag configure t#$n -elide 0
        $Text tag configure d#$n -elide 1
        $Text tag add turnhdr $hdr "$hdr lineend"
        lappend Turns [dict create id $n line $lineno hdr $hdr \
            body [$Text index "$hdr +1line linestart"] end "" \
            label [lindex [split [dict getdef $Bodies $lineno ""] \n] 0] \
            ts [::questlog::jsonl::record_timestamp $rec] \
            folded 0 shown 0 counts [dict create] stub ""]
        set CurTurn $n
    }

    # Close the open turn: append its stub (stub_sync, so close and stream
    # share one appender), tag the whole fold range - one definitive add that
    # subsumes any incremental fold-during-stream adds - and seal its end.
    # Caller (render_record_turned) holds $Text in -state normal.
    method turn_close {} {
        if {$CurTurn < 0} return
        set n $CurTurn
        my stub_sync
        set T [lindex $Turns $n]
        set e [$Text index "end-1l linestart"]
        $Text tag add t#$n [dict get $T body] $e
        dict set T end $e
        lset Turns $n $T
        set CurTurn -1
    }

    method turn_fold {n} {
        set T [lindex $Turns $n]
        if {[dict get $T folded]} return
        # The open turn's range is unsealed; bound it at the live content end
        # (before the endhint when one is up). Closed turns re-add their fixed
        # range - idempotent over turn_close's add.
        set e [dict get $T end]
        if {$e eq ""} {
            set ce [my content_end]
            set e [expr {$ce eq "end" ? [$Text index "end-1l linestart"] \
                                      : [$Text index "$ce linestart"]}]
        }
        $Text tag add t#$n [dict get $T body] $e
        $Text tag configure t#$n -elide 1
        $Text tag configure d#$n -elide 1   ;# re-folding re-hides details
        dict set T folded 1
        dict set T shown 0
        lset Turns $n $T
        my swap_glyph [dict get $T hdr] "▸"
        if {[dict get $T stub] ne ""} { my swap_glyph [dict get $T stub] "▸" }
    }

    method turn_unfold {n} {
        set T [lindex $Turns $n]
        if {![dict get $T folded]} return
        # d#N stays 1: unfolding shows the turn's prose and stub, not its
        # hidden detail - that is details_show's decision.
        $Text tag configure t#$n -elide 0
        dict set T folded 0
        lset Turns $n $T
        my swap_glyph [dict get $T hdr] "▾"
    }

    method turn_toggle {n} {
        if {[dict get [lindex $Turns $n] folded]} {
            my turn_unfold $n
        } else {
            my turn_fold $n
        }
    }

    method details_show {n} {
        set T [lindex $Turns $n]
        if {[dict get $T shown]} return
        $Text tag configure d#$n -elide 0
        dict set T shown 1
        lset Turns $n $T
        if {[dict get $T stub] ne ""} { my swap_glyph [dict get $T stub] "▾" }
    }

    method details_hide {n} {
        set T [lindex $Turns $n]
        if {![dict get $T shown]} return
        $Text tag configure d#$n -elide 1
        dict set T shown 0
        lset Turns $n $T
        if {[dict get $T stub] ne ""} { my swap_glyph [dict get $T stub] "▸" }
    }

    method details_toggle {n} {
        if {[dict get [lindex $Turns $n] shown]} {
            my details_hide $n
        } else {
            my details_show $n
        }
    }

    # Fold every turn: the table-of-contents reading, one header per turn.
    # Both mass toggles drop the hover-copy button: the relayout slides new
    # text under the pointer, and a placed button would float over a message
    # it does not copy until the next Motion.
    method fold_all {} {
        my copy_hide
        for {set n 0} {$n < [llength $Turns]} {incr n} { my turn_fold $n }
    }

    method expand_all {} {
        my copy_hide
        for {set n 0} {$n < [llength $Turns]} {incr n} { my turn_unfold $n }
    }

    # The turn containing a text index; -1 for the preamble before the first
    # turn and for the chrome between turns (a gap divider or section header
    # renders after turn_close sealed the old end, so it belongs to neither
    # side). The open turn owns everything from its header down.
    method turn_at {idx} {
        set i [$Text index $idx]
        for {set n [expr {[llength $Turns] - 1}]} {$n >= 0} {incr n -1} {
            set T [lindex $Turns $n]
            if {[$Text compare $i < [dict get $T hdr]]} continue
            set e [dict get $T end]
            if {$e eq "" || [$Text compare $i < $e]} { return $n }
            return -1
        }
        return -1
    }

    # The one jump gate: every site that scrolls the transcript to an index
    # routes here, because `see` cannot land on an elided char. Unfolds the
    # target's turn, and shows details only when the index itself sits in the
    # turn's detail region - jumping to a visible line must not spill the
    # whole turn's hidden blocks. The see must wait for the reshaped line
    # metrics: an un-elide moves thousands of display lines, its relayout
    # registers through an idle handler, and a bare `see` in the same
    # callback scrolls to where the target used to be (the first jump out of
    # fold_all on a large session landed at the top; later jumps only worked
    # because the first had warmed the metrics). Neither a targeted
    # `count -update` nor a bare `sync` cures it - both run before the idle
    # relayout has even invalidated the metrics - so drain idletasks first,
    # then sync, then see. Click-latency price, paid only on a jump.
    method reveal_index {idx} {
        # The jump is layout churn like any other: the see slides new text
        # under a pointer resting on the transcript (a find-entry Return jumps
        # without moving the mouse), and a placed copy button would float over
        # a message it does not name. Same rule as the wheel and the mass
        # toggles: drop it, the next Motion re-places it.
        my copy_hide
        set n [my turn_at $idx]
        if {$n >= 0} {
            if {[dict get [lindex $Turns $n] folded]} { my turn_unfold $n }
            if {"d#$n" in [$Text tag names $idx]} { my details_show $n }
        }
        update idletasks
        $Text sync
        $Text see $idx
    }

    # Swap a 1-char state glyph in place (header ▾/▸, stub ▸/▾): a same-length
    # replace, so every bare index downstream stays true. Re-applies the tags
    # found under the old glyph (minus a transient sel) and runs under a saved
    # and restored -state, because callers arrive from click handlers on the
    # disabled transcript as often as from the render path.
    method swap_glyph {idx glyph} {
        set tags [lsearch -all -inline -not -exact [$Text tag names $idx] sel]
        set st [$Text cget -state]
        $Text configure -state normal
        $Text replace $idx "$idx +1c" $glyph $tags
        $Text configure -state $st
    }

    # Make the open turn's trailing stub reflect its current counts: delete
    # the old stub line if one stands, re-append if the turn holds any detail.
    # Legal only because the open turn's stub is the last content line - the
    # rewrite splices no index before it. Closed turns never come here.
    method stub_sync {} {
        if {$CurTurn < 0} return
        set n $CurTurn
        set T [lindex $Turns $n]
        set st [$Text cget -state]
        $Text configure -state normal
        set s [dict get $T stub]
        if {$s ne ""} {
            $Text delete $s "$s +1line linestart"
            dict set T stub ""
        }
        set txt [my stub_text [dict get $T counts]]
        if {$txt ne ""} {
            set glyph [expr {[dict get $T shown] ? "▾" : "▸"}]
            set idx [$Text index "end-1l linestart"]
            # Tagged t#N explicitly, so a turn folded mid-stream keeps its
            # fresh stub hidden like the rest of its lines; never d#N.
            $Text insert end "$glyph $txt\n" [list stub t#$n]
            dict set T stub $idx
        }
        $Text configure -state $st
        lset Turns $n $T
    }

    # The stub's count phrase: nonzero kinds only, "· 7 tool calls · 2
    # thinking". Tool results are not a kind of their own - they shadow their
    # calls - unless a turn somehow holds results with no calls, where they
    # are the only honest label. "" when the turn has no detail at all: such a
    # turn takes no stub line.
    method stub_text {counts} {
        set parts [list]
        set tu [dict getdef $counts tool_use 0]
        set th [dict getdef $counts thinking 0]
        set im [dict getdef $counts image 0]
        set tr [dict getdef $counts tool_result 0]
        if {$tu} { lappend parts "$tu tool call[expr {$tu == 1 ? "" : "s"}]" }
        if {$th} { lappend parts "$th thinking" }
        if {$im} { lappend parts "$im image[expr {$im == 1 ? "" : "s"}]" }
        if {$tr && !$tu} {
            lappend parts "$tr tool result[expr {$tr == 1 ? "" : "s"}]"
        }
        if {![llength $parts]} { return "" }
        return "· [join $parts " · "]"
    }

    # Header/stub click handlers, shared by every turn through the two global
    # tags; the click index says which turn. The sel guard is quote_copy_at's:
    # a drag-select that merely releases over the line must not toggle it.
    method turnhdr_click {x y} {
        if {[$Text tag ranges sel] ne ""} return
        set n [my turn_at [$Text index @$x,$y]]
        if {$n >= 0} { my turn_toggle $n }
    }

    method stub_click {x y} {
        if {[$Text tag ranges sel] ne ""} return
        set n [my turn_at [$Text index @$x,$y]]
        if {$n >= 0} { my details_toggle $n }
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

    # Insert one turn's body. A body with no blockquote goes wholesale to
    # ::tkdown::body (fenced code under the block `code` tag, everything else
    # markdown prose over `body`). An assistant body carrying blockquotes
    # keeps the fence split here, because a quote run becomes an inset tagged
    # block, app chrome tkdown knows nothing about.
    method insert_body {t body} {
        set has_quote [expr {$t eq "assistant" && [regexp -line {^>} $body]}]
        if {!$has_quote} {
            ::tkdown::body $Text end $body body code
            return
        }
        if {![regexp -line {^\s*```} $body]} {
            my insert_segments $body
            return
        }
        foreach seg [::tkdown::segment_code_fences $body] {
            lassign $seg kind text
            if {$kind eq "code"} {
                $Text insert end "$text\n" code
            } elseif {[regexp -line {^>} $text]} {
                my insert_segments $text
            } else {
                ::tkdown::prose $Text end $text body "\n"
            }
        }
        $Text insert end "\n" body
    }

    # Render an assistant or tool_result record body one content block at a
    # time, per extract_blocks. Text blocks keep the whole markdown path
    # (fences, tables, blockquotes) through insert_body; tool_use, thinking,
    # tool_result and image blocks each become one dk-* tagged region, the
    # regions detail-hiding elides per turn. Every block's content goes in
    # verbatim as one contiguous run - lib/match.tcl indexes these exact
    # strings, and search highlighting must keep landing on the same
    # characters (issue #21) - so any visual lead-in is a separate dk-chrome
    # insert that shifts no content offset.
    method insert_blocks {rec} {
        # Inside a turn every detail block also carries the turn's d#N elide
        # tag (hidden by default, toggled by the turn's stub line) and bumps
        # the per-kind tally the stub prints. Preamble records before the
        # first turn carry neither: always visible.
        set dtag [expr {$CurTurn >= 0 ? "d#$CurTurn" : ""}]
        set last ""
        set sawtext 0
        foreach {btype content} [::questlog::jsonl::extract_blocks $rec] {
            switch -- $btype {
                assistant - user {
                    my insert_body $btype $content
                    set sawtext 1
                }
                thinking {
                    # extract_blocks emits thinking bare, without the
                    # "[thinking] " prefix extract_text carries; restore it as
                    # chrome so the reading view is unchanged. The redacted
                    # placeholder never carried the prefix, so it gets none.
                    if {$dtag ne ""} { my count_detail thinking }
                    if {$content ne "\[redacted thinking\]"} {
                        $Text insert end "\[thinking\] " [concat dk-chrome $dtag]
                    }
                    $Text insert end "$content\n" [concat dk-thinking $dtag]
                }
                default {
                    # tool_use / tool_result / image, one line per block.
                    # tool_use content is format_tool_use_full, the very
                    # string extract_text flattened, so the words on screen
                    # do not change, only their tag.
                    if {$dtag ne ""} { my count_detail $btype }
                    $Text insert end "$content\n" [concat [list dk-$btype] $dtag]
                }
            }
            set last $btype
        }
        # insert_body closes a text block with its own blank line; a record
        # ending on a detail block still owes the record separator. The
        # separator is itself detail only when a text block already ended the
        # label's line: then hiding details leaves ordinary single-record
        # spacing. Without one (a tool-only record) it must stay visible, or
        # the bare label - whose own newline hides with its first block -
        # would run into the next record's line.
        if {$last ni {assistant user}} {
            set sep body
            if {$sawtext && $dtag ne ""} { set sep [list body $dtag] }
            $Text insert end "\n" $sep
        }
    }

    # Bump the open turn's tally of one detail kind; the stub line renders
    # these numbers when the turn closes (or on stub_sync while it streams).
    method count_detail {kind} {
        set T [lindex $Turns $CurTurn]
        set c [dict get $T counts]
        dict incr c $kind
        dict set T counts $c
        lset Turns $CurTurn $T
    }

    # Render an assistant body that contains at least one blockquote run:
    # normal text inline, each blockquote run as an inset tagged block.
    method insert_segments {body} {
        set atstart 0
        foreach seg [::tkdown::segment_blockquotes $body] {
            lassign $seg kind text
            if {$kind eq "quote"} {
                if {!$atstart} { $Text insert end "\n" body }
                my insert_quote_text $text
                set atstart 1
            } else {
                ::tkdown::prose $Text end $text body "\n"
                set atstart 1
            }
        }
        $Text insert end "\n" body
    }

    # Render a de-quoted blockquote run as an inset block of tagged text. Each
    # physical line gets a muted ▏ rule and the reading font (inline *emphasis*
    # and `code` still style through ::tkdown::runs, base tag `quote`), and a ⧉
    # copy glyph heads the block. Unlike the embedded text widget it replaced,
    # this scrolls with the transcript (that widget's own Text-class wheel
    # binding swallowed the wheel as the pointer crossed a quote) and its text
    # is visible to $Text search.
    method insert_quote_text {dequoted} {
        # Index this quote for the Quotes band tab before inserting it: the
        # block's first line -- where the ⧉ glyph lands -- is the jump target,
        # and its bare index is exactly what a qcopy click resolves back to.
        # ponytail: a bare index (not a Tk mark), the same assumption LineMap
        # makes - the transcript only appends at end or wholesale-reloads, never
        # splices mid-way; move both to marks together if that ever changes.
        lappend QuoteIdx [$Text index "end-1l linestart"]
        lappend QuoteBodies $dequoted
        $QuoteList insert end "[my tool_time $CurTs] · [my quote_preview $dequoted]"
        $QuoteList itemconfigure end -foreground [::questlog::ui::theme::c assistant]
        $Text insert end "⧉ " {qcopy quote}
        foreach line [split $dequoted "\n"] {
            $Text insert end "▏ " {quotebar quote}
            ::tkdown::runs $Text end $line quote
            $Text insert end "\n" quote
        }
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

    method on_resize {} {
        ::tkdown::refit $Text
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

    method section_header {ts_iso} {
        set when [my fmt_iso $ts_iso]
        return "▼ $when"
    }

    method fmt_iso {ts_iso} {
        if {$ts_iso eq ""} { return "" }
        set epoch [my parse_iso $ts_iso]
        if {$epoch == 0} { return $ts_iso }
        return [clock format $epoch -format "%a %d %b  %H:%M"]
    }

    # ISO->epoch and gap formatting are the shared session-segmentation
    # clock (lib/jsonl.tcl), so the viewer's dividers and the markdown export
    # never disagree. Kept as thin methods so the call sites read `my ...`.
    method parse_iso {ts_iso}  { return [::questlog::jsonl::parse_iso $ts_iso] }
    method fmt_gap {minutes}   { return [::questlog::jsonl::fmt_gap $minutes] }

    # Scroll the reading view to a jsonl line. A directly mapped line (a turn
    # that rendered a text body) is shown as-is. A line with no anchor falls
    # back to the nearest mapped line at or before it: tool-use-only turns
    # render no prose and so get no LineMap entry, yet a tool-call timeline row
    # must still land the reader on the turn that issued it, which is the turn
    # whose body precedes the call in the transcript.
    method scroll_to_line {lineno} {
        if {[dict exists $LineMap $lineno]} {
            ::questlog::debug::log scroll "want $lineno exact hit"
            my reveal_index [dict get $LineMap $lineno]
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
        if {$best ne ""} { my reveal_index $best }
    }

    method find_show {} {
        if {!$Shown} return
        pack $Find -side bottom -fill x
        focus $Find.e
    }

    method find_hide {} {
        pack forget $Find
        $Text tag remove find 1.0 end
        set FindMatches [list]
        set FindIdx 0
    }

    method find_next {} {
        if {[llength $FindMatches] == 0 || $FindVar ne [my last_find_var]} {
            set FindMatches [my collect_matches $FindVar]
            set FindIdx 0
            my mark_find_var $FindVar
        }
        if {[llength $FindMatches] == 0} {
            bell
            return
        }
        set idx [lindex $FindMatches $FindIdx]
        my reveal_index $idx
        incr FindIdx
        if {$FindIdx >= [llength $FindMatches]} { set FindIdx 0 }
    }

    method collect_matches {pattern} {
        $Text tag remove find 1.0 end
        if {$pattern eq ""} { return [list] }
        set results [list]
        set start 1.0
        while {1} {
            set len 0
            # -elide: without it `search` skips hidden text, and a hit inside
            # an elided detail block must still be findable (it is what lets
            # a jump reveal the block).
            set m [$Text search -elide -count len -nocase -- $pattern $start [my content_end]]
            if {$m eq ""} break
            set start "$m + ${len}c"
            # A stub's own words ("7 tool calls") and a header's fold glyph
            # are turn chrome, not transcript; a hit there would step the
            # reader nowhere useful, and a glyph hit would go stale the moment
            # swap_glyph flips it.
            set mtags [$Text tag names $m]
            if {"stub" in $mtags || "foldglyph" in $mtags} continue
            $Text tag add find $m "$m + ${len}c"
            lappend results $m
        }
        return $results
    }

    variable LastFindVar
    method last_find_var {}    { return [expr {[info exists LastFindVar] ? $LastFindVar : ""}] }
    method mark_find_var {v}   { set LastFindVar $v }

    # ---- match index (seeded from the search query) ------------------

    # Highlight every literal occurrence of the search terms in the rendered
    # transcript, remember them ordered rarest-keyword-first (one hit of each
    # term before any term repeats), and open the band on its match index. Terms
    # are matched literally (the search bar is Google-style, not
    # regex; the toolbar's pattern row is the separate regex restriction and is
    # not highlighted here). An empty query (a session opened while browsing)
    # clears the highlight and hides the index. Shares the `find` tag and
    # FindMatches/FindIdx with the Ctrl-F overlay, so stepping is unified.
    method index_matches {query} {
        $Text tag remove find 1.0 end
        set FindMatches [list]
        set FindIdx 0
        set MatchLabels [list]
        set terms [expr {[dict exists $query terms] ? [dict get $query terms] : {}}]
        set nocase [expr {[dict exists $query nocase] ? [dict get $query nocase] : 0}]

        # Collect each distinct term's occurrences in document order, tagging
        # every one. A term repeated in the query is counted once.
        set per_term [list]
        set seen_terms [dict create]
        foreach term $terms {
            if {$term eq ""} continue
            if {[dict exists $seen_terms $term]} continue
            dict set seen_terms $term 1
            set positions [list]
            set start 1.0
            while {1} {
                set len 0
                # -elide as in collect_matches: hits inside hidden detail
                # blocks still index.
                if {$nocase} {
                    set m [$Text search -elide -nocase -count len -- $term $start [my content_end]]
                } else {
                    set m [$Text search -elide -count len -- $term $start [my content_end]]
                }
                if {$m eq ""} break
                if {$len <= 0} { set len 1 }
                set start "$m + ${len}c"
                # Skip stub-line and fold-glyph hits, as in collect_matches.
                set mtags [$Text tag names $m]
                if {"stub" in $mtags || "foldglyph" in $mtags} continue
                $Text tag add find $m "$m + ${len}c"
                lappend positions $m
            }
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
            lappend MatchLabels [my match_context $m]
        }
        if {[::questlog::debug::enabled]} {
            ::questlog::debug::log index "terms=[llength $terms]\
                matched_terms=[llength $per_term] total_matches=[llength $FindMatches]"
        }
        my refresh_match_control
    }

    # lsort comparator over per-term position lists: fewer occurrences first,
    # ties broken by the earlier first occurrence in the document.
    method cmp_term_rarity {a b} {
        set la [llength $a]
        set lb [llength $b]
        if {$la != $lb} { return [expr {$la < $lb ? -1 : 1}] }
        return [my cmp_index [lindex $a 0] [lindex $b 0]]
    }

    # Order two text indices in document order, for lsort.
    method cmp_index {a b} {
        if {[$Text compare $a < $b]} { return -1 }
        if {[$Text compare $a > $b]} { return 1 }
        return 0
    }

    # A one-line, whitespace-collapsed excerpt of the match's line, for the
    # match index row.
    method match_context {idx} {
        # A hit on a record's first line would excerpt the role label too, and
        # the row already leads with the role - "ASSISTANT · ...ASSISTANT
        # Write(" read twice. Start the excerpt where the content does: past
        # the fold glyph and the label, when the line opens with them.
        set s [$Text index "$idx linestart"]
        foreach chrome {foldglyph lbl-user lbl-assistant lbl-system lbl-tool_result} {
            set r [$Text tag nextrange $chrome $s "$s lineend"]
            if {[llength $r] && [$Text compare [lindex $r 0] == $s]} {
                set s [lindex $r 1]
            }
        }
        set line [regsub -all {\s+} [string trim [$Text get $s "$s lineend"]] " "]
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
    # the chosen list into the content cell and remove the rest, so only the
    # active list's height drives the band. Re-derives the tab styling and the
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

    # Open the band (re-grids its body row) on the given tab.
    method band_show {tab} {
        set BandOpen 1
        grid $Band
        my set_tab $tab
    }

    # Collapse the band: grid-remove gives row 0 back to the transcript.
    method band_hide {} {
        set BandOpen 0
        grid remove $Band
        my update_band_glyphs
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
        my reveal_index [lindex $FindMatches $i]
        set FindIdx $i
    }

    # ---- tool-call timeline (the did-versus-claimed audit, issue #15) ----

    # Walk the loaded Records in document order, collect every assistant
    # tool_use block as one timeline row "time · tool · path", and fill the
    # head-strip count. Records are already in chronological order, so the
    # walk needs no sort. Each row remembers its record's jsonl line (in
    # ToolLines, parallel to the listbox rows) so a click jumps the reading
    # view there. With no tool calls both the band's Tools tab and the head
    # count stay hidden.
    method index_tool_calls {} {
        set ToolLines [list]
        $ToolList delete 0 end
        foreach rec $Records {
            set lineno [dict get $rec _line]
            set when [my tool_time [::questlog::jsonl::record_timestamp $rec]]
            foreach use [::questlog::jsonl::record_tool_uses $rec] {
                set name [dict get $use name]
                set path [dict get $use path]
                set row "$when · $name"
                if {$path ne ""} { append row " · $path" }
                $ToolList insert end $row
                $ToolList itemconfigure end -foreground [::questlog::ui::theme::c tool]
                lappend ToolLines $lineno
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

    # Jump the reading view to the clicked call's line, then open that turn's
    # detail so the call itself is on screen. scroll_to_line routes through
    # reveal_index, which unfolds the landing turn but shows hidden detail only
    # when the jump index sits inside it; a tool_use renders after its record's
    # visible label line, so a plain reveal lands on the label and leaves the
    # call elided. The Tools tab is the one caller that explicitly asked for that
    # hidden line, so it spills the whole turn's detail after landing. The other
    # scroll_to_line callers (the session-list snippet deep links) keep the
    # reveal-only-what-you-hit rule - which is exactly why this detail spill lives
    # in the caller and not in scroll_to_line or reveal_index.
    method tool_list_select {} {
        set sel [$ToolList curselection]
        if {$sel eq ""} return
        set lineno [lindex $ToolLines [lindex $sel 0]]
        my scroll_to_line $lineno
        if {[dict exists $LineMap $lineno]} {
            set n [my turn_at [dict get $LineMap $lineno]]
            if {$n >= 0} { my details_show $n }
        }
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
    # rows were filled by insert_quote_text). Opt-in like the tool audit (auto 0):
    # it never opens the band, only makes the Quotes tab and count available; with
    # no quotes both stay hidden. refresh_band_control does the work.
    method refresh_quote_control {} {
        my refresh_band_control quotes [llength $QuoteIdx]
    }

    # Jump the reading view to the clicked quote's box.
    method quote_list_select {} {
        set sel [$QuoteList curselection]
        if {$sel eq ""} return
        my reveal_index [lindex $QuoteIdx [lindex $sel 0]]
    }

    # ---- turns index (jump to a turn's header) ----------------------------

    # Fill the Turns listbox from the registry, one row per turn "time · first
    # prompt line" coloured like a user label (a turn opens on a user prompt).
    # The label was captured at turn_open (the prompt's first line); collapse
    # its whitespace and clip it the way the match and quote rows clip, so a
    # long or ragged opening still reads as one tidy row. Called from show and,
    # after a streamed turn lands, from resume_finish - the registry is the one
    # source of truth, so a refill always tracks [llength $Turns]. Unlike the
    # quote rows (appended live during render) turn rows are not maintained
    # incrementally, so this rebuilds them wholesale.
    method index_turns {} {
        $TurnList delete 0 end
        foreach T $Turns {
            set label [regsub -all {\s+} [string trim [dict get $T label]] " "]
            if {[string length $label] > 60} {
                set label "[string range $label 0 59]…"
            }
            $TurnList insert end "[my tool_time [dict get $T ts]] · $label"
            $TurnList itemconfigure end -foreground [::questlog::ui::theme::c user]
        }
        my refresh_turn_control
    }

    # Expose the head-strip Turns count from the registry (index_turns has
    # filled the rows). Opt-in like the tool and quote audits (descriptor auto
    # is 0): it makes the Turns tab and count available but never opens the band
    # on its own - the Turns index is reached for, not surfaced by a session
    # click. With no turns the count is hidden and a band already on Turns
    # collapses; refresh_band_control does the work.
    method refresh_turn_control {} {
        my refresh_band_control turns [llength $Turns]
    }

    # Jump the reading view to a clicked turn's header. A header line is never
    # elided (turn_fold hides from the body down, keeping the header as the
    # fold's visible handle), so the reveal here only unfolds a folded target
    # and scrolls - it spills no detail. The jump still routes through
    # reveal_index rather than a bare `see`, because that one-gate rule is the
    # whole discipline: every transcript jump lands through the primitive that
    # knows how to make an elided target visible, even where this particular
    # target can never be elided.
    method turn_list_select {} {
        set sel [$TurnList curselection]
        if {$sel eq ""} return
        set T [lindex $Turns [lindex $sel 0]]
        my reveal_index [dict get $T hdr]
    }
}
