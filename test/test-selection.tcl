#!/usr/bin/env wish9.0
# Multi-selection model for the session list.
#
# The list holds a set of selected session paths (SelectedSet) with an anchor.
# A plain click selects one; Control toggles one across folders; Shift selects a
# contiguous range within one folder. The set is path-keyed, so it survives a
# move (relocate_card re-keys it) and a delete (forget_session drops it). This
# drives the model directly over a two-folder sandbox and asserts each gesture
# and each survival path.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _selection_sandbox]
set FA "-tmp-sel-a"
set FB "-tmp-sel-b"

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add $ROOT
package require leash
package require streamtree
foreach f {config.tcl lib/cost.tcl ui/theme.tcl lib/path.tcl lib/filter.tcl lib/sessionlist.tcl lib/jsonl.tcl \
           lib/match.tcl ui/terminal.tcl ui/live.tcl lib/scan.tcl lib/search.tcl \
           ui/drag.tcl ui/toolbar.tcl ui/sessions.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

::questlog::path::_real_file delete -force $SAND
set DIRA [file join $SAND .claude projects $FA]
set DIRB [file join $SAND .claude projects $FB]
::questlog::path::_real_file mkdir $DIRA
::questlog::path::_real_file mkdir $DIRB
set ::env(HOME) $SAND

proc noop {args} {}

proc write_session {path ts} {
    set fh [open $path w]
    puts $fh "{\"type\":\"user\",\"cwd\":\"/tmp/proj\",\"timestamp\":\"${ts}Z\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}"
    puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}Z\",\"message\":{\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
    puts $fh "{\"type\":\"user\",\"timestamp\":\"${ts}Z\",\"message\":{\"role\":\"user\",\"content\":\"more\"}}"
    close $fh
}

# Folder A: a01 newest .. a03 oldest, so date-descending display order is
# a01, a02, a03. Folder B: b01, b02, older still. Session moments are offsets
# from now, not calendar dates: the scan below filters with `since 30d`, and a
# fixed date silently ages out of that window and starves the sandbox (it
# happened; the streamed-in counts collapsed to 1 and 0).
proc session_moment {days_ago} { return [expr {[clock seconds] - $days_ago*24*3600}] }
set A {}
for {set i 1} {$i <= 3} {incr i} {
    set p [file join $DIRA [format a%02d $i].jsonl]
    set when [session_moment $i]
    write_session $p [clock format $when -format "%Y-%m-%dT%H:%M:%S" -gmt 1]
    file mtime $p $when
    lappend A $p
}
set B {}
for {set i 1} {$i <= 2} {incr i} {
    set p [file join $DIRB [format b%02d $i].jsonl]
    set when [session_moment [expr {4 + $i}]]
    write_session $p [clock format $when -format "%Y-%m-%dT%H:%M:%S" -gmt 1]
    file mtime $p $when
    lappend B $p
}
lassign $A a01 a02 a03
lassign $B b01 b02

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc lookup {path}   { return [$::Scan lookup $path] }
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }
proc scopef {f} { set ::scoped $f }

set SL [::questlog::ui::SessionList new .s resolvef lookup noop noop noop noop noop \
            noop scanpath noop subagentsf noop noop noop noop scopef]
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
# Selection as a sorted list, so order of toggles does not make the test flap.
proc sel {} { return [lsort [$::SL selection_paths]] }

$SL apply_filter [dict create since 30d]
set ::scan_done 0
$::Scan extend [dict create since 30d]
after 200 [list set ::scan_done 1]
vwait ::scan_done
$SL toggle_folder $FA
$SL toggle_folder $FB
update

check "both folders streamed in" \
    [list [llength [$SL folder_session_paths $FA]] [llength [$SL folder_session_paths $FB]]] \
    {3 2}
check "folder_visible_paths is date-descending order" \
    [$SL folder_visible_paths $FA] [list $a01 $a02 $a03]

# ---- folder selection: name-keyed, exclusive with session selection ------
# A folder heading is selectable too, but held apart from the path-keyed session
# set (a folder is name-keyed). The two selections are mutually exclusive.
$SL selection_set $a02
$SL folder_select $FA
check "folder_select highlights the folder" [$SL is_folder_selected $FA] 1
check "folder_select clears the session selection" [$SL selection_count] 0
$SL selection_set $a01
check "a session gesture clears the folder highlight" [$SL is_folder_selected $FA] 0
check "the session selection stands after clearing the folder" [sel] [list $a01]

# ---- scope-to-folder invokes the owner callback --------------------------
set ::scoped ""
$SL folder_scope $FB
check "folder_scope calls OnScopeFolder with the folder" $::scoped $FB

# ---- plain select --------------------------------------------------------
$SL selection_set $a02
check "plain select picks exactly one" [sel] [list $a02]
check "is_selected true for the member" [$SL is_selected $a02] 1
check "is_selected false for a non-member" [$SL is_selected $a01] 0

# ---- Control toggle, same folder then across folders ---------------------
$SL selection_toggle $a01
check "ctrl-add a second in the same folder" [sel] [lsort [list $a01 $a02]]
$SL selection_toggle $b01
check "ctrl-add across folders (safe)" [sel] [lsort [list $a01 $a02 $b01]]
$SL selection_toggle $a01
check "ctrl-remove drops just that one" [sel] [lsort [list $a02 $b01]]

# ---- Shift range, confined to one folder ---------------------------------
$SL selection_set $a01
$SL selection_range $a03
check "shift-range covers the folder slice anchor..target" [sel] [lsort [list $a01 $a02 $a03]]
$SL selection_set $a03
$SL selection_range $a01
check "shift-range is order-independent (target above anchor)" [sel] [lsort [list $a01 $a02 $a03]]

# A shift-click in another folder than the anchor re-anchors there instead of
# selecting an undefined cross-folder range.
$SL selection_set $a01
$SL selection_range $b02
check "cross-folder shift re-anchors to the target alone" [sel] [list $b02]

# ---- selection survives a move (relocate_card re-keys the set) -----------
$SL selection_set $a02
set moved [file join $DIRB moved.jsonl]
$SL relocate_card $a02 $moved $FB
check "moved member follows to its new path" [$SL is_selected $moved] 1
check "old path is no longer selected" [$SL is_selected $a02] 0

# ---- selection survives a delete (forget_session drops the member) -------
$SL selection_set $a01
$SL forget_session $a01
check "deleting the selected session empties the set" [$SL selection_count] 0

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
