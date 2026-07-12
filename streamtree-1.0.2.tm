package require Tcl 9
package require Tk
package provide streamtree 1.0.2

namespace eval ::streamtree {}

# ::streamtree::StreamTree - the generic "tree drawn in one text widget" engine.
#
# A StreamTree owns a tree of abstract NODES rendered into a single read-only
# text widget, with a right-pinned, sortable metadata strip whose columns line
# up across every row. Each node is a folder/row/child carrying the position
# marks and tag that locate it in the widget, plus an opaque domain payload.
# The subclass supplies the content and ordering through the hooks
# (Template Method); the engine never looks inside a payload.
#
# Layout of the body, top to bottom:
#   header   - a 1-line text widget carrying the sortable column labels, in the
#              same grid column as the list so its labels share the list's width.
#   list     - the text widget the nodes render into, with a scrollbar beside it.
#
# A node tracks its position with two marks:
#   node.start  the mark at the node's first char.
#   node.end    the mark just past the node's last descendant line, the append
#               point where the node's children and content land.
#   node.tag    the per-node text tag carrying the row's hit-test / bindings.
# Plus TailMark: right gravity, always just before the implicit final newline,
# the append point for new root nodes. Gravity makes a mid-document insert push
# every mark to its right along with it, so the tree streams without bespoke
# shuffling.
#
# Anti-self-scroll: a streaming insert is bracketed by anchor_save /
# anchor_restore, which pins the top visible line back to the top, so a late
# insert above the viewport never shifts what the reader is on.
#
# The engine owns every text-mark mutation behind a treeview-style primitive
# ensemble - insert/delete/detach/item/expand/collapse/hide/unhide/move/rebuild,
# plus reset and a content door (append_open/emit/emit_window/append_close) for
# loose in-row content that is not itself a node. A subclass drives the widget
# only through these and never touches the text widget.
#
# Hooks the subclass overrides (Template Method). Every hook has a working
# default, so a minimal subclass overrides nothing and gets a plain tree whose
# row text is the payload's `label` (falling back to the node key); columns,
# rich subjects and custom sorts come from overriding the content hooks:
#   Content / layout
#     subject_label             the header label over the subject column ("")
#     column_spec               the metadata columns {id label sample align sortable} ({})
#     render_subject node max    the row's left side: {subject <str> tags <ranges> meta_run 0|1}
#                                (ranges is a list of {tag off len}, subject-relative)
#     cell_values node           ordered {col value} pairs the engine lays as cells ({})
#     cell_tag node col          the tag names overlaid on that cell (empty for none)
#     sort_key payload col       the sort value for a column, from a node's payload
#     apply_column_tabs tabs     set the right tab stops; the default sets them
#                                widget-wide, a host whose row tags carry their own
#                                -tabs configures those tags instead
#     relayout_content           re-fit every rendered row after a width change
#   Row lifecycle (per node kind)
#     start_gravity kind         the row's start-mark gravity (right keeps a heading
#                                pinned to its line; left pins a nested row to its parent)
#     row_tags kind              the static style tags every row of a kind carries
#     on_node_created id         register the node's domain indices before it renders
#     on_row_rendered id         wire a laid row (bindings, nested content, selection)
#     on_before_delete id        drop the node's domain indices before it leaves the store
#     populate id                realize a lazy node's children at the top of expand,
#                                before the engine draws them
#   Rebuild
#     sort_siblings ids          reorder a sibling set for display, keeping every node
#     render_skip id             leave a node out of the view while keeping it in the store
#     rebuild_restore anchor     re-pin the view to a {kind key} top node after a rebuild

# Coerce a {pos align ...} tab spec to strictly increasing positive stops,
# which Tk requires. Guards the degenerate column geometry a too-narrow width
# (a build-time placeholder, or high DPI) can produce. Used by the metadata
# strip's column layout.
proc ::streamtree::sane_tabs {tabs} {
    set out [list]
    set prev 0
    foreach {x align} $tabs {
        if {$x <= $prev} { set x [expr {$prev + 1}] }
        lappend out $x $align
        set prev $x
    }
    return $out
}

oo::class create ::streamtree::StreamTree {
    variable Top
    variable Text
    # The generic node store. Nodes maps a node id to its dict
    # {parent kind key expanded rendered hidden start end tag children payload};
    # Roots is the ordered list of root node ids, in arrival order.
    variable Nodes
    variable Roots
    variable NextId
    # Column geometry, measured once (the proportional list font is fixed) and
    # re-pinned on resize.
    variable ColTabs          ;# -tabs spec for a row (right-pinned metadata)
    variable ColRightX        ;# right-edge x px per metadata column, for header click mapping
    variable ColW             ;# effective widths per metadata column, parallel to column_spec
    variable ColWMeasured     ;# measured-from-sample widths, the override-or-measured base
    variable ColWOverride     ;# col id -> user width px (a manual resize), else absent
    variable ColMinW          ;# col id -> minimum width px clamp, else a default floor
    variable ColGap           ;# gap px between metadata cells
    variable ResizeCol        ;# index of the column being drag-resized, or "" when none
    variable ResizeX0         ;# header x (column space) the resize drag began at
    variable ResizeW0         ;# the column's width when the resize drag began
    variable ColHandles       ;# the visible vertical resize-handle rules over the header
    variable Opts             ;# widget options decoupling the engine from any host app
    variable SubjectMax       ;# px the subject may fill before the metadata block
    variable FolderLabelMax   ;# px a root label may fill before its aggregates
    variable LayoutW          ;# Text width the current layout was computed for
    variable RelayoutPending  ;# 1 while a debounced relayout is queued
    variable SortKey          ;# active sort column id
    variable SortDir          ;# desc | asc
    variable ResortTimer      ;# after-id of the debounced resort, or "" when none is pending
    variable AtTop            ;# anchor state across a streaming insert
    variable AtBottom         ;# tail-latch state across a streaming insert (-autofollow)
    variable WasAtBottom      ;# last observed bottom state, edges fire <<AtBottom>>/<<LeftBottom>>

    # ---- generic node store ------------------------------------------
    #
    # A node id is allocated from NextId; the store keeps the structural fields
    # (parent/kind/key/expanded/rendered/start/end/tag/children) generic and
    # hangs the domain dict off `payload`. The accessors below are the single
    # door to the store.

    method reset_nodes {} {
        set Nodes [dict create]
        set Roots [list]
    }

    method node_new {kind parent key payload} {
        set id "node[incr NextId]"
        # `key` is the node's domain key (the subclass's reverse-lookup key),
        # kept out of payload so payload stays the pristine per-entity dict.
        dict set Nodes $id [dict create \
            parent $parent kind $kind key $key expanded 0 rendered 0 hidden 0 \
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
    method roots {} { return $Roots }

    # ---- structural invariant ----------------------------------------
    #
    # The mark contract every structural mutation must preserve: each root's
    # [start,end] region is well-formed (end >= start) and the roots are ordered
    # and disjoint down the buffer. A violation means a mark desynced - the class
    # of fault behind merged headings and rows that escape their folder. Gated on
    # the STREAMTREE_AUDIT env var so production pays nothing; when on, it logs the
    # first violation with the call chain and latches off, naming the primitive
    # that broke the contract. Every primitive calls this at its tail.
    method check_invariant {where} {
        if {![info exists ::env(STREAMTREE_AUDIT)]} return
        if {[info exists ::STREAMTREE_AUDIT_TRIPPED]} return
        set probs [list]
        set prev_end ""
        set prev_key ""
        foreach fid $Roots {
            if {![dict exists $Nodes $fid]} continue
            set s [my node_field $fid start]
            set e [my node_field $fid end]
            if {$s eq "" || $e eq ""} continue
            if {[catch {$Text index $s} si]} { lappend probs "[my node_field $fid key]: unresolvable start"; continue }
            if {[catch {$Text index $e} ei]} { lappend probs "[my node_field $fid key]: unresolvable end"; continue }
            if {[$Text compare $e < $s]} {
                lappend probs "[my node_field $fid key]: end($ei) before start($si)"
            }
            if {$prev_end ne "" && [$Text compare $s < $prev_end]} {
                lappend probs "[my node_field $fid key] start($si) overlaps prev '$prev_key' end($prev_end)"
            }
            # TailMark is the append point: it must sit at or after every root's
            # end. If a folder's content extends past TailMark, TailMark drifted
            # up into the body and the next append will splice into that folder.
            if {[$Text compare TailMark < $e]} {
                lappend probs "TailMark([$Text index TailMark]) drifted above [my node_field $fid key] end($ei)"
            }
            set prev_end $ei
            set prev_key [my node_field $fid key]
        }
        if {[llength $probs]} {
            set ::STREAMTREE_AUDIT_TRIPPED 1
            puts stderr "INVARIANT @ $where : [join $probs {; }] | TailMark=[$Text index TailMark] end=[$Text index end]"
            for {set l [info level]} {$l > 0} {incr l -1} {
                puts stderr "   <- [string range [info level $l] 0 70]"
            }
        }
    }

    # ---- widget options ----------------------------------------------
    #
    # The engine takes its host-specific bindings as options so its body holds no
    # app references: two font names, a colours dict (the header strip background,
    # its muted label ink, the active-column ink), the debounce a streamed resort
    # waits out, and a motion callback the drag-to-move host wires in. Defaults
    # are a plain Tk look so the widget runs standalone; a host overrides them
    # through `configure` before the body is built.
    method engine_default_opts {} {
        return [dict create \
            listfont TkTextFont \
            headfont TkHeadingFont \
            colours [dict create strip #ececec muted #767676 ink #1d1d1d] \
            resortdelay 250 \
            autofollow 0 \
            motioncb ""]
    }
    method configure {args} {
        if {![info exists Opts]} { set Opts [my engine_default_opts] }
        set known [my engine_default_opts]
        foreach {opt val} $args {
            set k [string trimleft $opt -]
            if {![dict exists $known $k]} { error "unknown option $opt" }
            dict set Opts $k $val
        }
    }
    method opt {k} {
        if {![info exists Opts]} { set Opts [my engine_default_opts] }
        return [dict get $Opts $k]
    }
    method colour {role} { return [dict get [my opt colours] $role] }

    # ---- body assembly -----------------------------------------------

    # The whole construction ritual in one call, for a host without bespoke
    # assembly needs: seed the engine state, build the body and header into
    # `parent` (a frame the host owns and packs), and lay out the columns. A
    # subclass constructor calls `my configure ...` first when it overrides the
    # look, then `my setup $parent`. The initial sort is the subject key when
    # the subclass defines one, else the first sortable metadata column.
    method setup {parent} {
        set Top $parent
        my reset_nodes
        set NextId 0
        set SortKey [my subject_sort_id]
        if {$SortKey eq ""} {
            foreach col [my column_spec] {
                lassign $col id label sample align sortable
                if {$sortable} { set SortKey $id; break }
            }
        }
        set SortDir [expr {$SortKey ne "" ? [my default_sort_dir $SortKey] : "desc"}]
        set RelayoutPending 0
        set ResortTimer ""
        set LayoutW -1
        my build_body
        my compute_col_widths
        my build_header
        update idletasks
        my relayout
    }

    # The body grid: the sortable column header in row 0 (same column as the
    # text below it, so its labels share the text's width and the right-pinned
    # metadata columns line up), the list text and its scrollbar in row 1 (the
    # scrollbar beside the text only, never under the header).
    method build_body {} {
        ttk::frame $Top.body
        pack $Top.body -side top -fill both -expand 1
        text $Top.body.hdr -height 1 -wrap none -state disabled -takefocus 0 \
            -exportselection 0 -borderwidth 0 -highlightthickness 0 \
            -padx 8 -pady 1 -cursor hand2 -font [my opt listfont] \
            -background [my colour strip] \
            -foreground [my colour muted]
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
        # Re-pin the metadata columns and re-fit the subject ellipsis on resize.
        bind $Text <Configure> [list [self] on_text_configure %w]
        # This is a list, not editable text: make the click-drag text selection
        # invisible (it otherwise paints rows grey, active and inactive) and
        # hide the insert cursor.
        $Text configure -insertwidth 0 -inactiveselectbackground "" \
            -selectbackground [$Text cget -background] \
            -selectforeground [$Text cget -foreground]

        $Text mark set TailMark "end-1c"
        $Text mark gravity TailMark right

        # This is an object list, not editable text. Block the Text class's
        # selection gestures so a click never starts a text selection (which
        # would grab the X PRIMARY clipboard and, via tk::TextAutoScan, run a
        # self-scrolling drag-select). The per-tag click/drag bindings fire
        # first; these widget-level breaks stop the class bindings that follow.
        # B1-Motion still drives the host's motion callback, then breaks the
        # class handler (an empty callback just breaks, blocking selection).
        bind $Text <B1-Motion> "[my opt motioncb]; break"
        foreach ev {<Button-1> <Double-Button-1> <Triple-Button-1> \
                    <Shift-Button-1> <Control-Button-1> <B1-Leave>} {
            bind $Text $ev break
        }
    }

    # Text widget yview update: forward to the scrollbar, and edge-detect the
    # tail so a host can mirror the tail -f contract: <<AtBottom>> fires on the
    # host frame when the view reaches the last line, <<LeftBottom>> when the
    # reader scrolls away from it.
    method on_yscroll {args} {
        $Top.body.sb set {*}$args
        set now [expr {[lindex $args 1] >= 0.999}]
        if {![info exists WasAtBottom]} { set WasAtBottom $now; return }
        if {$now != $WasAtBottom} {
            set WasAtBottom $now
            event generate $Top [expr {$now ? "<<AtBottom>>" : "<<LeftBottom>>"}]
        }
    }

    # Jump to the tail and latch there, so with -autofollow on the view keeps
    # following streamed appends until the reader scrolls away.
    method follow {} {
        $Text yview moveto 1
    }

    # ---- column geometry ---------------------------------------------

    # Measure the metadata cells once in the list font (it is fixed, so the
    # widths never change at runtime). layout_columns turns these into positions;
    # doing the measuring once keeps resize cheap.
    method compute_col_widths {} {
        set ColGap [font measure [my opt listfont] "  "]
        if {![info exists ColWOverride]} { set ColWOverride [dict create] }
        if {![info exists ColMinW]} { set ColMinW [dict create] }
        if {![info exists ResizeCol]} { set ResizeCol "" }
        set ColWMeasured [list]
        foreach col [my column_spec] {
            lassign $col id label sample
            # A column must be wide enough for both its widest cell (the sample)
            # and its header label with the sort arrow, so a short-sampled column
            # like Turns never has its "Turns ▾" heading spill into the neighbour.
            set ws [font measure [my opt listfont] $sample]
            set wl [font measure [my opt headfont] "$label ▾"]
            lappend ColWMeasured [expr {$ws > $wl ? $ws : $wl}]
        }
        set ColW [my effective_col_widths]
    }

    # The width each column actually lays out at: a user override when set
    # (manual resize), else the measured width, each held at or above its minimum
    # (an explicit per-column minwidth, or a small floor so a column never
    # collapses to nothing).
    method effective_col_widths {} {
        set out [list]
        set i 0
        foreach col [my column_spec] {
            set id [lindex $col 0]
            set w [lindex $ColWMeasured $i]
            if {[dict exists $ColWOverride $id]} { set w [dict get $ColWOverride $id] }
            set minw [dict getdef $ColMinW $id 16]
            if {$w < $minw} { set w $minw }
            lappend out $w
            incr i
        }
        return $out
    }

    # Treeview-style column control: `column <id> -width N -minwidth M`. -width
    # sets a manual override (the resize drag uses the same path); -minwidth sets
    # the clamp the override and the drag honour. Re-lays out so the change
    # round-trips to the rendered rows.
    method column {id args} {
        foreach {opt val} $args {
            switch -- $opt {
                -width    { dict set ColWOverride $id $val }
                -minwidth { dict set ColMinW $id $val }
                default   { error "unknown column option $opt" }
            }
        }
        set ColW [my effective_col_widths]
        my relayout
    }

    # Pin the metadata strip flush to the list's right edge for the current
    # width: the last column's right edge sits a hair inside the edge and each
    # earlier column stacks leftward by its width plus a gap, so the subject gets
    # whatever room is left before the leftmost column. Right tab stops put each
    # cell's right edge on its stop. Called at build and on every resize; it only
    # repositions (cheap), the per-row ellipsis refit is the separate relayout.
    method layout_columns {} {
        set ColW [my effective_col_widths]
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
        # Floor the stops to a strictly increasing positive sequence: at the
        # build-time placeholder width, or a very narrow window at high DPI, the
        # right-to-left arithmetic can leave the leftmost stops non-positive, and
        # Tk rejects a tab stop that is not positive or not greater than the one
        # before it. The real positions recompute on <Configure> once mapped.
        set ColTabs [::streamtree::sane_tabs $ColTabs]
        if {$n == 0} {
            # No metadata columns: the subject and a root label may run to the
            # full width.
            set SubjectMax [expr {$cw - 12}]
            set FolderLabelMax [expr {$cw - 16}]
        } else {
            # Subject runs up to just before the leftmost metadata column.
            set first_rx [lindex $rights 0]
            set SubjectMax [expr {$first_rx - [lindex $ColW 0] - $ColGap - 12}]
            # A root label has no date cell, so it may run up to the first tab
            # stop before its aggregates; cap it just short of that.
            set FolderLabelMax [expr {$first_rx - 16}]
        }
        if {$SubjectMax < 80} { set SubjectMax 80 }
        if {$FolderLabelMax < 60} { set FolderLabelMax 60 }
        my apply_column_tabs $ColTabs
        if {[winfo exists $Top.body.hdr]} { $Top.body.hdr configure -tabs $ColTabs }
        my draw_column_handles
    }

    # The visible resize affordance: a thin vertical rule down the header at each
    # column's left-edge handle, in the muted heading ink, so the boundary the
    # cursor snaps to is something the eye can also find. The rules carry the
    # resize bindings, so grabbing the line drives the same drag as the wider
    # cursor zone the header detects. They reposition with the columns on every
    # layout pass (including live during a drag).
    method draw_column_handles {} {
        if {![winfo exists $Top.body.hdr]} return
        set h $Top.body.hdr
        if {![info exists ColHandles]} { set ColHandles [list] }
        set n [llength $ColW]
        while {[llength $ColHandles] < $n} {
            set w $h.sep[llength $ColHandles]
            frame $w -width 1 -background [my colour muted] \
                -cursor sb_h_double_arrow -takefocus 0
            bind $w <ButtonPress-1>   [list [self] on_handle press %X]
            bind $w <B1-Motion>       [list [self] on_handle drag %X]
            bind $w <ButtonRelease-1> [list [self] on_handle release %X]
            lappend ColHandles $w
        }
        for {set i 0} {$i < [llength $ColHandles]} {incr i} {
            set w [lindex $ColHandles $i]
            if {$i < $n} {
                set x [expr {[lindex $ColRightX $i] - [lindex $ColW $i] + 8}]
                place $w -in $h -x $x -rely 0 -relheight 1
                raise $w
            } else {
                place forget $w
            }
        }
    }
    # A resize gesture begun on a handle rule rather than in the header's cursor
    # zone: convert the root x to the header column space the handlers expect.
    method on_handle {phase X} {
        set hx [expr {$X - [winfo rootx $Top.body.hdr]}]
        switch $phase {
            press   { my on_header_press $hx }
            drag    { my on_header_drag $hx }
            release { my on_header_release $hx }
        }
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
        my relayout_content
        $Text configure -state disabled
    }

    # ---- sortable header ----------------------------------------------
    #
    # The sortable column header lives in row 0 of the body grid (created in
    # build_body, so it shares the text's width). It shares a row's font and tab
    # stops, so its right-pinned labels sit over the columns. Clicking a metadata
    # column sorts by it; clicking the active one flips the direction. Clicking
    # the subject zone sorts by the domain's subject key, when it defines one.
    method build_header {} {
        set h $Top.body.hdr
        set ResizeCol ""
        $h tag configure colactive -font [my opt headfont] -foreground [my colour ink]
        # A drag near a column boundary resizes that column; a press-and-release
        # that did not start on a boundary sorts (sort fires on release so a
        # resize drag does not also sort). Motion shows the resize cursor when the
        # pointer is over a boundary.
        bind $h <Motion>         [list [self] on_header_motion %x]
        bind $h <ButtonPress-1>  [list [self] on_header_press %x]
        bind $h <B1-Motion>      [list [self] on_header_drag %x]
        bind $h <ButtonRelease-1> [list [self] on_header_release %x]
        my draw_header
    }

    # The column whose left-edge resize handle sits within a few px of header x
    # (column space), or "" when the pointer is not on a boundary. A column's
    # left edge is its right edge less its width; dragging it left widens the
    # column (the columns to its left and the subject absorb the change).
    method boundary_col {cx} {
        set n [llength $ColW]
        for {set i 0} {$i < $n} {incr i} {
            set left [expr {[lindex $ColRightX $i] - [lindex $ColW $i]}]
            if {abs($cx - $left) <= 4} { return $i }
        }
        return ""
    }
    method on_header_motion {x} {
        if {$ResizeCol ne ""} return
        set cx [expr {$x - 8}]
        if {[my boundary_col $cx] ne ""} {
            $Top.body.hdr configure -cursor sb_h_double_arrow
        } else {
            $Top.body.hdr configure -cursor hand2
        }
    }
    method on_header_press {x} {
        set cx [expr {$x - 8}]
        set col [my boundary_col $cx]
        if {$col ne ""} {
            set ResizeCol $col
            set ResizeX0 $cx
            set ResizeW0 [lindex $ColW $col]
        } else {
            set ResizeCol ""
        }
    }
    method on_header_drag {x} {
        if {$ResizeCol eq ""} return
        set cx [expr {$x - 8}]
        # The column's right edge is pinned, so dragging its left-edge handle
        # left (cx down) widens it by the same amount.
        set id [lindex [lindex [my column_spec] $ResizeCol] 0]
        set w [expr {$ResizeW0 + ($ResizeX0 - $cx)}]
        set minw [dict getdef $ColMinW $id 16]
        if {$w < $minw} { set w $minw }
        dict set ColWOverride $id $w
        # Re-pin the tab stops live (cheap); the per-row subject refit waits for
        # release, where relayout runs the full pass.
        my layout_columns
        my draw_header
    }
    method on_header_release {x} {
        if {$ResizeCol ne ""} {
            set ResizeCol ""
            my relayout
        } else {
            my on_header_click $x
        }
    }

    # The domain's sort id for the non-metadata subject zone, or "" when the
    # subject is not sortable (the engine default). A subclass overrides this so
    # the leftmost header sorts.
    method subject_sort_id {} { return "" }

    # Map a header click x (widget pixels) to a metadata column and sort by it.
    # Each column occupies [right_edge - width, right_edge]; a click left of the
    # leftmost column is the subject zone and sorts by the domain's subject key,
    # when it defines one; a click in the gaps sorts nothing.
    method on_header_click {x} {
        set cx [expr {$x - 8}]
        set cols [my column_spec]
        if {![llength $cols]} {
            set sid [my subject_sort_id]
            if {$sid ne ""} { my set_sort $sid }
            return
        }
        for {set i 0} {$i < [llength $cols]} {incr i} {
            lassign [lindex $cols $i] id label sample align sortable
            set rx [lindex $ColRightX $i]
            set lo [expr {$rx - [lindex $ColW $i] - 6}]
            if {$cx >= $lo && $cx <= $rx + 4} {
                if {$sortable} { my set_sort $id }
                return
            }
        }
        set first_lo [expr {[lindex $ColRightX 0] - [lindex $ColW 0] - 6}]
        if {$cx < $first_lo} {
            set sid [my subject_sort_id]
            if {$sid ne ""} { my set_sort $sid }
        }
    }

    # The direction a freshly-adopted sort key starts in. Metadata columns lead
    # with their largest value (descending); a subclass may override per id.
    method default_sort_dir {id} { return "desc" }

    # Adopt a new sort key in its default direction, or flip the direction when
    # the active key is clicked again, then re-render the list in the new order.
    method set_sort {id} {
        if {$SortKey eq $id} {
            set SortDir [expr {$SortDir eq "desc" ? "asc" : "desc"}]
        } else {
            set SortKey $id
            set SortDir [my default_sort_dir $id]
        }
        my cancel_resort
        my rebuild
        my draw_header
    }

    # Paint the header labels: the subject column on the left, then the
    # right-pinned metadata labels over their columns, the active one marked with
    # a direction arrow and bold ink.
    method draw_header {} {
        set h $Top.body.hdr
        $h configure -state normal
        $h delete 1.0 end
        set line [my subject_label]
        set act_off -1
        set act_len 0
        set subj_id [my subject_sort_id]
        if {$subj_id ne "" && $SortKey eq $subj_id} {
            append line [expr {$SortDir eq "desc" ? " ▾" : " ▴"}]
            set act_off 0
            set act_len [string length $line]
        }
        foreach col [my column_spec] {
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

    # ---- sort ordering ------------------------------------------------

    # Order a list of domain keys by the active sort. Each value reads a cached
    # payload field through the sort_key hook; date descending reproduces the
    # mtime-descending streaming order. src maps a key to its payload (the live
    # model on expand, the pre-rebuild snapshot in redraw_all).
    method sort_paths {paths src} {
        set keyed [list]
        foreach p $paths {
            set v -1
            if {[dict exists $src $p]} {
                set v [my sort_key [dict get $src $p] $SortKey]
            }
            lappend keyed [list $p $v]
        }
        set dir [expr {$SortDir eq "asc" ? "-increasing" : "-decreasing"}]
        return [lmap e [lsort -real -index 1 $dir $keyed] { lindex $e 0 }]
    }

    # Order folder keys by a folder->value map. mode picks the lsort comparator:
    # -real for the numeric cost aggregate, -dictionary for the string path label.
    method sort_folders {order valmap {mode -real}} {
        set dflt [expr {$mode eq "-real" ? 0.0 : ""}]
        set keyed [lmap f $order { list $f [dict getdef $valmap $f $dflt] }]
        set dir [expr {$SortDir eq "asc" ? "-increasing" : "-decreasing"}]
        return [lmap e [lsort $mode -index 1 $dir $keyed] { lindex $e 0 }]
    }

    method is_default_sort {} {
        return [expr {$SortKey eq "date" && $SortDir eq "desc"}]
    }

    # A row streamed or recosted under a non-default sort lands out of order.
    # Debounce a single full re-render to restore the sort: each arrival resets
    # the timer, so a metric flood resolves to one rebuild when arrivals pause,
    # and the list stays still (in arrival order) while they stream. The default
    # sort needs none (streaming order is already correct), so this no-ops then.
    method schedule_resort {} {
        if {[my is_default_sort]} return
        if {$ResortTimer ne ""} { after cancel $ResortTimer }
        set ResortTimer [after [my opt resortdelay] \
            [list [self] do_resort]]
    }
    method do_resort {} {
        set ResortTimer ""
        if {[my is_default_sort]} return
        my rebuild
    }
    # Drop a pending debounced resort. Called before a synchronous redraw_all
    # (a header click), so a stale timer cannot fire a second redundant rebuild
    # just after the user starts interacting with the freshly-sorted list.
    method cancel_resort {} {
        if {$ResortTimer ne ""} { after cancel $ResortTimer; set ResortTimer "" }
    }

    # ---- view-anchoring around streaming inserts ----------------------
    #
    # A streaming insert must not shift what the reader is looking at. Three
    # cases: with -autofollow on and the reader at the tail, keep them latched to
    # the tail so streamed appends keep scrolling into view (the tail -f / chat
    # contract, released the moment they scroll away); if the reader is at the
    # very top (the default while browsing or watching results arrive), keep them
    # pinned to the absolute top so the newest content and the heading stay in
    # view; if they have scrolled into the list, pin the character that was at
    # the top so an insert above it scrolls to compensate and their line does not
    # move.
    method anchor_save {} {
        lassign [$Text yview] first last
        set AtTop    [expr {$first <= 0.0001}]
        set AtBottom [expr {$last >= 0.999}]
        $Text mark set AnchorTop @0,0
        $Text mark gravity AnchorTop left
    }
    method anchor_restore {} {
        if {[my opt autofollow] && [info exists AtBottom] && $AtBottom} {
            $Text yview moveto 1
        } elseif {[info exists AtTop] && $AtTop} {
            $Text yview moveto 0
        } else {
            catch {$Text yview AnchorTop}
        }
        catch {$Text mark unset AnchorTop}
    }

    # The rendered node whose row sits at the top of the viewport, as {kind key},
    # or "" when the list is empty. redraw_all re-anchors the view by this rather
    # than by the AnchorTop mark, which cannot survive its `$Text delete 1.0 end`.
    # Scans node start marks (not tags) so a snippet or child-snippet line, which
    # owns no node, resolves to its containing node: the answer is the rendered
    # node with the greatest start line <= the top visible line.
    method top_visible_node {} {
        set topline [lindex [split [$Text index @0,0] .] 0]
        set best ""
        set bestline -1
        foreach id [my all_rendered_nodes] {
            set m [my node_field $id start]
            if {$m eq ""} continue
            set ln [lindex [split [$Text index $m] .] 0]
            if {$ln <= $topline && $ln > $bestline} {
                set bestline $ln
                set best $id
            }
        }
        if {$best eq ""} { return "" }
        return [list [my node_field $best kind] [my node_field $best key]]
    }

    # Every node currently drawn in the widget, parents before children: each
    # root (folder headings are always drawn), each root's rendered session
    # children, and those sessions' rendered subagent children.
    method all_rendered_nodes {} {
        set out [list]
        foreach fid $Roots {
            lappend out $fid
            foreach sid [my node_field $fid children] {
                if {![my node_field $sid rendered]} continue
                lappend out $sid
                foreach cid [my node_field $sid children] {
                    if {[my node_field $cid rendered]} { lappend out $cid }
                }
            }
        }
        return $out
    }

    # ---- generic line engine ------------------------------------------
    #
    # A row is the subject (the node's left side, built by render_subject) plus a
    # right-pinned metadata strip laid by the engine from cell_values: each cell
    # is preceded by a tab, so the column tab stops align it under the header.
    # build_line returns the text and a per-column {off len} map; apply_line tags
    # the subject ranges, the contiguous metadata run (when meta_run is set), and
    # each cell's overlay tags from cell_tag.

    # Trim text to fit px in font, appending an ellipsis when it is cut. A binary
    # search on the character count keeps it cheap for long previews.
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

    # Build one row's text: the subject from render_subject, then the metadata
    # cells from cell_values pinned to the right by the column tab stops. Returns
    # {line subject subjtags meta_run meta_off offs}, where offs maps each laid
    # column id to its {off len} range for cell tagging.
    method build_line {node} {
        set sub [my render_subject $node $SubjectMax]
        set subject [dict get $sub subject]
        set subjtags [dict getdef $sub tags {}]
        set meta_run [dict getdef $sub meta_run 0]
        set meta_off [string length $subject]
        set line $subject
        set offs [dict create]
        foreach pair [my cell_values $node] {
            lassign $pair col val
            append line "\t"
            set off [string length $line]
            append line $val
            dict set offs $col [list $off [string length $val]]
        }
        return [dict create line $line subject $subject subjtags $subjtags \
            meta_run $meta_run meta_off $meta_off offs $offs]
    }

    # Tag a freshly-inserted (or rewritten-in-place) row from its build_line
    # info: the contiguous muted metadata run on the right (when meta_run is
    # set), the subject-relative ranges from render_subject, then each non-empty
    # cell's overlay tags from cell_tag.
    method apply_line {node row_start info} {
        if {[dict get $info meta_run]} {
            $Text tag add meta \
                "$row_start + [dict get $info meta_off]c" "$row_start lineend"
        }
        foreach r [dict get $info subjtags] {
            lassign $r tag off len
            if {$len <= 0} continue
            $Text tag add $tag "$row_start + ${off}c" \
                "$row_start + [expr {$off + $len}]c"
        }
        dict for {col range} [dict get $info offs] {
            lassign $range off len
            if {$len <= 0} continue
            foreach tag [my cell_tag $node $col] {
                $Text tag add $tag "$row_start + ${off}c" \
                    "$row_start + [expr {$off + $len}]c"
            }
        }
    }

    # ---- structural primitives ----------------------------------------
    #
    # The engine owns every text-mark mutation behind a small treeview-style
    # ensemble (insert/delete/detach/item/expand/collapse/hide/unhide/move/
    # rebuild) plus a content door (append_open/emit/append_close) for loose
    # in-row content that is not itself a node. A subclass drives the widget
    # only through these; it supplies content through the render hooks
    # (build_line/render_subject/cell_values) and reacts through the lifecycle
    # hooks (start_gravity/row_tags/on_row_rendered/on_before_delete). Each
    # primitive asserts the widget editable on entry (so a re-entrant call can
    # never run against a -state disabled widget and drop its inserts) and ends
    # in check_invariant, so the audit gate names whichever primitive breaks the
    # mark contract.

    # Run a script with the widget editable and the view anchored once, restoring
    # the prior state after. A streaming flush brackets many inserts in one batch
    # so the reader's scroll position is saved and restored a single time.
    method batch {script} {
        set st [$Text cget -state]
        $Text configure -state normal
        my anchor_save
        set code [catch {uplevel 1 $script} res opts]
        my anchor_restore
        $Text configure -state $st
        return -options $opts $res
    }

    # The lifecycle hooks. Defaults suit a plain list; the session subclass
    # overrides them. start_gravity fixes a row's start mark (right keeps a
    # heading pinned to its own line when a sibling above expands; left pins a
    # nested row to its parent's append point). row_tags are the static style
    # tags every row of a kind carries. on_row_rendered runs after a row is laid
    # (bindings, nested content, selection). on_before_delete runs before a node
    # leaves the store (drop domain indices and aggregates). populate runs at the
    # top of expand, so a lazy host can enumerate and attach the node's children
    # right before the engine draws them; a fully materialized tree leaves it
    # as the no-op default.
    method start_gravity {kind} { return right }
    method row_tags {kind} { return [list] }
    method on_node_created {id} {}
    method on_row_rendered {id} {}
    method on_before_delete {id} {}
    method populate {id} {}

    # Content hooks, all with working defaults so a minimal subclass renders
    # something sensible before overriding anything: no metadata columns, the
    # row text from the payload's `label` (falling back to the node's key), no
    # cell content, tabs applied widget-wide, and a relayout that re-renders
    # every drawn row in place. A host with columns overrides column_spec,
    # cell_values and render_subject; a host whose row tags carry their own
    # -tabs overrides apply_column_tabs to configure those tags instead.
    method subject_label {} { return "" }
    method column_spec {} { return [list] }
    method render_subject {node max} {
        return [dict create subject [my node_pget $node label [my node_field $node key]] \
            tags [list] meta_run 0]
    }
    method cell_values {node} { return [list] }
    method cell_tag {node col} { return "" }
    method sort_key {payload col} { return "" }
    method apply_column_tabs {tabs} { $Text configure -tabs $tabs }
    method relayout_content {} { foreach id [my all_rendered_nodes] { my item $id } }

    # Lay a node's row at its parent's append point and register its marks. The
    # one home for the right-gravity-temp-mark insert and the ancestor-end
    # advance that the per-kind render methods each used to repeat: a left-gravity
    # end mark stays left of an insert, so every ancestor whose end currently
    # sits at the append point must be carried forward past the new row (a folder
    # end follows only its own last session down; a session in the middle relies
    # on the insert shifting the lower end mark on its own). Both insert and
    # expand/unhide route through here.
    method render_row {id} {
        set parent [my node_field $id parent]
        set kind   [my node_field $id kind]
        if {$parent eq ""} {
            # A root appends after every existing one, so its append point is the
            # true buffer end by definition: re-anchor TailMark there rather than
            # trust a value an upstream op may have drifted into a folder body.
            $Text mark set TailMark "end - 1 chars"
            $Text mark gravity TailMark right
            set ins TailMark
        } else {
            set ins [my node_field $parent end]
        }
        set insidx [$Text index $ins]
        set climb [list]
        for {set p $parent} {$p ne ""} {set p [my node_field $p parent]} {
            set pe [my node_field $p end]
            if {$pe ne "" && [$Text compare $pe == $insidx]} { lappend climb $p }
        }
        set tag "${id}_t"
        set info [my build_line $id]
        set tmp "__rowins"
        $Text mark set $tmp $insidx
        $Text mark gravity $tmp right
        set rstart [$Text index $tmp]
        $Text insert $tmp "[dict get $info line]\n" [list {*}[my row_tags $kind] $tag]
        my apply_line $id $rstart $info
        set rowend [$Text index $tmp]
        $Text mark unset $tmp
        set sm "${id}_s"
        $Text mark set $sm $rstart
        $Text mark gravity $sm [my start_gravity $kind]
        set em "${id}_e"
        $Text mark set $em $rowend
        $Text mark gravity $em left
        my node_set $id tag $tag
        my node_set $id start $sm
        my node_set $id end $em
        my node_set $id rendered 1
        foreach a $climb { $Text mark set [my node_field $a end] $rowend }
        my on_row_rendered $id
    }

    # Un-render every node at once, for the two whole-buffer paths (rebuild,
    # reset). Order matters for speed: marks are unset BEFORE the text delete,
    # while they are still spread across the buffer. Deleting the text first
    # collapses every mark into one pile at 1.0, and each subsequent unset then
    # walks that pile: quadratic, seconds at 10k rows. Batched single calls
    # spare the per-mark command dispatch as well.
    method mass_unrender {} {
        set marks [list]
        set tags [list]
        foreach id [my all_node_ids] {
            set s [my node_field $id start]
            if {$s ne ""} { lappend marks $s [my node_field $id end] }
            set g [my node_field $id tag]
            if {$g ne ""} { lappend tags $g }
            my node_set $id start ""
            my node_set $id end ""
            my node_set $id tag ""
            my node_set $id rendered 0
        }
        if {[llength $marks]} { catch {$Text mark unset {*}$marks} }
        $Text delete 1.0 end
        if {[llength $tags]} { catch {$Text tag delete {*}$tags} }
    }

    # Reset a node's render state (drop its marks and tag, clear rendered) without
    # touching the buffer: the shared tail of detach/collapse, which delete the
    # text in bulk and then clear the per-node bookkeeping.
    method drop_render_marks {id} {
        set s [my node_field $id start]
        set e [my node_field $id end]
        if {$s ne "" || $e ne ""} { catch {$Text mark unset $s $e} }
        set tag [my node_field $id tag]
        if {$tag ne "" && [llength [$Text tag ranges $tag]] == 0} {
            catch {$Text tag delete $tag}
        }
        my node_set $id start ""
        my node_set $id end ""
        my node_set $id tag ""
        my node_set $id rendered 0
    }

    # insert: add a node and draw it if its parent is open. parent "" makes a
    # root. -pos {before <id>} orders it before a sibling, else it appends.
    method insert {parent kind key payload args} {
        set before ""
        foreach {opt val} $args {
            if {$opt eq "-pos" && [lindex $val 0] eq "before"} { set before [lindex $val 1] }
        }
        set st [$Text cget -state]
        $Text configure -state normal
        set id [my node_new $kind $parent $key $payload]
        if {$parent eq ""} {
            if {$before ne ""} {
                set i [lsearch -exact $Roots $before]
                set Roots [linsert $Roots [expr {$i < 0 ? "end" : $i}] $id]
            } else {
                lappend Roots $id
            }
        } else {
            set kids [my node_field $parent children]
            if {$before ne ""} {
                set i [lsearch -exact $kids $before]
                set kids [linsert $kids [expr {$i < 0 ? "end" : $i}] $id]
            } else {
                lappend kids $id
            }
            my node_set $parent children $kids
        }
        # Let the subclass register its domain indices for this node before the
        # row renders: render_subject may read the node back through an index
        # (a folder heading counts its sessions through the folder->id map), so
        # the index must exist by the time render_row builds the line.
        my on_node_created $id
        set open [expr {$parent eq "" || [my node_field $parent expanded]}]
        if {$open && ![my node_field $id hidden]} { my render_row $id }
        $Text configure -state $st
        my check_invariant insert
        return $id
    }

    # delete: remove a node and its subtree from both the view and the store. The
    # node's whole region (its line and any descendant rows) goes in one delete,
    # then the subtree is unregistered: every node, descendants first, runs its
    # on_before_delete hook so the subclass drops that node's domain indices.
    method delete {id} {
        set st [$Text cget -state]
        $Text configure -state normal
        if {[my node_field $id rendered]} {
            $Text delete [my node_field $id start] [my node_field $id end]
        }
        my detach_child $id
        my forget_subtree $id
        $Text configure -state $st
        my check_invariant delete
    }

    # Unregister a node and its descendants from the store, running each node's
    # on_before_delete and dropping any marks and tags it still holds. The text
    # is assumed already gone (a bulk delete of the region, or never rendered).
    method forget_subtree {id} {
        foreach c [my node_field $id children] { my forget_subtree $c }
        my on_before_delete $id
        my drop_render_marks $id
        dict unset Nodes $id
    }
    # Remove a node from its parent's child list (or from Roots for a root).
    method detach_child {id} {
        set parent [my node_field $id parent]
        if {$parent eq ""} {
            set Roots [lsearch -all -inline -not -exact $Roots $id]
        } elseif {[dict exists $Nodes $parent]} {
            my node_set $parent children \
                [lsearch -all -inline -not -exact [my node_field $parent children] $id]
        }
    }

    # detach: remove a node's whole drawn region (its line and, if open, its
    # body) but keep it and its subtree in the store, so it can be re-rendered
    # later in the same expanded state. Unlike collapse, this leaves `expanded`
    # untouched: a node detached open re-renders open. The descendants' text went
    # with the bulk delete, so their render marks are reset for that re-render.
    method detach {id} {
        set st [$Text cget -state]
        $Text configure -state normal
        if {[my node_field $id rendered]} {
            $Text delete [my node_field $id start] [my node_field $id end]
            foreach c [my node_field $id children] { my reset_subtree_render $c }
        }
        my drop_render_marks $id
        $Text configure -state $st
        my check_invariant detach
    }

    # item: rewrite a rendered node's own line in place, leaving its subtree and
    # marks intact. The start mark has right gravity, so re-inserting at it would
    # carry it to the end of the new text: pin the row start as an index, lay the
    # line there, then reset the mark to the first char.
    method item {id} {
        if {![my node_field $id rendered]} return
        set st [$Text cget -state]
        $Text configure -state normal
        set sm [my node_field $id start]
        set tag [my node_field $id tag]
        set info [my build_line $id]
        set s0 [$Text index $sm]
        $Text delete $sm "$sm lineend"
        $Text mark gravity $sm left
        $Text insert $s0 [dict get $info line] [list {*}[my row_tags [my node_field $id kind]] $tag]
        $Text mark gravity $sm [my start_gravity [my node_field $id kind]]
        $Text mark set $sm $s0
        my apply_line $id $s0 $info
        $Text configure -state $st
        my check_invariant item
    }

    # expand: open a node and draw its not-hidden children. populate runs first,
    # so a lazy host realizes the children this expand is about to draw. On a
    # node that is not itself rendered, expand records the flag alone; the
    # children draw when the node's own row does, or on the next rebuild. That
    # makes opening one level everywhere a one-liner over any id set, e.g.
    #   $t batch { lmap id [$t roots] { $t expand $id } }
    method expand {id} {
        set st [$Text cget -state]
        $Text configure -state normal
        my populate $id
        my node_set $id expanded 1
        if {[my node_field $id rendered]} {
            foreach c [my node_field $id children] {
                if {![my node_field $c hidden]} { my render_row $c }
            }
        }
        $Text configure -state $st
        my check_invariant expand
    }

    # collapse: close a node and delete its body, keeping its own line and its
    # children in the store (their render marks are reset for a later expand).
    method collapse {id} {
        set st [$Text cget -state]
        $Text configure -state normal
        my node_set $id expanded 0
        set sm [my node_field $id start]
        set em [my node_field $id end]
        if {$sm ne "" && $em ne ""} {
            set bodystart [$Text index "$sm lineend +1c"]
            if {[$Text compare $bodystart < $em]} {
                $Text delete $bodystart $em
                $Text mark set $em $bodystart
            }
            foreach c [my node_field $id children] { my reset_subtree_render $c }
        }
        $Text configure -state $st
        my check_invariant collapse
    }
    # Clear render marks across a node and its descendants (their text just went
    # with a bulk body delete), so a later expand redraws them from scratch.
    method reset_subtree_render {id} {
        foreach c [my node_field $id children] { my reset_subtree_render $c }
        my drop_render_marks $id
    }

    # hide/unhide: a reversible per-node filter. hide removes the row in place
    # (same mechanism as detach) and marks it hidden; unhide clears the flag and
    # redraws it when its parent is open. Re-ordering a shown row into sorted
    # position is a rebuild, not an unhide.
    method hide {id} {
        my node_set $id hidden 1
        my detach $id
    }
    method unhide {id} {
        my node_set $id hidden 0
        set parent [my node_field $id parent]
        if {$parent eq "" || [my node_field $parent expanded]} {
            set st [$Text cget -state]
            $Text configure -state normal
            my render_row $id
            $Text configure -state $st
            my check_invariant unhide
        }
    }

    # move: reparent a node, then rebuild. A move can re-key the node and folder
    # regions are disjoint down the buffer, so an in-place splice is not honest;
    # a rebuild keeps the mark scheme consistent and moves are rare.
    method move {id newparent args} {
        my detach_child $id
        my node_set $id parent $newparent
        set kids [my node_field $newparent children]
        lappend kids $id
        my node_set $newparent children $kids
        my rebuild
    }

    # rebuild: re-render the whole list from the durable store, preserving the
    # reader's view. The store survives (it is the model), so this re-sorts the
    # sibling order in place (the sort_siblings hook, keeping every node), then
    # wipes the buffer and re-lays each root and its open, not-hidden
    # descendants. A node the render_skip hook rejects (a folder with no viewable
    # row) stays in the store but leaves the view. Store order tracks display
    # order, so a sort reorders Roots and each node's children, not just the
    # painted sequence.
    method rebuild {} {
        set st [$Text cget -state]
        $Text configure -state normal
        set at_top [expr {[lindex [$Text yview] 0] <= 0.0001}]
        set anchor [my top_visible_node]
        set Roots [my sort_siblings $Roots]
        foreach id [my all_node_ids] {
            my node_set $id children [my sort_siblings [my node_field $id children]]
        }
        # Un-render everything (marks, text, tags) so the re-render starts from
        # a clean buffer with no stale marks left to be dragged into an overlap.
        # The durable node store itself survives.
        my mass_unrender
        $Text mark set TailMark "end-1c"
        $Text mark gravity TailMark right
        foreach rid $Roots {
            if {[my render_skip $rid]} continue
            my render_subtree $rid
        }
        if {$at_top} { $Text yview moveto 0 } else { my rebuild_restore $anchor }
        $Text configure -state $st
        my check_invariant rebuild
    }
    # reset: empty the whole widget - wipe the buffer, drop every node's marks
    # and tag, re-anchor TailMark and clear the store. The base of a fresh view.
    method reset {} {
        set st [$Text cget -state]
        $Text configure -state normal
        my mass_unrender
        $Text mark set TailMark "end-1c"
        $Text mark gravity TailMark right
        my reset_nodes
        $Text configure -state $st
        my check_invariant reset
    }

    # Render a node and, when it is open, its not-hidden children in store order.
    method render_subtree {id} {
        my render_row $id
        if {[my node_field $id expanded]} {
            foreach c [my node_field $id children] {
                if {[my node_field $c hidden]} continue
                my render_subtree $c
            }
        }
    }
    # Every node id in the store, for the pre-rebuild render-state reset.
    method all_node_ids {} { return [dict keys $Nodes] }
    # Reorder a sibling set for display, keeping every node (a sort, not a
    # filter). Default keeps store order; the subclass applies the active sort.
    method sort_siblings {ids} { return $ids }
    # Whether to leave a node (and its subtree) out of the rendered view while
    # keeping it in the store. Default renders everything.
    method render_skip {id} { return 0 }
    # Re-pin the view to a {kind key} anchor after a rebuild. Default best-effort.
    method rebuild_restore {anchor} {}

    # ---- content door -------------------------------------------------
    #
    # Loose in-row content (a match snippet, a badge window) is not a node: it is
    # tagged text appended inside a node's region that must carry that node's end
    # mark, and every ancestor end mark coincident with it, forward. open at the
    # node's append point, emit pieces, then close to advance the marks.
    method append_open {id} {
        set m "__emit"
        $Text mark set $m [$Text index [my node_field $id end]]
        $Text mark gravity $m right
        return $m
    }
    method emit {mark text tags} {
        set i0 [$Text index $mark]
        $Text insert $mark $text $tags
        return [list $i0 [$Text index $mark]]
    }
    method emit_window {mark args} {
        set i0 [$Text index $mark]
        $Text window create $mark {*}$args
        return [list $i0 [$Text index $mark]]
    }
    method append_close {id mark} {
        set newend [$Text index $mark]
        set oldend [$Text index [my node_field $id end]]
        $Text mark set [my node_field $id end] $newend
        for {set p [my node_field $id parent]} {$p ne ""} {set p [my node_field $p parent]} {
            set pe [my node_field $p end]
            if {$pe ne "" && [$Text compare $pe == $oldend]} { $Text mark set $pe $newend }
        }
        $Text mark unset $mark
        my check_invariant append_close
    }

    # ---- drag hit-testing ---------------------------------------------

    # The text index under a root-coordinate point, or "" if outside the widget.
    method index_at {X Y} {
        set lx [expr {$X - [winfo rootx $Text]}]
        set ly [expr {$Y - [winfo rooty $Text]}]
        return [$Text index @$lx,$ly]
    }
    # Whether a root-coordinate click landed on a char carrying the named tag.
    method click_on_tag {X Y tag} {
        set idx [my index_at $X $Y]
        return [expr {[lsearch -exact [$Text tag names $idx] $tag] >= 0}]
    }
}
