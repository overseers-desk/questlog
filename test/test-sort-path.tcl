#!/usr/bin/env wish9.0
# Regression test for sorting the main column (folder path).
#
# The metadata columns (date/size/cost/...) sort the list, and the leftmost
# subject zone, which shows each folder's path, sorts the FOLDERS by that
# displayed path: ascending on the first click (A->Z), flipping on re-click,
# while the sessions inside each folder keep their date-descending order. This
# drives it and asserts:
#   1. a subject-zone header click adopts the "path" sort;
#   2. path-ascending orders the folders by label A->Z (a real reorder, not the
#      arrival/date order);
#   3. a second click flips to Z->A;
#   4. sessions within a folder keep date-descending order under a path sort;
#   5. the "Session" header shows the direction arrow and the active highlight.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _sortpath_sandbox]

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

# Three project folders, each with two sessions inside the last fortnight.
# The folder's NEWEST session sets its place in the mtime-descending scan
# stream, so arrival order is proj-1, proj-2, proj-3. The displayed path
# (resolvef -> pretty_home) sorts to a DIFFERENT order, so a path sort is
# observable, not a no-op:
#   proj-1 -> ~/work/zoo     proj-2 -> ~/work/apple    proj-3 -> ~/work/mango
# Dictionary-ascending by label: apple, mango, zoo == proj-2, proj-3, proj-1.
set ::CWD [dict create \
    proj-1 [file join $SAND work zoo] \
    proj-2 [file join $SAND work apple] \
    proj-3 [file join $SAND work mango]]
proc resolvef {f} { return [dict getdef $::CWD $f ""] }

# {folder newer-days-ago older-days-ago}; the newer session is the folder's
# stream position. Ages are relative to now so the fixtures always sit inside
# the 30d window below: a calendar date would age out of it as the suite gets
# older and folders would silently stop rendering.
set SPECS {{proj-1 2 3} {proj-2 4 5} {proj-3 6 7}}
set P1PATHS [list]   ;# proj-1's two session paths, newest first
set NOW [clock seconds]
foreach spec $SPECS {
    lassign $spec folder d1 d2
    set dir [file join $SAND .claude projects $folder]
    ::questlog::path::_real_file mkdir $dir
    foreach ago [list $d1 $d2] {
        set p [file join $dir s$ago.jsonl]
        set ts [expr {$NOW - $ago*86400}]
        write_session $p [list a-$ago b-$ago] \
            [clock format $ts -format "%Y-%m-%dT%H:%M" -gmt 1]
        file mtime $p $ts
        if {$folder eq "proj-1"} { lappend P1PATHS $p }
    }
}

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc lookup {path}     { return [$::Scan lookup $path] }
proc scanpath {path}   { return [$::Scan scan_path $path] }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

set SL [::questlog::ui::SessionList new .s resolvef lookup noop noop noop noop noop \
            noop scanpath noop subagentsf noop]
pack .s -fill both -expand 1
$SL apply_filter [dict create since 30d]

set ns [info object namespace $SL]
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
proc rootkeys {} {
    global SL ns
    return [lmap fid [set ${ns}::Roots] { $SL node_field $fid key }]
}
proc rootlabels {} {
    global SL ns
    return [lmap fid [set ${ns}::Roots] { $SL node_pget $fid label "" }]
}

# Stream the three folders in under the default (date-desc) sort.
set ::scan_done 0
$::Scan extend [dict create since 30d]
after 300 [list set ::scan_done 1]
vwait ::scan_done
update

check "three folders rendered" [llength [rootkeys]] 3

# Arrival order is the mtime-descending stream order.
set arrival [rootkeys]
check "folders arrive newest-first" $arrival {proj-1 proj-2 proj-3}

# proj-1's sessions, captured under the default sort, are date-descending.
set p1_date_order [$SL folder_session_paths proj-1]
check "sessions stream date-descending within a folder" $p1_date_order $P1PATHS

# Expected folder orders, derived from the live labels (not hard-coded), so the
# test tracks resolvef rather than restating it.
set labelled [lmap fid [set ${ns}::Roots] { list [$SL node_field $fid key] [$SL node_pget $fid label ""] }]
set want_asc  [lmap e [lsort -dictionary -index 1 $labelled] { lindex $e 0 }]
set want_desc [lmap e [lsort -dictionary -decreasing -index 1 $labelled] { lindex $e 0 }]
check "the path order genuinely differs from arrival order" \
    [expr {$arrival ne $want_asc}] 1

# ---- 1: a subject-zone header click adopts the path sort -----------------
# x=10 -> cx=2, left of every right-pinned metadata column.
$SL on_header_click 10
update
check "a subject-zone click sorts by path" [set ${ns}::SortKey] path
check "a path sort starts ascending (A->Z)" [set ${ns}::SortDir] asc

# ---- 2: ascending orders the folders by their displayed label ------------
check "path-ascending orders folders by label A->Z" [rootkeys] $want_asc
check "labels are in ascending dictionary order" \
    [rootlabels] [lsort -dictionary [rootlabels]]

# ---- 4: sessions within a folder keep date-descending order --------------
check "a path sort leaves within-folder session order date-descending" \
    [$SL folder_session_paths proj-1] $p1_date_order

# ---- 3: a second click flips to descending -------------------------------
$SL set_sort path
update
check "re-clicking the path header flips to descending" [set ${ns}::SortDir] desc
check "path-descending reverses the folder order" [rootkeys] $want_desc

# ---- 5: the Session header shows the arrow and active highlight ----------
$SL set_sort cost ;# move the active column away, then click the subject again
$SL on_header_click 10
update
set HDR [set ${ns}::Top].body.hdr
set hline [$HDR get 1.0 "1.0 lineend"]
check "the Session header carries the ascending arrow" \
    [string range $hline 0 8] "Session ▲"
check "the Session label is the active (highlighted) header" \
    [$HDR tag ranges colactive] {1.0 1.9}

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
