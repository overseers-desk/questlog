#!/usr/bin/env wish9.0
# Viewer turn-fold benchmark. The honest guard on the series' central bet: that
# elide-based folding stays responsive on a multi-MB session. Prints one
# markdown table - median over 3 in-process iterations with the min-max spread
# (the first iteration carries bytecode compilation and allocator warmup, which
# the median discards), plus a VmRSS delta from fresh child processes.
#
# The document under test is a REAL session: the largest .jsonl under
# ~/.claude/projects (reported below with its on-disk size and the rendered
# line/turn count - a big jsonl renders far smaller than its byte size, since
# the viewer caps tool output). A synthetic multi-turn corpus is generated only
# when no real session is found, so the script runs anywhere.
#
# What each scenario measures (keep these captions in sync with the table):
#   show        one full open: load + render + index_matches(empty) +
#               index_tool_calls + index_turns, with count -update -ypixels
#               forced INSIDE the timed region so the number provably includes
#               the async line-metric pass (full layout) on every Tk build.
#   index_matches  a frequent term whose hits sit inside hidden detail; the
#               search carries -elide, which is what lets a hit in a folded
#               block be found. Hit count reported.
#   fold_all    collapse every turn to its header + stub, then the same forced
#               line-metric pass: this is the table-of-contents latency, the
#               number the >1s tripwire watches.
#   expand_all  the reverse (details stay hidden - a refold re-hides them).
#   reveal jump jump_to_match into a hit that is hidden under a full fold:
#               reveal_index unfolds the turn and un-hides its detail, then sees.
#   yview sweep 20 moveto steps across the document, per-step median, once
#               folded and once expanded: scroll cost over an elide-heavy doc.
#   VmRSS       whole-document RSS delta from an empty viewer, median of 3 fresh
#               processes, after show (expanded) and after fold_all. Elide keeps
#               the content in the widget, so the fold delta should be ~nil.

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add $ROOT
package require leash
package require streamtree
foreach f {config.tcl lib/debug.tcl lib/path.tcl lib/jsonl.tcl lib/match.tcl \
           ui/theme.tcl ui/viewer.tcl} {
    source [file join $ROOT $f]
}
# The match procs read the display caps once per interp (the launcher does the
# same); the tool timeline formats tool_use blocks through them.
::questlog::match::set_caps [dict create \
    content_cap     [::questlog::config::get content_cap] \
    snippet_lead    [::questlog::config::get snippet_lead] \
    snippet_trail   [::questlog::config::get snippet_trail] \
    tool_param_cap  [::questlog::config::get tool_param_cap] \
    tool_render_cap [::questlog::config::get tool_render_cap]]
::questlog::ui::theme::init

# ---- helpers ----------------------------------------------------------------
proc rss_kb {} {
    set fh [open /proc/self/status r]; set s [read $fh]; close $fh
    regexp {VmRSS:\s+(\d+) kB} $s -> kb
    return $kb
}
proc median {vals} { return [lindex [lsort -real $vals] [expr {[llength $vals] / 2}]] }
proc median3 {vals} { return [lindex [lsort -real $vals] 1] }
proc ms {us} { return [format %.0f [expr {$us / 1000.0}]] }
proc ms2 {us} { return [format %.2f [expr {$us / 1000.0}]] }
# "median (min-max)" in ms, from three raw microsecond samples.
proc spread_ms {vals} {
    set s [lsort -real $vals]
    return "[ms [lindex $s 1]] ms ([ms [lindex $s 0]]-[ms [lindex $s 2]])"
}
# Force the async line-metric pass to finish inside the caller's timed region.
proc force_metrics {T} { $T count -update -ypixels 1.0 end }

# ---- child mode: one viewer, RSS delta after show then after fold_all -------
# Measured from an empty viewer, so the number is the document's own footprint;
# the two points differ only by whatever fold_all allocates (elide keeps every
# character resident, so the difference should be near zero).
if {[llength $argv] >= 2 && [lindex $argv 0] eq "childmem"} {
    set path [lindex $argv 1]
    set V [::questlog::ui::Viewer new .v]
    pack .v -fill both -expand 1
    update
    set before [rss_kb]
    $V show $path 0 {}
    update
    force_metrics [$V textwidget]
    set expanded [expr {[rss_kb] - $before}]
    $V fold_all
    update
    force_metrics [$V textwidget]
    set folded [expr {[rss_kb] - $before}]
    puts "$expanded $folded"
    exit 0
}

# ---- corpus: the largest real session, else a synthetic fallback ------------
proc largest_session {} {
    set best ""; set bestsz 0
    set root [::questlog::path::projects_root]
    foreach d [glob -nocomplain -type d -directory $root *] {
        foreach f [glob -nocomplain -directory $d *.jsonl] {
            set sz [file size $f]
            if {$sz > $bestsz} { set bestsz $sz; set best $f }
        }
    }
    return [list $best $bestsz]
}

# A multi-turn corpus written when no real session exists: typed prompts, each
# turn carrying thinking + prose + a Read tool_use (with a file_path input) and
# its result, plus padding so the file reaches a few MB. Detail blocks give the
# fold something to hide; "file_path" gives the search term something to find.
proc gen_synthetic {path nturns} {
    set fh [open $path w]
    fconfigure $fh -encoding utf-8
    set pad [string repeat "lorem ipsum dolor sit amet consectetur " 40]
    for {set i 0} {$i < $nturns} {incr i} {
        set ts [format "2026-01-01T%02d:%02d:%02dZ" [expr {$i / 3600 % 24}] [expr {$i / 60 % 60}] [expr {$i % 60}]]
        puts $fh [subst -nocommands {{"type":"user","promptSource":"typed","cwd":"/tmp/proj","timestamp":"$ts","message":{"role":"user","content":"Question number $i about the subsystem. $pad"}}}]
        puts $fh [subst -nocommands {{"type":"assistant","timestamp":"$ts","message":{"role":"assistant","model":"claude-x","content":[{"type":"thinking","thinking":"reasoning step $i $pad","signature":"s$i"},{"type":"text","text":"Answer $i. $pad"},{"type":"tool_use","id":"t$i","name":"Read","input":{"file_path":"/tmp/module-$i.txt"}}],"usage":{"input_tokens":10,"output_tokens":5}}}}]
        puts $fh [subst -nocommands {{"type":"user","timestamp":"$ts","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t$i","content":"file_path contents for module $i: $pad"}]}}}]
    }
    close $fh
}

set tmpbase [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set TMP [file join $tmpbase ql-bench-fold-[pid]]
::questlog::path::_real_file mkdir $TMP

lassign [largest_session] SESSION SIZE
set SYNTH 0
if {$SESSION eq ""} {
    set SESSION [file join $TMP synth.jsonl]
    gen_synthetic $SESSION 600
    set SIZE [file size $SESSION]
    set SYNTH 1
}

# ---- the viewer under test --------------------------------------------------
set V [::questlog::ui::Viewer new .v]
pack .v -fill both -expand 1
update
set T [$V textwidget]
set NS [info object namespace $V]

# ---- scenario bodies --------------------------------------------------------
proc t_show {} {
    set t0 [clock microseconds]
    $::V show $::SESSION 0 {}
    update
    force_metrics $::T
    return [expr {[clock microseconds] - $t0}]
}
proc t_index {term} {
    set t0 [clock microseconds]
    $::V index_matches [dict create terms [list $term] nocase 0]
    return [expr {[clock microseconds] - $t0}]
}
proc find_count {} { return [llength [set ${::NS}::FindMatches]] }
proc t_fold {} {
    set t0 [clock microseconds]
    $::V fold_all
    update
    force_metrics $::T
    return [expr {[clock microseconds] - $t0}]
}
proc t_expand {} {
    set t0 [clock microseconds]
    $::V expand_all
    update
    force_metrics $::T
    return [expr {[clock microseconds] - $t0}]
}
# jump_to_match 0 from a fully folded document, into a hidden hit. Returns the
# jump latency; the caller resets the fold afterward.
proc t_reveal {term} {
    $::V fold_all
    update
    $::V index_matches [dict create terms [list $term] nocase 0]
    set t0 [clock microseconds]
    $::V jump_to_match 0
    update
    return [expr {[clock microseconds] - $t0}]
}
# 20 moveto steps across the document; returns per-step latencies (us).
proc sweep {} {
    set lat [list]
    for {set i 0} {$i <= 20} {incr i} {
        set frac [expr {$i / 20.0}]
        set s [clock microseconds]
        $::T yview moveto $frac
        update idletasks
        lappend lat [expr {[clock microseconds] - $s}]
    }
    $::T yview moveto 0
    return $lat
}

# ---- run --------------------------------------------------------------------
# show: fresh open each iteration (show resets the whole document).
set show_v [list [t_show] [t_show] [t_show]]
# The document is now freshly shown (expanded, detail hidden by default).

# Pick a frequent term whose hits land in hidden detail. Prefer "file_path";
# fall back to whatever the corpus offers.
set TERM ""; set HITS 0
foreach cand {file_path error Read result the} {
    $V index_matches [dict create terms [list $cand] nocase 0]
    if {[find_count] > 0} { set TERM $cand; set HITS [find_count]; break }
}

set index_v [list [t_index $TERM] [t_index $TERM] [t_index $TERM]]

# fold/expand pair: each iteration folds from the expanded state then expands
# back, so both start from a known baseline.
set fold_v [list]; set expand_v [list]
foreach - {1 2 3} {
    lappend fold_v [t_fold]
    lappend expand_v [t_expand]
}

# reveal jump: median of 3, each with a fresh fold + index; confirm the hidden
# hit is laid out afterward (bbox non-empty means the reveal put it on screen).
set reveal_v [list]
foreach - {1 2 3} {
    lappend reveal_v [t_reveal $TERM]
    $V expand_all; update
}
$V fold_all; update
$V index_matches [dict create terms [list $TERM] nocase 0]
set h0 [lindex [set ${NS}::FindMatches] 0]
set hidden_before [expr {[$T count -displaychars $h0 "$h0 + 1c"] == 0}]
$V jump_to_match 0; update
set shown_after [expr {[$T bbox $h0] ne ""}]
$V expand_all; update

# yview sweeps, folded then expanded, per-step median.
$V fold_all; update
set sweep_folded [sweep]
$V expand_all; update
set sweep_expanded [sweep]

# document shape, for the caption and per-scenario detail.
set nrec   [llength [set ${NS}::Records]]
set nturns [llength [set ${NS}::Turns]]
set nlines [expr {[lindex [split [$T index end] .] 0] - 1}]

# VmRSS: median of 3 fresh processes, expanded and folded.
proc childmem {path} { return [exec [info nameofexecutable] [info script] childmem $path] }
set exps [list]; set folds [list]
foreach - {1 2 3} {
    lassign [childmem $SESSION] e f
    lappend exps $e; lappend folds $f
}
set rss_exp [median3 $exps]
set rss_fold [median3 $folds]

# ---- output -----------------------------------------------------------------
set cpu unknown
catch {
    set fh [open /proc/cpuinfo r]; set ci [read $fh]; close $fh
    regexp {model name\s*:\s*([^\n]+)} $ci -> cpu
}
set szmb [format %.2f [expr {$SIZE / 1048576.0}]]
set src [expr {$SYNTH ? "synthetic fallback (no real session found)" : $SESSION}]
puts "Tcl [info patchlevel], Tk [package present Tk], $cpu, [exec uname -sr],\
Xvfb (software rendering)."
puts "Session: $src"
puts "On disk $szmb MB; renders to $nlines lines / $nrec records / $nturns turns\
(the viewer caps tool output, so a big jsonl renders far smaller)."
puts ""
puts "| scenario | median (min-max) | detail | notes |"
puts "|---|---|---|---|"
puts "| show (load+render+index+metrics) | [spread_ms $show_v] | $nturns turns, $nlines lines | count -update forced inside the timed region |"
puts "| index_matches \"$TERM\" | [spread_ms $index_v] | $HITS hits | -elide finds hits inside hidden detail |"
puts "| fold_all + line metrics | [spread_ms $fold_v] | $nturns turns -> ToC | table-of-contents latency (the >1s tripwire) |"
puts "| expand_all + line metrics | [spread_ms $expand_v] | | detail stays hidden (refold re-hid it) |"
puts "| reveal jump (folded -> hidden hit) | [spread_ms $reveal_v] | hidden before: [expr {$hidden_before?{yes}:{NO}}], shown after: [expr {$shown_after?{yes}:{NO}}] | jump_to_match unfolds + un-hides + sees |"
puts "| yview sweep, folded | [ms2 [median $sweep_folded]] ms/step | 20 steps | scroll over the folded ToC |"
puts "| yview sweep, expanded | [ms2 [median $sweep_expanded]] ms/step | 20 steps | scroll over the full transcript |"
puts "| VmRSS after show (expanded) | [format %.1f [expr {$rss_exp / 1024.0}]] MB | median of 3 procs | whole-document delta from an empty viewer |"
puts "| VmRSS after fold_all | [format %.1f [expr {$rss_fold / 1024.0}]] MB | median of 3 procs | elide keeps content: [format %+.1f [expr {($rss_fold - $rss_exp) / 1024.0}]] MB vs expanded |"
puts ""

# ---- the >1s tripwire -------------------------------------------------------
set fold_med [median3 $fold_v]
set sweep_med [median $sweep_folded]
set sweep_max [lindex [lsort -real $sweep_folded] end]
set tripped 0
if {$fold_med > 1000000} { set tripped 1 }
if {$sweep_med > 1000000 || $sweep_max > 1000000} { set tripped 1 }
if {$tripped} {
    puts "TRIPWIRE: fold_all or the folded scroll sweep exceeded 1s on this session."
    puts "Elide-based folding is too slow at this scale. The fallback is to fold"
    puts "by delete-and-re-render between marks instead of elide - the posture"
    puts "streamtree-1.0.2.tm already implements for the session list - at the"
    puts "cost of moving search from the widget to the model and every bare"
    puts "index in the viewer to marks."
} else {
    puts "Tripwire clear: fold_all median [ms $fold_med] ms and folded sweep\
(median [ms2 $sweep_med] ms/step, max [ms2 $sweep_max] ms/step) are all well under 1s."
}

# ---- clean up ---------------------------------------------------------------
::questlog::path::_real_file delete -force $TMP
exit 0
