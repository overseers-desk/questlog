package require Tcl 9
package require Tk

# Glyphs for the status markers. The single home for both; the toolbar
# toggles are plain text, so these characters live only here.
namespace eval ::questlog::ui {
    variable GLYPH_RUNNING  ●
    variable GLYPH_BOOKMARK ★
    variable GLYPH_ACTIONS  ⋯
}

# The session list's metadata columns, in render order. This is the single
# place that decides which columns appear, their order, the sort-header label,
# the sample string each column's width is measured from, the alignment, and
# whether its header sorts. The tab stops, the cost-tier cell, and the sortable
# header all derive from this list, so reordering or extending it is the one
# edit that moves a column. Each row is {id label sample align sortable}.
#
# The row reads subject-on-the-left, metadata right-pinned: the subject (glyphs,
# slug, preview, match count) fills from the left and the columns below sit in a
# fixed strip flush to the right edge, in this left-to-right order. Turns and
# Duration are filled by the cost second pass (the forward scan stops at the
# second user record and computes neither); the actions column carries the row's
# "⋯" overflow control and is not sortable.
proc ::questlog::ui::session_columns {} {
    return {
        {date     Date     {Wed 30 May 12:30} right 1}
        {size     Size     {999.9 M}          right 1}
        {cost     Cost     {$999.99}          right 1}
        {turns    Turns    {9999}             right 1}
        {duration Duration {0:00:00}          right 1}
        {actions  {}       {⋯}                right 0}
    }
}

# ::questlog::ui::SessionList - the left pane: one read-only text widget that is
# both the session browser and the search-result index in a single list.
#
# Layout, top to bottom, as tagged regions in the one text widget:
#   folder heading   - the project label, a drop target for moves
#   session header   - glyphs, label, time, and (when searching) a match count
#   snippet rows     - up to three per session: a block-type label and a
#                      hit-centred snippet with the matched term in bold
#
# Two display states share the widget. With no criteria it browses: every
# session that passes the snapshot filter appears as a header, grouped by
# folder. With criteria it indexes: only matching sessions appear, each with
# its snippets. A single click opens the session in the docked viewer and
# anchors it to the relevant line.
#
# A text widget is the list; position is tracked with text marks:
#   TailMark   right-gravity, always just before the implicit final newline.
#   <folder>   fmark left-gravity at the heading start; femark right-gravity
#              at the end of the folder's session group (new sessions land
#              here); htag, a per-folder tag on the heading line for drop
#              hit-testing.
#   <session>  smark left-gravity at the header start; semark right-gravity
#              at the session's end (new snippets land here); stag, a
#              per-session tag carrying the click/drag bindings.
# Gravity makes a mid-document insert push every mark to its right along
# with it, so folder grouping streams without bespoke shuffling.
#
# Anti-self-scroll: every streaming insert is bracketed by anchor_save /
# anchor_restore, which pins the top visible line back to the top, so a late
# match inserted above the viewport never shifts what the reader is on.

oo::class create ::questlog::ui::SessionList {
    variable Top
    variable Text
    variable StatusVar
    variable CancelCb
    variable ResolveFolder    ;# cb: folder -> display cwd
    variable LookupSession    ;# cb: path -> row dict
    variable OnOpen           ;# cb: path lineno -> open + anchor in viewer
    variable OnMoveRequest    ;# cb: paths -> open move picker
    variable OnDropMove       ;# cb: paths folder -> direct move
    variable OnBookmarkToggle ;# cb: path -> flip the +x bookmark bit
    variable OnScanPath       ;# cb: path -> row (synchronous single-file scan)
    variable OnShowAll        ;# cb: () -> ask the toolbar to drop the auto-under
    variable Snapshot
    variable CriteriaActive
    variable RunningSet       ;# dict uuid -> 1, replaced wholesale each tick
    variable Query            ;# {terms <list> nocase 0|1} for hit highlighting
    variable HitTags
    variable Folders          ;# folder -> {fmark femark htag}
    variable FolderOrder      ;# folders in arrival (mtime-desc) order
    variable SessionsByFolder ;# folder -> ordered list of paths
    variable Sessions         ;# path -> session dict (see model_add_session)
    variable HtagFolder       ;# htag -> folder, for drop hit-testing
    variable Selected         ;# currently selected session path, or ""
    variable NextId
    variable Menu
    variable MenuPath
    variable MenuTarget
    variable BookmarkIndex    ;# menu index of the Bookmark entry (its label mutates)
    variable RenameIndex      ;# menu index of the Rename entry, enabled per running state
    variable TotalCost        ;# running sum of per-session cost in the model
    variable StatusBase       ;# last text set by set_progress/set_done
    variable ColTabs          ;# -tabs spec for the session line (right-pinned metadata)
    variable ColRightX        ;# right-edge x px per metadata column, for header click mapping
    variable ColW             ;# measured widths per metadata column, parallel to session_columns
    variable ColGap           ;# gap px between metadata cells
    variable SubjectMax       ;# px the subject may fill before the metadata block
    variable FolderLabelMax   ;# px the folder label may fill before its aggregates
    variable LayoutW          ;# Text width the current layout was computed for
    variable RelayoutPending  ;# 1 while a debounced relayout is queued
    variable SortKey          ;# active sort column id: date | size | cost
    variable SortDir          ;# desc | asc
    variable ResortPending    ;# 1 while a debounced redraw is queued under a non-default sort

    constructor {parent resolve_cb lookup_cb on_open on_move_request \
                 on_drop_move on_bookmark_toggle on_scan_path cancel_cb \
                 on_show_all} {
        set Top $parent
        set ResolveFolder $resolve_cb
        set LookupSession $lookup_cb
        set OnOpen $on_open
        set OnMoveRequest $on_move_request
        set OnDropMove $on_drop_move
        set OnBookmarkToggle $on_bookmark_toggle
        set OnScanPath $on_scan_path
        set CancelCb $cancel_cb
        set OnShowAll $on_show_all
        set StatusVar "Idle"
        set StatusBase ""
        set TotalCost 0.0
        set Snapshot [dict create]
        set CriteriaActive 0
        set RunningSet [dict create]
        set Query [dict create terms [list] nocase 0]
        set Selected ""
        set NextId 0
        # Default sort reproduces the streaming order (mtime descending), so a
        # fresh list looks exactly as before any header is clicked.
        set SortKey "date"
        set SortDir "desc"
        set ResortPending 0
        set LayoutW 0
        set RelayoutPending 0
        my reset_model
        my build
    }

    method reset_model {} {
        set Folders [dict create]
        set FolderOrder [list]
        set SessionsByFolder [dict create]
        set Sessions [dict create]
        set HtagFolder [dict create]
        set Selected ""
    }

    method build {} {
        ttk::frame $Top

        ttk::frame $Top.bar
        pack $Top.bar -side top -fill x
        ttk::label $Top.bar.status -textvariable [my varname StatusVar]
        pack $Top.bar.status -side left -padx 4 -pady 2
        ttk::button $Top.bar.cancel -text "Cancel" -command [list [self] cancel]
        pack $Top.bar.cancel -side right -padx 4 -pady 2

        # Show-all banner: visible only when the toolbar's `under` chip was
        # seeded at launch (under_auto == 1) and so is hiding sessions the
        # user did not ask to hide. Update_banner manages visibility.
        # A soft-tinted alert strip (plain tk frame/label so -background takes;
        # ttk would ignore it), so the launch-scope notice reads as a banner
        # rather than blending into the chrome.
        frame $Top.banner -background [::questlog::theme::c banner_bg]
        label $Top.banner.text -anchor w \
            -background [::questlog::theme::c banner_bg] \
            -foreground [::questlog::theme::c banner_fg]
        ttk::button $Top.banner.showall -text "Show all" \
            -command [list [self] on_show_all_clicked]
        pack $Top.banner.text -side left -padx 8 -pady 5 -fill x -expand 1
        pack $Top.banner.showall -side right -padx 8 -pady 5

        ttk::frame $Top.body
        pack $Top.body -side top -fill both -expand 1
        # The sortable column header sits in row 0 of the body grid, in the
        # same column as the text below it, so its labels share the text's
        # width and the right-pinned metadata columns line up. The scrollbar is
        # beside the text only (row 1), never under the header.
        text $Top.body.hdr -height 1 -wrap none -state disabled -takefocus 0 \
            -exportselection 0 -borderwidth 0 -highlightthickness 0 \
            -padx 8 -pady 1 -cursor hand2 -font QLList \
            -background [::questlog::theme::c strip] \
            -foreground [::questlog::theme::c muted]
        text $Top.body.t -wrap word -state disabled -exportselection 0 \
            -yscrollcommand [list [self] on_yscroll] \
            -borderwidth 0 -highlightthickness 0 -padx 8 -pady 8 -cursor arrow \
            -takefocus 0
        ttk::scrollbar $Top.body.sb -orient vertical \
            -command [list $Top.body.t yview]
        grid $Top.body.hdr -row 0 -column 0 -sticky ew
        grid $Top.body.t   -row 1 -column 0 -sticky nsew
        grid $Top.body.sb  -row 1 -column 1 -sticky ns
        grid columnconfigure $Top.body 0 -weight 1
        grid rowconfigure    $Top.body 1 -weight 1
        set Text $Top.body.t
        # Re-pin the metadata columns and re-fit the subject ellipsis when the
        # list is resized.
        bind $Text <Configure> [list [self] on_text_configure %w]
        # This is a list, not editable text: make the click-drag text selection
        # invisible (it otherwise paints rows grey, active and inactive) and
        # hide the insert cursor.
        $Text configure -insertwidth 0 -inactiveselectbackground "" \
            -selectbackground [$Text cget -background] \
            -selectforeground [$Text cget -foreground]

        $Text mark set TailMark "end-1c"
        $Text mark gravity TailMark right

        my configure_tags
        my build_header
        # This is an object list, not editable text. Block the Text class's
        # selection gestures so a click never starts a text selection (which
        # would grab the X PRIMARY clipboard and, via tk::TextAutoScan, run a
        # self-scrolling drag-select). The per-tag click/drag bindings fire
        # first; these widget-level breaks stop the class bindings that follow.
        # B1-Motion still drives drag-to-move, then breaks the class handler.
        bind $Text <B1-Motion> {::questlog::ui::drag::motion %X %Y; break}
        foreach ev {<Button-1> <Double-Button-1> <Triple-Button-1> \
                    <Shift-Button-1> <Control-Button-1> <B1-Leave>} {
            bind $Text $ev break
        }
        my build_menu
    }

    method configure_tags {} {
        # Folder heading: the outermost level, with a wide gap above so each
        # project group reads as a section. Proportional (QLList), like the
        # rest of the list - the design carries no fixed-width font.
        # Folder heading is single-line so its size/cost aggregates can sit in
        # the same right-pinned columns as the session rows below it.
        $Text tag configure folderhead \
            -font QLList -foreground [::questlog::theme::c folder] \
            -spacing1 14 -spacing3 3 -wrap none
        $Text tag configure glyph-running  -foreground [::questlog::theme::c glyph_running]
        $Text tag configure glyph-bookmark -foreground [::questlog::theme::c glyph_bookmark]
        # Session header: one line, the block's "title" (like a search result
        # heading), indented under its folder. Rows are separated by the gap
        # above each and the bold title colour; no background band. The
        # selected row gets a highlight for click feedback. The metadata
        # columns align on per-tag right tab stops (set by layout_columns), so
        # the line reads in the proportional QLList without a fixed-width crutch.
        $Text tag configure sessionhead -lmargin1 12 -lmargin2 28 \
            -spacing1 6 -spacing3 2 -foreground [::questlog::theme::c ink] \
            -font QLList
        # The slug (Claude's agentName / aiTitle) renders bold inline before
        # the prompt body, so the slug acts as the headline and the prompt
        # as the deck below it. Bold weight is the only marker; brackets
        # would compete with the kebab-case hyphens.
        $Text tag configure slug -font QLBold
        $Text tag configure selected -background [::questlog::theme::c sel]
        $Text tag configure drop-candidate -background [::questlog::theme::c drop]

        # Snippet rows: a rounded type-badge pill in a left column, the matched
        # line beside it. Indented past the header so each block reads
        # title-then-evidence. The badge is an embedded label drawing the shared
        # qlBadge_<type> pill image (theme::build_chrome), so the content column
        # is sized from that pill's width; content is the proportional QLList.
        set barcol 22
        # Tk positions an embedded window at the line's -lmargin2, not after the
        # preceding glyph, so the badge column IS lmargin2: just past the bar
        # glyph. lmargin1 holds the bar; a single tab then aligns content.
        set badgecol [expr {$barcol + [font measure QLList "▏"] + 6}]
        set bpw [image width [::questlog::theme::badge_pill system]]
        set content_col [expr {$badgecol + $bpw + 12}]
        $Text configure -tabs [list $content_col left]
        # A thin session-grouping spine runs in the gutter to the left of the
        # badge: every snippet line opens with a bar glyph, so the matches of one
        # session stack into one continuous rule (the design's MatchList left
        # guide). The badge (an embedded pill) sits at lmargin2; content tabs to
        # content_col. -wrap none clips each match to one row, as the design does.
        $Text tag configure snippet -lmargin1 $barcol -lmargin2 $badgecol \
            -tabs [list $content_col left] -wrap none \
            -font QLList -foreground [::questlog::theme::c snippet] -spacing3 1
        $Text tag configure snippetbar -foreground [::questlog::theme::c snippet_guide]
        # Metadata cells (date, size, cost): the muted grey column run pinned
        # to the right of each session line. Proportional QLList, aligned by
        # the sessionhead right tab stops, not a monospace font.
        $Text tag configure meta -foreground [::questlog::theme::c meta]
        # Cost tiers draw the eye to the sessions that ate the budget: amber
        # from 10c, brick red from $1. Below 10c the cell keeps the muted meta
        # grey, so only elevated costs stand out. Configured after meta so the
        # tier foreground wins over it on the cost cell.
        $Text tag configure cost-mid     -foreground [::questlog::theme::c cost_mid]
        $Text tag configure cost-outlier -foreground [::questlog::theme::c cost_outlier]
        # The per-row actions control ("⋯") in the rightmost column. It rests at
        # the faded meta grey with the rest of the metadata and brightens to ink
        # while its row is hovered or selected, so the menu it opens advertises
        # itself for anyone whose trackpad refuses the right-click. The bright
        # tag is added/removed per row over the cell's range; configured after
        # meta so its foreground wins.
        $Text tag configure actioncell        -foreground [::questlog::theme::c meta]
        $Text tag configure actioncell-bright  -foreground [::questlog::theme::c ink]
        # Folder size/cost aggregates are bold (a sum, not a row value); they
        # overlay meta or a cost tier for colour, so this only sets the weight.
        $Text tag configure foldagg -font QLBold

        set HitTags [list]
        set hues [::questlog::theme::hues]
        for {set i 0} {$i < [llength $hues]} {incr i} {
            set t hit-$i
            $Text tag configure $t -background [lindex $hues $i]
            lappend HitTags $t
        }

        my compute_col_widths
        my layout_columns
    }

    # Measure the metadata cells once in QLList (the proportional list font is
    # fixed, so the widths never change at runtime). layout_columns turns these
    # into positions; doing the measuring once keeps resize cheap.
    method compute_col_widths {} {
        set ColGap [font measure QLList "  "]
        set ColW [list]
        foreach col [::questlog::ui::session_columns] {
            lassign $col id label sample
            # A column must be wide enough for both its widest cell (the sample)
            # and its header label with the sort arrow, so a short-sampled column
            # like Turns never has its "Turns ▾" heading spill into the neighbour.
            set ws [font measure QLList $sample]
            set wl [font measure QLBold "$label ▾"]
            lappend ColW [expr {$ws > $wl ? $ws : $wl}]
        }
    }

    # Pin the metadata strip flush to the list's right edge for the current
    # width: the last column's right edge sits a hair inside the edge and each
    # earlier column stacks leftward by its width plus a gap, so the subject
    # gets whatever room is left before the leftmost column. Right tab stops put
    # each cell's right edge on its stop. Called at build and on every resize; it
    # only repositions (cheap), the per-row ellipsis refit is the separate
    # relayout step.
    method layout_columns {} {
        set w [winfo width $Text]
        if {$w <= 1} { set w 600 }
        set cw [expr {$w - 16}]          ;# inside the 8px left/right -padx
        set n [llength $ColW]
        set rights [lrepeat $n 0]
        set edge [expr {$cw - 6}]        ;# rightmost column's right edge
        for {set i [expr {$n - 1}]} {$i >= 0} {incr i -1} {
            lset rights $i $edge
            set edge [expr {$edge - [lindex $ColW $i] - $ColGap}]
        }
        set ColRightX $rights
        set ColTabs [list]
        foreach rx $rights { lappend ColTabs $rx right }
        # Subject runs up to just before the leftmost metadata column.
        set first_rx [lindex $rights 0]
        set SubjectMax [expr {$first_rx - [lindex $ColW 0] - $ColGap - 12}]
        if {$SubjectMax < 80} { set SubjectMax 80 }
        # The folder label has no date cell, so it may run up to the first tab
        # stop before its aggregates; cap it just short of that.
        set FolderLabelMax [expr {$first_rx - 16}]
        if {$FolderLabelMax < 60} { set FolderLabelMax 60 }
        $Text tag configure sessionhead -tabs $ColTabs
        $Text tag configure folderhead  -tabs $ColTabs
        if {[winfo exists $Top.body.hdr]} { $Top.body.hdr configure -tabs $ColTabs }
    }

    # Resize hook: when the width actually changes, re-pin the columns and
    # re-fit every rendered subject's ellipsis, coalesced to one pass at idle.
    method on_text_configure {w} {
        if {$w == $LayoutW} return
        set LayoutW $w
        if {$RelayoutPending} return
        set RelayoutPending 1
        after idle [list [self] relayout]
    }
    method relayout {} {
        set RelayoutPending 0
        my layout_columns
        my draw_header
        $Text configure -state normal
        foreach folder $FolderOrder { my redraw_folder_heading $folder }
        dict for {path s} $Sessions {
            if {[dict get $s rendered]} { my redraw_header $path }
        }
        $Text configure -state disabled
    }

    # The sortable column header lives in row 0 of the body grid (created in
    # build, so it shares the text's width). It shares the session line's font
    # and tab stops, so its right-pinned Date/Size/Cost labels sit over the
    # columns. Clicking a metadata column sorts by it; clicking the active one
    # flips the direction. The Session zone on the left is not sortable.
    method build_header {} {
        set h $Top.body.hdr
        $h tag configure colactive -font QLBold -foreground [::questlog::theme::c ink]
        bind $h <Button-1> [list [self] on_header_click %x]
        my draw_header
    }

    # Map a header click x (widget pixels) to a metadata column and sort by it.
    # Each column occupies [right_edge - width, right_edge]; a click in the
    # Session area or the gaps falls through and sorts nothing.
    method on_header_click {x} {
        set cx [expr {$x - 8}]
        set cols [::questlog::ui::session_columns]
        for {set i 0} {$i < [llength $cols]} {incr i} {
            lassign [lindex $cols $i] id label sample align sortable
            set rx [lindex $ColRightX $i]
            set lo [expr {$rx - [lindex $ColW $i] - 6}]
            if {$cx >= $lo && $cx <= $rx + 4} {
                if {$sortable} { my set_sort $id }
                return
            }
        }
    }

    # Adopt a new sort key (descending), or flip the direction when the active
    # key is clicked again, then re-render the list in the new order.
    method set_sort {id} {
        if {$SortKey eq $id} {
            set SortDir [expr {$SortDir eq "desc" ? "asc" : "desc"}]
        } else {
            set SortKey $id
            set SortDir "desc"
        }
        my redraw_all
        my draw_header
    }

    # Paint the header labels: the Session column on the left, then the
    # right-pinned Date/Size/Cost over their columns, the active one marked with
    # a direction arrow and bold ink.
    method draw_header {} {
        set h $Top.body.hdr
        $h configure -state normal
        $h delete 1.0 end
        set line "Session"
        set act_off -1
        set act_len 0
        foreach col [::questlog::ui::session_columns] {
            lassign $col id label
            append line "\t"
            set lbl $label
            if {$id eq $SortKey} {
                append lbl [expr {$SortDir eq "desc" ? " ▾" : " ▴"}]
                set act_off [string length $line]
                set act_len [string length $lbl]
            }
            append line $lbl
        }
        $h insert 1.0 $line
        if {$act_off >= 0} {
            $h tag add colactive "1.0 + ${act_off}c" \
                "1.0 + [expr {$act_off + $act_len}]c"
        }
        $h configure -state disabled
    }

    # Order a folder's session paths by the active sort. Each key reads a
    # cached field (mtime for date, size, cost); date descending reproduces the
    # mtime-descending streaming order. A blank or unknown cost sinks to the
    # bottom. src is the dict to read fields from (the live model on expand, the
    # pre-rebuild snapshot in redraw_all).
    method sort_paths {paths src} {
        set keyed [list]
        foreach p $paths {
            set v -1
            if {[dict exists $src $p]} {
                set s [dict get $src $p]
                switch -- $SortKey {
                    date { set v [dict getdef $s mtime 0] }
                    size { set v [dict getdef $s size 0] }
                    cost {
                        set v [dict getdef $s cost ""]
                        if {$v eq "" || $v < 0} { set v -1 }
                    }
                    turns {
                        set v [dict getdef $s turns ""]
                        if {$v eq ""} { set v -1 }
                    }
                    duration {
                        set v [dict getdef $s duration_secs ""]
                        if {$v eq ""} { set v -1 }
                    }
                }
            }
            lappend keyed [list $p $v]
        }
        set dir [expr {$SortDir eq "asc" ? "-increasing" : "-decreasing"}]
        return [lmap e [lsort -real -index 1 $dir $keyed] { lindex $e 0 }]
    }

    method sort_folders {order foldercost} {
        set keyed [lmap f $order { list $f [dict getdef $foldercost $f 0.0] }]
        set dir [expr {$SortDir eq "asc" ? "-increasing" : "-decreasing"}]
        return [lmap e [lsort -real -index 1 $dir $keyed] { lindex $e 0 }]
    }

    method is_default_sort {} {
        return [expr {$SortKey eq "date" && $SortDir eq "desc"}]
    }

    # A row streamed or recosted under a non-default sort lands out of order;
    # coalesce a single full re-render at idle to restore the sort. The default
    # sort needs none (streaming order is already correct), so this no-ops then.
    method schedule_resort {} {
        if {[my is_default_sort]} return
        if {$ResortPending} return
        set ResortPending 1
        after idle [list [self] do_resort]
    }
    method do_resort {} {
        set ResortPending 0
        if {[my is_default_sort]} return
        my redraw_all
    }

    method build_menu {} {
        set Menu $Top.cmenu
        menu $Menu -tearoff 0
        $Menu add command -label "Open in viewer" -command [list [self] menu_open]
        $Menu add separator
        $Menu add command -label "Copy resume command" \
            -command [list [self] menu_copy_resume]
        $Menu add command -label "Copy session id" \
            -command [list [self] menu_copy_uuid]
        $Menu add command -label "Copy session path" \
            -command [list [self] menu_copy_path]
        $Menu add command -label "Copy last assistant output" \
            -command [list [self] menu_copy_last_assistant]
        $Menu add separator
        $Menu add command -label "Resume in new terminal tab" \
            -command [list [self] menu_resume 0]
        $Menu add command -label "Resume forked" -command [list [self] menu_resume 1]
        $Menu add separator
        $Menu add command -label "Move to..." -command [list [self] menu_move]
        $Menu add command -label "Reveal folder" -command [list [self] menu_reveal]
        $Menu add separator
        $Menu add command -label "Bookmark" -command [list [self] menu_bookmark]
        # Addressed by index, not label: on_session_right rewrites this label
        # to Add/Remove bookmark, so a label lookup would fail on the next open.
        set BookmarkIndex [$Menu index end]
        $Menu add command -label "Rename..." -command [list [self] menu_rename]
        set RenameIndex [$Menu index end]
        set MenuTarget [dict create]
        set MenuPath ""
    }

    # ---- view-anchoring around streaming inserts ----------------------
    #
    # A streaming insert must not shift what the reader is looking at. Two
    # cases: if the reader is at the very top (the default while browsing or
    # watching results arrive), keep them pinned to the absolute top so the
    # newest content and the folder heading stay in view; if they have
    # scrolled into the list, pin the character that was at the top so an
    # insert above it scrolls to compensate and their line does not move.

    variable AtTop
    method anchor_save {} {
        set AtTop [expr {[lindex [$Text yview] 0] <= 0.0001}]
        $Text mark set AnchorTop @0,0
        $Text mark gravity AnchorTop left
    }
    method anchor_restore {} {
        if {[info exists AtTop] && $AtTop} {
            $Text yview moveto 0
        } else {
            catch {$Text yview AnchorTop}
        }
        catch {$Text mark unset AnchorTop}
    }

    # ---- filter / clear ----------------------------------------------

    method clear {} {
        $Text configure -state normal
        $Text delete 1.0 end
        my purge_tags_and_marks
        $Text mark set TailMark "end-1c"
        $Text mark gravity TailMark right
        $Text configure -state disabled
        my reset_model
        set TotalCost 0.0
        set StatusBase ""
        my refresh_status
    }

    # Drop the per-region tags and position marks left behind by a cleared
    # body, so neither accumulates across filter changes.
    method purge_tags_and_marks {} {
        foreach t [$Text tag names] {
            if {[string match "s#*" $t] || [string match "f#*" $t] \
                || [string match "n#*" $t]} {
                $Text tag delete $t
            }
        }
        foreach m [$Text mark names] {
            if {[string match "sm*" $m] || [string match "se*" $m] \
                || [string match "fm*" $m] || [string match "fe*" $m]} {
                $Text mark unset $m
            }
        }
    }

    method apply_filter {snapshot} {
        set Snapshot $snapshot
        set CriteriaActive [::questlog::ui::any_criteria $snapshot]
        my update_banner
        my clear
    }

    # Show the launch-scope banner when the toolbar's under chip was the
    # one the app seeded (under_auto == 1), since the user did not type it
    # and may not realise it is filtering their results. Hide otherwise.
    method update_banner {} {
        set under_auto [dict getdef $Snapshot under_auto 0]
        set under_list [dict getdef $Snapshot under {}]
        if {$under_auto && [llength $under_list] > 0} {
            set path [lindex $under_list 0]
            set pretty [::questlog::path::pretty_home $path]
            $Top.banner.text configure -text \
                "ⓘ  Showing sessions from $pretty only."
            pack $Top.banner -side top -fill x -after $Top.bar
        } else {
            pack forget $Top.banner
        }
    }

    method on_show_all_clicked {} {
        if {$OnShowAll ne ""} { {*}$OnShowAll }
    }

    method set_query {terms nocase} {
        set Query [dict create terms $terms nocase $nocase]
    }

    # ---- snapshot membership -----------------------------------------

    # Whether a row passes the current snapshot's row-level filters. The
    # predicate is shared with Scan through ::questlog::filter, so the model and
    # the view never disagree on what the snapshot admits.
    method row_matches_snapshot {row} {
        return [::questlog::filter::row_matches $Snapshot $row]
    }

    # ---- streaming inserts -------------------------------------------

    # Browse-mode row from Scan. Skipped under running-only (the reconciler
    # owns the display then) and when criteria are active (the result index
    # is built from matches, not the scan stream).
    method on_scan_row {row} {
        if {[dict getdef $Snapshot running_only 0]} return
        if {$CriteriaActive} return
        if {![my row_matches_snapshot $row]} return
        set path [dict get $row path]
        if {[dict exists $Sessions $path]} return
        $Text configure -state normal
        my anchor_save
        my model_add_session $path $row
        if {[my folder_expanded [dict get $row folder]]} { my render_session $path }
        my anchor_restore
        $Text configure -state disabled
        my schedule_resort
    }

    # Match record from Search. The first match for a session creates its
    # card; later matches bump the count and add a snippet (capped at three).
    # Bracket a slice of render_session_matches calls so a whole idle flush does
    # one anchor_save/restore and one schedule_resort, not per session.
    method begin_batch {} {
        $Text configure -state normal
        my anchor_save
    }
    method end_batch {} {
        my anchor_restore
        $Text configure -state disabled
        my schedule_resort
    }

    # A whole found session from Search: its full match list in line order.
    # Renders the session card, up to snippets_per_session snippets, and the
    # final match count in one anchored pass - no per-match anchoring or redraw,
    # which is what kept a broad query from freezing the list. Self-brackets one
    # session; the batched flush (begin_batch/end_batch) brackets many at once.
    method add_session_matches {matches} {
        if {[llength $matches] == 0} return
        $Text configure -state normal
        my anchor_save
        my render_session_matches $matches
        my anchor_restore
        $Text configure -state disabled
        my schedule_resort
    }

    # The render body without the anchor/state bracketing, so a flush can
    # bracket a whole slice of sessions once (see app.tcl flush_search).
    method render_session_matches {matches} {
        set first [lindex $matches 0]
        set path  [dict get $first path]
        if {![dict exists $Sessions $path]} {
            set row [{*}$LookupSession $path]
            if {$row eq ""} { set row [dict create folder [dict get $first folder]] }
            my model_add_session $path $row [dict get $first lineoff]
        }
        # Search folders are expanded, so render the session if it is not yet.
        if {[my folder_expanded [dict get $Sessions $path folder]] \
            && ![dict get $Sessions $path rendered]} {
            my render_session $path
        }
        set cap [::questlog::config::get snippets_per_session]
        foreach m $matches {
            dict set Sessions $path count [expr {[dict get $Sessions $path count] + 1}]
            if {[llength [dict get $Sessions $path snippets]] < $cap} {
                set btype   [dict get $m btype]
                set content [dict get $m content]
                set lineoff [dict get $m lineoff]
                set sn [dict get $Sessions $path snippets]
                lappend sn [list $btype $content $lineoff]
                dict set Sessions $path snippets $sn
                if {[dict get $Sessions $path rendered]} {
                    my render_snippet $path $btype $content $lineoff
                }
            }
        }
        if {[dict get $Sessions $path rendered]} { my redraw_header $path }
    }

    method folder_expanded {folder} {
        if {![dict exists $Folders $folder]} { return 0 }
        return [dict get [dict get $Folders $folder] expanded]
    }

    # Record a session in the model without drawing it. A collapsed folder
    # holds its sessions here only; they are drawn lazily on expand. This is
    # what keeps a folded list cheap and free of hidden (elided) lines.
    method model_add_session {path row {first_lineno 0}} {
        set folder [dict get $row folder]
        my ensure_folder $folder
        set label [my session_label $path $row]
        set slug  [dict getdef $row slug ""]
        set aitt  [dict getdef $row ai_title ""]
        set mtime [dict getdef $row mtime 0]
        set when  [my fmt_time $mtime]
        set size  [dict getdef $row size 0]
        set uuid  [dict getdef $row uuid [file rootname [file tail $path]]]
        set cost  [dict getdef $row cost_usd ""]
        set turns [dict getdef $row turns ""]
        set dsecs [dict getdef $row duration_secs ""]
        dict set Sessions $path [dict create \
            folder $folder label $label slug $slug ai_title $aitt \
            when $when mtime $mtime size $size uuid $uuid cost $cost \
            turns $turns duration_secs $dsecs \
            count 0 first_lineno $first_lineno snippets [list] \
            stag "" smark "" semark "" rendered 0]
        dict lappend SessionsByFolder $folder $path
        # Count and size accrue together (size is known at scan time); fold both
        # into one heading redraw. Cost arrives later, on its own redraw.
        dict set Folders $folder count \
            [expr {[dict get [dict get $Folders $folder] count] + 1}]
        dict set Folders $folder size \
            [expr {[dict getdef [dict get $Folders $folder] size 0] + $size}]
        my redraw_folder_heading $folder
        if {$cost ne "" && $cost > 0} {
            my bump_folder_cost $folder $cost
            set TotalCost [expr {$TotalCost + $cost}]
            my refresh_status
        }
    }

    # Draw a session that the model already knows, inserting its header (and
    # any stored snippets) at the folder's append point. Idempotent.
    method render_session {path} {
        if {[dict get $Sessions $path rendered]} return
        set folder [dict get $Sessions $path folder]
        set femark [dict get [dict get $Folders $folder] femark]
        set stag "s#[incr NextId]"
        set sstart [$Text index $femark]
        set info [my build_session_line $path]
        $Text insert $femark "[dict get $info line]\n" \
            [list sessionhead $stag]
        my apply_line_tags $sstart $path $info
        # Single-line rows: the subject preview is ellipsised to stop before the
        # right-pinned metadata (build_session_line), and -wrap none guards
        # against any residual overflow. The full prompt is read in the viewer,
        # which a click on the row opens.
        $Text tag configure $stag -wrap none
        set smark "sm[incr NextId]"
        $Text mark set $smark $sstart
        $Text mark gravity $smark left
        set send [$Text index "$smark lineend +1c"]
        set semark "se[incr NextId]"
        $Text mark set $semark $send
        $Text mark gravity $semark left
        $Text mark set $femark $send
        dict set Sessions $path stag $stag
        dict set Sessions $path smark $smark
        dict set Sessions $path semark $semark
        dict set Sessions $path rendered 1
        $Text tag bind $stag <ButtonPress-1> \
            [list [self] on_session_press $path %X %Y]
        $Text tag bind $stag <ButtonRelease-1> \
            [list [self] on_session_release $path %X %Y]
        # Tk's <<ContextMenu>> virtual event already maps to the right button
        # per platform (Button-2 on Aqua, Button-3 elsewhere); app.tcl extends
        # it with Control-Button-1 on Aqua so Ctrl+click works too.
        $Text tag bind $stag <<ContextMenu>> \
            [list [self] on_session_right $path %X %Y]
        # A whole session row is one clickable object: a hand cursor over it,
        # an arrow elsewhere. Text tags carry no -cursor, so swap the widget
        # cursor on enter/leave; entering also brightens the row's ⋯ control.
        $Text tag bind $stag <Enter> [list [self] on_row_enter $path]
        $Text tag bind $stag <Leave> [list [self] on_row_leave $path]
        foreach snip [dict get $Sessions $path snippets] {
            lassign $snip btype content lineoff
            my render_snippet $path $btype $content $lineoff
        }
        if {$Selected eq $path} {
            $Text tag add selected $smark "$smark lineend"
        }
    }

    method render_snippet {path btype content lineoff} {
        set semark [dict get $Sessions $path semark]
        set ntag "n#[incr NextId]"
        # Normalise to a type with a known badge pill; an unknown block type
        # falls back to the neutral system pill.
        set fgrole [dict getdef {
            user user assistant assistant tool_use tool
            tool_result tool_result system system
        } $btype system]
        set bt [expr {$fgrole eq "system" && $btype ne "system" ? "system" : $btype}]
        # Build at a temporary right-gravity mark so the pieces land in order;
        # semark is left gravity and would otherwise reverse successive inserts.
        set tmp tmpsnip
        $Text mark set $tmp [$Text index $semark]
        $Text mark gravity $tmp right
        $Text insert $tmp "▏" [list snippet snippetbar $ntag]
        # Rounded type badge: a label drawing the type name centred over the
        # shared pill image (Tk's SVG cannot render text itself). It is created
        # lazily through -create so only the on-screen badges become real widgets
        # — a whole-corpus search can list thousands of snippets, and eagerly
        # building a widget per badge pegs a core; -create keeps it to a screenful.
        set wstart [$Text index $tmp]
        $Text window create $tmp -align center -pady 1 -padx 3 \
            -create [list [self] make_badge $bt $fgrole $path $lineoff]
        # The window segment must carry the snippet tag too, or its untagged
        # -wrap (the widget default `word`) lets the row wrap to a second line.
        $Text tag add snippet $wstart "$wstart +1c"
        $Text tag add $ntag   $wstart "$wstart +1c"
        $Text insert $tmp "\t" [list snippet $ntag]
        set cstart [$Text index $tmp]
        $Text insert $tmp $content [list snippet $ntag]
        set cend [$Text index $tmp]
        $Text insert $tmp "\n" [list snippet $ntag]
        my tag_hits_in_range $cstart $cend $content
        $Text tag bind $ntag <ButtonRelease-1> \
            [list [self] on_snippet_release $path $lineoff]
        # A snippet row is an extension of its session, so right-clicking it
        # raises the same session menu as the header.
        $Text tag bind $ntag <<ContextMenu>> \
            [list [self] on_session_right $path %X %Y]
        $Text tag bind $ntag <Enter> [list $Text configure -cursor hand2]
        $Text tag bind $ntag <Leave> [list $Text configure -cursor arrow]
        # Advance this session's end and the folder's append point past the
        # snippet (the session receiving snippets is always its folder's last).
        $Text mark set $semark [$Text index $tmp]
        $Text mark unset $tmp
        set folder [dict get $Sessions $path folder]
        if {[dict exists $Folders $folder]} {
            $Text mark set [dict get [dict get $Folders $folder] femark] \
                [$Text index $semark]
        }
    }

    # Build one snippet badge on demand (the text widget's -create callback when
    # the row scrolls into view). Embedded windows do not inherit the row's tag
    # bindings, so click and context-menu are forwarded to the same handlers.
    method make_badge {bt fgrole path lineoff} {
        set b $Text.badge[incr NextId]
        label $b -image [::questlog::theme::badge_pill $bt] -compound center \
            -text [string toupper [string map {_ { }} $bt]] \
            -font QLBold -foreground [::questlog::theme::c $fgrole] \
            -background [$Text cget -background] -borderwidth 0 \
            -takefocus 0 -cursor hand2
        bind $b <ButtonRelease-1> [list [self] on_snippet_release $path $lineoff]
        bind $b <<ContextMenu>>   [list [self] on_session_right $path %X %Y]
        return $b
    }

    method session_label {path row} {
        set body [dict getdef $row first_user ""]
        if {$body eq ""} { set body [dict getdef $row uuid [file rootname [file tail $path]]] }
        return $body
    }

    # The metadata cell values for a row, keyed by column id. Cost is blank
    # until the second-pass worker fills it in; an unknown model (negative
    # cost) stays blank.
    method session_meta_cells {path} {
        set s [dict get $Sessions $path]
        set cells [dict create]
        foreach col [::questlog::ui::session_columns] {
            lassign $col id
            switch -- $id {
                date { set v [dict get $s when] }
                size { set v [my fmt_size [dict get $s size]] }
                cost {
                    set c [dict getdef $s cost ""]
                    set v [expr {($c ne "" && $c >= 0) \
                                 ? [::questlog::cost::format_usd $c] : ""}]
                }
                turns {
                    set t [dict getdef $s turns ""]
                    set v [expr {($t ne "" && $t > 0) ? $t : ""}]
                }
                duration {
                    set v [::questlog::cost::fmt_dur [dict getdef $s duration_secs ""]]
                }
                actions { set v $::questlog::ui::GLYPH_ACTIONS }
                default { set v "" }
            }
            dict set cells $id $v
        }
        return $cells
    }

    # Build one session line: the subject on the left (status glyphs, the bold
    # slug, the first-prompt preview, the match count), then the metadata cells
    # pinned to the right by the sessionhead tab stops, in session_columns order.
    # The preview is ellipsised to SubjectMax so it never collides with the
    # metadata; the glyphs, slug and count are kept whole. Returns the text, the
    # char ranges the caller tags, and a per-column {off len} map (offs) so the
    # cost tier colour and the actions cell can be located.
    method build_session_line {path} {
        set s [dict get $Sessions $path]
        set cells [my session_meta_cells $path]

        set running [dict exists $RunningSet [dict get $s uuid]]
        set bk [my session_bookmarked $path]
        set g [my glyph_cell $running $bk]
        set slug [dict get $s slug]
        set count [dict get $s count]
        set count_str ""
        if {$count > 0} {
            set count_str "   ·   $count [expr {$count == 1 ? {match} : {matches}}]"
        }

        set subj ""
        if {$g ne ""} { append subj "$g " }
        set slug_off -1
        set slug_len 0
        if {$slug ne ""} {
            set slug_off [string length $subj]
            append subj $slug
            set slug_len [string length $slug]
            append subj "  "
        }
        # Fit the preview into the room left after the kept pieces.
        set fixed 0
        if {$g ne ""} { incr fixed [font measure QLList "$g "] }
        if {$slug ne ""} {
            incr fixed [expr {[font measure QLBold $slug] + [font measure QLList "  "]}]
        }
        incr fixed [font measure QLList $count_str]
        set preview [my truncate_px [dict get $s label] \
                         [expr {$SubjectMax - $fixed}] QLList]
        append subj $preview
        append subj $count_str

        set meta_off [string length $subj]
        set line $subj
        set offs [dict create]
        foreach col [::questlog::ui::session_columns] {
            lassign $col id
            append line "\t"
            set off [string length $line]
            set val [dict get $cells $id]
            append line $val
            dict set offs $id [list $off [string length $val]]
        }
        return [dict create line $line meta_off $meta_off \
            slug_off $slug_off slug_len $slug_len offs $offs]
    }

    # Trim text to fit px in font, appending an ellipsis when it is cut. A
    # binary search on the character count keeps it cheap for long previews.
    method truncate_px {text px font} {
        if {$px <= 0} { return "" }
        if {[font measure $font $text] <= $px} { return $text }
        set lo 0
        set hi [string length $text]
        while {$lo < $hi} {
            set mid [expr {($lo + $hi + 1) / 2}]
            set cand "[string range $text 0 [expr {$mid - 1}]]…"
            if {[font measure $font $cand] <= $px} {
                set lo $mid
            } else {
                set hi [expr {$mid - 1}]
            }
        }
        return "[string range $text 0 [expr {$lo - 1}]]…"
    }

    # Tag a freshly-inserted session line from its build_session_line info: the
    # muted metadata run on the right, the bold slug, the status glyphs at the
    # start, and the cost cell's tier colour (amber from 10c, brick red from
    # $1; below that, and blank/unknown, keep the meta grey).
    method apply_line_tags {row_start path info} {
        $Text tag add meta \
            "$row_start + [dict get $info meta_off]c" "$row_start lineend"
        set so [dict get $info slug_off]
        if {$so >= 0} {
            $Text tag add slug "$row_start + ${so}c" \
                "$row_start + [expr {$so + [dict get $info slug_len]}]c"
        }
        my tag_glyphs $row_start 0
        lassign [dict getdef [dict get $info offs] cost {-1 0}] co cl
        if {$co >= 0 && $cl > 0} {
            set c [dict getdef [dict get $Sessions $path] cost ""]
            if {$c ne "" && $c >= 0.10} {
                set tag [expr {$c >= 1.0 ? "cost-outlier" : "cost-mid"}]
                $Text tag add $tag "$row_start + ${co}c" \
                    "$row_start + [expr {$co + $cl}]c"
            }
        }
        # Mark the actions cell so a click on it can be told apart from a click
        # on the row, and so it can brighten; the selected row shows it bright.
        lassign [dict getdef [dict get $info offs] actions {-1 0}] ao al
        if {$ao >= 0 && $al > 0} {
            set as "$row_start + ${ao}c"
            set ae "$row_start + [expr {$ao + $al}]c"
            $Text tag add actioncell $as $ae
            if {$Selected eq $path} { $Text tag add actioncell-bright $as $ae }
        }
    }

    # Colour the status glyphs at the head of a row: running ● green, bookmark
    # ★ amber. They are the leading run of glyph chars at the start of the
    # subject, before the first space.
    method tag_glyphs {row_start off} {
        set base "$row_start + ${off}c"
        for {set i 0} {$i < 4} {incr i} {
            set ch [$Text get "$base + ${i}c"]
            if {$ch eq $::questlog::ui::GLYPH_RUNNING} {
                $Text tag add glyph-running "$base + ${i}c" "$base + [expr {$i + 1}]c"
            } elseif {$ch eq $::questlog::ui::GLYPH_BOOKMARK} {
                $Text tag add glyph-bookmark "$base + ${i}c" "$base + [expr {$i + 1}]c"
            } else break
        }
    }

    method session_bookmarked {path} {
        set row [{*}$LookupSession $path]
        if {$row ne ""} { return [dict getdef $row bookmarked 0] }
        return [file executable $path]
    }

    # Rewrite a session header line in place (glyphs, count). Leaves the
    # surrounding lines untouched, so a per-tick glyph refresh never shifts
    # the view.
    method redraw_header {path} {
        set s [dict get $Sessions $path]
        if {![dict get $s rendered]} return
        set smark [dict get $s smark]
        set stag  [dict get $s stag]
        set info [my build_session_line $path]
        $Text delete $smark "$smark lineend"
        $Text insert $smark [dict get $info line] \
            [list sessionhead $stag]
        my apply_line_tags $smark $path $info
        if {$Selected eq $path} {
            $Text tag add selected $smark [dict get $s semark]
        }
    }

    # Text widget yview update: forward to the scrollbar.
    method on_yscroll {args} {
        $Top.body.sb set {*}$args
    }

    method ensure_folder {folder} {
        if {[dict exists $Folders $folder]} return
        set label [::questlog::path::display_label [{*}$ResolveFolder $folder] $folder]
        set htag  "f#[incr NextId]"
        # Browsing opens folders collapsed (an overview of projects); a search
        # opens them expanded so the matches under each folder are visible. A
        # collapsed folder draws only its heading - its sessions live in the
        # model and are rendered lazily on expand, so there are no hidden lines.
        set expanded [expr {$CriteriaActive ? 1 : 0}]
        set fmark  "fm[incr NextId]"
        set femark "fe[incr NextId]"
        dict set Folders $folder [dict create fmark $fmark femark $femark \
            htag $htag label $label count 0 cost 0.0 size 0 expanded $expanded]
        set fstart [$Text index TailMark]
        set info [my folder_heading_info $folder]
        $Text insert TailMark "[dict get $info line]\n" \
            [list folderhead $htag]
        my apply_folder_tags $fstart $info
        $Text mark set $fmark $fstart
        $Text mark gravity $fmark left
        $Text mark set $femark [$Text index TailMark]
        $Text mark gravity $femark left
        dict set HtagFolder $htag $folder
        dict set SessionsByFolder $folder [list]
        lappend FolderOrder $folder
        $Text tag bind $htag <Button-1> [list [self] toggle_folder $folder]
    }

    # Build a folder heading line: the marker, the (truncated) project label and
    # a bare "(N)" session count on the left, then the folder's total size and
    # cost pinned in the same columns as the rows below. The aggregates carry no
    # date cell, so a double tab opens straight into the size column. Returns the
    # line and the char ranges apply_folder_tags bolds.
    method folder_heading_info {folder} {
        set f [dict get $Folders $folder]
        set marker [expr {[dict get $f expanded] ? "▾" : "▸"}]
        set n [dict get $f count]
        set count_str [expr {$n > 0 ? " ($n)" : ""}]
        set size_sum ""
        set cost_sum ""
        set fc 0.0
        if {$n > 0} {
            set size_sum [my fmt_size [dict getdef $f size 0]]
            set fc [dict getdef $f cost 0.0]
            if {$fc > 0} { set cost_sum [::questlog::cost::format_usd $fc] }
        }
        # Marker joined to the label by a space; the label is truncated so it
        # never runs into the right-pinned aggregates.
        set fixed [expr {[font measure QLList "$marker "] \
                         + [font measure QLList $count_str]}]
        set label [my truncate_px [dict get $f label] \
                       [expr {$FolderLabelMax - $fixed}] QLList]
        set line "$marker $label$count_str"
        append line "\t\t"
        set size_off [string length $line]
        set size_len [string length $size_sum]
        append line $size_sum
        append line "\t"
        set cost_off [string length $line]
        set cost_len [string length $cost_sum]
        append line $cost_sum
        return [dict create line $line \
            size_off $size_off size_len $size_len \
            cost_off $cost_off cost_len $cost_len cost $fc]
    }

    # Bold the folder's size and cost aggregates in their columns. The size
    # keeps the muted meta grey; the cost also takes its tier colour, so the
    # project that ate the most reads bold red at a glance.
    method apply_folder_tags {fstart info} {
        set so [dict get $info size_off]
        set sl [dict get $info size_len]
        if {$sl > 0} {
            $Text tag add meta    "$fstart + ${so}c" "$fstart + [expr {$so + $sl}]c"
            $Text tag add foldagg "$fstart + ${so}c" "$fstart + [expr {$so + $sl}]c"
        }
        set co [dict get $info cost_off]
        set cl [dict get $info cost_len]
        if {$cl > 0} {
            set fc [dict get $info cost]
            set ctag meta
            if {$fc >= 1.0} {
                set ctag cost-outlier
            } elseif {$fc >= 0.10} {
                set ctag cost-mid
            }
            $Text tag add $ctag   "$fstart + ${co}c" "$fstart + [expr {$co + $cl}]c"
            $Text tag add foldagg "$fstart + ${co}c" "$fstart + [expr {$co + $cl}]c"
        }
    }

    method redraw_folder_heading {folder} {
        if {![dict exists $Folders $folder]} return
        set f [dict get $Folders $folder]
        set fmark [dict get $f fmark]
        set info [my folder_heading_info $folder]
        $Text delete $fmark "$fmark lineend"
        $Text insert $fmark [dict get $info line] \
            [list folderhead [dict get $f htag]]
        my apply_folder_tags $fmark $info
    }

    method toggle_folder {folder} {
        if {![dict exists $Folders $folder]} return
        set exp [expr {![dict get [dict get $Folders $folder] expanded]}]
        dict set Folders $folder expanded $exp
        $Text configure -state normal
        if {$exp} { my expand_folder $folder } else { my collapse_folder $folder }
        my redraw_folder_heading $folder
        $Text configure -state disabled
    }

    method expand_folder {folder} {
        foreach path [my sort_paths [dict getdef $SessionsByFolder $folder {}] $Sessions] {
            my render_session $path
        }
    }

    # Delete every rendered line of the folder's body and drop the per-session
    # render marks; the sessions remain in the model and redraw on the next
    # expand. No hidden text is left behind.
    method collapse_folder {folder} {
        set f [dict get $Folders $folder]
        set fmark [dict get $f fmark]
        set femark [dict get $f femark]
        set bodystart [$Text index "$fmark lineend +1c"]
        $Text delete $bodystart $femark
        $Text mark set $femark $bodystart
        foreach path [dict getdef $SessionsByFolder $folder {}] {
            if {![dict exists $Sessions $path]} continue
            if {![dict get $Sessions $path rendered]} continue
            catch {$Text mark unset [dict get $Sessions $path smark] \
                                    [dict get $Sessions $path semark]}
            dict set Sessions $path rendered 0
            dict set Sessions $path stag ""
            dict set Sessions $path smark ""
            dict set Sessions $path semark ""
        }
        # Drop the now-empty per-session / per-snippet tags left by the delete.
        foreach tg [$Text tag names] {
            if {([string match "s#*" $tg] || [string match "n#*" $tg]) \
                && [llength [$Text tag ranges $tg]] == 0} {
                $Text tag delete $tg
            }
        }
    }

    method bump_folder_count {folder delta} {
        if {![dict exists $Folders $folder]} return
        dict set Folders $folder count \
            [expr {[dict get [dict get $Folders $folder] count] + $delta}]
        my redraw_folder_heading $folder
    }

    method bump_folder_cost {folder delta} {
        if {![dict exists $Folders $folder]} return
        dict set Folders $folder cost \
            [expr {[dict getdef [dict get $Folders $folder] cost 0.0] + $delta}]
        my redraw_folder_heading $folder
    }

    # Apply a batch of buffered cost results in one pass (see app.tcl
    # flush_cost). Each is routed through refresh_cost; grouping them into one
    # event-loop turn keeps a flood of worker results from churning the list
    # while the user interacts.
    method refresh_cost_batch {batch} {
        dict for {path cost_dict} $batch {
            my refresh_cost $path $cost_dict
        }
    }

    # Late arrival from the cost-pass worker. Diffs the new cost against the
    # cached one (so a retry on a re-scanned file does not double-count),
    # updates the Sessions cell, bumps the folder aggregate and the running
    # total, then redraws the row's meta region in place.
    method refresh_cost {path cost_dict} {
        if {![dict exists $Sessions $path]} return
        set s [dict get $Sessions $path]
        set old [dict getdef $s cost ""]
        if {$old eq ""} { set old 0.0 }
        set new [dict get $cost_dict cost_usd]
        set delta 0.0
        if {$new >= 0} {
            dict set Sessions $path cost $new
            if {$old < 0} { set old 0.0 }
            set delta [expr {$new - $old}]
        } else {
            # Unknown model. Leave previous cost (if any) in place; do not
            # zero out a known number on a partial result.
            dict set Sessions $path cost $new
        }
        # Turns and duration ride the same worker result; cache them so the new
        # columns fill in the same redraw as cost.
        dict set Sessions $path turns [dict getdef $cost_dict turns ""]
        dict set Sessions $path duration_secs [dict getdef $cost_dict duration_secs ""]
        # bump_folder_cost mutates the heading line and redraw_header
        # mutates the session line — both go through $Text delete/insert,
        # so the widget must be in normal state for the duration.
        $Text configure -state normal
        if {$delta != 0} {
            my bump_folder_cost [dict get $s folder] $delta
            set TotalCost [expr {$TotalCost + $delta}]
            my refresh_status
        }
        if {[dict get $s rendered]} { my redraw_header $path }
        $Text configure -state disabled
        # The worker result can change cost-, turns- or duration-sorted order.
        if {$SortKey in {cost turns duration}} { my schedule_resort }
    }

    method glyph_cell {running bookmarked} {
        set s ""
        if {$running}    { append s $::questlog::ui::GLYPH_RUNNING }
        if {$bookmarked} { append s $::questlog::ui::GLYPH_BOOKMARK }
        return $s
    }

    method tag_hits_in_range {start end snippet} {
        set terms [dict get $Query terms]
        if {[llength $terms] == 0} return
        set nocase [dict get $Query nocase]
        set hue_count [llength $HitTags]
        if {$hue_count == 0} return
        # Terms are matched literally (the search bar is Google-style); a
        # case-folded haystack gives case-insensitive search without regex.
        set hay [expr {$nocase ? [string tolower $snippet] : $snippet}]
        set i 0
        foreach term $terms {
            if {$term eq ""} { incr i; continue }
            set needle [expr {$nocase ? [string tolower $term] : $term}]
            set tlen [string length $needle]
            set tag [lindex $HitTags [expr {$i % $hue_count}]]
            set from 0
            while {1} {
                set pos [string first $needle $hay $from]
                if {$pos < 0} break
                set ts [$Text index "$start + ${pos}c"]
                set te [$Text index "$start + [expr {$pos + $tlen}]c"]
                $Text tag add $tag $ts $te
                set from [expr {$pos + $tlen}]
            }
            incr i
        }
    }

    # ---- selection / open --------------------------------------------

    # Select the whole session object - its header and any snippets - as one
    # highlighted block (the full-width region, not a text run).
    method select {path} {
        set prev $Selected
        if {$Selected ne "" && [dict exists $Sessions $Selected] \
            && [dict get $Sessions $Selected rendered]} {
            set os [dict get $Sessions $Selected]
            catch {$Text tag remove selected [dict get $os smark] [dict get $os semark]}
        }
        set Selected $path
        if {[dict exists $Sessions $path] && [dict get $Sessions $path rendered]} {
            set s [dict get $Sessions $path]
            $Text tag add selected [dict get $s smark] [dict get $s semark]
        }
        # The selected row shows its ⋯ bright; the row losing selection re-fades.
        if {$prev ne "" && $prev ne $path} { my action_set_bright $prev 0 }
        my action_set_bright $path 1
    }

    method open_session {path {lineno -1}} {
        if {$lineno < 0} {
            set lineno 0
            if {[dict exists $Sessions $path]} {
                set lineno [dict get [dict get $Sessions $path] first_lineno]
            }
        }
        {*}$OnOpen $path $lineno
    }

    # A plain click selects and opens the session in the viewer. A click that
    # moved the pointer is a drag (armed on press) and wins instead, so the
    # reading view loads only on a click that stayed put. Selecting and showing
    # are the same act, so the highlight and the viewer never disagree.
    method on_session_release {path X Y} {
        # A release on the ⋯ control raises the session menu instead of opening
        # the session, the left-click equivalent of the right-click menu.
        if {[my click_on_action $X $Y]} {
            my on_session_right $path $X $Y
            return
        }
        set was_drag [::questlog::ui::drag::release $X $Y]
        if {$was_drag} return
        my select $path
        my open_session $path
    }

    # A snippet click opens the session too, deep-linked to that match's line.
    method on_snippet_release {path lineno} {
        my select $path
        my open_session $path $lineno
    }

    # ---- drag-to-move -------------------------------------------------

    method on_session_press {path X Y} {
        # A press on the ⋯ control is a menu click, not the start of a drag.
        if {[my click_on_action $X $Y]} return
        ::questlog::ui::drag::watch $Text $X $Y [list $path] \
            [list [self] handle_drop] \
            [list [self] drag_hit] [list [self] drag_paint]
    }

    # ---- the ⋯ actions control --------------------------------------

    # The actions cell's text range for a rendered row, or {} when absent.
    method action_range {path} {
        if {![dict exists $Sessions $path]} { return {} }
        set s [dict get $Sessions $path]
        if {![dict get $s rendered]} { return {} }
        return [$Text tag nextrange actioncell \
                    [dict get $s smark] [dict get $s semark]]
    }

    method action_set_bright {path on} {
        set r [my action_range $path]
        if {[llength $r] < 2} return
        if {$on} {
            $Text tag add actioncell-bright {*}$r
        } else {
            $Text tag remove actioncell-bright {*}$r
        }
    }

    # Whether a root-coordinate click landed on a row's ⋯ actions cell.
    method click_on_action {X Y} {
        set lx [expr {$X - [winfo rootx $Text]}]
        set ly [expr {$Y - [winfo rooty $Text]}]
        set idx [$Text index @$lx,$ly]
        return [expr {[lsearch -exact [$Text tag names $idx] actioncell] >= 0}]
    }

    method on_row_enter {path} {
        $Text configure -cursor hand2
        my action_set_bright $path 1
    }

    method on_row_leave {path} {
        $Text configure -cursor arrow
        # Keep the ⋯ bright if this row stays selected; otherwise re-fade it.
        my action_set_bright $path [expr {$Selected eq $path}]
    }

    method drag_hit {X Y} {
        set lx [expr {$X - [winfo rootx $Text]}]
        set ly [expr {$Y - [winfo rooty $Text]}]
        set idx [$Text index @$lx,$ly]
        foreach t [$Text tag names $idx] {
            if {[dict exists $HtagFolder $t]} { return [dict get $HtagFolder $t] }
        }
        return ""
    }

    method drag_paint {old new} {
        if {$old ne "" && [dict exists $Folders $old]} {
            set fm [dict get [dict get $Folders $old] fmark]
            catch {$Text tag remove drop-candidate $fm "$fm lineend"}
        }
        if {$new ne "" && [dict exists $Folders $new]} {
            set fm [dict get [dict get $Folders $new] fmark]
            $Text tag add drop-candidate $fm "$fm lineend"
        }
    }

    method handle_drop {paths target_folder} {
        {*}$OnDropMove $paths $target_folder
    }

    # ---- right-click menu --------------------------------------------

    method on_session_right {path X Y} {
        set row [{*}$LookupSession $path]
        set uuid [file rootname [file tail $path]]
        set folder ""
        set cwd ""
        if {$row ne ""} {
            set folder [dict getdef $row folder ""]
            set uuid [dict getdef $row uuid $uuid]
        }
        if {$folder eq "" && [dict exists $Sessions $path]} {
            set folder [dict get [dict get $Sessions $path] folder]
        }
        if {$folder ne ""} { set cwd [{*}$ResolveFolder $folder] }
        set MenuPath $path
        set MenuTarget [dict create path $path uuid $uuid cwd $cwd folder $folder]

        set rstate [expr {$cwd ne "" ? "normal" : "disabled"}]
        foreach lbl {"Copy resume command" "Resume in new terminal tab" \
                     "Resume forked"} {
            $Menu entryconfigure $lbl -state $rstate
        }
        $Menu entryconfigure "Reveal folder" \
            -state [expr {$folder ne "" ? "normal" : "disabled"}]
        $Menu entryconfigure $BookmarkIndex \
            -label [expr {[file executable $path] ? "Remove bookmark" : "Add bookmark"}]
        # Rename writes into the file; greying it while the session is
        # running keeps us from interleaving with claude's own writes.
        set is_running [dict exists $RunningSet $uuid]
        $Menu entryconfigure $RenameIndex \
            -state [expr {$is_running ? "disabled" : "normal"}]
        tk_popup $Menu $X $Y
    }

    method menu_target_get {key} { return [dict get $MenuTarget $key] }
    method menu_open {} { my open_session $MenuPath }
    method menu_copy_resume {} {
        my clipboard_set [::questlog::terminal::resume_command \
            [my menu_target_get cwd] [my menu_target_get uuid]]
    }
    method menu_copy_uuid {} { my clipboard_set [my menu_target_get uuid] }
    method menu_copy_path {} { my clipboard_set $MenuPath }
    method menu_copy_last_assistant {} {
        my clipboard_set [::questlog::jsonl::last_assistant_text [my menu_target_get path]]
    }
    method menu_resume {fork} {
        ::questlog::terminal::launch_tab [my menu_target_get cwd] \
            [my menu_target_get uuid] $fork
    }
    method menu_reveal {} {
        set dir [file join [::questlog::path::projects_root] [my menu_target_get folder]]
        set opener [expr {$::tcl_platform(os) eq "Darwin" ? "open" : "xdg-open"}]
        if {[catch {exec $opener $dir &} err]} {
            puts stderr "questlog: $opener failed: $err"
        }
    }
    method menu_move {} { {*}$OnMoveRequest [list $MenuPath] }
    method menu_bookmark {} { {*}$OnBookmarkToggle $MenuPath }

    # Rename the session. An empty entry reverts to Claude's auto title
    # (the ai_title we captured at scan time); otherwise the new value
    # becomes the custom title. Either path appends Claude Code's native
    # rename records (custom-title and agent-name) to the jsonl, so the
    # title survives an app restart and shows up in claude's own picker.
    method menu_rename {} {
        if {![dict exists $Sessions $MenuPath]} return
        set s [dict get $Sessions $MenuPath]
        set uuid [dict get $s uuid]
        set current [dict get $s slug]
        set aitt [dict getdef $s ai_title ""]
        set entered [my prompt_rename $current]
        if {$entered eq "<cancelled>"} return
        if {$entered eq ""} {
            ::questlog::title::clear_custom $MenuPath $uuid $aitt
            dict set Sessions $MenuPath slug $aitt
        } else {
            ::questlog::title::set_custom $MenuPath $uuid $entered
            dict set Sessions $MenuPath slug $entered
        }
        $Text configure -state normal
        my redraw_header $MenuPath
        $Text configure -state disabled
    }

    # Small modal one-field dialog. Returns the entered text on OK, or
    # the literal "<cancelled>" string on Cancel / Escape / close.
    # "<cancelled>" is a sentinel rather than {} so an OK with an empty
    # entry (which means "revert to auto") stays distinguishable.
    method prompt_rename {current} {
        set dlg .renameDialog
        if {[winfo exists $dlg]} { destroy $dlg }
        toplevel $dlg
        wm title $dlg "Set session title"
        wm transient $dlg [winfo toplevel $Text]
        wm resizable $dlg 1 0
        set ::questlog::ui::rename_entry $current
        set ::questlog::ui::rename_outcome ""
        ttk::label $dlg.lbl \
            -text "Title (kebab-case; empty reverts to Claude's auto title):"
        ttk::entry $dlg.ent -textvariable ::questlog::ui::rename_entry
        ttk::frame $dlg.bf
        ttk::button $dlg.bf.ok -text "OK" \
            -command [list set ::questlog::ui::rename_outcome ok]
        ttk::button $dlg.bf.cancel -text "Cancel" \
            -command [list set ::questlog::ui::rename_outcome cancel]
        pack $dlg.lbl -padx 12 -pady {12 4} -anchor w -fill x
        pack $dlg.ent -padx 12 -pady 4 -fill x
        pack $dlg.bf  -padx 12 -pady {4 12} -anchor e -fill x
        pack $dlg.bf.cancel -side right -padx 4
        pack $dlg.bf.ok     -side right -padx 4
        bind $dlg.ent <Return> [list $dlg.bf.ok invoke]
        bind $dlg.ent <Escape> [list $dlg.bf.cancel invoke]
        wm protocol $dlg WM_DELETE_WINDOW \
            [list set ::questlog::ui::rename_outcome cancel]
        focus $dlg.ent
        $dlg.ent selection range 0 end
        grab set $dlg
        vwait ::questlog::ui::rename_outcome
        set outcome $::questlog::ui::rename_outcome
        set value   $::questlog::ui::rename_entry
        catch {grab release $dlg}
        destroy $dlg
        if {$outcome ne "ok"} { return "<cancelled>" }
        return $value
    }

    method clipboard_set {s} { clipboard clear; clipboard append $s }

    # ---- running / bookmark reconciliation ---------------------------

    # Re-derive the running glyph for every shown session from a fresh
    # running set, surfacing running sessions that are not yet shown and
    # dropping rows that no longer pass a running-only / bookmarked-only
    # filter. Idempotent: running it twice is a no-op, and a missed tick
    # self-corrects on the next.
    method reconcile_running {running} {
        set RunningSet $running
        set running_only    [dict getdef $Snapshot running_only 0]
        set bookmarked_only [dict getdef $Snapshot bookmarked_only 0]
        set before [dict size $Sessions]

        $Text configure -state normal
        my anchor_save
        if {$running_only || !$CriteriaActive} {
            dict for {uuid path} $running {
                if {[dict exists $Sessions $path]} continue
                set row [{*}$LookupSession $path]
                if {$row eq "" && [file isfile $path]} {
                    set row [{*}$OnScanPath $path]
                }
                if {$row eq "" || ![dict size $row]} continue
                # OnScanPath above is not a pure read: scan_path -> publish_row
                # fires OnRow, which in browse mode is on_scan_row, which has
                # already added (and rendered) this session. Re-check so we do
                # not add it a second time. A running session that on_scan_row
                # filtered out (out of window / one-turn) is still absent here
                # and is added below, so running sessions always surface.
                if {[dict exists $Sessions $path]} continue
                my model_add_session $path $row
                if {[my folder_expanded [dict get $row folder]]} {
                    my render_session $path
                }
            }
        }
        foreach path [my all_session_paths] {
            if {![dict exists $Sessions $path]} continue
            set uuid [dict get [dict get $Sessions $path] uuid]
            set is_running [dict exists $running $uuid]
            # A session that is not running and whose backing jsonl is gone is
            # a phantom in every mode - a Resume-forked session quit before any
            # input leaves no file, but its cached Rows row outlives the file
            # and would otherwise keep it (and its folder count) forever. A
            # still-running session is exempt: its file may be mid-creation.
            if {!$is_running && ![file isfile $path]} {
                my forget_session $path
                continue
            }
            set row [{*}$LookupSession $path]
            set bk 0
            if {$row ne ""} { set bk [dict getdef $row bookmarked 0] }
            if {$running_only && $bookmarked_only} {
                set keep [expr {$is_running && $bk}]
            } elseif {$running_only} {
                set keep $is_running
            } elseif {$bookmarked_only} {
                set keep $bk
            } elseif {$CriteriaActive} {
                set keep 1
            } else {
                set keep [expr {($row ne "" && [my row_matches_snapshot $row]) || $is_running}]
            }
            if {!$keep} { my forget_session $path; continue }
            my redraw_header $path
        }
        my anchor_restore
        $Text configure -state disabled
        # Surfacing or dropping running sessions changes the set, so a
        # non-default sort needs a re-render to reseat them.
        if {[dict size $Sessions] != $before} { my schedule_resort }
    }

    method reconcile_one {path} {
        if {![dict exists $Sessions $path]} return
        $Text configure -state normal
        my redraw_header $path
        $Text configure -state disabled
    }

    method all_session_paths {} {
        set out [list]
        foreach folder $FolderOrder {
            foreach path [dict getdef $SessionsByFolder $folder {}] { lappend out $path }
        }
        return $out
    }

    # ---- removal / relocation ----------------------------------------

    method forget_session {path} {
        if {![dict exists $Sessions $path]} return
        set s [dict get $Sessions $path]
        set folder [dict get $s folder]
        if {[dict get $s rendered]} {
            $Text delete [dict get $s smark] [dict get $s semark]
            catch {$Text mark unset [dict get $s smark] [dict get $s semark]}
        }
        # Subtract this session's cost and size from the folder aggregates and
        # the running total before the dict entry vanishes, so a later sum over
        # remaining sessions stays exact.
        set cost [dict getdef $s cost ""]
        if {$cost ne "" && $cost > 0} {
            my bump_folder_cost $folder [expr {-$cost}]
            set TotalCost [expr {$TotalCost - $cost}]
            my refresh_status
        }
        dict unset Sessions $path
        if {$Selected eq $path} { set Selected "" }
        set lst [dict getdef $SessionsByFolder $folder {}]
        set i [lsearch -exact $lst $path]
        if {$i >= 0} { dict set SessionsByFolder $folder [lreplace $lst $i $i] }
        if {[llength [dict getdef $SessionsByFolder $folder {}]] == 0} {
            my forget_folder $folder
        } else {
            dict set Folders $folder size \
                [expr {[dict getdef [dict get $Folders $folder] size 0] \
                       - [dict getdef $s size 0]}]
            my bump_folder_count $folder -1
        }
    }

    method forget_folder {folder} {
        if {![dict exists $Folders $folder]} return
        set f [dict get $Folders $folder]
        set fmark [dict get $f fmark]
        set femark [dict get $f femark]
        $Text delete $fmark $femark
        catch {$Text mark unset $fmark $femark}
        dict unset HtagFolder [dict get $f htag]
        dict unset Folders $folder
        dict unset SessionsByFolder $folder
        set i [lsearch -exact $FolderOrder $folder]
        if {$i >= 0} { set FolderOrder [lreplace $FolderOrder $i $i] }
    }

    # After a move renames the file, re-key the model and rebuild the view
    # so the session appears under its new folder. A full rebuild keeps the
    # mark scheme consistent; moves are rare, so the cost is not on a hot path.
    method relocate_card {old_path new_path new_folder} {
        if {![dict exists $Sessions $old_path]} return
        set s [dict get $Sessions $old_path]
        set old_folder [dict get $s folder]
        dict set s folder $new_folder
        dict unset Sessions $old_path
        dict set Sessions $new_path $s
        set lst [dict getdef $SessionsByFolder $old_folder {}]
        set i [lsearch -exact $lst $old_path]
        if {$i >= 0} { dict set SessionsByFolder $old_folder [lreplace $lst $i $i] }
        if {![dict exists $SessionsByFolder $new_folder]} {
            dict set SessionsByFolder $new_folder [list]
            lappend FolderOrder $new_folder
        }
        dict lappend SessionsByFolder $new_folder $new_path
        if {$Selected eq $old_path} { set Selected $new_path }
        my redraw_all
    }

    method redraw_all {} {
        $Text configure -state normal
        my anchor_save
        $Text delete 1.0 end
        my purge_tags_and_marks
        $Text mark set TailMark "end-1c"
        $Text mark gravity TailMark right
        # Snapshot the model, remember each folder's expanded state, then
        # rebuild the model and re-render only the expanded folders' bodies.
        set saved $Sessions
        set order $FolderOrder
        set byfolder $SessionsByFolder
        set wasexp [dict create]
        set foldercost [dict create]
        dict for {f fd} $Folders {
            dict set wasexp $f [dict get $fd expanded]
            dict set foldercost $f [dict getdef $fd cost 0.0]
        }
        # Sorting by cost reorders the folders by their aggregate too; the other
        # keys keep the folders in arrival order.
        if {$SortKey eq "cost"} { set order [my sort_folders $order $foldercost] }
        set Folders [dict create]
        set FolderOrder [list]
        set SessionsByFolder [dict create]
        set HtagFolder [dict create]
        set Sessions [dict create]
        # Folders.cost was wiped above; reset TotalCost too so the bumps in
        # model_add_session re-establish both consistently.
        set TotalCost 0.0
        foreach folder $order {
            foreach path [my sort_paths [dict getdef $byfolder $folder {}] $saved] {
                if {![dict exists $saved $path]} continue
                set s [dict get $saved $path]
                my model_add_session $path \
                    [dict create folder [dict get $s folder] \
                         uuid [dict get $s uuid] mtime [dict getdef $s mtime 0] \
                         size [dict get $s size] \
                         first_user [dict get $s label] \
                         slug [dict getdef $s slug ""] \
                         ai_title [dict getdef $s ai_title ""] \
                         cost_usd [dict getdef $s cost ""]] \
                    [dict get $s first_lineno]
                dict set Sessions $path label [dict get $s label]
                dict set Sessions $path when [dict get $s when]
                dict set Sessions $path snippets [dict get $s snippets]
                dict set Sessions $path count [dict get $s count]
            }
            if {[dict exists $wasexp $folder] && [dict exists $Folders $folder]} {
                dict set Folders $folder expanded [dict get $wasexp $folder]
            }
        }
        foreach folder $FolderOrder {
            if {[dict get [dict get $Folders $folder] expanded]} {
                foreach path [dict getdef $SessionsByFolder $folder {}] {
                    my render_session $path
                }
            }
            my redraw_folder_heading $folder
        }
        if {$Selected ne "" && [dict exists $Sessions $Selected] \
            && [dict get $Sessions $Selected rendered]} {
            set sm [dict get [dict get $Sessions $Selected] smark]
            $Text tag add selected $sm "$sm lineend"
        }
        my anchor_restore
        $Text configure -state disabled
    }

    # ---- status ------------------------------------------------------

    method set_progress {done total matches} {
        set StatusBase "Searching … $done / $total sessions   matches: $matches"
        my refresh_status
    }
    method set_done {total matches} {
        set StatusBase "Done. $total sessions, $matches matches."
        my refresh_status
    }
    method cancel {} {
        if {$CancelCb ne ""} { {*}$CancelCb }
        set StatusBase "Cancelled."
        my refresh_status
    }

    # Recompute the visible status string from the current base + total.
    # The total is hidden when zero so a fresh app or a rate-table miss
    # does not show "$0.00" as a misleading aggregate. The bullet
    # separator only appears between a non-empty base and the total, so
    # a browse-mode scan (base empty) shows the dollar amount alone.
    method refresh_status {} {
        set total ""
        if {$TotalCost > 0} { set total [::questlog::cost::format_usd $TotalCost] }
        if {$StatusBase ne "" && $total ne ""} {
            set StatusVar "$StatusBase · $total"
        } elseif {$total ne ""} {
            set StatusVar $total
        } else {
            set StatusVar $StatusBase
        }
    }

    # ---- formatting helpers ------------------------------------------

    method fmt_time {epoch} {
        if {$epoch eq "" || $epoch == 0} { return "" }
        return [clock format $epoch -format "%a %d %b %H:%M"]
    }

    method fmt_size {bytes} {
        if {$bytes eq "" || $bytes == 0} { return "" }
        if {$bytes < 1024}        { return "${bytes} B" }
        if {$bytes < 1048576}     { return "[expr {$bytes / 1024}] K" }
        if {$bytes < 1073741824}  { return "[format %.1f [expr {$bytes / 1048576.0}]] M" }
        return "[format %.1f [expr {$bytes / 1073741824.0}]] G"
    }
}
