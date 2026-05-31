package require Tcl 9
package require json

namespace eval ::questlog::jsonl {
    namespace export extract_text extract_blocks record_tool_uses \
        is_compact_boundary record_timestamp first_cwd segment_blockquotes \
        parse_inline
}

# Parse one JSONL line into a Tcl dict. Returns "" on parse failure.
proc ::questlog::jsonl::parse_line {line} {
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
proc ::questlog::jsonl::extract_text {rec} {
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
proc ::questlog::jsonl::is_string_content {c} {
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

proc ::questlog::jsonl::extract_array_text {blocks} {
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

# Split a message body into ordered {kind text} segments, where kind is
# "prose" or "code". A code segment is the content between a pair of triple
# backtick fence lines (```), captured verbatim with the fence markers and any
# language tag dropped. An unterminated fence renders its captured run as code.
# A body with no fence is one prose segment. Pure function on the raw body.
proc ::questlog::jsonl::segment_code_fences {body} {
    set segs [list]
    set buf  [list]
    set incode 0
    foreach line [split $body "\n"] {
        if {[regexp {^\s*```} $line]} {
            if {$incode} {
                lappend segs [list code [join $buf "\n"]]
            } elseif {[llength $buf]} {
                lappend segs [list prose [join $buf "\n"]]
            }
            set buf [list]
            set incode [expr {!$incode}]
            continue
        }
        lappend buf $line
    }
    if {[llength $buf]} {
        lappend segs [list [expr {$incode ? "code" : "prose"}] [join $buf "\n"]]
    }
    return $segs
}

# Split a message body into ordered {kind text} segments, where kind is
# "normal" or "quote". A quote segment is a maximal run of markdown
# blockquote lines (each starting with ">"); its text is de-quoted, one
# leading "> " or ">" stripped per line. A bare blank line (no ">") ends a
# quote run, the strict markdown split. Pure function on the raw body.
proc ::questlog::jsonl::segment_blockquotes {body} {
    set segs [list]
    set buf  [list]   ;# accumulating normal lines
    set q    [list]   ;# accumulating de-quoted lines
    set mode normal
    foreach line [split $body "\n"] {
        if {[regexp {^>( ?)(.*)$} $line -> _sp rest]} {
            if {$mode eq "normal" && [llength $buf]} {
                lappend segs [list normal [join $buf "\n"]]
                set buf [list]
            }
            set mode quote
            lappend q $rest
        } else {
            if {$mode eq "quote" && [llength $q]} {
                lappend segs [list quote [join $q "\n"]]
                set q [list]
            }
            set mode normal
            lappend buf $line
        }
    }
    if {[llength $buf]} { lappend segs [list normal [join $buf "\n"]] }
    if {[llength $q]}   { lappend segs [list quote  [join $q "\n"]] }
    return $segs
}

# Parse one prose run into styled inline runs for the reading view. Returns an
# ordered list of {style chunk} pairs; style is one of plain, code, bold,
# italic, bolditalic, and chunk is the text to display with the markdown
# markers removed. Adjacent plain runs are coalesced. A pure function on a
# single prose run: callers strip fenced code and blockquotes first, so this
# never sees a ``` fence. Pragmatic, not full CommonMark:
#   - code spans (one or two backticks) win over emphasis, so asterisks inside
#     `code` are never styled;
#   - emphasis is asterisks only (*, **, ***): underscores stay literal, so
#     snake_case, __init__ and the like are left alone;
#   - an opener needs a non-space char after it and a closer a non-space char
#     before it (flanking), so "3 * 4" and "* item" stay literal;
#   - \`, \* and \\ escape a literal backtick, asterisk and backslash; every
#     other backslash is kept verbatim (paths and regex carry many).
proc ::questlog::jsonl::parse_inline {text} {
    # Escapes go to private-use sentinels so the marker scans never meet them;
    # any stray sentinel in the raw input is dropped first.
    set bt \uE000 ;# escaped backtick  -> literal `
    set st \uE001 ;# escaped asterisk  -> literal *
    set bs \uE002 ;# escaped backslash -> literal \
    set text [string map [list $bt {} $st {} $bs {}] $text]
    set text [string map [list {\`} $bt {\*} $st {\\} $bs] $text]

    # Pass A: peel off code spans; the gaps between them are prose.
    set segs [list]
    set buf ""
    set i 0
    set n [string length $text]
    while {$i < $n} {
        if {[string index $text $i] ne "`"} {
            append buf [string index $text $i]
            incr i
            continue
        }
        set j $i
        while {$j < $n && [string index $text $j] eq "`"} { incr j }
        set fence [expr {$j - $i}]
        set close -1
        if {$fence <= 2} {
            set close [::questlog::jsonl::inline_close_code $text $j $fence]
        }
        if {$close < 0} {
            append buf [string range $text $i [expr {$j - 1}]]
            set i $j
            continue
        }
        if {$buf ne ""} { lappend segs prose $buf; set buf "" }
        set content [string range $text $j [expr {$close - 1}]]
        if {[string length $content] >= 2 && [string index $content 0] eq " " \
                && [string index $content end] eq " " \
                && [string trim $content] ne ""} {
            set content [string range $content 1 end-1]
        }
        lappend segs code $content
        set i [expr {$close + $fence}]
    }
    if {$buf ne ""} { lappend segs prose $buf }

    # Pass B: emphasis within each prose gap; unescape every emitted chunk.
    set runs [list]
    foreach {kind chunk} $segs {
        if {$kind eq "code"} {
            lappend runs [list code [::questlog::jsonl::inline_unescape $chunk]]
            continue
        }
        foreach run [::questlog::jsonl::inline_emphasis $chunk] {
            lassign $run style stext
            lappend runs [list $style [::questlog::jsonl::inline_unescape $stext]]
        }
    }
    return $runs
}

# Index of the closing backtick run of exactly `fence` backticks at or after
# `from`, or -1. Runs of a different length are literal content, so skipped.
proc ::questlog::jsonl::inline_close_code {s from fence} {
    set n [string length $s]
    set i $from
    while {$i < $n} {
        if {[string index $s $i] ne "`"} { incr i; continue }
        set k $i
        while {$k < $n && [string index $s $k] eq "`"} { incr k }
        if {($k - $i) == $fence} { return $i }
        set i $k
    }
    return -1
}

# Split one prose run into {style chunk} runs on asterisk emphasis. plain runs
# are coalesced; chunks still carry escape sentinels (the caller unescapes).
proc ::questlog::jsonl::inline_emphasis {s} {
    set runs [list]
    set plain ""
    set i 0
    set n [string length $s]
    while {$i < $n} {
        if {[string index $s $i] ne "*"} {
            append plain [string index $s $i]
            incr i
            continue
        }
        set j $i
        while {$j < $n && [string index $s $j] eq "*"} { incr j }
        set runlen [expr {$j - $i}]
        set style ""
        switch -- $runlen {
            1 { set style italic }
            2 { set style bold }
            3 { set style bolditalic }
        }
        set close -1
        if {$style ne ""} {
            set after [string index $s $j]
            if {$after ne "" && ![string is space $after]} {
                set close [::questlog::jsonl::inline_close_emph $s $j $runlen]
            }
        }
        if {$close < 0} {
            append plain [string range $s $i [expr {$j - 1}]]
            set i $j
            continue
        }
        if {$plain ne ""} { lappend runs [list plain $plain]; set plain "" }
        lappend runs [list $style [string range $s $j [expr {$close - 1}]]]
        set i [expr {$close + $runlen}]
    }
    if {$plain ne ""} { lappend runs [list plain $plain] }
    return $runs
}

# Index of a closing asterisk run of exactly `runlen` whose preceding char is
# non-space (flanking), at or after `from`; -1 if none.
proc ::questlog::jsonl::inline_close_emph {s from runlen} {
    set n [string length $s]
    set i $from
    while {$i < $n} {
        if {[string index $s $i] ne "*"} { incr i; continue }
        set k $i
        while {$k < $n && [string index $s $k] eq "*"} { incr k }
        if {($k - $i) == $runlen} {
            set before [string index $s [expr {$i - 1}]]
            if {$before ne "" && ![string is space $before]} { return $i }
        }
        set i $k
    }
    return -1
}

# Restore the escape sentinels to their literal characters.
proc ::questlog::jsonl::inline_unescape {s} {
    return [string map [list \uE000 "`" \uE001 "*" \uE002 "\\"] $s]
}

# Walk a record's content blocks and emit one {btype content} pair per
# block worth showing. Pure function on a parsed record dict.
#
#   user (string content):                {user $string}
#   user (array of tool_result blocks):   {tool_result <text>}* (one per block)
#   user (array of text blocks):          {user <text>}*
#   assistant (array of text blocks):     {assistant <text>}*
#   assistant (array of tool_use blocks): {tool_use <NAME(args)>}*
#   system / queue-operation (.content):  {system $content}
#   last-prompt:                          {user $lastPrompt}
#   anything else (attachment, file-history-snapshot, etc.): empty list.
#
# tool_use blocks pass through ::questlog::search::format_tool_use, which lives
# in the search namespace because the rendered form is a search-pane
# concern, not a JSONL concern.
proc ::questlog::jsonl::extract_blocks {rec} {
    set out [list]
    set t [dict_get_or $rec type ""]
    switch -- $t {
        user {
            if {![dict exists $rec message]} { return $out }
            set msg [dict get $rec message]
            if {![dict exists $msg content]} { return $out }
            set c [dict get $msg content]
            if {[is_string_content $c]} {
                lappend out user $c
            } else {
                foreach blk $c {
                    set bt [dict_get_or $blk type ""]
                    if {$bt eq "tool_result"} {
                        set bc [tool_result_text $blk]
                        if {$bc ne ""} { lappend out tool_result $bc }
                    } elseif {$bt eq "text"} {
                        lappend out user [dict_get_or $blk text ""]
                    }
                }
            }
        }
        assistant {
            if {![dict exists $rec message]} { return $out }
            set msg [dict get $rec message]
            if {![dict exists $msg content]} { return $out }
            set c [dict get $msg content]
            if {[is_string_content $c]} {
                lappend out assistant $c
            } else {
                foreach blk $c {
                    set bt [dict_get_or $blk type ""]
                    if {$bt eq "text"} {
                        lappend out assistant [dict_get_or $blk text ""]
                    } elseif {$bt eq "tool_use"} {
                        set name  [dict_get_or $blk name ""]
                        set input [dict_get_or $blk input [dict create]]
                        lappend out tool_use [::questlog::search::format_tool_use $name $input]
                    }
                }
            }
        }
        system - queue-operation {
            set c [dict_get_or $rec content ""]
            if {$c ne ""} { lappend out system $c }
        }
        last-prompt {
            set c [dict_get_or $rec lastPrompt ""]
            if {$c ne ""} { lappend out user $c }
        }
    }
    return $out
}

proc ::questlog::jsonl::tool_result_text {blk} {
    if {![dict exists $blk content]} { return "" }
    set c [dict get $blk content]
    if {[is_string_content $c]} { return $c }
    set parts [list]
    foreach inner $c {
        set it [dict_get_or $inner type ""]
        switch -- $it {
            text            { lappend parts [dict_get_or $inner text ""] }
            tool_reference  { lappend parts [dict_get_or $inner tool_name ""] }
        }
    }
    return [join $parts " "]
}

# Walk an assistant record's tool_use blocks. Returns one dict per block:
#   {name <tool>  path <file_path|notebook_path|"">  rendered <NAME(args)>}
# Path is the file the built-in tool acted on, read off the parsed input
# rather than the rendered string, so it carries the full untruncated path
# and the NotebookEdit notebook_path. Used by Search to satisfy
# read/write/edit criteria structurally. Empty for non-assistant records.
proc ::questlog::jsonl::record_tool_uses {rec} {
    set out [list]
    if {[dict_get_or $rec type ""] ne "assistant"} { return $out }
    if {![dict exists $rec message]} { return $out }
    set msg [dict get $rec message]
    if {![dict exists $msg content]} { return $out }
    set c [dict get $msg content]
    if {[is_string_content $c]} { return $out }
    foreach blk $c {
        if {[dict_get_or $blk type ""] ne "tool_use"} continue
        set name  [dict_get_or $blk name ""]
        set input [dict_get_or $blk input [dict create]]
        set path ""
        if {![catch {dict size $input}]} {
            if {[dict exists $input file_path]} {
                set path [dict get $input file_path]
            } elseif {[dict exists $input notebook_path]} {
                set path [dict get $input notebook_path]
            }
        }
        lappend out [dict create name $name path $path \
                         rendered [::questlog::search::format_tool_use $name $input]]
    }
    return $out
}

# 1 iff this is a compaction boundary: type=system AND subtype=compact_boundary.
proc ::questlog::jsonl::is_compact_boundary {rec} {
    if {[dict_get_or $rec type ""] ne "system"} { return 0 }
    if {[dict_get_or $rec subtype ""] ne "compact_boundary"} { return 0 }
    return 1
}

# ISO timestamp string from a record (.timestamp). Empty if absent.
proc ::questlog::jsonl::record_timestamp {rec} {
    return [dict_get_or $rec timestamp ""]
}

# Last non-empty assistant text body in a session jsonl. Empty string if
# the file holds no parseable assistant record with text content (e.g. the
# final assistant turn was all tool_use blocks).
proc ::questlog::jsonl::last_assistant_text {path} {
    set last ""
    if {[catch {open $path r} fh]} { return "" }
    chan configure $fh -encoding utf-8 -profile replace
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

# First "cwd" value recorded in a session jsonl. Empty string if the
# file cannot be opened or holds no record with a cwd. A line-level
# regex, not a full parse: cwd appears on most record types and the
# first hit is enough.
proc ::questlog::jsonl::first_cwd {path} {
    if {[catch {open $path r} fh]} { return "" }
    chan configure $fh -encoding utf-8 -profile replace
    set cwd ""
    while {[chan gets $fh line] >= 0} {
        if {$line eq ""} continue
        if {[regexp {"cwd":"([^"]+)"} $line -> m]} {
            set cwd $m
            break
        }
    }
    close $fh
    return $cwd
}

# dict get with default - Tcl 9's [dict getdef] would do this but is verbose.
proc ::questlog::jsonl::dict_get_or {d k default} {
    if {[dict exists $d $k]} { return [dict get $d $k] }
    return $default
}
