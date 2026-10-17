package require Tcl 9

# Markdown export of a session transcript. The text-only mirror of what the
# viewer's `render` shows: USER / ASSISTANT / TOOL RESULT / SYSTEM turns in
# document order (the label comes from ::logman::record_role_label, the
# same helper the viewer uses, so a tool result never reads USER on either side),
# broken into the same segments by the same two cues. The export mirrors the
# viewer body verbatim: ::logman::extract_text renders tool_use as
# `Tool(args)`, thinking as `[thinking] ...`, and image blocks as `[image]`
# placeholders, and prefixes tool_result with `ERROR: ` when is_error is true,
# so all of that flows through into the exported markdown alongside the prose.
#
# Segmentation runs off ::logman::transcript_step, the single classifier
# the viewer folds over too (issue #31), so the two cannot disagree on where a
# session breaks. This export only formats the cues the step hands back:
#   primary   - a compact_boundary record ({compact}) opens a "## --- /compact
#               ---" heading and resets the clock.
#   secondary - a silence of viewer_idle_gap_min minutes or more between content
#               turns ({gap N}) opens a "## --- N later ---" heading.
# A record whose extract_text is empty (a metadata snapshot or attachment) yields
# no event but still advances the clock inside the step, the same as the viewer,
# so an idle gap is measured from the last real message either side of the quiet
# records.
namespace eval ::questlog::markdown {
    namespace export export_session
}

# Build and return the Markdown for one session jsonl. Walks the file line by
# line (the read+parse idiom of ::logman::last_assistant_text: utf-8,
# replace profile), classifies each record by type, and emits a role heading
# plus the text body. Returns "" for a file that cannot be opened.
#
# With anchors true, each turn's heading carries its 1-based jsonl record number
# (the physical line, the same index the viewer's LineMap and the search --json
# "line" field use), so the headless `questlog show` output can be cited and a
# reader can jump back to a record. The GUI copy/export-markdown actions leave
# anchors off, so their output stays clean.
#
# With dialogue true the export drops to the human<->AI conversation
# (::logman::dialogue_body): the user's prompts and the assistant's prose, no
# tool calls, tool results, thinking, or dividers - the reading that a study of
# the interaction itself wants. anchors still cite each kept turn.
#
# roles narrows that view to one side: a list drawn from {user assistant}, the
# empty list keeping both. The prompts alone are a session read for how the
# human drove it, at a fraction of the tokens the replies cost; the anchors are
# what a reader follows back into the file for the replies worth having.
proc ::questlog::markdown::export_session {path {anchors 0} {dialogue 0} {roles {}}} {
    if {[catch {open $path r} fh]} { return "" }
    chan configure $fh -encoding utf-8 -profile replace

    set idle_gap [::questlog::config::get viewer_idle_gap_min]
    set out [list]
    set last_ts 0
    set lineno 0
    # Read the records before walking them: the turn grouping the viewer shows
    # needs the whole list, because a prompt is a draft only once a later one
    # arrives with no assistant reply between. Nothing is lost by the wait, the
    # assembled output being whole-file already.
    set recs [list]
    while {[chan gets $fh line] >= 0} {
        incr lineno
        if {$line eq ""} continue
        set rec [::logman::parse_line $line]
        if {$rec eq ""} continue
        dict set rec _line $lineno
        lappend recs $rec
    }
    close $fh

    # A rolled-back branch, the turns a rewind abandoned, becomes a <details>
    # block, the mirror of the viewer's folded ROLLED BACK line. Inside it the
    # idle-gap clock runs on the branch's own time; after it the clock resumes
    # where the branch left the surviving path, so a gap is measured along the
    # conversation that stood.
    set clocks [list]
    foreach rec [::logman::mark_turns $recs] {
        if {[dict exists $rec _branch_open]} {
            lappend out [list open \
                [::logman::branch_phrase [dict get $rec _branch_open]]]
            lappend clocks $last_ts
        }
        lassign [record_items $rec $last_ts $idle_gap $dialogue $roles] \
            items last_ts
        lappend out {*}$items
        for {set n [dict getdef $rec _branch_close 0]} {$n > 0} {incr n -1} {
            lappend out [list close]
            set last_ts [lindex $clocks end]
            set clocks [lrange $clocks 0 end-1]
        }
    }

    # Assemble: each turn is its bold role heading then the body; each divider
    # heading sits on its own. Blank lines separate every block, which is also
    # what lets the markdown inside a <details> block render. Each entry
    # carries its kind as its first element, so a body that happens to read
    # like a divider line is never mistaken for one.
    set blocks [list]
    foreach item $out {
        switch -- [lindex $item 0] {
            turn {
                lassign $item _ role text ln
                if {$anchors} {
                    lappend blocks "**\[#$ln] $role**\n\n$text"
                } else {
                    lappend blocks "**$role**\n\n$text"
                }
            }
            open {
                set phrase [string map {& &amp; < &lt; > &gt;} [lindex $item 1]]
                lappend blocks "<details><summary>ROLLED BACK · $phrase</summary>"
            }
            close { lappend blocks "</details>" }
            default { lappend blocks [lindex $item 1] }
        }
    }
    return [join $blocks "\n\n"]
}

# The export items one record yields, {turn role text line} and {divider
# text}, and the idle-gap clock it leaves: {items last_ts}.
proc ::questlog::markdown::record_items {rec last_ts idle_gap dialogue roles} {
    set lineno [dict get $rec _line]
    set out [list]
    # A draft the user edited away before the assistant answered. The viewer
    # renders only the message it was a draft of, so this mirror does the same,
    # and the two agree on where a session breaks.
    if {[dict exists $rec _superseded]} { return [list $out $last_ts] }

    # Dialogue view: the conversation only, no dividers. The one selector
    # (dialogue_body) yields "" for every non-dialogue record, so the walk keeps
    # just the user prompts and assistant prose.
    if {$dialogue} {
        set body [::logman::dialogue_body $rec $roles]
        if {$body ne ""} {
            lappend out [list turn [::logman::record_role_label $rec] $body $lineno]
        }
        return [list $out $last_ts]
    }

    # The shared segmenter (::logman::transcript_step) classifies the record
    # and moves the idle-gap clock; this export owns the format of every cue it
    # hands back. A compact boundary opens a primary divider and resets the
    # clock (the step returns last_ts 0); an idle gap opens a secondary divider,
    # emitted before the body so it sits above the turn; a non-empty body is a
    # role heading plus text. An empty-body record yields no events but still
    # advances the clock, so a gap spans the quiet metadata records between two
    # real messages.
    lassign [::logman::transcript_step $rec $last_ts $idle_gap] events last_ts
    foreach ev $events {
        switch -- [lindex $ev 0] {
            compact {
                lappend out [list divider "## --- /compact ---"]
            }
            gap {
                lappend out [list divider \
                    "## --- [::logman::fmt_gap [lindex $ev 1]] later ---"]
            }
            body {
                lappend out [list turn \
                    [::logman::record_role_label $rec] [lindex $ev 1] $lineno]
            }
        }
    }
    return [list $out $last_ts]
}
