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

# ---- the parse pass anchors matches on true physical lines --------------------------
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

# ---- glob metachars in a single nocase keyword go through gate_pat verbatim --
# A single raw-safe keyword under nocase takes the string-match -nocase gate.
# gate_pat escapes each glob metacharacter, so the needle matches only its
# literal text: a `*`/`?`/`[` needle must hit the literal and miss the glob
# expansion (content `axxb` for needle `a*b`). Case folds both ways. A needle
# with a backslash is raw-unsafe, routes to always_candidate, and still hits.
foreach {tag needle hitline missline} {
    star  a*b {say A*B loud} {say axxb loud}
    quest a?b {an A?B here}  {an axb here}
    brack {x[y]} {see X[Y] now} {see xy now}
} {
    set L_g [::questlog::match::kw_leaf $needle {} 0]
    set f_gh [fixture glob_${tag}_h [list [format {{"type":"user","message":{"role":"user","content":"%s"}}} $hitline]]]
    set f_gm [fixture glob_${tag}_m [list [format {{"type":"user","message":{"role":"user","content":"%s"}}} $missline]]]
    check glob_${tag}_literal_hit 1 [nmatches $f_gh [and_clauses [list $L_g] 1]]
    check glob_${tag}_no_expand   0 [nmatches $f_gm [and_clauses [list $L_g] 1]]
}
set L_bs [::questlog::match::kw_leaf {a\b} {} 0]
set f_bs [fixture glob_bs [list {{"type":"user","message":{"role":"user","content":"path a\\b end"}}}]]
check glob_backslash_hit 1 [nmatches $f_bs [and_clauses [list $L_bs] 1]]

# ---- several fold literals share one tolower; a lone (?i) factor folds itself -
# Two mixed-case keywords under nocase land in kw_needles (>1, the shared-fold
# loop); the AND also carries one (?i) regex whose single factor takes the
# match -nocase path. A match needs all three folded correctly; dropping gamma
# from the line fails the AND.
set L_ka  [::questlog::match::kw_leaf Alpha {} 0]
set L_kb  [::questlog::match::kw_leaf Beta {} 0]
set L_rg  [::questlog::match::rx_leaf {(?i)gamma} {} 0]
set f_abc [fixture multifold_hit  [list {{"type":"user","message":{"role":"user","content":"ALPHA and beta then GaMmA"}}}]]
set f_ab  [fixture multifold_miss [list {{"type":"user","message":{"role":"user","content":"ALPHA and beta only"}}}]]
check multifold_all_present [expr {[nmatches $f_abc [and_clauses [list $L_ka $L_kb $L_rg] 1]] > 0}] 1
check multifold_gamma_gone  0 [nmatches $f_ab  [and_clauses [list $L_ka $L_kb $L_rg] 1]]

# ---- a non-ASCII keyword is raw-unsafe, so every line stays a candidate ------
# héllo cannot gate the encoded line (the writer stores the é as é), so the
# needle routes to always_candidate; the parse pass decodes the escape and the
# keyword still matches.
set L_kacc [::questlog::match::kw_leaf "héllo" {} 0]
set f_kesc [fixture kw_esc [list {{"type":"user","message":{"role":"user","content":"oh h\u00e9llo there"}}}]]
check kw_rawunsafe_candidate 1 [nmatches $f_kesc [and_clauses [list $L_kacc] 1]]

# ==== retirement: satisfied-and-capped leaves stop the leaf walk ============
# A cap rides in on the clauses dict (snippet_cap / snippet_cap_child); the CLI
# injects it, the GUI never does. Every case asserts emitted RESULTS: the buffer
# keeps the earliest cap of hits by line, so a capped scan's snippets are the
# uncapped scan's first-cap prefix, byte for byte.
proc matches_of {path clauses} {
    lassign [::questlog::match::scan_file $path $clauses] _ matches
    return $matches
}
# A body line carrying $needle, tagged $tag so each line's snippet differs.
proc bodyline {tag needle} {
    return [format {{"type":"user","message":{"role":"user","content":"%s %s here"}}} $tag $needle]
}

# ---- cap honoured: exactly the earliest cap of matches, dicts identical ------
# Five body lines match; cap 2 keeps the two earliest, and those two dicts equal
# the uncapped run's first two. A single raw-safe keyword gates, so this drives
# the gated pass-2 break.
set five [list [bodyline one target] [bodyline two target] [bodyline three target] \
    [bodyline four target] [bodyline five target]]
set f_five [fixture five $five]
set L_target [::questlog::match::kw_leaf target {} 0]
set C_uncapped [and_clauses [list $L_target] 1]
set C_cap2 $C_uncapped; dict set C_cap2 snippet_cap 2
check cap_uncapped_count 5 [llength [matches_of $f_five $C_uncapped]]
set capped [matches_of $f_five $C_cap2]
check cap_honoured_count 2 [llength $capped]
check cap_prefix_identical [lrange [matches_of $f_five $C_uncapped] 0 1] $capped

# ---- cap honoured on the single combined pass (no gate) ---------------------
# A non-ASCII keyword is raw-unsafe -> always_candidate, no positive gate, so
# gate_on is 0 and scan_file runs one combined pass; retirement there sets
# do_leaves 0 and reads on for the row. Same earliest-two result.
set five_acc [list [bodyline one héllo] [bodyline two héllo] [bodyline three héllo] \
    [bodyline four héllo] [bodyline five héllo]]
set f_five_acc [fixture five_acc $five_acc]
set L_acc [::questlog::match::kw_leaf "héllo" {} 0]
set C_acc_un [and_clauses [list $L_acc] 1]
set C_acc_cap $C_acc_un; dict set C_acc_cap snippet_cap 2
check cap_singlepass_count 2 [llength [matches_of $f_five_acc $C_acc_cap]]
check cap_singlepass_prefix [lrange [matches_of $f_five_acc $C_acc_un] 0 1] \
    [matches_of $f_five_acc $C_acc_cap]

# ---- snippet_cap_child selects the per-subagent cap on a child transcript ----
# is_child is derived from a `.../subagents/` parent dir. With the session cap
# set wide (would keep all five) and the child cap at 2, a child file honours
# the child cap - proof scan_file picks the cap by is_child.
set childdir [file join $fixdir sess-uuid subagents]
file mkdir $childdir
set childpath [file join $childdir agent-c.jsonl]
set cfh [open $childpath w]
chan configure $cfh -encoding utf-8 -translation lf
foreach l $five { puts $cfh $l }
close $cfh
set C_child $C_uncapped
dict set C_child snippet_cap 10
dict set C_child snippet_cap_child 2
lassign [::questlog::match::scan_file $childpath $C_child] crow cmatches
check child_is_child 1 [dict get $crow is_child]
check child_cap_honoured 2 [llength $cmatches]

# ---- a satisfied names leaf blocks retirement; the early name hit survives ---
# A names leaf never satisfies in the body walk, so while it is unsettled the cap
# cannot fire. The name hit anchors on the title line (line 1) and the body hits
# follow; capped and uncapped emit the identical prefix, name hit first.
set NAMEQUEST {{"type":"ai-title","aiTitle":"the-quest-marker","sessionId":"s1"}}
set namebody [list $NAMEQUEST [bodyline two target] [bodyline three target] \
    [bodyline four target] [bodyline five target] [bodyline six target]]
set f_nb [fixture namebody $namebody]
set L_name [::questlog::match::kw_leaf marker {names} 0]
set C_nb_un [and_clauses [list $L_name $L_target] 1]
set C_nb_cap $C_nb_un; dict set C_nb_cap snippet_cap 2
set nb_un [matches_of $f_nb $C_nb_un]
set nb_cap [matches_of $f_nb $C_nb_cap]
check names_block_retire_identical $nb_un $nb_cap
check names_hit_anchors_first names [dict get [lindex $nb_cap 0] btype]

# ---- a names leaf the file never shows settles via possible==0 ----------
# The names needle appears on no raw line, so the parse pass marks its leaf impossible
# and settles it; the sibling OR-branch then drives retirement normally. The
# session matches through the sibling, its snippets the uncapped first-cap prefix.
set sib [list [bodyline one target] [bodyline two target] [bodyline three target] \
    [bodyline four target] [bodyline five target]]
set f_sib [fixture sib $sib]
set L_absent [::questlog::match::kw_leaf absentname {names} 0]
set C_or_un [or_clauses [list [list $L_absent] [list $L_target]] 1]
set C_or_cap $C_or_un; dict set C_or_cap snippet_cap 2
set or_un [matches_of $f_sib $C_or_un]
set or_cap [matches_of $f_sib $C_or_cap]
check names_possible0_matches 2 [llength $or_cap]
check names_possible0_prefix [lrange $or_un 0 1] $or_cap

# ---- a names leaf whose needle sits only in body content stays unsatisfied ---
# names:novel AND body:target; `novel` appears in body text but never as a worn
# name, so its literal is present (the gate keeps the leaf possible), it never
# settles, retirement never fires, and the AND fails - zero matches.
set foobar [list [bodyline one target] [bodyline two target] \
    [bodyline {with novel} target] [bodyline four target] \
    [bodyline five target] [bodyline six target]]
set f_foobar [fixture foobar $foobar]
set L_novel [::questlog::match::kw_leaf novel {names} 0]
set C_fb [and_clauses [list $L_novel $L_target] 1]
dict set C_fb snippet_cap 2
check names_bodyonly_zero 0 [llength [matches_of $f_foobar $C_fb]]

# ---- a negated leaf (stopword) must be seen before retirement, past the cap ---------
# target AND NOT stopword; target fills the buffer past the cap on early lines,
# but the negated leaf is unsettled until stopword is read, so retirement holds
# off, stopword is detected, and the AND fails.
set negfile [list [bodyline one target] [bodyline two target] [bodyline three target] \
    [bodyline four target] [bodyline five target] \
    {{"type":"user","message":{"role":"user","content":"here comes stopword now"}}}]
set f_neg [fixture negfile $negfile]
set L_stopneg [::questlog::match::kw_leaf stopword {} 1]
set C_neg [and_clauses [list $L_target $L_stopneg] 1]
dict set C_neg snippet_cap 2
check neg_seen_beyond_cap 0 [llength [matches_of $f_neg $C_neg]]

# ---- the same negation with Z absent: the tree holds, matches emit ----------
set negclean [list [bodyline one target] [bodyline two target] [bodyline three target]]
set f_negc [fixture negclean $negclean]
check neg_absent_match 1 [expr {[llength [matches_of $f_negc $C_neg]] > 0}]

file delete -force $fixdir

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
