#!/usr/bin/env wish9.0
# The live list hangs each folder where the container rule would: one
# corpus fed to ::questlog::path::container_tree (the rule as a pure
# function over {folder dir} pairs) and streamed into a SessionList gives
# the same parent for every folder, and the same label. The corpus mixes
# the cases the rule decides: a root with sessions of its own, a child
# folder, a chain of directories holding no folder, a branch point holding
# none (whose children step up), a project whose sessions all fall outside
# the window over two folders (a group row), a directory that is gone, and an
# unrelated root. Every name fictional.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _treeparity_sandbox]
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

# A session that ran in cwd, filed under the folder Claude Code names for it.
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
    return $folder
}

# cwd, the days back its session ran, and whether the directory exists.
set CORPUS {
    {proj/orchard                      1 1}
    {proj/orchard/harvest              2 1}
    {proj/orchard/trellis/espalier     3 1}
    {proj/orchard/grants/spring-2026   4 0}
    {proj/kiln/glaze                   5 1}
    {proj/kiln/wheel                   6 1}
    {proj/kiln/wheel/spokes            7 1}
    {proj/anvil                        8 1}
    {proj/forge                       60 1}
    {proj/forge/bellows                9 1}
    {proj/forge/tongs/pliers          10 1}
    {proj/forge/quench                11 1}
}
set entries [list]
set groups [list]
set i 0
foreach row $CORPUS {
    lassign $row rel ago exists
    set cwd [file join $SAND $rel]
    set folder [write_session $cwd s[incr i] $ago $exists]
    if {$ago > 30} { lappend groups [list $folder $cwd] } else { lappend entries [list $folder $cwd] }
    dict set rel_of $folder $rel
}

# The rule's answer: for every folder, its parent folder ("" at a root) and
# its label, root labels through the same home abbreviation the list uses.
proc rule_of {nodes {parent ""} {dict {}}} {
    foreach node $nodes {
        set key [lindex [dict get $node keys] 0]
        set label [dict get $node label]
        if {$parent eq ""} { set label [::questlog::path::pretty_home $label] }
        dict set dict $key [list $parent $label]
        set dict [rule_of [dict get $node children] $key $dict]
    }
    return $dict
}
set rule [rule_of [::questlog::path::container_tree $entries $groups]]

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop {} {} {} 0]
proc scanpath {path}   { return [$::Scan scan_path $path] }
proc resolvef {f}      { return [$::Scan folder_cwd $f] }
proc subagentsf {path} { return [$::Scan subagents_for $path] }
set SL [::questlog::ui::SessionList new .s resolvef noop noop noop noop noop \
            noop scanpath noop subagentsf noop]
pack .s -fill both -expand 1
$SL apply_filter [dict create since 30d]

set fails 0
proc check {name got want} {
    if {$got eq $want} { puts "ok   - $name" } else {
        puts "FAIL - $name"; puts "       got:  $got"; puts "       want: $want"; incr ::fails
    }
}

set ::scan_done 0
$::Scan extend [dict create since 30d]
after 400 [list set ::scan_done 1]
vwait ::scan_done
update

# The list's answer, in the same shape.
proc live_of {} {
    set dict [dict create]
    foreach fid [$::SL all_node_ids] {
        if {[$::SL node_field $fid kind] ne "folder"} continue
        set p [$::SL node_field $fid parent]
        dict set dict [$::SL node_field $fid key] \
            [list [expr {$p eq "" ? "" : [$::SL node_field $p key]}] [$::SL folder_label $fid]]
    }
    return $dict
}

check "the list holds a folder for every entry" \
    [lsort [dict keys [live_of]]] [lsort [dict keys $rule]]
foreach key [lsort [dict keys $rule]] {
    check "parent and label of [dict get $rel_of $key]" \
        [dict get [live_of] $key] [dict get $rule $key]
}
check "the domain audit is clean" [$SL audit] {}

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
