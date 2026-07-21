#!/usr/bin/env tclsh9.0
# Tests for scan_file's raw-line pre-gates around regex leaves. The gates are
# necessary-condition filters only, so every case asserts match RESULTS, and
# each fixture is built so a gate that over-filters (a negated factor dropped,
# a (?i) factor tested case-sensitively, a factor-less pattern gated) flips
# the result, not just the work done. Pure and Tk-free. Run:
#   tclsh9.0 test/test-scan-gate.tcl
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
set ::questlog_config_only 1; source [file join $ROOT questlog]
package require logman
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

# A fixture session written from a list of raw jsonl lines; returns its path.
set fixdir [file join [file dirname [info script]] _gate_fixtures]
file mkdir $fixdir
proc fixture {name lines} {
    set path [file join $::fixdir $name.jsonl]
    set fh [open $path w]
    chan configure $fh -encoding utf-8 -translation lf
    foreach l $lines { puts $fh $l }
    close $fh
    return $path
}
# An AND-tree clauses dict over pre-built leaves.
proc and_clauses {leaves nocase} {
    set nodes [list]
    for {set i 0} {$i < [llength $leaves]} {incr i} {
        lappend nodes [::questlog::match::tnode_leaf $i]
    }
    return [dict create leaves $leaves \
        tree [::questlog::match::tnode_and $nodes] nocase $nocase]
}
proc nmatches {path clauses} {
    lassign [::questlog::match::scan_file $path $clauses] row matches
    return [llength $matches]
}

set TOOLLINE {{"type":"assistant","message":{"content":[{"type":"text","text":"editing now"},{"type":"tool_use","name":"Edit","input":{"file_path":"lib/busyduck.tcl","old_string":"x","new_string":"y"}}]}}}
set M2LINE   {{"type":"assistant","message":{"content":[{"type":"text","text":"the M2 core dumped"}]}}}
set PLAIN    {{"type":"user","message":{"role":"user","content":"just an ordinary prompt"}}}
set ZEBRA    {{"type":"user","message":{"role":"user","content":"a zebra walked past"}}}
set TITLE    {{"type":"ai-title","aiTitle":"the-M2-quest","sessionId":"s1"}}

set L_tool  [::questlog::match::tool_leaf file edit lib/busyduck.tcl 0]
set L_rx    [::questlog::match::rx_leaf {[^A-Za-z]M2[^A-Za-z]} {} 0]
set L_rxneg [::questlog::match::rx_leaf {[^A-Za-z]M2[^A-Za-z]} {} 1]

# ---- a factor-gated regex still hits and still misses -----------------------
set f_hit  [fixture hit  [list $PLAIN $M2LINE]]
set f_miss [fixture miss [list $PLAIN]]
check factor_hit  1 [nmatches $f_hit  [and_clauses [list $L_rx] 1]]
check factor_miss 0 [nmatches $f_miss [and_clauses [list $L_rx] 1]]

# ---- a negated regex's factor stays in the candidate gate -------------------
# The file satisfies the tool leaf and, on a line carrying nothing but the
# factor, the regex; --not over the regex must therefore fail the tree. A gate
# that drops negated factors never parses the M2 line, reads the leaf as
# unsatisfied, and inverts the file into a false positive.
set f_negtrap [fixture negtrap [list $TOOLLINE $M2LINE]]
set L_kw [::questlog::match::kw_leaf ordinary {} 0]
check neg_factor_gated 0 [nmatches $f_negtrap [and_clauses [list $L_tool $L_rxneg] 1]]
check neg_absent_hits  1 [nmatches $f_miss    [and_clauses [list $L_kw $L_rxneg] 1]]

# ---- a (?i) factor folds its own case, not the global mode ------------------
# The search is case-sensitive (nocase 0); the pattern carries its own (?i).
# The content says M2, the factor is lowered to m2, so a gate that tests it
# case-sensitively against the raw line skips the only matching record.
set L_rxi [::questlog::match::rx_leaf {(?i)m2 core} {} 0]
check own_case_hit 1 [nmatches $f_hit [and_clauses [list $L_rxi] 0]]

# ---- a pattern with no factor stays ungated ---------------------------------
set L_rxnum [::questlog::match::rx_leaf {[0-9]{4}} {} 0]
set f_year [fixture year [list {{"type":"user","message":{"content":"year 2026 ok"}}}]]
check factorless_hit  1 [nmatches $f_year [and_clauses [list $L_rxnum] 1]]
check factorless_miss 0 [nmatches $f_miss [and_clauses [list $L_rxnum] 1]]

# ---- a factor beside escaped quotes sits verbatim in the raw line -----------
set f_quoted [fixture quoted [list {{"type":"user","message":{"content":"he said \"M2\" loudly"}}}]]
check quoted_factor_hit 1 [nmatches $f_quoted [and_clauses [list $L_rx] 1]]

# ---- a factor outside the raw-safe class cannot gate the encoded line -------
# must::factor happily extracts "héllo", but the writer may store the é as a
# \u escape, so the raw line never holds the factor; the classification must
# discard it (every line a candidate) or the only matching record is skipped.
set f_esc [fixture esc [list {{"type":"user","message":{"role":"user","content":"oh h\u00e9llo there"}}}]]
set L_rxacc [::questlog::match::rx_leaf "héllo" {} 0]
check rawunsafe_factor_discarded 1 [nmatches $f_esc [and_clauses [list $L_rxacc] 1]]

# ---- the file-level gate: a hopeless file still yields its whole row --------
# A holds both literals, B only the tool path, C only the factor, D neither.
# Only A can satisfy the AND; the others are ruled out by the gate yet must
# return the same complete row a scanned-and-unsatisfied file returns, since
# the GUI publishes every row.
set f_A [fixture gateA [list $TOOLLINE $M2LINE]]
set f_B [fixture gateB [list $TOOLLINE $PLAIN]]
set f_C [fixture gateC [list $PLAIN $M2LINE]]
set f_D [fixture gateD [list $PLAIN]]
set AND2 [and_clauses [list $L_tool $L_rx] 1]
foreach {name path want} [list A $f_A 2 B $f_B 0 C $f_C 0 D $f_D 0] {
    lassign [::questlog::match::scan_file $path $AND2] row matches
    check gate_${name}_matches $want [llength $matches]
    check gate_${name}_row_kept 1 [expr {$row ne ""}]
}
# The ruled-out rows carry their fields, not blanks: the row pass ran whole.
lassign [::questlog::match::scan_file $f_B $AND2] row _
check gate_row_nturns 1 [dict get $row nturns]
check gate_row_first_user {just an ordinary prompt} [dict get $row first_user]

# ---- pass 2 anchors matches on true physical lines --------------------------
# The gated-in file is read twice; a lineno not reset for the second pass
# would shift every anchor by the file's length.
lassign [::questlog::match::scan_file $f_A $AND2] _ matches
check gate_lineoffs {1 2} [lmap m $matches {dict get $m lineoff}]

# ---- a names-region hit survives the gate -----------------------------------
# The factor appears only in the aiTitle line; the gate must count that raw
# line, and the name walk (scored at EOF from the row pass's collection)
# still lands the match.
set f_title [fixture title [list $TITLE $PLAIN]]
set L_rxnames [::questlog::match::rx_leaf {[^A-Za-z]M2[^A-Za-z]} {names} 0]
check gate_names_hit 1 [nmatches $f_title [and_clauses [list $L_rxnames] 1]]

# ---- an OR tree passes through the branch whose literals are present --------
proc or_clauses {branches nocase} {
    set leaves [list]
    set ors [list]
    foreach b $branches {
        set ands [list]
        foreach leaf $b {
            lappend ands [::questlog::match::tnode_leaf [llength $leaves]]
            lappend leaves $leaf
        }
        lappend ors [::questlog::match::tnode_and $ands]
    }
    return [dict create leaves $leaves \
        tree [::questlog::match::tnode_or $ors] nocase $nocase]
}
set L_zebra [::questlog::match::kw_leaf zebra {} 0]
set f_zebra [fixture zebra [list $ZEBRA]]
set OR2 [or_clauses [list [list $L_tool $L_rx] [list $L_zebra]] 1]
check gate_or_other_branch 1 [nmatches $f_zebra $OR2]
check gate_or_no_branch    0 [nmatches $f_D    $OR2]
check gate_or_and_branch   2 [nmatches $f_A    $OR2]

file delete -force $fixdir

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
