# tkdown

## NAME

tkdown - a pragmatic markdown renderer for a Tk text widget

## SYNOPSIS

```tcl
::tcl::tm::path add $dir
package require tkdown

text .body
::tkdown::tags .body [dict create \
    body TkTextFont bold myBold italic myItalic bolditalic myBoldItalic \
    mono TkFixedFont]
::tkdown::prose .body end $markdown {base} "\n\n"
```

## DESCRIPTION

Markdown reaches a Tk application constantly, in chat bodies, transcripts, and tool output, and the choices on offer are showing the markers raw or embedding a browser. tkdown is the third: it parses a completed block of markdown into structured segments and inline runs, then paints those onto a `text` widget under the styling tags it owns. The emit half paints fenced code, GFM pipe tables, ATX headings, flat lists, code spans, and asterisk emphasis, and leaves everything else as literal text. Blockquotes are parse-half only: `segment_blockquotes` splits them off, and a host that wants quotes styled paints each de-quoted run itself, under its own tags, because a quote's chrome (bar, indent, ink) is host styling in the same way a code block's is.

The parse half is pure Tcl and needs no Tk, so it runs under a bare `tclsh`; the emit half needs Tk.

## THE HOST OWNS THE CHROME

Every `td-*` tag is either font-only or geometry-only, never coloured. The module owns the faces: it configures `td-bold`, `td-italic`, `td-code`, and the heading levels, each carrying nothing but a `-font`. The two geometry tags carry layout and no font: a table's `td-tbl<N>` tag carries its tab stops and the module's fixed table geometry, and `td-list` the list hanging indent. Colour and selection stay the host's everywhere. A caller passes its own base tags into every emit call, and each styled span stacks the module's face over those base tags, so only the typeface changes and the host's ink and layout hold underneath.

That split is why the host, not the module, configures the fonts. `tags` takes a dict of Tk font names the host has already created to match its own reading font, and the module simply binds those names onto its faces. A code block goes in one step further: `body` inserts it under a `codeTags` name the host passes outright, because a code block's margins and background are host chrome, not a tkdown face.

## THE SEGMENT AND INLINE MODEL

The parse half splits a body in layers, each splitter seeing a body the ones above it have already peeled. The block splitters run first, then one prose run at a time goes through the inline pass.

| Proc | Produces | Kinds |
|---|---|---|
| `segment_code_fences` | `{kind text}` | `prose`, `code` (the verbatim run between a pair of fence lines, markers and language tag gone) |
| `segment_blockquotes` | `{kind text}` | `normal`, `quote` (a maximal run of `>` lines, de-quoted one marker deep); parse-half only, the emit walk does not call it |
| `segment_tables` | `{kind payload}` | `normal`, `table` (a parsed GFM pipe table, `{align <per-col> rows <header-then-body>}`) |
| `segment_lists` | `{kind payload}` | `normal`, `list` (a maximal run of `- `/`* `/`N. ` lines; payload is the flat items, each `{num text}`) |
| `parse_inline` | ordered `{style chunk}` runs | `plain`, `code`, `bold`, `italic`, `bolditalic`, markers stripped, adjacent plain runs coalesced |

The inline rules are pragmatic rather than full CommonMark. A code span wins over emphasis, so asterisks inside `` `code` `` stay literal. Emphasis is asterisks only, so `snake_case` and `__init__` are left alone. An opener needs a non-space character after it and a closer one before it, so `3 * 4` and a `* ` bullet marker stay literal. A backslash escapes a literal backtick, asterisk, or backslash, and every other backslash is kept verbatim, so paths and regex survive intact.

## THE EMIT API

Each emit call inserts at an index the caller advances, a mark or `end`, painting in document order.

| Proc | Arguments | Purpose |
|---|---|---|
| `tags` | `w fonts` | Register a text widget: configure its `td-*` faces from the fonts dict and open its table registry. Call once per widget before painting. |
| `runs` | `w idx text baseTags` | Insert one prose run's inline spans at `idx`. |
| `prose` | `w idx text baseTags {suffix "\n\n"}` | Insert prose plus GFM pipe tables, ATX headings, and flat lists, closed by `suffix`. |
| `body` | `w idx text baseTags codeTags` | Insert a fenced body: prose segments through `prose`, fenced code verbatim under `codeTags`. |
| `refit` | `w` | Recompute the tab stops of every rendered table under the current fonts. |
| `forget` | `w` | Drop the widget's rendered tables before a full re-render. |

The fonts dict requires the keys `body`, `bold`, `italic`, `bolditalic`, and `mono`; a missing one is an error, and extra keys are kept but nothing draws with them. The heading keys `h1`, `h2`, and `h3` are optional, each falling back to `bold` when the host leaves it out. ATX heading lines map by their marker count, and four through six `#` all clamp to `h3`, so a document never asks for a face the host did not size.

A flat list renders as one logical line per item: a marker, a tab, then the item text through the inline-run path so markdown inside an item still styles. The marker is a `•` bullet for an unordered item or the item's own number and a dot for an ordered one (`3. ` renders `3.`, the source numbering preserved rather than renumbered). The whole list carries `td-list`, a hanging indent that sets the marker at the left margin and lands the item text, and any line it wraps to, at the tab stop past it; the tag is geometry only, so colour still comes from the base tags.

## THE TABLE AND REFIT LIFECYCLE

A pipe table renders as tab-aligned columns rather than a grid. Each table gets its own `td-tbl<N>` tag carrying the computed `-tabs`, so two tables on one widget never share column geometry, and `-wrap none`, so a row wider than the pane clips at the right edge instead of wrapping and breaking the columns. Header cells also carry `td-head` for bold. The column widths come from measuring each cell's content in the font it will paint in, the header measured bold, and the stops honour the delimiter's per-column left, right, or centre alignment. Column zero anchors at the left margin, so a delimiter asking right or centre there falls back to left; the stops are floored to stay strictly increasing, which Tk requires of a tab spec.

The stops depend on the font, not the pane width, so a resize needs no recompute but a reading-font change does: the host calls `refit` and every rendered table recomputes its stops from the payload the registry kept at render time. Before a full re-render, the host calls `forget`: the `td-tbl<N>` tags survive a `delete 1.0 end` as configured-but-empty tags and would pile up across reloads, so `forget` drops them along with the retained payloads. Registration itself survives, and the registry entry dies with the widget.

## LIMITS

tkdown is not a full CommonMark implementation. Its lists are flat: an indented continuation or a nested marker stays literal, and a host wanting nested lists asks for a block model this renderer keeps deliberately flat. It has no links and no setext (underline) headings; underscores never mark emphasis; anything outside the covered forms renders as literal text. It also takes completed blocks, not a stream: each call paints a finished body in one pass. A host streaming content re-renders the affected block from its own model and repaints it whole.

## REQUIREMENTS

Tcl 9 for the parse half; Tk for the emit half.

## KEYWORDS

markdown, text widget, GFM, tables, rendering, transcript
