#!/usr/bin/env wish9.0
# The docked viewer survives a move of the session it is showing. A session's
# identity is its node, not its path; the viewer holds the open session by path,
# so when a list move renames the file the app must follow it in the viewer too.
# Before that follow, Move from the viewer silently no-ops (the stale path is no
# longer a modelled session) and Bookmark/Rename throw (the file is gone from the
# old path). This drives the real GUI path (app::move_one) with a real Viewer
# wired in, and asserts the viewer tracks the move so its verbs keep acting.

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
package require streamdoc
package require tkdown
package require logman
set ::questlog_config_only 1; source [file join $ROOT questlog]
foreach f {lib/debug.tcl lib/cost.tcl ui/theme.tcl lib/path.tcl lib/listfilter.tcl \
           lib/match.tcl ui/terminal.tcl ui/live.tcl lib/scan.tcl lib/search.tcl \
           ui/drag.tcl ui/toolbar.tcl ui/reveal.tcl ui/sessions.tcl ui/viewer.tcl ui/app.tcl} {
    source [file join $ROOT $f]
}
::questlog::match::set_caps [dict create \
    content_cap     [::questlog::config::get content_cap] \
    snippet_lead    [::questlog::config::get snippet_lead] \
    snippet_trail   [::questlog::config::get snippet_trail] \
    tool_param_cap  [::questlog::config::get tool_param_cap] \
    tool_render_cap [::questlog::config::get tool_render_cap]]
::questlog::ui::theme::init

set SAND [file join [pwd] _viewermove_sandbox]
::questlog::path::_real_file delete -force $SAND
set ::env(HOME) $SAND
unset -nocomplain ::env(CLAUDE_CONFIG_DIR)

proc noop {args} {}
proc write_session {path prompts cwd ts} {
    ::questlog::path::_real_file mkdir [file dirname $path]
    set fh [open $path w]
    set t 0
    foreach p $prompts {
        puts $fh "{\"type\":\"user\",\"cwd\":\"$cwd\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"role\":\"user\",\"content\":\"$p\"}}"
        puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
        incr t
    }
    close $fh
}

set CWDA [file join $SAND work proj-a]
set CWDB [file join $SAND work proj-b]
::questlog::path::_real_file mkdir $CWDA
::questlog::path::_real_file mkdir $CWDB
set FA [::questlog::path::encode_cwd $CWDA]
set FB [::questlog::path::encode_cwd $CWDB]
set PROOT [file join $SAND .claude projects]
set a1 [file join $PROOT $FA aaaa.jsonl]
# The rows date from an hour ago: the list models only rows inside its since
# window, so a fixed calendar date would age out of it.
set BASE [expr {[clock seconds] / 60 * 60 - 3600}]
proc moment {epoch} { clock format $epoch -gmt 1 -format %Y-%m-%dT%H:%M }
write_session $a1 {a1-one a1-two} $CWDA [moment $BASE]
file mtime $a1 [expr {$BASE + 60}]
# A subagent sidecar so a child transcript can be opened in the viewer and its
# parent moved (the child-in-viewer case).
set a1side [file join $PROOT $FA aaaa subagents]
::questlog::path::_real_file mkdir $a1side
set a1child [file join $a1side agent-1.jsonl]
write_session $a1child {sub-one} $CWDA [moment [expr {$BASE + 120}]]

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

set SL [::questlog::ui::SessionList new .s resolvef noop noop noop noop noop noop \
            noop scanpath noop subagentsf noop]
pack .s -side left -fill both -expand 1
set VW [::questlog::ui::Viewer new .v noop noop noop noop scanpath]
pack .v -side left -fill both -expand 1

# app::move_one reaches its collaborators through namespace variables; wire the
# live objects in so the real move path (and its viewer follow) runs unchanged.
namespace eval ::questlog::ui::app {
    variable SessionList $::SL
    variable Viewer      $::VW
    variable ViewerPath  ""
    variable Running     [dict create]
}
# The status-bar writer reaches a dozen mode vars the full app owns; this test
# drives the move/viewer path, not the bottom strip, so stub it out.
proc ::questlog::ui::app::refresh_status {} {}

set fails 0
proc check {name got want} {
    if {$got eq $want} { puts "ok   - $name" } else {
        puts "FAIL - $name"; puts "       got:  $got"; puts "       want: $want"; incr ::fails
    }
}

$SL on_scan_row [scanpath $a1]
update
$VW show $a1
update
check "viewer shows the session" [$VW current_path] $a1
check "the open session is a modelled row (Move would act)" \
    [expr {[$SL session_node [$VW current_path]] ne ""}] 1

# Move the open session through the real GUI path.
::questlog::ui::app::move_one $a1 $CWDB
update
set a1_new [file join $PROOT $FB aaaa.jsonl]
check "viewer followed the moved session" [$VW current_path] $a1_new
check "the source path is gone from disk" [file isfile $a1] 0
check "the new path is on disk" [file isfile $a1_new] 1
# Move still finds a modelled row at the followed path (old path would be "").
check "Move from the viewer still resolves a row" \
    [expr {[$SL session_node [$VW current_path]] ne ""}] 1
# Bookmark from the viewer acts on the followed path (the old path would throw).
check "Bookmark on the old path would throw" \
    [catch {::questlog::path::set_bookmark $a1}] 1
set rc [catch {::questlog::ui::app::on_bookmark_toggle [$VW current_path]} err]
check "Bookmark from the viewer does not throw" $rc 0
check "Bookmark from the viewer flipped the +x bit" [file executable $a1_new] 1
check "store clean after the viewer move" [$SL audit] {}

# --- Child-in-viewer: a subagent transcript is open when its PARENT moves. The
#     sidecar dir relocates on disk, so the viewer must repoint the child to its
#     new path, not the deleted one. a1 now lives under B (with its sidecar); open
#     the child there and move a1 back to A.
set child_b [file join $PROOT $FB aaaa subagents agent-1.jsonl]
check "the child transcript is on disk under B" [file isfile $child_b] 1
$VW show $child_b
update
check "viewer shows the child transcript" [$VW current_path] $child_b
::questlog::ui::app::move_one $a1_new $CWDA
update
set child_a [file join $PROOT $FA aaaa subagents agent-1.jsonl]
check "the child followed its parent on disk"   [file isfile $child_a] 1
check "the old child path is gone from disk"     [file isfile $child_b] 0
check "viewer repointed the open child to its new path" [$VW current_path] $child_a
# The bug this closes: on the stale child path, Bookmark throws; on the followed
# path it acts.
check "Bookmark on the stale child path would throw" \
    [catch {::questlog::path::set_bookmark $child_b}] 1
check "Bookmark on the followed child does not throw" \
    [catch {::questlog::path::set_bookmark [$VW current_path]}] 0
check "store clean after the child-in-viewer move" [$SL audit] {}

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
