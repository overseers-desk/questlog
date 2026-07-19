#!/usr/bin/env wish9.0
# The list-view filters as the engine's own filter controls, packed onto the list
# strip beside "expand all". Running and bookmarked are glyphed bools, model is an
# excluded-set enum; each is a control the StreamTree attribute facility builds
# into the strip and drives through attr_filter_set / -attrfiltercb. Toggling one
# hides or shows rows in place - no scan, no search, the selection preserved. The
# engine owns the one filter state, and the filter note and the folder counts read
# it back through attr_filter_all, not a copy.
#
# Invariant under test: a filter click reaches no disk (the scan sees no new
# scan_path), hides/shows loaded rows by the engine's excluded-set rules
# (attr_admits), and keeps a path-keyed selection across the hide and the show.

package require Tcl 9
package require Tk
# Opt in to a draft module (module-<v>a<n>.tm) when one sits beside the
# release; with none present this resolves the releases as usual.
package prefer latest

set SAND [file join [pwd] _filterstrip_sandbox]
set FOLDER "-tmp-filterstrip-proj"

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
set PROJDIR [file join $SAND .claude projects $FOLDER]
::questlog::path::_real_file mkdir $PROJDIR
set ::env(HOME) $SAND

proc noop {args} {}

# Two user turns clear a min-turns floor; the model id decides the model label.
proc write_session {path model ts} {
    set fh [open $path w]
    foreach p {first second} {
        puts $fh "{\"type\":\"user\",\"cwd\":\"/tmp/proj\",\"timestamp\":\"${ts}Z\",\"message\":{\"role\":\"user\",\"content\":\"$p\"}}"
        puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}Z\",\"message\":{\"model\":\"$model\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
    }
    close $fh
}

# A: sonnet, plain. B: opus, bookmarked. C: sonnet, plain. A newest .. C oldest.
set Ap [file join $PROJDIR aaaa.jsonl]
set Bp [file join $PROJDIR bbbb.jsonl]
set Cp [file join $PROJDIR cccc.jsonl]
write_session $Ap "claude-3-5-sonnet-20241022" "2026-05-24T17:00:00"
write_session $Bp "claude-opus-4-20250514"     "2026-05-23T10:00:00"
write_session $Cp "claude-3-5-sonnet-20241022" "2026-05-22T09:00:00"
file mtime $Ap [clock scan "2026-05-24 17:01:00" -gmt 1]
file mtime $Bp [clock scan "2026-05-23 10:01:00" -gmt 1]
file mtime $Cp [clock scan "2026-05-22 09:01:00" -gmt 1]
# Bookmark B (the +x bit is what scan reads as `bookmarked`).
::questlog::path::set_bookmark $Bp

# Count scan_path calls: a filter click must add none.
set ::scan_path_calls 0
set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc scanpath {path} { incr ::scan_path_calls; return [$::Scan scan_path $path] }
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

# --- 1. Load all three; expand the folder.
$SL apply_filter [dict create since all min_turns 2]
set ::scan_done 0
$::Scan extend [dict create since all min_turns 2]
after 300 [list set ::scan_done 1]
vwait ::scan_done
$SL toggle_folder $FOLDER
update

# The cost second pass is not wired in this harness; land the model labels the
# way it would (refresh_cost writes the node), so the model filter has a
# roster and the engine can read each row's model.
foreach {p m} [list $Ap {Sonnet} $Bp {Opus} $Cp {Sonnet}] {
    $SL refresh_cost $p [dict create cost_usd 0.01 model $m]
}
update
check "all three rendered before any filter" \
    [list [$SL sflag $Ap rendered] [$SL sflag $Bp rendered] [$SL sflag $Cp rendered]] {1 1 1}

# --- 1b. The status glyphs are engine-rendered attribute prefixes now (the
#         hand-rolled appends are retired): a running row prefixes ● under
#         attr-running, a bookmarked row prefixes ★ under attr-bookmarked, each
#         dressed in its theme colour. Mark A running for the check, then clear it.
set T .s.body.t
$SL reconcile_running [dict create [$SL sget $Ap uuid] $Ap]
update
check "running glyph rendered under attr-running" ● \
    [$T get [lindex [$T tag ranges attr-running] 0] [lindex [$T tag ranges attr-running] 1]]
check "bookmark glyph rendered under attr-bookmarked" ★ \
    [$T get [lindex [$T tag ranges attr-bookmarked] 0] [lindex [$T tag ranges attr-bookmarked] 1]]
check "running glyph takes the running colour" [::questlog::ui::theme::c attr_running] \
    [$T tag cget attr-running -foreground]
check "bookmark glyph takes the bookmark colour" [::questlog::ui::theme::c attr_bookmarked] \
    [$T tag cget attr-bookmarked -foreground]
$SL reconcile_running [dict create]
update

# --- 2. The controls exist on the strip, right-aligned, after expand all.
check "expand-all sits on the left of the strip" left \
    [dict get [pack info .s.lvt.expandall] -side]
check "running control exists on the strip"    1 [winfo exists .s.lvt.attr_running]
check "bookmarked control exists on the strip"  1 [winfo exists .s.lvt.attr_bookmarked]
check "model control exists on the strip"       1 [winfo exists .s.lvt.attr_model]
check "running control is right-aligned"    right [dict get [pack info .s.lvt.attr_running] -side]
check "bookmarked control is right-aligned"  right [dict get [pack info .s.lvt.attr_bookmarked] -side]
check "model control is right-aligned"       right [dict get [pack info .s.lvt.attr_model] -side]
check "the two bool filters are checkbuttons" {TCheckbutton TCheckbutton} \
    [list [winfo class .s.lvt.attr_running] [winfo class .s.lvt.attr_bookmarked]]
check "the model filter is a menubutton" TMenubutton [winfo class .s.lvt.attr_model]

set base_scans $::scan_path_calls

# --- 3. Select the non-bookmarked, non-running A; it must survive every toggle.
$SL selection_set $Ap
check "A is selected" [$SL is_selected $Ap] 1

# --- 4. Running filter. Mark B running, then flip "running only": B stays, A and C
#        hide in place. The selection on the hidden A is retained (path-keyed).
set Buuid [$SL sget $Bp uuid]
$SL reconcile_running [dict create $Buuid $Bp]
$SL attr_filter_set running 1
update
check "running filter keeps live B"    [$SL sflag $Bp rendered] 1
check "running filter hides idle A"    [$SL sflag $Ap rendered] 0
check "running filter hides idle C"    [$SL sflag $Cp rendered] 0
check "A stays in the model (hidden)"  [$SL has_session $Ap] 1
check "A selection survives the hide"  [$SL is_selected $Ap] 1
# any_view_toggle reads the engine's filter state directly, so it reports a filter
# the moment the strip sets one - no copy to land first.
check "a filter is active" 1 [$SL any_view_toggle]
$SL attr_filter_set running 0
update
check "clearing the filter reports none active" 0 [$SL any_view_toggle]
check "clearing running brings A and C back" \
    [list [$SL sflag $Ap rendered] [$SL sflag $Cp rendered]] {1 1}
check "A still selected after the show" [$SL is_selected $Ap] 1

# --- 5. Bookmarked filter: only B (its +x bit is set) shows.
$SL attr_filter_set bookmarked 1
update
check "bookmarked filter keeps B"  [$SL sflag $Bp rendered] 1
check "bookmarked filter hides A"  [$SL sflag $Ap rendered] 0
check "bookmarked filter hides C"  [$SL sflag $Cp rendered] 0
$SL attr_filter_set bookmarked 0
update

# --- 6. Model filter (excluded-set): shutting off Sonnet hides A and C, keeps Opus B.
$SL attr_filter_set model [list Sonnet]
update
check "excluding Sonnet hides A"  [$SL sflag $Ap rendered] 0
check "excluding Sonnet hides C"  [$SL sflag $Cp rendered] 0
check "excluding Sonnet keeps Opus B" [$SL sflag $Bp rendered] 1

# The stay-open checklist opens as a combobox-style popdown under the button:
# undecorated, themed through the popcheck/popbtn/popframe roles, one entry
# per loaded model, plus all/none.
set mbtn .s.lvt.attr_model
$SL open_enum_popover model $mbtn
update
set pop .streamtree_attrpop
set pf $pop.f
check "the popdown is undecorated" 1 [wm overrideredirect $pop]
check "the popdown sits under its button" 1 \
    [expr {[winfo rooty $pop] >= [winfo rooty $mbtn] + [winfo height $mbtn]}]
check "the checklist offers one entry per loaded model" 2 \
    [llength [lsearch -all -inline [winfo children $pf] $pf.v*]]
check "the checklist carries select-all and select-none" 1 \
    [expr {[winfo exists $pf.btns.all] && [winfo exists $pf.btns.none]}]
check "the checklist rows carry the host's style" LV.TCheckbutton \
    [$pf.v0 cget -style]
check "the popdown frame carries the host's style" LVStrip.TFrame \
    [$pf cget -style]
# Select-none excludes the whole roster: every known-model row hides.
$SL on_enum_none model
update
check "select-none hides every known-model row" \
    [list [$SL sflag $Ap rendered] [$SL sflag $Bp rendered] [$SL sflag $Cp rendered]] {0 0 0}
# Select-all clears the exclusion: every row returns.
$SL on_enum_all model
update
check "select-all brings every row back" \
    [list [$SL sflag $Ap rendered] [$SL sflag $Bp rendered] [$SL sflag $Cp rendered]] {1 1 1}
# A press outside the popdown closes it, the combobox contract.
$SL on_pop_press 1 1
update
check "a press outside closes the popdown" 0 [winfo exists $pop]
# Pressing the button again toggles: open, open again, closed.
$SL open_enum_popover model $mbtn
update
$SL open_enum_popover model $mbtn
update
check "the button press toggles the popdown closed" 0 [winfo exists $pop]
# The window moving from under it closes it (the Configure guard).
$SL open_enum_popover model $mbtn
update
event generate . <Configure>
update
check "the app window moving closes the popdown" 0 [winfo exists $pop]
$SL close_enum_popover

# --- 7. Not one filter click touched disk: the scan saw no new scan_path.
check "no filter click ran a scan_path" $::scan_path_calls $base_scans
check "A survived the whole filter sequence selected" [$SL is_selected $Ap] 1

# --- 8. A filter survives a scope change. The toolbar's snapshot carries search
#        and scope only; the engine owns the filter and holds it across the change,
#        with no copy to wipe. With bookmarked pressed, a scope change (apply_filter,
#        clear, refill) must re-insert rows that still honour the filter, and the
#        strip control must still read as pressed.
$SL attr_filter_set bookmarked 1
update
check "bookmarked filter on: only B shows" \
    [list [$SL sflag $Ap rendered] [$SL sflag $Bp rendered] [$SL sflag $Cp rendered]] {0 1 0}
# Mirror the app's scope-switch sequence: replay the retained rows the new
# snapshot admits from the store, then extend for anything newly in scope.
set snap2 [dict create since all min_turns 1]
$SL apply_filter $snap2
$SL replay_scope
set ::scan_done 0
$::Scan extend $snap2
after 300 [list set ::scan_done 1]
vwait ::scan_done
$SL toggle_folder $FOLDER
update
check "the engine still holds the filter across the scope change" \
    [$SL attr_filter_get bookmarked] 1
check "the refilled list still honours the filter" \
    [list [$SL sflag $Ap rendered] [$SL sflag $Bp rendered] [$SL sflag $Cp rendered]] {0 1 0}
$SL attr_filter_set bookmarked 0
update

$SL reconcile_running [dict create]
::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
