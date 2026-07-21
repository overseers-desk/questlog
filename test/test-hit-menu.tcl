#!/usr/bin/env wish9.0
# A search hit's two context-menu entries (issue #42).
#
# A right-click on a snippet row (parent snippet, name breadcrumb, or badge)
# now carries the match it sits on, so the session menu gains two hit-only
# entries: "Open at this match" (the same deep-linked open the badge's
# left-click performs) and "Copy this snippet" (the model's full stored match
# text on the clipboard). Both are absent from a plain header/row right-click
# and from the viewer's "..." menu, whose ctx never carries a hit.
#
# The plumbing must not reopen issue #41: the numeric lineoff and the machine-
# made reveal tag ride the bind script bare, but the snippet's free text never
# enters it - it is resolved at event time from the same PeekByTag entry the
# hover reveal uses. This drives that seam end to end over a one-session
# sandbox, and proves a percent-laden snippet survives the whole path verbatim.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _hitmenu_sandbox]
set FA "-tmp-hitmenu"

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
set ::questlog_config_only 1; source [file join $ROOT questlog]
foreach f {lib/cost.tcl ui/theme.tcl lib/path.tcl lib/listfilter.tcl \
           lib/match.tcl ui/terminal.tcl ui/live.tcl lib/scan.tcl lib/search.tcl \
           ui/drag.tcl ui/toolbar.tcl lib/markdown.tcl ui/session_actions.tcl ui/sessions.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

::questlog::path::_real_file delete -force $SAND
set DIRA [file join $SAND .claude projects $FA]
::questlog::path::_real_file mkdir $DIRA
set ::env(HOME) $SAND

proc noop {args} {}
proc session_moment {days_ago} { return [expr {[clock seconds] - $days_ago*24*3600}] }

proc write_session {path ts} {
    set fh [open $path w]
    fconfigure $fh -encoding utf-8
    puts $fh [string map [list @TS@ $ts] {{"type":"user","promptSource":"typed","cwd":"/tmp/proj","timestamp":"@TS@Z","message":{"role":"user","content":"hello from the hit menu"}}}]
    puts $fh [string map [list @TS@ $ts] {{"type":"assistant","timestamp":"@TS@Z","message":{"role":"assistant","model":"claude-x","content":[{"type":"text","text":"a reply"}],"usage":{"input_tokens":5,"output_tokens":5}}}}]
    close $fh
}

set SP [file join $DIRA s01.jsonl]
set when [session_moment 1]
write_session $SP [clock format $when -format "%Y-%m-%dT%H:%M:%S" -gmt 1]
file mtime $SP $when

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

# The open callback records exactly what a deep-link open delivers: path and
# line offset. "Open at this match" must reach it with the hit's line.
set ::opened "(never)"
proc record_open {path {lineno ""} args} { set ::opened [list $path $lineno] }

set SL [::questlog::ui::SessionList new .s resolvef record_open noop noop noop noop \
            noop scanpath noop subagentsf noop noop noop]
pack .s -fill both -expand 1
set TX .s.body.t
set NS [info object namespace $SL]

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

# The command-entry labels of a menu, in order (separators skipped).
proc menu_labels {m} {
    set out {}
    if {[$m index end] eq "none"} { return $out }
    for {set i 0} {$i <= [$m index end]} {incr i} {
        if {[$m type $i] eq "command"} { lappend out [$m entrycget $i -label] }
    }
    return $out
}
proc menu_command {m label} {
    for {set i 0} {$i <= [$m index end]} {incr i} {
        if {[$m type $i] eq "command" && [$m entrycget $i -label] eq $label} {
            return [$m entrycget $i -command]
        }
    }
    return ""
}
# Invoke the command entry with this label (separators shift the widget index
# off the command-only position, so walk the widget rather than count labels).
proc invoke_label {m label} {
    for {set i 0} {$i <= [$m index end]} {incr i} {
        if {[$m type $i] eq "command" && [$m entrycget $i -label] eq $label} {
            $m invoke $i; return 1
        }
    }
    return 0
}

# --- Stream the session in and render it.
$SL apply_filter [dict create since 30d]
set ::scan_done 0
$::Scan extend [dict create since 30d]
after 200 [list set ::scan_done 1]
vwait ::scan_done
$SL toggle_folder $FA
update
check "session rendered" [$SL sflag $SP rendered] 1

# --- Inject a hit with a plain snippet at a known line offset.
set SNIP "the matched transcript line, whose trailing context runs past the column"
set LOFF 7
$SL add_session_matches \
    [list [dict create path $SP folder $FA btype tool_use content $SNIP lineoff $LOFF]]
update
$TX see end
update

# --- The snippet row's <<ContextMenu>> bind routes to the hit-aware handler,
#     carries the numeric lineoff and the reveal tag bare, and - the issue #41
#     guard - does NOT splice the free-text snippet into the script.
set ntag [lindex [lsearch -all -inline -glob [$TX tag names] n#*] 0]
set tagscript [$TX tag bind $ntag <<ContextMenu>>]
check "row context bind routes to on_hit_right" \
    [string match "*on_hit_right*" $tagscript] 1
check "row context bind carries the reveal tag" \
    [string match "*$ntag*" $tagscript] 1
check "row context bind carries the numeric lineoff bare" \
    [string match "*$LOFF*" $tagscript] 1
check "row context bind does NOT splice the snippet text" \
    [string match "*$SNIP*" $tagscript] 0

# --- The badge widget (a real window, no inherited tag bindings) is wired the
#     same way: same handler, same tag, still no text.
set badge ""
foreach w [winfo children $TX] {
    if {[winfo class $w] eq "Label"} { set badge $w; break }
}
check "the snippet badge widget exists" [expr {$badge ne ""}] 1
set badgescript [bind $badge <<ContextMenu>>]
check "badge context bind routes to on_hit_right with the tag" \
    [string match "*on_hit_right*$ntag*" $badgescript] 1
check "badge context bind does NOT splice the snippet text" \
    [string match "*$SNIP*" $badgescript] 0

# --- The registry is the resolution source the handler reads at event time.
check "the reveal registry resolves the tag to the full snippet" \
    [lindex [dict get [set ${NS}::PeekByTag] $ntag] 1] $SNIP

# --- Drive the real hit right-click handler. It resolves the snippet from the
#     registry, builds the shared session menu with a hit ctx, and posts it.
set Menu [set ${NS}::Menu]
$SL on_hit_right $SP $LOFF $ntag 100 100
update
set hitlabels [menu_labels $Menu]
check "hit menu shows Open at this match" \
    [expr {"Open at this match" in $hitlabels}] 1
check "hit menu shows Copy this snippet" \
    [expr {"Copy this snippet" in $hitlabels}] 1

# --- "Open at this match" reuses the badge's left-click open (on_snippet_release)
#     and carries the hit's line - it does not invent a second open verb.
set opencmd [menu_command $Menu "Open at this match"]
check "Open-at-this-match reuses on_snippet_release" \
    [string match "*on_snippet_release*" $opencmd] 1
check "Open-at-this-match carries the hit line" \
    [string match "*$LOFF*" $opencmd] 1

# --- Invoking it deep-links the open: the open callback receives path + line.
set ::opened "(never)"
invoke_label $Menu "Open at this match"
update
check "Open-at-this-match deep-links the open" $::opened [list $SP $LOFF]

# --- "Copy this snippet" puts the exact model snippet on the clipboard.
clipboard clear
invoke_label $Menu "Copy this snippet"
update
check "Copy this snippet copies the model's snippet verbatim" \
    [clipboard get] $SNIP
$Menu unpost

# --- A plain header/row right-click (no hit) shows neither entry.
$SL on_session_right $SP 100 100
update
set plainlabels [menu_labels $Menu]
check "hitless menu omits Open at this match" \
    [expr {"Open at this match" in $plainlabels}] 0
check "hitless menu omits Copy this snippet" \
    [expr {"Copy this snippet" in $plainlabels}] 0
$Menu unpost

# --- The shared builder gates purely on the ctx "hit" key, so the viewer's
#     hitless ctx (which never sets it) shows neither entry. Exercise the
#     builder directly on a scratch menu, with and without a hit.
menu .scratch -tearoff 0
set base [dict create \
    target [dict create path $SP uuid u cwd /tmp/proj folder $FA] \
    parent .s clipboard {noop} on_open {noop} on_move {noop} \
    on_bookmark {noop} on_rename {noop} \
    state [dict create is_bookmarked 0 has_cwd 1 has_folder 1]]
::questlog::ui::session_actions::populate .scratch $base
set nohit [menu_labels .scratch]
check "builder without a hit omits both entries" \
    [expr {("Open at this match" in $nohit) || ("Copy this snippet" in $nohit)}] 0
set withhit [dict merge $base [dict create \
    hit [dict create lineoff $LOFF snippet $SNIP] on_open_at {noop}]]
::questlog::ui::session_actions::populate .scratch $withhit
set both [menu_labels .scratch]
check "builder with a hit adds both entries" \
    [expr {("Open at this match" in $both) && ("Copy this snippet" in $both)}] 1

# --- A percent-laden snippet survives the whole path verbatim: the characters
#     bind's %-substitution corrupts ("printf %s", "50%", "%%") ride the reveal
#     registry untouched and land on the clipboard exactly. Injected as a second
#     match so it runs the same wire -> registry -> resolve -> copy path.
set PCT {printf %s lands 50% done and %% stays doubled}
set PLOFF 9
$SL add_session_matches \
    [list [dict create path $SP folder $FA btype tool_use content $PCT lineoff $PLOFF]]
update
$TX see end
update
set ptag [lindex [lsearch -all -inline -glob [$TX tag names] n#*] end]
set pscript [$TX tag bind $ptag <<ContextMenu>>]
check "percent-snippet bind does NOT splice its text" \
    [string match "*$PCT*" $pscript] 0
$SL on_hit_right $SP $PLOFF $ptag 100 100
update
clipboard clear
invoke_label $Menu "Copy this snippet"
update
check "a percent-laden snippet copies verbatim" [clipboard get] $PCT
$Menu unpost

# --- Subagent matched lines get the same treatment through the child menu,
#     which is separate (a subagent is not a resumable session). Drive the two
#     halves the refactor touches: the per-open builder, and on_child_right's
#     registry resolution. A synthesized c# reveal entry stands in for what
#     render_child_snippet's peek_wire stores, the same source the handler reads.
set CMenu [set ${NS}::CMenu]
$SL populate_child_menu ""
set chnohit [menu_labels $CMenu]
check "child menu without a hit omits both entries" \
    [expr {("Open at this match" in $chnohit) || ("Copy this snippet" in $chnohit)}] 0
$SL populate_child_menu [dict create lineoff 4 snippet "plain child hit"]
set chhit [menu_labels $CMenu]
check "child menu with a hit adds both entries" \
    [expr {("Open at this match" in $chhit) && ("Copy this snippet" in $chhit)}] 1

# on_child_right resolves the snippet from the reveal registry, never a script.
set CP "/tmp/fake-child.jsonl"
set ctag "c#test"
set CHPCT {child printf %s 50% and %% verbatim}
set ${NS}::PeekByTag [dict set [set ${NS}::PeekByTag] $ctag [list agent $CHPCT]]
set ::opened "(never)"
$SL on_child_right $CP 100 100 $ctag 4
update
invoke_label $CMenu "Open at this match"
update
check "child Open-at-this-match deep-links the subagent open" $::opened [list $CP 4]
clipboard clear
invoke_label $CMenu "Copy this snippet"
update
check "child Copy this snippet copies the resolved snippet verbatim" \
    [clipboard get] $CHPCT
# A hitless header right-click on_child_right (no tag) drops the hit entries.
$SL on_child_right $CP 100 100
update
set chhdr [menu_labels $CMenu]
check "child header right-click (no tag) omits both entries" \
    [expr {("Open at this match" in $chhdr) || ("Copy this snippet" in $chhdr)}] 0
$CMenu unpost

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
