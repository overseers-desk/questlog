#!/usr/bin/env tclsh9.0
# Unit test for ::questlog::match::snippet_window - the search-hit match window,
# a short excerpt that leads with the matched term. Pure logic, no Tk. Run:
#   tclsh9.0 test/test-snippet.tcl

set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT config.tcl]
source [file join $ROOT lib match.tcl]
::questlog::match::set_caps [dict create \
    content_cap     [::questlog::config::get content_cap] \
    snippet_lead    [::questlog::config::get snippet_lead] \
    snippet_trail   [::questlog::config::get snippet_trail] \
    tool_param_cap  [::questlog::config::get tool_param_cap] \
    tool_render_cap [::questlog::config::get tool_render_cap]]

set failures 0
proc check {name got want} {
    if {$got eq $want} {
        puts "ok   - $name"
    } else {
        puts "FAIL - $name"
        puts "       got:  $got"
        puts "       want: $want"
        incr ::failures
    }
}

# A long line so both ends elide; the hit sits in the middle.
set mid [string repeat "x " 60][string repeat "y " 60]
append mid "NEEDLE "
append mid [string repeat "z " 60][string repeat "w " 60]

set w [::questlog::match::snippet_window $mid NEEDLE -nocase]
check "middle hit is bracketed by ellipses" \
    [expr {[string index $w 0] eq "…" && [string index $w end] eq "…"}] 1
check "middle hit keeps the matched term" [string match "*NEEDLE*" $w] 1
check "middle window is short, not the whole line" \
    [expr {[string length $w] < [string length $mid]}] 1
# The hit leads: only the leading "…" and snippet_lead characters of context
# precede the matched term, so it survives a narrow, non-scrolling row.
check "snippet leads with the keyword" \
    [string first NEEDLE $w] [expr {1 + [::questlog::match::cap snippet_lead]}]

# Hit at the very start: no leading ellipsis, trailing one present.
set head "NEEDLE [string repeat {tail } 80]"
set w [::questlog::match::snippet_window $head NEEDLE -nocase]
check "start hit has no leading ellipsis" [expr {[string index $w 0] ne "…"}] 1
check "start hit has trailing ellipsis"   [string match "NEEDLE *…" $w] 1

# Hit at the very end: leading ellipsis, no trailing one.
set tail "[string repeat {head } 80]NEEDLE"
set w [::questlog::match::snippet_window $tail NEEDLE -nocase]
check "end hit has leading ellipsis"     [expr {[string index $w 0] eq "…"}] 1
check "end hit has no trailing ellipsis" [expr {[string index $w end] ne "…"}] 1

# Short content with the hit: returned whole, no ellipses at all.
set w [::questlog::match::snippet_window "a NEEDLE b" NEEDLE -nocase]
check "short content returned whole" $w "a NEEDLE b"

# Case-insensitive flag honoured.
set w [::questlog::match::snippet_window "found a needle here" NEEDLE -nocase]
check "nocase matches lowercase" [string match "*needle*" $w] 1

# No match: falls back to the head-capped clean_text rather than erroring.
set w [::questlog::match::snippet_window "no match in here" NEEDLE -nocase]
check "no-match fallback returns the text" $w "no match in here"

# Whitespace is collapsed before windowing.
set w [::questlog::match::snippet_window "a\n\n  NEEDLE\t\tb" NEEDLE -nocase]
check "whitespace collapsed" $w "a NEEDLE b"

if {$failures > 0} {
    puts "\n$failures test(s) failed."
    exit 1
}
puts "\nAll tests passed."
