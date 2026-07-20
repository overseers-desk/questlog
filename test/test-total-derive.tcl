#!/usr/bin/env wish9.0
# The status line's grand total derives from the store at render (issue #64),
# not from a running sum maintained at seven mutation sites. This drives a
# SessionList over a small sandbox and asserts the derived total tracks the
# store through the paths that used to adjust the sum by hand: a coalesced
# cost-arrival batch, and a forget. A batch must also refresh the status exactly
# once (the boundary), not per row.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _totalderive_sandbox]
set FA "-tmp-totalderive"

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
set DIRA [file join $SAND .claude projects $FA]
::questlog::path::_real_file mkdir $DIRA
set ::env(HOME) $SAND

proc noop {args} {}
proc write_session {path ts} {
    set fh [open $path w]
    puts $fh "{\"type\":\"user\",\"cwd\":\"/tmp/proj\",\"timestamp\":\"${ts}Z\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}"
    puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}Z\",\"message\":{\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
    close $fh
}

set P {}
for {set i 1} {$i <= 3} {incr i} {
    set p [file join $DIRA [format s%02d $i].jsonl]
    set when [expr {[clock seconds] - $i*24*3600}]
    write_session $p [clock format $when -format "%Y-%m-%dT%H:%M:%S" -gmt 1]
    file mtime $p $when
    lappend P $p
}

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

set SL [::questlog::ui::SessionList new .s resolvef noop noop noop noop noop noop \
            scanpath noop subagentsf noop]
pack .s -fill both -expand 1
set ns [info object namespace $SL]

set fails 0
proc check {name got want} {
    if {$got eq $want} {
        puts "ok   - $name"
    } else {
        puts "FAIL - $name (got <$got> want <$want>)"
        incr ::fails
    }
}

# Stream the sessions in.
$SL apply_filter [dict create since 30d]
set ::scan_done 0
$::Scan extend [dict create since 30d]
after 200 [list set ::scan_done 1]
vwait ::scan_done

check "no cost yet, total is zero" [$SL total_cost] 0.0

# A coalesced batch of cost arrivals: the total derives to their sum, and the
# status is refreshed once for the whole flush (the boundary), not per row.
# refresh_status is the sole writer of StatusVar, so counting its writes counts
# the refreshes.
set ::flushes 0
set tcb {apply {{args} { incr ::flushes }}}
trace add variable [set ns]::StatusVar write $tcb
set batch [dict create \
    [lindex $P 0] [dict create cost_usd 0.50 turns 1 duration_secs 5 model_breakdown {}] \
    [lindex $P 1] [dict create cost_usd 0.25 turns 1 duration_secs 5 model_breakdown {}] \
    [lindex $P 2] [dict create cost_usd 1.00 turns 1 duration_secs 5 model_breakdown {}]]
$SL refresh_cost_batch $batch
trace remove variable [set ns]::StatusVar write $tcb

check "derived total sums the batch" [format %.2f [$SL total_cost]] 1.75
check "the batch refreshed the status once, not per row" $::flushes 1
check "the strip shows the derived figure" \
    [string match "*\$1.75*" [set ${ns}::StatusVar]] 1

# A forget drops that session's cost from the derived total with no bookkeeping.
$SL forget_session [lindex $P 2]
check "forget drops the derived total" [format %.2f [$SL total_cost]] 0.75

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
