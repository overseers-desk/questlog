#!/usr/bin/env wish9.0
# The store is the memo for scanned-but-not-shown rows. A session that leaves
# the current scope - the window narrows, a running import stops - is retained
# as a detached node, not forgotten; widening the scope replays it from the
# store with NO disk re-scan, and every hydration site (search results, the
# running import) re-attaches the retained copy. This test instruments
# scan_one to prove the negative (no disk read), and drives the audit after
# every step.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _retention_sandbox]
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
foreach f {config.tcl lib/cost.tcl ui/theme.tcl lib/path.tcl lib/listfilter.tcl lib/jsonl.tcl \
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
set P1 [file join $PROOT -tmp-ret-p1]
set P2 [file join $PROOT -tmp-ret-p2]
set Ap [file join $P1 aaaa.jsonl]
set Bp [file join $P1 bbbb.jsonl]
set Cp [file join $P2 cccc.jsonl]
# A an hour ago (inside 24h); B five days and C ten days ago (inside 30d only).
set NOW [clock seconds]
write_session $Ap {a-first a-second} [expr {$NOW - 3600}]
write_session $Bp {b-first b-second} [expr {$NOW - 5 * 86400}]
write_session $Cp {c-first c-second} [expr {$NOW - 10 * 86400}]
file mtime $Ap [expr {$NOW - 3600}]
file mtime $Bp [expr {$NOW - 5 * 86400}]
file mtime $Cp [expr {$NOW - 10 * 86400}]

set SL ""
# The store is the scan's differential-skip memory, wired the way the app
# wires it: known_mtime answers from the widget's retained copy.
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop \
    {} {} [list apply {{p} { $::SL stored_mtime $p }}]]
# The instrument: every disk scan is counted, so a step that claims "from
# the store" proves it by the count staying flat.
set ::SCANS 0
oo::objdefine $::Scan method scan_one {path} { incr ::SCANS; next $path }
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

set SL [::questlog::ui::SessionList new .s resolvef noop noop noop noop noop \
            noop scanpath noop subagentsf noop]
pack .s -fill both -expand 1

set fails 0
proc check {name got want} {
    if {$got eq $want} { puts "ok   - $name" } else {
        puts "FAIL - $name"; puts "       got:  $got"; puts "       want: $want"; incr ::fails
    }
}

# The app's scope-switch sequence (on_filter): clear-and-retain, replay the
# retained rows the snapshot admits from the store, then extend for
# newly-windowed files.
proc switch_scope {snap} {
    $::SL apply_filter $snap
    $::SL replay_bounds
    set ::scan_done 0
    $::Scan extend $snap
    after 300 [list set ::scan_done 1]
    vwait ::scan_done
    update
}

# --- 1. Wide scope: everything streams in from disk.
switch_scope [dict create since 30d]
check "three sessions scanned from disk" $::SCANS 3
check "A attached" [$SL has_session $Ap] 1
check "B attached" [$SL has_session $Bp] 1
check "C attached" [$SL has_session $Cp] 1
check "audit clean after the stream" [$SL audit] {}

# --- 2. Narrow to 24h: B and C leave the tree into retention, not oblivion.
set ::SCANS 0
switch_scope [dict create since 24h]
check "narrowing re-scanned nothing" $::SCANS 0
check "A still attached" [$SL has_session $Ap] 1
check "B out of the tree" [$SL has_session $Bp] 0
check "B retained in the store" [$SL has_retained $Bp] 1
check "C retained in the store" [$SL has_retained $Cp] 1
check "C's emptied folder left the tree" [$SL has_folder -tmp-ret-p2] 0
check "audit clean after the narrow" [$SL audit] {}

# --- 3. A cost arrival for a retained row lands in its payload, so the row
# comes back priced.
$SL refresh_cost $Bp [dict create cost_usd 1.25 turns 4 duration_secs 60 \
    human_secs 20 model "claude-3-5-sonnet-20241022" context_pct 12]
check "retained row took the cost write" [$SL sget $Bp cost] 1.25

# --- 4. Widen back: the store replays; disk is not read.
set ::SCANS 0
switch_scope [dict create since 30d]
check "widening re-scanned nothing" $::SCANS 0
check "B re-attached from the store" [$SL has_session $Bp] 1
check "C re-attached from the store" [$SL has_session $Cp] 1
check "C's folder returned" [$SL has_folder -tmp-ret-p2] 1
check "B kept its cost across retention" [$SL sget $Bp cost] 1.25
check "B's folder aggregate carries the cost" [$SL fget -tmp-ret-p1 cost] 1.25
check "no background error across the round trip" $::bgerr ""
check "audit clean after the widen" [$SL audit] {}

# --- 5. Search staging: under active criteria the scan stream feeds the memo,
# and a search result hydrates from it without a disk read.
$SL apply_filter [dict create since 30d search b-first search_case 0]
check "criteria cleared the tree" [$SL has_session $Bp] 0
check "criteria kept the retention" [$SL has_retained $Bp] 1
$Scan scan_path $Bp                  ;# the scan stream during a search: staged
set ::SCANS 0
$SL add_session_matches [list [dict create path $Bp folder -tmp-ret-p1 \
    btype user content "b-first hit" lineoff 1]]
check "search result hydrated without a disk read" $::SCANS 0
check "search result attached from the store" [$SL has_session $Bp] 1
check "hydrated result kept its cost" [$SL sget $Bp cost] 1.25
check "audit clean under criteria" [$SL audit] {}

# --- 6. Clearing the search replays browse from the store.
set ::SCANS 0
switch_scope [dict create since 30d]
check "search-clear re-scanned nothing" $::SCANS 0
check "all three back in browse" \
    [list [$SL has_session $Ap] [$SL has_session $Bp] [$SL has_session $Cp]] {1 1 1}
check "replayed row carries no stale match count" [$SL sget $Bp count] 0
check "audit clean after the search clears" [$SL audit] {}

# --- 7. The running import under a narrow scope restores from the store, and
# a session that stops running retires back into it.
set ::SCANS 0
switch_scope [dict create since 24h]
$SL reconcile_running [dict create bbbb $Bp]
check "running import restored the retained row" [$SL has_session $Bp] 1
check "the import read no disk" $::SCANS 0
$SL reconcile_running [dict create]
check "stopped session retired, not forgotten" \
    [list [$SL has_session $Bp] [$SL has_retained $Bp]] {0 1}
check "audit clean after the running round trip" [$SL audit] {}

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
