# Use Case Survey: Claude Code session history in 2025-2026

Snapshot taken May 2026. Re-snapshot trigger: a major Anthropic feature release affecting local session storage, or six months elapsed.

Sources: r/ClaudeAI and r/ClaudeCode (the densest signal, full of "I built X" launch posts), the `anthropics/claude-code` issue tracker, Hacker News, developer blogs, product pages. USP numbers cross-reference `usp-ranking.md`.

The organizing question of this survey is not "what features do session tools have" but **why a developer goes back to a session that is already finished.** That question separates the work questlog is uniquely needed for from the work the ecosystem already handles another way.

## Why you return to a finished session

Seven distinct motivations appear in the evidence. The decisive axis is not how loudly each is voiced but whether it is **forward-preventable**: could the developer have avoided the return by writing state to a file at the time. The motivations that are forward-preventable are already owned by the community's memory-system culture. The ones that are not are where a backward-looking reader of the session archive is the only answer.

| Why you return | How often voiced | Forward-preventable? | questlog fit |
|---|---|---|---|
| Continue interrupted work | Dominant | Yes (handoff docs, CLAUDE.md, memory MCPs) | #3, #9 |
| Reference a decision or fact | Dominant memory-discussion pain | Yes (memory systems persist the decision) | #9, #6 |
| Reuse a past solution | Real (~3-5 posts) | Yes (write-on-solve at the moment of the fix) | #9 |
| **Close a loop you left open** (forgot to send the result, commit, file the report) | Real (~5-8 posts), tools built | **No**: the need was unforeseeable at session time | #9 find, #3 resume |
| **Defend a conclusion that was challenged** (go back to verify the source) | First-party; publicly near-silent | **No**: you could not know it would be challenged | #1, #6 |
| Prove the model regressed against a baseline | Strong, high-score | Partly (some log every session forward) | #9, #6 (but bulk-analytical) |
| Audit what the agent did versus claimed | Real pain | Mostly forward (in-session hooks) | #1, #6 (partial) |

The forward-preventable rows are settled territory. Every high-engagement thread on continuity, reference, and reuse resolves to the same answer: capture state at the moment, so a future session never has to look back. `/ce:compound`, CLAUDE.md, AgentWorkingMemory, Mem0, and a dozen others exist for this, and direct session-history search has negligible traction as the advocated fix. questlog does not win by fighting on this ground.

The two rows marked "No" are different in kind. You cannot write a note at session time against a need you do not yet have. You did not know, when you finished the analysis, that you would forget to send it, or that a client would challenge the figure in a meeting three days later. When that need arrives, the only artefact is the finished session, and the only move is to go back into it. This is the ground questlog holds alone, and it is the ground the public corpus shows least, because the moment is private and consequence-driven rather than a thing people post about.

### First-party owner cases

Two motivations are documented from the project owner's own use rather than from public posts. They are marked n=1 and kept out of `voices.md` (a public-quote corpus); they carry weight as the lived experience of the tool's primary user, not as measured market demand.

- **Close a loop.** An analysis was run over an hour of work. Days later, after the session was quit, the owner realised the result was never sent by email, which was the entire point of running it. The session had to be found again to issue the final instruction or to write the message. This is the single most frequent personal use of the tool.
- **Defend a conclusion.** A conclusion reached in a session was later challenged in the real world. The owner returned to the session to verify the source and reasoning behind the figure, in order to defend or correct it.

Both are irreducibly backward: neither could have been pre-empted by forward state-keeping, because the trigger was unknowable at session time.

## What the field builds (the mechanics in demand)

The tooling people actually ship clusters around a few mechanics; the detail and per-tool capabilities live in `competitive-landscape.md`.

- **Cross-session search** is the most-built feature (Chronicle, flex, search-sessions, claude-history, searchat).
- **Live monitoring of parallel sessions** is among the highest-scoring launch posts (Agent Deck, Claude Control, Maestro): which of fifteen tabs is running, which waits for input.
- **Resume**, with the working directory restored, is table-stakes and the named friction.
- **Token/cost analytics** over the same JSONL is a whole cluster (ccusage, Claud-ometer, budi, cc-lens).
- **MCP-surfaced history for the agent itself** (flex, searchat) lets the running agent recall its own past work, a category questlog does not occupy.

## What public forums can and cannot show

Two structural biases shape this corpus and are stated here so the rankings are read correctly.

- **The posting population is builders and bug-reporters.** Consequence-driven professional returns (close a loop, defend a conclusion) leave almost no public trace: nobody posts "I forgot to send the email" or "I had to prove where Claude got that number." Ranking purely by public-post frequency therefore undervalues exactly the returns that forward hygiene cannot prevent.
- **The coping culture is forward, not backward.** The loud, high-volume solutions push state into files. This both pre-empts the forward-preventable returns and hides them, which means the visible demand under-represents how often people would look backward if looking backward were easy.

## Verdict on the 12 USPs

**Broad demand, multiple independent sources:**

- USP #9 (cross-session search): the most-built feature in the field.
- USP #8 (live status of running sessions): three of the highest-scoring launch posts are monitors; questlog's read-only any-terminal detection is the distinct form.
- USP #3 (resume / fork): confirmed everywhere; cwd restoration is the named friction.

**High value, low public volume (the backward core):**

- USP #1 (tool-use file-path search) plus USP #6 (the segmented reading pane): together these serve the two irreducibly-backward returns, finding the session that touched a file and reading its reasoning and sources. A direct file-touch competitor exists (a VS Code extension) but at negligible traction.

**Niche but real:**

- USP #10 (move / drag between folders) and USP #7 (per-repo scope): organising the tree; folder-rename loss is the sharp edge.
- USP #4 (bookmark): real need (#55291), thin verbatim base; only Chronicle offers any bookmark, and the `u+x` storage is implementation, not the competitive point.
- USP #12 (native Linux, no Electron): real on Linux where the official Desktop does not run.

**Solves a problem few ask about explicitly:**

- USP #5 (streaming snippets) and USP #11 (coroutine responsiveness): quality and implementation, not voiced as feature requests.

**Gap versus demand:**

- Token/cost analytics, MCP-surfaced history for the agent, session export/sharing, cross-device and cross-client unification: all voiced, none in questlog.

## Bottom line

questlog is strongest, and least substitutable, on the returns that cannot be prevented by writing state forward: closing a loop you did not know you had left open, and defending a conclusion you did not know would be challenged. The ecosystem has converged on forward memory systems for continuity, reference, and reuse, so questlog should not contest that ground; it should own the backward-looking returns, where the finished session is the only record and a fast way back into it is the whole value. The most-built things questlog does not do (cost analytics, MCP history for the agent, parallel-session orchestration) are real demand but a different product.

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
- GitHub #8701, #25130, #38494, #49095, #49775, #55291, #56067, #27967, #36937, #40981. https://github.com/anthropics/claude-code/issues/
- Claude Code docs, manage sessions, https://code.claude.com/docs/en/sessions
