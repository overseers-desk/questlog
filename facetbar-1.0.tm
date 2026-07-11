package require Tcl 8.6-
package require Tk 8.6-
package provide facetbar 1.0

namespace eval ::facetbar {}

# One dict read with a default. Not every interpreter this module runs on has it
# as a built-in, so it is written here once and used throughout.
proc ::facetbar::getdef {d key dflt} {
    if {[dict exists $d $key]} { return [dict get $d $key] }
    return $dflt
}

# ::facetbar::FacetBar - a bar of criteria, kept as chips.
#
# The widget holds a set of criteria and shows each applied value as a chip the
# user can remove. It collapses to just those chips, expands into a full editor,
# and tells its owner whenever the set changes. What the criteria are FOR - what
# they select, restrict or colour - is the owner's business entirely: the bar
# stores values, draws them, hands them back, and asks nothing about them.
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
# door, `report_values`, which a `control` editor uses to say what it now holds: it
# takes the values and does NOT redraw that facet's editor, because the bar will
# not rebuild a control under the hand still on it. An owner changing a facet from
# outside uses `set_values` (or `set_model`), which does redraw it.
#
# Collapse summarizes, it never hides. A collapsed bar still draws every applied
# value as a chip, with its delete affordance live; what it takes away is the
# editors and the rail. The rule is the bar's own and needs nothing outside it: a
# chip the user cannot see is a chip the user cannot delete, and a bar that holds a
# value its user can neither reach nor count is a bar lying about what it holds.
# So the one state that could hide a value is the one state the widget will not
# enter. It is the same rule that makes a `control` facet without an editor an
# error: while the bar is expanded, that editor is the only thing that would draw
# the facet's value, and a facet drawn by nothing is a facet held in secret.
#
# The bar's grammar, and its limit. Within a facet, the values are drawn joined by
# that facet's connector word; between one facet and the next, nothing is drawn at
# all. The widget takes no position on what any of that means: the model is a
# mapping of facet to values, and how the criteria combine is the owner's to
# decide and, through the connective and connector words, the owner's to say.
#
# Lifecycle. `setup` runs once, on a frame the host creates, packs and in the end
# destroys; a second `setup` is an error, as is a frame that does not exist. Every
# widget the bar builds is a child of that frame: they are the bar's to create and
# to destroy, and the host adds none of its own to it. The exception is an editor
# area, which is handed to the caller's editor callback to fill, and which the bar
# empties before it draws that area again, so an editor's widgets are built fresh
# on each call and none of them outlives the frame. Destroying the object takes the
# bar's widgets with it and leaves the frame, which is the host's, standing empty.
# Destroying the frame first is allowed too: the object goes inert, and every
# method still answers rather than raising, so a host may tear the two down in
# either order.
#
# The look. Every widget the bar draws takes a ttk style named by a role in
# -styles, or per facet by `tagstyle` and `chipstyle`, and the module names no
# colour, no font and no padding of its own. Two of those roles have a look the
# pattern cannot do without - a chip and a tag must at least have an outline - so
# the bar dresses those two, but ONLY while they still carry the style names it
# ships with: `FacetChip.TFrame` and `FacetTag.TLabel` are the bar's, it dresses
# them when it is built and dresses them again on every theme change (a ttk style's
# configuration belongs to the theme it was made under and would vanish with it,
# taking the chips' outline along). To own the look of a chip, name a style of your
# own: a style the bar does not name, the bar does not touch, ever - which also
# means its dress across a theme change is yours to lay again, as any ttk style's
# is.
#
# A chip's padding rides its style with the rest of its look, which is where a host
# at a high DPI sets it. Tk will not hand a frame the padding its style names, so
# the bar reads it out of the style and applies it, rather than set a padding of its
# own that would beat the style's; a style that names none is given the bar's gaps,
# so an undressed chip is still a chip, and a style that wants none says {0 0}.
#
# Every gap the bar leaves is in -gaps, in pixels, and nowhere else: at a high DPI
# they are scaled, not hardcoded.
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
# the four tables below are the whole contract.
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
#           {id topping conn "carries"    editor topping_editor tail 1
#            orword "and" ortext "+ and"}
#       }
#   $bar setup .host                  ;# a frame the host created and packed
#   $bar set_model {colour {red blue}}
#
# Methods. Every one that takes a facet id refuses an id no descriptor declares,
# and every one that takes a value index refuses an index no value sits at.
#   setup frame           build the bar into a frame the host owns. Once only.
#   configure ?args?      no arguments reads every option, one reads that option,
#                         pairs set them. A set applies all of them or, if one is
#                         bad, none of them - including an option whose badness only
#                         shows when the bar redraws.
#   cget -opt             read one option.
#   model                 the whole model: every facet id, applied or not.
#   values id             one facet's values.
#   set_model m           the owner's door. It sets the whole model, so a facet the
#                         dict leaves out is a facet with no values, and
#                         `set_model {}` returns the bar to rest: nothing applied, no
#                         editor open, every tail facet back on the rail. Every id and
#                         every cap is checked before anything is written. It fires no
#                         change callback: the owner making the call is the one that
#                         would hear it.
#   set_values id vals    the owner's per-facet door: replaces that facet's values,
#                         redraws its editor from them, and publishes.
#   report_values id vals a `control` editor saying what it now holds. As set_values,
#                         except that it does not redraw the editor it came from,
#                         which is what keeps a control alive under the hand that just
#                         moved it. It is that editor's door and no one else's: on a
#                         `chips` facet it is an error, because the chips ARE that
#                         facet's drawing of its values and leaving them unredrawn
#                         would leave them lying about the model.
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
#                         collapsed. On a facet at its cap it opens no editor, because
#                         the affordance it stands in for is not drawn there either,
#                         and a value typed into an editor the model has no room for
#                         would be dropped on commit.
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
#                 format taking one count ("%d active"; "" suppresses it)
#   -orword       the connector drawn between one facet's chips ("or"), the default
#                 for the per-facet key of the same name
#   -addtext      the inline add affordance on a facet with no values ("+")
#   -ortext       the inline add affordance on a facet that has one ("+ or"), the
#                 default for the per-facet key of the same name
#   -deltext      the chip's delete affordance ("×")
#   -delside      which end of the chip that affordance sits at, left or right
#                 ("right", where a chip control is usually looked for). A chip can be
#                 wider than the bar it sits in (see Wrapping), and the far end of one
#                 that is will be out of view: a host whose values run long puts the
#                 delete at the near end with "left".
#   -raillabel    the leading word on the add rail ("Add"; "" draws none)
#   -emptytext    the affordance shown collapsed while nothing is applied ("+ add")
#   -expandtext   the disclosure while collapsed ("▸")
#   -collapsetext the disclosure while expanded ("▾")
#   -changecb     a command prefix invoked with the model dict every time the widget
#                 changes it, and only then: a write that moves no value publishes
#                 nothing, so a callback that writes the model back cannot drive the
#                 bar round in circles. The owner is told what the criteria now are,
#                 not which chip moved. `set_model` does not fire it, because the
#                 owner making that call already knows. The callback may raise, and
#                 the bar does not catch it: the model is updated and drawn before the
#                 callback runs, so the widget is left consistent either way, and the
#                 error travels as any error does - reported through Tk's background
#                 error handler, with the host's own stack, when the change came from
#                 a click or a keystroke, and propagated to the caller when it came
#                 from a direct call.
#   -styles       dict of role -> ttk style name; a partial dict merges over the
#                 defaults, and a role no widget has is an error. Roles: heading
#                 toggle tag conn or chip chiptext del add.
#   -gaps         dict of role -> pixels; a partial dict merges over the defaults, and
#                 a role no gap has is an error. Roles: chip (between the items of one
#                 chip area, and inside a chip), column (between the three columns of
#                 a row, and between a tag and its chips), row (above and below a row),
#                 line (between two wrapped lines of chips), group (between two facets
#                 in the collapsed summary), rail (around the add rail's buttons).
#                 Defaults {chip 4 column 6 row 1 line 2 group 12 rail 4}: a host at a
#                 high DPI scales them.
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
#             not drawn, no editor opens on it, a commit takes no more, and a
#             `set_model`, `set_values` or `report_values` that would break the cap is
#             refused. `max 1` is the single-valued facet: a committed value replaces
#             the one already there rather than joining it, so a criterion that can
#             only mean one thing cannot be made to mean two.
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
#             control inside the chip, belonging to the value it sits on (a two-way
#             switch on a `topping` chip, choosing light or extra). The caller creates
#             a widget at the path $w names, and the bar lays out whatever it finds
#             there; creating nothing leaves a plain chip. It reports an edit with
#             `set_value_at`.
#   railtext  the facet's button on the add rail (defaults to "+ <label>")
#   tagstyle  ttk style for this facet's tag, over the -styles default
#   chipstyle ttk style for this facet's chips, over the -styles default. The chip's
#             padding is read from this style, so it is where a host at a high DPI sets
#             it; a style that names no padding is given the bar's own gaps instead.
#
# Limits. Every chip carries a delete and every value can be removed: the bar has no
# locked criterion and no read-only state, so a host that must keep a value applied
# cannot say so here, and would have to put it back from the change callback and live
# with the flicker. Nor is a facet disableable: dropping it from -facets takes its
# values with it. Both are absent because the widget cannot own what they mean -
# whether a locked value still counts as the user's, whether a disabled facet still
# holds - and a knob whose meaning lives in the host is a knob the host should hold.
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
#
# Requires Tcl and Tk 8.6 or better.

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
            deltext      "×" \
            delside      right \
            raillabel    "Add" \
            emptytext    "+ add" \
            expandtext   "▸" \
            collapsetext "▾" \
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
                add      FacetAdd.TButton] \
            gaps         [dict create \
                chip 4  column 6  row 1  line 2  group 12  rail 4]]
    }

    # No arguments reads the options, one argument reads that option, pairs write.
    # A write is all or nothing. Every value is checked first, and only then is any
    # of it kept - and because an option can still be refused by the drawing (a
    # format ttk will not take, an editor that raises on a value it has never seen),
    # a redraw that fails rolls the whole configure back and re-lays the bar as it
    # was, rather than leave it standing on an option that breaks it on every later
    # draw. Options may be set before setup, the usual order, or after, where the
    # bar redraws on the spot.
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
                facets   { my validate_facets $val }
                countfmt { my validate_countfmt $val }
                delside  {
                    if {$val ni {left right}} {
                        error "facetbar: delside '$val' is neither left nor right"
                    }
                }
                styles   { set val [my merge_roles styles $val "style role" 0] }
                gaps     { set val [my merge_roles gaps   $val "gap"        1] }
            }
            dict set staged $k $val
        }
        set before $Opts
        set Opts $staged
        if {[catch {my apply_opts} err info]} {
            set Opts $before
            catch {my apply_opts}
            return -options $info $err
        }
        return
    }

    method apply_opts {} {
        my dress_styles
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
    method gap {role} { return [dict get [my opt gaps] $role] }

    # The style for one facet's tag or chips: the descriptor's own, else the bar's
    # role. A host tints a facet by naming a style, never by naming a colour.
    method facet_style {id key role} { return [my dget $id $key [my style $role]] }

    # A partial -styles or -gaps dict, merged over what the bar has. A role the bar
    # draws nothing with would merge in and change nothing at all, so it is refused
    # for the reason a misspelt descriptor key is.
    method merge_roles {which val what numeric} {
        if {[catch {dict size $val}]} {
            error "facetbar: -$which takes a dict of $what to value"
        }
        set have [dict get $Opts $which]
        dict for {role v} $val {
            if {![dict exists $have $role]} {
                error "facetbar: unknown $what '$role'; the roles are:\
                       [join [dict keys $have] {, }]"
            }
            if {$numeric && (![string is integer -strict $v] || $v < 0)} {
                error "facetbar: $what '$role' takes a count of pixels, not '$v'"
            }
        }
        return [dict merge $have $val]
    }

    # The count format is the one option whose badness would not show until the bar
    # next drew its heading, which could be a keystroke away and a long way from the
    # caller who set it. It is tried here, on a count, so it fails where it was
    # written.
    method validate_countfmt {fmt} {
        if {$fmt eq ""} return
        if {[catch {format $fmt 0} err]} {
            error "facetbar: countfmt '$fmt' is not a format taking one count: $err"
        }
    }

    # Check the descriptor list where the caller wrote it. A mistyped key would
    # otherwise surface as a row that silently never draws, or an editor never
    # called, which is a long walk back from the symptom.
    method validate_facets {facets} {
        if {[catch {llength $facets}]} { error "facetbar: -facets is not a list" }
        set known {id label conn format mode max dedupe orword ortext tail editor
                   chipctl railtext tagstyle chipstyle}
        set seen [list]
        foreach d $facets {
            if {[catch {dict size $d}]} {
                error "facetbar: facet descriptor is not a dict: $d"
            }
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
            # through nothing else, so one without an editor would hold a value the
            # user could neither see nor delete.
            if {$mode eq "control" && [::facetbar::getdef $d editor ""] eq ""} {
                error "facetbar: facet '$id': a control facet needs an editor,\
                       or its value would be held and never shown"
            }
            set max [::facetbar::getdef $d max 0]
            if {![string is integer -strict $max] || $max < 0} {
                error "facetbar: facet '$id': max '$max' is not a count"
            }
            foreach flag {tail dedupe} {
                set v [::facetbar::getdef $d $flag 1]
                if {![string is boolean -strict $v]} {
                    error "facetbar: facet '$id': $flag '$v' is not a true or false value"
                }
            }
        }
    }

    # The two styles the pattern cannot do without: a chip and a tag drawn in an
    # unconfigured style are invisible flat frames, and a bar of invisible chips is
    # not the pattern at all. The bar dresses them when it is built and again on
    # every theme change, because a ttk style's configuration belongs to the theme it
    # was made under. It dresses only the names it ships with: a style the host has
    # named is the host's, in this theme and in every other, and the bar does not
    # reach into it - which is what makes naming a style the way to own a chip's look,
    # padding and all.
    #
    # It writes only what is not already written. `ttk::style configure` announces
    # itself with <<ThemeChanged>>, which is the very event that brings this method
    # back: a dress that wrote unconditionally would answer the event it had just
    # raised, and two bars in one application would hand that ring back and forth
    # until the host's event loop stopped serving anything else. Writing only a
    # difference ends it on the first pass.
    method dress_styles {} {
        set mine [dict get [my default_opts] styles]
        foreach {role spec} {
            chip {-relief solid -borderwidth 1 -padding {4 1}}
            tag  {-relief solid -borderwidth 1 -padding {4 0}}
        } {
            set s [my style $role]
            if {$s ne [dict get $mine $role]} continue
            set cur [ttk::style configure $s]
            set dressed 1
            foreach {o v} $spec {
                if {![dict exists $cur $o] || [dict get $cur $o] ne $v} {
                    set dressed 0
                    break
                }
            }
            if {!$dressed} { ttk::style configure $s {*}$spec }
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
    # abandoning the add that revealed it, or collapsing the bar, puts it back.
    method tail_hidden {id} {
        if {![my dget $id tail 0]}          { return 0 }
        if {[::facetbar::getdef $Revealed $id 0]} { return 0 }
        return [expr {[llength [my values $id]] == 0}]
    }

    # The facets with a row, in descriptor order. The rail carries the ones without,
    # so a body whose `present` list has not changed has an unchanged rail.
    method present {} {
        return [lmap id [my ids] { expr {[my tail_hidden $id] ? [continue] : $id} }]
    }

    # Whether the facet will take another value through its editor. This gates all
    # three ways to that editor - the inline affordance, begin_add, and an editor
    # left open while the model moved under it - because an editor a value cannot
    # leave is an editor that eats what is typed into it. A single-valued facet
    # always says yes: a commit there replaces, so there is always something the
    # editor can do.
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
        if {[catch {llength $vals}]} {
            error "facetbar: facet '$id': values are not a list"
        }
        set max [my dget $id max 0]
        if {$max > 0 && [llength $vals] > $max} {
            error "facetbar: facet '$id' holds at most $max value(s),\
                   given [llength $vals]"
        }
    }

    # An index names one of the facet's values. Anything else is a caller's mistake,
    # and is told so here rather than passed down to lreplace to garble, or quietly
    # dropped as a no-op that looks like a working delete.
    method check_index {id idx} {
        if {![string is integer -strict $idx]} {
            error "facetbar: facet '$id': '$idx' is not a value index"
        }
        set n [llength [my values $id]]
        if {$idx < 0 || $idx >= $n} {
            error "facetbar: facet '$id' has no value at index $idx ($n applied)"
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

    # The owner's door: it replaces the whole model. A facet the dict leaves out is a
    # facet with no values, and `set_model {}` returns the bar to rest - nothing
    # applied, no editor open, every tail facet back on the rail. Every id and every
    # cap is checked before anything is written, so a bad call cannot leave half a
    # model behind. The bar redraws whole, and every editor is rebuilt from the new
    # values. It fires no change callback: the owner making this call is the one that
    # would hear it.
    method set_model {m} {
        if {[catch {dict size $m}]} { error "facetbar: the model is not a dict" }
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
        return
    }

    # The owner's per-facet door: replace one facet's values and redraw its editor
    # from them, so a control shows what the owner has just set.
    method set_values {id vals} {
        my desc $id
        my check_max $id $vals
        if {$vals eq [my values $id]} return
        set was [my present]
        dict set Model $id $vals
        my after_change $id $was 1
        return
    }

    # A `control` editor's door: the editor telling the bar what it now holds. The
    # one thing it does not do is redraw that facet's editor, because that editor is
    # where this change came from, and rebuilding it would destroy the control under
    # the hand that just moved it. A `chips` facet has no such editor to spare: its
    # chips are the bar's drawing of its values, so not redrawing them would leave
    # them showing values the model no longer holds. Its editor commits with
    # add_value, and an owner writing from outside uses set_values.
    method report_values {id vals} {
        my desc $id
        if {[my dget $id mode chips] eq "chips"} {
            error "facetbar: facet '$id' is a chips facet: its editor commits with\
                   add_value, and an owner writes it with set_values.\
                   report_values is a control editor's door"
        }
        my check_max $id $vals
        if {$vals eq [my values $id]} return
        set was [my present]
        dict set Model $id $vals
        # An editor that reports keeps its row. A tail facet loses its row when its
        # last value goes, and the row would take the editor with it - so a control
        # wound down to a value of "none" would be destroyed from inside its own
        # callback, which is the one thing this door exists to prevent. The row it
        # was drawn in stays until something other than the editor closes it.
        if {[my dget $id tail 0] && $id in $was} { dict set Revealed $id 1 }
        my after_change $id $was 0
        return
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
        return
    }

    # Remove the value at $idx: the chip whose delete affordance was pressed. By
    # index, not by value: a per-value control can leave two chips value-equal, and a
    # by-value delete would drop the first twin rather than the chip the user pressed.
    method remove_value_at {id idx} {
        my desc $id
        my check_index $id $idx
        set was [my present]
        dict set Model $id [lreplace [my values $id] $idx $idx]
        my after_change $id $was 1
        return
    }

    # Rewrite one value in place: the per-value control's door, for when what the
    # value applies to has changed but the value itself has not moved.
    method set_value_at {id idx value} {
        my desc $id
        my check_index $id $idx
        set vals [my values $id]
        if {[lindex $vals $idx] eq $value} return
        set was [my present]
        lset vals $idx $value
        dict set Model $id $vals
        my after_change $id $was 1
        return
    }

    # Every path that changes the model lands here, and only a path that really
    # changed it: redraw what the change can touch, then tell the owner. Redrawing
    # the one facet, rather than the whole body, is what keeps another row's editor
    # alive - a stepper mid-step, an entry mid-word - while this row's chip is
    # deleted. Only a change in which facets have rows (a tail facet's first value, or
    # a row whose last value left) re-lays the body, and the rail rides that same
    # test, because the rail carries exactly the facets the rows do not.
    #
    # `redraw` is 0 on the one path that must not touch the facet's editor: a control
    # editor reporting, through report_values, what it now holds.
    method after_change {id was redraw} {
        # A value the change put out of reach of the editor closes it: an editor open
        # on a facet that can take no more would swallow whatever is typed into it.
        if {[::facetbar::getdef $Editing $id 0] && ![my addable $id]} {
            dict unset Editing $id
        }
        if {!$Expanded || [my present] ne $was} {
            my refresh
        } else {
            if {$redraw} { my render_editor $id }
            my render_head
        }
        my publish
        return
    }

    # The change is drawn before the owner hears of it, so the widget is consistent
    # whatever the callback does, raising included. Its error is not caught: it
    # travels as any error does, which at event time is Tk's background error handler,
    # with the host's own stack intact. Its return value is not the bar's to pass on.
    method publish {} {
        set cb [my opt changecb]
        if {$cb eq ""} return
        {*}$cb [my model]
        return
    }

    # ---- disclosure --------------------------------------------------------

    method expanded {} { return $Expanded }

    method expand {} {
        if {$Expanded} return
        set Expanded 1
        my refresh
        return
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
        return
    }

    method toggle {} { if {$Expanded} { my collapse } else { my expand } }

    # Open a facet's editor: reveal the facet if it is still on the rail, expand the
    # bar if it is collapsed (an editor has nowhere to draw in a collapsed bar), and
    # open the add affordance into the editor. It opens exactly what that affordance
    # opens, and on a facet at its cap the affordance is not drawn, so this opens no
    # editor either. A `control` facet has no add affordance to open, so revealing its
    # row is the whole of it. The editor callback lands the caret itself. Nothing is
    # published: no value has changed.
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
        return
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
        return
    }

    # ---- assembly ----------------------------------------------------------

    # Build the bar into `parent`, a frame the host created and packed. The head line
    # is built once and only ever reworded; the body is swapped whole by the
    # disclosure, so its children are the bar's to destroy.
    method setup {parent} {
        if {$Top ne ""} { error "facetbar: setup has already run" }
        if {![winfo exists $parent]} {
            error "facetbar: setup: no such window '$parent'"
        }
        set Top $parent
        my dress_styles
        ttk::frame $Top.head
        pack $Top.head -side top -fill x
        ttk::label $Top.head.hd -style [my style heading] -anchor w
        pack $Top.head.hd -side left
        # -width 0 on every affordance the bar builds: ttk's stock button style
        # carries a nine to eleven character minimum width, which would blow a "+"
        # out to the size of a dialog button. A button's size is part of this
        # pattern's geometry, as its gaps are; the styles carry the look, and a host
        # that wants a bigger control gives its style more padding.
        ttk::button $Top.head.tog -style [my style toggle] -width 0 \
            -command [list [self] toggle]
        pack $Top.head.tog -side right
        ttk::frame $Top.body
        pack $Top.body -side top -fill x
        # A ttk style's configuration belongs to the theme it was made under, so on a
        # theme change the bar lays its own two styles again. It touches no other.
        bind $Top <<ThemeChanged>> [list [namespace which my] dress_styles]
        my refresh
        return
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
        set col [my gap column]
        ttk::frame $rows
        pack $rows -side top -fill x
        grid columnconfigure $rows 2 -weight 1
        set r 0
        foreach id [my present] {
            ttk::label $rows.tag_$id -style [my facet_style $id tagstyle tag] \
                -text [my dget $id label $id] -anchor center
            grid $rows.tag_$id -row $r -column 0 -sticky w \
                -padx [list 0 $col] -pady [my gap row]
            set conn [my dget $id conn ""]
            if {$conn ne ""} {
                ttk::label $rows.conn_$id -style [my style conn] -text $conn
                grid $rows.conn_$id -row $r -column 1 -sticky w -padx [list 0 $col]
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
        dict set Flow $ed [my render_chips $id $ed "" 0 1]
        my flow_schedule
    }

    # A facet's chips, in model order, joined by that facet's connector. `withadd` is
    # the row's own editor area, where the inline add affordance follows the chips;
    # the collapsed strip passes 0 and takes chips alone. `prefix` tells apart the
    # facets that share the strip; a row's area holds one facet and passes none.
    # `lead` is the gap before the first chip, which in the strip follows the facet's
    # tag. Returns the {widget leftgap} items it drew, for the flow to lay out.
    method render_chips {id parent prefix lead withadd} {
        set cstyle [my facet_style $id chipstyle chip]
        set ctl    [my dget $id chipctl ""]
        set orword [my dget $id orword [my opt orword]]
        set gap    [my gap chip]
        set items [list]
        set i 0
        foreach v [my values $id] {
            # A facet whose connector is the empty string is drawn without one: an
            # empty label would still take its two gaps, so a bar that asked for no
            # word between its chips would get a hole instead.
            if {$i > 0 && $orword ne ""} {
                ttk::label $parent.or$prefix$i -style [my style or] -text $orword
                lappend items [list $parent.or$prefix$i $gap]
            }
            set chip $parent.c$prefix$i
            # A chip's padding is part of the look, so the chip's style carries it
            # with the rest. A ttk::frame will not take padding from a style by
            # itself, so the bar reads it out of the style and hands it to the widget
            # rather than set a padding of its own, which would beat the style's and
            # leave the style carrying a look it could not apply. A style that names
            # no padding gets the bar's gaps, so a chip in an undressed style is a
            # chip and not a hairline; a style that wants none says {0 0}.
            ttk::frame $chip -style $cstyle
            set pad [ttk::style lookup $cstyle -padding]
            if {$pad eq ""} { set pad [list $gap [my gap row]] }
            $chip configure -padding $pad
            ttk::button $chip.x -style [my style del] -text [my opt deltext] \
                -width 0 -command [list [self] remove_value_at $id $i]
            if {[my opt delside] eq "left"} {
                pack $chip.x -side left -padx [list 0 $gap]
            } else {
                pack $chip.x -side right -padx [list $gap 0]
            }
            if {$ctl ne ""} {
                {*}$ctl $chip.lead $id $i $v
                if {[winfo exists $chip.lead]} {
                    pack $chip.lead -side left -padx [list 0 $gap]
                }
            }
            ttk::label $chip.t -style [my style chiptext] -text [my chip_text $id $v]
            pack $chip.t -side left
            lappend items [list $chip [expr {$i > 0 ? $gap : $lead}]]
            incr i
        }
        if {$withadd} {
            set w [my render_add $id $parent]
            if {$w ne ""} { lappend items [list $w [expr {$i > 0 ? $gap : $lead}]] }
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
    # something the facet will not do. A facet that can take no more value has none of
    # this: no button, and no open editor either, whichever way that editor was opened.
    # Returns the widget it built, or "".
    method render_add {id parent} {
        if {![my addable $id]} { return "" }
        if {[::facetbar::getdef $Editing $id 0]} {
            ttk::frame $parent.add
            {*}[my dget $id editor ""] $parent.add $id [my values $id]
            return $parent.add
        }
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
        set gap  [my gap rail]
        set rail $Top.body.rail
        ttk::frame $rail
        pack $rail -side top -fill x -pady [list $gap 0]
        if {[my opt raillabel] ne ""} {
            ttk::label $rail.label -style [my style conn] -text [my opt raillabel]
            pack $rail.label -side left -padx [list 0 $gap]
        }
        foreach id $hidden {
            ttk::button $rail.b_$id -style [my style add] -width 0 \
                -text [my dget $id railtext "+ [my dget $id label $id]"] \
                -command [list [self] begin_add $id]
            pack $rail.b_$id -side left -padx [list 0 $gap]
        }
    }

    # The collapsed body: the applied facets, each as its tag and then its chips, all
    # of them siblings in one wrapping strip, so a long criterion breaks to a new line
    # rather than run off the edge. The chips keep their delete affordance here: this
    # state summarizes the values, it does not put them out of reach. With nothing
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
            lappend items [list $strip.tag_$id \
                [expr {[llength $items] ? [my gap group] : 0}]]
            lappend items {*}[my render_chips $id $strip _${id}_ [my gap column] 0]
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

    # The lay is put at the BACK of the idle queue every time, cancelling any lay
    # already waiting there. The sizes it measures are the ones the geometry managers
    # work out in that same queue, when the chips it is about to place were packed:
    # a lay left where an earlier render put it would run ahead of the packing done by
    # a later one, and measure that render's chips at the 1x1 they have not yet grown
    # out of. Two changes in one turn of the event loop - a host applying two criteria
    # in one script - is all it takes.
    method flow_schedule {} {
        if {$Top eq ""} return
        if {$FlowIdle ne ""} { after cancel $FlowIdle }
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
        set line [my gap line]
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
                set y [expr {$y + $rowh + $line}]
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
    unexport default_opts apply_opts opt style gap facet_style merge_roles \
        validate_countfmt validate_facets dress_styles ids desc dget tail_hidden \
        present addable can_take_more check_max check_index sync_state after_change \
        publish drawable refresh active_count render_head render_rows render_editor \
        render_chips chip_text render_add render_rail render_strip \
        flow_schedule flow_all flow_configure flow_area
}
