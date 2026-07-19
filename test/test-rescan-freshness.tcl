#!/usr/bin/env wish9.0
# The store is the memo for every scanned row, so re-scan freshness is its
# duty: when a file changes on disk and the scan re-reads it, the fresh row
# must land in the store's payload whether the path is attached (browse) or
# retained detached (under search criteria). The attached row travels
# retire-then-restore, so folder books and rendering settle with it; the
# detached copy freshens in place. An unchanged file is never re-read at all
# (the known_mtime skip answers from the store).

package require Tcl 9
package require Tk

set SAND [file join [pwd] _rescan_fresh_sandbox]
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
set P1 [file join $PROOT -tmp-rf-p1]
set Ap [file join $P1 aaaa.jsonl]
set Bp [file join $P1 bbbb.jsonl]
set NOW [clock seconds]
write_session $Ap {a-first a-second} [expr {$NOW - 3600}]
write_session $Bp {b-first b-second} [expr {$NOW - 5 * 86400}]
file mtime $Ap [expr {$NOW - 3600}]
file mtime $Bp [expr {$NOW - 5 * 86400}]

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop \
    {} {} [list apply {{p} { $::SL stored_mtime $p }}]]
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

# The app's scope-switch sequence: clear-and-retain, replay, extend.
proc switch_scope {snap} {
    $::SL apply_filter $snap
    $::SL replay_scope
    set ::scan_done 0
    $::Scan extend $snap
    after 300 [list set ::scan_done 1]
    vwait ::scan_done
    update
}

# --- 1. Both stream in; price A so the re-scan's cost reset is observable.
switch_scope [dict create since 30d]
check "both scanned from disk" $::SCANS 2
check "A holds two turns" [$SL sget $Ap nturns] 2
$SL refresh_cost $Ap [dict create cost_usd 0.5 turns 2]
check "A priced" [$SL sget $Ap cost] 0.5

# --- 2. A changes on disk (a turn appended, mtime moved); re-extend. Only A
# is re-read - B's stored mtime answers the skip - and the attached payload
# takes the fresh fields.
set old_size [$SL sget $Ap size 0]
write_session $Ap {a-first a-second a-third} [expr {$NOW - 3000}]
file mtime $Ap [expr {$NOW - 3000}]
set ::SCANS 0
switch_scope [dict create since 30d]
check "only the changed file was re-read" $::SCANS 1
check "A still attached" [$SL has_session $Ap] 1
check "attached payload took the new turn count" [$SL sget $Ap nturns] 3
check "attached payload took the new mtime" [$SL sget $Ap mtime] [expr {$NOW - 3000}]
check "attached payload took the new size" \
    [expr {[$SL sget $Ap size 0] > $old_size}] 1
check "freshened row is re-priced from scratch" [$SL sget $Ap cost] ""
check "no background error" $::bgerr ""
check "audit clean after the attached freshen" [$SL audit] {}

# --- 2b. A selected, pinned, anchored running row is the common freshen case:
# the periodic rescan freshens it, and the retire/restore trip must not lose its
# place in the selection model. Set the three, change A on disk, re-extend so
# freshen_attached runs, and assert all three survive.
proc slvar {name} { global SL; set ns [info object namespace $SL]; return [set ${ns}::$name] }
$SL selection_set $Ap
set NS [info object namespace $SL]
namespace eval $NS { dict set Pinned $::Ap 1 }
check "A selected before the freshen" [$SL is_selected $Ap] 1
check "A pinned before the freshen" [dict exists [slvar Pinned] $Ap] 1
check "A is the anchor before the freshen" [slvar SelectAnchor] $Ap
# The trigger is a periodic rescan on the unchanged snapshot - no scope switch,
# so no clear - and A is already attached, so its changed file streams straight
# into freshen_attached's retire/restore trip.
write_session $Ap {a-first a-second a-third a-fourth} [expr {$NOW - 2000}]
file mtime $Ap [expr {$NOW - 2000}]
set ::scan_done 0
$::Scan extend [dict create since 30d]
after 300 [list set ::scan_done 1]
vwait ::scan_done
update
check "the freshen landed the new turn count" [$SL sget $Ap nturns] 4
check "A stays selected across the freshen" [$SL is_selected $Ap] 1
check "A stays pinned across the freshen" [dict exists [slvar Pinned] $Ap] 1
check "A stays the anchor across the freshen" [slvar SelectAnchor] $Ap
check "audit clean after the selected freshen" [$SL audit] {}

# --- 3. Under active criteria the rows are retained detached; a change on
# disk still freshens the retained copy through freshen_from_row.
$SL apply_filter [dict create since 30d search b-first search_case 0]
check "criteria retained B detached" [$SL has_retained $Bp] 1
write_session $Bp {b-first b-second b-third} [expr {$NOW - 4 * 86400}]
file mtime $Bp [expr {$NOW - 4 * 86400}]
set ::SCANS 0
set ::scan_done 0
$::Scan extend [dict create since 30d search b-first search_case 0]
after 300 [list set ::scan_done 1]
vwait ::scan_done
update
check "only the changed file was re-read under criteria" $::SCANS 1
check "B stayed detached" [$SL has_retained $Bp] 1
check "detached payload took the new turn count" [$SL sget $Bp nturns] 3
check "detached payload took the new mtime" [$SL sget $Bp mtime] [expr {$NOW - 4 * 86400}]
check "audit clean after the detached freshen" [$SL audit] {}

# --- 4. Clearing the criteria replays the freshened copies without a re-read.
set ::SCANS 0
switch_scope [dict create since 30d]
check "the replay re-read nothing" $::SCANS 0
check "replayed B carries the fresh turn count" [$SL sget $Bp nturns] 3
check "audit clean after the replay" [$SL audit] {}

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
