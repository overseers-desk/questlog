#!/usr/bin/env wish9.0
# A list-view toggle detaches folders left with no viewable session and shows
# the viewable (not the model-total) count in each remaining heading. A folder
# detached this way keeps its node and sessions in the model, so toggling back
# re-attaches it in its original display position - even when the re-attached
# folders sit on both sides of one that stayed.
#
# Three single-session folders P1, P2, P3 in display order. Only P2's session is
# running. Under running-only P1 and P3 detach and P2's heading shows "(1)".
# Turning the toggle off re-attaches P1 and P3 around P2 with the order intact.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _folderdetach_sandbox]
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
set ::questlog_config_only 1; source [file join $ROOT questlog]
foreach f {lib/cost.tcl ui/theme.tcl lib/path.tcl lib/listfilter.tcl \
           lib/match.tcl ui/terminal.tcl ui/live.tcl lib/scan.tcl lib/search.tcl \
           ui/drag.tcl ui/toolbar.tcl ui/sessions.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

::questlog::path::_real_file delete -force $SAND
set ::env(HOME) $SAND

proc noop {args} {}
proc write_session {path prompts ts} {
    ::questlog::path::_real_file mkdir [file dirname $path]
    set fh [open $path w]
    set t 0
    foreach p $prompts {
        puts $fh "{\"type\":\"user\",\"cwd\":\"/tmp/proj\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"role\":\"user\",\"content\":\"$p\"}}"
        puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
        incr t
    }
    close $fh
}

set PROOT [file join $SAND .claude projects]
# Folder keys are the project-dir names; newest-first arrival fixes P1,P2,P3.
set P1 [file join $PROOT -tmp-fd-p1]
set P2 [file join $PROOT -tmp-fd-p2]
set P3 [file join $PROOT -tmp-fd-p3]
set Ap [file join $P1 aaaa.jsonl]
set Bp [file join $P2 bbbb.jsonl]
set Cp [file join $P3 cccc.jsonl]
write_session $Ap {a-first a-second} "2026-05-24T17:00"
write_session $Bp {b-first b-second} "2026-05-23T10:00"
write_session $Cp {c-first c-second} "2026-05-22T09:00"
::questlog::path::set_bookmark $Bp   ;# P2 bookmarked: section 4 filters on it
file mtime $Ap [clock scan "2026-05-24 17:01:00" -gmt 1]
file mtime $Bp [clock scan "2026-05-23 10:01:00" -gmt 1]
file mtime $Cp [clock scan "2026-05-22 09:01:00" -gmt 1]

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

set SL [::questlog::ui::SessionList new .s resolvef noop noop noop noop noop \
            noop scanpath noop subagentsf noop]
pack .s -fill both -expand 1

set ns [info object namespace $SL]
set TX [set ${ns}::Text]

set fails 0
proc check {name got want} {
    if {$got eq $want} { puts "ok   - $name" } else {
        puts "FAIL - $name"; puts "       got:  $got"; puts "       want: $want"; incr ::fails
    }
}
# Folders actually drawn, in document order (by heading position in the text).
proc rendered_order {} {
    global SL ns TX
    set out [list]
    foreach fid [set ${ns}::Roots] {
        set f [$SL node_field $fid key]
        if {![$SL folder_attached $f]} continue
        lappend out [list [$TX index [$SL node_field $fid start]] $f]
    }
    return [lmap e [lsort -real -index 0 $out] { lindex $e 1 }]
}

# --- 1. Stream the three folders in (running-only off). All three attached.
$SL apply_filter [dict create since all]
set ::scan_done 0
$::Scan extend [dict create since all]
after 200 [list set ::scan_done 1]
vwait ::scan_done
update
check "three folders, in arrival order" [rendered_order] {-tmp-fd-p1 -tmp-fd-p2 -tmp-fd-p3}
check "P1 count = 1 viewable" [$SL folder_visible_count -tmp-fd-p1] 1
check "P2 count = 1 viewable" [$SL folder_visible_count -tmp-fd-p2] 1

# --- 2. Turn running-only ON. The base class holds the filter; the running poll settles
#        the view each tick, so mark only P2's session running and let a poll pass:
#        P1 and P3 have no running row and detach, P2 stays.
$SL attr_filter_set running 1
$SL reconcile_running [dict create bbbb $Bp]
update
check "P1 detached (no running session)"  [$SL folder_attached -tmp-fd-p1] 0
check "P3 detached (no running session)"  [$SL folder_attached -tmp-fd-p3] 0
check "P2 stays attached (has a running session)" [$SL folder_attached -tmp-fd-p2] 1
check "P1 still in the model"              [$SL has_folder -tmp-fd-p1] 1
check "only P2 is drawn"                   [rendered_order] {-tmp-fd-p2}
check "P2 heading shows 1 viewable"        [$SL folder_visible_count -tmp-fd-p2] 1

# --- 3. Turn running-only OFF. P1 and P3 re-attach AROUND P2, order intact.
$SL attr_filter_set running 0
update
check "all three drawn again"             [$SL folder_attached -tmp-fd-p1] 1
check "order preserved across mass re-attach" [rendered_order] {-tmp-fd-p1 -tmp-fd-p2 -tmp-fd-p3}
check "P2 count back to 1"                 [$SL folder_visible_count -tmp-fd-p2] 1

# --- 4. A filter with no poll behind it detaches folders on the toggle alone.
#        Running rides the liveness reconcile; bookmarked has no such follow-up,
#        so the toggle itself is the only chance to drop an emptied heading. The
#        rebuild inside the toggle reads the base class's filter state directly, which
#        attr_filter_set has already updated, so it sees the new state at once.
$SL attr_filter_set bookmarked 1
update
check "bookmarked toggle alone detaches P1" [$SL folder_attached -tmp-fd-p1] 0
check "bookmarked toggle alone detaches P3" [$SL folder_attached -tmp-fd-p3] 0
check "the bookmarked folder stays"         [$SL folder_attached -tmp-fd-p2] 1
$SL attr_filter_set bookmarked 0
update
check "releasing the filter re-attaches all"  [rendered_order] {-tmp-fd-p1 -tmp-fd-p2 -tmp-fd-p3}

check "domain audit clean at end" [$SL audit] {}
::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
