#!/usr/bin/env tclsh9.0
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT lib jsonl.tcl]

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
proc pi {s} { return [::questlog::jsonl::parse_inline $s] }

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

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
