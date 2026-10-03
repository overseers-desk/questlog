#!/usr/bin/env wish9.0
# A folder's own sessions read as its own, not as the contents of the
# subfolder listed above them. Folder FA holds subfolder FB and two sessions
# of its own; FB holds one. Checked:
#   - a session's title starts at the x of its sibling subfolder's label;
#   - every line leads with an image carrying a hairline at the marker column
#     of each folder above it, and a shut folder adds none of its own;
#   - the running and bookmark marks trail the title;
#   - a session's subagent chevron shows only on a selected or open row, and a
#     double-click toggles the subagents without reopening the session.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _depthguides_sandbox]
set FA "-tmp-dg"
set FB "-tmp-dg-sub"

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
set ::questlog_config_only 1; source [file join $ROOT questlog]
foreach f {lib/cost.tcl ui/theme.tcl lib/path.tcl lib/listfilter.tcl \
           lib/match.tcl ui/terminal.tcl ui/live.tcl lib/scan.tcl lib/search.tcl \
           ui/drag.tcl ui/toolbar.tcl ui/reveal.tcl ui/sessions.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

::questlog::path::_real_file delete -force $SAND
set PROJECTS [file join $SAND .claude projects]
set CWD [dict create $FA [file join $SAND proj] $FB [file join $SAND proj sub]]
foreach f [list $FA $FB] {
    ::questlog::path::_real_file mkdir [file join $PROJECTS $f]
    ::questlog::path::_real_file mkdir [dict get $CWD $f]
}
set ::env(HOME) $SAND
unset -nocomplain ::env(CLAUDE_CONFIG_DIR)

proc noop {args} {}
proc write_session {path days_ago} {
    set when [expr {[clock seconds] - $days_ago*24*3600}]
    set ts [clock format $when -format "%Y-%m-%dT%H:%M:%S" -gmt 1]
    set fh [open $path w]
    puts $fh "{\"type\":\"user\",\"cwd\":\"/tmp/proj\",\"timestamp\":\"${ts}Z\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}"
    puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}Z\",\"message\":{\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
    close $fh
    file mtime $path $when
}
# FB's session is the newest, so FB sorts above FA's own sessions only by
# being a folder (folders first), the arrangement that misled.
set SB  [file join $PROJECTS $FB b1.jsonl]
set SA1 [file join $PROJECTS $FA a1.jsonl]
set SA2 [file join $PROJECTS $FA a2.jsonl]
write_session $SB 1
write_session $SA1 2
write_session $SA2 3
# SA1 is bookmarked (an executable transcript); SA2 has a subagent.
::questlog::path::_real_file attributes $SA1 -permissions 0o755
set SUB [file join $PROJECTS $FA a2 subagents]
::questlog::path::_real_file mkdir $SUB
write_session [file join $SUB agent-1.jsonl] 3

set ::opened ""
proc openf {path lineno} { set ::opened [list $path $lineno] }

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f} { return [dict getdef $::CWD $f ""] }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

set SL [::questlog::ui::SessionList new .s resolvef openf noop noop noop noop noop \
            scanpath noop subagentsf noop]
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

$SL apply_filter [dict create since 30d]
set ::scan_done 0
$::Scan extend [dict create since 30d]
after 300 [list set ::scan_done 1]
vwait ::scan_done
update

set TX [set [info object namespace $SL]::Text]
proc open_folder {f open} {
    if {[$::SL node_field [$::SL fid $f] expanded] != $open} { $::SL toggle_folder $f }
    update
}
proc row_start {id} { return [$::TX index [$::SL node_field $id start]] }
proc line_img {id} { return [lindex [$::TX dump -image [row_start $id] "[row_start $id] +1c"] 1] }
# Whether line image img draws a hairline at the marker column of the folder
# at nesting m.
proc rule_at {img m} {
    set x [expr {$m * [$::SL marker_w] + [font measure QLList "▸"] / 2}]
    if {$x >= [image width $img]} { return 0 }
    return [expr {![$img transparency get $x 0]}]
}
proc title_x {path} {
    set s [row_start [$::SL sid $path]]
    set tab [$::TX search -exact "\t" $s "$s lineend"]
    return [lindex [$::TX bbox "$tab +1c"] 0]
}
proc line_has {path tag} {
    set s [row_start [$::SL sid $path]]
    return [expr {[llength [$::TX tag nextrange $tag $s "$s lineend"]] > 0}]
}

open_folder $FA 1
open_folder $FB 0
check "FB nests under FA" [$SL node_field [$SL fid $FB] parent] [$SL fid $FA]

# ---- a session's title starts where its sibling folder's label does --------
set fbs [row_start [$SL fid $FB]]
set marker [lindex [$TX tag nextrange foldchevron $fbs "$fbs lineend"] 0]
set label_x [lindex [$TX bbox "$marker +2c"] 0]
check "FA's own session title starts at FB's label x" [title_x $SA1] $label_x

# ---- depth guides --------------------------------------------------------
check "FA's heading carries no rule (a root)" [rule_at [line_img [$SL fid $FA]] 0] 0
check "FB's heading carries FA's rule" [rule_at [line_img [$SL fid $FB]] 0] 1
check "FA's own session carries FA's rule" [rule_at [line_img [$SL sid $SA1]] 0] 1
check "FA's own session carries no rule for shut FB" [rule_at [line_img [$SL sid $SA1]] 1] 0
open_folder $FB 1
check "FB's session carries FA's rule" [rule_at [line_img [$SL sid $SB]] 0] 1
check "FB's session carries FB's rule" [rule_at [line_img [$SL sid $SB]] 1] 1
check "FA's own session still carries no FB rule" [rule_at [line_img [$SL sid $SA1]] 1] 0

# ---- trailing marks ------------------------------------------------------
set s [row_start [$SL sid $SA1]]
set star [lindex [$TX tag nextrange attr-bookmarked $s "$s lineend"] 0]
check "the bookmark mark is drawn" [expr {$star ne ""}] 1
check "the bookmark mark trails the title" \
    [expr {$star ne "" && [lindex [$TX bbox $star] 0] > [title_x $SA1]}] 1

# ---- the subagent chevron and double-click -------------------------------
$SL set_selection [list]
update
check "a shut, unselected row shows no chevron" [line_has $SA2 chevron] 0
check "its title still lands on the title stop" [title_x $SA2] [title_x $SA1]
$SL selection_set $SA2
update
check "selecting the row shows its chevron" [line_has $SA2 chevron] 1
$SL set_selection [list]
update
check "deselecting the row hides it again" [line_has $SA2 chevron] 0

set s [row_start [$SL sid $SA2]]
set X [expr {[winfo rootx $TX] + [title_x $SA2] + 2}]
set Y [expr {[winfo rooty $TX] + [lindex [$TX bbox "$s +3c"] 1] + 2}]
set ::opened ""
$SL on_session_double $SA2 $X $Y
update
check "a double-click opens the subagents" [$SL node_field [$SL sid $SA2] expanded] 1
$SL on_session_release $SA2 $X $Y
check "the double-click's own release does not reopen the session" $::opened ""
check "an open, unselected row shows its chevron" [line_has $SA2 chevron] 1
$SL on_session_release $SA2 $X $Y
check "a later single click opens the session" $::opened [list $SA2 0]

check "domain audit clean at end" [$SL audit] {}
::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
