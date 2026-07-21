#!/usr/bin/env wish9.0
# The model filter as the engine evaluates it (attr_admits over a session node),
# the one filter evaluator. The model filter's state is the excluded-label list:
# a row hides when its model is known AND on that list, so one model can be
# excluded while the rest stay, and a label first seen after the reader chose
# shows by default. A row whose model is empty or absent stays, because the cost
# pass fills models in after the row lands and hiding on absence would flicker the
# list as it does. Here the state is set through the engine (attr_filter_set) and
# read through attr_admits on the node, not through any second predicate.
#
# It composes with running and bookmarked exactly as the engine ANDs its filters:
# a row shows only when every active filter admits it.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _modelfilter_sandbox]
set FOLDER "-tmp-modelfilter-proj"

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
set ::questlog_config_only 1; source [file join $ROOT questlog]
foreach f {lib/cost.tcl ui/theme.tcl lib/path.tcl lib/listfilter.tcl \
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

proc write_session {path model ts} {
    set fh [open $path w]
    foreach p {first second} {
        puts $fh "{\"type\":\"user\",\"cwd\":\"/tmp/proj\",\"timestamp\":\"${ts}Z\",\"message\":{\"role\":\"user\",\"content\":\"$p\"}}"
        puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}Z\",\"message\":{\"model\":\"$model\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
    }
    close $fh
}

# A: opus. B: sonnet, bookmarked. C: sonnet but its cost pass never lands, so its
# node model stays "" - the absent/pending case.
set Ap [file join $PROJDIR aaaa.jsonl]
set Bp [file join $PROJDIR bbbb.jsonl]
set Cp [file join $PROJDIR cccc.jsonl]
write_session $Ap "claude-opus-4-20250514"     "2026-05-24T17:00:00"
write_session $Bp "claude-3-5-sonnet-20241022" "2026-05-23T10:00:00"
write_session $Cp "claude-3-5-sonnet-20241022" "2026-05-22T09:00:00"
file mtime $Ap [clock scan "2026-05-24 17:01:00" -gmt 1]
file mtime $Bp [clock scan "2026-05-23 10:01:00" -gmt 1]
file mtime $Cp [clock scan "2026-05-22 09:01:00" -gmt 1]
::questlog::path::set_bookmark $Bp

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

set SL [::questlog::ui::SessionList new .s resolvef noop noop noop noop noop \
            noop scanpath noop subagentsf noop]
pack .s -fill both -expand 1

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
# 1 iff the engine admits the session at $path under the active filters.
proc admits {path} { return [$::SL attr_admits [$::SL sid $path]] }

# Load all three into the model.
$SL apply_filter [dict create since all min_turns 2]
set ::scan_done 0
$::Scan extend [dict create since all min_turns 2]
after 300 [list set ::scan_done 1]
vwait ::scan_done

# Land the model labels the cost pass would, on A and B only. C keeps a "" model.
foreach {p m} [list $Ap {Opus} $Bp {Sonnet}] {
    $SL refresh_cost $p [dict create cost_usd 0.01 model $m]
}
update
check "A carries the Opus label"   [$SL sget $Ap model] Opus
check "B carries the Sonnet label"  [$SL sget $Bp model] Sonnet
check "C carries no model yet"       [$SL sget $Cp model] ""

# ---- nothing excluded: every row shows, whatever its model says --------------
check nothing_excluded_a [admits $Ap] 1
check nothing_excluded_b [admits $Bp] 1
check nothing_excluded_absent [admits $Cp] 1

# ---- one label excluded: only the known carrier hides -----------------------
$SL attr_filter_set model [list Sonnet]
check excluded_hides   [admits $Bp] 0
check others_stay      [admits $Ap] 1
check absent_stays     [admits $Cp] 1

# ---- several labels, several cuts; the unknown-model row survives them all ----
$SL attr_filter_set model [list Sonnet Opus]
check both_excluded_a [admits $Ap] 0
check both_excluded_b [admits $Bp] 0
check unknown_survives_full_cut [admits $Cp] 1

# ---- a label no row carries cuts nothing (a late-loading model shows) --------
$SL attr_filter_set model [list Haiku]
check absent_label_cuts_nothing_a [admits $Ap] 1
check absent_label_cuts_nothing_b [admits $Bp] 1
$SL attr_filter_set model [list]

# ---- composes with the bookmarked filter: both clauses must admit the row ----
# B is the only bookmarked row. With bookmarked on, A and C hide; add the model
# cut and B hides too, so no row shows - the clauses AND.
$SL attr_filter_set bookmarked 1
check bm_keeps_bookmarked [admits $Bp] 1
check bm_hides_plain_a    [admits $Ap] 0
$SL attr_filter_set model [list Sonnet]
check bm_and_excluded_hides_b [admits $Bp] 0
$SL attr_filter_set model [list]
$SL attr_filter_set bookmarked 0

# ---- composes with the running filter: liveness and the exclusion both gate --
# Mark A and B running. Running-only keeps both; excluding Sonnet then drops B,
# and A (running, not excluded) stays. C is neither running nor excluded, but the
# running filter alone already hides it.
$SL reconcile_running [dict create [file rootname [file tail $Ap]] $Ap [file rootname [file tail $Bp]] $Bp]
$SL attr_filter_set running 1
check run_keeps_live_a  [admits $Ap] 1
check run_keeps_live_b  [admits $Bp] 1
check run_hides_idle_c  [admits $Cp] 0
$SL attr_filter_set model [list Sonnet]
check run_and_excluded_hides_b [admits $Bp] 0
check run_and_kept_a           [admits $Ap] 1
$SL attr_filter_set model [list]
$SL attr_filter_set running 0
$SL reconcile_running [dict create]

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
