package require Tcl 9
package require Tk

# ===== TRIM-AFTER ~2026-06-05 (issue #4): always-on autoscroll capture =====
# The native drag-select guards in Viewer build are parked (the `if {0}`
# block). Until the root cause is found, capture every tk::TextAutoScan tick
# plus the pointer press/release/motion stream to a persistent log, so a
# once-a-week autoscroll runaway is recorded without anyone watching for it.
# Each line is flushed, so a force-killed app still keeps what it logged.
# The log lives at /var/local/log/questlog/autoscroll.log; it is a temporary
# diagnostic, not a feature, and goes away with this block once the cause is
# found (see issue #4). After about a week of capture, read that log, then
# either fix the cause and remove this diagnostic or restore the guards.
namespace eval ::questlog::ui::diag {
    variable Chan ""
}

proc ::questlog::ui::diag::log {msg} {
    variable Chan
    if {$Chan eq ""} return
    catch { puts $Chan "[clock milliseconds] $msg"; flush $Chan }
}

# The shared pointer/scroll state Tk drives drag-select and autoscan from.
proc ::questlog::ui::diag::state {} {
    set out ""
    foreach k {buttons window mouseMoved afterId pressX pressY x y} {
        if {[info exists ::tk::Priv($k)]} { append out " $k=[set ::tk::Priv($k)]" }
    }
    return "$out grab=[grab current]"
}

# Open the log (append) and wrap tk::TextAutoScan once. The log dir is
# provisioned once, out of band; this diagnostic does no filesystem mutation,
# since `file mkdir` is trapped to ::questlog::path::* (see lib/path.tcl). If
# the dir is absent the open fails and we say so, loudly, on stderr: a silent
# miss wastes a week of waiting. Idempotent across calls.
proc ::questlog::ui::diag::init {} {
    variable Chan
    if {$Chan ne ""} return
    set path /var/local/log/questlog/autoscroll.log
    if {[catch {open $path a} ch]} {
        puts stderr "questlog diag: cannot open $path (does its dir exist?): $ch"
        return
    }
    set Chan $ch
    log "==== started pid [pid] [clock format [clock seconds]] ===="
    if {[llength [info commands ::tk::TextAutoScan_preissue4]] == 0} {
        rename ::tk::TextAutoScan ::tk::TextAutoScan_preissue4
        proc ::tk::TextAutoScan {w} {
            ::questlog::ui::diag::log "AUTOSCAN w=$w[::questlog::ui::diag::state]"
            ::tk::TextAutoScan_preissue4 $w
        }
    }
}
# ===== end TRIM-AFTER block (issue #4) =====================================

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

    constructor {parent} {
        set Top $parent
        set Shown 0
        set Path ""
        set IdleGap 10
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

        # ===== TRIM-AFTER ~2026-06-05 (issue #4) ====================
        # Parked native-drag-select guards plus the always-on autoscroll
        # capture (the log setup and the tk::TextAutoScan wrap live in the
        # diag namespace at the top of this file). Restore the guards by
        # flipping `if {0}` to `if {1}`; remove the whole diagnostic, here
        # and at the top, once the root cause is found.
        #
        # A read-only reading view. Keep <Button-1> (focus, for Ctrl-F) but
        # block the drag-select gestures: tk::TextSelectTo / tk::TextAutoScan
        # would otherwise run a self-scrolling drag-select, painting the whole
        # view grey. -exportselection 0 keeps it off the X PRIMARY clipboard.
        if {0} {
        $Text configure -exportselection 0 -inactiveselectbackground ""
        foreach ev {<B1-Motion> <Double-Button-1> <Triple-Button-1> \
                    <B1-Leave> <B1-Enter>} {
            bind $Text $ev break
        }
        }

        # Capture the autoscroll: diag::init wraps tk::TextAutoScan (every
        # scroll tick logs with state); these bindings add this view's
        # press/release/motion context. F8 forces an on-demand state dump.
        ::questlog::ui::diag::init
        bind $Text <Button-1>        {+::questlog::ui::diag::log "PRESS  [::questlog::ui::diag::state]"}
        bind $Text <ButtonRelease-1> {+::questlog::ui::diag::log "RELEASE[::questlog::ui::diag::state]"}
        bind $Text <B1-Motion>       {+::questlog::ui::diag::log "MOTION x=%x y=%y[::questlog::ui::diag::state]"}
        bind . <F8>                  {+::questlog::ui::diag::log "F8DUMP [::questlog::ui::diag::state]"}
        # ===== end TRIM-AFTER block (issue #4) ======================

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
            set t [::questlog::jsonl::dict_get_or $rec type ""]
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

    # Insert one turn's body. The common case (no fenced code, no blockquote)
    # is one tagged run, byte-identical to the prior renderer. A fenced body is
    # split into prose and code runs, code kept monospace; a prose run that is
    # an assistant blockquote still becomes embedded quote boxes.
    method insert_body {t body} {
        set has_code  [regexp -line {^\s*```} $body]
        set has_quote [expr {$t eq "assistant" && [regexp -line {^>} $body]}]
        if {!$has_code && !$has_quote} {
            $Text insert end "$body\n\n" body
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
                $Text insert end "$text\n" body
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
                $Text insert end "$text\n" body
                set atstart 1
            }
        }
        $Text insert end "\n" body
    }

    # A de-quoted blockquote run as a bordered box embedded in the reading
    # view: caption, a Copy button (full de-quoted text), and an Expand
    # toggle when the run is longer than the preview limit.
    method insert_quote_box {dequoted} {
        set qid [incr NextQid]
        set n [llength [split $dequoted "\n"]]
        set limit 6
        set f $Text.q$qid
        # The box is a child of the reading text widget, whose cursor is the
        # xterm I-beam; an empty ttk cursor inherits it, so the buttons would
        # show the I-beam. Pin an arrow here; the inner text keeps its xterm.
        ttk::frame $f -relief solid -borderwidth 1 -padding 2 -cursor arrow
        ttk::frame $f.hdr
        ttk::label $f.hdr.cap -text "Quote" -foreground [::questlog::theme::c muted]
        pack $f.hdr.cap -side left -padx 4
        ttk::button $f.hdr.copy -text "Copy" -width 5 \
            -command [list [self] clipboard_set $dequoted]
        pack $f.hdr.copy -side right -padx 2
        if {$n > $limit} {
            ttk::button $f.hdr.toggle -text "Expand" -width 8 \
                -command [list [self] toggle_box $qid]
            pack $f.hdr.toggle -side right -padx 2
        }
        pack $f.hdr -side top -fill x
        set bt $f.body
        text $bt -wrap word -borderwidth 0 -highlightthickness 0 \
            -height [expr {$n > $limit ? $limit : $n}] -width 1
        $bt insert end $dequoted
        $bt configure -state disabled
        pack $bt -side top -fill both -expand 1
        bind $bt <Map> [list [self] fit_box $qid]
        $Text window create end -window $f -align top
        $Text insert end "\n"
        dict set Drafts $qid [dict create frame $f body $bt full $dequoted \
            nlines $n limit $limit expanded 0]
        my fit_box $qid
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
            set cols 80
        } else {
            set cols [expr {max(10, ($px - 60) / $fw)}]
        }
        $bt configure -width $cols
        # An off-screen embedded text reports a 1px width, which would make
        # count -displaylines wrap at one character. Only size the expanded
        # height when the box is actually laid out; the <Map> binding redoes
        # it when an off-screen box scrolls into view.
        if {[dict get $Drafts $qid expanded] \
                && [winfo ismapped $bt] && [winfo width $bt] > 1} {
            update idletasks
            set dl [$bt count -displaylines 1.0 "end-1c"]
            $bt configure -height [expr {max(1, $dl)}]
        }
    }

    method toggle_box {qid} {
        if {![dict exists $Drafts $qid]} return
        set d [dict get $Drafts $qid]
        set f [dict get $d frame]
        if {[dict get $d expanded]} {
            [dict get $d body] configure -height [dict get $d limit]
            catch {$f.hdr.toggle configure -text "Expand"}
            dict set Drafts $qid expanded 0
        } else {
            dict set Drafts $qid expanded 1
            catch {$f.hdr.toggle configure -text "Collapse"}
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
    # transcript, remember them in document order, and show the floating match
    # index. Terms are matched literally (the search bar is Google-style, not
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
        set hits [list]
        foreach term $terms {
            if {$term eq ""} continue
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
                lappend hits $m
                set start "$m + ${len}c"
            }
        }
        foreach m [lsort -unique -command [list [self] cmp_index] $hits] {
            lappend FindMatches $m
            lappend MatchLabels [my match_context $m]
        }
        my refresh_match_control
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
