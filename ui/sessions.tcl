package require Tcl 9
package require Tk

# Glyphs for the status markers, and the model filter at rest. The single home
# for each: the glyphs mark running and bookmarked rows in the list, and
# MODEL_ANY is the word the model filter carries when no model is chosen (read by
# the strip's model control below for its rest label).
namespace eval ::questlog::ui {
    variable GLYPH_RUNNING  ●
    variable GLYPH_BOOKMARK ★
    variable GLYPH_ACTIONS  ⋯
    variable MODEL_ANY "any model"
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
# Duration, Ctx% and Model are filled by the cost second pass (the forward scan
# stops at the second user record and computes none of them); Ctx% is the
# context occupancy of the transcript's final request against its model's
# window, how full the session is if resumed; Model is the session's last
# non-sidechain assistant model and is not sortable (the per-session sort
# keys are numeric, and a model name has none). The actions column carries the
# row's "⋯" overflow control and is not sortable.
proc ::questlog::ui::session_columns {} {
    return {
        {date     Date     {Wed 30 May 12:30} right 1}
        {size     Size     {999.9 MB}         right 1}
        {cost     Cost     {$9999.99}         right 1}
        {turns    Turns    {9999}             right 1}
        {duration Duration {0:00:00}          right 1}
        {ah       A/H      {999.9}            right 1}
        {context  Ctx%     {100%}             right 1}
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
    variable OnScopeFolder    ;# cb: folder -> scope the toolbar search to that folder, or ""
    variable OnFilterChange   ;# cb: state -> the app learns a strip filter changed, or ""
    variable Snapshot
    variable CriteriaActive
    variable RunningSet       ;# dict uuid -> 1, replaced wholesale each tick
    variable PrevRunning      ;# the prior tick's running set, to redraw only the rows that flipped
    variable FilterMembers    ;# dict uuid -> {path ?cwd?}: what the active filters jointly claim
    variable FilterNote       ;# the status line's filter clause, "" when no filter or no membership
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
    variable SelectedFolder   ;# folder name whose heading is highlighted, or ""
    variable FMenu            ;# the folder-heading right-click menu
    variable Menu
    variable MenuPath
    variable MenuTarget
    variable CMenu            ;# the reduced right-click menu for subagent child rows
    variable ChildMenuPath    ;# child path the child menu acts on
    variable MenuIndices      ;# entry indices returned by session_actions::populate
    variable TotalCost        ;# running sum of per-session cost in the model
    variable StatusBase       ;# last text set by set_progress/set_done
    variable Busy             ;# 1 while a search is in flight (set_progress..set_done/cancel)
    variable OnSubagents      ;# cb: parent path -> list of child row dicts
    variable OnSubagentCost   ;# cb: child path -> start the cost pass for it
    variable OnStatusPeek     ;# cb: text -> reveal it on the app's bottom strip, or ""
    variable OnStatusUnpeek   ;# cb: {} -> restore the strip's standing text, or ""
    variable PeekByTag        ;# dict: row tag -> {kind text}; hover reveal and hit menu resolve from it at event time

    # on_widen is optional: without it the cut banner still names what the search
    # left behind and still offers to load it (that is this object's own doing),
    # and only the widen escape - which relaxes a toolbar criterion, and so needs
    # the toolbar - is absent.
    constructor {parent resolve_cb lookup_cb on_open on_move_request \
                 on_drop_move on_bookmark_toggle on_bookmark_set on_rename \
                 on_scan_path cancel_cb \
                 on_subagents on_subagent_cost \
                 {on_widen ""} {on_status_peek ""} {on_status_unpeek ""} \
                 {on_scope_folder ""} {on_filter_change ""}} {
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
        set OnStatusPeek $on_status_peek
        set OnStatusUnpeek $on_status_unpeek
        set OnScopeFolder $on_scope_folder
        set OnFilterChange $on_filter_change
        set PeekByTag [dict create]
        set StatusVar "Idle"
        set StatusBase ""
        set Busy 0
        set TotalCost 0.0
        set Snapshot [dict create]
        set CriteriaActive 0
        set RunningSet [dict create]
        set PrevRunning [dict create]
        set FilterMembers [dict create]
        set FilterNote ""
        set CutMembers [list]
        set CutReason ""
        set Pinned [dict create]
        set ViewRebuildTimer ""
        set Query [dict create terms [list] nocase 0]
        set SelectedSet [dict create]
        set SelectAnchor ""
        set SelectedFolder ""
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
        # The three list-view filters declared to the engine, which renders the
        # running/bookmarked glyphs (subject-prefix, per-attribute tag attr-<id>)
        # and builds the strip filter controls. attr_value below answers running
        # from the live set, bookmarked from the row, model from the row label;
        # loaded_models provides the enum roster (hidden rows included). The
        # controls' colours ride LV.* styles so they sit on the strip band; the
        # popover keeps the stock look off the strip. A change fires on_filter_change.
        my configure \
            -attrs [list \
                [dict create id running label "running only" kind bool \
                    glyph $::questlog::ui::GLYPH_RUNNING filterable 1] \
                [dict create id bookmarked label "bookmarked only" kind bool \
                    glyph $::questlog::ui::GLYPH_BOOKMARK filterable 1] \
                [dict create id model label $::questlog::ui::MODEL_ANY kind enum \
                    filterable 1 values [list [self] loaded_models]]] \
            -attrstyles [dict create \
                check LV.TCheckbutton menu LV.TMenubutton \
                popcheck LV.TCheckbutton popbtn LV.TButton popframe LVStrip.TFrame] \
            -attrfiltercb [list [self] on_filter_change]
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
        # A wholesale clear can delete the hovered snippet out from under a
        # parked pointer (a streaming search's clear-and-fill); a peek must
        # not outlive its row, and relying on Tk to synthesize the <Leave> is
        # a bet this line does not take. Same invalidation family as the
        # viewer's hover-copy cache. The reveal registry dies with the rows
        # it describes.
        set PeekByTag [dict create]
        if {$OnStatusUnpeek ne ""} { {*}$OnStatusUnpeek }
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

    # ---- domain invariant audit ----------------------------------------
    #
    # The whole-store consistency check over the session domain, the
    # counterpart to the engine's structural check_invariant (which guards the
    # marks). It returns a list of human-readable violation strings, empty when
    # clean, so a test asserts `check audit [$SL audit] {}` and the soak calls
    # it after every operation. Three invariants:
    #   (a) PathNode and the session/subagent nodes' key fields are a bijection,
    #       and FolderNode likewise over folder keys: every registered key
    #       resolves to a node carrying it, and every keyed node is registered
    #       under that key. The half-done move's fault - two nodes under one key -
    #       shows here as a node absent from its own reverse index.
    #   (b) no node's children list names a child twice, the fault that paints a
    #       row twice when sort_siblings maps a repeated key back through sid.
    #   (c) each folder's stored count/size/cost equal a fresh sum over its
    #       member sessions' payloads. The stored count tracks total membership;
    #       a view toggle changes only what the heading displays
    #       (folder_visible_count), not what is stored, so the stored value is
    #       compared against the full member count.
    method audit {} {
        set probs [list]
        # (a) reverse indices are a bijection with the keyed nodes.
        dict for {path id} $PathNode {
            if {![dict exists $Nodes $id]} {
                lappend probs "PathNode\[$path] -> missing node $id"
            } elseif {[my node_field $id key] ne $path} {
                lappend probs "PathNode\[$path] -> node keyed '[my node_field $id key]'"
            }
        }
        dict for {folder id} $FolderNode {
            if {![dict exists $Nodes $id]} {
                lappend probs "FolderNode\[$folder] -> missing node $id"
            } elseif {[my node_field $id key] ne $folder} {
                lappend probs "FolderNode\[$folder] -> node keyed '[my node_field $id key]'"
            }
        }
        foreach id [my all_node_ids] {
            set key [my node_field $id key]
            switch [my node_field $id kind] {
                session - subagent {
                    if {![dict exists $PathNode $key]} {
                        lappend probs "[my node_field $id kind] $key not in PathNode"
                    } elseif {[dict get $PathNode $key] ne $id} {
                        lappend probs "[my node_field $id kind] $key -> $id but PathNode holds [dict get $PathNode $key]"
                    }
                }
                folder {
                    if {![dict exists $FolderNode $key]} {
                        lappend probs "folder $key not in FolderNode"
                    } elseif {[dict get $FolderNode $key] ne $id} {
                        lappend probs "folder $key -> $id but FolderNode holds [dict get $FolderNode $key]"
                    }
                }
            }
        }
        # (b) no children list holds an id twice.
        foreach id [my all_node_ids] {
            set seen [dict create]
            foreach c [my node_field $id children] {
                if {[dict exists $seen $c]} {
                    lappend probs "[my node_field $id key] children repeat $c"
                }
                dict set seen $c 1
            }
        }
        # (c) folder aggregates equal a fresh sum over member sessions.
        dict for {folder fid} $FolderNode {
            set n 0; set sz 0; set cst 0.0
            foreach sid [my node_field $fid children] {
                if {[my node_field $sid kind] ne "session"} continue
                incr n
                set sz [expr {$sz + [my node_pget $sid size 0]}]
                set c [my node_pget $sid cost]
                if {$c ne "" && $c > 0} { set cst [expr {$cst + $c}] }
            }
            if {[my fget $folder count] != $n} {
                lappend probs "folder $folder count [my fget $folder count] != $n members"
            }
            if {[my fget $folder size 0] != $sz} {
                lappend probs "folder $folder size [my fget $folder size 0] != $sz members"
            }
            if {abs([my fget $folder cost 0.0] - $cst) > 1e-6} {
                lappend probs "folder $folder cost [my fget $folder cost 0.0] != $cst members"
            }
        }
        return $probs
    }

    # ---- domain-keyed shims over the node store ----------------------
    #
    # Folder/session/subagent operations name their target by domain key
    # (folder name or file path). These shims turn that key into a node id and
    # read or write the structural and payload fields, so the bodies below
    # speak the domain vocabulary and never touch node ids directly.

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
                set bfolder [my pctsafe $folder]
                # A click on the marker toggles expand/collapse; a click on the
                # rest of the heading selects the folder (on_folder_click routes
                # by hit-testing the foldchevron range). Double-click also toggles,
                # and the right button raises the folder menu.
                $Text tag bind $htag <Button-1> \
                    [list [self] on_folder_click $bfolder %X %Y]
                $Text tag bind $htag <Double-Button-1> \
                    [list [self] toggle_folder $bfolder]
                $Text tag bind $htag <<ContextMenu>> \
                    [list [self] on_folder_right $bfolder %X %Y]
                if {[my is_folder_selected $folder]} {
                    set fm [my node_field $id start]
                    $Text tag add selected $fm "$fm lineend"
                }
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
        # Cancel is live only while there is a search to cancel; it rests disabled
        # so the button never invites a click that would stamp "Cancelled." over an
        # idle list. sync_cancel follows the Busy flag at each search boundary.
        ttk::button $Top.bar.cancel -text "Cancel" -state disabled \
            -command [list [self] cancel]
        pack $Top.bar.cancel -side right -padx 4 -pady 2

        my build_cut_banner

        # The list strip: it sits between the status line and the body's
        # column-header strip, taking that strip's #ececec colour so it reads as
        # the top of the list. Packed before build_body so it lands above the
        # header band. Expand-all acts on the list (packed left); the filters
        # (running, bookmarked, model) are the engine's own filter
        # controls, packed right. During the interim the toolbar still carries a
        # duplicate View row; a later stage removes it.
        ttk::frame $Top.lvt -style LVStrip.TFrame -padding {8 4}
        pack $Top.lvt -side top -fill x
        ttk::button $Top.lvt.expandall -text "expand all" -style LV.TButton \
            -takefocus 0 -command [list [self] expand_all_folders]
        pack $Top.lvt.expandall -side left
        # The engine fills the strip with a control per filterable attribute,
        # packed toward the right so they sit opposite expand-all.
        my build_filters $Top.lvt right

        # The engine assembles the body (header text, list text, scrollbar, the
        # <Configure> relayout hook, the selection suppression and TailMark);
        # the session-domain tags, sort header and menus go on top of it.
        my build_body
        my configure_tags
        my build_header
        my build_menu
        my build_child_menu
        my build_folder_menu
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
        # The status glyphs are engine-rendered attribute prefixes (running,
        # bookmarked declared as glyphed bools); the engine tags each glyph
        # attr-<id>, and these dress the two glyphed attributes in their
        # theme colours.
        $Text tag configure attr-running    -foreground [::questlog::ui::theme::c attr_running]
        $Text tag configure attr-bookmarked -foreground [::questlog::ui::theme::c attr_bookmarked]
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
        # grey, so only elevated costs stand out. An elevated cell carries both
        # the tier colour and a bolder weight (QLBold), so the money reads at a
        # glance even where colour is hard to tell apart. Configured after meta so
        # the tier foreground and font win over it on the cost cell.
        $Text tag configure cost-mid     -foreground [::questlog::ui::theme::c cost_mid] -font QLBold
        $Text tag configure cost-outlier -foreground [::questlog::ui::theme::c cost_outlier] -font QLBold
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
        # A list italic face for the muted secondary lines (the "N more matches"
        # overflow row and the case-B subagent note), matched to the list font's
        # family and size. Created once; a second SessionList reuses it.
        if {"QLListItalic" ni [font names]} {
            font create QLListItalic {*}[font actual QLList] -slant italic
        }
        # The title run dims to the muted grey when only a session's subagents
        # matched (session_subject), so the parent reads as context for the hits
        # below. Configured after sessionhead/slug so its foreground wins there.
        $Text tag configure dimmed -foreground [::questlog::ui::theme::c muted]
        # The overflow row ("+N ... N more matches ...") and the case-B note read
        # as a quiet aside beneath the matched lines: muted and italic. Overlays
        # the snippet/childsnip indent, so it is configured after them to win the
        # font and colour on that run.
        $Text tag configure snippetmore \
            -foreground [::questlog::ui::theme::c muted] -font QLListItalic

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
        set SelectedFolder ""
        set TotalCost 0.0
        set StatusBase ""
        # The pinned sessions were pulled in past the old search; the new one has
        # its own answer. The filter membership survives (it is gathered outside the
        # search), but its cut cannot be recounted against a list that has not
        # been filled yet - the reconcile that follows the fill recounts it, so the
        # banner never flashes a cut that the new search does load.
        set Pinned [dict create]
        my drop_filter_note
        my refresh_status
    }

    method apply_filter {snapshot} {
        set Snapshot $snapshot
        # The arriving snapshot is search and scope only; the engine owns the
        # filters and holds them across the change, so a refill honours a filter
        # still pressed on the strip with nothing here to re-graft.
        set CriteriaActive [::questlog::ui::any_criteria $snapshot]
        my clear
    }

    # The models the loaded rows carry: every distinct, non-empty model label in
    # the list, hidden rows included, sorted so the filter does not reorder itself
    # with the scan. Hidden rows count because a row the model filter is hiding is
    # exactly the row whose entry must stay in the menu for the filter to be widened
    # back off it. A row whose cost pass has not landed yet has no label and is
    # simply not named; the model filter admits such a row (its value is absent),
    # so it never disappears for want of an entry.
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

    # ---- declarative-attribute hooks (the engine's filter and glyph facility) --

    # The value of a declared attribute on a node (engine hook). The engine reads
    # every attribute only through here, so it filters and glyphs the three filters
    # without ever looking inside a payload. Only a session answers: a folder or a
    # subagent returns "" for all three, so a container is never glyphed and never
    # filtered (a bool absent shows and draws no mark, an enum empty always shows),
    # exactly as the filters only ever touch session rows.
    #   running    live iff the row's uuid is in the poll-derived running set.
    #   bookmarked the row's +x bit (session_bookmarked), the same the filter reads.
    #   model      the row's model label, "" until the cost pass fills it.
    method attr_value {node id} {
        if {[my node_field $node kind] ne "session"} { return "" }
        switch -- $id {
            running    { return [expr {[dict exists $RunningSet [my node_pget $node uuid]] ? 1 : 0}] }
            bookmarked { return [my session_bookmarked [my node_field $node key]] }
            model      { return [my node_pget $node model ""] }
            default    { return [my node_pget $node $id] }
        }
    }

    # Apply the engine's active attribute filters to the list (engine method,
    # overridden). The base walks each node through the hide/unhide primitives and
    # keeps its own ledger; that cannot compose with this list's folder-drop
    # rebuild, whose render_skip takes an emptied folder out of the view, because
    # the base unhide would try to render a row back into a folder heading that is
    # no longer drawn. So derive each session's hidden flag from attr_admits (the
    # engine's live filter state) and rebuild instead: the rebuild is hidden-aware,
    # drops and restores folders by their viewable count, and keeps the selection
    # (path-keyed, re-applied on paint) and the scroll. Only sessions carry the
    # attributes (attr_value answers "" for folders and subagents), so a container
    # is never filtered. This is what the strip controls drive, and what
    # reconcile_running re-applies when the running set changes.
    method apply_attr_filters {} {
        set st [$Text cget -state]
        $Text configure -state normal
        foreach path [my all_session_paths] {
            my sflagset $path hidden [expr {![my attr_admits [my sid $path]]}]
        }
        $Text configure -state $st
        my rebuild
    }

    # A strip filter moved (engine hook -attrfiltercb): apply_attr_filters (fired
    # from attr_filter_set just before this) has already re-derived the view and
    # rebuilt. Recount the filter note off the fresh engine state, and hand the
    # state to the app so it can gather the filter memberships. No disk: the loaded
    # rows come from the cache and nothing here scans or searches.
    method on_filter_change {state} {
        my refresh_filter_note
        if {$OnFilterChange ne ""} { {*}$OnFilterChange $state }
    }

    # ---- snapshot membership -----------------------------------------

    # Whether a row passes the current snapshot's row-level filters. The
    # predicate is shared with Scan through ::questlog::scope, so the model and
    # the view never disagree on what the snapshot admits.
    method row_matches_snapshot {row} {
        return [::questlog::scope::row_matches $Snapshot $row]
    }

    # The scope-relevant fields of a modelled session, assembled from its node
    # payload into the row shape ::questlog::scope reads. These are exactly the
    # fields row_subtree_match (folder, folder_cwd, cwd_hint) and row_matches
    # (mtime, nturns) consult; a caller with a modelled path uses this in place
    # of a Scan.Rows lookup. mtime and nturns are set-at-scan and go stale for a
    # session still being written, but such a session is running and is retained
    # by that fact before its recency is ever weighed, so the frozen copy
    # decides nothing a fresh read would decide differently.
    method payload_scope_row {path} {
        return [dict create \
            folder     [my sget $path folder] \
            folder_cwd [my sget $path folder_cwd] \
            cwd_hint   [my sget $path cwd_hint] \
            mtime      [my sget $path mtime 0] \
            nturns     [my sget $path nturns]]
    }

    # ---- streaming inserts -------------------------------------------

    # Browse-mode row from Scan. Skipped when criteria are active (the result
    # index is built from matches, not the scan stream). The view filters do
    # not gate the stream: every in-scope row enters the model, and the engine's
    # attr_admits settles its hidden flag, so a filter only chooses what paints.
    method on_scan_row {row} {
        if {$CriteriaActive} return
        if {![my row_matches_snapshot $row]} return   ;# scope = model membership
        set path [dict get $row path]
        if {[dict exists $PathNode $path]} return
        $Text configure -state normal
        my anchor_save
        my model_add_session $path $row
        # The model holds every in-scope session; the filters decide only whether it is
        # drawn (model_add_session flagged it), so a later filter hides/shows it in
        # place without a re-scan.
        if {[my sflag $path hidden]} {
            # It landed hidden under a filter, so its folder may now be a heading
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
            my model_add_session $path $row
        }
        # Search folders are expanded, so render the session if it is visible
        # and not yet drawn. A result a filter hides leaves its folder a heading
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
        if {[my sflag $path rendered]} {
            # A subagent's match can land before the parent's own. The case-B
            # note that arrival drew no longer holds now direct matches exist,
            # and the children it rendered sit above the snippets this call just
            # laid, so reseat the sub block: the note lifts (render_subhint
            # no-ops once count is nonzero) and the children re-lay below the
            # parent's own content.
            if {[my sget $path subhint_tag] ne ""} { my redraw_sub_block $path }
            # After the capped snippets, name the rest: a session with more matches
            # than the shown snippets gets a "N more matches" overflow row.
            set shown [llength [my sget $path snippets]]
            set total [my sget $path count]
            if {$total > $shown} { my render_overflow $path [expr {$total - $shown}] }
            my redraw_header $path
        }
    }

    method folder_expanded {folder} {
        if {![dict exists $FolderNode $folder]} { return 0 }
        return [my node_field [dict get $FolderNode $folder] expanded]
    }

    # Record a session in the model without drawing it. A collapsed folder
    # holds its sessions here only; they are drawn lazily on expand. This is
    # what keeps a folded list cheap and free of hidden (elided) lines.
    method model_add_session {path row} {
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
        set ctxp  [dict getdef $row context_pct ""]
        # Scan's row fields the store answers session questions from directly,
        # so a modelled session need not be looked up in Scan.Rows to be asked
        # about. bookmarked defaults to the on-disk +x bit for a synthetic row
        # that omits it; the rest default empty. The token fields and
        # model_breakdown arrive with cost and are kept fresh by refresh_cost,
        # bookmarked by reconcile_one; the rest are set-at-scan and static.
        set bkmk  [dict getdef $row bookmarked [file executable $path]]
        set fuser [dict getdef $row first_user ""]
        set okind [dict getdef $row kind ""]
        set fcwd  [dict getdef $row folder_cwd ""]
        set chint [dict getdef $row cwd_hint ""]
        set ntrn  [dict getdef $row nturns ""]
        set itok  [dict getdef $row input_tokens ""]
        set otok  [dict getdef $row output_tokens ""]
        set cwtok [dict getdef $row cache_write_tokens ""]
        set crtok [dict getdef $row cache_read_tokens ""]
        set mbrk  [dict getdef $row model_breakdown ""]
        # The session node: payload carries the per-session domain dict; the
        # node's expanded/rendered flags, start/end marks, tag and children
        # (the attached subagent nodes) live alongside it in the store.
        set fid [my fid $folder]
        set sid [my node_new session $fid $path [dict create \
            folder $folder label $label slug $slug ai_title $aitt \
            when $when mtime $mtime size $size uuid $uuid cost $cost \
            turns $turns duration_secs $dsecs human_secs $hsecs model $model \
            context_pct $ctxp \
            bookmarked $bkmk first_user $fuser kind $okind folder_cwd $fcwd \
            cwd_hint $chint nturns $ntrn input_tokens $itok output_tokens $otok \
            cache_write_tokens $cwtok cache_read_tokens $crtok \
            model_breakdown $mbrk \
            own_cost $cost own_turns $turns own_duration_secs $dsecs \
            own_human_secs $hsecs own_model $model own_context_pct $ctxp \
            count 0 snippets [list] \
            has_subagents [dict getdef $row has_subagents 0] \
            sub_total 0 children_listed 0 all_child_paths [list]]]
        dict set PathNode $path $sid
        my node_set $fid children [linsert [my node_field $fid children] end $sid]
        # Whether the filters admit this row is settled here by the engine, before
        # the folder heading below is redrawn from it: a row added hidden and
        # flagged after the fact is counted into a heading that then shows nothing
        # under it, and the heading reads "(1)" over an empty folder. The model
        # holds every in-scope session either way; the flag only decides what
        # paints. attr_admits reads the node just created above, so the node is
        # asked, never the scanner's cache.
        my node_set $sid hidden [expr {![my attr_admits $sid]}]

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
        # Every $path below rides through pctsafe: bind %-substitutes its
        # script before Tcl parses it, and a project directory holding a %
        # would be rewritten in place (issue #41's "100%pure" repro). The
        # %X/%Y stay bare - they are the substitutions doing their job.
        set bpath [my pctsafe $path]
        $Text tag bind $stag <ButtonPress-1> \
            [list [self] on_session_press $bpath %X %Y]
        $Text tag bind $stag <ButtonRelease-1> \
            [list [self] on_session_release $bpath %X %Y]
        # Shift/Control extend the selection. The modifier press is a no-op that
        # only outranks the plain <ButtonPress-1> above, so a modified click arms
        # no drag; the gesture resolves on the modified release.
        $Text tag bind $stag <Shift-ButtonPress-1>   [list [self] on_modified_press]
        $Text tag bind $stag <Control-ButtonPress-1> [list [self] on_modified_press]
        $Text tag bind $stag <Shift-ButtonRelease-1> \
            [list [self] on_session_shift_release $bpath %X %Y]
        $Text tag bind $stag <Control-ButtonRelease-1> \
            [list [self] on_session_ctrl_release $bpath %X %Y]
        # Tk's <<ContextMenu>> virtual event already maps to the right button
        # per platform (Button-2 on Aqua, Button-3 elsewhere); app.tcl extends
        # it with Control-Button-1 on Aqua so Ctrl+click works too.
        $Text tag bind $stag <<ContextMenu>> \
            [list [self] on_session_right $bpath %X %Y]
        # A whole session row is one clickable object: a hand cursor over it,
        # an arrow elsewhere. Text tags carry no -cursor, so swap the widget
        # cursor on enter/leave; entering also brightens the row's ⋯ control.
        $Text tag bind $stag <Enter> [list [self] on_row_enter $bpath]
        $Text tag bind $stag <Leave> [list [self] on_row_leave $bpath]
        foreach snip [my sget $path snippets] {
            lassign $snip btype content lineoff
            my render_snippet $path $btype $content $lineoff
        }
        # Replay the two below-snippet lines the streaming pass drew: the "N more
        # matches" overflow (count over the snippet cap) and the case-B note (only
        # subagents matched). Both sit above the subagents. render_subhint no-ops
        # unless case B holds; the overflow no-ops unless the cap was exceeded.
        set shown [llength [my sget $path snippets]]
        set total [my sget $path count]
        if {$total > $shown} { my render_overflow $path [expr {$total - $shown}] }
        my render_subhint $path
        if {[my node_field $id expanded]} { my render_children $path }
        if {[my is_selected $path]} {
            $Text tag add selected $sm "$sm lineend"
        }
    }

    # The badge word for a block type, in the reader's vocabulary: a user turn
    # reads "user text" and a tool call "tool call", so the badge names the source
    # line the way the reader thinks of it, not by its raw record type. The other
    # types keep their name with the underscore opened to a space (tool_result ->
    # "tool result"). The caller uppercases it for the pill.
    method badge_label {bt} {
        return [dict getdef {
            user     {user text}
            tool_use {tool call}
        } $bt [string map {_ { }} $bt]]
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
                [string toupper [my badge_label $bt]] $path $lineoff $ntag]]
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
            [list [self] on_snippet_release [my pctsafe $path] $lineoff]
        # A snippet row is an extension of its session, so right-clicking it
        # raises the session menu - but on a specific match, so it goes through
        # the hit-aware handler: the numeric lineoff rides the script bare, the
        # snippet text is resolved at event time from the reveal registry
        # ($ntag's entry) rather than spliced (issue #41's %-corruption).
        $Text tag bind $ntag <<ContextMenu>> \
            [list [self] on_hit_right [my pctsafe $path] $lineoff $ntag %X %Y]
        # Hovering reveals the whole snippet line (bt leads it) on the bottom
        # strip; the row itself only shows what fits before the metadata columns.
        my peek_wire $ntag $bt $content
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
            -create [list [self] make_badge names name $label $path $lineoff $ntag]]
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
            [list [self] on_snippet_release [my pctsafe $path] $lineoff]
        # A name breadcrumb is a hit too: the hit-aware right-click carries the
        # matched line and resolves the worn title from $ntag's reveal entry.
        $Text tag bind $ntag <<ContextMenu>> \
            [list [self] on_hit_right [my pctsafe $path] $lineoff $ntag %X %Y]
        # The reveal leads with the breadcrumb's own badge word ("name" /
        # "former name") and carries the whole worn title.
        my peek_wire $ntag [string tolower $label] $content
        my append_close $sid $m
    }

    # The "N more matches" overflow row under a capped parent snippet block: past
    # the first snippets_per_session hits shown, this muted italic line names how
    # many more the session holds and points at the viewer, where the whole match
    # index sits. Loose content (an n# tag, swept on detach), appended after the
    # shown snippets; a click opens the session at its start (like a plain row
    # click), landing the reader in the full index.
    method render_overflow {path more} {
        set sid [my sid $path]
        set ntag "n#[incr NextId]"
        set m [my append_open $sid]
        my emit $m "▏" [list snippet snippetbar $ntag]
        my emit $m "  +$more" [list snippet snippetmore $ntag]
        my emit $m "\t" [list snippet $ntag]
        my emit $m "$more more [expr {$more == 1 ? {match} : {matches}}]\
            in this session - open to see all" [list snippet snippetmore $ntag]
        my emit $m "\n" [list snippet $ntag]
        $Text tag bind $ntag <ButtonRelease-1> \
            [list [self] on_snippet_release [my pctsafe $path] 0]
        my append_close $sid $m
    }

    # 1 iff only a session's subagents matched (case B): it carries no hit of its
    # own but its subagents do, so it surfaces on theirs.
    method session_onlyinsubs {path} {
        return [expr {[my sget $path count] == 0 && [my sget $path sub_total] > 0}]
    }

    # The case-B note beneath a session header: only its subagents matched, so a
    # muted italic line says how many matches sit in how many subagents, and the
    # subagents auto-expand below to carry them. Loose content whose tag is kept on
    # the session so clear_subhint can lift it before a redraw.
    method render_subhint {path} {
        if {![my session_onlyinsubs $path]} return
        set sid [my sid $path]
        set subt [my sget $path sub_total]
        set nsub [llength [my session_child_paths $path]]
        set ntag "n#[incr NextId]"
        set m [my append_open $sid]
        my emit $m "▏" [list snippet snippetbar $ntag]
        my emit $m "\t" [list snippet $ntag]
        my emit $m "no match in this session - $subt\
            [expr {$subt == 1 ? {match} : {matches}}] below in\
            [expr {$nsub == 1 ? {a subagent} : {subagents}}]" \
            [list snippet snippetmore $ntag]
        my emit $m "\n" [list snippet $ntag]
        my sset $path subhint_tag $ntag
        my append_close $sid $m
    }

    # Remove a session's case-B note line, if one is drawn, so a redraw can lay a
    # fresh one from the current totals with no stale copy left behind.
    method clear_subhint {path} {
        set tag [my sget $path subhint_tag]
        if {$tag eq ""} return
        # The engine owns the text delete (mark bookkeeping); the host clears its
        # own registry entry and the per-session handle.
        my drop_loose $tag
        $Text tag delete $tag
        dict unset PeekByTag $tag
        my sset $path subhint_tag ""
    }

    # Build one snippet badge on demand (the text widget's -create callback when
    # the row scrolls into view). $pilltype selects the shared pill image and
    # $text is its centred label: render_snippet derives both from the block type,
    # render_name_snippet passes the breadcrumb's own. Embedded windows do not
    # inherit the row's tag bindings, so click and context-menu are forwarded to
    # the same handlers; $ntag is the row's reveal tag, carried into the
    # hit-aware right-click so the menu can resolve this match's snippet text.
    method make_badge {pilltype fgrole text path lineoff ntag} {
        set b $Text.badge[incr NextId]
        label $b -image [::questlog::ui::theme::badge_pill $pilltype] -compound center \
            -text $text \
            -font QLBold -foreground [::questlog::ui::theme::c $fgrole] \
            -background [$Text cget -background] -borderwidth 0 \
            -takefocus 0 -cursor hand2
        bind $b <ButtonRelease-1> \
            [list [self] on_snippet_release [my pctsafe $path] $lineoff]
        bind $b <<ContextMenu>> \
            [list [self] on_hit_right [my pctsafe $path] $lineoff $ntag %X %Y]
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
            context_pct "" \
            agent_type [dict getdef $crow agent_type ""] \
            agent_id [dict getdef $crow agent_id [file rootname [file tail $cp]]] \
            label $label hits [list] count 0 open_lineoff 0]]
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
            my render_child_snippet $path $cp $btype $content $lineoff
        }
        # A subagent capped at snippets_per_subagent gets the same "N more matches"
        # overflow row as a parent, one level deeper, opening the subagent itself.
        set shown [llength [dict get $c hits]]
        set total [dict getdef $c count $shown]
        if {$total > $shown} {
            my render_child_overflow $path $cp [expr {$total - $shown}]
        }
        set lineoff 0
        if {[llength [dict get $c hits]] > 0} {
            set lineoff [lindex [lindex [dict get $c hits] 0] 2]
        }
        my node_pset $id open_lineoff $lineoff
        $Text tag bind $ctag <ButtonRelease-1> \
            [list [self] on_child_release [my pctsafe $cp]]
        $Text tag bind $ctag <<ContextMenu>> \
            [list [self] on_child_right [my pctsafe $cp] %X %Y]
        # The subagent header's description is truncated into the room before the
        # metadata; hovering reveals it whole on the strip, led by the agent type.
        my peek_wire $ctag [dict get $c agent_type] [dict get $c label]
        # Cost rides the same second pass as a session's; trigger it once (when
        # the child has no cost yet), so a re-render after the result does not
        # re-queue it.
        if {[dict get $c cost] eq ""} { {*}$OnSubagentCost $cp }
    }

    # A subagent's matched line, beneath its child header, opening the subagent's
    # own transcript at the hit (issue #13 chose per-file open over a unified
    # parent+child view). Lighter than a parent snippet (no badge widget): a
    # deeper spine then the hit-leading content with the terms emboldened.
    method render_child_snippet {path cp btype content lineoff} {
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
        $Text tag bind $ntag <ButtonRelease-1> \
            [list [self] on_child_open_at [my pctsafe $cp] $lineoff]
        # A subagent's matched line is a hit: the right-click carries its numeric
        # lineoff bare and $ntag, so the child menu can open at the match and copy
        # the snippet (text resolved from $ntag's reveal entry, never spliced).
        $Text tag bind $ntag <<ContextMenu>> \
            [list [self] on_child_right [my pctsafe $cp] %X %Y $ntag $lineoff]
        # Same reveal as a parent snippet, one level deeper: the whole matched
        # line on the strip, led by its block type.
        my peek_wire $ntag $btype $content
        my append_close $cid $m
    }

    # The "N more matches" overflow row under a capped subagent block: names the
    # hits past the shown snippets and opens the subagent's own transcript, where
    # they all sit. A childsnip-depth line, muted and italic like the parent's.
    method render_child_overflow {path cp more} {
        set cid [my sid $cp]
        set ntag "c#[incr NextId]"
        set m [my append_open $cid]
        my emit $m "▏  " [list childsnip childbar $ntag]
        my emit $m "+$more more [expr {$more == 1 ? {match} : {matches}}]\
            in this session - open to see all" [list childsnip snippetmore $ntag]
        my emit $m "\n" [list childsnip $ntag]
        $Text tag bind $ntag <ButtonRelease-1> \
            [list [self] on_child_release [my pctsafe $cp]]
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
    # path, copy last output, and reveal remain. The widget is built empty and
    # refilled per-open by populate_child_menu, so the header and a matched line
    # can differ (the line gains the two hit entries).
    method build_child_menu {} {
        set CMenu $Top.ccmenu
        menu $CMenu -tearoff 0
        set ChildMenuPath ""
    }

    # Refill the child menu for this open. A right-click on a matched line passes
    # a hit {lineoff snippet}; a right-click on the header passes "". The two hit
    # entries mirror the parent snippet's: open the subagent transcript at the
    # match, and copy the matched snippet the model stored.
    method populate_child_menu {hit} {
        $CMenu delete 0 end
        $CMenu add command -label "Open in viewer" \
            -command [list [self] child_menu_open]
        if {$hit ne ""} {
            $CMenu add command -label "Open at this match" \
                -command [list [self] on_child_open_at $ChildMenuPath \
                    [dict get $hit lineoff]]
            $CMenu add command -label "Copy this snippet" \
                -command [list [self] clipboard_set [dict get $hit snippet]]
        }
        $CMenu add separator
        $CMenu add command -label "Copy session path" \
            -command [list [self] child_menu_copy_path]
        $CMenu add command -label "Copy last assistant output" \
            -command [list [self] child_menu_copy_last_assistant]
        $CMenu add separator
        $CMenu add command -label "Reveal folder" \
            -command [list [self] child_menu_reveal]
    }

    # A hitless open (from the subagent header) leaves $tag empty; a matched line
    # passes its reveal tag and numeric lineoff, and the snippet text is resolved
    # from the registry at event time - never carried in the bind script.
    method on_child_right {cp X Y {tag ""} {lineoff ""}} {
        set ChildMenuPath $cp
        set hit ""
        if {$tag ne ""} {
            set snippet ""
            if {[dict exists $PeekByTag $tag]} {
                set snippet [lindex [dict get $PeekByTag $tag] 1]
            }
            set hit [dict create lineoff $lineoff snippet $snippet]
        }
        my populate_child_menu $hit
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
            # The child's own total (for its "N more matches" overflow line); its
            # shown snippets are capped at $cap, its count is not.
            my cset $cp count [expr {[my cget_field $cp count 0] + 1}]
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
        # Reseat the below-header block from the current totals: the case-B note
        # then the matched subagents, in that order. A whole-block redraw (not an
        # incremental child append) keeps the note above the children and lets its
        # "N matches in a subagent/subagents" wording track each arriving child.
        if {[my sflag $parent rendered]} {
            if {[my node_field [my sid $parent] expanded]} {
                my redraw_sub_block $parent
            }
            my redraw_header $parent
        }
    }

    # Redraw a session's below-header content that depends on subagent totals: the
    # case-B "no direct match" note and the matched subagent rows, under the
    # header and above nothing else. Cheap - a session has few subagents. The
    # parent's own match snippets (case C) sit above this block and are untouched.
    method redraw_sub_block {path} {
        if {![my sflag $path rendered]} return
        my detach_session_children $path
        my clear_subhint $path
        my render_subhint $path
        my render_children $path
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
                ah {
                    # Machine time over human time: how many multiples of the
                    # user's composing the machine worked. One decimal below 10
                    # (3.5), whole from 10 up (12). Blank until both figures
                    # exist and human time is above zero, so an unscanned or
                    # empty session shows nothing rather than a bare number.
                    set h [dict getdef $s human_secs ""]
                    set m [dict getdef $s duration_secs ""]
                    if {$h eq "" || $m eq "" || $h <= 0} {
                        set v ""
                    } else {
                        set r [expr {double($m) / $h}]
                        set v [expr {$r < 10 ? [format %.1f $r] : round($r)}]
                    }
                }
                context {
                    set p [dict getdef $s context_pct ""]
                    set v [expr {$p ne "" ? "$p%" : ""}]
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
            ah {
                set h [dict getdef $s human_secs ""]
                set m [dict getdef $s duration_secs ""]
                if {$h eq "" || $m eq "" || $h <= 0} { return -1 }
                return [expr {double($m) / $h}]
            }
            context {
                set v [dict getdef $s context_pct ""]
                if {$v eq ""} { return -1 }
                return $v
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
        set slug [dict get $s slug]
        set count [dict get $s count]
        set subt  [dict get $s sub_total]
        # Match-count tail: direct matches, plus a "+N in subagent(s)" pip when the
        # session's subagents also matched (case C). The case-B "no direct match"
        # note is not a tail here: with no hit of its own the parent surfaces on
        # its subagents alone, and the note is its own line below the row
        # (render_subhint), so it does not eat the preview's room.
        set count_str ""
        if {$count > 0} {
            set count_str "   ·   $count [expr {$count == 1 ? {match} : {matches}}]"
            if {$subt > 0} {
                append count_str "   ·   +$subt in\
                    [expr {$subt == 1 ? {subagent} : {subagents}}]"
            }
        }
        # Only its subagents matched: the row still carries the session, dimmed, so
        # the eye reads it as context for the hits below rather than a hit itself.
        set only_in_subs [expr {$count == 0 && $subt > 0}]

        set tags [list]
        set subj ""
        # Every session title starts at the same x. The chevron sits in a fixed
        # left gutter, then a tab sends the slug to the title stop apply_column_tabs
        # adds to the sessionhead tabs - the same column-tab mechanism the
        # right-pinned metadata uses. The running/bookmark status glyphs are no
        # longer laid here: the engine prefixes them ahead of this subject (its
        # attr-running / attr-bookmarked tags), so this method draws only the
        # chevron and the title. Only a present chevron is drawn, so a plain gutter
        # shows nothing and the title still lands on the stop. The chevron is the
        # only marker click_on_chevron tests, so a plain gutter has no chevron tag
        # and a click in it just opens the session.
        if {[dict get $s has_subagents]} {
            lappend tags [list chevron [string length $subj] 1]
            append subj [expr {[my node_field $node expanded] ? "▾" : "▸"}]
            append subj " "
        }
        append subj "\t"
        set title_off [string length $subj]
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
        # Dim the title run (slug and preview, past the marker gutter) when only
        # the subagents matched; the running/bookmark glyphs keep their own colour.
        if {$only_in_subs} {
            lappend tags [list dimmed $title_off [expr {[string length $subj] - $title_off}]]
        }
        return [dict create subject $subj tags $tags meta_run 1]
    }

    method session_bookmarked {path} {
        if {[my has_session $path]} { return [my sget $path bookmarked 0] }
        return [file executable $path]
    }

    # Rewrite a session header line in place (glyphs, count). Leaves the
    # surrounding lines untouched, so a per-tick glyph refresh never shifts
    # the view.
    method redraw_header {path} {
        # item rewrites the session line in place, re-pinning the right-gravity
        # start mark; the selection re-paint rides on_row_rendered's wiring being
        # untouched, so re-add the selection tag here.
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
    # bold/tier tags come from cell_tag. The subject tags only its leading marker
    # (the foldchevron range), so a Button-1 on the marker can be told from one on
    # the label: the marker toggles expand/collapse, the label selects the folder.
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
        return [dict create subject "$marker $label$count_str" \
                    tags [list [list foldchevron 0 1]] meta_run 0]
    }

    method redraw_folder_heading {folder} {
        if {![my has_folder $folder]} return
        # item rewrites the heading line in place; a detached folder is
        # unrendered, so item no-ops and the detached case guards itself.
        my item [my fid $folder]
        # item drops every tag on the re-laid line, including the folder selection
        # highlight; re-add it from membership, the way redraw_header does.
        if {[my is_folder_selected $folder]} {
            set fm [my node_field [my fid $folder] start]
            $Text tag add selected $fm "$fm lineend"
        }
    }

    # ---- folder click, selection and menu ----------------------------
    #
    # A folder heading is selectable like a session row, but its state lives
    # apart from the path-keyed session selection: a folder is name-keyed, so it
    # cannot join SelectedSet. There is one highlighted folder at a time, held in
    # SelectedFolder, and it and the session selection are mutually exclusive (one
    # selection model). The highlight reuses the session `selected` tag over the
    # heading line; re-lays reapply it from membership (on_row_rendered and
    # redraw_folder_heading above).

    method on_folder_click {folder X Y} {
        if {[my click_on_tag $X $Y foldchevron]} {
            my toggle_folder $folder
            return
        }
        my folder_select $folder
    }

    method is_folder_selected {folder} { return [expr {$SelectedFolder eq $folder}] }

    method folder_select {folder} {
        if {![my has_folder $folder]} return
        # Drop any session selection first; set_selection also clears a prior
        # folder highlight (clear_folder_selection), so SelectedFolder is empty
        # before this folder claims it.
        my set_selection [list]
        set SelectAnchor ""
        set SelectedFolder $folder
        set fid [my fid $folder]
        if {[my node_field $fid rendered]} {
            set fm [my node_field $fid start]
            $Text tag add selected $fm "$fm lineend"
        }
    }

    method clear_folder_selection {} {
        if {$SelectedFolder eq ""} return
        if {[my has_folder $SelectedFolder]} {
            set fid [my fid $SelectedFolder]
            if {[my node_field $fid rendered]} {
                set fm [my node_field $fid start]
                catch {$Text tag remove selected $fm "$fm lineend"}
            }
        }
        set SelectedFolder ""
    }

    # The folder heading's right-click menu. Kept small and folder-shaped (a
    # scope action and a reveal), not the session action set, which is built for
    # a session target. Reveal opens the project's real working directory; a
    # folder whose directory is gone resolves to "" and the entry greys out.
    method build_folder_menu {} {
        set FMenu $Top.fmenu
        menu $FMenu -tearoff 0
    }

    method on_folder_right {folder X Y} {
        if {![my has_folder $folder]} return
        my folder_select $folder
        set cwd [{*}$ResolveFolder $folder]
        $FMenu delete 0 end
        $FMenu add command -label "Search within this folder" \
            -command [list [self] folder_scope $folder] \
            -state [expr {$OnScopeFolder eq "" ? "disabled" : "normal"}]
        $FMenu add command -label "Reveal folder" \
            -command [list [self] folder_reveal $folder] \
            -state [expr {$cwd eq "" ? "disabled" : "normal"}]
        tk_popup $FMenu $X $Y
    }

    method folder_scope {folder} {
        if {$OnScopeFolder eq ""} return
        {*}$OnScopeFolder $folder
    }

    method folder_reveal {folder} {
        set cwd [{*}$ResolveFolder $folder]
        if {$cwd eq ""} return
        set opener [expr {$::tcl_platform(os) eq "Darwin" ? "open" : "xdg-open"}]
        if {[catch {exec $opener $cwd &} err]} {
            puts stderr "questlog: $opener failed: $err"
        }
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

    # True while a filter is narrowing the view, so some loaded sessions may be
    # hidden. When none is, the model count is exact and the per-session walk
    # below is skipped. Every filter counts, the model filter included: it hides
    # loaded rows exactly as the other two do, and a folder whose rows it all
    # hides must not go on reporting them.
    method any_view_toggle {} {
        return [expr {[llength [::questlog::listfilter::active_filters [my attr_filter_all]]] > 0}]
    }

    # A row that arrives while a filter is on lands hidden, and the folder created
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
        my refresh_filter_note
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
    # Their reveal-registry entries go with them.
    method sweep_loose_tags {} {
        foreach tg [$Text tag names] {
            if {([string match "n#*" $tg] || [string match "c#*" $tg]) \
                && [llength [$Text tag ranges $tg]] == 0} {
                $Text tag delete $tg
                dict unset PeekByTag $tg
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
        my sset $path own_context_pct [dict getdef $cost_dict context_pct ""]
        # The token counts and per-model split are own-session values with no
        # subagent aggregation; store them from the same cost arrival that
        # Scan.update_cost writes into Rows, so the payload copy stays level
        # with Rows for a session question that reads them.
        my sset $path input_tokens [dict getdef $cost_dict input_tokens ""]
        my sset $path output_tokens [dict getdef $cost_dict output_tokens ""]
        my sset $path cache_write_tokens [dict getdef $cost_dict cache_write_tokens ""]
        my sset $path cache_read_tokens [dict getdef $cost_dict cache_read_tokens ""]
        my sset $path model_breakdown [dict getdef $cost_dict model_breakdown ""]

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
        # The worker result can change cost-, turns-, duration-, A/H- or
        # context-sorted order.
        if {$SortKey in {cost turns duration ah context}} { my schedule_resort }
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
        my cset $cp context_pct [dict getdef $cost_dict context_pct ""]
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
            # The worker result can change cost-, turns-, duration-, A/H- or
            # context-sorted order.
            if {$SortKey in {cost turns duration ah context}} { my schedule_resort }
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
        # Model and context occupancy are the session's own, never summed: a
        # parent shows the model it ran on and how full its own window is, not
        # its subagents'.
        my sset $path model [dict getdef $s own_model ""]
        my sset $path context_pct [dict getdef $s own_context_pct ""]
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
        # A session selection and a folder selection are mutually exclusive; any
        # gesture that sets the session selection drops the folder highlight.
        my clear_folder_selection
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

    # Opening a session lands at its start unless the caller names a line: the
    # deep links that know a match (a snippet click, the menu's Open at this
    # match) pass its lineoff, and every general "open" verb reads from the top.
    method open_session {path {lineno 0}} {
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
        # A plain click on a search result lands at the session start, not at its
        # first match; the matches are reached through the snippet rows and the
        # viewer index. Anchoring to a hit is reserved for the two deliberate
        # deep-link gestures (a snippet click, the menu's "Open at this match").
        my open_session $path 0
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

    # Hovering a snippet (or a subagent header) both swaps the cursor to the hand
    # and reveals the row's full text on the app's bottom strip. The rendered row
    # is clipped at the list column's right edge (-wrap none); $text is the
    # model's full stored snippet (itself a lead/trail window around the hit),
    # captured when the row was wired, so the reader sees the trailing context
    # past the edge without opening the session. $kind
    # is the badge word (tool_use, name, an agent type) and leads the reveal when
    # present, so the strip reads e.g. "tool_use · <full line>". <Leave> restores
    # the strip's standing text. No-op reveal when the app wired no peek callback
    # (a bare SessionList in a test), so the cursor swap always stands alone.
    method peek_enter {kind text} {
        $Text configure -cursor hand2
        if {$OnStatusPeek eq ""} return
        if {$kind ne ""} { set text "$kind · $text" }
        {*}$OnStatusPeek $text
    }
    method peek_leave {} {
        $Text configure -cursor arrow
        if {$OnStatusUnpeek ne ""} { {*}$OnStatusUnpeek }
    }

    # Double the percents in data bound into a bind script. bind runs its
    # %-substitution over the script string before Tcl ever parses it, so a
    # spliced path or folder name holding a % is rewritten in place
    # ("100%pure" -> "100??ure"; [list] cannot help, it quotes for Tcl and
    # bind's pass runs first - issue #41). %% renders back to the literal %.
    # Free-text content does not get this treatment: it rides PeekByTag and
    # never enters a script at all. Machine-made splices (lineoff integers,
    # tag names, [self]) are %-free and stay bare.
    method pctsafe {v} { return [string map {% %%} $v] }

    # Wire a row tag's hover reveal. The bind script carries ONLY the
    # machine-made tag name, never the content: bind runs %-substitution over
    # its script at event time, and a snippet holding a % is corrupted in
    # place ("50% done" -> "50\\ done", "printf %s" -> the state field) - the
    # same splice bug issue #41 tracks for paths in menu binds. The content
    # waits in PeekByTag and is resolved when the event fires; a tag with no
    # entry (swept, or cleared by reset) still swaps the cursor and reveals
    # nothing.
    method peek_wire {tag kind text} {
        dict set PeekByTag $tag [list $kind $text]
        $Text tag bind $tag <Enter> [list [self] peek_enter_tag $tag]
        $Text tag bind $tag <Leave> [list [self] peek_leave]
    }
    method peek_enter_tag {tag} {
        if {![dict exists $PeekByTag $tag]} {
            $Text configure -cursor hand2
            return
        }
        lassign [dict get $PeekByTag $tag] kind text
        my peek_enter $kind $text
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

    # A right-click carrying a search hit ($hit is {lineoff snippet}) gains the
    # two match-specific entries and always acts on the one hit's session, so it
    # skips the multi-selection menu even when several rows are highlighted. A
    # header/row right-click passes no hit and behaves as before.
    method on_session_right {path X Y {hit ""}} {
        # A right-click on a row outside the current selection retargets the
        # selection to it (the menu then acts on what is highlighted). A click
        # on a member of a multi-selection keeps the set and shows the multi
        # menu - the actions that apply to many sessions at once.
        if {![my is_selected $path]} { my selection_set $path }
        if {$hit eq "" && [my selection_count] > 1} {
            my popup_multi_menu $X $Y
            return
        }
        set uuid [file rootname [file tail $path]]
        set folder ""
        set cwd ""
        if {[my has_session $path]} {
            set folder [my sget $path folder]
            set uuid [my sget $path uuid $uuid]
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
        # A hit adds the two match-specific entries: "Open at this match" reuses
        # the badge's left-click open (on_snippet_release), "Copy this snippet"
        # rides the clipboard. The snippet text was already resolved from the
        # registry into $hit; it travels inside the ctx dict, never a script.
        if {$hit ne ""} {
            dict set ctx hit $hit
            dict set ctx on_open_at [list [self] on_snippet_release]
        }
        set MenuIndices [::questlog::ui::session_actions::populate $Menu $ctx]
        ::questlog::ui::session_actions::apply_state \
            $Menu $MenuIndices [dict get $ctx state]
        tk_popup $Menu $X $Y
    }

    # The hit-aware right-click for a snippet row (parent snippet, name
    # breadcrumb, or badge). The numeric lineoff and the machine-made reveal tag
    # ride the bind script bare; the snippet's free text does not - it is
    # resolved here from the same PeekByTag entry peek_wire stored (issue #41:
    # free text in a bind script is %-corrupted). A missing entry (swept row)
    # leaves the snippet empty but still opens the match.
    method on_hit_right {path lineoff tag X Y} {
        set snippet ""
        if {[dict exists $PeekByTag $tag]} {
            set snippet [lindex [dict get $PeekByTag $tag] 1]
        }
        my on_session_right $path $X $Y \
            [dict create lineoff $lineoff snippet $snippet]
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
                    && ![::questlog::scope::row_subtree_match $row $subtree]} continue
                my model_add_session $path $row
                # Drawing is the dirty pass's job below: rebuild is
                # hidden-aware and creates the folder heading, which this
                # import cannot assume exists (under the running filter a folder
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
            # This path is modelled (checked at the loop head), so its scope
            # fields come from the store, not a Scan.Rows lookup.
            set row [my payload_scope_row $path]
            # Retain in the model: a matched search row always; a browse row while it is
            # in scope or running. An out-of-scope, non-running browse row leaves.
            if {$CriteriaActive} {
                set retained 1
            } else {
                # The subtree scope is hard; within it a running session bypasses the
                # recency / min-turns bounds (it always surfaces), but a running
                # session OUTSIDE the subtree scope does not.
                set in_subtree [expr {[llength $subtree] == 0 || $row eq "" \
                    || [::questlog::scope::row_subtree_match $row $subtree]}]
                # A session the reader pulled in through the cut banner stays,
                # whatever the scope says: they named it and asked for it, and
                # dropping it on the next tick would answer them by taking it away.
                set retained [expr {[dict exists $Pinned $path] || ($in_subtree \
                    && (($row ne "" && [my row_matches_snapshot $row]) || $is_running))}]
            }
            if {!$retained} { my forget_session $path; continue }
            set now_hidden [expr {![my attr_admits [my sid $path]]}]
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
        set running_changed [expr {[lsort [dict keys $running]] \
                                   ne [lsort [dict keys $PrevRunning]]}]
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
        # A change in the running set changes the `running` attribute's value on
        # the rows that flipped, so when the engine's running filter is on its
        # picture of the rows has gone stale: re-apply the attribute filters
        # against the fresh set, which re-lays the list. A session that stopped
        # while "running only" is on drops out; one that started shows. Gated on
        # the membership actually moving, because the poll fires every couple of
        # seconds and an unconditional re-apply would rebuild the list on every
        # tick for nothing.
        if {$running_changed && [my attr_filter_get running]} {
            my apply_attr_filters
        }
        # The loaded set and the running set have both just settled, so this is
        # where the filter's cut is recounted: every tick, and every filter change
        # that routes through here.
        my refresh_filter_note
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
        # A bookmark toggle flips the file's +x bit and then calls here to
        # redraw the one row's marker. The marker is drawn from the payload's
        # bookmarked field (session_bookmarked), so refresh it from the bit
        # before the redraw: this is the store-side counterpart of Scan's
        # set_bookmark_field keeping Rows fresh, and it is what lets the glyph
        # follow a toggle without a re-scan.
        my sset $path bookmarked [file executable $path]
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
        # The session's own size and cost move with it; capture them and the
        # source folder before the node is re-keyed and reparented, so the two
        # folders' aggregates can be settled below.
        set src_fid [my node_field $sid parent]
        set src_folder [my node_field $src_fid key]
        set size [my node_pget $sid size 0]
        set cost [my node_pget $sid cost]
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
        # Carry the aggregates across: the destination gains the session's size,
        # cost and one to its count; the source loses them, or is dropped whole
        # when the move emptied it (the same rule forget_session applies). Cost
        # stays in TotalCost throughout - the session left neither folder's app,
        # only its heading.
        my fset $new_folder size [expr {[my fget $new_folder size 0] + $size}]
        my bump_folder_count $new_folder 1
        if {$cost ne "" && $cost > 0} { my bump_folder_cost $new_folder $cost }
        if {[llength [my node_field $src_fid children]] == 0} {
            my forget_folder $src_folder
        } else {
            my fset $src_folder size [expr {[my fget $src_folder size 0] - $size}]
            my bump_folder_count $src_folder -1
            if {$cost ne "" && $cost > 0} { my bump_folder_cost $src_folder [expr {-$cost}] }
        }
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

    # ---- the filter cut ----------------------------------------------
    #
    # A filter shows a subset of the rows the SEARCH loaded, so a session that
    # genuinely belongs to the filter but that the search never read is invisible.
    # Running is the case that bites: a session burning tokens right now, outside
    # the time window, is not in the list, and an unqualified "1 session" tells
    # the reader nothing else is running. The cure is not to let the filter read
    # disk (that would make it a search, and a search drops the selection): it is
    # to count what the filter is missing and say so, and to let the reader ask for
    # the missing session by name.
    #
    # The membership comes from outside the search and is pushed in by the poll
    # (set_filter_members): the live registry for Running, which knows every session
    # running on this machine whatever the window was, and a bookmark sweep for
    # Bookmarked. filter_cut in lib/listfilter.tcl does the arithmetic; the status
    # line says the cut, and the banner names it and offers the two escapes.

    # The membership the active filters claim, uuid -> {path ?cwd?}, as the caller
    # gathered it outside the search: with both filters on it is the intersection of
    # the two sets, so every uuid here is a session the list would show. A running
    # member carries the cwd its process runs in, which the registry knows for
    # free; a bookmarked one carries none, because finding it would mean reading a
    # transcript on a path that must not (member_name resolves what it needs, when
    # it needs it). Recounts the cut; the filters themselves are not touched, so
    # this can arrive on any tick without disturbing the view.
    method set_filter_members {members} {
        set FilterMembers $members
        my refresh_filter_note
    }

    # Recount the active filters against their membership: the status line's clause,
    # the cut members the banner names, and the criterion it offers to relax. With
    # no filter on, or none that has a membership (the model filter has none: a
    # row's model is known only once its transcript is parsed), nothing is claimed.
    #
    # `shown` is the loaded session nodes the engine admits, counted through the one
    # evaluator (attr_admits) over the node store - what the list is holding and the
    # filters admit, which is not the rows on screen (a folded folder's rows count
    # and are not painted, and folding is the reader's own business). `total` is the
    # membership size; the cut (filter_cut) is the members no loaded node carries.
    method refresh_filter_note {} {
        set state [my attr_filter_all]
        set filters [::questlog::listfilter::member_filters $state]
        if {![llength $filters] || ![dict size $FilterMembers]} { my drop_filter_note; return }
        set shown 0
        set loaded [dict create]
        foreach path [my all_session_paths] {
            dict set loaded [my sget $path uuid] 1
            if {[my attr_admits [my sid $path]]} { incr shown }
        }
        set FilterNote "[my filter_phrase $filters] · showing $shown\
            of [dict size $FilterMembers]"
        set CutMembers [list]
        foreach uuid [::questlog::listfilter::filter_cut $state $loaded $FilterMembers] {
            set m [dict get $FilterMembers $uuid]
            dict set m resolved [my member_file $m]
            lappend CutMembers $m
        }
        set CutReason ""
        if {[llength $CutMembers]} {
            # "criteria", not "search": the time window, the folder scope or the
            # min-turns floor can be what cut a member, and the banner's next
            # sentence names which one - so the clause must not claim the search did.
            append FilterNote " · [llength $CutMembers] outside your criteria"
            set CutReason [my cut_reason [lindex $CutMembers 0]]
        }
        my refresh_status
        my refresh_cut_banner
    }

    method drop_filter_note {} {
        set FilterNote ""
        set CutMembers [list]
        set CutReason ""
        my refresh_status
        my refresh_cut_banner
    }

    # The filters in words: "Running", "Bookmarked", or "Running and Bookmarked"
    # when both are on. The conjunction is the honest word for what is on screen -
    # a row must be running AND bookmarked to pass both filters - and it is what the
    # counts beside it are measured against: the membership is the intersection of
    # the two sets, so a running session that carries no bookmark is neither shown
    # nor counted as something the search withheld. Naming one filter and dropping
    # the other would put a count from one sentence under the heading of another.
    # The status line takes the phrase as it stands and the banner lowercases it
    # into the adjective on "session", so the two lines cannot name different filters.
    method filter_phrase {filters} {
        return [join [lmap f $filters {string totitle $f}] " and "]
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
        if {[::questlog::scope::cutoff_for $Snapshot] > 0} { return since }
        if {[dict getdef $Snapshot min_turns 1] > 1} { return min_turns }
        return unloaded
    }

    # Is the member inside the folder scope? The live registry records the cwd the
    # session runs in, which answers it outright; a member with no cwd (a bookmark
    # sweep records none) falls back to its row if the model has one, and finally
    # to its encoded folder name, the same evidence the scanner's walk uses.
    method member_in_subtree {member subtree} {
        set cwd [dict getdef $member cwd ""]
        if {$cwd ne ""} { return [::questlog::scope::in_subtree_of $cwd $subtree] }
        set path [dict get $member path]
        if {[my has_session $path]} {
            return [::questlog::scope::row_subtree_match \
                        [my payload_scope_row $path] $subtree]
        }
        return [::questlog::scope::folder_subtree_candidate \
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
    # happens to know (a bookmarked row loaded under another filter) is named by its
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
        set noun [string tolower \
            [my filter_phrase [::questlog::listfilter::member_filters [my attr_filter_all]]]]
        set it [expr {$n == 1 ? "it" : "them"}]
        set names [list]
        foreach m [lrange $CutMembers 0 1] { lappend names [my member_name $m] }
        set who [join $names ", "]
        if {$n > [llength $names]} {
            append who " and [expr {$n - [llength $names]}] more"
        }
        $b.msg configure -text "$n $noun session[expr {$n == 1 ? {} : {s}}]\
            outside your criteria: $who. [my reason_phrase $CutReason $it]"
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
    # not put it back out of scope, and drawn in its folder. The filter is not
    # touched and needs no exemption: a running session admitted under the Running
    # filter passes attr_admits on its own.
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
        # folder from the store, so the new row lands in its place under the filter
        # rather than being appended past the list's end.
        if {$added} { my rebuild }
        my refresh_filter_note
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
        set Busy 1
        my sync_cancel
        set StatusBase "Searching … $done / $total sessions   matches: $matches"
        my refresh_status
    }
    method set_done {total matches} {
        set Busy 0
        my sync_cancel
        if {$matches == 0} {
            set StatusBase "Done. $total sessions, no matches."
        } else {
            set StatusBase "Done. $total sessions, $matches matches."
        }
        # The result set is final, so the filter's shown count is too: recount it
        # here rather than leave the status line a poll tick behind the answer.
        my refresh_filter_note
    }
    method cancel {} {
        # Nothing in flight, nothing to cancel: leave the standing line alone. The
        # button rests disabled off Busy, so this is the belt to that suspenders.
        if {!$Busy} return
        set Busy 0
        my sync_cancel
        if {$CancelCb ne ""} { {*}$CancelCb }
        set StatusBase "Cancelled."
        my refresh_status
    }

    # Follow the Busy flag onto the Cancel button: live while a search runs, greyed
    # otherwise. Guarded so it is safe before build (a test may drive the status
    # methods without the widgets).
    method sync_cancel {} {
        set b $Top.bar.cancel
        if {![winfo exists $b]} return
        $b configure -state [expr {$Busy ? "normal" : "disabled"}]
    }

    # Recompute the visible status string: what the list is doing, what the active
    # filter is showing out of what it holds, and what it all cost. Each clause is
    # omitted when it has nothing to say - a zero total would read as a misleading
    # "$0.00" aggregate, and a list under no filter is showing everything it loaded -
    # so the bullets only ever separate clauses that are there.
    method refresh_status {} {
        set parts [list]
        if {$StatusBase ne ""} { lappend parts $StatusBase }
        if {$FilterNote ne ""} { lappend parts $FilterNote }
        if {$TotalCost > 0} {
            # While a search is still landing, the total is provisional: mark it
            # "and counting…" so a mid-flight figure does not read as the final
            # tally. Cleared the moment set_done/cancel drops Busy.
            set cost [::questlog::cost::format_usd $TotalCost]
            if {$Busy} { append cost " and counting…" }
            lappend parts $cost
        }
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
        if {$bytes < 1048576}     { return "[expr {$bytes / 1024}] KB" }
        if {$bytes < 1073741824}  { return "[format %.1f [expr {$bytes / 1048576.0}]] MB" }
        return "[format %.1f [expr {$bytes / 1073741824.0}]] GB"
    }
}
