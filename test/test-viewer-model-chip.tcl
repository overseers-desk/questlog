#!/usr/bin/env wish9.0
# The per-turn model chip in the session viewer.
#
# The model in use can change mid-session (/model), so each assistant header
# line carries a small tinted chip (coloured dot + short "Family Ver" label)
# naming the model that produced it. The first assistant of every turn chips;
# a later assistant chips again only on a genuine model change. A sidechain
# (subagent) record and a <synthetic> filler never chip, and the chip's words
# ("Opus", "Sonnet", version digits) are chrome the transcript search skips.
#
# This drives a real Viewer over a synthetic two-turn session that switches
# model mid-way and asserts all of that.
#
# Runs under wish (it builds a Viewer, so it needs Tk); run-audit routes it to
# wish9.0 on the private Xvfb. Standalone: DISPLAY=:95 wish9.0 test-viewer-model-chip.tcl

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
# Mirror the launcher's GUI source order for the subset the Viewer needs: config
# and the Tk-free libs it reads (including cost.tcl, whose model_family/fmt_model
# the chip resolves the family and label through), the theme (named fonts +
# palette, where the model_* roles live), then the class itself.
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

# ---- synthetic session: two turns, model switched mid-way --------------------
# Turn 1's assistant is claude-opus-4-8; turn 2's is claude-sonnet-4-5 (a /model
# change). Turn 2 also holds a sidechain (subagent) assistant on haiku and a
# <synthetic> filler; neither may chip. Body text deliberately carries no family
# word ("opus"/"sonnet"/...) so the search assertion below can prove the chip
# label is the ONLY "Opus" in the transcript and is excluded from search.
set tmpbase [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set TMP [file join $tmpbase ql-modelchip-test-[pid]]
# lib/path.tcl wraps `file` to refuse callers outside ::questlog::path::*; reach
# the unwrapped command for the sandbox dir under /tmp, as the other UI tests do.
::questlog::path::_real_file mkdir $TMP
set JP [file join $TMP session.jsonl]
set fh [open $JP w]
fconfigure $fh -encoding utf-8
puts $fh {{"type":"user","cwd":"/tmp/proj","timestamp":"2026-07-11T10:00:00Z","message":{"role":"user","content":"first prompt"}}}
puts $fh {{"type":"assistant","timestamp":"2026-07-11T10:00:05Z","message":{"role":"assistant","model":"claude-opus-4-8","content":"First turn reply here.","usage":{"input_tokens":10,"output_tokens":5}}}}
puts $fh {{"type":"user","cwd":"/tmp/proj","timestamp":"2026-07-11T10:01:00Z","message":{"role":"user","content":"second prompt"}}}
puts $fh {{"type":"assistant","timestamp":"2026-07-11T10:01:05Z","message":{"role":"assistant","model":"claude-sonnet-4-5","content":"Second turn reply here.","usage":{"input_tokens":10,"output_tokens":5}}}}
puts $fh {{"type":"assistant","isSidechain":true,"timestamp":"2026-07-11T10:01:07Z","message":{"role":"assistant","model":"claude-haiku-4-5","content":"Subagent reply here.","usage":{"input_tokens":3,"output_tokens":2}}}}
puts $fh {{"type":"assistant","timestamp":"2026-07-11T10:01:09Z","message":{"role":"assistant","model":"<synthetic>","content":"No response requested.","usage":{"input_tokens":0,"output_tokens":0}}}}
puts $fh {{"type":"user","cwd":"/tmp/proj","timestamp":"2026-07-11T10:01:20Z","message":{"role":"user","content":"thanks"}}}
close $fh

# ---- build a real Viewer and show the session --------------------------------
set V [::questlog::ui::Viewer new .v]
pack .v -fill both -expand 1
$V show $JP 0 {}
update idletasks
update

set Text [$V textwidget]
set NS [info object namespace $V]

# 1. Turn 1 chips Opus 4.8, tagged model-opus and modelchip at the hit.
set oi [$Text search "Opus 4.8" 1.0 end]
check "Opus chip present on turn 1" [expr {$oi ne ""}] 1
set otags [$Text tag names $oi]
check "Opus chip carries model-opus" [expr {"model-opus" in $otags}] 1
check "Opus chip carries modelchip" [expr {"modelchip" in $otags}] 1

# 2. Turn 2 chips Sonnet 4.5, tagged model-sonnet (the mid-session change).
set si [$Text search "Sonnet 4.5" 1.0 end]
check "Sonnet chip present on turn 2" [expr {$si ne ""}] 1
check "Sonnet chip carries model-sonnet" \
    [expr {"model-sonnet" in [$Text tag names $si]}] 1

# 3. Exactly the two real turns chipped: the sidechain and <synthetic> assistant
#    records took no chip. Each chip is one contiguous modelchip range.
check "only the two real turns chipped" \
    [expr {[llength [$Text tag ranges modelchip]] / 2}] 2

# 4. The chip's words are chrome, not transcript: a search for the family word
#    finds nothing (the body carries no "Opus"; the chip is excluded).
$V show $JP 0 {terms Opus nocase 1}
update idletasks
update
check "chip label excluded from search" [llength [set ${NS}::FindMatches]] 0

# ---- clean up ----------------------------------------------------------------
::questlog::path::_real_file delete -force $TMP
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
