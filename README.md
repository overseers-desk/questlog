# Claude Session Manager

A GUI for finding, reading, and reopening past Claude Code sessions stored under `~/.claude/projects/`. It replaces the shell aliases `cs-ls` and `cs-grep` with a session list grouped by project, a typed search that streams matches across all projects as snippets under each session, a docked viewer that segments long conversations into sections, and right-click actions that reopen a session in its original working directory.

## Why a session manager

- A bug surfaces after the session that wrote it is gone.
- You remember a session by when, not by what.
- You need a fact from a past session, not to resume it.
- Fork an old session without disturbing the original.

## Window layout

The window opens as a single **session list** with a toolbar on top and a status bar at the bottom. The **reading view** appears to its right the first time a session or snippet is clicked, splitting the window in two; until then the list has the whole width and no search is running.

The **toolbar** holds a time window (24 h / 7 d / 30 d / all), a list of AND-joined search criteria with a case toggle, and a "this cwd only" filter that auto-detects whether the launch directory has a corresponding project folder. A criterion is typed: **regex** matches message content; **read** / **write** / **edit** match the file a built-in tool (Read, Write, Edit/MultiEdit/NotebookEdit) acted on, by path suffix, so a bare filename finds it in any directory and a full path matches exactly. Every **+** button opens a small dropdown that asks for the criterion's value before the row appears, so typing never drives a live search. **+ Read / + Write / + Edit** drop down the launch repo's working-tree changes (`git status`) alongside a path entry and a file chooser; **+ regex** drops down a single pattern entry. A session is shown only when it satisfies every criterion somewhere in its log.

The **session list** is one widget doing two jobs. With no criteria active it browses: every session in the time window appears as a header line grouped under its project folder, carrying the time of the first prompt, a preview of the first user message, a ● marker while the session is running, and a ★ when it is bookmarked. Folders are inserted in mtime-descending order as rows arrive. When any criterion is active it becomes the result index: only matching sessions remain, each with up to three snippet rows beneath its header. A snippet is one piece of evidence (a content line for a regex criterion, a `tool_use` for read/write/edit), shown as a short window centred on the hit with the matched term in bold, and the header carries the total match count. Inserts never scroll the list out from under you while results stream in.

The **reading view** is docked on the right, revealed by the first click. A single click on a session header or a snippet renders the whole jsonl, then anchors it to the relevant line, so the view never grows or jumps as it loads. It splits a long jsonl at compaction-boundary records and at idle gaps over ten minutes, presenting each segment as a section. `Ctrl-F` opens an inline find within the session.

Right-clicking a session offers "Open in viewer", "Copy resume command", "Copy session id", "Copy session path", "Copy last assistant output", "Resume in new terminal tab", "Resume forked", "Move to...", "Reveal folder", and "Add/Remove bookmark". A session can also be moved by dragging it onto another folder heading. The terminal launcher detects `gnome-terminal` / `konsole` / `ptyxis` / `xterm` and uses the right `--tab`-style invocation.

## Design principles

**The filesystem is the source of truth.** Session logs sit on disk with mtimes the kernel maintains for free. Any picture of "what sessions exist" we keep elsewhere is older than what the filesystem already reports. The tool reads the filesystem at the moment it needs an answer, rather than holding a separate model of it that has to be kept in sync.

**Read what is needed at the moment it is needed.** The toolbar's default seven-day window covers a few thousand files. Reading each one with line-streaming Tcl regex, stopping at the second user record, takes under a second in serial. The full corpus of ten thousand files takes two seconds. There is no work budget here that demands amortisation across launches.

**Memoise within a process, not across launches.** Once a file's row has been computed in this run it is reused for subsequent toolbar window changes. Shrinking the window filters in memory; growing it scans only the new files. The accumulated state lives for the lifetime of the GUI process and is discarded on quit. A user resuming a session in another terminal sees the change on the next launch, not via a watcher or a sync protocol.

**Native Tcl over subprocesses where the work allows it.** The interpreter already has an event loop, a regex engine that is C-implemented, coroutines that yield cleanly to the event loop, and a JSON parser for the cases that need one. External commands carry process-startup latency and an extra serialisation boundary at every call. The two places this tool *does* shell out (`xdg-open` for a file manager and the user's terminal binary for "Resume in new tab") are operations that can only be done by handing control to another program.

**Coroutines drive long work and yield often.** A scan that touches several thousand files cannot run as a blocking call. The scanner is a coroutine that processes a small number of files, reschedules itself with `after 1`, and yields. The UI repaints between ticks; cancellation is a single integer increment that the coroutine notices at its next yield boundary. There is no thread, no shared mutex, no worker pipe.

**Match the parser to the predicate.** Most of what the tool reads from a jsonl is a yes-or-no question against the early records of a file: *does this session contain a second user prompt?* *what is the .cwd field on any record?* These do not need a full JSON tree; a line-bounded regex finds them faster and stops earlier. The session viewer, which renders content with formatting, uses a real JSON parser per record. Different precision for different questions.

## Implementation map

```
csm                     entry script (wish9.0)
lib/
  app.tcl               wires everything; constructs Scan, Toolbar,
                        SessionList, Viewer, Search; subscribes them
  scan.tcl              Scan class: coroutine-driven, mtime-keyed
                        in-process row dict, pre-sorted by mtime DESC,
                        epoch-token cancellation
  search.tcl            Search class: own coroutine (threaded fan-out when
                        CSM_SEARCH_THREADS is set), iterates the same path
                        list, evaluates the AND-joined criteria, emits
                        matches and publishes row data back to Scan
  cli.tcl               parses a command-line criterion chain into criteria
                        that pre-seed the GUI
  path.tcl              folder-name encode/decode, projects-root path
  jsonl.tcl             record-level JSON helpers; tool_use path extraction
  terminal.tcl          terminal detection and "Resume in new tab" launch
ui/
  toolbar.tcl           ttk widgets, typed-criteria rows, git-status add
                        dropdown, snapshot publication, keystroke debounce
  sessions.tcl          SessionList: the left pane, a text widget that browses
                        and indexes; folder grouping, glyphs, hit-centred
                        snippets, right-click actions, drag-to-move
  drag.tcl              shared press-motion-release drag machinery
  viewer.tcl            docked reading view, segmentation, in-session find
  move_dialog.tcl       folder picker for "Move to..."
test/
  test-path.tcl         folder name decoding
  test-jsonl.tcl        record extraction, tool_use path/criterion
                        matching, compaction-boundary detection
  test-scan.tcl         Scan: synthetic tree, memoisation, mtime
                        invalidation, subagent-folder exclusion, ordering,
                        replay-after-window-change
  test-scan-coroutine.tcl   chunked yielding, mid-flight epoch cancellation
```

The Scan and Search classes share two structural choices. Cancellation is by epoch token: an integer that the orchestrator increments and the coroutine compares against its own captured copy after every yield. Each coroutine yields once at the very top before doing any work, so callers using `vwait` see callbacks that fire after the wait is established rather than during the synchronous setup.

Both classes reach into the project tree with a depth-2 glob: `~/.claude/projects/*/[uuid].jsonl`. Deeper paths under `<folder>/<uuid>/subagents/` hold internal subagent records, not user-visible sessions, and must not appear in the list.

## Running and testing

```
./csm                                  # launch the GUI
./csm edit lib/scan.tcl                # launch pre-seeded with an edit criterion
./csm edit foo.tcl regex "bar"         # several criteria, AND-joined
./csm -regex "pattern"                 # prefill a single regex criterion
tclsh9.0 test/test-path.tcl            # run individual tests
tclsh9.0 test/test-jsonl.tcl
tclsh9.0 test/test-scan.tcl
tclsh9.0 test/test-scan-coroutine.tcl
```

`./csm` opens the main window immediately and streams rows in. The default seven-day window populates in under a second; switching to "all" extends incrementally with the tree growing as files are scanned. Scan progress is reported in the bottom status bar.

A leading criterion type on the command line pre-seeds the GUI with a criteria chain: arguments pair as `<type> <value>`, where type is `regex`, `read`, `write`, or `edit`. `read` / `write` / `edit` match the recorded file path by suffix, `regex` matches content. The GUI then behaves normally, including the time-window control, so widen the window from the default 7 d when hunting an older edit. This launches `wish` like any GUI invocation and needs an X display. The older `-regex PATTERN` flag still prefills one regex criterion.

## Conventions enforced by pre-commit grep

```
grep -nE 'method[[:space:]]+_' lib/*.tcl ui/*.tcl   # must be empty
grep -nE '\bexec\b'           lib/*.tcl ui/*.tcl   # only ui/sessions.tcl (xdg-open),
                                                   # lib/terminal.tcl (terminal launch),
                                                   # and ui/toolbar.tcl (git status)
```

The first guards against TclOO methods named with a leading underscore. TclOO treats those as unexported and fails dispatch through callbacks like Tk `-command`, `bind`, `after`, and `chan event`. The second ensures the only subprocesses are the two genuinely unavoidable ones; if a third appears, it should be challenged before being merged.
