#!/usr/bin/env wish9.0
# facetbar is a portable widget, so this test invents a host for it out of
# nothing: a colour facet whose chips carry a per-value control, a size facet
# edited by one bespoke stepper, a weight facet that is a stepper reached from the
# add rail and reports itself empty at its floor, a shape facet that may hold only
# one value, a note facet where the same value twice is two criteria, a tag facet
# that joins its values with "and", and an origin facet the owner fills and the
# user cannot type into. The test sources the module and no other file, and drives
# the bar through the widgets the bar itself built - the chips' delete buttons, the
# add rail, the inline editors - so a green run says the pattern holds for a host
# the module has never seen.
#
# It also holds the module to what its header promises, at the places where such a
# promise is easiest to make and quietly break: the caps (including the third way
# in, begin_add), the editor that reports itself empty from inside its own command,
# the lifecycle in both teardown orders, the style fallback across a theme change,
# the width the bar asks of a master that does not pin it, and every option at a
# value no default could be mistaken for, so a hard-coded "or" could not pass.

package require Tcl 8.6-
package require Tk 8.6-

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add $ROOT
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

proc on_change {model} { lappend ::events $model }
set ::events {}
set FACETS {
    {id colour conn "is"        format colour_chip editor text_editor chipctl colour_shade}
    {id size   conn "counts"    format size_chip   editor size_editor mode control max 1}
    {id weight conn "weighs"    format weight_chip editor weight_editor mode control max 1 tail 1}
    {id shape  conn "is shaped" editor text_editor max 1}
    {id note   conn "notes"     editor text_editor dedupe 0}
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
check "a host that styles nothing still gets a chip it can see" solid \
    [dict get [ttk::style configure FacetChip.TFrame] -relief]
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
check "the heading counts the applied facets" "Restrict to items that…   1 active" \
    [.f.head.hd cget -text]
check "set_model fires no change event: the owner already knows" 0 [llength $::events]

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

# ---- a facet where a repeat is a second value ----------------------------

$ROWS.ed_note.add invoke
update
type_into $ROWS.ed_note.add note fragile
type_into $ROWS.ed_note.add note fragile
check "a facet that asks for repeats takes the same value twice" {fragile fragile} \
    [$bar values note]
check "and chips them both" 1 [winfo exists $ROWS.ed_note.c1]
event generate $ROWS.ed_note.add.e <Escape>
update

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

event generate $ROWS.ed_tag.add.e <Escape>
update
check "abandoning the add that revealed it puts the facet back on the rail" {0 1} \
    [list [winfo exists $ROWS.tag_tag] [winfo exists $BODY.rail.b_tag]]

$BODY.rail.b_tag invoke
update
type_into $ROWS.ed_tag.add tag urgent
check "a revealed facet's committed value renders as a chip" urgent \
    [$ROWS.ed_tag.c0.t cget -text]
check "and the row stays now that it carries one" 1 [winfo exists $ROWS.tag_tag]
type_into $ROWS.ed_tag.add tag blocked
check "a facet joins its values in its own word, not the bar's" and \
    [$ROWS.ed_tag.or1 cget -text]
check "at its cap the facet offers no way to add another" 0 [winfo exists $ROWS.ed_tag.add]
check "and holds exactly the values it is allowed" {urgent blocked} [$bar values tag]

# The third way to an editor. begin_add stands in for the affordance, and at the cap
# that affordance is not drawn - so this must not draw one either, or a user would
# type a value into an editor the model has no room for and watch it vanish on Enter.
set n [llength $::events]
$bar begin_add tag
update
check "begin_add on a facet at its cap opens no editor, so no value can be typed and lost" \
    0 [winfo exists $ROWS.ed_tag.add]
check "the model is untouched" {urgent blocked} [$bar values tag]
check "and nothing is published" $n [llength $::events]

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
refused "a mode that is neither chips nor control is refused" \
    {$bar configure -facets {{id a mode slider}}} "*neither chips nor control*"
refused "a control facet with no editor is refused: its value would be applied and never shown" \
    {$bar configure -facets {{id a mode control}}} "*control facet needs an editor*"
refused "a max that is not a count is refused" \
    {$bar configure -facets {{id a max two}}} "*is not a count*"
refused "an id that is not a plain word is refused" \
    {$bar configure -facets {{id a.b}}} "*plain word*"
refused "and so is one carrying a percent, which a binding script would swallow" \
    {$bar configure -facets {{id pct%W}}} "*plain word*"
refused "a model that would break a facet's cap is refused" \
    {$bar set_model {shape {round square}}} "*holds at most 1*"
refused "so is a set_values that would break it" \
    {$bar set_values shape {round square}} "*holds at most 1*"
refused "and a report_values that would break it" \
    {$bar report_values shape {round square}} "*holds at most 1*"
refused "an unknown option is refused" {$bar configure -bogus 1} "*unknown option*"
refused "a misspelt style role is refused, as a misspelt descriptor key is" \
    {$bar configure -styles {chipp X.TFrame}} "*unknown style role*"
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

refused "a configure with one bad option raises on it" \
    {$bar configure -heading "changed" -facets {{id a} {id a}}} "*duplicate*"
check "and applies none of the good options that came with it" \
    "Restrict to items that…" [$bar cget -heading]
check "one argument reads an option rather than clearing it" \
    "Restrict to items that…" [$bar configure -heading]
check "no argument reads them all" or [dict get [$bar configure] orword]
check "the facets survived every refusal" {colour size weight shape note tag origin} \
    [dict keys [$bar model]]

# ---- the styles, and a theme change --------------------------------------

ttk::style configure FacetChip.TFrame -relief flat -borderwidth 3
$bar configure -heading "Restrict to items that…"
update
check "a host's own dress of the default chip style is not stamped over" {flat 3} \
    [list [ttk::style lookup FacetChip.TFrame -relief] \
          [ttk::style lookup FacetChip.TFrame -borderwidth]]

# A ttk style's configuration belongs to the theme it was made under, so the chips
# would go flat and invisible on a theme change if the dress were laid only once.
ttk::style theme use clam
update
check "the fallback dress follows a theme change, where a style's configuration does not" \
    solid [dict get [ttk::style configure FacetChip.TFrame] -relief]

# ---- a facet dropped, and put back ---------------------------------------

$bar begin_add tag
update
check "the tail facet is revealed again" 1 [winfo exists $ROWS.tag_tag]
$bar configure -facets [lrange $FACETS 0 3]
update
check "dropping a facet takes its row" 0 [winfo exists $ROWS.tag_tag]
check "and its key leaves the model" {colour size weight shape} [dict keys [$bar model]]
$bar configure -facets $FACETS
update
check "putting it back puts it back on the rail, not in the row it once held" {0 1} \
    [list [winfo exists $ROWS.tag_tag] [winfo exists $BODY.rail.b_tag]]

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
check "-countfmt counts the applied facets into the heading" "H   (2)" \
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

# ---- wrapping, in a frame that pins its width ----------------------------

pack [ttk::frame .narrow -width 320 -height 200] -fill both
pack propagate .narrow 0
set bar2 [::facetbar::FacetBar new]
$bar2 configure -heading "" -facets \
    {{id word conn "reads" format plain_chip chipstyle Word.TFrame}}
$bar2 setup .narrow
$bar2 set_model {word {"a first long value" "a second long value" "a third long value"}}
update
update idletasks
set W .narrow.body.rows.ed_word
check "a facet's chips take the style its descriptor names" Word.TFrame [$W.c0 cget -style]
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
    $bar5 report_values word {beta gamma}
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
check "and still keeps its model through all of it" {gamma delta} [$bar5 values word]
no_error "and destroys cleanly with no frame left to clear" {$bar5 destroy}

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
