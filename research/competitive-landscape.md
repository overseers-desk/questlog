# Competitive Landscape: Claude Code session tools

Snapshot taken May 2026. Survey scope: CLI baselines, TUI browsers, web and native desktop viewers, search indexers, multi-session orchestrators, and cost dashboards that read `~/.claude/projects/*/*.jsonl`. The field is crowded and young: most entries are 2025-2026 launch posts on r/ClaudeCode and GitHub.

Capabilities for the community tools are as their authors describe them in launch posts and READMEs, not independently re-verified; cells that could not be confirmed read "unconfirmed". Star counts and last-active dates are approximate and omitted where unknown. USP numbers cross-reference `usp-ranking.md`.

## Feature matrix

Cells: Yes / No / Partial / unconfirmed, with a short note.

| Tool | Platform / UI | Cross-session search (#9) | Tool-use path search (#1) | Resume / fork (#3) | Bookmark (#4) | Live status (#8) | Compaction + idle segmentation (#6) | Move / organise (#10) |
|---|---|---|---|---|---|---|---|---|
| **csm** (SmartLayer) | Tcl/Tk native Linux GUI | Yes (regex, streaming snippets) | Yes (Read/Write/Edit filter + git-status picker) | Yes (resume, fork, new tab) | Yes (`u+x` bit, no DB) | Yes (process-table, any terminal) | Yes (compaction boundary + 10-min idle) | Yes (move / drag between folders) |
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

Tool links: SmartLayer/claude-session-manager; code.claude.com/docs/en/sessions (CLI) and /desktop; github.com/JosephYaduvanshi/claude-history-manager (Chronicle); jazzyalex.github.io/agent-sessions; github.com/asheshgoplani/agent-deck; github.com/sverrirsig/claude-control; github.com/damiandelmas/flex; github.com/Process-Point-Technologies-Corporation/searchat; github.com/pchalasani/claude-code-tools; github.com/raine/claude-history; github.com/d-kimuson/claude-code-viewer; github.com/winfunc/opcode; github.com/kbwo/ccmanager; github.com/smtg-ai/claude-squad; github.com/sinzin91/search-sessions; github.com/daaain/claude-code-log; github.com/dr5hn/ccm; github.com/ryoppippi/ccusage.

## Per-USP differentiation verdict

**USP #1, tool-use path search. Rare.** flex queries file edits and tool calls over a SQL index, and searchat plus claude-code-tools expose session history to the agent via MCP for the "what did I do to this file last time" lookup. Those answer the same question from the agent side. A VS Code extension (nypaavsalt) does surface "find the past conversation that edited this file" directly in a human UI, the closest analog to csm's filter, but at negligible traction (single-digit score). csm is the only one keyed to a git-status picker (see USP #2), which turns the query from typing a path into clicking a changed file.

**USP #2, git-status file picker in search criteria. Unique.** No tool turns the current repo's `git status` into selectable session-search criteria. This is the part of the file-level search story that no competitor touches.

**USP #3, resume and fork. Common.** Table-stakes: the built-in CLI, Chronicle, claude-history, Agent Deck, opcode, search-sessions and others resume; fork exists in the CLI (`--fork-session`, `/branch`), claude-history, and Agent Deck. Chronicle additionally restores the working directory, the specific friction users name. csm's three modes in one right-click menu is convenience, not a capability gap.

**USP #4, bookmark via `u+x` permission bit. Rare; mechanism unique.** Chronicle offers pin/tag, the only competitor with any bookmark concept. The permission-bit encoding (no sidecar, scriptable, survives a move and a copy to another machine) is csm's alone.

**USP #5, hit-centred streaming snippets with non-scrolling insert. Rare.** Many tools show results; the no-autoscroll anchor as hits stream in is documented only in csm.

**USP #6, viewer segmenting by compaction boundary and 10-min idle gap. Rare.** claude-compaction-viewer surfaces compaction boundaries in a TUI; opcode shows a timeline that is not compaction-aware. No other tool segments a session into readable chapters by both signals inside a reading pane. Note the ceiling: `/compact` runs server-side and is not written back to the JSONL, so a local reader segments around boundaries rather than recovering compacted content.

**USP #7, "this cwd only" auto-detection. Common.** The built-in picker defaults to the current worktree; flow and others scope per project. Expected behaviour.

**USP #8, live status of running sessions. Common feature, distinct angle.** Live status is now one of the most-built features: Agent Deck, Claude Control, Maestro, ccmanager, claude-squad, the d-kimuson viewer, and the Desktop sidebar all show it. In every case "live" means a session that tool launched or supervises. csm detects live processes from the process table, so it sees sessions started in any terminal, read-only, on Linux. That angle is unduplicated.

**USP #9, cross-session full-text search. Common.** The crowded centre of the field: Chronicle, Agent Sessions, claude-history, search-sessions, flex, searchat, claude-code-tools, opcode, claude-code-viewer all search across sessions. Regex specifically is less universal (many use fuzzy, FTS, or semantic), but the capability is table-stakes.

**USP #10, move / drag between project folders. Rare.** flow and Agent Deck group sessions; CCM relocates on a move. Actual GUI drag-to-move of the session file between project folders, preserving the bookmark, is csm's. Reframing-on-move is the recurring unsolved pain (folder rename loses sessions).

**USP #11, coroutine responsiveness. Implementation detail.** No tool markets its concurrency model.

**USP #12, native Tk, no Electron, no web view. Rare and demanded.** Chronicle, Agent Sessions, and Claude Control are macOS-native; opcode and the Tauri viewers embed a WebView; the official Desktop is Electron and macOS/Windows only, leaving Linux on the CLI. csm is the only first-class Linux native desktop tool in the survey with no web engine. The demand is voiced ("not supported on Linux yet", and a standing dislike of Electron memory weight), against a counter-segment that wants no GUI at all.

## Top moats

1. **GUI tool-use path search with the git-status picker (USP #1 + #2).** The file-level "which session touched X" query is now contested from the agent side by flex and searchat, but the human-GUI form, and the git-status picker that makes it a click, are csm's alone.
2. **Native Linux desktop (USP #12) with read-only, any-terminal live detection (USP #8).** Native GUIs here are macOS-first; live monitors only see sessions they launched. csm is the only tool that is both native on Linux and able to see any running session by process inspection.
3. **Move / drag-to-move (USP #10) with bookmark-as-`u+x` (USP #4).** Organising the session tree, with a bookmark that survives the move, against the loud folder-rename-loses-sessions pain that no competitor and not the core address.

## Top table-stakes

1. **Cross-session search (USP #9):** the crowded centre of the field.
2. **Resume / fork (USP #3):** every serious tool has it.
3. **Live status (USP #8) as a feature:** common, though csm's read-only any-terminal angle is not.

## Features competitors have that csm lacks

- **Token / cost analytics.** A whole cluster reads the same JSONL for spend: ccusage, Claud-ometer, cc-lens, budi, Claudest, claude-code-conversation-analyzer. csm shows no cost.
- **MCP-surfaced session history for the agent itself.** flex, searchat, and claude-code-tools let the running agent query its own past sessions mid-task. csm is a human-facing GUI, not an MCP server.
- **Cross-agent support.** Agent Sessions, searchat, and claude-history read Codex CLI and other agents' logs; csm is Claude Code only.
- **Multi-session orchestration.** Agent Deck, Maestro, Claude Control, ccmanager, claude-squad launch and supervise parallel worktree sessions; csm is a passive browser and launcher.
- **Windows and macOS desktop, and mobile/remote.** csm is Linux desktop only.
- **Semantic search, checkpoints, diffs.** claude-history (semantic), opcode (checkpoint restore, diffs) have these; csm does not.
- **In-place session rename.** The built-in picker renames; csm does not.

## What no competitor positions around

The field competes on mechanics: search, resume, live status, cost. None positions around why a developer returns to a finished session, and none separates the returns that forward state-keeping cannot prevent (closing a loop, defending a conclusion) from the forward-preventable ones that memory systems already serve. That framing is unclaimed.
