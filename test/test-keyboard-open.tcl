#!/usr/bin/env wish9.0
# The keyboard verbs the context menu advertises (issue #53). Return opens the
# selected session and Ctrl+R copies its resume command; the app binds both to
# SessionList open_selected / copy_selected_resume. Each acts on a lone
# selection and no-ops otherwise, so the -accelerator hints never lie. This
# drives those two methods directly (the bindings are one-line delegations).

package require Tcl 9
package require Tk

set SAND [file join [pwd] _kbopen_sandbox]
set FA "-tmp-kbopen"

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
set ::questlog_config_only 1; source [file join $ROOT questlog]
foreach f {lib/cost.tcl ui/theme.tcl lib/path.tcl lib/listfilter.tcl lib/jsonl.tcl \
           lib/match.tcl ui/terminal.tcl ui/live.tcl lib/scan.tcl lib/search.tcl \
           ui/drag.tcl ui/toolbar.tcl ui/sessions.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

::questlog::path::_real_file delete -force $SAND
set DIRA [file join $SAND .claude projects $FA]
::questlog::path::_real_file mkdir $DIRA
set ::env(HOME) $SAND

proc noop {args} {}
proc write_session {path ts} {
    set fh [open $path w]
    puts $fh "{\"type\":\"user\",\"cwd\":\"/tmp/proj\",\"timestamp\":\"${ts}Z\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}"
    puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}Z\",\"message\":{\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
    close $fh
}

proc session_moment {days_ago} { return [expr {[clock seconds] - $days_ago*24*3600}] }
set P {}
for {set i 1} {$i <= 2} {incr i} {
    set p [file join $DIRA [format s%02d $i].jsonl]
    set when [session_moment $i]
    write_session $p [clock format $when -format "%Y-%m-%dT%H:%M:%S" -gmt 1]
    file mtime $p $when
    lappend P $p
}
lassign $P s01 s02

set ::opened ""
proc openf {path lineno} { set ::opened [list $path $lineno] }

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

set SL [::questlog::ui::SessionList new .s resolvef openf noop noop noop noop noop \
            scanpath noop subagentsf noop]
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

$SL apply_filter [dict create since 30d]
set ::scan_done 0
$::Scan extend [dict create since 30d]
after 200 [list set ::scan_done 1]
vwait ::scan_done
$SL toggle_folder $FA
update

# ---- Return: opens the lone selection at its start -----------------------
$SL selection_set $s01
set ::opened ""
$SL open_selected
check "open_selected opens the sole selection" $::opened [list $s01 0]

# ---- Return no-ops without a single target -------------------------------
$SL set_selection [list]
set ::opened ""
$SL open_selected
check "open_selected no-ops on an empty selection" $::opened ""

$SL selection_set $s01
$SL selection_toggle $s02
set ::opened ""
$SL open_selected
check "open_selected no-ops on a multi-selection" $::opened ""

# ---- Ctrl+R: copies the lone selection's resume command ------------------
$SL selection_set $s02
clipboard clear
clipboard append "sentinel"
$SL copy_selected_resume
set want [::questlog::ui::terminal::resume_command /tmp/proj [file rootname [file tail $s02]]]
check "copy_selected_resume puts the resume command on the clipboard" \
    [clipboard get] $want

# ---- Ctrl+R no-ops without a single target -------------------------------
$SL selection_set $s01
$SL selection_toggle $s02
clipboard clear
clipboard append "sentinel"
$SL copy_selected_resume
check "copy_selected_resume no-ops on a multi-selection" [clipboard get] "sentinel"

check "domain audit clean at end" [$SL audit] {}
::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
