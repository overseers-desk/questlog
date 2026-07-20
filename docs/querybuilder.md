# querybuilder

## NAME

querybuilder - a bar of structured criteria, kept as chips

## SYNOPSIS

```tcl
::tcl::tm::path add $dir
package require querybuilder

set qb [::querybuilder::QueryBuilder new]
$qb configure -heading "Show the items that" \
    -changecommand {apply_criteria} -facets {
        {kind colour label colour conn "is"      editor colour_editor}
        {kind flag   label flag   conn "carries" op {any all} defaultop any
         editor flag_editor tail 1}
    }
$qb setup .host                      ;# a frame you created and packed
$qb add_criterion colour red         ;# returns the criterion's stable id
```

## DESCRIPTION

A filter bar assembled by hand from comboboxes and entries has no owner: what is applied lives scattered across the widgets, folding the bar away hides values the user can no longer count or remove, and every new criterion type is another bespoke row of glue. querybuilder is the owner. It holds a set of criteria - each an applied instance of a *facet* the consumer declares - and draws each one as a chip with a live delete affordance. Expanded, it shows one editor row per facet and an add rail offering the optional facets not yet in use; collapsed, it shows just the chips. Every criterion carries a stable integer id assigned at add time: removal never renumbers the survivors and an edit preserves the id, so an id held across either stays good. What the criteria are *for* - what they select, restrict or colour - is the consumer's business entirely: values are opaque, the widget stores them, prints them through the caller's formatter, and hands them back.

It is one half of the shared query contract at [query-contract.md](query-contract.md): the builder owns the `criteria` key of the query dict, and the sibling [searchfield](searchfield.md) owns `terms`, `case` and `region`. Neither knows the other, deliberately: each publishes a fragment, and the consumer merges the two dicts into one query and answers it at whatever cost its data demands. The pairing is a page of consumer code, not a megawidget; the contract file shows the whole merge.

## FACETS ARE DATA, NOT SUBCLASSES

One bar carries several facets at once, and they differ from each other, not from bar to bar - so the type-specific part is a descriptor dict hung on the facet, not methods hung on a subclass, and a host adds a facet at runtime by appending a dict to `-facets`. Only `kind` is required; the descriptor list is validated where it is written, so a mistyped key fails at the `configure`, not as a row that silently never draws.

| Key | Meaning |
|---|---|
| `kind` | the facet's name and its criteria's `kind`; a plain word (letters, digits, underscore) |
| `label` | the word on the type tag (defaults to the kind) |
| `conn` | the connective word between tag and editor ("" draws none) |
| `format` | command prefix over the whole criterion dict, returning the chip's text; the raw value is the fallback |
| `op` / `defaultop` | the operator vocabulary carried per criterion, and what an omitted op means; declared together or not at all |
| `mode` | `chips` (default) or `control`, below |
| `max` | most values the facet may hold (0: no limit); a rule on the model, refused at every door that would break it; `max 1` replaces on commit |
| `dedupe` | 1 (default) treats a repeated value as no second criterion |
| `orword` / `ortext` | this facet's chip connector and its "one more" affordance, over the bar-wide defaults |
| `tail` | 1 for an optional facet, revealed from the add rail |
| `editor` | command prefix building the facet's editor (the protocol below) |
| `chipctl` | command prefix drawing an optional per-value control inside the chip, a swatch on a colour chip |
| `railtext`, `tagstyle`, `chipstyle` | the rail button's text and per-facet style overrides |

Two editor modes, because one is not enough and three would be a taxonomy. In `chips` mode values are typed or picked one at a time: the widget draws the chips and the inline add affordance, and the descriptor's editor builds only the control that affordance opens into. In `control` mode one bespoke widget - a stepper, a menu of choices that exclude one another - owns the whole editor area and reports what it holds through `report_values`. One chip renderer serves both, so a collapsed bar reads the same whichever mode a facet is in.

## THE CRITERIA

The by-id doors follow the contract: **add_criterion** *kind value ?op?* returns the new id (under the facet's own rules: replace at `max 1`, the existing id on a deduped repeat), **remove_criterion** *id* drops it wherever it sits, and a dead id is an error, since a caller holding one has a bookkeeping bug worth hearing about. **fragment** / **set_fragment** / **reset** / **publish** are the shared idiom, verbatim from the contract; a restored fragment's ids are honored and the generator allocates past them, so saved-search restore keeps every id stable. **format** *criterion* returns the chip text the builder itself would draw, so a consumer mirroring criteria elsewhere renders the same labels; **kinds** lists the declared kinds in order.

Beside them sit the owner's doors in the *model* shape (a dict of kind to values, no ids or ops): **model**, **values** *kind*, **set_model** *m*, **set_values** *kind vals*, **set_value_at** *kind i v* and **remove_value_at** *kind i*, each edit preserving the ids of the positions that survive. **report_values** *kind vals* is a `control` editor's own door: as `set_values`, except it does not redraw the editor it came from, which is what keeps a control alive under the hand that just moved it. **begin_add** / **cancel_add** open and abandon an add as the bar's own affordances would; **expand** / **collapse** / **toggle** / **expanded** / **collapsed** are the disclosure. Every method that takes a kind, an index or an id refuses one that names nothing, and every door that draws rolls back to a consistent widget if the drawing raises.

## THE EDITOR PROTOCOL

An editor is a command prefix, called when the user opens the facet's add row (and, in `control` mode, whenever the row is drawn):

```
{*}$editor $frame $initial $commit $cancel
```

`$frame` is an empty ttk frame the editor packs its widgets into; `$initial` is the criterion under edit, or an empty dict on a fresh add; the editor invokes `{*}$commit $value ?$op?` on the user's accept, or `{*}$cancel` to abort. Escape cancels with no editor code: the builder appends its own bindtag to every widget under `$frame`. The builder validates the commit as `add_criterion` would, draws the chip, and fires `-changecommand`, this being user action; a drawing that raises keeps the row open with the editor's text intact. The full protocol, including how a `control` editor differs, is in the contract file and the module header.

## WHEN CALLBACKS FIRE

The contract's one rule: every callback fires on user action only, and every programmatic entry point is quiet - `set_model`, `set_fragment`, `add_criterion`, `expand`, all of them. Only the consumer knows when a batch of mutations is complete, so only the consumer decides when to react, by calling `publish` or its own answer path. `-foldcommand` fires on the user's own fold gestures; folding is display only, the fragment before and after a fold is identical.

## COLLAPSE SUMMARIZES, IT NEVER HIDES

A collapsed bar still draws every applied criterion as a chip, delete affordance live; what it takes away is the editors and the rail. A chip the user cannot see is a chip the user cannot delete, and a bar holding a value its user can neither reach nor count is a bar lying about what it holds - so the one state that could hide a value is the one state the widget will not enter. The same rule makes a `control` facet without an editor a declaration error.

## THE LOOK

Every widget the bar draws takes a ttk style named by a role in `-styles` (or per facet by `tagstyle`/`chipstyle`), and the module names no colour, no font and no padding of its own. Two roles have a look the pattern cannot do without - a chip and a tag must at least have an outline - so the bar dresses `QBChip.TFrame` and `QBTag.TLabel`, but only while they still carry the names it ships with: name a style of your own and the bar never touches it. Every gap is in `-gaps`, in pixels, and nowhere else. Chips wrap: an area lays them left to right, breaks to a new line when the next would not fit, and asks for no more width than its widest single chip, so a width-pinned host frame makes the bar wrap and grow downward.

## OPTIONS

| Option | Default | Purpose |
|---|---|---|
| `-facets` | `{}` | the ordered descriptor list; that order is the rows' reading order |
| `-heading` | `""` | the head line's text |
| `-countfmt` / `-countables` | `"%d active"` / all | the active count appended to the heading, and which facets it sums |
| `-orword` / `-addtext` / `-ortext` / `-deltext` / `-delside` | `or` / `+` / `+ or` / `×` / `right` | the chip strip's words and the delete affordance's end |
| `-raillabel` / `-emptytext` | `Add` / `+ add` | the rail's leading word, and the collapsed empty bar's affordance |
| `-expandtext` / `-collapsetext` / `-disclosure` | `▸` / `▾` / `1` | the disclosure; 0 leaves it out, and with no heading the head line goes too |
| `-changecommand` | empty | command prefix invoked with the fragment appended, on user changes only |
| `-foldcommand` | empty | command prefix invoked with the fold state appended (1 collapsed), on user folds only |
| `-styles` / `-gaps` | see header | role-to-style and role-to-pixels dicts; a partial dict merges |

`configure` is all or nothing: a set applies every pair or, if one is bad - including one whose badness only shows when the bar redraws - none, criteria included. The widget paths of everything the bar builds are stable and listed in the module header, so a host can hang a tooltip on a chip or drive one from a test; the header carries the full per-key contract this page compresses.

## LIMITS

Every value can be removed and every facet can be edited: there is no locked value, no read-only state and no disabled facet. Between one facet and the next the bar draws nothing and takes no position on how criteria combine; the connective and connector words are the owner's to say.

## REQUIREMENTS

Tcl and Tk 8.6 or better. The structured half of the query contract; [searchfield](searchfield.md) is the typed half.

## KEYWORDS

filter, criteria, facet, chips, query, search, ttk
