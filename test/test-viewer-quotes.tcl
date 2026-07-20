#!/usr/bin/env wish9.0
# Assistant blockquotes render as plain tagged text, not embedded text widgets.
#
# The old renderer embedded a child `text` widget per quote: its Text-class
# wheel binding swallowed the mouse wheel as the pointer crossed a quote, and
# its content was invisible to the transcript's own $Text search. This drives a
# real Viewer over a one-quote synthetic session and asserts the replacement:
# no embedded windows survive, the quoted text is found by $Text search, a click
# on the ⧉ glyph copies the raw de-quoted text, and a reload leaves no stale
# quote state behind.
#
# Runs under wish (it builds a Viewer, so it needs Tk); run-audit routes it to
# wish9.0 on the private Xvfb. Standalone: DISPLAY=:95 wish9.0 test-viewer-quotes.tcl

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
foreach f {lib/debug.tcl lib/path.tcl lib/jsonl.tcl lib/match.tcl \
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

# ---- synthetic session: one assistant turn carrying a markdown blockquote ----
set tmpbase [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set TMP [file join $tmpbase ql-quote-test-[pid]]
# lib/path.tcl wraps `file` to refuse callers outside ::questlog::path::*; reach
# the unwrapped command for the sandbox dir under /tmp, as the other UI tests do.
::questlog::path::_real_file mkdir $TMP
set JP [file join $TMP session.jsonl]
set fh [open $JP w]
fconfigure $fh -encoding utf-8
# The assistant body has a two-line blockquote (each line "> ...") with a
# distinctive token and a **bold** span inside, so the test can find the token
# by search and confirm the copy carries the raw (still-marked-up) de-quoted
# text. \n is a JSON string escape here, decoded to a newline by the parser.
puts $fh {{"type":"user","cwd":"/tmp/proj","timestamp":"2026-07-11T10:00:00Z","message":{"role":"user","content":"show me a quote"}}}
puts $fh {{"type":"assistant","timestamp":"2026-07-11T10:00:05Z","message":{"role":"assistant","model":"claude-3-5-sonnet-20241022","content":"Here is a quote:\n\n> This is QUOTETOKEN a quoted line\n> with **bold** inside\n\nDone.","usage":{"input_tokens":10,"output_tokens":5}}}}
puts $fh {{"type":"user","cwd":"/tmp/proj","timestamp":"2026-07-11T10:00:09Z","message":{"role":"user","content":"thanks"}}}
close $fh

# The one quote's raw de-quoted text (what a copy must yield): the two quoted
# lines with the "> " stripped, joined by a newline, markdown left intact.
set EXPECTED "This is QUOTETOKEN a quoted line\nwith **bold** inside"

# ---- build a real Viewer and show the session --------------------------------
# The transcript text widget defaults to 80x24 chars, so the natural window is
# large enough to lay the quote out; `$Text see` below scrolls its glyph into
# view before the bbox click. (No wm geometry: content drives the size.)
set V [::questlog::ui::Viewer new .v]
pack .v -fill both -expand 1
$V show $JP 0 {}
update idletasks
update

set Text [$V textwidget]
set NS [info object namespace $V]

# 1. No embedded windows remain in the transcript: the quote is tagged text now.
check "no embedded quote widgets" [llength [$Text window names]] 0

# 2. The quoted text is ordinary searchable content.
check "quote token found by \$Text search" \
    [expr {[$Text search QUOTETOKEN 1.0 end] ne ""}] 1

# 3. Exactly one quote was captured, in lock-step index/body lists.
check "one quote indexed" [llength [set ${NS}::QuoteIdx]] 1
check "QuoteBodies parallels QuoteIdx" \
    [llength [set ${NS}::QuoteBodies]] [llength [set ${NS}::QuoteIdx]]
check "captured body is the raw de-quoted text" \
    [lindex [set ${NS}::QuoteBodies] 0] $EXPECTED

# 4. Clicking the ⧉ glyph copies that raw text. Drive the tag-bind handler over
#    the glyph's own bbox after making sure it is laid out.
set GI [$Text search "⧉" 1.0 end]
check "copy glyph present" [expr {$GI ne ""}] 1
$Text see $GI
update idletasks
lassign [$Text bbox $GI] bx by bw bh
clipboard clear
clipboard append "sentinel-before"
$V quote_copy_at [expr {$bx + 1}] [expr {$by + 1}]
check "glyph click copies the de-quoted text" [clipboard get] $EXPECTED

# 5. A drag-select release over the glyph must NOT copy (selection present).
clipboard clear
clipboard append "sentinel-keeps"
$Text tag add sel $GI "$GI + 1c"
$V quote_copy_at [expr {$bx + 1}] [expr {$by + 1}]
check "glyph click with a live selection does not copy" \
    [clipboard get] "sentinel-keeps"
$Text tag remove sel 1.0 end

# 6. Reloading the same session leaves no stale quote state: the lists reset and
#    refill to the same one quote, not two.
$V show $JP 0 {}
update idletasks
update
check "QuoteIdx does not accumulate across reload" [llength [set ${NS}::QuoteIdx]] 1
check "QuoteBodies matches QuoteIdx after reload" \
    [llength [set ${NS}::QuoteBodies]] [llength [set ${NS}::QuoteIdx]]
check "still no embedded widgets after reload" [llength [$Text window names]] 0

# ---- clean up ----------------------------------------------------------------
::questlog::path::_real_file delete -force $TMP
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
