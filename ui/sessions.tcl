package require Tcl 9
package require Tk

# MODEL_ANY is the word the model filter carries when no model is chosen
# (read by the strip's model control for its rest label).
namespace eval ::questlog::ui {
    variable GLYPH_RUNNING  ●
    variable GLYPH_BOOKMARK ★
    variable GLYPH_ACTIONS  ⋯
    variable GLYPH_GONE     †     ;# a folder whose directory no longer exists
    variable MODEL_ANY "any model"
}

# The one place that decides which columns appear, their order, the header
# label, the width sample, the alignment, and whether the header sorts. Each
# row is {id label sample align sortable}.
#
# The row reads subject-on-the-left, metadata right-pinned: the subject (glyphs,
# slug, preview) fills from the left and the columns below sit in a
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
# a StreamTree (the generic tree-in-a-text-widget base class) specialised for
# the session domain: a folder holds the folders and sessions beneath its
# directory, a session holds its subagents. A folder's node sits under the
# folder whose directory most closely contains its own (ensure_folder), so a
# project's subdirectories nest under it, a corpus of unrelated directories is
# a row of roots, and a folder whose directory is gone hangs under its nearest
# living ancestor. SessionList supplies the content, the ordering and what a
# heading adds up to through the base class's hooks (column_spec,
# render_subject, cell_values, cell_tag, sort_key, kind_rank, aggregate_seed
# and aggregate_add) and owns the session-specific interaction, a session's
# subagent cost roll-up, menus, rename, search snippets, and reconcile.
#
# Layout, top to bottom, as tagged regions in the one text widget:
#   folder heading   - the project label, a drop target for moves
#   session header   - glyphs, label, time; its hover names the matched subagents
#   snippet rows     - up to three per session: a block-type label and a
#                      hit-leading snippet with the matched term in bold
#
# Two display states share the widget. With no criteria it browses: every
# session that passes the snapshot filter appears as a header, grouped by
# folder. With criteria it indexes: only matching sessions appear, each with
# its snippets. A single click opens the session in the docked viewer and
# anchors it to the relevant line.
#
# The base class draws each node into the widget with two marks (node.start at
# its first char, node.end at the append point past its last descendant) and a
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
    # Shared with the StreamTree base class (same per-object variables): the widget
    # refs, the node store, the column geometry and the sort state.
    variable Top
    variable Text
    variable Nodes
    variable Roots
    variable NextId
    variable ColTabs
    variable ColGap
    variable SubjectMax
    variable LabelMax
    variable LayoutW
    variable RelayoutPending
    variable SortKey
    variable SortDir
    variable ResortTimer
    variable StatusVar
    variable CancelCb
    variable ResolveFolder    ;# cb: folder -> display cwd; opens no transcript
    variable OnOpen           ;# cb: path lineno -> open + anchor in viewer
    variable OnMoveRequest    ;# cb: paths -> open move picker
    variable OnDropMove       ;# cb: paths folder -> direct move
    variable OnBookmarkToggle ;# cb: path -> flip the +x bookmark bit
    variable OnBookmarkSet    ;# cb: paths -> flip the +x bit across a selection
    variable OnRename         ;# cb: path -> app rename router (dialog + apply + refresh)
    variable OnScanPath       ;# cb: path -> row (synchronous single-file scan)
    variable OnWiden          ;# cb: criterion -> relax it in the toolbar and republish
    variable OnFolderBound    ;# cb: folder -> bound the toolbar search to that folder, or ""
    variable OnFilterChange   ;# cb: state -> the app learns a strip filter changed, or ""
    variable Snapshot
    variable RunningSet       ;# dict uuid -> 1, replaced wholesale each tick
    variable PrevRunning      ;# the prior tick's running set, to redraw only the rows that flipped
    variable FilterMembers    ;# dict uuid -> {path ?cwd?}: what the active filters jointly claim
    variable FilterNote       ;# the status line's filter clause, "" when no filter or no membership
    variable CutMembers       ;# the members with no loaded row, as {path ?cwd? resolved} dicts
    variable CutReason        ;# the criterion that cut them: subtree|search|since|""
    variable Pinned           ;# dict sid -> 1: sessions the reader pulled in past the search
    variable ViewRebuildTimer ;# after-id of the debounced hidden-aware rebuild, or ""
    variable DirtyHeadings    ;# dict folder -> 1: headings whose aggregates moved
                              ;# during the open batch, redrawn once at its close
    variable TurnsView        ;# the toolbar's turns floor as a view filter: a
                              ;# session with nturns below it is hidden, never
                              ;# excluded - it stays stored, priced and counted
    variable Query            ;# {terms <list> nocase 0|1} for hit highlighting
    variable LineGeo          ;# line kind tag -> {indent above below}, px
    variable ContentCol       ;# a snippet's content tab stop at the root
    variable Guides           ;# {width height folders} -> depth-guide photo
    variable HitTags
    # Domain indices into the node store: a folder name or a session/subagent
    # path to its node id.
    variable FolderNode       ;# folder name -> node id
    variable PathNode         ;# session path OR subagent path -> node id
    variable SelectedSet      ;# ordered set (dict sid->1) of selected sessions
    variable SelectAnchor     ;# sid a Shift-range extends from, or ""
    variable DoubleRelease    ;# 1 while a double-click's own release is pending
    variable SelectedFolder   ;# fid whose heading is highlighted, or ""
    variable FMenu            ;# the folder-heading right-click menu
    variable Menu
    variable MenuPath
    variable MenuTarget
    variable CMenu            ;# the reduced right-click menu for subagent child rows
    variable ChildMenuPath    ;# child path the child menu acts on
    variable MenuIndices      ;# entry indices returned by session_actions::populate
    variable StatusBase       ;# last text set by set_progress/set_done
    variable Busy             ;# 1 while a search is in flight (set_progress..set_done/cancel)
    variable ScanBusy         ;# 1 while the corpus scan is in flight (scan_begin..scan_end)
    variable OnSubagents      ;# cb: parent path -> list of child row dicts
    variable OnSubagentCost   ;# cb: child path -> start the cost pass for it
    variable PeekByTag        ;# dict: row tag -> {kind text cursor sub}; hover reveal and hit menu resolve from it at event time
    variable HeaderPeek       ;# the column id the pointer last rested over in the header, or ""

    # on_widen is optional: without it the cut banner still names what the search
    # left behind and still offers to load it (that is this object's own doing),
    # and only the widen escape - which relaxes a toolbar criterion, and so needs
    # the toolbar - is absent.
    constructor {parent resolve_cb on_open on_move_request \
                 on_drop_move on_bookmark_toggle on_bookmark_set on_rename \
                 on_scan_path cancel_cb \
                 on_subagents on_subagent_cost \
                 {on_widen ""} \
                 {on_folder_bound ""} {on_filter_change ""}} {
        set Top $parent
        set ResolveFolder $resolve_cb
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
        set OnFolderBound $on_folder_bound
        set OnFilterChange $on_filter_change
        set PeekByTag [dict create]
        set HeaderPeek ""
        set StatusVar "Idle"
        set StatusBase ""
        set Busy 0
        set ScanBusy 0
        set Snapshot [dict create]
        set RunningSet [dict create]
        set PrevRunning [dict create]
        set FilterMembers [dict create]
        set FilterNote ""
        set CutMembers [list]
        set CutReason ""
        set Pinned [dict create]
        set ViewRebuildTimer ""
        set DirtyHeadings [dict create]
        set TurnsView 1
        set Query [dict create terms [list] nocase 0]
        set SelectedSet [dict create]
        set SelectAnchor ""
        set DoubleRelease 0
        set SelectedFolder ""
        set NextId 0
        # Default sort reproduces the streaming order (mtime descending), so a
        # fresh list looks exactly as before any header is clicked.
        set SortKey "date"
        set SortDir "desc"
        set ResortTimer ""
        set LayoutW 0
        set RelayoutPending 0
        # Bind the base class to this app's look and host services: the list and
        # heading fonts, the theme colours its header strip uses, the streamed-
        # resort debounce from config, and the drag-to-move motion handler. These
        # are the only app-specific values the otherwise self-contained StreamTree
        # base class needs; it carries no reference to them itself.
        my configure -listfont QLList -headfont QLBold \
            -colours [dict create \
                strip [::questlog::ui::theme::c strip] \
                muted [::questlog::ui::theme::c muted] \
                ink   [::questlog::ui::theme::c ink]] \
            -resortdelay [::questlog::config::get resort_debounce_ms] \
            -motioncb {::questlog::ui::drag::motion %X %Y} \
            -cursorcb [list [self] on_cursor]
        # The three list-view filters declared to the base class, which renders the
        # running/bookmarked glyphs (trailing the subject, per-attribute tag attr-<id>)
        # and builds the strip filter controls. attr_value below answers running
        # from the live set, bookmarked from the row, model from the row label;
        # loaded_models provides the enum roster (hidden rows included). The
        # controls' colours ride LV.* styles so they sit on the strip band; the
        # popover keeps the stock look off the strip. A change fires on_filter_change.
        my configure \
            -attrs [list \
                [dict create id running label "running only" kind bool \
                    glyph $::questlog::ui::GLYPH_RUNNING place trail filterable 1] \
                [dict create id bookmarked label "bookmarked only" kind bool \
                    glyph $::questlog::ui::GLYPH_BOOKMARK place trail filterable 1] \
                [dict create id model label $::questlog::ui::MODEL_ANY kind enum \
                    filterable 1 values [list [self] loaded_models]]] \
            -attrstyles [dict create \
                check LV.TCheckbutton menu LV.TMenubutton \
                popcheck LV.TCheckbutton popbtn LV.TButton popframe LVStrip.TFrame] \
            -attrfiltercb [list [self] on_filter_change]
        my reset_nodes
        my build
        bind $Top.body.hdr <Leave> [list [self] header_peek ""]
    }

    # Hovering the A/H heading reveals what the ratio is and the human-gap rule
    # behind its denominator, values in force included, so the reader meets the
    # rule where they meet the figure. The base class's handler sets the cursor;
    # this one finds the column under the pointer (the zones on_header_click
    # reads) and moves the reveal only on crossing a zone edge, since every
    # motion inside one would otherwise re-arm it.
    method on_header_motion {x} {
        next $x
        my header_peek [my column_at $x]
    }
    method header_peek {col} {
        if {$col eq $HeaderPeek} return
        set HeaderPeek $col
        if {$col ne "ah"} { ::questlog::ui::reveal::hide; return }
        ::questlog::ui::reveal::show "Machine time over human time. Human time:\
            [::questlog::cost::human_gap_rule]; the ⋯ menu sets both." A/H
    }

    # The session-domain indices are reverse-lookups into the base class's node
    # store, so they must be dropped exactly when the store is wiped. Bulk
    # store resets (init, and the buffer reset behind clear) do not fire the
    # per-node on_before_delete hook, so extend the store-wipe primitive itself
    # rather than each caller. The store, id allocation and payload accessors
    # live in the StreamTree base.
    method reset_nodes {} {
        next
        set FolderNode [dict create]
        set PathNode [dict create]
        # A wholesale clear can delete the hovered row out from under a parked
        # pointer; a reveal must not outlive its row, and Tk is not guaranteed
        # to synthesize the <Leave>.
        set PeekByTag [dict create]
        ::questlog::ui::reveal::hide
    }

    # ---- public payload accessors (white-box tests, and any caller that
    # wants a read-only snapshot of a row's domain dict) -----------------

    method session_payload {path} {
        if {![dict exists $PathNode $path]} { return "" }
        return [my node_payload [dict get $PathNode $path]]
    }
    # ---- domain invariant audit ----------------------------------------
    #
    # The whole-store consistency check over the session domain, the
    # counterpart to the base class's structural check_invariant (which guards the
    # marks). It returns a list of human-readable violation strings, empty when
    # clean, so a test asserts `check audit [$SL audit] {}` and the soak calls
    # it after every operation. Two invariants:
    #   (a) PathNode and the session/subagent nodes' key fields are a bijection,
    #       and FolderNode likewise over folder keys: every registered key
    #       resolves to a node carrying it, and every keyed node is registered
    #       under that key. The half-done move's fault - two nodes under one key -
    #       shows here as a node absent from its own reverse index.
    #   (b) no node's children list names a child twice, the fault that paints a
    #       row twice when sort_siblings maps a repeated key back through sid.
    #   (c) every folder sits under the folder whose directory most closely
    #       contains its own (a placeless one at the root), the shape
    #       ensure_folder builds and folder_after_leave keeps: a folder left at
    #       the root after its parent arrived, or under a parent whose last
    #       session left, shows here.
    #   (d) the mutable view-state sets (selection, pin, anchor, folder highlight)
    #       hold node ids that exist as nodes, never a path or basename a move
    #       mutates: a regression to path-keying lodges a string that is no node id
    #       and trips here.
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
        # (c) each folder hangs where its directory puts it. Two folders can
        # share a directory (one spelled through a symlink), so the parent is
        # checked by directory, not by id.
        foreach id [my all_node_ids] {
            if {[my node_field $id kind] ne "folder"} continue
            set want [my folder_parent_for [my node_pget $id dir]]
            set have [my node_field $id parent]
            if {$want ne $have && ($want eq "" || $have eq "" \
                    || [my node_pget $want dir] ne [my node_pget $have dir])} {
                lappend probs "folder [my node_field $id key] sits under '$have', its directory says '$want'"
            }
        }
        # (d) the mutable view-state sets are node-keyed: every id they hold is a
        # live node, so a move (which changes a path, not an id) strands none.
        foreach id [dict keys $SelectedSet] {
            if {![dict exists $Nodes $id]} { lappend probs "SelectedSet holds non-node $id" }
        }
        foreach id [dict keys $Pinned] {
            if {![dict exists $Nodes $id]} { lappend probs "Pinned holds non-node $id" }
        }
        if {$SelectAnchor ne "" && ![dict exists $Nodes $SelectAnchor]} {
            lappend probs "SelectAnchor is non-node $SelectAnchor"
        }
        if {$SelectedFolder ne "" && ![dict exists $Nodes $SelectedFolder]} {
            lappend probs "SelectedFolder is non-node $SelectedFolder"
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
    method has_folder {folder} { return [dict exists $FolderNode $folder] }

    # The store node holding this path, or "" when the store has never seen it.
    method session_node {path} {
        if {[dict exists $PathNode $path]} { return [dict get $PathNode $path] }
        return ""
    }

    # The mtime the store holds for a path, or "" when the store has never
    # seen it. This is Scan's differential-skip memory (the known_mtime
    # callback the app hands it): a path answering its live mtime is not
    # re-read, and an unknown or changed one streams in fresh.
    method stored_mtime {path} {
        set id [my session_node $path]
        if {$id eq ""} { return "" }
        # A full row answers its real mtime, so an unchanged corpus
        # re-extends without a disk read.
        return [my node_pget $id mtime 0]
    }

    # sid raises on a path the store has never seen: that is a caller error
    # here, not an empty node.
    method sid {path} {
        set id [my session_node $path]
        if {$id eq ""} { error "no session node for $path" }
        return $id
    }
    method fid {folder} { return [dict get $FolderNode $folder] }

    method sget {path key {dflt ""}} { my node_pget [my sid $path] $key $dflt }
    method sset {path key value} { my node_pset [my sid $path] $key $value }
    method sflag {path field} { my node_field [my sid $path] $field }
    method sflagset {path field value} { my node_set [my sid $path] $field $value }

    # ---- base-class lifecycle hooks ------------------------------------
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
        my pin_title_stop $id
        switch [my node_field $id kind] {
            folder {
                set htag [my node_field $id tag]
                set folder [my node_field $id key]
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
                dict unset FolderNode [my node_field $id key]
                if {$SelectedFolder eq $id} { set SelectedFolder "" }
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
        # (running, bookmarked, model) are the base class's own filter
        # controls, packed right. During the interim the toolbar still carries a
        # duplicate View row; a later stage removes it.
        ttk::frame $Top.lvt -style LVStrip.TFrame -padding {8 4}
        pack $Top.lvt -side top -fill x
        ttk::button $Top.lvt.expandall -text "expand all" -style LV.TButton \
            -takefocus 0 -command [list [self] expand_all_folders]
        pack $Top.lvt.expandall -side left
        # The base class fills the strip with a control per filterable attribute,
        # packed toward the right so they sit opposite expand-all.
        my build_filters $Top.lvt right

        # The base class assembles the body (header text, list text, scrollbar, the
        # <Configure> relayout hook, the selection suppression and TailMark);
        # the session-domain tags, sort header and menus go on top of it.
        my build_body
        # A click acts on the row under the pointer and usually opens it; the
        # panel would otherwise hang over the result until the pointer moved off
        # the row. Widget-level, so it fires whichever row tag handles the click.
        bind $Text <ButtonPress> +[list ::questlog::ui::reveal::hide]
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
        # Every line is one row: a subject is ellipsised before the right-pinned
        # metadata, and a match is clipped. Set on the widget, not per tag: under
        # the base class's `word`, Tk breaks a line before an embedded window
        # that follows text, whatever the line's tags say, so a match's badge
        # would drop to a line of its own.
        $Text configure -wrap none
        $Text tag configure folderhead \
            -font QLList -foreground [::questlog::ui::theme::c folder]
        # The status glyphs are attribute prefixes the base class renders (running,
        # bookmarked declared as glyphed bools); the base class tags each glyph
        # attr-<id>, and these dress the two glyphed attributes in their
        # theme colours.
        $Text tag configure attr-running    -foreground [::questlog::ui::theme::c attr_running]
        $Text tag configure attr-bookmarked -foreground [::questlog::ui::theme::c attr_bookmarked]
        # Session header: one line, the block's "title" (like a search result
        # heading). Its marker slot is one marker width in, where a sibling
        # folder's marker sits, so its title starts where that folder's label
        # does. The rows are separated by the gap
        # above each (LineGeo) and the bold title colour; no band. The
        # selected row gets a highlight for click feedback. The metadata
        # columns align on per-tag right tab stops (set by layout_columns), so
        # the line reads in the proportional QLList without a fixed-width crutch.
        $Text tag configure sessionhead -foreground [::questlog::ui::theme::c ink] \
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
        set badgecol [expr {$barcol + [font measure QLList "▏"] + 6}]
        set bpw [image width [::questlog::ui::theme::badge_pill system]]
        set ContentCol [expr {$badgecol + $bpw + 12}]
        $Text configure -tabs [list $ContentCol left]
        # A thin session-grouping spine runs in the gutter to the left of the
        # badge: every snippet line opens with a bar glyph, so the matches of one
        # session stack into one continuous rule (the design's MatchList left
        # guide). The badge (an embedded pill) follows the bar; content tabs to
        # the content column.
        $Text tag configure snippet -tabs [list $ContentCol left] \
            -font QLList -foreground [::questlog::ui::theme::c snippet]
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
        $Text tag configure childhead \
            -foreground [::questlog::ui::theme::c ink] -font QLList
        $Text tag configure childbar -foreground [::questlog::ui::theme::c snippet_guide]
        # A subagent's matched line, beneath its child row, indented past the
        # child so the hit reads at full width (its own line, not cramped into the
        # metadata strip). Same look as a parent snippet, one level deeper.
        $Text tag configure childsnip \
            -font QLList -foreground [::questlog::ui::theme::c snippet]
        # Each line kind's indent and the gaps above and below it. The line image
        # (line_image) carries all three, so a kind tag sets no margin or spacing;
        # -offset places the text inside the taller line, which centres it.
        set LineGeo [dict create \
            folderhead  {0 14 3} \
            sessionhead [list [my marker_w] 6 2] \
            childhead   {30 2 2} \
            snippet     [list $barcol 0 1] \
            childsnip   {40 0 1}]
        dict for {tag geo} $LineGeo {
            lassign $geo _ above below
            $Text tag configure $tag -offset [expr {($below - $above) / 2}]
        }
        set Guides [dict create]
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

    # ---- base-class hooks: columns and relayout ------------------------

    # The metadata columns (a base-class hook): id, label, width sample,
    # alignment, and whether the header sorts. The single home is session_columns.
    method column_spec {} { return [::questlog::ui::session_columns] }

    # The header label over the subject column (a base-class hook).
    method subject_label {} { return "Session" }

    # Pin the base class's freshly-computed tab stops onto the three
    # session-domain row tags, so folder headings, session headers and child
    # rows all align their metadata under the header (a base-class hook,
    # called from layout_columns).
    method apply_column_tabs {tabs} {
        # Session rows get a leading left tab stop for the title so every slug
        # aligns past the marker slot, chevron or none; folder and child rows
        # keep the plain metadata tabs. This reuses the same
        # column-tab mechanism the right-pinned metadata already rides on.
        #
        # The stops arrive already sane (positive, strictly increasing) from
        # layout_columns.
        $Text tag configure sessionhead -tabs [my session_tabs $tabs 0]
        $Text tag configure folderhead -tabs $tabs
        $Text tag configure childhead  -tabs $tabs
    }

    # A session row's stops: the leading title stop, shifted in by px for a
    # nested row, then the metadata stops. The title stop is added only when it
    # fits inside the first metadata stop; in a degenerate narrow layout it does
    # not fit and the slug just tabs to the first column (a build-time state,
    # replaced once the window maps).
    method session_tabs {tabs px} {
        set first [lindex $tabs 0]
        set title_x [expr {2 * [my marker_w] + $px}]
        if {$first ne "" && $title_x < $first} {
            return [list $title_x left {*}$tabs]
        }
        return $tabs
    }

    # A marker and its space: a folder label's offset from its marker, and so
    # one depth step and a session title's offset from its marker slot.
    method marker_w {} { return [font measure QLList "▸ "] }

    # ---- depth --------------------------------------------------------
    #
    # A row steps in by one marker width per folder between its own folder and
    # the root, so a nested folder's heading starts under its parent's label and
    # its rows under that. Every line leads with an image that is the line's
    # indent and its full height, gaps included, carrying a hairline at the
    # marker column of each folder above it. Only open folders have lines under
    # them, so each folder's rule runs unbroken from its heading to its last
    # line, and a folder's own sessions visibly hang off it rather than off the
    # subfolder listed above them.

    # Folders between a row's own folder and the root.
    method nesting {id} {
        set n 0
        foreach a [my ancestors $id] {
            if {[my node_field $a kind] eq "folder"} { incr n }
        }
        return [expr {[my node_field $id kind] eq "folder" ? $n : $n - 1}]
    }

    method indent_px {id} {
        return [expr {[my nesting $id] * [my marker_w]}]
    }

    # The image a line of kind tag `kindtag` leads with, the line owned by node
    # id (a row, or the session or subagent its loose content hangs under).
    method line_image {id kindtag {badge 0}} {
        lassign [dict get $LineGeo $kindtag] indent above below
        set w [expr {max(1, $indent + [my indent_px $id])}]
        set h [expr {[font metrics QLList -linespace] + $above + $below}]
        if {$badge} { set h [expr {max($h, [my badge_line_h])}] }
        set rules [expr {[my nesting $id] + ([my node_field $id kind] ne "folder")}]
        set key [list $w $h $rules]
        if {![dict exists $Guides $key]} {
            set img [image create photo -width $w -height $h]
            set half [expr {[font measure QLList "▸"] / 2}]
            for {set m 0} {$m < $rules} {incr m} {
                set x [expr {$m * [my marker_w] + $half}]
                if {$x < $w} {
                    $img put [::questlog::ui::theme::c snippet_guide] \
                        -to $x 0 [expr {$x + 1}] $h
                }
            }
            dict set Guides $key $img
        }
        return [dict get $Guides $key]
    }

    # The height of a line holding a type badge: the badge window, its padding
    # included, is taller than the list font. The probe is never mapped, and
    # lives outside the list so it is not taken for a badge.
    method badge_line_h {} {
        set b $Top.badgeprobe
        if {![winfo exists $b]} {
            label $b -image [::questlog::ui::theme::badge_pill system] \
                -compound center -text SYSTEM -font QLBold -borderwidth 0
        }
        return [expr {[winfo reqheight $b] + 2}]
    }

    # Base-class hook: a row leads with its line image.
    method row_image {id} {
        return [list -image [my line_image $id [my row_tags [my node_field $id kind]]]]
    }

    # A nested session's title stop moves in with its row, on the row's own tag
    # (a Tk tag's -tabs replaces rather than adds, so the kind tag's stops
    # cannot carry it). That tag outranks the kind tag by birth: every kind tag
    # was created at build, before any row.
    method pin_title_stop {id} {
        if {[my node_field $id kind] ne "session"} return
        set px [my indent_px $id]
        if {$px <= 0} return
        $Text tag configure [my node_field $id tag] -tabs [my session_tabs $ColTabs $px]
    }

    # Open a line of loose content under node owner: the append point, then the
    # line image under the line's own tag ntag and its kind tag. A snippet's
    # content stop moves in with the line.
    method line_open {owner ntag kindtag {badge 0}} {
        if {$kindtag eq "snippet"} {
            $Text tag configure $ntag \
                -tabs [list [expr {$ContentCol + [my indent_px $owner]}] left]
        }
        set m [my append_open $owner]
        lassign [my emit_image $m -image [my line_image $owner $kindtag $badge]] i0 i1
        $Text tag add $kindtag $i0 $i1
        $Text tag add $ntag $i0 $i1
        return $m
    }

    # Re-fit every rendered row's ellipsis after a width change (a base-class
    # hook, called from relayout inside the widget's normal state): each folder
    # heading, each rendered session header, and the children of an expanded
    # session. A nested session's title stop rides its own tag (pin_title_stop)
    # rather than the kind tag apply_column_tabs re-pinned, so it is re-pinned
    # here beside the redraw.
    method relayout_content {} {
        foreach id [my all_rendered_nodes] {
            switch [my node_field $id kind] {
                folder { my redraw_folder_heading [my node_field $id key] }
                session {
                    set path [my node_field $id key]
                    my pin_title_stop $id
                    my redraw_header $path
                    if {[my node_field $id expanded]} { my rerender_children $path }
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
        # A snapshot change wipes the store; the scan that follows re-streams
        # the new bounds from disk. The loose snippet/match tags the buffer
        # wipe leaves empty are swept after.
        my reset
        my sweep_loose_tags
        set SelectedSet [dict create]
        set SelectAnchor ""
        set SelectedFolder ""
        set StatusBase ""
        # The pinned sessions were pulled in past the old search; the new one
        # has its own answer. The filter membership survives, but its cut is
        # recounted only by the reconcile that follows the fill, so the banner
        # never flashes a cut that the new search does load.
        set Pinned [dict create]
        my drop_filter_note
        my refresh_status
    }

    method apply_filter {snapshot} {
        set Snapshot $snapshot
        set TurnsView [dict getdef $snapshot turns_view 1]
        # The arriving snapshot is search and bounds only; the base class owns
        # the filters and holds them across the change, so a refill honours a filter
        # still pressed on the strip with nothing here to re-graft.
        my clear
    }

    # The turns floor moved with everything else equal: re-derive every hidden
    # flag over the loaded rows and rebuild, no rescan. The floor is a view
    # key (ui/toolbar.tcl): a below-floor session stays in the store, priced,
    # and only its rendering is suppressed, so the grand total still sums the
    # whole window while a heading's figures narrow to what it shows.
    method set_turns_view {n} {
        set TurnsView $n
        my apply_attr_filters
    }

    # 1 unless a session node's recorded turn count sits below the view floor.
    # An empty nturns admits (a row that somehow lacks one, mirroring the CLI
    # bound's default); non-session nodes are never floored.
    method turns_admits {node} {
        if {$TurnsView <= 1} { return 1 }
        if {[my node_field $node kind] ne "session"} { return 1 }
        set nturns [my node_pget $node nturns]
        if {$nturns eq ""} { return 1 }
        return [expr {$nturns >= $TurnsView}]
    }

    # The one evaluator every hidden-flag derivation calls (the base class's
    # attribute filters and this class's seven call sites alike), so the turns
    # floor rides it rather than adding an eighth derivation.
    method attr_admits {node} {
        return [expr {[next $node] && [my turns_admits $node]}]
    }

    # Every distinct, non-empty model label in the list, sorted. Hidden rows
    # count: a row the model filter is hiding is exactly the row whose entry
    # must stay in the menu for the filter to be widened back off it. A row
    # whose cost pass has not landed has no label yet; the filter admits it.
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

    # ---- declarative-attribute hooks (the base class's filter and glyph facility) -

    # The value of a declared attribute on a node (a base-class hook). Only a
    # session answers: a folder or subagent returns "" for all three, so a
    # container is never glyphed and never filtered (a bool absent shows and
    # draws no mark, an enum empty always shows).
    method attr_value {node id} {
        if {[my node_field $node kind] ne "session"} { return "" }
        switch -- $id {
            running    { return [expr {[dict exists $RunningSet [file rootname [file tail [my node_field $node key]]]] ? 1 : 0}] }
            bookmarked { return [my session_bookmarked [my node_field $node key]] }
            model      { return [my node_pget $node model ""] }
            default    { return [my node_pget $node $id] }
        }
    }

    # Apply the base class's active attribute filters (a base-class method,
    # overridden). The base's hide/unhide ledger cannot compose with this list's
    # folder-drop rebuild: the base unhide would render a row back into a
    # folder heading render_skip no longer draws. So derive each session's
    # hidden flag from attr_admits and rebuild - hidden-aware, folder-aware,
    # selection and scroll kept.
    method apply_attr_filters {} {
        set st [$Text cget -state]
        $Text configure -state normal
        foreach path [my all_session_paths] {
            my sflagset $path hidden [expr {![my attr_admits [my sid $path]]}]
        }
        $Text configure -state $st
        my rebuild
    }

    # A strip filter moved (a base-class hook, -attrfiltercb): apply_attr_filters
    # (fired from attr_filter_set just before this) has already re-derived the
    # view and rebuilt. Recount the filter note off the fresh base-class state,
    # and hand the state to the app so it can gather the filter memberships. No
    # disk: the loaded rows come from the cache and nothing here scans or searches.
    method on_filter_change {state} {
        my refresh_filter_note
        if {$OnFilterChange ne ""} { {*}$OnFilterChange $state }
    }

    # ---- snapshot membership -----------------------------------------

    # Whether a row passes the current snapshot's row-level filters. The
    # predicate is shared with Scan through ::questlog::scan, so the model and
    # the view never disagree on what the snapshot admits.
    method row_matches_snapshot {row} {
        return [::questlog::scan::row_in_bounds $Snapshot $row]
    }

    # The bounds-relevant fields of a modelled session, assembled from its node
    # payload into the row shape ::questlog::scan reads. These are exactly the
    # fields row_subtree_match (folder, folder_cwd, cwd_hint) and row_in_bounds
    # (mtime, nturns) consult; a caller with a modelled path asks the store,
    # never the scanner. mtime and nturns are set-at-scan; for a session still
    # being written the poll's live refresh (run_tick) keeps them fresh, and
    # the quit tick re-reads before recency is weighed (reconcile_running).
    method payload_bounds_row {path} {
        return [dict create \
            folder     [my sget $path folder] \
            folder_cwd [my sget $path folder_cwd] \
            cwd_hint   [my sget $path cwd_hint] \
            mtime      [my sget $path mtime 0] \
            nturns     [my sget $path nturns]]
    }

    # A re-scanned row arriving for an attached path: the file changed on disk
    # (an unchanged mtime is a no-op), so replace the payload in place and
    # settle what depends on it. The enumerated children are dropped for
    # re-enumeration - a changed transcript may have grown or lost subagents.
    # Cost fields do not ride a scan row, so the freshened payload is costless
    # and the app's cost gate re-prices it - correct for a file whose spend
    # just changed, except while the session runs (the carry below). Selection,
    # pin and anchor survive untouched: the row never leaves the model.
    method freshen_attached {path row} {
        if {[dict getdef $row mtime 0] == [my sget $path mtime 0]} return
        set sid [my sid $path]
        set folder [my sget $path folder]
        set payload [my row_payload $path $row]
        # A running session freshens on every poll tick, and a costless payload
        # would queue a whole-transcript re-parse through the app's cost gate
        # each time: while it runs the priced fields carry over, lagged, and
        # the quit tick (reconcile_running) settles the one re-price.
        if {![dict exists $row cost_usd]
            && [my is_running [file rootname [file tail $path]]]} {
            foreach k {cost turns duration_secs human_secs model context_pct
                       own_cost own_turns own_duration_secs own_human_secs
                       own_model own_context_pct input_tokens output_tokens
                       cache_write_tokens cache_read_tokens model_breakdown} {
                dict set payload $k [my sget $path $k]
            }
        }
        my begin_batch
        my detach_session_children $path
        my node_set $sid expanded 0
        my drop_child_nodes $sid
        dict set Nodes $sid payload $payload
        my mark_heading_dirty $folder
        my node_set $sid hidden [expr {![my attr_admits $sid]}]
        if {[my sflag $path hidden]} {
            my schedule_view_rebuild
        } elseif {[my sflag $path rendered]} {
            my redraw_header $path
        }
        my end_batch
        my check_invariant freshen_attached
    }

    # Drop a session node's subagent child nodes and their indices - the
    # stale-children half of freshen_attached. Walks both child rosters:
    # all_child_paths (the enumerated set) plus the attached children list,
    # since a match-attached child can predate or outgrow the enumeration.
    method drop_child_nodes {id} {
        set cps [my node_pget $id all_child_paths]
        foreach cid [my node_field $id children] {
            set cp [my node_field $cid key]
            if {$cp ni $cps} { lappend cps $cp }
        }
        foreach cp $cps {
            set cid [my session_node $cp]
            if {$cid eq ""} continue
            dict unset Nodes $cid
            dict unset PathNode $cp
        }
        my node_set $id children [list]
    }

    # ---- streaming inserts -------------------------------------------

    # Browse-mode row from Scan. Skipped when criteria are active (the result
    # index is built from matches, not the scan stream). The view filters do
    # not gate the stream: every in-bounds row enters the model, and the base
    # class's attr_admits settles its hidden flag, so a filter only chooses what
    # paints.
    method on_scan_row {row} {
        my begin_batch
        my add_scan_row $row
        my end_batch
    }

    # The batch body of on_scan_row: the caller holds the bracket (the app's
    # sliced flush brackets many rows at once; single-row callers go through
    # on_scan_row, which brackets one).
    method add_scan_row {row} {
        # Under active criteria the result index owns the list, so the scan
        # stream attaches nothing; an out-of-bounds row is simply not modelled.
        if {[::questlog::ui::any_criteria $Snapshot]} return
        set path [dict get $row path]
        if {![my row_matches_snapshot $row]} return
        if {[dict exists $PathNode $path]} {
            my freshen_attached $path $row
            return
        }
        my model_add_session $path $row
        # The model holds every in-bounds session; the filters decide only what
        # paints, and draw_arrival owns which arrivals paint now.
        my draw_arrival $path
    }

    # The base class's batch bracket, which a whole idle flush holds open so
    # it pays one anchor_save/restore and one rebuild for every move inside
    # it, with the host's own close work: the headings whose sums moved are
    # redrawn once, inside the bracket, and one schedule_resort follows. A row
    # method that brackets itself when called singly (freshen_attached,
    # on_scan_row) opens a no-op inner bracket when an outer one holds the
    # widget, so only the outermost close settles anything.
    method end_batch {} {
        if {[my batch_depth] == 1} {
            dict for {f _} $DirtyHeadings { my redraw_folder_heading $f }
            set DirtyHeadings [dict create]
        }
        next
        if {![my batch_depth]} { my schedule_resort }
    }

    # A folder heading whose sums moved, and every heading above it, since a
    # heading sums its whole subtree: redrawn now when unbatched, once per
    # flush when batched (the per-row redraw was O(rows x folder size); this
    # is O(flushes x touched folders)).
    method mark_heading_dirty {folder} {
        set fid [my fid $folder]
        foreach id [list $fid {*}[my ancestors $fid]] {
            if {[my batch_depth]} {
                dict set DirtyHeadings [my node_field $id key] 1
            } else {
                my redraw_folder_heading [my node_field $id key]
            }
        }
    }

    # A whole found session from Search: its complete row and its full match list
    # in line order. Renders the session card, up to snippets_per_session
    # snippets, and the overflow line in one anchored pass - no per-match
    # anchoring or redraw, which is what kept a broad query from freezing the
    # list. Self-brackets one session; the batched flush (begin_batch/end_batch)
    # brackets many at once.
    method add_session_matches {matches {row ""}} {
        if {[llength $matches] == 0} return
        my begin_batch
        my render_session_matches $matches $row
        my end_batch
    }

    # A matched path absent from the model: model it and price it (the scan
    # stream attaches nothing under criteria, so this is where a result's row
    # enters the store). The search pass already read the file and produced a
    # complete row, carried here, so a direct-match session is modelled WITHOUT a
    # second read (issue #30); a caller with no row in hand (a case-B parent that
    # itself matched nothing) passes "" and pays one read through the scan seam.
    # A file that cannot be re-read gets a minimal synthetic row the next scan
    # fills. The hidden flag settles inside model_add_session, so a streamed
    # result obeys the view toggles from its first paint.
    method hydrate_session {path folder {row ""}} {
        if {$row eq "" || ![dict size $row]} { set row [{*}$OnScanPath $path] }
        if {$row eq "" || ![dict size $row]} { set row [dict create folder $folder] }
        if {[my has_session $path]} return
        my model_add_session $path $row
        if {[my sget $path cost] eq ""} { {*}$OnSubagentCost $path }
    }

    # Draw a session that has just entered the model where it lands, or leave it
    # to the debounced rebuild. The one home for that decision: browse arrivals,
    # search matches and subagent matches all reach it, and written out at each
    # site it drifted into three copies that did not agree.
    #
    # Two arrivals wait for the rebuild. One a filter hides, which drawn would
    # leave its folder a heading over nothing. One whose folder has no row:
    # dropped by the last rebuild for having nothing visible under it
    # (render_skip), or shut inside a collapsed ancestor. A dropped folder
    # keeps its expanded flag but mass_unrender cleared its marks, so there
    # is no append point to draw beneath and the empty end mark reads as a bad
    # text index. Deferring both, the rebuild lays the heading and the row
    # together; under a shut ancestor, its expand draws the subtree.
    method draw_arrival {path} {
        set folder [my sget $path folder]
        if {[my sflag $path hidden] || ![my folder_attached $folder]} {
            my schedule_view_rebuild
        } elseif {[my folder_expanded $folder] && ![my sflag $path rendered]} {
            my render_session $path
        }
    }

    # The render body without the anchor/state bracketing, so a flush can
    # bracket a whole slice of sessions once (see app.tcl flush_search). row is
    # the session's complete scan_file row, used to model a direct-match session
    # without a re-read; it defaults "" for a caller with only matches in hand (a
    # test, or a subagent-only match), which then hydrates through the scan seam.
    method render_session_matches {matches {row ""}} {
        set first [lindex $matches 0]
        # Subagent matches attach to the parent session (issue #13 cases B and C);
        # a session's own matches take the path below.
        if {[dict getdef $first is_child 0]} {
            my add_subagent_matches $matches
            return
        }
        set path  [dict get $first path]
        if {![my has_session $path]} {
            my hydrate_session $path [dict get $first folder] $row
        }
        my draw_arrival $path
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

    # A session node's payload from a scan-row dict: the one place the row
    # shape becomes the payload shape, shared by the attach path
    # (model_add_session) and the freshen path (freshen_attached).
    method row_payload {path row} {
        set label [my session_label $path $row]
        set slug  [dict getdef $row slug ""]
        set aitt  [dict getdef $row ai_title ""]
        set mtime [dict getdef $row mtime 0]
        set when  [my fmt_time $mtime]
        set size  [dict getdef $row size 0]
        set cost  [dict getdef $row cost_usd ""]
        set turns [dict getdef $row turns ""]
        set dsecs [dict getdef $row duration_secs ""]
        set hsecs [dict getdef $row human_secs ""]
        set model [dict getdef $row model ""]
        set ctxp  [dict getdef $row context_pct ""]
        # bookmarked defaults to the on-disk +x bit for a synthetic row that
        # omits it; the rest default empty. The token fields and
        # model_breakdown arrive with cost and are kept fresh by refresh_cost,
        # bookmarked by reconcile_one; the rest are set-at-scan and static.
        set bkmk  [dict getdef $row bookmarked [file executable $path]]
        set fuser [dict getdef $row first_user ""]
        # The exchange the session ended on, for the row's hover reveal: what a
        # reader wants in order to tell two sessions apart is where each got to,
        # which the opening prompt stops saying after the first few turns.
        set luser [dict getdef $row last_user ""]
        set lrepl [dict getdef $row last_reply ""]
        set okind [dict getdef $row kind ""]
        set fcwd  [dict getdef $row folder_cwd ""]
        set chint [dict getdef $row cwd_hint ""]
        set ntrn  [dict getdef $row nturns ""]
        set itok  [dict getdef $row input_tokens ""]
        set otok  [dict getdef $row output_tokens ""]
        set cwtok [dict getdef $row cache_write_tokens ""]
        set crtok [dict getdef $row cache_read_tokens ""]
        set mbrk  [dict getdef $row model_breakdown ""]
        return [dict create \
            folder [dict get $row folder] label $label slug $slug ai_title $aitt \
            when $when mtime $mtime size $size cost $cost \
            turns $turns duration_secs $dsecs human_secs $hsecs model $model \
            context_pct $ctxp \
            bookmarked $bkmk first_user $fuser kind $okind folder_cwd $fcwd \
            last_user $luser last_reply $lrepl \
            cwd_hint $chint nturns $ntrn input_tokens $itok output_tokens $otok \
            cache_write_tokens $cwtok cache_read_tokens $crtok \
            model_breakdown $mbrk \
            own_cost $cost own_turns $turns own_duration_secs $dsecs \
            own_human_secs $hsecs own_model $model own_context_pct $ctxp \
            count 0 snippets [list] \
            has_subagents [dict getdef $row has_subagents 0] \
            sub_total 0 children_listed 0 all_child_paths [list]]
    }

    # Record a session in the model without drawing it. A collapsed folder
    # holds its sessions here only; they are drawn lazily on expand. This is
    # what keeps a folded list cheap and free of hidden (elided) lines.
    method model_add_session {path row} {
        set folder [dict get $row folder]
        my ensure_folder $folder
        set fid [my fid $folder]
        set sid [my node_new session $fid $path [my row_payload $path $row]]
        dict set PathNode $path $sid
        my node_set $fid children [linsert [my node_field $fid children] end $sid]
        # The filters settle the hidden flag before the heading below is
        # redrawn from it: a row added hidden and flagged after the fact reads
        # "(1)" over an empty folder.
        my node_set $sid hidden [expr {![my attr_admits $sid]}]

        if {[dict getdef $row has_subagents 0]} {
            my ensure_children_enumerated $path [dict getdef $row children ""]
            my recompute_parent_totals $path
        }

        my mark_heading_dirty $folder
        my check_invariant model_add_session
    }

    # Draw a session that the model already knows, inserting its header (and
    # any stored snippets) at the folder's append point. Idempotent.
    method render_session {path} {
        set sid [my sid $path]
        if {[my node_field $sid rendered]} return
        my render_row $sid
    }

    # The bindings, nested content and selection a freshly-laid session row
    # carries, run by render_row's on_row_rendered tail.
    method wire_session_row {id} {
        set path [my node_field $id key]
        set stag [my node_field $id tag]
        set sm   [my node_field $id start]
        # Every $path below rides through pctsafe: bind %-substitutes its
        # script before Tcl parses it, and a project directory holding a %
        # would be rewritten in place (issue #41's "100%pure" repro). The
        # %X/%Y stay bare - they are the substitutions doing their job.
        set bpath [my pctsafe $path]
        $Text tag bind $stag <ButtonPress-1> \
            [list [self] on_session_press $bpath %X %Y]
        $Text tag bind $stag <ButtonRelease-1> \
            [list [self] on_session_release $bpath %X %Y]
        $Text tag bind $stag <Double-Button-1> \
            [list [self] on_session_double $bpath %X %Y]
        # Shift extends the selection; the platform's add-to-selection click,
        # which Tk names <<ToggleSelection>>, adds or drops one row. It is bound
        # as the virtual event and resolved on the matching release, never
        # written out: it is Command-Button-1 on Aqua but Control-Button-1 here,
        # and a literal Control sequence would outrank <<ContextMenu>>, which
        # Aqua's Control-click also raises (bind(n) MULTIPLE MATCHES, rule (d)).
        $Text tag bind $stag <Shift-ButtonPress-1> [list [self] on_modified_press]
        $Text tag bind $stag <<ToggleSelection>>   [list [self] on_modified_press]
        $Text tag bind $stag <Shift-ButtonRelease-1> \
            [list [self] on_session_shift_release $bpath %X %Y]
        $Text tag bind $stag [string map {Button- ButtonRelease-} \
                [lindex [event info <<ToggleSelection>>] 0]] \
            [list [self] on_session_toggle_release $bpath %X %Y]
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
        set m [my line_open $sid $ntag snippet 1]
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
        $Text tag add $ntag $wstart "$wstart +1c"
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
        set m [my line_open $sid $ntag snippet 1]
        my emit $m "▏" [list snippet snippetbar $ntag]
        set wr [my emit_window $m -align center -pady 1 -padx 3 \
            -create [list [self] make_badge names name $label $path $lineoff $ntag]]
        set wstart [lindex $wr 0]
        $Text tag add $ntag $wstart "$wstart +1c"
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
        set m [my line_open $sid $ntag snippet]
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
        set nsub [my matched_subagents $sid]
        set ntag "n#[incr NextId]"
        set m [my line_open $sid $ntag snippet]
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
        # The base class owns the text delete (mark bookkeeping); the host clears its
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
    # search the matched children attach as their matches arrive, and the
    # parent auto-expands when only its subagents matched (case B). Children
    # are subagent nodes under their parent's; their cost rides the same
    # second pass as a session's, triggered when first drawn.

    method toggle_subagents {path} {
        if {![my has_session $path]} return
        if {![my sget $path has_subagents]} return
        set sid [my sid $path]
        $Text configure -state normal
        my anchor_save
        if {[my node_field $sid expanded]} {
            my node_set $sid expanded 0
            my detach_session_children $path
        } else {
            # The base class's primitive: populate realizes the children, then
            # it lays them at the session's append point.
            my expand $sid
        }
        if {[my node_field $sid rendered]} { my redraw_header $path }
        my anchor_restore
        $Text configure -state disabled
    }

    # How many of a session's subagents matched the search: the attached ones
    # with a hit, since a session expanded before its matches arrived has every
    # subagent attached.
    method matched_subagents {node} {
        set n 0
        foreach cid [my node_field $node children] {
            if {[my node_pget $cid count 0] > 0} { incr n }
        }
        return $n
    }

    # The attached subagent subset, as child paths in render order, derived
    # from the session node's children.
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

    # Base-class hook: realize a session's subagent children at the top of expand.
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

    # Detach every rendered subagent of a session: each child node's region spans
    # its header and its matched-line content, so detaching the children removes
    # the whole subagent block while leaving the session's own match snippets in
    # place (base collapse would take those too). The freed child-snippet tags
    # are loose content, swept after.
    method detach_session_children {path} {
        foreach cp [my session_child_paths $path] {
            if {[my has_session $cp] && [my node_field [my sid $cp] rendered]} {
                my detach [my sid $cp]
            }
        }
        my sweep_loose_tags
    }

    # Seed the models of every subagent of this session (meta only, no hits).
    # Once per session; the matched-children set is built separately as search
    # matches arrive. A pool-scanned row carries its children with it, already
    # enumerated in the worker; a caller without them in hand (a search-attached
    # row, the reconcile paths) passes "" and the scanner seam enumerates here.
    method ensure_children_enumerated {path {children ""}} {
        if {[my sget $path children_listed]} return
        if {$children eq ""} { set children [{*}$OnSubagents $path] }
        set listed [list]
        foreach crow $children {
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
        if {[my has_session $cp]} return
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

    # Base-class override for a rebuild's recursion. A session's subagents are drawn
    # by wire_session_row (via render_children) as the session row is re-laid, so
    # descending into them here would draw each a second time (issue #52). Stop at
    # a session and let render_children be the one writer; a folder's body,
    # folders and sessions alike, is what is due under it, which no wire step draws.
    method render_subtree {id} {
        my render_row $id
        if {[my node_field $id kind] eq "session"} return
        if {[my node_field $id expanded]} {
            foreach c [my node_field $id children] {
                if {[my drawable $c]} { my render_subtree $c }
            }
        }
    }

    method render_children {path} {
        if {![my sflag $path rendered]} return
        foreach cp [my session_child_paths $path] {
            if {![my has_session $cp]} continue
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
        if {![my has_session $cp]} return
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
        set m [my line_open $cid $ntag childsnip]
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
        set m [my line_open $cid $ntag childsnip]
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
        set fixed [font measure QLList $spine]
        set sep_w [font measure QLList "  "]
        set atype [my truncate_px $atype [expr {$max - $fixed - $sep_w}] QLBold]
        if {$atype ne ""} {
            lappend tags [list slug [string length $subj] [string length $atype]]
            append subj $atype "  "
            incr fixed [expr {[font measure QLBold $atype] + $sep_w}]
        }
        append subj [my truncate_px [dict get $c label] \
                         [expr {$max - $fixed}] QLList]
        return [dict create subject $subj tags $tags meta_run 1]
    }

    method on_child_open_at {cp lineoff} { {*}$OnOpen $cp $lineoff }

    method on_child_release {cp} {
        if {![my has_session $cp]} return
        {*}$OnOpen $cp [my sget $cp open_lineoff 0]
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
        my clipboard_set [::logman::last_assistant_text $ChildMenuPath]
    }
    method child_menu_reveal {} {
        ::questlog::ui::session_actions::reveal_dir [file dirname $ChildMenuPath]
    }

    # Attach a subagent's matches to its parent session (issue #13 cases B and C).
    # Creates the parent card if the parent itself had no match (case B), seeds
    # the child models, attaches this child's hits (capped at
    # snippets_per_subagent), counts them for the parent, and either
    # auto-expands (case B: no direct match) or leaves it collapsed.
    method add_subagent_matches {matches} {
        set first [lindex $matches 0]
        set cp     [dict get $first path]
        set parent [dict get $first parent_path]
        set folder [dict get $first folder]
        if {![my has_session $parent]} {
            my hydrate_session $parent $folder
        }
        my sset $parent has_subagents 1
        my draw_arrival $parent
        my ensure_children_enumerated $parent
        if {![my has_session $cp]} {
            my child_add_model $parent [dict create path $cp parent_path $parent \
                folder $folder agent_id [dict getdef $first agent_id ""]]
        }
        set cap [::questlog::config::get snippets_per_subagent]
        set hits [my sget $cp hits]
        foreach m $matches {
            my sset $parent sub_total [expr {[my sget $parent sub_total] + 1}]
            # The child's own total (for its "N more matches" overflow line); its
            # shown snippets are capped at $cap, its count is not.
            my sset $cp count [expr {[my sget $cp count 0] + 1}]
            if {[llength $hits] < $cap} {
                lappend hits [list [dict get $m btype] \
                    [dict get $m content] [dict get $m lineoff]]
            }
        }
        my sset $cp hits $hits
        my attach_child $parent $cp
        # Case B (no direct hit in the parent) auto-expands so the matched
        # subagents are visible; case C keeps the parent collapsed.
        if {[my sget $parent count] == 0} {
            my node_set [my sid $parent] expanded 1
        }
        # Reseat the below-header block from the current totals: the case-B note
        # then the matched subagents, in that order. A whole-block redraw (not an
        # incremental child append) keeps the note above the children and lets its
        # "N matches below in a subagent/subagents" wording track each arriving child.
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

    # ---- base-class hooks: cell values and tags -------------------------

    # The metadata cells the base class lays for a node, as ordered {col value}
    # pairs (a base-class hook). A session or subagent row carries every column.
    # A folder heading carries the sums of what it shows, formatted as the rows
    # format their own, through the date cell (empty, so its sums tab under
    # the rows' columns) to A/H; a sum with nothing in it is blank rather
    # than "$0.00" or "00:00".
    method cell_values {node} {
        set kind [my node_field $node kind]
        if {$kind eq "folder"} {
            set agg [my node_aggregate $node 1]
            set cells [my meta_cells [dict filter $agg script {k v} {expr {$v > 0}}]]
            return [lmap col {date size cost turns duration ah} {
                list $col [dict get $cells $col]
            }]
        }
        set cells [my meta_cells [my node_payload $node]]
        set out [list]
        foreach col [::questlog::ui::session_columns] {
            lassign $col id
            lappend out [list $id [dict get $cells $id]]
        }
        return $out
    }

    # The overlay tags for one laid cell (a base-class hook), applied only when the
    # cell is non-empty. The cost cell takes a tier colour (amber from 10c, brick
    # red from $1; below that the muted meta grey shows through); the actions cell
    # is marked so a click on it is told apart from the row, and brightens while
    # the row is selected. A heading's sums are bold; the cost also takes the
    # tier colour, so the project that ate the most reads bold red.
    method cell_tag {node col} {
        set kind [my node_field $node kind]
        if {$kind eq "folder"} {
            if {$col ni {size cost duration ah}} { return {} }
            set ctag meta
            if {$col eq "cost"} {
                set fc [dict get [my node_aggregate $node 1] cost]
                if {$fc >= 1.0} { set ctag cost-outlier } elseif {$fc >= 0.10} { set ctag cost-mid }
            }
            return [list $ctag foldagg]
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

    # The sort value for a column from a node's payload (a base-class hook). Date reads
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

    # Rows stream in newest first, so under the date sort descending an arrival
    # is already in place and the debounced resort can stay unarmed.
    method arrival_in_order {key dir} { return [expr {$key eq "date" && $dir eq "desc"}] }

    # ---- base-class hook: the row subject (left side) --------------------

    # Build a node's subject: the left side per kind, ellipsised to fit before
    # the metadata strip (a base-class hook). Returns {subject <str> tags <ranges>
    # meta_run <0|1>}, where tags is a list of {tag off len} ranges relative to
    # the subject start and meta_run asks the base class to paint the contiguous muted
    # metadata run. A folder paints no meta run (its cells are tagged singly).
    method render_subject {node max} {
        switch -- [my node_field $node kind] {
            folder   { return [my folder_subject $node] }
            subagent { return [my child_subject $node $max] }
            default  { return [my session_subject $node $max] }
        }
    }

    # The session subject: the expand chevron (when it has subagents), the status
    # glyphs (running ● green, bookmark ★ amber), the bold slug, then the
    # first-prompt preview ellipsised into the room left. The chevron and glyphs
    # are kept whole; the slug and the preview are trimmed to the room.
    method session_subject {node max} {
        set s [my node_payload $node]
        set path [my node_field $node key]
        set slug [dict get $s slug]
        set count [dict get $s count]
        set subt  [dict get $s sub_total]
        # The title run's reveal closes on how many subagents matched, not on
        # hits: "more in 2 subagents" when the session matched too (case C), "in
        # 2 subagents" when only they did (case B, whose own line below the row
        # already says the session has no direct match, render_subhint).
        set count_str ""
        if {$subt > 0} {
            set nsub [my matched_subagents $node]
            set count_str "in $nsub [expr {$nsub == 1 ? {subagent} : {subagents}}]"
            if {$count > 0} { set count_str "more $count_str" }
        }
        # Only its subagents matched: the row still carries the session, dimmed, so
        # the eye reads it as context for the hits below rather than a hit itself.
        set only_in_subs [expr {$count == 0 && $subt > 0}]

        set tags [list]
        set subj ""
        # A tab sends the title to the title stop apply_column_tabs adds to the
        # sessionhead tabs, so the title lands there with or without a chevron
        # before it. The subagent chevron shows only on a selected or open row:
        # shown on every row it would read as a folder's marker. A row without
        # it has no chevron tag, so a click there just opens the session.
        if {[dict get $s has_subagents]
            && ([my node_field $node expanded] || [my is_selected $path])} {
            lappend tags [list chevron [string length $subj] 1]
            append subj [expr {[my node_field $node expanded] ? "▾" : "▸"}]
            append subj " "
        }
        append subj "\t"
        set title_off [string length $subj]
        # The slug and the preview share the room between the title stop and the
        # metadata block: the slug is trimmed first, the preview into what is
        # left. An untrimmed slug wider than that room runs past the first
        # metadata stop, and the row's tab stops cascade off their columns.
        set fixed [my marker_w]
        set full_slug $slug
        set clipped 0
        set sep_w [font measure QLList "  "]
        set slug [my truncate_px $slug [expr {$max - $fixed - $sep_w}] QLBold]
        if {$slug ne $full_slug} { set clipped 1 }
        if {$slug ne ""} {
            lappend tags [list slug [string length $subj] [string length $slug]]
            append subj $slug "  "
            incr fixed [expr {[font measure QLBold $slug] + $sep_w}]
        }
        set full_label [dict get $s label]
        set label [my truncate_px $full_label [expr {$max - $fixed}] QLList]
        if {$label ne $full_label} { set clipped 1 }
        append subj $label
        # A name long enough to be cut is the reason a reader cannot tell two
        # rows apart, so a cut title run carries the reveal: the name leads it,
        # then the exchange the session ended on - its last prompt and the head
        # of the reply to it - which says where the session got to, where the
        # row's own preview is the opening prompt and stops saying that after
        # the first few turns. A session too young to have finished a turn has
        # no reply yet, and a row with neither falls back to the preview the row
        # shows, so the reveal is never empty. A row whose subagents matched
        # wires it cut or not, for the line it closes on; any other untrimmed
        # row shows all it has and wires nothing. The run gets a tag of its own
        # rather than riding the row's ($stag already binds <Enter>/<Leave> for
        # the cursor and the ⋯ brightening, which peek_wire would overwrite),
        # minted here rather than in wire_session_row because a rename redraws
        # the row through item, which does not re-run on_row_rendered. The name
        # is the node's, not a fresh mint: a running row redraws on every glyph
        # tick, and a minted tag per redraw would pile entries up in PeekByTag
        # for the life of the window. t# is its own tag family, swept like the
        # n# hit tags and the c# subagent ones but apart from them, so a title
        # run is never mistaken for a hit by anything that resolves a hit's tag.
        if {$clipped || $count_str ne ""} {
            set ntag "t#$node"
            lappend tags [list $ntag $title_off \
                              [expr {[string length $subj] - $title_off}]]
            set body [dict getdef $s last_user ""]
            if {$body eq ""} { set body $full_label }
            set sub [dict getdef $s last_reply ""]
            if {$count_str ne ""} {
                set sub [expr {$sub eq "" ? $count_str : "$sub\n\n$count_str"}]
            }
            my peek_wire $ntag $full_slug $body 0 $sub
        }
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

    # Rewrite a session header line in place (glyphs). Leaves the
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

    # The one creator of folder nodes. A folder hangs under the folder whose
    # directory most closely contains its own, or at the root when none does;
    # a folder the resolver cannot place (dir "") is a root and never a parent.
    # This is the rule ::questlog::path::container_tree states over a whole
    # corpus at once, applied here one folder at a time as they arrive.
    # Folders arrive in their newest session's order, not top-down, so a new
    # folder whose directory contains a sibling's takes that sibling beneath
    # it, and takes the sibling's place among the siblings: the sibling's
    # newest session is now its own, so the place is its by recency. The same
    # step hangs a folder recreated after its last session left back over the
    # folders it held. cwd is the folder's working directory when the caller
    # already holds it (a move into an as-yet-unscanned folder, where
    # ResolveFolder would walk the filesystem and find nothing); left "" the
    # resolver answers, as browse does.
    method ensure_folder {folder {cwd ""}} {
        if {[my has_folder $folder]} return
        if {$cwd eq ""} { set cwd [{*}$ResolveFolder $folder] }
        set dir [expr {$cwd eq "" ? "" : [file normalize $cwd]}]
        set parent [my folder_parent_for $dir]
        set held [my folders_within $parent $dir]
        set at [expr {[llength $held] ? [lindex $held 0] : [my first_session_child $parent]}]
        set fid [my insert $parent folder $folder [dict create dir $dir] -pos [list before $at]]
        # A search opens every folder, so the matches under each are in view.
        # Browsing opens the first root alone, the project with the newest
        # session, and leaves the rest an overview of headings; a folder
        # arriving over that root takes its place and opens with it, so what
        # was in view stays in view. The heading is drawn shut, so an open one
        # redraws its marker.
        if {[::questlog::ui::any_criteria $Snapshot] || [lindex [my roots] 0] eq $fid} {
            my node_set $fid expanded 1
            my item $fid
        }
        # Inside a flush's bracket the moves' rebuild waits for its end.
        if {[llength $held]} {
            my batch { foreach id $held { my move $id $fid } }
        }
    }

    # The first session among a folder's children ("" with none, or at the
    # root): where a folder goes in to keep folders above sessions (kind_rank)
    # between rebuilds.
    method first_session_child {parent} {
        if {$parent eq ""} { return "" }
        foreach c [my node_field $parent children] {
            if {[my node_field $c kind] eq "session"} { return $c }
        }
        return ""
    }

    # The folders among a parent's children (the roots for parent "") whose
    # directories lie inside dir, in store order: what a folder arriving at
    # dir takes beneath it.
    method folders_within {parent dir} {
        set out [list]
        set sibs [expr {$parent eq "" ? [my roots] : [my node_field $parent children]}]
        foreach id $sibs {
            if {[my node_field $id kind] eq "folder" \
                && [my dir_within [my node_pget $id dir] $dir]} { lappend out $id }
        }
        return $out
    }

    # The folder whose directory most closely contains dir, the parent a folder
    # at dir takes; "" when no folder's does. Two folders can share a directory
    # (one spelled through a symlink), and the first in store order wins.
    method folder_parent_for {dir} {
        set best ""
        set depth -1
        dict for {_ fid} $FolderNode {
            set fdir [my node_pget $fid dir]
            if {[string length $fdir] > $depth && [my dir_within $dir $fdir]} {
                set best $fid
                set depth [string length $fdir]
            }
        }
        return $best
    }

    # 1 iff dir lies strictly inside ancestor. A placeless "" is inside nothing
    # and holds nothing.
    method dir_within {dir ancestor} {
        return [expr {$dir ne "" && $ancestor ne "" && $dir ne $ancestor \
                      && [::questlog::scan::in_subtree_of $dir [list $ancestor]]}]
    }

    # A folder's label: its directory relative to the folder it sits under, or
    # absolute (home abbreviated) at the root, where nothing above it is a row.
    # The relative form runs several segments when the directories between hold
    # no folder, and when the folder's own directory is gone and it hangs under
    # its nearest living ancestor.
    method folder_label {fid} {
        set parent [my node_field $fid parent]
        return [::questlog::path::display_label [my node_pget $fid dir] \
                    [my node_field $fid key] \
                    [expr {$parent eq "" ? "" : [my node_pget $parent dir]}]]
    }

    # 1 iff the folder's directory is known and no longer exists. Read from disk
    # at each heading draw, so a directory restored later heals on the next.
    method folder_gone {fid} {
        set dir [my node_pget $fid dir]
        return [expr {$dir ne "" && ![file isdirectory $dir]}]
    }

    # ---- the fold behind a heading --------------------------------------
    #
    # The folder heading subject: the marker, the (truncated) project label, the
    # gone glyph when its directory no longer exists, and a bare "(N)" count of
    # the sessions beneath it, nested folders included - "(N of M)" when a list
    # filter hides some of them, M the store's count. The folder's size, cost
    # and time sums are laid by the base class as cells (cell_values) under the
    # rows' columns, with an empty date cell so the double tab opens straight
    # into the size column; their bold/tier tags come from cell_tag. The
    # subject tags only its leading marker (the foldchevron range), so a
    # Button-1 on the marker can be told from one on the label: the marker
    # toggles expand/collapse, the label selects the folder.
    method folder_subject {node} {
        set marker [expr {[my node_field $node expanded] ? "▾" : "▸"}]
        set n [dict get [my node_aggregate $node 1] count]
        set total [expr {[my any_view_toggle] ? [dict get [my node_aggregate $node] count] : $n}]
        set count_str [expr {[my folder_gone $node] ? " $::questlog::ui::GLYPH_GONE" : ""}]
        if {$n > 0} {
            append count_str [expr {$total > $n ? " ($n of $total)" : " ($n)"}]
        }
        # Marker joined to the label by a space; the label is truncated so it
        # never runs into the right-pinned aggregates. Everything before the
        # first tab stop is the marker, the label, the count and the indent, and
        # a pixel past that stop puts the whole strip of aggregates on the next
        # one, a column right of the rows'. With nothing left for a label the
        # count keeps the strip in place on its own, so the joining space goes
        # with the label.
        set fixed [expr {[font measure QLList "$marker "] \
                         + [font measure QLList $count_str] \
                         + [my indent_px $node]}]
        set full [my folder_label $node]
        set label [my truncate_px $full [expr {$LabelMax - $fixed}] QLList]
        set gap [expr {$label eq "" ? "" : " "}]
        set tags [list [list foldchevron 0 1]]
        # A project path is long and cut from the front of the aggregates, so a
        # deep folder shows its head and hides the leaf that names it. The cut
        # label carries the reveal, over the label run alone: the chevron and the
        # counts beside it say all they have to say. The heading has no <Enter>
        # of its own, so the reveal leaves the cursor alone rather than promising
        # a hand the row never showed before.
        # A pane too narrow for one letter of label leaves the heading nameless,
        # so there the reveal takes the whole line instead of the label run.
        if {$label ne $full} {
            set ntag "t#$node"
            if {$label eq ""} {
                lappend tags [list $ntag 0 \
                                  [string length "$marker$gap$label$count_str"]]
            } else {
                lappend tags [list $ntag [string length "$marker$gap"] \
                                  [string length $label]]
            }
            my peek_wire $ntag $full "" 0
        }
        return [dict create subject "$marker$gap$label$count_str" \
                    tags $tags meta_run 0]
    }

    method redraw_folder_heading {folder} {
        if {![my has_folder $folder]} return
        # item rewrites the heading line in place; a detached folder is
        # unrendered, so item no-ops and the detached case guards itself.
        my item [my fid $folder]
        # item drops every tag on the re-laid line, including the folder selection
        # highlight; re-add it from membership, the way redraw_header does. The
        # membership is model state and outlives a rebuild that detached the
        # folder, so the heading has to be drawn before its start mark is read:
        # a batch's dirty flush reaches a folder a rebuild has since detached.
        if {[my folder_attached $folder] && [my is_folder_selected $folder]} {
            set fm [my node_field [my fid $folder] start]
            $Text tag add selected $fm "$fm lineend"
        }
    }

    # ---- folder click, selection and menu ----------------------------
    #
    # A folder heading is selectable like a session row, but its state lives
    # apart from the session selection: a folder joins no SelectedSet of its own.
    # There is one highlighted folder at a time, held in SelectedFolder by node id
    # (a fid, like SelectedSet holds sids), and it and the session selection are
    # mutually exclusive (one selection model). Keying by the stable fid dissolves
    # the stale-highlight roach: a forgotten folder's id is purged on delete, so a
    # later folder reusing the name never inherits its highlight. The highlight
    # reuses the session `selected` tag over the heading line; re-lays reapply it
    # from membership (on_row_rendered and redraw_folder_heading above).

    method on_folder_click {folder X Y} {
        if {[my click_on_tag $X $Y foldchevron]} {
            my toggle_folder $folder
            return
        }
        my folder_select $folder
    }

    method is_folder_selected {folder} {
        return [expr {[my has_folder $folder] && $SelectedFolder eq [my fid $folder]}]
    }

    method folder_select {folder} {
        if {![my has_folder $folder]} return
        # Drop any session selection first; set_selection also clears a prior
        # folder highlight (clear_folder_selection), so SelectedFolder is empty
        # before this folder claims it.
        my set_selection [list]
        set SelectAnchor ""
        set fid [my fid $folder]
        set SelectedFolder $fid
        if {[my node_field $fid rendered]} {
            set fm [my node_field $fid start]
            $Text tag add selected $fm "$fm lineend"
        }
    }

    method clear_folder_selection {} {
        if {$SelectedFolder eq ""} return
        if {[dict exists $Nodes $SelectedFolder] \
            && [my node_field $SelectedFolder rendered]} {
            set fm [my node_field $SelectedFolder start]
            catch {$Text tag remove selected $fm "$fm lineend"}
        }
        set SelectedFolder ""
    }

    # The folder heading's right-click menu. Kept small and folder-shaped (a
    # bounds action and a reveal), not the session action set, which is built for
    # a session target. Every action here needs the project's working
    # directory: a folder the resolver cannot place greys them all out; one
    # whose directory is gone still bounds a search by the path it had, but
    # has nowhere to reveal.
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
            -command [list [self] folder_bound $folder] \
            -state [expr {$OnFolderBound eq "" || $cwd eq "" ? "disabled" : "normal"}]
        $FMenu add command -label "Reveal folder" \
            -command [list [self] folder_reveal $folder] \
            -state [expr {[file isdirectory $cwd] ? "normal" : "disabled"}]
        tk_popup $FMenu $X $Y
    }

    method folder_bound {folder} {
        if {$OnFolderBound eq ""} return
        {*}$OnFolderBound $folder
    }

    method folder_reveal {folder} {
        set cwd [{*}$ResolveFolder $folder]
        if {![file isdirectory $cwd]} return
        ::questlog::ui::session_actions::reveal_dir $cwd
    }

    # Open or shut a folder: the base class's expand draws what is due under it,
    # folders and sessions in store order, and collapse takes the body away.
    method toggle_folder {folder} {
        if {![my has_folder $folder]} return
        set fid [my fid $folder]
        $Text configure -state normal
        if {[my node_field $fid expanded]} {
            my collapse_folder $folder
        } else {
            my expand $fid
        }
        my redraw_folder_heading $folder
        $Text configure -state disabled
        my check_invariant toggle_folder
    }

    # Right and Left on the cursor's row open and shut it the way a click on
    # its marker does: a folder through toggle_folder, a session's subagents
    # through toggle_subagents, each redrawing the marker and sweeping what the
    # body left behind. The base class's cursor_open reaches the bare expand
    # and collapse, which do neither; a subagent row has nothing to open.
    method cursor_open {open} {
        set id [my cursor]
        if {$id eq "" || $open == [my node_field $id expanded]} return
        switch -- [my node_field $id kind] {
            folder  { my toggle_folder [my node_field $id key] }
            session { my toggle_subagents [my node_field $id key] }
        }
    }

    # Open every folder at every depth, in one batch so the reader's scroll
    # position anchors once for the whole sweep. Parents before children: a
    # nested folder's heading is drawn shut by its parent's expand, then its
    # own expand lays its body and the redraw turns its marker. A folder
    # already open is left alone, since expand lays a body it finds laid a
    # second time.
    method expand_all_folders {} {
        my batch {
            foreach rid [my roots] {
                foreach id [list $rid {*}[my descendants $rid]] {
                    if {[my node_field $id kind] ne "folder" \
                        || [my node_field $id expanded]} continue
                    my expand $id
                    my redraw_folder_heading [my node_field $id key]
                }
            }
        }
        my check_invariant expand_all_folders
    }

    # A folder's own session paths, in the order they sit under the folder node;
    # the folders beside them are not sessions and are left out.
    method folder_session_paths {folder} {
        if {![my has_folder $folder]} { return [list] }
        set out [list]
        foreach sid [my node_field [my fid $folder] children] {
            if {[my node_field $sid kind] eq "session"} {
                lappend out [my node_field $sid key]
            }
        }
        return $out
    }

    # The destinations the move picker lists, each as {key dir label parent}:
    # every folder in the store in display order, parents before children,
    # labelled as their headings are and naming the folder they hang under
    # ("" at the root), then beneath them the projects on disk the store
    # holds no session of (outside the since or subtree bound), labelled by
    # their absolute path, so a session can move to a project the list is
    # not showing. A folder the resolver cannot place is left out; one whose
    # directory is gone the picker leaves out.
    method folder_roster {} {
        set out [list]
        foreach rid [my roots] {
            foreach id [list $rid {*}[my descendants $rid]] {
                if {[my node_field $id kind] ne "folder"} continue
                set p [my node_field $id parent]
                lappend out [dict create key [my node_field $id key] \
                    dir [my node_pget $id dir] label [my folder_label $id] \
                    parent [expr {$p eq "" ? "" : [my node_field $p key]}]]
            }
        }
        set rest [list]
        foreach folder [::questlog::path::list_all_projects] {
            if {[my has_folder $folder]} continue
            set cwd [{*}$ResolveFolder $folder]
            if {$cwd eq ""} continue
            lappend rest [dict create key $folder dir [file normalize $cwd] \
                label [::questlog::path::pretty_home $cwd] parent ""]
        }
        return [concat $out [lsort -dictionary -index 5 $rest]]
    }

    # True while a filter is narrowing the view, so some loaded sessions may be
    # hidden. Every filter counts, the model filter included: it hides loaded
    # rows exactly as the other two do, and a folder whose rows it all hides
    # must not go on reporting them.
    method any_view_toggle {} {
        if {$TurnsView > 1} { return 1 }
        return [expr {[llength [::questlog::listfilter::active_filters [my attr_filter_all]]] > 0}]
    }

    # A row that arrives while a filter is on lands hidden, and the folder created
    # for it draws a heading with nothing under it: rows stream in one at a time
    # (the scan, the search) and no step in that path re-derives the view, so the
    # heading stands over an empty folder. rebuild is the pass that does
    # re-derive it (hidden-aware, dropping a folder with no shown row), so ask
    # for one - debounced, so a flood of streamed rows costs one rebuild rather
    # than one per row.
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

    # What a node adds up to (the base class's fold hooks, node_aggregate):
    # the sessions beneath it counted, with their bytes, spend, machine time
    # and human time summed, and the newest of them dated. Only a session
    # adds: a subagent's spend is already rolled into its parent's cost, and
    # a folder is only its subtree. An unpriced session adds nothing to the
    # figures it lacks.
    method aggregate_seed {} {
        return [dict create count 0 size 0 cost 0.0 duration_secs 0 human_secs 0 mtime 0]
    }
    method aggregate_add {acc id} {
        set node [dict get $Nodes $id]
        if {[dict get $node kind] ne "session"} { return $acc }
        set s [dict get $node payload]
        dict incr acc count
        dict incr acc size [dict getdef $s size 0]
        if {[dict getdef $s mtime 0] > [dict get $acc mtime]} {
            dict set acc mtime [dict get $s mtime]
        }
        set c [dict getdef $s cost ""]
        if {$c ne "" && $c > 0} { dict set acc cost [expr {[dict get $acc cost] + $c}] }
        foreach k {duration_secs human_secs} {
            set v [dict getdef $s $k ""]
            if {$v ne ""} { dict incr acc $k $v }
        }
        return $acc
    }

    # Drop the per-snippet / per-child-snippet tags ("n#" / "c#") left empty by a
    # body delete. They are loose row content, not nodes, so the base class's
    # node-based cleanup does not reach them; without this they accumulate.
    # Their reveal-registry entries go with them.
    method sweep_loose_tags {} {
        foreach tg [$Text tag names] {
            if {([string match "n#*" $tg] || [string match "c#*" $tg] \
                 || [string match "t#*" $tg]) \
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
        my collapse [my fid $folder]
        my sweep_loose_tags
    }

    # Apply a batch of buffered cost results in one pass (see app.tcl
    # flush_cost). Each row's model and render work runs through apply_cost;
    # the status line's grand total derives from the whole store, so it is
    # refreshed once here after the loop rather than per row - a thousand-session
    # flush would otherwise re-walk the store a thousand times (issue #64).
    # Grouping the render into one event-loop turn also keeps a flood of worker
    # results from churning the list while the user interacts.
    method refresh_cost_batch {batch} {
        my begin_batch
        dict for {path cost_dict} $batch {
            my apply_cost $path $cost_dict
        }
        my end_batch
        my refresh_status
    }

    # A single cost result, model and render and status. The batch path calls
    # apply_cost directly and refreshes the status once for the whole flush.
    method refresh_cost {path cost_dict} {
        my apply_cost $path $cost_dict
        my refresh_status
    }

    # Late arrival from the cost-pass worker, without the status refresh (its
    # caller owns that). Diffs the new cost against the cached one (so a retry on
    # a re-scanned file does not double-count) to decide whether the folder
    # heading changed, then redraws the row's meta region and its folder heading
    # in place. The status line's total is derived, not maintained here.
    method apply_cost {path cost_dict} {
        if {![dict exists $PathNode $path]} return
        # A subagent's cost lands on its child row, not a session row.
        if {[my node_field [my sid $path] kind] eq "subagent"} {
            my apply_child_cost $path $cost_dict
            return
        }
        set folder [my sget $path folder]
        set old_cost [my sget $path cost]
        if {$old_cost eq "" || $old_cost < 0} { set old_cost 0.0 }
        my write_cost_fields $path $cost_dict
        my recompute_parent_totals $path

        set new_cost [my sget $path cost]
        if {$new_cost eq "" || $new_cost < 0} { set new_cost 0.0 }
        set delta [expr {$new_cost - $old_cost}]

        # Heading and session line both re-lay through the item primitive,
        # which owns its own widget state, so this method holds none.
        if {$delta != 0} { my mark_heading_dirty $folder }
        if {[my sflag $path rendered]} { my redraw_header $path }
        # The worker result can change cost-, turns-, duration-, A/H- or
        # context-sorted order.
        if {[lindex [my sort] 0] in {cost turns duration ah context}} { my schedule_resort }
    }

    # The cost arrival's payload writes, shared by the attached path (which
    # then settles folder books and redraws). The token counts and per-model
    # split are own-session values with no subagent aggregation.
    method write_cost_fields {path cost_dict} {
        my sset $path own_cost [dict get $cost_dict cost_usd]
        my sset $path own_turns [dict getdef $cost_dict turns ""]
        my sset $path own_duration_secs [dict getdef $cost_dict duration_secs ""]
        my sset $path own_human_secs [dict getdef $cost_dict human_secs ""]
        my sset $path own_model [dict getdef $cost_dict model ""]
        my sset $path own_context_pct [dict getdef $cost_dict context_pct ""]
        my sset $path input_tokens [dict getdef $cost_dict input_tokens ""]
        my sset $path output_tokens [dict getdef $cost_dict output_tokens ""]
        my sset $path cache_write_tokens [dict getdef $cost_dict cache_write_tokens ""]
        my sset $path cache_read_tokens [dict getdef $cost_dict cache_read_tokens ""]
        my sset $path model_breakdown [dict getdef $cost_dict model_breakdown ""]
    }

    # A subagent's cost/turns/duration arriving from the second pass. Stored on
    # the child and shown on its own row, but also folded up to the parent
    # session level. Redraws the parent's children block and updates the parent
    # row. No status refresh (its caller owns that); the grand total is derived.
    method apply_child_cost {cp cost_dict} {
        if {![my has_session $cp]} return
        my sset $cp cost [dict get $cost_dict cost_usd]
        my sset $cp turns [dict getdef $cost_dict turns ""]
        my sset $cp duration_secs [dict getdef $cost_dict duration_secs ""]
        my sset $cp human_secs [dict getdef $cost_dict human_secs ""]
        my sset $cp model [dict getdef $cost_dict model ""]
        my sset $cp context_pct [dict getdef $cost_dict context_pct ""]
        set parent [my sget $cp parent_path]
        if {[my has_session $parent]} {
            set folder [my sget $parent folder]
            set old_cost [my sget $parent cost]
            if {$old_cost eq "" || $old_cost < 0} { set old_cost 0.0 }

            my recompute_parent_totals $parent

            set new_cost [my sget $parent cost]
            if {$new_cost eq "" || $new_cost < 0} { set new_cost 0.0 }
            set delta [expr {$new_cost - $old_cost}]

            $Text configure -state normal
            if {$delta != 0} { my mark_heading_dirty $folder }
            if {[my sflag $parent rendered]} {
                my redraw_header $parent
            }
            if {[my node_field [my sid $cp] rendered]} {
                my rerender_children $parent
            }
            $Text configure -state disabled
            # The worker result can change cost-, turns-, duration-, A/H- or
            # context-sorted order.
            if {[lindex [my sort] 0] in {cost turns duration ah context}} { my schedule_resort }
        }
    }

    # Recomputes the parent session's aggregated totals from its own raw values
    # plus the computed metrics of all its subagents.
    method recompute_parent_totals {path} {
        set sid [my session_node $path]
        if {$sid eq ""} return
        set s [my node_payload $sid]

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
            set cid [my session_node $cp]
            if {$cid ne ""} {
                set c [my node_payload $cid]
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
    # The selection is a set of session node ids (SelectedSet, a dict sid->1 in
    # insertion order) with a SelectAnchor sid the Shift-range extends from. A
    # plain click selects one and opens it; Control toggles one (across folders);
    # Shift selects the run of drawn rows between two clicks. Membership is keyed by
    # the stable node id, so it survives the frequent re-renders and follows a
    # moved session for free (a move re-parents the node, its id unchanged); the
    # path-facing accessors (is_selected, selection_paths) resolve sid -> key at
    # the boundary.

    method is_selected {path} {
        return [expr {[my has_session $path] && [dict exists $SelectedSet [my sid $path]]}]
    }
    method selection_paths {}   { return [lmap id [dict keys $SelectedSet] { my node_field $id key }] }
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
            # A shut row's subagent chevron follows the selection (session_subject).
            if {[my sget $path has_subagents] && ![my node_field $sid expanded]} {
                my redraw_header $path
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
        foreach p $paths { dict set new [my sid $p] 1 }
        set old $SelectedSet
        set SelectedSet $new
        foreach id [dict keys $old] {
            if {![dict exists $new $id]} { my apply_selection_tag [my node_field $id key] 0 }
        }
        foreach id [dict keys $new] {
            if {![dict exists $old $id]} { my apply_selection_tag [my node_field $id key] 1 }
        }
    }

    # Plain click: the selection is exactly this one, and it anchors a range.
    method selection_set {path} {
        my set_selection [list $path]
        set SelectAnchor [my sid $path]
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
        set SelectAnchor [my sid $path]
    }

    # Shift click: the sessions among the drawn rows from the anchor to this
    # row, whatever folders the run crosses. The headings in the run are not
    # sessions and stay apart from the selection; a subagent row is its
    # session's and not selected either. Only drawn rows are in the run, so a
    # shut folder between the two clicks contributes none of its sessions and
    # a filtered-out row is never touched: a range selection or a batch action
    # must never reach a session the reader cannot see. A row a filter has
    # hidden keeps its line until the debounced rebuild takes it, so the
    # hidden flag is checked as well as the row. An anchor with no row (its
    # folder shut since) re-anchors here. The anchor stays put so dragging the
    # endpoint grows or shrinks the run from the same origin.
    method selection_range {path} {
        set rows [my all_rendered_nodes]
        set ia [expr {$SelectAnchor eq "" ? -1 : [lsearch -exact $rows $SelectAnchor]}]
        set ib [expr {[my has_session $path] ? [lsearch -exact $rows [my sid $path]] : -1}]
        if {$ia < 0 || $ib < 0} { my selection_set $path; return }
        if {$ia > $ib} { lassign [list $ib $ia] ia ib }
        set run [list]
        foreach id [lrange $rows $ia $ib] {
            if {[my node_field $id kind] eq "session" && ![my node_field $id hidden]} {
                lappend run [my node_field $id key]
            }
        }
        my set_selection $run
    }

    # Opening a session lands at its start unless the caller names a line: the
    # deep links that know a match (a snippet click, the menu's Open at this
    # match) pass its lineoff, and every general "open" verb reads from the top.
    method open_session {path {lineno 0}} {
        {*}$OnOpen $path $lineno
    }

    # The keyboard verbs the context menu advertises (issue #53). Both act on a
    # lone selection and no-op otherwise: the single-session menu is the only one
    # carrying "Open in viewer" / "Copy resume command", so a multi-selection has
    # no single target for either.
    method open_selected {} {
        if {[my selection_count] != 1} return
        my open_session [lindex [my selection_paths] 0] 0
    }
    method copy_selected_resume {} {
        if {[my selection_count] != 1} return
        set path [lindex [my selection_paths] 0]
        if {![my has_session $path]} return
        set folder [my sget $path folder]
        set cwd [expr {$folder ne "" ? [{*}$ResolveFolder $folder] : ""}]
        if {![file isdirectory $cwd]} return
        my clipboard_set \
            [::questlog::ui::terminal::resume_command $cwd [file rootname [file tail $path]]]
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
        # The first click of a double already selected and opened the row; a
        # second open would reload the viewer and drop its typed prompt.
        if {$DoubleRelease} { set DoubleRelease 0; return }
        # A plain click collapses any multi-selection back to this one row.
        my selection_set $path
        # A plain click on a search result lands at the session start, not at its
        # first match; the matches are reached through the snippet rows and the
        # viewer index. Anchoring to a hit is reserved for the two deliberate
        # deep-link gestures (a snippet click, the menu's "Open at this match").
        my open_session $path 0
    }

    # A double-click toggles the session's subagents, as one does a folder.
    # On the chevron the first click's release has toggled already.
    method on_session_double {path X Y} {
        if {[my click_on_action $X $Y] || [my click_on_chevron $X $Y]} return
        set DoubleRelease 1
        my toggle_subagents $path
    }

    # Toggle release: add or drop this row in the selection, across folders.
    method on_session_toggle_release {path X Y} {
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

    # Where the arrow keys leave the base class's cursor, the selection follows,
    # so the keyboard and a plain click highlight a row the same way. Neither
    # opens anything: Return does that, on whatever the cursor reached. A
    # subagent row carries no selection and is passed over.
    method on_cursor {id prev} {
        switch -- [my node_field $id kind] {
            folder  { my folder_select [my node_field $id key] }
            session { my selection_set [my node_field $id key] }
        }
    }

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

    # Hovering a clipped row reveals its full text on the panel beside the
    # pointer. The rendered row is cut at the list column's right edge
    # (-wrap none); $text is the model's full stored string - a snippet's
    # lead/trail window around the hit, a session's name and preview - captured
    # when the row was wired, so the reader sees what ran past the edge without
    # opening the session. $kind heads the reveal when present: the badge word
    # for a snippet (tool_use, name, an agent type), the session's own name for
    # a header row, so the panel carries what the run is called above what it
    # says.
    #
    # $cursor is 1 where the hovered run is the whole clickable row and the hand
    # is this binding's to set, 0 where the run sits inside a row that already
    # manages the cursor for itself (a session header, whose ⋯ cell brightens
    # on the row's own <Enter>) - there a <Leave> for the inner run would put the
    # arrow back while the pointer is still on the row.
    method peek_enter {kind text {cursor 1} {sub ""}} {
        if {$cursor} { $Text configure -cursor hand2 }
        ::questlog::ui::reveal::show $text $kind $sub
    }
    method peek_leave {{cursor 1}} {
        if {$cursor} { $Text configure -cursor arrow }
        ::questlog::ui::reveal::hide
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
    method peek_wire {tag kind text {cursor 1} {sub ""}} {
        dict set PeekByTag $tag [list $kind $text $cursor $sub]
        $Text tag bind $tag <Enter> [list [self] peek_enter_tag $tag]
        $Text tag bind $tag <Leave> [list [self] peek_leave $cursor]
    }
    method peek_enter_tag {tag} {
        if {![dict exists $PeekByTag $tag]} {
            $Text configure -cursor hand2
            return
        }
        lassign [dict get $PeekByTag $tag] kind text cursor sub
        my peek_enter $kind $text $cursor $sub
    }

    # The folder under a drag point: the innermost drawn folder whose region
    # (its heading through its last descendant row) holds the point, so a
    # session dropped anywhere in a folder's body lands in that folder, and
    # one dropped in a nested folder's heading or body lands in the nested
    # one. Past the last row there is no folder. The walk descends from the
    # roots through the one child region that holds the point at each level.
    method drag_hit {X Y} {
        set idx [my index_at $X $Y]
        set hit ""
        set kids [my roots]
        while {1} {
            set found ""
            foreach id $kids {
                if {[my node_field $id kind] ne "folder" || ![my node_field $id rendered]} continue
                if {[$Text compare $idx >= [my node_field $id start]] \
                    && [$Text compare $idx < [my node_field $id end]]} { set found $id; break }
            }
            if {$found eq ""} break
            set hit $found
            set kids [my node_field $found children]
        }
        return [expr {$hit eq "" ? "" : [my node_field $hit key]}]
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
        }
        if {$folder ne ""} { set cwd [{*}$ResolveFolder $folder] }
        set MenuPath $path
        set MenuTarget [dict create path $path uuid $uuid cwd $cwd folder $folder]

        # A resume runs in the project directory, so the resolver's answer
        # for a gone directory (the path the folder had) is no cwd to resume
        # in: the entries grey out as folder_reveal and the move picker do.
        set ctx [dict create target $MenuTarget parent $Top \
            clipboard [list [self] clipboard_set] \
            on_open [list [self] open_session] \
            on_move $OnMoveRequest \
            on_bookmark $OnBookmarkToggle \
            on_rename $OnRename \
            state [dict create \
                is_bookmarked [file executable $path] \
                has_cwd [file isdirectory $cwd] \
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

    # Whether the session with this uuid is in the live running set. The app
    # keeps no running mirror; this is the uuid-keyed reader its move and rename
    # guards ask, over the set reconcile_running writes each poll tick.
    method is_running {uuid} { return [dict exists $RunningSet $uuid] }

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
        # A uuid in PrevRunning but not here quit this tick. Its modelled mtime
        # froze at the last live refresh and the retention pass below reads that
        # cached value, so under a short window the row would drop the moment
        # the session stops: freshen it from disk first, letting the quit
        # instant's mtime decide. The freshen resets the priced fields (no
        # longer running, freshen_attached carries nothing) and the app's cost
        # gate re-prices; for an unchanged file the freshen no-ops and the
        # re-price is asked for directly, so cost catches up on completion
        # either way. Before the state/anchor bracket below: the freshen owns
        # its own.
        if {![::questlog::ui::any_criteria $Snapshot]} {
            dict for {uuid path} $PrevRunning {
                if {[dict exists $running $uuid]} continue
                if {![my has_session $path]} continue
                if {![catch {file mtime $path} m] && $m != [my sget $path mtime 0]} {
                    {*}$OnScanPath $path
                }
                if {[my sget $path cost] ne ""} { {*}$OnSubagentCost $path }
            }
        }
        # The subtree bound is hard, even for a running session: a live session in
        # another project must not surface under a folder bound. The recency bound
        # is the only thing a running session bypasses, not the folder bound.
        set subtree [dict getdef $Snapshot subtree {}]
        set before [llength [my all_session_paths]]

        $Text configure -state normal
        my anchor_save
        set imported [dict create]
        if {![::questlog::ui::any_criteria $Snapshot]} {
            dict for {uuid path} $running {
                if {[my has_session $path]} continue
                if {![file isfile $path]} continue
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
                if {$row eq "" || ![dict size $row]} continue
                # OnScanPath above is not a pure read: scan_path -> publish_row
                # fires OnRow, which in browse mode is on_scan_row, which has
                # already added (and rendered) this session. Re-check so we do
                # not add it a second time. A running session that on_scan_row
                # filtered out (out of window / below the min-turns floor) is
                # still absent here and is added below, so a running session in
                # bounds surfaces in plain browse.
                if {[my has_session $path]} continue
                if {[llength $subtree] > 0 \
                    && ![::questlog::scan::row_subtree_match $row $subtree]} continue
                my model_add_session $path $row
                if {[my sget $path cost] eq ""} { {*}$OnSubagentCost $path }
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
            set uuid [file rootname [file tail $path]]
            set is_running [dict exists $running $uuid]
            # Phantom: not running and the backing jsonl is gone (a Resume-fork that quit
            # before any input). Drop it from every mode.
            if {!$is_running && ![file isfile $path]} { my forget_session $path; continue }
            # This path is modelled (checked at the loop head), so its bounds
            # fields come straight from the store.
            set row [my payload_bounds_row $path]
            # Retain in the model: a matched search row always; a browse row while it is
            # in bounds or running. An out-of-bounds, non-running browse row leaves.
            if {[::questlog::ui::any_criteria $Snapshot]} {
                set retained 1
            } else {
                # The subtree bound is hard; within it a running session bypasses the
                # recency / min-turns bounds (it always surfaces), but a running
                # session OUTSIDE the subtree bound does not.
                set in_subtree [expr {[llength $subtree] == 0 \
                    || [::questlog::scan::row_subtree_match $row $subtree]}]
                # A session the reader pulled in through the cut banner stays,
                # whatever the bounds say: they named it and asked for it, and
                # dropping it on the next tick would answer them by taking it away.
                set retained [expr {[dict exists $Pinned [my sid $path]] || ($in_subtree \
                    && ([my row_matches_snapshot $row] || $is_running))}]
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
            if {[llength [my all_session_paths]] != $before} { my schedule_resort }
        }
        # A change in the running set changes the `running` attribute's value on
        # the rows that flipped, so when the base class's running filter is on its
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

    method reconcile_one {path} {
        if {![my has_session $path]} return
        # A bookmark toggle flips the file's +x bit and then calls here to
        # redraw the one row's marker. The marker is drawn from the payload's
        # bookmarked field (session_bookmarked), so refresh it from the bit
        # before the redraw: this one write is what lets the glyph follow a
        # toggle without a re-scan.
        my sset $path bookmarked [file executable $path]
        # The bit is also the "bookmarked only" filter's attribute, so re-derive
        # this one row's hidden flag: a row the filter no longer admits leaves
        # through the debounced rebuild now, not at the next poll.
        my sflagset $path hidden [expr {![my attr_admits [my sid $path]]}]
        if {[my sflag $path hidden]} {
            my schedule_view_rebuild
        } elseif {[my sflag $path rendered]} {
            $Text configure -state normal
            my redraw_header $path
            $Text configure -state disabled
        }
    }

    # Every session in the store (subagents excluded), at any depth.
    method all_session_paths {} {
        set out [list]
        foreach id [my all_node_ids] {
            if {[my node_field $id kind] eq "session"} { lappend out [my node_field $id key] }
        }
        return $out
    }

    # ---- removal / relocation ----------------------------------------

    # The folder-level settle after one session leaves it. A folder with no
    # session of its own is not a row: the folders it still holds step up to
    # its parent (carrying its label in theirs, folder_label) and it is dropped
    # whole; else its heading re-derives. The node must already be off the
    # folder's children list (deleted or detached) when this runs. The moves
    # share one batch, so the step up pays one rebuild, which also ranks the
    # promoted folders back above their new siblings' sessions; with none
    # promoted, only the sums above the dropped folder moved.
    method folder_after_leave {fid folder} {
        if {[llength [my folder_session_paths $folder]] > 0} {
            my mark_heading_dirty $folder
            return
        }
        set parent [my node_field $fid parent]
        set held [my node_field $fid children]
        my batch { foreach c $held { my move $c $parent } }
        my forget_folder $folder
        if {![llength $held] && $parent ne ""} {
            my mark_heading_dirty [my node_field $parent key]
        }
    }

    method forget_session {path} {
        if {![my has_session $path]} return
        set sid [my sid $path]
        set fid [my node_field $sid parent]
        set folder [my node_field $fid key]
        # The delete primitive removes the row and its subagent rows in one cut
        # and unregisters the subtree, running on_before_delete on each node:
        # forget_session_domain subtracts this session's cost and drops its
        # domain indices (its own and its subagents'). The folder-level
        # bookkeeping that depends on whether the folder is now empty stays here.
        my delete $sid
        my folder_after_leave $fid $folder
    }

    # A session leaving the store: drop its path index, its selection
    # membership, and the indices of any enumerated subagents the
    # rendered-children subtree did not already cover. Unlike a move (which
    # re-parents the node and keeps its id), a forget deletes the node, so the
    # sid-keyed view-state sets are purged here by id. The status line's grand
    # total is derived from the surviving nodes, so nothing to subtract here.
    method forget_session_domain {id} {
        set path [my node_field $id key]
        foreach cp [my node_pget $id all_child_paths] {
            if {[dict exists $PathNode $cp]} {
                catch {dict unset Nodes [dict get $PathNode $cp]}
                dict unset PathNode $cp
            }
        }
        dict unset PathNode $path
        dict unset SelectedSet $id
        dict unset Pinned $id
        if {$SelectAnchor eq $id} { set SelectAnchor "" }
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
    method relocate_card {old_path new_path new_folder new_cwd} {
        if {![my has_session $old_path]} return
        set sid [my sid $old_path]
        set src_fid [my node_field $sid parent]
        set src_folder [my node_field $src_fid key]
        my node_pset $sid folder $new_folder
        my node_set $sid key $new_path
        dict unset PathNode $old_path
        dict set PathNode $new_path $sid
        # The rename preserves the file's mtime, so the differential skip
        # suppresses any rescan of the new path and a stale bookmarked/mtime/size
        # would live on forever. Re-read the three from disk now, and re-stamp
        # folder_cwd for the new residence: move_one hands us the destination cwd
        # (ResolveFolder walks the filesystem and would not answer for a folder
        # the scan has not yet touched).
        my node_pset $sid bookmarked [file executable $new_path]
        my node_pset $sid mtime [file mtime $new_path]
        my node_pset $sid size [file size $new_path]
        my node_pset $sid folder_cwd $new_cwd
        # The subagent sidecar dir (<uuid>/) moved with the jsonl
        # (path::move_session), so each enumerated child now lives under the new
        # folder: re-key its PathNode entry, node key, folder and parent_path so
        # apply_child_cost's child->parent fold-up still resolves after the move.
        set base [file rootname $new_path]
        set new_cps [list]
        foreach old_cp [my node_pget $sid all_child_paths] {
            set new_cp [file join $base subagents [file tail $old_cp]]
            set cid [my session_node $old_cp]
            if {$cid ne ""} {
                dict unset PathNode $old_cp
                dict set PathNode $new_cp $cid
                my node_set $cid key $new_cp
                my node_pset $cid parent_path $new_path
                my node_pset $cid folder $new_folder
            }
            lappend new_cps $new_cp
        }
        my node_pset $sid all_child_paths $new_cps
        # Create the destination folder through the single creator, placed by
        # the cwd move_one holds (the resolver would not answer for a folder the
        # scan has not touched). No draw needed; the move's rebuild re-lays it.
        my ensure_folder $new_folder $new_cwd
        # Selection, pin and anchor key by the stable sid, which the move keeps, so
        # a re-parent carries them for free - nothing to re-key here.
        # The move's rebuild re-lays both headings from the derived totals; the
        # source folder settles as after any other leave.
        my move $sid [my fid $new_folder]
        my folder_after_leave $src_fid $src_folder
    }

    # Folders sit above the sessions beside them, as every file tree groups
    # directories first; a session's subagents have no other kind beside them.
    method kind_rank {kind} {
        return [dict get {folder 0 session 1 subagent 2} $kind]
    }

    # Reorder one kind's run of siblings for a rebuild, keeping every node (the
    # base renders from the durable store and skips the unviewable separately;
    # it ranks the kinds and hands each run here on its own). Folders reorder
    # by the active sort: a summed column by the heading's sum, date by the
    # newest session anywhere beneath (so the roots read by recency, as the
    # sessions of one folder do), path by label, else arrival order; sessions
    # by their payloads; subagents keep arrival order.
    method sort_siblings {ids} {
        if {[llength $ids] == 0} { return $ids }
        set bykey [dict create]
        foreach id $ids { dict set bykey [my node_field $id key] $id }
        set order [dict keys $bykey]
        set key [lindex [my sort] 0]
        switch [my node_field [lindex $ids 0] kind] {
            folder {
                set summed {date mtime size size cost cost duration duration_secs}
                if {[dict exists $summed $key]} {
                    set valmap [dict create]
                    foreach id $ids {
                        dict set valmap [my node_field $id key] \
                            [dict get [my node_aggregate $id 1] [dict get $summed $key]]
                    }
                    set order [my sort_by_value $order $valmap -real]
                } elseif {$key eq "path"} {
                    set valmap [dict create]
                    foreach id $ids { dict set valmap [my node_field $id key] [my folder_label $id] }
                    set order [my sort_by_value $order $valmap -dictionary]
                }
            }
            session {
                set payloads [dict create]
                foreach id $ids { dict set payloads [my node_field $id key] [my node_payload $id] }
                set order [my sort_by_payload $order $payloads]
            }
        }
        return [lmap k $order { dict get $bykey $k }]
    }

    # A folder with no shown session anywhere beneath it (none of its own,
    # none in a folder it holds) leaves the rendered view but stays in the
    # store, so it returns once a session is shown again. One whose own
    # sessions a list-view toggle hides stays a row while a folder beneath
    # shows one: the toggle hides rows, it does not reshape the tree.
    method render_skip {id} {
        return [expr {[my node_field $id kind] eq "folder"
                      && [dict get [my node_aggregate $id 1] count] == 0}]
    }

    # Whether a folder's heading is currently drawn: a folder dropped from the
    # view by render_skip, or shut inside a collapsed ancestor, reads 0 until
    # the rebuild or the ancestor's expand draws it again (a drawn row has
    # every ancestor drawn and open, the base class's invariant).
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
    # `shown` is the loaded session nodes the base class admits, counted through the one
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
            dict set loaded [file rootname [file tail $path]] 1
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
            # "criteria", not "search": the time window, the folder bound or the
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
    # they bind: the subtree bound is hard (even a running session outside it never
    # surfaces, see reconcile_running), then the content criteria (with a search
    # active the matches decide what loads, and a session with no hit is not among
    # them), then the recency window. The turns floor is not here: a view
    # filter cuts nothing from the corpus.
    method cut_reason {member} {
        if {[dict getdef $member resolved ""] eq ""} { return none }
        set subtree [dict getdef $Snapshot subtree {}]
        if {[llength $subtree] > 0 && ![my member_in_subtree $member $subtree]} {
            return subtree
        }
        if {[::questlog::ui::any_criteria $Snapshot]} { return search }
        if {[::questlog::scan::cutoff_for $Snapshot] > 0} { return since }
        return unloaded
    }

    # Is the member inside the folder bound? The live registry records the cwd the
    # session runs in, which answers it outright; a member with no cwd (a bookmark
    # sweep records none) falls back to its row if the model has one, and finally
    # to its encoded folder name, the same evidence the scanner's walk uses.
    method member_in_subtree {member subtree} {
        set cwd [dict getdef $member cwd ""]
        if {$cwd ne ""} { return [::questlog::scan::in_subtree_of $cwd $subtree] }
        set path [dict get $member path]
        if {[my has_session $path]} {
            return [::questlog::scan::row_subtree_match \
                        [my payload_bounds_row $path] $subtree]
        }
        return [::questlog::scan::folder_subtree_candidate \
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
        if {$resolved ne "" && [my has_session $resolved]} {
            set slug [my sget $resolved slug]
            if {$slug ne ""} { return $slug }
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
            subtree   { return "The folder bound excluded $it." }
            search    { return "Your search terms excluded $it." }
            since     { return "The time window excluded $it." }
            unloaded  { return "The search did not load $it." }
            default   { return "No transcript on disk to load yet." }
        }
    }

    method widen_label {reason} {
        return [dict getdef {
            subtree   "Clear the folder bound"
            search    "Clear the search"
            since     "Clear the time window"
        } $reason ""]
    }

    # The escape that reads disk, and the only one here that does: load exactly the
    # sessions the search left behind, because the reader asked for them by name.
    # Each is scanned in (a single-file read), pinned so the next reconcile does
    # not put it back out of bounds, and drawn in its folder. The filter is not
    # touched and needs no exemption: a running session admitted under the Running
    # filter passes attr_admits on its own.
    method show_excluded {} {
        set added 0
        set shown [list]
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
            dict set Pinned [my sid $path] 1
            lappend shown $path
            set added 1
        }
        # rebuild is hidden-aware and owns its own widget state: it reseats every
        # folder from the store, so the new row lands in its place under the filter
        # rather than being appended past the list's end. A browse folder is
        # created shut, so the row is then brought into view through whatever
        # headings shut it away.
        if {$added} { my rebuild }
        foreach path $shown { my reveal_session $path }
        my refresh_filter_note
    }

    # Bring a session's row into view whatever shuts it away: the base
    # class's reveal opens every shut folder above it and scrolls to the row,
    # and the headings it opened are redrawn for their marker, as
    # toggle_folder redraws after its expand. A row the filter hides has no
    # row to show and the view stays put.
    method reveal_session {path} {
        if {![my has_session $path]} return
        set sid [my sid $path]
        set shut [lmap a [my ancestors $sid] {
            if {[my node_field $a expanded]} continue
            set a
        }]
        my reveal $sid
        foreach a $shut { my redraw_folder_heading [my node_field $a key] }
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
    # The corpus scan's in-flight signal, paired around app.tcl's scan (issue
    # #54). Distinct from Busy, which is the search's own flag and drives the
    # Cancel button: a browse scan streams cost in silently, so without this the
    # "and counting…" suffix rode a search only and never a plain corpus load.
    method scan_begin {} { set ScanBusy 1; my refresh_status }
    method scan_end {}   { set ScanBusy 0; my refresh_status }

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
        set total [my total_cost]
        if {$total > 0} {
            # While a search or the corpus scan is still landing, the total is
            # provisional: mark it "and counting…" so a mid-flight figure does not
            # read as the final tally. Cleared when both settle (set_done/cancel
            # drops Busy, scan_end drops ScanBusy).
            set cost [::questlog::cost::format_usd $total]
            if {$Busy || $ScanBusy} { append cost " and counting…" }
            lappend parts $cost
        }
        set StatusVar [join $parts " · "]
    }

    # The whole model's spend, the roots' sums read at render time (issue
    # #64), hidden rows included, so no arrival, freshen or forget has to keep
    # a running sum in step.
    method total_cost {} {
        set cst 0.0
        foreach fid $Roots { set cst [expr {$cst + [dict get [my node_aggregate $fid] cost]}] }
        return $cst
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
