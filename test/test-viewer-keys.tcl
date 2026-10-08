#!/usr/bin/env wish9.0
# Keyboard keys act on the session viewer from where the reader is looking.
#
# The reading pane keeps the Tk Text class bindings, because it wants the
# class's wheel and its drag-select copy. Every motion key that class defines
# ends in tk::TextSetCursor, which does `see insert`, and nobody types into a
# transcript, so its insert mark sits where the render left it: the last line
# of the session. Untended, one arrow press throws the reader from the message
# they were on to the end of the transcript, and Ctrl+B does it while folding
# the sidebar, so the app's own accelerator carries the jump with it.
#
# park_cursor re-seats the mark on the top visible line before the class
# handler runs, but only when it has drifted out of view: a mark still on
# screen is where the last keystroke put it, which is what lets a run of arrow
# presses walk down the page instead of resetting each time.
#
# Runs under wish (it builds a Viewer, so it needs Tk); run-audit routes it to
# wish9.0 on the private Xvfb. Standalone: DISPLAY=:95 wish9.0 test-viewer-keys.tcl

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
set ::questlog_config_only 1; source [file join $ROOT questlog]
foreach f {lib/debug.tcl lib/path.tcl lib/match.tcl \
           lib/cost.tcl ui/theme.tcl ui/reveal.tcl ui/viewer.tcl} {
    source [file join $ROOT $f]
}
::questlog::match::set_caps [dict create \
    content_cap     [::questlog::config::get content_cap] \
    snippet_lead    [::questlog::config::get snippet_lead] \
    snippet_trail   [::questlog::config::get snippet_trail] \
    tool_param_cap  [::questlog::config::get tool_param_cap] \
    tool_render_cap [::questlog::config::get tool_render_cap]]
::questlog::ui::theme::init

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

# ---- a transcript long enough to scroll -------------------------------------
set tmpbase [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set TMP [file join $tmpbase ql-keys-test-[pid]]
::questlog::path::_real_file mkdir $TMP
set JP [file join $TMP session.jsonl]
set fh [open $JP w]
fconfigure $fh -encoding utf-8
set ask {{"type":"user","promptSource":"typed","cwd":"/tmp/proj","timestamp":"%s","message":{"role":"user","content":"question number %d about the subject at hand"}}}
set say {{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":[{"type":"text","text":"answer number %d, at enough length to take a line or two of the pane on its own"}]}}}
for {set i 0} {$i < 60} {incr i} {
    set ts [format "2026-07-11T%02d:%02d:00Z" [expr {8 + $i / 30}] [expr {$i % 30 * 2}]]
    puts $fh [format $ask $ts $i]
    puts $fh [format $say $ts $i]
}
close $fh

set V [::questlog::ui::Viewer new .v]
pack .v -fill both -expand 1
set Text [$V textwidget]
# A short viewport, so the transcript scrolls under it by a known amount.
$Text configure -height 10
$V show $JP 0 {}
update idletasks
update

# yview fractions rest on line heights Tk is still estimating in the
# background; sync settles them so a page step compares like with like.
proc top {} { $::Text sync; return [lindex [$::Text yview] 0] }
proc press {key} {
    focus -force $::Text
    update
    event generate $::Text $key
    update
}

$Text sync
check "the transcript is longer than the pane" \
    [expr {[lindex [$Text yview] 1] < 0.5}] 1
check "the render leaves the insert mark out of view" \
    [expr {[$Text bbox insert] eq ""}] 1

# Each motion key, from a view parked at the top. Without park_cursor every one
# of these lands near 1.0, the end of the transcript.
foreach key {<Control-Key-b> <Key-Down> <Key-Up> <Key-End> <Key-Home> \
             <Key-Next> <Key-Prior> <Control-Key-e> <Control-Key-n>} {
    # Restore the state a render leaves: the mark at the end, the reader at the
    # top. Without this each key inherits the mark the last one dragged into
    # view, and passes on the previous key's work.
    $Text mark set insert "end - 1 chars"
    $Text yview moveto 0
    update
    press $key
    check "$key keeps the reader near the top of the transcript" \
        [expr {[top] < 0.1}] 1
}

# A run of presses walks: the mark is left alone while it is on screen, so the
# second Down starts from where the first left the cursor. Down moves a display
# line, and a long answer wraps at some widths, so the walk counts those.
$Text yview moveto 0
update
set walk [list]
foreach n {1 2 3} {
    press <Key-Down>
    lappend walk [$Text count -displaylines 1.0 insert]
}
check "repeated Down walks the cursor down" \
    [expr {[lindex $walk 0] < [lindex $walk 1] && [lindex $walk 1] < [lindex $walk 2]}] 1

# The page keys page, from where the reader is rather than from the mark's
# resting place. Half the pane's own height is the floor for "it moved".
$Text yview moveto 0.4
update
$Text sync
set page [expr {[lindex [$Text yview] 1] - [lindex [$Text yview] 0]}]
set y0 [top]
press <Key-Next>
set fwd [expr {[top] - $y0}]
check "PageDown pages forward" [expr {$fwd > $page / 2.0}] 1
$Text yview moveto 0.4
update
set y0 [top]
press <Key-Prior>
set back [expr {$y0 - [top]}]
check "PageUp pages back" [expr {$back > $page / 2.0}] 1

# Nothing here disturbed the mouse selection the pane keeps for copying, so
# drag across a line known to carry text rather than a bare coordinate.
set hit [$Text search -- "answer number 20" 1.0 end]
$Text see $hit
update
lassign [$Text bbox $hit] hx hy hw hh
event generate $Text <ButtonPress-1> -x [expr {$hx + 1}] -y [expr {$hy + $hh / 2}]
event generate $Text <B1-Motion>     -x [expr {$hx + 90}] -y [expr {$hy + $hh / 2}]
event generate $Text <ButtonRelease-1> -x [expr {$hx + 90}] -y [expr {$hy + $hh / 2}]
update
check "a drag still selects text for copying" \
    [expr {[llength [$Text tag ranges sel]] > 0}] 1

::questlog::path::_real_file delete -force $TMP
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
