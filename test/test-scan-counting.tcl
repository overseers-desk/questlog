#!/usr/bin/env wish9.0
# The list strip's "and counting…" cost suffix during a corpus scan (issue #54).
#
# The suffix marks a provisional total. Before the fix it rode the search-only
# Busy flag, so a plain browse scan accrued cost silently. The list now carries a
# distinct ScanBusy flag (scan_begin..scan_end, driven by app.tcl around the
# corpus scan); the suffix shows while a search OR the scan is in flight and
# clears only when both settle. This drives those flags directly and asserts the
# suffix appears during the scan and disappears at scan end and search end.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _scancount_sandbox]
set FA "-tmp-scancount"

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

proc session_moment {days_ago} { return [expr {[clock seconds] - $days_ago*24*3600}] }
set P {}
for {set i 1} {$i <= 2} {incr i} {
    set p [file join $DIRA [format s%02d $i].jsonl]
    set when [session_moment $i]
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
        puts "FAIL - $name"
        puts "       got:  $got"
        puts "       want: $want"
        incr ::fails
    }
}
proc counting {} {
    return [string match "*and counting*" [set ${::ns}::StatusVar]]
}

# Stream the sessions so the model carries a non-zero cost total, then give each
# a cost so the strip's cost clause is present at all.
$SL apply_filter [dict create since 30d]
set ::scan_done 0
$::Scan extend [dict create since 30d]
after 200 [list set ::scan_done 1]
vwait ::scan_done
foreach p $P {
    $SL refresh_cost $p [dict create cost_usd 0.5 turns 1 duration_secs 5 model_breakdown {}]
}
check "cost is shown at rest" \
    [string match "*\$1.00*" [set ${ns}::StatusVar]] 1
check "no counting suffix at rest" [counting] 0

# ---- scan in flight: the suffix appears -----------------------------------
$SL scan_begin
check "the suffix appears during the corpus scan" [counting] 1

# ---- a search overlapping the scan keeps the suffix -----------------------
$SL set_progress 1 2 0
check "the suffix stays while a search runs too" [counting] 1

# ---- search ends but the scan is still in flight: suffix stays ------------
$SL set_done 2 0
check "the suffix stays after search end while the scan runs" [counting] 1

# ---- scan ends: the suffix clears -----------------------------------------
$SL scan_end
check "the suffix clears at scan end" [counting] 0

# ---- the search-only path still clears at search end ----------------------
$SL set_progress 1 2 0
check "a lone search shows the suffix" [counting] 1
$SL set_done 2 0
$SL refresh_status
check "the suffix clears at search end" [counting] 0

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
