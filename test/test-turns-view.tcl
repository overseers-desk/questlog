#!/usr/bin/env wish9.0
# The toolbar's turns floor is a view filter: a session below it stays in the
# store, priced and counted in the grand total, and only its rendering is
# suppressed, the heading narrowing to what it shows. Moving the floor re-derives the view over
# the loaded rows in place - no rescan, no re-read. (The min_turns snapshot
# key stays a row_in_bounds bound; test-scan.tcl guards that side.)

package require Tcl 9
package require Tk

set SAND [file join [pwd] _turnsview_sandbox]
set FOLDER "-tmp-turnsview-proj"

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
set ::questlog_config_only 1; source [file join $ROOT questlog]
foreach f {lib/cost.tcl ui/theme.tcl lib/path.tcl lib/listfilter.tcl \
           lib/match.tcl ui/terminal.tcl ui/live.tcl lib/scan.tcl lib/search.tcl \
           ui/drag.tcl ui/toolbar.tcl ui/reveal.tcl ui/sessions.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init
::questlog::cost::load_rates $ROOT

::questlog::path::_real_file delete -force $SAND
set PROJDIR [file join $SAND .claude projects $FOLDER]
::questlog::path::_real_file mkdir $PROJDIR
set ::env(HOME) $SAND
unset -nocomplain ::env(CLAUDE_CONFIG_DIR)

proc noop {args} {}

proc write_session {path prompts ts} {
    set fh [open $path w]
    set t 0
    foreach p $prompts {
        puts $fh "{\"type\":\"user\",\"cwd\":\"/tmp/proj\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"role\":\"user\",\"content\":\"$p\"}}"
        puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"model\":\"claude-sonnet-4-6\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
        incr t
    }
    close $fh
}

set ONE   [file join $PROJDIR aaaa.jsonl]
set THREE [file join $PROJDIR bbbb.jsonl]
write_session $ONE   {only-turn}                   "2026-06-10T17:00"
write_session $THREE {b-first b-second b-third}    "2026-06-09T10:00"
# In a folder of its own, one turn kept and one a rewind abandoned: the user
# asked "rolled", got an answer, rewound to the session's start and asked
# "kept". The scan's running count is 2; the cost pass counts the 1 turn kept.
set REWDIR [file join $SAND .claude projects -tmp-rewound]
::questlog::path::_real_file mkdir $REWDIR
set REW [file join $REWDIR cccc.jsonl]
set fh [open $REW w]
puts $fh {{"parentUuid":null,"isSidechain":false,"type":"system","subtype":"local_command","content":"session start","uuid":"s0","timestamp":"2026-06-08T09:59:59Z"}}
puts $fh {{"parentUuid":"s0","isSidechain":false,"promptSource":"typed","cwd":"/tmp/rewound","type":"user","message":{"role":"user","content":"rolled"},"uuid":"p1","timestamp":"2026-06-08T10:00:00Z"}}
puts $fh {{"parentUuid":"p1","isSidechain":false,"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":50}},"uuid":"a1","timestamp":"2026-06-08T10:00:05Z"}}
puts $fh {{"parentUuid":"s0","isSidechain":false,"promptSource":"typed","cwd":"/tmp/rewound","type":"user","message":{"role":"user","content":"kept"},"uuid":"p2","timestamp":"2026-06-08T10:01:00Z"}}
puts $fh {{"parentUuid":"p2","isSidechain":false,"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":50}},"uuid":"a2","timestamp":"2026-06-08T10:01:05Z"}}
close $fh

set SL ""
set ::scanpath_calls 0
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc scanpath {path} { incr ::scanpath_calls; return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }
proc subagent_cost_cb {path} {}

set SL [::questlog::ui::SessionList new .s resolvef noop noop noop noop noop \
            noop scanpath noop subagentsf subagent_cost_cb]
pack .s -fill both -expand 1

chan configure stdout -buffering line
proc bgerror {msg} { puts "BGERROR: $msg"; puts $::errorInfo; exit 9 }

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

# The floor rides the snapshot as turns_view; both sessions are in the window.
$SL apply_filter [dict create since all turns_view 2]
set ::scan_done 0
$::Scan extend [dict create since all]
after 200 [list set ::scan_done 1]
vwait ::scan_done
$SL toggle_folder $FOLDER
check "a rewound session's running count passes the floor at scan" \
    [list [$SL sget $REW nturns] [$SL sflag $REW hidden]] {2 0}
foreach path [list $ONE $THREE $REW] {
    $SL refresh_cost $path [::questlog::cost::build_cost_dict \
                                [::questlog::cost::parse_file $path]]
}
update
check "its cost counts the one turn kept, and the floor hides it" \
    [list [$SL sget $REW nturns] [$SL sflag $REW hidden]] {1 1}

check "both sessions are in the store" \
    [list [$SL has_session $ONE] [$SL has_session $THREE]] {1 1}
check "the one-turn session is hidden" [$SL sflag $ONE hidden] 1
check "the three-turn session shows" [$SL sflag $THREE hidden] 0
check "visible count excludes the hidden row" [dict get [$SL node_aggregate [$SL fid $FOLDER] 1] count] 1

set whole [expr {[$SL sget $ONE cost] + [$SL sget $THREE cost]}]
check "the store's folder sum is whole, hidden included" \
    [dict get [$SL node_aggregate [$SL fid $FOLDER]] cost] $whole
check "the heading's sum is what it shows" \
    [dict get [$SL node_aggregate [$SL fid $FOLDER] 1] cost] [$SL sget $THREE cost]
check "the grand total is the whole sum, the rewound folder's hidden row included" \
    [$SL total_cost] [expr {$whole + [$SL sget $REW cost]}]

# Dropping the floor reveals the row from the store: no rescan, no file read.
set before $::scanpath_calls
$SL set_turns_view 1
update
check "set_turns_view 1 reveals the one-turn row" [$SL sflag $ONE hidden] 0
check "the reveal reads no file" $::scanpath_calls $before
check "visible count recovers" [dict get [$SL node_aggregate [$SL fid $FOLDER] 1] count] 2

# Raising it again hides without forgetting: the row and its cost stay.
$SL set_turns_view 2
update
check "raising the floor re-hides in place" [$SL sflag $ONE hidden] 1
check "the hidden row keeps its priced cost" \
    [expr {[$SL sget $ONE cost] > 0}] 1

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
