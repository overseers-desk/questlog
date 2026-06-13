#!/usr/bin/env wish9.0
# Regression test for the streaming-search resort storm.
#
# Under a non-default sort, a late metric (cost/turns/duration/H%) reorders the
# list, which means a full redraw_all. The cost pass streams results coalesced
# every 80ms, so before the fix the list was wiped and rebuilt on every batch
# and the scroll snapped to the top (the AnchorTop mark cannot survive
# redraw_all's `delete 1.0 end`), so a result could not be clicked.
#
# This drives the fix and asserts:
#   1. a metric flood debounces to ONE rebuild when arrivals pause;
#   2. rows stay put (arrival/sorted order) during the flood;
#   3. scroll is preserved across the rebuild (no top-snap);
#   4. a header click (set_sort) cancels a pending debounce, so no second
#      redundant rebuild fires just after the user starts interacting;
#   5. the running poll redraws only rows whose running-state flipped.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _resortscroll_sandbox]
set FOLDER "-tmp-resortscroll-proj"

set ROOT [file dirname [file dirname [file normalize [info script]]]]
foreach f {config.tcl lib/cost.tcl ui/theme.tcl lib/path.tcl lib/filter.tcl lib/jsonl.tcl \
           lib/match.tcl ui/terminal.tcl ui/live.tcl lib/scan.tcl lib/search.tcl \
           ui/drag.tcl ui/toolbar.tcl ui/texttree.tcl ui/sessions.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

::questlog::path::_real_file delete -force $SAND
set PROJDIR [file join $SAND .claude projects $FOLDER]
::questlog::path::_real_file mkdir $PROJDIR
set ::env(HOME) $SAND

proc noop {args} {}

proc write_session {path prompts ts} {
    set fh [open $path w]
    set t 0
    foreach p $prompts {
        puts $fh "{\"type\":\"user\",\"cwd\":\"/tmp/proj\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"role\":\"user\",\"content\":\"$p\"}}"
        puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
        incr t
    }
    close $fh
}

# Twelve sessions, all within the last fortnight (well inside a 30d window).
# mtime descends with i (i=1 newest); cost ASCENDS with i, so cost-descending
# order is the exact reverse of the date-descending stream order - a resort is
# observable, not a no-op.
set PATHS [list]
for {set i 1} {$i <= 12} {incr i} {
    set id [format s%02d $i]
    set p [file join $PROJDIR $id.jsonl]
    set day [format %02d [expr {13 - $i}]]
    write_session $p [list ${id}-a ${id}-b] "2026-06-${day}T10:00"
    file mtime $p [clock scan "2026-06-${day} 10:00:00" -gmt 1]
    lappend PATHS $p
}

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc lookup {path}   { return [$::Scan lookup $path] }
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

set SL [::questlog::ui::SessionList new .s resolvef lookup noop noop noop noop noop \
            scanpath noop noop subagentsf noop]
pack .s -fill both -expand 1
$SL apply_filter [dict create since 30d one_turn 0]

set ns [info object namespace $SL]
set TX [set ${ns}::Text]
set fails 0
proc check {name got want} {
    if {$got eq $want} {
        puts "ok   - $name"
    } else {
        puts "FAIL - $name"
        puts "       got:  $got"
        puts "       want: $want"
        incr ::fails
    }
}
proc sline {p} {
    global SL TX
    if {![$SL has_session $p] && ![$SL has_child $p]} { return -1 }
    set st [$SL node_field [$SL sid $p] start]
    if {$st eq ""} { return -1 }
    return [lindex [split [$TX index $st] .] 0]
}
proc topkey {} { lindex [$::SL top_visible_node] 1 }

# Stream the sessions in, open the folder, give each a cost under the default
# date sort (no resort fires there), then shrink the viewport so the list
# overflows and scroll has somewhere to go.
set ::scan_done 0
$::Scan extend [dict create since 30d one_turn 0]
after 200 [list set ::scan_done 1]
vwait ::scan_done
$SL toggle_folder $FOLDER
update
for {set i 1} {$i <= 12} {incr i} {
    $SL refresh_cost [lindex $PATHS [expr {$i-1}]] \
        [dict create cost_usd [expr {0.001 * $i}] turns $i duration_secs 5 model_breakdown {}]
}
$TX configure -height 6
update

check "all twelve sessions rendered" \
    [expr {[llength [$SL folder_session_paths $FOLDER]]}] 12

# Spy on the full rebuild and the per-row header redraw.
set ::redraws 0
set ::headers 0
oo::objdefine $SL method redraw_all {} { incr ::redraws; next }
oo::objdefine $SL method redraw_header {p} { incr ::headers; next $p }

set S12 [lindex $PATHS 11]   ;# highest cost -> first under cost-desc

# ---- 1 + 2: debounce coalesces a flood; rows stay put during it ----------
$SL set_sort cost
update
check "cost-desc puts the highest-cost session at the top" [sline $S12] 2
set ::redraws 0
set base [sline $S12]
for {set i 1} {$i <= 12} {incr i} {
    $SL refresh_cost [lindex $PATHS [expr {$i-1}]] \
        [dict create cost_usd [expr {0.001 * $i}] turns $i duration_secs 5 model_breakdown {}]
}
check "no full rebuild during the cost flood" $::redraws 0
check "a row does not move during the flood" [sline $S12] $base
after 350 [list set ::d1 1]
vwait ::d1
check "the whole flood coalesced to one rebuild" $::redraws 1

# ---- 3: scroll preserved across the rebuild ------------------------------
$TX yview moveto 0.4
update
set top_before [topkey]
set frac_before [lindex [$TX yview] 0]
check "scrolled away from the top" [expr {$frac_before > 0.0001}] 1
set rb $::redraws
$SL refresh_cost [lindex $PATHS 0] \
    [dict create cost_usd 0.001 turns 1 duration_secs 5 model_breakdown {}]
after 350 [list set ::d3 1]
vwait ::d3
check "an order-preserving recost still rebuilt once" [expr {$::redraws == $rb + 1}] 1
check "the same node sits at the top after the rebuild" [topkey] $top_before
check "the view did not snap to the top" [expr {[lindex [$TX yview] 0] > 0.0001}] 1

# ---- 4: a header click cancels a pending debounce ------------------------
set ::redraws 0
$SL refresh_cost [lindex $PATHS 2] \
    [dict create cost_usd 0.003 turns 3 duration_secs 5 model_breakdown {}]
$SL set_sort turns
update
check "the header click did its own immediate rebuild" $::redraws 1
after 350 [list set ::d4 1]
vwait ::d4
check "the stale debounce did not fire after the click" $::redraws 1

# ---- 5: the running poll redraws only rows that flipped ------------------
set ::headers 0
$SL reconcile_running [dict create]
check "an idle tick redraws no headers" $::headers 0
$SL reconcile_running [dict create]
check "a second identical tick redraws no headers" $::headers 0
set u [$SL sget [lindex $PATHS 0] uuid]
$SL reconcile_running [dict create $u [lindex $PATHS 0]]
check "one session entering redraws exactly one header" $::headers 1

# ---- restore_anchor tolerates a missing/vanished anchor ------------------
check "restore_anchor tolerates an empty anchor" \
    [catch {$SL restore_anchor "" ""}] 0
check "restore_anchor falls back when the node is gone" \
    [catch {$SL restore_anchor [list session /nope.jsonl] $FOLDER}] 0

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
