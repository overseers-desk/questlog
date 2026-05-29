package require Tcl 9
package require Tk

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

    constructor {parent} {
        set Top $parent
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
        my build
    }

    # Load a session and anchor to a line (1-based; 0 means top). Replaces
    # whatever was shown before.
    method show {jsonl_path {scroll_to_line 0}} {
        set Path $jsonl_path
        set Records [list]
        set LineMap [dict create]
        $PathLabel configure -text $Path
        my find_hide
        my load
        my render
        if {$scroll_to_line > 0} {
            my scroll_to_line $scroll_to_line
        } else {
            $Text see 1.0
        }
    }

    method build {} {
        ttk::frame $Top
        ttk::frame $Top.head
        pack $Top.head -side top -fill x
        ttk::label $Top.head.path -text ""
        pack $Top.head.path -side left -padx 4 -pady 2
        set PathLabel $Top.head.path

        ttk::frame $Top.body
        pack $Top.body -side top -fill both -expand 1
        # text widget - no ttk equivalent.
        text $Top.body.t -wrap word -yscrollcommand [list $Top.body.sb set] \
            -state disabled
        ttk::scrollbar $Top.body.sb -orient vertical -command [list $Top.body.t yview]
        grid $Top.body.t  -row 0 -column 0 -sticky nsew
        grid $Top.body.sb -row 0 -column 1 -sticky ns
        grid columnconfigure $Top.body 0 -weight 1
        grid rowconfigure    $Top.body 0 -weight 1
        set Text $Top.body.t

        # ===== TRIM-AFTER 2026-06-05 (issue #4) =====================
        # Autoscroll diagnostic plus parked guards. Native drag-select is on
        # under a no-incident watch. Remove this whole marked block (down to
        # the matching end marker) if no autoscroll incident by the date above;
        # if one recurs, re-enable the guards by flipping `if {0}` to `if {1}`.
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

        # DIAGNOSTIC (issue #4): log pointer events on the session viewer and
        # dump Tk's shared button/grab/autoscan state on F12. Revert.
        bind $Text <Button-1>        {+puts stderr "DIAG press    [clock milliseconds] state=%s"}
        bind $Text <ButtonRelease-1> {+puts stderr "DIAG release  [clock milliseconds] state=%s"}
        bind $Text <B1-Motion>       {+puts stderr "DIAG b1motion [clock milliseconds] state=%s"}
        bind . <F8> {
            puts stderr "==== tk::Priv DUMP [clock milliseconds] ===="
            foreach _k {buttons window mouseMoved afterId pressX pressY} {
                if {[info exists ::tk::Priv($_k)]} {
                    puts stderr "  Priv($_k) = [set ::tk::Priv($_k)]"
                }
            }
            puts stderr "  grab current = [grab current]"
        }
        # ===== end TRIM-AFTER 2026-06-05 block ======================

        # Tags.
        $Text tag configure section-header -font {-weight bold -size 11} \
            -spacing1 8 -spacing3 4 -foreground "#444"
        $Text tag configure divider -justify center -foreground "#888" \
            -spacing1 6 -spacing3 6
        $Text tag configure compact-divider -justify center -foreground "#a33" \
            -spacing1 8 -spacing3 8 -font {-weight bold}
        $Text tag configure user      -foreground "#06c" -lmargin1 8 -lmargin2 8
        $Text tag configure assistant -foreground "#222" -lmargin1 8 -lmargin2 8
        $Text tag configure system    -foreground "#a60" -lmargin1 8 -lmargin2 8
        $Text tag configure recap     -background "#ffefd0"
        $Text tag configure find      -background yellow

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

    method load {} {
        set fh [open $Path r]
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

            # Idle-gap secondary divider.
            if {$last_ts > 0 && $ts_epoch > 0} {
                set gap [expr {($ts_epoch - $last_ts) / 60}]
                if {$gap >= $IdleGap} {
                    $Text insert end "─── [my fmt_gap $gap] later ───\n" divider
                    set in_section 0
                }
            }

            if {!$in_section} {
                set hdr [my section_header $ts_iso]
                $Text insert end "$hdr\n" section-header
                set in_section 1
            }

            # Map this jsonl line to the current text index.
            set start_idx [$Text index "end-1l linestart"]
            dict set LineMap $lineno $start_idx

            set body [::questlog::jsonl::extract_text $rec]
            if {$body eq ""} {
                # Skip records that contribute no text body.
                if {$ts_epoch > 0} { set last_ts $ts_epoch }
                continue
            }
            dict set Bodies $lineno $body
            set tag $t
            if {$t eq "user" || $t eq "assistant" || $t eq "system"} {
                # use the type as the tag name
            } else {
                set tag system
            }
            $Text insert end "[string toupper $t]: " "$tag section-header"
            if {$t eq "assistant" && [regexp -line {^>} $body]} {
                my insert_segments $body $tag
            } else {
                $Text insert end "$body\n\n" $tag
            }

            if {$ts_epoch > 0} { set last_ts $ts_epoch }
        }
        $Text configure -state disabled
    }

    # Render an assistant body that contains at least one blockquote run:
    # normal text inline, each blockquote run as an embedded box.
    method insert_segments {body roletag} {
        set atstart 0
        foreach seg [::questlog::jsonl::segment_blockquotes $body] {
            lassign $seg kind text
            if {$kind eq "quote"} {
                if {!$atstart} { $Text insert end "\n" $roletag }
                my insert_quote_box $text
                set atstart 1
            } else {
                $Text insert end "$text\n" $roletag
                set atstart 1
            }
        }
        $Text insert end "\n" $roletag
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
        ttk::label $f.hdr.cap -text "Quote" -foreground "#888"
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
        if {[catch {clock scan $ts_iso -format "%Y-%m-%dT%H:%M:%S.%QZ" -gmt 1} e]} {
            if {[catch {clock scan $ts_iso -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1} e]} {
                return 0
            }
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
}
