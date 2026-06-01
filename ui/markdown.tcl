package require Tcl 9

# Markdown export of a session transcript. The text-only mirror of what the
# viewer's `render` shows: USER / ASSISTANT / SYSTEM turns in document order,
# broken into the same segments by the same two cues. Tool calls (tool_use /
# tool_result blocks) are deliberately out of scope - they belong to the
# tool-call timeline, not this text export - and ::questlog::jsonl::extract_text
# already drops tool_use blocks, so the text it returns is exactly the body this
# export wants.
#
# Segmentation reuses the viewer's helpers and threshold so the two never
# disagree on where a session breaks:
#   primary   - a compact_boundary record (::questlog::jsonl::is_compact_boundary)
#               opens a "## --- /compact ---" heading and resets the clock.
#   secondary - a silence of viewer_idle_gap_min minutes or more between content
#               turns opens a "## --- N later ---" heading.
# A record whose extract_text is empty (a tool-only turn or a metadata snapshot)
# emits no turn but still advances the clock, the same as the viewer, so an idle
# gap is measured from the last real message either side of the quiet records.
namespace eval ::questlog::ui::markdown {
    namespace export export_session
}

# Build and return the Markdown for one session jsonl. Walks the file line by
# line (the read+parse idiom of ::questlog::jsonl::last_assistant_text: utf-8,
# replace profile), classifies each record by type, and emits a role heading
# plus the text body. Returns "" for a file that cannot be opened.
proc ::questlog::ui::markdown::export_session {path} {
    if {[catch {open $path r} fh]} { return "" }
    chan configure $fh -encoding utf-8 -profile replace

    set idle_gap [::questlog::config::get viewer_idle_gap_min]
    set out [list]
    set last_ts 0
    while {[chan gets $fh line] >= 0} {
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

        lappend out [list turn [role_label [dict getdef $rec type ""]] $body]
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
            lassign $item _ role text
            lappend blocks "**$role**\n\n$text"
        } else {
            lappend blocks [lindex $item 1]
        }
    }
    return [join $blocks "\n\n"]
}

# Map a record type to its export role heading. Conversation types only;
# anything else has already been filtered out by an empty extract_text, but a
# defensive default keeps an unexpected type labelled rather than blank.
proc ::questlog::ui::markdown::role_label {type} {
    switch -- $type {
        user      { return USER }
        assistant { return ASSISTANT }
        default   { return SYSTEM }
    }
}
