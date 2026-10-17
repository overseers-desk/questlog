#!/usr/bin/env tclsh9.0
# Rolled-back branches: logman's mark_branches finds the turns a rewind
# abandoned from the uuid tree, mark_turn_runs keeps their boundaries out of
# its draft runs, and mark_turns fills each branch's header facts. Fixtures
# are real record shapes in file order, built by `R`, each record linked to
# its parent by uuid.
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
set ::questlog_config_only 1; source [file join $ROOT questlog]
package require logman

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

# One record of kind k with uuid u under parent p ("" a root), stamped a
# minute after the one before. Kinds: P typed prompt, A assistant reply,
# T tool result, N turn_duration note, C local-command caveat (isMeta),
# M a /model command echo, K compact boundary (p is its logical parent),
# S sidechain assistant, X a record with no uuid.
set ::minute 0
proc R {k u p {text x}} {
    set ts [format "2026-10-17T13:%02d:00.000Z" [incr ::minute]]
    set par [expr {$p eq "" ? "null" : "\"$p\""}]
    set head "\"uuid\":\"$u\",\"parentUuid\":$par,\"timestamp\":\"$ts\""
    switch -- $k {
        P { set j "{\"type\":\"user\",$head,\"promptSource\":\"typed\",\"message\":{\"role\":\"user\",\"content\":\"$text\"}}" }
        A { set j "{\"type\":\"assistant\",$head,\"message\":{\"role\":\"assistant\",\"content\":\[{\"type\":\"text\",\"text\":\"$text\"}\]}}" }
        T { set j "{\"type\":\"user\",$head,\"message\":{\"role\":\"user\",\"content\":\[{\"type\":\"tool_result\",\"tool_use_id\":\"t\",\"content\":\"ok\"}\]}}" }
        N { set j "{\"type\":\"system\",\"subtype\":\"turn_duration\",$head}" }
        C { set j "{\"type\":\"user\",\"isMeta\":true,$head,\"message\":{\"role\":\"user\",\"content\":\"<local-command-caveat>Caveat</local-command-caveat>\"}}" }
        M { set j "{\"type\":\"user\",$head,\"message\":{\"role\":\"user\",\"content\":\"<command-name>/model</command-name>\"}}" }
        K { set j "{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"uuid\":\"$u\",\"parentUuid\":null,\"logicalParentUuid\":\"$p\",\"timestamp\":\"$ts\",\"content\":\"Conversation compacted\"}" }
        S { set j "{\"type\":\"assistant\",\"isSidechain\":true,$head,\"message\":{\"role\":\"assistant\",\"content\":\[{\"type\":\"text\",\"text\":\"$text\"}\]}}" }
        X { set j "{\"type\":\"last-prompt\",\"lastPrompt\":\"$text\"}" }
    }
    return [::logman::parse_line $j]
}

# One word per record: its branch depth, then "o" where a branch opens and
# "cN" where N branches close; "-" outside every branch.
proc marks {recs} {
    set out {}
    foreach r $recs {
        set w [dict getdef $r _branch_depth -]
        if {[dict exists $r _branch_open]} { append w o }
        if {[dict exists $r _branch_close]} { append w c[dict get $r _branch_close] }
        lappend out $w
    }
    return $out
}
proc branches {recs} { return [marks [::logman::mark_branches $recs]] }

# The header facts of every branch, in file order.
proc facts {recs} {
    set out {}
    foreach r [::logman::mark_turns $recs] {
        if {![dict exists $r _branch_open]} continue
        set b [dict get $r _branch_open]
        lappend out [list [dict get $b depth] [dict get $b turns] \
            [dict get $b prompt] [string range [dict get $b t0] 11 15] \
            [string range [dict get $b t1] 11 15] [dict get $b inner]]
    }
    return $out
}

# Stamps mark_turn_runs leaves through mark_turns: "s" superseded, "eN" the
# survivor of N drafts, "-" plain.
proc drafts {recs} {
    set out {}
    foreach r [::logman::mark_turns $recs] {
        if {[dict exists $r _superseded]} { lappend out s
        } elseif {[dict exists $r _edits]} { lappend out e[dict get $r _edits]
        } else { lappend out - }
    }
    return $out
}

# ---- a simple rewind -------------------------------------------------------
# p2 was answered, then the user rewound to before it and sent p3 from a1.
set ::minute 0
set simple [list [R P p1 "" first] [R A a1 p1] [R P p2 a1 rolled] [R A a2 p2] \
    [R P p3 a1 replacement] [R A a3 p3]]
check simple_branch {- - 1o 1c1 - -} [branches $simple]
check simple_facts {{1 1 rolled 13:03 13:04 0}} [facts $simple]

# ---- a rewind followed by /model -------------------------------------------
# The first record after the rewind is the command's caveat, not a prompt:
# the fork parent has one prompt child, and the path still tells the branch.
set ::minute 0
check model_after_rewind {- - 1o 1c1 - - - -} [branches [list \
    [R P p1 "" first] [R A a1 p1] [R P p2 a1 rolled] [R A a2 p2] \
    [R C c1 a1] [R M m1 c1] [R P p3 m1 next] [R A a3 p3]]]

# ---- the last-written prompt is not the survivor ---------------------------
# p3 was sent and abandoned unanswered; the session went on through a
# command. p3 has no reply under it, so it is a draft, not a branch.
set ::minute 0
set unanswered [list [R P p1 "" first] [R A a1 p1] [R P p2 a1 rolled] [R A a2 p2] \
    [R P p3 a1 orphan] [R C c1 a1] [R P p4 c1 next] [R A a4 p4]]
check last_prompt_not_survivor {- - 1o 1c1 - - - -} [branches $unanswered]

# ---- nested ----------------------------------------------------------------
# Inside the branch from p2 the user had already rewound once (p4 abandoned
# for p5); later the whole branch was abandoned for p6.
set ::minute 0
set nested [list [R P p1 "" first] [R A a1 p1] \
    [R P p2 a1 outer] [R A a2 p2] [R P p3 a2 more] [R A a3 p3] \
    [R P p4 a3 inner] [R A a4 p4] \
    [R P p5 a3 instead] [R A a5 p5] \
    [R P p6 a1 replacement] [R A a6 p6]]
check nested_branches {- - 1o 1 1 1 2o 2c1 1 1c1 - -} [branches $nested]
check nested_facts {{1 3 outer 13:03 13:10 1} {2 1 inner 13:07 13:08 0}} \
    [facts $nested]

# A prompt opening on a blank line quotes its first line with words.
set ::minute 0
check facts_prompt_skips_blank {{1 1 {pasted text} 13:03 13:04 0}} [facts [list \
    [R P p1 "" first] [R A a1 p1] [R P p2 a1 "\\n  pasted text\\nmore"] [R A a2 p2] \
    [R P p3 a1 replacement] [R A a3 p3]]]

# ---- a branch ending on a note ---------------------------------------------
set ::minute 0
check ends_on_note {- - 1o 1 1c1 - -} [branches [list \
    [R P p1 "" first] [R A a1 p1] [R P p2 a1 rolled] [R A a2 p2] [R N n2 a2] \
    [R P p3 a1 replacement] [R A a3 p3]]]

# ---- a branch ending on an unanswered prompt -------------------------------
# p2b closes the branch unanswered. It is a turn of the branch, and the run
# breaks at the branch's end, so p3 is no draft of it.
set ::minute 0
set open_end [list [R P p1 "" first] [R A a1 p1] [R P p2 a1 rolled] [R A a2 p2] \
    [R P p2b a2 unanswered] [R P p3 a1 replacement] [R A a3 p3]]
check ends_on_prompt {- - 1o 1 1c1 - -} [branches $open_end]
check ends_on_prompt_no_draft {- - - - - - -} [drafts $open_end]
check ends_on_prompt_turns {{1 2 rolled 13:03 13:05 0}} [facts $open_end]

# ---- an edit draft is not a branch -----------------------------------------
set ::minute 0
set draft [list [R P p1 "" first] [R A a1 p1] [R P p2 a1 draf] [R P p3 a1 draft] [R A a3 p3]]
check draft_no_branch {- - - - -} [branches $draft]
check draft_still_collapses {- - s e1 -} [drafts $draft]

# ---- parallel tool results are not a branch --------------------------------
# The second result hangs off the first call, off the path from the last
# record, and nothing answers under it.
set ::minute 0
check parallel_results {- - - - - -} [branches [list \
    [R P p1 "" go] [R A u1 p1] [R A u2 u1] [R T r1 u2] [R T r2 u1] [R A a2 r1]]]

# ---- a compaction does not cut the path ------------------------------------
# The boundary's parentUuid is null; through logicalParentUuid the path from
# after the /compact still reaches the fork before it.
set ::minute 0
check through_compaction {- - 1o 1c1 - - - - -} [branches [list \
    [R P p1 "" first] [R A a1 p1] [R P p2 a1 rolled] [R A a2 p2] \
    [R P p3 a1 replacement] [R A a3 p3] [R K k1 a3] [R P p4 k1 later] [R A a4 p4]]]

# ---- sidechain records and records without a uuid --------------------------
# A trailing sidechain record is not the leaf, and records without a uuid
# ride inside the run they fall in.
set ::minute 0
check sidechain_and_bare {- - 1o 1 1c1 - - -} [branches [list \
    [R P p1 "" first] [R A a1 p1] [R P p2 a1 rolled] [R X x1 ""] [R A a2 p2] \
    [R P p3 a1 replacement] [R A a3 p3] [R S s1 a1]]]

# ---- a live prompt inside the run leaves the branch unmarked ---------------
# Never seen in a session: a branch whose records straddle a prompt of the
# surviving path. Folding it would hide that prompt.
set ::minute 0
check foreign_prompt {- - - - - -} [branches [list \
    [R P p1 "" first] [R A a1 p1] [R P p2 a1 rolled] [R P pL a1 live] \
    [R A a2 p2] [R A aL pL]]]

# ---- the header phrase ------------------------------------------------------
# Local times; the test pins the zone so they read the same anywhere.
set ::env(TZ) UTC
proc phrase {args} {
    return [::logman::branch_phrase [dict merge \
        {turns 1 prompt "" t0 "" t1 "" inner 0} $args]]
}
check phrase_simple {1 turn · 13:03–13:04 · "rolled"} \
    [phrase prompt rolled t0 2026-10-17T13:03:00.000Z t1 2026-10-17T13:04:30.000Z]
check phrase_nested {3 turns · 13:03–13:10 · 1 rollback inside · "outer"} \
    [phrase turns 3 prompt outer inner 1 \
        t0 2026-10-17T13:03:00.000Z t1 2026-10-17T13:10:00.000Z]
check phrase_one_minute {2 turns · 13:03 · 2 rollbacks inside} \
    [phrase turns 2 inner 2 t0 2026-10-17T13:03:00.000Z t1 2026-10-17T13:03:40.000Z]
check phrase_midnight {1 turn · 17 Oct 23:58–18 Oct 00:02} \
    [phrase t0 2026-10-17T23:58:00.000Z t1 2026-10-18T00:02:00.000Z]
check phrase_cut "1 turn · \"[string repeat a 47]…\"" \
    [phrase prompt [string repeat a 60]]

# ---- a list without uuids passes through -----------------------------------
set plain [list [::logman::parse_line {{"type":"user","promptSource":"typed","message":{"role":"user","content":"hi"}}}]]
check no_uuids $plain [::logman::mark_branches $plain]

if {$fails > 0} {
    puts "FAILED: $fails"
    exit $fails
}
puts "PASS"
exit 0
