package require Tcl 9
package provide tkdown 2.0

namespace eval ::tkdown {
    namespace export parse_inline segment_code_fences segment_blockquotes \
        segment_headings segment_rules segment_images segment_tables \
        segment_lists table_to_markdown table_colwidths ensure_fonts tags \
        runs prose body emit_prose emit_code emit_quote emit_table \
        emit_image emit_rule refit forget unregister table_scan \
        table_spotlight link_at link_scan
    # Emit state, one entry per registered widget: widget path -> {fonts
    # margin copystyle quotetags image_cmd on_block tables nextid spot fittok
    # links nextlink}, tables being id -> the table's entry (see the grid
    # section), spot the lit table's id, fittok the pending re-fit's after
    # token and links td-link<N> tag -> url.
    variable widgets [dict create]
    # table_colwidths' search state, keyed by a per-call id; see colwidths_memo.
    variable colmemo
    # Numbers body's per-block marks.
    variable blockseq 0
}

# tkdown - a pragmatic markdown renderer for a Tk text widget.
#
# tkdown parses a block of markdown text into structured segments and inline
# runs, then paints those onto a text widget with the styling tags the emit
# half owns. It is not a full CommonMark implementation: it covers the block
# and inline forms a chat, transcript or notes file actually carries -
# fenced code, blockquotes, GFM pipe tables, ATX and setext headings,
# thematic breaks, image lines, nested lists, links, code spans, and
# asterisk emphasis - and leaves the rest as literal text.
#
# The parse half (the segment_* splitters and parse_inline) is pure Tcl,
# needs no Tk, and runs under a bare tclsh. The splitters are layered: each
# sees a body the ones above it have already peeled, in the order body
# walks them. The prose emitter splits lists and lifts headings itself;
# segment_headings is for a host that wants a document's headings as
# segments of its own. The emit half paints onto a widget registered with
# `tags`, and every td-* tag it configures is font-only or geometry-only.
# Colour always comes from the base tags the host stacks underneath or from
# td-* tags the host inks, so the module owns faces and layout and the host
# owns the ink.

# Split a body into ordered {kind text} segments, where kind is
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

# Split a body into ordered {kind text} segments, where kind is
# "normal" or "quote". A quote segment is a maximal run of markdown
# blockquote lines (each starting with ">"); its text is de-quoted, one
# leading "> " or ">" stripped per line. A bare blank line (no ">") ends a
# quote run, the strict markdown split.
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

# A fence line, the same test segment_code_fences splits on: optional
# leading whitespace, then three backticks.
proc ::tkdown::fence_line {line} {
    return [regexp {^\s*```} $line]
}

# A thematic-break line: three or more of one of "-", "*" or "_", spaces or
# tabs allowed between them, nothing else on the line, indented at most three
# spaces.
proc ::tkdown::rule_line {line} {
    if {![regexp {^ {0,3}[-*_]} $line]} { return 0 }
    set bare [string map [list " " "" "\t" ""] $line]
    return [regexp {^(-{3,}|\*{3,}|_{3,})$} $bare]
}

# If line is an ATX heading, return {level title}, else "". A heading is one
# to six "#" at the start of the line and then a space or tab; the title is
# the rest with any closing "#" run (one standing alone or after whitespace,
# the CommonMark rule) and the surrounding whitespace stripped. "#5" and
# "#######" are not headings.
proc ::tkdown::atx_line {line} {
    if {![regexp {^(#{1,6})[ \t]+(.*)$} $line -> marks title]} { return "" }
    regsub {(^|[ \t])#+[ \t]*$} $title {} title
    return [list [string length $marks] [string trim $title]]
}

# If lines[i+1] is a setext underline for lines[i], return its level (1 for
# "===", 2 for "---"), else 0. The underline is three or more of one of the
# two characters, contiguous, indented at most three spaces. The line above
# must be non-blank and plain text: a "|" in it (a table row, so the line
# under it is a delimiter row or a rule) and a line that is a quote, fence,
# rule, ATX heading, list item or itself underline-shaped all rule it out.
# Callers keep fenced lines away from here.
proc ::tkdown::setext_level {lines i} {
    if {$i < 0 || $i + 1 >= [llength $lines]} { return 0 }
    set above [lindex $lines $i]
    set under [lindex $lines [expr {$i + 1}]]
    set shape {^ {0,3}(={3,}|-{3,})[ \t]*$}
    if {![regexp $shape $under -> ul]} { return 0 }
    if {[string trim $above] eq ""} { return 0 }
    if {[string first "|" $above] >= 0} { return 0 }
    if {[string match ">*" $above] || [::tkdown::fence_line $above]
            || [::tkdown::rule_line $above] || [regexp $shape $above]
            || [::tkdown::atx_line $above] ne ""
            || [::tkdown::list_marker $above] ne ""} {
        return 0
    }
    return [expr {[string index $ul 0] eq "=" ? 1 : 2}]
}

# Split a body into ordered {kind payload} segments, where kind is "heading"
# (payload {level title}) or "normal" (payload raw text). A heading is an ATX
# line (atx_line) or a setext pair, a line of text over its underline
# (setext_level); only the one line directly above an underline becomes the
# title. The title keeps its inline markdown for the inline pass. Lines
# inside a ``` fence are never headings, and the fence lines themselves stay
# in the normal text verbatim, so segment_code_fences still splits it.
proc ::tkdown::segment_headings {body} {
    set lines [split $body "\n"]
    set n [llength $lines]
    set segs [list]
    set buf  [list]
    set incode 0
    for {set i 0} {$i < $n} {incr i} {
        set line [lindex $lines $i]
        set head ""
        if {[::tkdown::fence_line $line]} {
            set incode [expr {!$incode}]
        } elseif {!$incode} {
            set head [::tkdown::atx_line $line]
            if {$head eq ""} {
                set lvl [::tkdown::setext_level $lines $i]
                if {$lvl} {
                    set head [list $lvl [string trim $line]]
                    incr i
                }
            }
        }
        if {$head eq ""} {
            lappend buf $line
            continue
        }
        if {[llength $buf]} {
            lappend segs [list normal [join $buf "\n"]]
            set buf [list]
        }
        lappend segs [list heading $head]
    }
    if {[llength $buf]} { lappend segs [list normal [join $buf "\n"]] }
    return $segs
}

# Split a run into ordered {kind payload} segments, where kind is "rule"
# (payload empty) for a thematic-break line (rule_line) or "normal" (payload
# raw text). A "---" that underlines the line above it (setext_level) is a
# heading's, not a rule, and a fenced line is never a rule.
proc ::tkdown::segment_rules {text} {
    set lines [split $text "\n"]
    set n [llength $lines]
    set segs [list]
    set buf  [list]
    set incode 0
    for {set i 0} {$i < $n} {incr i} {
        set line [lindex $lines $i]
        if {[::tkdown::fence_line $line]} {
            set incode [expr {!$incode}]
        } elseif {!$incode && [::tkdown::rule_line $line]
                && ![::tkdown::setext_level $lines [expr {$i - 1}]]} {
            if {[llength $buf]} {
                lappend segs [list normal [join $buf "\n"]]
                set buf [list]
            }
            lappend segs [list rule ""]
            continue
        }
        lappend buf $line
    }
    if {[llength $buf]} { lappend segs [list normal [join $buf "\n"]] }
    return $segs
}

# Split a run into ordered {kind payload} segments, where kind is "image"
# (payload {alt path}) for a line holding nothing but one ![alt](path), an
# optional quoted title after the path, or "normal" (payload raw text). An
# image sharing its line with other text is left for the inline pass, and a
# fenced line is never an image.
proc ::tkdown::segment_images {text} {
    set segs [list]
    set buf  [list]
    set incode 0
    foreach line [split $text "\n"] {
        if {[::tkdown::fence_line $line]} {
            set incode [expr {!$incode}]
        } elseif {!$incode && [regexp \
                {^\s*!\[([^\]]*)\]\(\s*([^\s()]+)(?:\s+"[^"]*")?\s*\)\s*$} \
                $line -> alt path]} {
            if {[llength $buf]} {
                lappend segs [list normal [join $buf "\n"]]
                set buf [list]
            }
            lappend segs [list image [list $alt $path]]
            continue
        }
        lappend buf $line
    }
    if {[llength $buf]} { lappend segs [list normal [join $buf "\n"]] }
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
# never reaches here.
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

proc ::tkdown::norm_row {cells ncol} {
    while {[llength $cells] < $ncol} { lappend cells "" }
    if {[llength $cells] > $ncol} { set cells [lrange $cells 0 [expr {$ncol - 1}]] }
    return $cells
}

# A table payload ({align rows}, the segment_tables shape) back to GFM text.
# Cells re-escape the "|" that split_row decoded, so the text round-trips
# through segment_tables to the same payload. The source's padding and its
# left-colon spelling of a left column are not in the payload, so the
# delimiter row is regenerated canonically.
proc ::tkdown::table_to_markdown {payload} {
    set lines [list]
    set first 1
    foreach row [dict get $payload rows] {
        set cells [list]
        foreach cell $row { lappend cells [string map {"|" "\\|"} $cell] }
        lappend lines "| [join $cells { | }] |"
        if {$first} {
            set d [list]
            foreach a [dict get $payload align] {
                switch -- $a {
                    right   { lappend d "---:" }
                    center  { lappend d ":---:" }
                    default { lappend d "---" }
                }
            }
            lappend lines "| [join $d { | }] |"
            set first 0
        }
    }
    return [join $lines "\n"]
}

# Column widths in pixels for a table whose cells word-wrap within avail
# pixels. rows is a list of rows, a row a list of cells, a cell a list of
# token widths (its words measured in the font they paint in); em is the
# width of one em (or "0") and space of one space, both in the body font.
# Pure: the caller measures, so it runs without Tk.
#
# A column's max-content is its widest cell laid on one line. When the
# max-contents fit, they are the answer. Otherwise each column has a floor,
# its widest token but no more than eight ems or an equal share of avail,
# below which a token character-wraps; when the floors alone fill avail,
# they are the answer. Between the two the widths are searched rather than
# shrunk. The cost of an allocation is the table's line count (each row as
# tall as its tallest cell under greedy word wrap) plus one per
# character-wrap, since a broken word reads worse than a wrapped one. Three
# seeds - CSS auto layout, a proportional shrink of the max-contents, and a
# greedy climb from the floors - are each refined by moving pixels between
# column pairs while the cost falls, and the cheapest result is returned.
# The proportional shrink being a seed, the result never costs more than it.
proc ::tkdown::table_colwidths {rows avail em space} {
    set ncol 0
    foreach row $rows {
        if {[llength $row] > $ncol} { set ncol [llength $row] }
    }
    if {$ncol == 0} { return {} }
    set toks [lrepeat $ncol 0]
    set maxs [lrepeat $ncol 0]
    foreach row $rows {
        for {set j 0} {$j < $ncol} {incr j} {
            set cell [lindex $row $j]
            set full 0
            set widest 0
            foreach t $cell {
                if {$t > $widest} { set widest $t }
                incr full $t
            }
            if {[llength $cell] > 1} {
                incr full [expr {([llength $cell] - 1) * $space}]
            }
            if {$widest > [lindex $toks $j]} { lset toks $j $widest }
            if {$full > [lindex $maxs $j]} { lset maxs $j $full }
        }
    }
    if {[tcl::mathop::+ {*}$maxs] <= $avail} { return $maxs }
    set cap [expr {min(8 * $em, $avail / $ncol)}]
    set mins [list]
    foreach t $toks { lappend mins [expr {min($t, $cap)}] }
    if {[tcl::mathop::+ {*}$mins] >= $avail} { return $mins }

    set memo [::tkdown::colwidths_memo $rows $ncol $space]
    set best {}
    set bestc -1
    foreach seed [::tkdown::colwidths_seeds $memo $mins $maxs $avail] {
        set w [::tkdown::colwidths_search $memo $seed $mins $maxs]
        set c [::tkdown::colwidths_cost $memo $w]
        if {$bestc < 0 || $c < $bestc} {
            set best $w
            set bestc $c
        }
    }
    ::tkdown::colwidths_forget $memo
    return $best
}

# The search's scratch state: the rows split into columns, and a cache of
# each column's per-row line counts by width. The search asks for the same
# column at the same width many times over, and a table of a few hundred
# words would otherwise rewrap every cell for every trial.
proc ::tkdown::colwidths_memo {rows ncol space} {
    variable colmemo
    set id [incr colmemo(next)]
    set cols [list]
    for {set j 0} {$j < $ncol} {incr j} {
        set col [list]
        foreach row $rows { lappend col [lindex $row $j] }
        lappend cols $col
    }
    set colmemo($id,cols) $cols
    set colmemo($id,space) $space
    return $id
}

proc ::tkdown::colwidths_forget {memo} {
    variable colmemo
    array unset colmemo $memo,*
}

# Column j's line count per row at width w, character-wraps penalised.
proc ::tkdown::colwidths_lines {memo j w} {
    variable colmemo
    set key $memo,$j,$w
    if {![info exists colmemo($key)]} {
        set space $colmemo($memo,space)
        set out [list]
        foreach cell [lindex $colmemo($memo,cols) $j] {
            lappend out [::tkdown::cell_lines $cell $w $space]
        }
        set colmemo($key) $out
    }
    return $colmemo($key)
}

# Lines of one cell at width w under greedy word wrap. A token wider than w
# starts its own line and breaks every w pixels; each break costs one more
# on top of the line it adds when penalise is set.
proc ::tkdown::cell_lines {cell w space {penalise 1}} {
    set lines 1
    set cur -1
    foreach t $cell {
        if {$t > $w && $w > 0} {
            if {$cur >= 0} { incr lines }
            set wraps [expr {($t - 1) / $w}]
            incr lines $wraps
            if {$penalise} { incr lines $wraps }
            set cur [expr {$t - $wraps * $w}]
        } elseif {$cur < 0} {
            set cur $t
        } elseif {$cur + $space + $t <= $w} {
            set cur [expr {$cur + $space + $t}]
        } else {
            incr lines
            set cur $t
        }
    }
    return $lines
}

# The cost of an allocation: each row's tallest cell, summed.
proc ::tkdown::colwidths_cost {memo widths} {
    set tallest {}
    set j 0
    foreach cw $widths {
        set col [::tkdown::colwidths_lines $memo $j $cw]
        if {$j == 0} {
            set tallest $col
        } else {
            set tallest [lmap a $tallest b $col {expr {max($a, $b)}}]
        }
        incr j
    }
    return [tcl::mathop::+ 0 {*}$tallest]
}

# The starting allocations: CSS auto layout (the excess over the floors
# shared in proportion to each column's max-content less its floor), the
# max-contents scaled to avail, and a greedy climb from the floors.
proc ::tkdown::colwidths_seeds {memo mins maxs avail} {
    set summin [tcl::mathop::+ {*}$mins]
    set summax [tcl::mathop::+ {*}$maxs]
    set spare [expr {$avail - $summin}]
    set room [expr {$summax - $summin}]
    set css [lmap lo $mins hi $maxs {
        expr {$lo + ($hi - $lo) * $spare / $room}
    }]
    set prop [lmap hi $maxs { expr {$hi * $avail / $summax} }]
    return [list \
        [::tkdown::colwidths_fill $css $mins $maxs $avail] \
        [::tkdown::colwidths_fill $prop $mins $maxs $avail] \
        [::tkdown::colwidths_climb $memo $mins $maxs $avail]]
}

# Pin an allocation into [mins, maxs] summing to avail: clamp each column,
# then hand the difference to the columns with room, first to last.
proc ::tkdown::colwidths_fill {widths mins maxs avail} {
    set out [lmap cw $widths lo $mins hi $maxs {
        expr {min(max($cw, $lo), $hi)}
    }]
    set left [expr {$avail - [tcl::mathop::+ {*}$out]}]
    for {set j 0} {$j < [llength $out] && $left != 0} {incr j} {
        if {$left > 0} {
            set add [expr {min([lindex $maxs $j] - [lindex $out $j], $left)}]
        } else {
            set add [expr {max([lindex $mins $j] - [lindex $out $j], $left)}]
        }
        lset out $j [expr {[lindex $out $j] + $add}]
        set left [expr {$left - $add}]
    }
    return $out
}

# From the floors, widen the column whose next breakpoint saves the most
# cost per pixel, while the pixels last.
proc ::tkdown::colwidths_climb {memo mins maxs avail} {
    set w $mins
    set spare [expr {$avail - [tcl::mathop::+ {*}$mins]}]
    set cost [::tkdown::colwidths_cost $memo $w]
    while {$spare > 0} {
        set bestj -1
        set bestrate 0
        set j 0
        foreach cw $w {
            set nb [::tkdown::colwidths_next $memo $j $cw [lindex $maxs $j]]
            if {$nb >= 0 && $nb - $cw <= $spare} {
                set trial $w
                lset trial $j $nb
                set c [::tkdown::colwidths_cost $memo $trial]
                set rate [expr {double($cost - $c) / ($nb - $cw)}]
                if {$rate > $bestrate} {
                    set bestj $j
                    set bestrate $rate
                    set bestw $nb
                    set bestc $c
                }
            }
            incr j
        }
        if {$bestj < 0} break
        set spare [expr {$spare - ($bestw - [lindex $w $bestj])}]
        lset w $bestj $bestw
        set cost $bestc
    }
    return [::tkdown::colwidths_fill $w $mins $maxs $avail]
}

# Local search over pair moves: one column up to one of its next three
# breakpoints, the pixels taken from another column above its floor, a move
# kept when the cost falls, until no move lowers it.
proc ::tkdown::colwidths_search {memo w mins maxs} {
    set ncol [llength $w]
    set cost [::tkdown::colwidths_cost $memo $w]
    set improved 1
    while {$improved} {
        set improved 0
        for {set j 0} {$j < $ncol && !$improved} {incr j} {
            set from [lindex $w $j]
            for {set k 0} {$k < 3 && !$improved} {incr k} {
                set nb [::tkdown::colwidths_next $memo $j $from [lindex $maxs $j]]
                if {$nb < 0} break
                set from $nb
                set step [expr {$nb - [lindex $w $j]}]
                for {set i 0} {$i < $ncol} {incr i} {
                    if {$i == $j} continue
                    if {[lindex $w $i] - $step < [lindex $mins $i]} continue
                    set trial $w
                    lset trial $j $nb
                    lset trial $i [expr {[lindex $w $i] - $step}]
                    set c [::tkdown::colwidths_cost $memo $trial]
                    if {$c < $cost} {
                        set w $trial
                        set cost $c
                        set improved 1
                        break
                    }
                }
            }
        }
    }
    return $w
}

# The smallest width above cur, up to max, at which some cell of column j
# takes fewer lines; -1 when none does. A cell's line count never rises with
# the width, so each cell's breakpoint is a binary search. max is always the
# column's max-content, so the cache keys on j and cur alone.
proc ::tkdown::colwidths_next {memo j cur max} {
    variable colmemo
    set key $memo,next,$j,$cur
    if {[info exists colmemo($key)]} { return $colmemo($key) }
    set space $colmemo($memo,space)
    set best -1
    foreach cell [lindex $colmemo($memo,cols) $j] \
            now [::tkdown::colwidths_lines $memo $j $cur] \
            top [::tkdown::colwidths_lines $memo $j $max] {
        if {$now < 2 || $top >= $now} continue
        set lo [expr {$cur + 1}]
        set hi $max
        while {$lo < $hi} {
            set mid [expr {($lo + $hi) / 2}]
            if {[::tkdown::cell_lines $cell $mid $space] < $now} {
                set hi $mid
            } else {
                set lo [expr {$mid + 1}]
            }
        }
        if {$best < 0 || $lo < $best} { set best $lo }
    }
    set colmemo($key) $best
    return $best
}

# If line opens a list item, return {depth marker text}, else "". A marker is
# "-", "*" or "+" (marker "•") or ASCII digits and one dot (marker the digits
# and the dot, "3.", the source numbering kept), then one space; text is the
# rest of the line, still markdown. Depth counts the indentation before the
# marker, two spaces or one tab per level. "tcl 9.0" and "1.2.3" open
# nothing, and neither does a thematic break such as "- - -".
proc ::tkdown::list_marker {line} {
    if {![regexp {^([ \t]*)([-*+]|[0-9]+\.) (.*)$} $line -> ind mk rest]} {
        return ""
    }
    if {[::tkdown::rule_line $line]} { return "" }
    set tabs [regexp -all {\t} $ind]
    set width [expr {[string length $ind] - $tabs + 2 * $tabs}]
    if {$mk in {- * +}} { set mk "•" }
    return [list [expr {$width / 2}] $mk $rest]
}

# Split a normal (table-free) run into ordered {kind payload} segments, where
# kind is "normal" (payload is raw text) or "list" (payload is the items in
# source order, each {depth marker text} as list_marker reads it). A list is
# a run of item lines and the lines that belong to them:
#   - a non-blank line that is not itself a marker, directly under an item or
#     under that item's earlier continuation, joins the item's text on a line
#     of its own, "\n" between, its own indentation dropped (lazy
#     continuation);
#   - blank lines followed by another marker, at any depth, are dropped and
#     the list goes on; blank lines followed by anything else end it and stay
#     in the normal text that follows;
#   - a ``` fence line ends the list, and fenced lines are never items or
#     continuations.
proc ::tkdown::segment_lists {text} {
    set lines [split $text "\n"]
    set n [llength $lines]
    set segs  [list]
    set buf   [list]   ;# accumulating normal lines
    set items [list]   ;# accumulating {depth marker text} list items
    set incode 0
    for {set i 0} {$i < $n} {incr i} {
        set line [lindex $lines $i]
        set fence [::tkdown::fence_line $line]
        if {$fence} { set incode [expr {!$incode}] }
        if {!$fence && !$incode} {
            set item [::tkdown::list_marker $line]
            if {$item ne ""} {
                if {[llength $buf]} {
                    lappend segs [list normal [join $buf "\n"]]
                    set buf [list]
                }
                lappend items $item
                continue
            }
            if {[llength $items]} {
                set more [string trim $line]
                if {$more ne ""} {
                    set have [lindex $items end 2]
                    lset items end 2 [expr {$have eq "" ? $more : "$have\n$more"}]
                    continue
                }
                set j $i
                while {$j < $n && [string trim [lindex $lines $j]] eq ""} { incr j }
                if {$j < $n && [::tkdown::list_marker [lindex $lines $j]] ne ""} {
                    set i [expr {$j - 1}]
                    continue
                }
            }
        }
        if {[llength $items]} {
            lappend segs [list list $items]
            set items [list]
        }
        lappend buf $line
    }
    if {[llength $buf]}   { lappend segs [list normal [join $buf "\n"]] }
    if {[llength $items]} { lappend segs [list list $items] }
    return $segs
}

# Parse one prose run into styled inline runs. Returns an ordered list of
# runs, each {style chunk} or, for a link, {link chunk url}; style is one of
# plain, code, bold, italic, bolditalic, link, and chunk is the text to
# display with the markdown markers removed. Adjacent plain runs are
# coalesced. Callers strip fenced code and blockquotes first, so this never
# sees a ``` fence. The rules:
#   - code spans (one or two backticks) win over everything else, so
#     asterisks, links and URLs inside `code` stay literal;
#   - [text](url) is a link whose chunk is the raw text between the brackets,
#     emphasis markers and all; a bare http:// or https:// URL, or one in
#     <angle brackets>, is a link whose chunk is the URL itself;
#   - an inline ![alt](path) shows its alt text in the surrounding style;
#   - emphasis is asterisks only (*, **, ***): underscores stay literal, so
#     snake_case, __init__ and the like are left alone;
#   - an opener needs a non-space char after it and a closer a non-space char
#     before it (flanking), so "3 * 4" and "* item" stay literal;
#   - \`, \* and \\ escape a literal backtick, asterisk and backslash; every
#     other backslash is kept verbatim (paths and regex carry many).
proc ::tkdown::parse_inline {text} {
    # Escapes go to private-use sentinels so the marker scans never meet them;
    # any stray sentinel in the raw input is dropped first. Links are lifted
    # out to a sentinel of their own before the emphasis scan.
    set bt \uE000 ;# escaped backtick  -> literal `
    set st \uE001 ;# escaped asterisk  -> literal *
    set bs \uE002 ;# escaped backslash -> literal backslash
    set lk \uE003 ;# a link held aside, in order
    set text [string map [list $bt {} $st {} $bs {} $lk {}] $text]
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

    # Pass B: links out, emphasis within each prose gap, links back in where
    # their sentinels landed; unescape every emitted chunk.
    set runs [list]
    foreach {kind chunk} $segs {
        if {$kind eq "code"} {
            lappend runs [list code [::tkdown::inline_unescape $chunk]]
            continue
        }
        lassign [::tkdown::inline_links $chunk] chunk links
        set k 0
        foreach run [::tkdown::inline_emphasis $chunk] {
            lassign $run style stext
            set first 1
            foreach part [split $stext $lk] {
                if {!$first} {
                    lassign [lindex $links $k] ltext url
                    lappend runs [list link [::tkdown::inline_unescape $ltext] \
                        [::tkdown::inline_unescape $url]]
                    incr k
                }
                if {$part ne ""} {
                    lappend runs [list $style [::tkdown::inline_unescape $part]]
                }
                set first 0
            }
        }
    }
    set out [list]
    foreach run $runs {
        if {[lindex $run 0] eq "plain" && [llength $out]
                && [lindex $out end 0] eq "plain"} {
            lset out end 1 "[lindex $out end 1][lindex $run 1]"
        } else {
            lappend out $run
        }
    }
    return $out
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

proc ::tkdown::inline_unescape {s} {
    return [string map [list \uE000 "`" \uE001 "*" \uE002 "\\"] $s]
}

# Lift the links out of one prose gap. Returns {s links}: s is the gap with
# each link replaced by the \uE003 sentinel and each inline image by its alt
# text (asterisks escaped, so the alt reads literally), and links is the
# {text url} pairs in sentinel order. A bare URL must not follow a letter or
# digit, and loses a trailing punctuation run (url_trim).
proc ::tkdown::inline_links {s} {
    set out ""
    set links [list]
    set i 0
    set n [string length $s]
    while {$i < $n} {
        set ch [string index $s $i]
        set rest [string range $s $i end]
        if {$ch eq "!" && [string index $s [expr {$i + 1}]] eq "\["} {
            set hit [::tkdown::inline_link_at $s [expr {$i + 1}]]
            if {$hit ne ""} {
                lassign $hit alt url next
                append out [string map [list * \uE001] $alt]
                set i $next
                continue
            }
        } elseif {$ch eq "\["} {
            set hit [::tkdown::inline_link_at $s $i]
            if {$hit ne ""} {
                lassign $hit ltext url next
                if {$ltext eq ""} { set ltext $url }
                lappend links [list $ltext $url]
                append out \uE003
                set i $next
                continue
            }
        } elseif {$ch eq "<" && [regexp {^<(https?://[^\s<>]+)>} $rest m url]} {
            lappend links [list $url $url]
            append out \uE003
            incr i [string length $m]
            continue
        } elseif {$ch eq "h" && [regexp {^https?://[^\s<]+} $rest m]
                && ![string is alnum -strict [string index $s [expr {$i - 1}]]]} {
            set url [::tkdown::url_trim $m]
            if {[regexp {://.} $url]} {
                lappend links [list $url $url]
                append out \uE003
                incr i [string length $url]
                continue
            }
        }
        append out $ch
        incr i
    }
    return [list $out $links]
}

# If a [text](dest) link starts at index i of s, return {text url next},
# where next is the index just past its closing paren; else "". Brackets in
# the text and parens in the destination nest. The destination is a URL,
# optionally in <angle brackets>, optionally followed by a quoted title,
# which is dropped; an empty URL or anything else after it is no link.
proc ::tkdown::inline_link_at {s i} {
    set n [string length $s]
    set depth 0
    for {set j $i} {$j < $n} {incr j} {
        set c [string index $s $j]
        if {$c eq "\["} { incr depth }
        if {$c eq "\]" && [incr depth -1] == 0} break
    }
    if {$j >= $n || [string index $s [expr {$j + 1}]] ne "("} { return "" }
    set depth 0
    for {set k [expr {$j + 1}]} {$k < $n} {incr k} {
        set c [string index $s $k]
        if {$c eq "("} { incr depth }
        if {$c eq ")" && [incr depth -1] == 0} break
    }
    if {$k >= $n} { return "" }
    set dest [string trim [string range $s [expr {$j + 2}] [expr {$k - 1}]]]
    if {![regexp {^(<[^<>]*>|\S+)(?:\s+("[^"]*"|'[^']*'))?$} $dest -> url]} {
        return ""
    }
    set url [string trim $url "<>"]
    if {$url eq ""} { return "" }
    return [list [string range $s [expr {$i + 1}] [expr {$j - 1}]] $url \
        [expr {$k + 1}]]
}

# A bare URL with its trailing punctuation dropped, GFM's autolink trim: any
# run of ? ! . , : ; * _ ~ ' " at the end goes, and a closing paren goes
# while the URL holds more ")" than "(", so (see https://x.org/a) loses the
# paren and https://en.wikipedia.org/wiki/Tcl_(language) keeps it.
proc ::tkdown::url_trim {url} {
    while {$url ne ""} {
        set c [string index $url end]
        if {[string first $c {?!.,:;*_~'"}] >= 0
                || ($c eq ")" && [regexp -all {\)} $url] > [regexp -all {\(} $url])} {
            set url [string range $url 0 end-1]
            continue
        }
        break
    }
    return $url
}


# The Td* reading faces, derived from TkTextFont and TkFixedFont and created
# once per interp, as the fonts dict tags wants. A host with faces of its
# own passes those to tags instead. A widget that names one of these fonts
# before it exists keeps Tk's fallback face after it is created, so a host
# calls this before any widget names them.
proc ::tkdown::ensure_fonts {} {
    if {"TdBody" ni [font names]} {
        set text [font actual TkTextFont]
        set mono [font actual TkFixedFont]
        font create TdBody           {*}$text
        font create TdBodyBold       {*}$text -weight bold
        font create TdBodyItalic     {*}$text -slant italic
        font create TdBodyBoldItalic {*}$text -weight bold -slant italic
        font create TdMono           {*}$mono
        font create TdMonoBold       {*}$mono -weight bold
    }
    return [dict create body TdBody bold TdBodyBold italic TdBodyItalic \
        bolditalic TdBodyBoldItalic mono TdMono monobold TdMonoBold]
}

# Register a text widget for emission and configure the td-* faces on it.
# fonts is a dict of Tk font names: body bold italic bolditalic mono are
# required; h1 h2 h3 are optional heading faces falling back to bold. Extra
# keys, monobold among them, are kept for the host but nothing here draws
# with them. The options are those refit re-sets: -margin {left right} (or one n for both) is the host's base margin
# in screen distance, -copystyle the ttk style of a grid's copy button,
# -quotetags the tags the quote emitter lays over a quote, -image_cmd the
# command turning an image path into a Tk image, -on_block the command told
# of each block body paints. Registration opens the widget's table and link
# registries; the entry dies with the widget. Registering a widget again
# keeps the tables and links it already holds.
proc ::tkdown::tags {w fonts args} {
    variable widgets
    foreach k {body bold italic bolditalic mono} {
        if {![dict exists $fonts $k]} {
            error "tkdown: fonts dict missing \"$k\""
        }
    }
    set reg [dict create fonts $fonts margin {0 0} copystyle Copy.TButton \
        quotetags {} image_cmd {} on_block {} \
        tables [dict create] nextid 0 spot "" fittok "" \
        links [dict create] nextlink 0]
    if {[dict exists $widgets $w]} {
        foreach k {tables nextid spot fittok links nextlink} {
            dict set reg $k [dict get $widgets $w $k]
        }
    }
    set reg [::tkdown::options $w $reg $args]
    dict set widgets $w $reg
    # Later-configured tags win on -font where they stack: a link first so a
    # link inside a heading keeps the heading's face, headings next so
    # emphasis spans inside a heading still restyle.
    $w tag configure td-link -font [dict get $fonts body]
    foreach lvl {h1 h2 h3} {
        set f [expr {[dict exists $fonts $lvl]
            ? [dict get $fonts $lvl] : [dict get $fonts bold]}]
        $w tag configure td-$lvl -font $f
    }
    $w tag configure td-bold       -font [dict get $fonts bold]
    $w tag configure td-italic     -font [dict get $fonts italic]
    $w tag configure td-bolditalic -font [dict get $fonts bolditalic]
    $w tag configure td-code       -font [dict get $fonts mono]
    # A rule is one line of a face two pixels tall.
    if {"TdRule" ni [font names]} {
        font create TdRule -size -2 \
            -family [font actual [dict get $fonts body] -family]
    }
    $w tag configure td-rule -font TdRule
    ::tkdown::margins $w
    # A grid's frame, cells and copy button share one bindtag per pane: the
    # wheel goes on to w with its delta untouched (a cell would otherwise
    # take it and the pane stop scrolling under the pointer), and crossing
    # into or out of a table shows or hides its copy button.
    set bt tkdown.grid$w
    foreach ev {<MouseWheel> <Shift-MouseWheel> <TouchpadScroll>} {
        bind $bt $ev "[list event generate $w $ev -delta] %D; break"
    }
    bind $bt <Enter> [list ::tkdown::table_hover $w %W]
    bind $bt <Leave> [list after idle [list ::tkdown::table_hover_check $w %W]]
    foreach {ev script} [list <Destroy> [list ::tkdown::unregister $w] \
            <Configure> [list ::tkdown::refit_later $w]] {
        if {[string first $script [bind $w $ev]] < 0} {
            bind $w $ev +$script
        }
    }
}

# Fold option-value pairs into a registry entry and return it. -margin is
# held as two pixel counts.
proc ::tkdown::options {w reg opts} {
    if {[llength $opts] % 2} {
        error "tkdown: option \"[lindex $opts end]\" has no value"
    }
    foreach {opt val} $opts {
        switch -- $opt {
            -margin {
                if {[llength $val] == 1} { set val [list $val $val] }
                if {[llength $val] != 2} {
                    error "tkdown: -margin wants {left right} or one distance"
                }
                dict set reg margin [lmap d $val { winfo pixels $w $d }]
            }
            -copystyle { dict set reg copystyle $val }
            -quotetags { dict set reg quotetags $val }
            -image_cmd { dict set reg image_cmd $val }
            -on_block  { dict set reg on_block $val }
            default {
                error "tkdown: unknown option \"$opt\": want -margin,\
                    -copystyle, -quotetags, -image_cmd or -on_block"
            }
        }
    }
    return $reg
}

# The geometry tags, offset from the host's margin. td-margin is the margin
# itself, laid on everything body, prose and runs paint, and kept lowest of
# all w's tags so that any other tag setting a margin, the host's or the
# td-* ones below, wins where it stacks. A list item at depth d
# carries td-list and td-list<d>: the marker sits 10 px in plus 18 px a
# level, and the item text (and any wrapped continuation) 20 px past that.
# A line an item continues on carries td-listc<d> as well, which sets both
# margins at the item text. td-quote insets a quote block, bar included. A
# grid sits at the margin itself, and its width is capped by both margins.
# td-rule zeroes the line spacing and is raised over the base tags: spacing
# from a base tag would widen the line, and the line takes td-rule's
# -background, so the bar would be thicker than the face's two pixels.
proc ::tkdown::margins {w} {
    ::tkdown::list_indent $w td-list 0
    foreach tag [$w tag names] {
        if {[regexp {^td-list(\d+)$} $tag -> d]} {
            ::tkdown::list_indent $w $tag $d
        }
    }
    lassign [dict get [set ::tkdown::widgets] $w margin] l r
    $w tag configure td-margin -lmargin1 $l -lmargin2 $l -rmargin $r
    $w tag lower td-margin
    $w tag configure td-quote -lmargin1 [expr {$l + 14}] \
        -lmargin2 [expr {$l + 14}] -rmargin $r
    $w tag configure td-tblwin -lmargin1 $l -lmargin2 $l -rmargin $r
    $w tag configure td-rule -spacing1 0 -spacing2 0 -spacing3 0
    $w tag raise td-rule
}

# Configure a list tag for depth; for td-list<d>, td-listc<d> too, kept just
# above it so its lmargin1 wins on a continued line.
proc ::tkdown::list_indent {w tag depth} {
    lassign [dict get [set ::tkdown::widgets] $w margin] l r
    set mark [expr {$l + 10 + 18 * $depth}]
    set text [expr {$mark + 20}]
    $w tag configure $tag -lmargin1 $mark -lmargin2 $text -tabs $text \
        -rmargin $r
    if {$tag ne "td-list"} {
        $w tag configure td-listc$depth -lmargin1 $text -lmargin2 $text \
            -rmargin $r
        $w tag raise td-listc$depth $tag
    }
}

# Drop the widget from the registry, its grids and their bindings with it.
proc ::tkdown::unregister {w} {
    variable widgets
    if {![dict exists $widgets $w]} return
    ::tkdown::forget $w
    set bt tkdown.grid$w
    foreach ev [bind $bt] { bind $bt $ev {} }
    dict unset widgets $w
}

proc ::tkdown::with_margin {tags} {
    if {"td-margin" ni $tags} { lappend tags td-margin }
    return $tags
}

# Insert one prose run's inline spans at idx. Each styled chunk stacks its
# td-* face over baseTags, so only the -font changes and the host's colour
# and margins hold. A link's text also carries td-link, for the host's ink
# and bindings, and a tag of its own, td-link<N>, which the registry maps to
# its url (link_at, link_scan).
proc ::tkdown::runs {w idx text baseTags} {
    variable widgets
    set baseTags [::tkdown::with_margin $baseTags]
    foreach run [::tkdown::parse_inline $text] {
        lassign $run style chunk url
        set tags $baseTags
        switch -- $style {
            code       { lappend tags td-code }
            bold       { lappend tags td-bold }
            italic     { lappend tags td-italic }
            bolditalic { lappend tags td-bolditalic }
            link {
                set n [dict get $widgets $w nextlink]
                dict set widgets $w nextlink [incr n]
                dict set widgets $w links td-link$n $url
                lappend tags td-link td-link$n
            }
        }
        $w insert $idx $chunk $tags
    }
}

# Insert a prose run at idx through the prose emitter, closed by suffix (a
# rendering concern, passed rather than parsed).
proc ::tkdown::prose {w idx text baseTags {suffix "\n\n"}} {
    set baseTags [::tkdown::with_margin $baseTags]
    ::tkdown::emit_prose $w $idx $text $baseTags
    if {$suffix ne ""} { $w insert $idx $suffix $baseTags }
}

# Paint a markdown body at idx, one block at a time, then one closing
# newline under baseTags. Fenced code is split off first, then from each
# prose run in turn quotes, rules, image lines and tables; what is left is
# prose. Each block goes to its kind's emitter: emitters maps a kind (prose
# code quote table image rule) to a command, a kind it leaves out to
# ::tkdown::emit_<kind>, and a kind it maps to "" to nothing, so that kind
# is never split out and its lines reach the next splitter, and at last the
# prose emitter, as written. The emitters are called as
#   prose w idx text baseTags      code  w idx text codeTags
#   quote w idx text baseTags      table w idx payload baseTags
#   image w idx alt path baseTags  rule  w idx baseTags
# with a quote's text de-quoted and a table's payload segment_tables'.
# Code goes in under codeTags, named by the host outright, because a code
# block's chrome (margins, ink) is host styling, not a tkdown face. Both tag
# lists gain td-margin, so every emitter, the host's too, paints within it.
proc ::tkdown::body {w idx text baseTags codeTags {emitters {}}} {
    set baseTags [::tkdown::with_margin $baseTags]
    set codeTags [::tkdown::with_margin $codeTags]
    set em [::tkdown::emitters $emitters]
    set code [dict get $em code]
    set segs [expr {$code eq "" ? [list [list prose $text]]
        : [::tkdown::segment_code_fences $text]}]
    foreach seg $segs {
        lassign $seg kind chunk
        if {$kind eq "code"} {
            ::tkdown::block $w $idx code $chunk $baseTags \
                [list {*}$code $w $idx $chunk $codeTags]
        } else {
            ::tkdown::walk $w $idx $chunk $baseTags $em {quote rule image table}
        }
    }
    $w insert $idx "\n" $baseTags
}

# The emitters dict with every kind filled in.
proc ::tkdown::emitters {given} {
    set kinds {prose code quote table image rule}
    dict for {kind cmd} $given {
        if {$kind ni $kinds} {
            error "tkdown: unknown block kind \"$kind\": want [join $kinds {, }]"
        }
    }
    set em [dict create]
    foreach kind $kinds {
        dict set em $kind [dict getdef $given $kind ::tkdown::emit_$kind]
    }
    if {[dict get $em prose] eq ""} {
        error "tkdown: the prose emitter cannot be empty"
    }
    return $em
}

# Split a prose run by the first of stages, painting each block it splits
# off and handing each normal run to the rest; with no stages left, the
# run is one prose block. An empty run is a blank line, which a splitter
# would return no segments for, so it goes straight to prose.
proc ::tkdown::walk {w idx text baseTags em stages} {
    if {![llength $stages] || $text eq ""} {
        ::tkdown::block $w $idx prose $text $baseTags \
            [list {*}[dict get $em prose] $w $idx $text $baseTags]
        return
    }
    set rest [lassign $stages kind]
    set cmd [dict get $em $kind]
    if {$cmd eq ""} {
        tailcall ::tkdown::walk $w $idx $text $baseTags $em $rest
    }
    set split [dict get {quote segment_blockquotes rule segment_rules
        image segment_images table segment_tables} $kind]
    foreach seg [::tkdown::$split $text] {
        lassign $seg k payload
        switch -- $k {
            normal {
                ::tkdown::walk $w $idx $payload $baseTags $em $rest
            }
            quote {
                ::tkdown::block $w $idx quote $payload $baseTags \
                    [list {*}$cmd $w $idx $payload $baseTags]
            }
            rule {
                ::tkdown::block $w $idx rule "" $baseTags \
                    [list {*}$cmd $w $idx $baseTags]
            }
            image {
                lassign $payload alt path
                ::tkdown::block $w $idx image $alt $baseTags \
                    [list {*}$cmd $w $idx $alt $path $baseTags]
            }
            table {
                ::tkdown::block $w $idx table \
                    [::tkdown::table_to_markdown $payload] $baseTags \
                    [list {*}$cmd $w $idx $payload $baseTags]
            }
        }
    }
}

# Paint one block by running cmd, then end its line: a prose block always
# (a prose emitter leaves its last line open), any other only when its
# emitter left it open. Then -on_block hears {kind start end text}: start is
# the block's first character of content, end just past everything it
# inserted; the newlines a quote, rule, image or table emitter writes ahead
# of its content to set it off lie before start. text is the block's text (a
# table's as GFM, an image's alt, a rule's empty). A prose block of blank
# lines, the gap between two other blocks, is painted but not reported.
proc ::tkdown::block {w idx kind text baseTags cmd} {
    variable widgets
    variable blockseq
    set m td#block[incr blockseq]
    $w mark set $m [::tkdown::insert_at $w $idx]
    $w mark gravity $m left
    {*}$cmd
    set at [::tkdown::insert_at $w $idx]
    if {$kind eq "prose" || [$w compare $at != "$at linestart"]} {
        $w insert $idx "\n" $baseTags
        set at [::tkdown::insert_at $w $idx]
    }
    set start [$w index $m]
    $w mark unset $m
    if {$kind ni {prose code}} {
        while {[$w compare $start < $at] && [$w get $start] eq "\n"} {
            set start [$w index "$start +1c"]
        }
    }
    set on [dict get $widgets $w on_block]
    if {$on ne "" && !($kind eq "prose" && [string trim $text] eq "")} {
        {*}$on $kind $start $at $text
    }
}

# The index where an insert at idx lands: idx itself, or the last newline's
# index when idx is end.
proc ::tkdown::insert_at {w idx} {
    set at [$w index $idx]
    if {[$w compare $at == end]} { set at [$w index end-1c] }
    return $at
}

# Re-set any of tags' options, then bring the pane up to date with them:
# margins re-derived, copy buttons restyled, tables whose window has gone
# from the text dropped, and every built grid re-fitted on the next idle
# pass. A resize needs only the re-fit, which the pane's <Configure>
# schedules by itself; a host calls refit after a font change or to change
# an option.
proc ::tkdown::refit {w args} {
    variable widgets
    if {![dict exists $widgets $w]} return
    dict set widgets $w [::tkdown::options $w [dict get $widgets $w] $args]
    ::tkdown::margins $w
    set style [::tkdown::copy_style $w]
    dict for {id t} [dict get $widgets $w tables] {
        set f [dict get $t frame]
        if {[winfo exists $f.copy]} { $f.copy configure -style $style }
    }
    ::tkdown::table_prune $w
    ::tkdown::refit_later $w
}

# Schedule one fitting pass over the built grids. <Configure> fires per
# pixel through a sash drag and each fit walks every cell, so the pass is
# debounced to a single idle callback.
proc ::tkdown::refit_later {w} {
    variable widgets
    if {![dict exists $widgets $w]} return
    after cancel [dict get $widgets $w fittok]
    dict set widgets $w fittok [after idle [list ::tkdown::refit_run $w]]
}

proc ::tkdown::refit_run {w} {
    variable widgets
    if {![dict exists $widgets $w]} return
    dict set widgets $w fittok ""
    dict for {id t} [dict get $widgets $w tables] {
        if {![winfo exists [dict get $t frame]]} continue
        ::tkdown::table_paint $w $id
        ::tkdown::table_fit $w $id
    }
}

# Drop w's tables and links: destroy every grid, unset every tbl#m<N> mark,
# delete every td-link<N> tag, empty both registries. A `delete 1.0 end`
# alone leaves the link tags behind, and an unbuilt table's mark until
# refit or table_scan drops its record. Registration survives; call before a re-render. Table and
# link numbers are not reset, so a number never names two things.
proc ::tkdown::forget {w} {
    variable widgets
    if {![dict exists $widgets $w]} return
    after cancel [dict get $widgets $w fittok]
    dict for {id t} [dict get $widgets $w tables] {
        after cancel [dict get $t fbtok]
        destroy [dict get $t frame]
    }
    if {[winfo exists $w]} {
        foreach m [$w mark names] {
            if {[string match tbl#m* $m]} { $w mark unset $m }
        }
        set tags [dict keys [dict get $widgets $w links]]
        if {[llength $tags]} { $w tag delete {*}$tags }
    }
    dict set widgets $w tables [dict create]
    dict set widgets $w links [dict create]
    dict set widgets $w spot ""
    dict set widgets $w fittok ""
}

# The url of the link under idx, or "".
proc ::tkdown::link_at {w idx} {
    variable widgets
    if {![dict exists $widgets $w]} { return "" }
    set links [dict get $widgets $w links]
    foreach tag [$w tag names $idx] {
        if {[dict exists $links $tag]} { return [dict get $links $tag] }
    }
    return ""
}

# Search the links' urls, which the text does not show unless the link's
# text is its url. One hit per link whose url holds the needle and whose
# text does not, a match in the text being the host's own search's to find,
# in document order: {index url}, index being the start of the link's text.
# A link whose text is gone leaves the registry here.
proc ::tkdown::link_scan {w needle nocase} {
    variable widgets
    if {![dict exists $widgets $w] || $needle eq ""} { return {} }
    if {$nocase} { set needle [string tolower $needle] }
    set out [list]
    dict for {tag url} [dict get $widgets $w links] {
        set ranges [$w tag ranges $tag]
        set at [lindex $ranges 0]
        if {$at eq ""} {
            $w tag delete $tag
            dict unset widgets $w links $tag
            continue
        }
        set shown ""
        foreach {a b} $ranges { append shown [$w get $a $b] }
        if {$nocase} {
            set url_hay [string tolower $url]
            set shown [string tolower $shown]
        } else {
            set url_hay $url
        }
        if {[string first $needle $url_hay] >= 0
                && [string first $needle $shown] < 0} {
            lappend out [list $at $url]
        }
    }
    return [lsort -command [list ::tkdown::mark_order $w] $out]
}

# The default prose emitter: one prose run split into peer blocks that
# re-join on the newlines the splits consumed. A list run paints through
# emit_list; a heading line, ATX (atx_line) or a line over its setext
# underline (setext_level), lifts out under td-h1/h2/h3 (levels 4-6 render
# as h3); the rest is plain text, inline spans parsed inside each. A run
# with no list and no heading emits byte-for-byte as one inline pass. The
# last line is left open.
proc ::tkdown::emit_prose {w idx text baseTags} {
    set blocks [list]
    foreach seg [::tkdown::segment_lists $text] {
        lassign $seg kind payload
        if {$kind eq "list"} {
            lappend blocks [list list $payload]
            continue
        }
        set lines [split $payload "\n"]
        set buf [list]
        for {set i 0} {$i < [llength $lines]} {incr i} {
            set line [lindex $lines $i]
            set head [::tkdown::atx_line $line]
            if {$head eq ""} {
                set lvl [::tkdown::setext_level $lines $i]
                if {$lvl} {
                    set head [list $lvl [string trim $line]]
                    incr i
                }
            }
            if {$head eq ""} {
                lappend buf $line
                continue
            }
            if {[llength $buf]} {
                lappend blocks [list text [join $buf "\n"]]
                set buf [list]
            }
            lassign $head lvl title
            lappend blocks [list td-h[expr {min($lvl, 3)}] $title]
        }
        if {[llength $buf]} { lappend blocks [list text [join $buf "\n"]] }
    }
    set first 1
    foreach b $blocks {
        lassign $b kind chunk
        if {!$first} { $w insert $idx "\n" $baseTags }
        switch -- $kind {
            list    { ::tkdown::emit_list $w $idx $chunk $baseTags }
            text    { ::tkdown::runs $w $idx $chunk $baseTags }
            default { ::tkdown::runs $w $idx $chunk [concat $baseTags [list $kind]] }
        }
        set first 0
    }
}

# Emit one parsed list as consecutive logical lines, each item under td-list
# and td-list<depth>, its hanging indent: the marker, then a tab, then the
# item text through the inline-run path, so markdown inside an item still
# styles. Each line the item's text continues on adds td-listc<depth>, so it
# starts where the item text does. An item deeper than one level below the
# item before it is drawn one level below it.
proc ::tkdown::emit_list {w idx items baseTags} {
    set prev -1
    set tags {}
    foreach item $items {
        lassign $item depth marker text
        set depth [expr {min($depth, $prev + 1)}]
        set prev $depth
        if {$tags ne ""} { $w insert $idx "\n" $tags }
        if {"td-list$depth" ni [$w tag names]} {
            ::tkdown::list_indent $w td-list$depth $depth
        }
        set tags [concat $baseTags [list td-list td-list$depth]]
        $w insert $idx "$marker\t" $tags
        $w mark set td#item [::tkdown::insert_at $w $idx]
        $w mark gravity td#item left
        ::tkdown::runs $w $idx $text $tags
        set from [$w index "td#item +1 line linestart"]
        set at [::tkdown::insert_at $w $idx]
        if {[$w compare $from < $at]} { $w tag add td-listc$depth $from $at }
    }
    $w mark unset td#item
}

# The default code emitter: the text verbatim under codeTags, its line ended.
proc ::tkdown::emit_code {w idx text codeTags} {
    $w insert $idx "$text\n" $codeTags
}

# The default quote emitter. A quote following text with no blank line
# between gets one. Each physical line opens with a bar under td-quotebar,
# then its inline runs; the block lies under baseTags, -quotetags and
# td-quote. A ">" left inside a quote's text is literal.
proc ::tkdown::emit_quote {w idx text baseTags} {
    variable widgets
    set at [::tkdown::insert_at $w $idx]
    if {[$w compare $at != "$at linestart"]} {
        $w insert $idx "\n" $baseTags
        set at [::tkdown::insert_at $w $idx]
    }
    if {[$w compare $at > 1.0] && [$w compare "$at -1c linestart" != "$at -1c"]} {
        $w insert $idx "\n" $baseTags
    }
    set tags [concat $baseTags [dict get $widgets $w quotetags] [list td-quote]]
    foreach line [split $text "\n"] {
        $w insert $idx "▏ " [concat $tags [list td-quotebar]]
        ::tkdown::runs $w $idx $line $tags
        $w insert $idx "\n" $tags
    }
}

# The default image emitter: -image_cmd turns the path into a Tk image,
# embedded on a line of its own under baseTags; with no command, or none
# returned, the alt text stands in, inline spans parsed.
proc ::tkdown::emit_image {w idx alt path baseTags} {
    variable widgets
    set cmd [dict get $widgets $w image_cmd]
    set img [expr {$cmd eq "" ? "" : [{*}$cmd $path]}]
    if {$img ne ""} {
        set at [::tkdown::insert_at $w $idx]
        $w image create $idx -image $img -align baseline -padx 0 -pady 2
        foreach tag $baseTags { $w tag add $tag $at }
    } else {
        ::tkdown::runs $w $idx $alt $baseTags
    }
    $w insert $idx "\n" $baseTags
}

# The default rule emitter: one line holding a space under td-rule, the
# two-pixel face, so the host's td-rule -background draws a thin bar across
# the pane. td-rule is raised again here, over any base tag created since
# tags or refit, so its face and zero spacing win.
proc ::tkdown::emit_rule {w idx baseTags} {
    $w insert $idx " \n" [concat $baseTags [list td-rule]]
    $w tag raise td-rule
}

# ---- the grid ------------------------------------------------------------
#
# A table is one embedded window: a frame of gridded text cells that wrap
# their words, so a table wider than the pane folds its long cells instead
# of running off the edge. A cell is a text widget because one cell can mix
# faces (bold, `code`). The window builds itself only when the text first
# shows it (-create), so a long document costs no widgets until it is read;
# everything search and spotlight need is recorded at emit time instead:
# the payload, the cells' text as the reader sees it, and a mark on the
# window character. Per table the registry keeps
#   mark frame payload base flat lit fbtok cells
# where mark is tbl#m<N> on the window character, frame the grid's path
# (built or not), payload the parsed {align rows}, base the baseTags the
# table was painted under, flat the cells' text with inline markers
# dropped, for scan, lit whether it is the spotlit table, fbtok the copy
# button's pending ✓ reset token, and cells the cell widget paths, empty
# until built.

# The default table emitter: paint a parsed GFM table {align rows} at idx,
# the window character under td-tblwin (its margins, raised over the base
# tags' own) and baseTags (so a host's fold or elide tag reaches the table
# too), the left-gravity mark tbl#m<N> on it, then its newline under
# baseTags. A table met mid-line starts a line of its own.
proc ::tkdown::emit_table {w idx payload baseTags} {
    variable widgets
    set id [dict get $widgets $w nextid]
    incr id
    dict set widgets $w nextid $id
    set at [$w index $idx]
    if {[$w compare $at == end]} { set at [$w index end-1c] }
    if {[$w compare $at != "$at linestart"]} {
        $w insert $idx "\n" $baseTags
        set at [$w index "$at +1c"]
    }
    $w window create $idx -create [list ::tkdown::table_realize $w $id] \
        -align top -pady 2 -stretch 0
    foreach tag [concat $baseTags [list td-tblwin]] { $w tag add $tag $at }
    $w tag raise td-tblwin
    $w mark set tbl#m$id $at
    $w mark gravity tbl#m$id left
    $w insert $idx "\n" $baseTags
    set flat [lmap row [dict get $payload rows] {
        lmap cell $row {
            set s ""
            foreach run [::tkdown::parse_inline $cell] { append s [lindex $run 1] }
            set s
        }
    }]
    dict set widgets $w tables $id [dict create mark tbl#m$id frame $w.tbl$id \
        payload $payload base $baseTags flat $flat lit 0 fbtok "" cells {}]
}

# The window's -create: build table id's frame and return its path, or ""
# for a table the registry no longer holds. The frame's background is the
# gridline colour, showing through the one-pixel pads around each cell.
proc ::tkdown::table_realize {w id} {
    variable widgets
    if {![dict exists $widgets $w tables $id]} { return "" }
    set t [dict get $widgets $w tables $id]
    set f [dict get $t frame]
    if {[winfo exists $f]} { return $f }
    set fonts [dict get $widgets $w fonts]
    frame $f -borderwidth 0 -highlightthickness 0
    set align [dict get $t payload align]
    set ncol [llength $align]
    set cells [list]
    set r 0
    foreach row [dict get $t payload rows] {
        for {set j 0} {$j < $ncol} {incr j} {
            set c $f.c${r}x$j
            text $c -wrap word -width 1 -height 1 -borderwidth 0 \
                -highlightthickness 0 -padx 4 -pady 2 -takefocus 0 \
                -font [dict get $fonts body]
            ::tkdown::table_fill_cell $c $fonts [lindex $row $j] \
                [expr {$r == 0}] [lindex $align $j]
            grid $c -row $r -column $j -sticky nsew -padx 1 -pady 1
            bind $c <Configure> [list ::tkdown::table_cell_height $c]
            lappend cells $c
        }
        incr r
    }
    ttk::button $f.copy -style [::tkdown::copy_style $w] -text "⧉" -width 2 \
        -takefocus 0 -cursor hand2 -command [list ::tkdown::table_copy $w $id]
    foreach x [concat [list $f $f.copy] $cells] {
        bindtags $x [linsert [bindtags $x] 1 tkdown.grid$w]
    }
    bind $f <Destroy> [list ::tkdown::table_destroyed $w $id %W]
    dict set widgets $w tables $id cells $cells
    ::tkdown::table_paint $w $id
    after idle [list ::tkdown::table_fit $w $id]
    return $f
}

# Fill one cell from its markdown: the inline runs under per-cell face
# tags, a header cell bold throughout (hb is configured last, so it
# outranks the span faces), an aligned column justified by al.
proc ::tkdown::table_fill_cell {c fonts cell header align} {
    foreach {tg k} {b bold i italic bi bolditalic cd mono hb bold} {
        $c tag configure $tg -font [dict get $fonts $k]
    }
    if {$align ne "left"} { $c tag configure al -justify $align }
    foreach run [::tkdown::parse_inline $cell] {
        lassign $run style chunk
        switch -- $style {
            code       { set tags cd }
            bold       { set tags b }
            italic     { set tags i }
            bolditalic { set tags bi }
            default    { set tags {} }
        }
        $c insert end $chunk $tags
    }
    if {$header} { $c tag add hb 1.0 end }
    if {$align ne "left"} { $c tag add al 1.0 end }
    $c configure -state disabled
}

# Colour a built grid from the pane as it stands: the frame in the gridline
# (or spotlight) colour, each cell in the pane's background and cursor and
# the ink of the table's base tags.
proc ::tkdown::table_paint {w id} {
    variable widgets
    set t [dict get $widgets $w tables $id]
    set f [dict get $t frame]
    set bg [::tkdown::grid_colour $w]
    if {[dict get $t lit]} {
        set spot [::tkdown::tag_ink $w td-spot -background]
        if {$spot ne ""} { set bg $spot }
    }
    $f configure -background $bg
    set fg [$w cget -foreground]
    foreach tag [dict get $t base] {
        set ink [::tkdown::tag_ink $w $tag -foreground]
        if {$ink ne ""} { set fg $ink; break }
    }
    foreach c [dict get $t cells] {
        $c configure -background [$w cget -background] -foreground $fg \
            -cursor [$w cget -cursor]
    }
}

# A tag option's value on w, or "" when the host has not configured it.
proc ::tkdown::tag_ink {w tag opt} {
    if {[catch {$w tag cget $tag $opt} v]} { return "" }
    return $v
}

proc ::tkdown::grid_colour {w} {
    set c [::tkdown::tag_ink $w td-grid -background]
    if {$c eq ""} { set c [$w cget -foreground] }
    return $c
}

# The copy button's style: -copystyle while it names a style ttk knows,
# else plain TButton, so a host that styled nothing still gets a button.
proc ::tkdown::copy_style {w} {
    variable widgets
    set s [dict get $widgets $w copystyle]
    if {[catch {ttk::style layout $s}]} { set s TButton }
    return $s
}

# The table id behind a window of w's grids (frame, cell or button), or "".
proc ::tkdown::table_of {w x} {
    set pre $w.tbl
    if {[string first $pre $x] != 0} { return "" }
    if {![regexp {^(\d+)(\.|$)} [string range $x [string length $pre] end] \
            -> id]} { return "" }
    return $id
}

# Show a table's copy button at its top-right while the pointer is over it.
# Crossing from the frame into a cell fires <Leave> on the frame, so the
# hide waits for idle and keeps the button while the pointer is anywhere
# inside the frame.
proc ::tkdown::table_hover {w x} {
    set id [::tkdown::table_of $w $x]
    if {$id eq ""} return
    set f $w.tbl$id
    if {![winfo exists $f.copy]} return
    place $f.copy -in $f -relx 1.0 -x -2 -y 2 -anchor ne
    raise $f.copy
}

proc ::tkdown::table_hover_check {w x} {
    set id [::tkdown::table_of $w $x]
    if {$id eq ""} return
    set f $w.tbl$id
    if {![winfo exists $f.copy]} return
    set at [winfo containing {*}[winfo pointerxy $f]]
    if {$at eq $f || [string first $f. $at] == 0} return
    place forget $f.copy
}

# The copy button's action: the table as GFM onto the clipboard, the
# embedded window's text being out of reach of a drag-selection.
proc ::tkdown::table_copy {w id} {
    variable widgets
    if {![dict exists $widgets $w tables $id]} return
    set t [dict get $widgets $w tables $id]
    clipboard clear -displayof $w
    clipboard append -displayof $w -- \
        [::tkdown::table_to_markdown [dict get $t payload]]
    set f [dict get $t frame]
    if {![winfo exists $f.copy]} return
    after cancel [dict get $t fbtok]
    $f.copy configure -text "✓"
    dict set widgets $w tables $id fbtok \
        [after 700 [list ::tkdown::table_copy_reset $w $id]]
}

proc ::tkdown::table_copy_reset {w id} {
    variable widgets
    if {![dict exists $widgets $w tables $id]} return
    dict set widgets $w tables $id fbtok ""
    set f [dict get $widgets $w tables $id frame]
    if {[winfo exists $f.copy]} { $f.copy configure -text "⧉" }
}

# Size a built grid's columns to the pane. avail is the pane's inner width
# less both margins and, per column, the two gridline pixels and the
# cell's own padding; table_colwidths turns the cells' measured words into
# column widths, pinned as grid minsizes. The cells' <Configure> bindings
# turn the new widths into wrapped heights. Words are measured afresh on
# every fit, so a refit after a font change sees the new faces.
proc ::tkdown::table_fit {w id} {
    variable widgets
    if {![dict exists $widgets $w tables $id]} return
    set t [dict get $widgets $w tables $id]
    set f [dict get $t frame]
    if {![winfo exists $f]} return
    if {[winfo width $w] <= 1} return
    set fonts [dict get $widgets $w fonts]
    set ncol [llength [dict get $t payload align]]
    lassign [dict get $widgets $w margin] l r
    set inset [expr {2 * ([winfo pixels $w [$w cget -borderwidth]] \
        + [winfo pixels $w [$w cget -highlightthickness]] \
        + [winfo pixels $w [$w cget -padx]])}]
    set avail [expr {[winfo width $w] - $inset - $l - $r - $ncol * 10}]
    if {$avail < $ncol} { set avail $ncol }
    set rows [list]
    set header 1
    foreach row [dict get $t payload rows] {
        lappend rows [lmap cell $row { ::tkdown::cell_tokens $fonts $cell $header }]
        set header 0
    }
    set body [dict get $fonts body]
    set widths [::tkdown::table_colwidths $rows $avail \
        [font measure $body "0"] [font measure $body " "]]
    set j 0
    foreach cw $widths {
        grid columnconfigure $f $j -minsize [expr {$cw + 10}] -weight 0
        incr j
    }
}

# The pixel widths of one cell's words, each run measured in the face it
# paints in (a header cell is bold throughout). A word split across runs,
# as in a**b**, is one token whose width is the sum of its pieces.
proc ::tkdown::cell_tokens {fonts cell header} {
    set out [list]
    set cur -1
    foreach run [::tkdown::parse_inline $cell] {
        lassign $run style chunk
        if {$header} {
            set f [dict get $fonts bold]
        } else {
            switch -- $style {
                code       { set f [dict get $fonts mono] }
                bold       { set f [dict get $fonts bold] }
                italic     { set f [dict get $fonts italic] }
                bolditalic { set f [dict get $fonts bolditalic] }
                default    { set f [dict get $fonts body] }
            }
        }
        foreach piece [regexp -all -inline {\s+|\S+} $chunk] {
            if {[string is space $piece]} {
                if {$cur >= 0} { lappend out $cur; set cur -1 }
            } elseif {$cur < 0} {
                set cur [font measure $f $piece]
            } else {
                incr cur [font measure $f $piece]
            }
        }
    }
    if {$cur >= 0} { lappend out $cur }
    return $out
}

# One cell's <Configure>: size it to its wrapped display-line count at the
# width grid just gave it. Setting -height resizes only the cell's row, and
# the height-only Configure that follows measures the same count, so the
# chain ends there.
proc ::tkdown::table_cell_height {c} {
    if {![winfo exists $c]} return
    set dl [$c count -update -displaylines 1.0 end]
    if {$dl < 1} { set dl 1 }
    if {[$c cget -height] != $dl} { $c configure -height $dl }
}

# A grid's <Destroy>, whether by forget or by its window character being
# deleted: the table leaves the registry and its mark is unset. The text may
# be partway through deleting the window character, so the mark goes on the
# next idle pass rather than from inside the delete.
proc ::tkdown::table_destroyed {w id x} {
    variable widgets
    if {![dict exists $widgets $w tables $id]} return
    if {[dict get $widgets $w tables $id frame] ne $x} return
    after cancel [dict get $widgets $w tables $id fbtok]
    after idle [list ::tkdown::mark_unset $w \
        [dict get $widgets $w tables $id mark]]
    dict unset widgets $w tables $id
    if {[dict get $widgets $w spot] eq $id} { dict set widgets $w spot "" }
}

proc ::tkdown::mark_unset {w m} {
    if {[winfo exists $w]} { $w mark unset $m }
}

# Drop the tables whose mark no longer sits on their window character, the
# mark unset with them: the text holding them was deleted before the grid
# was ever built, so no <Destroy> came to say so.
proc ::tkdown::table_prune {w} {
    variable widgets
    dict for {id t} [dict get $widgets $w tables] {
        set m [dict get $t mark]
        if {![catch {$w dump -window $m} d]} {
            if {[llength $d] == 3 && [lindex $d 1] in [list "" [dict get $t frame]]} {
                continue
            }
            $w mark unset $m
        }
        after cancel [dict get $t fbtok]
        destroy [dict get $t frame]
        dict unset widgets $w tables $id
        if {[dict get $widgets $w spot] eq $id} { dict set widgets $w spot "" }
    }
}

# Search the tables' text, which a `$w search` cannot see inside an
# embedded window. One hit per table, in document order: {mark excerpt},
# the excerpt being the first matching cell's text as the reader sees it.
proc ::tkdown::table_scan {w needle nocase} {
    variable widgets
    if {![dict exists $widgets $w] || $needle eq ""} { return {} }
    ::tkdown::table_prune $w
    if {$nocase} { set needle [string tolower $needle] }
    set out [list]
    dict for {id t} [dict get $widgets $w tables] {
        set hit ""
        foreach cell [concat {*}[dict get $t flat]] {
            set hay [expr {$nocase ? [string tolower $cell] : $cell}]
            if {[string first $needle $hay] >= 0} { set hit $cell; break }
        }
        if {$hit ne ""} { lappend out [list [dict get $t mark] $hit] }
    }
    return [lsort -command [list ::tkdown::mark_order $w] $out]
}

proc ::tkdown::mark_order {w a b} {
    set a [lindex $a 0]
    set b [lindex $b 0]
    if {[$w compare $a < $b]} { return -1 }
    if {[$w compare $a > $b]} { return 1 }
    return 0
}

# Light the table whose mark sits at idx and put out the one lit before;
# any other idx, "" included, only puts it out. A lit grid's frame takes
# td-spot's background, so the gridlines and border read as the hit. The
# flag is set before the grid exists, so a jump that scrolls a table into
# view for the first time builds it lit.
proc ::tkdown::table_spotlight {w idx} {
    variable widgets
    if {![dict exists $widgets $w]} return
    set target ""
    if {$idx ne ""} {
        dict for {id t} [dict get $widgets $w tables] {
            if {![catch {$w compare [dict get $t mark] == $idx} same] && $same} {
                set target $id
                break
            }
        }
    }
    set prev [dict get $widgets $w spot]
    if {$prev ne "" && $prev ne $target && [dict exists $widgets $w tables $prev]} {
        dict set widgets $w tables $prev lit 0
        if {[winfo exists [dict get $widgets $w tables $prev frame]]} {
            ::tkdown::table_paint $w $prev
        }
    }
    dict set widgets $w spot $target
    if {$target eq ""} return
    dict set widgets $w tables $target lit 1
    if {[winfo exists [dict get $widgets $w tables $target frame]]} {
        ::tkdown::table_paint $w $target
    }
}
