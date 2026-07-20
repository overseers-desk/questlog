#!/usr/bin/env wish9.0
# The arrival poll: a session .jsonl appearing in the projects tree mid-run,
# with no live-registry entry (launched under a different CLAUDE_CONFIG_DIR, or
# synced in by syncthing), enters the session list from a cheap tree poll rather
# than only at restart. This drives a real ::questlog::Scan wired to a real
# SessionList (its stored_mtime answers the differential skip) and asserts that
# poll_arrivals models an in-window arrival, honours the same snapshot bounds the
# scan stream does (window / subtree / min-turns / active criteria), leaves the
# disk untouched for a quiescent corpus (the dir-mtime memo suppresses the
# globs) and for an out-of-window arrival (the stat gate spares the scan), never
# interleaves with a running extend, and freshens a rewritten file.
#
# Runs under wish (it builds a SessionList, so it needs Tk); run-audit routes it
# to wish9.0 on the private Xvfb. Standalone: DISPLAY=:97 wish9.0 test-arrival-poll.tcl

package require Tcl 9
if {[catch {package require Tk} e]} { puts "SKIP - no Tk/display ($e)"; exit 0 }

set SAND [file join [pwd] _arrival_poll_sandbox]
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
set ::questlog_config_only 1; source [file join $ROOT questlog]
foreach f {lib/cost.tcl ui/theme.tcl lib/path.tcl lib/listfilter.tcl lib/jsonl.tcl \
           lib/match.tcl ui/terminal.tcl ui/live.tcl lib/scan.tcl lib/search.tcl \
           ui/drag.tcl ui/toolbar.tcl ui/sessions.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

::questlog::path::_real_file delete -force $SAND
set ::env(HOME) $SAND

set ::bgerr ""
proc bgerror {msg} { set ::bgerr $msg }

proc noop {args} {}

# A session transcript of $prompts user turns, each answered, dated at $secs.
# The recorded cwd is $cwd, so its project folder resolves (encode_cwd($cwd)
# names the folder) and the subtree predicate has a residence to read.
proc write_session {path cwd prompts secs} {
    ::questlog::path::_real_file mkdir [file dirname $path]
    set ts [clock format $secs -format "%Y-%m-%dT%H:%M" -gmt 1]
    set fh [open $path w]
    set t 0
    foreach p $prompts {
        puts $fh "{\"type\":\"user\",\"cwd\":\"$cwd\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"role\":\"user\",\"content\":\"$p\"}}"
        puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
        incr t
    }
    close $fh
}
proc touch_now {path} { file mtime $path [clock seconds] }

set PROOT [file join $SAND .claude projects]
# Real cwd directories so peek_folder_cwd resolves each folder to an extant path
# and the subtree bound reads a true residence.
set W    [file normalize [file join $SAND w]]
set cwdA [file join $W projA]
set cwdB [file join $W projB]
set cwdX [file normalize [file join $SAND out projX]]
::questlog::path::_real_file mkdir $cwdA $cwdB $cwdX

proc spath {cwd uuid} { return [file join $::PROOT [::questlog::path::encode_cwd $cwd] $uuid.jsonl] }
set folderA [::questlog::path::encode_cwd $cwdA]
set folderB [::questlog::path::encode_cwd $cwdB]
set dirA [file join $PROOT $folderA]
set dirB [file join $PROOT $folderB]

set sessA    [spath $cwdA aaaa]
set sessN    [spath $cwdA nnnn]
set sessB    [spath $cwdB bbbb]
set sessOld  [spath $cwdA oldold]
set sessX    [spath $cwdX xxxx]
set sessOne  [spath $cwdA oneone]
set sessCrit [spath $cwdA critcrit]

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop \
    {} {} [list apply {{p} { $::SL stored_mtime $p }}]]
set ::SCANS 0
oo::objdefine $::Scan method scan_one {path} { incr ::SCANS; next $path }
proc scanpath {path}   { return [$::Scan scan_path $path] }
proc subagentsf {path} { return [$::Scan subagents_for $path] }
proc resolvef {f}      { return "" }

set SL [::questlog::ui::SessionList new .s resolvef noop noop noop noop noop noop \
            scanpath noop subagentsf noop]
pack .s -fill both -expand 1

set fails 0
proc check {name got want} {
    if {$got eq $want} { puts "ok   - $name" } else {
        puts "FAIL - $name"; puts "       got:  $got"; puts "       want: $want"; incr ::fails
    }
}

proc rescan {snap} {
    set ::scan_done 0
    $::Scan extend $snap
    after 300 [list set ::scan_done 1]
    vwait ::scan_done
    update
}
proc switch_scope {snap} { $::SL apply_filter $snap; rescan $snap }

set NOW [clock seconds]

# --- initial corpus: one existing session, streamed by an ordinary extend.
write_session $sessA $cwdA {a-first a-second} [expr {$NOW - 3600}]
file mtime $sessA [expr {$NOW - 3600}]
switch_scope [dict create since 30d]
check "existing session modelled by extend" [$SL has_session $sessA] 1

# --- 1. A fresh jsonl lands in the existing folder with no registry entry; one
# poll models it and reports one file scanned. Only the arrival is read - the
# store answers the differential skip for the file it already holds.
write_session $sessN $cwdA {n-first n-second} [expr {$NOW - 100}]
file mtime $sessN [expr {$NOW - 100}]
set ::SCANS 0
set n [$Scan poll_arrivals]
check "arrival modelled after poll" [$SL has_session $sessN] 1
check "poll reported one file" $n 1
check "only the arrival was read" $::SCANS 1

# --- 2. A brand-new project folder with a fresh jsonl (exercises the root pass).
# Backdate the root and warm its memo first, so creating the folder moves the
# root mtime clear of the memo - second-granular mtimes collide within a second,
# and the root pass has no same-second guard.
file mtime $PROOT [expr {$NOW - 100}]
$Scan poll_arrivals
write_session $sessB $cwdB {b-first b-second} [expr {$NOW - 200}]
file mtime $sessB [expr {$NOW - 200}]
set n [$Scan poll_arrivals]
check "new-folder arrival modelled" [$SL has_session $sessB] 1
check "root pass reported one file" $n 1

# --- 3. Quiescent corpus: the dir-mtime memo suppresses the globs, so the poll
# reads nothing and reports zero. Backdate the folders past the same-second guard
# and warm the memo first, so the second poll truly rests on the memo.
file mtime $dirA [expr {$NOW - 100}]
file mtime $dirB [expr {$NOW - 100}]
$Scan poll_arrivals
set ::SCANS 0
set n [$Scan poll_arrivals]
check "quiescent poll reports zero" $n 0
check "quiescent poll reads nothing" $::SCANS 0

# --- 4. An arrival outside the snapshot window: the stat gate spares the scan,
# so it is neither read nor modelled.
write_session $sessOld $cwdA {old-first} [expr {$NOW - 40 * 86400}]
file mtime $sessOld [expr {$NOW - 40 * 86400}]
set ::SCANS 0
set n [$Scan poll_arrivals]
check "out-of-window arrival not modelled" [$SL has_session $sessOld] 0
check "out-of-window arrival not read" $::SCANS 0
check "out-of-window poll reports zero" $n 0

# --- 5. A subtree bound: an in-window arrival in an out-of-subtree folder is
# scanned (the walk has no subtree gate) but on_scan_row's bounds check keeps it
# out of the model.
switch_scope [dict create since 30d subtree [list $W]]
# Warm the root memo off a backdated root (as in step 2) so the new out-of-
# subtree folder created next moves the root mtime clear of the memo.
file mtime $PROOT [expr {$NOW - 100}]
$Scan poll_arrivals
write_session $sessX $cwdX {x-first x-second} [clock seconds]
touch_now $sessX
set ::SCANS 0
set n [$Scan poll_arrivals]
check "out-of-subtree arrival was scanned" [expr {$::SCANS >= 1}] 1
check "out-of-subtree arrival not modelled" [$SL has_session $sessX] 0

# --- 6. A min-turns floor: a one-turn arrival is scanned but not modelled.
switch_scope [dict create since 30d min_turns 2]
write_session $sessOne $cwdA {only-one} [clock seconds]
touch_now $sessOne
set ::SCANS 0
$Scan poll_arrivals
check "one-turn arrival was scanned" [expr {$::SCANS >= 1}] 1
check "one-turn arrival not modelled" [$SL has_session $sessOne] 0

# --- 7. Active search criteria: the arrival is scanned and published, but the
# criteria guard in on_scan_row drops it without error.
switch_scope [dict create since 30d search zzznomatch search_case 0]
write_session $sessCrit $cwdA {crit-first crit-second} [clock seconds]
touch_now $sessCrit
set ::bgerr ""
$Scan poll_arrivals
check "arrival under criteria not modelled" [$SL has_session $sessCrit] 0
check "no error under criteria" $::bgerr ""

# --- 8. While an extend is Active, the poll never interleaves: it reports zero.
$SL apply_filter [dict create since 30d]
set ::scan_done 0
$Scan extend [dict create since 30d]
check "poll reports zero while extend active" [$Scan poll_arrivals] 0
after 300 [list set ::scan_done 1]
vwait ::scan_done
update

# --- 9. A syncthing-style rewrite (temp file + rename, which bumps the dir
# mtime) freshens the attached row's turn count.
check "modelled turn count before rewrite" [$SL sget $sessN nturns] 2
set tmp [file join $dirA tmp-nnnn.jsonl]
write_session $tmp $cwdA {n-first n-second n-third} [clock seconds]
touch_now $tmp
::questlog::path::_real_file rename -force -- $tmp $sessN
$Scan poll_arrivals
check "rewrite freshened the turn count" [$SL sget $sessN nturns] 3

# --- 10. No background error the whole way through.
check "no background error" $::bgerr ""

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
