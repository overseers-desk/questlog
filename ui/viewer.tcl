package require Tcl 9
package require Tk

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
    variable NextQid          ;# monotonic id for embedded quote boxes
    variable Drafts           ;# dict: qid -> box state
    variable Bodies           ;# dict: jsonl line -> raw body (for Copy message)
    variable MatchBtn         ;# head-strip "N matches" count, packed on demand
    variable MatchList        ;# listbox of per-match rows inside the band
    variable MatchLabels      ;# per-match one-line excerpt, parallel to FindMatches
    variable MatchCountText   ;# "N matches" string, shared by the head count and band tab
    variable ToolBtn          ;# head-strip "N tool calls" count, packed on demand
    variable ToolList         ;# listbox of per-call rows inside the band
    variable ToolLines        ;# jsonl line of each call, parallel to the ToolList rows
    variable ToolCountText    ;# "N tool calls" string, shared by the head count and band tab
    variable Roles            ;# dict: jsonl line -> uppercased role, for row colour
    # Docked index band above the transcript: one collapsible pane whose content
    # switches between the match index and the tool-call timeline. It replaces the
    # two floating panels that used to cover the reading view.
    variable Band             ;# the band frame, gridded in the body's row 0
    variable BandTab          ;# "matches"|"tools": which list the band currently shows
    variable BandOpen         ;# 1 while the band is gridded (taking transcript height)
    variable BandCount        ;# band-header count label
    variable TabMatches       ;# band-header "Matches" tab label
    variable TabTools         ;# band-header "Tools" tab label
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
    variable Tick             ;# after-id of the jsonl tail tick while streaming
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
        set NextQid 0
        set Drafts [dict create]
        set Bodies [dict create]
        set MatchLabels [list]
        set MatchCountText ""
        set ToolLines [list]
        set ToolCountText ""
        set Roles [dict create]
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
        # Match index: a count on the right of the head strip that opens the
        # docked band (built below) on its Matches tab, and collapses it when
        # clicked again. It carries the count even while the band is collapsed;
        # its glyph reads ▾ closed, ▴ open. Packed on demand by
        # refresh_match_control; absent when the session was opened without a
        # search.
        label $Top.head.matches -text "" -background $strip \
            -foreground [::questlog::ui::theme::c sessionhead] -cursor hand2
        set MatchBtn $Top.head.matches
        bind $MatchBtn <Button-1> [list [self] band_toggle matches]
        # Tool-call timeline: a sibling count on the head strip that opens the
        # band on its Tools tab. It carries the session's tool-call count;
        # glyph ▾ closed, ▴ open, like the match count. Packed on demand by
        # refresh_tool_control; absent when the session made no tool calls.
        label $Top.head.tools -text "" -background $strip \
            -foreground [::questlog::ui::theme::c sessionhead] -cursor hand2
        set ToolBtn $Top.head.tools
        bind $ToolBtn <Button-1> [list [self] band_toggle tools]
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
        # column keeps its width (the win over a side column). Two listboxes
        # share the band's content cell; set_tab grids one and removes the other.
        # The header carries the Matches|Tools tabs, the active count, and ✕.
        # A classic tk frame/label set tinted with the head strip's background,
        # not ttk (clam ignores -background on ttk frames), so the head strip and
        # band read as one contiguous chrome zone over the transcript.
        set Band $Top.body.band
        frame $Band -background $strip
        frame $Band.hdr -background $strip
        frame $Band.hdr.tabs -background $strip
        set TabMatches $Band.hdr.tabs.matches
        label $TabMatches -text "Matches" -background $strip -cursor hand2 \
            -foreground [::questlog::ui::theme::c muted] -font QLMonoBold
        bind $TabMatches <Button-1> [list [self] set_tab matches]
        set TabTools $Band.hdr.tabs.tools
        label $TabTools -text "Tools" -background $strip -cursor hand2 \
            -foreground [::questlog::ui::theme::c muted] -font QLMonoBold
        bind $TabTools <Button-1> [list [self] set_tab tools]
        pack $TabMatches -side left
        pack $TabTools   -side left -padx {10 0}
        set BandCount $Band.hdr.count
        label $BandCount -text "" -background $strip \
            -foreground [::questlog::ui::theme::c sessionhead]
        label $Band.hdr.close -text "✕" -background $strip \
            -foreground [::questlog::ui::theme::c muted] -cursor hand2
        bind $Band.hdr.close <Button-1> [list [self] band_hide]
        pack $Band.hdr.tabs  -side left -padx 8 -pady 2
        pack $BandCount      -side left -padx 6
        pack $Band.hdr.close -side right -padx 8
        # Match index listbox: rows "ROLE · …excerpt… · line N", coloured by role,
        # each jumping the reading view to that hit.
        set MatchList $Band.matchlist
        listbox $MatchList -height 1 -width 44 -activestyle none \
            -borderwidth 0 -highlightthickness 0 \
            -yscrollcommand [list $Band.matchsb set]
        ttk::scrollbar $Band.matchsb -orient vertical \
            -command [list $MatchList yview]
        bind $MatchList <<ListboxSelect>> [list [self] match_list_select]
        # Tool-call timeline listbox: the did-versus-claimed audit (issue #15),
        # rows "time · tool · path" in chronological order, each jumping the
        # reading view to the call's line.
        set ToolList $Band.toollist
        listbox $ToolList -height 1 -width 44 -activestyle none \
            -borderwidth 0 -highlightthickness 0 \
            -yscrollcommand [list $Band.toolsb set]
        ttk::scrollbar $Band.toolsb -orient vertical \
            -command [list $ToolList yview]
        bind $ToolList <<ListboxSelect>> [list [self] tool_list_select]
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
        # Body prose follows QLBody, the proportional reading font switched at
        # runtime; fenced code keeps QLMono so it stays aligned regardless of
        # the reading font. Without an explicit -font the text widget would
        # render both in its TkFixedFont default.
        $Text tag configure body          -font QLBody -foreground [::questlog::ui::theme::c body] -lmargin1 10 -lmargin2 10 -spacing2 3 -spacing3 6
        $Text tag configure code          -font QLMono -foreground [::questlog::ui::theme::c body] -lmargin1 10 -lmargin2 10 -spacing2 3 -spacing3 6
        # Inline-span tags carry only a -font; colour and margins keep coming
        # from the body tag, which stays on every prose run (tags stack, and
        # these later tags win on -font). i-code is kept separate from the
        # block code tag so block-fence spacing and inline spans stay decoupled.
        $Text tag configure i-bold       -font QLBodyBold
        $Text tag configure i-italic     -font QLBodyItalic
        $Text tag configure i-bolditalic -font QLBodyBoldItalic
        $Text tag configure i-code       -font QLMono
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

        # Right-click copy (issue #4) and width tracking for the embedded
        # quote boxes that drafts render into.
        my build_menu
        bind $Text <<ContextMenu>> [list [self] on_right %x %y %X %Y]
        bind $Text <Configure>     [list [self] on_resize]

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
        bind $Text <Control-f>  [list [self] find_show]
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
            if {$rec eq ""} continue
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
        set RenderTs 0
        set RenderInSection 0
        foreach rec $Records {
            lassign [my render_record $rec $RenderTs $RenderInSection] \
                RenderTs RenderInSection
        }
        $Text configure -state disabled
    }

    # Render one record at the end of the transcript and return the trailing
    # {last_ts in_section} state it advances: last_ts is the epoch of the most
    # recent content turn (for idle-gap detection), in_section is 1 while a
    # section header is open. Pulled out of render so the wholesale fill and the
    # streamed append (append_new) make identical divider and header decisions.
    # The caller holds $Text in -state normal.
    method render_record {rec last_ts in_section} {
        set t [dict getdef $rec type ""]
        # last-prompt records are repeated, truncated harness snapshots of the
        # most recent user prompt: the harness writes the same value many times,
        # and it echoes the real user turn already shown. Not part of the
        # conversation, so omit it from the reading view.
        if {$t eq "last-prompt"} { return [list $last_ts $in_section] }
        set ts_iso [::questlog::jsonl::record_timestamp $rec]
        set ts_epoch [my parse_iso $ts_iso]
        set lineno [dict get $rec _line]

        # Compact boundary primary divider.
        if {[::questlog::jsonl::is_compact_boundary $rec]} {
            $Text insert end "─── /compact ───\n" compact-divider
            return [list 0 0]
        }

        # Records that carry no text body (permission-mode, file-history
        # snapshots, attachments) head no section and draw no line; they only
        # keep the clock moving for gap detection. Tested before the header so a
        # leading metadata record never leaves a bare section glyph at the top of
        # the transcript. Tool-only assistant turns now render (extract_text
        # emits Tool(args), [thinking], [image] placeholders), so they pass
        # through to the body path below.
        set body [::questlog::jsonl::extract_text $rec]
        if {[::questlog::debug::enabled]} {
            ::questlog::debug::log render "line $lineno type=$t\
                empty=[expr {$body eq ""}]\
                tools=[llength [::questlog::jsonl::record_tool_uses $rec]]"
        }
        if {$body eq ""} {
            if {$ts_epoch > 0} { set last_ts $ts_epoch }
            return [list $last_ts $in_section]
        }

        # Idle-gap secondary divider, between content turns.
        if {$last_ts > 0 && $ts_epoch > 0} {
            set gap [expr {($ts_epoch - $last_ts) / 60}]
            if {$gap >= $IdleGap} {
                $Text insert end "─── [my fmt_gap $gap] later ───\n" divider
                set in_section 0
            }
        }

        if {!$in_section} {
            $Text insert end "[my section_header $ts_iso]\n" section-header
            set in_section 1
        }

        # Map this jsonl line to the current text index.
        set start_idx [$Text index "end-1l linestart"]
        dict set LineMap $lineno $start_idx
        dict set Bodies $lineno $body
        dict set Roles $lineno [string toupper $t]
        set ltag "lbl-$t"
        if {$t ne "user" && $t ne "assistant" && $t ne "system"} {
            set ltag lbl-system
        }
        $Text insert end "[string toupper $t]  " $ltag
        my insert_body $t $body

        if {$ts_epoch > 0} { set last_ts $ts_epoch }
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
        set at_bottom [expr {[lindex [$Text yview] 1] >= 0.999}]
        $Text configure -state normal
        set lineno 0
        set new 0
        while {1} {
            if {[chan gets $fh line] < 0} break
            if {[chan eof $fh]} break
            incr lineno
            if {$lineno <= $LoadedLines} continue
            if {$line eq ""} continue
            set rec [::questlog::jsonl::parse_line $line]
            if {$rec eq ""} continue
            dict set rec _line $lineno
            lappend Records $rec
            lassign [my render_record $rec $RenderTs $RenderInSection] \
                RenderTs RenderInSection
            incr new
        }
        close $fh
        set LoadedLines $lineno
        $Text configure -state disabled
        if {$new > 0 && $at_bottom} { $Text see end }
        return $new
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
        if {$Running} return
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
        set Tick [after 300 [list [self] resume_tick]]
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
            set Tick [after 300 [list [self] resume_tick]]
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
        if {$Tick ne ""} { after cancel $Tick; set Tick "" }
    }

    # The turn's process has closed its output. Reap it for the exit status, do
    # a final tail and bar reset unless detached to another view, and refresh
    # the streamed session's list row so its cost and activity catch up.
    method resume_finish {} {
        if {$Pipe eq ""} return
        if {$Tick ne ""} { after cancel $Tick; set Tick "" }
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
        if {$OnRefresh ne "" && $rpath ne ""} { {*}$OnRefresh $rpath }
    }

    # Insert inline-parsed runs into a text widget. The style->tag mapping lives
    # here so the main pane and the quote boxes render emphasis identically; base
    # is the tag stacked under every run (body in the main pane, none in a box,
    # where the widget's default face already is QLBody).
    method insert_runs {w text base} {
        foreach run [::questlog::jsonl::parse_inline $text] {
            lassign $run style chunk
            set tags $base
            switch -- $style {
                code       { lappend tags i-code }
                bold       { lappend tags i-bold }
                italic     { lappend tags i-italic }
                bolditalic { lappend tags i-bolditalic }
            }
            $w insert end $chunk $tags
        }
    }

    # Insert a prose run into the main reading pane with inline markdown
    # rendered. Each font tag stacks over body, so colour and margins are
    # inherited and only the face changes. The trailing newline(s) are a
    # rendering concern, passed as a suffix rather than parsed.
    method insert_prose {text {suffix "\n\n"}} {
        my insert_runs $Text $text body
        if {$suffix ne ""} { $Text insert end $suffix body }
    }

    # Insert one turn's body. Plain prose goes through insert_prose, which renders
    # inline `code`, *italic* and **bold** spans. A fenced body is split into
    # prose and code runs (fenced code kept verbatim in monospace); a prose run
    # that is an assistant blockquote becomes embedded quote boxes.
    method insert_body {t body} {
        set has_code  [regexp -line {^\s*```} $body]
        set has_quote [expr {$t eq "assistant" && [regexp -line {^>} $body]}]
        if {!$has_code && !$has_quote} {
            my insert_prose $body "\n\n"
            return
        }
        if {!$has_code} {
            my insert_segments $body
            return
        }
        foreach seg [::questlog::jsonl::segment_code_fences $body] {
            lassign $seg kind text
            if {$kind eq "code"} {
                $Text insert end "$text\n" code
            } elseif {$has_quote && [regexp -line {^>} $text]} {
                my insert_segments $text
            } else {
                my insert_prose $text "\n"
            }
        }
        $Text insert end "\n" body
    }

    # Render an assistant body that contains at least one blockquote run:
    # normal text inline, each blockquote run as an embedded box.
    method insert_segments {body} {
        set atstart 0
        foreach seg [::questlog::jsonl::segment_blockquotes $body] {
            lassign $seg kind text
            if {$kind eq "quote"} {
                if {!$atstart} { $Text insert end "\n" body }
                my insert_quote_box $text
                set atstart 1
            } else {
                my insert_prose $text "\n"
                set atstart 1
            }
        }
        $Text insert end "\n" body
    }

    # A de-quoted blockquote run embedded in the reading view. A thin left
    # rule marks it as a quotation; the text follows the reading font. Copy,
    # and a Collapse toggle for long runs, appear only while the pointer is
    # over the quote (see make_overlay). Long runs show full height; Collapse
    # trims to the preview limit.
    method insert_quote_box {dequoted} {
        set qid [incr NextQid]
        set n [llength [split $dequoted "\n"]]
        set limit [::questlog::config::get blockquote_preview_lines]
        set f $Text.q$qid
        # Outer container draws no box. The hover buttons are children of it,
        # pinned to the arrow cursor so they do not inherit the reading text's
        # I-beam.
        tk::frame $f -borderwidth 0 -highlightthickness 0 -cursor arrow
        # The quoted marker: a single muted vertical rule. A classic tk::frame
        # (not ttk) is used because clam ignores -background on ttk frames.
        tk::frame $f.rule -width 3 -background [::questlog::ui::theme::c muted]
        pack $f.rule -side left -fill y
        set bt $f.body
        # No -font of its own: QLBody is the reading font, reconfigured live by
        # the font chooser, so the quote tracks the body. -padx indents the
        # text in from the rule.
        text $bt -wrap word -borderwidth 0 -highlightthickness 0 \
            -height $n -width 1 -cursor arrow -font QLBody
        # Inline spans inside the quote. The box's default face is QLBody, so
        # plain text needs no tag; these variant tags carry only a font and
        # track the reading font just like the main pane's i-* tags.
        $bt tag configure i-bold       -font QLBodyBold
        $bt tag configure i-italic     -font QLBodyItalic
        $bt tag configure i-bolditalic -font QLBodyBoldItalic
        $bt tag configure i-code       -font QLMono
        my insert_runs $bt $dequoted ""
        $bt configure -state disabled
        pack $bt -side left -fill both -expand 1 -padx {8 0}
        bind $bt <Map> [list [self] fit_box $qid]
        $Text window create end -window $f -align top
        $Text insert end "\n"
        dict set Drafts $qid [dict create frame $f body $bt full $dequoted \
            nlines $n limit $limit expanded 1 \
            copybtn "" togglebtn "" hidetimer ""]
        my make_overlay $qid
        my fit_box $qid
    }

    # Build the hover affordances un-placed: Copy always, plus a Collapse
    # toggle for long runs. Entering the quote or any child shows them;
    # leaving hides them. Bound on every descendant so crossing onto a button
    # still counts as inside.
    method make_overlay {qid} {
        set d [dict get $Drafts $qid]
        set f [dict get $d frame]
        set cb $f.copy
        ttk::button $cb -text "Copy" -width 5 \
            -command [list [self] clipboard_set [dict get $d full]]
        dict set Drafts $qid copybtn $cb
        set hover [list $f [dict get $d body] $cb]
        if {[dict get $d nlines] > [dict get $d limit]} {
            set tb $f.toggle
            ttk::button $tb -text "Collapse" -width 8 \
                -command [list [self] toggle_box $qid]
            dict set Drafts $qid togglebtn $tb
            lappend hover $tb
        }
        foreach w $hover {
            bind $w <Enter> [list [self] overlay_show $qid]
            bind $w <Leave> [list [self] overlay_leave $qid]
        }
    }

    # Place Copy top-right and the toggle top-left, over the body text.
    method overlay_show {qid} {
        if {![dict exists $Drafts $qid]} return
        set d [dict get $Drafts $qid]
        set t [dict get $d hidetimer]
        if {$t ne ""} { after cancel $t; dict set Drafts $qid hidetimer "" }
        set cb [dict get $d copybtn]
        place $cb -relx 1.0 -x -2 -rely 0 -y 2 -anchor ne
        raise $cb
        set tb [dict get $d togglebtn]
        if {$tb ne ""} {
            place $tb -relx 0.0 -x 6 -rely 0 -y 2 -anchor nw
            raise $tb
        }
    }

    # Leaving any part of the quote schedules a hide. Deferring to idle lets
    # the matching <Enter> on the button just crossed into cancel it first, so
    # frame-to-button crossings do not dismiss the overlay.
    method overlay_leave {qid} {
        if {![dict exists $Drafts $qid]} return
        set t [after idle [list [self] overlay_check $qid]]
        dict set Drafts $qid hidetimer $t
    }

    method overlay_check {qid} {
        if {![dict exists $Drafts $qid]} return
        dict set Drafts $qid hidetimer ""
        set f [dict get $Drafts $qid frame]
        if {![winfo exists $f]} return
        set w [winfo containing [winfo pointerx .] [winfo pointery .]]
        set inside 0
        while {$w ne "" && $w ne "."} {
            if {$w eq $f} { set inside 1; break }
            set w [winfo parent $w]
        }
        if {!$inside} { my overlay_hide $qid }
    }

    method overlay_hide {qid} {
        if {![dict exists $Drafts $qid]} return
        set d [dict get $Drafts $qid]
        catch {place forget [dict get $d copybtn]}
        set tb [dict get $d togglebtn]
        if {$tb ne ""} { catch {place forget $tb} }
    }

    # Size a box's inner text to the reading column width, and (when
    # expanded) to its full wrapped height. Embedded windows do not stretch
    # on their own, so this runs on creation and on every <Configure>.
    method fit_box {qid} {
        if {![dict exists $Drafts $qid]} return
        set bt [dict get $Drafts $qid body]
        if {![winfo exists $bt]} return
        set px [winfo width $Text]
        set fw [font measure [$bt cget -font] 0]
        if {$fw <= 0} { set fw 7 }
        if {$px <= 1} {
            set cols [::questlog::config::get textbox_default_cols]
        } else {
            set cols [expr {max([::questlog::config::get textbox_min_cols], \
                ($px - [::questlog::config::get textbox_margin_px]) / $fw)}]
        }
        $bt configure -width $cols
        # An off-screen embedded text reports a 1px width, which would make
        # count -displaylines wrap at one character. Only size the expanded
        # height when the box is actually laid out; the <Map> binding redoes
        # it when an off-screen box scrolls into view.
        if {[dict get $Drafts $qid expanded] \
                && [winfo ismapped $bt] && [winfo width $bt] > 1} {
            update idletasks
            set dl [$bt count -displaylines 1.0 "end"]
            $bt configure -height [expr {max(1, $dl)}]
        }
    }

    method toggle_box {qid} {
        if {![dict exists $Drafts $qid]} return
        set d [dict get $Drafts $qid]
        set tb [dict get $d togglebtn]
        if {[dict get $d expanded]} {
            [dict get $d body] configure -height [dict get $d limit]
            catch {$tb configure -text "Expand"}
            dict set Drafts $qid expanded 0
        } else {
            dict set Drafts $qid expanded 1
            catch {$tb configure -text "Collapse"}
            my fit_box $qid
        }
    }

    method on_resize {} {
        dict for {qid d} $Drafts { my fit_box $qid }
    }

    method build_menu {} {
        set Menu $Top.cmenu
        menu $Menu -tearoff 0
        $Menu add command -label "Copy message" \
            -command [list [self] menu_copy_message]
    }

    method clipboard_set {s} { clipboard clear; clipboard append $s }

    # Right-click a turn to copy its whole body. The explicit copy affordance
    # for the viewer (issue #4); per-quote copy is the button inside each box.
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
            $Text see [dict get $LineMap $lineno]
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
        if {$best ne ""} { $Text see $best }
    }

    method find_show {} {
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
        $Text see $idx
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
            set m [$Text search -count len -nocase -- $pattern $start [my content_end]]
            if {$m eq ""} break
            $Text tag add find $m "$m + ${len}c"
            lappend results $m
            set start "$m + ${len}c"
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
                if {$nocase} {
                    set m [$Text search -nocase -count len -- $term $start [my content_end]]
                } else {
                    set m [$Text search -count len -- $term $start [my content_end]]
                }
                if {$m eq ""} break
                if {$len <= 0} { set len 1 }
                $Text tag add find $m "$m + ${len}c"
                lappend positions $m
                set start "$m + ${len}c"
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
        set line [regsub -all {\s+} [string trim [$Text get "$idx linestart" "$idx lineend"]] " "]
        if {[string length $line] > 60} { set line "[string range $line 0 59]…" }
        return $line
    }

    # Fill the match listbox and the head-strip count from the current matches,
    # then open the band on its Matches tab. With no matches (a session opened
    # while browsing) the count is hidden and the band, if it was showing
    # matches, collapses. Auto-opening on every populate is what lands a session
    # click on the index when a search is active, with no second gesture.
    method refresh_match_control {} {
        set n [llength $FindMatches]
        $MatchList delete 0 end
        if {$n == 0} {
            pack forget $MatchBtn
            set MatchCountText ""
            if {$BandOpen && $BandTab eq "matches"} { my band_hide }
            my update_band_tabs
            return
        }
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
        $MatchList configure -height [expr {min($n, 8)}]
        $MatchList selection clear 0 end
        $MatchList selection set 0
        set MatchCountText "$n [expr {$n == 1 ? {match} : {matches}}]"
        # Reserve the count's width on the right before the path fills the rest,
        # so a long file path clips rather than squeezing it out of the strip.
        # Re-packing the path after fixes the order regardless of which packed
        # first.
        pack forget $PathLabel
        pack $MatchBtn -side right -padx 6
        pack $PathLabel -side left -padx 6 -pady 1 -fill x -expand 1
        my band_show matches
    }

    # Row foreground by role, echoing the rendered transcript's role colours.
    method role_color {ty} {
        switch -- $ty {
            USER      { return [::questlog::ui::theme::c user] }
            ASSISTANT { return [::questlog::ui::theme::c assistant] }
            default   { return [::questlog::ui::theme::c tool] }
        }
    }

    # ---- docked band: open/collapse and tab switching --------------------

    # Switch the band's content without changing its open/collapsed state: grid
    # the chosen list into the content cell and remove the other, so only the
    # active list's height drives the band. Re-derives the tab styling and the
    # head-strip glyphs.
    method set_tab {tab} {
        set BandTab $tab
        if {$tab eq "matches"} {
            grid remove $ToolList $Band.toolsb
            grid $MatchList    -row 1 -column 0 -sticky nsew
            grid $Band.matchsb -row 1 -column 1 -sticky ns
        } else {
            grid remove $MatchList $Band.matchsb
            grid $ToolList    -row 1 -column 0 -sticky nsew
            grid $Band.toolsb -row 1 -column 1 -sticky ns
        }
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
    # active tab's count in the band header. Forget both first, then re-pack the
    # present ones in canonical Matches-then-Tools order, so a tab that was
    # hidden for the prior session never re-packs after its sibling.
    method update_band_tabs {} {
        pack forget $TabMatches $TabTools
        set hasm [expr {[llength $FindMatches] > 0}]
        set hast [expr {[llength $ToolLines] > 0}]
        if {$hasm} { pack $TabMatches -side left }
        if {$hast} { pack $TabTools -side left -padx [expr {$hasm ? "10 0" : "0"}] }
        set active     [::questlog::ui::theme::c sessionhead]
        set inactive   [::questlog::ui::theme::c faint]
        $TabMatches configure \
            -foreground [expr {$BandTab eq "matches" ? $active : $inactive}]
        $TabTools configure \
            -foreground [expr {$BandTab eq "tools" ? $active : $inactive}]
        $BandCount configure -text \
            [expr {$BandTab eq "matches" ? $MatchCountText : $ToolCountText}]
    }

    # Keep the ▾/▴ glyph on both head-strip counts: ▴ on the count whose tab is
    # the open front tab, ▾ otherwise. Each count may be unpacked (its list is
    # empty), so guard on existence in the strip.
    method update_band_glyphs {} {
        set mglyph [expr {$BandOpen && $BandTab eq "matches" ? "▴" : "▾"}]
        set tglyph [expr {$BandOpen && $BandTab eq "tools" ? "▴" : "▾"}]
        if {$MatchCountText ne ""} {
            $MatchBtn configure -text "$mglyph $MatchCountText"
        }
        if {$ToolCountText ne ""} {
            $ToolBtn configure -text "$tglyph $ToolCountText"
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
        $Text see [lindex $FindMatches $i]
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

    # Fill the head-strip count and size the listbox from the collected calls,
    # then expose the Tools entry point. With no calls the count is hidden and a
    # band already on Tools collapses. Unlike a search, the audit is opt-in: this
    # never opens the band, it only makes the Tools tab and count available, so
    # the matches that index_matches auto-opened (it runs first) stay in front.
    method refresh_tool_control {} {
        set n [llength $ToolLines]
        if {$n == 0} {
            pack forget $ToolBtn
            set ToolCountText ""
            if {$BandOpen && $BandTab eq "tools"} { my band_hide }
            my update_band_tabs
            return
        }
        $ToolList configure -height [expr {min($n, 8)}]
        $ToolList selection clear 0 end
        set ToolCountText "$n tool [expr {$n == 1 ? {call} : {calls}}]"
        # Reserve the count's width on the strip before the path fills the rest,
        # so a long file path clips rather than squeezing it out.
        pack forget $PathLabel
        pack $ToolBtn -side right -padx 6
        pack $PathLabel -side left -padx 6 -pady 1 -fill x -expand 1
        my update_band_tabs
        my update_band_glyphs
    }

    # Jump the reading view to the clicked call's line.
    method tool_list_select {} {
        set sel [$ToolList curselection]
        if {$sel eq ""} return
        my scroll_to_line [lindex $ToolLines [lindex $sel 0]]
    }
}
