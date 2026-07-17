#!/usr/bin/env wish9.0
# The StreamTree declarative-attribute facility, driven through a tiny invented
# host: a basket of fruit, each fruit carrying two bool flags and one enum colour.
#   ripe    a bool WITH a glyph, so it draws as a subject-prefix mark
#   organic a bool WITHOUT a glyph, so it draws as a check column in the strip
#   colour  an enum, filtered by an excluded-value set through the popover
# All three are filterable. The tests cover declaration validation, both bool
# presentation branches, bool and enum filtering (including a rebuild and an
# unknown-valued row), the roster refresh, where the controls land, that no
# host-named style is dressed, the state round-trip, and the change callback.

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add $ROOT
package require streamtree

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name\n  expected: $expected\n  actual:   $actual"
        incr ::fails
    } else { puts "ok:   $name" }
}
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
# One ordinary column (origin), so the check column has a neighbour to sit beside
# and the strip has more than the attribute cells. attr_value keeps its default,
# reading each attribute id straight out of the payload.
oo::class create FruitTree {
    superclass ::streamtree::StreamTree
    method column_spec {} { return {{origin Origin {Neverland} left 1}} }
    method subject_label {} { return "Fruit" }
    method render_subject {node max} {
        return [dict create subject [my node_pget $node name] tags {} meta_run 1]
    }
    method cell_values {node} {
        return [list [list origin [my node_pget $node origin]]]
    }
    method sort_key {payload col} { return [dict getdef $payload $col ""] }
}
# The engine's Text is private, but setup builds it at $parent.body.t, which the
# assertions read directly.

# The enum roster comes from a provider the tests can grow, so the "next open sees
# the new value" case has something to add.
set ::ROSTER {green red yellow}
proc fruit_colours {} { return $::ROSTER }

# The line of a rendered node, tab-separated as the strip lays it.
proc row_line {t path} {
    # Each row is one line; find the one whose subject carries $path's name.
    set n [lindex [split [$t index end] .] 0]
    for {set i 1} {$i < $n} {incr i} {
        set line [$t get $i.0 "$i.0 lineend"]
        if {[string match "*$path*" $line]} { return $line }
    }
    return ""
}

# ---- assembly ------------------------------------------------------------

# Keep the main window mapped: the enum popover is `wm transient` to it, and a key
# event reaches a transient only while its master is mapped (in the real app it
# always is). A withdrawn master would swallow the Escape the popover test sends.
wm deiconify .
set W .fruit
frame $W
pack $W
set h [FruitTree new]
$h configure -attrs {
    {id ripe    label Ripe    kind bool glyph ● filterable 1}
    {id organic label Organic kind bool          filterable 1}
    {id colour  label Colour  kind enum filterable 1 values fruit_colours}
    {id season  label Season  kind enum}
} -attrfiltercb {record_filter}

set ::CB_COUNT 0
set ::CB_LAST ""
proc record_filter {state} { incr ::CB_COUNT; set ::CB_LAST $state }

$h setup $W
set T $W.body.t

# The basket root, then the fruit rows under it. apple: ripe, organic, red.
# lime: unripe, organic, green. plum: ripe, not organic, red. mystery: ripe,
# organic, colour unknown (empty) - the row that every colour filter keeps.
set basket [$h insert "" folder basket {name Basket origin {}}]
$h expand $basket
set id(apple)   [$h insert $basket fruit apple   {name apple   origin Kent    ripe 1 organic 1 colour red}]
set id(lime)    [$h insert $basket fruit lime    {name lime    origin Persia  ripe 0 organic 1 colour green}]
set id(plum)    [$h insert $basket fruit plum    {name plum    origin Kent    ripe 1 organic 0 colour red}]
set id(mystery) [$h insert $basket fruit mystery {name mystery origin ""      ripe 1 organic 1 colour ""}]
update

# ---- declaration validation ---------------------------------------------

refused "unknown descriptor key refused" {
    $h configure -attrs {{id x kind bool weird 1}}
} "*unknown descriptor key 'weird'*"
refused "bad kind refused" {
    $h configure -attrs {{id x kind scalar}}
} "*kind 'scalar' is neither bool nor enum*"
refused "duplicate id refused" {
    $h configure -attrs {{id x kind bool} {id x kind enum}}
} "*duplicate attribute id 'x'*"
refused "non-word id refused" {
    $h configure -attrs {{id "no space" kind bool}}
} "*is not a plain word*"
refused "attrs not a list refused" {
    $h configure -attrs "\{"
} "*attrs is not a list*"
refused "descriptor not a dict refused" {
    $h configure -attrs {loose}
} "*is not a dict*"
refused "descriptor with no id refused" {
    $h configure -attrs {{kind bool}}
} "*with no id*"
refused "non-boolean filterable refused" {
    $h configure -attrs {{id x kind bool filterable maybe}}
} "*filterable 'maybe' is not a true or false value*"
# The refused configures rolled nothing valid in; the working attrs still stand.
check "attrs survive a refused configure" {ripe organic colour season} [$h attr_order]

# Atomicity: a call carrying a valid -attrs but a bad later option keeps neither.
refused "valid -attrs plus a bad option is refused whole" {
    $h configure -attrs {{id only kind bool}} -nonesuch 1
} "*unknown option -nonesuch*"
check "a refused mixed configure leaves attr_order untouched" {ripe organic colour season} \
    [$h attr_order]
check "a refused mixed configure leaves the -attrs option untouched" \
    {ripe organic colour season} [lmap d [$h opt attrs] {dict get $d id}]

# ---- glyphed bool: subject-prefix glyph with its tag --------------------

check "ripe glyph present on apple's subject" 1 \
    [string match "●*apple*" [row_line $T apple]]
check "no ripe glyph on unripe lime" 0 \
    [string match "*●*" [row_line $T lime]]
# The glyph carries the per-attribute tag attr-ripe, and only over the glyph.
set rr [$T tag ranges attr-ripe]
check "attr-ripe tag is applied" 1 [expr {[llength $rr] >= 2}]
check "attr-ripe covers a single glyph char" ● \
    [$T get [lindex $rr 0] [lindex $rr 1]]

# ---- glyphless bool: a check column in the strip ------------------------

# The effective strip is the consumer column then the organic check column; the
# enum adds no column of its own.
check "organic joins the column strip after origin" {origin organic} \
    [lmap c [$h effective_column_spec] {lindex $c 0}]
# apple is organic: its last cell is the check; plum is not: its last cell blank.
check "organic-true apple shows a check in its cell" ✓ \
    [lindex [split [row_line $T apple] \t] end]
check "organic-false plum shows a blank cell" "" \
    [lindex [split [row_line $T plum] \t] end]

# ---- bool filter hides/shows, and survives a rebuild --------------------

$h attr_filter_set ripe 1
update
check "ripe filter hides unripe lime" "" [row_line $T lime]
check "ripe filter keeps ripe apple" 1 [string match "*apple*" [row_line $T apple]]
$h rebuild
update
check "hidden lime stays hidden across a rebuild" "" [row_line $T lime]
check "shown apple stays shown across a rebuild" 1 \
    [string match "*apple*" [row_line $T apple]]
$h attr_filter_set ripe 0
update
check "clearing the ripe filter brings lime back" 1 \
    [string match "*lime*" [row_line $T lime]]

# ---- a bool filter against a row that lacks the attribute ---------------

# ghost carries no organic key at all: absent, not false. The organic filter hides
# explicit-false rows and leaves ghost (and every explicit-true row) in view.
set id(ghost) [$h insert $basket fruit ghost {name ghost origin Nowhere ripe 1 colour green}]
update
$h attr_filter_set organic 1
update
check "organic filter keeps a row whose value is absent" 1 \
    [string match "*ghost*" [row_line $T ghost]]
check "organic filter hides an explicit-false row" "" [row_line $T plum]
check "organic filter keeps an explicit-true row" 1 \
    [string match "*lime*" [row_line $T lime]]
$h attr_filter_set organic 0
update

# ---- composition: the filter never resurrects another layer's hide ------

# Stand in for a consumer's own filter by hiding apple directly; the attribute
# layer must leave it hidden through any filter toggle and through a clear.
$h hide $id(apple)
update
check "a consumer-hidden node is hidden" "" [row_line $T apple]
$h attr_filter_set ripe 1
update
check "an unrelated filter-on does not resurrect a consumer-hidden node" "" \
    [row_line $T apple]
$h attr_filter_set ripe 0
update
check "clearing all filters does not resurrect a consumer-hidden node" "" \
    [row_line $T apple]
$h unhide $id(apple)
update
check "the consumer can still show its own hidden node" 1 \
    [string match "*apple*" [row_line $T apple]]

# ---- enum excluded-set semantics ----------------------------------------

# Exclude red: the red fruits go, the green one stays, and mystery (empty colour)
# always stays.
$h attr_filter_set colour {red}
update
check "excluding red hides apple" "" [row_line $T apple]
check "excluding red hides plum" "" [row_line $T plum]
check "excluding red keeps green lime" 1 [string match "*lime*" [row_line $T lime]]
check "an unknown-colour row stays under an enum filter" 1 \
    [string match "*mystery*" [row_line $T mystery]]
# Select-none is the whole current roster excluded; the unknown-colour row still
# shows.
$h attr_filter_set colour [fruit_colours]
update
check "select-none hides every known-colour fruit" {{} {} {}} \
    [list [row_line $T apple] [row_line $T lime] [row_line $T plum]]
check "select-none still shows the unknown-colour row" 1 \
    [string match "*mystery*" [row_line $T mystery]]
$h attr_filter_set colour {}
update
check "clearing the colour filter brings the fruits back" 1 \
    [expr {[string match "*apple*" [row_line $T apple]] \
        && [string match "*lime*" [row_line $T lime]]}]

# ---- filter controls in the host frame, on the declared side ------------

frame $W.filters
pack $W.filters
$h build_filters $W.filters right
update
check "bool ripe control lands in the host frame" 1 [winfo exists $W.filters.attr_ripe]
check "bool organic control lands in the host frame" 1 \
    [winfo exists $W.filters.attr_organic]
check "enum colour control lands in the host frame" 1 \
    [winfo exists $W.filters.attr_colour]
check "a control packs toward the declared side" right \
    [dict get [pack info $W.filters.attr_ripe] -side]
check "the ripe checkbutton is a checkbutton" TCheckbutton \
    [winfo class $W.filters.attr_ripe]
check "the colour control is a menubutton" TMenubutton \
    [winfo class $W.filters.attr_colour]
refused "build_filters refuses a side that is neither left nor right" {
    frame $W.badside
    $h build_filters $W.badside middle
} "*neither left nor right*"

# ---- the enum popover, and the roster refresh ---------------------------

$h open_enum_popover colour
update
set pf .streamtree_attrpop.f
check "the popover offers one checkbutton per roster value" 3 \
    [llength [lsearch -all -inline [winfo children $pf] $pf.v*]]
check "the popover carries select-all and select-none" 1 \
    [expr {[winfo exists $pf.btns.all] && [winfo exists $pf.btns.none]}]
$h close_enum_popover
# A value the provider gains after the popover last drew appears the next open.
lappend ::ROSTER purple
$h open_enum_popover colour
update
check "a value added to the roster appears on the next open" 4 \
    [llength [lsearch -all -inline [winfo children $pf] $pf.v*]]
# A real Escape event on the popover closes it, not just a direct method call.
focus -force .streamtree_attrpop
event generate .streamtree_attrpop <Escape>
update
check "an Escape event closes the popover" 0 [winfo exists .streamtree_attrpop]

# ---- styles arrive by name; the module dresses none of them -------------

# Name a host style for every control role. Each control must take the named
# style, and the module must configure nothing on any of them: they stay empty
# because nothing (host or module) has dressed them.
$h configure -attrstyles {
    check    HostCheck.TCheckbutton
    menu     HostMenu.TMenubutton
    popcheck HostPop.TCheckbutton
    popbtn   HostBtn.TButton
}
frame $W.styled
pack $W.styled
$h build_filters $W.styled left
update
check "the check control took the named check style" HostCheck.TCheckbutton \
    [$W.styled.attr_ripe cget -style]
check "the menubutton took the named menu style" HostMenu.TMenubutton \
    [$W.styled.attr_colour cget -style]
$h open_enum_popover colour
update
check "a popover value took the named popcheck style" HostPop.TCheckbutton \
    [$pf.v0 cget -style]
check "a popover button took the named popbtn style" HostBtn.TButton \
    [$pf.btns.all cget -style]
foreach s {HostCheck.TCheckbutton HostMenu.TMenubutton HostPop.TCheckbutton HostBtn.TButton} {
    check "the module configured nothing on $s" "" [ttk::style configure $s]
}
$h close_enum_popover

# ---- state get/set round-trip -------------------------------------------

$h configure -attrstyles {check "" menu "" popcheck "" popbtn ""}
$h attr_filter_set ripe 1
check "a bool filter reads back what was set" 1 [$h attr_filter_get ripe]
$h attr_filter_set ripe 0
check "a bool filter clears" 0 [$h attr_filter_get ripe]
$h attr_filter_set colour {red yellow}
check "an enum excluded set round-trips" {red yellow} \
    [lsort [$h attr_filter_get colour]]
$h attr_filter_set colour {}
refused "state access refuses a declared non-filterable attribute" {
    $h attr_filter_get season
} "*not filterable*"
refused "state access refuses an undeclared name" {
    $h attr_filter_get nope
} "*no such attribute*"

# ---- the callback fires on change, and not on a no-op -------------------

set ::CB_COUNT 0
$h attr_filter_set ripe 1
check "the callback fires on a real change" 1 $::CB_COUNT
check "the callback carries the filter state" 1 [dict get $::CB_LAST ripe]
$h attr_filter_set ripe 1
check "the callback does not fire on a no-op set" 1 $::CB_COUNT
$h attr_filter_set colour {}
check "a no-op enum set fires no callback" 1 $::CB_COUNT
$h attr_filter_set ripe 0

# ---- attr_value override: the engine reads only through the hook ---------

# The value lives in a nested props dict, a shape the default attr_value would
# never find. A working glyph and a working filter prove the engine reads every
# attribute value only through the hook, so a payload stays the consumer's own. A
# per-object override on a fresh FruitTree carries it, so $h keeps its default
# reading for the tests around it; a whole subclass would earn its place only by
# adding behaviour past this one redirected read, and it adds none.
frame $W.op
pack $W.op
set o [FruitTree new]
oo::objdefine $o method attr_value {node id} {
    return [dict getdef [my node_pget $node props] $id ""]
}
$o configure -attrs {{id star kind bool glyph ★ filterable 1}}
$o setup $W.op
set OT $W.op.body.t
set ob [$o insert "" folder ob {name Root}]
$o expand $ob
$o insert $ob item lit  {name lit  props {star 1}}
$o insert $ob item dark {name dark props {star 0}}
update
check "the override feeds the subject-prefix glyph" 1 \
    [string match "★*lit*" [row_line $OT lit]]
check "the override leaves a false row unglyphed" 0 [string match "*★*" [row_line $OT dark]]
$o attr_filter_set star 1
update
check "the override feeds the bool filter" "" [row_line $OT dark]
check "the override keeps the passing row" 1 [string match "*lit*" [row_line $OT lit]]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
