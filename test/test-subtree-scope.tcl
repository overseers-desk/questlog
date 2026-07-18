#!/usr/bin/env tclsh9.0
# `subtree` is the scan's enumeration root: list_paths_for walks only the folders
# at or below the scoped directory, so out-of-scope sessions are never opened.
# Because encode_cwd is lossy (every non-alphanumeric -> -), the folder-name test
# can pull in a hyphenated sibling (.../proj-x looks like a child of .../proj);
# row_subtree_match confirms each kept row. This pins the enumeration
# restriction, the residence semantics (the row's project folder resolved on
# disk decides; a moved session follows its new home), and the fallback chain
# for unresolvable folders (recorded cwd, then encoded name).

package require Tcl 9
package require TclOO
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
source [file join $ROOT config.tcl]
source [file join $ROOT lib path.tcl]
source [file join $ROOT lib scope.tcl]
source [file join $ROOT lib jsonl.tcl]
source [file join $ROOT lib match.tcl]
source [file join $ROOT lib scan.tcl]

proc ::questlog::path::projects_root {} { return /tmp/questlog-subtree-test }

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name  expected=<$expected>  actual=<$actual>"
        incr ::fails
    } else {
        puts "ok:   $name"
    }
}

# A session whose head records the cwd, two turns so it is a normal row.
proc mkf {folder cwd uuid} {
    set dir /tmp/questlog-subtree-test/$folder
    ::questlog::path::_real_file mkdir $dir
    set fh [open $dir/$uuid.jsonl w]
    puts $fh "{\"type\":\"user\",\"cwd\":\"$cwd\",\"timestamp\":\"2026-06-22T10:00:00.000Z\",\"message\":{\"content\":\"hi\"}}"
    puts $fh "{\"type\":\"assistant\",\"timestamp\":\"2026-06-22T10:00:05.000Z\",\"message\":{\"content\":\"yo\"}}"
    puts $fh "{\"type\":\"user\",\"cwd\":\"$cwd\",\"timestamp\":\"2026-06-22T10:01:00.000Z\",\"message\":{\"content\":\"more\"}}"
    close $fh
}

::questlog::path::_real_file delete -force /tmp/questlog-subtree-test
mkf -home-test-code-proj      /home/test/code/proj      aaaa
mkf -home-test-code-proj-sub  /home/test/code/proj/sub  bbbb
mkf -home-test-code-proj-x    /home/test/code/proj-x    cccc
mkf -home-test-code-other     /home/test/code/other     dddd

set U [list /home/test/code/proj]

# ---- folder_subtree_candidate: the enumeration test (name only, no read) ----
check cand_exact      1 [::questlog::scope::folder_subtree_candidate -home-test-code-proj $U]
check cand_child      1 [::questlog::scope::folder_subtree_candidate -home-test-code-proj-sub $U]
check cand_hyphen_sib 1 [::questlog::scope::folder_subtree_candidate -home-test-code-proj-x $U]
check cand_other      0 [::questlog::scope::folder_subtree_candidate -home-test-code-other $U]

# ---- list_paths_for walks only candidate folders (other never enumerated) ----
set s [::questlog::Scan new {} {}]
set lp_folders [lsort -unique [lmap p [$s list_paths_for [dict create since all subtree $U]] \
                                   {file tail [file dirname $p]}]]
check enum_excludes_other  0 [expr {"-home-test-code-other"    in $lp_folders}]
check enum_keeps_proj      1 [expr {"-home-test-code-proj"     in $lp_folders}]
check enum_keeps_child     1 [expr {"-home-test-code-proj-sub" in $lp_folders}]
check enum_keeps_hyphen    1 [expr {"-home-test-code-proj-x"   in $lp_folders}]

# ---- row_subtree_match, fallback chain: /home/test/... does not exist on the
# running machine, so the folders are unresolvable and the recorded cwd_hint
# decides - the deleted-repo path. The hyphenated sibling still drops. ----
set rp [$s stamp_subtree [$s scan_one /tmp/questlog-subtree-test/-home-test-code-proj/aaaa.jsonl]]
set rc [$s stamp_subtree [$s scan_one /tmp/questlog-subtree-test/-home-test-code-proj-sub/bbbb.jsonl]]
set rx [$s stamp_subtree [$s scan_one /tmp/questlog-subtree-test/-home-test-code-proj-x/cccc.jsonl]]
check gone_stamp_empty       {} [dict get $rp folder_cwd]
check gone_exact             1 [::questlog::scope::row_subtree_match $rp $U]
check gone_child             1 [::questlog::scope::row_subtree_match $rc $U]
check gone_hyphen_sibling    0 [::questlog::scope::row_subtree_match $rx $U]
# cwd_hint also empty: the encoded folder name is the last evidence.
set rblank [dict create folder -home-test-code-proj-sub cwd_hint "" folder_cwd ""]
check gone_blank_by_name     1 [::questlog::scope::row_subtree_match $rblank $U]
check gone_blank_other       0 [::questlog::scope::row_subtree_match \
                                    [dict create folder -home-test-code-other cwd_hint ""] $U]

# ---- canon_dir: the entry-point canonicaliser both the toolbar's folder
# editor and the CLI's --subtree run a typed path through. Tcl 9 expands ~
# nowhere, so without it a typed ~/x scope compares literally and matches
# nothing (the bug this pins). ----
set home [file home]
check canon_tilde      $home/code/proj [::questlog::path::canon_dir ~/code/proj]
check canon_bare_tilde $home           [::questlog::path::canon_dir ~]
check canon_absolute   /home/test/code/proj [::questlog::path::canon_dir /home/test/code/proj]
check canon_trailing   /home/test/code/proj [::questlog::path::canon_dir /home/test/code/proj/]
check canon_empty      {} [::questlog::path::canon_dir {}]
check canon_bad_user   1  [catch {::questlog::path::canon_dir ~nosuchuser/x}]
# The canonicalised form is what the predicates see: a tilde scope, once
# expanded, admits the exact dir and its subtree like any absolute scope.
set UT [list [::questlog::path::canon_dir ~/../../home/test/code/proj]]
check canon_feeds_confirm_exact 1 [::questlog::scope::row_subtree_match $rp $UT]
check canon_feeds_confirm_child 1 [::questlog::scope::row_subtree_match $rc $UT]

# ---- residence: real directories, so folders resolve and residence decides.
# The move feature files a session into a project folder; the scope reads that
# filing, not the cwd recorded in the transcript. ----
set BASE /tmp/questlog-subtree-test-src
::questlog::path::_real_file delete -force $BASE
foreach d [list $BASE/proj $BASE/proj/sub $BASE/other $BASE/we\[i\]rd $BASE/weird] {
    ::questlog::path::_real_file mkdir $d
}
set P $BASE/proj
mkf [::questlog::path::encode_cwd $P]        $P        r001    ;# resident
mkf [::questlog::path::encode_cwd $P/sub]    $P/sub    r002    ;# subdir resident
mkf [::questlog::path::encode_cwd $P]        $BASE/other mv01  ;# moved INTO proj's folder
mkf [::questlog::path::encode_cwd $BASE/other] $P/sub  mv02    ;# moved OUT to other's folder
mkf [::questlog::path::encode_cwd $BASE/we\[i\]rd] $BASE/we\[i\]rd w001
mkf [::questlog::path::encode_cwd $BASE/weird]     $BASE/weird     w002

set s2 [::questlog::Scan new {} {}]
set root /tmp/questlog-subtree-test
set r_res  [$s2 stamp_subtree [$s2 scan_one $root/[::questlog::path::encode_cwd $P]/r001.jsonl]]
set r_sub  [$s2 stamp_subtree [$s2 scan_one $root/[::questlog::path::encode_cwd $P/sub]/r002.jsonl]]
set r_min  [$s2 stamp_subtree [$s2 scan_one $root/[::questlog::path::encode_cwd $P]/mv01.jsonl]]
set r_mout [$s2 stamp_subtree [$s2 scan_one $root/[::questlog::path::encode_cwd $BASE/other]/mv02.jsonl]]
set r_wb   [$s2 stamp_subtree [$s2 scan_one $root/[::questlog::path::encode_cwd $BASE/we\[i\]rd]/w001.jsonl]]
set r_wp   [$s2 stamp_subtree [$s2 scan_one $root/[::questlog::path::encode_cwd $BASE/weird]/w002.jsonl]]

check res_stamp             $P [dict get $r_res folder_cwd]
check res_exact             1 [::questlog::scope::row_subtree_match $r_res [list $P]]
check res_ancestor          1 [::questlog::scope::row_subtree_match $r_res [list $BASE]]
check res_subdir            1 [::questlog::scope::row_subtree_match $r_sub [list $P]]
# The moved-in session answers to its new home at every level of its tree,
# and no longer to the directory recorded in its transcript.
check moved_in_new_home     1 [::questlog::scope::row_subtree_match $r_min [list $P]]
check moved_in_ancestor     1 [::questlog::scope::row_subtree_match $r_min [list $BASE]]
check moved_in_not_old_cwd  0 [::questlog::scope::row_subtree_match $r_min [list $BASE/other]]
# The moved-out session left proj's tree even though its transcript ran there.
check moved_out_gone        0 [::questlog::scope::row_subtree_match $r_mout [list $P]]
check moved_out_new_home    1 [::questlog::scope::row_subtree_match $r_mout [list $BASE/other]]
# Glob metacharacters in a directory name are characters, not patterns: the
# scope we\[i\]rd matches only that directory, never its glob-shadow weird.
check metachar_self         1 [::questlog::scope::row_subtree_match $r_wb [list $BASE/we\[i\]rd]]
check metachar_no_shadow    0 [::questlog::scope::row_subtree_match $r_wp [list $BASE/we\[i\]rd]]

# ---- stream agreement: the row predicate over published rows admits exactly
# what a fresh walk admits, so a warm GUI and a fresh scan answer the scope
# alike ----
set ::pub [list]
foreach f [glob -directory $root -- */*.jsonl] { lappend ::pub [$s2 scan_path $f] }
set snapP [dict create since all subtree [list $P]]
set got [lsort [lmap r $::pub {expr {
    [::questlog::scope::row_matches $snapP $r]
        ? [file rootname [file tail [dict get $r path]]] : [continue]}}]]
check stream_residence {mv01 r001 r002} $got
$s2 destroy
::questlog::path::_real_file delete -force $BASE

# ---- no subtree scope: every folder is walked (show-all) ----
set all_folders [lsort -unique [lmap p [$s list_paths_for [dict create since all]] \
                                    {file tail [file dirname $p]}]]
check no_scope_walks_other 1 [expr {"-home-test-code-other" in $all_folders}]

$s destroy
::questlog::path::_real_file delete -force /tmp/questlog-subtree-test

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
