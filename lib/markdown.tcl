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
proc ::questlog::markdown::export_session {path {anchors 0}} {
    if {[catch {open $path r} fh]} { return "" }
    chan configure $fh -encoding utf-8 -profile replace

    set idle_gap [::questlog::config::get viewer_idle_gap_min]
    set out [list]
    set last_ts 0
    set lineno 0
    while {[chan gets $fh line] >= 0} {
        incr lineno
        if {$line eq ""} continue
        set rec [::logman::parse_line $line]
        if {$rec eq ""} continue

        # The shared segmenter (::logman::transcript_step) classifies
        # the record and moves the idle-gap clock; this export owns the format of
        # every cue it hands back. A compact boundary opens a primary divider and
        # resets the clock (the step returns last_ts 0); an idle gap opens a
        # secondary divider, emitted before the body so it sits above the turn; a
        # non-empty body is a role heading plus text. An empty-body record yields
        # no events but still advances the clock, so a gap spans the quiet
        # metadata records between two real messages.
        lassign [::logman::transcript_step $rec $last_ts $idle_gap] \
            events last_ts
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
                        [::logman::record_role_label $rec] \
                        [lindex $ev 1] $lineno]
                }
            }
        }
    }
    close $fh

    # Assemble: each turn is its bold role heading then the body; each divider
    # heading sits on its own. Blank lines separate every block. Each entry
    # carries its kind ("turn" or "divider") as its first element, so a body
    # that happens to read like a divider line is never mistaken for one.
    set blocks [list]
    foreach item $out {
        if {[lindex $item 0] eq "turn"} {
            lassign $item _ role text ln
            if {$anchors} {
                lappend blocks "**\[#$ln] $role**\n\n$text"
            } else {
                lappend blocks "**$role**\n\n$text"
            }
        } else {
            lappend blocks [lindex $item 1]
        }
    }
    return [join $blocks "\n\n"]
}
