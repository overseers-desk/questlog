package require Tcl 9

# ::questlog::rename - the session-rename domain operation: append Claude Code's
# native rename records to a session jsonl, addressed purely by file path. No UI
# and no view state, so it loads in both CLI and GUI mode (sourced from lib/) and
# the `questlog rename` subcommand and the GUI dialog share one implementation.
#
# Two lines are appended per rename:
#   {"type":"custom-title","customTitle":<title>,"sessionId":<uuid>}
#   {"type":"agent-name","agentName":<title>,"sessionId":<uuid>}
# scan_one's slug is agentName > aiTitle, so the agent-name line is what the list
# reads; the custom-title line is for Claude Code's own picker. Both are well
# under PIPE_BUF, so each append is atomic against a live claude's own appends.

namespace eval ::questlog::rename {}

# Apply a rename to the session at `path`. A non-empty `entered` becomes the
# custom title; an empty `entered` reverts to the auto title (the file's last
# aiTitle). The uuid is the file basename - no model or scan object needed.
# Returns the effective title now in force, for a caller that wants to refresh a
# display without re-reading the file.
proc ::questlog::rename::apply {path entered} {
    set uuid [file rootname [file tail $path]]
    if {$entered eq ""} {
        set revert_to [current_ai_title $path]
        clear_custom $path $uuid $revert_to
        return $revert_to
    }
    set_custom $path $uuid $entered
    return $entered
}

# The file's current auto title: the last aiTitle in the tail window. scan_one is
# the richer reader, but it shares one open channel across a forward + tail pass
# and reuse here would re-read a small file end to end; revert needs only the
# auto title, so this takes its own minimal tail read and leaves the hot scan
# path untouched. "" when the session never generated an aiTitle.
proc ::questlog::rename::current_ai_title {path} {
    if {[catch {open $path r} fh]} { return "" }
    chan configure $fh -encoding utf-8 -profile replace
    if {[catch {file size $path} fsz]} { set fsz 0 }
    set tail_start [expr {$fsz - [::questlog::config::get tail_window_bytes]}]
    if {$tail_start > 0} {
        chan seek $fh $tail_start
        chan gets $fh _
    }
    set ai_title ""
    while {[chan gets $fh line] >= 0} {
        if {[regexp {"aiTitle":"([^"]+)"} $line -> m]} { set ai_title $m }
    }
    close $fh
    return $ai_title
}

proc ::questlog::rename::set_custom {path uuid title} {
    set title_json [json_escape $title]
    set uuid_json  [json_escape $uuid]
    set line1 "{\"type\":\"custom-title\",\"customTitle\":\"$title_json\",\"sessionId\":\"$uuid_json\"}\n"
    set line2 "{\"type\":\"agent-name\",\"agentName\":\"$title_json\",\"sessionId\":\"$uuid_json\"}\n"
    set fh [open $path a]
    chan configure $fh -encoding utf-8 -translation lf
    puts -nonewline $fh $line1
    puts -nonewline $fh $line2
    close $fh
}

# Clear back to the auto title: an empty customTitle and an agentName carrying
# revert_to (the auto aiTitle, or "" when none). Last agentName wins on rescan.
proc ::questlog::rename::clear_custom {path uuid revert_to} {
    set rev_json  [json_escape $revert_to]
    set uuid_json [json_escape $uuid]
    set line1 "{\"type\":\"custom-title\",\"customTitle\":\"\",\"sessionId\":\"$uuid_json\"}\n"
    set line2 "{\"type\":\"agent-name\",\"agentName\":\"$rev_json\",\"sessionId\":\"$uuid_json\"}\n"
    set fh [open $path a]
    chan configure $fh -encoding utf-8 -translation lf
    puts -nonewline $fh $line1
    puts -nonewline $fh $line2
    close $fh
}

# Minimal JSON string escaping for the fields we write. Titles are kebab slugs in
# normal use; this handles the literal characters that must not appear raw inside
# a JSON string.
proc ::questlog::rename::json_escape {s} {
    return [string map [list \
        "\\" "\\\\" \
        "\"" "\\\"" \
        "\n" "\\n" \
        "\r" "\\r" \
        "\t" "\\t"] $s]
}
