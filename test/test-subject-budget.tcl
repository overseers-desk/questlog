#!/usr/bin/env wish9.0
# Regression test for the session-subject width budget. A session row reads
# "chevron \t slug  preview \t metadata...": the bold slug (the session title)
# sits at the title tab stop, the preview follows, then the right-pinned
# metadata cells. session_subject (and child_subject for a subagent row) get a
# budget `max` from the base class - SubjectMax, the px the subject may fill
# before the metadata block.
#
# The bug: the bold slug was appended untrimmed. A slug wider than the room
# before the first metadata tab stop pushed the whole row past the Date stop,
# and every metadata cell cascaded onto the wrong column. The fix trims the slug
# with truncate_px against the budget, then fits the preview into what is left,
# so the visible run (slug + separator + preview) never overruns the budget.

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
set ::questlog_config_only 1; source [file join $ROOT questlog]
foreach f {lib/cost.tcl ui/theme.tcl lib/path.tcl \
           lib/listfilter.tcl lib/match.tcl ui/terminal.tcl \
           ui/live.tcl lib/scan.tcl lib/search.tcl ui/drag.tcl ui/toolbar.tcl \
           ui/reveal.tcl ui/sessions.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

set SAND [file join [pwd] _subjectbudget_sandbox]
::questlog::path::_real_file delete -force $SAND
set ::env(HOME) $SAND
unset -nocomplain ::env(CLAUDE_CONFIG_DIR)

proc noop {args} {}
set SL [::questlog::ui::SessionList new .s noop noop noop noop noop noop noop \
            noop noop noop noop noop]

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

# The subject builders read a node's payload straight off the store, so a
# synthetic node carrying just the payload dict is enough to exercise them at a
# known budget - no widget layout, no streamed scan. node_new returns the id.
proc subject_at {payload max} {
    return [$::SL session_subject [$::SL node_new default "" /tmp/subjbudget $payload] $max]
}
proc child_at {payload max} {
    return [$::SL child_subject [$::SL node_new subagent "" /tmp/subjbudget/sub $payload] $max]
}
# Pull one tagged run out of a subject by its {tag off len} range (char offsets).
proc tagged_run {res tagname} {
    set subj [dict get $res subject]
    foreach r [dict get $res tags] {
        lassign $r tag off len
        if {$tag eq $tagname} {
            return [string range $subj $off [expr {$off + $len - 1}]]
        }
    }
    return ""
}

set ELLIP "…"

# ---- case 1: a long slug is trimmed to the budget --------------------------
# A 200-char slug cannot fit a 300px budget: the slug is ellipsised, and the
# visible run (bold slug + the "  " separator + the QLList preview) stays inside
# the budget instead of shoving the row past the first metadata stop.
set MAX 300
set res [subject_at [dict create slug [string repeat x 200] count 0 sub_total 0 \
             has_subagents 0 label "make the retry backoff exponential"] $MAX]
set slug [tagged_run $res slug]
# Everything past the bold slug is drawn in QLList: the "  " gap then the
# preview. Trailing separator space (when the budget leaves no room for a
# preview) is not part of the visible run, so measure it trimmed.
set rest [string range [dict get $res subject] \
              [expr {[string first $slug [dict get $res subject]] + [string length $slug]}] end]
set run_px [expr {[font measure QLBold $slug] + [font measure QLList [string trimright $rest]]}]
check "long slug is ellipsised" [string index $slug end] $ELLIP
check "long-slug visible run fits the 300px budget" [expr {$run_px <= $MAX}] 1

# ---- case 2: a short slug stays whole, the preview still gets room ----------
# At a roomy budget a short slug is left untouched, and the preview lands after
# it rather than being starved by an over-long title.
set MAX 600
set res [subject_at [dict create slug "quick fix" count 0 sub_total 0 \
             has_subagents 0 label "adjust the retry backoff and log the outcome"] $MAX]
set slug [tagged_run $res slug]
set rest [string range [dict get $res subject] \
              [expr {[string first $slug [dict get $res subject]] + [string length $slug]}] end]
check "short slug is left untrimmed" $slug "quick fix"
check "short slug carries no ellipsis" [expr {[string first $ELLIP $slug] < 0}] 1
# rest is "  " + the preview; the preview past the two-space gap is non-empty.
check "the preview still gets room after a short slug" \
    [expr {[string length [string range $rest 2 end]] > 0}] 1
check "short-slug visible run fits the 600px budget" \
    [expr {[font measure QLBold $slug] + [font measure QLList $rest] <= $MAX}] 1

# The "  " after the slug is drawn too, so the budget holds it: a slug trimmed
# to the whole room would push the separator past the row's width. The title
# run starts at its tab stop, after the marker's reserved width.
proc title_px {res} {
    set subj [dict get $res subject]
    set slug [tagged_run $res slug]
    set at   [string first $slug $subj]
    return [expr {[font measure QLBold $slug] \
                  + [font measure QLList [string range $subj [expr {$at + [string length $slug]}] end]]}]
}
foreach MAX {60 90 120} {
    set res [subject_at [dict create slug [string repeat x 200] count 0 sub_total 0 \
                 has_subagents 0 label ""] $MAX]
    check "session row with its separator fits a ${MAX}px budget" \
        [expr {[$SL marker_w] + [title_px $res] <= $MAX}] 1
}
set res [subject_at [dict create slug [string repeat x 200] count 0 sub_total 0 \
             has_subagents 0 label ""] \
             [expr {[$SL marker_w] + [font measure QLList "  "]}]]
check "a slug with no room left drops its separator too" [dict get $res subject] "\t"

# ---- case 3: child_subject trims a long agent_type the same way ------------
# A subagent row is "spine  agent_type  preview"; the bold agent_type is trimmed
# to the budget just as the slug is, so a very long agent type never overruns.
set MAX 300
set res [child_at [dict create agent_type [string repeat a 200] \
             label "summarise the diff and report back"] $MAX]
set atype [tagged_run $res slug]
set subj  [dict get $res subject]
set spine [string range $subj 0 [expr {[string first $atype $subj] - 1}]]
set rest  [string range $subj [expr {[string first $atype $subj] + [string length $atype]}] end]
set run_px [expr {[font measure QLList $spine] \
                  + [font measure QLBold $atype] + [font measure QLList [string trimright $rest]]}]
check "long agent_type is ellipsised" [string index $atype end] $ELLIP
check "child visible run fits the 300px budget" [expr {$run_px <= $MAX}] 1

# The "  " after the agent type is drawn too, so the budget holds it: a type
# trimmed to the whole room would push the separator past the row's width.
proc child_px {res} {
    set subj  [dict get $res subject]
    set atype [tagged_run $res slug]
    set at    [string first $atype $subj]
    return [expr {[font measure QLList [string range $subj 0 [expr {$at - 1}]]] \
                  + [font measure QLBold $atype] \
                  + [font measure QLList [string range $subj [expr {$at + [string length $atype]}] end]]}]
}
foreach MAX {60 90 120} {
    set res [child_at [dict create agent_type [string repeat a 200] label ""] $MAX]
    check "child row with its separator fits a ${MAX}px budget" \
        [expr {[child_px $res] <= $MAX}] 1
}
set res [child_at [dict create agent_type [string repeat a 200] label ""] \
             [expr {[font measure QLList "▏  "] + [font measure QLList "  "]}]]
check "a type with no room left drops its separator too" [dict get $res subject] "▏  "

# ---- case 4: a cut title run carries the hover reveal ----------------------
# What the row cannot show, the hover shows: a trimmed row wires a t# tag over
# the title run and parks the whole name and preview in the reveal registry, so
# the reader reaches them without opening the session. A row that fits shows all
# it has and wires nothing.
proc reveal_entry {res} {
    foreach r [dict get $res tags] {
        lassign $r tag off len
        if {[string match "t#*" $tag]} {
            return [dict get [set [info object namespace $::SL]::PeekByTag] $tag]
        }
    }
    return ""
}
set LONGSLUG [string repeat x 200]
set LONGLABEL "make the retry backoff exponential and log every attempt it makes"
set LASTU "and now drop the jitter"
set LASTR "Dropped. The backoff is now a plain doubling from 1s."
set res [subject_at [dict create slug $LONGSLUG count 0 sub_total 0 \
             has_subagents 0 label $LONGLABEL \
             last_user $LASTU last_reply $LASTR] 300]
lassign [reveal_entry $res] rkind rtext rcursor rsub
check "a cut row reveals the whole name" $rkind $LONGSLUG
check "a cut row reveals the last prompt, not the first" $rtext $LASTU
check "a cut row reveals the reply to it" $rsub $LASTR
check "the title run leaves the cursor to the row" $rcursor 0

# A session with no finished exchange yet has nothing to say about where it got
# to, so the reveal falls back to the preview the row itself shows.
set res [subject_at [dict create slug $LONGSLUG count 0 sub_total 0 \
             has_subagents 0 label $LONGLABEL] 300]
lassign [reveal_entry $res] rkind rtext rcursor rsub
check "with no last prompt the reveal falls back to the row's preview" $rtext $LONGLABEL
check "with no reply the reveal carries none" $rsub ""

set res [subject_at [dict create slug "quick fix" count 0 sub_total 0 \
             has_subagents 0 label "short one"] 600]
check "an untrimmed row wires no reveal" [reveal_entry $res] ""

# ---- case 5: a folder heading cut to its aggregates reveals its path -------
# A project path is what names a folder, and a deep one is cut before the
# right-pinned aggregates. The heading carries the same reveal as a session row,
# with the path as the whole of it: there is nothing under a folder's name to
# show. A path that fits wires nothing.
# A heading takes its budget from the base class's LabelMax, the room before
# the first tab stop for a label laying no cell of its own.
proc folder_at {folder cwd max} {
    set ns [info object namespace $::SL]
    set ${ns}::LabelMax $max
    $::SL ensure_folder $folder $cwd
    return [$::SL folder_subject [$::SL fid $folder]]
}
set DEEP /home/somebody/code/a-long-organisation-name/a-long-repository-name/nested/deeper
set res [folder_at "-deep" $DEEP 200]
lassign [reveal_entry $res] rkind rtext
check "a cut folder heading reveals the whole path" $rkind \
    [::questlog::path::pretty_home $DEEP]
check "a folder reveal has nothing under the path" $rtext ""

set res [folder_at "-short" /tmp/p 200]
check "an untrimmed folder heading wires no reveal" [reveal_entry $res] ""

# The count rides in front of the stop with the label, so the budget holds both:
# a three-digit count under a narrow pane took the label's room and the heading
# threw its aggregates onto the next stop, a column right of the rows'.
# Synthetic children stand in for a scan; the fold counts session nodes off the
# store.
proc folder_with {folder cwd n max} {
    folder_at $folder $cwd $max
    set fid [$::SL fid $folder]
    set kids [list]
    for {set i 0} {$i < $n} {incr i} {
        lappend kids [$::SL node_new session $fid $folder/$i [dict create size 1]]
    }
    $::SL node_set $fid children $kids
    return [$::SL folder_subject $fid]
}
set res [folder_with "-many" /home/somebody/code/an-orchard-of-quilting-almanacs \
             130 90]
check "a heading with a three-digit count stays within the budget" \
    [expr {[font measure QLList [dict get $res subject]] <= 90}] 1
check "and keeps the count it was cut for" \
    [regexp {\(130\)$} [dict get $res subject]] 1

::questlog::path::_real_file delete -force $SAND
if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
