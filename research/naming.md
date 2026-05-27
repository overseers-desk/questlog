# Naming: questlog

Snapshot taken May 2026. Records why the project is called questlog, after two prior names (`claude-session-manager`, then `find-my-session`) were retired.

## The problem the rename fixes

The prior names both made claims the tool does not deliver. "Session manager" sets the expectation that the tool launches, supervises, and orchestrates parallel sessions; `competitive-landscape.md` lists five confirmed competitors (Agent Deck, Maestro, Claude Control, ccmanager, claude-squad) that actually do that. The tool here does not. It also does not expose session history to the running agent over MCP (flex, searchat, claude-code-tools do), does not export or share sessions, does not unify history across devices or clients, and does not orchestrate parallel work. Those are voiced as real demand in `use-case-survey.md`, but each is a different product.

`find-my-session` narrowed the claim to retrieval but missed the rest of what the tool actually does in practice: read a past session in a segmented viewer, account for what each session cost in tokens, defend a conclusion against challenge by going back to its source. Retrieval is one verb among several.

## What the tool actually does

Browse past sessions grouped by project. Search across them by content or by which files the agent read, wrote, or edited. Read a selected session in a docked viewer that segments long transcripts by compaction boundary and idle gap. See per-session token cost as a column. Resume or fork a session in a new terminal tab. Bookmark or move a session between project folders.

The unifying frame is backward-looking: the user returns to a session that is already finished, with a need that was not foreseeable when the session ended (`use-case-survey.md` thesis). The tool is the way back in.

## Why questlog

In role-playing games, the quest log is the in-game screen that lists active, in-progress, and completed quests, each with its objective, its rewards, and its cost in time or supplies, and lets the player resume one. The mapping is direct: a session is a quest, the per-session cost column is the quest's cost, the resume command is "pick up the quest", and the list itself is the screen the player opens when they cannot remember what they were doing.

The name says what the tool is without claiming management it lacks.

## What user request led here

The rename followed a single observation: that the prior naming was overclaiming, and that a recent feature commit (per-session token cost column, `e302f44`) had been read as positioning intent rather than as a quiet expansion of scope. The user named the pattern as the tool inheriting a name from "session manager" while not having full session-manager functions, and asked for a name that honestly covers the actual scope. The chosen name resolves that mismatch.
