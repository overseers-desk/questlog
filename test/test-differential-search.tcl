#!/usr/bin/env tclsh9.0
# Differential truth-table for session search.
#
# The same query is answered two ways - by the GUI engine (lib/scan.tcl Scan +
# lib/search.tcl Search, driven here exactly as the app drives it) and by the
# CLI engine (the real ./questlog --json subprocess) - over one fixture corpus
# with known properties. Each case asserts BOTH engines return the exact
# expected session set. They share lib/ but diverge in orchestration, so a
# scope filter the GUI search forgets (the `under` row-scope, which lives in
# filter::row_matches and the CLI applies but the GUI search corpus does not)
# shows up as a GUI-vs-truth and GUI-vs-CLI mismatch, not a silent pass.
#
# Pure Tcl, no Tk: QUESTLOG_SEARCH_THREADS=0 forces the single-thread coroutine
# search path so the GUI engine runs headless under one vwait. Fixture mtimes
# are relative to now, so the since-bound cases never rot.

package require Tcl 9
package require TclOO
package require json

set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT config.tcl]
source [file join $ROOT lib path.tcl]
source [file join $ROOT lib filter.tcl]
source [file join $ROOT lib jsonl.tcl]
source [file join $ROOT lib match.tcl]
source [file join $ROOT lib scan.tcl]
source [file join $ROOT lib search.tcl]

# The match procs read display caps from config; the launcher injects these for
# the real app's main interp, so do the same here for the in-process search.
::questlog::match::set_caps [dict create \
    content_cap     [::questlog::config::get content_cap] \
    snippet_lead    [::questlog::config::get snippet_lead] \
    snippet_trail   [::questlog::config::get snippet_trail] \
    tool_param_cap  [::questlog::config::get tool_param_cap] \
    tool_render_cap [::questlog::config::get tool_render_cap]]

set ::env(QUESTLOG_SEARCH_THREADS) 0

# Isolated corpus. HOME points the exec'd CLI at the same tree the in-process
# resolver returns, so both engines read one corpus.
set TMP /tmp/questlog-diff-test
set CORPUS [file join $TMP .claude projects]
proc ::questlog::path::projects_root {} { return $::CORPUS }
set ::env(HOME) $TMP

set fails 0
proc check {name expected actual} {
    if {$expected eq $actual} {
        puts "ok:   $name"
    } else {
        puts "FAIL: $name"
        puts "      expected: $expected"
        puts "      actual:   $actual"
        incr ::fails
    }
}

# ---- fixture --------------------------------------------------------

# A multi-turn session in $folder with cwd $cwd, the needle in its first user
# turn (so a keyword search hits), and an mtime $age_days before now.
proc write_session {folder uuid cwd needle age_days} {
    global CORPUS
    set dir [file join $CORPUS $folder]
    ::questlog::path::_real_file mkdir $dir
    set path [file join $dir $uuid.jsonl]
    set fh [open $path w]
    puts $fh "{\"type\":\"user\",\"cwd\":\"$cwd\",\"timestamp\":\"2026-06-20T10:00:00.000Z\",\"message\":{\"content\":\"first turn mentions $needle here\"}}"
    puts $fh "{\"type\":\"assistant\",\"timestamp\":\"2026-06-20T10:00:05.000Z\",\"message\":{\"content\":\"a reply\"}}"
    puts $fh "{\"type\":\"user\",\"cwd\":\"$cwd\",\"timestamp\":\"2026-06-20T10:01:00.000Z\",\"message\":{\"content\":\"a second turn\"}}"
    close $fh
    file mtime $path [expr {[clock seconds] - $age_days * 86400}]
    return $path
}

# Two project folders. PROJA is the in-scope project; PROJB stands in for the
# other project whose sessions an `under PROJA` scope must exclude.
set PROJA /home/test/code/proja
set PROJB /home/test/code/projb

::questlog::path::_real_file delete -force $TMP
# sA: under proja, hits "shimmer", recent.
write_session -home-test-code-proja aaaa $PROJA shimmer 2
# sN: under proja, but NO "shimmer" (content-filter control).
write_session -home-test-code-proja nnnn $PROJA plainword 2
# sB: under projb, hits "shimmer", recent.
write_session -home-test-code-projb bbbb $PROJB shimmer 2
# sC: under projb, hits "shimmer", but 40 days old (since control).
write_session -home-test-code-projb cccc $PROJB shimmer 40

# ---- engines --------------------------------------------------------

# uuids (sorted) of the sessions a path list names.
proc uuids {paths} {
    return [lsort [lmap p $paths { file rootname [file tail $p] }]]
}

# The GUI search engine: Scan + Search wired as the app wires them, collecting
# the matched session paths the way on_search_file does, run to completion under
# one vwait.
proc gui_search {snapshot} {
    set ::g_done 0
    set ::g_hits [dict create]
    set scan   [::questlog::Scan new {} {}]
    set search [::questlog::Search new $scan \
        [list apply {{matches} {
            foreach m $matches { dict set ::g_hits [dict get $m path] 1 }
        }}] \
        noop \
        [list apply {{total matches} { set ::g_done 1 }}]]
    set guard [after 15000 {set ::g_done 1}]
    $search start $snapshot
    vwait ::g_done
    after cancel $guard
    $search destroy
    $scan destroy
    return [uuids [dict keys $::g_hits]]
}
proc noop {args} {}

# The CLI engine: the real ./questlog --json subprocess (HOME points it at the
# fixture corpus), its folder/session JSON parsed back to a uuid set.
proc cli_search {argv} {
    global ROOT
    set json [exec [file join $ROOT questlog] --json {*}$argv 2> /dev/null]
    set paths [list]
    foreach folder [::json::json2dict $json] {
        foreach sess [dict get $folder sessions] {
            lappend paths [dict get $sess path]
        }
    }
    return [uuids $paths]
}

# One case: the same query through both engines, both asserted against truth,
# and the two engines asserted equal to each other.
proc run_case {name search since under truth} {
    set argv [list --search $search --since $since]
    set snap [dict create search $search search_case 0 search_regions any since $since]
    if {$under ne ""} {
        lappend argv --under $under
        dict set snap under [list $under]
    }
    set cli [cli_search $argv]
    set gui [gui_search $snap]
    check "$name / CLI == truth" $truth $cli
    check "$name / GUI == truth" $truth $gui
    check "$name / CLI == GUI"   $cli   $gui
}

# ---- truth table ----------------------------------------------------
#
# A: no scope            -> every shimmer session (sN has no needle).
# B: under proja         -> only sA; sB/sC are under projb. (THE under-in-search case)
# C: since 7d            -> sA, sB; sC is 40d old, pruned by the corpus bound.
# D: since 7d + under projb -> only sB; sA is under proja, sC is too old.

run_case "A all/no-under"       shimmer all {}     {aaaa bbbb cccc}
run_case "B all/under-proja"    shimmer all $PROJA {aaaa}
run_case "C 7d/no-under"        shimmer 7d  {}     {aaaa bbbb}
run_case "D 7d/under-projb"     shimmer 7d  $PROJB {bbbb}

::questlog::path::_real_file delete -force $TMP

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
