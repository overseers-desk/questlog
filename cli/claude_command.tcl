package require Tcl 9

# Install and keep current the questlog command for Claude Code.
#
# This writes a Claude Code *command* (~/.claude/commands/questlog.md), not a
# skill: a user's skills directory is often a curated, version-controlled tree,
# and a tool writing into it would pollute that repository, whereas the commands
# directory is the conventional home for a tool to register itself. COMMAND below
# is the single source of the file's content. Every launch keeps the installed
# file equal to it: when the file is missing or differs, it is rewritten.
# "Current" means byte-for-byte equal to COMMAND, so there is no version stamp to
# maintain and no per-release judgement about whether the command changed. A
# same-named skill, if the user keeps one, supersedes the command and the refresh
# leaves it alone.
#
# Registering the command has nothing to do with the session store under
# ~/.claude/projects that lib/path.tcl guards, so the launcher sources this file
# and runs refresh/install before path.tcl renames `file`; the native command is
# used directly here.

namespace eval ::questlog::claude {
    variable COMMAND
}

# The command body and the single source of its content. The frontmatter
# description is written to make a Claude Code session reach for questlog at the
# right moment (the user asking about an earlier or finished session); how to
# drive the CLI is the body, not the description.
set ::questlog::claude::COMMAND {---
name: questlog
description: When the user is reaching back to a finished Claude Code session: to find which earlier conversation it was, recall what it said or decided, or see what past sessions cost. Not the session in progress.
allowed-tools: Bash
---

# questlog

questlog searches, reads, and totals the user's finished Claude Code sessions (the JSONL transcripts under ~/.claude/projects) through the questlog CLI. Each run takes one query and prints to stdout, so drive it from Bash.

## Searching

```bash
questlog --json --since 7d --keyword "stripe webhook" | jq '[.[].sessions[] | {uuid, title, path, first_ts, cost_usd, turns}]'
```

A session is returned when its clauses hold somewhere in its log. Clauses combine by one algebra: adjacency is AND, `--or` is OR, `--not` negates the next clause, with precedence NOT, then AND, then OR. There is no grouping, so write `A AND (B OR C)` as `A B --or A C`. The clause kinds:

- `--keyword <text>` is a literal needle; `--regex <re>` is a pattern. Either takes an optional `:regions` suffix to confine the match, e.g. `--keyword:user`, `--regex:assistant,tool-use`, where a region is one of user, assistant, tool-use, tool-result, any.
- `--tool:read|write|edit|file <path>` finds a session that read, wrote, edited, or touched a file, matched by path suffix, so a bare filename finds it in any directory.
- `--tool:<name> <key>` finds a session that used a tool (Bash, Grep, ...) whose invocation contains the key, and an empty key means any use.

Bound the whole result with `--since <24h|7d|2w|2026-04-01|all>`, `--until <...>`, `--subtree <dir>` (sessions in the subtree of `<dir>`: the directory itself and everything below it), or `--limit <N>`. Use the words from the user's own request (a topic, a filename, a tool name), and reach for `--regex` only when a literal keyword will not do. The full clause and bound inventory is in `questlog --help`.

The output is an array of project folders, each with its `sessions`, and each session its `subagents`. A folder carries `project_path` (the session's original directory); a session carries `uuid`, `path`, `title`, `first_ts`, `cost_usd`, `turns`, and the matched `matches` snippets. Slice it with `jq`; the `uuid` or `path` feeds the next step.

## Reading a session

```bash
questlog show <uuid|session.jsonl>
```

Prints a finished session as a readable transcript, each turn anchored by its record number so a conclusion can be quoted and cited. The argument is a `uuid` from a prior `--json` hit, or a path. This is how to recall what was said or decided in an earlier session, rather than reading the raw JSONL.

## Totalling cost and usage

```bash
questlog --shortstat --since 7d
```

Emits session and subagent counts, turns, token categories, and total cost over the same result set the matching `--json` query would return. Cost is the recorded tokens priced at per-model API rates, an API-equivalent figure rather than a number the harness billed. Add `--accrued-cost` (with a time bound) to count only the spend dated inside the window instead of each matching session's whole-transcript cost.

## Reopening and renaming

To reopen a found session, give the user the resume command `cd <project_path> && claude --resume <uuid>`, where `project_path` is the folder field and `uuid` the session field from a `--json` hit; append `--fork-session` to branch instead of continue. `questlog rename <session.jsonl> [title]` sets a session's title, and an empty or omitted title reverts it to the auto title.
}

# ~/.claude, or "" when HOME is unknown.
proc ::questlog::claude::claude_dir {} {
    if {[catch {file home} home] || $home eq ""} { return "" }
    return [file join $home .claude]
}

proc ::questlog::claude::command_file {} {
    return [file join [claude_dir] commands questlog.md]
}

# A same-named skill, if the user keeps one, supersedes the command.
proc ::questlog::claude::skill_dir {} {
    return [file join [claude_dir] skills questlog]
}

# True when Claude Code is absent (no ~/.claude), or a same-named skill
# supersedes the command.
proc ::questlog::claude::superseded {} {
    set base [claude_dir]
    return [expr {$base eq "" || ![file isdirectory $base]
        || [file isdirectory [skill_dir]]}]
}

proc ::questlog::claude::_write {path text} {
    set dir [file dirname $path]
    if {![file isdirectory $dir]} { file mkdir $dir }
    set fh [open $path w]
    chan configure $fh -encoding utf-8
    puts -nonewline $fh $text
    close $fh
}

proc ::questlog::claude::_read {path} {
    set fh [open $path r]
    chan configure $fh -encoding utf-8
    set text [read $fh]
    close $fh
    return $text
}

# Keep ~/.claude/commands/questlog.md equal to COMMAND. Silent, idempotent, and
# best-effort: a missing Claude Code install or a same-named skill is left alone,
# and a write failure (read-only home, etc.) does not disturb the launch.
proc ::questlog::claude::refresh {} {
    if {[superseded]} return
    set f [command_file]
    if {[file isfile $f] && [_read $f] eq $::questlog::claude::COMMAND} return
    catch {_write $f $::questlog::claude::COMMAND}
    return
}

# The `install-claude-command` subcommand: the same write, done explicitly and
# with a printed result.
proc ::questlog::claude::install {} {
    if {[superseded]} {
        puts "Skipped: Claude Code is not installed (no ~/.claude), or a\
            same-named skill supersedes the command."
        return
    }
    set f [command_file]
    if {[catch {_write $f $::questlog::claude::COMMAND} err]} {
        puts stderr "questlog: could not write $f: $err"
        exit 1
    }
    puts "Installed: $f"
    return
}
