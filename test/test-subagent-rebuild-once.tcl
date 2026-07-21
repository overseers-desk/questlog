#!/usr/bin/env wish9.0
# Expanded subagent rows must render exactly once across a rebuild (issue #52).
#
# On a rebuild (a metric sort-header click is the easiest trigger) two writers
# both drew an expanded session's subagents: wire_session_row's render_children,
# fired when the session row is re-laid, and the base class's render_subtree
# recursion, which then re-lays each child too. render_children is the single
# writer - render_subtree stops at a session, leaving its subagents to
# render_children - so a rebuild draws each subagent once. This expands a
# session, rebuilds via set_sort, and asserts no child line is duplicated.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _subrebuild_sandbox]
set FOLDER "-tmp-subrebuild-proj"

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
set PROJDIR [file join $SAND .claude projects $FOLDER]
::questlog::path::_real_file mkdir $PROJDIR
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

# F with three subagents; a sibling G with none. Moments are offsets from now so
# the fixture cannot age out of the 30d window overnight.
proc session_moment {days_ago} { return [expr {[clock seconds] - $days_ago*24*3600}] }
set Fp [file join $PROJDIR ffff.jsonl]
write_session $Fp {f-first f-second} "2026-05-24T17:00"
set SUBDIR [file join $PROJDIR ffff subagents]
::questlog::path::_real_file mkdir $SUBDIR
foreach a {agent-1 agent-2 agent-3} {
    write_session [file join $SUBDIR $a.jsonl] {subwork} "2026-05-24T17:00"
}
set Gp [file join $PROJDIR gggg.jsonl]
write_session $Gp {g-alpha g-beta} "2026-05-23T10:00"
file mtime $Fp [session_moment 1]
file mtime $Gp [session_moment 2]

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }
proc subcost {path} {}

set SL [::questlog::ui::SessionList new .s resolvef noop noop noop noop noop noop \
            scanpath noop subagentsf subcost]
pack .s -fill both -expand 1

set ns [info object namespace $SL]
set TX [set ${ns}::Text]
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
# Physical line count in the text buffer: a duplicated child block shows up as
# extra lines the node marks no longer point at.
proc nlines {} { return [lindex [split [$::TX index "end-1c"] .] 0] }
# How many buffer lines carry the childhead style tag (a subagent header line).
# A duplicated child block doubles this count.
proc childhead_lines {} {
    set n 0
    set total [nlines]
    for {set i 1} {$i <= $total} {incr i} {
        if {"childhead" in [$::TX tag names $i.0]} { incr n }
    }
    return $n
}

$SL apply_filter [dict create since 30d]
set ::scan_done 0
$::Scan extend [dict create since 30d]
after 200 [list set ::scan_done 1]
vwait ::scan_done
$SL toggle_folder $FOLDER
update
$SL toggle_subagents $Fp
update

check "F has three children" [llength [$SL session_child_paths $Fp]] 3
set before_lines [nlines]
set before_heads [childhead_lines]
check "three subagent header lines before the rebuild" $before_heads 3

# The rebuild: a metric sort-header click. Before the fix this re-drew F's three
# subagents twice, leaving three orphaned child lines behind.
$SL set_sort size
update

check "the line count is unchanged by the rebuild" [nlines] $before_lines
check "still three subagent header lines after the rebuild" [childhead_lines] 3
check "F still has three children in the model" \
    [llength [$SL session_child_paths $Fp]] 3
check "domain audit clean after the rebuild" [$SL audit] {}

# A second rebuild (sort back) must not accumulate either.
$SL set_sort date
update
check "no accumulation across a second rebuild" [childhead_lines] 3

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
