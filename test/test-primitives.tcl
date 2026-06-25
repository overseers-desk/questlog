#!/usr/bin/env wish9.0
# Drive the TextTree structural primitives directly on a minimal subclass, with
# the audit gate on, asserting after each that the mark contract holds and that
# the buffer returns to its empty baseline (no leaked marks or tags) once every
# node is gone. This exercises the engine's mark ownership in isolation, before
# any session-domain wiring rides on it.

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
foreach f {config.tcl ui/theme.tcl ui/drag.tcl ui/texttree.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init
set ::env(TEXTTREE_AUDIT) 1

# A minimal concrete TextTree: three node kinds nested folder>session>subagent,
# one metadata column, the per-kind start gravity and style tags the session
# list uses, and a trivial subject.
oo::class create Demo {
    superclass ::questlog::ui::TextTree
    variable Top Text Nodes Roots NextId ColTabs ColRightX ColW ColGap \
        SubjectMax FolderLabelMax LayoutW RelayoutPending SortKey SortDir \
        ResortTimer AtTop
    constructor {parent} {
        set Top $parent
        my reset_nodes
        set NextId 0
        set SortKey date
        set SortDir desc
        set RelayoutPending 0
        set ResortTimer ""
        set LayoutW -1
        my build_body
        my compute_col_widths
        my build_header
        update idletasks
        my relayout
    }
    method column_spec {} { return {{n N {9999} right 0}} }
    method render_subject {node max} { return [dict create subject [my node_pget $node label] tags {} meta_run 0] }
    method cell_values {node} { return [list [list n [my node_pget $node n 0]]] }
    method cell_tag {node col} { return [list] }
    method sort_key {payload col} { return 0 }
    method apply_column_tabs {tabs} {}
    method relayout_content {} {}
    method start_gravity {kind} { return [expr {$kind eq "subagent" ? "left" : "right"}] }
    method row_tags {kind} {
        return [dict get {folder folderhead session sessionhead subagent childhead} $kind]
    }
}

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name\n  expected: $expected\n  actual:   $actual"
        incr ::fails
    } else { puts "ok:   $name" }
}
proc tripped {} { return [expr {[info exists ::TEXTTREE_AUDIT_TRIPPED] ? 1 : 0}] }
# Count the position marks the engine owns (named <node>_s / <node>_e), so a
# leak (a row removed but its marks left live) is visible as a non-zero residue.
proc live_marks {w} {
    set n 0
    foreach m [$w mark names] { if {[string match {node*_s} $m] || [string match {node*_e} $m]} { incr n } }
    return $n
}

pack [ttk::frame .f] -fill both -expand 1
set d [Demo new .f]
set T .f.body.t

# Build two folders, each with two sessions; expand as we go.
set f1 [$d insert "" folder f1 {label ProjectOne n 0}]
set f2 [$d insert "" folder f2 {label ProjectTwo n 0}]
check "two roots drawn, invariant clean" 0 [tripped]
$d expand $f1
set s1 [$d insert $f1 session s1 {label alpha n 11}]
set s2 [$d insert $f1 session s2 {label beta  n 22}]
$d expand $f2
set s3 [$d insert $f2 session s3 {label gamma n 33}]
check "sessions under open folders, invariant clean" 0 [tripped]
check "six live marks (2 folders + ... only rendered nodes)" 1 [expr {[live_marks $T] >= 6}]

# A subagent nested under the first session of folder one (middle session: the
# folder end must not be dragged into its child block).
$d expand $s1
set a1 [$d insert $s1 subagent a1 {label worker n 1}]
check "subagent nested, invariant clean" 0 [tripped]

# In-place rewrite of a heading and a session row.
$d node_pset $f1 label "ProjectOne (renamed)"
$d item $f1
$d node_pset $s2 label "beta updated"
$d item $s2
check "in-place item rewrites, invariant clean" 0 [tripped]

# Collapse and re-expand a folder; the body vanishes and comes back clean.
$d collapse $f1
check "collapse folder one, invariant clean" 0 [tripped]
$d expand $f1
check "re-expand folder one, invariant clean" 0 [tripped]

# Hide then unhide a session (reversible filter).
$d hide $s3
check "hide a session, invariant clean" 0 [tripped]
$d unhide $s3
check "unhide a session, invariant clean" 0 [tripped]

# Delete everything; the buffer returns to its empty-baseline mark count.
$d delete $a1
$d delete $s1
$d delete $s2
$d delete $s3
$d delete $f1
$d delete $f2
check "all deleted, invariant clean" 0 [tripped]
check "no leaked position marks after empty" 0 [live_marks $T]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
