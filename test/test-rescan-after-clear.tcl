#!/usr/bin/env wish9.0
# Switching the recency scope (e.g. 7-day to 30-day) clears the list and
# re-runs the scan. clear wipes the engine's node store; the session-domain
# reverse indices (FolderNode/PathNode/TagNode) into that store must be wiped
# with it. If they are not, a wider scope that brings a fresh session into a
# folder already seen under the narrower scope hits a stale FolderNode whose
# node id was deleted from the store, and node_field throws
# "key nodeN not known" from inside the scan coroutine.
#
# The fixture is one folder with two sessions: A inside the 7-day window, B
# only inside the 30-day window. Under 7-day the folder streams in with A.
# Switching to 30-day clears, replays A, then extend scans B as a new path -
# B's path index is absent (so on_scan_row proceeds to model_add_session) while
# the folder index is stale, which is exactly the combination that crashes.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _rescanclear_sandbox]
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
foreach f {config.tcl lib/cost.tcl ui/theme.tcl lib/path.tcl lib/scope.tcl lib/listfilter.tcl lib/jsonl.tcl \
           lib/match.tcl ui/terminal.tcl ui/live.tcl lib/scan.tcl lib/search.tcl \
           ui/drag.tcl ui/toolbar.tcl ui/sessions.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

::questlog::path::_real_file delete -force $SAND
set ::env(HOME) $SAND

# Trap the background error the scan coroutine would raise on the stale id, so
# the failure is observable instead of only landing on stderr.
set ::bgerr ""
proc bgerror {msg} { set ::bgerr $msg }

proc noop {args} {}
proc write_session {path prompts secs} {
    ::questlog::path::_real_file mkdir [file dirname $path]
    set ts [clock format $secs -format "%Y-%m-%dT%H:%M" -gmt 1]
    set fh [open $path w]
    set t 0
    foreach p $prompts {
        puts $fh "{\"type\":\"user\",\"cwd\":\"/tmp/proj\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"role\":\"user\",\"content\":\"$p\"}}"
        puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
        incr t
    }
    close $fh
}

set PROOT [file join $SAND .claude projects]
set P1 [file join $PROOT -tmp-rc-p1]
set Ap [file join $P1 aaaa.jsonl]
set Bp [file join $P1 bbbb.jsonl]
# A an hour ago (inside 7d and 30d); B fifteen days ago (inside 30d only).
set NOW    [clock seconds]
set RECENT [expr {$NOW - 3600}]
set OLDER  [expr {$NOW - 15 * 86400}]
write_session $Ap {a-first a-second} $RECENT
write_session $Bp {b-first b-second} $OLDER
file mtime $Ap $RECENT
file mtime $Bp $OLDER

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc lookup {path}   { return [$::Scan lookup $path] }
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

set SL [::questlog::ui::SessionList new .s resolvef lookup noop noop noop noop noop \
            noop scanpath noop subagentsf noop]
pack .s -fill both -expand 1

set fails 0
proc check {name got want} {
    if {$got eq $want} { puts "ok   - $name" } else {
        puts "FAIL - $name"; puts "       got:  $got"; puts "       want: $want"; incr ::fails
    }
}

# Mirror the app's scope-switch sequence: replay the memoised rows that match
# the snapshot (Scan's coroutine skips already-scanned paths, so the replay is
# what re-feeds them), then extend for any newly-windowed file.
proc scan_now {snap} {
    foreach row [$::Scan query $snap] { $::SL on_scan_row $row }
    set ::scan_done 0
    $::Scan extend $snap
    after 300 [list set ::scan_done 1]
    vwait ::scan_done
    update
}

# --- 1. Seven-day scope: the folder streams in with session A only.
set snap7 [dict create since 7d]
$SL apply_filter $snap7
scan_now $snap7
check "folder present after 7-day scan" [$SL has_folder -tmp-rc-p1] 1
check "session A present" [$SL has_session $Ap] 1
check "session B outside 7-day window" [$SL has_session $Bp] 0

# --- 2. Switch to 30-day: clear + rescan. The clear must drop the folder index
# alongside the node store, or extend's discovery of B crashes the coroutine.
set snap30 [dict create since 30d]
$SL apply_filter $snap30
check "folder index reset on scope switch" [$SL has_folder -tmp-rc-p1] 0
scan_now $snap30
check "no background error on rescan" $::bgerr ""
check "folder re-added after scope switch" [$SL has_folder -tmp-rc-p1] 1
check "session A re-added" [$SL has_session $Ap] 1
check "session B now in 30-day window" [$SL has_session $Bp] 1

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
