#!/usr/bin/env wish9.0
# Both lenses at once: Running AND Bookmarked.
#
# The two lenses latch independently, so a reader can press both, and the list
# then shows the rows that are running AND bookmarked - one set, the intersection
# of two, not the union and not whichever lens was pressed last.
#
# The arithmetic behind the words has to move with it. A lens says what the
# SEARCH left on disk by counting its membership against the rows it loaded, and
# the membership of two lenses is the intersection of their sets: a session that
# is running but carries no bookmark is not a session this view would show, so
# the search did not withhold it and the banner may not count it. Over-counting
# there is invisible - the strip reads plausibly either way - which is why the
# corpus below holds one running session that is not bookmarked and one bookmark
# that is not running, both outside the search, and neither may be counted.
#
# Under test, on a real SessionList over a sandbox corpus:
#   1. the lenses compose: only the row that is both shows;
#   2. the membership is the intersection, so the cut is the intersection's;
#   3. the strip and the banner say both lenses, not one of them;
#   4. "show it" loads the cut member, which passes both lenses, and the cut
#      closes;
#   5. a lens is a filter: pressing both and releasing them loads nothing, drops
#      nothing and keeps the selection - even the selection of a row the lenses
#      hide while they are on.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _lensboth_sandbox]
set FOLDER "-tmp-lensboth-proj"
set OTHER  "-tmp-lensboth-other"
set THIRD  "-tmp-lensboth-third"
set INSIDE  /tmp/lensboth/proj
set OUTSIDE /tmp/lensboth/other
set ELSEWHERE /tmp/lensboth/third

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add $ROOT
package require leash
package require streamtree
foreach f {config.tcl lib/cost.tcl ui/theme.tcl lib/path.tcl lib/filter.tcl \
           lib/sessionlist.tcl lib/jsonl.tcl lib/match.tcl ui/terminal.tcl \
           ui/live.tcl lib/scan.tcl lib/search.tcl ui/drag.tcl ui/toolbar.tcl \
           ui/sessions.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

::questlog::path::_real_file delete -force $SAND
set PROJDIR  [file join $SAND .claude projects $FOLDER]
set OTHERDIR [file join $SAND .claude projects $OTHER]
set THIRDDIR [file join $SAND .claude projects $THIRD]
::questlog::path::_real_file mkdir $PROJDIR
::questlog::path::_real_file mkdir $OTHERDIR
::questlog::path::_real_file mkdir $THIRDDIR
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

# The corpus, and what each session is:
#   A  bookmarked, not running     inside the scope, loaded
#   B  running, not bookmarked     inside the scope, loaded
#   C  running AND bookmarked      inside the scope, loaded - the row both lenses admit
#   D  running AND bookmarked      another project: the folder scope cuts it
#   E  running, not bookmarked     a third project: cut too, but no member of the
#                                  pair of lenses, and so no part of what they claim
set Ap [file join $PROJDIR  aaaa.jsonl]
set Bp [file join $PROJDIR  bbbb.jsonl]
set Cp [file join $PROJDIR  cccc.jsonl]
set Dp [file join $OTHERDIR dddd.jsonl]
set Ep [file join $THIRDDIR eeee.jsonl]
write_session $Ap $INSIDE    {a-first a-second} "2026-05-24T17:00"
write_session $Bp $INSIDE    {b-first b-second} "2026-05-24T18:00"
write_session $Cp $INSIDE    {c-first c-second} "2026-05-24T19:00"
write_session $Dp $OUTSIDE   {d-first d-second} "2026-05-24T20:00"
write_session $Ep $ELSEWHERE {e-first e-second} "2026-05-24T21:00"
foreach p [list $Ap $Bp $Cp $Dp $Ep] { file mtime $p [clock seconds] }
foreach p [list $Ap $Cp $Dp] { ::questlog::path::set_bookmark $p }

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc lookup {path}   { return [$::Scan lookup $path] }
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }
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

# What each lens knows outside the search: the live registry reports every session
# running on this machine (uuid -> {path cwd}), the bookmark sweep every +x file
# on disk (uuid -> {path}). Neither owes anything to the search's window.
set RUN [dict create \
    bbbb [dict create path $Bp cwd $INSIDE] \
    cccc [dict create path $Cp cwd $INSIDE] \
    dddd [dict create path $Dp cwd $OUTSIDE] \
    eeee [dict create path $Ep cwd $ELSEWHERE]]
set BM [dict create \
    aaaa [dict create path $Ap] \
    cccc [dict create path $Cp] \
    dddd [dict create path $Dp]]
set LIVE [dict create bbbb $Bp cccc $Cp dddd $Dp eeee $Ep]

# The poll's job, as app.tcl does it: gather a set for each lens that has one and
# hand the list what they jointly claim. With both lenses on that is the
# intersection, which is the only membership the counts may be measured against.
proc push {snap} {
    set sets [list]
    foreach lens [::questlog::sessionlist::member_lenses $snap] {
        switch -- $lens {
            running    { lappend sets $::RUN }
            bookmarked { lappend sets $::BM }
        }
    }
    $::SL set_lens_members [::questlog::sessionlist::lens_members $sets]
}

proc snap {run bm} {
    return [dict create since all min_turns 1 search "" subtree [list $::INSIDE] \
        listview [dict create running_only $run bookmarked_only $bm model ""]]
}

# --- 1. Browse, scoped to one project: A, B and C load; D and E never do.
$SL apply_filter [snap 0 0]
set ::scan_done 0
$::Scan extend [snap 0 0]
after 300 [list set ::scan_done 1]
vwait ::scan_done
$SL toggle_folder $FOLDER
$SL reconcile_running $LIVE
update
check "A loaded" [$SL has_session $Ap] 1
check "B loaded" [$SL has_session $Bp] 1
check "C loaded" [$SL has_session $Cp] 1
check "D not loaded (another project)" [$SL has_session $Dp] 0
check "E not loaded (another project)" [$SL has_session $Ep] 0
check "no lens on: the strip claims nothing about one" [strip] ""

# The selection a filter must not cost the reader. A is bookmarked and not
# running, so both lenses below will hide it: the hardest row to keep.
$SL selection_set $Ap
update
check "A is selected" [$SL is_selected $Ap] 1
set loaded_before [llength [$SL all_session_paths]]

# --- 2. Running alone: B and C show, and the cut is every running session the
#        search left on disk - D and E both.
$SL apply_listview [snap 1 0]
push [snap 1 0]
settle
check "Running: A hidden"    [$SL sflag $Ap rendered] 0
check "Running: B shown"     [$SL sflag $Bp rendered] 1
check "Running: C shown"     [$SL sflag $Cp rendered] 1
check "Running: the strip counts every running session" \
    [strip] "Running · showing 2 of 4 · 2 outside your search"

# --- 3. Bookmarked joins Running. Only C is both, so only C shows - and the
#        membership is now the INTERSECTION: D is running and bookmarked, E is
#        running alone. E is no member of this view, so the search did not cut it
#        from this view, and the count says 1, not 2. Were E counted, the banner
#        would name its project beside D's.
$SL apply_listview [snap 1 1]
push [snap 1 1]
settle
check "both: A hidden (not running)"     [$SL sflag $Ap rendered] 0
check "both: B hidden (not bookmarked)"  [$SL sflag $Bp rendered] 0
check "both: C shown (running and bookmarked)" [$SL sflag $Cp rendered] 1
check "both: one row shows"              [$SL folder_visible_count $FOLDER] 1
check "both: the strip counts the intersection, not either lens" \
    [strip] "Running and Bookmarked · showing 1 of 2 · 1 outside your search"
check "both: the banner names the cut member and says both lenses" \
    [banner] \
    "1 running and bookmarked session outside your search: $OUTSIDE.\
     The folder scope excluded it."
check "both: the lenses loaded nothing" \
    [llength [$SL all_session_paths]] $loaded_before
check "both: the selection survives a lens that hides its row" \
    [$SL is_selected $Ap] 1

# --- 4. Show it: the reader asked for the cut member by name, so it is read in.
#        It is running and bookmarked, so both lenses paint it and the cut closes
#        without either lens being touched.
.s.cut.show invoke
settle
check "show it loaded the cut member"  [$SL has_session $Dp] 1
check "and both lenses paint it"       [$SL sflag $Dp rendered] 1
check "the strip has nothing left to report" \
    [strip] "Running and Bookmarked · showing 2 of 2"
check "the banner is gone"             [winfo manager .s.cut] ""
check "and the running session that carries no bookmark was never pulled in" \
    [$SL has_session $Ep] 0

# --- 5. Releasing Bookmarked leaves Running pressed, and the count returns to the
#        running membership alone: the two lenses are independent, and the strip
#        re-derives what it is speaking for rather than remembering it.
$SL apply_listview [snap 1 0]
push [snap 1 0]
settle
check "Running alone again: B shows"  [$SL sflag $Bp rendered] 1
check "Running alone again: the strip counts running sessions" \
    [strip] "Running · showing 3 of 4 · 1 outside your search"

# --- 6. Releasing both: every loaded row paints again, the strip drops the lens
#        clause, and the selection the reader made before any of this is still
#        theirs. Nothing was loaded and nothing dropped by a lens the whole way.
$SL apply_listview [snap 0 0]
push [snap 0 0]
settle
check "no lens: A renders again"   [$SL sflag $Ap rendered] 1
check "no lens: A still selected"  [$SL is_selected $Ap] 1
check "no lens: the strip drops the lens clause" [strip] ""
check "the only session any of this loaded is the one the reader named" \
    [llength [$SL all_session_paths]] [expr {$loaded_before + 1}]

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
