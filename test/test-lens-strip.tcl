#!/usr/bin/env wish9.0
# The list-view lenses as the engine's own filter controls, packed onto the list
# strip beside "expand all". Running and bookmarked are glyphed bools, model is an
# excluded-set enum; each is a control the StreamTree attribute facility builds
# into the strip and drives through attr_filter_set / -attrfiltercb. Toggling one
# hides or shows rows in place - no scan, no search, the selection preserved - and
# the change mirrors into the snapshot's listview sub-dict so the lens note and the
# folder counts read the same lenses.
#
# Invariant under test: a lens click reaches no disk (the scan sees no new
# scan_path), hides/shows loaded rows by the excluded-set rules row_visible uses,
# and keeps a path-keyed selection across the hide and the show.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _lensstrip_sandbox]
set FOLDER "-tmp-lensstrip-proj"

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add $ROOT
package require leash
package require streamtree
foreach f {config.tcl lib/cost.tcl ui/theme.tcl lib/path.tcl lib/scope.tcl lib/sessionlist.tcl lib/jsonl.tcl \
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

# Count scan_path calls: a lens click must add none.
set ::scan_path_calls 0
set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc lookup {path}   { return [$::Scan lookup $path] }
proc scanpath {path} { incr ::scan_path_calls; return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

set SL [::questlog::ui::SessionList new .s resolvef lookup noop noop noop noop noop \
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
$SL apply_filter [dict create since all min_turns 2 listview [dict create]]
set ::scan_done 0
$::Scan extend [dict create since all min_turns 2 listview [dict create]]
after 300 [list set ::scan_done 1]
vwait ::scan_done
$SL toggle_folder $FOLDER
update

# The cost second pass is not wired in this harness; land the model labels the way
# it would, on both the node (refresh_cost) and the scanner cache (update_cost),
# so the model lens has a roster and row_visible can read each row's model.
foreach {p m} [list $Ap {Sonnet} $Bp {Opus} $Cp {Sonnet}] {
    $SL refresh_cost $p [dict create cost_usd 0.01 model $m]
    $::Scan update_cost $p [dict create cost_usd 0.01 model $m]
}
update
check "all three rendered before any lens" \
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
check "running glyph takes the running colour" [::questlog::ui::theme::c glyph_running] \
    [$T tag cget attr-running -foreground]
check "bookmark glyph takes the bookmark colour" [::questlog::ui::theme::c glyph_bookmark] \
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
check "the two bool lenses are checkbuttons" {TCheckbutton TCheckbutton} \
    [list [winfo class .s.lvt.attr_running] [winfo class .s.lvt.attr_bookmarked]]
check "the model lens is a menubutton" TMenubutton [winfo class .s.lvt.attr_model]

set base_scans $::scan_path_calls

# --- 3. Select the non-bookmarked, non-running A; it must survive every toggle.
$SL selection_set $Ap
check "A is selected" [$SL is_selected $Ap] 1

# --- 4. Running lens. Mark B running, then flip "running only": B stays, A and C
#        hide in place. The selection on the hidden A is retained (path-keyed).
set Buuid [$SL sget $Bp uuid]
$SL reconcile_running [dict create $Buuid $Bp]
$SL attr_filter_set running 1
update
check "running lens keeps live B"      [$SL sflag $Bp rendered] 1
check "running lens hides idle A"      [$SL sflag $Ap rendered] 0
check "running lens hides idle C"      [$SL sflag $Cp rendered] 0
check "A stays in the model (hidden)"  [$SL has_session $Ap] 1
check "A selection survives the hide"  [$SL is_selected $Ap] 1
# The engine filter mirrored into the snapshot: any_view_toggle reads the snapshot
# (not the engine), so it only reports a lens when the mirror landed.
check "the lens mirrored into the snapshot" 1 [$SL any_view_toggle]
$SL attr_filter_set running 0
update
check "clearing the lens clears the snapshot mirror" 0 [$SL any_view_toggle]
check "clearing running brings A and C back" \
    [list [$SL sflag $Ap rendered] [$SL sflag $Cp rendered]] {1 1}
check "A still selected after the show" [$SL is_selected $Ap] 1

# --- 5. Bookmarked lens: only B (its +x bit is set) shows.
$SL attr_filter_set bookmarked 1
update
check "bookmarked lens keeps B"  [$SL sflag $Bp rendered] 1
check "bookmarked lens hides A"  [$SL sflag $Ap rendered] 0
check "bookmarked lens hides C"  [$SL sflag $Cp rendered] 0
$SL attr_filter_set bookmarked 0
update

# --- 6. Model lens (excluded-set): shutting off Sonnet hides A and C, keeps Opus B.
$SL attr_filter_set model [list Sonnet]
update
check "excluding Sonnet hides A"  [$SL sflag $Ap rendered] 0
check "excluding Sonnet hides C"  [$SL sflag $Cp rendered] 0
check "excluding Sonnet keeps Opus B" [$SL sflag $Bp rendered] 1

# The stay-open checklist opens with one entry per loaded model, plus all/none.
$SL open_enum_popover model
update
set pf .streamtree_attrpop.f
check "the checklist offers one entry per loaded model" 2 \
    [llength [lsearch -all -inline [winfo children $pf] $pf.v*]]
check "the checklist carries select-all and select-none" 1 \
    [expr {[winfo exists $pf.btns.all] && [winfo exists $pf.btns.none]}]
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
$SL close_enum_popover

# --- 7. Not one lens click touched disk: the scan saw no new scan_path.
check "no lens click ran a scan_path" $::scan_path_calls $base_scans
check "A survived the whole lens sequence selected" [$SL is_selected $Ap] 1

# --- 8. A lens survives a scope change. The toolbar's snapshot carries search
#        and scope only; the lenses are the engine's and ride along by mirror.
#        With bookmarked pressed, a scope change (apply_filter, clear, refill)
#        must re-insert rows that still honour the lens, and the strip control
#        must still read as pressed.
$SL attr_filter_set bookmarked 1
update
check "bookmarked lens on: only B shows" \
    [list [$SL sflag $Ap rendered] [$SL sflag $Bp rendered] [$SL sflag $Cp rendered]] {0 1 0}
# Mirror the app's scope-switch sequence: replay the memoised rows the new
# snapshot admits (the scan coroutine skips already-scanned paths), then extend
# for anything newly in scope.
set snap2 [dict create since all min_turns 1]
$SL apply_filter $snap2
foreach row [$::Scan query $snap2] { $SL on_scan_row $row }
set ::scan_done 0
$::Scan extend $snap2
after 300 [list set ::scan_done 1]
vwait ::scan_done
$SL toggle_folder $FOLDER
update
check "the engine still holds the lens across the scope change" \
    [$SL attr_filter_get bookmarked] 1
check "the refilled list still honours the lens" \
    [list [$SL sflag $Ap rendered] [$SL sflag $Bp rendered] [$SL sflag $Cp rendered]] {0 1 0}
set snapmirror [set [info object namespace $SL]::Snapshot]
check "the snapshot mirror carries the lens the strip shows" \
    [::questlog::sessionlist::toggle $snapmirror bookmarked_only 0] 1
$SL attr_filter_set bookmarked 0
update

$SL reconcile_running [dict create]
::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
