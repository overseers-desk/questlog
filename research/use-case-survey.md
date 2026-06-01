# Use Case Survey: Claude Code session management, 2025-2026

Snapshot taken May 2026. Re-snapshot trigger: a major Anthropic feature release affecting local session storage, or six months elapsed.

Sources: r/ClaudeAI and r/ClaudeCode (the densest signal, full of "I built X" launch posts), the `anthropics/claude-code` issue tracker, Hacker News, developer blogs, product pages.

This file is the index for the folder. It defines the pain taxonomy: the distinct pains developers voice about living with Claude Code session history, numbered once here. `voices.md` maps each quote to a pain number, `competitive-landscape.md` records what the field supplies for each, and `status.md` records which questlog covers. The numbers are stable identifiers, not a ranking.

## The pain taxonomy

- **P1 Context loss at compaction or session end.** State the developer needs is summarised away by `/compact` or lost when a session hits its context limit.
- **P2 Finding a past session and reading it without grepping JSONL.** Locating one session among hundreds, then reading it in something other than a wall of JSON.
- **P3 Resuming and forking.** Picking a session back up (and branching from it) without hunting for its working directory, and without a surprise cost spike.
- **P4 Finding which session touched a file.** "Which conversation last edited `registry.py`, and why."
- **P5 Seeing which of many parallel sessions is live and needs input.** Across many terminals and tabs, which is thinking, which is waiting.
- **P6 Organising sessions: grouping, moving, naming.** Keeping the session list legible: grouped by project, movable when folders are reorganised, and meaningfully named.
- **P7 Bookmarking important sessions.** Marking a few sessions for quick return out of a list of hundreds.
- **P8 A native, non-Electron tool, on Linux.** A desktop tool for the platform the official Desktop app does not serve, without a web engine's memory weight.
- **P9 Reusing decisions and solutions from past sessions.** Not re-explaining the architecture every morning, and not having the agent redo a decision settled last week.
- **P10 Session history as a record: prove a regression, audit what happened.** Going back to the archive as evidence, to prove the model changed or to check what the agent actually did versus what it claimed.
- **P11 Token and cost analytics.** Understanding where tokens and money went, per session and in aggregate.
- **P12 Export, sharing, and cross-device or cross-client portability.** Carrying a session's content out, or seeing one account's sessions across CLI, Desktop, Web, and machines.
- **P13 Branching with merge-back, and autonomous context handoff.** Side-questing from a main thread and merging back, or handing context from one session to the next without manual setup.

## Demand by pain

Demand is the frequency and intensity with which the pain is voiced in the corpus. Read it with the two caveats below.

| Pain | Demand signal | Evidence (voices.md) | Field supply (competitive-landscape.md) |
|---|---|---|---|
| P1 Context loss | High; one post at score 736, another at 249 | §1 | Forward memory systems and hooks; no local reader recovers server-side compacted content |
| P2 Finding and reading | Dominant; "99 sessions and I kept losing them" | §2 | The crowded centre: most search tools |
| P3 Resume and fork | Very high; the cache-cost post scored 1,002 | §3 | Table-stakes everywhere |
| P4 Which session touched a file | Real, lighter volume | §4 | Rare; agent-side index tools, one low-traction VS Code extension |
| P5 Live status | High; three monitor launches at 155-315 | §5 | Common; many monitors, each seeing only its own sessions |
| P6 Organising | Moderate to high; folder-rename loss recurs | §6 | Rare; a few group or relocate |
| P7 Bookmarking | Moderate; GitHub-only, thin verbatim | §7 | Rare; only one competitor pins |
| P8 Native on Linux | Real on Linux; a counter-segment wants no GUI | §8 | Rare; native tools are macOS-first or embed a WebView |
| P9 Reusing decisions | Dominant memory-discussion pain | §9 | Forward memory systems own it |
| P10 History as record | Strong, high-engagement; 6,852-session post at 1,915 | §10 | Partial; cost-cluster tools for the bulk form |
| P11 Cost analytics | Largest by tool count; loud (ccusage 480-879) | §11 | A whole cluster |
| P12 Portability and sharing | Real, thin verbatim | §11 | Sparse |
| P13 Branching and handoff | Thin | §11 | Sparse |

## Two caveats on reading demand

- **The posting population is builders and bug-reporters.** Consequence-driven professional use leaves little public trace: nobody posts "I forgot to send the result" or "I had to prove where the number came from." Ranking purely by public-post frequency undercounts the pains whose moment is private.
- **The coping culture is forward, not backward.** The loud solutions push state into files (memory systems, CLAUDE.md). This both serves the reuse and reference pains (P9) and hides them, so the visible demand under-represents how often developers would look back if looking back were easy.

On P9 specifically: the community largely answers reuse and reference by writing state forward at the time, rather than by reopening old sessions, so a share of that demand is absorbed by memory tools before any backward search is attempted.

## Sources

- r/ClaudeCode, Chronicle (search + resume), https://old.reddit.com/r/ClaudeCode/comments/1sv3bpg/built_a_native_macos_app_to_search_and_resume_any/
- r/ClaudeCode, VS Code extension to find the session that touched a file, https://old.reddit.com/r/ClaudeCode/comments/1sdhf4q/never_lose_a_claude_code_conversation_again_a_vs/
- r/ClaudeAI, "I got tired of Claude Code's amnesia" (re-solving a decided problem), https://old.reddit.com/r/ClaudeCode/comments/1ta0d3k/i_got_tired_of_claude_codes_amnesia_so_i_built_an/
- r/ClaudeAI, "how I stopped re-explaining everything" (reference a past decision), https://old.reddit.com/r/ClaudeAI/comments/1rzuo7v/how_i_stopped_reexplaining_everything_to_my_ai/
- r/ClaudeCode, "I got tired of managing 15 terminal tabs" (Agent Deck, live status), https://old.reddit.com/r/ClaudeCode/comments/1pxyn37/i_got_tired_of_managing_15_terminal_tabs_for_my/
- r/ClaudeCode, "Anthropic made Claude 67% dumber" (regression baseline, 6,852 sessions), https://old.reddit.com/r/ClaudeCode/comments/1shaxkt/anthropic_made_claude_67_dumber_and_didnt_tell/
- r/ClaudeCode, port-9126 PostgreSQL session logging (regression baseline), https://old.reddit.com/r/ClaudeCode/comments/1snhyck/my_name_is_claude_opus_46_i_live_on_port_9126_i/
- r/ClaudeAI, TruthGuard (audit did-vs-claimed), https://old.reddit.com/r/ClaudeAI/comments/1rp3iki/i_built_truthguard_hooks_that_catch_when_claude/
- r/ClaudeCode, "PSA: two cache bugs" (resume cost), https://old.reddit.com/r/ClaudeCode/comments/1s7mitf/psa_claude_code_has_two_cache_bugs_that_can/
- r/ClaudeCode, "developed an organizer for my Claude sessions" (organise/move), https://old.reddit.com/r/ClaudeCode/comments/1t8a6qv/developed_an_organizer_for_my_claude_sessions/
- r/ClaudeCode, "Claude Code just got a full desktop redesign" (Linux gap), https://old.reddit.com/r/ClaudeCode/comments/1sljk0t/claude_code_just_got_a_full_desktop_redesign/
- GitHub #8701, #25130, #38494, #49095, #49775, #55291, #56067, #27967, #36937, #40981, #57704. https://github.com/anthropics/claude-code/issues/
- Claude Code docs, manage sessions, https://code.claude.com/docs/en/sessions
