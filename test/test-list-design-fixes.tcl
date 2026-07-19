#!/usr/bin/env wish9.0
# Design-audit fixes for the session list (B1, B3, B6, C3, C4, C6, C7, C8, C9,
# C10a).
#
# Drives a SessionList over a small sandbox and asserts each fixed behaviour:
#   B1   a plain click on a search result opens at the session start, not the
#        first match; the snippet click still deep-links to its line.
#   B6   a capped snippet block names the rest with a "N more matches" row, for
#        parents and for subagents; a block within the cap emits none.
#   C3   an elevated cost cell carries the tier colour AND a bolder weight.
#   C4   the strip's cost figure reads "and counting" while a search is in flight.
#   B3   the Cancel button rests disabled and is live only during a search.
#   C6   fmt_size emits KB/MB/GB.
#   C7   the snippet badge names the source in the reader's words.
#   C8   on a hit the menu offers Copy this snippet in the slot Copy last
#        assistant output holds otherwise.
#   C9   only-subagents-matched shows an indented note below the row (subject
#        dimmed), with the match/subagent counts singularised.
#   C10a the "+N in subagents" pip singularises to "+1 in subagent".

package require Tcl 9
package require Tk

set SAND [file join [pwd] _designfixes_sandbox]
set FA "-tmp-designfixes"

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
foreach f {config.tcl lib/cost.tcl ui/theme.tcl lib/path.tcl lib/listfilter.tcl lib/jsonl.tcl \
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

proc write_session {path prompts ts} {
    set fh [open $path w]
    fconfigure $fh -encoding utf-8
    set t 0
    foreach p $prompts {
        puts $fh "{\"type\":\"user\",\"cwd\":\"/tmp/proj\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"role\":\"user\",\"content\":\"$p\"}}"
        puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
        incr t
    }
    close $fh
}

# One plain session for B1/B6, and a parent with two subagents for C9/C10a.
set S1 [file join $DIRA over.jsonl]
write_session $S1 {alpha beta} "2026-05-24T17:00"
file mtime $S1 [clock scan "2026-05-24 17:01:00" -gmt 1]
set S2 [file join $DIRA few.jsonl]
write_session $S2 {gamma delta} "2026-05-24T16:00"
file mtime $S2 [clock scan "2026-05-24 16:01:00" -gmt 1]

set PB [file join $DIRA parentb.jsonl]
write_session $PB {parent-b work} "2026-05-24T15:00"
file mtime $PB [clock scan "2026-05-24 15:01:00" -gmt 1]
set PBSUB [file join $DIRA parentb subagents]
::questlog::path::_real_file mkdir $PBSUB
write_session [file join $PBSUB agent-1.jsonl] {subwork} "2026-05-24T15:00"

set PC [file join $DIRA parentc.jsonl]
write_session $PC {parent-c work} "2026-05-24T14:00"
file mtime $PC [clock scan "2026-05-24 14:01:00" -gmt 1]
set PCSUB [file join $DIRA parentc subagents]
::questlog::path::_real_file mkdir $PCSUB
write_session [file join $PCSUB agent-1.jsonl] {subwork} "2026-05-24T14:00"

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

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
proc widget_text {} { global TX; return [$TX get 1.0 end] }
proc has_line {pat} {
    foreach l [split [widget_text] "\n"] { if {[string match $pat $l]} { return 1 } }
    return 0
}

# ---- C8: one copy slot - snippet on a hit, else last assistant output -----
proc menu_labels {m} {
    set out {}
    if {[$m index end] eq "none"} { return $out }
    for {set i 0} {$i <= [$m index end]} {incr i} {
        if {[$m type $i] eq "command"} { lappend out [$m entrycget $i -label] }
    }
    return $out
}
menu .c8 -tearoff 0
set c8base [dict create \
    target [dict create path /tmp/x.jsonl uuid u cwd /tmp/proj folder $FA] \
    parent .s clipboard {noop} on_open {noop} on_move {noop} \
    on_bookmark {noop} on_rename {noop} \
    state [dict create is_bookmarked 0 has_cwd 1 has_folder 1]]
::questlog::ui::session_actions::populate .c8 $c8base
set c8_nohit [menu_labels .c8]
check "no hit -> last assistant output shown" \
    [expr {"Copy last assistant output" in $c8_nohit}] 1
check "no hit -> this snippet absent" \
    [expr {"Copy this snippet" in $c8_nohit}] 0
::questlog::ui::session_actions::populate .c8 \
    [dict merge $c8base [dict create hit [dict create lineoff 3 snippet s] on_open_at {noop}]]
set c8_hit [menu_labels .c8]
check "hit -> this snippet shown" \
    [expr {"Copy this snippet" in $c8_hit}] 1
check "hit -> last assistant output suppressed" \
    [expr {"Copy last assistant output" in $c8_hit}] 0

# ---- C6: fmt_size KB/MB/GB ------------------------------------------------
check "fmt_size bytes"     [$SL fmt_size 512]         "512 B"
check "fmt_size KB"        [$SL fmt_size 48000]       "46 KB"
check "fmt_size MB"        [$SL fmt_size 5000000]     "4.8 MB"
check "fmt_size GB"        [$SL fmt_size 2000000000]  "1.9 GB"

# ---- C7: badge labels in the reader's words -------------------------------
check "badge label user -> user text"       [$SL badge_label user]        "user text"
check "badge label tool_use -> tool call"   [$SL badge_label tool_use]    "tool call"
check "badge label tool_result unchanged"   [$SL badge_label tool_result] "tool result"
check "badge label assistant unchanged"     [$SL badge_label assistant]   "assistant"

# ---- C3: elevated cost cells carry a bolder weight ------------------------
check "cost-mid is bold"     [$TX tag cget cost-mid -font]     QLBold
check "cost-outlier is bold" [$TX tag cget cost-outlier -font] QLBold

# ---- B3/C4: Cancel rests disabled, live only during a search --------------
check "cancel disabled at rest" [.s.bar.cancel cget -state] disabled
set ${NS}::TotalCost 1.50
$SL set_progress 2 10 1
check "cancel enabled while searching"  [.s.bar.cancel cget -state] normal
check "strip reads 'and counting' mid-search" \
    [string match "*and counting*" [set ${NS}::StatusVar]] 1
$SL set_done 10 1
check "cancel disabled once done"       [.s.bar.cancel cget -state] disabled
check "strip drops 'and counting' when done" \
    [string match "*and counting*" [set ${NS}::StatusVar]] 0
# The idle Cancel is inert: a stray invoke must not stamp "Cancelled." over rest.
set ${NS}::StatusBase "resting"
$SL cancel
check "cancel while idle is a no-op" [set ${NS}::StatusBase] "resting"

# ---- Stream the sessions in, then enter search mode. ----------------------
$SL apply_filter [dict create since all]
set ::scan_done 0
$::Scan extend [dict create since all]
after 200 [list set ::scan_done 1]
vwait ::scan_done
# Search mode: folders auto-expand, matches build the index.
$SL apply_filter [dict create since all search work]

# ---- B6: parent overflow past the snippet cap (3) -------------------------
set matches {}
foreach lo {2 4 6 8 10} {
    lappend matches [dict create path $S1 folder $FA btype tool_use \
        content "hit at line $lo work" lineoff $lo]
}
$SL add_session_matches $matches
update
check "session over the cap is rendered" [$SL sflag $S1 rendered] 1
check "overflow row names the rest (5 matches, cap 3 -> +2)" \
    [has_line "*2 more matches in this session - open to see all*"] 1

# A session within the cap emits no overflow row.
$SL add_session_matches [list \
    [dict create path $S2 folder $FA btype user content "gamma work one" lineoff 3] \
    [dict create path $S2 folder $FA btype user content "gamma work two" lineoff 5]]
update
check "session within the cap has no overflow row" \
    [expr {[llength [regexp -all -inline "more match" [widget_text]]]}] 1

# ---- B1: every general open lands at the start; only a deep link names a line
# The search's first match sits at line 2; opening without naming a line (the
# menu's Open in viewer takes this path) reads from the top regardless.
set ::opened "(never)"
$SL open_session $S1
check "an open that names no line lands at the start" $::opened [list $S1 0]
set ::opened "(never)"
$SL on_snippet_release $S1 2
check "snippet click deep-links to its line" $::opened [list $S1 2]
# Plain click: aim at the subject text, past the marker gutter, well clear of
# the right-pinned actions cell.
set sm [$SL node_field [$SL sid $S1] start]
lassign [$TX bbox "$sm +6c"] bx by bw bh
set X [expr {[winfo rootx $TX] + $bx + 1}]
set Y [expr {[winfo rooty $TX] + $by + 1}]
set ::opened "(never)"
$SL on_session_release $S1 $X $Y
check "plain click opens at the session start (line 0)" $::opened [list $S1 0]

# ---- C9 + C10a + B6(subagent): case B (only subagents matched) ------------
# Two matches inside one subagent of parent PB; the parent has no direct hit.
$SL add_session_matches [list \
    [dict create is_child 1 path [file join $PBSUB agent-1.jsonl] \
        parent_path $PB folder $FA agent_id agent-1 \
        btype tool_use content "sub hit one work" lineoff 4] \
    [dict create is_child 1 path [file join $PBSUB agent-1.jsonl] \
        parent_path $PB folder $FA agent_id agent-1 \
        btype tool_use content "sub hit two work" lineoff 8]]
update
check "case-B parent is rendered" [$SL sflag $PB rendered] 1
check "case-B note sits below the row (2 matches, 1 subagent)" \
    [has_line "*no match in this session - 2 matches below in a subagent*"] 1
# The subject run is dimmed (only its subagents matched). The subject begins
# after the chevron and its tab, so probe the first subject character rather
# than a fixed offset into the line.
set sm [$SL node_field [$SL sid $PB] start]
check "case-B subject run is dimmed" \
    [expr {"dimmed" in [$TX tag names "$sm +3c"]}] 1
# Subagent capped at snippets_per_subagent (1); its 2nd match becomes overflow.
check "subagent overflow names the rest (2 matches, cap 1 -> +1)" \
    [has_line "*1 more match in this session - open to see all*"] 1

# ---- C10a: case C pip singularises on one subagent match ------------------
# PC has one direct match AND one subagent match: header shows "+1 in subagent".
$SL add_session_matches [list \
    [dict create path $PC folder $FA btype user content "parent-c work" lineoff 1]]
$SL add_session_matches [list \
    [dict create is_child 1 path [file join $PCSUB agent-1.jsonl] \
        parent_path $PC folder $FA agent_id agent-1 \
        btype tool_use content "sub c work" lineoff 3]]
update
set psm [$SL node_field [$SL sid $PC] start]
set headline [$TX get $psm "$psm lineend"]
check "case-C pip singularises to '+1 in subagent'" \
    [string match "*+1 in subagent*" $headline] 1
check "case-C pip is not pluralised" \
    [string match "*+1 in subagents*" $headline] 0
check "case-C header keeps its own direct match count" \
    [string match "*1 match*" $headline] 1

# ---- case B -> case C: the subagent's match lands before the parent's own --
# The note case B drew must lift when direct matches arrive, and the children
# it rendered re-lay below the parent's own content.
set PD [file join $DIRA parentd.jsonl]
write_session $PD {parent-d work} "2026-05-24T13:00"
set PDSUB [file join $DIRA parentd subagents]
::questlog::path::_real_file mkdir $PDSUB
write_session [file join $PDSUB agent-1.jsonl] {subwork} "2026-05-24T13:00"
$SL add_session_matches [list \
    [dict create is_child 1 path [file join $PDSUB agent-1.jsonl] \
        parent_path $PD folder $FA agent_id agent-1 \
        btype tool_use content "pd sub hit work" lineoff 4]]
update
check "reversed order: case-B note stands while only the subagent matched" \
    [has_line "*no match in this session - 1 match below in a subagent*"] 1
$SL add_session_matches [list \
    [dict create path $PD folder $FA btype user content "pd own hit work" lineoff 1]]
update
check "reversed order: the note lifts once a direct match arrives" \
    [has_line "*no match in this session - 1 match below in a subagent*"] 0
set pdm [$SL node_field [$SL sid $PD] start]
check "reversed order: the subject is no longer dimmed" \
    [expr {"dimmed" in [$TX tag names "$pdm +6c"]}] 0
set pdend [$SL node_field [$SL sid $PD] end]
set snip [$TX search "pd own hit work" $pdm $pdend]
set sub  [$TX search "pd sub hit work" $pdm $pdend]
check "reversed order: the parent's own snippet is drawn" [expr {$snip ne ""}] 1
check "reversed order: the subagent block sits below the parent's snippet" \
    [$TX compare $snip < $sub] 1

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
