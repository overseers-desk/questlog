#!/usr/bin/env wish9.0
# Reveal-on-hover for a clipped match snippet (issue #22).
#
# A snippet row is one line with -wrap none, so a snippet wider than the list
# column is cut at the right edge and its trailing context is unreachable from
# the list. Hovering the row now reveals the model's full stored snippet - not
# the clipped display - on the app's always-visible bottom strip,
# and leaving restores the strip's standing text. The strip is app.tcl's, so
# the list reaches it through the narrow status_peek/status_unpeek pair rather
# than poking the label; this drives that seam end to end over a one-session
# sandbox: the wired <Enter> binding carries the full text, a progress write
# arriving mid-peek is not lost when <Leave> restores, and the resting scope
# line returns.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _peek_sandbox]
set FA "-tmp-peek-a"

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add $ROOT
package require leash
package require streamtree
foreach f {config.tcl lib/cost.tcl ui/theme.tcl lib/path.tcl lib/filter.tcl lib/sessionlist.tcl lib/jsonl.tcl \
           lib/match.tcl ui/terminal.tcl ui/live.tcl lib/scan.tcl lib/search.tcl \
           ui/drag.tcl ui/toolbar.tcl ui/sessions.tcl ui/app.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

::questlog::path::_real_file delete -force $SAND
set DIRA [file join $SAND .claude projects $FA]
::questlog::path::_real_file mkdir $DIRA
set ::env(HOME) $SAND

# The status machine's variables, in the resting state start() would leave them
# in. The test never runs start (which would build the whole window); it exercises
# only the peek pair and refresh_status, which read exactly these.
namespace eval ::questlog::ui::app {
    variable StatusMode browse
    variable SearchSummary ""
    variable ViewerPath ""
    variable ProgressLine ""
    variable PeekText ""
    variable StatusVar ""
}

proc noop {args} {}

proc write_session {path ts} {
    set fh [open $path w]
    puts $fh "{\"type\":\"user\",\"cwd\":\"/tmp/proj\",\"timestamp\":\"${ts}Z\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}"
    puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}Z\",\"message\":{\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
    puts $fh "{\"type\":\"user\",\"timestamp\":\"${ts}Z\",\"message\":{\"role\":\"user\",\"content\":\"more\"}}"
    close $fh
}

proc session_moment {days_ago} { return [expr {[clock seconds] - $days_ago*24*3600}] }
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

# Wire the real app peek/restore procs as the list's status callbacks, so the
# hover drives the actual status machine (not a stub) and the mid-peek survival
# is a genuine assertion about refresh_status.
set SL [::questlog::ui::SessionList new .s resolvef lookup noop noop noop noop noop \
            noop scanpath noop subagentsf noop \
            ::questlog::ui::app::status_peek ::questlog::ui::app::status_unpeek]
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
proc statusvar {} { return [set ::questlog::ui::app::StatusVar] }

# --- Stream the one session in and open its folder so the row renders.
$SL apply_filter [dict create since 30d]
set ::scan_done 0
$::Scan extend [dict create since 30d]
after 200 [list set ::scan_done 1]
vwait ::scan_done
$SL toggle_folder $FA
update
check "session rendered" [$SL sflag $SP rendered] 1

# --- Inject a match whose snippet is far wider than any list column, so the
#     rendered row is clipped and only a hover can surface the tail.
set LONG "the quick brown fox jumps over the lazy dog and then keeps running far\
 past the right edge of the narrow session-list column where a reader cannot see\
 the trailing context without this hover reveal working end to end"
set matches [list [dict create path $SP folder $FA btype tool_use content $LONG lineoff 5]]
$SL add_session_matches $matches
update

set stored [lindex [lindex [$SL sget $SP snippets] 0] 1]
check "model holds the full untruncated snippet" $stored $LONG

# The n# tag on the freshly-drawn snippet, and its wired <Enter>/<Leave> scripts.
set ntags [lsearch -all -inline -glob [$TX tag names] n#*]
check "exactly one snippet tag" [llength $ntags] 1
set ntag [lindex $ntags 0]
set enter [$TX tag bind $ntag <Enter>]
set leave [$TX tag bind $ntag <Leave>]

# The binding must NOT embed the content: bind %-substitutes its script at
# event time, so embedded text holding a % is corrupted in place ("printf %s"
# becomes the state field). The script carries only the machine-made tag; the
# content waits in the registry and resolves when the event fires.
check "enter binding does not splice content into bind's script" \
    [string match "*$LONG*" $enter] 0
set NS [info object namespace $SL]
check "the registry resolves the tag to the full model text" \
    [string match "*$LONG*" [dict get [set ${NS}::PeekByTag] $ntag]] 1

# --- Standing text before any hover: the resting scope line. start() seeds the
#     bar from the machine once at launch; do the same before asserting on it.
::questlog::ui::app::refresh_status
check "resting bar is the scope line" [statusvar] [::questlog::ui::app::scope_status]

# --- <Enter>: the strip shows the badge kind then the whole snippet line.
eval $enter
check "peek shows badge-led full snippet" [statusvar] "tool_use · $LONG"

# --- A progress write arriving MID-PEEK: the machine's state advances but the
#     bar keeps the peek (refresh_status honours the flag at the top).
set ::questlog::ui::app::StatusMode searching
set ::questlog::ui::app::ProgressLine "Searching 5 / 10 · 3 matches"
::questlog::ui::app::refresh_status
check "mid-peek progress does not disturb the reveal" \
    [statusvar] "tool_use · $LONG"

# --- <Leave>: unpeek re-derives from the machine's CURRENT state, so the
#     mid-peek progress line surfaces now rather than a stale pre-peek snapshot.
eval $leave
check "unpeek surfaces the mid-peek progress (not a stale snapshot)" \
    [statusvar] "Searching 5 / 10 · 3 matches"

# --- Back to browse, hover then leave: the resting scope line returns.
set ::questlog::ui::app::StatusMode browse
set ::questlog::ui::app::ProgressLine ""
eval $enter
check "peek again while browsing" [statusvar] "tool_use · $LONG"
eval $leave
check "leave restores the standing scope line" \
    [statusvar] [::questlog::ui::app::scope_status]

# --- Percent-laden content survives verbatim: the very characters bind's
#     %-substitution corrupts ("printf %s" -> the state field, "50%" -> "50\ ")
#     ride the registry untouched. Injected as a second match so the reveal
#     runs the same wire -> registry -> resolve path as any snippet.
set PCT {printf %s lands 50% done and %% stays doubled}
$SL add_session_matches \
    [list [dict create path $SP folder $FA btype tool_use content $PCT lineoff 9]]
update
set ptag [lindex [lsearch -all -inline -glob [$TX tag names] n#*] end]
eval [$TX tag bind $ptag <Enter>]
check "a percent-laden snippet reveals verbatim" [statusvar] "tool_use · $PCT"
eval [$TX tag bind $ptag <Leave>]

# --- A wholesale clear under a parked pointer: the hovered row is deleted with
#     no guarantee Tk synthesizes its <Leave>, so reset_nodes itself unpeeks -
#     a peek must not outlive its row.
eval $enter
check "peek up before the clear" [statusvar] "tool_use · $LONG"
$SL reset
update
check "a wholesale clear drops the stale peek" \
    [statusvar] [::questlog::ui::app::scope_status]

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
