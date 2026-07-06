#!/usr/bin/env wish9.0
# The base class must render with no subclass at all: every content hook has a
# working default (rows read the payload's `label`, no metadata columns, tabs
# widget-wide), the setup ritual seeds the engine state, and the zero-column
# geometry paths (layout, header, header click) hold. Audit gate on throughout.

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add $ROOT
package require streamtree
set ::env(STREAMTREE_AUDIT) 1

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name\n  expected: $expected\n  actual:   $actual"
        incr ::fails
    } else { puts "ok:   $name" }
}
proc tripped {} { return [expr {[info exists ::STREAMTREE_AUDIT_TRIPPED] ? 1 : 0}] }

pack [ttk::frame .f] -fill both -expand 1
set d [::streamtree::StreamTree new]
$d setup .f
set T .f.body.t
update

# Build a small tree through the primitives, using nothing but defaults.
set a [$d insert "" folder groceries [dict create label Groceries]]
$d node_set $a expanded 1
set a1 [$d insert $a item milk [dict create label "Milk, 2L"]]
set a2 [$d insert $a item bread [dict create]]   ;# no label: row falls back to the key
set b [$d insert "" folder chores [dict create label Chores]]
update
check "both roots and the expanded folder's children render under defaults" 4 \
    [llength [$d all_rendered_nodes]]
check "labelless row falls back to its key" 1 \
    [expr {[string first bread [$T get 1.0 end]] >= 0}]
check "no audit trip after inserts" 0 [tripped]

# The zero-column paths: a header click and a relayout land on no columns.
$d on_header_click 40
$d relayout
update
check "no audit trip after zero-column header click and relayout" 0 [tripped]

# Structure primitives on defaults.
$d collapse $a
$d expand $a
$d hide $a2
$d unhide $a2
$d move $a1 $b
$d delete $b
update
check "delete of the adopted subtree leaves one root" 1 [llength [$d roots]]
check "no audit trip after structure ops" 0 [tripped]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
