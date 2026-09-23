#!/usr/bin/env wish9.0
# Drag-to-move over the nested tree. The drop target is the innermost drawn
# folder whose region holds the pointer, so a session dropped anywhere in a
# folder's body lands in that folder, and one dropped in a nested folder's
# heading or body lands in the nested one; below the last row there is no
# target. drag_paint marks the target's heading. The drop itself goes through
# the app's on_drop_move, which refuses a folder whose directory is gone (the
# resolver answers the path it had, which is no directory) and moves into a
# living one; every write stays under this test's sandbox projects root.
#
# The corpus, under a sandbox $HOME (every name fictional):
#   ~/proj/kiln            two sessions; the first root, open on arrival
#   ~/proj/kiln/glaze      nested, one session
#   ~/proj/kiln/ash        nested, one session, the directory gone
#   ~/proj/wheel           an unrelated root

package require Tcl 9
package require Tk

set SAND [file join [pwd] _dragtarget_sandbox]
set ::env(STREAMTREE_AUDIT) 1

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
set ::questlog_config_only 1; source [file join $ROOT questlog]
foreach f {lib/cost.tcl ui/theme.tcl lib/path.tcl lib/listfilter.tcl \
           lib/match.tcl ui/terminal.tcl ui/live.tcl lib/scan.tcl lib/search.tcl \
           ui/drag.tcl ui/toolbar.tcl ui/reveal.tcl ui/sessions.tcl ui/viewer.tcl ui/app.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

::questlog::path::_real_file delete -force $SAND
set ::env(HOME) $SAND
unset -nocomplain ::env(CLAUDE_CONFIG_DIR)

proc noop {args} {}

# A session that ran in cwd, filed under the folder Claude Code names for it,
# mtime `ago` days back. The directory is made unless the caller says not to.
proc write_session {cwd name ago {mkdir 1}} {
    if {$mkdir} { ::questlog::path::_real_file mkdir $cwd }
    set folder [::questlog::path::encode_cwd $cwd]
    set dir [file join $::SAND .claude projects $folder]
    ::questlog::path::_real_file mkdir $dir
    set path [file join $dir $name.jsonl]
    set secs [expr {[clock seconds] - $ago * 86400}]
    set ts [clock format $secs -format "%Y-%m-%dT%H:%M" -gmt 1]
    set fh [open $path w]
    puts $fh "{\"type\":\"user\",\"cwd\":\"$cwd\",\"timestamp\":\"${ts}:00Z\",\"message\":{\"role\":\"user\",\"content\":\"hello from $name\"}}"
    puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}:01Z\",\"message\":{\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
    close $fh
    file mtime $path $secs
    return $path
}

set KILN  [file join $SAND proj kiln]
set GLAZE [file join $KILN glaze]
set ASH   [file join $KILN ash]
set WHEEL [file join $SAND proj wheel]
set kiln1  [write_session $KILN  kiln-1  1]
set glaze1 [write_session $GLAZE glaze-1 2]
set ash1   [write_session $ASH   ash-1   3 0]
set wheel1 [write_session $WHEEL wheel-1 4]
set kiln2  [write_session $KILN  kiln-2  5]
foreach v {KILN GLAZE ASH WHEEL} { set F_$v [::questlog::path::encode_cwd [set $v]] }

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop {} {} {} 0]
proc scanpath {path}   { return [$::Scan scan_path $path] }
proc resolvef {f}      { return [$::Scan folder_cwd $f] }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

set SL [::questlog::ui::SessionList new .s resolvef noop noop \
            ::questlog::ui::app::on_drop_move noop noop noop scanpath noop subagentsf noop]
pack .s -fill both -expand 1
set TX .s.body.t

# on_drop_move reaches the resolver and the list through the app's namespace
# variables; the error box it raises on a refusal is caught here instead.
namespace eval ::questlog::ui::app {
    variable SessionList $::SL
    variable Scan $::Scan
}
set ::refused ""
proc ::questlog::ui::error_box {args} { set ::refused [dict get $args -message] }

set fails 0
proc check {name got want} {
    if {$got eq $want} { puts "ok   - $name" } else {
        puts "FAIL - $name"; puts "       got:  $got"; puts "       want: $want"; incr ::fails
    }
}
# The root coordinates of a point on a node's own row, a little in from the
# left, where a pointer dragging over it would be.
proc point_on {id} {
    lassign [$::TX bbox [$::SL node_field $id start]] x y w h
    return [list [expr {[winfo rootx $::TX] + $x + 4}] [expr {[winfo rooty $::TX] + $y + $h / 2}]]
}
proc hit_at {id} { return [$::SL drag_hit {*}[point_on $id]] }

$SL apply_filter [dict create since 30d]
set ::scan_done 0
$::Scan extend [dict create since 30d]
after 400 [list set ::scan_done 1]
vwait ::scan_done
update

# ---- containment ----------------------------------------------------------
check "the root's heading targets the root" [hit_at [$SL fid $F_KILN]] $F_KILN
check "a nested folder's heading targets the nested folder" [hit_at [$SL fid $F_GLAZE]] $F_GLAZE
check "a session row in the root's body, below the nested headings, targets the root" \
    [hit_at [$SL sid $kiln1]] $F_KILN
check "the gone folder's heading is a target too" [hit_at [$SL fid $F_ASH]] $F_ASH
check "the other root's heading targets it" [hit_at [$SL fid $F_WHEEL]] $F_WHEEL
$SL toggle_folder $F_GLAZE
update
check "a session row in the nested folder's body targets the nested folder, not the root" \
    [hit_at [$SL sid $glaze1]] $F_GLAZE
check "below the last row there is no target" \
    [$SL drag_hit [expr {[winfo rootx $TX] + 10}] [expr {[winfo rooty $TX] + [winfo height $TX] - 3}]] ""

# ---- the mark --------------------------------------------------------------
$SL drag_paint "" $F_GLAZE
set gm [$SL node_field [$SL fid $F_GLAZE] start]
check "drag_paint marks the target's heading line" \
    [$TX tag ranges drop-candidate] [list [$TX index $gm] [$TX index "$gm lineend"]]
$SL drag_paint $F_GLAZE $F_KILN
set km [$SL node_field [$SL fid $F_KILN] start]
check "moving on clears the old mark and lays the new" \
    [$TX tag ranges drop-candidate] [list [$TX index $km] [$TX index "$km lineend"]]
$SL drag_paint $F_KILN ""
check "a release clears the mark" [$TX tag ranges drop-candidate] {}

# ---- the drop ----------------------------------------------------------------
# A gone directory refuses the move, and the file stays where it was.
::questlog::ui::app::on_drop_move [list $kiln2] $F_ASH
update
check "a drop on a gone folder is refused" [string match "*no longer exists*" $::refused] 1
check "and the session stays in its file" [file isfile $kiln2] 1
check "and in its folder" [$SL sget $kiln2 folder] $F_KILN
# A living nested folder takes the session: the file moves under its project
# folder and the store follows.
set ::refused ""
set moved [file join $SAND .claude projects $F_GLAZE kiln-2.jsonl]
::questlog::ui::app::on_drop_move [list $kiln2] $F_GLAZE
update
check "a drop on a living nested folder raises nothing" $::refused ""
check "the file moved into the nested folder's project folder" \
    [list [file isfile $moved] [file isfile $kiln2]] {1 0}
check "the store holds it under the nested folder" \
    [list [$SL has_session $moved] [$SL sget $moved folder]] [list 1 $F_GLAZE]
check "the nested folder's heading counts it" \
    [dict get [$SL node_aggregate [$SL fid $F_GLAZE]] count] 2
check "the domain audit is clean" [$SL audit] {}
check "no audit trip" [info exists ::STREAMTREE_AUDIT_TRIPPED] 0

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
