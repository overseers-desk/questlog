package require Tcl 9
package require Tk
package require logman
package require streamdoc
package require tkdown
package provide showman 0.1

# showman - a Claude Code session transcript as a foldable, searchable
# conversation view: the display base class questlog's own viewer and a live
# chat both subclass.
#
# ::showman::Showman subclasses ::streamdoc::StreamDoc (one region per
# turn; the base class owns the marks and both elide layers) and adds the
# transcript skin over it:
#   - record rendering (render_records / append_records): parsed jsonl records
#     in, logman supplying the record semantics (turn starts, role labels,
#     content blocks, dividers), tkdown supplying markdown-to-Tk. Each turn
#     folds to its header line; tool_use / thinking / tool_result blocks are
#     detail, hidden behind a trailing stub ("· N tool calls · M thinking").
#   - find (Ctrl-F): an overlay bar under the text; collect_matches tags hits
#     `find` (reaching into elided detail), find_next steps with wraparound
#     and reveals the hit through the one jump gate (reveal_index).
#   - a LIVE turn (the reason this base exists): live_open starts a growing
#     turn, live_write streams text into it in place (savepoint/rewind: each
#     chunk re-renders the provisional message tail, so markdown that
#     completes across chunks settles correctly), live_set is its repaint
#     twin for hosts whose frames repeat the message's whole text (replace,
#     not append), live_working rides a "working…" marker on the base
#     class's summary transaction, and live_close seals the region.
#     append_records drops finished records (tool calls, results) into the
#     open turn between streamed messages.
#
# Display-only: Showman knows nothing about claude, processes, files or
# the API. A subclass owns where records come from and what happens around
# the view.
#
# Widget options (through the streamdoc option door; `configure` before or at
# construction):
#   -palette dict   colour roles: section muted faint body user assistant
#                   system tool_result find. Defaults are a plain light look.
#   -fonts dict     tkdown font names {body bold italic bolditalic mono};
#                   "" (the default) derives SV* named fonts from Tk's.
#   -idle_gap min   minutes of silence that draw an idle-gap divider.
# plus streamdoc's own: -font -glyphs -autofollow.

namespace eval ::showman {}

# The derived named fonts the default look reads: body faces from TkTextFont,
# mono faces from TkFixedFont. Created once per interp; a host that passes
# -fonts and -font uses its own and these still exist harmlessly.
proc ::showman::ensure_fonts {} {
    if {"SVBody" in [font names]} return
    font create SVBody           {*}[font actual TkTextFont]
    font create SVBodyBold       {*}[font actual TkTextFont] -weight bold
    font create SVBodyItalic     {*}[font actual TkTextFont] -slant italic
    font create SVBodyBoldItalic {*}[font actual TkTextFont] -weight bold -slant italic
    font create SVMono           {*}[font actual TkFixedFont]
    font create SVMonoBold       {*}[font actual TkFixedFont] -weight bold
}

oo::class create ::showman::Showman {
    superclass ::streamdoc::StreamDoc

    # Top and Text are the streamdoc base class's (same object namespace);
    # declared here so this class's methods read them.
    variable Top
    variable Text
    variable Records          ;# parsed records rendered, in document order
    variable Pending          ;# a trailing turn start held back from the last append batch
    variable LineMap          ;# dict: record _line -> text index of its label line
    variable NextLine         ;# highest _line seen; numbers records that carry none
    variable RenderTs         ;# trailing render state: epoch of the last content record
    variable RenderInSection  ;# trailing render state: 1 while a section header is open
    variable Find             ;# find overlay frame
    variable FindVar          ;# find entry text
    variable FindMatches      ;# list of indices of all current matches
    variable FindCur          ;# 0-based hit last shown (-1 = none shown yet)
    variable FindPos          ;# find-bar "N of M" readout text ("" while cleared)
    variable LastFindVar      ;# the term collect_matches last ran, for drift detection
    variable StreamSp         ;# savepoint of the live streamed message ("" between messages)
    variable StreamBuf        ;# the streamed message's accumulated source text
    variable StreamRole       ;# the streamed message's role (labels its first render)
    variable StreamSetId      ;# the id of the message live_set is repainting ("" between)

    constructor {parent args} {
        my configure -autofollow 1
        if {[llength $args]} { my configure {*}$args }
        my setup $parent
    }

    # Assemble the view into `parent`: the base class's text and scrollbar,
    # this class's tags and find bar, and a seeded document. A subclass with
    # bespoke widget assembly (its own text widget in Text, its own find
    # overlay) skips this and ends its build with `my reset` instead - the
    # streamdoc pattern one level up.
    method setup {parent} {
        ::showman::ensure_fonts
        next $parent
        my build_tags
        my build_find
        my reset
    }

    # ---- options -----------------------------------------------------------
    #
    # The base class validates against default_opts, so extending the dict
    # here is what admits -palette/-fonts/-idle_gap through its `configure`.
    method default_opts {} {
        set d [next]
        dict set d font SVBody
        dict set d fonts ""
        dict set d idle_gap 10
        dict set d palette [dict create \
            section     #57606a \
            muted       #6a737d \
            faint       #a8b0b8 \
            body        #1f2328 \
            user        #0a5bd3 \
            assistant   #116329 \
            system      #9a6700 \
            tool_result #6639ba \
            find        #fff8c5]
        return $d
    }

    # One palette colour, by role name.
    method color {k} { return [dict get [my opt palette] $k] }

    # The reading text widget, so a host can bind or focus it.
    method textwidget {} { return $Text }

    # ---- body assembly -----------------------------------------------------

    # Tags over the document, colours from the palette. Order is priority:
    # later-configured tags win where they stack, so tkdown's td-* faces go
    # after body/code (they must win on -font) and `find` goes last (its
    # highlight must win on -background).
    method build_tags {} {
        $Text tag configure section-header -font SVMono \
            -spacing1 10 -spacing3 4 -foreground [my color section]
        $Text tag configure divider -justify center -font SVMono \
            -foreground [my color muted] -spacing1 6 -spacing3 6
        $Text tag configure compact-divider -justify center -font SVMono \
            -foreground [my color muted] -spacing1 8 -spacing3 8
        # Colour marks only the role label; the body is neutral ink, so the
        # transcript reads as prose with a coloured speaker tag.
        foreach {role key} {user user assistant assistant system system \
                            tool_result tool_result} {
            $Text tag configure lbl-$role -foreground [my color $key] \
                -font SVMonoBold -lmargin1 10 -lmargin2 10 -spacing1 6
        }
        $Text tag configure body -font [my body_font] -foreground [my color body] \
            -lmargin1 10 -lmargin2 10 -spacing2 3 -spacing3 6
        $Text tag configure code -font [my mono_font] -foreground [my color body] \
            -lmargin1 10 -lmargin2 10 -spacing2 3 -spacing3 6
        # Detail-block faces, one per block kind insert_blocks renders; muted
        # so detail reads apart from prose. They share body/code's margins but
        # carry no -spacing1/2/3 (spacing would seam at the elide boundary).
        foreach dk {dk-tool_use dk-tool_result dk-image dk-chrome} {
            $Text tag configure $dk -font [my mono_font] \
                -foreground [my color muted] -lmargin1 10 -lmargin2 10
        }
        $Text tag configure dk-thinking -font [my italic_font] \
            -foreground [my color muted] -lmargin1 10 -lmargin2 10
        # Turn chrome: foldglyph heads the header line (it holds the line's
        # first char, so it carries the label row's spacing and margins);
        # turnhdr is the header's click zone and sets no appearance (it
        # overlays the lbl-* colours); stub is the faint detail-summary line.
        $Text tag configure foldglyph -font SVMonoBold \
            -foreground [my color muted] -lmargin1 10 -lmargin2 10 -spacing1 6
        $Text tag configure stub -font SVMono \
            -foreground [my color faint] -lmargin1 10 -lmargin2 10
        ::tkdown::tags $Text [my tkdown_fonts]
        $Text tag configure find -background [my color find]
        # Header and stub clicks: fold toggle and detail toggle. Tag bindings
        # fire on disabled text; the handlers resolve which turn from the
        # click index, so two global tags serve every turn.
        set rcursor [$Text cget -cursor]
        foreach zone {turnhdr stub} {
            $Text tag bind $zone <Enter> [list $Text configure -cursor hand2]
            $Text tag bind $zone <Leave> [list $Text configure -cursor $rcursor]
        }
        $Text tag bind turnhdr <ButtonRelease-1> [list [self] turnhdr_click %x %y]
        $Text tag bind stub    <ButtonRelease-1> [list [self] stub_click %x %y]
    }

    # The tkdown fonts dict: the -fonts option verbatim, or the SV* defaults.
    method tkdown_fonts {} {
        set f [my opt fonts]
        if {$f ne ""} { return $f }
        return [dict create body SVBody bold SVBodyBold italic SVBodyItalic \
            bolditalic SVBodyBoldItalic mono SVMono]
    }
    method body_font {}   { return [dict get [my tkdown_fonts] body] }
    method mono_font {}   { return [dict get [my tkdown_fonts] mono] }
    method italic_font {} { return [dict get [my tkdown_fonts] italic] }

    # The find overlay, gridded under the text (streamdoc's setup gridded the
    # text and scrollbar at row 0) and hidden until summoned.
    method build_find {} {
        set Find $Top.find
        ttk::frame $Find
        ttk::label $Find.lbl -text "Find:"
        ttk::entry $Find.e -textvariable [my varname FindVar] -width 30
        ttk::label $Find.pos -textvariable [my varname FindPos] \
            -foreground [my color muted]
        ttk::button $Find.next -text "Next" -command [list [self] find_next]
        ttk::button $Find.close -text "✕" -command [list [self] find_hide]
        pack $Find.lbl -side left -padx 4
        pack $Find.e   -side left -fill x -expand 1
        pack $Find.pos -side left -padx 4
        pack $Find.next  -side left -padx 2
        pack $Find.close -side left -padx 2
        grid $Find -row 1 -column 0 -columnspan 2 -sticky ew
        grid remove $Find
        bind [winfo toplevel $Top] <Control-f> [list [self] find_show]
        bind $Text <Escape>     [list [self] find_hide]
        bind $Find.e <Escape>   [list [self] find_hide]
        bind $Find.e <Return>   [list [self] find_next]
        # Editing the term strands the old readout, so blank it until the
        # next search re-establishes the tally.
        bind $Find.e <KeyRelease> [list [self] find_typing]
    }

    # ---- document lifecycle ------------------------------------------------

    # Empty the document and this class's caches with it. The first call
    # also seeds this class's state - a subclass with bespoke assembly
    # reaches here without the constructor's help, like the base class.
    method reset {} {
        if {![info exists FindVar]}     { set FindVar "" }
        if {![info exists FindMatches]} { set FindMatches [list] }
        if {![info exists FindCur]}     { set FindCur -1 }
        if {![info exists FindPos]}     { set FindPos "" }
        if {![info exists LastFindVar]} { set LastFindVar "" }
        if {![info exists StreamSp]}    { set StreamSp "" }
        if {![info exists StreamSetId]} { set StreamSetId "" }
        next
        set Records [list]
        set Pending [list]
        set LineMap [dict create]
        set NextLine 0
        set RenderTs 0
        set RenderInSection 0
        my live_flush
    }

    # Give a record its _line (the per-record key LineMap and the detail
    # tagging read): keep one it carries, else number it past the highest
    # seen, so file-fed and synthesized records mix without colliding.
    method number_record {rec} {
        if {[dict exists $rec _line]} {
            set l [dict get $rec _line]
            if {$l > $NextLine} { set NextLine $l }
            return $rec
        }
        dict set rec _line [incr NextLine]
        return $rec
    }

    # Wholesale render of a list of parsed records (::logman::parse_line
    # dicts). Replaces whatever was shown. The final turn stays open - a
    # session can always grow - with its detail summary standing as the
    # trailing content line the door knows to pop; a caller wanting it sealed
    # follows with live_close.
    method render_records {recs} {
        my reset
        ::tkdown::forget $Text
        $Text configure -state normal
        foreach rec [::logman::mark_turn_runs $recs] {
            set rec [my number_record $rec]
            lappend Records $rec
            lassign [my render_record_turned $rec $RenderTs $RenderInSection] \
                RenderTs RenderInSection
        }
        my summary_sync
        $Text configure -state disabled
    }

    # Append finished records at the tail: into the open turn while one
    # stands (a tool_result record is detail in its entirety), and a
    # turn-start record closes it and opens its own. One base-class batch:
    # the door pops the open turn's summary so records land inside the turn,
    # and append_close re-covers a fold held during the stream and re-appends
    # the summary with the caught-up counts. Finalizes any streamed message
    # first - a later live_write starts a fresh one - so a stream rewind can
    # never delete a finished record. Returns the number appended.
    # A trailing turn start is held back rather than rendered. The user may be
    # part way through editing the message, and the next batch would then carry
    # another draft of it; a turn once rendered cannot be taken back, because a
    # closed region is immutable. Holding it costs one tick of the caller's
    # cadence. A call that brings nothing new releases the hold: the file has
    # had a full interval to produce a successor and did not, so the message is
    # as settled as the file can say.
    # The trailing turn start held back from the last batch, empty when none
    # stands. A streaming caller reads it to know that an otherwise-empty tick
    # still has work to do: releasing the hold.
    method pending {} { return $Pending }

    method append_records {recs} {
        set fresh [llength $recs]
        set recs [concat $Pending $recs]
        set Pending [list]
        if {$fresh && [llength $recs] && [::logman::opens_turn [lindex $recs end]]} {
            set Pending [list [lindex $recs end]]
            set recs [lrange $recs 0 end-1]
        }
        if {![llength $recs]} { return 0 }
        my live_flush
        my batch {
            set m [my append_open]
            foreach rec [::logman::mark_turn_runs $recs] {
                set rec [my number_record $rec]
                lappend Records $rec
                lassign [my render_record_turned $rec $RenderTs $RenderInSection] \
                    RenderTs RenderInSection
            }
            my append_close $m
        }
        return [llength $recs]
    }

    # ---- record rendering (the logman fold) --------------------------------

    # Render one record at the tail and return the trailing {last_ts
    # in_section} state it advances. The per-record cues - compact boundary,
    # empty-body clock advance, idle gap - come from ::logman::transcript_step;
    # every glyph and tag, the section headers and the label/body rendering
    # live here. The caller holds $Text in -state normal.
    method render_record {rec last_ts in_section} {
        set t [dict getdef $rec type ""]
        # last-prompt records are repeated harness snapshots of the most
        # recent user prompt, echoing the real turn already shown.
        if {$t eq "last-prompt"} { return [list $last_ts $in_section] }
        set lineno [dict get $rec _line]

        lassign [::logman::transcript_step $rec $last_ts [my opt idle_gap]] \
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
        if {$body eq ""} { return [list $last_ts $in_section] }

        set ts_iso [::logman::record_timestamp $rec]
        if {!$in_section} {
            $Text insert end "[my section_header $ts_iso]\n" section-header
            set in_section 1
        }

        set start_idx [$Text index "end-1l linestart"]
        dict set LineMap $lineno $start_idx
        set label [::logman::record_role_label $rec]
        # A turn-start record's label line is its turn's header, a region
        # boundary: the region opens here, after the between-turn chrome
        # above, so the divider and section header stay outside it
        # (render_record_turned closed the previous region before this
        # record). The fold glyph heads the line; render_record_turned tags
        # the completed line turnhdr after.
        if {[::logman::is_turn_start $rec]} {
            my region_open [dict create line $lineno \
                label [lindex [split $body \n] 0] ts $ts_iso \
                edits [dict getdef $rec _edits 0] \
                counts [dict create] working 0]
            $Text insert end "▾ " {foldglyph turnhdr}
        }
        $Text insert end "$label  " "lbl-[string map {{ } _} [string tolower $label]]"
        my on_label_rendered $rec $lineno $body $label $ts_iso
        # Assistant and tool_result records render one content block at a
        # time so each tool_use/thinking/tool_result/image block is its own
        # dk-* tagged run the turn's detail elide can hide; prompts and
        # system records keep the flat body.
        if {$t eq "assistant" || [::logman::is_tool_result_record $rec]} {
            my insert_blocks $rec
        } else {
            my insert_body $t $body
        }
        return [list $last_ts $in_section]
    }

    # Turn-aware wrapper around render_record, the one entry the wholesale
    # fill and the streamed append both use. A turn-start record first closes
    # the open region - the closing summary lands before the new turn's
    # chrome, keeping the summary inside the old turn and the between-turns
    # chrome outside every region - then renders, opening its own region at
    # the header line. Every other record renders into the running region; a
    # tool_result record is detail in its entirety.
    method render_record_turned {rec last_ts in_section} {
        # A draft the user edited before the assistant answered. mark_turn_runs
        # stamped it; the message it was a draft of renders as the turn, with
        # the count of drafts it replaced. Rendering nothing here opens no
        # region, so the turn count and the turn index need no separate rule.
        if {[dict exists $rec _superseded]} { return [list $last_ts $in_section] }
        if {[::logman::opens_turn $rec]} {
            my region_close
            lassign [my render_record $rec $last_ts $in_section] \
                last_ts in_section
            if {[my live] >= 0} {
                set s [dict get [my region_info [my live]] start]
                $Text tag add turnhdr $s "$s lineend"
            }
            return [list $last_ts $in_section]
        }
        lassign [my render_record $rec $last_ts $in_section] last_ts in_section
        if {[my live] >= 0 && [::logman::is_tool_result_record $rec]} {
            set lineno [dict get $rec _line]
            if {[dict exists $LineMap $lineno]} {
                $Text tag add [my detail_tag [my live]] \
                    [dict get $LineMap $lineno] [$Text index "end-1l linestart"]
            }
        }
        return [list $last_ts $in_section]
    }

    # Insert one record body: markdown through tkdown (fenced code under the
    # block `code` tag, everything else prose over `body`).
    method insert_body {t body} {
        ::tkdown::body $Text end $body body code
    }

    # Render an assistant or tool_result record body one content block at a
    # time, per ::logman::extract_blocks. Text blocks keep the whole markdown
    # path; tool_use, thinking, tool_result and image blocks each become one
    # dk-* tagged run carrying the open turn's detail elide tag. Every
    # block's content goes in verbatim as one contiguous run, so a search
    # lands on the same characters a match indexer would; any visual lead-in
    # is a separate dk-chrome insert that shifts no content offset.
    method insert_blocks {rec} {
        # Inside a turn every detail block also carries the region's detail
        # elide tag (hidden by default, toggled by the stub line) and bumps
        # the per-kind tally the stub prints. Preamble records before the
        # first turn carry neither: always visible.
        set dtag [expr {[my live] >= 0 ? [my detail_tag [my live]] : ""}]
        set last ""
        set sawtext 0
        foreach {btype content} [::logman::extract_blocks $rec] {
            switch -- $btype {
                assistant - user {
                    my insert_body $btype $content
                    set sawtext 1
                }
                thinking {
                    # extract_blocks emits thinking bare; restore the
                    # "[thinking] " lead-in as chrome. The redacted
                    # placeholder never carried it, so it gets none.
                    if {$dtag ne ""} { my count_detail thinking }
                    if {$content ne "\[redacted thinking\]"} {
                        $Text insert end "\[thinking\] " [concat dk-chrome $dtag]
                    }
                    $Text insert end "$content\n" [concat dk-thinking $dtag]
                }
                default {
                    # tool_use / tool_result / image, one line per block.
                    if {$dtag ne ""} { my count_detail $btype }
                    $Text insert end "$content\n" [concat [list dk-$btype] $dtag]
                }
            }
            set last $btype
        }
        # insert_body closes a text block with its own blank line; a record
        # ending on a detail block still owes the record separator. The
        # separator is itself detail only when a text block already ended the
        # label's line; without one (a tool-only record) it must stay
        # visible, or the bare label would run into the next record's line.
        if {$last ni {assistant user}} {
            set sep body
            if {$sawtext && $dtag ne ""} { set sep [list body $dtag] }
            $Text insert end "\n" $sep
        }
        # A tool-only assistant record (no text block) is detail in its
        # entirety, like a tool_result record: otherwise its bare label line
        # stands visible with every block hidden, stacking empty "ASSISTANT"
        # headers down a tool-heavy turn.
        if {!$sawtext && $dtag ne ""} {
            set lineno [dict get $rec _line]
            if {[dict exists $LineMap $lineno]} {
                $Text tag add $dtag [dict get $LineMap $lineno] \
                    [$Text index "end-1l linestart"]
            }
        }
    }

    # Bump the open turn's tally of one detail kind; the summary line renders
    # these numbers when the turn closes (or on summary_sync mid-stream).
    method count_detail {kind} {
        set n [my live]
        set p [my payload $n]
        set c [dict get $p counts]
        dict incr c $kind
        dict set p counts $c
        my payload_set $n $p
    }

    # ---- streamdoc hooks ---------------------------------------------------

    # The open turn's trailing stub phrase from the payload's per-kind detail
    # tally, plus the live "working…" marker while one is set. Nonzero kinds
    # only; tool results shadow their calls unless a turn holds results with
    # no calls. "" when there is nothing to say: such a turn takes no stub.
    method summary_text {payload} {
        set counts [dict get $payload counts]
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
        if {[dict getdef $payload working 0]} { lappend parts "working…" }
        if {![llength $parts]} { return "" }
        return "· [join $parts " · "]"
    }

    # The styling tag on every summary line the base class writes: `stub`
    # carries the faint mono face and the detail-toggle click zone.
    method region_tags {payload} { return [list stub] }

    # ---- subclass hooks ----------------------------------------------------
    #
    # Template-method seams a subclass layers app behaviour through, each
    # with a no-op default (streamdoc's on_region_rendered style).

    # After a record's role label is inserted, before its body: the seam for
    # per-record app caches (a copy-source map, a role map) and for chrome
    # riding the header line (a model chip).
    method on_label_rendered {rec lineno body label ts_iso} {}

    # After find_next collected a fresh match set (the term changed), before
    # the step: the seam for an index a subclass keeps over the matches.
    method on_find_collected {} {}

    # After find_next landed on hit i: the seam for tracking the step in a
    # subclass's own affordance (a highlight, a readout of its own).
    method on_find_stepped {i} {}

    # Tags whose text is chrome, not transcript: a hit there is skipped by
    # collect_matches. A subclass extends the list for chrome of its own.
    method find_chrome_tags {} { return [list stub foldglyph] }

    # ---- fold and jump -----------------------------------------------------

    # Header/stub click handlers, shared by every turn through the two global
    # tags; the click index says which turn. The sel guard: a drag-select
    # that merely releases over the line must not toggle it.
    method turnhdr_click {x y} {
        if {[$Text tag ranges sel] ne ""} return
        set n [my region_at [$Text index @$x,$y]]
        if {$n >= 0} { my toggle $n }
    }

    method stub_click {x y} {
        if {[$Text tag ranges sel] ne ""} return
        set n [my region_at [$Text index @$x,$y]]
        if {$n >= 0} { my detail_toggle $n }
    }

    # The one jump gate: every site that scrolls the view to an index routes
    # here. The base class's reveal unfolds the target's turn, shows its
    # detail only when the index itself sits inside it, and drains the line
    # metrics before scrolling: align `see` scrolls the least, `top` puts the
    # target on the top edge. A subclass with layout-riding chrome (a placed
    # hover button) overrides this to invalidate it first.
    method reveal_index {idx {align see}} {
        my reveal $idx $align
    }

    # The text index of the k-th (0-based) tool_use block of the record at
    # jsonl line lineno, or "" when the record has no such call. Each block is
    # one logical line tagged dk-tool_use, but adjacent blocks merge into one
    # tag range, so a line already inside the tag counts. The walk stops at the
    # next record's label, so a k past the record's calls finds nothing rather
    # than a later record's call.
    method tool_use_index {lineno k} {
        if {![dict exists $LineMap $lineno]} { return "" }
        set from [dict get $LineMap $lineno]
        set stop [$Text index end]
        dict for {ln idx} $LineMap {
            if {[$Text compare $idx > $from] && [$Text compare $idx < $stop]} {
                set stop $idx
            }
        }
        for {set i 0} {$i <= $k} {incr i} {
            if {"dk-tool_use" ni [$Text tag names $from]} {
                set r [$Text tag nextrange dk-tool_use $from $stop]
                if {$r eq ""} { return "" }
                set from [lindex $r 0]
            }
            set call $from
            set from [$Text index "$call +1line linestart"]
            if {$i < $k && [$Text compare $from >= $stop]} { return "" }
        }
        return $call
    }

    # ---- live turn (the streamed conversation path) ------------------------
    #
    # A subclass streaming a conversation drives these; everything rides the
    # streamdoc streaming contract (the content door, savepoint/rewind, the
    # summary transaction), so a reader parked mid-history never moves and a
    # tail reader follows.

    # Open a live turn on a prompt: seal any open turn, render the prompt as
    # the turn's header line and body (role label `user`), and leave the new
    # region open for streamed content. Returns the region index. The live
    # path draws no section chrome; ts (ISO) is kept in the payload and
    # advances the idle-gap clock so a later append_records never back-dates
    # a divider.
    method live_open {label {ts ""}} {
        my live_flush
        set n -1
        my batch {
            set m [my append_open]
            my region_close
            # edits 0: the driver hands over one settled prompt per turn, so a
            # streamed exchange has no drafts to collapse. The key is present
            # anyway, so a payload reader needs no special case for this path.
            set n [my region_open [dict create line "" \
                label [lindex [split $label \n] 0] ts $ts \
                edits 0 counts [dict create] working 0]]
            $Text insert end "▾ " {foldglyph turnhdr}
            $Text insert end "USER  " lbl-user
            my insert_body user $label
            set s [dict get [my region_info $n] start]
            $Text tag add turnhdr $s "$s lineend"
            my append_close $m
        }
        set e [::logman::parse_iso $ts]
        if {$e > 0} { set RenderTs $e }
        return $n
    }

    # Stream a chunk of a message into the open turn, in place. The first
    # write of a message renders its role label and takes a savepoint; every
    # write appends the chunk to the message's accumulated source and
    # re-renders the whole provisional tail from the savepoint (rewind, then
    # one markdown pass), so formatting that only settles once its closing
    # syntax arrives - a fence, an emphasis run, a table - is re-read
    # correctly on every chunk. The trailing summary line rides the door's
    # summary transaction: popped before the rewrite, re-appended after.
    method live_write {chunk {role assistant}} {
        if {[my live] < 0} { error "live_write with no open turn" }
        append StreamBuf $chunk
        my batch {
            set m [my append_open]
            if {$StreamSp eq ""} {
                set StreamRole $role
                $Text insert end "[string toupper $role]  " \
                    "lbl-[string tolower $role]"
                set StreamSp [my savepoint]
            } else {
                my rewind $StreamSp
            }
            my insert_body $StreamRole $StreamBuf
            my append_close $m
        }
    }

    # Mark the open turn working (or not): a "working…" phrase on its stub
    # line, carried by the payload so the summary transaction keeps it the
    # trailing line through every streamed append. A no-op with no open turn.
    method live_working {on} {
        set n [my live]
        if {$n < 0} return
        set p [my payload $n]
        dict set p working [expr {$on ? 1 : 0}]
        my payload_set $n $p
        my batch { my summary_sync }
    }

    # Idempotently REPLACE the streamed message's whole text, live_write's
    # repaint twin: a host whose stream frames each repeat the message's
    # entire text so far (self-healing repaints) calls this instead, and the
    # accumulated text never doubles. turn_id names the message the frame
    # belongs to: frames carrying one id replace each other's text (an
    # identical frame repeated is a no-op); a frame with a fresh id finalizes
    # the message in progress and starts its own, so a reply resuming after
    # its tool calls renders as two messages, like live_write's
    # flush-between-messages path. A frame for a message already finalized
    # (live_flush ran; the id comes back) starts a new message: dropping late
    # or duplicate frames past the finalize is the host's business.
    method live_set {turn_id text {role assistant}} {
        if {[my live] < 0} { error "live_set with no open turn" }
        if {$StreamSp ne "" && $turn_id ne $StreamSetId} { my live_flush }
        if {$StreamSp ne "" && $text eq $StreamBuf} { return }
        set StreamSetId $turn_id
        set StreamBuf $text
        my batch {
            set m [my append_open]
            if {$StreamSp eq ""} {
                set StreamRole $role
                $Text insert end "[string toupper $role]  " \
                    "lbl-[string tolower $role]"
                set StreamSp [my savepoint]
            } else {
                my rewind $StreamSp
            }
            my insert_body $StreamRole $StreamBuf
            my append_close $m
        }
    }

    # Finalize the streamed message in progress: the provisional tail becomes
    # settled document, the savepoint is released, and the next live_write
    # starts a fresh message. append_records and live_close call this
    # themselves; a subclass calls it between two streamed messages of one
    # turn (an assistant reply resuming after its tool calls).
    method live_flush {} {
        if {$StreamSp ne ""} { my discard $StreamSp; set StreamSp "" }
        set StreamBuf ""
        set StreamRole ""
        set StreamSetId ""
    }

    # Close the live turn: drop the working marker, seal the region (the
    # final summary line lands through the base class's region_close). A
    # no-op with no open turn.
    method live_close {} {
        my live_flush
        set n [my live]
        if {$n < 0} return
        set p [my payload $n]
        dict set p working 0
        my payload_set $n $p
        my batch { my region_close }
    }

    # ---- find (Ctrl-F) -----------------------------------------------------

    # The boundary between session content and any trailing chrome a
    # subclass appends under an `endhint` tag: searches stop here so the
    # chrome's words are never matches. "end" while none stands.
    method content_end {} {
        set r [$Text tag ranges endhint]
        if {[llength $r]} { return [lindex $r 0] }
        return "end"
    }

    method find_show {} {
        grid $Find
        focus $Find.e
    }

    method find_hide {} {
        grid remove $Find
        my find_clear
    }

    # Drop the find state: highlight, match set, cursor, readout. The one
    # home for the clearing, whatever overlay a subclass dismisses around it.
    method find_clear {} {
        $Text tag remove find 1.0 end
        set FindMatches [list]
        set FindCur -1
        set FindPos ""
    }

    # Collect every occurrence of a literal pattern, tagging hits `find`.
    # -elide: without it `search` skips hidden text, and a hit inside an
    # elided detail block must still be findable (it is what lets a jump
    # reveal the block). A stub's own words and a header's fold glyph are
    # turn chrome, not transcript, so hits there are skipped.
    method collect_matches {pattern} {
        $Text tag remove find 1.0 end
        if {$pattern eq ""} { return [list] }
        set results [list]
        set start 1.0
        set skip [my find_chrome_tags]
        while {1} {
            set len 0
            set m [$Text search -elide -count len -nocase -- $pattern $start \
                [my content_end]]
            if {$m eq ""} break
            set start "$m + ${len}c"
            set chrome 0
            foreach tg [$Text tag names $m] {
                if {$tg in $skip} { set chrome 1; break }
            }
            if {$chrome} continue
            $Text tag add find $m "$m + ${len}c"
            lappend results $m
        }
        return $results
    }

    # Step to the next hit, wrapping, collecting first when the term changed
    # since the last collection. The jump routes through reveal_index, so a
    # hit inside a folded turn or hidden detail block is made visible.
    method find_next {} {
        if {[llength $FindMatches] == 0 || $FindVar ne $LastFindVar} {
            set FindMatches [my collect_matches $FindVar]
            set FindCur -1
            set LastFindVar $FindVar
            my on_find_collected
        }
        if {[llength $FindMatches] == 0} {
            set FindCur -1
            # A search ran and found nothing: state the empty tally so "no
            # matches" reads apart from "no search yet" (which blanks it).
            set FindPos "0 of 0"
            catch {bell}
            return
        }
        set FindCur [expr {$FindCur < 0 ? 0 : $FindCur + 1}]
        if {$FindCur >= [llength $FindMatches]} { set FindCur 0 }
        my reveal_index [lindex $FindMatches $FindCur]
        my on_find_stepped $FindCur
        my update_find_readout
    }

    # The find bar's "N of M" readout, off the shared match set and the
    # active-hit cursor. An empty set blanks it; find_next's own no-result
    # path shows the explicit "0 of 0".
    method update_find_readout {} {
        set total [llength $FindMatches]
        if {$total == 0} { set FindPos ""; return }
        set cur [expr {$FindCur < 0 ? 1 : $FindCur + 1}]
        set FindPos "$cur of $total"
    }

    # The entry text drifted from what was last collected: the readout counts
    # the old set, so blank it until the next search re-establishes the tally.
    method find_typing {} {
        if {$FindVar ne $LastFindVar} { set FindPos "" }
    }

    # ---- section chrome ----------------------------------------------------

    method section_header {ts_iso} { return "▼ [my fmt_iso $ts_iso]" }

    method fmt_iso {ts_iso} {
        if {$ts_iso eq ""} { return "" }
        set epoch [my parse_iso $ts_iso]
        if {$epoch == 0} { return $ts_iso }
        return [clock format $epoch -format "%a %d %b  %H:%M"]
    }

    # ISO->epoch and gap formatting are logman's, the shared segmentation
    # clock; thin methods so the call sites read `my ...`.
    method parse_iso {ts_iso} { return [::logman::parse_iso $ts_iso] }
    method fmt_gap {minutes}  { return [::logman::fmt_gap $minutes] }
}
