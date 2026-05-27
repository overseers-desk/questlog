package require Tcl 9

# ::questlog::title - persist a session title by appending Claude Code's native
# rename records to the jsonl. Two lines:
#   {"type":"custom-title","customTitle":<title>,"sessionId":<uuid>}
#   {"type":"agent-name","agentName":<title>,"sessionId":<uuid>}
#
# A custom title overrides the auto aiTitle in scan_one's slug priority
# (agentName > aiTitle). To clear the custom title back to the auto, the
# caller passes the original aiTitle (or "" if none was found) as
# revert_to: an empty customTitle is written, and agentName is written
# with revert_to, so the next scan picks up revert_to as the slug.
#
# Two short JSON lines are well under PIPE_BUF, so each append-mode write
# is atomic against concurrent appends from a live claude process. The
# rename UI still disables this action while the session is running, so
# this safety net never has to carry weight.

namespace eval ::questlog::title {}

proc ::questlog::title::set_custom {path uuid title} {
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

# Clear back to the auto title. Writes an empty customTitle and an
# agentName carrying the supplied revert_to (the original aiTitle, or ""
# when none was ever generated). Last agentName wins on the next scan.
proc ::questlog::title::clear_custom {path uuid revert_to} {
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

# Minimal JSON string escaping for the fields we write. Titles are kebab
# slugs in normal use; this handles the literal characters that must not
# appear raw inside a JSON string.
proc ::questlog::title::json_escape {s} {
    return [string map [list \
        "\\" "\\\\" \
        "\"" "\\\"" \
        "\n" "\\n" \
        "\r" "\\r" \
        "\t" "\\t"] $s]
}
