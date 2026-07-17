#!/usr/bin/env wish
# The bar, driven through the widgets it builds: the chips' delete buttons, the add
# rail, the inline editors, the disclosure. The facets here are colour, size, weight,
# shape, note, tag and origin - a chip list with a per-value control, two steppers,
# a single-valued facet, one that takes repeats up to a cap, one revealed from the
# rail, and one only the owner can fill.

package require Tcl 8.6-
package require Tk 8.6-

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require facetbar

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name\n  expected: $expected\n  actual:   $actual"
        incr ::fails
    } else { puts "ok:   $name" }
}
# The guards: what the widget refuses, it has to refuse where the caller wrote it.
proc refused {name script pattern} {
    set caught [catch {uplevel 1 $script} err]
    if {!$caught || ![string match $pattern $err]} {
        puts "FAIL: $name\n  expected an error matching: $pattern\n  actual:   $err"
        incr ::fails
    } else { puts "ok:   $name" }
}
proc no_error {name script} {
    set caught [catch {uplevel 1 $script} err]
    if {$caught} {
        puts "FAIL: $name\n  raised: $err"
        incr ::fails
    } else { puts "ok:   $name" }
}

# ---- the invented host ---------------------------------------------------
#
# colour: values are {shade name} pairs, so the chip's per-value control (a shade
# cycler) has something to edit, and two chips can print differently from one name.
proc colour_chip {value} {
    lassign $value shade name
    return [expr {$shade eq "any" ? $name : "$shade $name"}]
}
proc colour_shade {w id idx value} {
    lassign $value shade name
    ttk::button $w -text $shade -width 5 -command [list cycle_shade $idx]
}
proc cycle_shade {idx} {
    lassign [lindex [$::bar values colour] $idx] shade name
    set next [dict get {any dark  dark light  light any} $shade]
    $::bar set_value_at colour $idx [list $next $name]
}
# A per-value control that decides there is nothing to draw: the chip is plain, and
# the bar lays out what it finds, which is nothing.
proc no_ctl {w id idx value} { return }

# size and weight: bespoke controls, the case a chip list cannot serve. Their floor
# means "no criterion", so at the floor the facet holds no value and shows no chip,
# and the control says so from inside its own command - which is the moment a tail
# facet's row would otherwise be pulled out from under the control reporting it.
# Both talk back through report_values, the door that leaves the reporter alone.
proc size_chip {value}   { return "at least $value" }
proc weight_chip {value} { return "over $value kg" }
proc size_editor {parent id values} {
    set ::sizevar [expr {[llength $values] ? [lindex $values 0] : 1}]
    ttk::spinbox $parent.sb -from 1 -to 99 -width 3 \
        -textvariable ::sizevar -command size_changed
    pack $parent.sb -side left
}
proc size_changed {} {
    if {$::sizevar <= 1} {
        $::bar report_values size {}
    } else {
        $::bar report_values size [list $::sizevar]
    }
}
proc weight_editor {parent id values} {
    set ::weightvar [expr {[llength $values] ? [lindex $values 0] : 0}]
    ttk::spinbox $parent.sb -from 0 -to 99 -width 3 \
        -textvariable ::weightvar -command weight_changed
    pack $parent.sb -side left
}
proc weight_changed {} {
    if {$::weightvar <= 0} {
        $::bar report_values weight {}
    } else {
        $::bar report_values weight [list $::weightvar]
    }
}

# The chip facets' add editor: one entry, committing on Return, abandoning on
# Escape. It takes the caret itself, as the module's contract asks. The focus is
# forced because Tk hands a key event to the focus widget and no window manager
# runs on the test display, so the toplevel never takes the X focus and a plain
# `focus` would leave the synthetic Return below undelivered.
proc text_editor {parent id values} {
    set ::addtext($id) ""
    ttk::entry $parent.e -width 12 -textvariable ::addtext($id)
    pack $parent.e -side left
    bind $parent.e <Return> [list commit_text $id]
    bind $parent.e <Escape> [list $::bar cancel_add $id]
    focus -force $parent.e
}
proc commit_text {id} {
    set v [string trim $::addtext($id)]
    if {$v eq ""} { $::bar cancel_add $id; return }
    if {$id eq "colour"} { set v [list any $v] }
    $::bar add_value $id $v
}
# Type a value into a facet's open editor and press Return.
proc type_into {area id value} {
    set ::addtext($id) $value
    event generate $area.e <Return>
    update
}
proc plain_chip {v} { return $v }
proc boom_editor {parent id values} { error "the editor blew up" }
# A formatter that meets a value it cannot print.
proc picky_chip {v} {
    if {$v eq "unprintable"} { error "cannot print that" }
    return $v
}

proc on_change {model} { lappend ::events $model }
set ::events {}
set FACETS {
    {id colour conn "is"        format colour_chip editor text_editor chipctl colour_shade}
    {id size   conn "counts"    format size_chip   editor size_editor mode control max 1}
    {id weight conn "weighs"    format weight_chip editor weight_editor mode control max 1 tail 1}
    {id shape  conn "is shaped" editor text_editor max 1}
    {id note   conn "notes"     editor text_editor dedupe 0 max 3 chipctl no_ctl}
    {id tag    conn "is tagged" editor text_editor tail 1 max 2 orword "and" ortext "+ and"}
    {id origin conn "came from" tail 1}
}

# ---- the bar -------------------------------------------------------------

pack [ttk::frame .f] -fill both -expand 1
set bar [::facetbar::FacetBar new]
$bar configure -heading "Restrict to items that…" -changecb on_change -facets $FACETS
$bar setup .f
update

set BODY .f.body
set ROWS $BODY.rows

check "the model carries every facet, applied or not" \
    {colour {} size {} weight {} shape {} note {} tag {} origin {}} [$bar model]
check "the bar dresses the chip style it ships with, so an unstyled host can see a chip" \
    solid [dict get [ttk::style configure FacetChip.TFrame] -relief]
check "a persistent facet has a row from the start" {1 1} \
    [list [winfo exists $ROWS.tag_colour] [winfo exists $ROWS.tag_size]]
check "a tail facet has none, and waits on the add rail" {0 1} \
    [list [winfo exists $ROWS.tag_tag] [winfo exists $BODY.rail.b_tag]]
check "the rail button names the facet it reveals" "+ tag" [$BODY.rail.b_tag cget -text]
check "a tail facet with no editor is never offered on the rail: it would be a dead end" \
    0 [winfo exists $BODY.rail.b_origin]
check "an empty facet's add affordance reads as the first value" "+" \
    [$ROWS.ed_colour.add cget -text]
check "the heading carries no count while nothing is applied" \
    "Restrict to items that…" [.f.head.hd cget -text]

# ---- chips render, and delete --------------------------------------------

$bar set_model {colour {{any red} {any blue}}}
update
check "chips render one per value, in model order" {red blue} \
    [list [$ROWS.ed_colour.c0.t cget -text] [$ROWS.ed_colour.c1.t cget -text]]
check "the connector joins them" or [$ROWS.ed_colour.or1 cget -text]
check "an applied facet's add affordance reads as one more, joined" "+ or" \
    [$ROWS.ed_colour.add cget -text]
check "set_model fires no change event: the owner already knows" 0 [llength $::events]

# ---- the count sums the values across the countable facets ----------------
#
# By default every facet counts, and the count is the number of values applied,
# not the number of facets holding one: colour alone, with its two values, reads
# two. A -countables subset counts only the facets it names, so a facet left out
# of it adds nothing however many values it holds. An id no descriptor declares
# is refused where it is named, and the whole configure with it: the count is
# still summed over the facets it had.
check "the count sums the values across every facet by default" \
    "Restrict to items that…   2 active" [.f.head.hd cget -text]
$bar configure -countables {size weight}
update
check "a -countables subset counts only the facets it names, and colour is not one" \
    "Restrict to items that…" [.f.head.hd cget -text]
$bar configure -countables {colour}
update
check "and it sums the values of a facet it does name" \
    "Restrict to items that…   2 active" [.f.head.hd cget -text]
refused "a -countables naming a facet no descriptor declares is refused" \
    {$bar configure -countables {colour nosuch}} "*no facet declares*"
check "the refusal keeps the -countables it had, all or nothing like every configure" \
    colour [$bar cget -countables]
$bar configure -countables {}
update
check "the empty default counts every facet again" \
    "Restrict to items that…   2 active" [.f.head.hd cget -text]

update idletasks
check "the delete sits at the chip's trailing edge, where a chip control is looked for" \
    1 [expr {[winfo x $ROWS.ed_colour.c0.x] > [winfo x $ROWS.ed_colour.c0.t]}]
$bar configure -delside left
update idletasks
check "-delside left brings it to the near end, which is the end still in view on a chip wider than the bar" \
    1 [expr {[winfo x $ROWS.ed_colour.c0.x] < [winfo x $ROWS.ed_colour.c0.t]}]

$ROWS.ed_colour.c1.x invoke
update
check "a chip's delete affordance drops its value" {{any red}} [$bar values colour]
check "and the chip's widget goes with it" 0 [winfo exists $ROWS.ed_colour.c1]
check "the delete tells the owner the whole new model" \
    {colour {{any red}} size {} weight {} shape {} note {} tag {} origin {}} \
    [lindex $::events end]

# ---- the per-value control -----------------------------------------------

$ROWS.ed_colour.c0.lead invoke
update
check "a chip's own control edits that value in place" {{dark red}} [$bar values colour]
check "and the chip reruns the caller's formatter" "dark red" \
    [$ROWS.ed_colour.c0.t cget -text]

set n [llength $::events]
$bar set_value_at colour 0 {dark red}
check "rewriting a value with the value it already holds moves nothing" \
    {{dark red}} [$bar values colour]
check "and publishes nothing" $n [llength $::events]

# ---- the inline add, and the editor that stays open -----------------------

$ROWS.ed_colour.add invoke
update
check "the add affordance opens into the facet's own editor" 1 \
    [winfo exists $ROWS.ed_colour.add.e]
type_into $ROWS.ed_colour.add colour green
check "committing the editor appends the value" {{dark red} {any green}} \
    [$bar values colour]
check "the commit tells the owner" {{dark red} {any green}} \
    [dict get [lindex $::events end] colour]
check "and the editor stays open, so a second value can be typed straight after" 1 \
    [winfo exists $ROWS.ed_colour.add.e]

set n [llength $::events]
type_into $ROWS.ed_colour.add colour green
check "a repeat of an applied value is no second criterion" {{dark red} {any green}} \
    [$bar values colour]
check "and raises no change event" $n [llength $::events]

event generate $ROWS.ed_colour.add.e <Escape>
update
check "Escape closes the editor back to the add affordance" "+ or" \
    [$ROWS.ed_colour.add cget -text]
check "and changes no value" {{dark red} {any green}} [$bar values colour]

# ---- a facet where a repeat is a second value, up to a cap of three -------

$ROWS.ed_note.add invoke
update
type_into $ROWS.ed_note.add note fragile
type_into $ROWS.ed_note.add note fragile
check "a facet that asks for repeats takes the same value twice" {fragile fragile} \
    [$bar values note]
check "and chips them both" 1 [winfo exists $ROWS.ed_note.c1]
check "a per-value control that draws nothing leaves a plain chip" 0 \
    [winfo exists $ROWS.ed_note.c0.lead]
type_into $ROWS.ed_note.add note heavy
check "a third value reaches the facet's cap" {fragile fragile heavy} [$bar values note]
check "which closes the editor and takes the affordance away" 0 \
    [winfo exists $ROWS.ed_note.add]
set n [llength $::events]
$bar add_value note extra
check "and a commit past the cap adds nothing" {fragile fragile heavy} [$bar values note]
check "and publishes nothing" $n [llength $::events]

# ---- cardinality: a facet that can hold only one value --------------------

$ROWS.ed_shape.add invoke
update
type_into $ROWS.ed_shape.add shape round
check "a single-valued facet takes its first value" round [$bar values shape]
check "it closes its editor, because there is nothing more it can take" 0 \
    [winfo exists $ROWS.ed_shape.add.e]
check "and its affordance offers no join, because a commit there replaces" "+" \
    [$ROWS.ed_shape.add cget -text]
$ROWS.ed_shape.add invoke
update
type_into $ROWS.ed_shape.add shape square
check "a second value replaces it rather than joining it" square [$bar values shape]
check "so the row never grows a second chip" 0 [winfo exists $ROWS.ed_shape.c1]

# ---- the tail facet, its own connector, and its cap -----------------------

$BODY.rail.b_tag invoke
update
check "the rail reveals the tail facet's row" 1 [winfo exists $ROWS.tag_tag]
check "with its editor already open, so the reveal is one click from typing" 1 \
    [winfo exists $ROWS.ed_tag.add.e]
check "its button leaves the rail, which stays for the facet it still offers" {0 1} \
    [list [winfo exists $BODY.rail.b_tag] [winfo exists $BODY.rail.b_weight]]

# An editor open while the owner fills the facet to its cap from outside. The cap has
# to reach the editor that is already standing, not only the affordance that opens
# one: an editor a value cannot leave would take what is typed into it and drop it.
$bar set_values tag {urgent blocked}
update
check "an editor open when the model reaches the cap is closed, not left to eat the next value" \
    0 [winfo exists $ROWS.ed_tag.add]
check "and the values the owner set are chipped" {urgent blocked} [$bar values tag]
check "a facet joins its values in its own word, not the bar's" and \
    [$ROWS.ed_tag.or1 cget -text]

# The third way to an editor: begin_add stands in for the affordance, and at the cap
# that affordance is not drawn, so this must not draw one either.
set n [llength $::events]
$bar begin_add tag
update
check "begin_add on a facet at its cap opens no editor, so no value can be typed and lost" \
    0 [winfo exists $ROWS.ed_tag.add]
check "the model is untouched" {urgent blocked} [$bar values tag]
check "and nothing is published" $n [llength $::events]

$ROWS.ed_tag.c1.x invoke
update
check "with a value deleted the facet is below its cap again" {urgent} [$bar values tag]
check "and its affordance is back, in its own word" "+ and" [$ROWS.ed_tag.add cget -text]

# ---- the facet the owner fills and the user cannot ------------------------

$bar set_model {colour {{dark red}} size 7 shape square tag {urgent blocked} origin post}
update
check "an editorless facet appears when the owner gives it a value" post \
    [$ROWS.ed_origin.c0.t cget -text]
check "with no add affordance: its values are the owner's to set" 0 \
    [winfo exists $ROWS.ed_origin.add]
check "and its chip still deletes" 1 [winfo exists $ROWS.ed_origin.c0.x]
$ROWS.ed_origin.c0.x invoke
update
check "deleting its last value takes the row away again" 0 [winfo exists $ROWS.tag_origin]
check "and it is still not offered on the rail" 0 [winfo exists $BODY.rail.b_origin]

# ---- the control facet, and its two doors --------------------------------

check "a control facet's editor is the caller's, and the bar chips nothing there" \
    {1 0} [list [winfo exists $ROWS.ed_size.sb] [winfo exists $ROWS.ed_size.c0]]
check "a control editor is rebuilt from the facet's values" 7 $::sizevar

set ::sizevar 9
size_changed                      ;# what the stepper's -command does
update
check "an editor reports its change through report_values" 9 [$bar values size]
check "the owner hears it" 9 [dict get [lindex $::events end] size]
check "and the control that reported it is not rebuilt under the user's hand" \
    {1 9} [list [winfo exists $ROWS.ed_size.sb] $::sizevar]

$bar set_values size 12
update
check "the owner's own door redraws that editor, so the control shows what was set" \
    12 $::sizevar

refused "report_values on a chips facet is refused: its chips are the bar's drawing of its values" \
    {$bar report_values colour {{any pink}}} "*chips facet*"
check "so the chips can never be left showing what the model no longer holds" \
    {{dark red}} [$bar values colour]

# ---- a control facet reached from the rail, wound down to its floor -------
#
# A tail facet's row goes when its last value goes. Here the editor is what reports
# the last value gone, from inside its own command, so a row leaving on that report
# would destroy the control mid-callback: the one thing report_values exists to
# prevent, and a case that only appears when a control facet is also a tail facet.
$BODY.rail.b_weight invoke
update
check "the rail reveals a control facet's row and its editor" {1 1} \
    [list [winfo exists $ROWS.tag_weight] [winfo exists $ROWS.ed_weight.sb]]
set ::weightvar 5
weight_changed
update
check "the control applies a value" 5 [$bar values weight]
set ::weightvar 0
weight_changed                    ;# the floor: the editor reports itself empty
update
check "an editor that reports its last value gone keeps its row" 1 \
    [winfo exists $ROWS.tag_weight]
check "and is not destroyed from inside its own command" 1 \
    [winfo exists $ROWS.ed_weight.sb]
check "though the value really is gone" {} [$bar values weight]

# ---- the change callback: it may raise, and it may write back -------------
#
# A callback that normalises the model writes it straight back. A write that moves no
# value publishes nothing, so the bar does not go round in circles.
set ::normalised 0
proc normalise {model} {
    incr ::normalised
    $::bar set_values shape [dict get $model shape]   ;# the same values, back again
}
$bar configure -changecb normalise
$bar set_values shape {round}
check "a callback that writes the model back is not called again by its own write" \
    1 $::normalised

proc boom {model} { error "the host said no" }
$bar configure -changecb boom
refused "a callback that raises is not swallowed by the bar" \
    {$bar set_values shape {square}} "*the host said no*"
check "and the model it was called with is the model the bar holds" square \
    [$bar values shape]
check "with the chip already drawn, so the widget is consistent whatever the host does" \
    square [$ROWS.ed_shape.c0.t cget -text]
$bar configure -changecb on_change

# ---- collapse and expand -------------------------------------------------

$bar set_values weight 4
update
set before [$bar model]
set n [llength $::events]
$bar collapse
update
check "collapsing takes the editor rows away" {0 0} \
    [list [winfo exists $ROWS] [winfo exists $BODY.rail]]
check "an applied criterion stays visible as a chip: collapse summarizes, it never hides" \
    "dark red" [$BODY.strip.c_colour_0.t cget -text]
check "a control facet's value shows there too, through its formatter" \
    "at least 12" [$BODY.strip.c_size_0.t cget -text]
check "each applied facet keeps its tag in the summary" tag [$BODY.strip.tag_tag cget -text]
check "and a collapsed chip keeps its delete affordance" 1 \
    [winfo exists $BODY.strip.c_size_0.x]
check "collapsing moves no value" $before [$bar model]
check "and fires no change event" $n [llength $::events]

$bar expand
update
check "expanding restores the rows" {1 1 1} [list [winfo exists $ROWS.ed_colour.c0] \
    [winfo exists $ROWS.ed_size.sb] [winfo exists $ROWS.ed_tag.c0]]
check "collapse and expand round-trip the same model" $before [$bar model]

$bar collapse
update
$BODY.strip.c_size_0.x invoke
update
check "a chip deletes from the collapsed bar" {} [$bar values size]
check "the owner hears that too" {} [dict get [lindex $::events end] size]
check "and the emptied facet leaves the summary" 0 [winfo exists $BODY.strip.tag_size]

$bar expand
update
check "the control editor comes back at the value the collapsed delete left" 1 $::sizevar

# ---- the empty bar, without collapsing first ------------------------------
#
# set_model {} returns the bar to rest, and the expanded rows are where that has to
# be visible: a tail facet revealed earlier has no values now, so its row goes and
# its button comes back to the rail.
$bar begin_add tag
update
check "a revealed tail facet has a row before the reset" 1 [winfo exists $ROWS.tag_tag]
$bar set_model {}
update
check "set_model {} clears every value" \
    {colour {} size {} weight {} shape {} note {} tag {} origin {}} [$bar model]
check "the revealed tail facet's row goes with them" 0 [winfo exists $ROWS.tag_tag]
check "its button is back on the rail" 1 [winfo exists $BODY.rail.b_tag]
check "and the editor it had open is closed" 0 [winfo exists $ROWS.ed_tag.add.e]

# A row revealed and left empty must not outlive a collapse: its rail button is gone,
# so nothing on the bar could dismiss the row again.
$bar begin_add tag
update
$bar collapse
update
$bar expand
update
check "a tail facet revealed but never filled leaves no orphan row across a collapse" \
    {0 1} [list [winfo exists $ROWS.tag_tag] [winfo exists $BODY.rail.b_tag]]

$bar collapse
update
check "an empty set collapses to the add affordance" 1 [winfo exists $BODY.strip.add]
check "with no chips beside it" 0 [winfo exists $BODY.strip.c_colour_0]
check "the heading drops its count at zero" "Restrict to items that…" \
    [.f.head.hd cget -text]
$BODY.strip.add invoke
update
check "and that affordance opens the bar" {1 1} [list [$bar expanded] [winfo exists $ROWS]]

# ---- the contract's edges ------------------------------------------------

refused "a duplicate facet id is refused" \
    {$bar configure -facets {{id a} {id a}}} "*duplicate facet id*"
refused "an unknown descriptor key is refused" \
    {$bar configure -facets {{id a bogus 1}}} "*unknown descriptor key*"
refused "a facet descriptor that is not a dict is refused" \
    {$bar configure -facets {{id a conn}}} "*not a dict*"
refused "a mode that is neither chips nor control is refused" \
    {$bar configure -facets {{id a mode slider}}} "*neither chips nor control*"
refused "a control facet with no editor is refused: its value would be held and never shown" \
    {$bar configure -facets {{id a mode control}}} "*control facet needs an editor*"
refused "a max that is not a count is refused" \
    {$bar configure -facets {{id a max two}}} "*is not a count*"
refused "a tail that is not a true or false value is refused" \
    {$bar configure -facets {{id a tail maybe}}} "*not a true or false*"
refused "and so is such a dedupe, at the door and not later from inside a button" \
    {$bar configure -facets {{id a dedupe maybe}}} "*not a true or false*"
refused "an id that is not a plain word is refused" \
    {$bar configure -facets {{id a.b}}} "*plain word*"
refused "and so is one carrying a percent, which a binding script would swallow" \
    {$bar configure -facets {{id pct%W}}} "*plain word*"
refused "a model that would break a facet's cap is refused" \
    {$bar set_model {shape {round square}}} "*holds at most 1*"
refused "so is a set_values that would break it" \
    {$bar set_values shape {round square}} "*holds at most 1*"
refused "and a report_values that would break it" \
    {$bar report_values size {1 2}} "*holds at most 1*"
refused "a model that is not a dict is refused" \
    {$bar set_model colour} "*not a dict*"
refused "an index that is not one is refused, rather than quietly doing nothing" \
    {$bar remove_value_at colour foo} "*not a value index*"
refused "and one that names no value is refused, rather than garbling a list" \
    {$bar remove_value_at colour 99} "*no value at index 99*"
refused "the same at the other index door" \
    {$bar set_value_at colour 1.5 x} "*not a value index*"
refused "an unknown option is refused" {$bar configure -bogus 1} "*unknown option*"
refused "a countfmt that is not a format taking one count is refused at the door" \
    {$bar configure -countfmt "%d of %d"} "*not a format taking one count*"
refused "a misspelt style role is refused, as a misspelt descriptor key is" \
    {$bar configure -styles {chipp X.TFrame}} "*unknown style role*"
refused "a -styles that is not a dict is refused" \
    {$bar configure -styles notadict} "*dict of style role*"
refused "a misspelt gap role is refused" {$bar configure -gaps {chpi 4}} "*unknown gap*"
refused "a gap that is not a count of pixels is refused" \
    {$bar configure -gaps {chip huge}} "*count of pixels*"
refused "a delside that is neither end is refused" \
    {$bar configure -delside middle} "*neither left nor right*"
refused "cget refuses an unknown option the same way, not with a dict error" \
    {$bar cget -bogus} "*unknown option*"
refused "an odd argument count is refused, rather than setting an empty value" \
    {$bar configure -heading X -countfmt} "*option/value pairs*"
refused "an unknown facet in the model is refused" \
    {$bar set_model {nosuch x}} "*no such facet*"
refused "and reading one is refused too, rather than answering 'nothing applied'" \
    {$bar values nosuch} "*no such facet*"
refused "a second setup is refused" {$bar setup .f} "*already run*"
refused "an internal method is no part of the contract" \
    {$bar refresh} "*unknown method*"
refused "add_value on a control facet is refused, the mirror of report_values on a chips one" \
    {$bar add_value size 3} "*control facet*"

# The rail withholds an editorless tail facet because a row with nothing to type into
# is one nothing on the bar can dismiss. begin_add stands in for the rail's button, so
# it must withhold it too.
set n [llength $::events]
$bar begin_add origin
update
check "begin_add on a facet with no editor reveals no row" 0 [winfo exists $ROWS.tag_origin]
check "and publishes nothing" $n [llength $::events]

refused "a configure with one bad option raises on it" \
    {$bar configure -heading "changed" -facets {{id a} {id a}}} "*duplicate*"
check "and applies none of the good options that came with it" \
    "Restrict to items that…" [$bar cget -heading]

# A rolled-back configure has to put back the model too, values and all. A facet list
# rewrites the model on its way in, so an option list that rolls back while the model
# stays rewritten would drop the values of a facet the rollback then restores - and
# drop them without a word, because a configure publishes nothing.
$bar set_model {colour {{any red} {any blue}} shape round tag {urgent}}
update
set full [$bar model]
refused "an option that only fails when the bar draws takes the whole configure down with it" \
    {$bar configure -heading "boom" \
        -facets {{id colour conn "is" format colour_chip editor text_editor} \
                 {id z conn "z" mode control editor boom_editor}}} "*the editor blew up*"
check "the facets it had are the facets it has" \
    {colour size weight shape note tag origin} [dict keys [$bar model]]
check "and the values they held are still held: the rollback puts the model back too" \
    $full [$bar model]
check "and so is the heading" "Restrict to items that…" [$bar cget -heading]
no_error "and the bar still draws" {$bar collapse; $bar expand; update}

# A facet list is a route into the model, so it meets the model's cap.
refused "a facet list that would cap a facet below what it already holds is refused" \
    {$bar configure -facets [lreplace $FACETS 0 0 \
        {id colour conn "is" format colour_chip editor text_editor max 1}]} \
    "*holds at most 1*"
check "and the model it would have broken is untouched" $full [$bar model]

# A formatter that meets a value it cannot print. The value goes back where it came
# from, the owner is not told of a change that did not happen, and the bar still draws
# - rather than be left holding a value that raises on every later draw.
$bar configure -facets [lreplace $FACETS 4 4 \
    {id note conn "notes" format picky_chip editor text_editor dedupe 0 max 3}]
update
set n [llength $::events]
set was [$bar model]
refused "a value the formatter cannot print is refused by the door that took it" \
    {$bar add_value note unprintable} "*cannot print that*"
check "the value is not in the model" $was [$bar model]
check "the owner is not told of a change that did not happen" $n [llength $::events]
no_error "and the bar still draws, rather than raise on every later draw" \
    {$bar collapse; $bar expand; update}
no_error "a value it can print still goes in" {$bar add_value note plain}
check "and lands" {plain} [$bar values note]
$bar configure -facets $FACETS
$bar set_model $full
update

check "one argument reads an option rather than clearing it" \
    "Restrict to items that…" [$bar configure -heading]
check "no argument reads them all" or [dict get [$bar configure] orword]

# ---- the styles, and a theme change --------------------------------------
#
# The bar's own two style names are the bar's: it dresses them, and dresses them
# again on a theme change, because a ttk style's configuration belongs to the theme it
# was made under and the chips would otherwise go flat and invisible. A style the host
# names is the host's, in every theme, and the bar never reaches into it.
check "a style the bar does not name, the bar does not dress" {} \
    [ttk::style configure Host.TFrame]
ttk::style theme use clam
update
check "the fallback dress follows a theme change, where a style's configuration does not" \
    solid [dict get [ttk::style configure FacetChip.TFrame] -relief]
check "and the host's own style is still the host's, untouched in the new theme" {} \
    [ttk::style configure Host.TFrame]

# ---- the geometry a style and the gaps own -------------------------------
#
# The chip's padding rides its style: a widget's own padding would beat the style's,
# so the bar sets none of its own and reads the style's instead.
pack [ttk::frame .geo -width 600 -height 120] -fill x
pack propagate .geo 0
ttk::style configure Host.TFrame -relief solid -borderwidth 1 -padding {2 1}
set bar7 [::facetbar::FacetBar new]
$bar7 configure -heading "" \
    -facets {{id w conn "reads" format plain_chip chipstyle Host.TFrame}}
$bar7 setup .geo
$bar7 set_model {w {one two}}
update
update idletasks
set G .geo.body.rows.ed_w
set tight [winfo reqwidth $G.c0]
ttk::style configure Host.TFrame -padding {40 20}
$bar7 set_model {}
$bar7 set_model {w {one two}}
update
update idletasks
check "a chip's padding comes from its style, so a host can set it" 1 \
    [expr {[winfo reqwidth $G.c0] > $tight + 60}]

# The gap the bar leaves between two chips is -gaps, not a number in the source.
ttk::style configure Host.TFrame -padding {2 1}
$bar7 configure -gaps {chip 40}
$bar7 set_model {}
$bar7 set_model {w {one two}}
update
update idletasks
check "the gap the bar leaves beside a chip comes from -gaps" 40 \
    [expr {[winfo x $G.or1] - ([winfo x $G.c0] + [winfo reqwidth $G.c0])}]

# ---- two changes in one turn of the event loop ----------------------------
#
# A host that applies two criteria in one script gives the bar two renders before the
# event loop turns. Both facets' chips must be laid out at the size they really are,
# and not at the 1x1 they have until the geometry managers reach them - which is what
# a lay left standing where the first render put it would measure.
pack [ttk::frame .turn] -fill x
set bar8 [::facetbar::FacetBar new]
$bar8 configure -heading "" -facets {
    {id one conn "is" format plain_chip editor text_editor}
    {id two conn "is" format plain_chip editor text_editor}
}
$bar8 setup .turn
$bar8 set_values one {first}
$bar8 set_values two {second}
update
update idletasks
set T1 .turn.body.rows.ed_one.c0
set T2 .turn.body.rows.ed_two.c0
check "a chip drawn in the same turn as another facet's is laid out at its real size" \
    {1 1} [list [expr {[winfo width $T2] > 5}] [expr {[winfo height $T2] > 5}]]
check "and the first one is too" {1 1} \
    [list [expr {[winfo width $T1] > 5}] [expr {[winfo height $T1] > 5}]]

# ---- the options, at values that are not their defaults -------------------
#
# Every word the bar draws comes from an option. Each is set here to something no
# default could be mistaken for, so a hard-coded word could not pass for one.
pack [ttk::frame .opts] -fill x
set bar6 [::facetbar::FacetBar new]
$bar6 configure -heading "H" -countfmt "(%d)" -orword "plus" -addtext "new" \
    -ortext "another" -deltext "Remove" -raillabel "also" -emptytext "start here" \
    -expandtext "more" -collapsetext "less" -facets {
        {id a conn "is" format plain_chip editor text_editor}
        {id c conn "lists" format plain_chip orword ""}
        {id b tail 1 editor text_editor}
    }
$bar6 setup .opts
$bar6 set_model {a {x y} c {p q}}
update
set A .opts.body.rows.ed_a
check "-orword is the word drawn between two chips" plus [$A.or1 cget -text]
check "-deltext is the chip's delete affordance" Remove [$A.c0.x cget -text]
check "-ortext is the affordance on a facet that holds a value" another [$A.add cget -text]
check "-countfmt sums the applied values into the heading" "H   (4)" \
    [.opts.head.hd cget -text]
check "-collapsetext is the disclosure while the bar is expanded" less \
    [.opts.head.tog cget -text]
check "-raillabel leads the add rail" also [.opts.body.rail.label cget -text]
check "a facet whose connector is empty is drawn without one, and without its gaps" \
    0 [winfo exists .opts.body.rows.ed_c.or1]
$bar6 collapse
update
check "-expandtext is the disclosure while the bar is collapsed" more \
    [.opts.head.tog cget -text]
$bar6 set_model {}
update
check "-emptytext is the affordance of a collapsed bar with nothing applied" \
    "start here" [.opts.body.strip.add cget -text]
$bar6 expand
update
check "-addtext is the affordance on a facet with no values" new [$A.add cget -text]

# ---- the disclosure, which a bar need not have ---------------------------

$bar6 configure -disclosure 0
update
check "-disclosure 0 takes the disclosure button away" "" [winfo manager .opts.head.tog]
$bar6 configure -heading ""
update
check "and with no heading either the head line goes, leaving the rows and nothing above them" \
    [list {} grid] [list [winfo manager .opts.head] [winfo manager .opts.body.rows.ed_a]]
$bar6 collapse
update
check "a bar with no head line collapses to a bare strip of chips" 1 \
    [winfo exists .opts.body.strip]
$bar6 expand
$bar6 configure -disclosure 1 -heading "H"
update
check "and the disclosure comes back when it is asked for" pack [winfo manager .opts.head.tog]
refused "a disclosure that is neither true nor false is refused" \
    {$bar6 configure -disclosure maybe} "*not a true or false*"

# ---- a build that fails hands the frame back -----------------------------

pack [ttk::frame .retry] -fill x
set barR [::facetbar::FacetBar new]
$barR configure -facets {{id z conn "z" mode control editor boom_editor}}
refused "a setup whose build raises does not swallow the frame" \
    {$barR setup .retry} "*the editor blew up*"
$barR configure -facets {{id w conn "reads" format plain_chip}}
no_error "and the bar can be set up again, rather than refuse every retry as a second setup" \
    {$barR setup .retry}
$barR set_model {w {ok}}
update
check "and it draws" ok [.retry.body.rows.ed_w.c0.t cget -text]

# ---- values are lists, and compare as lists ------------------------------

$bar set_model {tag {urgent}}
update
set n [llength $::events]
$bar set_values tag "urgent "
check "a write that moves no value publishes nothing, whatever its spacing" \
    $n [llength $::events]
check "and the model holds what it held" {urgent} [$bar values tag]

# ---- wrapping, in a frame that pins its width ----------------------------

pack [ttk::frame .narrow -width 320 -height 200] -fill both
pack propagate .narrow 0
set bar2 [::facetbar::FacetBar new]
$bar2 configure -heading "" -facets \
    {{id word conn "reads" format plain_chip chipstyle Host.TFrame}}
$bar2 setup .narrow
$bar2 set_model {word {"a first long value" "a second long value" "a third long value"}}
update
update idletasks
set W .narrow.body.rows.ed_word
check "a facet's chips take the style its descriptor names" Host.TFrame [$W.c0 cget -style]
check "the first chip sits on the first line" 0 [winfo y $W.c0]
check "a chip that will not fit wraps onto the next line" 1 \
    [expr {[winfo y $W.c2] > [winfo y $W.c0]}]
check "and no chip is left hanging off the right edge" 1 \
    [expr {[winfo x $W.c2] + [winfo reqwidth $W.c2] <= [winfo width $W]}]

# ---- and the width the bar asks of a host that does not pin it ------------
#
# The header's claim, tested where it can fail: in a propagating frame, a chip wider
# than the bar asks for its own width and the window grows to it. That is the
# documented behaviour, not a wrap, and a host that cannot afford it pins the frame,
# as .narrow above does.
pack [ttk::frame .wide] -fill x
set bar3 [::facetbar::FacetBar new]
$bar3 configure -heading "" -facets {{id word conn "reads" format plain_chip}}
$bar3 setup .wide
$bar3 set_model {word {"one value so long that no sane bar could ever hold it on a line"}}
update
update idletasks
set L .wide.body.rows.ed_word
check "a chip wider than the bar asks for its own width" 1 \
    [expr {[winfo reqwidth $L] >= [winfo reqwidth $L.c0]}]
check "and a propagating host grows to it, which is why a host that cannot pins the frame" \
    1 [expr {[winfo reqwidth .wide] >= [winfo reqwidth $L.c0]}]

# ---- the lifecycle -------------------------------------------------------

refused "setup on a window that does not exist is refused" \
    {[::facetbar::FacetBar new] setup .no.such.frame} "*no such window*"

pack [ttk::frame .life] -fill x
set bar4 [::facetbar::FacetBar new]
$bar4 configure -facets {{id word conn "reads" format plain_chip}}
$bar4 setup .life
$bar4 set_model {word {alpha}}
update
check "the bar built its widgets into the host's frame" 1 [winfo exists .life.body]
$bar4 destroy
update
check "destroying the bar takes its widgets, whose commands name a dead object" {0 0} \
    [list [winfo exists .life.head] [winfo exists .life.body]]
check "and leaves the frame, which is the host's" 1 [winfo exists .life]

pack [ttk::frame .life2] -fill x
set bar5 [::facetbar::FacetBar new]
$bar5 configure -facets {{id word conn "reads" format plain_chip editor text_editor}}
$bar5 setup .life2
$bar5 set_model {word {alpha}}
update
destroy .life2
# Every method of the contract but `setup`, which refuses a second call by design.
no_error "a bar whose frame was destroyed under it goes inert: every method still answers" {
    $bar5 model
    $bar5 values word
    $bar5 set_model {word {alpha beta}}
    $bar5 set_values word {beta}
    $bar5 add_value word delta
    $bar5 set_value_at word 0 epsilon
    $bar5 remove_value_at word 0
    $bar5 begin_add word
    $bar5 cancel_add word
    $bar5 collapse
    $bar5 expand
    $bar5 toggle
    $bar5 expanded
    $bar5 configure -heading "after"
    $bar5 cget -heading
}
check "and still keeps its model through all of it" {delta} [$bar5 values word]
no_error "and destroys cleanly with no frame left to clear" {$bar5 destroy}

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
