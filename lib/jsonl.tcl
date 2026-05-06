package require Tcl 9
package require json

namespace eval ::csm::jsonl {
    namespace export extract_text is_compact_boundary record_timestamp
}

# Parse one JSONL line into a Tcl dict. Returns "" on parse failure.
proc ::csm::jsonl::parse_line {line} {
    if {[catch {::json::json2dict $line} d]} { return "" }
    return $d
}

# Extract the canonical text body of a record. Mirrors the jq pipeline
# in the user's cs-grep alias (~/.bash_aliases:724-738).
#
#   user/assistant: .message.content if string,
#                   else for each array element: .text if .type=="text",
#                   .content if .type=="tool_result" and .content is string.
#   queue-operation: .content
#   last-prompt:    .lastPrompt
#   system:         .content (catches "Conversation compacted")
#   anything else:  ""
proc ::csm::jsonl::extract_text {rec} {
    set t [dict_get_or $rec type ""]
    switch -- $t {
        user - assistant {
            if {![dict exists $rec message]} { return "" }
            set msg [dict get $rec message]
            if {![dict exists $msg content]} { return "" }
            set c [dict get $msg content]
            # Heuristic: a JSON array always parses to a list whose first
            # element is itself a dict-shaped value.
            if {[is_string_content $c]} { return $c }
            return [extract_array_text $c]
        }
        queue-operation - system {
            return [dict_get_or $rec content ""]
        }
        last-prompt {
            return [dict_get_or $rec lastPrompt ""]
        }
        default { return "" }
    }
}

# .message.content as parsed by tcllib's json package: a JSON string is a
# Tcl string; a JSON array is a Tcl list of dict-shaped strings. Tell them
# apart by the test "the value, treated as a list, has at least one element
# that is a valid dict with a 'type' key".
proc ::csm::jsonl::is_string_content {c} {
    if {$c eq ""} { return 1 }
    # If it is not a well-formed list, it is a string.
    if {[catch {llength $c} n]} { return 1 }
    if {$n == 0} { return 1 }
    # A list of content blocks: every element is a dict with key "type".
    foreach el $c {
        if {[catch {dict exists $el type} ok] || !$ok} { return 1 }
    }
    return 0
}

proc ::csm::jsonl::extract_array_text {blocks} {
    set out [list]
    foreach blk $blocks {
        set bt [dict_get_or $blk type ""]
        switch -- $bt {
            text {
                lappend out [dict_get_or $blk text ""]
            }
            tool_result {
                set bc [dict_get_or $blk content ""]
                if {[is_string_content $bc]} { lappend out $bc }
            }
        }
    }
    return [join $out "\n"]
}

# 1 iff this is a compaction boundary: type=system AND subtype=compact_boundary.
proc ::csm::jsonl::is_compact_boundary {rec} {
    if {[dict_get_or $rec type ""] ne "system"} { return 0 }
    if {[dict_get_or $rec subtype ""] ne "compact_boundary"} { return 0 }
    return 1
}

# ISO timestamp string from a record (.timestamp). Empty if absent.
proc ::csm::jsonl::record_timestamp {rec} {
    return [dict_get_or $rec timestamp ""]
}

# Last non-empty assistant text body in a session jsonl. Empty string if
# the file holds no parseable assistant record with text content (e.g. the
# final assistant turn was all tool_use blocks).
proc ::csm::jsonl::last_assistant_text {path} {
    set last ""
    if {[catch {open $path r} fh]} { return "" }
    while {[chan gets $fh line] >= 0} {
        if {$line eq ""} continue
        set rec [parse_line $line]
        if {$rec eq ""} continue
        if {[dict_get_or $rec type ""] ne "assistant"} continue
        set body [extract_text $rec]
        if {$body ne ""} { set last $body }
    }
    close $fh
    return $last
}

# dict get with default - Tcl 9's [dict getdef] would do this but is verbose.
proc ::csm::jsonl::dict_get_or {d k default} {
    if {[dict exists $d $k]} { return [dict get $d $k] }
    return $default
}
