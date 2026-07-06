package require Tcl 9

# Markdown export of a session transcript. The text-only mirror of what the
# viewer's `render` shows: USER / ASSISTANT / TOOL RESULT / SYSTEM turns in
# document order (the label comes from ::questlog::jsonl::record_role_label, the
# same helper the viewer uses, so a tool result never reads USER on either side),
# broken into the same segments by the same two cues. The export mirrors the
# viewer body verbatim: ::questlog::jsonl::extract_text renders tool_use as
# `Tool(args)`, thinking as `[thinking] ...`, and image blocks as `[image]`
# placeholders, and prefixes tool_result with `ERROR: ` when is_error is true,
# so all of that flows through into the exported markdown alongside the prose.
#
# Segmentation reuses the viewer's helpers and threshold so the two never
# disagree on where a session breaks:
#   primary   - a compact_boundary record (::questlog::jsonl::is_compact_boundary)
#               opens a "## --- /compact ---" heading and resets the clock.
#   secondary - a silence of viewer_idle_gap_min minutes or more between content
#               turns opens a "## --- N later ---" heading.
# A record whose extract_text is empty (a metadata snapshot or attachment)
# emits no turn but still advances the clock, the same as the viewer, so an idle
# gap is measured from the last real message either side of the quiet records.
namespace eval ::questlog::markdown {
    namespace export export_session
}

# Build and return the Markdown for one session jsonl. Walks the file line by
# line (the read+parse idiom of ::questlog::jsonl::last_assistant_text: utf-8,
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
        set rec [::questlog::jsonl::parse_line $line]
        if {$rec eq ""} continue

        set ts_iso [::questlog::jsonl::record_timestamp $rec]
        set ts_epoch [::questlog::jsonl::parse_iso $ts_iso]

        # Primary divider: a compaction boundary. Reset the clock so the first
        # turn after a compaction never reads as an idle gap from before it.
        if {[::questlog::jsonl::is_compact_boundary $rec]} {
            lappend out [list divider "## --- /compact ---"]
            set last_ts 0
            continue
        }

        # A record with no text body (tool-only turn, file-history snapshot,
        # attachment) emits nothing but keeps the clock moving for gap
        # detection, matching the viewer's render.
        set body [::questlog::jsonl::extract_text $rec]
        if {$body eq ""} {
            if {$ts_epoch > 0} { set last_ts $ts_epoch }
            continue
        }

        # Secondary divider: an idle gap between content turns.
        if {$last_ts > 0 && $ts_epoch > 0} {
            set gap [expr {($ts_epoch - $last_ts) / 60}]
            if {$gap >= $idle_gap} {
                lappend out [list divider \
                    "## --- [::questlog::jsonl::fmt_gap $gap] later ---"]
            }
        }

        lappend out [list turn [::questlog::jsonl::record_role_label $rec] $body $lineno]
        if {$ts_epoch > 0} { set last_ts $ts_epoch }
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
