#!/usr/bin/env wish9.0
# Reversible list-view toggles: a filter (here bookmarked) hides or shows
# rows in place without re-scanning, without dropping them from the model, and
# without losing the selection.
#
# Invariant under test: MODEL membership is scope (a browse row that passes
# row_matches), independent of the view toggles. A toggle sets a per-session
# `hidden` flag and re-renders the affected folders via collapse+expand; the
# row stays in the model (model total unchanged, so the toggle is reversible),
# and the selection - keyed by path, not by a rendered mark - survives the hide
# and re-paints on the show. The heading's displayed count, by contrast, tracks
# the viewable sessions and so drops when a row hides (see test-folder-detach
# for the folder that detaches once its viewable count reaches zero).

package require Tcl 9
package require Tk

set SAND [file join [pwd] _togglerev_sandbox]
set FOLDER "-tmp-togglerev-proj"

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
set PROJDIR [file join $SAND .claude projects $FOLDER]
::questlog::path::_real_file mkdir $PROJDIR
set ::env(HOME) $SAND

proc noop {args} {}

# Two multi-turn sessions in one folder. write_session emits two user turns so
# both clear a min-turns floor; B is bookmarked (its +x bit is set), A is not.
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

set Ap [file join $PROJDIR aaaa.jsonl]
set Bp [file join $PROJDIR bbbb.jsonl]
write_session $Ap {a-first a-second} "2026-05-24T17:00"
write_session $Bp {b-first b-second} "2026-05-23T10:00"
file mtime $Ap [clock scan "2026-05-24 17:01:00" -gmt 1]
file mtime $Bp [clock scan "2026-05-23 10:01:00" -gmt 1]
# Bookmark B (the +x bit is what scan reads as `bookmarked`).
::questlog::path::set_bookmark $Bp

# Wire Scan <-> SessionList (same shape as test-subagent-render-order).
set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }
proc subagent_cost_cb {path} {}

set SL [::questlog::ui::SessionList new .s resolvef noop noop noop noop noop \
            noop scanpath noop subagentsf subagent_cost_cb]
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

# --- 1. Stream both rows in, expand the folder; both render and are in the model.
$SL apply_filter [dict create since all]
set ::scan_done 0
$::Scan extend [dict create since all]
after 200 [list set ::scan_done 1]
vwait ::scan_done
$SL toggle_folder $FOLDER
update

check "A in model"   [$SL has_session $Ap] 1
check "B in model"   [$SL has_session $Bp] 1
check "A rendered"   [$SL sflag $Ap rendered] 1
check "B rendered"   [$SL sflag $Bp rendered] 1
check "folder count = 2 (model total)" [$SL fget $FOLDER count] 2

# --- 2. Select the NON-bookmarked session A (the gesture the click uses).
$SL selection_set $Ap
update
check "A is selected" [$SL is_selected $Ap] 1

# --- 3. Turn the bookmarked filter on. A hides in place but stays
#        in the model; B keeps rendering; the model total holds at 2 (so the
#        toggle is reversible) while the viewable count drops to 1; A's selection
#        is retained (path-keyed) though it is unpainted.
$SL attr_filter_set bookmarked 1
update
check "A not rendered (hidden)"   [$SL sflag $Ap rendered] 0
check "A still in model"          [$SL has_session $Ap] 1
check "B still rendered"          [$SL sflag $Bp rendered] 1
check "model total unchanged"     [$SL fget $FOLDER count] 2
check "viewable count drops to 1" [$SL folder_visible_count $FOLDER] 1
check "A selection retained"      [$SL is_selected $Ap] 1

# --- 4. Turn the bookmarked filter back off: A renders again, still selected
#        (the selected tag is re-applied by render_session from SelectedSet).
$SL attr_filter_set bookmarked 0
update
check "A rendered again"        [$SL sflag $Ap rendered] 1
check "A still selected"        [$SL is_selected $Ap] 1
check "B still rendered"        [$SL sflag $Bp rendered] 1

# --- 5. A running, non-bookmarked session stays hidden under the bookmarked filter:
#        the label promises bookmarks and nothing else. Running-ness retains it
#        in the model; it does not paint it.
$SL attr_filter_set bookmarked 1
update
set Auuid [$SL sget $Ap uuid]
$SL reconcile_running [dict create $Auuid $Ap]
update
check "running A still hidden under the bookmarked filter" [$SL sflag $Ap rendered] 0
check "running A retained in model" [$SL has_session $Ap] 1
$SL reconcile_running [dict create]

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
