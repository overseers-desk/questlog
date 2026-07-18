# streamtree

## NAME

streamtree - a tree with sortable columns drawn in one Tk text widget

## SYNOPSIS

```tcl
::tcl::tm::path add $dir
package require streamtree

set t [::streamtree::StreamTree new]
$t setup .host                       ;# a frame you created and packed
$t insert "" row a [dict create label "first row"]
```

## DESCRIPTION

`ttk::treeview` cannot draw multi-line rows, embed per-row widgets (match snippets, badge pills), anchor the viewport against a streaming insert, or roll child aggregates up into a parent heading. A canvas rewrite that can is a project of its own.

streamtree renders a tree of abstract nodes into a single `text` widget: nodes nested to any depth, each rendered as one row, with a right-pinned metadata strip whose sortable, resizable columns line up across every row. It reuses treeview's *vocabulary* so the API reads as familiar. Each node carries the position marks and tag that locate it in the widget plus an opaque domain payload; the subclass supplies content and ordering through hooks (Template Method), and the engine never looks inside a payload.

`setup` runs the whole construction ritual: it seeds the engine state, builds the header and list into the frame, and lays out the columns. A host that wants to assemble things differently can do what `setup` does, step by step. Content beyond a flat labelled list comes from subclassing and overriding hooks (columns, rich subjects, sorts, per-kind row styles).

## PRIMITIVES MAPPED TO ttk::treeview

| streamtree | ttk::treeview | Notes |
|---|---|---|
| `insert parent kind key payload` | `insert parent end -id ...` | `kind` selects the row's per-node-type hooks (`start_gravity`, `row_tags`, ...); returns a node id; renders now if the parent is open and the node is not hidden |
| `delete id` | `delete id` | removes the node and its subtree from view and store |
| `detach id` | `detach id` | removes the row from view, keeps the node (and its open state) in the store |
| `item id` | `item id -values ...` | rewrites the node's own row in place |
| `expand id` / `collapse id` | `item id -open true/false` | draws / removes the body |
| `hide id` / `unhide id` | `detach` + `move` | a reversible per-node filter (treeview has no first-class hide) |
| `move id newparent` | `move id newparent end` | reparents, then rebuilds |
| `column id -width N -minwidth M` | `column id -width N -minwidth M` | per-column width override and clamp |
| `rebuild` | (none) | re-render the whole tree from the durable store under the active sort |
| `reset` | `delete [children {}]` | empty the whole widget |

Every primitive owns its text-mark mutation and ends in `check_invariant`; a host never touches the underlying text widget.

`expand` calls the `populate` hook first, so it is safe on a lazily-built tree, and it degrades to recording the open flag on a node whose own row is not drawn. Opening one level everywhere is therefore a one-liner from outside, `batch` anchoring the reader's scroll position once for the whole sweep:

```tcl
$t batch { lmap id [$t roots] { $t expand $id } }
```

## THE CONTENT DOOR

Match snippets and badge windows are loose row content, not nodes. They go through a small door that appends inside a node's region and carries that node's end mark forward, along with every ancestor end coincident with it:

- `append_open id` → a temp mark at the node's append point
- `emit mark text tags` / `emit_window mark args` → insert text or an embedded window
- `append_close id mark` → advance the marks past what was emitted

## THE STREAMING CONTRACT

The widget's defining behaviour: content arriving while the user reads never moves what they are reading.

- A streamed mutation is bracketed with `anchor_save` / `anchor_restore`. A reader pinned at the top stays at the top; a reader inside the list keeps their line even when rows land above it.
- With `-autofollow 1` and the reader at the tail, the view latches to the tail and follows streamed appends (the `tail -f` / chat contract); the latch releases the moment they scroll away.
- `follow` jumps to the tail and re-latches.
- `<<AtBottom>>` and `<<LeftBottom>>` fire on the host frame when the view reaches or leaves the last line, so a host can show a "jump to latest" affordance the way chat clients do.

## HOOKS

Every hook has a working default: the base class renders each node's payload `label` (falling back to the node key) as a plain tree with no metadata columns.

Content / layout: `subject_label` (header over the subject column), `column_spec`, `render_subject`, `cell_values`, `cell_tag`, `sort_key`, `apply_column_tabs` (default sets the tab stops widget-wide; override to configure row tags that carry their own `-tabs`), `relayout_content`.

Row lifecycle (per node kind): `start_gravity`, `row_tags`, `on_node_created` (register domain indices before the row renders), `on_row_rendered` (wire bindings, nested content, selection), `on_before_delete` (drop domain indices), `populate` (called at the top of `expand`; a lazy host enumerates and attaches the node's children here, a materialized tree keeps the no-op default).

Rebuild: `sort_siblings` (reorder a sibling set for display, keeping every node), `render_skip` (leave a node out of the view while keeping it in the store), `rebuild_restore` (re-pin the viewport to a captured top node).

## THE SUBCLASS SURFACE

A hook body works with its nodes through the store accessors, part of the subclassing contract: `node_exists id`, `node_get id` (the whole node dict), `node_field id field` / `node_set id field value` (one generic field), `node_payload id` (the opaque host dict) and `node_pget id key ?default?` / `node_pset id key value` (one payload key), and `roots` (the ordered root ids). Beside them sit the helpers a subclass reaches for while rendering and sorting: `colour role` (a `-colours` entry), `truncate_px text px font` (ellipsize to a pixel width), `all_rendered_nodes` (ids with a row in the view, document order), `set_sort id` (adopt a column as the active sort) and `schedule_resort` (debounced re-sort after streamed edits, `-resortdelay`). The demos use exactly this surface and nothing deeper; a subclass that finds itself wanting more than these and the hooks is reading the engine's own internals.

## OPTIONS

The engine takes its host-specific look and services as options, set through `configure` before the body is built, so its body holds no host references:

| Option | Default | Purpose |
|---|---|---|
| `-listfont` | `TkTextFont` | the row / list font |
| `-headfont` | `TkHeadingFont` | the column-heading font |
| `-colours` | a plain Tk palette | dict with keys `strip` (heading background), `muted` (heading ink), `ink` (active-column ink) |
| `-resortdelay` | `250` | ms a streamed resort debounces before one rebuild |
| `-autofollow` | `0` | keep the view latched to the tail while the reader is there |
| `-motioncb` | empty | a `<B1-Motion>` script the drag-to-move host wires in |

## THE AUDIT GATE

Set the `STREAMTREE_AUDIT` environment variable and every primitive checks the per-node mark contract after it runs: each node's `[start,end]` region is well-formed and the roots are ordered and disjoint down the buffer. The first violation latches `::STREAMTREE_AUDIT_TRIPPED` and writes an `INVARIANT @ <primitive>` line to stderr naming the operation that broke the contract. Production leaves the variable unset and pays nothing.

## PERFORMANCE

Measured July 2026 (medians of 3, min-max in parentheses) on an AMD Ryzen 7 5800X under Xvfb software rendering, Tcl/Tk 9.0.1. The numbers are for the base engine (one text string per row, no columns, no per-row bindings); a subclass with metadata columns and wired rows pays more per row.

| scenario | N | median (min-max) | per row | notes |
|---|---|---|---|---|
| bulk load, flat | 10,000 | 606 ms (554-613) | 60.6 µs | single flush for the whole batch |
| bulk load, flat | 50,000 | 3,909 ms (3,870-4,491) | 78.2 µs | single flush for the whole batch |
| bulk load, treed | 10,000 | 546 ms (539-573) | 54.6 µs | 100 expanded folders |
| streaming | 10k + 1,000 | 1,914 inserts/s | p95 780 µs | idle flush per insert; reader's line held |
| full rebuild | 10,000 | 1,210 ms (1,194-1,286) | 121 µs | the debounced resort's cost |
| memory, marginal row | 10k→50k | | 4.36 kB/row | includes the retained payload dict, per-row tag, two marks |

For calibration, ttk::treeview on the same machine bulk-loads 10k display-text-only rows in 28 ms (2.8 µs/row, a native C widget's floor) and holds 0.53 kB/row. It streams 1,846 inserts/s into a 10k flat list, but its scroll shifts on every insert; that repaint is baked into its number, where streamtree's number pays for the anchor work that prevents the shift. The workloads differ in what a row retains: streamtree keeps the payload dict, which doubles as the host's data model.

The engine renders every visible row into the text widget (no virtualization); collapsed subtrees stay unrendered, which is the intended posture for large trees. Practical ceiling: tens of thousands of rendered rows load in seconds and stream comfortably; memory is the binding constraint at roughly 4.4 kB per rendered row.

## LIMITS

To a screen reader the widget presents as one text area, not a tree of rows and columns; assistive-technology structure (row navigation, expansion state) is not exposed. Cell editing, checkbox columns, and type-ahead are not built in; a host can assemble them from embedded windows, row tags, and key bindings.

## DECLARATIVE ATTRIBUTES (1.1.0)

A consumer declares attributes on its rows: an id, a kind (bool or enum), a
label, an optional glyph, and whether a reader may filter on it. A glyphed
bool draws as a subject-prefix mark; a glyphless one as a check-mark column.
Filter controls build into a frame the host owns (a checkbutton per bool, a
stay-open checklist per enum with select all and none); an enum filter is a
set of excluded values. Values reach the engine only through the attr_value
hook. The filter layer hides through a ledger of its own hides and composes
with the consumer's: a node shows only when nobody hides it. The module
header carries the full contract.

## OPEN QUESTION

Filter kinds past bool and enum. A consumer will one day want a scalar
threshold (a numeric column above some value) or a free-text match as a
filter. What the control looks like, how a threshold is typed, and whether
text matching belongs in a tree engine at all are undecided; the kind field
in the declaration is the extension point when the design round happens.

## REQUIREMENTS

Tcl 9 and Tk. The sibling of [streamdoc](streamdoc.md): a tree of rows here, a document of regions there, the same architecture.

## KEYWORDS

treeview, text widget, tree, columns, sort, streaming, virtual list
