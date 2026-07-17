#!/usr/bin/env tclsh9.0
# Issue #45's requested measurement: what an unresolvable project folder
# actually costs a scan, before any cure is weighed.
#
# resolve_folder memoises only a folder that resolves; an unresolvable one
# (directory gone, or every session moved in from elsewhere) is re-resolved
# once per row, and each resolution peeks the folder - opening its transcripts
# until one's cwd re-encodes to the folder name, which in this case none ever
# does. Structurally that is N openings of N files per scan. The issue asks
# for the number on a real pass, not the structure: an unresolvable folder is
# uncommon, and a cure that caches costs the resolver its healing property
# (a Move depends on it), so nothing should be traded before the size of the
# cost is known. This prints transcript-open counts and wall time for a
# resolvable control folder and an unresolvable one at several sizes.
#
# bench- prefix: outside run-audit's test-*.tcl glob, run by hand:
#   tclsh9.0 test/bench-scan-resolve.tcl

package require Tcl 9
package require TclOO
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
source [file join $ROOT config.tcl]
source [file join $ROOT lib path.tcl]
source [file join $ROOT lib scope.tcl]
source [file join $ROOT lib sessionlist.tcl]
source [file join $ROOT lib jsonl.tcl]
source [file join $ROOT lib match.tcl]
source [file join $ROOT lib scan.tcl]
source [file join $ROOT lib cost.tcl]

set BASE /tmp/questlog-bench-resolve
proc ::questlog::path::projects_root {} { return $::BASE }

# Count every transcript open the resolver's peek performs: first_cwd is the
# one reader peek_folder_cwd calls per file.
rename ::questlog::jsonl::first_cwd ::questlog::jsonl::__first_cwd_real
proc ::questlog::jsonl::first_cwd {f} {
    incr ::OPENS
    return [::questlog::jsonl::__first_cwd_real $f]
}

# The caller supplies the exact recorded cwd: the folder-name and cwd
# derivations stay in ONE place (measure) - split across procs they drift,
# and a control whose cwd does not round-trip through encode_cwd (or whose
# directory is missing) silently degenerates into the unresolvable case it
# is meant to contrast.
proc build_folder {fname n cwd} {
    set dir [file join $::BASE $fname]
    ::questlog::path::_real_file mkdir $dir
    for {set i 0} {$i < $n} {incr i} {
        set fh [open [file join $dir s$i.jsonl] w]
        puts $fh "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"prompt $i\"},\"cwd\":\"$cwd\",\"timestamp\":\"2026-04-25T10:00:00.000Z\"}"
        close $fh
    }
}

proc on_row {row} {}
proc on_done {args} { set ::scan_done 1 }

proc measure {name n resolvable} {
    ::questlog::path::_real_file delete -force $::BASE ${::BASE}-cwds
    if {$resolvable} {
        # A resolvable control needs its cwd to round-trip: the recorded cwd
        # must encode to the folder's own name and its directory must exist,
        # or resolve_folder's memo never engages.
        set cwd "${::BASE}-cwds/$name"
        set fname [::questlog::path::encode_cwd $cwd]
        ::questlog::path::_real_file mkdir $cwd
    } else {
        # The shape questlog's own Move leaves: every recorded cwd encodes
        # to some OTHER folder's name.
        set cwd "/tmp/somewhere/else/entirely"
        set fname "-tmp-orphan-$name"
    }
    build_folder $fname $n $cwd
    set ::OPENS 0
    set ::scan_done 0
    set s [::questlog::Scan new on_row on_done]
    set t0 [clock microseconds]
    $s extend [dict create since all]
    vwait ::scan_done
    set ms [expr {([clock microseconds] - $t0) / 1000}]
    puts [format "| %-12s | %4d | %6d | %7d |" \
        [expr {$resolvable ? "resolvable" : "unresolvable"}] $n $::OPENS $ms]
    $s destroy
}

puts "| folder       |    N |  opens | scan ms |"
puts "|--------------|------|--------|---------|"
foreach n {5 25 100} {
    measure ctl$n $n 1
    measure orphan$n $n 0
}
::questlog::path::_real_file delete -force $::BASE ${::BASE}-cwds
