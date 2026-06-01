# Naming: questlog

Snapshot taken May 2026. Records why the project is called questlog, after two prior names (`claude-session-manager`, then `find-my-session`) were retired.

## The problem the rename fixes

The prior names both made claims the tool does not deliver. "Session manager" sets the expectation that the tool launches, supervises, and orchestrates parallel sessions; `competitive-landscape.md` lists five confirmed competitors (Agent Deck, Maestro, Claude Control, ccmanager, claude-squad) that actually do that. The tool here does not. It also does not expose session history to the running agent over MCP (flex, searchat, claude-code-tools do), does not export or share sessions, does not unify history across devices or clients, and does not orchestrate parallel work. Those are voiced as real demand in `use-case-survey.md`, but each is a different product.

`find-my-session` narrowed the claim to retrieval but missed the rest of what the tool does in practice: reading a past session in a segmented viewer, and accounting for what each session cost in tokens. Retrieval is one verb among several.

## What the tool does

In brief: it browses past sessions grouped by project, searches across them by content or by which files the agent read, wrote, or edited, reads a selected session in a docked viewer that segments long transcripts by compaction boundary and idle gap, shows per-session token cost as a column, resumes or forks a session in a new terminal tab, and bookmarks or moves a session between project folders. `status.md` is the authoritative list of what the tool does and where in the code.

The unifying frame is the past session: finding, reading, costing, and resuming work that is already on disk.

## Why questlog

In role-playing games, the quest log is the in-game screen that lists active, in-progress, and completed quests, each with its objective, its rewards, and its cost in time or supplies, and lets the player resume one. The mapping is direct: a session is a quest, the per-session cost column is the quest's cost, the resume command is "pick up the quest", and the list itself is the screen the player opens when they cannot remember what they were doing.

The name says what the tool is without claiming management it lacks.

## What user request led here

The rename followed a single observation: that the prior naming was overclaiming, and that a recent feature commit (per-session token cost column, `e302f44`) had been read as positioning intent rather than as a quiet expansion of scope. The user named the pattern as the tool inheriting a name from "session manager" while not having full session-manager functions, and asked for a name that honestly covers the actual scope. The chosen name resolves that mismatch.
