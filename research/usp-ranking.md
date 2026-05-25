# USP Ranking

USP list synthesised from `voices.md`, `competitive-landscape.md`, and `use-case-survey.md`. Snapshot May 2026.

The ranking sorts by demand (how often users voice the underlying pain) multiplied by differentiation (how rare the supply is among Claude Code session tools). One interpretive lens runs through it: a feature is most defensible when it serves a reason to return to a finished session that the user could not have prevented by writing state forward. The ecosystem already solves the forward-preventable returns with memory systems; csm's least-substitutable value is the backward ones.

## The 12 USPs

1. **Tool-use path search.** Filter sessions by which file was Read, Written, or Edited, keyed to `tool_use` records; a bare filename matches any directory. (`lib/jsonl.tcl`, `lib/search.tcl`)
2. **Git-status file picker in search criteria.** The "+ Read / + Write / + Edit" dropdowns populate from `git status` of the launch repo, so a recently-changed file is picked rather than typed. (`ui/toolbar.tcl`)
3. **One-click resume, resume-forked, resume-in-new-terminal-tab.** Resume, `--fork-session` branching, and launching into a fresh terminal tab from the right-click menu, in the session's original working directory. (`lib/terminal.tcl`)
4. **Bookmark as the file's `u+x` permission bit.** No sidecar, no database; the bookmark survives moves and is visible to `ls -l` and `find -perm`. (`lib/path.tcl`)
5. **Hit-centred streaming snippets with non-scrolling insert.** Up to three context-windowed snippets per session, match in bold; new rows insert above the viewport without moving the user's position. (`ui/sessions.tcl`)
6. **Docked session viewer with segmentation.** Renders the JSONL as formatted turns split at `compact_boundary` records and 10-minute idle gaps into labelled sections, anchored to the matched line. (`ui/viewer.tcl`)
7. **"This cwd only" auto-detection.** If the launch directory maps to a project folder, the filter pre-enables, scoping the list to the current repo. (`ui/toolbar.tcl`)
8. **"Running only" live-process filter and indicator.** Detects live Claude Code processes from the process table (validated against `/proc`), so it sees sessions launched from any terminal, not only its own. (`lib/live.tcl`)
9. **Cross-session full-text regex search.** Streams matches across all projects, replacing manual grep/jq over `~/.claude/projects/`. (`lib/search.tcl`, `lib/scan.tcl`)
10. **Move and drag-to-move sessions between project folders.** Renames the JSONL into the target folder, preserving the bookmark bit. (`lib/path.tcl`, `ui/move_dialog.tcl`, `ui/drag.tcl`)
11. **Coroutine-driven responsiveness.** Scanner and searcher yield to the Tk event loop; no threads by default, O(1) cancellation. (`lib/scan.tcl`)
12. **Native Linux Tk GUI.** No Electron, no embedded web view; the only first-class Linux native desktop tool in the survey with zero web-engine dependency. (`csm` entry script)

## Ranked by demand-times-differentiation

| Rank | USP | Demand | Differentiation | Tier |
|---|---|---|---|---|
| 1 | #9 + #1 + #6 backward-return core | The returns nothing else serves: close a loop, defend a conclusion | #9 common; file-level #1 contested only by a low-traction VS Code extension; the segmented reading pane #6 rare | Headline moat |
| 2 | #8 live status, read-only, any terminal | High. Three top-scoring launch posts are session monitors | Feature common; detecting any-terminal sessions read-only on Linux is unduplicated | Headline moat (the angle) |
| 3 | #2 git-status file picker | Low as voiced; the lever that makes #1 a click | Unique | Quiet moat (powers #1) |
| 4 | #10 move / drag-to-move | High. Folder-rename loses sessions, recurring and unfixed | Rare. flow groups, CCM relocates by CLI; GUI drag preserving the bookmark is csm's | Strong differentiator (incident-driven) |
| 5 | #3 resume / fork | Very high. Every tool covers it | Common. csm's three-mode right-click is convenience | Must-have, not a differentiator |
| 6 | #12 native Linux, no Electron | Real on Linux, where the official Desktop does not run | Rare. Competitors are macOS-first or embed a WebView | Positioning angle |
| 7 | #4 bookmark as `u+x` | Moderate (#55291); thin verbatim base | Mechanism unique; only Chronicle has any pin/tag | Distinctive, niche |
| 8 | #7 "this cwd only" | Moderate. Both per-repo and cross-project scope wanted | Common. Category default | Table-stakes |
| 9 | #5 streaming snippets, non-scrolling | Low. Voiced as "search is slow", not as this feature | Rare | Silent quality |
| 10 | #11 coroutine responsiveness | None voiced | Implementation detail | Contributor-facing |

## Reading of the ranking

The defensible centre is not the search box; it is the kind of return the search box enables. Developers go back to a finished session for seven reasons, and the ecosystem has already absorbed five of them. Continuing interrupted work, looking up a past decision, and reusing a past solution are all forward-preventable, and the community solves them by writing state into files at the time, with memory systems and CLAUDE.md, not by searching old sessions. Contesting that ground means competing with a dozen memory tools on their terms.

Two returns cannot be prevented that way, because the need is unknowable when the session ends. You do not write a note to find the session later when you do not yet know you forgot to send the result, and you do not preserve a citation trail against a challenge you do not yet know is coming. When those needs arrive, the finished session is the only record. Serving them is a trio: cross-session search to find the session (#9), the file-level filter and git-status picker to land on the one that touched the work (#1, #2), and the segmented reading pane to read its reasoning and the sources it used (#6). That trio is csm's least-substitutable value, and it is the quietest in the public record, because closing a loop and defending a conclusion are private, consequence-driven moments that rarely become posts.

Two more strengths stand on their own. Live status is one of the most-built features of the year, and where every other monitor sees only the sessions it launched, csm detects any running session from the process table, read-only, on Linux. And the folder-rename-loses-sessions pain, sharp and unfixed in the core, is answered directly by move and drag-to-move, with the bookmark surviving the move.

One differentiator is latent. The native Linux build with no web engine serves an audience the official Desktop app leaves on the CLI, and the README does not yet say so. A counter-segment wants no GUI at all and lives in tmux; the Linux-native pitch is aimed past them.

## Confirmed gaps

In rough priority for positioning impact and feasibility.

1. **Token / cost analytics per session.** The largest gap by tool count: a whole cluster (ccusage, Claud-ometer, budi, cc-lens) reads the same JSONL csm reads. The data is in hand; scope is the maintainer's call.
2. **MCP-surfaced session history for the agent itself.** flex and searchat let the running agent recall its own past work mid-task. Matching it means csm shipping an MCP server over the index it already builds, a different architecture from a human GUI.
3. **Session export and sharing.** `/export` to Markdown exists in the core; a structured share is a feasible extension of the viewer (`ui/viewer.tcl`).
4. **Chronological tool-call audit timeline within a session.** csm partially serves the did-vs-claimed audit through tool-use path search (#1) and segmentation (#6) but shows no step-by-step replay.
5. **In-place session rename.** Auto-generated titles are unhelpful; the built-in picker already renames. Low cost.
6. **Cross-device and cross-client unification.** Real demand but out of architectural reach: csm reads local JSONL and cannot see server-held Desktop or Web sessions.
7. **Bulk regression analytics.** Proving the model changed against a baseline reaches back into stored sessions, but in a statistical-over-many-sessions form closer to the cost-analytics cluster than to csm's single-session browse.
