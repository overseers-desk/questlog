#!/usr/bin/env wish9.0
# streamtree benchmark. Prints a markdown table: median over 3 in-process
# iterations with the min-max spread (fresh widget each iteration; the first
# iteration carries bytecode compilation and allocator warmup, which the
# median discards), plus per-N memory medians from fresh child processes.
# Run it headless: DISPLAY=:99 wish9.0 test/bench-streamtree.tcl
#
# What each scenario honestly measures (the captions in the output table
# repeat this; keep them in sync):
#   S1 bulk flat    N root rows, no event-loop entry, one flush at the end;
#                   any widget batched this way also flushes once
#   S2 bulk treed   100 expanded folders x N/100 children, same shape
#   S3 streaming    10k treed resident, reader mid-list, 1000 single bracketed
#                   inserts into the topmost folder (above the viewport), one
#                   idle flush per insert under a live event loop. Arrivals
#                   land above the view and the anchor re-pins it, so this is
#                   insert + scroll-re-pin cost, not row rasterisation; the
#                   assertion is that the reader's top line held.
#   S4 rebuild      one full rebuild at 10k treed (the debounced resort's cost)
#   S5 treeview     bulk and streaming-shaped inserts into ttk::treeview. Its
#                   streaming number includes the repaint its shifting scroll
#                   causes; streamtree's includes the anchor work that prevents
#                   the shift. Honest per-arrival costs of each widget while a
#                   reader sits mid-list, not a controlled microbenchmark.
#   memory          VmRSS delta, median of 3 fresh processes per point. The
#                   whole-widget delta divided by N bundles fixed widget cost
#                   into per-row, so the marginal row uses the 10k->50k slope.
#                   streamtree retains the payload dict per row (it doubles as
#                   the app's model); treeview holds display text only.
#
# The engine benchmarked is the BASE class: one text string per row, no
# metadata columns, no per-row bindings. A subclass with columns and wired
# rows pays more per row.

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add $ROOT
package require streamtree

proc rss_kb {} {
    set fh [open /proc/self/status r]; set s [read $fh]; close $fh
    regexp {VmRSS:\s+(\d+) kB} $s -> kb
    return $kb
}
proc median3 {vals} { return [lindex [lsort -real $vals] 1] }
proc ms {us} { return [format %.0f [expr {$us / 1000.0}]] }
# "median (min-max)" in ms, from three raw microsecond samples.
proc spread_ms {vals} {
    set s [lsort -real $vals]
    return "[ms [lindex $s 1]] ms ([ms [lindex $s 0]]-[ms [lindex $s 2]])"
}
proc usrow {us n} { return [format %.1f [expr {double($us) / $n}]] }

# ---- child mode: build one corpus, print RSS delta, exit --------------------
if {[llength $argv] == 3 && [lindex $argv 0] eq "childmem"} {
    lassign $argv - kind n
    update
    set before [rss_kb]
    if {$kind eq "streamtree"} {
        pack [ttk::frame .f] -fill both -expand 1
        set d [::streamtree::StreamTree new]
        $d setup .f
        $d anchor_save
        for {set i 0} {$i < $n} {incr i} {
            $d insert "" row r$i [dict create label "row $i, a plausible label"]
        }
        $d anchor_restore
    } else {
        ttk::treeview .tv
        pack .tv -fill both -expand 1
        for {set i 0} {$i < $n} {incr i} {
            .tv insert {} end -text "row $i, a plausible label"
        }
    }
    update
    puts [expr {[rss_kb] - $before}]
    exit 0
}

# ---- scenario bodies --------------------------------------------------------
proc fresh {} {
    catch {destroy .f}
    pack [ttk::frame .f] -fill both -expand 1
    set d [::streamtree::StreamTree new]
    $d setup .f
    update
    if {![winfo viewable .f.body.t]} { error "text widget not viewable; timings would omit paint" }
    return $d
}
proc teardown {d} { $d destroy; destroy .f; update }

proc bulk_flat {n} {
    set d [fresh]
    set t0 [clock microseconds]
    $d anchor_save
    for {set i 0} {$i < $n} {incr i} {
        $d insert "" row r$i [dict create label "row $i, a plausible label"]
    }
    $d anchor_restore
    update
    # Force the async line-metric pass to complete inside the timed region, so
    # the number provably includes full layout on every Tk build.
    .f.body.t count -update -ypixels 1.0 end
    set us [expr {[clock microseconds] - $t0}]
    teardown $d
    return $us
}

proc build_treed {d nfold nchild} {
    for {set f 0} {$f < $nfold} {incr f} {
        set fid [$d insert "" folder f$f [dict create label "folder $f"]]
        $d node_set $fid expanded 1
        for {set c 0} {$c < $nchild} {incr c} {
            $d insert $fid row f$f/c$c [dict create label "row $c of folder $f"]
        }
    }
}
proc bulk_treed {n} {
    set d [fresh]
    set t0 [clock microseconds]
    $d anchor_save
    build_treed $d 100 [expr {$n / 100}]
    $d anchor_restore
    update
    .f.body.t count -update -ypixels 1.0 end
    set us [expr {[clock microseconds] - $t0}]
    teardown $d
    return $us
}

# Streaming: returns {total_us p95_us held} where held is 1 when the reader's
# top line text is unchanged through 1000 above-viewport inserts.
proc streaming {} {
    set d [fresh]
    $d anchor_save
    build_treed $d 100 100
    $d anchor_restore
    update
    set T .f.body.t
    $T yview moveto 0.5
    update
    set line0 [$T get @0,0 "@0,0 lineend"]
    set target [lindex [$d roots] 0]
    set lat [list]
    set t0 [clock microseconds]
    for {set i 0} {$i < 1000} {incr i} {
        set s [clock microseconds]
        $d anchor_save
        $d insert $target row stream$i [dict create label "streamed arrival $i"]
        $d anchor_restore
        update idletasks
        lappend lat [expr {[clock microseconds] - $s}]
    }
    set total [expr {[clock microseconds] - $t0}]
    set held [expr {[$T get @0,0 "@0,0 lineend"] eq $line0}]
    teardown $d
    set lat [lsort -integer $lat]
    return [list $total [lindex $lat 949] $held]
}

proc rebuild10k {} {
    set d [fresh]
    $d anchor_save
    build_treed $d 100 100
    $d anchor_restore
    update
    set t0 [clock microseconds]
    $d rebuild
    update
    .f.body.t count -update -ypixels 1.0 end
    set us [expr {[clock microseconds] - $t0}]
    teardown $d
    return $us
}

proc tv_fresh {} {
    catch {destroy .tv}
    ttk::treeview .tv
    pack .tv -fill both -expand 1
    update
    if {![winfo viewable .tv]} { error "treeview not viewable; timings would omit paint" }
}
proc tv_bulk {n} {
    tv_fresh
    set t0 [clock microseconds]
    for {set i 0} {$i < $n} {incr i} {
        .tv insert {} end -text "row $i, a plausible label"
    }
    update
    .tv yview
    return [expr {[clock microseconds] - $t0}]
}
proc tv_stream {} {
    tv_fresh
    for {set i 0} {$i < 10000} {incr i} { .tv insert {} end -text "row $i" }
    update
    .tv yview moveto 0.5
    update
    set lat [list]
    set t0 [clock microseconds]
    for {set i 0} {$i < 1000} {incr i} {
        set s [clock microseconds]
        .tv insert {} 0 -text "streamed arrival $i"
        update idletasks
        lappend lat [expr {[clock microseconds] - $s}]
    }
    set total [expr {[clock microseconds] - $t0}]
    set lat [lsort -integer $lat]
    return [list $total [lindex $lat 949]]
}

proc childmem_median {kind n} {
    set vals [list]
    foreach - {1 2 3} {
        lappend vals [exec [info nameofexecutable] [info script] childmem $kind $n]
    }
    return [median3 $vals]
}

# ---- the matrix --------------------------------------------------------------
set cpu unknown
catch {
    set fh [open /proc/cpuinfo r]; set ci [read $fh]; close $fh
    regexp {model name\s*:\s*([^\n]+)} $ci -> cpu
}
puts "Tcl [info patchlevel], Tk [package present Tk], $cpu,\
[exec uname -sr], Xvfb (software rendering). Base engine: one text string per\
row, no columns, no per-row bindings."
puts ""
puts "| scenario | N | median (min-max) | per row | notes |"
puts "|---|---|---|---|---|"

foreach n {1000 10000 50000} {
    set v [list [bulk_flat $n] [bulk_flat $n] [bulk_flat $n]]
    puts "| streamtree bulk, flat | $n | [spread_ms $v] | [usrow [median3 $v] $n] µs | single flush for the whole batch |"
}
foreach n {10000 50000} {
    set v [list [bulk_treed $n] [bulk_treed $n] [bulk_treed $n]]
    puts "| streamtree bulk, treed | $n | [spread_ms $v] | [usrow [median3 $v] $n] µs | 100 expanded folders, single flush |"
}
foreach n {10000 50000} {
    set v [list [tv_bulk $n] [tv_bulk $n] [tv_bulk $n]]
    puts "| ttk::treeview bulk, flat | $n | [spread_ms $v] | [usrow [median3 $v] $n] µs | display text only, single flush |"
}

set totals [list]; set p95s [list]; set helds [list]
foreach - {1 2 3} {
    lassign [streaming] t p h
    lappend totals $t; lappend p95s $p; lappend helds $h
}
set tot [median3 $totals]
set rate [format %.0f [expr {1000.0 / ($tot / 1000000.0)}]]
set allheld [expr {[lindex [lsort -integer $helds] 0] == 1}]
puts "| streamtree streaming | 10k + 1000 | $rate inserts/s | p95 [usrow [median3 $p95s] 1] µs | idle flush per insert; arrivals above the view: insert + re-pin, not row rasterisation; reader's line held: [expr {$allheld ? "yes" : "NO"}] |"

set tvtotals [list]; set tvp95s [list]
foreach - {1 2 3} {
    lassign [tv_stream] t p
    lappend tvtotals $t; lappend tvp95s $p
}
set tvrate [format %.0f [expr {1000.0 / ([median3 $tvtotals] / 1000000.0)}]]
puts "| ttk::treeview streaming | 10k + 1000 | $tvrate inserts/s | p95 [usrow [median3 $tvp95s] 1] µs | scroll shifts each insert; number includes that repaint |"

set v [list [rebuild10k] [rebuild10k] [rebuild10k]]
puts "| streamtree full rebuild | 10k | [spread_ms $v] | [usrow [median3 $v] 10000] µs | the debounced resort's cost |"

set memo [dict create]
foreach kind {streamtree treeview} {
    foreach n {10000 50000} {
        set kb [childmem_median $kind $n]
        dict set memo $kind $n $kb
        puts "| $kind memory | $n | [format %.1f [expr {$kb / 1024.0}]] MB | [format %.2f [expr {double($kb) / $n}]] kB/row | whole-widget VmRSS delta, median of 3 processes |"
    }
    set marg [expr {double([dict get $memo $kind 50000] - [dict get $memo $kind 10000]) / 40000}]
    puts "| $kind memory, marginal row | 10k->50k | | [format %.2f $marg] kB/row | slope; fixed widget cost cancelled |"
}
puts ""
puts "streamtree rows retain the payload dict (the app's model), a per-row tag\
 and two position marks; treeview rows hold display text only."

if {!$allheld} { exit 1 }
exit 0
