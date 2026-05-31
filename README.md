# questlog

A native Linux GUI for finding, reading, and reopening past Claude Code sessions stored under `~/.claude/projects/`. It replaces the shell aliases `cs-ls` and `cs-grep` with a session list grouped by project, a typed search that streams matches across all projects as snippets under each session, a docked viewer that segments long conversations into sections, and right-click actions that reopen a session in its original working directory.

## Typical problems it solves

The tool exists for the moments you go back to a session after it is finished, above all the returns you could not have prevented by writing notes at the time.

- You quit a session and days later realise you never acted on its result, the email unsent, the commit unmade, which was the point of running it. The finished session is the only record of what was decided.
- A figure or conclusion from a session is challenged later, and you need to go back and check its source and reasoning.
- You cannot recall which project a conversation lived in, and grep-by-memory fails because what you typed was "ok now do the thing". The pile has grown past where `ls -lt` and scrolling still work.
- You want the session that last touched a particular file, and the reasoning around the change.
- You need a past session read as a conversation, not as a wall of thousand-character JSONL lines.
- You renamed a project folder and its sessions vanished from `/resume`, or you simply want them grouped and moved without loss.
- You run several sessions across terminals and cannot tell which is working and which is waiting for you.

## Scope

A single-user desktop tool that reads the local JSONL Claude Code already writes, and nothing more. It runs natively on Linux, with no Electron and no embedded web view, which is the gap the official Desktop app leaves on Linux. It reads files on the local machine only, and Claude Code sessions only, not other agents.

Deliberately out of scope, because separate tools already serve them: exposing session history to the running agent over MCP, orchestrating parallel sessions, and unifying history across devices or across the CLI, Desktop, and web clients. questlog is a way back into a finished session, not an orchestrator.

## Window layout

The window opens as a single **session list** with a toolbar on top and a status bar at the bottom. The **reading view** appears to its right the first time a session or snippet is clicked, splitting the window in two; until then the list has the whole width and no search is running.

The **toolbar** holds a time window (24 h / 7 d / 30 d / all), a list of AND-joined search criteria with a case toggle, and a "this cwd only" filter that auto-detects whether the launch directory has a corresponding project folder. A criterion is typed: **regex** matches message content; **read** / **write** / **edit** match the file a built-in tool (Read, Write, Edit/MultiEdit/NotebookEdit) acted on, by path suffix, so a bare filename finds it in any directory and a full path matches exactly. Every **+** button opens a small dropdown that asks for the criterion's value before the row appears, so typing never drives a live search. **+ Read / + Write / + Edit** drop down the launch repo's working-tree changes (`git status`) alongside a path entry and a file chooser; **+ regex** drops down a single pattern entry. A session is shown only when it satisfies every criterion somewhere in its log.

The **session list** is one widget doing two jobs. With no criteria active it browses: every session in the time window appears as a header line grouped under its project folder, carrying the time of the first prompt, a preview of the first user message, a ● marker while the session is running, a per-session cost, and a ★ when it is bookmarked. Folders are inserted in mtime-descending order as rows arrive. When any criterion is active it becomes the result index: only matching sessions remain, each with up to three snippet rows beneath its header. A snippet is one piece of evidence (a content line for a regex criterion, a `tool_use` for read/write/edit), shown as a short window centred on the hit with the matched term in bold, and the header carries the total match count. Inserts never scroll the list out from under you while results stream in.

The **reading view** is docked on the right, revealed by the first click. A single click on a session header or a snippet renders the whole jsonl, then anchors it to the relevant line, so the view never grows or jumps as it loads. It splits a long jsonl at compaction-boundary records and at idle gaps over ten minutes, presenting each segment as a section. `Ctrl-F` opens an inline find within the session.

Right-clicking a session offers "Open in viewer", "Copy resume command", "Copy session id", "Copy session path", "Copy last assistant output", "Resume in new terminal tab", "Resume forked", "Move to...", "Reveal folder", and "Add/Remove bookmark". A session can also be moved by dragging it onto another folder heading. The terminal launcher detects `gnome-terminal` / `konsole` / `ptyxis` / `xterm` and uses the right `--tab`-style invocation.

## Design principles

**The filesystem is the source of truth.** Session logs sit on disk with mtimes the kernel maintains for free. Any picture of "what sessions exist" we keep elsewhere is older than what the filesystem already reports. The tool reads the filesystem at the moment it needs an answer, rather than holding a separate model of it that has to be kept in sync.

**Read what is needed at the moment it is needed.** The toolbar's default seven-day window covers a few thousand files. Reading each one with a line-streaming regex, stopping at the second user record, takes under a second in serial. The full corpus of ten thousand files takes two seconds. There is no work budget here that demands amortisation across launches.

**Memoise within a process, not across launches.** Once a file's row has been computed in this run it is reused for subsequent toolbar window changes. Shrinking the window filters in memory; growing it scans only the new files. The accumulated state lives for the lifetime of the GUI process and is discarded on quit. A user resuming a session in another terminal sees the change on the next launch, not via a watcher or a sync protocol. This covers the session model; the only state kept across launches is a single first-run flag under `$XDG_STATE_HOME/questlog`, recording that the welcome banner was dismissed, which holds no session data.

## Installing

See [docs/installation.md](docs/installation.md) for the Debian, Fedora, Homebrew, and single-file options.

## Running

```
./questlog                                        # launch the GUI
./questlog edited lib/scan.tcl                    # launch pre-seeded with an edited criterion
./questlog edited foo.tcl pattern "bar"           # several criteria, AND-joined
./questlog -regex "pattern"                       # prefill a single pattern criterion
./questlog --search "california michael"          # prefill the search bar (plain words, not regex)
./questlog --window 30d                            # open on a time window other than the 7d default
```

`./questlog` opens the main window immediately and streams rows in. The default seven-day window populates in under a second; switching to "all" extends incrementally with the tree growing as files are scanned. Scan progress is reported in the bottom status bar.

A leading criterion type on the command line pre-seeds the GUI with a criteria chain: arguments pair as `<type> <value>`, where type is `pattern`, `read`, `wrote`, or `edited` (the older `regex`, `write`, `edit` are accepted as aliases). `read` / `wrote` / `edited` match the recorded file path by suffix, `pattern` matches content. The GUI then behaves normally, including the time-window control, so widen the window from the default 7 d when hunting an older edit. This launches `wish` like any GUI invocation and needs an X display. The older `-regex PATTERN` flag still prefills one pattern criterion.
