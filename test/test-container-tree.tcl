#!/usr/bin/env tclsh9.0
# The container rule: which resolved directories become rows in the session
# list, and what each row is labelled. A directory holding no folder of its
# own is not a row; its label is pushed down into its children.
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT lib path.tcl]

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name\n  expected=<$expected>\n  actual  =<$actual>"
        incr ::fails
    } else {
        puts "ok:   $name"
    }
}

# One line per node, depth as leading dots, keys in braces: enough to pin both
# the shape and the labels without asserting on dict key order.
proc render {nodes {depth 0}} {
    set out [list]
    foreach node $nodes {
        lappend out "[string repeat . $depth][dict get $node label] {[dict get $node keys]}"
        foreach line [render [dict get $node children] [expr {$depth + 1}]] {
            lappend out $line
        }
    }
    return $out
}
proc tree {entries {groups {}}} {
    return [join [render [::questlog::path::container_tree $entries $groups]] \n]
}

# ---- a flat corpus is the degenerate case, not a special one ---------

check "flat: each folder is its own root, labelled absolutely" \
    "/home/t/alpha {a}
/home/t/beta {b}" \
    [tree {{a /home/t/alpha} {b /home/t/beta}}]

# ---- a chain of empty directories collapses into one row -------------

check "chain: a lone child merges its parents' labels" \
    "/var/local/src/widget {w}" \
    [tree {{w /var/local/src/widget}}]

# ---- an empty branch point promotes its children ---------------------

check "promotion: a directory holding nothing is not a row" \
    "/var/local/src/anvil {a}
/var/local/src/cogwheel {c}
/var/local/src/widget {w}" \
    [tree {{w /var/local/src/widget} {a /var/local/src/anvil}
           {c /var/local/src/cogwheel}}]

# ---- a directory with its own sessions keeps its children ------------

check "container: own sessions and subfolders, children named by segment" \
    "/var/local/src/orchard {o}
.harvest {h}
.pruning {p}" \
    [tree {{o /var/local/src/orchard}
           {p /var/local/src/orchard/pruning}
           {h /var/local/src/orchard/harvest}}]

# ---- a gone directory hangs under its longest living ancestor --------
# Its own path no longer exists, so nothing else shares its prefix and the
# dead remainder arrives as one merged label under the ancestor that lives.

check "gone: the dead remainder is one label under the living parent" \
    "/var/local/src/orchard {o}
.grants/spring-2026 {g}" \
    [tree {{o /var/local/src/orchard}
           {g /var/local/src/orchard/grants/spring-2026}}]

# ---- two folders resolving to one directory share the row ------------

check "shared: one row carries both folder keys" \
    "/home/t/alpha {a b}" \
    [tree {{a /home/t/alpha} {b /home/t/alpha}}]

# ---- depth is not capped ---------------------------------------------

check "depth: nesting continues past the old two levels" \
    "/var/local/src/orchard {o}
.trellis {t}
..espalier {e}" \
    [tree {{o /var/local/src/orchard}
           {t /var/local/src/orchard/trellis}
           {e /var/local/src/orchard/trellis/espalier}}]

# ---- a group folder over two or more rows is a row --------------------

check "group: a project folder with no sessions holds the rows below it" \
    "/var/local/src/mill {m}
.bookish/design {d}
.enquiries {e}" \
    [tree {{e /var/local/src/mill/enquiries}
           {d /var/local/src/mill/bookish/design}} \
          {{m /var/local/src/mill} {b /var/local/src/mill/bookish}}]

check "group: over a single row it merges into that row's label" \
    "/var/local/src/mill/bookish/design {d}" \
    [tree {{d /var/local/src/mill/bookish/design}} {{m /var/local/src/mill}}]

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
