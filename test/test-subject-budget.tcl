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
           ui/sessions.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

set SAND [file join [pwd] _subjectbudget_sandbox]
::questlog::path::_real_file delete -force $SAND
set ::env(HOME) $SAND

proc noop {args} {}
set SL [::questlog::ui::SessionList new .s noop noop noop noop noop noop noop \
            noop noop noop noop noop noop noop]

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

::questlog::path::_real_file delete -force $SAND
if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
