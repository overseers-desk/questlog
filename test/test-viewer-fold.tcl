#!/usr/bin/env wish9.0
# Turn folding and default-hidden detail in the session viewer.
#
# The viewer models the transcript in turns (the double-ESC rollback notion:
# one typed prompt and everything until the next), each foldable to its header
# line, with tool/thinking/tool-result detail hidden by default behind a stub
# line. This drives a real Viewer over a synthetic multi-turn session - typed
# prompts, a queued prompt inside a running turn, tool_use/thinking/tool_result
# blocks, an idle-gap section split, and preamble records before the first
# turn - and asserts the registry, the elide behaviour, search reveal, the
# copy filter, and streamed-append continuity (stub recount, fold held during
# a stream, a new typed prompt closing the open turn).
#
# Runs under wish (it builds a Viewer, so it needs Tk); run-audit routes it to
# wish9.0 on the private Xvfb. Standalone: DISPLAY=:95 wish9.0 test-viewer-fold.tcl

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
set ::questlog_config_only 1; source [file join $ROOT questlog]
foreach f {lib/debug.tcl lib/path.tcl lib/match.tcl \
           lib/cost.tcl ui/theme.tcl ui/viewer.tcl} {
    source [file join $ROOT $f]
}
# The match procs read display caps injected once per interp (the launcher
# does the same); the tool timeline formats tool_use blocks through them.
::questlog::match::set_caps [dict create \
    content_cap     [::questlog::config::get content_cap] \
    snippet_lead    [::questlog::config::get snippet_lead] \
    snippet_trail   [::questlog::config::get snippet_trail] \
    tool_param_cap  [::questlog::config::get tool_param_cap] \
    tool_render_cap [::questlog::config::get tool_render_cap]]
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

# ---- synthetic session ------------------------------------------------------
# Three turns. Turn 1 (10:00) carries thinking + prose + one tool call and its
# result (the "needle" tokens live only in hidden detail). Turn 2 (12:30,
# 2.5 h later: an idle-gap divider and fresh section header land between the
# turns) has a queued prompt injected mid-turn and a tool-only assistant
# record. Turn 3 is prose-only: no detail, so no stub. One isMeta preamble
# record precedes everything.
set tmpbase [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set TMP [file join $tmpbase ql-fold-test-[pid]]
::questlog::path::_real_file mkdir $TMP
set JP [file join $TMP session.jsonl]
set fh [open $JP w]
fconfigure $fh -encoding utf-8
puts $fh {{"type":"user","isMeta":true,"cwd":"/tmp/proj","timestamp":"2026-07-11T10:00:00Z","message":{"role":"user","content":"Caveat: preamble record before the first turn"}}}
puts $fh {{"type":"user","promptSource":"typed","cwd":"/tmp/proj","timestamp":"2026-07-11T10:00:05Z","message":{"role":"user","content":"First question about frobnication"}}}
puts $fh {{"type":"assistant","timestamp":"2026-07-11T10:00:10Z","message":{"role":"assistant","model":"claude-x","content":[{"type":"thinking","thinking":"let me reason about frobnication","signature":"s1"},{"type":"text","text":"You frobnicate it gently."},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/tmp/needle-alpha.txt"}}],"usage":{"input_tokens":10,"output_tokens":5}}}}
puts $fh {{"type":"user","timestamp":"2026-07-11T10:00:12Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"needle-beta secret contents"}]}}}
puts $fh {{"type":"assistant","timestamp":"2026-07-11T10:00:15Z","message":{"role":"assistant","content":[{"type":"text","text":"Final answer one."}]}}}
puts $fh {{"type":"user","promptSource":"typed","timestamp":"2026-07-11T12:30:00Z","message":{"role":"user","content":"Second question about sigils"}}}
puts $fh {{"type":"user","promptSource":"queued","timestamp":"2026-07-11T12:30:05Z","message":{"role":"user","content":"queued extra request"}}}
puts $fh {{"type":"assistant","timestamp":"2026-07-11T12:30:10Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"grep -r sigil /tmp"}},{"type":"tool_use","id":"t3","name":"Grep","input":{"pattern":"sigil"}},{"type":"thinking","thinking":"thinking two here","signature":"s2"}]}}}
puts $fh {{"type":"user","timestamp":"2026-07-11T12:30:12Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"grep found sigil-result here"}]}}}
puts $fh {{"type":"user","promptSource":"typed","timestamp":"2026-07-11T12:40:00Z","message":{"role":"user","content":"Third question, prose only"}}}
puts $fh {{"type":"assistant","timestamp":"2026-07-11T12:40:05Z","message":{"role":"assistant","content":[{"type":"text","text":"Plain prose reply, no details."}]}}}
close $fh

# ---- build a real Viewer and show the session --------------------------------
set V [::questlog::ui::Viewer new .v]
pack .v -fill both -expand 1
$V show $JP 0 {}
update idletasks
update

set Text [$V textwidget]
set NS [info object namespace $V]
proc turn {n} { lindex [set ${::NS}::Turns] $n }

# Visible characters of a term's first (only) occurrence: 0 while elided.
proc vischars {term} {
    set m [$::Text search -elide -- $term 1.0 end]
    if {$m eq ""} { return -1 }
    return [$::Text count -displaychars $m "$m + [string length $term]c"]
}

# A turn's fold-range end for measuring: the sealed end, or for the open turn
# the live content end (before the endhint). The engine folds an open region
# to its own end mark, which sits at the content end whenever no hint stands;
# a hint folded away with the open turn reappears on expand (accepted, the
# hint never coexists with a streamed append).
proc turnend {n} {
    set e [dict get [turn $n] end]
    if {$e ne ""} { return $e }
    set ce [$::V content_end]
    if {$ce eq "end"} { return [$::Text index "end-1l linestart"] }
    return [$::Text index "$ce linestart"]
}

# ---- 1. registry -------------------------------------------------------------
check "three turns registered (queued prompt opened none)" \
    [llength [set ${NS}::Turns]] 3
check "last turn open" [set ${NS}::CurTurn] 2
check "turn 0 ends where it closed" [expr {[dict get [turn 0] end] ne ""}] 1
check "open turn has no end yet" [dict get [turn 2] end] ""
check "turn 0 heads at the typed record (preamble skipped)" \
    [dict get [turn 0] line] 2
check "header line carries the open fold glyph" \
    [$Text get [dict get [turn 0] hdr]] "▾"
check "turnhdr spans all three headers" \
    [expr {[llength [$Text tag ranges turnhdr]] / 2}] 3
set caveat [$Text search -elide "Caveat:" 1.0 end]
check "preamble belongs to no turn" [$V turn_at $caveat] -1
# The 2.5 h silence between turns 0 and 1 draws the idle-gap divider, and it
# lands between the sealed end and the next header: turn chrome, owned by
# neither side (the fixture's gap was previously set up but never asserted).
set gapidx [$Text search -elide " later ───" 1.0 end]
check "idle-gap divider rendered" [expr {$gapidx ne ""}] 1
check "divider sits between the turns" \
    [expr {[$Text compare $gapidx >= [dict get [turn 0] end]] \
        && [$Text compare $gapidx < [dict get [turn 1] hdr]]}] 1

# ---- 2. detail hidden by default, prose visible -------------------------------
check "prose visible" [expr {[vischars "frobnicate it gently"] > 0}] 1
check "queued prompt visible inside turn 1" \
    [expr {[vischars "queued extra request"] > 0}] 1
check "queued prompt sits in turn 1" \
    [$V turn_at [$Text search -elide "queued extra" 1.0 end]] 1
check "tool_use line hidden" [vischars "needle-alpha"] 0
check "thinking hidden" [vischars "reason about frobnication"] 0
check "tool_result record hidden" [vischars "needle-beta"] 0

# ---- 3. stub lines -------------------------------------------------------------
check "turn 0 stub counts its detail" \
    [$Text get [dict get [turn 0] stub] "[dict get [turn 0] stub] lineend"] \
    "▸ · 1 tool call · 1 thinking"
check "turn 1 stub counts its detail" \
    [$Text get [dict get [turn 1] stub] "[dict get [turn 1] stub] lineend"] \
    "▸ · 2 tool calls · 1 thinking"
check "prose-only turn takes no stub" [dict get [turn 2] stub] ""
# The stub's words are chrome: a search for them must not index - on either
# collector (the index_matches twin was previously unexercised).
check "stub words are not matches" [llength [$V collect_matches "tool call"]] 0
$V index_matches [dict create terms [list "tool call"] nocase 0]
check "stub words do not index either" [llength [set ${NS}::FindMatches]] 0
# Both collectors and both case branches reach hidden detail (-elide on every
# search site; the Ctrl-F path and the nocase branch were unexercised).
check "the find path reaches hidden detail" \
    [llength [$V collect_matches "needle-beta"]] 1
$V index_matches [dict create terms [list NEEDLE-BETA] nocase 1]
check "a nocase query reaches hidden detail" \
    [llength [set ${NS}::FindMatches]] 1

# ---- 4. hidden hit found and revealed by the jump ------------------------------
$V index_matches [dict create terms [list needle-beta] nocase 0]
check "hidden hit indexed" [llength [set ${NS}::FindMatches]] 1
set hit [lindex [set ${NS}::FindMatches] 0]
check "hit invisible before the jump" \
    [$Text count -displaychars $hit "$hit + 11c"] 0
$V jump_to_match 0
update idletasks
check "jump reveals the detail" \
    [$Text count -displaychars $hit "$hit + 11c"] 11
check "reveal flips the stub glyph" \
    [$Text get [dict get [turn 0] stub]] "▾"
check "revealed hit is laid out (bbox non-empty)" \
    [expr {[$Text bbox $hit] ne ""}] 1
# Only the jumped turn spilled its detail.
check "other turns stay hidden" [vischars "sigil-result"] 0
$V details_hide 0

# ---- 5. copy filter ------------------------------------------------------------
$Text tag add sel [dict get [turn 1] hdr] [dict get [turn 1] end]
clipboard clear
clipboard append "sentinel-before"
event generate $Text <<Copy>>
set clip [clipboard get]
$Text tag remove sel 1.0 end
check "copy keeps the visible prompt" \
    [string match "*Second question about sigils*" $clip] 1
check "copy keeps the visible stub" [string match "*2 tool calls*" $clip] 1
check "copy drops hidden tool lines" [string match "*sigil*Grep*" $clip] 0
check "copy drops the hidden result" [string match "*sigil-result*" $clip] 0

# ---- 6. fold_all: the table of contents ----------------------------------------
$V fold_all
update idletasks
foreach n {0 1 2} {
    check "turn $n body folds to nothing" \
        [$Text count -displaylines [dict get [turn $n] body] [turnend $n]] 0
    check "turn $n glyph folded" [$Text get [dict get [turn $n] hdr]] "▸"
    # The header itself must survive as the ToC line: a fold range that
    # started one line early would swallow it and stay green here otherwise.
    check "turn $n header stays a visible ToC line" \
        [expr {[$Text count -displaychars [dict get [turn $n] hdr] \
            "[dict get [turn $n] hdr] lineend"] > 0}] 1
}
check "preamble survives fold_all" \
    [$Text count -displaylines $caveat "$caveat +1line linestart"] 1
$V expand_all
update idletasks
check "expand_all reopens the glyph" [$Text get [dict get [turn 0] hdr]] "▾"
check "expand_all leaves detail hidden (refold re-hid it)" \
    [vischars "needle-beta"] 0
check "prose visible again" [expr {[vischars "frobnicate it gently"] > 0}] 1

# ---- 7. streamed append into the open turn -------------------------------------
set fh [open $JP a]
fconfigure $fh -encoding utf-8
puts $fh {{"type":"assistant","timestamp":"2026-07-11T12:41:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t4","name":"Read","input":{"file_path":"/tmp/stream-one.txt"}}]}}}
close $fh
$V append_new
update idletasks
check "still three turns after mid-turn append" [llength [set ${NS}::Turns]] 3
check "open turn grew a stub with the new count" \
    [$Text get [dict get [turn 2] stub] "[dict get [turn 2] stub] lineend"] \
    "▸ · 1 tool call"
check "streamed tool line hidden by default" [vischars "stream-one"] 0

# ---- 8. fold-during-stream ------------------------------------------------------
$V turn_fold 2
set fh [open $JP a]
fconfigure $fh -encoding utf-8
puts $fh {{"type":"assistant","timestamp":"2026-07-11T12:42:00Z","message":{"role":"assistant","content":[{"type":"text","text":"streamed prose while folded"},{"type":"tool_use","id":"t5","name":"Read","input":{"file_path":"/tmp/stream-two.txt"}}]}}}
close $fh
$V append_new
update idletasks
check "fresh prose lands inside the fold (invisible)" \
    [vischars "streamed prose while folded"] 0
check "stub recounts under the fold" \
    [$Text get [dict get [turn 2] stub] "[dict get [turn 2] stub] lineend"] \
    "▸ · 2 tool calls"
check "folded turn body still displays nothing" \
    [$Text count -displaylines [dict get [turn 2] body] [turnend 2]] 0

# ---- 9. a new typed prompt closes the open turn ---------------------------------
set fh [open $JP a]
fconfigure $fh -encoding utf-8
puts $fh {{"type":"user","promptSource":"typed","timestamp":"2026-07-11T12:50:00Z","message":{"role":"user","content":"Fourth question arrives"}}}
puts $fh {{"type":"assistant","timestamp":"2026-07-11T12:50:05Z","message":{"role":"assistant","content":[{"type":"text","text":"Fourth reply."}]}}}
close $fh
$V append_new
update idletasks
check "the typed prompt opened turn 3" [llength [set ${NS}::Turns]] 4
check "turn 3 is the open turn" [set ${NS}::CurTurn] 3
check "turn 2 sealed" [expr {[dict get [turn 2] end] ne ""}] 1
check "turn 2 held its fold across the close" \
    [$Text count -displaylines [dict get [turn 2] body] [dict get [turn 2] end]] 0
check "new turn renders visible" \
    [expr {[vischars "Fourth question arrives"] > 0}] 1

# ---- Turns index tab + fold-all affordances -------------------------------------
# The sections above left the fold and detail state churned (turns folded and
# refolded, a turn streamed in mid-fold); a fresh show resets that to a known
# baseline before the Turns-tab assertions. show refills the band's per-tab
# listboxes (index_turns among them), so their rows are current afterward.
$V show $JP 0 {}
update idletasks
update
set TurnLB [dict get [set ${NS}::BandDesc] turns list]
set ToolLB [dict get [set ${NS}::BandDesc] tools list]

# ---- 10. the Turns tab is a jump list over the registry ------------------------
check "turns listbox row count equals the registry after show" \
    [$TurnLB size] [llength [set ${NS}::Turns]]
check "a turn row reads its 1-based number, stamp and the prompt's first line" \
    [$TurnLB get 0] \
    "1 · [$V tool_time [dict get [turn 0] ts]] · [dict get [turn 0] label]"
check "turn rows carry 1-based numbers that increment down the list" \
    [$TurnLB get 1] \
    "2 · [$V tool_time [dict get [turn 1] ts]] · [dict get [turn 1] label]"

# ---- 11. a Turns-tab jump scrolls the view to the target header ------------------
# The old bbox-only check was vacuous: folded, the whole ToC fits the viewport
# and every header has a bbox no matter what the jump does. Shrink the viewport
# below the expanded document's height, park the view at the top, and demand
# the row select actually moves it.
set oldh [$Text cget -height]
$Text configure -height 8
$V expand_all
update idletasks
$Text yview moveto 0
update idletasks
set last [expr {[llength [set ${NS}::Turns]] - 1}]
$TurnLB selection clear 0 end
$TurnLB selection set $last
$V turn_list_select
update idletasks
check "the jump moves the view to the last header" \
    [expr {[lindex [$Text yview] 0] > 0}] 1
check "the last header is on screen after the jump" \
    [expr {[$Text bbox [dict get [turn $last] hdr]] ne ""}] 1
$Text configure -height $oldh
update idletasks

# ---- 12. index_turns re-run (as resume_finish does) tracks a grown registry ----
# A new typed prompt streamed in opens a fresh turn; resume_finish re-runs
# index_turns to catch the listbox up, and the refill must show the grown count.
set before [llength [set ${NS}::Turns]]
set fh [open $JP a]
fconfigure $fh -encoding utf-8
puts $fh {{"type":"user","promptSource":"typed","timestamp":"2026-07-11T13:00:00Z","message":{"role":"user","content":"Fifth question after the reset"}}}
puts $fh {{"type":"assistant","timestamp":"2026-07-11T13:00:05Z","message":{"role":"assistant","content":[{"type":"text","text":"Fifth reply."}]}}}
close $fh
$V append_new
$V index_turns
update idletasks
check "append_new grew the registry by one turn" \
    [llength [set ${NS}::Turns]] [expr {$before + 1}]
check "index_turns shows the grown count" \
    [$TurnLB size] [llength [set ${NS}::Turns]]

# ---- 13. a Tools-tab jump opens the turn's detail to reach the call -------------
# A tool_use renders after its record's visible label, so a plain reveal lands
# on the label and leaves the call elided; the Tools tab is the caller that
# asked for the hidden line, so its jump also spills the turn's detail. Row 0 is
# turn 0's Read(/tmp/needle-alpha.txt) call (document order).
check "the target tool line is hidden by default" [vischars "needle-alpha"] 0
$ToolLB selection clear 0 end
$ToolLB selection set 0
$V tool_list_select
update idletasks
check "the Tools jump reveals the tool_use line" \
    [expr {[vischars "needle-alpha"] > 0}] 1

# ---- hover copy button -----------------------------------------------------------
# A shared ⧉ button rides the top-right of the user/assistant message under the
# pointer, copying that message's whole body (Bodies, unfiltered by fold state) -
# the discoverable twin of the right-click "Copy message". Synthetic <Motion> is
# flaky under Xvfb, so drive the placement handler (copy_motion) directly at real
# on-screen coordinates taken from each line's bbox. A fresh show resets the
# fold/detail churn the sections above left behind.
$V show $JP 0 {}
update idletasks
update
set CopyBtn [set ${NS}::CopyBtn]

# Drive copy_motion at the on-screen position of a text index; 0 when the index
# is off screen (no bbox), so a genuine hover is told from a miss.
proc hover_at {idx} {
    set bb [$::Text bbox $idx]
    if {$bb eq ""} { return 0 }
    lassign $bb bx by
    $::V copy_motion [expr {$bx + 2}] [expr {$by + 2}]
    return 1
}

# ---- 14. the button places over an assistant message ----------------------------
set aidx [$Text search -elide "Final answer one." 1.0 [$V content_end]]
$V copy_hide
$Text see $aidx
update idletasks
check "an assistant line is on screen to hover" [hover_at $aidx] 1
check "button placed over the assistant message" \
    [expr {[place info $CopyBtn] ne ""}] 1
check "cached line is the assistant message under the pointer" \
    [set ${NS}::CopyLine] [$V line_at $aidx]
set aln [lindex [split [$Text index $aidx] .] 0]
check "the hovered line sits inside the cached span" \
    [expr {$aln >= [set ${NS}::CopyFirst] && $aln < [set ${NS}::CopyLast]}] 1

# ---- 15. the button copies the message body, then acknowledges with ✓ -----------
clipboard clear
clipboard append "sentinel-before-copy"
$CopyBtn invoke
check "copy button lifts the whole assistant body (Bodies, unfiltered)" \
    [clipboard get] [dict get [set ${NS}::Bodies] [set ${NS}::CopyLine]]
check "the button flips to a check on copy" [$CopyBtn cget -text] "✓"
set ::c6fb 0
after 900 {set ::c6fb 1}
vwait ::c6fb
check "the check restores to the glyph" [$CopyBtn cget -text] "⧉"
# The "unfiltered" half of the contract, proven on a record that HAS hidden
# detail (the prose-only record above cannot tell filtered from unfiltered):
# the clipboard must carry the elided tool call.
set didx [$Text search -elide "frobnicate it gently" 1.0 [$V content_end]]
$V copy_hide
$Text see $didx
update idletasks
check "the detailed assistant line is on screen to hover" [hover_at $didx] 1
clipboard clear
$CopyBtn invoke
check "the copy carries the hidden tool call (Bodies, unfiltered)" \
    [string match "*needle-alpha*" [clipboard get]] 1

# ---- 16. no button over a tool result -------------------------------------------
# Reveal turn 0's detail so its tool_result is on screen, then hover it: a tool
# result is not prose a reader lifts, so the role gate hides the button.
$V details_show 0
set tridx [$Text search -elide "needle-beta" 1.0 [$V content_end]]
$Text see $tridx
update idletasks
$V copy_hide
check "the tool_result line is on screen once revealed" [hover_at $tridx] 1
check "no button over a tool result" [expr {[place info $CopyBtn] ne ""}] 0
$V details_hide 0

# ---- 17. no button over between-turn chrome -------------------------------------
# The top line is a section header (▼ date), not a message; line_at finds no
# bodied line at or above it, so the button hides.
$Text see 1.0
update idletasks
$V copy_hide
check "the top line is section-header chrome" \
    [expr {"section-header" in [$Text tag names 1.0]}] 1
check "the section header is on screen to hover" [hover_at 1.0] 1
check "no button over a section header" [expr {[place info $CopyBtn] ne ""}] 0

# ---- 18. no button over the end-of-session hint ---------------------------------
# The endhint is chrome below the content boundary (content_end); the copy button
# stops there like the searches do. Scroll it into view and hover it.
$Text see end
update idletasks
set eidx [$Text search "Continue with one more prompt" 1.0 end]
$V copy_hide
check "the endhint is on screen to hover" [hover_at $eidx] 1
check "no button over the endhint" [expr {[place info $CopyBtn] ne ""}] 0

# ---- 19. a wheel notch on the button scrolls the transcript ---------------------
# The placed button eats the wheel like any widget, so it is forwarded to $Text's
# yview. Park the pointer on the button (event generate on it) and confirm the
# transcript scrolls - the load-bearing behaviour of the whole hover design.
$Text see 1.0
update idletasks
$V copy_hide
hover_at $aidx
update idletasks
check "the button is placed for the wheel test" \
    [expr {[place info $CopyBtn] ne ""}] 1
set y0 [lindex [$Text yview] 0]
event generate $CopyBtn <MouseWheel> -delta -120
update idletasks
check "a wheel notch on the button scrolls the transcript down" \
    [expr {[lindex [$Text yview] 0] > $y0}] 1

# ---- 19b. layout churn invalidates the hover cache -------------------------------
# The cache is bare text-line numbers; append_new pops the stub (a mid-document
# line delete), show swaps sessions entirely, and fold_all/expand_all reshape
# the view - each must drop the button, or a parked pointer copies the message
# above the one it hovers (unless invalidated, the stale cache survives
# every 300 ms stream tick).
set aidx [$Text search -elide "Final answer one." 1.0 [$V content_end]]
$V copy_hide
$Text see $aidx
update idletasks
hover_at $aidx
check "button placed before the stream tick" [expr {[place info $CopyBtn] ne ""}] 1
set fh [open $JP a]
fconfigure $fh -encoding utf-8
puts $fh {{"type":"assistant","timestamp":"2026-07-11T13:01:00Z","message":{"role":"assistant","content":[{"type":"text","text":"Streamed while hovering."}]}}}
close $fh
$V append_new
check "a streamed append drops the placed button" [place info $CopyBtn] ""
hover_at $aidx
check "the next motion re-places it" [expr {[place info $CopyBtn] ne ""}] 1
$V fold_all
check "fold_all drops the placed button" [place info $CopyBtn] ""
$V expand_all
update idletasks
# A find jump scrolls without moving the pointer (Return on the find entry),
# the one churn path a listbox-select test cannot catch - the pointer is on
# the transcript, the button placed, and the see slides new text under both.
hover_at $aidx
check "button placed before the find jump" [expr {[place info $CopyBtn] ne ""}] 1
$V reveal_index [$Text search -elide "needle-beta" 1.0 [$V content_end]]
check "a reveal jump drops the placed button" [place info $CopyBtn] ""
$V details_hide 0
hover_at $aidx
$CopyBtn invoke
$V copy_hide
check "hiding cancels the pending check mark" [$CopyBtn cget -text] "⧉"
hover_at $aidx
$V show $JP 0 {}
update idletasks
check "show drops the placed button" [place info $CopyBtn] ""

# ---- 20. a truncated tail read by show is re-read once complete -----------------
# claude writes a record in pieces; show can catch the file mid-write. load must
# leave the unparseable newline-less tail uncounted so append_new re-reads the
# finished record - counted, it would sit under LoadedLines and drop forever
# (a load/append_new asymmetry: load must not count a tail it cannot parse,
# or append_new will never get to re-read it).
set JP2 [file join $TMP tail.jsonl]
set fh [open $JP2 w]
fconfigure $fh -encoding utf-8
puts $fh {{"type":"user","promptSource":"typed","timestamp":"2026-07-11T14:00:00Z","message":{"role":"user","content":"Tail question"}}}
# One valid record, split mid-string: the prefix is the unparseable tail the
# writer is caught on, the remainder completes it on the "next write".
set tailrec {{"type":"assistant","timestamp":"2026-07-11T14:00:05Z","message":{"role":"assistant","content":[{"type":"text","text":"TAILMARKER redundant."}]}}}
puts -nonewline $fh [string range $tailrec 0 end-20]
close $fh
$V show $JP2
update idletasks
check "the mid-write tail rendered nothing" \
    [expr {[$Text search TAILMARKER 1.0 end] eq ""}] 1
set fh [open $JP2 a]
fconfigure $fh -encoding utf-8
puts $fh [string range $tailrec end-19 end]
close $fh
$V append_new
update idletasks
check "the completed tail record renders on the next pass" \
    [expr {[$Text search TAILMARKER 1.0 end] ne ""}] 1

# ---- 21. an empty-bodied typed prompt opens no turn ------------------------------
# is_turn_start would accept it, but with nothing to render there is no header
# line to fold from; ungated, it would close the running turn and orphan
# everything after into always-visible preamble. The gate treats it as any
# bodiless record: clock advances, the open turn keeps owning what follows.
set fh [open $JP2 a]
fconfigure $fh -encoding utf-8
puts $fh {{"type":"user","promptSource":"typed","timestamp":"2026-07-11T14:01:00Z","message":{"role":"user","content":""}}}
puts $fh {{"type":"user","timestamp":"2026-07-11T14:01:05Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t9","content":"orphan-check contents"}]}}}
close $fh
$V append_new
update idletasks
check "an empty typed prompt opens no turn" [llength [set ${NS}::Turns]] 1
check "the open turn still owns what follows (detail hidden, not preamble)" \
    [vischars "orphan-check"] 0

# ---- 22. match-context label doubling and stale-prompt carryover ------------------
# A match row already leads with the role; a hit landing on a record's first
# line must not excerpt the label into the context too ("ASSISTANT ·
# ...ASSISTANT ..."). And typed-but-unsent resume text stays with its session.
$V show $JP 0 {}
update idletasks
$V index_matches [dict create terms [list frobnication] nocase 0]
check "a first-line hit's context excerpt starts past the label" \
    [string match "*ASSISTANT*" [lindex [set ${NS}::MatchLabels] 0]] 0
set ${NS}::PromptVar "typed for session A, unsent"
$V show $JP2 0 {}
update idletasks
check "show clears the unsent prompt text" [set ${NS}::PromptVar] ""

# ---- 23. find-bar "N of M" readout and band highlight tracking ------------------
# The find machinery shares one match set across the docked band, the Ctrl-F
# overlay and the head-strip count. The find bar states the stepped position
# ("N of M", design screens.jsx FindBar); stepping and jumping move the band's
# highlight to the active hit, not leave it stranded on row 0.
set ML [set ${NS}::MatchList]
check "the readout label exists in the find bar" [winfo exists .v.find.pos] 1
$V show $JP 0 {}
update idletasks
# A term with several hits so stepping has somewhere to go.
$V index_matches [dict create terms [list sigil] nocase 0]
update idletasks
set M [llength [set ${NS}::FindMatches]]
check "the sigil query found more than one hit" [expr {$M > 1}] 1
# A freshly built index shows nothing yet (FindCur -1) but the readout
# anticipates "1 of M" and the band pre-selects row 0 (the design resting state).
check "a fresh index has shown no hit yet" [set ${NS}::FindCur] -1
check "readout anticipates 1 of M after indexing" [set ${NS}::FindPos] "1 of $M"
check "band pre-selects the first row" [$ML curselection] 0

# First Next surfaces hit 0 (unchanged navigation), landing the readout and the
# band highlight on it.
$V find_next
update idletasks
check "first Next surfaces hit 0" [set ${NS}::FindCur] 0
check "readout reads 1 of M on hit 0" [set ${NS}::FindPos] "1 of $M"
check "band highlight sits on row 0" [$ML curselection] 0

# The next Next advances the readout and the band highlight together.
$V find_next
update idletasks
check "second Next is on hit 1" [set ${NS}::FindCur] 1
check "readout reads 2 of M after two Next" [set ${NS}::FindPos] "2 of $M"
check "band highlight followed to row 1" [$ML curselection] 1

# A jump (the band-click twin) moves the active hit, readout and highlight to it.
$V jump_to_match [expr {$M - 1}]
update idletasks
check "jump sets the active hit to the last" [set ${NS}::FindCur] [expr {$M - 1}]
check "readout reads M of M after jumping last" [set ${NS}::FindPos] "$M of $M"
check "band highlight followed the jump" [$ML curselection] [expr {$M - 1}]

# Next past the last wraps to the first.
$V find_next
update idletasks
check "Next past the end wraps to hit 0" [set ${NS}::FindCur] 0
check "readout wraps to 1 of M" [set ${NS}::FindPos] "1 of $M"

# Closing the find bar clears the readout and the active hit.
$V find_hide
check "find_hide blanks the readout" [set ${NS}::FindPos] ""
check "find_hide drops the active hit" [set ${NS}::FindCur] -1

# A fresh Ctrl-F term collects its own hits into the shared set; the readout
# counts them. The band still holds the sigil rows (Ctrl-F does not refill it),
# so select_band_row's exact-set guard must decline to move the highlight.
set ${NS}::FindVar "frobnicate"
$V find_next
update idletasks
set MC [llength [set ${NS}::FindMatches]]
check "Ctrl-F collected its own hits" [expr {$MC >= 1}] 1
check "readout counts the Ctrl-F set" [set ${NS}::FindPos] "1 of $MC"
# The band still holds the sigil rows with row 0 last selected (the wrap above);
# select_band_row's exact-set guard must leave that untouched, not chase the
# frobnicate index onto an unrelated row.
check "stale band declines the step (guard holds)" [$ML curselection] 0

# Editing the term (drift from the last collected) blanks the stale readout.
set ${NS}::FindVar "frobnicate-XYZ"
$V find_typing
check "typing a new term blanks the stale readout" [set ${NS}::FindPos] ""

# A search that finds nothing states the empty tally rather than blanking it.
$V find_next
update idletasks
check "a fruitless search shows 0 of 0" [set ${NS}::FindPos] "0 of 0"

# ---- 24. the band is a paned split; the sash survives close/reopen --------------
# band_show docks the band as the top pane of the body split (the sash under it
# is the divider the user drags); band_hide forgets the pane and remembers the
# band's pixel height, and a reopen restores it - an absolute height, so the
# round trip holds even though the test root resizes around the forgotten pane.
# The placement runs deferred at idle (band_place_sash), so pump idle events
# between steps. This section runs last: the first sashpos set latches the
# paned window's size request (ttk::panedwindow stops tracking its panes'
# content requests), and a latched, shrunken root would squeeze any section
# after it that assumes a content-sized window.
set Body .v.body
set Band [set ${NS}::Band]
$V band_show turns
update idletasks
check "band_show docks the band as the top pane" [lindex [$Body panes] 0] $Band
$Body sashpos 0 120
set want [$Body sashpos 0]
$V band_hide
update idletasks
check "band_hide forgets the pane" [lsearch [$Body panes] $Band] -1
check "the closed band's height was remembered" [set ${NS}::BandSash] $want
$V band_show turns
update idletasks
check "a reopen restores the dragged sash (within 2px)" \
    [expr {abs([$Body sashpos 0] - $want) <= 2}] 1

# ---- clean up -------------------------------------------------------------------
::questlog::path::_real_file delete -force $TMP
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
