#!/usr/bin/env tclsh9.0
package require Tcl 9
package require TclOO
set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT lib path.tcl]
source [file join $ROOT lib scan.tcl]

# Synthetic projects tree under /tmp/csm-test-projects.
proc ::csm::path::projects_root {} { return /tmp/csm-test-projects }

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

file delete -force /tmp/csm-test-projects
file mkdir /tmp/csm-test-projects/-home-test-code-foo
file mkdir /tmp/csm-test-projects/-home-test-code-bar-baz
# Subagent path that MUST be ignored.
file mkdir /tmp/csm-test-projects/-home-test-code-foo/[set u 11111111-1111-1111-1111-111111111111]/subagents

set fh [open /tmp/csm-test-projects/-home-test-code-foo/aaa-1.jsonl w]
puts $fh {{"type":"user","message":{"content":"first prompt about foo"},"cwd":"/home/test/code/foo","timestamp":"2026-04-25T10:00:00.000Z"}}
puts $fh {{"type":"assistant","message":{"content":"reply"},"timestamp":"2026-04-25T10:00:05.000Z"}}
puts $fh {{"type":"user","message":{"content":"second prompt"},"timestamp":"2026-04-25T10:00:30.000Z"}}
close $fh

set fh [open /tmp/csm-test-projects/-home-test-code-foo/bbb-2.jsonl w]
puts $fh {{"type":"user","message":{"content":"only one turn here"},"cwd":"/home/test/code/foo","timestamp":"2026-04-25T11:00:00.000Z"}}
close $fh

set fh [open /tmp/csm-test-projects/-home-test-code-bar-baz/ccc-3.jsonl w]
puts $fh {{"type":"user","message":{"content":"prompt in bar/baz"},"cwd":"/home/test/code/bar/baz","timestamp":"2026-04-25T12:00:00.000Z"}}
puts $fh {{"type":"assistant","message":{"content":"reply"}}}
puts $fh {{"type":"user","message":{"content":"another"}}}
close $fh

# Subagent fixture — must NOT appear in Rows.
set fh [open /tmp/csm-test-projects/-home-test-code-foo/$u/subagents/x.jsonl w]
puts $fh {{"type":"user","message":{"content":"subagent should be ignored"}}}
puts $fh {{"type":"user","message":{"content":"second subagent line"}}}
close $fh

# ---- run scan --------------------------------------------------------

set ::scan_done 0
set ::rows [list]
proc on_row {row} { lappend ::rows $row }
proc on_done {scanned} { set ::scan_done 1 }

set s [::csm::Scan new on_row on_done]
$s extend [dict create window all one_turn 0]
vwait ::scan_done

# ---- assertions ------------------------------------------------------

check rows_count 3 [llength $::rows]

# Subagent regression: that file's path must not be in Rows.
set subagent_path "/tmp/csm-test-projects/-home-test-code-foo/$u/subagents/x.jsonl"
set in_rows 0
foreach r $::rows { if {[dict get $r path] eq $subagent_path} { set in_rows 1 } }
check subagent_excluded 0 $in_rows

# Folder display path resolution.
check resolve_foo "/home/test/code/foo"     [$s resolve_folder "-home-test-code-foo"]
check resolve_bar "/home/test/code/bar/baz" [$s resolve_folder "-home-test-code-bar-baz"]

# query with one_turn=1 drops the single-turn bbb-2 file.
set qrows [$s query [dict create window all one_turn 1]]
check query_one_turn 2 [llength $qrows]

# Memoisation: re-extending shouldn't re-scan unchanged paths.
set ::scan_done 0
set ::rows [list]
$s extend [dict create window all one_turn 0]
vwait ::scan_done
check memo_re_scanned_count 0 [llength $::rows]

# mtime invalidation: bumping a file's mtime forces a re-scan of just that path.
# Tcl's `file mtime` setter takes an explicit epoch — bypasses 1-second
# resolution issues from `exec touch`.
file mtime /tmp/csm-test-projects/-home-test-code-foo/aaa-1.jsonl [expr {[clock seconds] + 60}]
set ::scan_done 0
set ::rows [list]
$s extend [dict create window all one_turn 0]
vwait ::scan_done
check mtime_invalidation_count 1 [llength $::rows]
check mtime_invalidation_path /tmp/csm-test-projects/-home-test-code-foo/aaa-1.jsonl [dict get [lindex $::rows 0] path]

# Ordering: query result is mtime-DESC. The just-touched aaa-1 should be first.
set qall [$s query [dict create window all one_turn 0]]
set first_path [dict get [lindex $qall 0] path]
check ordering_first_is_touched /tmp/csm-test-projects/-home-test-code-foo/aaa-1.jsonl $first_path

# Regression: query against a previously-seen window must return the
# memoised rows. App's on_filter relies on this to repopulate the tree
# after a window-shrink-then-grow sequence (24h → 7d). Without it the
# coroutine skips memoised paths and the tree stays empty.
set q_before [$s query [dict create window all one_turn 0]]
set ::scan_done 0
$s extend [dict create window all one_turn 1]   ;# tighter (one_turn=1)
vwait ::scan_done
set q_back [$s query [dict create window all one_turn 0]]
check query_replay_after_window_change [llength $q_before] [llength $q_back]

$s destroy
file delete -force /tmp/csm-test-projects

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
