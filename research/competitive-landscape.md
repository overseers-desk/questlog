# Competitive Landscape: Claude Code session tools

Snapshot taken May 2026. Survey scope: CLI baselines, TUI browsers, web and native desktop viewers, search indexers, multi-session orchestrators, and cost dashboards that read `~/.claude/projects/*/*.jsonl`. The field is crowded and young: most entries are 2025-2026 launch posts on r/ClaudeCode and GitHub.

Capabilities are as their authors describe them in launch posts and READMEs, not independently re-verified; cells that could not be confirmed read "unconfirmed". Star counts and last-active dates are approximate and omitted where unknown. Pain numbers (P1-P13) cross-reference `use-case-survey.md`. questlog's own coverage is not in this file; it lives in `status.md`.

## Feature matrix

Cells: Yes / No / Partial / unconfirmed, with a short note.

| Tool | Platform / UI | Cross-session search (P2) | Tool-use path search (P4) | Resume / fork (P3) | Bookmark (P7) | Live status (P5) | Compaction + idle segmentation (P1) | Move / organise (P6) |
|---|---|---|---|---|---|---|---|---|
| Claude Code CLI built-in | Node.js terminal picker | Partial (name/summary filter) | No | Yes (`--resume`, `--fork-session`, `/branch`) | No | No | No (compaction is silent) | No |
| Claude Code Desktop | Electron (macOS/Windows) | Partial (sidebar summary) | No | Yes | No | Yes (sidebar live status) | No | No |
| Chronicle (claude-history-manager) | macOS native | Yes (full-text index) | No | Yes (one-click, restores cwd) | Partial (pin / tag) | No | No | No |
| claude session VS Code ext (nypaavsalt) | VS Code ext | Yes (full-text) | Partial (find the session that edited a file) | Yes (resume) | No | No | No | No |
| Agent Sessions (jazzyalex) | macOS native | Yes (instant, multi-agent) | No | Yes | No | No | No | No |
| Agent Deck | tmux TUI | Yes (global) | No | Yes (fork via `f`) | No | Yes (running/waiting/idle) | No | Partial (project groups) |
| Claude Control | macOS native | No | No | Partial | No | Yes (auto-discovers running procs) | No | No |
| Maestro | desktop grid | Partial | No | Partial | No | Yes (status badges) | No | Partial (groups) |
| flow (Facets-cloud) | CLI | No | No | Yes | No | No | No | Yes (tasks under project groups) |
| flex (damiandelmas) | CLI + MCP (SQLite) | Yes (SQL over messages) | Partial (queries file edits / tool calls) | Partial (returns ids) | No | No | No | No |
| searchat | CLI + MCP | Yes (cross-agent) | Partial (MCP agent self-lookup) | Yes | No | No | No | No |
| claude-code-tools / aichat | TUI + CLI (Tantivy) | Yes (FTS, TUI + JSON) | No | Yes | No | No | No | No |
| claude-history (raine) | TUI | Yes (fuzzy + semantic) | No | Yes (Ctrl+R / Ctrl+F fork) | No | No | No | No |
| claude-code-viewer (d-kimuson) | web (self-hosted) | Yes (full-text) | No | Yes | No | Yes (real-time log) | No | No |
| opcode (Claudia) | Tauri desktop | Yes (Smart Search) | No | Yes (timeline/checkpoint) | No | No | Partial (timeline, not compaction-aware) | No |
| ccmanager | Go TUI | No | No | Partial (active worktree) | No | Yes (waiting/busy/idle) | No | No |
| claude-squad | Go TUI (tmux) | No | No | Partial | No | Yes (active state) | No | No |
| search-sessions (sinzin91) | CLI | Yes (sub-second regex) | No | Yes (returns ids) | No | No | No | No |
| claude-code-log (daaain) | TUI + HTML | Partial (type/date filter) | No | Yes | No | No | No (timeline) | No |
| CCM (dr5hn) | Bash CLI | Yes | No | Partial | No | No | No | Yes (relocate on move) |
| ccusage | CLI (reports) | No | No | No | No | No | No | No |

Tool links: code.claude.com/docs/en/sessions (CLI) and /desktop; github.com/JosephYaduvanshi/claude-history-manager (Chronicle); jazzyalex.github.io/agent-sessions; github.com/asheshgoplani/agent-deck; github.com/sverrirsig/claude-control; github.com/damiandelmas/flex; github.com/Process-Point-Technologies-Corporation/searchat; github.com/pchalasani/claude-code-tools; github.com/raine/claude-history; github.com/d-kimuson/claude-code-viewer; github.com/winfunc/opcode; github.com/kbwo/ccmanager; github.com/smtg-ai/claude-squad; github.com/sinzin91/search-sessions; github.com/daaain/claude-code-log; github.com/dr5hn/ccm; github.com/ryoppippi/ccusage.

## Field supply by pain

How much of the field serves each pain, and how.

**P1, context loss at compaction.** Forward memory systems and hooks dominate the coping culture. For reading the archive, segmentation is rare: claude-compaction-viewer surfaces compaction boundaries in a TUI, and opcode shows a timeline that is not compaction-aware. No tool segments a session into readable chapters by both compaction and idle gap inside a reading pane. Ceiling: `/compact` runs server-side and is not written back to the JSONL, so a local reader segments around boundaries rather than recovering compacted content.

**P2, cross-session search.** The crowded centre of the field: Chronicle, Agent Sessions, claude-history, search-sessions, flex, searchat, claude-code-tools, opcode, and claude-code-viewer all search across sessions. Regex specifically is less universal; many use fuzzy, FTS, or semantic search. A no-autoscroll anchor as hits stream in is documented in none of the surveyed tools.

**P3, resume and fork.** Table-stakes: the built-in CLI, Chronicle, claude-history, Agent Deck, opcode, and search-sessions resume; fork exists in the CLI (`--fork-session`, `/branch`), claude-history, and Agent Deck. Chronicle additionally restores the working directory, the specific friction users name. The resume cache-cost spike is an Anthropic-side issue no tool resolves.

**P4, tool-use path search.** Rare. flex queries file edits and tool calls over a SQL index; searchat and claude-code-tools expose session history to the agent over MCP for the "what did I do to this file last time" lookup, answering it from the agent side. A VS Code extension (nypaavsalt) surfaces "find the past conversation that edited this file" directly in a human UI, the closest analog, but at negligible traction (single-digit score). No tool in the field turns the current repo's `git status` into selectable session-search criteria.

**P5, live status.** A common feature: Agent Deck, Claude Control, Maestro, ccmanager, claude-squad, the d-kimuson viewer, and the Desktop sidebar all show it. In every case "live" means a session that tool launched or supervises. Detecting any running session from the process table, read-only, regardless of which terminal launched it, is absent from the field.

**P6, organise: group, move, name.** The built-in picker defaults to the current worktree, and flow and others scope per project, so cwd-scoping is expected behaviour. Moving is rarer: flow and Agent Deck group sessions, CCM relocates on a move, but GUI drag-to-move of the session file between project folders, preserving a mark, is absent from the rest of the field. Folder-rename loses sessions is the recurring unsolved pain.

**P7, bookmark.** Rare. Chronicle's pin/tag is the only competitor with any bookmark concept.

**P8, native, no web engine, on Linux.** Rare and demanded. Chronicle, Agent Sessions, and Claude Control are macOS-native; opcode and the Tauri viewers embed a WebView; the official Desktop is Electron and macOS/Windows only, leaving Linux on the CLI. The demand is voiced ("not supported on Linux yet", and a standing dislike of Electron memory weight), against a counter-segment that wants no GUI at all.

**P9, reuse decisions and solutions.** Owned by forward memory systems (Mem0, AgentWorkingMemory, CLAUDE.md workflows, `/ce:compound`) rather than by session-history readers. searchat, flex, and claude-code-tools approach it from the agent side via MCP self-lookup.

**P10, history as a record.** Bulk regression analysis is done with one-off parsing scripts (the 6,852-session study); the did-vs-claimed audit is answered by in-session hooks (TruthGuard). No surveyed tool offers a step-by-step tool-call replay timeline in a reading pane.

**P11, token and cost analytics.** A whole cluster reads the same JSONL for spend: ccusage, Claud-ometer, cc-lens, budi, Claudest, claude-code-conversation-analyzer. Live monitoring dashboards and statusline integration are the most-built form.

**P12, export, sharing, portability.** Sparse. `/export` to Markdown exists in the core; cross-client unification (CLI, Desktop, VS Code, Web in one place) is unaddressed and open (issue #49775); cross-device sync of the `.claude` folder does not surface history in the sidebar.

**P13, branching with merge-back, autonomous handoff.** Sparse. The orchestrators (Agent Deck, Maestro, Claude Control, ccmanager, claude-squad) launch and supervise parallel worktree sessions, but merge-back of a branched thread and reliable autonomous context handoff remain unsolved.

## Cross-agent reach

Agent Sessions, searchat, and claude-history read Codex CLI and other agents' logs as well as Claude Code; most of the field is Claude Code only.
