#!/usr/bin/env tclsh9.0
# Tests for the clause grammar: region parsing (lib/search.tcl parse_regions),
# the argv parser (cli/commandline.tcl parse) and the boolean tree its clauses fold
# into (cli/main.tcl fold), the tree evaluator (lib/match.tcl eval_tree), and the
# issue's worked examples end to end through scan_file on a fixture. The query
# error paths are checked against the real launcher, since they exit through
# usage.
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
# The grammar declares its own version, and only what the parser and scan_file
# need is sourced: not lib/path.tcl (it renames `file` to guard deletes, which
# would block this test's fixture cleanup), nor the Scan/cost layer (run's
# concern, not the grammar's). cli/commandline.tcl calls path::canon_dir for --subtree
# only, which no case here exercises.
set QUESTLOG_VERSION 0

source [file join $ROOT config.tcl]
source [file join $ROOT lib scan.tcl]
source [file join $ROOT lib jsonl.tcl]
source [file join $ROOT lib match.tcl]
source [file join $ROOT lib search.tcl]
source [file join $ROOT cli commandline.tcl]
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

# ---- the parsed clauses, folded into the boolean tree ----------------------
# Every query here is a headless one: --or, --not and a :regions suffix ask for
# an output flag, since the window has no control for them.
proc tree {args} {
    return [::questlog::cli::main::fold [::questlog::cli::commandline::parse [linsert $args 0 --json]]]
}

# Adjacency ANDs, --or splits OR-groups: A B --or C is (A AND B) OR C.
check tree_precedence \
    {leaves {{kind keyword needle A regions {} neg 0} {kind keyword needle B regions {} neg 0} {kind keyword needle C regions {} neg 0}} tree {t or nodes {{t and nodes {{t leaf id 0} {t leaf id 1}}} {t and nodes {{t leaf id 2}}}}} nocase 1} \
    [tree --keyword A --keyword B --or --keyword C]

# --not negates the next leaf only (neg flag on the leaf).
check tree_not_flag {0 1} [lmap l [dict get [tree --keyword A --not --keyword B] leaves] { dict get $l neg }]

# A region suffix rides on the leaf; --case clears nocase.
check tree_regions {tool_result} [dict get [lindex [dict get [tree --keyword:tool-result x] leaves] 0] regions]
check tree_case    0 [dict get [tree --case --keyword x] nocase]
check tree_tool    {kind tool sel file spec read value c.tcl neg 0} \
    [lindex [dict get [tree --tool:read c.tcl] leaves] 0]

# ---- the global bounds ride beside the clause tree -------------------------
proc bound {key args} {
    return [dict get [::questlog::cli::commandline::parse [linsert $args 0 --json]] $key]
}
check bound_since   7d         [bound since --since 7d --keyword x]
check bound_until   2026-04-01 [bound until --until 2026-04-01 --keyword x]
check bound_until_default "" [bound until --keyword x]
# --accrued-cost is a boolean modifier; reaching the dict means its validation
# (needs a time bound) passed, so this also covers the accepted case.
check bound_accrued_set     1 [bound accrued --accrued-cost --since 7d --keyword x]
check bound_accrued_default 0 [bound accrued --keyword x]

# selection_snapshot_for clears the until ceiling (so an accrued pass keeps a
# session revived after it) while preserving the since floor and subtree scope.
set sel [::questlog::cli::main::selection_snapshot_for [dict create since 7d until 2d subtree /x]]
check sel_clears_until "" [dict get $sel until]
check sel_keeps_since 7d  [dict get $sel since]
check sel_keeps_subtree /x  [dict get $sel subtree]

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
puts $fh {{"type":"assistant","message":{"content":[{"type":"text","text":"He said \"hello world\" to me and C:\\Users\\here stayed"}]}}}
puts $fh {{"type":"assistant","message":{"content":[{"type":"text","text":"Anchored start of block"}]}}}
close $fh

# Does the session qualify for this query? (matches non-empty after scan_file)
proc q {args} {
    set clauses [::questlog::cli::main::fold [::questlog::cli::commandline::parse [linsert $args 0 --json]]]
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
# A path tail sits on a name boundary: "fig.tcl" is a character suffix of
# config.tcl but not a filename; an extension needle may land mid-name.
check ex_tail_boundary 0 [q --tool:read fig.tcl]
check ex_tail_ext      1 [q --tool:read .tcl]
# Tool-name canonicalisation covers the newer built-ins.
check tool_agent {kind tool sel tool spec Agent value {} neg 0} \
    [lindex [dict get [tree --tool:agent ""] leaves] 0]
check tool_multiedit Agent [dict get [lindex [dict get [tree --tool:AGENT x] leaves] 0] spec]
# Session-wide conjunction across records: auth (user, line 1) and TODO
# (assistant, line 4) both in the same session, not the same turn.
check ex_cross_record    1 [q --keyword:user auth --keyword:assistant TODO]

# The raw line is JSON-encoded, so needles bearing a quote or backslash and
# anchored regexes cannot be gated against it; they must still match (and a
# --not over them must still exclude).
check ex_quoted_needle   1 [q --keyword {said "hello}]
check ex_quoted_nocase   1 [q --keyword {SAID "HELLO}]
check ex_quoted_not      0 [q --keyword auth --not --keyword {said "hello}]
check ex_backslash       1 [q --keyword {C:\Users}]
check ex_regex_anchor    1 [q --regex {^Anchored}]
check ex_regex_anchor_not 0 [q --keyword auth --not --regex {^Anchored}]

file delete $fix

# ---- scan_file row fields over an array-content (image-bearing) prompt -----
set fix2 [file join [file dirname [info script]] _grammar_fixture2.jsonl]
set fh [open $fix2 w]
chan configure $fh -encoding utf-8 -translation lf
puts $fh {{"type":"user","message":{"role":"user","content":[{"type":"text","text":"fix the \"blue\" widget"},{"type":"image","source":{}}]},"timestamp":"2026-06-01T10:00:00Z"}}
puts $fh {{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"irrelevant"}]}}}
close $fh
lassign [::questlog::match::scan_file $fix2 \
    [::questlog::cli::main::fold [::questlog::cli::commandline::parse {--keyword widget}]]] row2 m2
check arr_nturns  1 [dict get $row2 nturns]
check arr_preview {fix the "blue" widget} [dict get $row2 first_user]
file delete $fix2

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
check err_bad_regex 1 [string match {*invalid pattern*}           [cli_err --regex "foo("]]
check err_limit_nan 1 [string match {*--limit: not a count*}       [cli_err --limit abc --keyword x]]
check err_not_flag  1 [string match {*--not must be followed*}     [cli_err --not --since 7d --keyword x]]
check err_all_neg   1 [string match {*at least one positive*}      [cli_err --not --keyword x]]
check err_accrued_no_bound 1 [string match {*--accrued-cost needs a time bound*} [cli_err --accrued-cost --keyword x]]
check err_accrued_all      1 [string match {*--accrued-cost needs a time bound*} [cli_err --accrued-cost --since all --keyword x]]
check err_not_not   1 [string match {*--not --not is not allowed*}  [cli_err --not --not --keyword x]]
check err_two_since 1 [string match {*--since given twice*}         [cli_err --since 7d --since 8d --keyword x]]
check err_two_modes 1 [string match {*choose one output*}           [cli_err --shortstat --keyword x]]
check err_font_headless 1 [string match {*--font is not available with --json*} [cli_err --font Sans --keyword x]]

# Every needle is written to a flag - there is no positional form - and each
# flag has one spelling, so a plausible near-miss is an error, not a synonym.
check err_bare_arg  1 [string match {*unexpected argument 'bareword'*} [cli_err bareword]]
foreach nearmiss {--kw --search --rx --pattern --cmd -h -v} {
    check err_nearmiss$nearmiss 1 [string match "*unknown option: $nearmiss*" [cli_err $nearmiss x]]
}

# ---- the GUI answers the same query, and refuses what it cannot hold --------
# Without an output flag the query seeds the window, so a clause with no widget
# behind it is named rather than dropped. Run without --json (and without a
# display: the parse rejects before Tk is ever sourced).
proc gui_err {args} {
    set ef [file join [file dirname [info script]] _grammar_err.txt]
    catch {exec [file join $::ROOT questlog] {*}$args 2>$ef}
    set h [open $ef r]; set t [read $h]; close $h
    file delete $ef
    return $t
}
check gui_err_or      1 [string match {*--or needs --json or --markdown or --shortstat*}    [gui_err --keyword a --or --keyword b]]
check gui_err_not     1 [string match {*--not needs --json or --markdown or --shortstat*}   [gui_err --not --keyword a --keyword b]]
check gui_err_regions 1 [string match {*:regions suffix needs --json*}        [gui_err --keyword:user a]]
check gui_err_until   1 [string match {*--until needs --json or --markdown or --shortstat*} [gui_err --until 7d --keyword a]]
check gui_err_limit   1 [string match {*--limit needs --json or --markdown or --shortstat*} [gui_err --limit 5 --keyword a]]
check gui_err_lmatch  1 [string match {*--limit-matches needs --json*}        [gui_err --limit-matches 0 --keyword a]]
check gui_err_accrued 1 [string match {*--accrued-cost needs --json*}         [gui_err --accrued-cost --since 7d --keyword a]]
check gui_err_quote   1 [string match {*double quote needs --json*}           [gui_err --keyword {say "hi}]]

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
