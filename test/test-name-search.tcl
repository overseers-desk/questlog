#!/usr/bin/env tclsh9.0
# Tests for the `names` search region: a session is found by any title it has
# ever worn, not by its message bodies. A rename appends an agent-name / ai-title
# record, so the file holds the whole name history; scan_file collects those worn
# names and a leaf whose regions include `names` scores against them per-session,
# folded into the same boolean tree as the per-record body evidence. customTitle
# is deliberately excluded - it feeds Claude Code's own picker, not the list slug.
# Pure and Tk-free. Run:
#   tclsh9.0 test/test-name-search.tcl
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
source [file join $ROOT config.tcl]
source [file join $ROOT lib jsonl.tcl]
source [file join $ROOT lib match.tcl]
source [file join $ROOT lib search.tcl]
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

# A fixture session whose worn names (desperate-user via agent-name, early-slug
# via ai-title) appear in no message body, plus a customTitle string that appears
# only there. The bodies mention "ordinary", so a body needle still has something
# to find and the two regions can be told apart.
set fix [file join [file dirname [info script]] _name_fixture.jsonl]
set fh [open $fix w]
chan configure $fh -encoding utf-8 -translation lf
puts $fh {{"type":"ai-title","aiTitle":"early-slug","sessionId":"s1"}}
puts $fh {{"type":"user","message":{"content":"just an ordinary prompt about widgets"}}}
puts $fh {{"type":"assistant","message":{"content":"a plain reply, nothing unusual"}}}
puts $fh {{"type":"custom-title","customTitle":"hidden-picker-name","sessionId":"s1"}}
puts $fh {{"type":"agent-name","agentName":"desperate-user","sessionId":"s1"}}
close $fh

# One-leaf clause dicts, region-spec resolved through the real parse_regions so a
# drift in the region vocabulary shows up here too.
proc kw_clauses {needle regionspec nocase} {
    set leaf [::questlog::match::kw_leaf $needle \
        [::questlog::search::parse_regions $regionspec] 0]
    return [dict create leaves [list $leaf] \
        tree [::questlog::match::tnode_and [list [::questlog::match::tnode_leaf 0]]] \
        nocase $nocase]
}
proc rx_clauses {needle regionspec nocase} {
    set leaf [::questlog::match::rx_leaf $needle \
        [::questlog::search::parse_regions $regionspec] 0]
    return [dict create leaves [list $leaf] \
        tree [::questlog::match::tnode_and [list [::questlog::match::tnode_leaf 0]]] \
        nocase $nocase]
}
# An AND-tree over pre-built leaves, for composition tests.
proc and_clauses {leaves nocase} {
    set nodes [list]
    for {set i 0} {$i < [llength $leaves]} {incr i} {
        lappend nodes [::questlog::match::tnode_leaf $i]
    }
    return [dict create leaves $leaves \
        tree [::questlog::match::tnode_and $nodes] nocase $nocase]
}
proc nmatches {clauses} {
    lassign [::questlog::match::scan_file $::fix $clauses] row matches
    return [llength $matches]
}

# ---- the region vocabulary carries `names` ---------------------------------
check region_names       {names}       [::questlog::search::parse_regions names]
check region_names_prefix {names}       [::questlog::search::parse_regions nam]
check region_names_joined {names user}  [::questlog::search::parse_regions user,names]

# ---- a name needle finds a worn name, a body needle does not ----------------
# desperate-user and early-slug live only in the name history; the `names` region
# finds them, the default (body) region does not. "ordinary" is the converse: in
# the body, not a name.
check names_agentname   1 [nmatches [kw_clauses desperate  names 1]]
check names_aititle     1 [nmatches [kw_clauses early-slug names 1]]
check body_misses_name  0 [nmatches [kw_clauses desperate  any   1]]
check body_misses_slug  0 [nmatches [kw_clauses early-slug any   1]]
check body_finds_body   1 [nmatches [kw_clauses ordinary   any   1]]
check names_misses_body 0 [nmatches [kw_clauses ordinary   names 1]]

# customTitle is not a worn name: a needle found only there matches nothing.
check names_excludes_custom_title 0 [nmatches [kw_clauses hidden-picker names 1]]

# ---- case sensitivity honours the flag, exactly as body keywords do ---------
check names_nocase_hit   1 [nmatches [kw_clauses DESPERATE names 1]]
check names_case_miss    0 [nmatches [kw_clauses DESPERATE names 0]]
check names_case_exact   1 [nmatches [kw_clauses desperate names 0]]

# ---- a regex leaf scopes to names too --------------------------------------
check names_regex_hit    1 [nmatches [rx_clauses {desp.*-user} names 1]]
check names_regex_miss   0 [nmatches [rx_clauses {^nomatch$}   names 1]]

# ---- names composes with body regions under the boolean tree ----------------
# names AND a satisfied body leaf keeps the session and buffers both snippets;
# names AND an unsatisfied body leaf fails the tree, so no snippet survives.
set L_name     [::questlog::match::kw_leaf desperate {names} 0]
set L_body     [::questlog::match::kw_leaf ordinary  {}      0]
set L_bodymiss [::questlog::match::kw_leaf ZZZNOPE   {}      0]
check compose_and_hit  2 [nmatches [and_clauses [list $L_name $L_body]     1]]
check compose_and_miss 0 [nmatches [and_clauses [list $L_name $L_bodymiss] 1]]

# ---- the buffered hit anchors the name, tagged with the `names` btype -------
lassign [::questlog::match::scan_file $fix [kw_clauses desperate names 1]] row matches
set m [lindex $matches 0]
check name_hit_btype   names          [dict get $m btype]
check name_hit_content desperate-user [dict get $m content]

file delete $fix

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
