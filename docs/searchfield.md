# searchfield

## NAME

searchfield - the typed half of a query: terms, case, region, live publishing

## SYNOPSIS

```tcl
::tcl::tm::path add $dir
package require searchfield

set sf [::searchfield::SearchField new]
$sf configure -label "Search:" -inlabel "in" \
    -regions {any "anywhere" subject Subject} \
    -live 1 -debounce 200 -changecommand {apply_query}
$sf setup .host                      ;# a frame you created and packed
$sf set_fragment {terms {foo "bar baz"} case 1}
```

## DESCRIPTION

A search entry wired straight to the answer path scans the corpus on every keystroke; one wired to a button loses the live feel. And the entry never stays alone: a case toggle appears beside it, then a scope picker, then pills for applied filters, then `from:ana` syntax - each a fresh piece of ad hoc glue holding query state in widget variables. searchfield owns that one line. It tokenizes what is typed under a fixed grammar (whitespace separates terms, double quotes make a phrase ONE term, a backslashed quote is a literal), publishes on a debounced cadence while the user types, and carries the case toggle, the region picker, and a strip of consumer-supplied pills. What the terms are matched *against* - which corpus, at what cost, on which thread - is the owner's business entirely: the field hands the fragment over and asks nothing about it.

It is one half of the shared query contract at [../../query-contract.md](../../query-contract.md): the field owns the `terms`, `case` and `region` keys of the query dict, and the sibling [querybuilder](../querybuilder/querybuilder.md) owns `criteria`. Neither knows the other, deliberately: each publishes a fragment, and the consumer merges the two dicts into one query and answers it. The pairing is a page of consumer code, not a megawidget; the contract file shows the whole merge, and the field's demo shows it running.

The grammar lives in two plain procs, `::searchfield::split_terms` and `::searchfield::join_terms`, exact inverses, so a consumer tokenizes or reassembles exactly as the field does and nowhere keeps a second grammar in sync.

## PUBLISHING

`-live 1` publishes on a debounced cadence: a key release (or a paste) that changed the text arms a `-debounce` millisecond timer, and the timer's lapse publishes; `-live 0` publishes on Return only. Return publishes at once in both modes, cancelling any pending debounce, so one Return is never two publishes. The case toggle and the region picker publish on the spot in both modes: each is one deliberate click, not a keystroke mid-burst. `owns_focus` and `is_typing` let a host's global shortcut decline while the user types, and let an expensive consumer defer while a burst is still running.

The contract's one rule holds here as in the builder: every callback fires on user action only, and every programmatic door - `set_fragment`, `reset`, `tokens`, `configure` - is quiet. A consumer that mutates programmatically reacts by calling `publish` or its own answer path.

## TOKENS

The field renders a consumer-supplied list of pills inside itself, before the entry. `tokens $list` sets it; each element is `{label <text> tag <opaque>}`, and setting an unchanged list is a no-op - no relayout, no flicker, no caret disturbance - so a consumer may re-mirror on every publish without guarding. The field draws the label and hands the tag back through `-removecommand` when the pill's close affordance is clicked, or when Backspace at the entry's start reaches the last pill, so keyboard users remove tokens too. Handing back is all it does: the list is the consumer's, and the pill leaves when the consumer sets the survivors. A consumer mirroring builder criteria uses criterion ids as tags, so a removal names its criterion whatever else moved meanwhile.

## PROMOTION

A consumer may teach the field that some typed tokens are structure, not text: `origin:china` belongs in the criteria bar, not in the term list. A typed term matching `-promotepattern` is withheld from `fragment`, and so from every publish - nobody scans a corpus for a half-typed `origin:c` - until promotion time, set by `-promoteon`: `return` (the default), `tokenend` (the text has moved past the term), or `focusout`. Each withheld term then goes to `-promotecommand` with the term and the pattern's capture groups appended, so the callback reuses the pattern's own parse. The callback returns the term's replacement: empty means consumed (its text leaves the field), anything else stays as a term, exempt from another test until the user next edits it, so a declining callback fires once, not on every keystroke after. When one gesture both promotes and publishes (Return does), every promote call completes first and exactly one publish follows. Consumers with no promotion syntax set neither option.

## METHODS

The shared idiom - **fragment**, **set_fragment** *frag*, **reset**, **publish**, **setup** *frame*, **configure**, **cget** - is the contract's, verbatim: the fragment is `{terms <list> case 0|1 region <name>}` with every key always present, a partial `set_fragment` merges and ignores keys the field does not own, so a whole saved query dict feeds it verbatim, and seeded terms land exempt from promotion. The field's own doors are **tokens** *?list?*, **owns_focus** and **is_typing**, above.

## OPTIONS

| Option | Default | Purpose |
|---|---|---|
| `-regions` | `{any "anywhere"}` | dict of stable region name to display label; the fragment carries the name, the menu shows the label, the first name is the resting default; one region draws no picker |
| `-label` / `-inlabel` | `""` | the leading label, and the word before the region picker |
| `-placeholder` | `""` | the entry's hint text while empty |
| `-casetext` / `-closetext` | `Aa` / `×` | the case toggle's text and a pill's close affordance |
| `-live` / `-debounce` | `1` / `200` | the publishing cadence, above |
| `-changecommand` | empty | command prefix invoked with the fragment appended, on user gestures only |
| `-removecommand` | empty | command prefix invoked with a removed token's tag appended |
| `-promotecommand` / `-promotepattern` / `-promoteon` | empty / empty / `return` | promotion, above; runs only while both the pattern and the command are set |
| `-styles` / `-gaps` | see header | role-to-style and role-to-pixels dicts; a partial dict merges |

`configure` is all or nothing, before or after `setup`; a reconfigure keeps whatever current values remain valid under the new declaration (a region the new `-regions` still names stands, one it dropped falls back to the first name). Every widget the field draws takes a ttk style named by a role, and the module names no colour and no font of its own; it dresses only `SFPill.TFrame`, and only while it still carries that name. The widget paths of everything the field builds are stable and listed in the module header, which carries the full contract this page compresses.

## REQUIREMENTS

Tcl 9 and Tk. The floor comes from [leash](../leash/leash.md), this repository's own module, which the field uses so its debounce dies with the field; the field's own code asks no more than 8.6. The `-placeholder` hint is Tk 9's ttk entry option, and a Tk without it goes without the hint. The typed half of the query contract; [querybuilder](../querybuilder/querybuilder.md) is the structured half.

## KEYWORDS

search, entry, debounce, query, tokens, pills, promotion, ttk
