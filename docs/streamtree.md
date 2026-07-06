# streamtree

A tree drawn into a single Tk `text` widget: abstract nodes nested to any depth, each rendered as one row, with a right-pinned metadata strip whose sortable, resizable columns line up across every row. It is the engine behind the questlog session list (`ui/sessions.tcl`), but it carries no questlog code and runs on its own. `examples/streamtree-demo.tcl` drives it under bare `wish` with a toy file tree.

The engine is a Tcl module, the `streamtree-<version>.tm` file at the repository root. It requires only Tcl 9 and Tk. A host adds the file's directory to the module path, requires the package, and builds the widget into a frame it owns; every hook has a working default, so the base class runs as-is and a subclass overrides only what its content needs:

```tcl
::tcl::tm::path add $dir
package require streamtree

set t [::streamtree::StreamTree new]
$t setup .host                       ;# a frame you created and packed
$t insert "" row a [dict create label "first row"]
```

`setup` runs the whole construction ritual: it seeds the engine state, builds the header and list into the frame, and lays out the columns. A host with bespoke assembly needs may instead do what `setup` does step by step, as questlog's session list does. Content beyond a flat labelled list comes from subclassing and overriding hooks (columns, rich subjects, sorts, per-kind row styles).

## Why a text widget, not ttk::treeview

`ttk::treeview` cannot draw multi-line rows, embed per-row widgets (the session list's match snippets and badge pills), anchor the viewport against a streaming insert, or roll child aggregates up into a parent heading. StreamTree renders into a `text` widget to get all of that, and reuses treeview's *vocabulary* so the API reads as familiar.

## Vocabulary mapped to ttk::treeview

| StreamTree | ttk::treeview | Notes |
|---|---|---|
| `insert parent kind key payload` | `insert parent end -id ...` | returns a node id; renders now if the parent is open |
| `delete id` | `delete id` | removes the node and its subtree from view and store |
| `detach id` | `detach id` | removes the row from view, keeps the node (and its open state) in the store |
| `item id` | `item id -values ...` | rewrites the node's own row in place |
| `expand id` / `collapse id` | `item id -open true/false` | draws / removes the body |
| `hide id` / `unhide id` | `detach` + `move` | a reversible per-node filter (treeview has no first-class hide) |
| `move id newparent` | `move id newparent end` | reparents, then rebuilds |
| `column id -width N -minwidth M` | `column id -width N -minwidth M` | per-column width override and clamp |
| `rebuild` | (none) | re-render the whole tree from the durable store under the active sort; no treeview counterpart |
| `reset` | `delete [children {}]` | empty the whole widget |

Every primitive owns its text-mark mutation and ends in `check_invariant`; a host never touches the underlying text widget.

### Content door

Match snippets and badge windows are loose row content, not nodes. They go through a small door that appends inside a node's region and carries that node's end mark forward, along with every ancestor end coincident with it:

- `append_open id` → a temp mark at the node's append point
- `emit mark text tags` / `emit_window mark args` → insert text or an embedded window
- `append_close id mark` → advance the marks past what was emitted

## The streaming contract

The widget's defining behaviour: content arriving while the user reads never moves what they are reading.

- A streamed mutation is bracketed with `anchor_save` / `anchor_restore`. A reader pinned at the top stays at the top; a reader inside the list keeps their line even when rows land above it.
- With `-autofollow 1` and the reader at the tail, the view latches to the tail and follows streamed appends (the `tail -f` / chat contract); the latch releases the moment they scroll away.
- `follow` jumps to the tail and re-latches.
- `<<AtBottom>>` and `<<LeftBottom>>` fire on the host frame when the view reaches or leaves the last line, so a host can show a "jump to latest" affordance the way chat clients do.

## Hooks a subclass overrides

Every hook has a working default: the base class renders each node's payload `label` (falling back to the node key) as a plain tree with no metadata columns.

Content / layout: `subject_label` (header over the subject column), `column_spec`, `render_subject`, `cell_values`, `cell_tag`, `sort_key`, `apply_column_tabs` (default sets the tab stops widget-wide; override to configure row tags that carry their own `-tabs`), `relayout_content`.

Row lifecycle (per node kind): `start_gravity`, `row_tags`, `on_node_created` (register domain indices before the row renders), `on_row_rendered` (wire bindings, nested content, selection), `on_before_delete` (drop domain indices).

Rebuild: `sort_siblings` (reorder a sibling set for display, keeping every node), `render_skip` (leave a node out of the view while keeping it in the store), `rebuild_restore` (re-pin the viewport to a captured top node).

## Options

The engine takes its host-specific look and services as options, set through `configure` before the body is built, so its body holds no host references:

| Option | Default | Purpose |
|---|---|---|
| `-listfont` | `TkTextFont` | the row / list font |
| `-headfont` | `TkHeadingFont` | the column-heading font |
| `-colours` | a plain Tk palette | dict with keys `strip` (heading background), `muted` (heading ink), `ink` (active-column ink) |
| `-resortdelay` | `250` | ms a streamed resort debounces before one rebuild |
| `-autofollow` | `0` | keep the view latched to the tail while the reader is there |
| `-motioncb` | empty | a `<B1-Motion>` script the drag-to-move host wires in |

## The audit gate

Set the `STREAMTREE_AUDIT` environment variable and every primitive checks the per-node mark contract after it runs: each node's `[start,end]` region is well-formed and the roots are ordered and disjoint down the buffer. The first violation latches `::STREAMTREE_AUDIT_TRIPPED` and writes an `INVARIANT @ <primitive>` line to stderr naming the operation that broke the contract. Production leaves the variable unset and pays nothing. `test/run-audit.sh` runs the whole test suite with the gate on; `test/test-soak.tcl` interleaves the four concurrent drivers under it.

## Limits

To a screen reader the widget presents as one text area, not a tree of rows and columns; assistive-technology structure (row navigation, expansion state) is not exposed. Cell editing, checkbox columns, and type-ahead are not built in; a host can assemble them from embedded windows, row tags, and key bindings.
