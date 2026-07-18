package require Tcl 8.6-
package require Tk 8.6-
package provide querybuilder 0.1.0

namespace eval ::querybuilder {}

# One dict read with a default, for interpreters without the built-in.
proc ::querybuilder::getdef {d key dflt} {
    if {[dict exists $d $key]} { return [dict get $d $key] }
    return $dflt
}

# ::querybuilder::QueryBuilder - a bar of structured criteria, kept as chips.
#
# The widget holds a set of criteria and shows each one as a chip the user can
# remove. It collapses to just those chips, expands into a full editor, and
# tells its owner whenever a user gesture changes the set. What the criteria
# are FOR - what they select, restrict or colour - is the owner's business
# entirely: the builder stores values, draws them, hands them back, and asks
# nothing about them. It is one half of the shared query contract in
# docs/query-contract.md, the half that owns the `criteria` key; the other
# half is the search field, and neither knows the other.
#
# Vocabulary, and the whole of the widget's world view:
#   facet     one criterion type. A descriptor dict declares it. The widget
#             learns its kind, its wording, its operator vocabulary and how to
#             reach its editor, and nothing else.
#   criterion one applied instance of a facet, carried as the dict
#             {id <n> kind <k> op <o> value <v>}:
#     id      the criterion's stable identity, an integer the builder assigns
#             at add time and never changes for the criterion's life. Removal
#             never renumbers the survivors, and an edit preserves the id, so
#             an id held across either stays good.
#     kind    the facet the criterion belongs to.
#     op      one word of the facet's declared operator vocabulary, or "" on a
#             facet declared without one.
#     value   the applied value. Opaque: the widget stores it, hands the whole
#             criterion to the caller's formatter for the chip's text, and
#             compares it with `in` to spot a repeat. It may be a string, a
#             pair, any Tcl value.
#   fragment  the dict {criteria <list of criterion dicts>}: what `fragment`
#             returns and the change callback carries, in facet declaration
#             order and then value order. The `criteria` key is always
#             present, so `dict get` on it is safe unconditionally.
#   model     dict of kind -> list of values, the same criteria without their
#             ids and ops: the owner's bulk read and write shape.
#
# What the widget owns: the layout (a heading line with the disclosure, one row
# per facet holding a type tag, a connective word and an editor area, and an add
# rail offering the tail facets not yet in use); the chips (their connector, their
# delete affordance, their inline add, their wrapping); the collapse/expand
# disclosure; the criterion ids; and the callbacks that tell the owner what the
# user did. Everything else - what a value is, how it is edited, how it prints -
# arrives from the caller as a descriptor. The widget never inspects a value.
#
# When callbacks fire: the one rule. Every callback fires on user action only,
# and every programmatic entry point is quiet - set_model, set_values,
# report_values, set_value_at, remove_value_at, add_criterion, remove_criterion,
# set_fragment, reset, expand, collapse, toggle, all of them. A user gesture in
# the bar - a chip's delete, an editor's commit, the disclosure - fires
# -changecommand or -foldcommand as ever. The rule exists because answering a
# query may be expensive: only the consumer knows when a batch of programmatic
# mutations is complete, so only the consumer decides when to react, and it says
# so by calling `publish` (fire the change callback once, now) or its own answer
# path. A widget that fired mid-batch would hand out a stale, half-built query.
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
# current state every time its row is drawn, so a value deleted from a chip while
# the bar was collapsed is already gone from the control when the row comes back.
# There is deliberately no second path by which the widget tells an editor "your
# value changed": that path is the row being drawn. The exception is exactly one
# door, `report_values`, which a `control` editor uses to say what it now holds: it
# takes the values and does NOT redraw that facet's editor, because the bar will
# not rebuild a control under the hand still on it. An owner changing a facet from
# outside uses `set_values` (or `set_model`), which does redraw it.
#
# Collapse summarizes, it never hides. A collapsed bar still draws every applied
# criterion as a chip, with its delete affordance live; what it takes away is the
# editors and the rail. The rule is the bar's own and needs nothing outside it: a
# chip the user cannot see is a chip the user cannot delete, and a bar that holds a
# value its user can neither reach nor count is a bar lying about what it holds.
# So the one state that could hide a value is the one state the widget will not
# enter. It is the same rule that makes a `control` facet without an editor an
# error: while the bar is expanded, that editor is the only thing that would draw
# the facet's value, and a facet drawn by nothing is a facet held in secret.
# Folding is display only: it moves no value, the fragment before and after a
# fold is identical, and a fold handler has no reason to reach the answer path.
#
# The bar's grammar, and its limit. Within a facet, the values are drawn joined by
# that facet's connector word; between one facet and the next, nothing is drawn at
# all. The widget takes no position on what any of that means: how the criteria
# combine is the owner's to decide and, through the connective and connector
# words, the owner's to say.
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
# ships with: `QBChip.TFrame` and `QBTag.TLabel` are the bar's, it dresses them
# when it is built and dresses them again on every theme change (a ttk style's
# configuration belongs to the theme it was made under and would vanish with it,
# taking the chips' outline along). To own the look of a chip, name a style of your
# own: a style the bar does not name, the bar does not touch, ever - which also
# means its dress across a theme change is yours to lay again, as any ttk style's
# is.
#
# A chip's padding rides its style with the rest of its look. Tk will not hand a
# frame the padding its style names, so the bar reads it out of the style and applies
# it, rather than set a padding of its own that would beat the style's; a style that
# names none is given the bar's gaps, so an undressed chip is still a chip, and a
# style that wants none says {0 0}.
#
# Every gap the bar leaves is in -gaps, in pixels, and nowhere else.
#
# The arrangement. A head line carrying the heading and the disclosure; below it, one
# row per facet - a tag, a connective word, an editor area - in three columns that
# line up down the bar; the add rail last. The disclosure can be taken away
# (-disclosure 0), and with no heading either the head line goes with it, which leaves
# a plain strip of chips or a plain set of editor rows. The rest of the arrangement is
# fixed: the columns line up because a bar whose editors start at different x is a
# list of unrelated controls; the chips wrap where they are because that is the one
# place a value can be shown and removed; the rail is last because it offers what is
# not yet there.
#
# Widget paths, stable, so a host can reach a widget the bar built (to hang a
# tooltip on a chip, to drive one from a test):
#   $top.head                    the heading line
#     $top.head.hd                 the heading text, with the active count appended
#     $top.head.tog                the disclosure button
#   $top.body                    the body, swapped whole by the disclosure
#     expanded:
#       $top.body.rows             the editor rows, three aligned grid columns
#         .tag_<kind>                the type tag
#         .conn_<kind>               the connective word
#         .ed_<kind>                 the editor area: the chips and their inline
#                                    add, or a `control` facet's own editor
#         .ed_<kind>.c<i>            one chip, and .add the inline add affordance
#         .ed_<kind>.or<i>           the connector word drawn before chip i
#       $top.body.rail             the add rail
#         .label                     its leading word
#         .b_<kind>                  one hidden tail facet's reveal button
#     collapsed:
#       $top.body.strip            the chip summary
#         .tag_<kind>                an applied facet's tag
#         .c_<kind>_<i>              one of its chips
#         .or_<kind>_<i>             the connector word drawn before that chip
#         .add                       the add affordance, when nothing is applied
# A chip holds `x` (its delete), `lead` (the optional per-value control) and `t`
# (its text). Every other method of the class, and every variable, is unexported:
# the paths above and the tables below are the whole contract.
#
# Usage:
#   ::tcl::tm::path add $dir
#   package require querybuilder
#
#   set qb [::querybuilder::QueryBuilder new]
#   $qb configure -heading "Show the items that…" \
#       -changecommand [list apply_criteria] -facets {
#           {kind colour  conn "is"         format colour_chip editor colour_editor}
#           {kind size    conn "is at most" format size_chip editor size_editor
#            mode control max 1}
#           {kind flag    conn "carries"    editor flag_editor tail 1
#            op {any all} defaultop any orword "and" ortext "+ and"}
#       }
#   $qb setup .host                   ;# a frame the host created and packed
#   $qb set_fragment {criteria {{kind colour op "" value red}}}
#
# Methods. Every one that takes a kind refuses one no descriptor declares, every
# one that takes a value index refuses an index no value sits at, and every one
# that takes a criterion id refuses an id no criterion carries: a caller holding
# a dead id has a bookkeeping bug worth hearing about. None of them fires a
# callback - every door below is programmatic - and every door that changes a
# value draws the change before it returns, so a drawing that raises (a
# formatter meeting a value it cannot print) puts the value back where it came
# from, re-lays the bar, and lets the error reach the caller with the widget
# consistent.
#
#   The shared idiom (docs/query-contract.md):
#   fragment              the current fragment: {criteria <criterion dicts>}, in
#                         facet declaration order then value order. The criteria
#                         key is always present, applied or not.
#   set_fragment frag     seed criteria quietly. A PARTIAL dict merges: a dict
#                         without a `criteria` key changes nothing, and keys the
#                         widget does not own are ignored, so a whole saved query
#                         dict feeds the builder verbatim. The ids a restored
#                         fragment carries are honored, and the id generator
#                         allocates past them, so restore keeps every id stable
#                         and collision-free; a criterion arriving without an id
#                         is assigned a fresh one, and one without an op gets the
#                         facet's defaultop. Every kind, op and cap is checked
#                         before anything is written.
#   reset                 back to the empty fragment: no criteria, no editor
#                         open, every tail facet on the rail.
#   publish               fire -changecommand once with the current fragment:
#                         the one door a consumer uses to react to its own batch
#                         of quiet mutations through the widget's own code path.
#   setup frame           build the bar into a frame the host owns. Once only,
#                         though a build that fails hands the frame back and can
#                         be retried.
#   configure ?args?      no arguments reads every option, one reads that option,
#                         pairs set them. A set applies all of them or, if one is
#                         bad, none of them - including an option whose badness
#                         only shows when the bar redraws, and including the
#                         criteria, which a facet list rewrites and a rollback
#                         puts back.
#   cget -opt             read one option.
#
#   The criteria, by id:
#   add_criterion kind value ?op?
#                         add one criterion and return its id. An omitted op
#                         means the facet's defaultop ("" on a facet with no
#                         vocabulary); an op outside the vocabulary, or a kind
#                         outside the declaration, is an error raised at the
#                         call. On a `control` facet it is an error - that
#                         facet's values are its editor's to shape, through
#                         report_values, and an owner writes them with
#                         set_values. The facet's own rules apply as they do at
#                         its editor: on a `max 1` facet the new criterion takes
#                         the place of the one held (a fresh id: the old
#                         criterion is gone, not edited); a repeat of a value a
#                         deduping facet already holds adds nothing and returns
#                         the id it already has; a facet at a cap above one
#                         refuses outright, since a call that must return an id
#                         has no way to quietly add nothing.
#   remove_criterion id   drop the criterion the id names, whatever facet it
#                         sits in. The survivors keep their ids.
#   format criterion      the chip text the builder itself would draw for the
#                         criterion: the facet's `format` command applied, the
#                         raw value as the fallback. A consumer mirroring
#                         criteria elsewhere renders the same labels the chips
#                         carry.
#   kinds                 the declared kind names, in declaration order.
#
#   The owner's doors, in the model shape (kind -> values, no ids or ops):
#   model                 the whole model: every kind, applied or not.
#   values kind           one facet's values.
#   set_model m           the bulk write: it sets the whole model, so a facet the
#                         dict leaves out is a facet with no values, and
#                         `set_model {}` returns the bar to rest. Every kind and
#                         every cap is checked before anything is written. A
#                         value at a position the facet already filled keeps
#                         that criterion's id and op - an edit preserves
#                         identity - and a position past the old list is a new
#                         criterion, freshly numbered, at the facet's defaultop.
#   set_values kind vals  the per-facet write: replaces that facet's values (ids
#                         and ops carried positionally, as set_model does) and
#                         redraws its editor from them.
#   report_values kind vals
#                         a `control` editor saying what it now holds. As
#                         set_values, except that it does not redraw the editor
#                         it came from, which is what keeps a control alive
#                         under the hand that just moved it. It is that editor's
#                         door and no one else's: on a `chips` facet it is an
#                         error, because the chips ARE that facet's drawing of
#                         its values and leaving them unredrawn would leave them
#                         lying about the model. Quiet like every programmatic
#                         door: the host that owns the control publishes, or
#                         answers on its own path.
#   set_value_at kind i v rewrite the value at index i in place, keeping its id
#                         and op: what a chip's own per-value control does. The
#                         host that owns that control publishes.
#   remove_value_at kind i
#                         drop the value at index i, as remove_criterion does by
#                         id. (The chip's delete affordance is the builder's own
#                         gesture and fires -changecommand itself; this door,
#                         like every other, is quiet.)
#
#   The editors and the disclosure:
#   begin_add kind        open a facet's editor as its add affordance would:
#                         reveal the facet if it waits on the rail, expand the
#                         bar if it is collapsed. It opens exactly what that
#                         affordance opens and nothing more, so on a facet at
#                         its cap, or one with no editor, it opens nothing and
#                         reveals nothing: an editor the model has no room for
#                         would drop what is typed into it, and a revealed row
#                         with no editor is one nothing on the bar can dismiss.
#   cancel_add kind       abandon an open add. The editor closes and its
#                         unconfirmed text goes with it; a tail facet revealed
#                         only to be typed into returns to the rail. This is
#                         what the builder's own Escape binding calls.
#   expand, collapse, toggle   the disclosure, quietly; the user's own click on
#                         it fires -foldcommand.
#   expanded              1 while the editor rows show, 0 while collapsed.
#   collapsed             the inverse, matching what -foldcommand carries.
#
# Options (`configure -opt value ...`):
#   -facets       the ordered descriptor list; that order is the rows' reading
#                 order. Checked at the door: a duplicate kind, an unknown key, a
#                 kind that cannot name a widget, an op vocabulary without a
#                 defaultop, or a `control` facet with no editor is an error
#                 where it was written, and so is a `max` that the values a
#                 facet already holds would break: a facet list is a route into
#                 the model, and it meets the model's rules. A facet the new
#                 list drops takes its criteria, its revealed row and its open
#                 editor with it, and no change callback fires for them:
#                 swapping the facet list is a change to what the bar can hold,
#                 which the owner is making, and not a change to the criteria
#                 the user applied.
#   -heading      the heading on the head line ("" draws none)
#   -countfmt     appended to the heading while the count is above zero: a format
#                 taking one count ("%d active"; "" suppresses it). The count is
#                 the number of values the countable facets hold.
#   -countables   the facets the count sums over: a list of kinds, or ""
#                 (default) for every facet. A bar that counts only some of its
#                 facets names them here; one that counts all of them leaves it
#                 empty. A kind no descriptor declares is refused, as it is at
#                 every door that names a facet.
#   -orword       the connector drawn between one facet's chips ("or"), the default
#                 for the per-facet key of the same name
#   -addtext      the inline add affordance on a facet with no values ("+")
#   -ortext       the inline add affordance on a facet that has one ("+ or"), the
#                 default for the per-facet key of the same name
#   -deltext      the chip's delete affordance ("×")
#   -delside      which end of the chip that affordance sits at, left or right
#                 ("right", where a chip control is usually looked for). A chip can be
#                 wider than the bar it sits in (see Wrapping), and the far end of one
#                 that is goes out of view; "left" keeps the affordance at the near end.
#   -raillabel    the leading word on the add rail ("Add"; "" draws none)
#   -emptytext    the affordance shown collapsed while nothing is applied ("+ add")
#   -expandtext   the disclosure while collapsed ("▸")
#   -collapsetext the disclosure while expanded ("▾")
#   -disclosure   1 (default) to draw the disclosure button, 0 to leave it out. With it
#                 out, the bar stays in whichever state it is in unless the owner calls
#                 expand or collapse, and a bar with no heading either has no head line
#                 at all: an always-expanded set of editor rows, or a bare chip strip.
#   -changecommand a command prefix invoked with the fragment appended, every
#                 time a user gesture in the bar changes the criteria, and only
#                 then: a chip's delete, an editor's commit. A gesture that
#                 moves no value publishes nothing, and no programmatic door
#                 publishes anything (the one rule, above); `publish` fires it
#                 on demand. The callback may raise, and the bar does not catch
#                 it: the change is drawn before the callback runs, so the
#                 widget is left consistent either way, and the error travels
#                 as any error does - through Tk's background error handler,
#                 with the host's own stack, when the gesture was a click or a
#                 keystroke, and to the caller when `publish` was the route.
#   -foldcommand  a command prefix invoked with the new fold state appended (1
#                 collapsed, 0 expanded) on every user fold change, collapse
#                 and expand alike: the disclosure, or the empty collapsed
#                 bar's add affordance opening it. Programmatic expand,
#                 collapse and toggle are quiet.
#   -styles       dict of role -> ttk style name; a partial dict merges over the
#                 defaults, and a role no widget has is an error. Roles: heading
#                 toggle tag conn or chip chiptext del add.
#   -gaps         dict of role -> pixels; a partial dict merges over the defaults, and
#                 a role no gap has is an error. Roles: chip (between the items of a
#                 chip area, and between a chip's own parts), column (between the three
#                 columns of a row, and between a tag and its chips), row (above and
#                 below a row), line (between two wrapped lines of chips), group
#                 (between two facets in the collapsed summary), rail (around the add
#                 rail's buttons). Defaults {chip 4 column 6 row 1 line 2 group 12
#                 rail 4}. A chip whose style names no padding is padded {chip row}.
#
# Descriptor keys (only `kind` is required):
#   kind      the facet's name, and its criteria's `kind`. It names widgets,
#             rides into a binding script, and is made to embed in a consumer's
#             promotion pattern, so it must be a plain word: letters, digits
#             and underscores.
#   label     the word on the type tag (defaults to the kind)
#   conn      the connective word between the tag and the editor ("" draws none)
#   format    a command prefix, `{*}$format $criterion` -> the chip's text,
#             handed the whole criterion dict so a facet with an operator
#             vocabulary can draw the op into the chip. Defaults to the raw
#             value. A formatter shared by several facets reads the kind out of
#             the criterion.
#   op        the facet's operator vocabulary, a list of words carried per
#             criterion. Omitted for a facet with no operators, whose criteria
#             carry op "". Declaring it requires `defaultop`.
#   defaultop what an omitted op means, at add_criterion and at a fresh add's
#             commit. Required when `op` is declared, refused without it, and
#             must be one of the vocabulary's words.
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
#   editor    a command prefix building this facet's editor - the protocol is
#             its own section, below. In `chips` mode it builds the control the
#             add affordance opens into; in `control` mode it is the whole
#             editor area, and it reports what it holds with `report_values`. A
#             `chips` facet with no editor gets no add affordance: its values
#             are the owner's to set, and the bar shows them and deletes them.
#   chipctl   a command prefix, `{*}$chipctl $w $kind $index $value`, for an optional
#             control inside the chip, belonging to the value it sits on, as a swatch
#             belongs on a colour facet's chip.
#             The caller creates a widget at the path $w names, and the bar lays out
#             whatever it finds there; creating nothing leaves a plain chip. It reports
#             an edit with `set_value_at`, and the host publishes it.
#   railtext  the facet's button on the add rail (defaults to "+ <label>")
#   tagstyle  ttk style for this facet's tag, over the -styles default
#   chipstyle ttk style for this facet's chips, over the -styles default. The chip's
#             padding is read from this style; one that names none is padded from -gaps.
#
# The editor protocol. An editor is a command prefix, called when the user opens
# the facet's add row - and, in `control` mode, whenever the row is drawn:
#
#   {*}$editor $frame $initial $commit $cancel
#
#   $frame    an empty ttk frame inside the builder's row: the editor packs its
#             widgets there and owns nothing else. It should take the keyboard
#             focus itself, because only it knows which of the widgets it built
#             takes typing.
#   $initial  the criterion dict being edited, or an empty dict for a fresh
#             add. A single-valued facet already holding its value is being
#             edited - a commit there replaces, and a replace that kept no
#             identity would break every id held across it - so its editor is
#             handed the criterion, and the commit keeps its id. Everywhere
#             else the add is fresh: empty initial, a new id at commit. (An
#             editor of a `control` facet above `max 1` gets an empty initial
#             too, and reads the values doors for the rest.)
#   $commit   a command prefix: the editor invokes `{*}$commit $value ?$op?`
#             when the user accepts (Return, a pick, a button - the editor's
#             choice of gesture). An omitted op keeps the criterion's current
#             op when editing and means the facet's defaultop on a fresh add;
#             a named op is validated against the vocabulary as add_criterion
#             validates one. The builder applies the commit under the facet's
#             own rules (cap, dedupe, replace-at-one), draws the chip, rebuilds
#             the editor area - open for the next value while the facet can
#             take one, closed at the cap - and fires -changecommand, this
#             being user action. A drawing that raises puts the value back and
#             keeps the row open with the editor intact, so its text is not
#             lost to a value the host cannot print. In `control` mode a commit
#             replaces the facet's criterion in place, id preserved, without
#             redrawing the editor it came from; a control clearing its facet
#             reports {} through report_values instead, since an empty commit
#             value is still a value.
#   $cancel   a command prefix: `{*}$cancel` aborts the add, as cancel_add
#             does. Escape needs no editor code at all: after the editor
#             callback returns, the builder appends its own bindtag to every
#             widget under $frame, so its Escape binding cancels the add
#             whichever child holds the focus. Appended, not prepended: an
#             editor that binds Escape itself is answered first, and a binding
#             that destroys its window ends the delivery.
#
# Limits. Every value can be removed and every facet can be edited: there is no locked
# value, no read-only state and no disabled facet.
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

oo::class create ::querybuilder::QueryBuilder {
    variable Top       ;# the frame the host owns and we build into
    variable Model     ;# dict: kind -> list of applied values
    variable Ids       ;# dict: kind -> list of criterion ids, parallel to Model
    variable Ops       ;# dict: kind -> list of criterion ops, parallel to Model
    variable NextId    ;# the next criterion id to allocate, monotonic
    variable Expanded  ;# 1 while the editor rows show, 0 while collapsed to chips
    variable Revealed  ;# dict: tail kind -> 1 once pulled off the add rail
    variable Editing   ;# dict: kind -> 1 while its inline add editor is open
    variable Opts      ;# widget options: the whole of the host-specific surface
    variable Flow      ;# dict: chip area -> the {widget leftgap} items it drew
    variable FlowW     ;# dict: chip area -> the width its current lay was made at
    variable FlowIdle  ;# after-idle token of a pending first lay, or ""

    constructor {} {
        set Top ""
        set Model    [dict create]
        set Ids      [dict create]
        set Ops      [dict create]
        set NextId   0
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
            facets        {} \
            heading       "" \
            countfmt      "%d active" \
            countables    "" \
            orword        "or" \
            addtext       "+" \
            ortext        "+ or" \
            deltext       "×" \
            delside       right \
            raillabel     "Add" \
            emptytext     "+ add" \
            expandtext    "▸" \
            collapsetext  "▾" \
            disclosure    1 \
            changecommand "" \
            foldcommand   "" \
            styles        [dict create \
                heading  FacetHeading.TLabel \
                toggle   FacetToggle.TButton \
                tag      QBTag.TLabel \
                conn     FacetConn.TLabel \
                or       FacetOr.TLabel \
                chip     QBChip.TFrame \
                chiptext FacetChipText.TLabel \
                del      FacetDel.TButton \
                add      FacetAdd.TButton] \
            gaps          [dict create \
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
            error "querybuilder: configure takes one option to read, or option/value pairs to set"
        }
        set staged $Opts
        foreach {opt val} $args {
            set k [string trimleft $opt -]
            if {![dict exists $staged $k]} { error "querybuilder: unknown option $opt" }
            switch -- $k {
                facets   { my validate_facets $val }
                countfmt { my validate_countfmt $val }
                delside  {
                    if {$val ni {left right}} {
                        error "querybuilder: delside '$val' is neither left nor right"
                    }
                }
                disclosure {
                    if {![string is boolean -strict $val]} {
                        error "querybuilder: disclosure '$val' is not a true or false value"
                    }
                }
                styles   { set val [my merge_roles styles $val "style role" 0] }
                gaps     { set val [my merge_roles gaps   $val "gap"        1] }
            }
            dict set staged $k $val
        }
        # The criteria, the revealed rows and the open editors are keyed by kind,
        # so applying a facet list rewrites them too. They go into the snapshot with
        # the options: rolling back an option list while leaving behind the criteria
        # it was applied to would drop the values of a facet the rollback then
        # restores, and drop them silently, because a configure publishes nothing.
        set obefore $Opts
        set sbefore [my save_state]
        set Opts $staged
        if {[catch {my apply_opts} err info]} {
            set Opts $obefore
            lassign $sbefore Model Ids Ops NextId Revealed Editing
            catch {my apply_opts}
            return -options $info $err
        }
        return
    }

    method apply_opts {} {
        my validate_countables
        my dress_styles
        my sync_state
        my refresh
    }

    method cget {opt} {
        set k [string trimleft $opt -]
        if {![dict exists $Opts $k]} { error "querybuilder: unknown option $opt" }
        return [dict get $Opts $k]
    }

    method opt {k} { return [dict get $Opts $k] }
    method style {role} { return [dict get [my opt styles] $role] }
    method gap {role} { return [dict get [my opt gaps] $role] }

    # The style for one facet's tag or chips: the descriptor's own, else the bar's
    # role. A host tints a facet by naming a style, never by naming a colour.
    method facet_style {kind key role} { return [my dget $kind $key [my style $role]] }

    # A partial -styles or -gaps dict, merged over what the bar has. A role the bar
    # draws nothing with would merge in and change nothing at all, so it is refused
    # for the reason a misspelt descriptor key is.
    method merge_roles {which val what numeric} {
        if {[catch {dict size $val}]} {
            error "querybuilder: -$which takes a dict of $what to value"
        }
        set have [dict get $Opts $which]
        dict for {role v} $val {
            if {![dict exists $have $role]} {
                error "querybuilder: unknown $what '$role'; the roles are:\
                       [join [dict keys $have] {, }]"
            }
            if {$numeric && (![string is integer -strict $v] || $v < 0)} {
                error "querybuilder: $what '$role' takes a count of pixels, not '$v'"
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
            error "querybuilder: countfmt '$fmt' is not a format taking one count: $err"
        }
    }

    # The countable facets are named by kind, so a name no descriptor declares would
    # sum a facet that is not there, or fall out of the tally the moment the facet
    # list moved under it. It is checked against the facets in force - the ones a
    # redraw would draw - so it travels the configure's rollback like any option
    # whose badness only shows when the bar is drawn. "" counts every facet and
    # names none, so it needs no check.
    method validate_countables {} {
        set c [my opt countables]
        if {[catch {llength $c}]} {
            error "querybuilder: -countables is not a list of kinds"
        }
        if {$c eq ""} return
        set kinds [my kinds]
        foreach kind $c {
            if {$kind ni $kinds} {
                error "querybuilder: -countables names '$kind', which no facet declares"
            }
        }
    }

    # Check the descriptor list where the caller wrote it. A mistyped key would
    # otherwise surface as a row that silently never draws, or an editor never
    # called, which is a long walk back from the symptom.
    method validate_facets {facets} {
        if {[catch {llength $facets}]} { error "querybuilder: -facets is not a list" }
        set known {kind label conn format mode max dedupe orword ortext tail editor
                   chipctl railtext tagstyle chipstyle op defaultop}
        set seen [list]
        foreach d $facets {
            if {[catch {dict size $d}]} {
                error "querybuilder: facet descriptor is not a dict: $d"
            }
            if {![dict exists $d kind]} { error "querybuilder: descriptor with no kind: $d" }
            set kind [dict get $d kind]
            # A plain word, because the kind names widgets and rides into the flow's
            # binding script, where a stray % would be taken for an event
            # substitution and hand the bar a window that does not exist.
            if {![regexp {^[A-Za-z0-9_]+$} $kind]} {
                error "querybuilder: kind '$kind' is not a plain word\
                       (letters, digits, underscore)"
            }
            if {$kind in $seen} { error "querybuilder: duplicate kind '$kind'" }
            lappend seen $kind
            foreach k [dict keys $d] {
                if {$k ni $known} {
                    error "querybuilder: facet '$kind': unknown descriptor key '$k'"
                }
            }
            set mode [::querybuilder::getdef $d mode chips]
            if {$mode ni {chips control}} {
                error "querybuilder: facet '$kind': mode '$mode' is neither chips nor control"
            }
            # An expanded bar draws a control facet's values through its editor and
            # through nothing else, so one without an editor would hold a value the
            # user could neither see nor delete.
            if {$mode eq "control" && [::querybuilder::getdef $d editor ""] eq ""} {
                error "querybuilder: facet '$kind': a control facet needs an editor,\
                       or its value would be held and never shown"
            }
            set max [::querybuilder::getdef $d max 0]
            if {![string is integer -strict $max] || $max < 0} {
                error "querybuilder: facet '$kind': max '$max' is not a count"
            }
            foreach flag {tail dedupe} {
                set v [::querybuilder::getdef $d $flag 1]
                if {![string is boolean -strict $v]} {
                    error "querybuilder: facet '$kind': $flag '$v' is not a true or false value"
                }
            }
            # An op vocabulary and its default travel together: a vocabulary with
            # no default would make every omitted op an error somewhere later, and
            # a default with no vocabulary defaults over nothing.
            if {[dict exists $d op]} {
                set vocab [dict get $d op]
                if {[catch {llength $vocab}] || [llength $vocab] == 0} {
                    error "querybuilder: facet '$kind': op takes a list of operator words"
                }
                if {![dict exists $d defaultop]} {
                    error "querybuilder: facet '$kind' declares an op vocabulary\
                           and no defaultop, so an omitted op would mean nothing"
                }
                if {[dict get $d defaultop] ni $vocab} {
                    error "querybuilder: facet '$kind': defaultop\
                           '[dict get $d defaultop]' is not in its op vocabulary"
                }
            } elseif {[dict exists $d defaultop]} {
                error "querybuilder: facet '$kind' names a defaultop with no op\
                       vocabulary for it to default over"
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
    # It writes only what differs. `ttk::style configure` raises <<ThemeChanged>>,
    # which is the event that calls this method: a handler for that event which
    # configures a style unconditionally re-raises the event it is answering, and the
    # ring does not close. Writing only a difference closes it on the first pass.
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

    method kinds {} { return [lmap d [my opt facets] {dict get $d kind}] }

    method desc {kind} {
        foreach d [my opt facets] {
            if {[dict get $d kind] eq $kind} { return $d }
        }
        error "querybuilder: no such facet '$kind'"
    }

    # One descriptor field, with that field's default. Every read of a descriptor
    # goes through here, so a key's default is written once, at the one call site.
    method dget {kind key dflt} { return [::querybuilder::getdef [my desc $kind] $key $dflt] }

    # The op a criterion lands with when the caller names none: the facet's
    # defaultop, which is "" exactly on a facet with no vocabulary.
    method op_default {kind} { return [my dget $kind defaultop ""] }

    # An op is one of the facet's declared vocabulary, or "" on a facet that
    # declares none. A criterion that cannot render has no better moment to fail
    # than the call that named it.
    method check_op {kind op} {
        set vocab [my dget $kind op {}]
        if {[llength $vocab] == 0} {
            if {$op ne ""} {
                error "querybuilder: facet '$kind' declares no operator\
                       vocabulary, so op '$op' names nothing"
            }
            return
        }
        if {$op ni $vocab} {
            error "querybuilder: facet '$kind': op '$op' is not one of\
                   [join $vocab {, }]"
        }
    }

    # A tail facet is hidden while it is neither revealed nor carrying a value: it
    # has no row, and its button waits on the add rail. Revealing is one way - a
    # revealed row stays, so another value can be added to it - except that
    # abandoning the add that revealed it, or collapsing the bar, puts it back.
    method tail_hidden {kind} {
        if {![my dget $kind tail 0]}          { return 0 }
        if {[::querybuilder::getdef $Revealed $kind 0]} { return 0 }
        return [expr {[llength [my values $kind]] == 0}]
    }

    # The facets with a row, in descriptor order. The rail carries the ones without,
    # so a body whose `present` list has not changed has an unchanged rail.
    method present {} {
        return [lmap kind [my kinds] { expr {[my tail_hidden $kind] ? [continue] : $kind} }]
    }

    # Whether the facet will take another value through its editor. This gates all
    # three ways to that editor - the inline affordance, begin_add, and an editor
    # left open while the model moved under it - because an editor a value cannot
    # leave is an editor that eats what is typed into it. A single-valued facet
    # always says yes: a commit there replaces, so there is always something the
    # editor can do.
    method addable {kind} {
        if {[my dget $kind editor ""] eq ""} { return 0 }
        set max [my dget $kind max 0]
        if {$max <= 1} { return 1 }
        return [expr {[llength [my values $kind]] < $max}]
    }

    # Whether a commit can be followed by another. This is what keeps the editor open
    # after a commit, so a keyboard user is not thrown back to the button between two
    # values; at the cap there is nothing more to type, and it closes.
    method can_take_more {kind} {
        if {[my dget $kind editor ""] eq ""} { return 0 }
        set max [my dget $kind max 0]
        return [expr {$max == 0 || [llength [my values $kind]] < $max}]
    }

    # `max` is a rule on the model, not only on the affordance: a value list that
    # breaks the cap is refused wherever it comes from, so no route into the widget
    # leaves a facet holding more than it says it may.
    method check_max {kind vals} {
        if {[catch {llength $vals}]} {
            error "querybuilder: facet '$kind': values are not a list"
        }
        set max [my dget $kind max 0]
        if {$max > 0 && [llength $vals] > $max} {
            error "querybuilder: facet '$kind' holds at most $max value(s),\
                   given [llength $vals]"
        }
    }

    # An index names one of the facet's values. Anything else is a caller's mistake,
    # and is told so here rather than passed down to lreplace to garble, or quietly
    # dropped as a no-op that looks like a working delete.
    method check_index {kind idx} {
        if {![string is integer -strict $idx]} {
            error "querybuilder: facet '$kind': '$idx' is not a value index"
        }
        set n [llength [my values $kind]]
        if {$idx < 0 || $idx >= $n} {
            error "querybuilder: facet '$kind' has no value at index $idx ($n applied)"
        }
    }

    # ---- the criteria ------------------------------------------------------

    # The model carries every facet, applied or not, so an owner reads a facet's
    # values without first asking whether any were set. A kind no descriptor
    # declares is an error here as it is at every other door: a facet read by a
    # name with a typo in it would otherwise answer "nothing applied", which is a
    # lie the caller has no way to catch.
    method model {} { return $Model }
    method values {kind} {
        my desc $kind
        return [::querybuilder::getdef $Model $kind {}]
    }

    method alloc_id {} { set n $NextId; incr NextId; return $n }

    # One criterion, assembled from the three parallel lists that hold it.
    method criterion_at {kind i} {
        return [dict create \
            id    [lindex [::querybuilder::getdef $Ids $kind {}] $i] \
            kind  $kind \
            op    [lindex [::querybuilder::getdef $Ops $kind {}] $i] \
            value [lindex [my values $kind] $i]]
    }

    # The fragment: the criteria as the shared query contract carries them, in
    # facet declaration order and then value order. The `criteria` key is always
    # present, so a consumer's `dict get` needs no guard.
    method fragment {} {
        set crit [list]
        foreach kind [my kinds] {
            for {set i 0} {$i < [llength [my values $kind]]} {incr i} {
                lappend crit [my criterion_at $kind $i]
            }
        }
        return [dict create criteria $crit]
    }

    # The chip text the builder itself would draw: the facet's formatter over the
    # whole criterion, the raw value where the facet names none. Public, so a
    # consumer mirroring criteria elsewhere renders the labels the chips carry.
    method format {criterion} {
        set kind [dict get $criterion kind]
        set fmt [my dget $kind format ""]
        if {$fmt eq ""} { return [dict get $criterion value] }
        return [{*}$fmt $criterion]
    }

    # Replace one facet's values, each surviving position keeping its criterion's
    # id and op: an edit preserves identity, and only a position past the old list
    # is a new criterion, freshly numbered, at the facet's default op. This is the
    # bulk doors' shape; the by-id and by-index doors edit the three lists in step
    # themselves, which is what keeps a removal from renumbering the survivors.
    method write_values {kind vals} {
        set oldids [::querybuilder::getdef $Ids $kind {}]
        set oldops [::querybuilder::getdef $Ops $kind {}]
        set ids [list]
        set ops [list]
        for {set i 0} {$i < [llength $vals]} {incr i} {
            if {$i < [llength $oldids]} {
                lappend ids [lindex $oldids $i]
                lappend ops [lindex $oldops $i]
            } else {
                lappend ids [my alloc_id]
                lappend ops [my op_default $kind]
            }
        }
        dict set Model $kind $vals
        dict set Ids   $kind $ids
        dict set Ops   $kind $ops
    }

    # Hold the bar's state to the facet list, which the host may set or swap at any
    # time. The criteria, the revealed rows and the open editors are all keyed by
    # kind: a facet that arrives starts with no values, hidden and closed, and one
    # that leaves takes all of them with it, so a facet dropped and put back does
    # not return already revealed, on the strength of a key nothing explains any
    # more.
    method sync_state {} {
        set kinds [my kinds]
        # A facet list is a route into the model like any other, so it meets the same
        # cap: a descriptor that would cap a facet below the values it already holds
        # is refused here, and the configure that brought it rolls back.
        foreach kind $kinds { my check_max $kind [::querybuilder::getdef $Model $kind {}] }
        set m  [dict create]
        set il [dict create]
        set ol [dict create]
        set r  [dict create]
        set e  [dict create]
        foreach kind $kinds {
            dict set m  $kind [::querybuilder::getdef $Model $kind {}]
            dict set il $kind [::querybuilder::getdef $Ids $kind {}]
            dict set ol $kind [::querybuilder::getdef $Ops $kind {}]
            if {[dict exists $Revealed $kind]} { dict set r $kind [dict get $Revealed $kind] }
            if {[dict exists $Editing $kind]}  { dict set e $kind [dict get $Editing $kind] }
        }
        set Model    $m
        set Ids      $il
        set Ops      $ol
        set Revealed $r
        set Editing  $e
    }

    # The bulk write: it replaces the whole model. A facet the dict leaves out is a
    # facet with no values, and `set_model {}` returns the bar to rest - nothing
    # applied, no editor open, every tail facet back on the rail. Every kind and
    # every cap is checked before anything is written, so a bad call cannot leave
    # half a model behind. The bar redraws whole, and every editor is rebuilt from
    # the new values. Quiet, as every programmatic door is.
    method set_model {m} {
        if {[catch {dict size $m}]} { error "querybuilder: the model is not a dict" }
        dict for {kind vals} $m {
            my desc $kind
            my check_max $kind $vals
        }
        set snap [my save_state]
        foreach kind [my kinds] {
            my write_values $kind [::querybuilder::getdef $m $kind {}]
        }
        set Revealed [dict create]
        set Editing  [dict create]
        if {[catch {my refresh} err info]} {
            my restore_state $snap
            return -options $info $err
        }
        return
    }

    # The empty fragment: no criteria, no editor open, every tail facet on the
    # rail. The id generator does not rewind - an id, once dead, names nothing
    # ever again.
    method reset {} { my set_model {} }

    # Seed criteria from a fragment, quietly. A partial dict merges: only the
    # `criteria` key is the builder's, a dict without it changes nothing, and
    # keys the builder does not own are ignored, so the whole saved query dict
    # feeds it verbatim. Restored ids are honored and the generator allocates
    # past them; a criterion without an id gets a fresh one, and one without an
    # op the facet's defaultop. Everything is checked before anything is written.
    method set_fragment {frag} {
        if {[catch {dict size $frag}]} { error "querybuilder: the fragment is not a dict" }
        if {![dict exists $frag criteria]} return
        set crit [dict get $frag criteria]
        if {[catch {llength $crit}]} { error "querybuilder: criteria is not a list" }
        set vals [dict create]
        set ids  [dict create]
        set ops  [dict create]
        set top -1
        foreach c $crit {
            if {[catch {dict size $c}]} {
                error "querybuilder: criterion is not a dict: $c"
            }
            foreach need {kind value} {
                if {![dict exists $c $need]} {
                    error "querybuilder: criterion with no $need: $c"
                }
            }
            set kind [dict get $c kind]
            my desc $kind
            set op [::querybuilder::getdef $c op [my op_default $kind]]
            my check_op $kind $op
            set cid [::querybuilder::getdef $c id ""]
            if {$cid ne ""} {
                if {![string is integer -strict $cid] || $cid < 0} {
                    error "querybuilder: criterion id '$cid' is not one the builder allocates"
                }
                if {$cid > $top} { set top $cid }
            }
            dict lappend vals $kind [dict get $c value]
            dict lappend ids  $kind $cid
            dict lappend ops  $kind $op
        }
        dict for {kind v} $vals { my check_max $kind $v }
        # The generator moves past every restored id first, so the fresh ids the
        # unnumbered criteria get cannot collide with the numbered ones.
        if {$top >= $NextId} { set NextId [expr {$top + 1}] }
        set snap [my save_state]
        foreach kind [my kinds] {
            dict set Model $kind [::querybuilder::getdef $vals $kind {}]
            set l [list]
            foreach cid [::querybuilder::getdef $ids $kind {}] {
                if {$cid eq ""} { set cid [my alloc_id] }
                lappend l $cid
            }
            dict set Ids $kind $l
            dict set Ops $kind [::querybuilder::getdef $ops $kind {}]
        }
        set Revealed [dict create]
        set Editing  [dict create]
        if {[catch {my refresh} err info]} {
            my restore_state $snap
            return -options $info $err
        }
        return
    }

    # The per-facet write: replace one facet's values and redraw its editor from
    # them, so a control shows what the owner has just set.
    method set_values {kind vals} {
        my desc $kind
        my check_max $kind $vals
        if {[my same_values $vals [my values $kind]]} return
        set was  [my present]
        set snap [my save_state]
        my write_values $kind $vals
        my after_change $kind $was 1 0 $snap
        return
    }

    # A `control` editor's door: the editor telling the bar what it now holds. The
    # one thing it does not do is redraw that facet's editor, because that editor is
    # where this change came from, and rebuilding it would destroy the control under
    # the hand that just moved it. A `chips` facet has no such editor to spare: its
    # chips are the bar's drawing of its values, so not redrawing them would leave
    # them showing values the model no longer holds. Its editor commits through the
    # commit prefix it was handed, and an owner writing from outside uses set_values.
    method report_values {kind vals} {
        my desc $kind
        if {[my dget $kind mode chips] eq "chips"} {
            error "querybuilder: facet '$kind' is a chips facet: its editor commits\
                   through its commit prefix, and an owner writes it with set_values.\
                   report_values is a control editor's door"
        }
        my check_max $kind $vals
        if {[my same_values $vals [my values $kind]]} return
        set was  [my present]
        set snap [my save_state]
        my write_values $kind $vals
        # An editor that reports keeps its row. A tail facet loses its row when its
        # last value goes, and the row would take the editor with it - so a control
        # wound down to a value of "none" would be destroyed from inside its own
        # callback, which is the one thing this door exists to prevent. The row it
        # was drawn in stays until something other than the editor closes it.
        if {[my dget $kind tail 0] && $kind in $was} { dict set Revealed $kind 1 }
        my after_change $kind $was 0 0 $snap
        return
    }

    # Add one criterion and return its id. The facet's rules apply as they do at
    # its editor: a single-valued facet takes the new criterion in place of the
    # old, which is gone, id and all; a repeat on a deduping facet adds nothing
    # and answers with the id the value already carries; a facet at a cap above
    # one refuses outright, because a call that must return an id has no way to
    # quietly add nothing. On a `control` facet it is an error: those values are
    # its editor's to shape and the owner's to set_values.
    method add_criterion {kind value args} {
        my desc $kind
        if {[llength $args] > 1} {
            error "querybuilder: add_criterion takes a kind, a value and at most an op"
        }
        if {[my dget $kind mode chips] eq "control"} {
            error "querybuilder: facet '$kind' is a control facet: its editor reports\
                   with report_values, and an owner writes it with set_values.\
                   add_criterion is a chips facet's door"
        }
        set op [expr {[llength $args] ? [lindex $args 0] : [my op_default $kind]}]
        my check_op $kind $op
        set old [my values $kind]
        set max [my dget $kind max 0]
        if {[my dget $kind dedupe 1] && $value in $old} {
            return [lindex [dict get $Ids $kind] [lsearch -exact $old $value]]
        }
        if {$max > 1 && [llength $old] >= $max} {
            error "querybuilder: facet '$kind' holds at most $max value(s), and\
                   holds them already"
        }
        set was  [my present]
        set snap [my save_state]
        set cid [my alloc_id]
        if {$max == 1} {
            dict set Model $kind [list $value]
            dict set Ids   $kind [list $cid]
            dict set Ops   $kind [list $op]
        } else {
            dict set Model $kind [linsert $old end $value]
            dict set Ids   $kind [linsert [::querybuilder::getdef $Ids $kind {}] end $cid]
            dict set Ops   $kind [linsert [::querybuilder::getdef $Ops $kind {}] end $op]
        }
        if {[my dget $kind tail 0]} { dict set Revealed $kind 1 }
        my after_change $kind $was 1 0 $snap
        return $cid
    }

    # Drop the criterion the id names, whatever facet it sits in. The survivors
    # keep their ids: removal never renumbers.
    method remove_criterion {cid} {
        foreach kind [my kinds] {
            set idx [lsearch -exact [::querybuilder::getdef $Ids $kind {}] $cid]
            if {$idx < 0} continue
            my drop_at $kind $idx 0
            return
        }
        error "querybuilder: no criterion has id '$cid': a caller holding a dead id\
               has a bookkeeping bug worth hearing about"
    }

    # Remove the value at $idx. By index, not by value: a per-value control can
    # leave two chips value-equal, and a by-value delete would drop the first twin
    # rather than the chip the user pressed.
    method remove_value_at {kind idx} {
        my desc $kind
        my check_index $kind $idx
        my drop_at $kind $idx 0
        return
    }

    # The chip's delete affordance: the same removal, fired as the user action it
    # is, so the owner hears the new fragment.
    method user_remove {kind idx} {
        my check_index $kind $idx
        my drop_at $kind $idx 1
        return
    }

    # One value out of the three parallel lists, in step, so no survivor's id or
    # op slides onto a neighbour's value.
    method drop_at {kind idx fire} {
        set was  [my present]
        set snap [my save_state]
        dict set Model $kind [lreplace [my values $kind] $idx $idx]
        dict set Ids   $kind [lreplace [dict get $Ids $kind] $idx $idx]
        dict set Ops   $kind [lreplace [dict get $Ops $kind] $idx $idx]
        my after_change $kind $was 1 $fire $snap
    }

    # Rewrite one value in place, its id and op standing: the per-value control's
    # door, for when what the value applies to has changed but the value itself
    # has not moved. The host that owns the control publishes.
    method set_value_at {kind idx value} {
        my desc $kind
        my check_index $kind $idx
        set vals [my values $kind]
        if {[lindex $vals $idx] eq $value} return
        set was  [my present]
        set snap [my save_state]
        lset vals $idx $value
        dict set Model $kind $vals
        my after_change $kind $was 1 0 $snap
        return
    }

    # An editor's commit prefix lands here: the one user path that adds or edits
    # a criterion, so the one that fires -changecommand. `editid` is the id the
    # editor was opened on, or "" for a fresh add; an omitted op keeps the edited
    # criterion's op, and means the facet's defaultop on a fresh add. A `control`
    # facet's commit replaces its criterion in place, id preserved, without
    # redrawing the editor it came from - the commit's whole point over
    # set_values. A `chips` commit runs the facet's own rules (replace at max 1,
    # dedupe, the cap), keeps the editor open while the facet can take another
    # value, and closes it at the cap; a commit that moves nothing fires nothing.
    method editor_commit {kind editid value args} {
        my desc $kind
        if {[llength $args] > 1} {
            error "querybuilder: a commit takes a value and at most an op"
        }
        set given [llength $args]
        set ids [::querybuilder::getdef $Ids $kind {}]
        set ops [::querybuilder::getdef $Ops $kind {}]
        set idx [expr {$editid ne "" ? [lsearch -exact $ids $editid] : -1}]
        if {[my dget $kind mode chips] eq "control"} {
            set op [expr {$given ? [lindex $args 0] : \
                        ($idx >= 0 ? [lindex $ops $idx] : [my op_default $kind])}]
            my check_op $kind $op
            if {[my same_values [list $value] [my values $kind]] \
                    && $op eq [lindex $ops 0]} return
            set was  [my present]
            set snap [my save_state]
            set cid [expr {$idx >= 0 ? $editid : [my alloc_id]}]
            dict set Model $kind [list $value]
            dict set Ids   $kind [list $cid]
            dict set Ops   $kind [list $op]
            if {[my dget $kind tail 0] && $kind in $was} { dict set Revealed $kind 1 }
            my after_change $kind $was 0 1 $snap
            return
        }
        set old [my values $kind]
        set max [my dget $kind max 0]
        set was  [my present]
        set snap [my save_state]
        if {$idx >= 0} {
            # An edit: the criterion keeps its id, and its op unless one was named.
            set op [expr {$given ? [lindex $args 0] : [lindex $ops $idx]}]
            my check_op $kind $op
            set vals $old
            lset vals $idx $value
            set changed [expr {![my same_values $vals $old] || $op ne [lindex $ops $idx]}]
            dict set Model $kind $vals
            dict set Ops   $kind [lreplace $ops $idx $idx $op]
        } else {
            set op [expr {$given ? [lindex $args 0] : [my op_default $kind]}]
            my check_op $kind $op
            set vals $old
            if {$max == 1} {
                set vals [list $value]
                set ids  [list [my alloc_id]]
                set ops  [list $op]
            } elseif {(![my dget $kind dedupe 1] || $value ni $old) \
                      && ($max == 0 || [llength $old] < $max)} {
                lappend vals $value
                lappend ids  [my alloc_id]
                lappend ops  $op
            }
            set changed [expr {![my same_values $vals $old]}]
            dict set Model $kind $vals
            dict set Ids   $kind $ids
            dict set Ops   $kind $ops
        }
        if {$changed && [my dget $kind tail 0]} { dict set Revealed $kind 1 }
        if {[my can_take_more $kind]} {
            dict set Editing $kind 1
        } else {
            dict unset Editing $kind
        }
        if {!$changed} {
            # A repeat of an applied value is no second criterion, and a facet at
            # its cap takes no more. Nothing changed, so no one is told; the editor
            # is left open or closed by the same rule as a commit that did land.
            if {[catch {my render_editor $kind} err info]} {
                my restore_state $snap
                return -options $info $err
            }
            return
        }
        my after_change $kind $was 1 1 $snap
        return
    }

    # Every path that changes the criteria lands here, and only a path that really
    # changed them: redraw what the change can touch, then - on a user gesture, and
    # only there - tell the owner. Redrawing the one facet, rather than the whole
    # body, is what keeps another row's editor alive - a stepper mid-step, an entry
    # mid-word - while this row's chip is deleted. Only a change in which facets
    # have rows (a tail facet's first value, or a row whose last value left)
    # re-lays the body, and the rail rides that same test, because the rail carries
    # exactly the facets the rows do not.
    #
    # `redraw` is 0 on the two paths that must not touch the facet's editor: a
    # control editor reporting, or committing, what it now holds.
    method after_change {kind was redraw fire snap} {
        if {[catch {my draw_change $kind $was $redraw} err info]} {
            # The drawing is where a caller's formatter meets the value for the first
            # time, and a formatter that cannot print it raises here, with the value
            # already in the model and its chips half drawn. The value goes back where
            # it came from and the bar is re-laid, so one value a host cannot print
            # cannot leave a bar that can no longer draw at all. The owner is not
            # told: nothing ended up changing.
            my restore_state $snap
            return -options $info $err
        }
        if {$fire} { my publish }
        return
    }

    method draw_change {kind was redraw} {
        # A value the change put out of reach of the editor closes it: an editor open
        # on a facet that can take no more would swallow whatever is typed into it.
        if {[::querybuilder::getdef $Editing $kind 0] && ![my addable $kind]} {
            dict unset Editing $kind
        }
        if {!$Expanded || [my present] ne $was} {
            my refresh
        } else {
            if {$redraw} { my render_editor $kind }
            my render_head
        }
    }

    # The state a value change touches, saved before it is drawn and put back if
    # the drawing will not have it. The id generator rides along: a rolled-back
    # add must not leave behind ids it never really issued.
    method save_state {} { return [list $Model $Ids $Ops $NextId $Revealed $Editing] }
    method restore_state {snap} {
        lassign $snap Model Ids Ops NextId Revealed Editing
        catch {my refresh}
    }

    # Values compare as lists, not as strings: "a  b" and {a b} are the same two
    # values, and a door that called them different would report a change that
    # moved nothing.
    method same_values {a b} {
        if {[llength $a] != [llength $b]} { return 0 }
        foreach x $a y $b { if {$x ne $y} { return 0 } }
        return 1
    }

    # Fire -changecommand once with the current fragment. The bar calls it itself
    # on every user gesture that changed the criteria; a consumer calls it to
    # react to its own batch of quiet mutations through the one code path. The
    # change is drawn before the owner hears of it, so the widget is consistent
    # whatever the callback does, raising included. Its error is not caught: it
    # travels as any error does, which at event time is Tk's background error
    # handler, with the host's own stack intact, and on a direct call is the
    # caller's. Its return value is not the bar's to pass on.
    method publish {} {
        set cb [my opt changecommand]
        if {$cb eq ""} return
        {*}$cb [my fragment]
        return
    }

    # ---- disclosure --------------------------------------------------------

    method expanded {} { return $Expanded }
    method collapsed {} { return [expr {!$Expanded}] }

    method expand {} {
        if {$Expanded} return
        set Expanded 1
        my refresh
        return
    }

    # Collapsing drops any open inline editor along with the rows it was drawn in;
    # nothing was committed, so nothing is reported. A tail facet revealed but never
    # given a value goes back to the rail with them, as it would if its add were
    # cancelled: leaving it revealed would bring back, on the next expand, an empty
    # row whose rail button is gone and which no affordance on the bar can dismiss.
    method collapse {} {
        if {!$Expanded} return
        set Expanded 0
        set Editing [dict create]
        foreach kind [my kinds] {
            if {[my dget $kind tail 0] && [llength [my values $kind]] == 0} {
                dict unset Revealed $kind
            }
        }
        my refresh
        return
    }

    method toggle {} { if {$Expanded} { my collapse } else { my expand } }

    # A user's own fold gesture - the disclosure button, or the empty collapsed
    # bar's add affordance opening it - and the one path that tells the owner,
    # with the new state appended. The programmatic doors above stay quiet, by
    # the one callback rule.
    method user_fold {} {
        my toggle
        set cb [my opt foldcommand]
        if {$cb ne ""} { {*}$cb [my collapsed] }
        return
    }

    # Open a facet's editor: reveal the facet if it is still on the rail, expand the
    # bar if it is collapsed (an editor has nowhere to draw in a collapsed bar), and
    # open the add affordance into the editor. It opens exactly what that affordance
    # opens, and on a facet at its cap the affordance is not drawn, so this opens no
    # editor either. A `control` facet has no add affordance to open, so revealing its
    # row is the whole of it. The editor callback lands the caret itself. Nothing is
    # reported: no value has changed.
    method begin_add {kind} {
        my desc $kind
        # A facet with no editor is not opened and not revealed. The rail withholds
        # such a facet for the reason that would apply here too: revealing it would
        # leave a row with nothing to type into, no affordance, and nothing on the bar
        # that could dismiss it again.
        if {[my dget $kind editor ""] eq ""} return
        set was [my present]
        if {[my dget $kind tail 0]} { dict set Revealed $kind 1 }
        if {[my dget $kind mode chips] eq "chips" && [my addable $kind]} {
            dict set Editing $kind 1
        }
        if {!$Expanded || [my present] ne $was} {
            set Expanded 1
            my refresh
        } else {
            my render_editor $kind
        }
        return
    }

    # Abandon an open add: the editor closes and its unconfirmed text goes with it. A
    # tail facet revealed only to be typed into returns to the rail, so a cancelled
    # add leaves no empty row behind. This is the editors' cancel prefix, and what
    # the builder's own Escape binding calls.
    method cancel_add {kind} {
        my desc $kind
        dict unset Editing $kind
        set was [my present]
        if {[my dget $kind tail 0] && [llength [my values $kind]] == 0} {
            dict unset Revealed $kind
        }
        if {[my present] ne $was} { my refresh } else { my render_editor $kind }
        return
    }

    # ---- assembly ----------------------------------------------------------

    # Build the bar into `parent`, a frame the host created and packed. The head line
    # is built once and only ever reworded; the body is swapped whole by the
    # disclosure, so its children are the bar's to destroy.
    method setup {parent} {
        if {$Top ne ""} { error "querybuilder: setup has already run" }
        if {![winfo exists $parent]} {
            error "querybuilder: setup: no such window '$parent'"
        }
        set Top $parent
        # A build that fails (a frame that already holds a bar, an editor that raises)
        # hands the frame back and forgets it, so the object can be set up again
        # rather than be left refusing every attempt as a second setup.
        if {[catch {my build} err info]} {
            catch {destroy $parent.head $parent.body}
            set Top ""
            return -options $info $err
        }
        return
    }

    method build {} {
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
            -command [list [namespace which my] user_fold]
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

    # Redraw the body from the criteria.
    method refresh {} {
        if {![my drawable]} return
        foreach c [winfo children $Top.body] { destroy $c }
        set Flow  [dict create]
        set FlowW [dict create]
        if {$Expanded} { my render_rows } else { my render_strip }
        my render_head
        my flow_schedule
    }

    # The count the heading carries: the number of values the countable facets
    # hold, summed. A facet left out of -countables adds nothing however many
    # values it holds, and a bar holding no countable value counts zero, where
    # render_head drops the count clause. "" counts every facet.
    method active_count {} {
        set c [my opt countables]
        if {$c eq ""} { set c [my kinds] }
        set n 0
        foreach kind $c { incr n [llength [my values $kind]] }
        return $n
    }

    # The head line, and whether there is one. A bar with no heading and no disclosure
    # has nothing to put on that line, so the line goes: what is left is a plain strip
    # of chips, or a plain set of editor rows, which is a bar a host may well want.
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
        if {[my opt disclosure]} {
            $Top.head.tog configure -text \
                [expr {$Expanded ? [my opt collapsetext] : [my opt expandtext]}]
            pack $Top.head.tog -side right
        } else {
            pack forget $Top.head.tog
        }
        if {$txt eq "" && ![my opt disclosure]} {
            pack forget $Top.head
        } else {
            pack $Top.head -side top -fill x -before $Top.body
        }
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
        foreach kind [my present] {
            ttk::label $rows.tag_$kind -style [my facet_style $kind tagstyle tag] \
                -text [my dget $kind label $kind] -anchor center
            grid $rows.tag_$kind -row $r -column 0 -sticky w \
                -padx [list 0 $col] -pady [my gap row]
            set conn [my dget $kind conn ""]
            if {$conn ne ""} {
                ttk::label $rows.conn_$kind -style [my style conn] -text $conn
                grid $rows.conn_$kind -row $r -column 1 -sticky w -padx [list 0 $col]
            }
            ttk::frame $rows.ed_$kind
            grid $rows.ed_$kind -row $r -column 2 -sticky ew
            # The window the lay is for comes from the event, %W, and not from a path
            # spliced into the script: bind substitutes its own % sequences in
            # whatever it is handed, so a path carrying one would arrive mangled and
            # the area would never be laid out again.
            bind $rows.ed_$kind <Configure> \
                [list [namespace which my] flow_configure %W %w]
            my render_editor $kind
            incr r
        }
        my render_rail
    }

    # What an opened editor is editing. On a single-valued facet already holding
    # its value the add affordance edits that criterion - a commit there replaces,
    # and a replace that kept no identity would break every id held across it - so
    # the editor is handed the criterion and the commit keeps the id. Anywhere
    # else the add is fresh: empty initial, a new id at commit.
    method edit_target {kind} {
        if {[my dget $kind max 0] == 1 && [llength [my values $kind]] == 1} {
            return [list [lindex [dict get $Ids $kind] 0] [my criterion_at $kind 0]]
        }
        return [list "" {}]
    }

    # One row's editor area, rebuilt in place. A `control` facet's area is the
    # caller's whole: the bar hands over the frame under the editor protocol and
    # draws nothing itself, so the control shows the value and no chip repeats it.
    method render_editor {kind} {
        if {![my drawable]} return
        set ed $Top.body.rows.ed_$kind
        if {![winfo exists $ed]} return        ;# collapsed, or a hidden tail facet
        foreach c [winfo children $ed] { destroy $c }
        dict unset Flow $ed
        dict unset FlowW $ed
        if {[my dget $kind mode chips] eq "control"} {
            lassign [my edit_target $kind] editid initial
            {*}[my dget $kind editor ""] $ed $initial \
                [list [namespace which my] editor_commit $kind $editid] \
                [list [self] cancel_add $kind]
            return
        }
        dict set Flow $ed [my render_chips $kind $ed "" 0 1]
        my flow_schedule
    }

    # A facet's chips, in criteria order, joined by that facet's connector. `withadd`
    # is the row's own editor area, where the inline add affordance follows the
    # chips; the collapsed strip passes 0 and takes chips alone. `prefix` tells apart
    # the facets that share the strip; a row's area holds one facet and passes none.
    # `lead` is the gap before the first chip, which in the strip follows the facet's
    # tag. Returns the {widget leftgap} items it drew, for the flow to lay out.
    method render_chips {kind parent prefix lead withadd} {
        set cstyle [my facet_style $kind chipstyle chip]
        set ctl    [my dget $kind chipctl ""]
        set orword [my dget $kind orword [my opt orword]]
        set gap    [my gap chip]
        set items [list]
        set i 0
        foreach v [my values $kind] {
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
                -width 0 -command [list [namespace which my] user_remove $kind $i]
            if {[my opt delside] eq "left"} {
                pack $chip.x -side left -padx [list 0 $gap]
            } else {
                pack $chip.x -side right -padx [list $gap 0]
            }
            if {$ctl ne ""} {
                {*}$ctl $chip.lead $kind $i $v
                if {[winfo exists $chip.lead]} {
                    pack $chip.lead -side left -padx [list 0 $gap]
                }
            }
            ttk::label $chip.t -style [my style chiptext] \
                -text [my format [my criterion_at $kind $i]]
            pack $chip.t -side left
            lappend items [list $chip [expr {$i > 0 ? $gap : $lead}]]
            incr i
        }
        if {$withadd} {
            set w [my render_add $kind $parent]
            if {$w ne ""} { lappend items [list $w [expr {$i > 0 ? $gap : $lead}]] }
        }
        return $items
    }

    # The inline add affordance: a button that opens, in place, into the facet's
    # editor. It reads "+" on an empty facet, and once the facet holds a value it
    # reads as one more joined to it, in whatever word that facet joins with. On a
    # single-valued facet it keeps reading "+", because there a commit replaces: an
    # affordance offering to join a second value to the first would be advertising
    # something the facet will not do. A facet that can take no more value has none of
    # this: no button, and no open editor either, whichever way that editor was opened.
    # Returns the widget it built, or "".
    method render_add {kind parent} {
        if {![my addable $kind]} { return "" }
        if {[::querybuilder::getdef $Editing $kind 0]} {
            ttk::frame $parent.add
            lassign [my edit_target $kind] editid initial
            {*}[my dget $kind editor ""] $parent.add $initial \
                [list [namespace which my] editor_commit $kind $editid] \
                [list [self] cancel_add $kind]
            my adopt_editor $parent.add $kind
            return $parent.add
        }
        set joins [expr {[llength [my values $kind]] > 0 && [my dget $kind max 0] != 1}]
        ttk::button $parent.add -style [my style add] -width 0 \
            -text [expr {$joins ? [my dget $kind ortext [my opt ortext]] : [my opt addtext]}] \
            -command [list [self] begin_add $kind]
        return $parent.add
    }

    # Escape without editor code: after the editor callback returns, every widget
    # it built - at whatever depth - gets the builder's own bindtag appended, so
    # the builder's Escape binding cancels the add whichever child holds the
    # focus. Appended, not prepended: an editor that binds Escape itself is
    # answered first, and a binding that destroys its window ends the delivery,
    # so the builder's does not fire into the wreckage.
    method adopt_editor {frame kind} {
        set tag [self]::esc_$kind
        bind $tag <Escape> [list [self] cancel_add $kind]
        set queue [list $frame]
        while {[llength $queue]} {
            set queue [lassign $queue w]
            lappend queue {*}[winfo children $w]
            bindtags $w [linsert [bindtags $w] end $tag]
        }
    }

    # The add rail: one button per tail facet still out of use. A facet with no editor
    # is not offered there, because pressing its button would reveal a row with
    # nothing to type into and take the button away with it: a dead end for the life
    # of the bar. With no facet left to offer, the rail itself goes, rather than
    # ending the bar on a word with nothing after it.
    method render_rail {} {
        set hidden [lmap kind [my kinds] {
            expr {[my tail_hidden $kind] && [my dget $kind editor ""] ne "" ? $kind : [continue]}
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
        foreach kind $hidden {
            ttk::button $rail.b_$kind -style [my style add] -width 0 \
                -text [my dget $kind railtext "+ [my dget $kind label $kind]"] \
                -command [list [self] begin_add $kind]
            pack $rail.b_$kind -side left -padx [list 0 $gap]
        }
    }

    # The collapsed body: the applied facets, each as its tag and then its chips, all
    # of them siblings in one wrapping strip, so a long criterion breaks to a new line
    # rather than run off the edge. The chips keep their delete affordance here: this
    # state summarizes the values, it does not put them out of reach. With nothing
    # applied there is nothing to summarize, so the strip carries the one affordance
    # that opens the bar - a user's fold gesture, like the disclosure's own.
    method render_strip {} {
        set strip $Top.body.strip
        ttk::frame $strip
        pack $strip -side top -fill x
        bind $strip <Configure> [list [namespace which my] flow_configure %W %w]
        set items [list]
        foreach kind [my kinds] {
            if {[llength [my values $kind]] == 0} continue
            ttk::label $strip.tag_$kind -style [my facet_style $kind tagstyle tag] \
                -text [my dget $kind label $kind] -anchor center
            lappend items [list $strip.tag_$kind \
                [expr {[llength $items] ? [my gap group] : 0}]]
            lappend items {*}[my render_chips $kind $strip _${kind}_ [my gap column] 0]
        }
        if {[llength $items] == 0} {
            ttk::button $strip.add -style [my style add] -width 0 \
                -text [my opt emptytext] -command [list [namespace which my] user_fold]
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
        if {[::querybuilder::getdef $FlowW $area -1] == $w} return
        my flow_area $area
    }

    method flow_area {area} {
        set items [::querybuilder::getdef $Flow $area {}]
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
        validate_countfmt validate_countables validate_facets dress_styles desc dget \
        op_default check_op tail_hidden \
        present addable can_take_more check_max check_index same_values \
        alloc_id criterion_at write_values drop_at user_remove user_fold \
        editor_commit edit_target adopt_editor \
        sync_state save_state restore_state after_change draw_change \
        build drawable refresh active_count render_head render_rows render_editor \
        render_chips render_add render_rail render_strip \
        flow_schedule flow_all flow_configure flow_area
}
