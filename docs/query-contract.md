# The query contract

Two widgets edit one query: `searchfield` (the typed text, its case toggle, its
region scope) and `querybuilder` (the structured criteria). Neither knows the
other. Each publishes a fragment; the consumer merges the fragments into one
query dict and answers it at whatever cost its data demands. A query is a
description of what the user wants, not a promise about where the answer comes
from: one consumer greps ten files in memory, another fans worker threads over
a hundred thousand.

## The query dict

```
terms     list of search tokens; a phrase is ONE list element however many
          words it holds
case      0|1, case-sensitive matching (default 0)
region    where terms may match: any | <consumer-declared region names>
          (default any)
criteria  list of criterion dicts (below), default empty
```

`searchfield` owns `terms`, `case`, `region`. `querybuilder` owns `criteria`.
The dict is plain data, made to be saved and restored verbatim.

The field's typing grammar: whitespace separates tokens; double quotes group
words into one token; a literal double quote inside a phrase is backslashed.
`fragment` returns terms already tokenized by that grammar, and tokens the
field is withholding for promotion (below) are excluded, because re-reading
`fragment` is the canonical consumer path and half-typed structure is exactly
what withholding keeps away from a scan. Field tokens (the pill objects,
below) are display items and no part of `terms`.

## A criterion

```
id     stable identity, assigned by the builder at add time and unchanged for
       the criterion's life; removal never renumbers survivors
kind   the facet it belongs to; the consumer declares the kinds
op     one of the facet's declared operator vocabulary, or "" for a facet
       declared without one
value  the criterion's value, opaque to both widgets
```

`add_criterion $kind $value ?$op?` returns the new criterion's id. Omitting
`$op` means the facet's declared `defaultop`; naming an op outside the
facet's vocabulary, or a kind outside the declaration, is an error raised at
the call, since a criterion that cannot render has no better moment to fail.
`remove_criterion $id` drops the criterion and returns nothing; an unknown
id is an error, since a consumer holding a dead id has a bookkeeping bug
worth hearing about. Editing a criterion preserves its id, whatever the
implementation does inside, so an id held across an edit stays good.
`set_fragment` honors the ids a restored fragment carries, and the builder's
id generator allocates past them, so saved-search restore keeps every id
stable and collision-free.

## When callbacks fire: the one rule

Every callback fires on user action only; every programmatic entry point is
quiet. That is the whole rule, and it covers all of them: `set_fragment`,
`add_criterion`, `remove_criterion`, `tokens`, `collapse`, `expand` fire
nothing. A consumer that mutates programmatically and wants the app to react
calls its own answer path, or the widget's `publish` (fire the change
callback now with the current fragment) to reuse that one code path.

The rule exists because answering may be expensive: only the consumer knows
when a batch of mutations is complete, so only the consumer decides when a
scan is worth launching. A widget that fired mid-batch would hand a stale,
half-built query to a worker fleet.

## Callback signatures

Every callback is a command prefix; the widget appends its arguments:

```
-changecommand   fragment          the widget's current fragment dict
-foldcommand     state             1 collapsed, 0 expanded
-removecommand   tag               the removed token's tag
-promotecommand  token submatches  the token and its pattern captures
```

## The shared idiom

Both widgets expose the same verbs, so a consumer learns one idiom:

- `fragment`            read the widget's current fragment, a dict; every
                        key the widget owns is present, defaults included,
                        so `dict get` on an owned key is safe unconditionally
- `set_fragment $frag`  seed values quietly; a PARTIAL dict merges into the
                        current fragment, so `{terms {foo}}` changes terms
                        and leaves case and region standing; keys the widget
                        does not own are ignored, so the whole saved query
                        dict feeds both widgets verbatim
- `reset`               return the fragment to its documented defaults, quietly
- `publish`             fire the change callback once with the current fragment
- `setup $win`          populate `$win`, an empty frame the consumer created
                        and owns; the consumer destroys `$win` for teardown,
                        after which the object is inert and reusable by the
                        next `setup`; a consumer done with the object calls
                        `$obj destroy` as well, which leaves `$win` untouched

Options follow Tk's style: run-together lowercase, callbacks named
`-...command` (`-changecommand`, `-removecommand`, `-foldcommand`), matching
the `-postcommand`/`-validatecommand` precedent. Options are `configure`/
`cget` state and may be reconfigured after `setup`; a reconfigure that
changes structure (`-facets`, `-regions`) rebuilds the widget's own UI and
keeps whatever current values remain valid under the new declaration,
dropping the rest.

Merging is the consumer's whole job:

```tcl
proc merged {sf qb} {
    dict merge [$sf fragment] [$qb fragment]
}
```

An expensive consumer that funnels several routes into one answer path may
keep the last-answered dict and skip an answer whose merged query is equal;
the fragments are plain dicts, so the comparison is `dict` equality and
costs nothing next to a scan.

## searchfield specifics

`-regions` is a dict of stable name to display label (`{any "Any part"
subject Subject}`); the fragment carries the name, the menu shows the label.
`-live 1` publishes on a debounced cadence while the user types (`-debounce`
milliseconds); `-live 0` publishes on Return only. Return publishes in both
modes.

Tokens: the field renders a consumer-supplied list of pills inside itself.
`tokens $list` sets it; each element is `{label <text> tag <opaque>}`. The
field draws the label and hands the tag back through `-removecommand` when
the pill's close glyph is clicked, or when Backspace at the field's start
reaches the last pill, so keyboard users remove tokens too. The tag is
opaque to the field; a consumer mirroring builder criteria uses criterion
ids as tags. Setting an unchanged list is a no-op: no relayout, no flicker,
no caret disturbance, so a consumer may re-mirror on every publish without
guarding.

## querybuilder specifics

A facet declaration is a pure dict:

```
{kind flag  label "carry the flag"  op {any all}  defaultop any  editor flag_editor}
```

`kind` is a simple word (alphanumeric), safe to embed in a pattern. `op` is
the operator vocabulary shown as the chip's pill menu, omitted for a facet
with no operators. `defaultop` is what an omitted op at `add_criterion`
means; required when `op` is declared. `kinds` returns the declared kind
names in declaration order.

`-foldcommand` fires on every user fold change, collapse and expand alike;
`collapsed` reads the current fold state. Folding is display only: it moves
no value, so the fragment before and after a fold is identical and a fold
handler has no reason to reach the answer path. `format $criterion` returns
the chip text the builder itself would draw (the facet's `format` command
applied, raw value as the fallback), so a consumer mirroring criteria
elsewhere renders the same labels the chips carry.

### The editor protocol

An editor is a command prefix, called when the user opens the facet's add
row (or edits an existing criterion):

```
{*}$editor $frame $initial $commit $cancel
```

`$frame` is an empty ttk frame inside the builder's row: the editor packs
its widgets there and owns nothing else. `$initial` is the criterion dict
being edited, or an empty dict for a fresh add. `$commit` and `$cancel` are
command prefixes: the editor invokes `{*}$commit $value ?$op?` when the user
accepts (Return, a pick, a button - the editor's choice of gesture), or
`{*}$cancel` to abort. An omitted op at commit keeps the criterion's
current op when editing and means `defaultop` on a fresh add. Escape
cancels without editor code: after the editor returns, the builder inserts
its own bindtag into every widget under `$frame`, so its Escape binding
fires whichever child holds focus. The builder validates the committed value the same way
`add_criterion` does, keeps the row open on error with the editor intact,
and on success renders the chip, destroys `$frame`'s children, and fires
`-changecommand`, this being user action. Chip text comes from the facet's
optional `format` command prefix (`{*}$format $criterion` returning the
label); absent, the chip shows the raw value.

## Promotion (optional, field-side)

A consumer may teach the field that some typed tokens are structure, not
text. `-promotepattern` is a regexp; a token matching it is withheld from
live publishes and from `fragment`, and at promotion time is passed to
`-promotecommand` as `{*}$cmd $token $submatches`, where `$submatches` is
the list of the pattern's capture groups, so the callback reuses the
pattern's own parse instead of keeping a second regexp in sync. The callback
returns the token's replacement in `terms`: empty means consumed (it became
a criterion, via the consumer calling the builder, and its text leaves the
field), anything else stays a term. A token kept as a term is exempt from
re-promotion until the user next edits it, so a declining callback fires
once, not on every keystroke after. Promotion time is set by `-promoteon`:
`return` (the default), `tokenend` (a completed token, i.e. at the
following whitespace), or `focusout`. When one user action both promotes
and publishes (Return does), every `-promotecommand` call completes first
and exactly one publish follows. Withholding applies to typed text only:
terms seeded through `set_fragment` pass into `fragment` untested, quiet
in, quiet through. Consumers with no promotion syntax set neither option.
The builder's `kinds` method gives the declaration to build the pattern
from; a consumer that derives `-promotepattern` from it recomputes the
pattern after any `configure -facets`, since the field holds the computed
string, not the derivation.
