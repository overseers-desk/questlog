#!/usr/bin/env wish9.0
# The emit half of tkdown: painting parsed markdown onto a Tk text widget.
#
# Where test-tkdown-parse.tcl drives the pure parse procs under a bare tclsh,
# this drives the widget-facing procs - tags, runs, prose, refit, forget - that
# need Tk: the per-widget font registry, the td-* faces, and the per-table
# td-tbl<N> tab geometry. It requires ONLY tkdown (no questlog sources) and
# builds its own named fonts, so a pass proves the module stands alone.
#
# Runs under wish (it builds text widgets): DISPLAY=:99 wish9.0 test-tkdown-emit.tcl

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add $ROOT
package require tkdown

set fails 0
proc check {name got want} {
    if {$got eq $want} {
        puts "ok   - $name"
    } else {
        puts "FAIL - $name"
        puts "       got:  $got"
        puts "       want: $want"
        incr ::fails
    }
}

# A named-font set the fonts dict needs, one Tk font per required key plus the
# optional headings left out (so the h1-h3 fallback is exercised). The mono
# faces are wider than body so a table's columns measure apart.
proc mkfonts {prefix size} {
    font create ${prefix}body       -family Courier -size $size
    font create ${prefix}bold       -family Courier -size $size -weight bold
    font create ${prefix}italic     -family Courier -size $size -slant italic
    font create ${prefix}bolditalic -family Courier -size $size -weight bold -slant italic
    font create ${prefix}mono       -family Courier -size $size
    return [dict create body ${prefix}body bold ${prefix}bold \
        italic ${prefix}italic bolditalic ${prefix}bolditalic \
        mono ${prefix}mono]
}
set FA [mkfonts fa- 10]   ;# default set
set FB [mkfonts fb- 22]   ;# a second, larger set for the crosstalk widget
set FC [mkfonts fc- 10]   ;# an isolated set the refit test mutates

# The alignment tokens out of a -tabs spec ({pos align pos align ...}).
proc tab_align {tabs} { set a {}; foreach {x al} $tabs { lappend a $al }; return $a }
proc strictly_up {tabs} {
    set prev -1
    foreach {x a} $tabs { if {$x <= $prev} { return 0 }; set prev $x }
    return 1
}
# Concatenated text of every range a tag covers.
proc tagtext {w tag} {
    set s ""
    foreach {a b} [$w tag ranges $tag] { append s [$w get $a $b] }
    return $s
}
proc reg {w} { return [dict get [set ::tkdown::widgets] $w] }

set TBL "| Name | Qty | Price |
| :--- | --: | --: |
| apple | 3 | 100 |
| fig | 12 | 5 |"

# ---- 1. tags: validation and the heading fallback ---------------------------
text .v
check "missing a required font key errors" \
    [catch {::tkdown::tags .v [dict remove $FA mono]} e] 1
check "the error names the missing key" [string match {*"mono"*} $e] 1
::tkdown::tags .v $FA
check "h1 falls back to bold when unset" \
    [.v tag cget td-h1 -font] [dict get $FA bold]
check "h2 falls back to bold when unset" \
    [.v tag cget td-h2 -font] [dict get $FA bold]
check "h3 falls back to bold when unset" \
    [.v tag cget td-h3 -font] [dict get $FA bold]

# ---- 2. runs: inline spans carry the right td-* over the right chars ---------
text .r
::tkdown::tags .r $FA
::tkdown::runs .r end "hello **world** and `code` here" base
check "td-bold covers exactly the emphasised word" [tagtext .r td-bold] "world"
check "td-code covers exactly the code span" [tagtext .r td-code] "code"
check "plain text carries only the base tag" [.r tag names 1.0] "base"
check "an emphasis span still stacks the base tag" \
    [expr {"base" in [.r tag names [lindex [.r tag ranges td-bold] 0]]}] 1
# Italic / bolditalic on their own faces.
::tkdown::runs .r end "an *aside* and ***both***" base
check "td-italic covers the italic word" [tagtext .r td-italic] "aside"
check "td-bolditalic covers the bolditalic word" [tagtext .r td-bolditalic] "both"

# ---- 3. prose: a pipe table's geometry, header face, and headings ------------
text .t
::tkdown::tags .t $FA
::tkdown::prose .t end $TBL base ""
set tag td-tbl1
check "the table renders under its own td-tbl1 tag" \
    [expr {[llength [.t tag ranges $tag]] > 0}] 1
set tabs [.t tag cget $tag -tabs]
check "the tab stops are strictly increasing" [strictly_up $tabs] 1
check "a right-aligned column yields a right tab stop" \
    [expr {"right" in [tab_align $tabs]}] 1
check "td-head covers the header cells only" [tagtext .t td-head] "NameQtyPrice"

text .h
::tkdown::tags .h $FA
::tkdown::prose .h end "# Alpha\n## Beta\n#### Delta" base ""
check "an ATX # line lands under td-h1" [tagtext .h td-h1] "Alpha"
check "an ATX ## line lands under td-h2" [tagtext .h td-h2] "Beta"
check "an ATX #### line clamps to td-h3" [tagtext .h td-h3] "Delta"

# A non-heading paragraph renders byte-for-byte the same whether or not a
# heading precedes it in the run.
text .p1
text .p2
::tkdown::tags .p1 $FA
::tkdown::tags .p2 $FA
::tkdown::prose .p1 end "alpha beta\ngamma delta" base ""
::tkdown::prose .p2 end "# A Heading\nalpha beta\ngamma delta" base ""
set para [.p1 get 1.0 "end-1c"]
set tail [string range [.p2 get 1.0 "end-1c"] [string length "A Heading\n"] end]
check "the plain paragraph renders identically with a heading above it" $tail $para

# ---- 4. refit: a font-size change recomputes the stops -----------------------
text .f
::tkdown::tags .f $FC
::tkdown::prose .f end $TBL base ""
set before [.f tag cget td-tbl1 -tabs]
font configure fc-body -size 30
font configure fc-bold -size 30
::tkdown::refit .f
set after [.f tag cget td-tbl1 -tabs]
check "refit changed the stops after the font grew" [expr {$before ne $after}] 1
check "the refitted stops are still strictly increasing" [strictly_up $after] 1

# ---- 5. forget: tables dropped, a fresh render stays clean -------------------
::tkdown::forget .t
check "no td-tbl* tag survives forget" \
    [expr {[llength [lsearch -all -glob [.t tag names] td-tbl*]]}] 0
check "the registry's table store is empty" [dict get [reg .t] tables] ""
.t delete 1.0 end
::tkdown::prose .t end $TBL base ""
check "a fresh table re-uses td-tbl1 (nextid reset)" \
    [expr {[llength [.t tag ranges td-tbl1]] > 0}] 1
check "the fresh table's stops are strictly increasing" \
    [strictly_up [.t tag cget td-tbl1 -tabs]] 1

# ---- 6. two registered widgets keep separate fonts and table ids ------------
text .w1
text .w2
::tkdown::tags .w1 $FA
::tkdown::tags .w2 $FB
::tkdown::prose .w1 end "$TBL\n\n$TBL" base ""   ;# two tables -> ids 1 and 2
::tkdown::prose .w2 end $TBL base ""             ;# one table  -> id 1
check "widget 1 counted two tables" [dict get [reg .w1] nextid] 2
check "widget 2's id counter is independent" [dict get [reg .w2] nextid] 1
check "each widget kept its own fonts dict" \
    [expr {[dict get [reg .w1] fonts] ne [dict get [reg .w2] fonts]}] 1
check "the larger font produced different stops (no shared geometry)" \
    [expr {[.w1 tag cget td-tbl1 -tabs] ne [.w2 tag cget td-tbl1 -tabs]}] 1
::tkdown::forget .w1
check "forgetting widget 1 left widget 2's table intact" \
    [expr {[llength [.w2 tag ranges td-tbl1]] > 0}] 1

# ---- 7. destroying a registered widget, then re-registering the path --------
text .g
::tkdown::tags .g $FA
destroy .g   ;# <Destroy> unregisters it
text .g
check "tags on a fresh widget of the same path succeeds" \
    [catch {::tkdown::tags .g $FA}] 0
check "the re-registered widget configures its faces" \
    [.g tag cget td-bold -font] [dict get $FA bold]

# ---- 8. lists: td-list ranges, hanging indent, ordered numbering -------------
text .l
::tkdown::tags .l $FA
check "td-list has lmargin1 shallower than lmargin2 (hanging indent)" \
    [expr {[.l tag cget td-list -lmargin1] < [.l tag cget td-list -lmargin2]}] 1
check "the td-list tab stop matches lmargin2" \
    [expr {[lindex [.l tag cget td-list -tabs] 0] == [.l tag cget td-list -lmargin2]}] 1

::tkdown::prose .l end "- apples\n- pears" base ""
check "an unordered list renders under td-list" \
    [expr {[llength [.l tag ranges td-list]] > 0}] 1
check "each bullet item carries the • marker then its text" \
    [tagtext .l td-list] "•\tapples\n•\tpears"
check "plain bullet text stacks the base tag under td-list" \
    [expr {"base" in [.l tag names [lindex [.l tag ranges td-list] 0]]}] 1

text .l2
::tkdown::tags .l2 $FA
::tkdown::prose .l2 end "3. gamma\n4. delta" base ""
check "an ordered list preserves its own numbers and dots" \
    [tagtext .l2 td-list] "3.\tgamma\n4.\tdelta"

# Inline markdown inside an item still styles through the run path.
text .l3
::tkdown::tags .l3 $FA
::tkdown::prose .l3 end "- see **bold** now" base ""
check "emphasis inside a list item still styles" [tagtext .l3 td-bold] "bold"

# Prose above and below a list; the list band is its own td-list range.
text .l4
::tkdown::tags .l4 $FA
::tkdown::prose .l4 end "intro line\n- a\n- b\noutro line" base ""
check "prose around a list stays outside td-list" [tagtext .l4 td-list] "•\ta\n•\tb"
check "the surrounding prose is present in the widget" \
    [expr {[string match {*intro line*outro line*} [.l4 get 1.0 end-1c]]}] 1

# A marker-like line that is not a flat list marker stays literal (no td-list).
text .l5
::tkdown::tags .l5 $FA
::tkdown::prose .l5 end "compute 3 * 4 then done" base ""
check "marker-like mid-line text carries no td-list" \
    [expr {[llength [.l5 tag ranges td-list]]}] 0

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
