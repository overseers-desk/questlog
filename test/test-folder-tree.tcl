#!/usr/bin/env wish9.0
# The session list is a tree of folders: a folder hangs under the folder whose
# directory most closely contains its own, whatever order the two arrive in,
# and what it draws follows the container rule (lib/path.tcl container_tree).
#
# The corpus, under a sandbox $HOME (every name fictional):
#   ~/proj/orchard                    sessions; the root the rest hang under
#   ~/proj/orchard/harvest            sessions, newer than orchard's, so it
#                                     arrives first and is adopted
#   ~/proj/orchard/trellis/espalier   sessions; trellis holds none, so the
#                                     label merges to trellis/espalier
#   ~/proj/orchard/grants/spring-2026 sessions, the directory gone: hangs under
#                                     orchard by its recorded path, marked
#   ~/proj/anvil                      sessions; an unrelated root
#
# Then orchard's own session leaves and it stays, a project folder grouping
# the folders beneath it; when all but one of those leave, the last steps up
# to the root; orchard's return takes it back.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _foldertree_sandbox]
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

set ORCHARD  [file join $SAND proj orchard]
set HARVEST  [file join $ORCHARD harvest]
set ESPALIER [file join $ORCHARD trellis espalier]
set GONE     [file join $ORCHARD grants spring-2026]
set ANVIL    [file join $SAND proj anvil]

set S_HARVEST  [write_session $HARVEST  harvest-1  1]
set S_ORCHARD  [write_session $ORCHARD  orchard-1  2]
set S_ESPALIER [write_session $ESPALIER espalier-1 3]
set S_GONE     [write_session $GONE     grants-1   4 0]
set S_ANVIL    [write_session $ANVIL    anvil-1    5]
foreach v {ORCHARD HARVEST ESPALIER GONE ANVIL} {
    set F_$v [::questlog::path::encode_cwd [set $v]]
}

set SL ""
# The GUI's scanner: no transcript peek, the cache warmed from each row's cwd.
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop {} {} {} 0]
proc scanpath {path}   { return [$::Scan scan_path $path] }
proc resolvef {f}      { return [$::Scan folder_cwd $f] }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

set SL [::questlog::ui::SessionList new .s resolvef noop noop noop noop noop \
            noop scanpath noop subagentsf noop]
pack .s -fill both -expand 1
$SL apply_filter [dict create since 30d]

set ns [info object namespace $SL]
set TX [set ${ns}::Text]
set fails 0
proc check {name got want} {
    if {$got eq $want} { puts "ok   - $name" } else {
        puts "FAIL - $name"; puts "       got:  $got"; puts "       want: $want"; incr ::fails
    }
}
proc rootkeys {} { return [lmap fid [$::SL roots] { $::SL node_field $fid key }] }
proc parent_of {f} {
    set p [$::SL node_field [$::SL fid $f] parent]
    return [expr {$p eq "" ? "" : [$::SL node_field $p key]}]
}
proc label_of {f} { return [$::SL folder_label [$::SL fid $f]] }
# The drawn rows top to bottom, each as kind:tail.
proc drawn {} {
    return [lmap id [$::SL all_rendered_nodes] {
        string cat [$::SL node_field $id kind] : [file tail [$::SL node_field $id key]]
    }]
}
proc heading_text {f} {
    set m [$::SL node_field [$::SL fid $f] start]
    return [string trim [$::TX get "$m linestart" "$m lineend"]]
}

set ::scan_done 0
$::Scan extend [dict create since 30d]
after 400 [list set ::scan_done 1]
vwait ::scan_done
update

# ---- the shape --------------------------------------------------------------
check "two roots, the containing folder and the unrelated one" \
    [rootkeys] [list $F_ORCHARD $F_ANVIL]
check "a folder that arrived before its parent hangs under it" \
    [parent_of $F_HARVEST] $F_ORCHARD
check "a folder two directories down hangs under the nearest folder" \
    [parent_of $F_ESPALIER] $F_ORCHARD
check "a folder whose directory is gone hangs under its living ancestor" \
    [parent_of $F_GONE] $F_ORCHARD
check "a folder's sessions are its sessions, not the folders beside them" \
    [lmap p [$SL folder_session_paths $F_ORCHARD] { file tail $p }] orchard-1.jsonl
check "the domain audit is clean" [$SL audit] {}

# ---- the labels -------------------------------------------------------------
check "a root is labelled by its absolute path" [label_of $F_ORCHARD] ~/proj/orchard
check "a nested folder is labelled relative to its parent" [label_of $F_HARVEST] harvest
check "a directory holding no folder merges into its child's label" \
    [label_of $F_ESPALIER] trellis/espalier
check "a gone directory's label is the dead remainder" \
    [label_of $F_GONE] grants/spring-2026

# ---- what is drawn ------------------------------------------------------------
# harvest arrived first and opened as the first root; orchard then took its
# place and opened with it, so what was in view stayed in view. The rest
# arrived shut.
check "browse opens the first root by recency and leaves the rest shut" [drawn] \
    [list folder:[file tail $F_ORCHARD] folder:[file tail $F_HARVEST] \
          session:harvest-1.jsonl folder:[file tail $F_ESPALIER] \
          folder:[file tail $F_GONE] session:orchard-1.jsonl \
          folder:[file tail $F_ANVIL]]
check "the folder the root took over is still open inside it" \
    [$SL folder_expanded $F_HARVEST] 1
# The label may truncate to the window; the marker sits past it, by the count.
check "the gone folder's heading carries the marker" \
    [string match "* $::questlog::ui::GLYPH_GONE (1)*" [heading_text $F_GONE]] 1
check "a living folder's heading carries none" \
    [string match "* harvest (1)*" [heading_text $F_HARVEST]] 1
$SL toggle_folder $F_HARVEST
update
check "shutting a nested folder takes its session off the view" \
    [lsearch [drawn] session:harvest-1.jsonl] -1
$SL toggle_folder $F_HARVEST
update
check "opening it draws its session under its heading" \
    [lsearch [drawn] session:harvest-1.jsonl] 2
# The roots order by the newest session anywhere beneath, whatever order they
# arrived in: orchard's newest is harvest's.
check "the roots sort by recency through the fold" \
    [lmap id [$SL sort_siblings [lreverse [$SL roots]]] { $SL node_field $id key }] \
    [list $F_ORCHARD $F_ANVIL]
$SL toggle_folder $F_ORCHARD
update
check "shutting the parent takes the nested folder off the view" \
    [$SL folder_attached $F_HARVEST] 0
check "and leaves it open in the store" [$SL folder_expanded $F_HARVEST] 1
$SL toggle_folder $F_ORCHARD
update
check "reopening the parent draws the nested folder open" \
    [lsearch [drawn] session:harvest-1.jsonl] 2

# A width change re-pins the metadata stops on the kind tags; a nested row's
# title stop rides its own tag and has to follow them.
set stag [$SL node_field [$SL sid $S_HARVEST] tag]
$TX configure -width [expr {[$TX cget -width] + 30}]
update
check "a nested row's stops follow the columns after a resize" \
    [lrange [$TX tag cget $stag -tabs] 2 end] [set ${ns}::ColTabs]

# A sort rebuilds from the store: the folders stay a run above the sessions.
$SL set_sort path
update
check "a rebuild keeps folders above sessions, sorted by label" [lrange [drawn] 0 5] \
    [list folder:[file tail $F_ANVIL] folder:[file tail $F_ORCHARD] \
          folder:[file tail $F_GONE] folder:[file tail $F_HARVEST] \
          session:harvest-1.jsonl folder:[file tail $F_ESPALIER]]
check "the audit is clean after the rebuild" [$SL audit] {}

# ---- a folder left holding only folders ----------------------------------------
$SL forget_session $S_ORCHARD
update
check "a project folder over several folders stays a row" [$SL has_folder $F_ORCHARD] 1
check "and keeps them" \
    [list [parent_of $F_HARVEST] [parent_of $F_ESPALIER] [parent_of $F_GONE]] \
    [list $F_ORCHARD $F_ORCHARD $F_ORCHARD]
check "the audit is clean with orchard a group" [$SL audit] {}
$SL add_scan_row [$::Scan scan_path $S_ORCHARD]
update
check "a session of the group's own lands in it" \
    [$SL folder_session_paths $F_ORCHARD] [list $S_ORCHARD]
$SL forget_session $S_ORCHARD
$SL forget_session $S_HARVEST
$SL forget_session $S_GONE
update
check "a group left over one folder is not a row" [$SL has_folder $F_ORCHARD] 0
check "the folder it held steps up" [lsort [rootkeys]] [lsort [list $F_ANVIL $F_ESPALIER]]
check "and carries its label in its own" [label_of $F_ESPALIER] ~/proj/orchard/trellis/espalier
check "the audit is clean after the step up" [$SL audit] {}
$SL add_scan_row [$::Scan scan_path $S_ORCHARD]
update
check "the folder's return takes it back" [parent_of $F_ESPALIER] $F_ORCHARD
check "relative again" [label_of $F_ESPALIER] trellis/espalier
check "the audit is clean at the end" [$SL audit] {}

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
