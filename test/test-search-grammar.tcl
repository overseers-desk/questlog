#!/usr/bin/env tclsh9.0
# Tests for the --json clause grammar: region parsing (lib/search.tcl
# parse_regions), the argv parser (cli/main.tcl parse_query) and its boolean
# tree, the tree evaluator (lib/match.tcl eval_tree), and the issue's worked
# examples end to end through scan_file on a fixture. The query error paths are
# checked against the real launcher, since they exit through usage.
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
# Only what parse_query and scan_file need: not lib/path.tcl (it renames `file`
# to guard deletes, which would block this test's fixture cleanup), nor the
# Scan/cost layer (run's concern, not the grammar's).
source [file join $ROOT config.tcl]
source [file join $ROOT lib filter.tcl]
source [file join $ROOT lib jsonl.tcl]
source [file join $ROOT lib match.tcl]
source [file join $ROOT lib search.tcl]
source [file join $ROOT cli main.tcl]
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
proc throws {body} { return [catch [list uplevel 1 $body]] }

# ---- parse_regions ---------------------------------------------------------
# any and empty are unrestricted (the empty list); the four tokens map to the
# block types; prefixes resolve when unambiguous; comma joins; an ambiguous or
# unknown token throws.
check region_any        {} [::questlog::search::parse_regions any]
check region_empty      {} [::questlog::search::parse_regions ""]
check region_one        tool_result [::questlog::search::parse_regions tool-result]
check region_prefix     assistant   [::questlog::search::parse_regions assi]
check region_prefix_use tool_use    [::questlog::search::parse_regions tool-u]
check region_comma      {assistant user} [::questlog::search::parse_regions user,assistant]
check region_any_wins   {} [::questlog::search::parse_regions user,any]
check region_ambig_tool 1 [throws {::questlog::search::parse_regions tool}]
check region_ambig_a    1 [throws {::questlog::search::parse_regions a}]
check region_unknown    1 [throws {::questlog::search::parse_regions nope}]

# ---- parse_query: the boolean tree -----------------------------------------
proc tree {args} { return [dict get [::questlog::cli::main::parse_query $args] clauses] }

# Adjacency ANDs, --or splits OR-groups: A B --or C is (A AND B) OR C.
check tree_precedence \
    {leaves {{kind keyword needle A regions {} neg 0} {kind keyword needle B regions {} neg 0} {kind keyword needle C regions {} neg 0}} tree {t or nodes {{t and nodes {{t leaf id 0} {t leaf id 1}}} {t and nodes {{t leaf id 2}}}}} nocase 1} \
    [tree --keyword A --keyword B --or --keyword C]

# --not negates the next leaf only (neg flag on the leaf).
check tree_not_flag {0 1} [lmap l [dict get [tree --keyword A --not --keyword B] leaves] { dict get $l neg }]

# A region suffix rides on the leaf; --case clears nocase; a bare word is keyword.
check tree_regions {tool_result} [dict get [lindex [dict get [tree --keyword:tool-result x] leaves] 0] regions]
check tree_case    0 [dict get [tree --case --keyword x] nocase]
check tree_bare_kw keyword [dict get [lindex [dict get [tree bareword] leaves] 0] kind]
check tree_tool    {kind tool sel file spec read value c.tcl neg 0} \
    [lindex [dict get [tree --tool:read c.tcl] leaves] 0]

# ---- parse_query: the global bounds ride beside the clause tree ------------
proc bound {key args} { return [dict get [::questlog::cli::main::parse_query $args] $key] }
check bound_since   7d         [bound since --since 7d --keyword x]
check bound_until   2026-04-01 [bound until --until 2026-04-01 --keyword x]
check bound_until_default "" [bound until --keyword x]
# --accrued-cost is a boolean modifier; reaching the dict means its validation
# (needs a time bound) passed, so this also covers the accepted case.
check bound_accrued_set     1 [bound accrued --accrued-cost --since 7d --keyword x]
check bound_accrued_default 0 [bound accrued --keyword x]

# selection_snapshot_for clears the until ceiling (so an accrued pass keeps a
# session revived after it) while preserving the since floor and under-scope.
set sel [::questlog::cli::main::selection_snapshot_for [dict create since 7d until 2d under /x one_turn 0]]
check sel_clears_until "" [dict get $sel until]
check sel_keeps_since 7d  [dict get $sel since]
check sel_keeps_under /x  [dict get $sel under]

# ---- eval_tree: the truth table for (A AND B) OR C -------------------------
# effsat is a dict leaf-id -> effective truth; leaves 0,1,2 are A,B,C.
set t [dict get [tree --keyword A --keyword B --or --keyword C] tree]
check eval_AB    1 [::questlog::match::eval_tree $t {0 1 1 1 2 0}] ;# A,B true
check eval_C     1 [::questlog::match::eval_tree $t {0 0 1 0 2 1}] ;# C true
check eval_Aonly 0 [::questlog::match::eval_tree $t {0 1 1 0 2 0}] ;# A only
check eval_none  0 [::questlog::match::eval_tree $t {0 0 1 0 2 0}]

# ---- worked examples end to end through scan_file --------------------------
# One fixture session carrying prose, tool calls and a tool result.
set fix [file join [file dirname [info script]] _grammar_fixture.jsonl]
set fh [open $fix w]
chan configure $fh -encoding utf-8 -translation lf
puts $fh {{"type":"user","cwd":"/tmp/p","timestamp":"2026-06-01T10:00:00Z","message":{"content":"please add auth token refresh and a timeout"}}}
puts $fh {{"type":"assistant","message":{"content":[{"type":"text","text":"I will write tests for the auth flow"},{"type":"tool_use","name":"Read","input":{"file_path":"config.tcl"}}]}}}
puts $fh {{"type":"user","message":{"content":[{"type":"tool_result","content":"permission denied while reading"}]}}}
puts $fh {{"type":"assistant","message":{"content":[{"type":"text","text":"TODO handle the refresh path"},{"type":"tool_use","name":"Edit","input":{"file_path":"config.tcl","old_string":"x","new_string":"y"}}]}}}
close $fh

# Does the session qualify for this query? (matches non-empty after scan_file)
proc q {args} {
    set clauses [dict get [::questlog::cli::main::parse_query $args] clauses]
    lassign [::questlog::match::scan_file $::fix $clauses] row m
    return [expr {[llength $m] > 0}]
}

check ex_and_all_three   1 [q --keyword auth --keyword token --keyword refresh]
check ex_and_one_missing 0 [q --keyword auth --keyword nonexistent]
check ex_region_prose    1 [q --keyword:user,assistant timeout]
check ex_region_excludes 0 [q --keyword:tool-result timeout]
check ex_or_either       1 [q --keyword TODO --or --keyword NOPE]
check ex_or_neither      0 [q --keyword NOPE1 --or --keyword NOPE2]
check ex_not_subtracts   1 [q --keyword tests --not --keyword flaky]
check ex_not_excludes    0 [q --keyword tests --not --keyword auth]
check ex_tool_result     1 [q {--keyword:tool-result} {permission denied}]
check ex_tool_result_not 0 [q {--keyword:user} {permission denied}]
check ex_tool_read       1 [q --tool:read config.tcl]
check ex_tool_read_miss  0 [q --tool:read nonexist.tcl]
check ex_tool_or         1 [q --tool:edit config.tcl --or --tool:read other.tcl]
# Session-wide conjunction across records: auth (user, line 1) and TODO
# (assistant, line 4) both in the same session, not the same turn.
check ex_cross_record    1 [q --keyword:user auth --keyword:assistant TODO]

file delete $fix

# ---- query error paths (exit through usage, so run the real launcher) ------
proc cli_err {args} {
    set ef [file join [file dirname [info script]] _grammar_err.txt]
    catch {exec [file join $::ROOT questlog] --json {*}$args 2>$ef}
    set h [open $ef r]; set t [read $h]; close $h
    file delete $ef
    return $t
}
check err_grouping  1 [string match {*grouping is not supported*} [cli_err "("]]
check err_ambig_rgn 1 [string match {*ambiguous region*}          [cli_err --keyword:tool x]]
check err_or_edge   1 [string match {*--or needs a clause*}       [cli_err --or --keyword x]]
check err_not_edge  1 [string match {*--not has no following*}    [cli_err --keyword x --not]]
check err_until_bad 1 [string match {*--until: invalid*}          [cli_err --until 3x --keyword x]]
check err_accrued_no_bound 1 [string match {*--accrued-cost needs a time bound*} [cli_err --accrued-cost --keyword x]]
check err_accrued_all      1 [string match {*--accrued-cost needs a time bound*} [cli_err --accrued-cost --since all --keyword x]]

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
