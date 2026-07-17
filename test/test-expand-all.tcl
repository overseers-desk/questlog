#!/usr/bin/env wish9.0
# The expand-all button: one press opens every folder one level, in one
# anchored batch, and a second press is a no-op. The button lives flush left
# in the list-view strip and drives SessionList expand_all_folders; a folder
# already open is skipped, a folder closed by hand re-opens on the next press.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _expall_sandbox]
set FOLDER1 "-tmp-expall-proj1"
set FOLDER2 "-tmp-expall-proj2"
set ::env(STREAMTREE_AUDIT) 1

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add $ROOT
package require leash
package require streamtree
foreach f {config.tcl lib/cost.tcl ui/theme.tcl lib/path.tcl lib/scope.tcl lib/sessionlist.tcl lib/jsonl.tcl \
           lib/match.tcl ui/terminal.tcl ui/live.tcl lib/scan.tcl lib/search.tcl \
           ui/drag.tcl ui/toolbar.tcl ui/sessions.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

::questlog::path::_real_file delete -force $SAND
foreach f [list $FOLDER1 $FOLDER2] {
    ::questlog::path::_real_file mkdir [file join $SAND .claude projects $f]
}
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

set Ap [file join $SAND .claude projects $FOLDER1 aaaa.jsonl]
set Bp [file join $SAND .claude projects $FOLDER1 bbbb.jsonl]
set Cp [file join $SAND .claude projects $FOLDER2 cccc.jsonl]
write_session $Ap {a-first a-second} "2026-05-24T17:00"
write_session $Bp {b-first b-second} "2026-05-23T10:00"
write_session $Cp {c-first c-second} "2026-05-22T09:00"
file mtime $Ap [clock scan "2026-05-24 17:01:00" -gmt 1]
file mtime $Bp [clock scan "2026-05-23 10:01:00" -gmt 1]
file mtime $Cp [clock scan "2026-05-22 09:01:00" -gmt 1]

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc lookup {path}   { return [$::Scan lookup $path] }
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }
proc subagent_cost_cb {path} {}

set SL [::questlog::ui::SessionList new .s resolvef lookup noop noop noop noop noop \
            noop scanpath noop subagentsf subagent_cost_cb]
pack .s -fill both -expand 1

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

# --- 1. Stream all rows in; folders arrive collapsed.
$SL apply_filter [dict create since all listview [dict create]]
set ::scan_done 0
$::Scan extend [dict create since all listview [dict create]]
after 200 [list set ::scan_done 1]
vwait ::scan_done
update

check "button in the strip" [winfo exists .s.lvt.expandall] 1
check "A unrendered before" [$SL sflag $Ap rendered] 0
check "C unrendered before" [$SL sflag $Cp rendered] 0

# --- 2. One press opens every folder one level.
.s.lvt.expandall invoke
update
foreach {p name} [list $Ap A $Bp B $Cp C] {
    check "$name rendered after expand-all" [$SL sflag $p rendered] 1
}
foreach f [list $FOLDER1 $FOLDER2] {
    check "$f expanded" [$SL node_field [$SL fid $f] expanded] 1
}

# --- 3. A second press is a no-op (every folder already open).
.s.lvt.expandall invoke
update
check "A still rendered" [$SL sflag $Ap rendered] 1
check "C still rendered" [$SL sflag $Cp rendered] 1

# --- 4. A folder closed by hand re-opens on the next press; the open one
#        is left alone.
$SL toggle_folder $FOLDER1
update
check "A unrendered after manual collapse" [$SL sflag $Ap rendered] 0
.s.lvt.expandall invoke
update
check "A re-rendered" [$SL sflag $Ap rendered] 1
check "C untouched"   [$SL sflag $Cp rendered] 1

check "no audit trip" [info exists ::STREAMTREE_AUDIT_TRIPPED] 0

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
