package require Tcl 9
package provide tkdown 1.0

namespace eval ::tkdown {
    namespace export parse_inline segment_tables segment_code_fences \
        segment_blockquotes
}

# tkdown - a pragmatic markdown renderer for a Tk text widget.
#
# tkdown parses a block of markdown text into structured segments and inline
# runs, then paints those onto a text widget with the styling tags the emit
# half owns. It is not a full CommonMark implementation: it covers the block
# and inline forms a chat or transcript body actually carries - fenced code,
# blockquotes, GFM pipe tables, code spans, and asterisk emphasis - and leaves
# the rest as literal text.
#
# The parse half (this file so far) is pure Tcl, needs no Tk, and runs under a
# bare tclsh. The block splitters are layered so each one sees a body the ones
# above it have already peeled:
#
#   segment_code_fences  - {kind text}, kind in {prose code}. Splits on ```
#                          fence lines; a code segment is the verbatim run
#                          between a fence pair, markers and language tag gone.
#   segment_blockquotes  - {kind text}, kind in {normal quote}. A quote is a
#                          maximal run of "> " lines, de-quoted one marker deep.
#   segment_tables       - {kind payload}, kind in {normal table}. A table
#                          payload is {align <per-col> rows <header-then-body>},
#                          the parsed GFM pipe table.
#
# The inline model, one prose run in:
#
#   parse_inline         - an ordered list of {style chunk} pairs; style is one
#                          of plain, code, bold, italic, bolditalic, and chunk
#                          is the display text with the markers stripped.
#                          Adjacent plain runs are coalesced.

# Split a message body into ordered {kind text} segments, where kind is
# "prose" or "code". A code segment is the content between a pair of triple
# backtick fence lines (```), captured verbatim with the fence markers and any
# language tag dropped. An unterminated fence renders its captured run as code.
# A body with no fence is one prose segment. Pure function on the raw body.
proc ::tkdown::segment_code_fences {body} {
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
proc ::tkdown::segment_blockquotes {body} {
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

# Split a prose run into ordered {kind payload} segments, where kind is
# "normal" (payload is raw text) or "table" (payload is a parsed GFM pipe
# table). A table is a header line, a delimiter line of dashes with optional
# alignment colons, and zero or more body rows, in the lenient GitHub form.
# Both the header and the delimiter must carry a "|" so a setext underline
# ("Heading" / "---") or a thematic break is never mistaken for a one-column
# table; single-column tables therefore need the explicit "| h |" / "| - |"
# form, as in cmark-gfm. Callers strip code fences first, so a fenced "|---|"
# never reaches here. Pure; unit-tested.
#
# A table payload is {align <list> rows <list-of-rows>}: align is one of
# left/right/center per column, rows[0] is the header, and every row is
# normalised to the header's column count (short rows padded, long truncated,
# per GFM).
proc ::tkdown::segment_tables {text} {
    set lines [split $text "\n"]
    set n [llength $lines]
    set segs [list]
    set buf  [list]
    set i 0
    while {$i < $n} {
        set tbl [::tkdown::table_at $lines $i]
        if {$tbl eq ""} {
            lappend buf [lindex $lines $i]
            incr i
            continue
        }
        if {[llength $buf]} {
            lappend segs [list normal [join $buf "\n"]]
            set buf [list]
        }
        lassign $tbl payload next
        lappend segs [list table $payload]
        set i $next
    }
    if {[llength $buf]} { lappend segs [list normal [join $buf "\n"]] }
    return $segs
}

# If a GFM table starts at line index $i of $lines, return {payload next},
# where next is the index just past the last consumed table line; else "".
# The header is at $i, the delimiter at $i+1, body rows from $i+2 until a
# blank line or the end of the run.
proc ::tkdown::table_at {lines i} {
    set n [llength $lines]
    if {$i + 1 >= $n} { return "" }
    set hdr_line [lindex $lines $i]
    if {[string trim $hdr_line] eq ""} { return "" }
    if {[string first "|" $hdr_line] < 0} { return "" }
    set delim_line [lindex $lines [expr {$i + 1}]]
    if {[string first "|" $delim_line] < 0} { return "" }
    set header [::tkdown::split_row $hdr_line]
    set ncol [llength $header]
    if {$ncol < 1} { return "" }
    set delim [::tkdown::split_row $delim_line]
    if {[llength $delim] != $ncol} { return "" }
    foreach c $delim {
        if {![regexp {^:?-+:?$} $c]} { return "" }
    }
    set align [list]
    foreach c $delim { lappend align [::tkdown::delim_align $c] }
    set rows [list [::tkdown::norm_row $header $ncol]]
    set j [expr {$i + 2}]
    while {$j < $n} {
        set ln [lindex $lines $j]
        if {[string trim $ln] eq ""} break
        lappend rows [::tkdown::norm_row \
            [::tkdown::split_row $ln] $ncol]
        incr j
    }
    return [list [dict create align $align rows $rows] $j]
}

# The column alignment a delimiter cell encodes: a leading colon means left,
# a trailing colon right, both center, neither the left default.
proc ::tkdown::delim_align {cell} {
    set l [string match {:*} $cell]
    set r [string match {*:} $cell]
    if {$l && $r} { return center }
    if {$r}       { return right }
    return left
}

# Split one table row into trimmed cells. Splits on unescaped "|"; a
# pipe-bounded row drops its empty leading/trailing cell; "\|" becomes a
# literal "|" in the cell (parse_inline's escape map covers only \` \* \\, so
# a surviving "\|" would leak a backslash into the rendered cell).
proc ::tkdown::split_row {line} {
    set line [string trim [string trimright $line "\r"]]
    set cells [list]
    set cur ""
    set len [string length $line]
    for {set k 0} {$k < $len} {incr k} {
        set ch [string index $line $k]
        if {$ch eq "\\" && [string index $line [expr {$k + 1}]] eq "|"} {
            append cur "|"
            incr k
            continue
        }
        if {$ch eq "|"} {
            lappend cells $cur
            set cur ""
            continue
        }
        append cur $ch
    }
    lappend cells $cur
    if {[llength $cells] > 1 && [string trim [lindex $cells 0]] eq "" \
            && [string index $line 0] eq "|"} {
        set cells [lrange $cells 1 end]
    }
    if {[llength $cells] > 1 && [string trim [lindex $cells end]] eq "" \
            && [string index $line end] eq "|"} {
        set cells [lrange $cells 0 end-1]
    }
    set out [list]
    foreach c $cells { lappend out [string trim $c] }
    return $out
}

# Pad a row out to ncol cells, or truncate the overflow, per GFM.
proc ::tkdown::norm_row {cells ncol} {
    while {[llength $cells] < $ncol} { lappend cells "" }
    if {[llength $cells] > $ncol} { set cells [lrange $cells 0 [expr {$ncol - 1}]] }
    return $cells
}

# Parse one prose run into styled inline runs. Returns an ordered list of
# {style chunk} pairs; style is one of plain, code, bold, italic, bolditalic,
# and chunk is the text to display with the markdown markers removed. Adjacent
# plain runs are coalesced. A pure function on a single prose run: callers strip
# fenced code and blockquotes first, so this never sees a ``` fence. Pragmatic,
# not full CommonMark:
#   - code spans (one or two backticks) win over emphasis, so asterisks inside
#     `code` are never styled;
#   - emphasis is asterisks only (*, **, ***): underscores stay literal, so
#     snake_case, __init__ and the like are left alone;
#   - an opener needs a non-space char after it and a closer a non-space char
#     before it (flanking), so "3 * 4" and "* item" stay literal;
#   - \`, \* and \\ escape a literal backtick, asterisk and backslash; every
#     other backslash is kept verbatim (paths and regex carry many).
proc ::tkdown::parse_inline {text} {
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
            set close [::tkdown::inline_close_code $text $j $fence]
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
            lappend runs [list code [::tkdown::inline_unescape $chunk]]
            continue
        }
        foreach run [::tkdown::inline_emphasis $chunk] {
            lassign $run style stext
            lappend runs [list $style [::tkdown::inline_unescape $stext]]
        }
    }
    return $runs
}

# Index of the closing backtick run of exactly `fence` backticks at or after
# `from`, or -1. Runs of a different length are literal content, so skipped.
proc ::tkdown::inline_close_code {s from fence} {
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
proc ::tkdown::inline_emphasis {s} {
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
                set close [::tkdown::inline_close_emph $s $j $runlen]
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
proc ::tkdown::inline_close_emph {s from runlen} {
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
proc ::tkdown::inline_unescape {s} {
    return [string map [list \uE000 "`" \uE001 "*" \uE002 "\\"] $s]
}
