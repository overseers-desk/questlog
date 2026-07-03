#!/usr/bin/env tclsh9.0
# `under` is the scan's enumeration root: list_paths_for walks only the folders
# at or below the scoped directory, so out-of-scope sessions are never opened.
# Because encode_cwd is lossy (every non-alphanumeric -> -), the folder-name test
# can pull in a hyphenated sibling (.../proj-x looks like a child of .../proj);
# row_under_match confirms each kept row from its real cwd. This pins both: the
# enumeration restriction and the confirmation that corrects the over-inclusion.

package require Tcl 9
package require TclOO
set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT config.tcl]
source [file join $ROOT lib path.tcl]
source [file join $ROOT lib filter.tcl]
source [file join $ROOT lib jsonl.tcl]
source [file join $ROOT lib match.tcl]
source [file join $ROOT lib scan.tcl]

proc ::questlog::path::projects_root {} { return /tmp/questlog-under-test }

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
    set dir /tmp/questlog-under-test/$folder
    ::questlog::path::_real_file mkdir $dir
    set fh [open $dir/$uuid.jsonl w]
    puts $fh "{\"type\":\"user\",\"cwd\":\"$cwd\",\"timestamp\":\"2026-06-22T10:00:00.000Z\",\"message\":{\"content\":\"hi\"}}"
    puts $fh "{\"type\":\"assistant\",\"timestamp\":\"2026-06-22T10:00:05.000Z\",\"message\":{\"content\":\"yo\"}}"
    puts $fh "{\"type\":\"user\",\"cwd\":\"$cwd\",\"timestamp\":\"2026-06-22T10:01:00.000Z\",\"message\":{\"content\":\"more\"}}"
    close $fh
}

::questlog::path::_real_file delete -force /tmp/questlog-under-test
mkf -home-test-code-proj      /home/test/code/proj      aaaa
mkf -home-test-code-proj-sub  /home/test/code/proj/sub  bbbb
mkf -home-test-code-proj-x    /home/test/code/proj-x    cccc
mkf -home-test-code-other     /home/test/code/other     dddd

set U [list /home/test/code/proj]

# ---- folder_under_candidate: the enumeration test (name only, no read) ----
check cand_exact      1 [::questlog::filter::folder_under_candidate -home-test-code-proj $U]
check cand_child      1 [::questlog::filter::folder_under_candidate -home-test-code-proj-sub $U]
check cand_hyphen_sib 1 [::questlog::filter::folder_under_candidate -home-test-code-proj-x $U]
check cand_other      0 [::questlog::filter::folder_under_candidate -home-test-code-other $U]

# ---- list_paths_for walks only candidate folders (other never enumerated) ----
set s [::questlog::Scan new {} {}]
set lp_folders [lsort -unique [lmap p [$s list_paths_for [dict create since all under $U]] \
                                   {file tail [file dirname $p]}]]
check enum_excludes_other  0 [expr {"-home-test-code-other"    in $lp_folders}]
check enum_keeps_proj      1 [expr {"-home-test-code-proj"     in $lp_folders}]
check enum_keeps_child     1 [expr {"-home-test-code-proj-sub" in $lp_folders}]
check enum_keeps_hyphen    1 [expr {"-home-test-code-proj-x"   in $lp_folders}]

# ---- row_under_match confirms the real cwd: the hyphenated sibling drops ----
set rp [$s scan_one /tmp/questlog-under-test/-home-test-code-proj/aaaa.jsonl]
set rc [$s scan_one /tmp/questlog-under-test/-home-test-code-proj-sub/bbbb.jsonl]
set rx [$s scan_one /tmp/questlog-under-test/-home-test-code-proj-x/cccc.jsonl]
check confirm_exact          1 [::questlog::filter::row_under_match $rp $U]
check confirm_child          1 [::questlog::filter::row_under_match $rc $U]
check confirm_hyphen_sibling 0 [::questlog::filter::row_under_match $rx $U]

# ---- canon_dir: the entry-point canonicaliser both the toolbar's folder
# editor and the CLI's --under run a typed path through. Tcl 9 expands ~
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
check canon_feeds_confirm_exact 1 [::questlog::filter::row_under_match $rp $UT]
check canon_feeds_confirm_child 1 [::questlog::filter::row_under_match $rc $UT]

# ---- no under: every folder is walked (show-all) ----
set all_folders [lsort -unique [lmap p [$s list_paths_for [dict create since all]] \
                                    {file tail [file dirname $p]}]]
check no_under_walks_other 1 [expr {"-home-test-code-other" in $all_folders}]

$s destroy
::questlog::path::_real_file delete -force /tmp/questlog-under-test

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
