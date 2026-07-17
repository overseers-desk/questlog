#!/usr/bin/env wish9.0
# The filter cut: what an active filter contains that the search never loaded.
#
# A filter filters loaded rows, so a session that belongs to the filter but that
# the search left on disk is invisible - and a session RUNNING RIGHT NOW that the
# list does not show is the worst of it, because an unqualified "1 session" then
# reads as "nothing else is running" while a process burns tokens. The cure is
# not to let the filter read disk (that would make it a search and cost the
# selection): it is to count the omission, say it, and offer the way out.
#
# Two searches genuinely cut a running session, and both are exercised here:
# the folder scope (hard even for a live session, see reconcile_running) and a
# content search (with one active, the matches decide what loads). A recency
# window alone does not: the reconciler already imports a live session that is
# only out of the window, which is why the window is not what is tested.
#
# Under test, on a real SessionList over a sandbox corpus:
#   1. the strip narrates the cut, from the membership the poll pushes in;
#   2. an EMPTY list under a filter says the cut rather than nothing at all;
#   3. the banner names the missing session and the criterion that excluded it;
#   4. "show it" reads that one session in, pins it, and the cut closes;
#   5. the pin survives the next reconcile, which would otherwise drop a row the
#      scope does not admit;
#   6. "widen" hands the blamed criterion back to the caller;
#   7. the filter stays a pure UI operation: toggling it loads nothing;
#   8. a member no criterion excluded is worded as one, and not as a session with
#      no file - the banner cannot deny a transcript it is offering to load.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _filtercut_sandbox]
set FOLDER "-tmp-filtercut-proj"
set OTHER  "-tmp-filtercut-other"
set INSIDE  /tmp/filtercut/proj
set OUTSIDE /tmp/filtercut/other

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add $ROOT
package require leash
package require streamtree
foreach f {config.tcl lib/cost.tcl ui/theme.tcl lib/path.tcl lib/scope.tcl \
           lib/sessionlist.tcl lib/jsonl.tcl lib/match.tcl ui/terminal.tcl \
           ui/live.tcl lib/scan.tcl lib/search.tcl ui/drag.tcl ui/toolbar.tcl \
           ui/sessions.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

::questlog::path::_real_file delete -force $SAND
set PROJDIR  [file join $SAND .claude projects $FOLDER]
set OTHERDIR [file join $SAND .claude projects $OTHER]
::questlog::path::_real_file mkdir $PROJDIR
::questlog::path::_real_file mkdir $OTHERDIR
set ::env(HOME) $SAND

proc noop {args} {}

proc write_session {path cwd prompts ts} {
    set fh [open $path w]
    set t 0
    foreach p $prompts {
        puts $fh "{\"type\":\"user\",\"cwd\":\"$cwd\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"role\":\"user\",\"content\":\"$p\"}}"
        puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
        incr t
    }
    close $fh
}

# A sits inside the folder scope. B runs in another project: the scope keeps it
# out of the list however live it is, so only the registry knows it is there.
set Ap [file join $PROJDIR aaaa.jsonl]
set Bp [file join $OTHERDIR bbbb.jsonl]
write_session $Ap $INSIDE  {a-first a-second} "2026-05-24T17:00"
write_session $Bp $OUTSIDE {b-first b-second} "2026-05-24T18:00"
file mtime $Ap [clock seconds]
file mtime $Bp [clock seconds]

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc lookup {path}   { return [$::Scan lookup $path] }
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

# The widen escape hands its criterion to the caller (in the app, the toolbar,
# which drops it and republishes).
set ::widened ""
proc widen {criterion} { set ::widened $criterion }

set SL [::questlog::ui::SessionList new .s resolvef lookup noop noop noop noop noop \
            noop scanpath noop subagentsf noop widen]
pack .s -fill both -expand 1

set fails 0
proc check {name got want} {
    if {$got eq $want} { puts "ok   - $name" } else {
        puts "FAIL - $name"; puts "       got:  $got"; puts "       want: $want"; incr ::fails
    }
}
proc strip {} { return [set [.s.bar.status cget -textvariable]] }
proc banner {} {
    if {[winfo manager .s.cut] eq ""} { return "" }
    return [.s.cut.msg cget -text]
}
proc settle {} { update; after 400; update }

# What the live registry reports (ui/live.tcl's shape: uuid -> {path cwd}), and
# the running set the list already takes each tick. B is running; no search the
# list ran would have loaded it.
set MEMBERS [dict create bbbb [dict create path $Bp cwd $OUTSIDE]]
set LIVE    [dict create bbbb $Bp]

proc snap {args} {
    return [dict merge [dict create since all min_turns 1 search "" \
        subtree [list $::INSIDE]] $args]
}

# --- 1. Browse, scoped to one project. B runs in another, so it never loads.
$SL apply_filter [snap]
set ::scan_done 0
$::Scan extend [snap]
after 300 [list set ::scan_done 1]
vwait ::scan_done
$SL toggle_folder $FOLDER
$SL reconcile_running $LIVE
update
check "A loaded (inside the scope)"        [$SL has_session $Ap] 1
check "B not loaded (outside the scope)"   [$SL has_session $Bp] 0
check "no filter on: the strip claims nothing about one" [strip] ""

# --- 2. The Running filter goes on and the poll pushes in the membership. The list
#        is now EMPTY - A is not running, B was never loaded - and it must not
#        stand there in silence.
$SL attr_filter_set running 1
$SL set_filter_members $MEMBERS
settle
check "A hidden (not running)"             [$SL sflag $Ap rendered] 0
check "the filter itself loaded nothing"   [$SL has_session $Bp] 0
check "the strip counts the cut" \
    [strip] "Running · showing 0 of 1 · 1 outside your criteria"
check "the banner names it and why" \
    [banner] \
    "1 running session outside your criteria: $OUTSIDE. The folder scope excluded it."
check "the banner offers to load it"       [.s.cut.show cget -text] "Show it"
check "the banner offers to widen"         [.s.cut.widen cget -text] "Clear the folder scope"

# --- 3. Widen hands the blamed criterion back to the caller. It reads nothing.
.s.cut.widen invoke
check "widen names the criterion that cut it" $::widened subtree

# --- 4. Show it: the one disk read, because the reader asked for this session by
#        name. It loads, and the Running filter paints it - it IS running - so the
#        cut closes without the filter being touched.
.s.cut.show invoke
settle
check "show it loaded the session"         [$SL has_session $Bp] 1
check "and painted it"                     [$SL sflag $Bp rendered] 1
check "the strip has nothing left to report" [strip] "Running · showing 1 of 1"
check "the banner is gone"                 [winfo manager .s.cut] ""

# --- 5. The next reconcile must not undo it: B is outside the scope, so nothing
#        but the pin keeps it in the list.
$SL reconcile_running $LIVE
settle
check "the pinned session survives the reconcile" [$SL has_session $Bp] 1
check "and is still painted"                      [$SL sflag $Bp rendered] 1

# --- 6. A pure filter: switching it off loads nothing and drops nothing.
set before [llength [$SL all_session_paths]]
$SL attr_filter_set running 0
settle
check "toggling the filter off loads nothing" \
    [llength [$SL all_session_paths]] $before
check "and the strip drops the filter clause"  [strip] ""

# --- 7. A content search cuts a running session too: with criteria active the
#        matches decide what loads, and a live session with no hit is not among
#        them. Nothing here reads the running session's file.
set SEARCH [snap search a-first subtree {}]
$SL apply_filter $SEARCH
$SL attr_filter_set running 1
$SL add_session_matches [list [dict create path $Ap folder $FOLDER \
    btype user content a-first lineoff 0]]
$SL reconcile_running $LIVE
$SL set_filter_members $MEMBERS
settle
check "the search did not load the running session" [$SL has_session $Bp] 0
check "the strip counts the search's cut" \
    [strip] "Running · showing 0 of 1 · 1 outside your criteria"
check "the banner blames the search" \
    [banner] \
    "1 running session outside your criteria: $OUTSIDE. Your search terms excluded it."
check "and offers to clear it"              [.s.cut.widen cget -text] "Clear the search"
.s.cut.widen invoke
check "widen names the search"              $::widened search

# --- 8. A cut member that NO criterion excluded. A bookmarked session sits on
#        disk inside the scope, the search carries no criterion at all, and the
#        list has not loaded it. The banner may not say there is nothing to load -
#        the "Show it" button beside that sentence would be offering to load
#        exactly what the sentence denies exists. It is not the same state as a
#        running session that has written no file yet, and it must not be worded
#        as one.
set Cp [file join $PROJDIR cccc.jsonl]
write_session $Cp $INSIDE {c-first c-second} "2026-05-24T19:00"
file mtime $Cp [clock seconds]
::questlog::path::set_bookmark $Cp

set OPEN [snap]
$SL apply_filter $OPEN
$SL attr_filter_set running 0
$SL attr_filter_set bookmarked 1
$SL reconcile_running [dict create]
$SL set_filter_members [dict create cccc [dict create path $Cp]]
settle
check "the bookmarked session was not loaded" [$SL has_session $Cp] 0
check "the banner blames no criterion, and does not deny the file" \
    [banner] \
    "1 bookmarked session outside your criteria: cccc. The search did not load it."
check "and still offers to load it"        [.s.cut.show cget -text] "Show it"
check "with nothing to widen"              [winfo manager .s.cut.widen] ""
.s.cut.show invoke
settle
check "show it loaded the session"         [$SL has_session $Cp] 1
check "and the banner is gone"             [winfo manager .s.cut] ""

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
