#!/usr/bin/env wish
# The builder, driven through the widgets it builds: the chips' delete buttons, the
# add rail, the inline editors, the disclosure. The facets here are colour, size,
# weight, shape, note, tag and origin - a chip list with a per-value control, two
# steppers, a single-valued facet, one that takes repeats up to a cap, one revealed
# from the rail, and one only the owner can fill - and, on a second bar, facets
# with operator vocabularies, for the criterion ids, the ops and the fragment.

package require Tcl 8.6-
package require Tk 8.6-

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require querybuilder

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
# Readers over the fragment, so a check names the one thing it is about.
proc crits {frag} { return [dict get $frag criteria] }
proc vals_of {frag kind} {
    set out [list]
    foreach c [dict get $frag criteria] {
        if {[dict get $c kind] eq $kind} { lappend out [dict get $c value] }
    }
    return $out
}
proc crit_of {bar kind} {
    foreach c [dict get [$bar fragment] criteria] {
        if {[dict get $c kind] eq $kind} { return $c }
    }
    return {}
}

# ---- the invented host ---------------------------------------------------
#
# colour: values are {shade name} pairs, so the chip's per-value control (a shade
# cycler) has something to edit, and two chips can print differently from one name.
# Every formatter takes the criterion dict, as the module hands it.
proc colour_chip {crit} {
    lassign [dict get $crit value] shade name
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
# Both talk back through report_values, the door that leaves the reporter alone -
# and a quiet door, so the host publishes when it wants the change heard.
proc size_chip {crit}   { return "at least [dict get $crit value]" }
proc weight_chip {crit} { return "over [dict get $crit value] kg" }
proc size_editor {parent initial commit cancel} {
    set ::sizevar [expr {[dict size $initial] ? [dict get $initial value] : 1}]
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
proc weight_editor {parent initial commit cancel} {
    set ::weightvar [expr {[dict size $initial] ? [dict get $initial value] : 0}]
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

# The chip facets' add editor, under the module's protocol: it packs into $parent,
# commits through the commit prefix on Return, and leaves Escape entirely to the
# builder's injected bindtag - the protocol's promise is that no editor code is
# needed for it. The kind rides in the descriptor's prefix, since the protocol
# passes none. An op set in ::addop($id) goes with the commit; absent, the commit
# omits it. The focus is forced because Tk hands a key event to the focus widget
# and no window manager runs on the test display, so the toplevel never takes the
# X focus and a plain `focus` would leave the synthetic Return below undelivered.
proc text_editor {id parent initial commit cancel} {
    set ::addtext($id) ""
    set ::editcb($id) [list $commit $cancel]
    ttk::entry $parent.e -width 12 -textvariable ::addtext($id)
    pack $parent.e -side left
    bind $parent.e <Return> [list commit_text $id]
    focus -force $parent.e
}
proc commit_text {id} {
    lassign $::editcb($id) commit cancel
    set v [string trim $::addtext($id)]
    if {$v eq ""} { {*}$cancel; return }
    if {$id eq "colour"} { set v [list any $v] }
    if {[info exists ::addop($id)] && $::addop($id) ne ""} {
        {*}$commit $v $::addop($id)
    } else {
        {*}$commit $v
    }
}
# Type a value into a facet's open editor and press Return.
proc type_into {area id value} {
    set ::addtext($id) $value
    event generate $area.e <Return>
    update
}
proc plain_chip {crit} { return [dict get $crit value] }
proc boom_editor {parent initial commit cancel} { error "the editor blew up" }
# A formatter that meets a value it cannot print.
proc picky_chip {crit} {
    set v [dict get $crit value]
    if {$v eq "unprintable"} { error "cannot print that" }
    return $v
}

proc on_change {frag} { lappend ::events $frag }
set ::events {}
set FACETS {
    {kind colour conn "is"        format colour_chip editor {text_editor colour} chipctl colour_shade}
    {kind size   conn "counts"    format size_chip   editor size_editor mode control max 1}
    {kind weight conn "weighs"    format weight_chip editor weight_editor mode control max 1 tail 1}
    {kind shape  conn "is shaped" editor {text_editor shape} max 1}
    {kind note   conn "notes"     editor {text_editor note} dedupe 0 max 3 chipctl no_ctl}
    {kind tag    conn "is tagged" editor {text_editor tag} tail 1 max 2 orword "and" ortext "+ and"}
    {kind origin conn "came from" tail 1}
}

# ---- the bar -------------------------------------------------------------

pack [ttk::frame .f] -fill both -expand 1
set bar [::querybuilder::QueryBuilder new]
$bar configure -heading "Restrict to items that…" -changecommand on_change -facets $FACETS
$bar setup .f
update

set BODY .f.body
set ROWS $BODY.rows

check "the model carries every facet, applied or not" \
    {colour {} size {} weight {} shape {} note {} tag {} origin {}} [$bar model]
check "the fragment's criteria key is present while nothing is applied" \
    {criteria {}} [$bar fragment]
check "the bar dresses the chip style it ships with, so an unstyled host can see a chip" \
    solid [dict get [ttk::style configure QBChip.TFrame] -relief]
check "kinds answers the declared kind names in declaration order" \
    {colour size weight shape note tag origin} [$bar kinds]
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
check "set_model fires no change event: every programmatic door is quiet" \
    0 [llength $::events]

# ---- the count sums the values across the countable facets ----------------
#
# By default every facet counts, and the count is the number of values applied,
# not the number of facets holding one: colour alone, with its two values, reads
# two. A -countables subset counts only the facets it names, so a facet left out
# of it adds nothing however many values it holds. A kind no descriptor declares
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
check "the delete is user action: it tells the owner the fragment, ids and all" \
    {criteria {{id 0 kind colour op {} value {any red}}}} [lindex $::events end]

# ---- the per-value control -----------------------------------------------

set n [llength $::events]
$ROWS.ed_colour.c0.lead invoke
update
check "a chip's own control edits that value in place" {{dark red}} [$bar values colour]
check "and the chip reruns the caller's formatter" "dark red" \
    [$ROWS.ed_colour.c0.t cget -text]
check "and its set_value_at door is quiet: the control's host decides when to publish" \
    $n [llength $::events]

$bar set_value_at colour 0 {dark red}
check "rewriting a value with the value it already holds moves nothing" \
    {{dark red}} [$bar values colour]
check "the criterion's id stands through the in-place edits" \
    0 [dict get [crit_of $bar colour] id]

# ---- the inline add, and the editor that stays open -----------------------

$ROWS.ed_colour.add invoke
update
check "the add affordance opens into the facet's own editor" 1 \
    [winfo exists $ROWS.ed_colour.add.e]
type_into $ROWS.ed_colour.add colour green
check "committing the editor appends the value" {{dark red} {any green}} \
    [$bar values colour]
check "the commit is user action: the owner hears the fragment" \
    {{dark red} {any green}} [vals_of [lindex $::events end] colour]
check "and the editor stays open, so a second value can be typed straight after" 1 \
    [winfo exists $ROWS.ed_colour.add.e]

set n [llength $::events]
type_into $ROWS.ed_colour.add colour green
check "a repeat of an applied value is no second criterion" {{dark red} {any green}} \
    [$bar values colour]
check "and raises no change event" $n [llength $::events]

# The editor binds no Escape of its own: the builder's bindtag, injected into
# every widget under the add frame after the editor returned, is what answers.
event generate $ROWS.ed_colour.add.e <Escape>
update
check "Escape cancels through the builder's injected bindtag, with no editor code" \
    "+ or" [$ROWS.ed_colour.add cget -text]
check "and changes no value" {{dark red} {any green}} [$bar values colour]

# ---- a facet where a repeat is a second value, up to a cap of three -------

$ROWS.ed_note.add invoke
update
type_into $ROWS.ed_note.add note fragile
type_into $ROWS.ed_note.add note fragile
check "a facet that asks for repeats takes the same value twice" {fragile fragile} \
    [$bar values note]
check "and chips them both" 1 [winfo exists $ROWS.ed_note.c1]
check "and each repeat carries an id of its own" 1 \
    [expr {[llength [lsort -unique [lmap c [crits [$bar fragment]] {dict get $c id}]]] \
           == [llength [crits [$bar fragment]]]}]
check "a per-value control that draws nothing leaves a plain chip" 0 \
    [winfo exists $ROWS.ed_note.c0.lead]
type_into $ROWS.ed_note.add note heavy
check "a third value reaches the facet's cap" {fragile fragile heavy} [$bar values note]
check "which closes the editor and takes the affordance away" 0 \
    [winfo exists $ROWS.ed_note.add]
set n [llength $::events]
refused "add_criterion past the cap refuses outright: a call that must return an id cannot quietly add nothing" \
    {$bar add_criterion note extra} "*holds at most*"
check "and the cap holds" {fragile fragile heavy} [$bar values note]
check "and nothing is published" $n [llength $::events]

# ---- cardinality: a facet that can hold only one value --------------------

$ROWS.ed_shape.add invoke
update
type_into $ROWS.ed_shape.add shape round
check "a single-valued facet takes its first value" round [$bar values shape]
check "it closes its editor, because there is nothing more it can take" 0 \
    [winfo exists $ROWS.ed_shape.add.e]
check "and its affordance offers no join, because a commit there replaces" "+" \
    [$ROWS.ed_shape.add cget -text]
set sid [dict get [crit_of $bar shape] id]
$ROWS.ed_shape.add invoke
update
type_into $ROWS.ed_shape.add shape square
check "a second value replaces it rather than joining it" square [$bar values shape]
check "so the row never grows a second chip" 0 [winfo exists $ROWS.ed_shape.c1]
check "and the replace is an edit: the criterion's id survives it" \
    $sid [dict get [crit_of $bar shape] id]

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
set n [llength $::events]
$bar set_values tag {urgent blocked}
update
check "an editor open when the model reaches the cap is closed, not left to eat the next value" \
    0 [winfo exists $ROWS.ed_tag.add]
check "and the values the owner set are chipped" {urgent blocked} [$bar values tag]
check "quietly: set_values is the owner's door, and the owner already knows" \
    $n [llength $::events]
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
check "a control editor is rebuilt from the criterion it is handed" 7 $::sizevar

set n [llength $::events]
set ::sizevar 9
size_changed                      ;# what the stepper's -command does
update
check "an editor reports its change through report_values" 9 [$bar values size]
check "and the report is quiet, like every programmatic door" $n [llength $::events]
check "and the control that reported it is not rebuilt under the user's hand" \
    {1 9} [list [winfo exists $ROWS.ed_size.sb] $::sizevar]

$bar publish
check "publish fires the change callback exactly once" \
    [expr {$n + 1}] [llength $::events]
check "with the current fragment, the reported value in it" \
    {9} [vals_of [lindex $::events end] size]

$bar set_values size 12
update
check "the owner's own door redraws that editor, so the control shows what was set" \
    12 $::sizevar

refused "report_values on a chips facet is refused: its chips are the bar's drawing of its values" \
    {$bar report_values colour {{any pink}}} "*chips facet*"
check "so the chips can never be left showing what the model no longer holds" \
    {{dark red}} [$bar values colour]
refused "add_criterion on a control facet is refused, the mirror of that" \
    {$bar add_criterion size 3} "*control facet*"

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

# ---- the change callback: a write-back cannot loop, and a raise travels ----
#
# A callback that normalises the criteria writes them straight back through the
# quiet doors, so its own write cannot re-fire it. And publish, being a direct
# call, propagates a raising callback to its caller rather than swallow it.
set ::normalised 0
proc normalise {frag} {
    incr ::normalised
    $::bar set_values shape [$::bar values shape]   ;# the same values, back again
}
$bar configure -changecommand normalise
$bar publish
check "a callback that writes the criteria back is not called again by its own write" \
    1 $::normalised

proc boom {frag} { error "the host said no" }
$bar configure -changecommand boom
refused "a callback that raises is not swallowed by the bar" \
    {$bar publish} "*the host said no*"
$bar configure -changecommand on_change

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
check "collapsed is the inverse of expanded" {1 0} \
    [list [$bar collapsed] [$bar expanded]]

$bar expand
update
check "expanding restores the rows" {1 1 1} [list [winfo exists $ROWS.ed_colour.c0] \
    [winfo exists $ROWS.ed_size.sb] [winfo exists $ROWS.ed_tag.c0]]
check "collapse and expand round-trip the same model" $before [$bar model]

# The fold callback: the disclosure is user action and fires it with the new
# state appended; the programmatic doors stay quiet, by the one rule.
set ::folds {}
proc on_fold {state} { lappend ::folds $state }
$bar configure -foldcommand on_fold
$bar collapse
$bar expand
update
check "programmatic collapse and expand are quiet" {} $::folds
.f.head.tog invoke
update
check "the disclosure click fires -foldcommand with 1, collapsed" {1} $::folds
check "and the bar really is collapsed" 1 [$bar collapsed]
.f.head.tog invoke
update
check "and the click back out appends 0, expanded" {1 0} $::folds
$bar configure -foldcommand ""

$bar collapse
update
$BODY.strip.c_size_0.x invoke
update
check "a chip deletes from the collapsed bar" {} [$bar values size]
check "the owner hears that too" {} [vals_of [lindex $::events end] size]
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

refused "a duplicate kind is refused" \
    {$bar configure -facets {{kind a} {kind a}}} "*duplicate kind*"
refused "an unknown descriptor key is refused" \
    {$bar configure -facets {{kind a bogus 1}}} "*unknown descriptor key*"
refused "a facet descriptor that is not a dict is refused" \
    {$bar configure -facets {{kind a conn}}} "*not a dict*"
refused "a mode that is neither chips nor control is refused" \
    {$bar configure -facets {{kind a mode slider}}} "*neither chips nor control*"
refused "a control facet with no editor is refused: its value would be held and never shown" \
    {$bar configure -facets {{kind a mode control}}} "*control facet needs an editor*"
refused "a max that is not a count is refused" \
    {$bar configure -facets {{kind a max two}}} "*is not a count*"
refused "a tail that is not a true or false value is refused" \
    {$bar configure -facets {{kind a tail maybe}}} "*not a true or false*"
refused "and so is such a dedupe, at the door and not later from inside a button" \
    {$bar configure -facets {{kind a dedupe maybe}}} "*not a true or false*"
refused "a kind that is not a plain word is refused" \
    {$bar configure -facets {{kind a.b}}} "*plain word*"
refused "and so is one carrying a percent, which a binding script would swallow" \
    {$bar configure -facets {{kind pct%W}}} "*plain word*"
refused "an op vocabulary without a defaultop is refused: an omitted op would mean nothing" \
    {$bar configure -facets {{kind a op {x y}}}} "*no defaultop*"
refused "a defaultop outside the vocabulary is refused" \
    {$bar configure -facets {{kind a op {x y} defaultop z}}} "*not in its op vocabulary*"
refused "and a defaultop with no vocabulary defaults over nothing" \
    {$bar configure -facets {{kind a defaultop x}}} "*no op vocabulary*"
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
refused "an op on a facet with no vocabulary names nothing" \
    {$bar add_criterion colour {any pink} loud} "*names nothing*"
refused "an id no criterion carries is a bookkeeping bug, told" \
    {$bar remove_criterion 99999} "*no criterion has id*"
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
refused "a fragment that is not a dict is refused" \
    {$bar set_fragment notadict} "*not a dict*"
refused "a criterion with a kind no facet declares is refused" \
    {$bar set_fragment {criteria {{kind nosuch value x}}}} "*no such facet*"
refused "a criterion with no value is refused" \
    {$bar set_fragment {criteria {{kind colour}}}} "*criterion with no value*"
refused "a second setup is refused" {$bar setup .f} "*already run*"
refused "an internal method is no part of the contract" \
    {$bar refresh} "*unknown method*"

# The rail withholds an editorless tail facet because a row with nothing to type into
# is one nothing on the bar can dismiss. begin_add stands in for the rail's button, so
# it must withhold it too.
set n [llength $::events]
$bar begin_add origin
update
check "begin_add on a facet with no editor reveals no row" 0 [winfo exists $ROWS.tag_origin]
check "and publishes nothing" $n [llength $::events]

refused "a configure with one bad option raises on it" \
    {$bar configure -heading "changed" -facets {{kind a} {kind a}}} "*duplicate*"
check "and applies none of the good options that came with it" \
    "Restrict to items that…" [$bar cget -heading]

# A rolled-back configure has to put back the criteria too, values and all. A facet
# list rewrites them on its way in, so an option list that rolls back while they
# stay rewritten would drop the values of a facet the rollback then restores - and
# drop them without a word, because a configure publishes nothing.
$bar set_model {colour {{any red} {any blue}} shape round tag {urgent}}
update
set full [$bar model]
refused "an option that only fails when the bar draws takes the whole configure down with it" \
    {$bar configure -heading "boom" \
        -facets {{kind colour conn "is" format colour_chip editor {text_editor colour}} \
                 {kind z conn "z" mode control editor boom_editor}}} "*the editor blew up*"
check "the facets it had are the facets it has" \
    {colour size weight shape note tag origin} [dict keys [$bar model]]
check "and the values they held are still held: the rollback puts the model back too" \
    $full [$bar model]
check "and so is the heading" "Restrict to items that…" [$bar cget -heading]
no_error "and the bar still draws" {$bar collapse; $bar expand; update}

# A facet list is a route into the model, so it meets the model's cap.
refused "a facet list that would cap a facet below what it already holds is refused" \
    {$bar configure -facets [lreplace $FACETS 0 0 \
        {kind colour conn "is" format colour_chip editor {text_editor colour} max 1}]} \
    "*holds at most 1*"
check "and the model it would have broken is untouched" $full [$bar model]

# A formatter that meets a value it cannot print. The value goes back where it came
# from, the owner is not told of a change that did not happen, and the bar still draws
# - rather than be left holding a value that raises on every later draw.
$bar configure -facets [lreplace $FACETS 4 4 \
    {kind note conn "notes" format picky_chip editor {text_editor note} dedupe 0 max 3}]
update
set n [llength $::events]
set was [$bar model]
refused "a value the formatter cannot print is refused by the door that took it" \
    {$bar add_criterion note unprintable} "*cannot print that*"
check "the value is not in the model" $was [$bar model]
check "the owner is not told of a change that did not happen" $n [llength $::events]
no_error "and the bar still draws, rather than raise on every later draw" \
    {$bar collapse; $bar expand; update}
no_error "a value it can print still goes in" {$bar add_criterion note plain}
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
    solid [dict get [ttk::style configure QBChip.TFrame] -relief]
check "and the host's own style is still the host's, untouched in the new theme" {} \
    [ttk::style configure Host.TFrame]

# ---- the geometry a style and the gaps own -------------------------------
#
# The chip's padding rides its style: a widget's own padding would beat the style's,
# so the bar sets none of its own and reads the style's instead.
pack [ttk::frame .geo -width 600 -height 120] -fill x
pack propagate .geo 0
ttk::style configure Host.TFrame -relief solid -borderwidth 1 -padding {2 1}
set bar7 [::querybuilder::QueryBuilder new]
$bar7 configure -heading "" \
    -facets {{kind w conn "reads" format plain_chip chipstyle Host.TFrame}}
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
set bar8 [::querybuilder::QueryBuilder new]
$bar8 configure -heading "" -facets {
    {kind one conn "is" format plain_chip editor {text_editor one}}
    {kind two conn "is" format plain_chip editor {text_editor two}}
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
set bar6 [::querybuilder::QueryBuilder new]
$bar6 configure -heading "H" -countfmt "(%d)" -orword "plus" -addtext "new" \
    -ortext "another" -deltext "Remove" -raillabel "also" -emptytext "start here" \
    -expandtext "more" -collapsetext "less" -facets {
        {kind a conn "is" format plain_chip editor {text_editor a}}
        {kind c conn "lists" format plain_chip orword ""}
        {kind b tail 1 editor {text_editor b}}
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
set barR [::querybuilder::QueryBuilder new]
$barR configure -facets {{kind z conn "z" mode control editor boom_editor}}
refused "a setup whose build raises does not swallow the frame" \
    {$barR setup .retry} "*the editor blew up*"
$barR configure -facets {{kind w conn "reads" format plain_chip}}
no_error "and the bar can be set up again, rather than refuse every retry as a second setup" \
    {$barR setup .retry}
$barR set_model {w {ok}}
update
check "and it draws" ok [.retry.body.rows.ed_w.c0.t cget -text]

# ---- values are lists, and compare as lists ------------------------------

$bar set_model {tag {urgent}}
update
set tid [dict get [crit_of $bar tag] id]
$bar set_values tag "urgent "
check "a write that moves no value moves nothing, whatever its spacing" \
    {urgent} [$bar values tag]
check "and the criterion's id stands, since nothing was edited" \
    $tid [dict get [crit_of $bar tag] id]

# ---- criterion ids, ops, and the fragment ---------------------------------
#
# A criterion's id is assigned at add time and never changes: removal keeps the
# survivors' ids, an edit keeps the edited one, and a restored fragment keeps
# them all, with the generator allocating past the highest restored id so no
# fresh id can collide with one. The flag facet declares an operator vocabulary,
# so its criteria carry an op the formatter can draw; sole is single-valued with
# a vocabulary, so an edit can show an omitted op keeping the current one.
pack [ttk::frame .q] -fill x
set barQ [::querybuilder::QueryBuilder new]
proc flag_chip {crit} { return "[dict get $crit op]:[dict get $crit value]" }
# The entry sits two levels under the add frame, so Escape reaching it proves the
# builder's bindtag lands on every descendant, not the frame's direct children.
proc deep_editor {parent initial commit cancel} {
    ttk::frame $parent.box
    pack $parent.box
    ttk::entry $parent.box.e -width 8 -textvariable ::deeptext
    pack $parent.box.e
    focus -force $parent.box.e
}
set QFACETS {
    {kind word conn "reads" format plain_chip editor {text_editor word}}
    {kind flag conn "carries" op {any all} defaultop any format flag_chip
     editor deep_editor}
    {kind sole conn "is" op {is not} defaultop is max 1 editor {text_editor sole}}
}
set ::qevents {}
proc on_qchange {frag} { lappend ::qevents $frag }
$barQ configure -heading "" -changecommand on_qchange -facets $QFACETS
$barQ setup .q
update
set QROWS .q.body.rows

set idA [$barQ add_criterion word alpha]
set idB [$barQ add_criterion word beta]
set idC [$barQ add_criterion flag banner all]
check "add_criterion returns the new criterion's id, allocated monotonically" \
    {0 1 2} [list $idA $idB $idC]
set idD [$barQ add_criterion flag pennant]
check "an omitted op means the facet's defaultop" \
    any [dict get [lindex [crits [$barQ fragment]] end] op]
check "the fragment carries the criteria in declaration order then value order" \
    {{id 0 kind word op {} value alpha} {id 1 kind word op {} value beta}\
     {id 2 kind flag op all value banner} {id 3 kind flag op any value pennant}} \
    [crits [$barQ fragment]]
refused "an op outside the facet's vocabulary is refused at the call" \
    {$barQ add_criterion flag x sideways} "*is not one of*"

$barQ remove_criterion $idB
check "remove_criterion drops exactly the criterion the id names" \
    {alpha} [$barQ values word]
check "and never renumbers the survivors" \
    {0 2 3} [lmap c [crits [$barQ fragment]] {dict get $c id}]
check "a repeat on a deduping facet answers with the id the value already carries" \
    $idA [$barQ add_criterion word alpha]
check "and every one of those doors was quiet" {} $::qevents

$barQ publish
check "publish fires -changecommand exactly once" 1 [llength $::qevents]
check "with the current fragment appended" [$barQ fragment] [lindex $::qevents end]
set ::qevents {}

# The chip draws through the facet's format, which sees the whole criterion, op
# included; `format` answers the same label from outside, and falls back to the
# raw value on a facet that names no formatter.
update
check "the chip's text is the formatter's, op and all" \
    "all:banner" [$QROWS.ed_flag.c0.t cget -text]
check "format answers the label the chip carries" \
    "all:banner" [$barQ format [lindex [crits [$barQ fragment]] 1]]
set barF [::querybuilder::QueryBuilder new]
$barF configure -facets {{kind bare}}
check "format falls back to the raw value where the facet names no formatter" \
    "just this" [$barF format {id 0 kind bare op {} value "just this"}]
$barF destroy

# ---- set_fragment: restored ids honored, foreign keys ignored -------------

$barQ set_fragment {terms {x y} case 1 criteria {
    {id 40 kind flag op any value carried}
    {kind word value typed}
}}
check "set_fragment replaces the criteria, honors restored ids, and numbers the rest past them" \
    {{id 41 kind word op {} value typed} {id 40 kind flag op any value carried}} \
    [crits [$barQ fragment]]
check "and the generator stays past the restored ids for every later add" \
    42 [$barQ add_criterion word fresh]
set held [$barQ fragment]
$barQ set_fragment {terms {only foreign keys}}
check "a fragment without a criteria key changes nothing: a partial dict merges" \
    $held [$barQ fragment]
check "set_fragment is quiet" {} $::qevents

set full [$barQ fragment]
$barQ reset
check "reset returns the builder to the empty fragment" {criteria {}} [$barQ fragment]
check "quietly" {} $::qevents
$barQ set_fragment $full
check "a fragment read back and restored is identical: the round trip is lossless" \
    $full [$barQ fragment]

# ---- the editor protocol: ops at commit, and the edit that keeps its id ----

$barQ begin_add sole
update
set ::addop(sole) not
type_into $QROWS.ed_sole.add sole grand
check "a commit naming an op carries it into the criterion" \
    {id 43 kind sole op not value grand} [crit_of $barQ sole]
check "and an editor's commit is user action: exactly one change event" \
    1 [llength $::qevents]
set ::qevents {}

$barQ begin_add sole                ;# max 1 and full: the editor edits in place
update
set ::addop(sole) ""
type_into $QROWS.ed_sole.add sole grander
check "an edit commit moves the value" {grander} [$barQ values sole]
check "keeps the criterion's id" 43 [dict get [crit_of $barQ sole] id]
check "and an omitted op at an edit keeps the current op, not the default" \
    not [dict get [crit_of $barQ sole] op]
set ::qevents {}

# ---- Escape reaches a widget the editor never bound, at any depth ----------

$barQ begin_add flag
update
set DEEP $QROWS.ed_flag.add.box.e
check "the deep editor's entry sits two levels under the add frame" \
    1 [winfo exists $DEEP]
set ::deeptext "half typed"
event generate $DEEP <Escape>
update
check "Escape cancels through the builder's bindtag, however deep the focus widget sits" \
    0 [winfo exists $QROWS.ed_flag.add.box]
check "the add affordance is back in its place" \
    TButton [winfo class $QROWS.ed_flag.add]
check "no value moved and nothing fired" \
    [list [vals_of $full flag] {}] [list [$barQ values flag] $::qevents]

# ---- wrapping, in a frame that pins its width ----------------------------

pack [ttk::frame .narrow -width 320 -height 200] -fill both
pack propagate .narrow 0
set bar2 [::querybuilder::QueryBuilder new]
$bar2 configure -heading "" -facets \
    {{kind word conn "reads" format plain_chip chipstyle Host.TFrame}}
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
set bar3 [::querybuilder::QueryBuilder new]
$bar3 configure -heading "" -facets {{kind word conn "reads" format plain_chip}}
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
    {[::querybuilder::QueryBuilder new] setup .no.such.frame} "*no such window*"

pack [ttk::frame .life] -fill x
set bar4 [::querybuilder::QueryBuilder new]
$bar4 configure -facets {{kind word conn "reads" format plain_chip}}
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
set bar5 [::querybuilder::QueryBuilder new]
$bar5 configure -facets {{kind word conn "reads" format plain_chip editor {text_editor word}}}
$bar5 setup .life2
$bar5 set_model {word {alpha}}
update
destroy .life2
# Every method of the contract but `setup`, which refuses a second call by design.
no_error "a bar whose frame was destroyed under it goes inert: every method still answers" {
    $bar5 model
    $bar5 values word
    $bar5 fragment
    $bar5 kinds
    $bar5 collapsed
    $bar5 publish
    $bar5 set_fragment {}
    $bar5 set_model {word {alpha beta}}
    $bar5 set_values word {beta}
    $bar5 add_criterion word delta
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
