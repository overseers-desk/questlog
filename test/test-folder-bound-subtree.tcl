#!/usr/bin/env wish9.0
# "Search within this folder" on a parent folder means its subtree: the
# folder's directory and everything under it. The heading's menu hands the
# folder to the app, the app hands the folder's directory to the toolbar's
# subtree facet, and a scan under that bound admits the parent's sessions and
# the nested folder's alike while an unrelated root stays out. And a session
# pulled in behind shut headings (show_excluded's reveal_session) opens
# every folder above it, marker and all, so a nested folder's session is in
# view.
#
# The corpus, under a sandbox $HOME (every name fictional):
#   ~/proj/press            a session; the root
#   ~/proj/press/platen     nested, a session
#   ~/proj/anvil            an unrelated root

package require Tcl 9
package require Tk

set SAND [file join [pwd] _fbsubtree_sandbox]

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

proc write_session {cwd name ago} {
    ::questlog::path::_real_file mkdir $cwd
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

set PRESS  [file join $SAND proj press]
set PLATEN [file join $PRESS platen]
set ANVIL  [file join $SAND proj anvil]
set press1  [write_session $PRESS  press-1  1]
set platen1 [write_session $PLATEN platen-1 2]
set anvil1  [write_session $ANVIL  anvil-1  3]
foreach v {PRESS PLATEN ANVIL} { set F_$v [::questlog::path::encode_cwd [set $v]] }

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop {} {} {} 0]
proc scanpath {path}   { return [$::Scan scan_path $path] }
proc subagentsf {path} { return [$::Scan subagents_for $path] }
set SL [::questlog::ui::SessionList new .s ::questlog::ui::app::folder_cwd noop noop \
            noop noop noop noop scanpath noop subagentsf noop noop \
            ::questlog::ui::app::on_folder_bound]
pack .s -fill both -expand 1

# The app's folder-bound handler reads the resolver off Scan and pushes the
# directory into the toolbar; a stand-in toolbar records what it was handed.
set ::bound [list]
proc fake_toolbar {verb args} { if {$verb eq "add_value"} { lappend ::bound {*}$args } }
namespace eval ::questlog::ui::app {
    variable Scan $::Scan
    variable Toolbar fake_toolbar
}

set fails 0
proc check {name got want} {
    if {$got eq $want} { puts "ok   - $name" } else {
        puts "FAIL - $name"; puts "       got:  $got"; puts "       want: $want"; incr ::fails
    }
}
proc scan_with {snap} {
    $::SL apply_filter $snap
    set ::scan_done 0
    $::Scan extend $snap
    after 400 [list set ::scan_done 1]
    vwait ::scan_done
    update
}
proc loaded {} { return [lsort [lmap p [$::SL all_session_paths] { file tail $p }]] }

scan_with [dict create since 30d]
check "the whole corpus loads unbounded" [loaded] {anvil-1.jsonl platen-1.jsonl press-1.jsonl}

# ---- the bound a parent's heading asks for ---------------------------------
$SL folder_bound $F_PRESS
check "the heading's menu hands the toolbar the folder's directory as a subtree bound" \
    $::bound [list subtree $PRESS]
scan_with [dict create since 30d subtree [list [lindex $::bound 1]]]
check "under that bound the parent's and the nested folder's sessions load, the unrelated root's does not" \
    [loaded] {platen-1.jsonl press-1.jsonl}
check "the nested folder hangs under the parent as before" \
    [$SL node_field [$SL fid $F_PLATEN] parent] [$SL fid $F_PRESS]

# ---- a session revealed behind shut headings ---------------------------------
scan_with [dict create since 30d]
$SL toggle_folder $F_PRESS
update
check "the root shut, its nested folder is off the view" [$SL folder_attached $F_PLATEN] 0
$SL reveal_session $platen1
update
check "revealing the nested folder's session opens every folder above it, so it is drawn" \
    [list [$SL folder_expanded $F_PRESS] [$SL folder_expanded $F_PLATEN] [$SL sflag $platen1 rendered]] \
    {1 1 1}
set TX [set [info object namespace $SL]::Text]
# A heading's marker follows the image its line leads with.
check "the headings it opened show the open marker" \
    [lmap f [list $F_PRESS $F_PLATEN] {
        $TX get "[$SL node_field [$SL fid $f] start] +1c"
    }] {▾ ▾}
check "the audit is clean after the reveal" [$SL audit] {}

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
