#!/usr/bin/env tclsh9.0
package require Tcl 9
package require TclOO
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
source [file join $ROOT config.tcl]
source [file join $ROOT lib path.tcl]
source [file join $ROOT lib listfilter.tcl]
source [file join $ROOT lib jsonl.tcl]
source [file join $ROOT lib match.tcl]
source [file join $ROOT lib scan.tcl]
source [file join $ROOT lib cost.tcl]

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
puts $fh {{"type":"user","message":{"role":"user","content":"first prompt about foo"},"cwd":"/home/test/code/foo","timestamp":"2026-04-25T10:00:00.000Z"}}
puts $fh {{"type":"assistant","message":{"content":"reply"},"timestamp":"2026-04-25T10:00:05.000Z"}}
puts $fh {{"type":"user","message":{"role":"user","content":"second prompt"},"timestamp":"2026-04-25T10:00:30.000Z"}}
puts $fh {{"type":"assistant","message":{"content":"reply two"},"timestamp":"2026-04-25T10:00:35.000Z"}}
# Third user turn: the scanner must count past the old early-break of 2 to
# record nturns 3, so this also proves the raised turn_count_cap loop.
puts $fh {{"type":"user","message":{"role":"user","content":"third prompt"},"timestamp":"2026-04-25T10:01:00.000Z"}}
close $fh

set fh [open /tmp/questlog-test-projects/-home-test-code-foo/bbb-2.jsonl w]
puts $fh {{"type":"user","message":{"role":"user","content":"only one turn here"},"cwd":"/home/test/code/foo","timestamp":"2026-04-25T11:00:00.000Z"}}
close $fh

set fh [open /tmp/questlog-test-projects/-home-test-code-bar-baz/ccc-3.jsonl w]
puts $fh {{"type":"user","message":{"role":"user","content":"prompt in bar/baz"},"cwd":"/home/test/code/bar/baz","timestamp":"2026-04-25T12:00:00.000Z"}}
puts $fh {{"type":"assistant","message":{"content":"reply"}}}
puts $fh {{"type":"user","message":{"role":"user","content":"another"}}}
close $fh

# Subagent fixture - must NOT enter the row stream.
set fh [open /tmp/questlog-test-projects/-home-test-code-foo/$u/subagents/x.jsonl w]
puts $fh {{"type":"user","message":{"role":"user","content":"subagent should be ignored"}}}
puts $fh {{"type":"user","message":{"role":"user","content":"second subagent line"}}}
close $fh

# ---- run scan --------------------------------------------------------

set ::scan_done 0
set ::rows [list]
# The consumer's retained copy is the differential skip's memory: record each
# published row's mtime, and answer known_mtime from that record, the way the
# session list's store answers it in the app.
set ::mtimes [dict create]
proc on_row {row} {
    lappend ::rows $row
    dict set ::mtimes [dict get $row path] [dict get $row mtime]
}
proc on_done {scanned} { set ::scan_done 1 }
proc known_mtime {path} { return [dict getdef $::mtimes $path ""] }

set s [::questlog::Scan new on_row on_done {} {} known_mtime]
$s extend [dict create since all]
vwait ::scan_done

# ---- assertions ------------------------------------------------------

check rows_count 3 [llength $::rows]

# Subagent regression: that file's path must not be published as a browse row.
set subagent_path "/tmp/questlog-test-projects/-home-test-code-foo/$u/subagents/x.jsonl"
set in_stream 0
foreach r $::rows { if {[dict get $r path] eq $subagent_path} { set in_stream 1 } }
check subagent_excluded 0 $in_stream

# Folder display path resolution. The resolver walks the real filesystem
# and returns a cwd only when the directory exists, so this uses a real
# temp dir as the session's cwd (the synthetic /home/test/... paths used
# elsewhere in this fixture deliberately resolve to "").
set realcwd /tmp/questlog-test-realcwd
::questlog::path::_real_file mkdir $realcwd
set rf [::questlog::path::encode_cwd $realcwd]
::questlog::path::_real_file mkdir [file join /tmp/questlog-test-projects $rf]
set fh [open [file join /tmp/questlog-test-projects $rf real-1.jsonl] w]
puts $fh "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"a\"},\"cwd\":\"$realcwd\"}"
puts $fh "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"b\"}}"
close $fh
check resolve_real_dir $realcwd [$s resolve_folder $rf]
check resolve_absent_dir "" [$s resolve_folder "-no-such-folder-xyz"]
::questlog::path::_real_file delete -force $realcwd
::questlog::path::_real_file delete -force [file join /tmp/questlog-test-projects $rf]

# ---- folder_cwd: the resolver that opens nothing ---------------------
#
# The UI is wired to folder_cwd, not to resolve_folder, and the whole line
# between a filter and a search runs through the difference: a filter re-filters
# rows already loaded, and the Bookmarked filter's sweep and the cut banner's names
# ride on that path, so neither may open a transcript. resolve_folder does open
# one (peek_folder_cwd), which is fine on the scan path and fatal on the filter
# path.
#
# The two folders below are the two cases. The first has an extant directory, so
# the filesystem walk answers it and folder_cwd is as good as resolve_folder. The
# second is the expensive one: its sessions were moved in from elsewhere (the cwd
# they record encodes to another basename) and that directory is gone, so the walk
# cannot name it. resolve_folder then reads every transcript in the folder, learns
# nothing it can trust, and caches nothing - so it pays those reads again on every
# call, which on a UI path is every poll tick. folder_cwd stops at the walk, and
# the open counter below is what holds it there.
rename open real_open
proc open {args} {
    if {[string match *.jsonl [lindex $args 0]]} { incr ::opens }
    return [uplevel 1 [list real_open {*}$args]]
}

set walkcwd /tmp/questlog-test-walkcwd
::questlog::path::_real_file mkdir $walkcwd
set wf [::questlog::path::encode_cwd $walkcwd]
::questlog::path::_real_file mkdir [file join /tmp/questlog-test-projects $wf]
set fh [real_open [file join /tmp/questlog-test-projects $wf walk-1.jsonl] w]
puts $fh "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"a\"},\"cwd\":\"$walkcwd\"}"
close $fh

set movedf -tmp-questlog-test-moved-away
::questlog::path::_real_file mkdir [file join /tmp/questlog-test-projects $movedf]
foreach n {1 2 3} {
    set fh [real_open [file join /tmp/questlog-test-projects $movedf moved-$n.jsonl] w]
    puts $fh "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"a\"},\"cwd\":\"/tmp/questlog-test-somewhere-else\"}"
    close $fh
}

set sr [::questlog::Scan new "" ""]

set ::opens 0
check folder_cwd_walks_to_real_dir $walkcwd [$sr folder_cwd $wf]
check folder_cwd_read_nothing 0 $::opens

set ::opens 0
check folder_cwd_gives_up_on_moved "" [$sr folder_cwd $movedf]
check folder_cwd_read_nothing_when_it_gives_up 0 $::opens

# The same question through the full resolver: it reads, and (having found no
# answer) it will read again next time. That is the cost the filter path no
# longer pays.
set ::opens 0
check resolve_folder_gives_up_on_moved "" [$sr resolve_folder $movedf]
check resolve_folder_read_the_folder 3 $::opens

rename open {}
rename real_open open
$sr destroy
::questlog::path::_real_file delete -force $walkcwd
::questlog::path::_real_file delete -force [file join /tmp/questlog-test-projects $wf]
::questlog::path::_real_file delete -force [file join /tmp/questlog-test-projects $movedf]

# min_turns is scope: the scanner records each row's nturns (capped), and
# filter::row_in_bounds drops a row below the floor. The 3-turn aaa session records
# nturns 3; the single-turn bbb-2 records nturns 1. A min_turns 2 scope keeps the
# two multi-turn rows (aaa 3, ccc 2) and drops bbb-2. The published stream is
# the rows' one delivery; scope questions are asked of the row dicts it carried.
set snap1 [dict create since all min_turns 2]
set qrows $::rows
check stream_rows_all 3 [llength $qrows]
array set nturns_of {}
foreach r $qrows { set nturns_of([dict get $r path]) [dict get $r nturns] }
check nturns_recorded_aaa 3 $nturns_of(/tmp/questlog-test-projects/-home-test-code-foo/aaa-1.jsonl)
check nturns_recorded_bbb 1 $nturns_of(/tmp/questlog-test-projects/-home-test-code-foo/bbb-2.jsonl)
set inscope 0
foreach r $qrows { if {[::questlog::scan::row_in_bounds $snap1 $r]} { incr inscope } }
check row_matches_min_turns 2 $inscope

# Memoisation: re-extending shouldn't re-scan unchanged paths.
set ::scan_done 0
set ::rows [list]
$s extend [dict create since all]
vwait ::scan_done
check memo_re_scanned_count 0 [llength $::rows]

# mtime invalidation: bumping a file's mtime forces a re-scan of just that path.
# Tcl's `file mtime` setter takes an explicit epoch - bypasses 1-second
# resolution issues from `exec touch`.
file mtime /tmp/questlog-test-projects/-home-test-code-foo/aaa-1.jsonl [expr {[clock seconds] + 60}]
set ::scan_done 0
set ::rows [list]
$s extend [dict create since all]
vwait ::scan_done
check mtime_invalidation_count 1 [llength $::rows]
check mtime_invalidation_path /tmp/questlog-test-projects/-home-test-code-foo/aaa-1.jsonl [dict get [lindex $::rows 0] path]

# Ordering: the path list (and so the stream) is mtime-DESC. The just-touched
# aaa-1 should lead it. Replay across snapshot changes is the session list
# store's duty and is proven in test-retention / test-rescan-freshness.
set first_path [lindex [$s list_paths_for [dict create since all]] 0]
check ordering_first_is_touched /tmp/questlog-test-projects/-home-test-code-foo/aaa-1.jsonl $first_path

$s destroy

# ---- bookmark flag + since override ---------------------------------
# Bookmark bbb-2 and age both it and ccc-3 past a 7d since bound. A fresh Scan
# then proves: scan_one reads the +x bit; a bookmark is a session attribute,
# never a window exemption, so neither enumeration nor the row predicate
# admits the old bookmarked file into a 7d window.
set bbb /tmp/questlog-test-projects/-home-test-code-foo/bbb-2.jsonl
set ccc /tmp/questlog-test-projects/-home-test-code-bar-baz/ccc-3.jsonl
::questlog::path::set_bookmark $bbb
file mtime $bbb [expr {[clock seconds] - 40*24*3600}]
file mtime $ccc [expr {[clock seconds] - 40*24*3600}]

set ::scan_done 0
set ::rows [list]
set s2 [::questlog::Scan new on_row on_done]
$s2 extend [dict create since all]
vwait ::scan_done

set bbb_row ""
set ccc_row ""
foreach r $::rows {
    if {[dict get $r path] eq $bbb} { set bbb_row $r }
    if {[dict get $r path] eq $ccc} { set ccc_row $r }
}
check bbb_bookmarked_flag 1 [dict get $bbb_row bookmarked]

# A bookmark is a session attribute (the bookmarked view filter reads it),
# never a window exemption: an out-of-window bookmarked row fails the window
# predicate exactly like a plain one.
check row_matches_bookmark_obeys_window 0 \
    [::questlog::scan::row_in_bounds [dict create since 7d] $bbb_row]
check row_matches_old_plain_dropped 0 \
    [::questlog::scan::row_in_bounds [dict create since 7d] $ccc_row]

set lp [$s2 list_paths_for [dict create since 7d]]
check enum_bookmark_obeys_window 0 [expr {$bbb in $lp}]
check enum_old_plain_dropped 0 [expr {$ccc in $lp}]

# The Bookmarked filter is a view filter, not a scope bound: the stream
# carries every in-window row regardless of the bookmark, and the +x bit the
# filter reads rides on the row. Exactly one row (bbb) carries it, so a
# bookmark-agnostic stream still hands the filter what it needs to keep just
# that one.
set bookmarked 0
foreach r $::rows { if {[dict getdef $r bookmarked 0]} { incr bookmarked } }
check stream_is_bookmark_agnostic 1 $bookmarked

$s2 destroy

# ---- slug read: tail window + full-file fallback --------------------
# scan_one reads the slug from a 64 KB tail window as a fast path, with a
# full-file sweep when that window holds no title. Three cases:
#   (a) title more than tail_window_bytes before EOF (a long, busy session) -
#       the tail misses it, the fallback recovers it;
#   (b) a short session whose only title precedes the forward break - the
#       tail starts after the break and misses it, the fallback recovers it;
#   (c) title inside the window - read by the fast path, no fallback.
# (a) and (b) both read as nameless without the fallback.
set s3 [::questlog::Scan new "" ""]
set win [::questlog::config::get tail_window_bytes]

set far /tmp/questlog-test-projects/-home-test-code-foo/far-title.jsonl
set fh [open $far w]
chan configure $fh -encoding utf-8 -translation lf
puts $fh {{"type":"user","message":{"role":"user","content":"first"},"cwd":"/home/test/code/foo","timestamp":"2026-05-01T10:00:00.000Z"}}
puts $fh {{"type":"agent-name","agentName":"far-back-title","sessionId":"far"}}
puts $fh {{"type":"user","message":{"role":"user","content":"second"},"timestamp":"2026-05-01T10:01:00.000Z"}}
set pad [string repeat x 200]
set written 0
while {$written < $win + 4096} {
    set line "{\"type\":\"assistant\",\"message\":{\"content\":\"$pad\"}}"
    puts $fh $line
    incr written [expr {[string length $line] + 1}]
}
close $fh
check slug_far_title_fallback far-back-title [dict get [$s3 scan_one $far] slug]

set early /tmp/questlog-test-projects/-home-test-code-foo/early-title.jsonl
set fh [open $early w]
chan configure $fh -encoding utf-8 -translation lf
puts $fh {{"type":"user","message":{"role":"user","content":"q1"},"cwd":"/home/test/code/foo","timestamp":"2026-05-02T10:00:00.000Z"}}
puts $fh {{"type":"agent-name","agentName":"early-named","sessionId":"early"}}
puts $fh {{"type":"user","message":{"role":"user","content":"q2"},"timestamp":"2026-05-02T10:01:00.000Z"}}
puts $fh {{"type":"assistant","message":{"content":"done"}}}
close $fh
check slug_early_title_fallback early-named [dict get [$s3 scan_one $early] slug]

set near /tmp/questlog-test-projects/-home-test-code-foo/near-title.jsonl
set fh [open $near w]
chan configure $fh -encoding utf-8 -translation lf
puts $fh {{"type":"user","message":{"role":"user","content":"q1"},"cwd":"/home/test/code/foo","timestamp":"2026-05-03T10:00:00.000Z"}}
puts $fh {{"type":"user","message":{"role":"user","content":"q2"},"timestamp":"2026-05-03T10:01:00.000Z"}}
puts $fh {{"type":"agent-name","agentName":"near-named","sessionId":"near"}}
close $fh
check slug_near_title near-named [dict get [$s3 scan_one $near] slug]

$s3 destroy

# ---- nturns and the cost turns count identically (F3) ---------------
# The scanner's nturns (which the min-turns floor reads) and the cost pass's
# turns (which the Turns column shows) must agree. A session of N typed prompts
# plus a slash-command echo (a harness user record the user never typed) and a
# tool_result user record (array content): is_user_turn counts only the N real
# prompts, so the floor and the column land on the same number.
::questlog::match::set_caps [dict create \
    content_cap     [::questlog::config::get content_cap] \
    snippet_lead    [::questlog::config::get snippet_lead] \
    snippet_trail   [::questlog::config::get snippet_trail] \
    tool_param_cap  [::questlog::config::get tool_param_cap] \
    tool_render_cap [::questlog::config::get tool_render_cap]]

set turns_fix /tmp/questlog-test-projects/-home-test-code-foo/turns-1.jsonl
set fh [open $turns_fix w]
chan configure $fh -encoding utf-8 -translation lf
puts $fh {{"type":"user","message":{"role":"user","content":"real prompt one"},"cwd":"/home/test/code/foo","timestamp":"2026-05-10T10:00:00.000Z"}}
puts $fh {{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-8","content":"reply"},"timestamp":"2026-05-10T10:00:05.000Z"}}
puts $fh {{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"},"timestamp":"2026-05-10T10:00:10.000Z"}}
puts $fh {{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"timestamp":"2026-05-10T10:00:20.000Z"}}
puts $fh {{"type":"user","message":{"role":"user","content":"real prompt two"},"timestamp":"2026-05-10T10:00:30.000Z"}}
puts $fh {{"type":"user","message":{"role":"user","content":"real prompt three"},"timestamp":"2026-05-10T10:01:00.000Z"}}
close $fh

set s4 [::questlog::Scan new "" ""]
set row3 [$s4 scan_one $turns_fix]
set scan_one_turns [dict get $row3 nturns]
# scan_file returns {row matches}; an empty clause set leaves the row's nturns
# intact while matching nothing.
set empty_clauses [dict create leaves {} tree {t and nodes {}} nocase 1]
lassign [::questlog::match::scan_file $turns_fix $empty_clauses] sf_row _
set scan_file_turns [dict get $sf_row nturns]
set cost_turns [dict get [::questlog::cost::parse_file $turns_fix] turns]

check turns_scan_one_is_three  3 $scan_one_turns
check turns_scan_file_is_three 3 $scan_file_turns
check turns_scan_one_eq_cost  $cost_turns $scan_one_turns
check turns_scan_file_eq_cost $cost_turns $scan_file_turns

# The floor reads nturns, the column shows the cost turns; with both 3, a floor
# of 3 keeps the row and a floor of 4 drops it, and that decision is the one the
# displayed turns count would predict.
check floor_3_keeps 1 [::questlog::scan::row_in_bounds [dict create since all min_turns 3] $row3]
check floor_4_drops 0 [::questlog::scan::row_in_bounds [dict create since all min_turns 4] $row3]
check floor_agrees_with_column 1 [expr {$cost_turns >= 3}]

$s4 destroy

::questlog::path::_real_file delete -force /tmp/questlog-test-projects

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
