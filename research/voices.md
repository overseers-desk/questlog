# Voices

Verbatim quotes from public discussion about living with Claude Code session history. Snapshot built May 2026, drawn chiefly from Reddit (r/ClaudeAI, r/ClaudeCode), the `anthropics/claude-code` GitHub issue tracker, Hacker News, and developer blogs. Each entry maps to a pain number from `use-case-survey.md`.

The corpus exists so feature copy speaks in words users already use. When writing about a feature, grep this file for the pain number and read the user's own language before drafting. The categories below are session-management pain points; `use-case-survey.md` defines the pain taxonomy (P1-P13) they map to.

A GitHub issue marked "closed as not planned" is noted as such: it shows Anthropic declining a need users plainly feel, which is the opening a third-party tool fills.

---

## 1. Context lost when a session compacts or ends → P1

> "I usually run my refresh-context command directly after it but sometimes I miss it and claude's quality drastically drops."
> — u/celeryattacker, r/ClaudeCode, July 2025 (score 2)
> https://old.reddit.com/r/ClaudeCode/comments/1lw5cjm/context_loss_on_claude_code_after_context/
> Context: early thread on automating context recovery after auto-compact.
> Maps to: P1

> "the thing is, most of those tool results are re-fetchable, file contents can be re-read, grep outputs can be re-run. But once `/compact` runs, they're gone from context permanently (this is when I realized that `/compact` command happens server-side, I thought it would write the JSONL logs of the compacted conversation, but NO)."
> — u/mrgoonvn, r/ClaudeCode, January 2026 (score 73)
> https://old.reddit.com/r/ClaudeCode/comments/1qcjwou/figured_out_why_compact_loses_so_much_useful/
> Context: analysis of what fills the context window and why /compact is destructive rather than recoverable. The detail that compaction is server-side and not written back to the JSONL bounds what any local reader can recover.
> Maps to: P1

> "Twenty messages in, it auto-compacts, and suddenly it's forgotten your file paths, your decisions, the numbers you spent an hour working out."
> — u/coolreddy, r/ClaudeAI, February 2026 (score 249)
> https://old.reddit.com/r/ClaudeAI/comments/1r06z4r/i_built_a_claudemd_that_solves_the/
> Context: motivation for a CLAUDE.md system that writes state to disk rather than trusting conversation memory.
> Maps to: P1

> "When a Claude Code session hits its maximum context window, the session effectively dies."
> — @eikiyo, GitHub issue #25695, February 2026
> https://github.com/anthropics/claude-code/issues/25695
> Context: feature request for auto-branch on context exhaustion, closed as "not planned".
> Maps to: P1

> "you re-explain your architecture, your decisions, your file structure. every. single. time."
> — u/Longjumping-Ship-303, r/ClaudeAI, March 2026 (score 736)
> https://old.reddit.com/r/ClaudeAI/comments/1rv5ox0/i_used_obsidian_as_a_persistent_brain_for_claude/
> Context: the stateless-session problem, as the reason for building an Obsidian-as-brain workflow.
> Maps to: P1

> "I've rebuilt context after compaction 40+ times before I fixed it. Each re-explanation averaged 20 minutes. That's over 13 hours of pure re-work."
> — Chudi Ezeani, chudi.dev, ~early 2026
> https://chudi.dev/blog/claude-context-management-dev-docs
> Context: blog post quantifying the re-orientation cost of compaction.
> Maps to: P1

> "compaction fires, and Claude suddenly has no idea what it was doing. The built-in summarizer tries its best but it treats everything equally. Your goals, your constraints, that random file listing from 40 messages ago... all get the same treatment. Sometimes it keeps the wrong stuff and drops what actually mattered."
> — u/naxmax2019, r/ClaudeCode, April 2026 (score 3)
> https://old.reddit.com/r/ClaudeCode/comments/1sbhpym/claude_bootstrap_v33_i_fixed_one_of_the_biggest/
> Context: post on a hooks-based compaction-memory system built because the built-in summariser is indiscriminate.
> Maps to: P1

---

## 2. Finding a past session, and reading it without grepping JSONL → P2

> "Your session history is still there, buried in `~/.claude/projects/`. But good luck finding anything in 1.6GB of JSONL files."
> — sinzin91, GitHub README for search-sessions, ~March 2026
> https://github.com/sinzin91/search-sessions
> Context: problem statement for a full-text session search CLI.
> Maps to: P2

> "When opening a Claude JSONL file in a text editor, you get a wall of JSON spanning thousands of lines, each line itself thousands of characters long."
> — gonewx, DEV Community, ~early 2026
> https://dev.to/gonewx/i-tested-4-tools-for-browsing-claude-code-session-history-17ie
> Context: comparison article describing the raw-file reading experience.
> Maps to: P2

> "No way to search for a conversation when I can't remember which project it was in. Switching projects to find something loses the context of whatever I was doing. This happens multiple times a week. Across the 14 project folders in my `~/.claude/projects/`, there are 72 sessions I've lost practical access to."
> — @ritik4ever, GitHub issue #49095, April 2026
> https://github.com/anthropics/claude-code/issues/49095
> Context: feature request for an all-projects view in the VS Code picker.
> Maps to: P2

> "When I needed to resume one I would either remember the UUID (lol) or grep for whatever I thought I said in that session, which also doesn't work because half the time the thing I said was something like 'ok now do the thing'."
> — u/Financial_Tailor7944, r/ClaudeAI, April 2026 (score 0)
> https://old.reddit.com/r/ClaudeAI/comments/1sz36h3/i_have_99_claude_code_sessions_and_i_kept/
> Context: an owner of 99 sessions describing the failure of grep-by-memory.
> Maps to: P2

> "This is exactly the problem I have too, except I'm still solving it by scrolling through ls -lt and hoping I hit the right one. 99 sessions is already way past the point where that works."
> — u/Puzzleheaded_Fox_859, r/ClaudeAI, April 2026 (score 1)
> https://old.reddit.com/r/ClaudeAI/comments/1sz36h3/i_have_99_claude_code_sessions_and_i_kept/
> Context: comment on the same thread.
> Maps to: P2

> "Ever lost track of a conversation from a week ago? I kept running into this - some session where I'd figured out a tricky bug or built something useful, but couldn't find it again. Claude Code stores everything locally in JSONL files, but good luck grepping through hundreds of sessions to find that one thread about your auth refactor."
> — u/joseph_yaduvanshi, r/ClaudeCode, April 2026 (score 5)
> https://old.reddit.com/r/ClaudeCode/comments/1sv3bpg/built_a_native_macos_app_to_search_and_resume_any/
> Context: intro for Chronicle, a macOS session indexer.
> Maps to: P2

> "claude code stores your sessions locally, but there is no good way to search them. i wanted to ask things like: how did we set up the docker environment for this? what session did we edit `registry.py` last and what was my reason?"
> — u/damian-delmas, r/ClaudeCode, May 2026 (score 4)
> https://old.reddit.com/r/ClaudeCode/comments/1t6et49/no_one_built_good_search_for_claude_code_sessions/
> Context: intro for flex, a SQL-backed session search tool.
> Maps to: P2

> "Something like this really should be integrated in CC, I have had the same issue several times, trying to find something I did last month."
> — u/chillebekk, r/ClaudeCode, April 2026 (score 2)
> https://old.reddit.com/r/ClaudeCode/comments/1sv3bpg/built_a_native_macos_app_to_search_and_resume_any/
> Context: comment requesting native cross-session search.
> Maps to: P2

---

## 3. Resume and fork: lost context, wrong directory, cost spikes → P3

> "Currently I work around this by: Running `find ~/.claude -name \"*.json\" -path \"*/sessions/*\"` to locate session files. Manually remembering which project each conversation belonged to."
> — anonymous reporter, GitHub issue #20687, ~December 2025
> https://github.com/anthropics/claude-code/issues/20687
> Context: workaround in a request for a global resume flag.
> Maps to: P3

> "Per #5768 (open since v1.0.80), sessions can only be resumed from the same directory where they were launched. If that directory no longer exists, the session cannot be resumed at all."
> — Jordan Dea-Mattson, GitHub issue #36937, March 2026
> https://github.com/anthropics/claude-code/issues/36937
> Context: request for a `--cwd` flag after a worktree directory is deleted; closed as duplicate.
> Maps to: P3

> "Every `--resume` causes a full cache miss on the entire conversation history. Only the system prompt (~11-14k tokens) is cached; everything else is `cache_creation` from scratch. This is a ~10-20x cost increase on the resume request."
> — u/skibidi-toaleta-2137, r/ClaudeCode, March 2026 (score 1002)
> https://old.reddit.com/r/ClaudeCode/comments/1s7mitf/psa_claude_code_has_two_cache_bugs_that_can/
> Context: reverse-engineering post documenting why resuming is expensive.
> Maps to: P3

> "ended up just starting fresh conversations instead of resuming, which sucks for context but at least the costs are predictable."
> — u/Deep_Ad1959, r/ClaudeCode, March 2026 (score 17)
> https://old.reddit.com/r/ClaudeCode/comments/1s7mitf/psa_claude_code_has_two_cache_bugs_that_can/
> Context: comment on the cache-bug thread; abandoning resume as a coping strategy.
> Maps to: P3

> "Also frankly never realized that resuming an old session would cause such a significant impact - I thought it was a way to save tokens by jumping back to a previous point. Oh how wrong I was..."
> — u/siberianmi, r/ClaudeCode, April 2026 (score 14)
> https://old.reddit.com/r/ClaudeCode/comments/1sdm0bz/new_warning_about_resuming_old_sessions/
> Context: reaction to a new warning UI about resuming stale sessions.
> Maps to: P3

> "hunting down the exact cwd just to `claude --resume` was the tedious part that pushed me to build this."
> — u/joseph_yaduvanshi, r/ClaudeCode, April 2026 (score 2)
> https://old.reddit.com/r/ClaudeCode/comments/1sv3bpg/built_a_native_macos_app_to_search_and_resume_any/
> Context: the Chronicle author naming cwd-hunting as the friction that motivated the tool.
> Maps to: P3

> "Does it pick up the working directory and resume in the same cwd, or do you have to re-orient it manually?"
> — u/mrtrly, r/ClaudeCode, April 2026 (score 1)
> https://old.reddit.com/r/ClaudeCode/comments/1sv3bpg/built_a_native_macos_app_to_search_and_resume_any/
> Context: comment asking whether cwd is restored on resume.
> Maps to: P3

> "If you've ever renamed a project folder and watched weeks of Claude Code conversations vanish... You know that sinking feeling when you type `/resume` expecting to pick up where you left off, and Claude stares back with nothing?"
> — curiouslychase, curiouslychase.com, October 2025
> https://curiouslychase.com/posts/rescuing-your-claude-conversations-when-you-rename-projects/
> Context: the path-encoding loss when a project directory is renamed.
> Maps to: P3, P6

---

## 4. Which session touched a file → P4

> "I can give Claude a file and ask why we created this file. In a few queries it can find the session that wrote that file, and read the 10 messages before it, then find a few rationale prompts that informed it."
> — u/damian-delmas, r/ClaudeCode, May 2026 (score 4)
> https://old.reddit.com/r/ClaudeCode/comments/1t6et49/no_one_built_good_search_for_claude_code_sessions/
> Context: the flex author describing file-level lookup over tool-call history.
> Maps to: P4

> "the search exposing the session index ... changes the ux from 'human goes finds context' to 'agent looks up what it did last time on the same file or symbol' at the start of a task."
> — u/Deep_Ad1959, r/ClaudeCode, April 2026 (score 1)
> https://old.reddit.com/r/ClaudeCode/comments/1sv3bpg/built_a_native_macos_app_to_search_and_resume_any/
> Context: comment framing per-file session lookup as the high-value query.
> Maps to: P4

---

## 5. Many sessions at once: which is live, which needs me → P5

> "I got tired of managing 15 terminal tabs for my Claude sessions ... constantly forgetting which session was thinking vs waiting for input."
> — u/asheshgoplani, r/ClaudeCode, December 2025 (score 315)
> https://old.reddit.com/r/ClaudeCode/comments/1pxyn37/i_got_tired_of_managing_15_terminal_tabs_for_my/
> Context: launch of Agent Deck, a tmux TUI with colour-coded session states.
> Maps to: P5

> "Currently there's no way to see which Claude Code sessions are actively running in real-time. `/resume` shows historical sessions but doesn't distinguish between sessions that are currently executing vs. idle/closed."
> — @xiaoyu-work, GitHub issue #38494, March 2026
> https://github.com/anthropics/claude-code/issues/38494
> Context: feature request for a live-session list; closed.
> Maps to: P5

> "I've been running multiple Claude Code sessions in parallel across different repos and got tired of cmd-tabbing between terminal tabs trying to figure out which one needs me and which one is still working."
> — u/svessisig, r/ClaudeCode, March 2026 (score 155)
> https://old.reddit.com/r/ClaudeCode/comments/1rzd604/i_built_a_macos_dashboard_for_managing_multiple/
> Context: launch of Claude Control, a macOS dashboard that auto-discovers running Claude processes.
> Maps to: P5

> "half the time I miss an approval prompt and one agent just sits there waiting for 20 minutes while I'm focused on another."
> — u/Deep_Ad1959, r/ClaudeCode, March 2026 (score 2)
> https://old.reddit.com/r/ClaudeCode/comments/1rzd604/i_built_a_macos_dashboard_for_managing_multiple/
> Context: comment corroborating the cost of not seeing which session needs input.
> Maps to: P5

> "Running multiple Claude Code agents in parallel is increasingly common (cloud agents, background tasks, /loop, etc.). Without a way to filter to live ones, the session list grows noisy fast and switching between active agents costs more than it should."
> — @danysirota, GitHub issue #57704, May 2026
> https://github.com/anthropics/claude-code/issues/57704
> Context: request to filter the session list to active sessions.
> Maps to: P5

---

## 6. Organising sessions: grouping by project, moving, naming → P6

> "When working on multiple projects at the same time, the Recent Sessions list in the left sidebar mixes sessions from all working directories together, sorted only by recency. It's easy to resume the wrong session and start editing in the wrong repo, or to lose track of which in-flight session belongs to which project."
> — anonymous reporter, GitHub issue #56067, ~April 2026
> https://github.com/anthropics/claude-code/issues/56067
> Context: request to group sidebar sessions by project.
> Maps to: P6

> "Currently, Claude sessions are permanently bound to the working directory where they were created. If you move project files or reorganize folders, you cannot move the session's context with them, you must start a new session in the new location and lose conversation history. This quickly creates a mess."
> — @yionis01, GitHub issue #27967, February 2026
> https://github.com/anthropics/claude-code/issues/27967
> Context: request for a `/relocate` command.
> Maps to: P6

> "It was hard to keep track of which session knew what, and I kept re-explaining the same context."
> — u/EmptyStatement, r/ClaudeCode, May 2026 (score 5)
> https://old.reddit.com/r/ClaudeCode/comments/1t8a6qv/developed_an_organizer_for_my_claude_sessions/
> Context: launch of flow, a CLI that organises sessions per task under project groups.
> Maps to: P6

> "My workaround was asking Claude to read the session jsonls itself to catch up. Worked, but felt backwards."
> — u/EmptyStatement, r/ClaudeCode, May 2026 (score 5)
> https://old.reddit.com/r/ClaudeCode/comments/1t8a6qv/developed_an_organizer_for_my_claude_sessions/
> Context: same thread; the absence of meaningful session names forces a read-the-logs workaround.
> Maps to: P6

---

## 7. Bookmarking important sessions → P7

> "The 'Past conversations' list in the official VSCode extension sidebar grows to hundreds of sessions over time, with no way to mark important ones for quick access. I currently have ~200 sessions across many project folders and have to scroll or search every time I want to revisit an in-progress investigation."
> — @bilal-ahmad-servicepath, GitHub issue #55291, May 2026
> https://github.com/anthropics/claude-code/issues/55291
> Context: feature request for star/bookmark in the VS Code sidebar; closed as duplicate.
> Maps to: P7

> "I'm investigating a tricky pricing bug across multiple sessions over several days. Each session is a long, expensive conversation with significant context. I want to bookmark three of them so I can flip between them quickly without losing my place."
> — @bilal-ahmad-servicepath, GitHub issue #55291, May 2026
> https://github.com/anthropics/claude-code/issues/55291
> Context: same issue; the multi-day investigation use case.
> Maps to: P7

No session tool surveyed offers bookmarking, and the demand surfaces only on GitHub, not in the Reddit corpus. The need is real; the verbatim base is thin.

---

## 8. Native, and on Linux → P8

> "I'm still using terminal bc it's not supported on Linux yet."
> — u/Prompt-Certs, r/ClaudeCode, April 2026 (score 95)
> https://old.reddit.com/r/ClaudeCode/comments/1sljk0t/claude_code_just_got_a_full_desktop_redesign/
> Context: the Claude Code desktop redesign with multi-session support shipped without Linux.
> Maps to: P8

> "The RAM usage of most git clients is insane. I was routinely seeing 600MB-1GB just sitting idle. That's wild for an app that's essentially displaying text diffs and a graph."
> — u/Different-Ant5687, r/ClaudeCode, April 2026 (score 10)
> https://old.reddit.com/r/ClaudeCode/comments/1sfo7qh/rgitui_a_gpuaccelerated_git_client_built_in_rust/
> Context: a native (no-Electron) developer tool, contrasted with the Electron memory tax.
> Maps to: P8

> "I just don't want a GUI, I'm happy with a TUI that I can use within tmux. I don't want to have to drag and drop to run agents side by side, I'm happy as fuck doing that in split terminal windows. I'm old man yelling at Claude (cloud)"
> — u/polynomialcheesecake, r/ClaudeCode, April 2026 (score 48)
> https://old.reddit.com/r/ClaudeCode/comments/1sljk0t/claude_code_just_got_a_full_desktop_redesign/
> Context: the counter-signal; a segment wants a terminal-native flow, not a desktop GUI of any kind.
> Maps to: P8 (counter-signal)

---

## 9. Reference a past decision; reuse a past solution → P9

These pains are real and frequent, and the community overwhelmingly answers them by writing state forward (memory systems, CLAUDE.md) rather than by reading old sessions.

> "Every morning, same ritual: open a new session, re-explain the architecture, re-explain the database schema, re-explain the decisions I made last week."
> — u/cid3as, r/ClaudeAI, March 2026 (score 3)
> https://old.reddit.com/r/ClaudeAI/comments/1rzuo7v/how_i_stopped_reexplaining_everything_to_my_ai/
> Context: the pain is decisions and facts from prior sessions, not continuing the work.
> Maps to: P9

> "I'd spent 3 sessions tuning RRF retrieval weights, landed on 0.5 BM25 / 0.3 vector / 0.2 graph, written tests, moved on. Sunday morning I open a fresh session, ask Claude Code to add a feature. Within 12 turns it proposes a different weighting scheme. With confidence. Like the previous decisions never happened."
> — u/WEEZIEDEEZIE, r/ClaudeCode, May 2026 (score 14)
> https://old.reddit.com/r/ClaudeCode/comments/1ta0d3k/i_got_tired_of_claude_codes_amnesia_so_i_built_an/
> Context: re-solving a problem settled in earlier sessions; the trigger is the agent redoing decided work.
> Maps to: P9

---

## 10. Session history as a record: prove what changed, audit what happened → P10

Going back to the session archive as evidence. The strong, high-engagement form is statistical over many sessions, closer to the cost-analytics cluster than to reading a single session.

> "6,852 Claude Code sessions, 17,871 thinking blocks analyzed, reasoning depth dropped 67%, Claude went from reading a file 6.6 times before editing it to just 2."
> — u/DangerousFlower8634, r/ClaudeCode, April 2026 (score 1915)
> https://old.reddit.com/r/ClaudeCode/comments/1shaxkt/anthropic_made_claude_67_dumber_and_didnt_tell/
> Context: parsing stored sessions to prove model regression against an earlier baseline.
> Maps to: P10

> "I got tired of Claude Code telling me 'Done! All tests pass!' when tests were never run. Or 'I updated the file' when the file is byte-for-byte identical."
> — u/sand-pyramid, r/ClaudeAI, March 2026 (score 2)
> https://old.reddit.com/r/ClaudeAI/comments/1rp3iki/i_built_truthguard_hooks_that_catch_when_claude/
> Context: the did-vs-claimed audit pain; on Reddit it is answered by in-session hooks, not by reopening a closed session.
> Maps to: P10

---

## 11. Cost, portability, and workflow gaps the field has not closed → P11, P12, P13

**Token and cost analytics.** The largest gap by tool count: many independent builders ship local dashboards over the same JSONL.

> "I've been using Claude Code a lot and wanted to understand where my tokens and money were going. Claude Code already stores everything in `~/.claude/` but there's no way to visualize it."
> — u/deshrajdry, r/ClaudeCode, February 2026 (score 45)
> https://old.reddit.com/r/ClaudeCode/comments/1re8vh7/i_built_a_local_dashboard_to_track_my_claude_code/
> Maps to: P11

> "2% of sessions eat 74% of the budget. 131 marathon sessions cost more than the other 6,859 combined."
> — u/siropkin, r/ClaudeCode, March 2026 (score 0)
> https://old.reddit.com/r/ClaudeCode/comments/1s59lkw/message_50_in_a_claude_code_session_costs_80_more/
> Maps to: P11

**Sharing and export.**

> "The problem I kept having was that a session would build up a lot of useful context, but later I would need to continue in a new chat and manually explain the whole state again."
> — u/josegpacheco, r/ClaudeAI, May 2026 (score 0)
> https://old.reddit.com/r/ClaudeAI/comments/1t8sl5d/i_made_a_small_extension_for_saving_and_resuming/
> Maps to: P12

**Cross-device portability.**

> "I've tried syncing the .claude folder with syncthing and it does sync all files, but the conversation history doesn't open in the sidebar."
> — u/pmf1111, r/ClaudeCode, May 2026 (score 1)
> https://old.reddit.com/r/ClaudeCode/comments/1t873fq/any_way_to_have_full_session_history_across/
> Maps to: P12

**Cross-client unified history.**

> "Currently, Claude Code sessions are siloed by client: Terminal CLI sessions don't appear in the Desktop app. VS Code extension sessions are separate. Web (claude.ai/code) sessions are isolated. There is no way to view all sessions from a single account in one place."
> — @case-88, GitHub issue #49775, April 2026
> https://github.com/anthropics/claude-code/issues/49775
> Maps to: P12

**Branching with merge-back.**

> "I know we have all done this, where we start working on one thing and then rabbit hole down another... What I think would be killer here is, if, as part of these memories we could side-quest from the main thread."
> — u/Shoemugscale, r/ClaudeCode, December 2025 (score 12)
> https://old.reddit.com/r/ClaudeCode/comments/1peszsg/i_built_a_memory_system_for_claude_code_now_it/
> Maps to: P13

**Autonomous context handoff.**

> "I've spent over 10 hours trying to set up a system to achieve that, asking Claude to review it, creating various hooks... I continuously kept running into either sessions ending dead, or multiple sessions spawning all at once, all trying to work on the same project."
> — u/Spooky-Shark, r/ClaudeCode, May 2026 (score 3)
> https://old.reddit.com/r/ClaudeCode/comments/1tez861/serious_question_has_anyone_figured_out_how_to/
> Maps to: P13

---

## How to add an entry

1. Identify the category. If none fits, leave the entry in the closest sibling and add a TODO at the bottom. Promote to a new section once a second entry arrives.
2. Capture verbatim where possible: double quotes plus an attribution line beginning with an em-dash (the only attribution-line em-dash exception). Reddit quotes carry the score in the attribution line.
3. If only a paraphrase is available, mark `[paraphrase]` and link the source so the next contributor can recover the verbatim text.
4. Add the date. If approximate, write `~YYYY` or `early YYYY`; do not invent precision.
5. Map to a pain number from `use-case-survey.md`. If it maps to more than one, list them.
6. Within the section, sort by date oldest-first.
