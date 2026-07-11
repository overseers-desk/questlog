package require Tcl 8.6-
package require Tk 8.6-
package provide facetbar 1.0

namespace eval ::facetbar {}

# The interpreter floor is 8.6, the Tk most hosts still run, and `dict getdef`
# (8.7) was the one thing standing above it. This is that command, so the module
# asks for nothing a 2013 interpreter cannot give. test/test-facetbar.tcl runs
# unchanged on either, and is checked on both.
proc ::facetbar::getdef {d key dflt} {
    if {[dict exists $d $key]} { return [dict get $d $key] }
    return $dflt
}

# ::facetbar::FacetBar - a faceted criteria bar.
#
# The pattern: a set of applied filter criteria, shown as removable chips, which
# collapses to just those chips and expands into a full editor, and which reports
# the criteria back to whatever acts on them. Faceted search calls one dimension
# of a filter a FACET; this is the bar those facets live in.
#
# Vocabulary, and the whole of the widget's world view:
#   facet   one criterion type. A descriptor dict declares it. The widget learns
#           its id, its wording and how to reach its editor, and nothing else.
#   value   one applied value of a facet. Opaque: the widget stores it, hands it
#           to the caller's formatter for the chip's text, and compares it with
#           `in` to spot a repeat. It may be a string, a pair, any Tcl value.
#   model   dict of facet id -> list of values. This is what the owner reads, and
#           what the change callback carries.
#
# What the widget owns: the layout (a heading line with the disclosure, one row
# per facet holding a type tag, a connective word and an editor area, and an add
# rail offering the tail facets not yet in use); the chips (their connector, their
# delete affordance, their inline add, their wrapping); the collapse/expand
# disclosure; and the one door that tells the owner the model changed. Everything
# else - what a value is, how it is edited, how it prints - arrives from the
# caller as a descriptor. The widget never inspects a value.
#
# Why descriptors, and not a subclass with hooks. Hooks fix the behaviour once per
# widget, which is the right grain when a widget's content is uniform. Here it is
# not: one bar carries several facets at once and they differ from each other, not
# from bar to bar. Two facets of the same kind in one bar, or two bars in one
# application sharing a facet, would each need a class of their own, and no facet
# could be added at runtime without writing one. So the type-specific part is data
# hung on the facet, not methods hung on the class, and a host adds a facet by
# appending a dict.
#
# Two editor modes, because one is not enough and three would be a taxonomy:
#   chips    the facet's values are typed or picked one at a time. The widget draws
#            the chips and the inline add affordance, and the descriptor's editor
#            callback builds only the control that affordance opens into.
#   control  the facet is edited by one bespoke widget: a stepper, a swatch, a menu
#            of choices that exclude one another. The caller's editor callback owns
#            the whole editor area. The widget draws no chips there, because the
#            control itself already shows the value - but it still draws them when
#            the bar is collapsed, where the control is gone.
# Without `control`, a criterion whose whole meaning is one bounded choice would
# have to be typed in as text and chipped like a list; without `chips`, every
# caller would rewrite the chip strip. One chip renderer serves both, so a
# collapsed bar reads the same whichever mode a facet is in.
#
# An editor is a function of the model. The editor callback is handed the facet's
# current values every time its row is drawn, so a value deleted from a chip while
# the bar was collapsed is already gone from the control when the row comes back.
# There is deliberately no second path by which the widget tells an editor "your
# value changed": that path is the row being drawn. The exception is exactly one
# door, `report_values`, which an editor uses to say what it now holds: it takes
# the values and does NOT redraw that facet's editor, because the bar will not
# rebuild a control under the hand still on it. An owner changing a facet from
# outside uses `set_values` (or `set_model`), which does redraw it.
#
# Collapse summarizes, it never hides. A collapsed bar still draws every applied
# value as a chip, with its delete affordance live; what it takes away is the
# editors and the rail. A criterion that narrows a result while invisible is the
# failure this pattern exists to prevent, so the one state that could hide a
# criterion is the one state the widget will not enter. That is also why a
# `control` facet must carry an editor: while the bar is expanded its values are
# drawn by that editor and by nothing else, so a control facet without one would
# apply a criterion the user could neither see nor delete. The door refuses it.
#
# The bar's grammar, and its limit. Within a facet, the values are drawn joined by
# that facet's connector word; between one facet and the next, nothing is drawn at
# all. The widget takes no position on what any of that means: the model is a
# mapping of facet to values, and how the criteria combine is the owner's to
# decide and, through the connective and connector words, the owner's to say.
#
# Lifecycle. `setup` runs once, on a frame the host creates, packs and in the end
# destroys; a second `setup` is an error. Every widget the bar builds is a child
# of that frame: they are the bar's to create and to destroy, and the host adds
# none of its own to it. The exception is an editor area, which is handed to the
# caller's editor callback to fill, and which the bar empties before it draws that
# area again, so an editor's widgets are built fresh on each call and none of them
# outlives the frame. Destroying the object takes the bar's widgets with it and
# leaves the frame, which is the host's, standing empty. Destroying the frame first
# is allowed too: the object goes inert, and every method still answers rather than
# raising, so a host may tear the two down in either order.
#
# The look is ttk styles, named in the -styles option and overridable per facet,
# so the module names no colour and no font. A host that styles nothing still gets
# a legible bar: the chip and the tag fall back to a plain outline. The fallback
# touches no style the host has renamed, and none it has already configured under
# the module's own name, so dressing `FacetChip.TFrame` yourself is enough to own
# the look of a chip.
#
# Widget paths, stable, so a host can reach a widget the bar built (to hang a
# tooltip on a chip, to drive one from a test):
#   $top.head                    the heading line
#     $top.head.hd                 the heading text, with the active count appended
#     $top.head.tog                the disclosure button
#   $top.body                    the body, swapped whole by the disclosure
#     expanded:
#       $top.body.rows             the editor rows, three aligned grid columns
#         .tag_<id>                  the type tag
#         .conn_<id>                 the connective word
#         .ed_<id>                   the editor area: the chips and their inline
#                                    add, or a `control` facet's own editor
#         .ed_<id>.c<i>              one chip, and .add the inline add affordance
#         .ed_<id>.or<i>             the connector word drawn before chip i
#       $top.body.rail             the add rail
#         .label                     its leading word
#         .b_<id>                    one hidden tail facet's reveal button
#     collapsed:
#       $top.body.strip            the chip summary
#         .tag_<id>                  an applied facet's tag
#         .c_<id>_<i>                one of its chips
#         .or_<id>_<i>               the connector word drawn before that chip
#         .add                       the add affordance, when nothing is applied
# A chip holds `x` (its delete), `lead` (the optional per-value control) and `t`
# (its text). Every other method of the class, and every variable, is unexported:
# the three tables below are the whole contract.
#
# Usage:
#   ::tcl::tm::path add $dir
#   package require facetbar
#
#   set bar [::facetbar::FacetBar new]
#   $bar configure -heading "Show the items that…" -changecb [list apply_criteria] \
#       -facets {
#           {id colour  conn "is"         format colour_chip editor colour_editor}
#           {id size    conn "is at most" format size_chip editor size_editor
#            mode control max 1}
#           {id keyword conn "mentions"   editor keyword_editor tail 1
#            orword "and" ortext "+ and"}
#       }
#   $bar setup .host                  ;# a frame the host created and packed
#   $bar set_model {colour {red blue}}
#
# Methods:
#   setup frame           build the bar into a frame the host owns. Once only.
#   configure ?args?      no arguments reads every option, one reads that option,
#                         pairs set them. A set applies all of them or, if one is
#                         bad, none of them.
#   cget -opt             read one option.
#   model                 the whole model: every facet id, applied or not.
#   values id             one facet's values. An id no descriptor declares is an
#                         error, here as at every other door.
#   set_model m           the owner's door. Sets the whole model, so a facet the dict
#                         leaves out is a facet with no values, and `set_model {}`
#                         returns the bar to rest: nothing applied, no editor open,
#                         every tail facet back on the rail. Every id and every cap is
#                         checked before anything is written. It fires no change
#                         callback, because the owner making the call is the one that
#                         would hear it.
#   set_values id vals    the owner's per-facet door: replaces that facet's values,
#                         redraws its editor from them, and publishes.
#   report_values id vals the editor's door: an editor saying what it now holds. As
#                         set_values, except that it does not redraw the editor it
#                         came from, which is what keeps a control alive under the
#                         hand that just moved it.
#   add_value id value    commit one value from a `chips` facet's editor. A facet at
#                         `max 1` takes it in place of the value it holds; one at its
#                         cap takes no more; a repeat is no second criterion unless
#                         the facet sets `dedupe 0`. The editor stays open while the
#                         facet can take another value, so a keyboard user types
#                         value, Enter, value, Enter, and closes it with Escape.
#   remove_value_at id i  drop the value at index i: what a chip's delete does.
#   set_value_at id i v   rewrite the value at index i in place: what a chip's own
#                         per-value control does.
#   cancel_add id         abandon an open add. The editor closes and its unconfirmed
#                         text goes with it; a tail facet revealed only to be typed
#                         into returns to the rail.
#   begin_add id          open a facet's editor as its add affordance would: reveal
#                         the facet if it waits on the rail, expand the bar if it is
#                         collapsed. On a facet at its cap it reveals and expands but
#                         opens no editor, because the affordance it stands in for is
#                         not drawn there either, and a value typed into an editor the
#                         model has no room for would be dropped on commit.
#   expand, collapse, toggle   the disclosure.
#   expanded              1 while the editor rows show, 0 while collapsed to chips.
#
# Options (`configure -opt value ...`):
#   -facets       the ordered descriptor list; that order is the rows' reading
#                 order. Checked at the door: a duplicate id, an unknown key, an id
#                 that cannot name a widget, or a `control` facet with no editor is
#                 an error where it was written. A facet the new list drops takes its
#                 values, its revealed row and its open editor with it, and no change
#                 callback fires for them: swapping the facet list is a change to what
#                 the bar can hold, which the owner is making, and not a change to the
#                 criteria the user applied.
#   -heading      the heading on the head line ("" draws none)
#   -countfmt     appended to the heading while at least one facet is applied: a
#                 format with one %d ("%d active"; "" suppresses the count)
#   -orword       the connector drawn between one facet's chips ("or"), the default
#                 for the per-facet key of the same name
#   -addtext      the inline add affordance on a facet with no values ("+")
#   -ortext       the inline add affordance on a facet that has one ("+ or"), the
#                 default for the per-facet key of the same name
#   -deltext      the chip's delete affordance ("×")
#   -raillabel    the leading word on the add rail ("Add"; "" draws none)
#   -emptytext    the affordance shown collapsed while nothing is applied ("+ add")
#   -expandtext   the disclosure while collapsed ("▸")
#   -collapsetext the disclosure while expanded ("▾")
#   -changecb     a command prefix invoked with the model dict every time the widget
#                 changes it. The one door: the owner is told what the criteria now
#                 are, not which chip moved. `set_model` does not fire it, because
#                 the owner making that call already knows. The callback may raise,
#                 and the bar does not catch it: the model is updated and drawn
#                 before the callback runs, so the widget is left consistent either
#                 way, and the error travels as any error does - reported through
#                 Tk's background error handler, with the host's own stack, when the
#                 change came from a click or a keystroke, and propagated to the
#                 caller when it came from a direct call.
#   -styles       dict of role -> ttk style name; a partial dict merges over the
#                 defaults, and a role no widget has is an error. Roles: heading
#                 toggle tag conn or chip chiptext del add.
#
# Descriptor keys (only `id` is required):
#   id        the facet's key in the model. It names widgets and rides into a binding
#             script, so it must be a plain word: letters, digits and underscores.
#   label     the word on the type tag (defaults to the id)
#   conn      the connective word between the tag and the editor ("" draws none)
#   format    a command prefix, `{*}$format $value` -> the chip's text. Defaults to
#             the value itself. It takes the value alone, so a one-liner needs no
#             wrapper; a formatter shared by several facets carries its facet in
#             the prefix.
#   mode      chips | control (default chips), as above. A `control` facet must carry
#             an editor: while the bar is expanded, nothing else draws its values.
#   max       the most values the facet may hold (default 0: no limit). It is a rule
#             on the model, not merely on the affordance: at the cap the inline add is
#             not drawn, a commit takes no more, and a `set_model`, `set_values` or
#             `report_values` that would break the cap is refused. `max 1` is the
#             single-valued facet: a committed value replaces the one already there
#             rather than joining it, so a criterion that can only mean one thing
#             cannot be made to mean two.
#   dedupe    1 (default) to treat a value the facet already holds as no second
#             criterion; 0 for a facet where a repeat is a legitimate second value.
#   orword    the connector between this facet's chips, over the -orword default.
#             Joining is a per-facet meaning, not a bar-wide one: one facet's values
#             may be alternatives while another's must all hold, and each says so in
#             its own word. "" draws no connector at all, and none of its spacing.
#   ortext    the inline add affordance on this facet once it holds a value, over the
#             -ortext default. It reads as "one more, joined" where it sits, after
#             the last chip, so a facet that joins with a different word wants a
#             different affordance. A `max 1` facet never shows it: a commit there
#             replaces, so the affordance keeps reading -addtext rather than offer a
#             join the facet will not make.
#   tail      1 for an optional facet, revealed from the add rail (default 0: the row
#             is always present). A tail facet with no editor is never offered on the
#             rail, because a row with nothing to type into is a dead end; such a
#             facet appears when the owner gives it a value and goes when its last
#             value is deleted.
#   editor    a command prefix, `{*}$editor $parent $id $values`, building this
#             facet's editor into the frame $parent, which the widget owns, puts
#             nothing else into, and will empty again. In `chips` mode that is the
#             control the add affordance opens into: it should take the keyboard
#             focus itself, because only it knows which of the widgets it built takes
#             typing, and it reports a committed value with `add_value` and an
#             abandoned one with `cancel_add`. In `control` mode it is the whole
#             editor, and it reports with `report_values`. A `chips` facet with no
#             editor gets no add affordance: its values are the owner's to set, and
#             the bar shows them and deletes them.
#   chipctl   a command prefix, `{*}$chipctl $w $id $index $value`, for an optional
#             control inside the chip, qualifying the value it sits on (a menu naming
#             which unit the value is in, a toggle turning the criterion around). The
#             caller creates a widget at the path $w names, and the bar lays out
#             whatever it finds there; creating nothing leaves a plain chip. It
#             reports an edit with `set_value_at`.
#   railtext  the facet's button on the add rail (defaults to "+ <label>")
#   tagstyle  ttk style for this facet's tag, over the -styles default
#   chipstyle ttk style for this facet's chips, over the -styles default
#
# Limits. Every chip carries a delete and every value can be removed: the bar has no
# locked criterion and no read-only state, so a host that must keep a criterion
# applied cannot say so here, and would have to put it back from the change callback
# and live with the flicker. Nor is a facet disableable: dropping it from -facets
# takes its values with it. Both are absent because the widget cannot own what they
# mean - whether a locked criterion still counts as the user's, whether a disabled
# facet still filters - and a knob whose meaning lives in the host is a knob the host
# should be holding.
#
# Requires Tcl and Tk 8.6 or better.
#
# Wrapping, and the width the bar asks for. Tk's packers do not wrap, so the chips
# are placed: an area lays them left to right and breaks to a new line when the next
# would not fit. It then asks its master for the height that took, and for the width
# of its widest single chip, which is the narrowest it can be without cutting a chip
# in half. So a chip wider than the room the bar has been given asks for its own
# width, and a host whose frame passes its children's requests upward will widen to
# it. Pin the frame's width if a long value must never widen the window - a frame
# with `pack propagate 0`, a grid cell with a weight, a pane - and the bar will use
# all the width it is given, wrap inside it, and grow downward instead.

oo::class create ::facetbar::FacetBar {
    variable Top       ;# the frame the host owns and we build into
    variable Model     ;# dict: facet id -> list of applied values
    variable Expanded  ;# 1 while the editor rows show, 0 while collapsed to chips
    variable Revealed  ;# dict: tail facet id -> 1 once pulled off the add rail
    variable Editing   ;# dict: facet id -> 1 while its inline add editor is open
    variable Opts      ;# widget options: the whole of the host-specific surface
    variable Flow      ;# dict: chip area -> the {widget leftgap} items it drew
    variable FlowW     ;# dict: chip area -> the width its current lay was made at
    variable FlowIdle  ;# after-idle token of a pending first lay, or ""

    constructor {} {
        set Top ""
        set Model    [dict create]
        set Revealed [dict create]
        set Editing  [dict create]
        set Flow     [dict create]
        set FlowW    [dict create]
        set FlowIdle ""
        set Expanded 1
        set Opts [my default_opts]
    }

    # The bar takes its own with it. Every widget it built carries a command prefix
    # naming this object, so leaving them standing would leave a disclosure button
    # that raises "invalid command name" the moment it is pressed. The frame is the
    # host's and stays. Deferred work goes the same way, or a lay scheduled for the
    # next idle moment would fire into a command that no longer exists.
    destructor {
        if {$FlowIdle ne ""} { after cancel $FlowIdle }
        if {$Top ne "" && [winfo exists $Top]} {
            destroy $Top.head $Top.body
        }
    }

    # ---- options -----------------------------------------------------------

    method default_opts {} {
        return [dict create \
            facets       {} \
            heading      "" \
            countfmt     "%d active" \
            orword       "or" \
            addtext      "+" \
            ortext       "+ or" \
            deltext      "\u00d7" \
            raillabel    "Add" \
            emptytext    "+ add" \
            expandtext   "\u25b8" \
            collapsetext "\u25be" \
            changecb     "" \
            styles       [dict create \
                heading  FacetHeading.TLabel \
                toggle   FacetToggle.TButton \
                tag      FacetTag.TLabel \
                conn     FacetConn.TLabel \
                or       FacetOr.TLabel \
                chip     FacetChip.TFrame \
                chiptext FacetChipText.TLabel \
                del      FacetDel.TButton \
                add      FacetAdd.TButton]]
    }

    # No arguments reads the options, one argument reads that option, pairs write.
    # A write is all or nothing: every value is checked, and only then is any of it
    # kept, so a bad facet list cannot leave a half-applied bar behind carrying the
    # good options that came with it. Options may be set before setup, the usual
    # order, or after, where the bar redraws on the spot.
    method configure {args} {
        if {[llength $args] == 0} { return $Opts }
        if {[llength $args] == 1} { return [my cget [lindex $args 0]] }
        if {[llength $args] % 2} {
            error "facetbar: configure takes one option to read, or option/value pairs to set"
        }
        set staged $Opts
        foreach {opt val} $args {
            set k [string trimleft $opt -]
            if {![dict exists $staged $k]} { error "facetbar: unknown option $opt" }
            switch -- $k {
                facets { my validate_facets $val }
                styles {
                    # A misspelt role would merge in, name a style nothing draws
                    # with, and quietly leave the look unchanged. It is refused for
                    # the reason a misspelt descriptor key is.
                    set roles [dict keys [dict get $staged styles]]
                    dict for {role name} $val {
                        if {$role ni $roles} {
                            error "facetbar: unknown style role '$role';\
                                   the roles are: [join $roles {, }]"
                        }
                    }
                    set val [dict merge [dict get $staged styles] $val]
                }
            }
            dict set staged $k $val
        }
        set Opts $staged
        my default_styles
        my sync_state
        my refresh
    }

    method cget {opt} {
        set k [string trimleft $opt -]
        if {![dict exists $Opts $k]} { error "facetbar: unknown option $opt" }
        return [dict get $Opts $k]
    }

    method opt {k} { return [dict get $Opts $k] }
    method style {role} { return [dict get [my opt styles] $role] }

    # The style for one facet's tag or chips: the descriptor's own, else the bar's
    # role. A host tints a facet by naming a style, never by naming a colour.
    method facet_style {id key role} { return [my dget $id $key [my style $role]] }

    # Check the descriptor list where the caller wrote it. A mistyped key would
    # otherwise surface as a row that silently never draws, or an editor never
    # called, which is a long walk back from the symptom.
    method validate_facets {facets} {
        set known {id label conn format mode max dedupe orword ortext tail editor
                   chipctl railtext tagstyle chipstyle}
        set seen [list]
        foreach d $facets {
            if {![dict exists $d id]} { error "facetbar: descriptor with no id: $d" }
            set id [dict get $d id]
            # A plain word, because the id names widgets and rides into the flow's
            # binding script, where a stray % would be taken for an event
            # substitution and hand the bar a window that does not exist.
            if {![regexp {^[A-Za-z0-9_]+$} $id]} {
                error "facetbar: facet id '$id' is not a plain word\
                       (letters, digits, underscore)"
            }
            if {$id in $seen} { error "facetbar: duplicate facet id '$id'" }
            lappend seen $id
            foreach k [dict keys $d] {
                if {$k ni $known} {
                    error "facetbar: facet '$id': unknown descriptor key '$k'"
                }
            }
            set mode [::facetbar::getdef $d mode chips]
            if {$mode ni {chips control}} {
                error "facetbar: facet '$id': mode '$mode' is neither chips nor control"
            }
            # An expanded bar draws a control facet's values through its editor and
            # through nothing else, so one without an editor would apply a criterion
            # the user could neither see nor delete: the failure the pattern exists
            # to prevent, admitted at the door.
            if {$mode eq "control" && [::facetbar::getdef $d editor ""] eq ""} {
                error "facetbar: facet '$id': a control facet needs an editor,\
                       or its value would be applied and never shown"
            }
            set max [::facetbar::getdef $d max 0]
            if {![string is integer -strict $max] || $max < 0} {
                error "facetbar: facet '$id': max '$max' is not a count"
            }
        }
    }

    # The fallback dress, for a bar whose host has styled nothing: a chip drawn in an
    # unconfigured style is an invisible flat frame, and the pattern is nothing
    # without its chips. It backs off from a style the host has renamed - that name is
    # the host's, and may dress widgets elsewhere - and from one the host has already
    # configured under the module's own name, which is the plainest way to restyle a
    # chip and must not be stamped over.
    method default_styles {} {
        set mine [dict get [my default_opts] styles]
        foreach role {chip tag} {
            set s [my style $role]
            if {$s ne [dict get $mine $role]} continue
            if {[ttk::style configure $s] ne ""} continue
            ttk::style configure $s -relief solid -borderwidth 1 -padding {4 0}
        }
    }

    # ---- the descriptors ---------------------------------------------------

    method ids {} { return [lmap d [my opt facets] {dict get $d id}] }

    method desc {id} {
        foreach d [my opt facets] {
            if {[dict get $d id] eq $id} { return $d }
        }
        error "facetbar: no such facet '$id'"
    }

    # One descriptor field, with that field's default. Every read of a descriptor
    # goes through here, so a key's default is written once, at the one call site.
    method dget {id key dflt} { return [::facetbar::getdef [my desc $id] $key $dflt] }

    # A tail facet is hidden while it is neither revealed nor carrying a value: it
    # has no row, and its button waits on the add rail. Revealing is one way - a
    # revealed row stays, so another value can be added to it - except that
    # abandoning the add that revealed it puts it back, see cancel_add.
    method tail_hidden {id} {
        if {![my dget $id tail 0]}         { return 0 }
        if {[::facetbar::getdef $Revealed $id 0]} { return 0 }
        return [expr {[llength [my values $id]] == 0}]
    }

    # The facets with a row, in descriptor order. The rail carries the ones without,
    # so a body whose `present` list has not changed has an unchanged rail.
    method present {} {
        return [lmap id [my ids] { expr {[my tail_hidden $id] ? [continue] : $id} }]
    }

    # Whether the inline add affordance is drawn. A single-valued facet always offers
    # it: a commit there replaces, so there is always something the affordance can do.
    method addable {id} {
        if {[my dget $id editor ""] eq ""} { return 0 }
        set max [my dget $id max 0]
        if {$max <= 1} { return 1 }
        return [expr {[llength [my values $id]] < $max}]
    }

    # Whether a commit can be followed by another. This is what keeps the editor open
    # after a commit, so a keyboard user is not thrown back to the button between two
    # values; at the cap there is nothing more to type, and it closes.
    method can_take_more {id} {
        if {[my dget $id editor ""] eq ""} { return 0 }
        set max [my dget $id max 0]
        return [expr {$max == 0 || [llength [my values $id]] < $max}]
    }

    # `max` is a rule on the model, not only on the affordance: a value list that
    # breaks the cap is refused wherever it comes from, so no route into the widget
    # leaves a facet holding more than it says it may.
    method check_max {id vals} {
        set max [my dget $id max 0]
        if {$max > 0 && [llength $vals] > $max} {
            error "facetbar: facet '$id' holds at most $max value(s),\
                   given [llength $vals]"
        }
    }

    # ---- the model ---------------------------------------------------------

    # The model carries every facet, applied or not, so an owner reads a facet's
    # values without first asking whether any were set. An id no descriptor declares
    # is an error here as it is at every other door: a facet read by a name with a
    # typo in it would otherwise answer "nothing applied", which is a lie the caller
    # has no way to catch.
    method model {} { return $Model }
    method values {id} {
        my desc $id
        return [::facetbar::getdef $Model $id {}]
    }

    # Hold the bar's state to the facet list, which the host may set or swap at any
    # time. The model, the revealed rows and the open editors are all keyed by facet
    # id: a facet that arrives starts with no values, hidden and closed, and one that
    # leaves takes all three with it, so a facet dropped and put back does not return
    # already revealed, on the strength of a key nothing explains any more.
    method sync_state {} {
        set ids [my ids]
        set m [dict create]
        set r [dict create]
        set e [dict create]
        foreach id $ids {
            dict set m $id [::facetbar::getdef $Model $id {}]
            if {[dict exists $Revealed $id]} { dict set r $id [dict get $Revealed $id] }
            if {[dict exists $Editing $id]}  { dict set e $id [dict get $Editing $id] }
        }
        set Model    $m
        set Revealed $r
        set Editing  $e
    }

    # The owner's door: the criteria changed out from under the bar (a saved filter
    # loaded, a criterion added from a menu elsewhere). It sets the whole model, so a
    # facet the dict leaves out is a facet with no values, and `set_model {}` returns
    # the bar to rest - nothing applied, no editor open, every tail facet back on the
    # rail. Every id and every cap is checked before anything is written, so a bad
    # call cannot leave half a model behind. The bar redraws whole, and every editor
    # is rebuilt from the new values. It fires no change callback: the owner making
    # this call is the one that would hear it.
    method set_model {m} {
        dict for {id vals} $m {
            my desc $id
            my check_max $id $vals
        }
        set new [dict create]
        foreach id [my ids] { dict set new $id [::facetbar::getdef $m $id {}] }
        set Model    $new
        set Revealed [dict create]
        set Editing  [dict create]
        my refresh
    }

    # The owner's per-facet door: replace one facet's values and redraw its editor
    # from them, so a control shows what the owner has just set.
    method set_values {id vals} {
        my desc $id
        my check_max $id $vals
        set was [my present]
        dict set Model $id $vals
        my after_change $id $was 1
    }

    # The editor's door: an editor telling the bar what it now holds. The one thing it
    # does not do is redraw that facet's editor, because that editor is where this
    # change came from, and rebuilding it would destroy the control under the hand
    # that just moved it.
    method report_values {id vals} {
        my desc $id
        my check_max $id $vals
        set was [my present]
        dict set Model $id $vals
        # An editor that reports keeps its row. A tail facet loses its row when its
        # last value goes, and the row would take the editor with it - so a control
        # wound down to a value of "none" would be destroyed from inside its own
        # callback, which is the one thing this door exists to prevent. The row it
        # was drawn in stays until something other than the editor closes it.
        if {[my dget $id tail 0] && $id in $was} { dict set Revealed $id 1 }
        my after_change $id $was 0
    }

    # Commit a value from a `chips` facet's editor. A single-valued facet takes the
    # new value in place of the old; any other appends it, refusing to pass its cap
    # or, unless the facet asks for repeats, to hold one value twice. The editor is
    # left open while the facet can take another value, and closes at the cap; Escape
    # closes it either way.
    method add_value {id value} {
        my desc $id
        set was [my present]
        set old [my values $id]
        set max [my dget $id max 0]
        set vals $old
        if {$max == 1} {
            set vals [list $value]
        } elseif {(![my dget $id dedupe 1] || $value ni $old) \
                  && ($max == 0 || [llength $old] < $max)} {
            lappend vals $value
        }
        dict set Model $id $vals
        if {$vals ne $old && [my dget $id tail 0]} { dict set Revealed $id 1 }
        if {[my can_take_more $id]} {
            dict set Editing $id 1
        } else {
            dict unset Editing $id
        }
        if {$vals eq $old} {
            # A repeat of an applied value is no second criterion, and a facet at its
            # cap takes no more. Nothing changed, so no one is told; the editor is
            # left open or closed by the same rule as a commit that did land.
            my render_editor $id
            return
        }
        my after_change $id $was 1
    }

    # Remove the value at $idx: the chip whose delete affordance was pressed. By
    # index, not by value: a per-value control can leave two chips value-equal, and a
    # by-value delete would drop the first twin rather than the chip the user pressed.
    method remove_value_at {id idx} {
        my desc $id
        set vals [my values $id]
        if {$idx < 0 || $idx >= [llength $vals]} return
        set was [my present]
        dict set Model $id [lreplace $vals $idx $idx]
        my after_change $id $was 1
    }

    # Rewrite one value in place: the per-value control's door, for when what the
    # value applies to has changed but the value itself has not moved.
    method set_value_at {id idx value} {
        my desc $id
        set vals [my values $id]
        if {$idx < 0 || $idx >= [llength $vals]} return
        set was [my present]
        lset vals $idx $value
        dict set Model $id $vals
        my after_change $id $was 1
    }

    # Every path that changes the model lands here: redraw what the change can touch,
    # then tell the owner. Redrawing the one facet, rather than the whole body, is
    # what keeps another row's editor alive - a stepper mid-step, an entry mid-word -
    # while this row's chip is deleted. Only a change in which facets have rows (a
    # tail facet's first value, or a row whose last value left) re-lays the body, and
    # the rail rides that same test, because the rail carries exactly the facets the
    # rows do not.
    #
    # `redraw` is 0 on the one path that must not touch the facet's editor: that
    # editor reporting, through report_values, what it now holds.
    method after_change {id was redraw} {
        if {!$Expanded || [my present] ne $was} {
            my refresh
        } else {
            if {$redraw} { my render_editor $id }
            my render_head
        }
        my publish
    }

    # The change is drawn before the owner hears of it, so the widget is consistent
    # whatever the callback does, raising included. Its error is not caught: it
    # travels as any error does, which at event time is Tk's background error handler,
    # with the host's own stack intact.
    method publish {} {
        set cb [my opt changecb]
        if {$cb eq ""} return
        {*}$cb [my model]
    }

    # ---- disclosure --------------------------------------------------------

    method expanded {} { return $Expanded }

    method expand {} {
        if {$Expanded} return
        set Expanded 1
        my refresh
    }

    # Collapsing drops any open inline editor along with the rows it was drawn in;
    # nothing was committed, so nothing is published. A tail facet revealed but never
    # given a value goes back to the rail with them, as it would if its add were
    # cancelled: leaving it revealed would bring back, on the next expand, an empty
    # row whose rail button is gone and which no affordance on the bar can dismiss.
    method collapse {} {
        if {!$Expanded} return
        set Expanded 0
        set Editing [dict create]
        foreach id [my ids] {
            if {[my dget $id tail 0] && [llength [my values $id]] == 0} {
                dict unset Revealed $id
            }
        }
        my refresh
    }

    method toggle {} { if {$Expanded} { my collapse } else { my expand } }

    # Open a facet's editor: reveal the facet if it is still on the rail, expand the
    # bar if it is collapsed (an editor has nowhere to draw in a collapsed bar), and
    # open the add affordance into the editor. It opens exactly what that affordance
    # opens, and on a facet at its cap the affordance is not drawn, so this opens
    # nothing either: an editor there would take a value the model has no room for
    # and drop it on commit, with nothing said. A `control` facet has no add
    # affordance to open, so revealing its row is the whole of it. The editor callback
    # lands the caret itself. Nothing is published: no value has changed.
    method begin_add {id} {
        my desc $id
        set was [my present]
        if {[my dget $id tail 0]} { dict set Revealed $id 1 }
        if {[my dget $id mode chips] eq "chips" && [my addable $id]} {
            dict set Editing $id 1
        }
        if {!$Expanded || [my present] ne $was} {
            set Expanded 1
            my refresh
        } else {
            my render_editor $id
        }
    }

    # Abandon an open add: the editor closes and its unconfirmed text goes with it. A
    # tail facet revealed only to be typed into returns to the rail, so a cancelled
    # add leaves no empty row behind.
    method cancel_add {id} {
        my desc $id
        dict unset Editing $id
        set was [my present]
        if {[my dget $id tail 0] && [llength [my values $id]] == 0} {
            dict unset Revealed $id
        }
        if {[my present] ne $was} { my refresh } else { my render_editor $id }
    }

    # ---- assembly ----------------------------------------------------------

    # Build the bar into `parent`, a frame the host created and packed. The head line
    # is built once and only ever reworded; the body is swapped whole by the
    # disclosure, so its children are the bar's to destroy.
    method setup {parent} {
        if {$Top ne ""} { error "facetbar: setup has already run" }
        set Top $parent
        my default_styles
        ttk::frame $Top.head
        pack $Top.head -side top -fill x
        ttk::label $Top.head.hd -style [my style heading] -anchor w
        pack $Top.head.hd -side left
        # -width 0 on every affordance the bar builds: ttk's stock button style
        # carries a nine to eleven character minimum width, which would blow a "+"
        # out to the size of a dialog button. A button's size is part of this
        # pattern's geometry, as its paddings are; the styles carry the look, and a
        # host that wants a bigger control gives its style more padding.
        ttk::button $Top.head.tog -style [my style toggle] -width 0 \
            -command [list [self] toggle]
        pack $Top.head.tog -side right
        ttk::frame $Top.body
        pack $Top.body -side top -fill x
        # A ttk style's configuration belongs to the theme it was made under, so a
        # host that switches themes drops the fallback dress and every chip and tag
        # goes flat and invisible: the failure default_styles exists to prevent,
        # arriving later. The dress is laid again on each theme change; it is
        # idempotent and backs off from a style the host owns, so a second pass over
        # it decides exactly what the first did.
        bind $Top <<ThemeChanged>> [list [namespace which my] default_styles]
        my refresh
    }

    # A host may destroy the frame while the object lives, so every method that draws
    # asks first whether there is anything left to draw into. The bar then goes inert
    # rather than raising into the host's next call.
    method drawable {} {
        return [expr {$Top ne "" && [winfo exists $Top]}]
    }

    # Redraw the body from the model.
    method refresh {} {
        if {![my drawable]} return
        foreach c [winfo children $Top.body] { destroy $c }
        set Flow  [dict create]
        set FlowW [dict create]
        if {$Expanded} { my render_rows } else { my render_strip }
        my render_head
        my flow_schedule
    }

    method active_count {} {
        set n 0
        foreach id [my ids] {
            if {[llength [my values $id]] > 0} { incr n }
        }
        return $n
    }

    method render_head {} {
        if {![my drawable]} return
        set txt [my opt heading]
        set n   [my active_count]
        set fmt [my opt countfmt]
        if {$n > 0 && $fmt ne ""} {
            if {$txt ne ""} { append txt "   " }
            append txt [format $fmt $n]
        }
        $Top.head.hd configure -text $txt
        $Top.head.tog configure -text \
            [expr {$Expanded ? [my opt collapsetext] : [my opt expandtext]}]
    }

    # The expanded body: one row per present facet, then the add rail.
    #
    # The three widgets of a row are gridded into the one rows container rather than
    # packed into a frame of their own, because grid column widths are shared by every
    # row of a container: the widest tag sets the column and each editor area starts
    # at the same x, with no facet told a width and no host measuring a font. Column 2
    # takes the slack, so an editor fills the bar.
    method render_rows {} {
        set rows $Top.body.rows
        ttk::frame $rows
        pack $rows -side top -fill x
        grid columnconfigure $rows 2 -weight 1
        set r 0
        foreach id [my present] {
            ttk::label $rows.tag_$id -style [my facet_style $id tagstyle tag] \
                -text [my dget $id label $id] -anchor center
            grid $rows.tag_$id -row $r -column 0 -sticky w -padx {0 6} -pady 1
            set conn [my dget $id conn ""]
            if {$conn ne ""} {
                ttk::label $rows.conn_$id -style [my style conn] -text $conn
                grid $rows.conn_$id -row $r -column 1 -sticky w -padx {0 6}
            }
            ttk::frame $rows.ed_$id
            grid $rows.ed_$id -row $r -column 2 -sticky ew
            # The window the lay is for comes from the event, %W, and not from a path
            # spliced into the script: bind substitutes its own % sequences in
            # whatever it is handed, so a path carrying one would arrive mangled and
            # the area would never be laid out again.
            bind $rows.ed_$id <Configure> \
                [list [namespace which my] flow_configure %W %w]
            my render_editor $id
            incr r
        }
        my render_rail
    }

    # One row's editor area, rebuilt in place. A `control` facet's area is the
    # caller's whole: the bar hands over the frame and the facet's values and draws
    # nothing itself, so the control shows the value and no chip repeats it.
    method render_editor {id} {
        if {![my drawable]} return
        set ed $Top.body.rows.ed_$id
        if {![winfo exists $ed]} return        ;# collapsed, or a hidden tail facet
        foreach c [winfo children $ed] { destroy $c }
        dict unset Flow $ed
        dict unset FlowW $ed
        if {[my dget $id mode chips] eq "control"} {
            {*}[my dget $id editor ""] $ed $id [my values $id]
            return
        }
        dict set Flow $ed [my render_chips $id $ed "" 1]
        my flow_schedule
    }

    # A facet's chips, in model order, joined by that facet's connector. `withadd` is
    # the row's own editor area, where the inline add affordance follows the chips;
    # the collapsed strip passes 0 and takes chips alone. `prefix` tells apart the
    # facets that share the strip; a row's area holds one facet and passes none.
    # Returns the {widget leftgap} items it drew, for the flow to lay out.
    method render_chips {id parent prefix withadd} {
        set cstyle [my facet_style $id chipstyle chip]
        set ctl    [my dget $id chipctl ""]
        set orword [my dget $id orword [my opt orword]]
        set items [list]
        set i 0
        foreach v [my values $id] {
            # A facet whose connector is the empty string is drawn without one: an
            # empty label would still take its two gaps, so a bar that asked for no
            # word between its chips would get a hole instead.
            if {$i > 0 && $orword ne ""} {
                ttk::label $parent.or$prefix$i -style [my style or] -text $orword
                lappend items [list $parent.or$prefix$i 4]
            }
            set chip $parent.c$prefix$i
            ttk::frame $chip -style $cstyle -padding {4 1}
            # The delete button packs first, so it anchors at the chip's left edge: a
            # sentence-long value grows its text rightward, and the affordance that
            # removes it has to stay where the eye and the pointer expect it.
            ttk::button $chip.x -style [my style del] -text [my opt deltext] \
                -width 0 -command [list [self] remove_value_at $id $i]
            pack $chip.x -side left -padx {0 2}
            if {$ctl ne ""} {
                {*}$ctl $chip.lead $id $i $v
                if {[winfo exists $chip.lead]} {
                    pack $chip.lead -side left -padx {0 4}
                }
            }
            ttk::label $chip.t -style [my style chiptext] -text [my chip_text $id $v]
            pack $chip.t -side left
            lappend items [list $chip [expr {$i > 0 ? 4 : 0}]]
            incr i
        }
        if {$withadd} {
            set w [my render_add $id $parent]
            if {$w ne ""} { lappend items [list $w [expr {$i > 0 ? 4 : 0}]] }
        }
        return $items
    }

    method chip_text {id value} {
        set fmt [my dget $id format ""]
        if {$fmt eq ""} { return $value }
        return [{*}$fmt $value]
    }

    # The inline add affordance: a button that opens, in place, into the facet's
    # editor. It reads "+" on an empty facet, and once the facet holds a value it
    # reads as one more joined to it, in whatever word that facet joins with. On a
    # single-valued facet it keeps reading "+", because there a commit replaces: an
    # affordance offering to join a second value to the first would be advertising
    # something the facet will not do. Returns the widget it built, or "" for a facet
    # that takes no more values.
    method render_add {id parent} {
        set cb [my dget $id editor ""]
        if {[::facetbar::getdef $Editing $id 0] && $cb ne ""} {
            ttk::frame $parent.add
            {*}$cb $parent.add $id [my values $id]
            return $parent.add
        }
        if {![my addable $id]} { return "" }
        set joins [expr {[llength [my values $id]] > 0 && [my dget $id max 0] != 1}]
        ttk::button $parent.add -style [my style add] -width 0 \
            -text [expr {$joins ? [my dget $id ortext [my opt ortext]] : [my opt addtext]}] \
            -command [list [self] begin_add $id]
        return $parent.add
    }

    # The add rail: one button per tail facet still out of use. A facet with no editor
    # is not offered there, because pressing its button would reveal a row with
    # nothing to type into and take the button away with it: a dead end for the life
    # of the bar. With no facet left to offer, the rail itself goes, rather than
    # ending the bar on a word with nothing after it.
    method render_rail {} {
        set hidden [lmap id [my ids] {
            expr {[my tail_hidden $id] && [my dget $id editor ""] ne "" ? $id : [continue]}
        }]
        if {[llength $hidden] == 0} return
        set rail $Top.body.rail
        ttk::frame $rail
        pack $rail -side top -fill x -pady {4 0}
        if {[my opt raillabel] ne ""} {
            ttk::label $rail.label -style [my style conn] -text [my opt raillabel]
            pack $rail.label -side left -padx {0 4}
        }
        foreach id $hidden {
            ttk::button $rail.b_$id -style [my style add] -width 0 \
                -text [my dget $id railtext "+ [my dget $id label $id]"] \
                -command [list [self] begin_add $id]
            pack $rail.b_$id -side left -padx {0 4}
        }
    }

    # The collapsed body: the applied facets, each as its tag and then its chips, all
    # of them siblings in one wrapping strip, so a long criterion breaks to a new line
    # rather than run off the edge. The chips keep their delete affordance here: this
    # state summarizes the criteria, it does not put them out of reach. With nothing
    # applied there is nothing to summarize, so the strip carries the one affordance
    # that opens the bar.
    method render_strip {} {
        set strip $Top.body.strip
        ttk::frame $strip
        pack $strip -side top -fill x
        bind $strip <Configure> [list [namespace which my] flow_configure %W %w]
        set items [list]
        foreach id [my ids] {
            if {[llength [my values $id]] == 0} continue
            ttk::label $strip.tag_$id -style [my facet_style $id tagstyle tag] \
                -text [my dget $id label $id] -anchor center
            lappend items [list $strip.tag_$id [expr {[llength $items] ? 12 : 0}]]
            lappend items {*}[my render_chips $id $strip _${id}_ 0]
        }
        if {[llength $items] == 0} {
            ttk::button $strip.add -style [my style add] -width 0 \
                -text [my opt emptytext] -command [list [self] expand]
            lappend items [list $strip.add 0]
        }
        dict set Flow $strip $items
    }

    # ---- the chip flow -----------------------------------------------------
    #
    # An area lays its items out left to right, breaking to a new line when the next
    # would not fit, and then tells its master the height that took. The measurements
    # it needs are the requested sizes the geometry managers work out at the next idle
    # moment, so the first lay of a freshly drawn area waits for it; every later width
    # change arrives on its own, as a <Configure>.

    method flow_schedule {} {
        if {$FlowIdle ne "" || $Top eq ""} return
        set FlowIdle [after idle [list [namespace which my] flow_all]]
    }

    method flow_all {} {
        set FlowIdle ""
        if {![my drawable]} return
        dict for {area items} $Flow {
            if {[winfo exists $area]} { my flow_area $area }
        }
    }

    # A width the area has already been laid at needs no second lay; and a height
    # change is the area's own doing, because the lay below asks for one, so re-laying
    # on that would be a loop with no end.
    method flow_configure {area w} {
        if {![dict exists $Flow $area] || ![winfo exists $area]} return
        if {[::facetbar::getdef $FlowW $area -1] == $w} return
        my flow_area $area
    }

    method flow_area {area} {
        set items [::facetbar::getdef $Flow $area {}]
        if {[llength $items] == 0} {
            $area configure -width 1 -height 1
            return
        }
        # Before the area has ever been laid out its width is 1, which is no width to
        # wrap in: lay one row, and wait for the <Configure> that maps it.
        set avail [winfo width $area]
        if {$avail <= 1} { set avail 100000 }
        set x 0
        set y 0
        set rowh 0
        set widest 1
        foreach it $items {
            lassign $it w gap
            set ww [winfo reqwidth $w]
            set wh [winfo reqheight $w]
            if {$ww > $widest} { set widest $ww }
            if {$x > 0 && $x + $gap + $ww > $avail} {
                set x 0
                set y [expr {$y + $rowh + 2}]
                set rowh 0
            } elseif {$x > 0} {
                incr x $gap
            }
            place $w -x $x -y $y
            incr x $ww
            if {$wh > $rowh} { set rowh $wh }
        }
        dict set FlowW $area [winfo width $area]
        # The height the lay took, and the width of the widest chip: the narrowest the
        # area can be without cutting a chip in half. What a chip wider than the bar's
        # room then does to a host that propagates is in the header, under Wrapping.
        $area configure -width $widest -height [expr {$y + $rowh}]
    }

    # Everything under the public contract is the bar's own business: a host binds to
    # what the header documents, and the rest stays free to change.
    unexport default_opts opt style facet_style validate_facets default_styles \
        ids desc dget tail_hidden present addable can_take_more check_max \
        sync_state after_change publish drawable refresh active_count \
        render_head render_rows render_editor render_chips chip_text render_add \
        render_rail render_strip flow_schedule flow_all flow_configure flow_area
}
