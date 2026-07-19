#!/usr/bin/env tclsh9.0
# Issue #45: an unresolvable project folder must be peeked ONCE per scan pass,
# not once per row. A folder fails to resolve when its directory is gone or when
# every session in it was moved in (each transcript's recorded cwd encodes to
# another folder's name), so peek_folder_cwd reads every .jsonl in it and learns
# nothing. Before the fix, stamp_subtree called resolve_folder once per row and
# nothing was cached, so a folder of N such rows read all N files N times (N^2
# transcript reads). The fix memoises the negative resolution for the pass.
#
# peek_folder_cwd is the only caller of ::questlog::jsonl::first_cwd, so counting
# first_cwd calls isolates peek reads from scan_one's own row reads: one peek of
# a fully-unresolvable N-file folder makes exactly N first_cwd calls, so a pass
# that reads the folder once totals N, and the unfixed once-per-row behaviour
# would total N^2.
package require Tcl 9
package require TclOO
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
source [file join $ROOT config.tcl]
source [file join $ROOT lib path.tcl]
source [file join $ROOT lib listfilter.tcl]
source [file join $ROOT lib jsonl.tcl]
source [file join $ROOT lib match.tcl]
source [file join $ROOT lib scan.tcl]
source [file join $ROOT lib cost.tcl]

set PROOT /tmp/questlog-negmemo-projects
proc ::questlog::path::projects_root {} { return /tmp/questlog-negmemo-projects }

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name  expected=<$expected>  actual=<$actual>"
        incr ::fails
    } else {
        puts "ok:   $name"
    }
}

# ---- fixture: one folder of N moved-in sessions -----------------------
# The folder basename names a directory that does not exist on disk, and every
# session records a cwd that encodes to a DIFFERENT basename (the source project
# it was moved from). So peek_folder_cwd never finds a self-consistent cwd and
# the filesystem walk finds no directory: the folder is unresolvable.
::questlog::path::_real_file delete -force $PROOT
set N 5
set gone -tmp-questlog-negmemo-9f3a2b-nowhere
::questlog::path::_real_file mkdir [file join $PROOT $gone]
for {set i 1} {$i <= $N} {incr i} {
    set fh [open [file join $PROOT $gone moved-$i.jsonl] w]
    chan configure $fh -encoding utf-8 -translation lf
    puts $fh {{"type":"user","message":{"role":"user","content":"moved in"},"cwd":"/tmp/questlog-negmemo-source-elsewhere","timestamp":"2026-05-01T10:00:00.000Z"}}
    close $fh
}

# Count peek reads by wrapping first_cwd, peek_folder_cwd's only file reader.
rename ::questlog::jsonl::first_cwd ::questlog::jsonl::_real_first_cwd
proc ::questlog::jsonl::first_cwd {path} {
    incr ::first_cwd_calls
    return [::questlog::jsonl::_real_first_cwd $path]
}

# No known_mtime callback: every path is scanned on every pass, so each pass
# stamps all N rows and thus calls resolve_folder N times for the one folder.
proc on_row {row} { lappend ::rows $row }
proc on_done {scanned} { set ::scan_done 1 }
set s [::questlog::Scan new on_row on_done]

# ---- pass 1: one peek, not N ------------------------------------------
set ::rows [list]
set ::scan_done 0
set ::first_cwd_calls 0
$s extend [dict create since all]
vwait ::scan_done
check pass1_rows $N [llength $::rows]
# N first_cwd calls == one peek of the folder. N^2 (25) would mean once per row.
check pass1_one_peek_per_pass $N $::first_cwd_calls
foreach r $::rows { check pass1_folder_unresolved "" [dict get $r folder_cwd] }

# ---- pass 2: the negative memo does not outlive the pass ---------------
# A fresh pass peeks again (a folder restored between passes must get a fresh
# chance), so it is one peek, not zero.
set ::rows [list]
set ::scan_done 0
set ::first_cwd_calls 0
$s extend [dict create since all]
vwait ::scan_done
check pass2_one_peek_again $N $::first_cwd_calls

$s destroy

rename ::questlog::jsonl::first_cwd {}
rename ::questlog::jsonl::_real_first_cwd ::questlog::jsonl::first_cwd
::questlog::path::_real_file delete -force $PROOT

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
