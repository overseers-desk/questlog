#!/usr/bin/env wish9.0
# GFM tables in the Viewer: tkdown paints each as an embedded grid, and the
# Viewer wires it into search, jump, copy and reload.
#
# This drives a real Viewer over a two-table synthetic session and asserts
# the Viewer's side: search finds table content (band and Ctrl-F), the band
# excerpt is the cell text, a jump spotlights the table in the theme's find
# colour, the message copy keeps the raw table source, and a reload leaves no
# orphaned table frames. The grid itself (wrap, fit, copy button, round trip)
# is tkdown's and its own suite covers it.
#
# Runs under wish (it builds a Viewer, so it needs Tk); run-audit routes it to
# wish9.0 on the private Xvfb. Standalone: DISPLAY=:95 wish9.0 test-viewer-tables.tcl

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
# Mirror the launcher's GUI source order for the subset the Viewer needs: config
# and the Tk-free libs it reads, the theme (named fonts + palette), then the
# class itself.
set ::questlog_config_only 1; source [file join $ROOT questlog]
foreach f {lib/debug.tcl lib/path.tcl lib/match.tcl \
           lib/cost.tcl ui/theme.tcl ui/reveal.tcl ui/viewer.tcl} {
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

# ---- synthetic session: two tables in one assistant turn -----------------------
set tmpbase [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set TMP [file join $tmpbase ql-table-test-[pid]]
# lib/path.tcl wraps `file` to refuse callers outside ::questlog::path::*; reach
# the unwrapped command for the sandbox dir under /tmp, as the other UI tests do.
::questlog::path::_real_file mkdir $TMP
set JP [file join $TMP session.jsonl]
set fh [open $JP w]
fconfigure $fh -encoding utf-8
# Table one: three columns with mixed alignment, a **bold** header span, the
# search token in a body cell, and an escaped \| whose round trip the copy
# test asserts. Table two: a cell long enough that it must wrap once its
# column shrinks to the pane. PLAINWORD sits in ordinary prose so a jump can
# land off-table and clear the spotlight.
puts $fh {{"type":"user","cwd":"/tmp/proj","timestamp":"2026-07-12T09:00:00Z","message":{"role":"user","content":"show me tables PLAINWORD"}}}
puts $fh {{"type":"assistant","timestamp":"2026-07-12T09:00:05Z","message":{"role":"assistant","model":"claude-3-5-sonnet-20241022","content":"Intro line.\n\n| Name | **Qty** | Price |\n| :--- | :---: | ---: |\n| alpha | TBLTOKEN mid | 9 |\n| pipe a \\| b | x | 1 |\n\nBetween tables.\n\n| Dimension | Detail |\n| --- | --- |\n| horizon | this is a very long sentence that must wrap across several display lines because its natural width is far beyond what a small reading pane can give one column |\n\nAfter text.","usage":{"input_tokens":10,"output_tokens":5}}}}
puts $fh {{"type":"user","cwd":"/tmp/proj","timestamp":"2026-07-12T09:00:09Z","message":{"role":"user","content":"thanks"}}}
close $fh

# ---- build a real Viewer and show the session ----------------------------------
set V [::questlog::ui::Viewer new .v]
pack .v -fill both -expand 1
$V show $JP 0 [dict create terms {TBLTOKEN} nocase 0]
update idletasks
update

set Text [$V textwidget]
set NS [info object namespace $V]

# 1. Two tables painted: two embedded windows and their window segments.
proc tblwins {} {
    lmap {key name idx} [$::Text dump -window 1.0 end] { set idx }
}
proc tblframes {} {
    lsort [lmap f [$::Text window names] { regsub {.*\.} $f {} }]
}
check "two table windows" [llength [tblwins]] 2
check "two td-tblwin segments" [llength [$Text tag ranges td-tblwin]] 4
foreach m [tblwins] {
    $Text see $m
    update idletasks
    update
}
set F1 $Text.tbl1
check "table 1 built" [winfo exists $F1] 1

# 4. The opening search found the table-only token: its match record is the
#    index of the table's window, and its band excerpt reads from the cell,
#    not the widget.
check "band search finds the table token" \
    [expr {[lsearch [set ${NS}::FindMatches] [lindex [tblwins] 0]] >= 0}] 1
set mi [lsearch [set ${NS}::FindMatches] [lindex [tblwins] 0]]
check "band excerpt is the cell text" \
    [expr {[string first "TBLTOKEN" [lindex [set ${NS}::MatchLabels] $mi]] >= 0}] 1

# 5. Jumping to the table match spotlights the whole table; a jump to a plain
#    index clears it.
set FIND  [::questlog::ui::theme::c find]
set FAINT [::questlog::ui::theme::c faint]
$V jump_to_match $mi
update idletasks
update
check "jump lights the table" [$F1 cget -background] $FIND
$V reveal 1.0
check "off-table jump clears the spotlight" [$F1 cget -background] $FAINT

# 6. Ctrl-F reaches table content: the token exists only in the payload, and
#    find_next lands on it (re-lighting the table).
set ${NS}::FindVar "tbltoken"
$V find_next
update idletasks
check "Ctrl-F finds the table-only token" \
    [expr {[lsearch [set ${NS}::FindMatches] [lindex [tblwins] 0]] >= 0}] 1
check "Ctrl-F jump lights the table" [$F1 cget -background] $FIND

# 8. The message copy still yields the raw markdown body, pipes intact.
set ${NS}::MenuTarget [dict create line 2]
$V menu_copy_message
check "message copy keeps the raw table source" \
    [expr {[string first "| Name | **Qty** | Price |" [clipboard get]] >= 0}] 1

# 9. Reload: the previous document's tables go with its text, frames and
#    all, and only the new document's tables stand.
$V show $JP 0 {}
update idletasks
update
foreach m [tblwins] {
    $Text see $m
    update idletasks
    update
}
check "table frames do not accumulate" [tblframes] {tbl3 tbl4}
check "td-tblwin segments do not accumulate" [llength [$Text tag ranges td-tblwin]] 4
set stale 0
foreach w [winfo children $Text] {
    if {[regexp {\.(tbl\d+)$} $w -> n] && $n ni [tblframes]} { incr stale }
}
check "no orphaned table frames" $stale 0

# ---- clean up ------------------------------------------------------------------
::questlog::path::_real_file delete -force $TMP
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
