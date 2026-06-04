package require Tcl 9
package require json

namespace eval ::questlog::jsonl {
    namespace export extract_text extract_blocks record_tool_uses \
        is_compact_boundary record_timestamp parse_iso fmt_gap first_cwd \
        segment_blockquotes parse_inline
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
    set t [dict getdef $rec type ""]
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
            return [dict getdef $rec content ""]
        }
        last-prompt {
            return [dict getdef $rec lastPrompt ""]
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
        set bt [dict getdef $blk type ""]
        switch -- $bt {
            text {
                lappend out [dict getdef $blk text ""]
            }
            tool_result {
                # Route through tool_result_text so is_error and image inner
                # blocks are honoured in the reading body too.
                set bc [tool_result_text $blk]
                if {$bc ne ""} { lappend out $bc }
            }
            tool_use {
                set name  [dict getdef $blk name ""]
                set input [dict getdef $blk input [dict create]]
                lappend out [::questlog::match::format_tool_use_full $name $input]
            }
            thinking {
                set tx [dict getdef $blk thinking ""]
                if {$tx ne ""} { lappend out "\[thinking\] $tx" }
            }
            redacted_thinking {
                lappend out "\[redacted thinking\]"
            }
            image {
                lappend out "\[image\]"
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
# tool_use blocks pass through ::questlog::match::format_tool_use_full, the
# uncapped renderer in the match namespace; the search snippet and the viewer
# body agree character-for-character. thinking/image blocks emit their own
# btypes so search regions can be extended to them later.
proc ::questlog::jsonl::extract_blocks {rec} {
    set out [list]
    set t [dict getdef $rec type ""]
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
                    set bt [dict getdef $blk type ""]
                    if {$bt eq "tool_result"} {
                        set bc [tool_result_text $blk]
                        if {$bc ne ""} { lappend out tool_result $bc }
                    } elseif {$bt eq "text"} {
                        lappend out user [dict getdef $blk text ""]
                    } elseif {$bt eq "image"} {
                        lappend out image "\[image\]"
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
                    set bt [dict getdef $blk type ""]
                    if {$bt eq "text"} {
                        lappend out assistant [dict getdef $blk text ""]
                    } elseif {$bt eq "tool_use"} {
                        set name  [dict getdef $blk name ""]
                        set input [dict getdef $blk input [dict create]]
                        lappend out tool_use [::questlog::match::format_tool_use_full $name $input]
                    } elseif {$bt eq "thinking"} {
                        set tx [dict getdef $blk thinking ""]
                        if {$tx ne ""} { lappend out thinking $tx }
                    } elseif {$bt eq "image"} {
                        lappend out image "\[image\]"
                    }
                }
            }
        }
        system - queue-operation {
            set c [dict getdef $rec content ""]
            if {$c ne ""} { lappend out system $c }
        }
        last-prompt {
            set c [dict getdef $rec lastPrompt ""]
            if {$c ne ""} { lappend out user $c }
        }
    }
    return $out
}

proc ::questlog::jsonl::tool_result_text {blk} {
    set is_err [dict getdef $blk is_error 0]
    if {![dict exists $blk content]} {
        return [expr {$is_err ? "ERROR:" : ""}]
    }
    set c [dict get $blk content]
    if {[is_string_content $c]} {
        if {$is_err} {
            return [expr {$c eq "" ? "ERROR:" : "ERROR: $c"}]
        }
        return $c
    }
    set parts [list]
    foreach inner $c {
        set it [dict getdef $inner type ""]
        switch -- $it {
            text            { lappend parts [dict getdef $inner text ""] }
            tool_reference  { lappend parts [dict getdef $inner tool_name ""] }
            image           { lappend parts "\[image\]" }
        }
    }
    set joined [join $parts " "]
    if {$is_err} {
        return [expr {$joined eq "" ? "ERROR:" : "ERROR: $joined"}]
    }
    return $joined
}

# Walk an assistant record's tool_use blocks. Returns one dict per block:
#   {name <tool>  path <file_path|notebook_path|"">  rendered <NAME(args)>
#    text <uncapped argument values, whitespace-collapsed>}
# Path is the file the built-in tool acted on, read off the parsed input
# rather than the rendered string, so it carries the full untruncated path
# and the NotebookEdit notebook_path; the `file` criterion matches it by
# suffix. `text` is the uncapped join of the input values, which the `tool`
# criterion matches a key against by substring - so a key past tool_render_cap
# is still found, and a path inside a Bash redirect (`gen.py > out.json`) is
# caught. `rendered` is the capped display form. Empty for non-assistant records.
proc ::questlog::jsonl::record_tool_uses {rec} {
    set out [list]
    if {[dict getdef $rec type ""] ne "assistant"} { return $out }
    if {![dict exists $rec message]} { return $out }
    set msg [dict get $rec message]
    if {![dict exists $msg content]} { return $out }
    set c [dict get $msg content]
    if {[is_string_content $c]} { return $out }
    foreach blk $c {
        if {[dict getdef $blk type ""] ne "tool_use"} continue
        set name  [dict getdef $blk name ""]
        set input [dict getdef $blk input [dict create]]
        set path ""
        set vals [list]
        if {![catch {dict size $input}]} {
            if {[dict exists $input file_path]} {
                set path [dict get $input file_path]
            } elseif {[dict exists $input notebook_path]} {
                set path [dict get $input notebook_path]
            }
            # Uncapped searchable text: the values only (not the keys, which
            # would match every use of a tool). Tcl's value duck-typing renders
            # a nested object as a string, same as format_tool_use treats it.
            foreach k [dict keys $input] {
                lappend vals [regsub -all {[\s]+} [dict get $input $k] " "]
            }
        }
        lappend out [dict create name $name path $path \
                         rendered [::questlog::match::format_tool_use $name $input] \
                         text [string trim [join $vals " "]]]
    }
    return $out
}

# 1 iff this is a compaction boundary: type=system AND subtype=compact_boundary.
proc ::questlog::jsonl::is_compact_boundary {rec} {
    if {[dict getdef $rec type ""] ne "system"} { return 0 }
    if {[dict getdef $rec subtype ""] ne "compact_boundary"} { return 0 }
    return 1
}

# ISO timestamp string from a record (.timestamp). Empty if absent.
proc ::questlog::jsonl::record_timestamp {rec} {
    return [dict getdef $rec timestamp ""]
}

# Epoch seconds from a Claude ISO timestamp, 0 on an empty or unparseable
# stamp. The session viewer's section dividers and the markdown export both
# segment on the same clock, so this is their one parser.
# Claude stamps millisecond precision (2026-05-24T22:29:21.279Z); clock scan
# has no fractional-second specifier, so the fraction is dropped before the Z
# and the second-resolution remainder is parsed as UTC.
proc ::questlog::jsonl::parse_iso {ts_iso} {
    if {$ts_iso eq ""} { return 0 }
    regsub {\.[0-9]+Z$} $ts_iso {Z} ts_iso
    if {[catch {clock scan $ts_iso -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1} e]} {
        return 0
    }
    return $e
}

# A silence span in minutes rendered for an idle-gap divider ("12 min",
# "2 hr 5 min", "3 day(s)"). Shared by the viewer's divider and the markdown
# export so a gap reads identically in both.
proc ::questlog::jsonl::fmt_gap {minutes} {
    if {$minutes < 60} { return "${minutes} min" }
    if {$minutes < 60*24} {
        set h [expr {$minutes / 60}]
        set m [expr {$minutes % 60}]
        if {$m == 0} { return "${h} hr" }
        return "${h} hr $m min"
    }
    set d [expr {$minutes / (60*24)}]
    return "${d} day(s)"
}

# Last non-empty assistant text body in a session jsonl. Empty string if
# the file holds no parseable assistant record with renderable content. A
# final turn consisting solely of tool_use blocks now returns the rendered
# Tool(args) line(s), since extract_array_text emits those too.
proc ::questlog::jsonl::last_assistant_text {path} {
    set last ""
    if {[catch {open $path r} fh]} { return "" }
    chan configure $fh -encoding utf-8 -profile replace
    while {[chan gets $fh line] >= 0} {
        if {$line eq ""} continue
        set rec [parse_line $line]
        if {$rec eq ""} continue
        if {[dict getdef $rec type ""] ne "assistant"} continue
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
