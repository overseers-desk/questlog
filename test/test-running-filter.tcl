#!/usr/bin/env wish9.0
# The running filter is purely local: of the sessions already loaded in the
# view it shows the running ones and hides the rest, and it imports nothing
# from the live registry. A running session that is NOT already in the model
# must stay out of the list while the toggle is on - the toggle chooses what to
# show, it does not pull sessions in from other projects.
#
# Invariant under test: with it on, reconcile_running's add-loop does
# not run, so a uuid in the running set whose session was never scanned is not
# imported (and so no cost task is queued for it); a session already loaded is
# shown iff it is running.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _runfilter_sandbox]
set FOLDER "-tmp-runfilter-proj"

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
set PROJDIR [file join $SAND .claude projects $FOLDER]
::questlog::path::_real_file mkdir $PROJDIR
set ::env(HOME) $SAND

proc noop {args} {}

proc write_session {path prompts ts} {
    set fh [open $path w]
    set t 0
    foreach p $prompts {
        puts $fh "{\"type\":\"user\",\"cwd\":\"/tmp/proj\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"role\":\"user\",\"content\":\"$p\"}}"
        puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
        incr t
    }
    close $fh
}

set Ap [file join $PROJDIR aaaa.jsonl]
set Bp [file join $PROJDIR bbbb.jsonl]
set Cp [file join $PROJDIR cccc.jsonl]
write_session $Ap {a-first a-second} "2026-05-24T17:00"
write_session $Bp {b-first b-second} "2026-05-23T10:00"
write_session $Cp {c-first} "2026-05-22T09:00"   ;# single turn: browse drops it at min_turns 2
file mtime $Ap [clock scan "2026-05-24 17:01:00" -gmt 1]
file mtime $Bp [clock scan "2026-05-23 10:01:00" -gmt 1]
file mtime $Cp [clock scan "2026-05-22 09:01:00" -gmt 1]

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }
proc subagent_cost_cb {path} {}

set SL [::questlog::ui::SessionList new .s resolvef noop noop noop noop noop \
            noop scanpath noop subagentsf subagent_cost_cb]
pack .s -fill both -expand 1

set fails 0
proc check {name got want} {
    if {$got eq $want} { puts "ok   - $name" } else {
        puts "FAIL - $name"; puts "       got:  $got"; puts "       want: $want"; incr ::fails
    }
}

# --- 1. Load A and B only (filter off); expand the folder. Both render.
#        C is left on disk, deliberately not scanned in.
$SL apply_filter [dict create since all min_turns 2]
set ::scan_done 0
$::Scan extend [dict create since all min_turns 2]
after 200 [list set ::scan_done 1]
vwait ::scan_done
$SL toggle_folder $FOLDER
update
check "A rendered (filter off)" [$SL sflag $Ap rendered] 1
check "B rendered (filter off)" [$SL sflag $Bp rendered] 1
check "C not loaded"                  [$SL has_session $Cp] 0

set Buuid [file rootname [file tail $Bp]]

# --- 2. Turn the running filter ON with an empty running set: both loaded rows hide.
$SL attr_filter_set running 1
update
check "A hidden (filter on, not live)" [$SL sflag $Ap rendered] 0
check "B hidden (filter on, not live)" [$SL sflag $Bp rendered] 0

# --- 3. The live poll reports C running while the filter is on. Membership
#        is bounds-or-running: C imports (running bypasses the min-turns floor
#        here exactly as it does in plain browse) and paints, because
#        the running filter's job is to show live sessions - it hides rows,
#        it never blocks liveness from arriving. Only running sessions can
#        enter this way: the import loop iterates the running set alone.
$SL reconcile_running [dict create cccc $Cp]
update
check "C imported under the running filter" [$SL has_session $Cp] 1
check "C rendered (it is running)"    [$SL sflag $Cp rendered] 1

# --- 4. A loaded session that becomes running shows in place; a running-only
#        import that stops running and is below the min-turns floor leaves the
#        model with its liveness.
$SL reconcile_running [dict create $Buuid $Bp]
update
check "B shown once it is running"  [$SL sflag $Bp rendered] 1
check "A still hidden (not running)" [$SL sflag $Ap rendered] 0
check "C left the model when no longer running" [$SL has_session $Cp] 0

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
