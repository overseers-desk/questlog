#!/usr/bin/env tclsh9.0
package require Tcl 9
package require TclOO
set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT config.tcl]
source [file join $ROOT lib path.tcl]
source [file join $ROOT lib filter.tcl]
source [file join $ROOT lib jsonl.tcl]
source [file join $ROOT lib match.tcl]
source [file join $ROOT lib scan.tcl]

# Synthetic projects tree under /tmp/questlog-test-projects.
proc ::questlog::path::projects_root {} { return /tmp/questlog-test-projects }

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name  expected=<$expected>  actual=<$actual>"
        incr ::fails
    } else {
        puts "ok:   $name"
    }
}

# ---- fixture --------------------------------------------------------

::questlog::path::_real_file delete -force /tmp/questlog-test-projects
::questlog::path::_real_file mkdir /tmp/questlog-test-projects/-home-test-code-foo
::questlog::path::_real_file mkdir /tmp/questlog-test-projects/-home-test-code-bar-baz
# Subagent path that MUST be ignored.
::questlog::path::_real_file mkdir /tmp/questlog-test-projects/-home-test-code-foo/[set u 11111111-1111-1111-1111-111111111111]/subagents

set fh [open /tmp/questlog-test-projects/-home-test-code-foo/aaa-1.jsonl w]
puts $fh {{"type":"user","message":{"content":"first prompt about foo"},"cwd":"/home/test/code/foo","timestamp":"2026-04-25T10:00:00.000Z"}}
puts $fh {{"type":"assistant","message":{"content":"reply"},"timestamp":"2026-04-25T10:00:05.000Z"}}
puts $fh {{"type":"user","message":{"content":"second prompt"},"timestamp":"2026-04-25T10:00:30.000Z"}}
close $fh

set fh [open /tmp/questlog-test-projects/-home-test-code-foo/bbb-2.jsonl w]
puts $fh {{"type":"user","message":{"content":"only one turn here"},"cwd":"/home/test/code/foo","timestamp":"2026-04-25T11:00:00.000Z"}}
close $fh

set fh [open /tmp/questlog-test-projects/-home-test-code-bar-baz/ccc-3.jsonl w]
puts $fh {{"type":"user","message":{"content":"prompt in bar/baz"},"cwd":"/home/test/code/bar/baz","timestamp":"2026-04-25T12:00:00.000Z"}}
puts $fh {{"type":"assistant","message":{"content":"reply"}}}
puts $fh {{"type":"user","message":{"content":"another"}}}
close $fh

# Subagent fixture - must NOT appear in Rows.
set fh [open /tmp/questlog-test-projects/-home-test-code-foo/$u/subagents/x.jsonl w]
puts $fh {{"type":"user","message":{"content":"subagent should be ignored"}}}
puts $fh {{"type":"user","message":{"content":"second subagent line"}}}
close $fh

# ---- run scan --------------------------------------------------------

set ::scan_done 0
set ::rows [list]
proc on_row {row} { lappend ::rows $row }
proc on_done {scanned} { set ::scan_done 1 }

set s [::questlog::Scan new on_row on_done]
$s extend [dict create since all one_turn 0]
vwait ::scan_done

# ---- assertions ------------------------------------------------------

check rows_count 3 [llength $::rows]

# Subagent regression: that file's path must not be in Rows.
set subagent_path "/tmp/questlog-test-projects/-home-test-code-foo/$u/subagents/x.jsonl"
set in_rows 0
foreach r $::rows { if {[dict get $r path] eq $subagent_path} { set in_rows 1 } }
check subagent_excluded 0 $in_rows

# Folder display path resolution. The resolver walks the real filesystem
# and returns a cwd only when the directory exists, so this uses a real
# temp dir as the session's cwd (the synthetic /home/test/... paths used
# elsewhere in this fixture deliberately resolve to "").
set realcwd /tmp/questlog-test-realcwd
::questlog::path::_real_file mkdir $realcwd
set rf [::questlog::path::encode_cwd $realcwd]
::questlog::path::_real_file mkdir [file join /tmp/questlog-test-projects $rf]
set fh [open [file join /tmp/questlog-test-projects $rf real-1.jsonl] w]
puts $fh "{\"type\":\"user\",\"message\":{\"content\":\"a\"},\"cwd\":\"$realcwd\"}"
puts $fh "{\"type\":\"user\",\"message\":{\"content\":\"b\"}}"
close $fh
check resolve_real_dir $realcwd [$s resolve_folder $rf]
check resolve_absent_dir "" [$s resolve_folder "-no-such-folder-xyz"]
::questlog::path::_real_file delete -force $realcwd
::questlog::path::_real_file delete -force [file join /tmp/questlog-test-projects $rf]

# query with one_turn=1 drops the single-turn bbb-2 file.
set qrows [$s query [dict create since all one_turn 1]]
check query_one_turn 2 [llength $qrows]

# Memoisation: re-extending shouldn't re-scan unchanged paths.
set ::scan_done 0
set ::rows [list]
$s extend [dict create since all one_turn 0]
vwait ::scan_done
check memo_re_scanned_count 0 [llength $::rows]

# mtime invalidation: bumping a file's mtime forces a re-scan of just that path.
# Tcl's `file mtime` setter takes an explicit epoch - bypasses 1-second
# resolution issues from `exec touch`.
file mtime /tmp/questlog-test-projects/-home-test-code-foo/aaa-1.jsonl [expr {[clock seconds] + 60}]
set ::scan_done 0
set ::rows [list]
$s extend [dict create since all one_turn 0]
vwait ::scan_done
check mtime_invalidation_count 1 [llength $::rows]
check mtime_invalidation_path /tmp/questlog-test-projects/-home-test-code-foo/aaa-1.jsonl [dict get [lindex $::rows 0] path]

# Ordering: query result is mtime-DESC. The just-touched aaa-1 should be first.
set qall [$s query [dict create since all one_turn 0]]
set first_path [dict get [lindex $qall 0] path]
check ordering_first_is_touched /tmp/questlog-test-projects/-home-test-code-foo/aaa-1.jsonl $first_path

# Regression: query against a previously-seen since bound must return the
# memoised rows. App's on_filter relies on this to repopulate the tree
# after a since-bound tighten-then-widen sequence (24h → 7d). Without it the
# coroutine skips memoised paths and the tree stays empty.
set q_before [$s query [dict create since all one_turn 0]]
set ::scan_done 0
$s extend [dict create since all one_turn 1]   ;# tighter (one_turn=1)
vwait ::scan_done
set q_back [$s query [dict create since all one_turn 0]]
check query_replay_after_since_change [llength $q_before] [llength $q_back]

$s destroy

# ---- bookmark flag + since override ---------------------------------
# Bookmark bbb-2 and age both it and ccc-3 past a 7d since bound. A fresh Scan
# (no memoised mtimes) then proves: scan_one reads the +x bit; the old
# bookmarked file survives both enumeration and query despite the since bound;
# the old non-bookmarked file does not.
set bbb /tmp/questlog-test-projects/-home-test-code-foo/bbb-2.jsonl
set ccc /tmp/questlog-test-projects/-home-test-code-bar-baz/ccc-3.jsonl
::questlog::path::set_bookmark $bbb
file mtime $bbb [expr {[clock seconds] - 40*24*3600}]
file mtime $ccc [expr {[clock seconds] - 40*24*3600}]

set ::scan_done 0
set ::rows [list]
set s2 [::questlog::Scan new on_row on_done]
$s2 extend [dict create since all one_turn 0]
vwait ::scan_done

set bbb_row ""
foreach r $::rows { if {[dict get $r path] eq $bbb} { set bbb_row $r } }
check bbb_bookmarked_flag 1 [dict get $bbb_row bookmarked]

set q7 [$s2 query [dict create since 7d one_turn 0]]
set paths7 [lmap r $q7 {dict get $r path}]
check query_bookmark_kept   1 [expr {$bbb in $paths7}]
check query_old_plain_dropped 0 [expr {$ccc in $paths7}]

set lp [$s2 list_paths_for [dict create since 7d]]
check enum_bookmark_kept     1 [expr {$bbb in $lp}]
check enum_old_plain_dropped 0 [expr {$ccc in $lp}]

# bookmarked_only filter keeps only the bookmarked row.
set qb [$s2 query [dict create since all one_turn 0 bookmarked_only 1]]
check query_bookmarked_only 1 [llength $qb]

$s2 destroy
::questlog::path::_real_file delete -force /tmp/questlog-test-projects

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
