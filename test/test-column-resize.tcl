#!/usr/bin/env wish9.0
# Draggable metadata-column resize on the StreamTree engine: a width set through
# the `column` API (the same path the header drag drives) round-trips and
# re-pins the tab stops, the minimum-width clamp holds, and a header click away
# from a boundary still sorts.

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add $ROOT
package require streamtree
foreach f {config.tcl ui/theme.tcl ui/drag.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

# A minimal concrete StreamTree with three right-pinned, sortable metadata columns.
oo::class create Demo {
    superclass ::streamtree::StreamTree
    variable Top Text Nodes Roots NextId ColTabs ColRightX ColW ColWMeasured \
        ColWOverride ColMinW ColGap SubjectMax FolderLabelMax LayoutW \
        RelayoutPending SortKey SortDir ResortTimer AtTop ResizeCol ResizeX0 ResizeW0
    constructor {parent} {
        set Top $parent
        my reset_nodes
        set NextId 0; set SortKey date; set SortDir desc
        set RelayoutPending 0; set ResortTimer ""; set LayoutW -1
        my build_body
        my compute_col_widths
        my build_header
        update idletasks
        my relayout
    }
    method column_spec {} {
        return {{date Date {Wed 30 May} right 1} {size Size {999 M} right 1} {cost Cost {$99.99} right 1}}
    }
    method render_subject {node max} { return [dict create subject [my node_pget $node label] tags {} meta_run 0] }
    method cell_values {node} { return {{date 1} {size 2} {cost 3}} }
    method cell_tag {node col} { return [list] }
    method sort_key {payload col} { return 0 }
    method apply_column_tabs {tabs} {}
    method relayout_content {} {}
    method row_tags {kind} { return [list] }
    # Expose a couple of internals for assertions.
    method colw {} { return $ColW }
    method rightx {} { return $ColRightX }
    method tabs {} { return $ColTabs }
    method sortkey {} { return $SortKey }
    method col_index {id} {
        set i 0
        foreach c [my column_spec] { if {[lindex $c 0] eq $id} { return $i }; incr i }
        return -1
    }
}

set fails 0
proc check {name got want} {
    if {$got eq $want} { puts "ok   - $name" } else {
        puts "FAIL - $name"; puts "       got:  $got"; puts "       want: $want"; incr ::fails
    }
}

pack [ttk::frame .f] -fill both -expand 1
.f configure -width 900 -height 400
set d [Demo new .f]
update idletasks
.f.body.t configure -width 900
$d relayout
update idletasks

set ci_cost [$d col_index cost]
set ci_date [$d col_index date]
set base_w   [lindex [$d colw] $ci_cost]
set base_dx  [lindex [$d rightx] $ci_date]

# ---- 1: a width override round-trips to the effective widths --------------
$d column cost -width [expr {$base_w + 60}]
check "the override width is the column's effective width" \
    [lindex [$d colw] $ci_cost] [expr {$base_w + 60}]

# ---- 2: a wider column re-pins the tab stops (columns to its left shift) ---
# cost is the rightmost column; widening it pushes the date column's right edge
# left by the same amount, so the tab stops genuinely moved.
check "widening a column shifts the left columns' tab stops" \
    [lindex [$d rightx] $ci_date] [expr {$base_dx - 60}]

# ---- 3: the minimum-width clamp holds over a too-small width --------------
$d column cost -width 5 -minwidth 40
check "a width below the minimum clamps to the minimum" \
    [lindex [$d colw] $ci_cost] 40

# ---- 4: a header click in a column interior still sorts -------------------
# Click well inside the size column (its right edge less half its width), away
# from any boundary handle; add the 8px -padx the handler subtracts back off.
set ci_size [$d col_index size]
set sx [expr {[lindex [$d rightx] $ci_size] - [lindex [$d colw] $ci_size] / 2 + 8}]
$d on_header_release $sx
check "a non-boundary header click sorts the clicked column" [$d sortkey] size

# ---- 5: a press on a boundary arms a resize, not a sort ------------------
# The left edge of the cost column (its right edge less its width) is a handle.
set bx [expr {[lindex [$d rightx] $ci_cost] - [lindex [$d colw] $ci_cost] + 8}]
set before [$d sortkey]
$d on_header_press $bx
$d on_header_release $bx
check "a boundary press-release does not sort" [$d sortkey] $before

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
