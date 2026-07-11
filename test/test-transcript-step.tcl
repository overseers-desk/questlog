#!/usr/bin/env tclsh9.0
# Direct unit tests for ::questlog::jsonl::transcript_step, the one shared
# per-record segmenter the markdown export and the session viewer both fold over
# (issue #31). The cues under test: a compaction boundary resets the clock and is
# the sole event; an empty-body record emits nothing but advances the clock when
# it is stamped; an idle gap fires only at or past the threshold and only between
# two stamped content records; and a gap is emitted before its body. tclsh-only,
# no Tk. Run:
#   tclsh9.0 test/test-transcript-step.tcl
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT config.tcl]
source [file join $ROOT lib jsonl.tcl]
# extract_text routes tool_use blocks through ::questlog::match; source it and
# inject the caps the launcher does so a body drawn from a tool call would render
# the same text the app exports. The cases here carry string bodies, but the
# dependency is real.
source [file join $ROOT lib match.tcl]
::questlog::match::set_caps [dict create \
    content_cap     [::questlog::config::get content_cap] \
    snippet_lead    [::questlog::config::get snippet_lead] \
    snippet_trail   [::questlog::config::get snippet_trail] \
    tool_param_cap  [::questlog::config::get tool_param_cap] \
    tool_render_cap [::questlog::config::get tool_render_cap]]

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name"
        puts "  expected: <$expected>"
        puts "  actual:   <$actual>"
        incr ::fails
    } else {
        puts "ok:   $name"
    }
}

# transcript_step takes a PARSED record, the epoch of the previous content
# record (0 for none), and the idle-gap threshold in minutes; it returns
# {events new_last_ts}. Feed it literal JSON through parse_line.
proc step {json last_ts idle} {
    return [::questlog::jsonl::transcript_step \
        [::questlog::jsonl::parse_line $json] $last_ts $idle]
}
# A stamped user prompt whose extract_text body is "hi" - one content record.
proc user_at {ts} {
    return "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hi\"},\"timestamp\":\"$ts\"}"
}

# Base clock and three offsets from it, parsed through the same parser the step
# uses so the epoch assertions below cannot drift from its arithmetic.
set e0  [::questlog::jsonl::parse_iso "2026-01-01T00:00:00.000Z"]  ;# base
set e30 [::questlog::jsonl::parse_iso "2026-01-01T00:30:00.000Z"]  ;# +30 min
set e45 [::questlog::jsonl::parse_iso "2026-01-01T00:45:00.000Z"]  ;# +45 min

# ---- compact boundary: sole event, clock reset ----------------------------
# A compaction boundary emits {compact} and nothing else, and returns a clock of
# 0 whatever the incoming last_ts, so the first turn after a compaction never
# reads as an idle gap from before it. Its own timestamp is not consulted.
lassign [step {{"type":"system","subtype":"compact_boundary","timestamp":"2026-01-01T09:00:00.000Z"}} 987654 30] evs nlt
check compact_event   {compact} $evs
check compact_resets  0         $nlt

# ---- empty body: no event, clock advances only when stamped ---------------
# A record extract_text draws no body from (a file-history snapshot) emits no
# event but advances the clock to its own stamp, so a later gap spans it.
lassign [step {{"type":"file-history-snapshot","timestamp":"2026-01-01T00:30:00.000Z"}} $e0 30] evs nlt
check empty_no_event  {}   $evs
check empty_advances  $e30 $nlt
# An unstamped empty record leaves the clock exactly where it was.
lassign [step {{"type":"file-history-snapshot"}} $e0 30] evs nlt
check empty_nostamp_event {}  $evs
check empty_nostamp_clock $e0 $nlt

# ---- first record never gaps ----------------------------------------------
# A stamped content record with no prior content (last_ts 0) is a plain body and
# leaves the clock at its stamp; there is nothing to measure a gap against.
lassign [step [user_at "2026-01-01T00:45:00.000Z"] 0 30] evs nlt
check first_body_only  {{body hi}} $evs
check first_body_clock $e45        $nlt

# ---- idle gap: threshold and content-to-content only ----------------------
# A silence at or over the threshold between two stamped content records fires a
# gap, emitted BEFORE the body, carrying the raw floored minute count (the
# consumer formats it). 45 min >= 30.
lassign [step [user_at "2026-01-01T00:45:00.000Z"] $e0 30] evs nlt
check gap_fires_order    {{gap 45} {body hi}} $evs
check gap_advances_clock $e45                 $nlt
# Exactly at the threshold fires (the test is >=, not >).
lassign [step [user_at "2026-01-01T00:30:00.000Z"] $e0 30] evs nlt
check gap_at_threshold {{gap 30} {body hi}} $evs
# One minute under the threshold does not.
lassign [step [user_at "2026-01-01T00:29:00.000Z"] $e0 30] evs nlt
check gap_below_threshold {{body hi}} $evs
# A gap needs both ends stamped: an unstamped content record cannot gap even
# with a prior content clock set, and it leaves that clock untouched.
lassign [step {{"type":"user","message":{"role":"user","content":"hi"}}} $e0 30] evs nlt
check gap_needs_this_stamp      {{body hi}} $evs
check gap_unstamped_keeps_clock $e0         $nlt

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
