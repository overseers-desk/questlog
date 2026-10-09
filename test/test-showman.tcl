#!/usr/bin/env wish9.0
# The showman module: the display base class over streamdoc that renders
# a Claude Code transcript as foldable, searchable turns, plus the live path
# (a growing turn streamed into in place) questlog's viewer never had.
#
# Drives a bare ::showman::Showman over hand-written fixture records
# (no session file, no app chrome): turn rendering, tool-detail fold and
# unfold, find reaching into a folded region and revealing the hit, and the
# live turn - open, streamed in-place writes, the working marker, finished
# records appended mid-turn, close.
#
# Runs under wish (it builds a Tk view); run-audit routes it to wish9.0 on
# the private Xvfb. Standalone: xvfb-run -a wish9.0 test/test-showman.tcl

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require showman

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

# ---- fixture records --------------------------------------------------------
# Two finished turns. Turn 0 (10:00) carries thinking + prose + one tool call
# and its result (the "needle" tokens live only in hidden detail). Turn 1
# (10:05) is prose-only: no detail, so no stub.
set LINES {
    {{"type":"user","promptSource":"typed","timestamp":"2026-07-20T10:00:00Z","message":{"role":"user","content":"First question about frobnication"}}}
    {{"type":"assistant","timestamp":"2026-07-20T10:00:05Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"reason about frobnication","signature":"s1"},{"type":"text","text":"You frobnicate it gently."},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/tmp/needle-alpha.txt"}}]}}}
    {{"type":"user","timestamp":"2026-07-20T10:00:07Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"needle-beta secret contents"}]}}}
    {{"type":"assistant","timestamp":"2026-07-20T10:00:10Z","message":{"role":"assistant","content":[{"type":"text","text":"Final answer one."}]}}}
    {{"type":"user","promptSource":"typed","timestamp":"2026-07-20T10:05:00Z","message":{"role":"user","content":"Second question, prose only"}}}
    {{"type":"assistant","timestamp":"2026-07-20T10:05:05Z","message":{"role":"assistant","content":[{"type":"text","text":"Plain prose reply."}]}}}
}
set RECS [list]
foreach line $LINES {
    set rec [::logman::parse_line [string trim $line]]
    if {$rec eq ""} { error "fixture line failed to parse: $line" }
    lappend RECS $rec
}

# ---- build the view and render the fixture ----------------------------------
ttk::frame .sv
set V [::showman::Showman new .sv]
pack .sv -fill both -expand 1
$V render_records $RECS
update idletasks
update

set Text [$V textwidget]
set NS [info object namespace $V]

# Visible characters of a term's first occurrence: 0 while elided, -1 absent.
proc vischars {term} {
    set m [$::Text search -elide -- $term 1.0 end]
    if {$m eq ""} { return -1 }
    return [$::Text count -displaychars $m "$m + [string length $term]c"]
}

# A region's stub line text ("" while no summary line stands).
proc stubline {n} {
    set s [dict get [$::V region_info $n] summary]
    if {$s eq ""} { return "" }
    return [$::Text get $s "$s lineend"]
}

# ---- 1. turns render --------------------------------------------------------
check "two turns registered" [$V region_count] 2
check "last turn open (a transcript can always grow)" [$V live] 1
set hdr0 [dict get [$V region_info 0] start]
check "header line carries the open fold glyph" [$Text get $hdr0] "▾"
check "header line is a turnhdr click zone" \
    [expr {"turnhdr" in [$Text tag names $hdr0]}] 1
check "prompt prose visible" [expr {[vischars "about frobnication"] > 0}] 1
check "assistant prose visible" [expr {[vischars "frobnicate it gently"] > 0}] 1

# ---- 2. tool detail hidden behind the stub ----------------------------------
check "tool_use line hidden by default" [vischars "needle-alpha"] 0
check "thinking hidden by default" [vischars "reason about frobnication"] 0
check "tool_result record hidden by default" [vischars "needle-beta"] 0
check "turn 0 stub counts its detail" [stubline 0] \
    "▸ · 1 tool call · 1 thinking"
check "prose-only turn takes no stub" [stubline 1] ""
check "stub words are chrome, not matches" \
    [llength [$V collect_matches "tool call"]] 0

# ---- 3. detail unfolds and refolds ------------------------------------------
$V detail_show 0
update idletasks
check "detail_show reveals the tool line" [expr {[vischars "needle-alpha"] > 0}] 1
check "detail_show flips the stub glyph" [string index [stubline 0] 0] "▾"
$V detail_hide 0
update idletasks
check "detail_hide re-hides the tool line" [vischars "needle-alpha"] 0

# ---- 4. a turn folds to its header ------------------------------------------
$V fold 0
update idletasks
set body0 [$Text index "$hdr0 +1line linestart"]
set end0 [dict get [$V region_info 0] end]
check "folded turn body displays nothing" \
    [$Text count -displaylines $body0 $end0] 0
check "folded glyph" [$Text get $hdr0] "▸"
check "the header survives as the ToC line" \
    [expr {[$Text count -displaychars $hdr0 "$hdr0 lineend"] > 0}] 1
$V unfold 0
update idletasks
check "unfold restores the prose" [expr {[vischars "frobnicate it gently"] > 0}] 1
check "unfold leaves detail hidden" [vischars "needle-alpha"] 0

# ---- 5. find reaches into a folded region and reveals the hit ---------------
$V fold 0
update idletasks
set ${NS}::FindVar "needle-beta"
$V find_next
update idletasks
check "find collected the hidden hit" \
    [llength [set ${NS}::FindMatches]] 1
check "readout reads 1 of 1" [set ${NS}::FindPos] "1 of 1"
set hit [lindex [set ${NS}::FindMatches] 0]
check "the hit carries the find highlight" \
    [expr {"find" in [$Text tag names $hit]}] 1
check "the jump unfolded the turn" [$V folded 0] 0
check "the jump spilled the detail to reach the hit" \
    [expr {[vischars "needle-beta"] > 0}] 1
check "the hit is laid out (bbox non-empty)" \
    [expr {[$Text bbox $hit] ne ""}] 1
set ${NS}::FindVar "no-such-token-xyzzy"
$V find_next
check "a fruitless search shows 0 of 0" [set ${NS}::FindPos] "0 of 0"
$V find_hide
check "find_hide blanks the readout" [set ${NS}::FindPos] ""
check "find_hide drops the highlight" [llength [$Text tag ranges find]] 0
$V detail_hide 0

# ---- 6. live turn: open, stream in place, working, append, close ------------
set n [$V live_open "Live question about ducks" "2026-07-20T10:10:00Z"]
update idletasks
check "live_open sealed the transcript's open turn" \
    [dict get [$V region_info 1] open] 0
check "live_open opened a fresh region" [$V live] $n
check "the live turn registered" [$V region_count] 3
check "the live prompt renders visible" \
    [expr {[vischars "Live question about ducks"] > 0}] 1
check "the live header is a turnhdr click zone" \
    [expr {"turnhdr" in [$Text tag names [dict get [$V region_info $n] start]]}] 1

$V live_working 1
update idletasks
check "working marker rides the stub line" [stubline $n] "▸ · working…"

$V live_write "Hello "
$V live_write "world, **bo"
$V live_write "ld** settles."
update idletasks
check "streamed chunks joined into one message" \
    [expr {[vischars "Hello world,"] > 0}] 1
check "the provisional tail was rewound, not duplicated" \
    [llength [$V collect_matches "Hello world"]] 1
check "markdown closing across chunks settled (no literal asterisks)" \
    [$Text search -elide -- "**" 1.0 end] ""
check "the streamed message carries the assistant label" \
    [expr {[vischars "ASSISTANT"] > 0}] 1
check "the working stub stayed the trailing content line" \
    [stubline $n] "▸ · working…"

# Finished records land inside the live turn as hidden detail; the stream
# message is finalized first, so the rewind cannot eat them.
set tooluse [::logman::parse_line {{"type":"assistant","timestamp":"2026-07-20T10:10:05Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t9","name":"Bash","input":{"command":"echo live-needle"}}]}}}]
check "append_records reports one record" [$V append_records [list $tooluse]] 1
update idletasks
check "the appended tool call is hidden detail" [vischars "live-needle"] 0
check "the stub recounts with the working marker" \
    [stubline $n] "▸ · 1 tool call · working…"
check "the streamed prose survived the append" \
    [expr {[vischars "Hello world,"] > 0}] 1

# A second streamed message after the appended record: a fresh label and
# savepoint, not a rewind into the finished text.
$V live_write "And the reply resumes."
update idletasks
check "a post-append write starts a fresh message" \
    [expr {[vischars "And the reply resumes."] > 0}] 1
check "the first message still stands" \
    [expr {[vischars "Hello world,"] > 0}] 1

$V live_working 0
$V live_close
update idletasks
check "live_close seals the region" [dict get [$V region_info $n] open] 0
check "no region stays open after live_close" [$V live] -1
check "the sealed stub drops the working marker" \
    [stubline $n] "▸ · 1 tool call"

# The closed live turn folds like any rendered one.
$V fold $n
update idletasks
set hdrn [dict get [$V region_info $n] start]
check "the closed live turn folds to its header" \
    [$Text count -displaylines [$Text index "$hdrn +1line linestart"] \
        [dict get [$V region_info $n] end]] 0
$V unfold $n

# A new live turn after a close opens cleanly.
set n2 [$V live_open "A second live prompt"]
check "a second live_open opens the next region" [$V live] $n2
check "the regions grew by one" [$V region_count] 4
$V live_close

# ---- 7. live_set: repaint frames replace, never double ----------------------
# A host streaming repaint frames repeats the message's whole text each
# flush; live_set replaces the provisional tail instead of appending it.
check "live_set with no open turn errors" \
    [catch {$V live_set 9 "orphan frame"}] 1
set n3 [$V live_open "A repaint-framed prompt" "2026-07-20T10:20:00Z"]
$V live_set 7 "Rep"
$V live_set 7 "Repaint gro"
$V live_set 7 "Repaint grows **who"
$V live_set 7 "Repaint grows **whole**."
update idletasks
check "growing frames render the text exactly once" \
    [llength [$V collect_matches "Repaint grows"]] 1
check "no frame's prefix survives as a duplicate" \
    [$Text search -elide -- "RepRepaint" 1.0 end] ""
check "markdown closing across frames settled (no literal asterisks)" \
    [$Text search -elide -- "**" 1.0 end] ""
check "the repaint message carries the assistant label" \
    [expr {[vischars "ASSISTANT"] > 0}] 1
$V live_set 7 "Repaint grows **whole**."
update idletasks
check "an identical frame repeated is a no-op" \
    [llength [$V collect_matches "Repaint grows"]] 1

# A finished record lands between messages: append_records finalizes the
# frame stream, and the next id's frames start a fresh message after it.
set tooluse2 [::logman::parse_line {{"type":"assistant","timestamp":"2026-07-20T10:20:05Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t10","name":"Bash","input":{"command":"echo set-needle"}}]}}}]
$V append_records [list $tooluse2]
$V live_set 8 "Second mess"
$V live_set 8 "Second message settles."
update idletasks
check "a fresh id's frames start their own message" \
    [expr {[vischars "Second message settles."] > 0}] 1
check "the first message survived the id change" \
    [llength [$V collect_matches "Repaint grows"]] 1
check "the appended record stayed hidden detail between them" \
    [vischars "set-needle"] 0
$V live_close
update idletasks
check "live_close seals the repaint turn" [dict get [$V region_info $n3] open] 0


# ---- drafts of one message render as one turn -------------------------------
# A message edited before the assistant answered leaves one record per draft.
# Only the settled draft gets a turn and a region; the earlier ones leave no
# text behind, and the survivor's payload carries how many it replaced.
ttk::frame .dv
set D [::showman::Showman new .dv]
pack .dv -fill both -expand 1
set DText [$D textwidget]
proc drafted {args} {
    set out [list]
    foreach j $args { lappend out [::logman::parse_line $j] }
    return $out
}
set REPLY {{"type":"assistant","timestamp":"2026-07-20T11:00:09Z","message":{"role":"assistant","content":[{"type":"text","text":"Answer to the settled draft."}]}}}
$D render_records [drafted \
    {{"type":"user","promptSource":"typed","timestamp":"2026-07-20T11:00:00Z","message":{"role":"user","content":"How do I frobn"}}} \
    {{"type":"user","promptSource":"typed","timestamp":"2026-07-20T11:00:04Z","message":{"role":"user","content":"How do I frobnicate a widget?"}}} \
    $REPLY]
update idletasks

check "three records with two drafts open one turn" [$D region_count] 1
check "the turn is labelled with the draft the user settled on" \
    [dict get [$D payload 0] label] "How do I frobnicate a widget?"
check "the superseded draft leaves no text in the view" \
    [$DText search -elide -- "How do I frobn?" 1.0 end] ""
check "the surviving turn counts the draft it replaced" \
    [dict get [$D payload 0] edits] 1

# The streamed tail cannot retract a rendered turn, so a trailing turn start is
# held back: it renders only once the file says what followed it. Here the
# successor is another draft, so the held record never becomes a turn of its own.
ttk::frame .av
set A2 [::showman::Showman new .av]
pack .av -fill both -expand 1
set AText [$A2 textwidget]
$A2 render_records [drafted $REPLY]
update idletasks
set before [$A2 region_count]
$A2 append_records [drafted \
    {{"type":"user","promptSource":"typed","timestamp":"2026-07-20T11:10:00Z","message":{"role":"user","content":"Held draft one"}}}]
update idletasks
check "a trailing turn start is not rendered on arrival" \
    [$A2 region_count] $before
$A2 append_records [drafted \
    {{"type":"user","promptSource":"typed","timestamp":"2026-07-20T11:10:06Z","message":{"role":"user","content":"Held draft two, settled"}}} \
    {{"type":"assistant","timestamp":"2026-07-20T11:10:09Z","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}}]
update idletasks
check "the held draft and its successor become one turn" \
    [$A2 region_count] [expr {$before + 1}]
check "that turn shows the settled draft" \
    [dict get [$A2 payload $before] label] "Held draft two, settled"
check "the held draft left no text behind" \
    [$AText search -elide -- "Held draft one" 1.0 end] ""

# A tick that brings nothing new releases the hold: the file has had a full
# interval to produce a successor and did not, so the message stands as typed.
ttk::frame .fv
set F [::showman::Showman new .fv]
pack .fv -fill both -expand 1
$F render_records [drafted $REPLY]
update idletasks
set before [$F region_count]
$F append_records [drafted \
    {{"type":"user","promptSource":"typed","timestamp":"2026-07-20T11:20:00Z","message":{"role":"user","content":"Last word"}}}]
$F append_records [list]
update idletasks
check "an empty tick releases the held turn start" \
    [$F region_count] [expr {$before + 1}]
check "the released turn shows no edits" [dict get [$F payload $before] edits] 0

# ---- Ctrl-F after the object is gone ---------------------------------------
# A host may destroy the object and keep its widgets (Conversation's destructor
# does). The toplevel's Ctrl-F must not call the dead object, and destroying an
# older view must leave a newer one's binding in place.
set BGERRS [list]
interp bgerror {} {apply {{msg opts} { lappend ::BGERRS $msg }}}
toplevel .ct
ttk::frame .ct.a
ttk::frame .ct.b
set CA [::showman::Showman new .ct.a]
pack .ct.a -fill both -expand 1
set CB [::showman::Showman new .ct.b]
$CA destroy
check "destroying an older view keeps the newer view's Ctrl-F" \
    [bind .ct <Control-f>] [list $CB find_show]
$CB destroy
check "the view's widgets outlive it" [winfo exists .ct.b] 1
check "destroying the view unbinds its Ctrl-F" [bind .ct <Control-f>] ""
update
focus -force .ct
update
event generate .ct <Control-f>
update
check "Ctrl-F on a dead view's toplevel raises no background error" $BGERRS {}
destroy .ct

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
