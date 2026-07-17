#!/usr/bin/env wish9.0
# Both filters at once: Running AND Bookmarked.
#
# The two filters latch independently, so a reader can press both, and the list
# then shows the rows that are running AND bookmarked - one set, the intersection
# of two, not the union and not whichever filter was pressed last.
#
# The arithmetic behind the words has to move with it. A filter says what the
# SEARCH left on disk by counting its membership against the rows it loaded, and
# the membership of two filters is the intersection of their sets: a session that
# is running but carries no bookmark is not a session this view would show, so
# the search did not withhold it and the banner may not count it. Over-counting
# there is invisible - the strip reads plausibly either way - which is why the
# corpus below holds one running session that is not bookmarked and one bookmark
# that is not running, both outside the search, and neither may be counted.
#
# The model filter is here for what it may NOT say. It hides loaded rows like the
# other two, but it has no membership outside the search - a row's model is known
# only once its transcript is parsed, and a filter parses nothing - so it can name
# no session the search left on disk. The words and the number must therefore both
# come from the filters that DO have one: with Running pressed and a model picked,
# the strip and the banner name Running alone and count Running's membership. A
# phrase built from every filter that is on would read "1 running and model session
# outside your criteria" over a number that only ever counted running ones, and claim
# the model was checked against the disk. It cannot be.
#
# Under test, on a real SessionList over a sandbox corpus:
#   1. the filters compose: only the row that is both shows;
#   2. the membership is the intersection, so the cut is the intersection's;
#   3. the strip and the banner say both filters, not one of them;
#   4. "show it" loads the cut member, which passes both filters, and the cut
#      closes;
#   5. a label shut off beside Running is named by neither line, and the count is
#      Running's membership whether the exclusion spares the rows or hides them all;
#   6. the model filter alone claims no cut, though it is hiding every row;
#   7. a filter is a pure view op: pressing both and releasing them loads nothing,
#      drops nothing and keeps the selection - even the selection of a row the
#      filters hide while they are on.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _filterboth_sandbox]
set FOLDER "-tmp-filterboth-proj"
set OTHER  "-tmp-filterboth-other"
set THIRD  "-tmp-filterboth-third"
set INSIDE  /tmp/filterboth/proj
set OUTSIDE /tmp/filterboth/other
set ELSEWHERE /tmp/filterboth/third

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
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
#   C  running AND bookmarked      inside the scope, loaded - the row both filters admit
#   D  running AND bookmarked      another project: the folder scope cuts it
#   E  running, not bookmarked     a third project: cut too, but no member of the
#                                  pair of filters, and so no part of what they claim
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

# What each filter knows outside the search: the live registry reports every session
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

# The poll's job, as app.tcl does it: gather a set for each filter that has one and
# hand the list what they jointly claim. The filters live in the engine, so read
# which ones are on from the engine's own filter state, not from a snapshot the
# caller builds. With both filters on that is the intersection, which is the only
# membership the counts may be measured against.
proc push {} {
    set state [$::SL attr_filter_all]
    set sets [list]
    foreach f [::questlog::sessionlist::member_filters $state] {
        switch -- $f {
            running    { lappend sets $::RUN }
            bookmarked { lappend sets $::BM }
        }
    }
    $::SL set_filter_members [::questlog::sessionlist::filter_members $sets]
}

# The model filter excludes LABELS a loaded row carries, which is what the filter
# checklist offers: every session in the corpus is written by one model, so
# shutting off MODEL hides every row the other filters admit, and shutting off
# OTHER_MODEL (a label no row here carries) hides none of them.
set MODEL [::questlog::cost::model_label claude-3-5-sonnet-20241022]
set OTHER_MODEL "Opus 4.8"

proc snap {} {
    return [dict create since all min_turns 1 search "" subtree [list $::INSIDE]]
}

# --- 1. Browse, scoped to one project: A, B and C load; D and E never do.
$SL apply_filter [snap]
set ::scan_done 0
$::Scan extend [snap]
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
check "no filter on: the strip claims nothing about one" [strip] ""

# The selection a filter must not cost the reader. A is bookmarked and not
# running, so both filters below will hide it: the hardest row to keep.
$SL selection_set $Ap
update
check "A is selected" [$SL is_selected $Ap] 1
set loaded_before [llength [$SL all_session_paths]]

# --- 2. Running alone: B and C show, and the cut is every running session the
#        search left on disk - D and E both.
$SL attr_filter_set running 1
push
settle
check "Running: A hidden"    [$SL sflag $Ap rendered] 0
check "Running: B shown"     [$SL sflag $Bp rendered] 1
check "Running: C shown"     [$SL sflag $Cp rendered] 1
check "Running: the strip counts every running session" \
    [strip] "Running · showing 2 of 4 · 2 outside your criteria"

# --- 3. Bookmarked joins Running. Only C is both, so only C shows - and the
#        membership is now the INTERSECTION: D is running and bookmarked, E is
#        running alone. E is no member of this view, so the search did not cut it
#        from this view, and the count says 1, not 2. Were E counted, the banner
#        would name its project beside D's.
$SL attr_filter_set bookmarked 1
push
settle
check "both: A hidden (not running)"     [$SL sflag $Ap rendered] 0
check "both: B hidden (not bookmarked)"  [$SL sflag $Bp rendered] 0
check "both: C shown (running and bookmarked)" [$SL sflag $Cp rendered] 1
check "both: one row shows"              [$SL folder_visible_count $FOLDER] 1
check "both: the strip counts the intersection, not either filter" \
    [strip] "Running and Bookmarked · showing 1 of 2 · 1 outside your criteria"
check "both: the banner names the cut member and says both filters" \
    [banner] \
    "1 running and bookmarked session outside your criteria: $OUTSIDE.\
     The folder scope excluded it."
check "both: the filters loaded nothing" \
    [llength [$SL all_session_paths]] $loaded_before
check "both: the selection survives a filter that hides its row" \
    [$SL is_selected $Ap] 1

# --- 4. Show it: the reader asked for the cut member by name, so it is read in.
#        It is running and bookmarked, so both filters paint it and the cut closes
#        without either filter being touched.
.s.cut.show invoke
settle
check "show it loaded the cut member"  [$SL has_session $Dp] 1
check "and both filters paint it"       [$SL sflag $Dp rendered] 1
check "the strip has nothing left to report" \
    [strip] "Running and Bookmarked · showing 2 of 2"
check "the banner is gone"             [winfo manager .s.cut] ""
check "and the running session that carries no bookmark was never pulled in" \
    [$SL has_session $Ep] 0

# --- 5. Releasing Bookmarked leaves Running pressed, and the count returns to the
#        running membership alone: the two filters are independent, and the strip
#        re-derives what it is speaking for rather than remembering it.
$SL attr_filter_set bookmarked 0
push
settle
check "Running alone again: B shows"  [$SL sflag $Bp rendered] 1
check "Running alone again: the strip counts running sessions" \
    [strip] "Running · showing 3 of 4 · 1 outside your criteria"

# --- 6. A model shut off while Running is pressed. Two filters are on, and the
#        rows on screen answer to both - but only one of them can say what the
#        search left on disk, so only one of them may be named beside a number.
#        The model filter is not it: E is a running session the search never read,
#        and nothing knows what model E ran without opening it.
#
#        First shut off a label no loaded row carries, so the filter is on and
#        hides nothing: the lines must read exactly as with Running alone, above.
#
#        A row's model is the label the COST PASS put there: the worker parses the
#        transcript, the main thread stamps the label, and the result lands in two
#        places, because two readers want it. The scan's cache holds it for the
#        render, which reads a row back through LookupSession; the list's node holds
#        it for the count, which reads it with sget. ui/app.tcl makes both landings
#        on a cost result - update_cost always, refresh_cost either in the same turn
#        (cost_render immediate) or in the next coalesced flush. That is the only way
#        a model ever reaches a row, and it is why the filter can claim no member it
#        has not already loaded. Run the pass over the loaded rows so they carry
#        what the app's rows carry.
foreach path [$SL all_session_paths] {
    set cd [::questlog::cost::build_cost_dict [::questlog::cost::parse_file $path]]
    $::Scan update_cost $path $cd
    $SL refresh_cost $path $cd
}
update
check "the cost pass put the model on the rows" [$SL sget $Bp model] $MODEL
$SL attr_filter_set model [list $OTHER_MODEL]
push
settle
check "exclusion beside Running: rows carrying other labels still show" \
    [$SL sflag $Bp rendered] 1
check "exclusion beside Running: the strip names Running alone" \
    [strip] "Running · showing 3 of 4 · 1 outside your criteria"
check "exclusion beside Running: the banner names Running alone" \
    [banner] \
    "1 running session outside your criteria: $ELSEWHERE.\
     The folder scope excluded it."

# Now shut off the label every loaded row carries, so the model filter hides every
# row the Running filter admits. Only `showing` may move: it is the rows on
# screen. The membership and the cut are Running's, and the model filter neither
# adds a member nor takes one away - it never looked. A phrase drawn from every
# active filter would now put "and model" over a 4 and a 1 that counted running
# sessions.
$SL attr_filter_set model [list $MODEL]
push
settle
check "the carried label shut off: it hides the rows Running admits" \
    [$SL sflag $Bp rendered] 0
check "the carried label shut off: no row is left showing" \
    [$SL folder_visible_count $FOLDER] 0
check "the carried label shut off: the strip still names Running, counts Running's members" \
    [strip] "Running · showing 0 of 4 · 1 outside your criteria"
check "the carried label shut off: the cut is Running's, the banner says only running" \
    [banner] \
    "1 running session outside your criteria: $ELSEWHERE.\
     The folder scope excluded it."
check "the model filter loaded nothing" \
    [llength [$SL all_session_paths]] [expr {$loaded_before + 1}]

# --- 7. The model filter alone. It is hiding every row in the list, so it is plainly
#        working - and it still claims nothing: there is no set of "sessions that
#        ran this model" to count the loaded rows against, and a filter with no
#        membership may not tell the reader the search cut one. No clause, no
#        banner, no offer to load anything.
$SL attr_filter_set running 0
push
settle
check "the model filter alone hides every row" [$SL folder_visible_count $FOLDER] 0
check "the model filter alone says nothing in the strip" [strip] ""
check "the model filter alone raises no cut banner"      [banner] ""

# --- 8. Releasing both: every loaded row paints again, the strip drops the filter
#        clause, and the selection the reader made before any of this is still
#        theirs. Nothing was loaded and nothing dropped by a filter the whole way.
$SL attr_filter_set model [list]
push
settle
check "no filter: A renders again"   [$SL sflag $Ap rendered] 1
check "no filter: A still selected"  [$SL is_selected $Ap] 1
check "no filter: the strip drops the filter clause" [strip] ""
check "the only session any of this loaded is the one the reader named" \
    [llength [$SL all_session_paths]] [expr {$loaded_before + 1}]

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
