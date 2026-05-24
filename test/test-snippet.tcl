#!/usr/bin/env tclsh9.0
# Unit test for ::csm::search::snippet_window - the hit-centred match window
# that replaced the 300-char head cap. Pure logic, no Tk. Run:
#   tclsh9.0 test/test-snippet.tcl

set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT lib search.tcl]

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

# A long line so the radius (80) elides both ends; the hit sits in the middle.
set mid [string repeat "x " 60][string repeat "y " 60]
append mid "NEEDLE "
append mid [string repeat "z " 60][string repeat "w " 60]

set w [::csm::search::snippet_window $mid NEEDLE -nocase]
check "middle hit is bracketed by ellipses" \
    [expr {[string index $w 0] eq "…" && [string index $w end] eq "…"}] 1
check "middle hit keeps the matched term" [string match "*NEEDLE*" $w] 1
check "middle window is short, not the whole line" \
    [expr {[string length $w] < [string length $mid]}] 1

# Hit at the very start: no leading ellipsis, trailing one present.
set head "NEEDLE [string repeat {tail } 80]"
set w [::csm::search::snippet_window $head NEEDLE -nocase]
check "start hit has no leading ellipsis" [expr {[string index $w 0] ne "…"}] 1
check "start hit has trailing ellipsis"   [string match "NEEDLE *…" $w] 1

# Hit at the very end: leading ellipsis, no trailing one.
set tail "[string repeat {head } 80]NEEDLE"
set w [::csm::search::snippet_window $tail NEEDLE -nocase]
check "end hit has leading ellipsis"     [expr {[string index $w 0] eq "…"}] 1
check "end hit has no trailing ellipsis" [expr {[string index $w end] ne "…"}] 1

# Short content with the hit: returned whole, no ellipses at all.
set w [::csm::search::snippet_window "a NEEDLE b" NEEDLE -nocase]
check "short content returned whole" $w "a NEEDLE b"

# Case-insensitive flag honoured.
set w [::csm::search::snippet_window "found a needle here" NEEDLE -nocase]
check "nocase matches lowercase" [string match "*needle*" $w] 1

# No match: falls back to the head-capped clean_text rather than erroring.
set w [::csm::search::snippet_window "no match in here" NEEDLE -nocase]
check "no-match fallback returns the text" $w "no match in here"

# Whitespace is collapsed before windowing.
set w [::csm::search::snippet_window "a\n\n  NEEDLE\t\tb" NEEDLE -nocase]
check "whitespace collapsed" $w "a NEEDLE b"

if {$failures > 0} {
    puts "\n$failures test(s) failed."
    exit 1
}
puts "\nAll tests passed."
