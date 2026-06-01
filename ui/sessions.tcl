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
# The list is one generic tree of nodes drawn into a single text widget. A
# node is a folder, a session, or a subagent; each carries the position marks
# and tag that locate it in the widget, plus a domain payload. Folders are the
# roots; a session's subagents are its child nodes, appended at the session's
# end region exactly as snippet and child rows render between a header and its
# append point.
#
# A text widget is the list; each node tracks its position with two marks:
#   node.start  the mark at the node's first char.
#               Folders: right gravity (heading start). Sessions and subagents:
#               left gravity (header start).
#   node.end    the mark just past the node's last descendant line, the append
#               point where the node's children and content land.
#               Folders and sessions: left gravity.
#   node.tag    the per-node text tag carrying the heading's drop hit-test
#               (folders) or the row's click/drag bindings (sessions, subagents).
# Plus TailMark: right gravity, always just before the implicit final newline,
# the append point for new folder headings.
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
    # The generic node store. Nodes maps a node id to its dict
    # {parent kind expanded rendered start end tag children payload}; Roots is
    # the ordered list of root (folder) node ids, in arrival (mtime-desc) order.
    variable Nodes
    variable Roots
    # Domain indices into the node store: a folder name or a session/subagent
    # path to its node id.
    variable FolderNode       ;# folder name -> node id
    variable PathNode         ;# session path OR subagent path -> node id
    variable TagNode          ;# folder node.tag -> node id, for drop hit-testing
    variable Selected         ;# currently selected session path, or ""
    variable NextId
    variable Menu
    variable MenuPath
    variable MenuTarget
    variable CMenu            ;# the reduced right-click menu for subagent child rows
    variable ChildMenuPath    ;# child path the child menu acts on
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
    variable OnSubagents      ;# cb: parent path -> list of child row dicts
    variable OnSubagentCost   ;# cb: child path -> start the cost pass for it

    constructor {parent resolve_cb lookup_cb on_open on_move_request \
                 on_drop_move on_bookmark_toggle on_scan_path cancel_cb \
                 on_show_all on_subagents on_subagent_cost} {
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
        set OnSubagents $on_subagents
        set OnSubagentCost $on_subagent_cost
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
        set Nodes [dict create]
        set Roots [list]
        set FolderNode [dict create]
        set PathNode [dict create]
        set TagNode [dict create]
        set Selected ""
    }

    # ---- generic node store ------------------------------------------
    #
    # A node id is allocated from NextId; the store keeps the structural fields
    # (parent/kind/expanded/rendered/start/end/tag/children) generic and hangs
    # the domain dict off `payload`. The accessors below are the single door to
    # the store so every folder/session/subagent operation reads and writes
    # node state the same way.

    method node_new {kind parent key payload} {
        set id "node[incr NextId]"
        # `key` is the node's domain key (folder name for folders, file path for
        # sessions and subagents): the reverse lookup from a node id back to the
        # FolderNode / PathNode index, kept out of payload so payload stays the
        # pristine per-entity dict.
        dict set Nodes $id [dict create \
            parent $parent kind $kind key $key expanded 0 rendered 0 \
            start "" end "" tag "" children [list] payload $payload]
        return $id
    }
    method node_exists {id} { return [dict exists $Nodes $id] }
    method node_get {id} { return [dict get $Nodes $id] }
    method node_field {id field} { return [dict get [dict get $Nodes $id] $field] }
    method node_set {id field value} { dict set Nodes $id $field $value }
    method node_payload {id} { return [dict get [dict get $Nodes $id] payload] }
    method node_pget {id key {dflt ""}} {
        return [dict getdef [dict get [dict get $Nodes $id] payload] $key $dflt]
    }
    method node_pset {id key value} {
        dict set Nodes $id payload [dict replace \
            [dict get [dict get $Nodes $id] payload] $key $value]
    }

    # ---- public payload accessors (white-box tests, and any caller that
    # wants a read-only snapshot of a row's domain dict) -----------------

    method session_payload {path} {
        if {![dict exists $PathNode $path]} { return "" }
        return [my node_payload [dict get $PathNode $path]]
    }
    method folder_payload {folder} {
        if {![dict exists $FolderNode $folder]} { return "" }
        return [my node_payload [dict get $FolderNode $folder]]
    }

    # ---- domain-keyed shims over the node store ----------------------
    #
    # Folder/session/subagent operations name their target by domain key
    # (folder name or file path). These shims turn that key into a node id and
    # read or write the structural and payload fields, so the bodies below read
    # the same way they did against the old per-entity dicts.

    method has_session {path} { return [dict exists $PathNode $path] }
    method has_child {path}   { return [dict exists $PathNode $path] }
    method has_folder {folder} { return [dict exists $FolderNode $folder] }

    method sid {path} { return [dict get $PathNode $path] }
    method fid {folder} { return [dict get $FolderNode $folder] }

    method sget {path key {dflt ""}} { my node_pget [my sid $path] $key $dflt }
    method sset {path key value} { my node_pset [my sid $path] $key $value }
    method sflag {path field} { my node_field [my sid $path] $field }
    method sflagset {path field value} { my node_set [my sid $path] $field $value }

    method cget_field {path key {dflt ""}} { my node_pget [my sid $path] $key $dflt }
    method cset {path key value} { my node_pset [my sid $path] $key $value }

    method fget {folder key {dflt ""}} { my node_pget [my fid $folder] $key $dflt }
    method fset {folder key value} { my node_pset [my fid $folder] $key $value }

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
        frame $Top.banner -background [::questlog::ui::theme::c banner_bg]
        label $Top.banner.text -anchor w \
            -background [::questlog::ui::theme::c banner_bg] \
            -foreground [::questlog::ui::theme::c banner_fg]
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
            -background [::questlog::ui::theme::c strip] \
            -foreground [::questlog::ui::theme::c muted]
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
        my build_child_menu
    }

    method configure_tags {} {
        # Folder heading: the outermost level, with a wide gap above so each
        # project group reads as a section. Proportional (QLList), like the
        # rest of the list - the design carries no fixed-width font.
        # Folder heading is single-line so its size/cost aggregates can sit in
        # the same right-pinned columns as the session rows below it.
        $Text tag configure folderhead \
            -font QLList -foreground [::questlog::ui::theme::c folder] \
            -spacing1 14 -spacing3 3 -wrap none
        $Text tag configure glyph-running  -foreground [::questlog::ui::theme::c glyph_running]
        $Text tag configure glyph-bookmark -foreground [::questlog::ui::theme::c glyph_bookmark]
        # Session header: one line, the block's "title" (like a search result
        # heading), indented under its folder. Rows are separated by the gap
        # above each and the bold title colour; no background band. The
        # selected row gets a highlight for click feedback. The metadata
        # columns align on per-tag right tab stops (set by layout_columns), so
        # the line reads in the proportional QLList without a fixed-width crutch.
        $Text tag configure sessionhead -lmargin1 12 -lmargin2 28 \
            -spacing1 6 -spacing3 2 -foreground [::questlog::ui::theme::c ink] \
            -font QLList
        # The slug (Claude's agentName / aiTitle) renders bold inline before
        # the prompt body, so the slug acts as the headline and the prompt
        # as the deck below it. Bold weight is the only marker; brackets
        # would compete with the kebab-case hyphens.
        $Text tag configure slug -font QLBold
        $Text tag configure selected -background [::questlog::ui::theme::c sel]
        $Text tag configure drop-candidate -background [::questlog::ui::theme::c drop]

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
        set bpw [image width [::questlog::ui::theme::badge_pill system]]
        set content_col [expr {$badgecol + $bpw + 12}]
        $Text configure -tabs [list $content_col left]
        # A thin session-grouping spine runs in the gutter to the left of the
        # badge: every snippet line opens with a bar glyph, so the matches of one
        # session stack into one continuous rule (the design's MatchList left
        # guide). The badge (an embedded pill) sits at lmargin2; content tabs to
        # content_col. -wrap none clips each match to one row, as the design does.
        $Text tag configure snippet -lmargin1 $barcol -lmargin2 $badgecol \
            -tabs [list $content_col left] -wrap none \
            -font QLList -foreground [::questlog::ui::theme::c snippet] -spacing3 1
        $Text tag configure snippetbar -foreground [::questlog::ui::theme::c snippet_guide]
        # Subagent child rows (issue #13): a session-header-style line one indent
        # deeper than the parent, on the same metadata tab stops (set by
        # layout_columns) so date/size/cost/turns/duration sit under the parent's
        # columns. The leading spine reuses the snippet guide colour as the tree
        # connector, so a session's children read as one grouped run.
        $Text tag configure childhead -lmargin1 30 -lmargin2 46 \
            -spacing1 2 -spacing3 2 -wrap none \
            -foreground [::questlog::ui::theme::c ink] -font QLList
        $Text tag configure childbar -foreground [::questlog::ui::theme::c snippet_guide]
        # A subagent's matched line, beneath its child row, indented past the
        # child so the hit reads at full width (its own line, not cramped into the
        # metadata strip). Same look as a parent snippet, one level deeper.
        $Text tag configure childsnip -lmargin1 40 -lmargin2 40 -wrap none \
            -font QLList -foreground [::questlog::ui::theme::c snippet] -spacing3 1
        # The expand/collapse chevron at the head of a session that has subagents.
        $Text tag configure chevron -foreground [::questlog::ui::theme::c meta]
        # Metadata cells (date, size, cost): the muted grey column run pinned
        # to the right of each session line. Proportional QLList, aligned by
        # the sessionhead right tab stops, not a monospace font.
        $Text tag configure meta -foreground [::questlog::ui::theme::c meta]
        # Cost tiers draw the eye to the sessions that ate the budget: amber
        # from 10c, brick red from $1. Below 10c the cell keeps the muted meta
        # grey, so only elevated costs stand out. Configured after meta so the
        # tier foreground wins over it on the cost cell.
        $Text tag configure cost-mid     -foreground [::questlog::ui::theme::c cost_mid]
        $Text tag configure cost-outlier -foreground [::questlog::ui::theme::c cost_outlier]
        # The per-row actions control ("⋯") in the rightmost column. It rests at
        # the faded meta grey with the rest of the metadata and brightens to ink
        # while its row is hovered or selected, so the menu it opens advertises
        # itself for anyone whose trackpad refuses the right-click. The bright
        # tag is added/removed per row over the cell's range; configured after
        # meta so its foreground wins.
        $Text tag configure actioncell        -foreground [::questlog::ui::theme::c meta]
        $Text tag configure actioncell-bright  -foreground [::questlog::ui::theme::c ink]
        # Folder size/cost aggregates are bold (a sum, not a row value); they
        # overlay meta or a cost tier for colour, so this only sets the weight.
        $Text tag configure foldagg -font QLBold

        set HitTags [list]
        set hues [::questlog::ui::theme::hues]
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
        $Text tag configure childhead   -tabs $ColTabs
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
        foreach fid $Roots {
            my redraw_folder_heading [my node_field $fid key]
            foreach sid [my node_field $fid children] {
                if {[my node_field $sid rendered]} {
                    set path [my node_field $sid key]
                    my redraw_header $path
                    if {[my node_field $sid expanded]} { my rerender_children $path }
                }
            }
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
        $h tag configure colactive -font QLBold -foreground [::questlog::ui::theme::c ink]
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
        $Menu add command -label "Copy session as Markdown" \
            -command [list [self] menu_copy_markdown]
        $Menu add command -label "Export to .md..." \
            -command [list [self] menu_export_markdown]
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
                || [string match "n#*" $t] || [string match "c#*" $t]} {
                $Text tag delete $t
            }
        }
        foreach m [$Text mark names] {
            if {[string match "sm*" $m] || [string match "se*" $m] \
                || [string match "fm*" $m] || [string match "fe*" $m] \
                || [string match "ch*" $m]} {
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
        if {[dict exists $PathNode $path]} return
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
        # Subagent matches attach to the parent session (issue #13 cases B and C);
        # a session's own matches take the path below.
        if {[dict getdef $first is_child 0]} {
            my add_subagent_matches $matches
            return
        }
        set path  [dict get $first path]
        if {![my has_session $path]} {
            set row [{*}$LookupSession $path]
            if {$row eq ""} { set row [dict create folder [dict get $first folder]] }
            my model_add_session $path $row [dict get $first lineoff]
        }
        # Search folders are expanded, so render the session if it is not yet.
        if {[my folder_expanded [my sget $path folder]] \
            && ![my sflag $path rendered]} {
            my render_session $path
        }
        set cap [::questlog::config::get snippets_per_session]
        foreach m $matches {
            my sset $path count [expr {[my sget $path count] + 1}]
            if {[llength [my sget $path snippets]] < $cap} {
                set btype   [dict get $m btype]
                set content [dict get $m content]
                set lineoff [dict get $m lineoff]
                set sn [my sget $path snippets]
                lappend sn [list $btype $content $lineoff]
                my sset $path snippets $sn
                if {[my sflag $path rendered]} {
                    my render_snippet $path $btype $content $lineoff
                }
            }
        }
        if {[my sflag $path rendered]} { my redraw_header $path }
    }

    method folder_expanded {folder} {
        if {![dict exists $FolderNode $folder]} { return 0 }
        return [my node_field [dict get $FolderNode $folder] expanded]
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
        # The session node: payload carries the per-session domain dict; the
        # node's expanded/rendered flags, start/end marks, tag and children
        # (the attached subagent nodes) live alongside it in the store.
        set fid [my fid $folder]
        set sid [my node_new session $fid $path [dict create \
            folder $folder label $label slug $slug ai_title $aitt \
            when $when mtime $mtime size $size uuid $uuid cost $cost \
            turns $turns duration_secs $dsecs \
            own_cost $cost own_turns $turns own_duration_secs $dsecs \
            count 0 first_lineno $first_lineno snippets [list] \
            has_subagents [dict getdef $row has_subagents 0] \
            sub_total 0 children_listed 0 all_child_paths [list]]]
        dict set PathNode $path $sid
        my node_set $fid children [linsert [my node_field $fid children] end $sid]

        # Enumerate and trigger subagents' cost if there are any
        if {[dict getdef $row has_subagents 0]} {
            my ensure_children_enumerated $path
            my recompute_parent_totals $path
            set cost [my sget $path cost]
        }

        # Count and size accrue together (size is known at scan time); fold both
        # into one heading redraw. Cost arrives later, on its own redraw.
        my fset $folder count [expr {[my fget $folder count] + 1}]
        my fset $folder size [expr {[my fget $folder size 0] + $size}]
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
        set sid [my sid $path]
        if {[my node_field $sid rendered]} return
        set folder [my sget $path folder]
        set femark [my node_field [my fid $folder] end]
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
        my node_set $sid tag $stag
        my node_set $sid start $smark
        my node_set $sid end $semark
        my node_set $sid rendered 1
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
        foreach snip [my sget $path snippets] {
            lassign $snip btype content lineoff
            my render_snippet $path $btype $content $lineoff
        }
        if {[my node_field $sid expanded]} { my render_children $path }
        if {$Selected eq $path} {
            $Text tag add selected $smark "$smark lineend"
        }
    }

    method render_snippet {path btype content lineoff} {
        set semark [my node_field [my sid $path] end]
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
        # lazily through -create so only the on-screen badges become real
        # widgets: a whole-corpus search can list thousands of snippets, and
        # eagerly building a widget per badge pegs a core; -create keeps it to a
        # screenful.
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
        set folder [my sget $path folder]
        if {[my has_folder $folder]} {
            $Text mark set [my node_field [my fid $folder] end] \
                [$Text index $semark]
        }
    }

    # Build one snippet badge on demand (the text widget's -create callback when
    # the row scrolls into view). Embedded windows do not inherit the row's tag
    # bindings, so click and context-menu are forwarded to the same handlers.
    method make_badge {bt fgrole path lineoff} {
        set b $Text.badge[incr NextId]
        label $b -image [::questlog::ui::theme::badge_pill $bt] -compound center \
            -text [string toupper [string map {_ { }} $bt]] \
            -font QLBold -foreground [::questlog::ui::theme::c $fgrole] \
            -background [$Text cget -background] -borderwidth 0 \
            -takefocus 0 -cursor hand2
        bind $b <ButtonRelease-1> [list [self] on_snippet_release $path $lineoff]
        bind $b <<ContextMenu>>   [list [self] on_session_right $path %X %Y]
        return $b
    }

    # ---- subagent child rows (issue #13) ------------------------------
    #
    # A session with subagents shows a chevron; expanding renders its subagents
    # as indented child rows under its header, pinned to the same metadata
    # columns. In browse the children are enumerated on demand (all of them); in
    # search the matched children attach as their matches arrive (sub_paths), and
    # the parent auto-expands when only its subagents matched (case B). Children
    # live in their own model (Children) and never enter Scan's Rows; their cost
    # rides the same second pass as a session's, triggered when first drawn.

    method toggle_subagents {path} {
        if {![my has_session $path]} return
        if {![my sget $path has_subagents]} return
        set sid [my sid $path]
        set exp [expr {![my node_field $sid expanded]}]
        my node_set $sid expanded $exp
        $Text configure -state normal
        my anchor_save
        if {$exp} { my expand_subagents $path } else { my collapse_subagents $path }
        if {[my node_field $sid rendered]} { my redraw_header $path }
        my anchor_restore
        $Text configure -state disabled
    }

    # Render a session's children. With no attached set yet (browse, or a search
    # case-A session whose subagents did not match), enumerate them all; otherwise
    # render the attached set (sub_paths, the matched children in search).
    # The attached subagent subset, as child paths in render order, derived from
    # the session node's children (the node ids of the attached subagents).
    method session_child_paths {path} {
        set out [list]
        foreach cid [my node_field [my sid $path] children] {
            lappend out [my node_field $cid key]
        }
        return $out
    }

    # The start mark of a session's children block, or "" when no child is
    # rendered: the first rendered child node's start mark. This is where the
    # old transient chmark sat (left gravity at the session's append point when
    # the first child went in), so deleting from here to the session end drops
    # the whole children run.
    method children_region_start {path} {
        foreach cid [my node_field [my sid $path] children] {
            if {[my node_field $cid rendered]} {
                return [my node_field $cid start]
            }
        }
        return ""
    }

    # Attach a subagent path to the session node's children (the rendered
    # subset), preserving arrival order and skipping a path already attached.
    method attach_child {path cp} {
        set sid [my sid $path]
        set cid [my sid $cp]
        if {$cid in [my node_field $sid children]} return
        my node_set $sid children [linsert [my node_field $sid children] end $cid]
    }

    method expand_subagents {path} {
        if {[llength [my node_field [my sid $path] children]] == 0} {
            my ensure_children_enumerated $path
            foreach cp [my sget $path all_child_paths] { my attach_child $path $cp }
        }
        my render_children $path
    }

    method collapse_subagents {path} {
        set chm [my children_region_start $path]
        if {$chm ne ""} {
            catch {$Text delete $chm [my node_field [my sid $path] end]}
        }
        foreach cp [my session_child_paths $path] {
            if {[my has_child $cp]} { my reset_child_render $cp }
        }
    }

    # Drop a subagent's render state: its rendered flag, tag, and the start/end
    # marks left behind by a deleted children block (so the "ch" marks do not
    # accumulate across collapse/rerender cycles).
    method reset_child_render {cp} {
        set cid [my sid $cp]
        catch {$Text mark unset [my node_field $cid start]}
        catch {$Text mark unset [my node_field $cid end]}
        my node_set $cid rendered 0
        my node_set $cid tag ""
        my node_set $cid start ""
        my node_set $cid end ""
    }

    # Ask the scanner for every subagent of this session and seed their models
    # (meta only, no hits). Once per session; the matched-children set is built
    # separately as search matches arrive.
    method ensure_children_enumerated {path} {
        if {[my sget $path children_listed]} return
        set listed [list]
        foreach crow [{*}$OnSubagents $path] {
            my child_add_model $path $crow
            lappend listed [dict get $crow path]
        }
        my sset $path all_child_paths $listed
        my sset $path children_listed 1
    }

    # Seed a subagent node from a row dict (from the scanner or a search match),
    # meta only, parented to its session node but not yet attached to the
    # rendered subset (that is the session node's children). Guarded so a later
    # re-enumeration cannot wipe hits already attached from a match.
    method child_add_model {parent crow} {
        set cp [dict get $crow path]
        if {[my has_child $cp]} return
        set label [dict getdef $crow description ""]
        if {$label eq ""} { set label [dict getdef $crow agent_type ""] }
        if {$label eq ""} {
            set label [dict getdef $crow agent_id [file rootname [file tail $cp]]]
        }
        set cid [my node_new subagent [my sid $parent] $cp [dict create \
            parent_path [dict getdef $crow parent_path ""] \
            folder [dict getdef $crow folder ""] \
            when [my fmt_time [dict getdef $crow mtime 0]] \
            mtime [dict getdef $crow mtime 0] \
            size [dict getdef $crow size 0] \
            cost "" turns "" duration_secs "" \
            agent_type [dict getdef $crow agent_type ""] \
            agent_id [dict getdef $crow agent_id [file rootname [file tail $cp]]] \
            label $label hits [list] open_lineoff 0]]
        dict set PathNode $cp $cid
        # Trigger the cost pass for the subagent immediately.
        {*}$OnSubagentCost $cp
    }

    method render_children {path} {
        if {![my sflag $path rendered]} return
        foreach cp [my session_child_paths $path] {
            if {![my has_child $cp]} continue
            if {[my node_field [my sid $cp] rendered]} continue
            my render_child $path $cp
        }
    }

    # Drop and redraw a session's whole children block (cheap: subagents per
    # session are few). Used when a child's cost arrives, so the new cell lands
    # without per-row mark surgery.
    method rerender_children {path} {
        if {![my has_session $path]} return
        if {![my sflag $path rendered]} return
        set chm [my children_region_start $path]
        if {$chm eq ""} return
        $Text delete $chm [my node_field [my sid $path] end]
        foreach cp [my session_child_paths $path] {
            if {[my has_child $cp]} { my reset_child_render $cp }
        }
        my render_children $path
    }

    # Draw one subagent under its parent: a tree-spine header line carrying the
    # agent type, the subagent's description, and date/size/cost/turns/duration
    # pinned in the parent's columns; then, in search, its matched lines as
    # full-width snippet rows beneath (capped at snippets_per_subagent already).
    method render_child {path cp} {
        if {![my has_child $cp]} return
        set cid [my sid $cp]
        if {[my node_field $cid rendered]} return
        set semark [my node_field [my sid $path] end]
        # The subagent node's start mark sits at its row's first char, left
        # gravity, so an insert at the session append point (right of it) keeps
        # it pinned to this row. The first child's start mark is the children
        # block start (where the old transient chmark sat), the anchor
        # children_region_start hands collapse/rerender to delete from.
        set cstart "ch[incr NextId]"
        $Text mark set $cstart [$Text index $semark]
        $Text mark gravity $cstart left
        set ctag "c#[incr NextId]"
        set info [my build_child_line $cp]
        set tmp tmpchild
        $Text mark set $tmp [$Text index $semark]
        $Text mark gravity $tmp right
        set rstart [$Text index $tmp]
        $Text insert $tmp "[dict get $info line]\n" [list childhead $ctag]
        my apply_child_tags $rstart $cp $info
        $Text mark set $semark [$Text index $tmp]
        $Text mark unset $tmp
        # The child node's end advances past its own rows so its region nests
        # inside the session's; render_child_snippet keeps moving both forward.
        set cend "ch[incr NextId]"
        $Text mark set $cend [$Text index $semark]
        $Text mark gravity $cend left
        my node_set $cid start $cstart
        my node_set $cid end $cend
        set c [my node_payload $cid]
        foreach h [dict get $c hits] {
            lassign $h btype content lineoff
            my render_child_snippet $path $cp $content $lineoff
        }
        $Text mark set $cend [$Text index $semark]
        set folder [my sget $path folder]
        if {[my has_folder $folder]} {
            $Text mark set [my node_field [my fid $folder] end] \
                [$Text index $semark]
        }
        set lineoff 0
        if {[llength [dict get $c hits]] > 0} {
            set lineoff [lindex [lindex [dict get $c hits] 0] 2]
        }
        my node_set $cid tag $ctag
        my node_pset $cid open_lineoff $lineoff
        my node_set $cid rendered 1
        $Text tag bind $ctag <ButtonRelease-1> [list [self] on_child_release $cp]
        $Text tag bind $ctag <<ContextMenu>> [list [self] on_child_right $cp %X %Y]
        $Text tag bind $ctag <Enter> [list $Text configure -cursor hand2]
        $Text tag bind $ctag <Leave> [list $Text configure -cursor arrow]
        # Cost rides the same second pass as a session's; trigger it once (when
        # the child has no cost yet), so a re-render after the result does not
        # re-queue it.
        if {[dict get $c cost] eq ""} { {*}$OnSubagentCost $cp }
    }

    # A subagent's matched line, beneath its child header, opening the subagent's
    # own transcript at the hit (issue #13 chose per-file open over a unified
    # parent+child view). Lighter than a parent snippet (no badge widget): a
    # deeper spine then the hit-centred content with the terms emboldened.
    method render_child_snippet {path cp content lineoff} {
        set semark [my node_field [my sid $path] end]
        set ntag "c#[incr NextId]"
        set tmp tmpcsnip
        $Text mark set $tmp [$Text index $semark]
        $Text mark gravity $tmp right
        $Text insert $tmp "▏  " [list childsnip childbar $ntag]
        set cstart [$Text index $tmp]
        $Text insert $tmp $content [list childsnip $ntag]
        set cend [$Text index $tmp]
        $Text insert $tmp "\n" [list childsnip $ntag]
        my tag_hits_in_range $cstart $cend $content
        $Text tag bind $ntag <ButtonRelease-1> [list [self] on_child_open_at $cp $lineoff]
        $Text tag bind $ntag <<ContextMenu>> [list [self] on_child_right $cp %X %Y]
        $Text tag bind $ntag <Enter> [list $Text configure -cursor hand2]
        $Text tag bind $ntag <Leave> [list $Text configure -cursor arrow]
        $Text mark set $semark [$Text index $tmp]
        $Text mark unset $tmp
    }

    # Build a subagent's header row: the tree spine, the bold agent type, the
    # description, and the right-pinned metadata cells.
    method build_child_line {cp} {
        set c [my node_payload [my sid $cp]]
        set cells [my meta_cells $c]
        set spine "▏  "
        set subj $spine
        set atype [dict get $c agent_type]
        set atype_off -1
        set atype_len 0
        if {$atype ne ""} {
            set atype_off [string length $subj]
            append subj $atype
            set atype_len [string length $atype]
            append subj "  "
        }
        set body [dict get $c label]
        set fixed [font measure QLList $spine]
        if {$atype ne ""} {
            incr fixed [expr {[font measure QLBold $atype] + [font measure QLList "  "]}]
        }
        set body [my truncate_px $body [expr {$SubjectMax - $fixed}] QLList]
        set body_off [string length $subj]
        append subj $body
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
        return [dict create line $line spine_len [string length $spine] \
            atype_off $atype_off atype_len $atype_len \
            body_off $body_off body $body meta_off $meta_off offs $offs]
    }

    method on_child_open_at {cp lineoff} { {*}$OnOpen $cp $lineoff }

    method apply_child_tags {row_start cp info} {
        $Text tag add childbar $row_start \
            "$row_start + [dict get $info spine_len]c"
        set ao [dict get $info atype_off]
        if {$ao >= 0} {
            $Text tag add slug "$row_start + ${ao}c" \
                "$row_start + [expr {$ao + [dict get $info atype_len]}]c"
        }
        $Text tag add meta \
            "$row_start + [dict get $info meta_off]c" "$row_start lineend"
        lassign [dict getdef [dict get $info offs] actions {-1 0}] aco acl
        if {$aco >= 0 && $acl > 0} {
            $Text tag add actioncell "$row_start + ${aco}c" \
                "$row_start + [expr {$aco + $acl}]c"
        }
        lassign [dict getdef [dict get $info offs] cost {-1 0}] co cl
        if {$co >= 0 && $cl > 0} {
            set cst [my cget_field $cp cost ""]
            if {$cst ne "" && $cst >= 0.10} {
                set tag [expr {$cst >= 1.0 ? "cost-outlier" : "cost-mid"}]
                $Text tag add $tag "$row_start + ${co}c" \
                    "$row_start + [expr {$co + $cl}]c"
            }
        }
    }

    method on_child_release {cp} {
        if {![my has_child $cp]} return
        {*}$OnOpen $cp [my cget_field $cp open_lineoff 0]
    }

    # The reduced menu for a subagent child row: a subagent is not a resumable
    # session (it has no session id of its own and no project cwd of its own), so
    # the resume / move / rename / bookmark verbs do not apply; only open, copy
    # path, copy last output, and reveal remain.
    method build_child_menu {} {
        set CMenu $Top.ccmenu
        menu $CMenu -tearoff 0
        $CMenu add command -label "Open in viewer" \
            -command [list [self] child_menu_open]
        $CMenu add separator
        $CMenu add command -label "Copy session path" \
            -command [list [self] child_menu_copy_path]
        $CMenu add command -label "Copy last assistant output" \
            -command [list [self] child_menu_copy_last_assistant]
        $CMenu add separator
        $CMenu add command -label "Reveal folder" \
            -command [list [self] child_menu_reveal]
        set ChildMenuPath ""
    }

    method on_child_right {cp X Y} {
        set ChildMenuPath $cp
        tk_popup $CMenu $X $Y
    }
    method child_menu_open {} { my on_child_release $ChildMenuPath }
    method child_menu_copy_path {} { my clipboard_set $ChildMenuPath }
    method child_menu_copy_last_assistant {} {
        my clipboard_set [::questlog::jsonl::last_assistant_text $ChildMenuPath]
    }
    method child_menu_reveal {} {
        set dir [file dirname $ChildMenuPath]
        set opener [expr {$::tcl_platform(os) eq "Darwin" ? "open" : "xdg-open"}]
        if {[catch {exec $opener $dir &} err]} {
            puts stderr "questlog: $opener failed: $err"
        }
    }

    # Attach a subagent's matches to its parent session (issue #13 cases B and C).
    # Creates the parent card if the parent itself had no match (case B), seeds
    # the child models, attaches this child's hits (capped at
    # snippets_per_subagent), counts them for the parent's pip, and either
    # auto-expands (case B: no direct match) or leaves collapsed with the pip.
    method add_subagent_matches {matches} {
        set first [lindex $matches 0]
        set cp     [dict get $first path]
        set parent [dict get $first parent_path]
        set folder [dict get $first folder]
        if {![my has_session $parent]} {
            set row [{*}$LookupSession $parent]
            if {$row eq ""} { set row [dict create folder $folder] }
            my model_add_session $parent $row
        }
        my sset $parent has_subagents 1
        if {[my folder_expanded [my sget $parent folder]] \
            && ![my sflag $parent rendered]} {
            my render_session $parent
        }
        my ensure_children_enumerated $parent
        if {![my has_child $cp]} {
            my child_add_model $parent [dict create path $cp parent_path $parent \
                folder $folder agent_id [dict getdef $first agent_id ""]]
        }
        set cap [::questlog::config::get snippets_per_subagent]
        set hits [my cget_field $cp hits]
        foreach m $matches {
            my sset $parent sub_total [expr {[my sget $parent sub_total] + 1}]
            if {[llength $hits] < $cap} {
                lappend hits [list [dict get $m btype] \
                    [dict get $m content] [dict get $m lineoff]]
            }
        }
        my cset $cp hits $hits
        my attach_child $parent $cp
        # Case B (no direct hit in the parent) auto-expands so the matched
        # subagents are visible; case C keeps the parent collapsed with the pip.
        if {[my sget $parent count] == 0} {
            my node_set [my sid $parent] expanded 1
        }
        if {[my node_field [my sid $parent] expanded] \
            && [my sflag $parent rendered]} {
            my render_child $parent $cp
        }
        if {[my sflag $parent rendered]} { my redraw_header $parent }
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
        return [my meta_cells [my session_payload $path]]
    }

    # The metadata cell values for a row dict (a session or a subagent child),
    # keyed by column id, so parent and child lines pin the same columns.
    method meta_cells {s} {
        set cells [dict create]
        foreach col [::questlog::ui::session_columns] {
            lassign $col id
            switch -- $id {
                date { set v [dict getdef $s when ""] }
                size { set v [my fmt_size [dict getdef $s size 0]] }
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
        set s [my session_payload $path]
        set cells [my session_meta_cells $path]

        set running [dict exists $RunningSet [dict get $s uuid]]
        set bk [my session_bookmarked $path]
        set g [my glyph_cell $running $bk]
        set slug [dict get $s slug]
        set count [dict get $s count]
        set subt  [dict get $s sub_total]
        # Match-count tail: direct matches, plus a "+N in subagents" pip when the
        # session's subagents also matched (case C); or the case-B line when only
        # subagents matched, so the parent surfaces with no hit of its own.
        set count_str ""
        if {$count > 0} {
            set count_str "   ·   $count [expr {$count == 1 ? {match} : {matches}}]"
            if {$subt > 0} { append count_str "   ·   +$subt in subagents" }
        } elseif {$subt > 0} {
            set count_str "   ·   no match in this session · $subt in subagents below"
        }

        set subj ""
        # A session with subagents leads with an expand/collapse chevron. It is a
        # separate click target (toggle, not open), so its char range is recorded
        # in offs and tagged; glyph_off marks where the status glyphs begin so
        # tag_glyphs colours them past the chevron.
        set chev_off -1
        if {[dict get $s has_subagents]} {
            set chev_off 0
            append subj [expr {[my sflag $path expanded] ? "▾" : "▸"}]
            append subj " "
        }
        set glyph_off [string length $subj]
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
        if {$chev_off >= 0} { incr fixed [font measure QLList "▸ "] }
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
        if {$chev_off >= 0} { dict set offs chevron [list $chev_off 1] }
        foreach col [::questlog::ui::session_columns] {
            lassign $col id
            append line "\t"
            set off [string length $line]
            set val [dict get $cells $id]
            append line $val
            dict set offs $id [list $off [string length $val]]
        }
        return [dict create line $line meta_off $meta_off glyph_off $glyph_off \
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
        lassign [dict getdef [dict get $info offs] chevron {-1 0}] cho chl
        if {$cho >= 0 && $chl > 0} {
            $Text tag add chevron "$row_start + ${cho}c" \
                "$row_start + [expr {$cho + $chl}]c"
        }
        my tag_glyphs $row_start [dict getdef $info glyph_off 0]
        lassign [dict getdef [dict get $info offs] cost {-1 0}] co cl
        if {$co >= 0 && $cl > 0} {
            set c [my sget $path cost]
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
        set sid [my sid $path]
        if {![my node_field $sid rendered]} return
        set smark [my node_field $sid start]
        set stag  [my node_field $sid tag]
        set info [my build_session_line $path]
        $Text delete $smark "$smark lineend"
        $Text insert $smark [dict get $info line] \
            [list sessionhead $stag]
        my apply_line_tags $smark $path $info
        if {$Selected eq $path} {
            $Text tag add selected $smark [my node_field $sid end]
        }
    }

    # Text widget yview update: forward to the scrollbar.
    method on_yscroll {args} {
        $Top.body.sb set {*}$args
    }

    method ensure_folder {folder} {
        if {[my has_folder $folder]} return
        set label [::questlog::path::display_label [{*}$ResolveFolder $folder] $folder]
        set htag  "f#[incr NextId]"
        # Browsing opens folders collapsed (an overview of projects); a search
        # opens them expanded so the matches under each folder are visible. A
        # collapsed folder draws only its heading - its sessions live in the
        # model and are rendered lazily on expand, so there are no hidden lines.
        set expanded [expr {$CriteriaActive ? 1 : 0}]
        set fmark  "fm[incr NextId]"
        set femark "fe[incr NextId]"
        # The folder node: a root, payload {label count cost size}; its start
        # mark is the heading start (fmark), its end the folder's append point
        # (femark, where new sessions land), its tag the heading's drop hit-test.
        set fid [my node_new folder "" $folder \
            [dict create label $label count 0 cost 0.0 size 0]]
        my node_set $fid tag $htag
        my node_set $fid start $fmark
        my node_set $fid end $femark
        my node_set $fid expanded $expanded
        dict set FolderNode $folder $fid
        set fstart [$Text index TailMark]
        set info [my folder_heading_info $folder]
        $Text insert TailMark "[dict get $info line]\n" \
            [list folderhead $htag]
        my apply_folder_tags $fstart $info
        $Text mark set $fmark $fstart
        $Text mark gravity $fmark right
        $Text mark set $femark [$Text index TailMark]
        $Text mark gravity $femark left
        dict set TagNode $htag $fid
        lappend Roots $fid
        $Text tag bind $htag <Button-1> [list [self] toggle_folder $folder]
    }

    # Build a folder heading line: the marker, the (truncated) project label and
    # a bare "(N)" session count on the left, then the folder's total size and
    # cost pinned in the same columns as the rows below. The aggregates carry no
    # date cell, so a double tab opens straight into the size column. Returns the
    # line and the char ranges apply_folder_tags bolds.
    method folder_heading_info {folder} {
        set f [my folder_payload $folder]
        set marker [expr {[my node_field [my fid $folder] expanded] ? "▾" : "▸"}]
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
        if {![my has_folder $folder]} return
        set fid [my fid $folder]
        set fmark [my node_field $fid start]
        set info [my folder_heading_info $folder]
        $Text delete $fmark "$fmark lineend"
        # Temporarily set gravity to left so the insert does not push fmark
        $Text mark gravity $fmark left
        $Text insert $fmark [dict get $info line] \
            [list folderhead [my node_field $fid tag]]
        $Text mark gravity $fmark right
        my apply_folder_tags $fmark $info
    }

    method toggle_folder {folder} {
        if {![my has_folder $folder]} return
        set fid [my fid $folder]
        set exp [expr {![my node_field $fid expanded]}]
        my node_set $fid expanded $exp
        $Text configure -state normal
        if {$exp} { my expand_folder $folder } else { my collapse_folder $folder }
        my redraw_folder_heading $folder
        $Text configure -state disabled
    }

    method expand_folder {folder} {
        foreach path [my sort_paths [my folder_session_paths $folder] [my folder_session_src $folder]] {
            my render_session $path
        }
    }

    # A folder's session paths, in the order they sit under the folder node.
    method folder_session_paths {folder} {
        if {![my has_folder $folder]} { return [list] }
        set out [list]
        foreach sid [my node_field [my fid $folder] children] {
            lappend out [my node_field $sid key]
        }
        return $out
    }

    # A path->payload map over a folder's sessions, the source sort_paths reads
    # its key fields (mtime/size/cost/turns/duration_secs) from.
    method folder_session_src {folder} {
        set src [dict create]
        foreach path [my folder_session_paths $folder] {
            dict set src $path [my session_payload $path]
        }
        return $src
    }

    # Delete every rendered line of the folder's body and drop the per-session
    # render marks; the sessions remain in the model and redraw on the next
    # expand. No hidden text is left behind.
    method collapse_folder {folder} {
        set fid [my fid $folder]
        set fmark [my node_field $fid start]
        set femark [my node_field $fid end]
        set bodystart [$Text index "$fmark lineend +1c"]
        $Text delete $bodystart $femark
        $Text mark set $femark $bodystart
        foreach path [my folder_session_paths $folder] {
            if {![my has_session $path]} continue
            set sid [my sid $path]
            if {![my node_field $sid rendered]} continue
            catch {$Text mark unset [my node_field $sid start] \
                                    [my node_field $sid end]}
            # The children's render marks vanished with the body; reset their
            # flags and drop their marks so a later expand redraws them.
            foreach cp [my session_child_paths $path] {
                if {[my has_child $cp]} { my reset_child_render $cp }
            }
            my node_set $sid rendered 0
            my node_set $sid tag ""
            my node_set $sid start ""
            my node_set $sid end ""
        }
        # Drop the now-empty per-session / per-snippet / per-child tags left by
        # the delete.
        foreach tg [$Text tag names] {
            if {([string match "s#*" $tg] || [string match "n#*" $tg] \
                 || [string match "c#*" $tg]) \
                && [llength [$Text tag ranges $tg]] == 0} {
                $Text tag delete $tg
            }
        }
    }

    method bump_folder_count {folder delta} {
        if {![my has_folder $folder]} return
        my fset $folder count [expr {[my fget $folder count] + $delta}]
        my redraw_folder_heading $folder
    }

    method bump_folder_cost {folder delta} {
        if {![my has_folder $folder]} return
        my fset $folder cost [expr {[my fget $folder cost 0.0] + $delta}]
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
        if {![dict exists $PathNode $path]} return
        # A subagent's cost lands on its child row, not a session row.
        if {[my node_field [my sid $path] kind] eq "subagent"} {
            my refresh_child_cost $path $cost_dict
            return
        }
        set folder [my sget $path folder]
        set old_cost [my sget $path cost]
        if {$old_cost eq "" || $old_cost < 0} { set old_cost 0.0 }
        my sset $path own_cost [dict get $cost_dict cost_usd]
        my sset $path own_turns [dict getdef $cost_dict turns ""]
        my sset $path own_duration_secs [dict getdef $cost_dict duration_secs ""]

        my recompute_parent_totals $path

        set new_cost [my sget $path cost]
        if {$new_cost eq "" || $new_cost < 0} { set new_cost 0.0 }
        set delta [expr {$new_cost - $old_cost}]

        # bump_folder_cost mutates the heading line and redraw_header
        # mutates the session line: both go through $Text delete/insert,
        # so the widget must be in normal state for the duration.
        $Text configure -state normal
        if {$delta != 0} {
            my bump_folder_cost $folder $delta
            set TotalCost [expr {$TotalCost + $delta}]
            my refresh_status
        }
        if {[my sflag $path rendered]} { my redraw_header $path }
        $Text configure -state disabled
        # The worker result can change cost-, turns- or duration-sorted order.
        if {$SortKey in {cost turns duration}} { my schedule_resort }
    }

    # A subagent's cost/turns/duration arriving from the second pass. Stored on
    # the child and shown on its own row, but also folded up to the parent
    # session level. Redraws the parent's children block and updates the parent
    # row.
    method refresh_child_cost {cp cost_dict} {
        if {![my has_child $cp]} return
        my cset $cp cost [dict get $cost_dict cost_usd]
        my cset $cp turns [dict getdef $cost_dict turns ""]
        my cset $cp duration_secs [dict getdef $cost_dict duration_secs ""]
        set parent [my cget_field $cp parent_path]
        if {[my has_session $parent]} {
            set folder [my sget $parent folder]
            set old_cost [my sget $parent cost]
            if {$old_cost eq "" || $old_cost < 0} { set old_cost 0.0 }

            my recompute_parent_totals $parent

            set new_cost [my sget $parent cost]
            if {$new_cost eq "" || $new_cost < 0} { set new_cost 0.0 }
            set delta [expr {$new_cost - $old_cost}]

            $Text configure -state normal
            if {$delta != 0} {
                my bump_folder_cost $folder $delta
                set TotalCost [expr {$TotalCost + $delta}]
                my refresh_status
            }
            if {[my sflag $parent rendered]} {
                my redraw_header $parent
            }
            if {[my node_field [my sid $cp] rendered]} {
                my rerender_children $parent
            }
            $Text configure -state disabled
            # The worker result can change cost-, turns- or duration-sorted order.
            if {$SortKey in {cost turns duration}} { my schedule_resort }
        }
    }

    # Recomputes the parent session's aggregated totals from its own raw values
    # plus the computed metrics of all its subagents.
    method recompute_parent_totals {path} {
        if {![my has_session $path]} return
        set s [my session_payload $path]

        set has_any_cost 0
        set has_any_turns 0
        set has_any_duration 0

        # Sum cost
        set own_cost [dict getdef $s own_cost ""]
        if {$own_cost ne "" && $own_cost >= 0} {
            set sum_cost $own_cost
            set has_any_cost 1
        } else {
            set sum_cost 0.0
        }

        # Sum turns
        set own_turns [dict getdef $s own_turns ""]
        if {$own_turns ne "" && $own_turns >= 0} {
            set sum_turns $own_turns
            set has_any_turns 1
        } else {
            set sum_turns 0
        }

        # Sum duration
        set own_duration [dict getdef $s own_duration_secs ""]
        if {$own_duration ne "" && $own_duration >= 0} {
            set sum_duration $own_duration
            set has_any_duration 1
        } else {
            set sum_duration 0
        }

        foreach cp [dict get $s all_child_paths] {
            if {[my has_child $cp]} {
                set c [my node_payload [my sid $cp]]
                set cc [dict getdef $c cost ""]
                if {$cc ne "" && $cc >= 0} {
                    set sum_cost [expr {$sum_cost + $cc}]
                    set has_any_cost 1
                }
                set ct [dict getdef $c turns ""]
                if {$ct ne "" && $ct >= 0} {
                    set sum_turns [expr {$sum_turns + $ct}]
                    set has_any_turns 1
                }
                set cd [dict getdef $c duration_secs ""]
                if {$cd ne "" && $cd >= 0} {
                    set sum_duration [expr {$sum_duration + $cd}]
                    set has_any_duration 1
                }
            }
        }

        my sset $path cost [expr {$has_any_cost ? $sum_cost : ""}]
        my sset $path turns [expr {$has_any_turns ? $sum_turns : ""}]
        my sset $path duration_secs [expr {$has_any_duration ? $sum_duration : ""}]
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
        if {$Selected ne "" && [my has_session $Selected] \
            && [my sflag $Selected rendered]} {
            set osid [my sid $Selected]
            catch {$Text tag remove selected [my node_field $osid start] \
                                             [my node_field $osid end]}
        }
        set Selected $path
        if {[my has_session $path] && [my sflag $path rendered]} {
            set sid [my sid $path]
            $Text tag add selected [my node_field $sid start] [my node_field $sid end]
        }
        # The selected row shows its ⋯ bright; the row losing selection re-fades.
        if {$prev ne "" && $prev ne $path} { my action_set_bright $prev 0 }
        my action_set_bright $path 1
    }

    method open_session {path {lineno -1}} {
        if {$lineno < 0} {
            set lineno 0
            if {[my has_session $path]} {
                set lineno [my sget $path first_lineno]
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
        # A release on the chevron expands or collapses the session's subagents.
        if {[my click_on_chevron $X $Y]} {
            my toggle_subagents $path
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
        # A press on the ⋯ control or the chevron is a control click, not a drag.
        if {[my click_on_action $X $Y]} return
        if {[my click_on_chevron $X $Y]} return
        ::questlog::ui::drag::watch $Text $X $Y [list $path] \
            [list [self] handle_drop] \
            [list [self] drag_hit] [list [self] drag_paint]
    }

    # ---- the ⋯ actions control --------------------------------------

    # The actions cell's text range for a rendered row, or {} when absent.
    method action_range {path} {
        if {![my has_session $path]} { return {} }
        set sid [my sid $path]
        if {![my node_field $sid rendered]} { return {} }
        return [$Text tag nextrange actioncell \
                    [my node_field $sid start] [my node_field $sid end]]
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

    # Whether a root-coordinate click landed on a session's expand chevron.
    method click_on_chevron {X Y} {
        set lx [expr {$X - [winfo rootx $Text]}]
        set ly [expr {$Y - [winfo rooty $Text]}]
        set idx [$Text index @$lx,$ly]
        return [expr {[lsearch -exact [$Text tag names $idx] chevron] >= 0}]
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
            if {[dict exists $TagNode $t]} {
                return [my node_field [dict get $TagNode $t] key]
            }
        }
        return ""
    }

    method drag_paint {old new} {
        if {$old ne "" && [my has_folder $old]} {
            set fm [my node_field [my fid $old] start]
            catch {$Text tag remove drop-candidate $fm "$fm lineend"}
        }
        if {$new ne "" && [my has_folder $new]} {
            set fm [my node_field [my fid $new] start]
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
        if {$folder eq "" && [my has_session $path]} {
            set folder [my sget $path folder]
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
        my clipboard_set [::questlog::ui::terminal::resume_command \
            [my menu_target_get cwd] [my menu_target_get uuid]]
    }
    method menu_copy_uuid {} { my clipboard_set [my menu_target_get uuid] }
    method menu_copy_path {} { my clipboard_set $MenuPath }
    method menu_copy_last_assistant {} {
        my clipboard_set [::questlog::jsonl::last_assistant_text [my menu_target_get path]]
    }
    # The whole session as Markdown on the clipboard: the text-only transcript
    # (USER/ASSISTANT/SYSTEM turns, segmented at compaction boundaries and idle
    # gaps the way the viewer breaks it). Tool calls are out of scope by design.
    method menu_copy_markdown {} {
        my clipboard_set \
            [::questlog::ui::markdown::export_session [my menu_target_get path]]
    }
    # The same Markdown to a file the reader picks. A cancelled dialog returns
    # empty and does nothing; a write failure is surfaced rather than swallowed.
    method menu_export_markdown {} {
        set path [my menu_target_get path]
        set initial "[file rootname [file tail $path]].md"
        set dest [tk_getSaveFile -parent $Top -title "Export session to Markdown" \
            -defaultextension .md -initialfile $initial \
            -filetypes {{Markdown {.md}} {{All files} *}}]
        if {$dest eq ""} return
        set md [::questlog::ui::markdown::export_session $path]
        if {[catch {
            set fh [open $dest w]
            chan configure $fh -encoding utf-8
            puts -nonewline $fh $md
            close $fh
        } err]} {
            tk_messageBox -parent $Top -icon error -title "Export session" \
                -message "Could not write $dest" -detail $err
        }
    }
    method menu_resume {fork} {
        ::questlog::ui::terminal::launch_tab [my menu_target_get cwd] \
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
        if {![my has_session $MenuPath]} return
        set uuid [my sget $MenuPath uuid]
        set current [my sget $MenuPath slug]
        set aitt [my sget $MenuPath ai_title ""]
        set entered [my prompt_rename $current]
        if {$entered eq "<cancelled>"} return
        if {$entered eq ""} {
            ::questlog::ui::title_writer::clear_custom $MenuPath $uuid $aitt
            my sset $MenuPath slug $aitt
        } else {
            ::questlog::ui::title_writer::set_custom $MenuPath $uuid $entered
            my sset $MenuPath slug $entered
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
        set before [my session_count]

        $Text configure -state normal
        my anchor_save
        if {$running_only || !$CriteriaActive} {
            dict for {uuid path} $running {
                if {[my has_session $path]} continue
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
                if {[my has_session $path]} continue
                my model_add_session $path $row
                if {[my folder_expanded [dict get $row folder]]} {
                    my render_session $path
                }
            }
        }
        foreach path [my all_session_paths] {
            if {![my has_session $path]} continue
            set uuid [my sget $path uuid]
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
        if {[my session_count] != $before} { my schedule_resort }
    }

    # The number of session nodes in the model (subagents excluded), so a
    # reconcile pass can tell whether the displayed session set changed.
    method session_count {} {
        set n 0
        foreach fid $Roots { incr n [llength [my node_field $fid children]] }
        return $n
    }

    method reconcile_one {path} {
        if {![my has_session $path]} return
        $Text configure -state normal
        my redraw_header $path
        $Text configure -state disabled
    }

    method all_session_paths {} {
        set out [list]
        foreach fid $Roots {
            foreach sid [my node_field $fid children] {
                lappend out [my node_field $sid key]
            }
        }
        return $out
    }

    # ---- removal / relocation ----------------------------------------

    method forget_session {path} {
        if {![my has_session $path]} return
        set sid [my sid $path]
        set fid [my node_field $sid parent]
        set folder [my node_field $fid key]
        if {[my node_field $sid rendered]} {
            $Text delete [my node_field $sid start] [my node_field $sid end]
            catch {$Text mark unset [my node_field $sid start] \
                                    [my node_field $sid end]}
        }
        # Subtract this session's cost and size from the folder aggregates and
        # the running total before the node vanishes, so a later sum over
        # remaining sessions stays exact.
        set cost [my sget $path cost]
        set size [my sget $path size 0]
        if {$cost ne "" && $cost > 0} {
            my bump_folder_cost $folder [expr {-$cost}]
            set TotalCost [expr {$TotalCost - $cost}]
            my refresh_status
        }
        # Drop the session node and any subagent nodes parented to it.
        foreach cid [my node_field $sid children] {
            set cp [my node_field $cid key]
            dict unset PathNode $cp
            dict unset Nodes $cid
        }
        foreach cp [my node_pget $sid all_child_paths] {
            if {[dict exists $PathNode $cp]} {
                dict unset Nodes [dict get $PathNode $cp]
                dict unset PathNode $cp
            }
        }
        dict unset Nodes $sid
        dict unset PathNode $path
        my node_set $fid children \
            [lsearch -all -inline -not -exact [my node_field $fid children] $sid]
        if {$Selected eq $path} { set Selected "" }
        if {[llength [my node_field $fid children]] == 0} {
            my forget_folder $folder
        } else {
            my fset $folder size [expr {[my fget $folder size 0] - $size}]
            my bump_folder_count $folder -1
        }
    }

    method forget_folder {folder} {
        if {![my has_folder $folder]} return
        set fid [my fid $folder]
        set fmark [my node_field $fid start]
        set femark [my node_field $fid end]
        $Text delete $fmark $femark
        catch {$Text mark unset $fmark $femark}
        dict unset TagNode [my node_field $fid tag]
        dict unset FolderNode $folder
        dict unset Nodes $fid
        set Roots [lsearch -all -inline -not -exact $Roots $fid]
    }

    # After a move renames the file, re-key the model and rebuild the view
    # so the session appears under its new folder. A full rebuild keeps the
    # mark scheme consistent; moves are rare, so the cost is not on a hot path.
    method relocate_card {old_path new_path new_folder} {
        if {![my has_session $old_path]} return
        set sid [my sid $old_path]
        my node_pset $sid folder $new_folder
        my node_set $sid key $new_path
        dict unset PathNode $old_path
        dict set PathNode $new_path $sid
        set old_fid [my node_field $sid parent]
        my node_set $old_fid children \
            [lsearch -all -inline -not -exact [my node_field $old_fid children] $sid]
        # Add the destination folder structurally (no drawing) when new; the
        # redraw_all below rebuilds the model from the node store and draws it.
        if {![my has_folder $new_folder]} {
            set new_fid [my node_new folder "" $new_folder \
                [dict create label "" count 0 cost 0.0 size 0]]
            my node_set $new_fid expanded [expr {$CriteriaActive ? 1 : 0}]
            dict set FolderNode $new_folder $new_fid
            lappend Roots $new_fid
        }
        set new_fid [my fid $new_folder]
        my node_set $sid parent $new_fid
        my node_set $new_fid children [linsert [my node_field $new_fid children] end $sid]
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
        # Snapshot the model from the node store, remember each folder's
        # expanded state, then reset the store and rebuild it, re-rendering only
        # the expanded folders' bodies.
        set order [list]                 ;# folder names in arrival order
        set byfolder [dict create]       ;# folder name -> ordered session paths
        set saved [dict create]          ;# session path -> payload snapshot
        set wasexp [dict create]
        set foldercost [dict create]
        foreach fid $Roots {
            set folder [my node_field $fid key]
            lappend order $folder
            dict set wasexp $folder [my node_field $fid expanded]
            dict set foldercost $folder [my node_pget $fid cost 0.0]
            set paths [list]
            foreach sid [my node_field $fid children] {
                set path [my node_field $sid key]
                lappend paths $path
                dict set saved $path [my node_payload $sid]
            }
            dict set byfolder $folder $paths
        }
        # Sorting by cost reorders the folders by their aggregate too; the other
        # keys keep the folders in arrival order.
        if {$SortKey eq "cost"} { set order [my sort_folders $order $foldercost] }
        my reset_model
        # Folder costs were dropped with the model; reset TotalCost too so the
        # bumps in model_add_session re-establish both consistently.
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
                my sset $path label [dict get $s label]
                my sset $path when [dict get $s when]
                my sset $path snippets [dict get $s snippets]
                my sset $path count [dict get $s count]
            }
            if {[dict exists $wasexp $folder] && [my has_folder $folder]} {
                my node_set [my fid $folder] expanded [dict get $wasexp $folder]
            }
        }
        foreach fid $Roots {
            set folder [my node_field $fid key]
            if {[my node_field $fid expanded]} {
                foreach path [my folder_session_paths $folder] {
                    my render_session $path
                }
            }
            my redraw_folder_heading $folder
        }
        if {$Selected ne "" && [my has_session $Selected] \
            && [my sflag $Selected rendered]} {
            set sm [my node_field [my sid $Selected] start]
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
