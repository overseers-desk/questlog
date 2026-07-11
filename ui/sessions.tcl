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
# fixed strip flush to the right edge, in this left-to-right order. Turns,
# Duration and Model are filled by the cost second pass (the forward scan stops
# at the second user record and computes none of them); Model is the session's
# last non-sidechain assistant model and is not sortable (the per-session sort
# keys are numeric, and a model name has none). The actions column carries the
# row's "⋯" overflow control and is not sortable.
proc ::questlog::ui::session_columns {} {
    return {
        {date     Date     {Wed 30 May 12:30} right 1}
        {size     Size     {999.9 M}          right 1}
        {cost     Cost     {$9999.99}         right 1}
        {turns    Turns    {9999}             right 1}
        {duration Duration {0:00:00}          right 1}
        {ratio    H%       {100%}             right 1}
        {model    Model    {Sonnet 4.6}       right 0}
        {actions  {}       {⋯}                right 0}
    }
}

# ::questlog::ui::SessionList - the left pane: one read-only text widget that is
# both the session browser and the search-result index in a single list. It is
# a StreamTree (the generic tree-in-a-text-widget engine) specialised for the
# session domain: folders are the roots, sessions are their children, and a
# session's subagents are its grandchildren. SessionList supplies the content
# and ordering through the engine's hooks (column_spec, render_subject,
# cell_values, cell_tag, sort_key) and owns the session-specific interaction,
# cost aggregation, menus, rename, search snippets, and reconcile.
#
# Layout, top to bottom, as tagged regions in the one text widget:
#   folder heading   - the project label, a drop target for moves
#   session header   - glyphs, label, time, and (when searching) a match count
#   snippet rows     - up to three per session: a block-type label and a
#                      hit-leading snippet with the matched term in bold
#
# Two display states share the widget. With no criteria it browses: every
# session that passes the snapshot filter appears as a header, grouped by
# folder. With criteria it indexes: only matching sessions appear, each with
# its snippets. A single click opens the session in the docked viewer and
# anchors it to the relevant line.
#
# The engine draws each node into the widget with two marks (node.start at its
# first char, node.end at the append point past its last descendant) and a
# per-node tag. A folder's start is the heading start (right gravity). A
# session's start is its header start with right gravity: a session rendered
# while a sibling above it is collapsed begins exactly where that sibling's end
# mark sits, and right gravity makes the start follow its own header down when
# the sibling later expands and inserts child rows at that point, rather than
# being stranded among them. A subagent's start is left gravity. A node's end
# is the folder's append point (where new sessions land) or the session's
# (where snippets and child rows land). A session's subagents render as its
# child nodes at the session's end region, exactly as snippet rows render
# between a header and its append point.

oo::class create ::questlog::ui::SessionList {
    superclass ::streamtree::StreamTree
    # The list arms one deferred call of its own (the debounced view rebuild), and
    # a raw [after] naming this object would fire into its remains after a destroy:
    # leash's `later` ties the arm to the object's life (leash-1.0.tm).
    mixin leash
    # Shared with the StreamTree engine (same per-object variables): the widget
    # refs, the node store, the column geometry and the sort state.
    variable Top
    variable Text
    variable Nodes
    variable Roots
    variable NextId
    variable ColTabs
    variable ColRightX
    variable ColW
    variable ColGap
    variable SubjectMax
    variable FolderLabelMax
    variable LayoutW
    variable RelayoutPending
    variable SortKey
    variable SortDir
    variable ResortTimer
    variable StatusVar
    variable CancelCb
    variable ResolveFolder    ;# cb: folder -> display cwd; opens no transcript
    variable LookupSession    ;# cb: path -> row dict
    variable OnOpen           ;# cb: path lineno -> open + anchor in viewer
    variable OnMoveRequest    ;# cb: paths -> open move picker
    variable OnDropMove       ;# cb: paths folder -> direct move
    variable OnBookmarkToggle ;# cb: path -> flip the +x bookmark bit
    variable OnBookmarkSet    ;# cb: paths -> flip the +x bit across a selection
    variable OnRename         ;# cb: path -> app rename router (dialog + apply + refresh)
    variable OnScanPath       ;# cb: path -> row (synchronous single-file scan)
    variable OnWiden          ;# cb: criterion -> relax it in the toolbar and republish
    variable Snapshot
    variable CriteriaActive
    variable RunningSet       ;# dict uuid -> 1, replaced wholesale each tick
    variable PrevRunning      ;# the prior tick's running set, to redraw only the rows that flipped
    variable LensMembers      ;# dict uuid -> {path ?cwd?}: the active lens's whole membership
    variable LensNote         ;# the strip's lens clause, "" when no lens or no membership
    variable CutMembers       ;# the members with no loaded row, as {path ?cwd? resolved} dicts
    variable CutReason        ;# the criterion that cut them: subtree|search|since|min_turns|""
    variable Pinned           ;# dict path -> 1: sessions the reader pulled in past the search
    variable ViewRebuildTimer ;# after-id of the debounced hidden-aware rebuild, or ""
    variable Query            ;# {terms <list> nocase 0|1} for hit highlighting
    variable HitTags
    # Domain indices into the node store: a folder name or a session/subagent
    # path to its node id.
    variable FolderNode       ;# folder name -> node id
    variable PathNode         ;# session path OR subagent path -> node id
    variable TagNode          ;# folder node.tag -> node id, for drop hit-testing
    variable SelectedSet      ;# ordered set (dict path->1) of selected sessions
    variable SelectAnchor     ;# path a Shift-range extends from, or ""
    variable Menu
    variable MenuPath
    variable MenuTarget
    variable CMenu            ;# the reduced right-click menu for subagent child rows
    variable ChildMenuPath    ;# child path the child menu acts on
    variable MenuIndices      ;# entry indices returned by session_actions::populate
    variable TotalCost        ;# running sum of per-session cost in the model
    variable StatusBase       ;# last text set by set_progress/set_done
    variable OnSubagents      ;# cb: parent path -> list of child row dicts
    variable OnSubagentCost   ;# cb: child path -> start the cost pass for it

    # on_widen is optional: without it the cut banner still names what the search
    # left behind and still offers to load it (that is this object's own doing),
    # and only the widen escape - which relaxes a toolbar criterion, and so needs
    # the toolbar - is absent.
    constructor {parent resolve_cb lookup_cb on_open on_move_request \
                 on_drop_move on_bookmark_toggle on_bookmark_set on_rename \
                 on_scan_path cancel_cb \
                 on_subagents on_subagent_cost {on_widen ""}} {
        set Top $parent
        set ResolveFolder $resolve_cb
        set LookupSession $lookup_cb
        set OnOpen $on_open
        set OnMoveRequest $on_move_request
        set OnDropMove $on_drop_move
        set OnBookmarkToggle $on_bookmark_toggle
        set OnBookmarkSet $on_bookmark_set
        set OnRename $on_rename
        set OnScanPath $on_scan_path
        set CancelCb $cancel_cb
        set OnSubagents $on_subagents
        set OnSubagentCost $on_subagent_cost
        set OnWiden $on_widen
        set StatusVar "Idle"
        set StatusBase ""
        set TotalCost 0.0
        set Snapshot [dict create]
        set CriteriaActive 0
        set RunningSet [dict create]
        set PrevRunning [dict create]
        set LensMembers [dict create]
        set LensNote ""
        set CutMembers [list]
        set CutReason ""
        set Pinned [dict create]
        set ViewRebuildTimer ""
        set Query [dict create terms [list] nocase 0]
        set SelectedSet [dict create]
        set SelectAnchor ""
        set NextId 0
        # Default sort reproduces the streaming order (mtime descending), so a
        # fresh list looks exactly as before any header is clicked.
        set SortKey "date"
        set SortDir "desc"
        set ResortTimer ""
        set LayoutW 0
        set RelayoutPending 0
        # Bind the engine to this app's look and host services: the list and
        # heading fonts, the theme colours its header strip uses, the streamed-
        # resort debounce from config, and the drag-to-move motion handler. These
        # are the only app-specific values the otherwise self-contained StreamTree
        # engine needs; it carries no reference to them itself.
        my configure -listfont QLList -headfont QLBold \
            -colours [dict create \
                strip [::questlog::ui::theme::c strip] \
                muted [::questlog::ui::theme::c muted] \
                ink   [::questlog::ui::theme::c ink]] \
            -resortdelay [::questlog::config::get resort_debounce_ms] \
            -motioncb {::questlog::ui::drag::motion %X %Y}
        my reset_nodes
        my build
    }

    # The session-domain indices are reverse-lookups into the engine's node
    # store, so they must be dropped exactly when the store is wiped. Bulk
    # store resets (init, and the buffer reset behind clear) do not fire the
    # per-node on_before_delete hook, so extend the store-wipe primitive itself
    # rather than each caller. The store, id allocation and payload accessors
    # live in the StreamTree base.
    method reset_nodes {} {
        next
        set FolderNode [dict create]
        set PathNode [dict create]
        set TagNode [dict create]
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

    # ---- engine lifecycle hooks --------------------------------------
    #
    # The StreamTree primitives own the marks; these hooks carry the session
    # domain's per-kind behaviour. start_gravity and row_tags fix a row's mark
    # gravity and style tag by kind; on_row_rendered wires a freshly-laid row's
    # bindings (and, as later phases land, its nested content and selection);
    # on_before_delete drops a node's domain indices before it leaves the store.

    method start_gravity {kind} { return [expr {$kind eq "subagent" ? "left" : "right"}] }
    method row_tags {kind} {
        return [dict get {folder folderhead session sessionhead subagent childhead} $kind]
    }
    method on_node_created {id} {
        switch [my node_field $id kind] {
            folder { dict set FolderNode [my node_field $id key] $id }
        }
    }
    method on_row_rendered {id} {
        switch [my node_field $id kind] {
            folder {
                set htag [my node_field $id tag]
                set folder [my node_field $id key]
                dict set TagNode $htag $id
                $Text tag bind $htag <Button-1> [list [self] toggle_folder $folder]
            }
            session { my wire_session_row $id }
            subagent { my wire_subagent_row $id }
        }
    }
    method on_before_delete {id} {
        switch [my node_field $id kind] {
            folder {
                set tag [my node_field $id tag]
                if {$tag ne ""} { dict unset TagNode $tag }
                dict unset FolderNode [my node_field $id key]
            }
            session { my forget_session_domain $id }
            subagent { dict unset PathNode [my node_field $id key] }
        }
    }

    method build {} {
        ttk::frame $Top

        ttk::frame $Top.bar
        pack $Top.bar -side top -fill x
        ttk::label $Top.bar.status -textvariable [my varname StatusVar]
        pack $Top.bar.status -side left -padx 4 -pady 2
        ttk::button $Top.bar.cancel -text "Cancel" -command [list [self] cancel]
        pack $Top.bar.cancel -side right -padx 4 -pady 2

        my build_cut_banner

        # The list strip: it sits between the status bar and the body's
        # column-header strip, taking that strip's #ececec colour so it reads as
        # the top of the list. Packed before build_body so it lands above the
        # header band. It carries the expand-all button, which acts on the list
        # rather than filtering it; the lenses that do filter (running,
        # bookmarked, model) are the toolbar's View row.
        ttk::frame $Top.lvt -style LVStrip.TFrame -padding {8 4}
        pack $Top.lvt -side top -fill x
        ttk::button $Top.lvt.expandall -text "expand all" -style LV.TButton \
            -takefocus 0 -command [list [self] expand_all_folders]
        pack $Top.lvt.expandall -side left

        # The engine assembles the body (header text, list text, scrollbar, the
        # <Configure> relayout hook, the selection suppression and TailMark);
        # the session-domain tags, sort header and menus go on top of it.
        my build_body
        my configure_tags
        my build_header
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
        # A `names` snippet is a title breadcrumb, not a transcript block: when the
        # matched name is superseded the row ends with an arrow to the name shown
        # now, muted so the matched (highlighted) former name stays the focus.
        $Text tag configure namearrow -foreground [::questlog::ui::theme::c muted]
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

    # ---- engine hooks: columns and relayout ---------------------------

    # The metadata columns (engine hook): id, label, width sample, alignment,
    # and whether the header sorts. The single home is session_columns.
    method column_spec {} { return [::questlog::ui::session_columns] }

    # The header label over the subject column (engine hook).
    method subject_label {} { return "Session" }

    # Pin the engine's freshly-computed tab stops onto the three session-domain
    # row tags, so folder headings, session headers and child rows all align
    # their metadata under the header (engine hook, called from layout_columns).
    method apply_column_tabs {tabs} {
        # Session rows get a leading left tab stop for the title so every slug
        # aligns past the marker gutter (the chevron and status glyphs); folder
        # and child rows keep the plain metadata tabs. This reuses the same
        # column-tab mechanism the right-pinned metadata already rides on.
        #
        # The stops arrive already sane (positive, strictly increasing) from
        # layout_columns. Add the leading title stop only when it fits inside the
        # first metadata stop; in a degenerate narrow layout it does not fit and
        # the slug just tabs to the first column (a build-time state, replaced
        # once the window maps).
        set first [lindex $tabs 0]
        set title_x [expr {12 + [my title_gutter_w]}]
        if {$first ne "" && $title_x < $first} {
            $Text tag configure sessionhead -tabs [list $title_x left {*}$tabs]
        } else {
            $Text tag configure sessionhead -tabs $tabs
        }
        $Text tag configure folderhead -tabs $tabs
        $Text tag configure childhead  -tabs $tabs
    }

    # The fixed left gutter on a session row, measured past sessionhead's
    # lmargin1 (12): the widest marker cluster (chevron, running circle, bookmark
    # star) plus a small gap, so a fully-marked gutter never reaches the title
    # stop. session_subject budgets the preview past this same width.
    method title_gutter_w {} {
        return [expr {[font measure QLList \
            "▾ $::questlog::ui::GLYPH_RUNNING$::questlog::ui::GLYPH_BOOKMARK"] + 8}]
    }

    # Re-fit every rendered row's ellipsis after a width change (engine hook,
    # called from relayout inside the widget's normal state): each folder
    # heading, each rendered session header, and the children of an expanded
    # session.
    method relayout_content {} {
        foreach fid [my roots] {
            my redraw_folder_heading [my node_field $fid key]
            foreach sid [my node_field $fid children] {
                if {[my node_field $sid rendered]} {
                    set path [my node_field $sid key]
                    my redraw_header $path
                    if {[my node_field $sid expanded]} { my rerender_children $path }
                }
            }
        }
    }

    # The entries are filled per-popup by session_actions::populate (shared with
    # the viewer's ⋯ menu); here we only create the empty widget.
    method build_menu {} {
        set Menu $Top.cmenu
        menu $Menu -tearoff 0
        set MenuIndices [dict create]
        set MenuTarget [dict create]
        set MenuPath ""
    }

    # ---- filter / clear ----------------------------------------------

    method clear {} {
        # The reset primitive wipes the buffer, drops every node's marks and the
        # store; the loose snippet/match tags it leaves empty are swept after.
        my reset
        my sweep_loose_tags
        # A fresh filter/search is a new view; drop the selection (the node store
        # is empty now, and a later rebuild repaints from it).
        set SelectedSet [dict create]
        set SelectAnchor ""
        set TotalCost 0.0
        set StatusBase ""
        # The pinned sessions were pulled in past the old search; the new one has
        # its own answer. The lens membership survives (it is gathered outside the
        # search), but its cut cannot be recounted against a list that has not
        # been filled yet - the reconcile that follows the fill recounts it, so the
        # banner never flashes a cut that the new search does load.
        set Pinned [dict create]
        my drop_lens_note
        my refresh_status
    }

    method apply_filter {snapshot} {
        set Snapshot $snapshot
        set CriteriaActive [::questlog::ui::any_criteria $snapshot]
        my clear
    }

    # A list-view-toggle-only snapshot change: the search and scope are unchanged, so the
    # result set is unchanged; only which in-model sessions are shown changes. Re-derive
    # the visible set in place (no clear, no re-scan, no re-search), preserving selection
    # and scroll, by recomputing each row's hidden flag and re-rendering the affected
    # folders - which reconcile_running already does.
    method apply_listview {snapshot} {
        set Snapshot $snapshot
        set CriteriaActive [::questlog::ui::any_criteria $snapshot]
        # reconcile_running re-derives the shown set from the loaded rows alone and
        # ends by recounting the lens against its membership, so the new lens says
        # what it shows and what it is missing in the same turn, with no disk read.
        my reconcile_running $RunningSet
    }

    # The models the loaded rows carry: every distinct, non-empty model label in
    # the list, hidden rows included, sorted so the lens does not reorder itself
    # with the scan. Hidden rows count because a row the model lens is hiding is
    # exactly the row whose entry must stay in the menu for the lens to be widened
    # back off it. A row whose cost pass has not landed yet has no label and is
    # simply not named; row_visible keeps such a row visible under any lens, so it
    # never disappears for want of an entry.
    method loaded_models {} {
        set seen [dict create]
        foreach path [my all_session_paths] {
            set model [my sget $path model]
            if {$model ne ""} { dict set seen $model 1 }
        }
        return [lsort [dict keys $seen]]
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

    # 1 iff a session is shown under the current snapshot: the view toggles
    # decide (row_visible), with the running set passed through so
    # running_only can keep live rows - never as a bypass around
    # bookmarked_only, whose label promises bookmarks and nothing else. row
    # may be "" (no cached row yet) -> treat as shown until the scan catches
    # up.
    method session_shown {path row} {
        if {$row eq ""} { return 1 }
        return [::questlog::sessionlist::row_visible $Snapshot $row $RunningSet]
    }

    # ---- streaming inserts -------------------------------------------

    # Browse-mode row from Scan. Skipped when criteria are active (the result
    # index is built from matches, not the scan stream). The view toggles do
    # not gate the stream: every in-scope row enters the model with its
    # hidden flag from session_shown, so a toggle only chooses what paints.
    method on_scan_row {row} {
        if {$CriteriaActive} return
        if {![my row_matches_snapshot $row]} return   ;# scope = model membership
        set path [dict get $row path]
        if {[dict exists $PathNode $path]} return
        $Text configure -state normal
        my anchor_save
        my model_add_session $path $row
        # The model holds every in-scope session; the toggles decide only whether it is
        # drawn (model_add_session flagged it), so a later toggle hides/shows it in
        # place without a re-scan.
        if {[my sflag $path hidden]} {
            # It landed hidden under a lens, so its folder may now be a heading
            # over nothing; the debounced rebuild settles that.
            my schedule_view_rebuild
        } elseif {[my folder_expanded [dict get $row folder]]} {
            my render_session $path
        }
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
            # A streamed result obeys the view toggles from its first paint (the
            # hidden flag is settled inside model_add_session) - not two seconds
            # later when the running-reconcile tick recomputes visibility.
            my model_add_session $path $row [dict get $first lineoff]
        }
        # Search folders are expanded, so render the session if it is visible
        # and not yet drawn. A result a lens hides leaves its folder a heading
        # over nothing until the debounced rebuild re-derives the view.
        if {[my sflag $path hidden]} {
            my schedule_view_rebuild
        } elseif {[my folder_expanded [my sget $path folder]] \
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
        set hsecs [dict getdef $row human_secs ""]
        set model [dict getdef $row model ""]
        # The session node: payload carries the per-session domain dict; the
        # node's expanded/rendered flags, start/end marks, tag and children
        # (the attached subagent nodes) live alongside it in the store.
        set fid [my fid $folder]
        set sid [my node_new session $fid $path [dict create \
            folder $folder label $label slug $slug ai_title $aitt \
            when $when mtime $mtime size $size uuid $uuid cost $cost \
            turns $turns duration_secs $dsecs human_secs $hsecs model $model \
            own_cost $cost own_turns $turns own_duration_secs $dsecs \
            own_human_secs $hsecs own_model $model \
            count 0 first_lineno $first_lineno snippets [list] \
            has_subagents [dict getdef $row has_subagents 0] \
            sub_total 0 children_listed 0 all_child_paths [list]]]
        dict set PathNode $path $sid
        my node_set $fid children [linsert [my node_field $fid children] end $sid]
        # Whether the lenses admit this row is settled here, before the folder
        # heading below is redrawn from it: a row added hidden and flagged after
        # the fact is counted into a heading that then shows nothing under it, and
        # the heading reads "(1)" over an empty folder. The model holds every
        # in-scope session either way; the flag only decides what paints.
        my node_set $sid hidden [expr {![my session_shown $path $row]}]

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
        my check_invariant model_add_session
    }

    # Draw a session that the model already knows, inserting its header (and
    # any stored snippets) at the folder's append point. Idempotent.
    method render_session {path} {
        set sid [my sid $path]
        if {[my node_field $sid rendered]} return
        # The render_row primitive lays the header at the folder's append point,
        # owns the start/end marks (start right gravity per start_gravity, so the
        # mark follows its own header down when a sibling above expands) and
        # advances the folder end. on_row_rendered then wires this row's
        # bindings, stored snippets, subagents and selection.
        my render_row $sid
    }

    # The bindings, nested content and selection a freshly-laid session row
    # carries, run by render_row's on_row_rendered tail.
    method wire_session_row {id} {
        set path [my node_field $id key]
        set stag [my node_field $id tag]
        set sm   [my node_field $id start]
        # Single-line rows: the subject preview is ellipsised to stop before the
        # right-pinned metadata (render_subject), and -wrap none guards against
        # any residual overflow. The full prompt is read in the viewer, which a
        # click on the row opens.
        $Text tag configure $stag -wrap none
        $Text tag bind $stag <ButtonPress-1> \
            [list [self] on_session_press $path %X %Y]
        $Text tag bind $stag <ButtonRelease-1> \
            [list [self] on_session_release $path %X %Y]
        # Shift/Control extend the selection. The modifier press is a no-op that
        # only outranks the plain <ButtonPress-1> above, so a modified click arms
        # no drag; the gesture resolves on the modified release.
        $Text tag bind $stag <Shift-ButtonPress-1>   [list [self] on_modified_press]
        $Text tag bind $stag <Control-ButtonPress-1> [list [self] on_modified_press]
        $Text tag bind $stag <Shift-ButtonRelease-1> \
            [list [self] on_session_shift_release $path %X %Y]
        $Text tag bind $stag <Control-ButtonRelease-1> \
            [list [self] on_session_ctrl_release $path %X %Y]
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
        if {[my node_field $id expanded]} { my render_children $path }
        if {[my is_selected $path]} {
            $Text tag add selected $sm "$sm lineend"
        }
    }

    method render_snippet {path btype content lineoff} {
        # A name hit is a title the session has worn, not a block of transcript,
        # so it renders as a breadcrumb rather than a type badge.
        if {$btype eq "names"} {
            my render_name_snippet $path $content $lineoff
            return
        }
        set sid [my sid $path]
        set ntag "n#[incr NextId]"
        # Normalise to a type with a known badge pill; an unknown block type
        # falls back to the neutral system pill.
        set fgrole [dict getdef {
            user user assistant assistant tool_use tool
            tool_result tool_result system system
        } $btype system]
        set bt [expr {$fgrole eq "system" && $btype ne "system" ? "system" : $btype}]
        # A snippet is loose content appended inside the session's region, not a
        # node: the content door opens a temp mark at the session's append point,
        # emits the pieces in order, then advances the session end (and the
        # folder end when this session is the folder's last) past them.
        set m [my append_open $sid]
        my emit $m "▏" [list snippet snippetbar $ntag]
        # Rounded type badge: a label drawing the type name centred over the
        # shared pill image (Tk's SVG cannot render text itself). It is created
        # lazily through -create so only the on-screen badges become real
        # widgets: a whole-corpus search can list thousands of snippets, and
        # eagerly building a widget per badge pegs a core; -create keeps it to a
        # screenful.
        set wr [my emit_window $m -align center -pady 1 -padx 3 \
            -create [list [self] make_badge $bt $fgrole \
                [string toupper [string map {_ { }} $bt]] $path $lineoff]]
        set wstart [lindex $wr 0]
        # The window segment must carry the snippet tag too, or its untagged
        # -wrap (the widget default `word`) lets the row wrap to a second line.
        $Text tag add snippet $wstart "$wstart +1c"
        $Text tag add $ntag   $wstart "$wstart +1c"
        my emit $m "\t" [list snippet $ntag]
        set cr [my emit $m $content [list snippet $ntag]]
        my emit $m "\n" [list snippet $ntag]
        my tag_hits_in_range [lindex $cr 0] [lindex $cr 1] $content
        $Text tag bind $ntag <ButtonRelease-1> \
            [list [self] on_snippet_release $path $lineoff]
        # A snippet row is an extension of its session, so right-clicking it
        # raises the same session menu as the header.
        $Text tag bind $ntag <<ContextMenu>> \
            [list [self] on_session_right $path %X %Y]
        $Text tag bind $ntag <Enter> [list $Text configure -cursor hand2]
        $Text tag bind $ntag <Leave> [list $Text configure -cursor arrow]
        my append_close $sid $m
    }

    # A name hit does not point at a message: it is a title the session has worn.
    # When that title is the one shown now the headline already carries it, so a
    # light "name" label beside the match is enough; when the search hit a name
    # since replaced, the row explains itself - a "former name" badge, the matched
    # name with the query still lit, and an arrow to the name shown today. The
    # buffered snippet is kept either way (an empty match list drops the session).
    # The row shape (spine, badge, tab, content) matches render_snippet's, so the
    # name breadcrumb and the transcript snippets read as one column. With no
    # browsed slug to compare against, the hit stays a plain "name": a former name
    # is only claimed when there is a different current name to point at.
    method render_name_snippet {path content lineoff} {
        set sid [my sid $path]
        set ntag "n#[incr NextId]"
        set slug [my sget $path slug]
        set superseded [expr {$slug ne "" && $content ne $slug}]
        set label [expr {$superseded ? "FORMER NAME" : "NAME"}]
        set m [my append_open $sid]
        my emit $m "▏" [list snippet snippetbar $ntag]
        set wr [my emit_window $m -align center -pady 1 -padx 3 \
            -create [list [self] make_badge names name $label $path $lineoff]]
        set wstart [lindex $wr 0]
        $Text tag add snippet $wstart "$wstart +1c"
        $Text tag add $ntag   $wstart "$wstart +1c"
        my emit $m "\t" [list snippet $ntag]
        set cr [my emit $m $content [list snippet $ntag]]
        my tag_hits_in_range [lindex $cr 0] [lindex $cr 1] $content
        # The arrow to the name shown now only earns its place when the matched
        # name is a former one; an equal name is the headline directly above.
        if {$superseded} {
            my emit $m "  → $slug" [list snippet namearrow $ntag]
        }
        my emit $m "\n" [list snippet $ntag]
        $Text tag bind $ntag <ButtonRelease-1> \
            [list [self] on_snippet_release $path $lineoff]
        $Text tag bind $ntag <<ContextMenu>> \
            [list [self] on_session_right $path %X %Y]
        $Text tag bind $ntag <Enter> [list $Text configure -cursor hand2]
        $Text tag bind $ntag <Leave> [list $Text configure -cursor arrow]
        my append_close $sid $m
    }

    # Build one snippet badge on demand (the text widget's -create callback when
    # the row scrolls into view). $pilltype selects the shared pill image and
    # $text is its centred label: render_snippet derives both from the block type,
    # render_name_snippet passes the breadcrumb's own. Embedded windows do not
    # inherit the row's tag bindings, so click and context-menu are forwarded to
    # the same handlers.
    method make_badge {pilltype fgrole text path lineoff} {
        set b $Text.badge[incr NextId]
        label $b -image [::questlog::ui::theme::badge_pill $pilltype] -compound center \
            -text $text \
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
        $Text configure -state normal
        my anchor_save
        if {[my node_field $sid expanded]} {
            my node_set $sid expanded 0
            my collapse_subagents $path
        } else {
            # The engine primitive: populate realizes the children, then the
            # engine lays them at the session's append point.
            my expand $sid
        }
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

    # Attach a subagent path to the session node's children (the rendered
    # subset), preserving arrival order and skipping a path already attached.
    method attach_child {path cp} {
        set sid [my sid $path]
        set cid [my sid $cp]
        if {$cid in [my node_field $sid children]} return
        my node_set $sid children [linsert [my node_field $sid children] end $cid]
    }

    # Engine hook: realize a session's subagent children at the top of expand.
    # With no attached set yet (browse, or a search case-A session whose
    # subagents did not match), enumerate and attach them all; in search the
    # matched children are already attached as their matches arrived
    # (add_subagent_matches), so they render as they stand.
    method populate {id} {
        if {[my node_field $id kind] ne "session"} return
        if {[llength [my node_field $id children]]} return
        set path [my node_field $id key]
        if {![my sget $path has_subagents]} return
        my ensure_children_enumerated $path
        foreach cp [my sget $path all_child_paths] { my attach_child $path $cp }
    }

    method collapse_subagents {path} {
        my detach_session_children $path
    }

    # Detach every rendered subagent of a session: each child node's region spans
    # its header and its matched-line content, so detaching the children removes
    # the whole subagent block while leaving the session's own match snippets in
    # place (base collapse would take those too). The freed child-snippet tags
    # are loose content, swept after.
    method detach_session_children {path} {
        foreach cp [my session_child_paths $path] {
            if {[my has_child $cp] && [my node_field [my sid $cp] rendered]} {
                my detach [my sid $cp]
            }
        }
        my sweep_loose_tags
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
            cost "" turns "" duration_secs "" human_secs "" model "" \
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
        my detach_session_children $path
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
        # A subagent is a node nested under its session: render_row lays its
        # header at the session's append point (start mark left gravity per
        # start_gravity, so it stays pinned to its row), advances the session end
        # and, when this is the folder's last session, the folder end. The
        # subagent branch of on_row_rendered then emits its matched lines and
        # wires its bindings and cost trigger.
        my render_row $cid
    }

    # The matched lines, bindings and cost trigger a freshly-laid subagent row
    # carries, run by render_row's on_row_rendered tail.
    method wire_subagent_row {id} {
        set cp   [my node_field $id key]
        set path [my node_field [my node_field $id parent] key]
        set ctag [my node_field $id tag]
        set c    [my node_payload $id]
        foreach h [dict get $c hits] {
            lassign $h btype content lineoff
            my render_child_snippet $path $cp $content $lineoff
        }
        set lineoff 0
        if {[llength [dict get $c hits]] > 0} {
            set lineoff [lindex [lindex [dict get $c hits] 0] 2]
        }
        my node_pset $id open_lineoff $lineoff
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
    # deeper spine then the hit-leading content with the terms emboldened.
    method render_child_snippet {path cp content lineoff} {
        set cid [my sid $cp]
        set ntag "c#[incr NextId]"
        # A matched line is loose content inside the subagent's region: the door
        # emits it at the subagent's append point and advances the subagent end
        # past it, carrying the session and folder ends with it where they
        # coincide (the same forward nesting the parent snippet uses).
        set m [my append_open $cid]
        my emit $m "▏  " [list childsnip childbar $ntag]
        set cr [my emit $m $content [list childsnip $ntag]]
        my emit $m "\n" [list childsnip $ntag]
        my tag_hits_in_range [lindex $cr 0] [lindex $cr 1] $content
        $Text tag bind $ntag <ButtonRelease-1> [list [self] on_child_open_at $cp $lineoff]
        $Text tag bind $ntag <<ContextMenu>> [list [self] on_child_right $cp %X %Y]
        $Text tag bind $ntag <Enter> [list $Text configure -cursor hand2]
        $Text tag bind $ntag <Leave> [list $Text configure -cursor arrow]
        my append_close $cid $m
    }

    # The subagent subject: the tree spine, the bold agent type, then the
    # description ellipsised into the room left before the metadata. Returns the
    # subject and its tags (the spine gets childbar, the agent type the bold slug
    # weight); meta_run paints the contiguous metadata grey.
    method child_subject {node max} {
        set c [my node_payload $node]
        set spine "▏  "
        set subj $spine
        set tags [list [list childbar 0 [string length $spine]]]
        set atype [dict get $c agent_type]
        if {$atype ne ""} {
            lappend tags [list slug [string length $subj] [string length $atype]]
            append subj $atype
            append subj "  "
        }
        set fixed [font measure QLList $spine]
        if {$atype ne ""} {
            incr fixed [expr {[font measure QLBold $atype] + [font measure QLList "  "]}]
        }
        append subj [my truncate_px [dict get $c label] \
                         [expr {$max - $fixed}] QLList]
        return [dict create subject $subj tags $tags meta_run 1]
    }

    method on_child_open_at {cp lineoff} { {*}$OnOpen $cp $lineoff }

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
            # The same first-paint toggle discipline as render_session_matches.
            my model_add_session $parent $row
        }
        my sset $parent has_subagents 1
        if {![my sflag $parent hidden] \
            && [my folder_expanded [my sget $parent folder]] \
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

    # The metadata cell values for a row dict (a session or a subagent child),
    # keyed by column id, so parent and child lines pin the same columns. Cost is
    # blank until the second-pass worker fills it in; an unknown model (negative
    # cost) stays blank.
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
                ratio {
                    # Human share of the engaged time, human/(human+machine).
                    # Blank until both figures exist and they amount to
                    # anything, so an unscanned or empty session shows no 0%.
                    set h [dict getdef $s human_secs ""]
                    set m [dict getdef $s duration_secs ""]
                    set v [expr {($h ne "" && $m ne "" && $h + $m > 0) \
                                 ? "[expr {round(100.0 * $h / ($h + $m))}]%" : ""}]
                }
                model { set v [dict getdef $s model ""] }
                actions { set v $::questlog::ui::GLYPH_ACTIONS }
                default { set v "" }
            }
            dict set cells $id $v
        }
        return $cells
    }

    # ---- engine hooks: cell values and tags ---------------------------

    # The metadata cells the engine lays for a node, as ordered {col value} pairs
    # (engine hook). A session or subagent row carries every column. A folder
    # heading carries no per-row date/turns/duration/actions: only an empty date
    # cell (so its size/cost still tab under the rows' size/cost columns) and the
    # size and cost aggregates.
    method cell_values {node} {
        set kind [my node_field $node kind]
        if {$kind eq "folder"} {
            set f [my node_payload $node]
            set n [dict get $f count]
            set size_sum ""
            set cost_sum ""
            if {$n > 0} {
                set size_sum [my fmt_size [dict getdef $f size 0]]
                set fc [dict getdef $f cost 0.0]
                if {$fc > 0} { set cost_sum [::questlog::cost::format_usd $fc] }
            }
            return [list [list date ""] [list size $size_sum] [list cost $cost_sum]]
        }
        set cells [my meta_cells [my node_payload $node]]
        set out [list]
        foreach col [::questlog::ui::session_columns] {
            lassign $col id
            lappend out [list $id [dict get $cells $id]]
        }
        return $out
    }

    # The overlay tags for one laid cell (engine hook), applied only when the
    # cell is non-empty. The cost cell takes a tier colour (amber from 10c, brick
    # red from $1; below that the muted meta grey shows through); the actions cell
    # is marked so a click on it is told apart from the row, and brightens while
    # the row is selected. Folder aggregates are bold; their cost also takes the
    # tier colour, so the project that ate the most reads bold red.
    method cell_tag {node col} {
        set kind [my node_field $node kind]
        if {$kind eq "folder"} {
            switch -- $col {
                size { return {meta foldagg} }
                cost {
                    set fc [dict getdef [my node_payload $node] cost 0.0]
                    set ctag meta
                    if {$fc >= 1.0} {
                        set ctag cost-outlier
                    } elseif {$fc >= 0.10} {
                        set ctag cost-mid
                    }
                    return [list $ctag foldagg]
                }
                default { return {} }
            }
        }
        switch -- $col {
            cost {
                set c [dict getdef [my node_payload $node] cost ""]
                if {$c ne "" && $c >= 0.10} {
                    return [list [expr {$c >= 1.0 ? "cost-outlier" : "cost-mid"}]]
                }
                return {}
            }
            actions {
                if {$kind eq "session" \
                    && [my is_selected [my node_field $node key]]} {
                    return {actioncell actioncell-bright}
                }
                return {actioncell}
            }
            default { return {} }
        }
    }

    # The sort value for a column from a node's payload (engine hook). Date reads
    # mtime so date-descending reproduces the mtime-descending streaming order; a
    # blank or unknown cost/turns/duration sinks to the bottom.
    method sort_key {s col} {
        switch -- $col {
            date { return [dict getdef $s mtime 0] }
            size { return [dict getdef $s size 0] }
            cost {
                set v [dict getdef $s cost ""]
                if {$v eq "" || $v < 0} { return -1 }
                return $v
            }
            turns {
                set v [dict getdef $s turns ""]
                if {$v eq ""} { return -1 }
                return $v
            }
            duration {
                set v [dict getdef $s duration_secs ""]
                if {$v eq ""} { return -1 }
                return $v
            }
            ratio {
                set h [dict getdef $s human_secs ""]
                set m [dict getdef $s duration_secs ""]
                if {$h eq "" || $m eq "" || $h + $m == 0} { return -1 }
                return [expr {double($h) / ($h + $m)}]
            }
            default { return -1 }
        }
    }

    # The leftmost subject zone sorts the folders by their displayed path; a
    # path reads naturally A->Z, so it adopts ascending while the metric columns
    # keep descending.
    method subject_sort_id {} { return "path" }
    method default_sort_dir {id} { return [expr {$id eq "path" ? "asc" : "desc"}] }

    # ---- engine hook: the row subject (left side) ---------------------

    # Build a node's subject: the left side per kind, ellipsised to fit before
    # the metadata strip (engine hook). Returns {subject <str> tags <ranges>
    # meta_run <0|1>}, where tags is a list of {tag off len} ranges relative to
    # the subject start and meta_run asks the engine to paint the contiguous muted
    # metadata run. A folder paints no meta run (its cells are tagged singly).
    method render_subject {node max} {
        switch -- [my node_field $node kind] {
            folder   { return [my folder_subject $node] }
            subagent { return [my child_subject $node $max] }
            default  { return [my session_subject $node $max] }
        }
    }

    # The session subject: the expand chevron (when it has subagents), the status
    # glyphs (running ● green, bookmark ★ amber), the bold slug, the first-prompt
    # preview ellipsised into the room left, then the match count. The chevron and
    # glyphs are kept whole; only the preview is trimmed.
    method session_subject {node max} {
        set s [my node_payload $node]
        set path [my node_field $node key]
        set running [dict exists $RunningSet [dict get $s uuid]]
        set bk [my session_bookmarked $path]
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

        set tags [list]
        set subj ""
        # Every session title starts at the same x. The chevron and status
        # glyphs (running circle, bookmark star) sit in a fixed left gutter, then
        # a tab sends the slug to the title stop apply_column_tabs adds to the
        # sessionhead tabs - the same column-tab mechanism the right-pinned
        # metadata uses. Only present markers are drawn, so an empty gutter shows
        # nothing and the title still lands on the stop. The chevron is the only
        # marker click_on_chevron tests, so a plain gutter has no chevron tag and
        # a click in it just opens the session.
        if {[dict get $s has_subagents]} {
            lappend tags [list chevron [string length $subj] 1]
            append subj [expr {[my node_field $node expanded] ? "▾" : "▸"}]
            append subj " "
        }
        if {$running} {
            lappend tags [list glyph-running [string length $subj] 1]
            append subj $::questlog::ui::GLYPH_RUNNING
        }
        if {$bk} {
            lappend tags [list glyph-bookmark [string length $subj] 1]
            append subj $::questlog::ui::GLYPH_BOOKMARK
        }
        append subj "\t"
        if {$slug ne ""} {
            lappend tags [list slug [string length $subj] [string length $slug]]
            append subj $slug
            append subj "  "
        }
        # The preview fills the room between the title stop and the metadata
        # block: past the gutter the title is tabbed over, then the slug and the
        # match count.
        set fixed [my title_gutter_w]
        if {$slug ne ""} {
            incr fixed [expr {[font measure QLBold $slug] + [font measure QLList "  "]}]
        }
        incr fixed [font measure QLList $count_str]
        append subj [my truncate_px [dict get $s label] \
                         [expr {$max - $fixed}] QLList]
        append subj $count_str
        return [dict create subject $subj tags $tags meta_run 1]
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
        # item rewrites the session line in place, re-pinning the right-gravity
        # start mark; the selection re-paint rides on_row_rendered's wiring being
        # untouched, so re-add the selection tag here as the old rewrite did.
        set sid [my sid $path]
        my item $sid
        if {[my node_field $sid rendered] && [my is_selected $path]} {
            $Text tag add selected [my node_field $sid start] \
                [my node_field $sid end]
        }
    }

    method ensure_folder {folder} {
        if {[my has_folder $folder]} return
        set label [::questlog::path::display_label [{*}$ResolveFolder $folder] $folder]
        # Browsing opens folders collapsed (an overview of projects); a search
        # opens them expanded so the matches under each folder are visible. A
        # collapsed folder draws only its heading - its sessions live in the
        # model and are rendered lazily on expand, so there are no hidden lines.
        set expanded [expr {$CriteriaActive ? 1 : 0}]
        # A folder is a root: the insert primitive owns the TailMark re-anchor,
        # the heading insert and the start/end marks; the on_row_rendered hook
        # binds the heading toggle and registers it for drop hit-testing. The
        # heading is drawn collapsed by default, so flip the open ones and redraw
        # the marker in place.
        set fid [my insert "" folder $folder \
            [dict create label $label count 0 cost 0.0 size 0]]
        if {$expanded} { my node_set $fid expanded 1; my item $fid }
    }

    # The folder heading subject: the marker, the (truncated) project label and a
    # bare "(N)" session count. The folder's size and cost aggregates are laid by
    # the engine as cells (cell_values) under the rows' size/cost columns, with an
    # empty date cell so the double tab opens straight into the size column; their
    # bold/tier tags come from cell_tag. The subject carries no tags of its own.
    method folder_subject {node} {
        set f [my node_payload $node]
        set marker [expr {[my node_field $node expanded] ? "▾" : "▸"}]
        set n [my folder_visible_count [my node_field $node key]]
        set count_str [expr {$n > 0 ? " ($n)" : ""}]
        # Marker joined to the label by a space; the label is truncated so it
        # never runs into the right-pinned aggregates.
        set fixed [expr {[font measure QLList "$marker "] \
                         + [font measure QLList $count_str]}]
        set label [my truncate_px [dict get $f label] \
                       [expr {$FolderLabelMax - $fixed}] QLList]
        return [dict create subject "$marker $label$count_str" tags {} meta_run 0]
    }

    method redraw_folder_heading {folder} {
        if {![my has_folder $folder]} return
        # item rewrites the heading line in place; a detached folder is unrendered,
        # so item no-ops, which is the old folder_attached guard.
        my item [my fid $folder]
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
        my check_invariant toggle_folder
    }

    method expand_folder {folder} {
        foreach path [my folder_visible_paths $folder] {
            my render_session $path
        }
    }

    # The expand-all button: open every folder one level, in one batch so the
    # reader's scroll position anchors once for the whole sweep. Folders render
    # through expand_folder, which sorts at expand time; the engine's store
    # order can lag the display order while streamed results await the
    # debounced resort.
    method expand_all_folders {} {
        my batch {
            foreach fid [my roots] {
                if {[my node_field $fid expanded]} continue
                set folder [my node_field $fid key]
                my node_set $fid expanded 1
                my expand_folder $folder
                my redraw_folder_heading $folder
            }
        }
        my check_invariant expand_all_folders
    }

    # A folder's VISIBLE session paths in the on-screen (sorted) order - the
    # order a Shift-range walks and that expand_folder renders. Hidden rows
    # (view-toggled out) are not in it: a range selection or a batch action
    # must never touch a session the user cannot see. The one place a
    # folder's display order and visibility compose.
    method folder_visible_paths {folder} {
        set shown [list]
        foreach path [my folder_session_paths $folder] {
            if {![my sflag $path hidden]} { lappend shown $path }
        }
        return [my sort_paths $shown [my folder_session_src $folder]]
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

    # True while a lens is narrowing the view, so some loaded sessions may be
    # hidden. When none is, the model count is exact and the per-session walk
    # below is skipped. Every lens counts, the model lens included: it hides
    # loaded rows exactly as the segments do, and a folder whose rows it all hides
    # must not go on reporting them.
    method any_view_toggle {} {
        return [expr {[::questlog::sessionlist::active_lens $Snapshot] ne ""}]
    }

    # A row that arrives while a lens is on lands hidden, and the folder created
    # for it draws a heading with nothing under it: rows stream in one at a time
    # (the scan, the search) and no step in that path re-derives the view, so the
    # heading stands over an empty folder claiming a size and a cost. rebuild is
    # the pass that does re-derive it (hidden-aware, dropping a folder with no
    # shown row), so ask for one - debounced, so a flood of streamed rows costs one
    # rebuild rather than one per row.
    method schedule_view_rebuild {} {
        if {![my any_view_toggle]} return
        if {$ViewRebuildTimer ne ""} { my forget $ViewRebuildTimer }
        set ViewRebuildTimer [my later [::questlog::config::get resort_debounce_ms] \
            [list [self] do_view_rebuild]]
    }

    method do_view_rebuild {} {
        set ViewRebuildTimer ""
        if {![my any_view_toggle]} return
        my rebuild
        my refresh_lens_note
    }

    # The number of a folder's sessions that are currently shown (not hidden by
    # a toggle). This is the count the heading displays and the value that, at
    # zero, detaches the folder from the view.
    method folder_visible_count {folder} {
        if {![my any_view_toggle]} { return [my fget $folder count] }
        set n 0
        foreach path [my folder_session_paths $folder] {
            if {![my sflag $path hidden]} { incr n }
        }
        return $n
    }

    # Drop the per-snippet / per-child-snippet tags ("n#" / "c#") left empty by a
    # body delete. They are loose row content, not nodes, so the engine's
    # node-based cleanup does not reach them; without this they accumulate.
    method sweep_loose_tags {} {
        foreach tg [$Text tag names] {
            if {([string match "n#*" $tg] || [string match "c#*" $tg]) \
                && [llength [$Text tag ranges $tg]] == 0} {
                $Text tag delete $tg
            }
        }
    }

    # Delete every rendered line of the folder's body and drop the per-session
    # render marks; the sessions remain in the model and redraw on the next
    # expand. No hidden text is left behind.
    method collapse_folder {folder} {
        # The collapse primitive deletes the folder's body, resets the end mark
        # to just past the heading, and clears every descendant session's and
        # subagent's render marks (their text just went). It drops the emptied
        # node tags; the loose snippet/match tags are swept separately.
        my collapse [my fid $folder]
        my sweep_loose_tags
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
        my sset $path own_human_secs [dict getdef $cost_dict human_secs ""]
        my sset $path own_model [dict getdef $cost_dict model ""]

        my recompute_parent_totals $path

        set new_cost [my sget $path cost]
        if {$new_cost eq "" || $new_cost < 0} { set new_cost 0.0 }
        set delta [expr {$new_cost - $old_cost}]

        # bump_folder_cost rewrites the heading line and redraw_header the
        # session line; both go through the item primitive, which owns its own
        # widget state, so this method holds none.
        if {$delta != 0} {
            my bump_folder_cost $folder $delta
            set TotalCost [expr {$TotalCost + $delta}]
            my refresh_status
        }
        if {[my sflag $path rendered]} { my redraw_header $path }
        # The worker result can change cost-, turns-, duration- or
        # ratio-sorted order.
        if {$SortKey in {cost turns duration ratio}} { my schedule_resort }
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
        my cset $cp human_secs [dict getdef $cost_dict human_secs ""]
        my cset $cp model [dict getdef $cost_dict model ""]
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
            # The worker result can change cost-, turns-, duration- or
            # ratio-sorted order.
            if {$SortKey in {cost turns duration ratio}} { my schedule_resort }
        }
    }

    # Recomputes the parent session's aggregated totals from its own raw values
    # plus the computed metrics of all its subagents.
    method recompute_parent_totals {path} {
        if {![my has_session $path]} return
        set s [my session_payload $path]

        set has_any_cost 0
        set has_any_turns 0

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
            }
        }

        # Duration is the parent's own active time alone. Subagent durations
        # are not added in: the parent's active span already overlaps the
        # wall-clock during which its subagents ran (they run inside the
        # parent's turns), and parallel subagents would push the figure past
        # real time, so summing would double count. Human time follows the
        # same rule: a sidechain's records are machine or neutral by
        # construction, so a subagent's human time is noise.
        set own_duration [dict getdef $s own_duration_secs ""]
        set dur [expr {($own_duration ne "" && $own_duration >= 0) \
                       ? $own_duration : ""}]
        set own_human [dict getdef $s own_human_secs ""]
        set hum [expr {($own_human ne "" && $own_human >= 0) \
                       ? $own_human : ""}]

        my sset $path cost [expr {$has_any_cost ? $sum_cost : ""}]
        my sset $path turns [expr {$has_any_turns ? $sum_turns : ""}]
        my sset $path duration_secs $dur
        my sset $path human_secs $hum
        # Model is the session's own, never summed: a parent shows the model it
        # ran on, not its subagents'.
        my sset $path model [dict getdef $s own_model ""]
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
    #
    # The selection is a set of session paths (SelectedSet, a dict path->1 in
    # insertion order) with a SelectAnchor the Shift-range extends from. A plain
    # click selects one and opens it; Control toggles one (across folders);
    # Shift selects a contiguous range within one folder. Membership is keyed by
    # path, so it survives the frequent re-renders and follows a moved session.

    method is_selected {path}   { return [dict exists $SelectedSet $path] }
    method selection_paths {}   { return [dict keys $SelectedSet] }
    method selection_count {}   { return [dict size $SelectedSet] }

    # Add or remove the `selected` highlight on one rendered session, and match
    # its ⋯ control brightness. A no-op for an absent or unrendered row (the
    # render path reapplies from membership when the row appears).
    method apply_selection_tag {path on} {
        if {[my has_session $path] && [my sflag $path rendered]} {
            set sid [my sid $path]
            if {$on} {
                $Text tag add selected [my node_field $sid start] [my node_field $sid end]
            } else {
                catch {$Text tag remove selected [my node_field $sid start] \
                                                 [my node_field $sid end]}
            }
        }
        my action_set_bright $path $on
    }

    # Replace the selection with the new set (a path list), repainting only the
    # rows that entered or left it. Shared by every gesture.
    method set_selection {paths} {
        set new [dict create]
        foreach p $paths { dict set new $p 1 }
        foreach p [dict keys $SelectedSet] {
            if {![dict exists $new $p]} { my apply_selection_tag $p 0 }
        }
        foreach p [dict keys $new] {
            if {![dict exists $SelectedSet $p]} { my apply_selection_tag $p 1 }
        }
        set SelectedSet $new
    }

    # Plain click: the selection is exactly this one, and it anchors a range.
    method selection_set {path} {
        my set_selection [list $path]
        set SelectAnchor $path
    }

    # Control click: add or drop one session, across folders; re-anchor to it.
    method selection_toggle {path} {
        if {[my is_selected $path]} {
            set keep [list]
            foreach p [my selection_paths] { if {$p ne $path} { lappend keep $p } }
            my set_selection $keep
        } else {
            my set_selection [concat [my selection_paths] [list $path]]
        }
        set SelectAnchor $path
    }

    # Shift click: the contiguous run between the anchor and this row, in the
    # folder's visible (sorted) order. A range spans one folder only; a Shift
    # click in another folder re-anchors there instead (a range across folders
    # is not a meaningful selection). The anchor stays put so dragging the
    # endpoint grows or shrinks the run from the same origin.
    method selection_range {path} {
        if {$SelectAnchor eq "" || ![my has_session $SelectAnchor]} {
            my selection_set $path
            return
        }
        set folder [my sget $SelectAnchor folder]
        if {![my has_session $path] || [my sget $path folder] ne $folder} {
            my selection_set $path
            return
        }
        set ordered [my folder_visible_paths $folder]
        set ia [lsearch -exact $ordered $SelectAnchor]
        set ib [lsearch -exact $ordered $path]
        if {$ia < 0 || $ib < 0} { my selection_set $path; return }
        if {$ia > $ib} { lassign [list $ib $ia] ia ib }
        my set_selection [lrange $ordered $ia $ib]
    }

    method selection_clear {} {
        my set_selection [list]
        set SelectAnchor ""
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
        # A plain click collapses any multi-selection back to this one row.
        my selection_set $path
        my open_session $path
    }

    # Control release: toggle this row in the selection, across folders. No open.
    method on_session_ctrl_release {path X Y} {
        if {[my click_on_action $X $Y] || [my click_on_chevron $X $Y]} return
        if {[::questlog::ui::drag::release $X $Y]} return
        my selection_toggle $path
    }

    # Shift release: extend the range to this row within its folder. No open.
    method on_session_shift_release {path X Y} {
        if {[my click_on_action $X $Y] || [my click_on_chevron $X $Y]} return
        if {[::questlog::ui::drag::release $X $Y]} return
        my selection_range $path
    }

    # A modified press only outranks the plain <ButtonPress-1> so no drag arms.
    method on_modified_press {args} {}

    # A snippet click opens the session too, deep-linked to that match's line.
    method on_snippet_release {path lineno} {
        my selection_set $path
        my open_session $path $lineno
    }

    # ---- drag-to-move -------------------------------------------------

    method on_session_press {path X Y} {
        # A press on the ⋯ control or the chevron is a control click, not a drag.
        if {[my click_on_action $X $Y]} return
        if {[my click_on_chevron $X $Y]} return
        # Dragging a selected row carries the whole selection; dragging an
        # unselected row carries just it (and leaves the selection untouched
        # unless the gesture resolves as a plain click on release).
        set payload [expr {[my is_selected $path] \
            ? [my selection_paths] : [list $path]}]
        ::questlog::ui::drag::watch $Text $X $Y $payload \
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
    method click_on_action {X Y} { return [my click_on_tag $X $Y actioncell] }

    # Whether a root-coordinate click landed on a session's expand chevron.
    method click_on_chevron {X Y} { return [my click_on_tag $X $Y chevron] }

    method on_row_enter {path} {
        $Text configure -cursor hand2
        my action_set_bright $path 1
    }

    method on_row_leave {path} {
        $Text configure -cursor arrow
        # Keep the ⋯ bright if this row stays selected; otherwise re-fade it.
        my action_set_bright $path [my is_selected $path]
    }

    # Resolve a drag point to the folder under it: the engine maps the point to a
    # text index; a folder heading's drop tag (TagNode) names the target folder.
    method drag_hit {X Y} {
        foreach t [$Text tag names [my index_at $X $Y]] {
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
        # A right-click on a row outside the current selection retargets the
        # selection to it (the menu then acts on what is highlighted). A click
        # on a member of a multi-selection keeps the set and shows the multi
        # menu - the actions that apply to many sessions at once.
        if {![my is_selected $path]} { my selection_set $path }
        if {[my selection_count] > 1} {
            my popup_multi_menu $X $Y
            return
        }
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

        set ctx [dict create target $MenuTarget parent $Top \
            clipboard [list [self] clipboard_set] \
            on_open [list [self] open_session] \
            on_move $OnMoveRequest \
            on_bookmark $OnBookmarkToggle \
            on_rename $OnRename \
            state [dict create \
                is_bookmarked [file executable $path] \
                has_cwd [expr {$cwd ne ""}] \
                has_folder [expr {$folder ne ""}]]]
        set MenuIndices [::questlog::ui::session_actions::populate $Menu $ctx]
        ::questlog::ui::session_actions::apply_state \
            $Menu $MenuIndices [dict get $ctx state]
        tk_popup $Menu $X $Y
    }

    # The menu for a multi-selection: only the actions that apply to many
    # sessions at once (Move, Bookmark). The bookmark label reflects the
    # tri-state rule the handler applies - add to all unless all already carry
    # the bit, in which case remove from all.
    method popup_multi_menu {X Y} {
        set paths [my selection_paths]
        set all_bm 1
        foreach p $paths { if {![file executable $p]} { set all_bm 0; break } }
        set ctx [dict create mode multi paths $paths all_bookmarked $all_bm \
            on_move $OnMoveRequest on_bookmark_set $OnBookmarkSet]
        ::questlog::ui::session_actions::populate $Menu $ctx
        tk_popup $Menu $X $Y
    }

    # Best-effort refresh of a renamed session's list row. The rename itself is
    # a path-only domain op (::questlog::rename) the app applies before calling
    # here; this only updates the shown title, and only if the row is still in
    # view - a session renamed while filtered out has nothing to redraw, which
    # is fine, the title write already persisted to the file.
    method refresh_row {path slug} {
        if {![my has_session $path]} return
        my sset $path slug $slug
        $Text configure -state normal
        my redraw_header $path
        $Text configure -state disabled
    }

    method clipboard_set {s} { clipboard clear; clipboard append $s }

    # ---- running / bookmark reconciliation ---------------------------

    # Re-derive the running glyph for every shown session from a fresh
    # running set and re-apply the running-only / bookmarked-only filter to
    # the loaded model (hiding rows that no longer pass, showing rows that
    # now do). In plain browse it also surfaces a newly-started running
    # session that the scan has not reached yet; under running-only it is a
    # pure local filter over what is already loaded and imports nothing (the
    # toggle chooses which loaded sessions to show, it does not pull sessions
    # in from other projects). Idempotent: running it twice is a no-op, and a
    # missed tick self-corrects on the next.
    method reconcile_running {running} {
        set RunningSet $running
        set running_only [::questlog::sessionlist::toggle $Snapshot running_only 0]
        # The subtree scope is hard, even for a running session: a live session in
        # another project must not surface under a folder scope. The recency bound
        # is the only thing a running session bypasses, not the folder scope.
        set subtree [dict getdef $Snapshot subtree {}]
        set before [my session_count]

        $Text configure -state normal
        my anchor_save
        set imported [dict create]
        if {!$CriteriaActive} {
            dict for {uuid path} $running {
                if {[my has_session $path]} continue
                set row [{*}$LookupSession $path]
                if {$row eq "" && [file isfile $path]} {
                    set row [{*}$OnScanPath $path]
                    # OnScanPath re-enters on_scan_row (see below), whose tail
                    # leaves the widget -state disabled. The model_add_session /
                    # render_session below mutate the buffer, and a disabled
                    # widget silently drops every insert - so a folder created
                    # here gets its heading text dropped, its end mark lands on
                    # its start (a collapsed [start,end] region), and the next
                    # real insert drags the start mark past the stranded end into
                    # end-before-start (the merged-heading desync). Re-assert the
                    # state this method opened with so the structural inserts land.
                    $Text configure -state normal
                }
                if {$row eq "" || ![dict size $row]} continue
                # OnScanPath above is not a pure read: scan_path -> publish_row
                # fires OnRow, which in browse mode is on_scan_row, which has
                # already added (and rendered) this session. Re-check so we do
                # not add it a second time. A running session that on_scan_row
                # filtered out (out of window / below the min-turns floor) is
                # still absent here and is added below, so a running session in
                # scope surfaces in plain browse.
                if {[my has_session $path]} continue
                if {[llength $subtree] > 0 \
                    && ![::questlog::filter::row_subtree_match $row $subtree]} continue
                my model_add_session $path $row
                # Drawing is the dirty pass's job below: rebuild is
                # hidden-aware and creates the folder heading, which this
                # import cannot assume exists (under running_only a folder
                # whose every row is hidden has no heading in the buffer, and
                # rendering into it dies on a bad text index).
                if {![my sflag $path hidden]} {
                    dict set imported [dict get $row folder] 1
                }
            }
        }
        set dirty $imported
        foreach path [my all_session_paths] {
            if {![my has_session $path]} continue
            set uuid [my sget $path uuid]
            set is_running [dict exists $running $uuid]
            # Phantom: not running and the backing jsonl is gone (a Resume-fork that quit
            # before any input). Drop it from every mode.
            if {!$is_running && ![file isfile $path]} { my forget_session $path; continue }
            set row [{*}$LookupSession $path]
            # Retain in the model: a matched search row always; a browse row while it is
            # in scope or running. An out-of-scope, non-running browse row leaves.
            if {$CriteriaActive} {
                set retained 1
            } else {
                # The subtree scope is hard; within it a running session bypasses the
                # recency / min-turns bounds (it always surfaces), but a running
                # session OUTSIDE the subtree scope does not.
                set in_subtree [expr {[llength $subtree] == 0 || $row eq "" \
                    || [::questlog::filter::row_subtree_match $row $subtree]}]
                # A session the reader pulled in through the cut banner stays,
                # whatever the scope says: they named it and asked for it, and
                # dropping it on the next tick would answer them by taking it away.
                set retained [expr {[dict exists $Pinned $path] || ($in_subtree \
                    && (($row ne "" && [my row_matches_snapshot $row]) || $is_running))}]
            }
            if {!$retained} { my forget_session $path; continue }
            set now_hidden [expr {![my session_shown $path $row]}]
            if {$now_hidden != [my sflag $path hidden]} {
                my sflagset $path hidden $now_hidden
                dict set dirty [my sget $path folder] 1
            }
            # Running glyph flip: redraw the header only when it changed AND the folder is
            # not being re-rendered below (the re-render redraws it anyway), and only when
            # the row is actually drawn.
            if {$is_running != [dict exists $PrevRunning $uuid] \
                && [my sflag $path rendered] \
                && ![dict exists $dirty [my sget $path folder]]} {
                my redraw_header $path
            }
        }
        set PrevRunning $running
        if {[dict size $dirty]} {
            # A toggle changed which sessions are viewable. Rebuild from the
            # store rather than edit in place: rebuild is hidden-aware (it skips
            # hidden rows and drops a folder left with none), renumbers the
            # headings to the viewable count, and reseats every folder in order
            # from a clean buffer, owning its own view anchor.
            my rebuild
            $Text configure -state disabled
        } else {
            my anchor_restore
            $Text configure -state disabled
            # Surfacing or dropping running sessions changes the set, so a
            # non-default sort needs a re-render to reseat them.
            if {[my session_count] != $before} { my schedule_resort }
        }
        # The loaded set and the running set have both just settled, so this is
        # where the lens's cut is recounted: every tick, and every filter change
        # that routes through here.
        my refresh_lens_note
        my check_invariant reconcile_running
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
        set size [my sget $path size 0]
        # The delete primitive removes the row and its subagent rows in one cut
        # and unregisters the subtree, running on_before_delete on each node:
        # forget_session_domain subtracts this session's cost and drops its
        # domain indices (its own and its subagents'). The folder-level
        # bookkeeping that depends on whether the folder is now empty stays here.
        my delete $sid
        if {[llength [my node_field $fid children]] == 0} {
            my forget_folder $folder
        } else {
            my fset $folder size [expr {[my fget $folder size 0] - $size}]
            my bump_folder_count $folder -1
        }
    }

    # A session leaving the store: subtract its cost from the folder aggregate
    # and the running total (its node is still present, so the value is exact),
    # then drop its path index, its selection membership, and the indices of any
    # enumerated subagents the rendered-children subtree did not already cover.
    method forget_session_domain {id} {
        set path [my node_field $id key]
        set folder [my node_pget $id folder]
        set cost [my node_pget $id cost]
        if {$cost ne "" && $cost > 0} {
            my bump_folder_cost $folder [expr {-$cost}]
            set TotalCost [expr {$TotalCost - $cost}]
            my refresh_status
        }
        foreach cp [my node_pget $id all_child_paths] {
            if {[dict exists $PathNode $cp]} {
                catch {dict unset Nodes [dict get $PathNode $cp]}
                dict unset PathNode $cp
            }
        }
        dict unset PathNode $path
        dict unset SelectedSet $path
        dict unset Pinned $path
        if {$SelectAnchor eq $path} { set SelectAnchor "" }
    }

    method forget_folder {folder} {
        if {![my has_folder $folder]} return
        # The delete primitive removes the heading region, unsets its marks and
        # drops the node from Roots and the store; the on_before_delete hook
        # clears the folder's domain indices.
        my delete [my fid $folder]
    }

    # After a move renames the file, re-key the model and move the node under its
    # new folder. The move primitive reparents the node off the old folder and
    # onto the new and rebuilds, which keeps the mark scheme consistent; moves
    # are rare, so the cost is not on a hot path.
    method relocate_card {old_path new_path new_folder} {
        if {![my has_session $old_path]} return
        set sid [my sid $old_path]
        my node_pset $sid folder $new_folder
        my node_set $sid key $new_path
        dict unset PathNode $old_path
        dict set PathNode $new_path $sid
        # Create the destination folder in the store when new (no draw; the
        # move's rebuild draws it).
        if {![my has_folder $new_folder]} {
            set new_fid [my node_new folder "" $new_folder \
                [dict create label "" count 0 cost 0.0 size 0]]
            my node_set $new_fid expanded [expr {$CriteriaActive ? 1 : 0}]
            dict set FolderNode $new_folder $new_fid
            lappend Roots $new_fid
        }
        if {[dict exists $SelectedSet $old_path]} {
            dict unset SelectedSet $old_path
            dict set SelectedSet $new_path 1
        }
        if {$SelectAnchor eq $old_path} { set SelectAnchor $new_path }
        my move $sid [my fid $new_folder]
    }

    # Reorder a sibling set for a rebuild, keeping every node (the base renders
    # from the durable store and skips the unviewable separately). Folders
    # reorder by the active sort (cost by aggregate, path by displayed label,
    # else arrival order); a folder's sessions reorder by sort_paths; subagents
    # keep arrival order.
    method sort_siblings {ids} {
        if {[llength $ids] == 0} { return $ids }
        switch [my node_field [lindex $ids 0] kind] {
            folder {
                set order [lmap id $ids { my node_field $id key }]
                if {$SortKey eq "cost"} {
                    set valmap [dict create]
                    foreach id $ids { dict set valmap [my node_field $id key] [my node_pget $id cost 0.0] }
                    set order [my sort_folders $order $valmap -real]
                } elseif {$SortKey eq "path"} {
                    set valmap [dict create]
                    foreach id $ids { dict set valmap [my node_field $id key] [my node_pget $id label ""] }
                    set order [my sort_folders $order $valmap -dictionary]
                }
                return [lmap k $order { my fid $k }]
            }
            session {
                set src [dict create]
                foreach id $ids { dict set src [my node_field $id key] [my session_payload [my node_field $id key]] }
                set order [my sort_paths [lmap id $ids { my node_field $id key }] $src]
                return [lmap k $order { my sid $k }]
            }
            default { return $ids }
        }
    }

    # A folder with no viewable session (empty, or every row hidden by a
    # list-view toggle) leaves the rendered view but stays in the store, so it
    # returns once a session is shown again.
    method render_skip {id} {
        return [expr {[my node_field $id kind] eq "folder" \
            && [my folder_visible_count [my node_field $id key]] == 0}]
    }

    # Whether a folder's heading is currently drawn: a folder dropped from the
    # view by render_skip reads 0 until a rebuild draws it again.
    method folder_attached {folder} {
        return [expr {[my has_folder $folder] && [my node_field [my fid $folder] rendered]}]
    }

    # Re-pin the view after a rebuild to the captured {kind key} top node. The
    # store survives the rebuild, so the node resolves directly; it falls back to
    # the node's folder heading (the row is now hidden or its folder collapsed),
    # then the absolute top.
    method rebuild_restore {anchor} {
        if {$anchor eq ""} { $Text yview moveto 0; return }
        lassign $anchor kind key
        set m ""
        if {$kind eq "folder"} {
            if {[my has_folder $key] && [my node_field [my fid $key] rendered]} {
                set m [my node_field [my fid $key] start]
            }
        } elseif {[dict exists $PathNode $key]} {
            set id [dict get $PathNode $key]
            if {[my node_field $id rendered]} {
                set m [my node_field $id start]
            } else {
                set folder [my node_pget $id folder ""]
                if {$folder ne "" && [my has_folder $folder] \
                    && [my node_field [my fid $folder] rendered]} {
                    set m [my node_field [my fid $folder] start]
                }
            }
        }
        if {$m eq ""} { $Text yview moveto 0 } else { catch {$Text yview $m} }
    }

    # ---- the lens cut ------------------------------------------------
    #
    # A lens shows a subset of the rows the SEARCH loaded, so a session that
    # genuinely belongs to the lens but that the search never read is invisible.
    # Running is the case that bites: a session burning tokens right now, outside
    # the time window, is not in the list, and an unqualified "1 session" tells
    # the reader nothing else is running. The cure is not to let the lens read
    # disk (that would make it a search, and a search drops the selection): it is
    # to count what the lens is missing and say so, and to let the reader ask for
    # the missing session by name.
    #
    # The membership comes from outside the search and is pushed in by the poll
    # (set_lens_members): the live registry for Running, which knows every session
    # running on this machine whatever the window was, and a bookmark sweep for
    # Bookmarked. lens_counts does the arithmetic; the strip says the cut, and the
    # banner names it and offers the two escapes.

    # The active lens's whole membership, uuid -> {path ?cwd?}, as the caller
    # gathered it outside the search. A running member carries the cwd its process
    # runs in, which the registry knows for free; a bookmarked one carries none,
    # because finding it would mean reading a transcript on a path that must not
    # (member_name resolves what it needs, when it needs it). Recounts the cut; the
    # lens itself is not touched, so this can arrive on any tick without disturbing
    # the view.
    method set_lens_members {members} {
        set LensMembers $members
        my refresh_lens_note
    }

    # Recount the active lens against its membership: the strip's clause, the cut
    # members the banner names, and the criterion it offers to relax. With no lens
    # on, or no membership for it (the model lens has none: a row's model is known
    # only once its transcript is parsed), nothing is claimed.
    method refresh_lens_note {} {
        set lens [::questlog::sessionlist::active_lens $Snapshot]
        if {$lens eq "" || ![dict size $LensMembers]} { my drop_lens_note; return }
        set rows [my loaded_rows]
        set c [::questlog::sessionlist::lens_counts \
                   $Snapshot $rows $LensMembers $RunningSet]
        set label [dict get {running Running bookmarked Bookmarked model Model} $lens]
        set LensNote "$label · showing [dict get $c shown] of [dict get $c total]"
        set CutMembers [list]
        foreach uuid [::questlog::sessionlist::lens_excluded \
                          $Snapshot $rows $LensMembers] {
            set m [dict get $LensMembers $uuid]
            dict set m resolved [my member_file $m]
            lappend CutMembers $m
        }
        set CutReason ""
        if {[llength $CutMembers]} {
            append LensNote " · [llength $CutMembers] outside your search"
            set CutReason [my cut_reason [lindex $CutMembers 0]]
        }
        my refresh_status
        my refresh_cut_banner
    }

    method drop_lens_note {} {
        set LensNote ""
        set CutMembers [list]
        set CutReason ""
        my refresh_status
        my refresh_cut_banner
    }

    # The loaded rows as the lens predicate reads them. Built from the node store,
    # not from the scanner's cache, so every row the list is holding is counted:
    # the number in the strip and the rows on screen are the one set.
    method loaded_rows {} {
        set rows [list]
        foreach path [my all_session_paths] {
            lappend rows [dict create \
                uuid       [my sget $path uuid] \
                model      [my sget $path model] \
                bookmarked [my session_bookmarked $path]]
        }
        return $rows
    }

    # Which criterion left this member on disk, as the key the banner words and
    # the widen button relaxes. Two of the six keys blame no criterion, and they
    # are not the same state, which is why they are not the same answer:
    #
    #   none      there is no transcript. The session is running and has not
    #             written a line, so nothing excluded it and nothing can show it.
    #   unloaded  there IS a transcript, and no criterion accounts for its absence
    #             (a bookmark the scan has not reached, a file that landed after
    #             the search ran). Nothing to widen, but "Show it" can read it in.
    #
    # Collapsing the two would put "no transcript on disk to load yet" next to a
    # button offering to load it. Otherwise the criteria are asked in the order
    # they bind: the subtree scope is hard (even a running session outside it never
    # surfaces, see reconcile_running), then the content criteria (with a search
    # active the matches decide what loads, and a session with no hit is not among
    # them), then the recency window, then the min-turns floor.
    method cut_reason {member} {
        if {[dict getdef $member resolved ""] eq ""} { return none }
        set subtree [dict getdef $Snapshot subtree {}]
        if {[llength $subtree] > 0 && ![my member_in_subtree $member $subtree]} {
            return subtree
        }
        if {$CriteriaActive} { return search }
        if {[::questlog::filter::cutoff_for $Snapshot] > 0} { return since }
        if {[dict getdef $Snapshot min_turns 1] > 1} { return min_turns }
        return unloaded
    }

    # Is the member inside the folder scope? The live registry records the cwd the
    # session runs in, which answers it outright; a member with no cwd (a bookmark
    # sweep records none) falls back to its row if the model has one, and finally
    # to its encoded folder name, the same evidence the scanner's walk uses.
    method member_in_subtree {member subtree} {
        set cwd [dict getdef $member cwd ""]
        if {$cwd ne ""} { return [::questlog::filter::in_subtree_of $cwd $subtree] }
        set path [dict get $member path]
        set row [{*}$LookupSession $path]
        if {$row ne ""} { return [::questlog::filter::row_subtree_match $row $subtree] }
        return [::questlog::filter::folder_subtree_candidate \
                    [file tail [file dirname $path]] $subtree]
    }

    # The member's transcript on disk, or "" when there is none to load. The live
    # registry names where the process would write; a session the manager has
    # moved lives elsewhere under the same file name, so look for it by name
    # across the projects (a glob, no reads). A session that has not written a
    # line yet has no file at all, and nothing can show it.
    method member_file {member} {
        set path [dict get $member path]
        if {[file isfile $path]} { return $path }
        foreach hit [glob -nocomplain -directory [::questlog::path::projects_root] \
                         -- */[file tail $path]] {
            if {[file isfile $hit]} { return $hit }
        }
        return ""
    }

    # A missing member's name for the banner. The registry carries the cwd of a
    # running session, so the project it runs in names it; a member the model
    # happens to know (a bookmarked row loaded under another lens) is named by its
    # title; a member with neither - every member of the bookmark sweep, which
    # stamps no cwd - has its project folder resolved here. That resolution reads
    # no transcript (ResolveFolder is Scan's no-read resolver), and it happens for
    # the two members the banner names and for no others, so the cost of naming
    # does not grow with the number of bookmarks on disk. The uuid head is the last
    # resort, for a folder whose directory is gone.
    method member_name {member} {
        set resolved [dict getdef $member resolved ""]
        if {$resolved ne ""} {
            set row [{*}$LookupSession $resolved]
            if {$row ne "" && [dict getdef $row slug ""] ne ""} {
                return [dict get $row slug]
            }
        }
        set cwd [dict getdef $member cwd ""]
        if {$cwd eq ""} {
            set folder [file tail [file dirname [dict get $member path]]]
            set cwd [{*}$ResolveFolder $folder]
        }
        if {$cwd ne ""} { return [::questlog::path::pretty_home $cwd] }
        return [string range [file rootname [file tail [dict get $member path]]] 0 7]
    }

    method build_cut_banner {} {
        set b $Top.cut
        ttk::frame $b -style Cut.TFrame -padding {8 3}
        ttk::label $b.msg -style Cut.TLabel -anchor w
        # The list column can be narrower than the sentence, so wrap the message
        # to the room the escapes leave: a cramped pane then costs the banner a
        # second line, never the half of the sentence that names the session. The
        # width is taken from the BANNER, whose width the parent imposes - taking
        # it from the label would feed the label's own re-wrap back into it and
        # spin the event loop.
        bind $b <Configure> [list [self] wrap_cut_message %w]
        ttk::button $b.show -style CutAct.TButton -takefocus 0 \
            -command [list [self] show_excluded]
        ttk::button $b.widen -style CutAct.TButton -takefocus 0 \
            -command [list [self] widen_cut]
        # Nothing is packed here. refresh_cut_banner raises the banner only while
        # there is a cut to report, and packs the escapes BEFORE the message: pack
        # gives each slave its room in order, so a message longer than the column
        # is wide would otherwise leave the two buttons no width at all, and the
        # escapes - the point of the banner - would be the first thing off-screen.
    }

    # Say the cut in one line: how many members the search left behind, which they
    # are, and what excluded them. Raised only while the cut is non-zero, so the
    # banner's presence is itself the signal.
    method refresh_cut_banner {} {
        set b $Top.cut
        if {![winfo exists $b]} return
        set n [llength $CutMembers]
        if {$n == 0} { pack forget $b; return }
        set lens [::questlog::sessionlist::active_lens $Snapshot]
        set noun [expr {$lens eq "bookmarked" ? "bookmarked" : "running"}]
        set it [expr {$n == 1 ? "it" : "them"}]
        set names [list]
        foreach m [lrange $CutMembers 0 1] { lappend names [my member_name $m] }
        set who [join $names ", "]
        if {$n > [llength $names]} {
            append who " and [expr {$n - [llength $names]}] more"
        }
        $b.msg configure -text "$n $noun session[expr {$n == 1 ? {} : {s}}]\
            outside your search: $who. [my reason_phrase $CutReason $it]"
        # Show it reads the named transcripts - a disk read, which is the whole
        # point: the reader asked for exactly these files. Nothing to read, no
        # button.
        if {[llength [my loadable_members]] == 0} {
            pack forget $b.show
        } else {
            $b.show configure -text [expr {$n == 1 ? "Show it" : "Show them"}]
            pack $b.show -side right -padx {6 0}
        }
        set widen [my widen_label $CutReason]
        if {$widen eq "" || $OnWiden eq ""} {
            pack forget $b.widen
        } else {
            $b.widen configure -text $widen
            pack $b.widen -side right
        }
        # The message last, so it fills what the escapes leave and is the thing
        # that clips in a narrow column.
        pack $b.msg -side left -fill x -expand 1
        pack $b -side top -fill x -after $Top.bar
    }

    # Wrap the message into the banner's width less what the two escapes take, so
    # the buttons keep their room and the sentence flows under itself. Written only
    # when it changes: a re-wrap re-lays the banner, which calls this straight back.
    method wrap_cut_message {w} {
        set room [expr {$w - [winfo reqwidth $Top.cut.show] \
                           - [winfo reqwidth $Top.cut.widen] - 30}]
        if {$room < 80} { set room 80 }
        if {[$Top.cut.msg cget -wraplength] == $room} return
        $Top.cut.msg configure -wraplength $room
    }

    method loadable_members {} {
        set out [list]
        foreach m $CutMembers {
            if {[dict getdef $m resolved ""] ne ""} { lappend out $m }
        }
        return $out
    }

    # The banner's second sentence. `unloaded` is the one that must not read like a
    # criterion, because none excluded the session: it is on disk, the search did
    # not take it, and the "Show it" button beside this sentence will.
    method reason_phrase {reason it} {
        switch -- $reason {
            subtree   { return "The folder scope excluded $it." }
            search    { return "Your search terms excluded $it." }
            since     { return "The time window excluded $it." }
            min_turns { return "The min-turns floor excluded $it." }
            unloaded  { return "The search did not load $it." }
            default   { return "No transcript on disk to load yet." }
        }
    }

    method widen_label {reason} {
        return [dict getdef {
            subtree   "Clear the folder scope"
            search    "Clear the search"
            since     "Clear the time window"
            min_turns "Clear the min-turns floor"
        } $reason ""]
    }

    # The escape that reads disk, and the only one here that does: load exactly the
    # sessions the search left behind, because the reader asked for them by name.
    # Each is scanned in (a single-file read), pinned so the next reconcile does
    # not put it back out of scope, and drawn in its folder. The lens is not
    # touched and needs no exemption: a running session admitted under the Running
    # lens passes row_visible on its own.
    method show_excluded {} {
        set added 0
        foreach m [my loadable_members] {
            set path [dict get $m resolved]
            set row [{*}$OnScanPath $path]
            if {$row eq "" || ![dict size $row]} continue
            # OnScanPath republishes the row through the scanner, so it may have
            # entered the model (and left the widget disabled) on the way; add it
            # only if it did not, and re-assert the state the inserts below need.
            $Text configure -state normal
            if {![my has_session $path]} { my model_add_session $path $row }
            $Text configure -state disabled
            dict set Pinned $path 1
            my open_folder_node [my sget $path folder]
            set added 1
        }
        # rebuild is hidden-aware and owns its own widget state: it reseats every
        # folder from the store, so the new row lands in its place under the lens
        # rather than being appended past the list's end.
        if {$added} { my rebuild }
        my refresh_lens_note
    }

    # Mark a folder open in the store without drawing it; the rebuild that follows
    # draws its shown rows. A browse folder is created collapsed, and a session
    # pulled in behind a collapsed heading would be loaded and still invisible.
    method open_folder_node {folder} {
        if {![my has_folder $folder]} return
        my node_set [my fid $folder] expanded 1
    }

    # The widen button is only ever drawn for a reason that names a criterion, and
    # the guard is written off the same predicate the drawing is, so a reason that
    # blames nothing (none, unloaded) can never be handed to the toolbar as one.
    method widen_cut {} {
        if {$OnWiden eq "" || [my widen_label $CutReason] eq ""} return
        {*}$OnWiden $CutReason
    }

    # ---- status ------------------------------------------------------

    method set_progress {done total matches} {
        set StatusBase "Searching … $done / $total sessions   matches: $matches"
        my refresh_status
    }
    method set_done {total matches} {
        if {$matches == 0} {
            set StatusBase "Done. $total sessions, no matches."
        } else {
            set StatusBase "Done. $total sessions, $matches matches."
        }
        # The result set is final, so the lens's shown count is too: recount it
        # here rather than leave the strip a poll tick behind the answer.
        my refresh_lens_note
    }
    method cancel {} {
        if {$CancelCb ne ""} { {*}$CancelCb }
        set StatusBase "Cancelled."
        my refresh_status
    }

    # Recompute the visible status string: what the list is doing, what the active
    # lens is showing out of what it holds, and what it all cost. Each clause is
    # omitted when it has nothing to say - a zero total would read as a misleading
    # "$0.00" aggregate, and a list under no lens is showing everything it loaded -
    # so the bullets only ever separate clauses that are there.
    method refresh_status {} {
        set parts [list]
        if {$StatusBase ne ""} { lappend parts $StatusBase }
        if {$LensNote ne ""}   { lappend parts $LensNote }
        if {$TotalCost > 0}    { lappend parts [::questlog::cost::format_usd $TotalCost] }
        set StatusVar [join $parts " · "]
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
