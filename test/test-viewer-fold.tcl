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
::tcl::tm::path add $ROOT
package require leash
package require streamtree
foreach f {config.tcl lib/debug.tcl lib/path.tcl lib/jsonl.tcl lib/match.tcl \
           ui/theme.tcl ui/viewer.tcl} {
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
# the live content end (before the endhint), the same bound turn_fold uses.
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
# The stub's words are chrome: a search for them must not index.
check "stub words are not matches" [llength [$V collect_matches "tool call"]] 0

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

# ---- C5: Turns index tab + fold-all affordances --------------------------------
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
check "a turn row reads its stamp and the prompt's first line" \
    [$TurnLB get 0] \
    "[$V tool_time [dict get [turn 0] ts]] · [dict get [turn 0] label]"

# ---- 11. a Turns-tab jump lands on the header, even everything folded -----------
# fold_all collapses every turn to its header; a jump to the last row must still
# reveal that header (turn_list_select routes through reveal_index, which
# unfolds the folded target and scrolls it in).
$V fold_all
update idletasks
set last [expr {[llength [set ${NS}::Turns]] - 1}]
$TurnLB selection clear 0 end
$TurnLB selection set $last
$V turn_list_select
update idletasks
check "the jump scrolls the folded last turn's header into view (bbox non-empty)" \
    [expr {[$Text bbox [dict get [turn $last] hdr]] ne ""}] 1
$V expand_all
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

# ---- clean up -------------------------------------------------------------------
::questlog::path::_real_file delete -force $TMP
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
