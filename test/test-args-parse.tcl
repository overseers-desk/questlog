#!/usr/bin/env tclsh9.0
# Tests for cli/args.tcl: the neutral query dict argv parses into, and the
# GUI-mappability gate that decides whether a query can seed the window or needs
# an output flag. Pure and Tk-free - the error paths that exit through usage are
# covered from the real launcher in test-search-grammar.tcl; these drive the
# procs directly, so only the accepted shapes are asserted here.
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT config.tcl]
source [file join $ROOT lib filter.tcl]
source [file join $ROOT lib match.tcl]
source [file join $ROOT lib search.tcl]
source [file join $ROOT cli args.tcl]

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
proc parse {args} { return [::questlog::cli::args::parse $args] }
# 1 iff the window can show the whole query: the gate names its objection, and
# no objection is the empty string.
proc mappable {args} {
    return [expr {[::questlog::cli::args::gui_objection [::questlog::cli::args::parse $args]] eq ""}]
}

# ---- mode: an output flag chooses the answer, absence opens the window ------
check mode_default   gui       [dict get [parse --keyword x] mode]
check mode_json      json      [dict get [parse --json --keyword x] mode]
check mode_shortstat shortstat [dict get [parse --shortstat --keyword x] mode]

# ---- groups: an OR-of-ANDs of clause dicts, in the order written ------------
# A B --or C is (A AND B) OR C: two groups, the first holding two clauses.
set g [dict get [parse --keyword A --keyword B --or --keyword C] groups]
check groups_count   2 [llength $g]
check group_one_size 2 [llength [lindex $g 0]]
check group_two_size 1 [llength [lindex $g 1]]
check clause_keyword {kind keyword value A regions {} neg 0} [lindex $g 0 0]

# --not rides on the clause that follows it, and on no other.
check clause_neg {0 1} \
    [lmap c [lindex [dict get [parse --keyword A --not --keyword B] groups] 0] { dict get $c neg }]

# A :regions suffix rides on the clause; a tool clause carries its selector.
check clause_regions {tool_result} \
    [dict get [lindex [dict get [parse --keyword:tool-result x] groups] 0 0] regions]
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
check bound_limit_all       0   [dict get [parse --limit all --keyword x] limit]
check bound_accrued         1   [dict get [parse --accrued-cost --since 7d --keyword x] accrued]
check bound_font            Sans [dict get [parse --font Sans --keyword x] font]

# An empty query is legal: it opens the window on the whole corpus.
check empty_groups {} [dict get [parse] groups]
check empty_mode   gui [dict get [parse] mode]

# ---- the GUI holds a query of clauses and bounds it has controls for -------
check map_plain    1 [mappable --keyword x]
check map_phrase   1 [mappable --keyword {two words}]
check map_tool     1 [mappable --tool:edit lib/scan.tcl]
check map_regex    1 [mappable --regex {^foo}]
check map_since    1 [mappable --since 30d --keyword x]
check map_case     1 [mappable --case --keyword x]
check map_limit_0  1 [mappable --limit 0 --keyword x]
check map_regions_any 1 [mappable --keyword:any x]

# ... and refuses what has no control behind it.
check map_or       0 [mappable --keyword a --or --keyword b]
check map_not      0 [mappable --not --keyword a --keyword b]
check map_regions  0 [mappable --keyword:user x]
check map_until    0 [mappable --until 7d --keyword x]
check map_limit    0 [mappable --limit 5 --keyword x]
# 0 snippets is a request, not an absence, so it is refused like any other cap.
check map_lmatch_0 0 [mappable --limit-matches 0 --keyword x]
check map_accrued  0 [mappable --accrued-cost --since 7d --keyword x]
# The search field quotes a phrase with ", so a needle holding one cannot be
# written into it; the headless matcher takes the needle literally.
check map_quote    0 [mappable --keyword {say "hi}]

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
