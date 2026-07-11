#!/usr/bin/env wish9.0
# Data spliced into a bind script survives bind's % substitution (issue #41).
#
# bind runs its % pass over the whole script string before Tcl parses it, so a
# session path or folder name holding a % ("100%pure") used to be rewritten in
# place - the handler received a path that does not exist. Every splice now
# rides pctsafe (percent doubling); this builds a sandbox project whose
# directory name carries a %, checks the wired scripts hold the doubled form,
# and proves the round trip on a real generated event: the open callback must
# receive the true path, single % and all.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _pctsafe_sandbox]
set FA "-tmp-100%pure"

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add $ROOT
package require leash
package require streamtree
foreach f {config.tcl lib/cost.tcl ui/theme.tcl lib/path.tcl lib/filter.tcl lib/sessionlist.tcl lib/jsonl.tcl \
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
proc session_moment {days_ago} { return [expr {[clock seconds] - $days_ago*24*3600}] }

proc write_session {path ts} {
    set fh [open $path w]
    fconfigure $fh -encoding utf-8
    puts $fh [string map [list @TS@ $ts] {{"type":"user","promptSource":"typed","cwd":"/tmp/proj","timestamp":"@TS@Z","message":{"role":"user","content":"hello from the percent folder"}}}]
    puts $fh [string map [list @TS@ $ts] {{"type":"assistant","timestamp":"@TS@Z","message":{"role":"assistant","model":"claude-x","content":[{"type":"text","text":"a reply"}],"usage":{"input_tokens":5,"output_tokens":5}}}}]
    close $fh
}

set SP [file join $DIRA s01.jsonl]
set when [session_moment 1]
write_session $SP [clock format $when -format "%Y-%m-%dT%H:%M:%S" -gmt 1]
file mtime $SP $when

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc lookup {path}   { return [$::Scan lookup $path] }
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

# The open callback is the round trip's witness: it records exactly the path
# the fired binding delivered.
set ::opened "(never)"
proc record_open {path args} { set ::opened $path }

set SL [::questlog::ui::SessionList new .s resolvef lookup record_open noop noop noop noop \
            noop scanpath noop subagentsf noop noop noop]
pack .s -fill both -expand 1
set TX .s.body.t

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

# --- Stream the percent-folder session in and render it.
$SL apply_filter [dict create since 30d]
set ::scan_done 0
$::Scan extend [dict create since 30d]
after 200 [list set ::scan_done 1]
vwait ::scan_done
$SL toggle_folder $FA
update
check "session under the % folder rendered" [$SL sflag $SP rendered] 1

# --- The wired scripts hold the doubled form, the shape bind's % pass
#     renders back to the literal path.
set NS [info object namespace $SL]
set sid [dict get [set ${NS}::PathNode] $SP]
set stag [$SL node_field $sid tag]
set script [$TX tag bind $stag <ButtonRelease-1>]
check "row bind script carries the %%-doubled path" \
    [string match "*100%%pure*" $script] 1
check "row bind script does not carry the raw path" \
    [string match "*100%pure*" [string map {%% ""} $script]] 0

# --- Round trip on a real event: inject a match so the badge (a real widget,
#     where event generate delivers and Tk runs its % pass) is wired, then
#     fire its release and demand the callback got the TRUE path.
$SL add_session_matches \
    [list [dict create path $SP folder $FA btype tool_use content "hit here" lineoff 1]]
update
$TX see end
update
set badge ""
foreach w [winfo children $TX] {
    if {[winfo class $w] eq "Label"} { set badge $w; break }
}
check "the snippet badge widget exists" [expr {$badge ne ""}] 1
event generate $badge <ButtonRelease-1>
update
check "the fired binding delivered the true path (single %)" $::opened $SP

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
