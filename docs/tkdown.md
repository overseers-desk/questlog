# tkdown

## NAME

tkdown - a pragmatic markdown renderer for a Tk text widget

## SYNOPSIS

```tcl
::tcl::tm::path add $dir
package require tkdown

text .body
::tkdown::tags .body [::tkdown::ensure_fonts] -margin 8 -quotetags quote
.body tag configure td-link -foreground blue -underline 1
::tkdown::body .body end $markdown {base} {base code}
```

## DESCRIPTION

Markdown reaches a Tk application constantly, in chat bodies, transcripts, notes files and tool output, and the choices on offer are showing the markers raw or embedding a browser. tkdown is the third: it parses a completed block of markdown into structured segments and inline runs, then paints those onto a `text` widget under the styling tags it owns.

It covers the forms such text actually carries: fenced code, blockquotes, GFM pipe tables, ATX and setext headings, thematic breaks, lines holding an image, nested bullet and numbered lists, links and bare URLs, code spans, and asterisk emphasis. Everything else is left as literal text.

`body` paints a whole document in one walk. It splits the body into blocks, fenced code, quotes, rules, image lines, tables and prose, and hands each to the emitter for its kind. Every kind has a default emitter, and a host may replace any of them with its own command or switch a kind off, leaving its lines as written in the prose around them.

The parse half is pure Tcl and needs no Tk, so it runs under a bare `tclsh`; the emit half needs Tk.

## THE HOST OWNS THE CHROME

Every `td-*` tag the module configures is either font-only or geometry-only, never coloured. The module owns the faces: `td-bold`, `td-italic`, `td-bolditalic`, `td-code`, `td-link` (the body face) and the heading levels, each carrying nothing but a `-font`, and `td-rule`, a face two pixels tall with its line spacing zeroed. The geometry tags carry layout and no font: `td-margin` the host's margin itself, `td-list` and `td-list<depth>` the list hanging indents, `td-listc<depth>` the indent of a line an item continues on, `td-quote` a quote's inset, and `td-tblwin` the margins of the character holding a table's grid, all set from the margin the host names with `-margin`.

`td-margin` is configured by `tags` and exists from then on; `refit -margin` only reconfigures it. Everything `body`, `prose` and `runs` paint carries it alongside the host's base tags: prose, list and quote lines, rules, an image or its alt text, a table's window character, and a code block under `codeTags`. The host therefore states its measure once, as `-margin`. `td-margin` is kept the lowest-priority tag on the widget, so any tag that sets a margin of its own wins where the two stack: a host tag, created before `tags` or after it, and the module's `td-list`, `td-quote` and `td-tblwin`.

Colour and selection stay the host's everywhere. A caller passes its own base tags into every emit call, and each styled span stacks the module's face over those base tags, so only the typeface changes and the host's ink and layout hold underneath. Where a block has ink of its own, the host configures a `td-*` tag for it; the module lays or reads that tag and never sets its colour:

| Tag | The host configures | Laid on |
|---|---|---|
| `td-link` | `-foreground`, `-underline`, and bindings (`<Button-1>` calling `link_at`) | every link's text |
| `td-quotebar` | `-foreground` | the bar opening each line of a quote |
| `td-rule` | `-background`, the rule's colour | the one line of a rule |
| `td-grid` | `-background`, the gridline colour | nothing; read when a grid is coloured |
| `td-spot` | `-background`, a spotlit grid's gridline colour | nothing; read when a grid is spotlit |
| `td-margin` | nothing; its margins are `-margin`'s | everything `body`, `prose` and `runs` paint |

That split is why the host, not the module, decides the fonts. `tags` takes a dict of Tk font names the host has created to match its own reading font, and the module binds those names onto its faces; `ensure_fonts` supplies a ready set for a host with no faces of its own. A code block goes in one step further: `body` inserts it under a `codeTags` list the host passes outright, because a code block's margins and background are host chrome, not a tkdown face.

## THE SEGMENT AND INLINE MODEL

The parse half splits a body in layers, each splitter seeing a body the ones above it have already peeled. `body` runs `segment_code_fences` first, then on each prose run `segment_blockquotes`, `segment_rules`, `segment_images` and `segment_tables`; what remains is prose, whose emitter splits lists with `segment_lists`, lifts its own headings, and passes each run of text through `parse_inline`. `segment_headings` is not part of that walk: it serves a host that wants a document's headings as segments.

| Proc | Produces | Kinds |
|---|---|---|
| `segment_code_fences` | `{kind text}` | `prose`, `code` (the verbatim run between a pair of fence lines, markers and language tag gone; an unterminated fence runs to the end) |
| `segment_blockquotes` | `{kind text}` | `normal`, `quote` (a maximal run of `>` lines, de-quoted one marker deep; a bare blank line ends it) |
| `segment_headings` | `{kind payload}` | `normal` (text), `heading` (`{level title}`): an ATX line of one to six `#` and a space, its closing `#` run dropped, or a setext pair, a line of text over an underline of three or more `=` (level 1) or `-` (level 2). The line above an underline must be non-blank plain text, and neither line may hold a `\|`, so a table's delimiter row is never an underline. Lines inside a fence are never headings, and the fence lines stay in the normal text. |
| `segment_rules` | `{kind payload}` | `normal` (text), `rule` (empty): a line of three or more `-`, `*` or `_`, spaces allowed between, that is not a setext underline and not inside a fence |
| `segment_images` | `{kind payload}` | `normal` (text), `image` (`{alt path}`): a line holding nothing but one `![alt](path)`, an optional quoted title after the path |
| `segment_tables` | `{kind payload}` | `normal` (text), `table` (`{align <per-col> rows <header-then-body>}`, every row padded or cut to the header's width) |
| `segment_lists` | `{kind payload}` | `normal` (text), `list` (the items in source order, each `{depth marker text}`) |
| `parse_inline` | ordered runs | `{style chunk}` with style `plain`, `code`, `bold`, `italic` or `bolditalic`, and `{link chunk url}`; markers stripped, adjacent plain runs coalesced, the display text always at index 1 |

A list item opens with `-`, `*` or `+` and a space, its marker `•`, or with ASCII digits, a dot and a space, its marker those digits and the dot, so a list keeps its source numbering. Its depth is its indentation in steps of two spaces or one tab. A non-blank line under an item that opens no item of its own, flush left or indented, joins that item's text and keeps its line break: the item's text holds a newline between the two source lines, the continuation's own indentation dropped. Blank lines followed by another item keep the list going; blank lines followed by anything else end it. `tcl 9.0`, `1.2.3` and `- - -` open nothing.

The inline rules are pragmatic rather than full CommonMark. A code span wins over everything else, so asterisks, brackets and URLs inside `` `code` `` stay literal. `[text](url)` is a link whose display text is the raw text between the brackets; a bare `http://` or `https://` URL, or one in `<angle brackets>`, is a link whose text is the URL, less any trailing punctuation and any unbalanced closing parenthesis. An inline `![alt](path)` shows its alt text as plain text. Emphasis is asterisks only, so `snake_case` and `__init__` are left alone. An opener needs a non-space character after it and a closer one before it, so `3 * 4` and a `* ` bullet stay literal. A backslash escapes a literal backtick, asterisk or backslash, and every other backslash is kept verbatim, so paths and regex survive intact.

`table_to_markdown payload` turns a table payload back into GFM text that `segment_tables` reads to the same payload. `table_colwidths rows avail em space` is the grid's column allocator, pure and callable on its own: given each cell's word widths in pixels, it returns the column widths that fit `avail` with the fewest wrapped lines.

## THE EMIT API

Each emit call inserts at an index the caller advances, a mark or `end`, painting in document order.

| Proc | Arguments | Purpose |
|---|---|---|
| `ensure_fonts` | | Create the Td\* faces from `TkTextFont` and `TkFixedFont` once per interp and return their fonts dict, `{body TdBody bold TdBodyBold italic TdBodyItalic bolditalic TdBodyBoldItalic mono TdMono monobold TdMonoBold}`. A widget given one of these font names before `ensure_fonts` has created it keeps Tk's fallback face even once the font exists, so a host calls `ensure_fonts` before any widget names a font from it. |
| `tags` | `w fonts ?option value ...?` | Register a text widget: configure its `td-*` faces from the fonts dict, take the options below, and open its table and link registries. Call once per widget before painting; calling again keeps the tables and links it holds. |
| `body` | `w idx text baseTags codeTags ?emitters?` | Paint a markdown body block by block, then one closing newline under `baseTags`. |
| `prose` | `w idx text baseTags ?suffix?` | Paint one prose run through `emit_prose`, then `suffix` (default `"\n\n"`) under `baseTags`. |
| `runs` | `w idx text baseTags` | Insert one run's inline spans. |
| `link_at` | `w idx` | The url of the link under `idx`, or `""`. |
| `link_scan` | `w needle nocase` | Search the links' urls: `{index url}` per link whose url holds the needle and whose visible text does not, in document order, the index being the start of the link's text. A match in the text, a bare URL's included, is left to the host's own text search. |
| `table_scan` | `w needle nocase` | Search the tables' cell text: `{mark excerpt}` per matching table, in document order. |
| `table_spotlight` | `w idx` | Light the table whose mark is at `idx` and put out the one lit before; `""` puts it out. |
| `refit` | `w ?option value ...?` | Re-set any option, re-derive the margins, and re-fit every built grid. |
| `forget` | `w` | Destroy the widget's grids, unset their marks and drop its links before a full re-render. |
| `unregister` | `w` | Drop the widget from the registry, its grids with it; runs on the widget's `<Destroy>`. |

The options, each re-settable through `refit`:

| Option | Default | Meaning |
|---|---|---|
| `-margin` | `{0 0}` | The host's base margin, `{left right}` or one distance for both, held by `td-margin`. Lists and quotes indent from it, a grid sits at its left edge and spends the width between the two. |
| `-quotetags` | `{}` | Tags the default quote emitter lays over a whole quote, for the host's ink and inset. |
| `-image_cmd` | `{}` | A command called with an image's path, returning a Tk image name or `""`. |
| `-on_block` | `{}` | A command told of each block `body` paints. |
| `-copystyle` | `Copy.TButton` | The ttk style of a grid's copy button, a style the host defines. Until the host defines it, or for any style ttk has no layout for, the module falls back to `TButton`. |

The fonts dict requires the keys `body`, `bold`, `italic`, `bolditalic` and `mono`; a missing one is an error. `monobold` is optional and, like any extra key, is kept for the host; nothing in the module draws with it. The heading keys `h1`, `h2` and `h3` are optional, each falling back to `bold`. Levels four through six all paint as `h3`, so a document never asks for a face the host did not size.

### Blocks and emitters

`body` walks fenced code first, then quotes, rules, image lines and tables, and paints the rest as prose. `emitters` is a dict mapping a block kind to the command that paints it. A kind the dict leaves out goes to its default, `::tkdown::emit_<kind>`. A kind mapped to `""` is not split out at all: its lines stay where they stand and reach the next splitter and, at last, the prose emitter exactly as written, so with `quote ""` a `>` line paints literally, and with `code ""` the fence lines do. Every kind but `prose` may be switched off. Each emitter is called with the widget and the index, then:

| Kind | Called as | Default |
|---|---|---|
| `prose` | `cmd w idx text baseTags` | `emit_prose`: headings, lists and inline runs, the last line left open |
| `code` | `cmd w idx text codeTags` | `emit_code`: the text verbatim under `codeTags` |
| `quote` | `cmd w idx text baseTags` | `emit_quote`, with the text de-quoted one level |
| `table` | `cmd w idx payload baseTags` | `emit_table`: the grid, below |
| `image` | `cmd w idx alt path baseTags` | `emit_image` |
| `rule` | `cmd w idx baseTags` | `emit_rule` |

Every block ends its own line before the next begins. The walk closes a prose block's last line itself, and closes any other block's line its emitter left open, so a table under a list starts on a line of its own.

After each block, `-on_block` is called as `cmd kind start end text`: `start` is the first character of the block's own content and `end` the index just past everything it inserted, exclusive. A newline an emitter writes ahead of a quote, rule, image or table to set it off, such as the blank line the default quote emitter puts between prose and a quote, lies before `start`, so a host inserting at `start` lands on the block's first painted line. `text` is the block's text (a quote's de-quoted, a table's as GFM, an image's alt, a rule's empty). It fires for every non-empty block `body` paints, each time it paints it, so a host that repaints a range hears its blocks again; a prose block of nothing but blank lines, the gap between two other blocks, is painted and not reported.

The default prose emitter lifts a heading line out under `td-h1`, `td-h2` or `td-h3`: an ATX line, or a line of text over a setext underline. Within prose a `---` under a line of text is that line's underline, not a rule. A list paints one logical line per item: the marker, then the item text through the inline-run path, so markdown inside an item still styles. Each item carries `td-list` and `td-list<depth>`, a hanging indent that sets the marker 10 pixels inside the host's margin plus 18 a level and lands the item text, and any line it wraps to, 20 pixels past the marker. A line the item continues on also carries `td-listc<depth>`, which starts it at the item text too. An item more than one level below the item before it is drawn one level below it.

The default quote emitter sets a quote off from the text above with a blank line when there is none. Each physical line opens with a `▏ ` bar under `td-quotebar` and goes on through the inline-run path; the whole block lies under the base tags, `-quotetags` and `td-quote`, whose inset is 14 pixels inside the margin. A `>` still inside the de-quoted text is literal.

The default image emitter calls `-image_cmd` with the path. A Tk image it returns is embedded on a line of its own under the base tags; with no command, or an empty answer, the alt text stands in, through the inline-run path in the body face.

The default rule emitter paints one line holding a single space under `td-rule` and the base tags. `td-rule`'s face is two pixels tall, so the line is a thin bar in whatever `-background` the host gives the tag. The tag zeroes `-spacing1`, `-spacing2` and `-spacing3` and is raised over the base tags, when configured and again as each rule is painted, so a base tag that spaces its lines does not thicken the bar.

### Links

A link's text goes in under the base tags, `td-link`, and a tag of its own, `td-link<N>`, whose number is never reused in the widget. The registry maps that tag to the link's url, which is how `link_at` answers for a click and `link_scan` searches urls a reader cannot see. `forget` deletes the per-link tags with the registry, and `link_scan` drops any link whose text has been deleted.

## THE TABLE AND REFIT LIFECYCLE

A pipe table renders as a grid: one embedded window in the text, a frame of gridded `text` cells that wrap their words. A table wider than the pane keeps its columns and folds its long cells onto more lines, so nothing runs past the right edge. Cells take their font from the fonts dict, the header row bold throughout, and inline markdown inside a cell still styles; each column honours the delimiter's left, right or centre alignment. A cell's background and cursor are the text widget's, its ink comes from the first base tag carrying a `-foreground` (the widget's own foreground otherwise), and the frame showing through between the cells is the gridline colour, `td-grid`'s `-background` or the widget's foreground when the host configured none.

The window builds itself only when the text first shows it, so a long document costs no widgets until the reader reaches its tables. What search and spotlight need is recorded when the table is painted: the payload, the cells' text as the reader sees it, and a left-gravity mark `tbl#m<N>` on the window character. That character carries `td-tblwin` and the base tags, so a host's fold or elide tag reaches the table like any other text, and it is followed by its newline under the base tags. A table met mid-line starts a line of its own.

Column widths are fitted to the pane: the room is the widget's inner width less both margins and each column's gridlines and cell padding, every cell's words are measured in the face they paint in, and `table_colwidths` divides the room. A table that fits keeps its natural widths and does not stretch to the pane. Each cell's height follows the width it is given. A grid is fitted once it is built and again, on the next idle pass, whenever the widget is resized or the host calls `refit`; a reading-font change fires no resize, so the host calls `refit`, which measures the words afresh.

Under the pointer a grid shows a copy button at its top-right, `-copystyle`'s ttk style, which copies the table to the clipboard as GFM text and shows a tick for a moment; a drag-selection cannot reach into an embedded window, so this is how a reader copies a table. The mouse wheel over a grid scrolls the text widget, with the delta it arrived with.

A text search cannot see into an embedded window either, so the module searches for the host. `table_scan` returns `{mark excerpt}` for each table holding the needle, in document order, the excerpt being the first matching cell's text. The mark is an index like any other: a host can scroll to it, and `table_spotlight` with the same index paints that table's gridlines in `td-spot`'s `-background`, putting out the table lit before. The spotlight takes effect before the table is built, so a jump that scrolls a table into view for the first time shows it lit.

Before a full re-render, the host calls `forget`: it destroys every grid, unsets every `tbl#m<N>` mark, deletes the per-link tags, and empties both registries. Table and link numbers carry on across `forget`, so a number never names two tables or two links in one widget's life. A `delete 1.0 end` alone destroys the built grids along with their window characters, and `refit`, `table_scan` and `forget` each drop the record of any table whose window character is gone. A table leaving the record takes its mark with it, a built grid's on the idle pass after its window goes, so a pane repainted many times without `forget` does not pile up `tbl#m<N>` marks. Registration survives `forget`; the registry entry dies with the widget.

## LIMITS

tkdown is not a full CommonMark implementation. A quote is one level deep: a `>` inside a quote is literal, and a quote's lines go through the inline pass only, so a list or heading inside a quote stays plain text. Links are inline only, with no reference-style `[text][ref]` definitions. Fences do not nest. A fence line is taken wherever it stands, so one indented under a list item ends the list; inside a quote it is quoted text. Underscores never mark emphasis. A column whose cells are all empty still takes one character's width in a grid. Anything outside the covered forms renders as literal text.

tkdown also takes completed blocks, not a stream: each call paints a finished body in one pass. A host streaming content re-renders the affected block from its own model and repaints it whole.

## REQUIREMENTS

Tcl 9 for the parse half; Tk for the emit half.

## KEYWORDS

markdown, text widget, GFM, tables, links, rendering, transcript
