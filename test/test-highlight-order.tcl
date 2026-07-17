#!/usr/bin/env tclsh9.0
# Tests for ::questlog::ui::rarity_round_robin - the match-index interleave that
# surfaces every search term once, rarest first, before any term repeats.
#
# The proc lives in ui/viewer.tcl, which requires Tk; this test only calls the
# pure proc, so it runs under tclsh9.0 given a display. With no display it skips
# rather than failing, so a display-less run of the suite stays green.
package require Tcl 9

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
if {[catch {package require Tk}]} {
    puts "SKIP - no Tk/display; rarity_round_robin lives in ui/viewer.tcl"
    exit 0
}
# The app declares the ui namespace in toolbar.tcl, the first ui file it sources
# before viewer.tcl; mirror that here so viewer.tcl can attach its proc.
namespace eval ::questlog::ui {}
source [file join $ROOT ui viewer.tcl]

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

# The caller passes per-term position lists already ordered rarest-first; the
# proc interleaves them round-robin and drops any position already taken.

# Rarest term leads, then one hit of each before any term repeats.
check "rarest-first round-robin" \
    [::questlog::ui::rarity_round_robin {{b1} {c1 c2} {a1 a2 a3}}] \
    {b1 c1 a1 c2 a2 a3}

# A single term keeps its document order.
check "single term unchanged" \
    [::questlog::ui::rarity_round_robin {{x1 x2}}] {x1 x2}

# No matches yields nothing.
check "empty input" [::questlog::ui::rarity_round_robin {}] {}

# A position matched by two terms (one a substring of the other at the same
# spot) appears once; the rest still interleave.
check "duplicate position deduped" \
    [::questlog::ui::rarity_round_robin {{p1 p2} {p1 p3}}] {p1 p2 p3}

# Tk-shaped indices order the same way (the real input type).
check "tk indices interleave" \
    [::questlog::ui::rarity_round_robin {{12.0} {3.0 40.5} {1.0 5.2 9.9}}] \
    {12.0 3.0 1.0 40.5 5.2 9.9}

if {$failures == 0} {
    puts "\nAll tests passed."
    exit 0
} else {
    puts "\n$failures test(s) failed."
    exit 1
}
