# questlog status

The single record of what questlog does, and the only file in `research/` written from the code rather than from the field. The sibling files describe the market: the pain taxonomy in `use-case-survey.md`, the verbatim quotes in `voices.md`, the competitor supply in `competitive-landscape.md`, the discussion dynamics in `discussion-drivers.md`. This file says which of those pains questlog covers, how, and where in the code. Update it when the code changes; update the siblings when the field changes. Pain numbers (P1-P13) are defined in `use-case-survey.md`.

Snapshot June 2026.

## Coverage

| Pain | Coverage | How | Code |
|---|---|---|---|
| P1 Context loss at compaction / session end | Partial | The viewer segments the transcript at `compact_boundary` records and 10-minute idle gaps, so a reader lands at the boundary and reads up to it | `ui/viewer.tcl`. Ceiling: `/compact` runs server-side and is not written back to the JSONL, so no local reader can recover compacted content |
| P2 Finding a past session and reading it | Solved | Cross-session regex search, hit-centred streaming snippets, and the segmented viewer; subagent transcripts are searched as first-class targets and listed under their parent session | `lib/search.tcl`, `lib/scan.tcl`, `ui/sessions.tcl`, `ui/viewer.tcl` |
| P3 Resuming and forking | Solved | Resume, fork, and resume-in-new-terminal-tab from the right-click menu, in the session's original cwd | `lib/terminal.tcl`, `ui/sessions.tcl:1475`. The resume cache-cost spike is Anthropic-side and out of reach |
| P4 Finding which session touched a file | Solved | Tool-use path search over Read/Write/Edit records (bare filename matches any directory by suffix), with a git-status file picker | `lib/match.tcl`, `lib/jsonl.tcl`, `lib/search.tcl`; picker `ui/toolbar.tcl:479-563`. The git listbox seeds the Write and Edit dropdowns; the Read dropdown keeps its file chooser and manual entry without a git list, since git status reports changed files (a write/edit signal), not reads (issue #16) |
| P5 Seeing which of many sessions is live | Solved | A "running only" filter reads live Claude processes from the process table, validated against `/proc`, so it sees sessions from any terminal | `lib/live.tcl` |
| P6 Organising: grouping, moving, naming | Solved | Group by project folder; move and drag-to-move between folders preserving the bookmark; in-place rename writing Claude's native title records | `lib/path.tcl`, `ui/move_dialog.tcl`, `ui/drag.tcl`; rename `ui/sessions.tcl:1494-1512`, `lib/title_writer.tcl` |
| P7 Bookmarking | Solved | The bookmark is the file's `u+x` permission bit (no sidecar), so it survives a move and a copy | `lib/path.tcl` |
| P8 A native, non-Electron tool on Linux | Solved | A Tcl/Tk GUI with no embedded web engine | `questlog` entry script, `ui/*.tcl` |
| P9 Reusing decisions and solutions | Partial (retrieval) | Search and the segmented viewer retrieve the earlier decision when asked | `lib/search.tcl`, `ui/viewer.tcl`. Persisting state forward so a future session never has to look back is a memory-system function questlog does not perform |
| P10 Session history as a record (prove regression, audit) | Partial | Per-session audit through tool-use path search, viewer segmentation, and a tool-call timeline in the viewer (each call as time/tool/path, click-to-jump) for the did-versus-claimed check | `lib/match.tcl`, `ui/viewer.tcl`, `lib/jsonl.tcl`. No bulk cross-session regression analytics |
| P11 Token and cost analytics | Partial | Per-session USD cost cell (a second-pass thread pool over token usage against a dated rate table), per-folder cost aggregates, a running total, sort-by-cost, and cost-tier colouring; a duration cell | `lib/cost.tcl`, `lib/app.tcl`, `lib/scan.tcl`, `ui/sessions.tcl`. No time-series or budget dashboards, live spend monitoring, statusline integration, or model-over-time breakdown |
| P12 Export, sharing, cross-device and cross-client portability | Partial | Copy session as Markdown and Export to .md from the right-click menu (USER/ASSISTANT/SYSTEM turns, segmented by compaction boundary and idle gap like the viewer) | `lib/markdown.tcl`, `ui/sessions.tcl`. Export and share only; cross-device and cross-client unification stay out of reach (server-held sessions) |
| P13 Branching with merge-back; autonomous handoff | None | Fork starts a branch (P3); there is no merge-back and no autonomous handoff | `lib/terminal.tcl` (fork only) |

## Feature catalogue

The features behind the coverage above, each with its code home and the pains it serves.

- Tool-use path search (Read/Write/Edit, suffix match): `lib/jsonl.tcl`, `lib/match.tcl`, `lib/search.tcl`. Serves P4.
- Git-status file picker (Write/Edit dropdowns): `ui/toolbar.tcl`. Serves P4.
- Resume, fork, resume-in-new-terminal-tab: `lib/terminal.tcl`, `ui/sessions.tcl`. Serves P3.
- Bookmark via the `u+x` bit: `lib/path.tcl`. Serves P7.
- Hit-centred streaming snippets with non-scrolling insert: `ui/sessions.tcl`. Serves P2.
- Segmented session viewer (compaction boundary and 10-minute idle gap): `ui/viewer.tcl`. Serves P1, P2, P9, P10.
- Tool-call audit timeline in the viewer (each call as time/tool/path, click-to-jump): `ui/viewer.tcl`, `lib/jsonl.tcl`. Serves P10.
- "This cwd only" auto-detection: `ui/toolbar.tcl`, `lib/app.tcl`. Serves P6 (scope).
- "Running only" live-process filter: `lib/live.tcl`. Serves P5.
- Cross-session regex search, streamed: `lib/search.tcl`, `lib/scan.tcl`. Serves P2, P9.
- Subagents listed under their parent (expand chevron, indented child rows with their own metadata) and searched as first-class targets attributed to the parent: `lib/scan.tcl`, `lib/match.tcl`, `lib/search.tcl`, `ui/sessions.tcl`. Serves P2, P4, P10.
- Move and drag-to-move between folders: `lib/path.tcl`, `ui/move_dialog.tcl`, `ui/drag.tcl`. Serves P6.
- In-place rename writing Claude's native title records: `ui/sessions.tcl`, `lib/title_writer.tcl`. Serves P6.
- Markdown session export (copy as Markdown or save to .md, segmented like the viewer): `lib/markdown.tcl`, `ui/sessions.tcl`. Serves P12.
- Per-session cost accounting: `lib/cost.tcl`, `lib/app.tcl`. Serves P11.
- Coroutine-driven responsiveness (scanner and searcher yield to the Tk event loop; O(1) cancellation): `lib/scan.tcl`. A quality property, not tied to one pain.
- Native Linux Tk GUI, no web engine: `questlog`. Serves P8.

## Differentiation map

For each shipped capability, how rare the same thing is in the field, read from `competitive-landscape.md`. A description of the built product, not a build-priority ranking.

- Tool-use path search: rare. Agent-side equivalents query an index (flex, searchat); the only human-GUI analog is a low-traction VS Code extension.
- Git-status file picker: unique. No surveyed tool turns the current repo's `git status` into session-search criteria.
- Resume and fork: common. Table-stakes across the field.
- Bookmark: rare. Only Chronicle offers any pin or tag.
- Streaming snippets, non-scrolling: rare.
- Segmented viewer: rare. One TUI surfaces compaction boundaries; none segments by both compaction and idle inside a reading pane.
- "This cwd only": common. The category default.
- Live status, any-terminal, read-only: the feature is common (many monitors), but each sees only the sessions it launched; detecting any running session from the process table, read-only, on Linux is unduplicated.
- Cross-session search: common. The crowded centre of the field.
- Move and drag-to-move: rare. A GUI drag that preserves the bookmark on the move is questlog's.
- Per-session cost: common as a capability (the ccusage cluster), though questlog's form is a per-session and per-folder column rather than a dashboard.
- Native Linux, no web engine: rare. Native GUIs in the field are macOS-first, or embed a WebView.
- Coroutine responsiveness: an implementation detail no tool markets.

## Gaps

Architectural limits, given that questlog reads local JSONL and is a human GUI:

- Cross-device and cross-client unification: it cannot see server-held Desktop or Web sessions.
- Cross-agent history: Claude Code only; it does not read other agents' logs.
- An MCP server exposing the index to a running agent: questlog is a human GUI, not an MCP server.

Not built, but feasible within the architecture:

- Cost analytics beyond the per-session column: time-series, budgets, live spend monitoring, statusline integration (P11).
- Interleaving a parent's subagent turns inline in one viewer (issue #13 deferred; subagents are listed and searched, and a subagent hit opens its own transcript).
- Bulk cross-session regression analytics (P10).

## Known viewer issues

- A diagnostic block tied to issue #4 in the viewer source logs mouse events and binds F8 to dump Tk state; text selection in the viewer is in a transitional state and should be re-checked against the code before viewer work proceeds.
- The viewer does not interleave a parent's subagent turns inline; subagents are listed and searched under the parent, and opening a subagent hit loads that subagent's own transcript (issue #13, unified view deferred).
- A full-height persistent viewer is proposed in `design/issues/viewer-full-height-persistent.md`; the pane currently appears only after the first session is opened.

## Positioning

Relocated from the discussion-volume findings in `discussion-drivers.md`, and kept here, in the product file, as explicit strategy. The session-management need is private and consequence-driven, so a feature announcement earns upvotes but few replies; the lanes that fill a comment section are cost, model regression, and usage-limit anxiety. Three moves follow.

1. Ride a loud lane onto a quiet one. questlog is not a cost tool, but the segmented viewer and the live-process detection touch the same "what is my session actually doing" question that powers the cost-cluster threads. An audit framing, "see what the session actually did versus what it claimed," borrows that loaded comment section.
2. Lead with a number. "I built a session viewer" draws fewer replies than a measurable claim does. questlog has measurable claims available: snippet latency across a stated session count, or the git picker turning a typed path into one click.
3. Frame as a question that takes a side: "Should Claude Code session search live in the IDE or in a native GUI?", or "Why does the Linux side ship without a desktop tool?"

The corpus shows no session-viewer launch crossing roughly 150 comments without an Anthropic-grievance hook or a numeric controversy; pure feature announcements top out around 25.
