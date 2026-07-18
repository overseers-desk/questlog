#!/usr/bin/env wish9.0
# Soak the StreamTree mark contract under the four concurrent drivers that, before
# the engine owned its marks, could desync one against another: the streaming
# scan (on_scan_row), the running poll (reconcile_running), the async cost flush
# (refresh_cost), and a width change (relayout). With the audit gate on, every
# primitive checks the per-folder mark invariant; this interleaves the drivers
# over many iterations and asserts the invariant never trips and that the buffer
# returns to its empty-baseline mark count once the model is cleared.

package require Tcl 9
package require Tk

set ::env(STREAMTREE_AUDIT) 1
set SAND [file join [pwd] _soak_sandbox]
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

# Three folders, a handful of multi-turn sessions each, descending mtimes.
set paths [list]
set fno 0
foreach folder {proj-a proj-b proj-c} {
    incr fno
    set dir [file join $SAND .claude projects -tmp-soak-$folder]
    ::questlog::path::_real_file mkdir $dir
    for {set i 0} {$i < 4} {incr i} {
        set p [file join $dir [format "s%d%d.jsonl" $fno $i]]
        write_session $p [list "$folder-q$i" "$folder-q$i-b"] [format "2026-05-%02dT1%d:00" [expr {28 - $fno}] $i]
        file mtime $p [clock scan [format "2026-05-%02d 1%d:01:00" [expr {28 - $fno}] $i] -gmt 1]
        lappend paths $p
    }
}

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
proc tripped {} { return [expr {[info exists ::STREAMTREE_AUDIT_TRIPPED] ? 1 : 0}] }
proc live_marks {} {
    set n 0
    foreach m [.s.body.t mark names] {
        if {[string match {node*_s} $m] || [string match {node*_e} $m]} { incr n }
    }
    return $n
}

set FILTER [dict create since all min_turns 2]

# Driver 1: streaming scan brings every session in.
$SL apply_filter $FILTER
$Scan extend $FILTER
update
check "all sessions streamed in, invariant clean" 0 [tripped]
check "domain audit clean after stream" [$SL audit] {}

# Expand every folder so sessions, costs and resizes all touch rendered rows.
foreach folder {proj-a proj-b proj-c} {
    if {[$SL has_folder -tmp-soak-$folder]} { $SL toggle_folder -tmp-soak-$folder }
}
update

set uuids [lmap p $paths { $SL sget $p uuid }]
set n [llength $paths]
set widths {1500 900 1200 700 1400}
set sorts {date cost turns date duration}

# Interleave the four drivers over many iterations. The mix is keyed off the
# loop index, so the run is deterministic and reproducible.
for {set k 0} {$k < 60} {incr k} {
    # Driver 2: the running poll, with a churning running set.
    set run [dict create]
    for {set j [expr {$k % $n}]} {$j < $n} {incr j 3} {
        dict set run [lindex $uuids $j] [lindex $paths $j]
    }
    $SL reconcile_running $run

    # Driver 3: an async cost result lands on a rotating session.
    set p [lindex $paths [expr {$k % $n}]]
    $SL refresh_cost $p [dict create cost_usd [expr {1.0 + ($k % 7)}] \
        turns [expr {3 + ($k % 5)}] duration_secs [expr {30 + $k}] \
        human_secs [expr {10 + $k}] model "claude-3-5-sonnet-20241022"]

    # Driver 4: a width change re-fits every rendered row.
    .s.body.t configure -width [lindex $widths [expr {$k % [llength $widths]}]]
    $SL relayout

    # A sort change every few ticks reseats the whole list through rebuild.
    if {$k % 5 == 0} { $SL set_sort [lindex $sorts [expr {$k % [llength $sorts]}]] }
    # Fold a folder shut and open again, exercising collapse/expand mid-soak.
    if {$k % 7 == 0} {
        $SL toggle_folder -tmp-soak-proj-b
        $SL toggle_folder -tmp-soak-proj-b
    }
    update
    if {[tripped]} { check "iteration $k kept the invariant" 1 0; break }
    # The domain audit rides beside the mark invariant: after every operation
    # the store's reverse indices, child lists and folder aggregates agree.
    if {[llength [$SL audit]]} { check "iteration $k domain audit clean" [$SL audit] {}; break }
}
check "60 interleaved driver iterations kept the invariant" 0 [tripped]
check "60 interleaved driver iterations kept the domain audit clean" [$SL audit] {}

# Clearing the model returns the buffer to its empty-baseline mark count.
$SL clear
update
check "cleared model leaks no position marks" 0 [live_marks]
check "invariant still clean after clear" 0 [tripped]
check "domain audit clean after clear" [$SL audit] {}

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
