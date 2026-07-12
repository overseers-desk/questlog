#!/usr/bin/env tclsh9.0
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add $ROOT
package require tkdown

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name"
        puts "  expected: <$expected>"
        puts "  actual:   <$actual>"
        incr ::fails
    } else {
        puts "ok:   $name"
    }
}
proc pi {s} { return [::tkdown::parse_inline $s] }

# ---- parse_inline: prose into styled inline runs ---------------------------
# Each style, markers stripped.
check inline_italic        {{italic x}}           [pi {*x*}]
check inline_bold          {{bold x}}             [pi {**x**}]
check inline_bolditalic    {{bolditalic x}}       [pi {***x***}]
check inline_code          {{code x}}             [pi {`x`}]
check inline_plain         {{plain {hello world}}} [pi {hello world}]

# Code spans win over emphasis: asterisks inside backticks stay literal.
check code_over_glob       {{code **/*.tcl}}      [pi {`**/*.tcl`}]
check code_over_bold       {{code **bold**}}      [pi {`**bold**`}]

# Flanking guards reject non-emphasis asterisks.
check flank_mult           {{plain {3 * 4}}}      [pi {3 * 4}]
check flank_bullet         {{plain {* item}}}     [pi {* item}]
check flank_spaced         {{plain {a * b}}}      [pi {a * b}]

# No matching closer: markers stay literal.
check unclosed_glob        {{plain **/*.tcl}}     [pi {**/*.tcl}]
check unclosed_backtick    {{plain {use the ` key}}} [pi {use the ` key}]

# Backslash escapes.
check escape_asterisk      {{plain *literal*}}    [pi {\*literal\*}]
check escape_backtick      {{plain `}}            [pi {\`}]
check escape_backslash     {{plain \\}}           [pi {\\}]

# Underscores stay literal (asterisk-only emphasis).
check snake_case_plain     {{plain {my_var __init__ tool_use_id}}} \
    [pi {my_var __init__ tool_use_id}]

# Mixed run: plain coalesced, code and bold in document order.
check mixed_run \
    {{plain {see }} {code foo} {plain { and }} {bold bar}} \
    [pi {see `foo` and **bar**}]

# bolditalic embedded mid-prose.
check bolditalic_embedded \
    {{plain {a }} {bolditalic b} {plain { c}}} \
    [pi {a ***b*** c}]

# ---- segment_blockquotes: split a body into ordered {kind text} segments,
# de-quoting one leading "> "/">" per blockquote line, strict blank split.
check seg_plain      {{normal hello}} \
    [::tkdown::segment_blockquotes "hello"]
check seg_pure_quote {{quote {To: a@b
body}}} \
    [::tkdown::segment_blockquotes "> To: a@b\n> body"]
check seg_mixed      {{normal intro:} {quote {line one
line two}} {normal outro}} \
    [::tkdown::segment_blockquotes "intro:\n> line one\n> line two\noutro"]
check seg_bare_gt    {{quote {has space
no space}}} \
    [::tkdown::segment_blockquotes "> has space\n>no space"]
check seg_blank_split {{quote first} {normal {}} {quote second}} \
    [::tkdown::segment_blockquotes "> first\n\n> second"]

# ---- segment_tables: split a prose run into {normal text} / {table payload}
# segments, payload = {align <per-col> rows <header-then-body>}. Expected
# values are built the same way the proc builds them (list + dict create), so
# a dict-ordering quirk can never make a correct result read as a failure.
check tbl_basic \
    [list [list table [dict create align {left left} rows {{H1 H2} {a b}}]]] \
    [::tkdown::segment_tables "| H1 | H2 |\n| --- | --- |\n| a | b |"]
check tbl_align \
    [list [list table [dict create align {left right center} \
        rows {{L R C} {1 2 3}}]]] \
    [::tkdown::segment_tables "| L | R | C |\n| :-- | --: | :-: |\n| 1 | 2 | 3 |"]
check tbl_unbounded \
    [list [list table [dict create align {left left} rows {{a b} {1 2}}]]] \
    [::tkdown::segment_tables "a | b\n- | -\n1 | 2"]
check tbl_escape \
    [list [list table [dict create align {left left} \
        rows [list {H1 H2} [list "a | b" c]]]]] \
    [::tkdown::segment_tables "| H1 | H2 |\n| - | - |\n| a \\| b | c |"]
check tbl_ragged \
    [list [list table [dict create align {left left left} \
        rows {{H1 H2 H3} {a b {}} {c d e}}]]] \
    [::tkdown::segment_tables \
        "| H1 | H2 | H3 |\n| - | - | - |\n| a | b |\n| c | d | e | f |"]
check tbl_header_only \
    [list [list table [dict create align {left left} rows {{H1 H2}}]]] \
    [::tkdown::segment_tables "| H1 | H2 |\n| - | - |"]
check tbl_setext \
    [list [list normal "Heading\n---\nbody"]] \
    [::tkdown::segment_tables "Heading\n---\nbody"]
check tbl_pipe_no_delim \
    [list [list normal "| not a table |\njust text"]] \
    [::tkdown::segment_tables "| not a table |\njust text"]
check tbl_interleave \
    [list [list normal "intro\n"] \
        [list table [dict create align {left left} rows {{H1 H2} {a b}}]] \
        [list normal "\noutro"]] \
    [::tkdown::segment_tables \
        "intro\n\n| H1 | H2 |\n| - | - |\n| a | b |\n\noutro"]

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
