#!/usr/bin/env wish9.0
# Rolled-back branches in the session viewer: the turns a rewind abandoned fold
# under one ROLLED BACK line at their fork, folded at first and nested as the
# rewinds nest; the line toggles on a click and opens to a find step; the
# conversation after a branch measures its idle gap from the path that stood;
# rows pointing into a branch read muted; the copy affordances skip what the
# reader cannot see; and a rewind met by the live tail re-renders the session.
#
# Runs under wish (it builds a Viewer, so it needs Tk); run-audit routes it to
# wish9.0 on the private Xvfb. Standalone: DISPLAY=:95 wish9.0 test-viewer-branches.tcl
# With no DISPLAY it skips cleanly (exit 0) rather than dying on the Tk load.

package require Tcl 9
if {![info exists ::env(DISPLAY)] || $::env(DISPLAY) eq ""} {
    puts "skip - no DISPLAY (viewer branch test needs Tk)"
    exit 0
}
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
set ::questlog_config_only 1; source [file join $ROOT questlog]
foreach f {lib/debug.tcl lib/path.tcl lib/match.tcl \
           lib/cost.tcl ui/theme.tcl ui/reveal.tcl ui/viewer.tcl} {
    source [file join $ROOT $f]
}
::questlog::match::set_caps [dict create \
    content_cap     [::questlog::config::get content_cap] \
    snippet_lead    [::questlog::config::get snippet_lead] \
    snippet_trail   [::questlog::config::get snippet_trail] \
    tool_param_cap  [::questlog::config::get tool_param_cap] \
    tool_render_cap [::questlog::config::get tool_render_cap]]
::questlog::ui::theme::init
# Header times are local; pin the zone so they read the same anywhere.
set ::env(TZ) UTC

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
set ::bgerr [list]
proc bgerror {msg} { lappend ::bgerr $msg }

# One jsonl line: kind P typed prompt, A assistant reply (with a Read call when
# tool is 1), C a local-command caveat; u its uuid under parent p at time hhmm.
proc L {k u p hhmm text {tool 0}} {
    set ts "2026-10-17T[string range $hhmm 0 1]:[string range $hhmm 2 3]:00.000Z"
    set par [expr {$p eq "" ? "null" : "\"$p\""}]
    set head "\"uuid\":\"$u\",\"parentUuid\":$par,\"timestamp\":\"$ts\""
    switch -- $k {
        P { return "{\"type\":\"user\",$head,\"promptSource\":\"typed\",\"cwd\":\"/tmp/bproj\",\"message\":{\"role\":\"user\",\"content\":\"$text\"}}" }
        A {
            set blocks "{\"type\":\"text\",\"text\":\"$text\"}"
            if {$tool} {
                append blocks ",{\"type\":\"tool_use\",\"id\":\"t$u\",\"name\":\"Read\",\"input\":{\"file_path\":\"/tmp/$u.txt\"}}"
            }
            return "{\"type\":\"assistant\",$head,\"message\":{\"role\":\"assistant\",\"content\":\[$blocks\]}}"
        }
        C { return "{\"type\":\"user\",\"isMeta\":true,$head,\"message\":{\"role\":\"user\",\"content\":\"<local-command-caveat>Caveat</local-command-caveat>\"}}" }
    }
}
proc write_lines {path lines {mode w}} {
    set fh [open $path $mode]
    fconfigure $fh -encoding utf-8
    foreach l $lines { puts $fh $l }
    close $fh
}

set tmpbase [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set TMP [file join $tmpbase ql-branch-test-[pid]]
::questlog::path::_real_file mkdir $TMP

# ---- the session ------------------------------------------------------------
# The opening exchange at 13:00. At 15:20 the user asked "abandoned outer
# prompt" and went on two more turns; inside that stretch they had already
# rewound once ("abandoned inner prompt" for "inner replacement"). At 15:30
# they rewound the whole stretch and asked "live replacement prompt" from the
# opening answer. The live path's gap, 13:01 to 15:30, draws a divider; the
# branch's own end, 15:25, would not.
set JP [file join $TMP session.jsonl]
write_lines $JP [list \
    [L P p1 ""  1300 "Opening question"] \
    [L A a1 p1  1301 "Opening answer"] \
    [L P p2 a1  1520 "abandoned outer prompt"] \
    [L A a2 p2  1521 "zebra-outer reply" 1] \
    [L P p3 a2  1522 "outer second prompt"] \
    [L A a3 p3  1523 "outer second reply"] \
    [L P p4 a3  1524 "abandoned inner prompt"] \
    [L A a4 p4  1524 "zebra-inner reply"] \
    [L P p5 a3  1525 "inner replacement"] \
    [L A a5 p5  1525 "inner replacement reply"] \
    [L P p6 a1  1530 "live replacement prompt"] \
    [L A a6 p6  1531 "live answer"]]

set V [::questlog::ui::Viewer new .v]
pack .v -fill both -expand 1
$V show $JP 0 {}
update idletasks
update
set Text [$V textwidget]
set NS [info object namespace $V]

# Visible characters of a term's first occurrence: 0 while elided.
proc vischars {term} {
    set m [$::Text search -elide -- $term 1.0 end]
    if {$m eq ""} { return -1 }
    return [$::Text count -displaychars $m "$m + [string length $term]c"]
}
# The ROLLED BACK lines' text, outermost first, elided or not.
proc headers {} {
    set out {}
    foreach {s e} [$::Text tag ranges grouphdr] {
        lappend out [string trimright [$::Text get $s $e] \n]
    }
    return $out
}
# Click a ROLLED BACK line by its index in the document.
proc click_header {k} {
    set s [lindex [$::Text tag ranges grouphdr] [expr {2 * $k}]]
    $::Text see $s
    update idletasks
    lassign [$::Text bbox $s] x y
    $::V grouphdr_click [expr {$x + 2}] [expr {$y + 2}]
    update idletasks
}

# ---- 1. the folded reading --------------------------------------------------
check "two ROLLED BACK lines, outer then inner" [headers] [list \
    "▸ ROLLED BACK  3 turns · 15:20–15:25 · 1 rollback inside · \"abandoned outer prompt\"" \
    "▸ ROLLED BACK  1 turn · 15:24 · \"abandoned inner prompt\""]
check "the outer line is visible" [vischars "abandoned outer prompt\""] 23
check "the branch's turns are folded away" \
    [list [vischars "zebra-outer"] [vischars "outer second reply"] [vischars "zebra-inner"]] {0 0 0}
check "the inner line folds with the outer" [vischars "abandoned inner prompt\""] 0
check "the surviving turns read on" \
    [list [vischars "Opening answer"] [vischars "live replacement prompt"] [vischars "live answer"]] \
    {14 23 11}
set div [$Text search -elide -backwards -regexp -- {later ───} \
    [$Text search -elide -- "live replacement prompt" 1.0 end] 1.0]
check "the gap after the branch is the live path's, drawn and visible" \
    [list [expr {$div ne ""}] [$Text count -displaychars $div "$div +5c"]] {1 5}

# ---- 2. turns and rows -------------------------------------------------------
set TurnList [dict get [set ${NS}::BandDesc] turns list]
check "every turn keeps its row" [$TurnList size] 6
set nums {}
for {set i 0} {$i < 6} {incr i} { lappend nums [lindex [$TurnList get $i] 0] }
check "only the turns kept are numbered" $nums {1 ↩ ↩ ↩ ↩ 2}
check "the head strip counts the turns kept" [set ${NS}::Kept] 2
set inks {}
for {set i 0} {$i < 6} {incr i} { lappend inks [$TurnList itemcget $i -foreground] }
set user [::questlog::ui::theme::c user]
set muted [::questlog::ui::theme::c muted]
check "rows inside the branch read muted" $inks \
    [list $user $muted $muted $muted $muted $user]
set ToolList [dict get [set ${NS}::BandDesc] tools list]
check "a tool call inside the branch reads muted" \
    [$ToolList itemcget 0 -foreground] $muted

# ---- 3. clicks open and close, and inner state survives ----------------------
click_header 0
check "a click opens the outer branch" \
    [list [vischars "zebra-outer"] [vischars "outer second reply"]] {11 18}
check "the inner branch stays folded" [vischars "zebra-inner"] 0
check "the opened branch carries the rail" \
    [expr {"rail1" in [$Text tag names [$Text search -elide -- "zebra-outer" 1.0 end]]}] 1
click_header 1
check "a click opens the inner branch" [vischars "zebra-inner"] 11
check "the inner branch carries the deeper rail" \
    [expr {"rail2" in [$Text tag names [$Text search -elide -- "zebra-inner" 1.0 end]]}] 1
click_header 0
check "folding the outer hides the open inner" [vischars "zebra-inner"] 0
click_header 0
check "reopening the outer finds the inner as it was left" [vischars "zebra-inner"] 11
check "a header click leaves the turn detail hidden" [vischars "/tmp/a2.txt"] 0

# ---- 4. find opens what it lands in -----------------------------------------
$V show $JP 0 {}
update idletasks
check "a fresh show folds every branch again" [vischars "zebra-inner"] 0
$V collect_matches "zebra-inner"
$V find_next
update idletasks
check "a find step two branches deep opens both" \
    [list [vischars "zebra-inner"] [vischars "abandoned inner prompt\""]] {11 23}
check "a ROLLED BACK line is no match" \
    [llength [$V collect "ROLLED BACK" 1]] 0
$V find_hide

# ---- 5. copy skips what the reader cannot see -------------------------------
$V show $JP 0 {}
update idletasks
update
set hdr [lindex [$Text tag ranges grouphdr] 0]
$Text see $hdr
update idletasks
lassign [$Text bbox $hdr] x y
$V copy_motion [expr {$x + 2}] [expr {$y + 2}]
check "no copy button on a ROLLED BACK line" [set ${NS}::CopyLine] ""
check "no copy target beside the folded branch" \
    [$V copy_line_at [$Text index "$div linestart"]] ""
set oidx [$Text search -- "Opening answer" 1.0 end]
set oline [$V line_at $oidx]
check "the message before the fork copies up to the ROLLED BACK line" \
    [$Text compare [$V next_body_index [dict get [set ${NS}::LineMap] $oline]] == $hdr] 1

# ---- 6. a rewind met by the live tail ----------------------------------------
# The file holds two answered turns; then the user rewinds past the second,
# runs a command, and asks again. The tail sees the new prompt descend from the
# first answer, not the second turn, and re-renders: the second turn folds.
set JL [file join $TMP live.jsonl]
write_lines $JL [list \
    [L P q1 ""  0900 "first live question"] \
    [L A b1 q1  0901 "first live answer"] \
    [L P q2 b1  0902 "second live question"] \
    [L A b2 q2  0903 "second live answer"]]
$V show $JL 0 {}
update idletasks
$V follow
update idletasks
check "before the rewind nothing is folded" [headers] {}
write_lines $JL [list \
    [L C k1 b1  0905 ""] \
    [L P q3 k1  0906 "third live question"] \
    [L A b3 q3  0907 "third live answer"]] a
$V append_new
update idletasks
update
check "the rewind folds the abandoned turn" [headers] \
    [list "▸ ROLLED BACK  1 turn · 09:02–09:03 · \"second live question\""]
check "the abandoned answer is folded" [vischars "second live answer"] 0
check "the new turn reads" [vischars "third live answer"] 17
check "a reader held at the tail stays there" \
    [expr {[lindex [$Text yview] 1] >= 0.999}] 1

# A growing turn with no rewind appends as before.
write_lines $JL [list [L A b4 b3 0908 "fourth live words"]] a
$V append_new
update idletasks
check "plain growth still appends" [vischars "fourth live words"] 17

# A prompt typed while that turn runs: the queue's bookkeeping draws nothing,
# and the prompt the model received reads once, USER, inside the running turn.
proc nranges {tag} { llength [$::Text tag ranges $tag] }
set before [list [nranges lbl-system] [nranges turnhdr] [expr {[nranges lbl-user] + 2}]]
write_lines $JL [list \
    {{"type":"queue-operation","operation":"enqueue","content":"queued words"}} \
    {{"type":"queue-operation","operation":"remove","reason":"absorbed_mid_turn"}} \
    {{"type":"attachment","uuid":"qa","parentUuid":"b4","timestamp":"2026-10-17T09:09:00.000Z","attachment":{"type":"queued_command","prompt":"queued words"}}}] a
$V append_new
update idletasks
check "a queued prompt reads as USER within the running turn" \
    [list [nranges lbl-system] [nranges turnhdr] [nranges lbl-user] \
        [llength [$Text search -all -elide -- "queued words" 1.0 end]] [vischars "queued words"]] \
    [concat $before 1 12]

check "no background errors" $::bgerr {}
::questlog::path::_real_file delete -force $TMP
if {$fails} { puts "FAILED: $fails" } else { puts "PASS" }
exit $fails
