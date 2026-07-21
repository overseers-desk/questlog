#!/usr/bin/env wish9.0
# The open session viewer grows when the transcript file grows on disk.
#
# append_new already tails records past LoadedLines, but its only driver was the
# 300 ms resume pipe, armed only for a turn the user sent from inside questlog.
# A transcript written by an external claude process, or replaced by syncthing,
# never reached the view until the user switched away and back. watch_tick is
# the standing re-stat: one file-size look per tick against the open session,
# tailing on growth, running the catch-up index pass at quiescence, and
# reloading on a shrink (a replace/truncate) with the prompt bar and session
# identity kept. This drives watch_tick directly over a real Viewer and asserts
# growth, the newline-less partial tail, shrink-reload, the resume-pipe guard,
# the switch re-arm, quiescence, and a clean background-error list.
#
# Runs under wish (it builds a Viewer, so it needs Tk); run-audit routes it to
# wish9.0 on the private Xvfb. Standalone: DISPLAY=:98 wish9.0 test-viewer-watch.tcl
# With no DISPLAY it skips cleanly (exit 0) rather than dying on the Tk load.

package require Tcl 9
if {![info exists ::env(DISPLAY)] || $::env(DISPLAY) eq ""} {
    puts "skip - no DISPLAY (viewer watch test needs Tk)"
    exit 0
}
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
set ::questlog_config_only 1; source [file join $ROOT questlog]
foreach f {lib/debug.tcl lib/path.tcl lib/match.tcl \
           lib/cost.tcl ui/theme.tcl ui/viewer.tcl} {
    source [file join $ROOT $f]
}
::questlog::match::set_caps [dict create \
    content_cap     [::questlog::config::get content_cap] \
    snippet_lead    [::questlog::config::get snippet_lead] \
    snippet_trail   [::questlog::config::get snippet_trail] \
    tool_param_cap  [::questlog::config::get tool_param_cap] \
    tool_render_cap [::questlog::config::get tool_render_cap]]
::questlog::ui::theme::init

set fails 0
proc check {name got want} {
    if {$got eq $want} {
        puts "ok   - $name"
    } else {
        puts "FAIL - $name"
        puts "       got:  $got"
        puts "       want: $want"
        incr ::fails
    }
}

# Any background error surfaces here (leash timers run at global level); the
# test forgets its re-armed timers, so this stays empty unless something throws.
set ::bgerr [list]
proc bgerror {msg} { lappend ::bgerr $msg }

# The on_refresh recorder: the constructor's 6th arg, invoked as `{*}$OnRefresh
# $Path` by the quiescence catch-up (mirroring resume_finish). Records each call.
set ::refreshed [list]
proc rec_refresh {path} { lappend ::refreshed $path }

# ---- fixtures ---------------------------------------------------------------
set tmpbase [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set TMP [file join $tmpbase ql-watch-test-[pid]]
::questlog::path::_real_file mkdir $TMP

# Write a list of complete jsonl records (each a raw json line) to a path.
proc write_records {path records} {
    set fh [open $path w]
    fconfigure $fh -encoding utf-8
    foreach r $records { puts $fh $r }
    close $fh
}
# Append complete records to an existing path.
proc append_records {path records} {
    set fh [open $path a]
    fconfigure $fh -encoding utf-8
    foreach r $records { puts $fh $r }
    close $fh
}

# One turn + one tool call. The needle token lives in the prose so it is easy to
# find in the transcript.
set A_INIT {
    {{"type":"user","promptSource":"typed","cwd":"/tmp/wproj","timestamp":"2026-07-11T10:00:00Z","message":{"role":"user","content":"Alpha question"}}}
    {{"type":"assistant","timestamp":"2026-07-11T10:00:05Z","message":{"role":"assistant","content":[{"type":"text","text":"Alpha reply here."},{"type":"tool_use","id":"a1","name":"Read","input":{"file_path":"/tmp/alpha.txt"}}]}}}
}
# Two complete records: a fresh typed turn plus an assistant tool call.
set A_GROW {
    {{"type":"user","promptSource":"typed","timestamp":"2026-07-11T10:05:00Z","message":{"role":"user","content":"Beta question"}}}
    {{"type":"assistant","timestamp":"2026-07-11T10:05:05Z","message":{"role":"assistant","content":[{"type":"text","text":"Beta reply here."},{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"echo beta"}}]}}}
}

set JA [file join $TMP a.jsonl]
set JB [file join $TMP b.jsonl]
write_records $JA $A_INIT

# ---- build a real Viewer ----------------------------------------------------
set V [::questlog::ui::Viewer new .v {} {} {} {} rec_refresh]
pack .v -fill both -expand 1
set NS [info object namespace $V]
$V show $JA 0 {}
update idletasks
set Text [$V textwidget]
set ToolLB [dict get [set ${NS}::BandDesc] tools list]

# Drive one watch_tick and forget the timer it re-arms, so no real 2 s timer is
# left pending to fire mid-test (the re-arm itself is proven in section 5). Both
# the pre-call token (a prior show's arm) and the freshly armed one are dropped.
proc tick {} {
    set pre [set ${::NS}::WatchTok]
    $::V watch_tick
    set post [set ${::NS}::WatchTok]
    if {$post ne ""} { $::V forget $post }
    if {$pre ne "" && $pre ne $post} { $::V forget $pre }
    update idletasks
}
proc peek {var} { return [set ${::NS}::$var] }
proc poke {var val} { set ${::NS}::$var $val }
proc occurrences {term} {
    return [llength [$::Text search -all -- $term 1.0 end]]
}
proc endhint_present {} {
    return [expr {[llength [$::Text tag ranges endhint]] > 0 ? 1 : 0}]
}

# ---- 1. growth: a tick renders, quiescence runs the catch-up ----------------
check "show loaded the one initial turn" [llength [peek Turns]] 1
check "show indexed the one tool call" [$ToolLB size] 1
set ::refreshed [list]
append_records $JA $A_GROW

tick
check "growth tick grew the turn registry" [llength [peek Turns]] 2
check "growth tick rendered the new turn" [expr {[occurrences "Beta question"] > 0}] 1
check "growth marked the catch-up as owed" [peek WatchDirty] 1
check "growth tick has not yet run the refresh" [llength $::refreshed] 0
check "growth tick has not yet caught up the tool band" [$ToolLB size] 1

tick
check "quiescence caught up the tool band" [$ToolLB size] 2
check "quiescence left the endhint present" [endhint_present] 1
check "quiescence fired the refresh exactly once" [llength $::refreshed] 1
check "the refresh carried the session path" [lindex $::refreshed 0] $JA
check "quiescence cleared the dirty flag" [peek WatchDirty] 0

# ---- 2. partial tail: a newline-less record renders nothing until complete ---
set gamma {{"type":"user","promptSource":"typed","timestamp":"2026-07-11T10:10:00Z","message":{"role":"user","content":"Gamma partial"}}}
set fh [open $JA a]
fconfigure $fh -encoding utf-8
puts -nonewline $fh $gamma
close $fh

set turns_before [llength [peek Turns]]
tick
check "the newline-less tail rendered nothing" [occurrences "Gamma partial"] 0
check "the newline-less tail opened no turn" [llength [peek Turns]] $turns_before
check "the newline-less tail set no dirty" [peek WatchDirty] 0

# Complete the line with its trailing newline.
set fh [open $JA a]
fconfigure $fh -encoding utf-8
puts $fh ""
close $fh
set ::refreshed [list]
tick
check "the completed record renders exactly once" [occurrences "Gamma partial"] 1
check "the completed record opened its turn" [llength [peek Turns]] [expr {$turns_before + 1}]
check "the completed record marked the catch-up owed" [peek WatchDirty] 1
check "the completing tick has not yet refreshed" [llength $::refreshed] 0

tick
check "the following tick fires the refresh" [llength $::refreshed] 1
check "the follow-up refresh carried the path" [lindex $::refreshed 0] $JA

# ---- 3. shrink: a replace/truncate reloads, keeping prompt + identity -------
poke PromptVar "unsent draft text"
set uuid_before [peek Uuid]
set tmp [file join $TMP shrink.tmp]
write_records $tmp {
    {{"type":"user","promptSource":"typed","timestamp":"2026-07-11T11:00:00Z","message":{"role":"user","content":"ShrinkNew fresh transcript"}}}
}
::questlog::path::_real_file rename -force $tmp $JA
set ::bgerr [list]
tick
check "the shrink reloaded the new transcript" [expr {[occurrences "ShrinkNew"] > 0}] 1
check "the shrink dropped the old transcript" [occurrences "Alpha reply"] 0
check "the shrink kept the unsent prompt text" [peek PromptVar] "unsent draft text"
check "the shrink kept the session identity" [peek Uuid] $uuid_before
check "the shrink cleared the dirty flag" [peek WatchDirty] 0
check "the shrink raised no background error" [llength $::bgerr] 0

# ---- 4. resume-pipe guard: a running stream owns the tail -------------------
write_records $JA $A_INIT
$V show $JA 0 {}
update idletasks
set turns_before [llength [peek Turns]]
poke Running 1
append_records $JA $A_GROW
tick
check "the guard renders nothing while a stream runs" [occurrences "Beta question"] 0
check "the guard left the registry untouched" [llength [peek Turns]] $turns_before
poke Running 0
tick
check "the tail lands once the stream releases it" [expr {[occurrences "Beta question"] > 0}] 1
check "the released tail grew the registry" [llength [peek Turns]] [expr {$turns_before + 1}]

# ---- 5. switch re-arm: one live watch timer after a session switch ----------
# Sweep any watch timers the direct-driven ticks above left pending, so the
# count reflects only the show re-arm under test.
foreach {tok val} [peek LeashPending] {
    if {[string match "*watch_tick*" [lindex $val 1]]} { $V forget $tok }
}
write_records $JB $A_INIT
$V show $JA 0 {}
$V show $JB 0 {}
update idletasks
set watch_timers 0
foreach {tok val} [peek LeashPending] {
    if {[string match "*watch_tick*" [lindex $val 1]]} { incr watch_timers }
}
check "a session switch leaves exactly one watch timer" $watch_timers 1
set wtok [peek WatchTok]
check "the surviving token is the current WatchTok" \
    [expr {[dict exists [peek LeashPending] $wtok] ? 1 : 0}] 1
set waid [lindex [dict get [peek LeashPending] $wtok] 0]
check "the watch timer is genuinely pending" [expr {$waid in [after info] ? 1 : 0}] 1
# Drop it so it cannot fire during the remaining sections.
$V forget $wtok

# ---- 6. quiescence: no change moves nothing and fires no refresh ------------
$V show $JB 0 {}
update idletasks
set end_before [$Text index end]
set ::refreshed [list]
tick
tick
check "two quiet ticks leave the transcript end stable" [$Text index end] $end_before
check "two quiet ticks fire no refresh" [llength $::refreshed] 0
check "two quiet ticks leave the dirty flag clear" [peek WatchDirty] 0

# ---- 7. clean background-error list -----------------------------------------
check "no background error across the run" [llength $::bgerr] 0

# ---- clean up ---------------------------------------------------------------
::questlog::path::_real_file delete -force $TMP
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
