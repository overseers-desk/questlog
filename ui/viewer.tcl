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
    variable PathLabel        ;# header label showing the loaded path
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
    variable MatchBtn         ;# head-strip "N matches" toggle, packed on demand
    variable MatchPanel       ;# floating index panel, placed over the body top-right
    variable MatchList        ;# listbox of per-match rows inside the panel
    variable MatchLabels      ;# per-match one-line excerpt, parallel to FindMatches
    variable Roles            ;# dict: jsonl line -> uppercased role, for row colour
    variable OnToggle         ;# cb: () -> ask the app to fold/unfold the list pane
    variable CollapseBtn      ;# the header toggle label
    variable IconOpen         ;# toggle photo, list shown (solid left pane)
    variable IconClosed       ;# toggle photo, list hidden (dim left pane)

    constructor {parent {on_toggle ""}} {
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
        set Roles [dict create]
        set OnToggle $on_toggle
        my build
    }

    # Load a session and anchor to a line (1-based; 0 means top). Replaces
    # whatever was shown before. `query` is the active search ({terms <list>
    # nocase 0|1}, or {}); its terms are matched literally, highlighted, and
    # listed in the floating match index.
    method show {jsonl_path {scroll_to_line 0} {query {}}} {
        if {!$Shown} {
            grid remove $Empty
            grid $Text        -row 0 -column 0 -sticky nsew
            grid $Top.body.sb -row 0 -column 1 -sticky ns
            set Shown 1
        }
        set Path $jsonl_path
        set Records [list]
        set LineMap [dict create]
        $PathLabel configure -text $Path
        my find_hide
        my load
        my render
        my index_matches $query
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
        set strip [::questlog::theme::c strip]
        frame $Top.head -background $strip
        pack $Top.head -side top -fill x
        label $Top.head.path -text "no session selected" -background $strip \
            -anchor w -font QLMono -foreground [::questlog::theme::c muted]
        pack $Top.head.path -side left -padx 6 -pady 1 -fill x -expand 1
        set PathLabel $Top.head.path
        # Match index: a count on the right of the head strip that toggles the
        # floating index panel (built below). It carries the count even while
        # the panel is dismissed and re-shows it when clicked; its glyph reads
        # ▾ closed, ▴ open. Packed on demand by refresh_match_control; absent
        # when the session was opened without a search.
        label $Top.head.matches -text "" -background $strip \
            -foreground [::questlog::theme::c sessionhead] -cursor hand2
        set MatchBtn $Top.head.matches
        bind $MatchBtn <Button-1> [list [self] match_panel_toggle]
        # Reading-font picker at the right of the head strip: a plain label
        # affordance (matching the strip's flat look) that pops the platform
        # font chooser. Packed once, always present; the match toggle packs to
        # its left when a search is active.
        label $Top.head.font -text "Font…" -background $strip \
            -foreground [::questlog::theme::c sessionhead] -cursor hand2
        # -before the path so this fixed-width control keeps its slot: the path
        # label expands and, once a long session path is loaded, its requested
        # width would otherwise claim the whole strip and squeeze this out.
        pack $Top.head.font -side right -padx 6 -before $Top.head.path
        bind $Top.head.font <Button-1> [list [self] choose_font]

        # Sidebar toggle at the far left of the strip (Ctrl+B's mouse twin). The
        # design icon (screens.jsx SessionViewer) is a panel outline with a
        # filled left pane and a divider; the left pane is solid when the list is
        # shown and dim when hidden, so the icon states the current mode. Two
        # photos, swapped by set_collapsed. It is the always-visible hint that
        # the list is foldable and reopenable. Core Tk 9 decodes SVG with no
        # extension; if a build cannot, make_toggle_icon returns "" and a text
        # glyph stands in.
        set IconOpen   [my make_toggle_icon [::questlog::theme::c muted] \
                            [::questlog::theme::c muted]]
        set IconClosed [my make_toggle_icon [::questlog::theme::c muted] \
                            [::questlog::theme::c faint]]
        set CollapseBtn $Top.head.collapse
        if {$IconOpen ne ""} {
            label $CollapseBtn -image $IconOpen -background $strip -cursor hand2
        } else {
            label $CollapseBtn -text "◫" -background $strip -cursor hand2 \
                -foreground [::questlog::theme::c muted]
        }
        pack $CollapseBtn -side left -padx {6 2} -before $Top.head.path
        bind $CollapseBtn <Button-1> [list [self] do_toggle]

        ttk::frame $Top.body
        pack $Top.body -side top -fill both -expand 1
        # text widget - no ttk equivalent.
        text $Top.body.t -wrap word -yscrollcommand [list $Top.body.sb set] \
            -state disabled -padx 10 -pady 6 -borderwidth 0 -highlightthickness 0
        ttk::scrollbar $Top.body.sb -orient vertical -command [list $Top.body.t yview]
        grid $Top.body.t  -row 0 -column 0 -sticky nsew
        grid $Top.body.sb -row 0 -column 1 -sticky ns
        grid columnconfigure $Top.body 0 -weight 1
        grid rowconfigure    $Top.body 0 -weight 1
        set Text $Top.body.t

        # Empty state: a centered prompt for the open gesture, gridded into the
        # same body cell as the text so the head+body silhouette is identical
        # whether empty or loaded. Shown at launch (the text and its scrollbar
        # start grid-removed); the first `show` swaps them in.
        ttk::frame $Top.body.empty
        grid $Top.body.empty -row 0 -column 0 -columnspan 2 -sticky nsew
        grid rowconfigure    $Top.body.empty {0 2} -weight 1
        grid columnconfigure $Top.body.empty {0 2} -weight 1
        ttk::frame $Top.body.empty.box
        ttk::label $Top.body.empty.box.msg -justify center -font QLBold \
            -foreground [::questlog::theme::c section] \
            -text "Click a session to show it here"
        ttk::label $Top.body.empty.box.sub -justify center -wraplength 340 \
            -foreground [::questlog::theme::c muted] \
            -text "A single click loads the transcript here. After a search, the match index up top jumps to each hit."
        pack $Top.body.empty.box.msg -side top -pady {0 6}
        pack $Top.body.empty.box.sub -side top
        grid $Top.body.empty.box -row 1 -column 1
        set Empty $Top.body.empty
        grid remove $Top.body.t $Top.body.sb

        # Floating match index. A panel placed over the body's top-right;
        # `place` is independent of the text's yview, so it stays put as the
        # transcript scrolls under it (a true float, not an embedded window
        # that would scroll away). Each row jumps the reading view to that
        # match's line, the way an in-page anchor does. ✕ dismisses it; the
        # head-strip count re-shows it. Sized to its rows (capped at 8), not to
        # a fixed fraction, so it stays a limited-height index and lets content
        # drive its height. Created hidden; refresh_match_control places it
        # when a session opens with matches.
        set MatchPanel $Top.body.matches
        ttk::frame $MatchPanel -relief solid -borderwidth 1
        ttk::frame $MatchPanel.hdr
        ttk::label $MatchPanel.hdr.title -text "" -foreground [::questlog::theme::c folder]
        ttk::label $MatchPanel.hdr.close -text "✕" \
            -foreground [::questlog::theme::c muted] -cursor hand2
        pack $MatchPanel.hdr.title -side left -padx 6 -pady 1
        pack $MatchPanel.hdr.close -side right -padx 4
        bind $MatchPanel.hdr.close <Button-1> [list [self] match_panel_hide]
        set MatchList $MatchPanel.list
        listbox $MatchList -height 1 -width 44 -activestyle none \
            -borderwidth 0 -highlightthickness 0 \
            -yscrollcommand [list $MatchPanel.sb set]
        ttk::scrollbar $MatchPanel.sb -orient vertical \
            -command [list $MatchList yview]
        bind $MatchList <<ListboxSelect>> [list [self] match_list_select]
        grid $MatchPanel.hdr -row 0 -column 0 -columnspan 2 -sticky ew
        grid $MatchList      -row 1 -column 0 -sticky nsew
        grid $MatchPanel.sb  -row 1 -column 1 -sticky ns
        grid columnconfigure $MatchPanel 0 -weight 1
        grid rowconfigure    $MatchPanel 1 -weight 1

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
            -spacing1 10 -spacing3 4 -foreground [::questlog::theme::c section]
        $Text tag configure divider -justify center -font QLMono \
            -foreground [::questlog::theme::c muted] -spacing1 6 -spacing3 6
        $Text tag configure compact-divider -justify center -font QLMono \
            -foreground [::questlog::theme::c compact] -spacing1 8 -spacing3 8
        # Colour marks only the role label (monospace bold, design role fg); the
        # message body is neutral ink, so the transcript reads as prose with a
        # coloured speaker tag, not a wall of tinted text.
        $Text tag configure lbl-user      -foreground [::questlog::theme::c user]      -font QLMonoBold -lmargin1 10 -lmargin2 10 -spacing1 6
        $Text tag configure lbl-assistant -foreground [::questlog::theme::c assistant] -font QLMonoBold -lmargin1 10 -lmargin2 10 -spacing1 6
        $Text tag configure lbl-system    -foreground [::questlog::theme::c tool]      -font QLMonoBold -lmargin1 10 -lmargin2 10 -spacing1 6
        # Body prose follows QLBody, the proportional reading font switched at
        # runtime; fenced code keeps QLMono so it stays aligned regardless of
        # the reading font. Without an explicit -font the text widget would
        # render both in its TkFixedFont default.
        $Text tag configure body          -font QLBody -foreground [::questlog::theme::c body] -lmargin1 10 -lmargin2 10 -spacing2 3 -spacing3 6
        $Text tag configure code          -font QLMono -foreground [::questlog::theme::c body] -lmargin1 10 -lmargin2 10 -spacing2 3 -spacing3 6
        # Inline-span tags carry only a -font; colour and margins keep coming
        # from the body tag, which stays on every prose run (tags stack, and
        # these later tags win on -font). i-code is kept separate from the
        # block code tag so block-fence spacing and inline spans stay decoupled.
        $Text tag configure i-bold       -font QLBodyBold
        $Text tag configure i-italic     -font QLBodyItalic
        $Text tag configure i-bolditalic -font QLBodyBoldItalic
        $Text tag configure i-code       -font QLMono
        $Text tag configure recap     -background [::questlog::theme::c recap]
        $Text tag configure find      -background [::questlog::theme::c find]

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

    # Apply a chosen font to the reading body. Reconfiguring the named QLBody
    # reflows every body-tagged run; fenced code (QLMono) is untouched.
    method on_font_chosen {fontspec args} {
        ::questlog::theme::set_body_font $fontspec
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
    }

    method render {} {
        $Text configure -state normal
        $Text delete 1.0 end
        set Roles [dict create]

        set last_ts 0
        set in_section 0
        foreach rec $Records {
            set t [dict getdef $rec type ""]
            # last-prompt records are repeated, truncated harness snapshots of
            # the most recent user prompt: the harness writes the same value
            # many times, and it echoes the real user turn already shown. Not
            # part of the conversation, so omit it from the reading view.
            if {$t eq "last-prompt"} continue
            set ts_iso [::questlog::jsonl::record_timestamp $rec]
            set ts_epoch [my parse_iso $ts_iso]
            set lineno [dict get $rec _line]

            # Compact boundary primary divider.
            if {[::questlog::jsonl::is_compact_boundary $rec]} {
                $Text insert end "─── /compact ───\n" compact-divider
                set in_section 0
                set last_ts 0
                continue
            }

            # Records that carry no text body (permission-mode, file-history
            # snapshots, attachments, tool-only turns) head no section and draw
            # no line; they only keep the clock moving for gap detection. Tested
            # before the header so a leading metadata record never leaves a bare
            # section glyph at the top of the transcript.
            set body [::questlog::jsonl::extract_text $rec]
            if {$body eq ""} {
                if {$ts_epoch > 0} { set last_ts $ts_epoch }
                continue
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
        }
        $Text configure -state disabled
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
        tk::frame $f.rule -width 3 -background [::questlog::theme::c muted]
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

    method parse_iso {ts_iso} {
        if {$ts_iso eq ""} { return 0 }
        # Claude stamps millisecond precision (2026-05-24T22:29:21.279Z). Tcl's
        # clock scan has no fractional-second specifier, so drop the fraction
        # before the Z and parse the second-resolution remainder as UTC.
        regsub {\.[0-9]+Z$} $ts_iso {Z} ts_iso
        if {[catch {clock scan $ts_iso -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1} e]} {
            return 0
        }
        return $e
    }

    method fmt_gap {minutes} {
        if {$minutes < 60} { return "${minutes} min" }
        if {$minutes < 60*24} {
            set h [expr {$minutes / 60}]
            set m [expr {$minutes % 60}]
            if {$m == 0} { return "${h} hr" }
            return "${h} hr $m min"
        }
        set d [expr {$minutes / (60*24)}]
        return "${d} day(s)"
    }

    method scroll_to_line {lineno} {
        if {[dict exists $LineMap $lineno]} {
            $Text see [dict get $LineMap $lineno]
        }
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
            set m [$Text search -count len -nocase -- $pattern $start end]
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
    # term before any term repeats), and show the floating match index. Terms
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
                    set m [$Text search -nocase -count len -- $term $start end]
                } else {
                    set m [$Text search -count len -- $term $start end]
                }
                if {$m eq ""} break
                if {$len <= 0} { set len 1 }
                $Text tag add find $m "$m + ${len}c"
                lappend positions $m
                set start "$m + ${len}c"
            }
            if {[llength $positions] > 0} { lappend per_term $positions }
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
    # dropdown entry.
    method match_context {idx} {
        set line [regsub -all {\s+} [string trim [$Text get "$idx linestart" "$idx lineend"]] " "]
        if {[string length $line] > 60} { set line "[string range $line 0 59]…" }
        return $line
    }

    # Fill the floating index and the head-strip count from the current
    # matches, then open the panel. With no matches (a session opened while
    # browsing) both are hidden. Opening on every populate is what lands a
    # session click on the index when a search is active, with no second
    # gesture.
    method refresh_match_control {} {
        set n [llength $FindMatches]
        $MatchList delete 0 end
        if {$n == 0} {
            pack forget $MatchBtn
            place forget $MatchPanel
            return
        }
        set i 0
        foreach m $FindMatches lab $MatchLabels {
            set ln [my line_at $m]
            set ty [expr {[dict exists $Roles $ln] ? [dict get $Roles $ln] : ""}]
            set tail [expr {$ln eq "" ? "" : " · line $ln"}]
            $MatchList insert end "$ty · …$lab…$tail"
            $MatchList itemconfigure $i -foreground [my role_color $ty]
            incr i
        }
        $MatchList configure -height [expr {min($n, 8)}]
        $MatchList selection clear 0 end
        $MatchList selection set 0
        $MatchPanel.hdr.title configure -text \
            "$n [expr {$n == 1 ? {match} : {matches}}]"
        # Reserve the count's width on the right before the path fills the rest,
        # so a long file path clips rather than squeezing it out of the strip.
        # Re-packing the path after fixes the order regardless of which packed
        # first.
        pack forget $PathLabel
        pack $MatchBtn -side right -padx 6
        pack $PathLabel -side left -padx 6 -pady 1 -fill x -expand 1
        my match_panel_show
    }

    # Row foreground by role, echoing the rendered transcript's role colours.
    method role_color {ty} {
        switch -- $ty {
            USER      { return [::questlog::theme::c user] }
            ASSISTANT { return [::questlog::theme::c assistant] }
            default   { return [::questlog::theme::c tool] }
        }
    }

    # Place the panel over the body's top-right, offset left of the scrollbar
    # so the drag thumb stays reachable; `raise` keeps it above the text. The
    # head-strip glyph turns up (▴) to read as open.
    method match_panel_show {} {
        if {[llength $FindMatches] == 0} return
        place $MatchPanel -relx 1.0 -x -18 -rely 0 -y 2 -anchor ne
        raise $MatchPanel
        $MatchBtn configure -text "▴ [$MatchPanel.hdr.title cget -text]"
    }

    method match_panel_hide {} {
        place forget $MatchPanel
        $MatchBtn configure -text "▾ [$MatchPanel.hdr.title cget -text]"
    }

    method match_panel_toggle {} {
        if {[winfo ismapped $MatchPanel]} {
            my match_panel_hide
        } else {
            my match_panel_show
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
}
