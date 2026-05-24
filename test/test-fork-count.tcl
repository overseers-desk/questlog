#!/usr/bin/env wish9.0
# Regression test for fork-related folder-count bugs in reconcile_running.
#
# Bug 1 (double-add): a RUNNING session not yet in Rows is added twice. The
#   first loop calls OnScanPath, which is not a pure read - scan_path ->
#   publish_row fires OnRow (on_scan_row), which already adds the session; the
#   loop then calls model_add_session again. Deterministic, no timing.
# Bug 2 (lingering phantom): a fork quit before any input leaves no file, but
#   its cached Rows row outlives the file, so the keep-decision retains it.
#
# Checks SBF entries == distinct == heading count after each step.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _fork_sandbox]
::file delete -force $SAND
set FOLDER "-tmp-proj"
set PROJDIR [file join $SAND .claude projects $FOLDER]
::file mkdir $PROJDIR
set ::env(HOME) $SAND

set ROOT [file dirname [file dirname [file normalize [info script]]]]
foreach f {lib/path.tcl lib/jsonl.tcl lib/terminal.tcl lib/live.tcl lib/scan.tcl \
           lib/search.tcl ui/drag.tcl ui/toolbar.tcl ui/sessions.tcl} {
    source [file join $ROOT $f]
}

proc noop {args} {}
proc write_multi {path} {
    set fh [open $path w]
    puts $fh {{"type":"user","cwd":"/tmp/proj","timestamp":"2026-05-24T17:00:00Z","message":{"content":"align"}}}
    puts $fh {{"type":"user","message":{"content":"second"}}}
    close $fh
}

set F [file join $PROJDIR ffff.jsonl]
set uF ffff
set FP [file join [::csm::path::projects_root] $FOLDER $uF.jsonl]
write_multi $F

# Wire Scan <-> SessionList as app.tcl does.
set SL ""
set ::Scan [::csm::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc lookup {path}   { return [$::Scan lookup $path] }
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
set SL [::csm::ui::SessionList new .s resolvef lookup noop noop noop noop scanpath noop]
pack .s -fill both -expand 1
$SL apply_filter [dict create window 7d one_turn 1]

set ns [info object namespace $SL]
set fails 0
proc check {label expected} {
    global ns FOLDER fails
    set SBF [set ${ns}::SessionsByFolder]
    set n 0; set d 0
    if {[dict exists $SBF $FOLDER]} {
        set l [dict get $SBF $FOLDER]; set n [llength $l]; set d [llength [lsort -unique $l]]
    }
    set c 0
    if {[dict exists [set ${ns}::Folders] $FOLDER]} {
        set c [dict get [dict get [set ${ns}::Folders] $FOLDER] count]
    }
    set ok [expr {$n == $d && $d == $c && $c == $expected}]
    if {!$ok} { incr fails }
    puts [format "%s %-34s entries=%s distinct=%s count=%s (want %s)" \
        [expr {$ok ? "ok " : "FAIL"}] $label $n $d $c $expected]
}

# Bug 1: running fork not yet in Rows -> must be a single entry.
$SL reconcile_running [dict create $uF $FP]
check "running fork (not in Rows)" 1

# Bug 2: it quits and its file is removed -> must be forgotten.
::csm::path::_real_file delete $F
$SL reconcile_running [dict create]
check "fork quit, file gone" 0

::csm::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
