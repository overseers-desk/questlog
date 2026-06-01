#!/usr/bin/env wish9.0
# Unit / Integration test for subagent cost/turns aggregation. Checks that
# when a subagent's cost is computed, its cost and turns fold up into the
# parent session's columns (updating session totals, folder aggregates, and
# running totals), while the parent's Duration stays its own active time.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _subagent_sandbox]
set FOLDER "-tmp-subagent-proj"

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

# Create parent session
set F [file join $PROJDIR ffff.jsonl]
set uF ffff
set FP [file join [::questlog::path::projects_root] $FOLDER $uF.jsonl]

set fh [open $F w]
puts $fh {{"type":"user","cwd":"/tmp/proj","timestamp":"2026-05-24T17:00:00Z","message":{"content":"align"}}}
puts $fh {{"type":"assistant","timestamp":"2026-05-24T17:00:05Z","message":{"model":"claude-3-5-sonnet-20241022","usage":{"input_tokens":100,"output_tokens":50}}}}
close $fh

# Create subagent
set SUBDIR [file join $PROJDIR $uF subagents]
::questlog::path::_real_file mkdir $SUBDIR
set SF [file join $SUBDIR agent-1.jsonl]
set fh [open $SF w]
puts $fh {{"type":"user","cwd":"/tmp/proj","timestamp":"2026-05-24T17:01:00Z","message":{"content":"subagent prompt"}}}
puts $fh {{"type":"assistant","timestamp":"2026-05-24T17:01:05Z","message":{"model":"claude-3-5-sonnet-20241022","usage":{"input_tokens":200,"output_tokens":80}}}}
close $fh

# Wire Scan <-> SessionList
set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc lookup {path}   { return [$::Scan lookup $path] }
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

set cost_calls [list]
proc subagent_cost_cb {path} {
    lappend ::cost_calls $path
}

set SL [::questlog::ui::SessionList new .s resolvef lookup noop noop noop noop scanpath noop noop subagentsf subagent_cost_cb]
pack .s -fill both -expand 1
$SL apply_filter [dict create window 7d one_turn 0]

set ns [info object namespace $SL]
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

# 1. Trigger the scan
set ::scan_done 0
$::Scan extend [dict create window 7d one_turn 0]
# Wait a brief moment for scan to populate
after 100 [list set ::scan_done 1]
vwait ::scan_done

# Check that subagent cost was queued
check "subagent cost queued" [llength $::cost_calls] 1
set child_path [lindex $::cost_calls 0]

# Check initial values of parent (before cost is parsed)
set s [$SL session_payload $F]
check "parent initially has subagents flag" [dict get $s has_subagents] 1

# 2. Simulate arrival of parent cost:
# Input: 100, Output: 50 => $0.00105
$SL refresh_cost $F [dict create cost_usd 0.00105 input_tokens 100 output_tokens 50 turns 1 duration_secs 5 model_breakdown {}]

set s [$SL session_payload $F]
check "parent own_cost set" [dict get $s own_cost] 0.00105
check "parent total cost matches own_cost initially" [dict get $s cost] 0.00105
check "parent total turns matches own_turns initially" [dict get $s turns] 1
check "parent total duration matches own_duration initially" [dict get $s duration_secs] 5

# 3. Simulate arrival of child/subagent cost:
# Input: 200, Output: 80 => $0.0018
$SL refresh_cost $child_path [dict create cost_usd 0.0018 input_tokens 200 output_tokens 80 turns 1 duration_secs 5 model_breakdown {}]

# Check aggregated totals on parent session!
set s [$SL session_payload $F]
check "parent own_cost remains unchanged" [dict get $s own_cost] 0.00105
check "parent aggregated cost summed up" [dict get $s cost] 0.00285
check "parent aggregated turns summed up" [dict get $s turns] 2
check "parent duration stays own, subagent durations not summed" [dict get $s duration_secs] 5

# Check running total Cost
check "running TotalCost summed up" [set ${ns}::TotalCost] 0.00285

# Check folder cost
set folder_info [$SL folder_payload $FOLDER]
check "folder cost summed up" [dict get $folder_info cost] 0.00285

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
