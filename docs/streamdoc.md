# streamdoc

## NAME

streamdoc - a streaming document of foldable regions in one Tk text widget

## SYNOPSIS

```tcl
::tcl::tm::path add $dir
package require streamdoc

set d [::streamdoc::StreamDoc new]
$d setup .host                        ;# a frame you created and packed
$d batch {
    set r [$d region_open [dict create]]
    set m [$d append_open]
    $d emit $m "▾ A region\nits body\n" {}
    $d append_close $m
    $d region_close
}
```

## DESCRIPTION

A transcript or log viewer wants three things at once: content streaming in at the tail while the user reads, finished sections folding to one line, and the reader's scroll position holding still through both. Doing this with raw text-widget indices breaks the first time an insert lands above the viewport; doing it with one text widget per section forfeits search, selection, and the single scrollbar.

streamdoc owns an append-only document rendered into a single read-only `text` widget: free text (chrome) interleaved with foldable regions, each a header line, a body, and an optional trailing summary line. Region boundaries are real Tk marks, a left-gravity start and a right-gravity end that rides the tail while the region is open and is sealed on close, so streamed inserts carry the bookkeeping by gravity, not by index arithmetic. The host supplies every character through the content door and the hooks (Template Method); the base class owns the marks, the elide layers, and the streaming contract, and never looks inside a payload.

Each region has exactly two elide layers, both owned by the base class (no host tag may set an explicit `-elide`):

- **fold** - the whole body and summary collapse to the header line. The layer covers whole logical lines and never the header's own newline, so folding everything leaves one header per line, a table of contents.
- **detail** - lines the host tags with `detail_tag $n` as it emits, hidden by default behind the summary line. The detail layer outranks the fold layer, so unfolding a region does not spill its hidden detail, and re-folding re-hides whatever was revealed.

The first character of a header line and of a summary line is a state glyph from the `-glyphs` pair, but the two track different state: the header glyph mirrors the region's fold state, the summary glyph mirrors its detail-shown state. The base class swaps each in place with a same-length replace, so downstream indices stay true. A header or summary line that does not start with a glyph is left alone.

## PRIMITIVES

| Primitive | Role |
|---|---|
| `region_open payload` | open a region at the tail; returns its index `n` |
| `region_close` | seal the open region: summary written, fold range laid, end mark sealed |
| `append_open` → mark | open the door: into the open region (popping its summary), else chrome at the tail |
| `emit mark text tags` / `emit_window mark args` | insert text or an embedded window at the door |
| `append_close mark` | close the door; the open region's summary re-appends |
| `savepoint` → mark | a left-gravity mark at the append point, for a later rewind |
| `rewind mark` | delete from a saved mark to the open region's end; the caller re-emits |
| `discard mark` | release a savepoint mark |
| `fold n` / `unfold n` / `toggle n` | collapse a region to its header / restore it |
| `detail_show n` / `detail_hide n` / `detail_toggle n` | reveal / re-hide a region's detail layer |
| `fold_all` / `expand_all` | the table-of-contents reading, and back |
| `summary_sync` | re-derive the open region's summary line from its payload |
| `reveal idx` | unfold and un-hide whatever covers an index, then scroll it into view |
| `region_at idx` | the region containing an index, `-1` for chrome |
| `detail_tag n` | the tag the host lays on region `n`'s detail lines as it emits |
| `payload n` / `payload_set n payload` | the region's opaque host dict |
| `region_count` / `live` / `folded n` / `shown n` | document and per-region state |
| `region_info n` | a region's resolved state: `{start end summary open folded shown payload}` |
| `reset` | empty the document: buffer, marks, elide tags, store |
| `batch script` | run mutations with the widget editable and the view anchored once |
| `follow` | jump to the tail and latch there |

Every mutating primitive ends in `check_invariant`; a host never touches the underlying text widget.

## THE CONTENT DOOR AND REWIND

All content, chrome and region alike, goes through the door inside a `batch`, in whole newline-terminated lines. While a region is open the door feeds it: `append_open` pops any standing summary line so new content lands inside the region, not under its summary, and `append_close` re-appends the summary from the current payload - the one legal rewrite window a mid-document line gets. Between regions the door appends chrome.

`rewind` is the door's undo: take a `savepoint` before emitting a provisional tail, then rewind to it and re-emit. The mark survives the cut (left gravity holds it at the boundary), so a feed can rewind to the same point repeatedly - the shape a wet-tail streaming renderer needs, and the mechanism the base class's own summary pop is built on.

## THE STREAMING CONTRACT

The widget's defining behaviour: content arriving while the user reads never moves what they are reading.

- A streamed mutation is bracketed by `batch`'s `anchor_save` / `anchor_restore`. A reader parked anywhere in the document keeps their line while regions land below.
- With `-autofollow 1` and the reader at the tail, the view latches to the tail and follows streamed appends (the `tail -f` / chat contract); the latch releases the moment they scroll away.
- `follow` jumps to the tail and re-latches.
- `<<AtBottom>>` and `<<LeftBottom>>` fire on the host frame when the view reaches or leaves the last line, so a host can show a "jump to latest" affordance the way chat clients do.

## HOOKS

- `summary_text payload` - the summary phrase for a region's payload; the empty string takes no summary line. Default: always empty.
- `region_tags payload` - the tags laid on the summary line the base class writes, so the host can style and bind it. Default: `summary`.
- `on_region_rendered n` - runs when a region closes; wire bindings or indices here. Default: nothing.

Everything else a host adds - header styling, click-to-fold, detail styling - is ordinary tag configuration and tag bindings on tags the host emits itself, resolved back to a region through `region_at`.

## OPTIONS

Set through `configure` before `setup`:

| Option | Default | Purpose |
|---|---|---|
| `-font` | `TkTextFont` | the document font |
| `-glyphs` | `{▸ ▾}` | the closed/open state glyph pair, one char each |
| `-autofollow` | `0` | keep the view latched to the tail while the reader is there |

## THE AUDIT GATE

Set the `STREAMDOC_AUDIT` environment variable and every primitive checks the mark contract after it runs: each region's `[start,end)` is well-formed and starts on a line start, regions are ordered and disjoint down the buffer, a standing summary mark sits inside its region, and the open region's end rides the buffer tail. The first violation latches `::STREAMDOC_AUDIT_TRIPPED` and writes an `INVARIANT @ <primitive>` line to stderr naming the operation that broke the contract. Production leaves the variable unset and pays nothing.

## LIMITS

One region may be open at a time, and the document is append-only: closed regions are immutable except for their 1-char state glyphs, and `rewind` reaches only the open region's tail. A region's header is exactly one line. Emitted content must arrive in whole newline-terminated lines, or the next region's header lands mid-line (the audit names it). To a screen reader the widget presents as one text area; region structure and fold state are not exposed.

## REQUIREMENTS

Tcl 9 and Tk. The sibling of [streamtree](streamtree.md): a document of regions here, a tree of rows there, the same architecture.

## KEYWORDS

text widget, streaming, fold, elide, transcript, log viewer, tail -f
