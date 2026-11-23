#!/usr/bin/env tclsh9.0
# The CLI run from the layout the packages install. The .deb, the .rpm and the
# Homebrew formula put the launcher in a bin directory and its tree in a share
# directory, rewriting the launcher's ROOT line to the tree, which holds no copy
# of the launcher. The CLI's pool workers source the launcher for its config, so
# they must reach it where it ran. This builds that layout over the checkout and
# runs a query wide enough to start the pool.
# Run:
#   tclsh9.0 test/test-cli-packaged-layout.tcl
package require Tcl 9
package require json

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
set failures 0
proc check {name got want} {
    if {$got eq $want} {
        puts "ok   - $name"
    } else {
        puts "FAIL - $name"
        puts "       got:  $got"
        puts "       want: $want"
        incr ::failures
    }
}

# Per-process, so two suite runs on one host do not delete each other's tree.
set TMP /tmp/questlog-packaged-test-[pid]
file delete -force $TMP
set ::env(HOME) $TMP
unset -nocomplain ::env(CLAUDE_CONFIG_DIR)

# The share tree: the checkout's directories, with no launcher among them.
set share [file join $TMP share]
file mkdir $share
foreach d {lib ui cli data modules vendor assets} {
    file link -symbolic [file join $share $d] [file join $ROOT $d]
}

# The launcher in its bin directory, its ROOT line rewritten as the packages do.
set fh [open [file join $ROOT questlog]]
set src [read $fh]
close $fh
regsub -line {^set ROOT .*$} $src "set ROOT $share" src
set launcher [file join $TMP bin questlog]
file mkdir [file dirname $launcher]
set fh [open $launcher w]
puts -nonewline $fh $src
close $fh
file attributes $launcher -permissions 0755

# Six sessions: with two workers, more than the two per worker the CLI needs
# before it prices on its pool.
set usage {"model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":1000,"output_tokens":500}}
for {set i 0} {$i < 6} {incr i} {
    set path [file join $TMP .claude projects -work-pkg \
        [format 55555555-5555-5555-5555-5555555555%02d.jsonl $i]]
    file mkdir [file dirname $path]
    set fh [open $path w]
    puts $fh "{\"type\":\"user\",\"cwd\":\"/work/pkg\",\"timestamp\":\"2026-06-21T11:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"pkgmark\"}}"
    puts $fh "{\"type\":\"assistant\",\"timestamp\":\"2026-06-21T11:00:30.000Z\",\"message\":{$usage,\"content\":\"pkgmark\"}}"
    close $fh
}

set ::env(QUESTLOG_THREADS) 2
set rc [catch {exec -ignorestderr $launcher --json --keyword pkgmark --since all} out]
unset ::env(QUESTLOG_THREADS)
check "a launcher apart from its tree: the pool's workers load the config" $rc 0
if {!$rc} {
    check "a launcher apart from its tree: every session is priced" \
        [dict get [lindex [::json::json2dict $out] 0] totals sessions] 6
}

file delete -force $TMP
if {$failures > 0} {
    puts "$failures failures"
}
exit $failures
