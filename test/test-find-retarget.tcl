#!/usr/bin/env wish9.0
# Ctrl-F on a term other than the search that filled the viewer retargets ALL
# three readers of the one match set, not just the find-bar readout (issue #51).
#
# The viewer's design is one match set with several readers: the head-strip
# count, the docked Matches band and the Ctrl-F overlay all report "where in
# this session" from the same collection. The bug: typing a different term into
# Ctrl-F recollected the shared set for stepping but left the band's rows and the
# head-strip count showing the old population. This drives a real Viewer over a
# synthetic session opened from a search, steps Ctrl-F on a second term, and
# asserts the band rows, the head-strip count and the find readout all move to
# the recollected set - then that closing the overlay reverts the two persistent
# readers to the opening search set.
#
# Runs under wish (it builds a Viewer, so it needs Tk); run-audit routes it to
# wish9.0 on the private Xvfb. Standalone: DISPLAY=:94 wish9.0 test-find-retarget.tcl

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
# Mirror the launcher's GUI source order for the subset the Viewer needs.
foreach f {config.tcl lib/debug.tcl lib/path.tcl lib/jsonl.tcl lib/match.tcl \
           lib/cost.tcl ui/theme.tcl ui/viewer.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

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

# ---- synthetic session: two content turns carrying the two probe terms --------
# ALPHA is the opening search term (2 occurrences); BETA is the different Ctrl-F
# term (3 occurrences). Distinct counts let each reader's population be told
# apart. The words sit in ordinary body text, not on stub/header/chip chrome, so
# collect_matches and index_matches both keep them.
set tmpbase [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set TMP [file join $tmpbase ql-find-retarget-[pid]]
::questlog::path::_real_file mkdir $TMP
set JP [file join $TMP session.jsonl]
set fh [open $JP w]
fconfigure $fh -encoding utf-8
puts $fh {{"type":"user","cwd":"/tmp/proj","timestamp":"2026-07-11T10:00:00Z","message":{"role":"user","content":"alpha is here and beta"}}}
puts $fh {{"type":"assistant","timestamp":"2026-07-11T10:00:05Z","message":{"role":"assistant","model":"claude-3-5-sonnet-20241022","content":"beta then alpha and beta again","usage":{"input_tokens":10,"output_tokens":5}}}}
puts $fh {{"type":"user","cwd":"/tmp/proj","timestamp":"2026-07-11T10:00:09Z","message":{"role":"user","content":"thanks"}}}
close $fh

# ---- build a real Viewer and open the session from a search for "alpha" -------
set V [::questlog::ui::Viewer new .v]
pack .v -fill both -expand 1
$V show $JP 0 {terms alpha nocase 1}
update idletasks
update

set NS [info object namespace $V]
proc iv {name} { return [set [set ::NS]::$name] }
set MatchList [iv MatchList]
proc bandcount {} { return [dict get [iv BandDesc] matches count] }
proc headstrip {} { return [[dict get [iv BandDesc] matches btn] cget -text] }

# 1. Opened from "alpha": all three readers report the 2-occurrence alpha set.
check "alpha: find set is 2"        [llength [iv FindMatches]]   2
check "alpha: band rows are the set" [iv BandMatchSet]           [iv FindMatches]
check "alpha: band listbox has 2"    [$MatchList size]           2
check "alpha: head-strip count"      [bandcount]                 "2 matches"

# ---- Ctrl-F a different term ("beta"), then Next ------------------------------
set ${NS}::FindVar beta
$V find_next
update idletasks

# 2. The recollected 3-occurrence beta set now drives ALL three readers, not
#    only the find-bar readout: the band rows and the head-strip count moved too.
check "beta: find set is 3"          [llength [iv FindMatches]]  3
check "beta: band rows retargeted"   [iv BandMatchSet]           [iv FindMatches]
check "beta: band listbox has 3"     [$MatchList size]           3
check "beta: head-strip count"       [bandcount]                 "3 matches"
check "beta: head-strip glyph+count" [headstrip]                 "▴ 3 matches"
check "beta: find readout"           [iv FindPos]                "1 of 3"
# The band's exact-set gate now passes (its rows ARE the live set), so stepping
# moves the band highlight to the hit.
check "beta: band highlight on hit 0" [$MatchList curselection]  0

# 3. A second Next steps within the retargeted set, all readers agreeing.
$V find_next
update idletasks
check "beta: find cursor advanced"    [iv FindCur]               1
check "beta: readout advanced"        [iv FindPos]               "2 of 3"
check "beta: highlight tracks"        [$MatchList curselection]  1

# ---- close the overlay: revert the persistent readers to the opening search ---
# The transient Ctrl-F term is gone, so the band and head-strip count return to
# the session's own search set (alpha). The accepted costs of a retarget hold
# only while a different term is live.
$V find_hide
update idletasks
check "close: band reverts to alpha"  [$MatchList size]          2
check "close: head-strip reverts"     [bandcount]                "2 matches"
check "close: band rows are alpha set" [llength [iv BandMatchSet]] 2

# ---- clean up ----------------------------------------------------------------
::questlog::path::_real_file delete -force $TMP
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
