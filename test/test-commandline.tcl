#!/usr/bin/env tclsh9.0
# Tests for cli/commandline.tcl: the neutral query dict argv folds into, and the
# clauses the grammar refuses before a window opens, because the window has no
# control for them. Pure and Tk-free. The error paths that print and exit are
# driven from the real launcher in test-search-grammar.tcl; these drive `parse`,
# which throws instead, so the accepted shapes and the refusals both read here.
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
set QUESTLOG_VERSION 0
set ::questlog_config_only 1; source [file join $ROOT questlog]
# --subtree canonicalises its directory through lib/path.tcl, which wraps `file`
# to guard deletes under the projects store. This test writes nothing, so the
# guard costs it nothing.
source [file join $ROOT lib path.tcl]
source [file join $ROOT lib scan.tcl]
source [file join $ROOT lib match.tcl]
source [file join $ROOT lib search.tcl]
source [file join $ROOT cli commandline.tcl]

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
proc parse {args} { return [::questlog::cli::commandline::parse $args] }
# The refusal a query meets, or "" when it is answered.
proc refusal {args} {
    if {[catch {::questlog::cli::commandline::parse $args} e]} { return $e }
    return ""
}

# ---- mode: an output flag chooses the answer, absence opens the window ------
check mode_default   gui       [dict get [parse --keyword x] mode]
check mode_json      json      [dict get [parse --json --keyword x] mode]
check mode_markdown  markdown  [dict get [parse --markdown --keyword x] mode]
check mode_shortstat shortstat [dict get [parse --shortstat --keyword x] mode]
# Two output flags conflict: neither wins, the query is refused.
check mode_conflict {choose one output: --json or --markdown} \
    [refusal --json --markdown --keyword x]

# ---- groups: an OR-of-ANDs of clause dicts, in the order written ------------
# A B --or C is (A AND B) OR C: two groups, the first holding two clauses.
set g [dict get [parse --json --keyword A --keyword B --or --keyword C] groups]
check groups_count   2 [llength $g]
check group_one_size 2 [llength [lindex $g 0]]
check group_two_size 1 [llength [lindex $g 1]]
check clause_keyword {kind keyword value A regions {} neg 0} [lindex $g 0 0]

# --not rides on the clause that follows it, and on no other.
check clause_neg {0 1} \
    [lmap c [lindex [dict get [parse --json --keyword A --not --keyword B] groups] 0] { dict get $c neg }]

# A :regions suffix rides on the clause; a tool clause carries its selector.
check clause_regions {tool_result} \
    [dict get [lindex [dict get [parse --json --keyword:tool-result x] groups] 0 0] regions]
check clause_tool_file {kind tool selkind file selspec read value c.tcl neg 0} \
    [lindex [dict get [parse --tool:read c.tcl] groups] 0 0]
check clause_tool_name Agent \
    [dict get [lindex [dict get [parse --tool:agent ""] groups] 0 0] selspec]

# ---- bounds ride outside the tree, with their unset values -----------------
check bound_since_default   ""  [dict get [parse --keyword x] since]
check bound_until_default   ""  [dict get [parse --keyword x] until]
check bound_limit_default   0   [dict get [parse --keyword x] limit]
check bound_lmatch_default  -1  [dict get [parse --keyword x] limit_matches]
check bound_nocase_default  1   [dict get [parse --keyword x] nocase]
check bound_case            0   [dict get [parse --case --keyword x] nocase]
check bound_limit_all       0   [dict get [parse --json --limit all --keyword x] limit]
check bound_accrued         1   [dict get [parse --json --accrued-cost --since 7d --keyword x] accrued]
check bound_font            Sans [dict get [parse --font Sans --keyword x] font]

# ---- context: -A/-B/-C and their long aliases fold to ctx_before/ctx_after --
check ctx_default {0 0} \
    [list [dict get [parse --json --keyword x] ctx_before] [dict get [parse --json --keyword x] ctx_after]]
check ctx_A {0 3} \
    [list [dict get [parse --json -A 3 --keyword x] ctx_before] [dict get [parse --json -A 3 --keyword x] ctx_after]]
check ctx_B {2 0} \
    [list [dict get [parse --json -B 2 --keyword x] ctx_before] [dict get [parse --json -B 2 --keyword x] ctx_after]]
check ctx_C {4 4} \
    [list [dict get [parse --json -C 4 --keyword x] ctx_before] [dict get [parse --json -C 4 --keyword x] ctx_after]]
check ctx_long {5 6} \
    [list [dict get [parse --json --before-context 5 --after-context 6 --keyword x] ctx_before] \
          [dict get [parse --json --before-context 5 --after-context 6 --keyword x] ctx_after]]
check ctx_long_context {7 7} \
    [list [dict get [parse --json --context 7 --keyword x] ctx_before] [dict get [parse --json --context 7 --keyword x] ctx_after]]
# Occurrence order: a later -A overrides the after side -C set (grep-like).
check ctx_C_then_A {3 5} \
    [list [dict get [parse --json -C 3 -A 5 --keyword x] ctx_before] [dict get [parse --json -C 3 -A 5 --keyword x] ctx_after]]
# Context is a headless-output feature, valid in markdown too.
check ctx_markdown {1 1} \
    [list [dict get [parse --markdown -C 1 --keyword x] ctx_before] [dict get [parse --markdown -C 1 --keyword x] ctx_after]]
# ... but the GUI and the totals have no per-hit context to draw.
check ctx_gui_refused {-A needs --json or --markdown (the totals and the GUI show no per-hit context)} \
    [refusal -A 3 --keyword x]
check ctx_shortstat_refused {-C needs --json or --markdown (the totals and the GUI show no per-hit context)} \
    [refusal --shortstat -C 3 --keyword x]
# The count must be a count.
check ctx_not_a_count {-B: not a count: 'x' (want a non-negative integer)} \
    [refusal --json -B x --keyword y]

# ---- dialogue: a conversation-only modifier on --json/--markdown -----------
check dialogue_default   0 [dict get [parse --json --keyword x] dialogue]
check dialogue_json      1 [dict get [parse --json --dialogue --keyword x] dialogue]
check dialogue_markdown  1 [dict get [parse --markdown --dialogue --keyword x] dialogue]
# A modifier, not an output mode: refused where there is no transcript to reduce.
check dialogue_shortstat_refused \
    {--dialogue needs --json or --markdown (a totals summary has no transcript to reduce)} \
    [refusal --shortstat --dialogue --keyword x]
check dialogue_gui_refused \
    {--dialogue needs --json or --markdown (a totals summary has no transcript to reduce)} \
    [refusal --dialogue --keyword x]

# An empty query is legal: it opens the window on the whole corpus.
check empty_groups {} [dict get [parse] groups]
check empty_mode   gui [dict get [parse] mode]

# ---- the window holds a query of the clauses and bounds it has controls for -
check gui_plain    "" [refusal --keyword x]
check gui_phrase   "" [refusal --keyword {two words}]
check gui_tool     "" [refusal --tool:edit lib/scan.tcl]
check gui_regex    "" [refusal --regex {^foo}]
check gui_since    "" [refusal --since 30d --keyword x]
check gui_case     "" [refusal --case --keyword x]
check gui_subtree  "" [refusal --subtree / --keyword x]
# `any` restricts nothing, so it asks the window for nothing it lacks.
check gui_regions_any "" [refusal --keyword:any x]

# ... and refuses what has no control behind it, naming the flag that would
# have answered the query as asked.
check gui_or      {--or needs --json or --markdown or --shortstat (the GUI ANDs its criteria)} \
    [refusal --keyword a --or --keyword b]
check gui_not     {--not needs --json or --markdown or --shortstat (the GUI has no negated criterion)} \
    [refusal --not --keyword a --keyword b]
check gui_regions {a :regions suffix needs --json or --markdown or --shortstat (the GUI's regions selector is one setting for the whole search)} \
    [refusal --keyword:user x]
check gui_until   {--until needs --json or --markdown or --shortstat}   [refusal --until 7d --keyword x]
check gui_limit   {--limit needs --json or --markdown or --shortstat}   [refusal --limit 5 --keyword x]
# 0 snippets is a request, not an absence, so it is refused like any other cap.
check gui_lmatch  {--limit-matches needs --json or --markdown or --shortstat} \
    [refusal --limit-matches 0 --keyword x]
check gui_accrued {--accrued-cost needs --json or --markdown or --shortstat} \
    [refusal --accrued-cost --since 7d --keyword x]
# The search field quotes a phrase with ", so a needle holding one cannot be
# written into it; the headless matcher takes the needle literally.
check gui_quote {a keyword holding a double quote needs --json or --markdown or --shortstat (the search field quotes phrases with it)} \
    [refusal --keyword {say "hi}]
# The reading font is the window's, and a headless run has nothing to render.
check headless_font {--font is not available with --json (the reading font is the GUI's)} \
    [refusal --json --font Sans --keyword x]

# ---- the query the fold builds must be readable end to end -----------------
# Every declared option is read by the fold; one that were not would be
# accepted, printed in the help, and inert.
check no_inert_option "" [refusal --json --keyword a --regex b --tool:read c \
    --or --not --keyword d --since 7d --until 1d --subtree / --accrued-cost \
    --limit 3 --limit-matches 2 --case --debug 1]

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
