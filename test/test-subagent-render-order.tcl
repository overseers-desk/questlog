#!/usr/bin/env wish9.0
# Regression test for the children/sibling render order in the session list.
#
# A session rendered while a sibling above it is collapsed begins at that
# sibling's end mark. When the sibling later expands, its child rows are
# inserted at that point. Two faults used to corrupt the layout:
#   1. the session's start mark had left gravity, so it was stranded among the
#      children, and the next redraw_header painted the session there (a sibling
#      appearing between the expanded one and its children);
#   2. render_child dragged the folder's append mark back to the expanded
#      session's end even when it was not the folder's last, so a session
#      arriving afterward landed inside the child block.
# This drives the exact sequence and asserts both stay fixed.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _renderorder_sandbox]
set FOLDER "-tmp-renderorder-proj"

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
foreach f {config.tcl lib/cost.tcl ui/theme.tcl lib/path.tcl lib/listfilter.tcl lib/jsonl.tcl \
           lib/match.tcl ui/terminal.tcl ui/live.tcl lib/scan.tcl lib/search.tcl \
           ui/drag.tcl ui/toolbar.tcl ui/sessions.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

::questlog::path::_real_file delete -force $SAND
set PROJDIR [file join $SAND .claude projects $FOLDER]
::questlog::path::_real_file mkdir $PROJDIR
set ::env(HOME) $SAND

proc noop {args} {}

# A two-turn parent F with two subagents, and a two-turn sibling G with none.
# F's mtime is later than G's so the date-descending default sort renders F
# directly above G.
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

set Fp [file join $PROJDIR ffff.jsonl]
write_session $Fp {f-first f-second} "2026-05-24T17:00"
set SUBDIR [file join $PROJDIR ffff subagents]
::questlog::path::_real_file mkdir $SUBDIR
foreach a {agent-1 agent-2} {
    write_session [file join $SUBDIR $a.jsonl] {subwork} "2026-05-24T17:00"
}
set Gp [file join $PROJDIR gggg.jsonl]
write_session $Gp {g-galpha g-gbeta} "2026-05-23T10:00"

file mtime $Gp [clock scan "2026-05-23 10:01:00" -gmt 1]
file mtime $Fp [clock scan "2026-05-24 17:01:00" -gmt 1]

# Wire Scan <-> SessionList (same shape as test-subagent-cost-aggregation).
set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }
proc subagent_cost_cb {path} {}

set SL [::questlog::ui::SessionList new .s resolvef noop noop noop noop noop \
            noop scanpath noop subagentsf subagent_cost_cb]
pack .s -fill both -expand 1
$SL apply_filter [dict create since all]

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
    if {![$SL has_session $p]} { return -1 }
    set st [$SL node_field [$SL sid $p] start]
    if {$st eq ""} { return -1 }
    return [lindex [split [$TX index $st] .] 0]
}

# Stream the two sessions into the model, then open the folder so both render
# (F collapsed, G directly below it).
set ::scan_done 0
$::Scan extend [dict create since all]
after 200 [list set ::scan_done 1]
vwait ::scan_done
$SL toggle_folder $FOLDER
update

check "F is rendered" [$SL sflag $Fp rendered] 1
check "G is rendered" [$SL sflag $Gp rendered] 1
check "F renders directly above G" [expr {[sline $Gp] == [sline $Fp] + 1}] 1

# Expand F: its two subagents render between F and G.
$SL toggle_subagents $Fp
update
set kids [$SL session_child_paths $Fp]
check "F has two children" [llength $kids] 2

# G's cost second pass returns and redraws G's header. Before the fix this
# painted G at its stranded start mark, among F's children.
$SL refresh_cost $Gp [dict create cost_usd 0.001 turns 2 duration_secs 5 model_breakdown {}]
update

check "child 1 sits directly under F"  [expr {[sline [lindex $kids 0]] == [sline $Fp] + 1}] 1
check "child 2 sits under child 1"      [expr {[sline [lindex $kids 1]] == [sline $Fp] + 2}] 1
check "G stays below both children"     [expr {[sline $Gp] == [sline $Fp] + 3}] 1

# Part 2: a session arriving after F expanded (F is no longer the folder's
# last) must land at the folder bottom, below G, not inside F's child block.
set Hp [file join $PROJDIR hhhh.jsonl]
write_session $Hp {h-halpha h-hbeta} "2026-05-22T08:00"
file mtime $Hp [clock scan "2026-05-22 08:00:00" -gmt 1]
$SL on_scan_row [$::Scan scan_path $Hp]
update
check "a session arriving after expand lands below G" [expr {[sline $Hp] > [sline $Gp]}] 1

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
