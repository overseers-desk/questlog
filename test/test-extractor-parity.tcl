#!/usr/bin/env wish9.0
# Issue #30: one session-row extractor for the browse and search passes.
#
# Scan.scan_one (browse) and ::questlog::match::scan_file (search) once each
# rebuilt the whole row independently and drifted - nturns was capped in browse
# but not in search, and slug/ai_title/kind rode only the browse row. They are
# now one extractor: scan_one delegates to scan_file with an empty clause set, so
# a single dict-build serves both passes and the row shape cannot diverge.
#
# Part A (no store): the browse row and the search row for the SAME file are
# identical in every shared field, including the three that used to be
# browse-only (slug, ai_title, kind) and the capped turn count.
#
# Part B (the store): a search-discovered session enters the session list from
# the complete row the search pass already produced - NO second full-file read.
# The read is counted through the on_scan_path seam (as test-scan-negmemo counts
# first_cwd calls): a matched row carried into hydrate_session costs zero seam
# reads, while a caller with no row in hand still pays exactly one.
#
# Runs under wish (Part B builds a SessionList); run-audit routes it to wish9.0
# on the private Xvfb.

package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
set ::questlog_config_only 1; source [file join $ROOT questlog]
foreach f {lib/cost.tcl ui/theme.tcl lib/path.tcl lib/listfilter.tcl \
           lib/jsonl.tcl lib/match.tcl ui/terminal.tcl ui/live.tcl lib/scan.tcl \
           lib/search.tcl ui/drag.tcl ui/toolbar.tcl ui/sessions.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init
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

proc noop {args} {}

# ---- fixture --------------------------------------------------------------
# One cli session: 12 real user turns (past turn_count_cap = 9, so a correct
# nturns saturates at 9), a recorded cwd and a first timestamp, and a rename tail
# (agentName + aiTitle) so the slug/ai_title fields have something to carry. The
# keyword "findme" in the opening prompt is what Part A's search clause matches.
set SAND [file join [pwd] _extractor_parity_sandbox]
::questlog::path::_real_file delete -force $SAND
set FA -home-test-code-foo
set DIRA [file join $SAND .claude projects $FA]
::questlog::path::_real_file mkdir $DIRA
set ::env(HOME) $SAND

proc write_session {path} {
    set fh [open $path w]
    chan configure $fh -encoding utf-8 -translation lf
    puts $fh {{"type":"user","cwd":"/home/test/code/foo","timestamp":"2026-05-01T09:00:00.000Z","message":{"role":"user","content":"findme in the very first prompt"}}}
    for {set i 2} {$i <= 12} {incr i} {
        puts $fh "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"model\":\"claude-opus-4-8\",\"content\":\"reply $i\"}}"
        puts $fh "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"real prompt $i\"}}"
    }
    puts $fh {{"type":"custom-title","customTitle":"picker only","sessionId":"s01"}}
    puts $fh {{"type":"agent-name","agentName":"the-worn-name","sessionId":"s01"}}
    close $fh
}

set SP [file join $DIRA s01.jsonl]
write_session $SP
file mtime $SP 1746090000

# ---- Part A: browse row == search row, no drift ---------------------------
set scan [::questlog::Scan new {} {}]
set browse_row [$scan scan_one $SP]

set clauses [::questlog::search::build_clauses [dict create search findme]]
lassign [::questlog::match::scan_file $SP $clauses] search_row matches

check "search actually matched (row has a match)" 1 [expr {[llength $matches] > 0}]

# The three fields that used to be browse-only now ride the search row too.
check "slug present in search row"     the-worn-name [dict getdef $search_row slug ""]
check "ai_title present in search row" ""            [dict getdef $search_row ai_title ""]
check "kind present in search row"     cli           [dict getdef $search_row kind ""]

# nturns is capped identically (12 real turns -> saturates at turn_count_cap 9).
check "nturns capped in browse" 9 [dict get $browse_row nturns]
check "nturns capped in search" 9 [dict get $search_row nturns]

# Every shared field agrees field by field...
foreach k {path mtime size folder uuid first_ts nturns kind first_user slug \
           ai_title has_subagents bookmarked cwd_hint is_child parent_path \
           parent_uuid} {
    check "shared field '$k' identical" [dict get $browse_row $k] [dict get $search_row $k]
}
# ...and the whole dict is byte-identical: one extractor, one row shape.
check "browse row == search row (whole dict)" $browse_row $search_row

# turn_count_cap rode in on the clause dict (so a worker caps without config).
check "clauses carry turn_count_cap" 9 [dict getdef $clauses turn_count_cap ""]

$scan destroy

# ---- Part B: a search-discovered row enters the store with no re-read ------
# The seam is on_scan_path: hydrate_session's fallback read. Count its calls.
set ::scan_reads 0
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc scanpath {path}    { incr ::scan_reads; return [$::Scan scan_path $path] }
proc resolvef {f}       { return "/home/test/code/foo" }
proc subagentsf {path}  { return [$::Scan subagents_for $path] }

set SL ""
set SL [::questlog::ui::SessionList new .s resolvef noop noop noop noop noop \
            noop scanpath noop subagentsf noop]
pack .s -fill both -expand 1

# A search is under way, so the browse stream attaches nothing: the result's row
# reaches the store only through the render path. This is where the second read
# used to happen.
$SL apply_filter [dict create search findme]

# The app flushes a found session as `render_session_matches $matches $row` with
# the COMPLETE row the search produced. A search-discovered path is modelled from
# that row alone - the scan seam is never touched.
$SL render_session_matches $matches $search_row
check "search-discovered session is modelled" 1 [$SL has_session $SP]
check "no seam read when the row is carried" 0 $::scan_reads

# A caller with no row in hand (a case-B parent that itself matched nothing)
# still hydrates through the seam: exactly one read, proving the count is live.
set SP2 [file join $DIRA s02.jsonl]
write_session $SP2
file mtime $SP2 1746090000
set m2 [list [dict create path $SP2 folder $FA btype user content "findme" lineoff 1 \
    is_child 0 parent_path "" parent_uuid "" agent_id s02]]
$SL render_session_matches $m2 ""
check "one seam read when no row is carried" 1 $::scan_reads
check "seam-read session is modelled"       1 [$SL has_session $SP2]

$SL destroy
$::Scan destroy
::questlog::path::_real_file delete -force $SAND

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
