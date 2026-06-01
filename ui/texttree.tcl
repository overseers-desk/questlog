package require Tcl 9
package require Tk

# ::questlog::ui::TextTree - the generic "tree drawn in one text widget" engine.
#
# A TextTree owns a tree of abstract NODES rendered into a single read-only
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
# Hooks the subclass overrides (Template Method):
#   column_spec                 the metadata columns {id label sample align sortable}
#   render_subject node max     the row's left side: {subject <str> tags <ranges> meta_run 0|1}
#                               (ranges is a list of {tag off len}, subject-relative)
#   cell_values node            ordered {col value} pairs the engine lays as cells
#   cell_tag node col           the tag names overlaid on that cell (empty for none)
#   sort_key payload col        the sort value for a column, from a node's payload
#   apply_column_tabs tabs      set the right tab stops on the subclass's row tags
#   redraw_all                  re-render the whole list under a new sort
#   relayout_content            re-fit every rendered row after a width change

oo::class create ::questlog::ui::TextTree {
    variable Top
    variable Text
    # The generic node store. Nodes maps a node id to its dict
    # {parent kind key expanded rendered start end tag children payload}; Roots
    # is the ordered list of root node ids, in arrival order.
    variable Nodes
    variable Roots
    variable NextId
    # Column geometry, measured once (the proportional list font is fixed) and
    # re-pinned on resize.
    variable ColTabs          ;# -tabs spec for a row (right-pinned metadata)
    variable ColRightX        ;# right-edge x px per metadata column, for header click mapping
    variable ColW             ;# measured widths per metadata column, parallel to column_spec
    variable ColGap           ;# gap px between metadata cells
    variable SubjectMax       ;# px the subject may fill before the metadata block
    variable FolderLabelMax   ;# px a root label may fill before its aggregates
    variable LayoutW          ;# Text width the current layout was computed for
    variable RelayoutPending  ;# 1 while a debounced relayout is queued
    variable SortKey          ;# active sort column id
    variable SortDir          ;# desc | asc
    variable ResortPending    ;# 1 while a debounced redraw is queued under a non-default sort
    variable AtTop            ;# anchor state across a streaming insert

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
    method roots {} { return $Roots }

    # ---- body assembly -----------------------------------------------
    #
    # The body grid: the sortable column header in row 0 (same column as the
    # text below it, so its labels share the text's width and the right-pinned
    # metadata columns line up), the list text and its scrollbar in row 1 (the
    # scrollbar beside the text only, never under the header).
    method build_body {} {
        ttk::frame $Top.body
        pack $Top.body -side top -fill both -expand 1
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
        # B1-Motion still drives drag-to-move, then breaks the class handler.
        bind $Text <B1-Motion> {::questlog::ui::drag::motion %X %Y; break}
        foreach ev {<Button-1> <Double-Button-1> <Triple-Button-1> \
                    <Shift-Button-1> <Control-Button-1> <B1-Leave>} {
            bind $Text $ev break
        }
    }

    # Text widget yview update: forward to the scrollbar.
    method on_yscroll {args} {
        $Top.body.sb set {*}$args
    }

    # ---- column geometry ---------------------------------------------

    # Measure the metadata cells once in QLList (the proportional list font is
    # fixed, so the widths never change at runtime). layout_columns turns these
    # into positions; doing the measuring once keeps resize cheap.
    method compute_col_widths {} {
        set ColGap [font measure QLList "  "]
        set ColW [list]
        foreach col [my column_spec] {
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
    # earlier column stacks leftward by its width plus a gap, so the subject gets
    # whatever room is left before the leftmost column. Right tab stops put each
    # cell's right edge on its stop. Called at build and on every resize; it only
    # repositions (cheap), the per-row ellipsis refit is the separate relayout.
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
        # Floor the stops to a strictly increasing positive sequence: at the
        # build-time placeholder width, or a very narrow window at high DPI, the
        # right-to-left arithmetic can leave the leftmost stops non-positive, and
        # Tk rejects a tab stop that is not positive or not greater than the one
        # before it. The real positions recompute on <Configure> once mapped.
        set ColTabs [my sane_tabs $ColTabs]
        # Subject runs up to just before the leftmost metadata column.
        set first_rx [lindex $rights 0]
        set SubjectMax [expr {$first_rx - [lindex $ColW 0] - $ColGap - 12}]
        if {$SubjectMax < 80} { set SubjectMax 80 }
        # A root label has no date cell, so it may run up to the first tab stop
        # before its aggregates; cap it just short of that.
        set FolderLabelMax [expr {$first_rx - 16}]
        if {$FolderLabelMax < 60} { set FolderLabelMax 60 }
        my apply_column_tabs $ColTabs
        if {[winfo exists $Top.body.hdr]} { $Top.body.hdr configure -tabs $ColTabs }
    }

    # Coerce a {pos align ...} tab spec to strictly increasing positive stops,
    # which Tk requires. Used to guard against the degenerate column geometry a
    # too-narrow width (build-time placeholder, or high DPI) can produce.
    method sane_tabs {tabs} {
        set out [list]
        set prev 0
        foreach {x align} $tabs {
            if {$x <= $prev} { set x [expr {$prev + 1}] }
            lappend out $x $align
            set prev $x
        }
        return $out
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
    # column sorts by it; clicking the active one flips the direction. The
    # subject zone on the left is not sortable.
    method build_header {} {
        set h $Top.body.hdr
        $h tag configure colactive -font QLBold -foreground [::questlog::ui::theme::c ink]
        bind $h <Button-1> [list [self] on_header_click %x]
        my draw_header
    }

    # Map a header click x (widget pixels) to a metadata column and sort by it.
    # Each column occupies [right_edge - width, right_edge]; a click in the
    # subject area or the gaps falls through and sorts nothing.
    method on_header_click {x} {
        set cx [expr {$x - 8}]
        set cols [my column_spec]
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

    # Paint the header labels: the subject column on the left, then the
    # right-pinned metadata labels over their columns, the active one marked with
    # a direction arrow and bold ink.
    method draw_header {} {
        set h $Top.body.hdr
        $h configure -state normal
        $h delete 1.0 end
        set line "Session"
        set act_off -1
        set act_len 0
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

    # ---- view-anchoring around streaming inserts ----------------------
    #
    # A streaming insert must not shift what the reader is looking at. Two cases:
    # if the reader is at the very top (the default while browsing or watching
    # results arrive), keep them pinned to the absolute top so the newest content
    # and the heading stay in view; if they have scrolled into the list, pin the
    # character that was at the top so an insert above it scrolls to compensate
    # and their line does not move.
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
