# Current UI State

## At a glance

questlog is a single-window desktop application built in Tk/Tcl. The window has three horizontal regions stacked top to bottom:

1. A toolbar at the top, holding all filters and search criteria.
2. A body area that fills the rest of the window. The body is a horizontal split: a session list on the left, and a session viewer on the right.
3. A one-line status bar pinned to the bottom edge.

When the app first opens, only the left pane of the body is present. The session viewer is built but kept out of the split until the user opens a session for the first time. From that point on both panes remain, with the list taking roughly two parts and the session viewer roughly three (the user can drag the divider between them).

The core loop is: pick a time window and any combination of filters in the toolbar, scan the list of sessions on the left for the one you want, open it in the session viewer on the right, then either read it, copy a resume command, or relaunch it in a terminal.

---

## Toolbar

The toolbar runs across the full window width at the top and is laid out as three stacked rows.

**Row 1, time window and current-directory scope.** A "Time:" label followed by four radio buttons (24h, 7d, 30d, all), then a vertical separator, then a checkbox labelled "this cwd only". Exactly one time button is active; the default is 7d. The checkbox is checked by default when the directory FMS was launched from has any matching Claude project folder on disk. When it does not, the checkbox is greyed out and stays unchecked.

**Criteria frame.** Below Row 1 sits a labelled frame captioned "Criteria (AND)". In its top-right corner is a small "Aa" checkbox that toggles case-sensitive matching for the regex criteria. The body of this frame holds two things: a stack of criterion rows (zero or more), and a fixed row of four buttons at the bottom labelled "+ regex", "+ Read", "+ Write", "+ Edit". The four-button row is always visible; criterion rows accumulate above it as the user adds them. The frame caption "(AND)" is the only visible hint that multiple rows compose by intersection.

Clicking one of the four "+" buttons opens a small floating dropdown anchored directly below it. For "+ regex" the dropdown is just a text entry and an "add" button (Enter in the entry submits). For "+ Read", "+ Write", and "+ Edit" the dropdown additionally shows an "open..." button that launches the system file chooser. For "+ Write" and "+ Edit", when the launch directory is a git repository, a short listbox at the top of the dropdown lists the working tree's modified and untracked files (up to about eight visible at once); clicking one immediately adds it and closes the dropdown. Confirming from any dropdown adds a criterion row and triggers a search.

Each criterion row has three parts: a fixed-width type label ("regex", "read", "write", or "edit"), a text entry containing the value, and a narrow "−" button. The "−" button removes the row immediately. Editing the text in a row re-runs the search after a 200 ms debounce, so the user does not need to press Return. On removal, focus moves to the previous remaining row's entry, or to "+ regex" if no rows remain.

The semantics: a regex criterion matches text content anywhere in the session. A read, write, or edit criterion matches file paths that were read, written, or edited during the session, by path suffix (a bare filename matches in any directory). All criteria are AND-combined.

**Row 2, secondary filters.** Three checkboxes on a single row: "exclude one-turn sessions" (default on), "running only" (default off), "bookmarked only" (default off). Each takes effect immediately.

---

## Session list (left pane)

The session list fills the height of the left pane. It is a read-only scrollable text widget with a vertical scrollbar on the right edge. A thin status strip sits above it with a label on the left and a "Cancel" button on the right.

The strip's label shows "Scanning N / M..." or "Searching ... N / M sessions   matches: K" while work is in progress, "Done. N sessions, K matches." when complete, or "Cancelled." after a cancellation. It is blank when idle. The Cancel button is always present but only meaningful while a search is running.

The list has two modes, switched implicitly by whether any criterion row currently has a value.

**Browse mode (no criteria).** The list shows every session that passes the time window and the secondary filters, grouped by project folder. Each group begins with a folder heading line: a disclosure triangle ("▸" collapsed, "▾" expanded), the project path, and a session count in parentheses. Groups start collapsed in this mode; clicking a heading toggles it. When expanded, each session inside the group appears as a single line containing a monospace prefix (day, date, month, time, file size), an optional glyph zone (a filled circle "●" for a running session, a star "★" for a bookmarked session, or both), and the text of that session's first user prompt. Sessions with no user prompt show the session UUID instead.

**Search mode (one or more criteria active).** Groups start expanded. Only sessions with at least one match are listed. Each matching session shows the same header line as in browse mode, with the match count appended ("· 3 matches"). Below the header, up to three snippet rows are shown, one per distinct match. A snippet row has a small block-type label on the left (user, assistant, tool_use, tool_result, or system, each in its own colour) followed by an excerpt of the surrounding text with the matched terms highlighted. Up to four simultaneous search terms each get a distinct highlight colour (yellow, light blue, pink, light green).

### Interaction with the list

A single click on a session header opens that session in the session viewer, anchored at its first match (or the top, when browsing), and highlights the whole session block in light blue.

A single click on a snippet row opens the session too, scrolled to the line of that particular match.

Selecting and opening are the same act, so the highlighted row and the viewer always refer to the same session.

The first time a click opens a session, the session viewer pane is added to the body split. From then on, every subsequent open replaces the content of the same right pane.

Right-click (or Control-click on macOS) on a session opens a context menu with these items, in order:

- Open in viewer
- (separator)
- Copy resume command
- Copy session id
- Copy session path
- Copy last assistant output
- (separator)
- Resume in new terminal tab
- Resume forked
- (separator)
- Move to...
- Reveal folder
- (separator)
- Bookmark (the label alternates with the session's current bookmark state)

"Copy resume command", "Resume in new terminal tab", and "Resume forked" are greyed out when the session's project folder cannot be resolved to a real directory. "Reveal folder" is greyed out when no folder is known. "Resume in new terminal tab" opens a new tab in Terminal.app or iTerm2 on macOS and runs `claude --resume` for that session; on first use macOS prompts for accessibility permission and, until granted, the action fails with a generic "execution error". "Resume forked" does the same with a fork flag, starting a new branch from the selected session.

Drag to move: pressing and holding on a session header and then moving the pointer at least 6 pixels begins a drag. The cursor changes to a fleur (crosshair). While the pointer is over the list, any folder heading it crosses is highlighted in light blue as a drop candidate. Releasing over a highlighted folder moves the session there. Releasing anywhere else, or never crossing the drag threshold, falls back to a click. Drag is the only direct gesture for re-filing; the same operation is available through the context menu's "Move to..." item.

---

## Session viewer (right pane)

The session viewer is the right pane. It is absent until the first open, then permanent for the rest of the session.

At the top sits a header strip: the full file path of the loaded session on the left, and, when the session was opened from a search, a match-count control on the right. Below it, the main area is a read-only scrollable text widget with a vertical scrollbar.

The content is the full session transcript as a flat sequence of turns. Consecutive turns with no long gap between them are grouped into sections; each section begins with a "▼" heading and a timestamp. A gap of 10 minutes or more between two consecutive turns shows as a centred "---  N min later ---" divider. A compaction boundary in the underlying file shows as a red centred "--- /compact ---" line. Each turn is preceded by its type label in uppercase (USER, ASSISTANT, SYSTEM, or the raw type for other kinds), colour-coded by type, followed by the text body.

Clicking inside the session viewer gives the text widget keyboard focus, which is needed for the in-text search shortcut.

Note: lines 88–110 of the session viewer's source carry an active diagnostic block tied to issue #4, including mouse-event logging on stderr and an F8 binding that dumps internal Tk state. Text selection behaviour in this pane is currently in a transitional state and should be re-checked against the code at the moment any design work proceeds.

**In-text search.** Ctrl+F opens a Find bar at the bottom of the session viewer: a "Find:" label, a text entry, a "Next" button, and a close button ("✕"). Typing and pressing Return (or clicking "Next") cycles through matches, highlighting each in yellow and scrolling it into view. Escape, "✕", or pressing Escape while focus is in the transcript closes the bar and clears the highlights.

**Match index.** When a session is opened from a search, its search terms are highlighted in the transcript (yellow) and the head strip carries a "▾ N matches" control on the right. Clicking it drops a list of every match, each labelled with a one-line excerpt of its line; choosing one scrolls the viewer to that match. It is an in-page anchor list; a long index scrolls within the dropdown. The control is absent when the session was opened while browsing. The index and the Ctrl+F Find bar share the same match set, so stepping is consistent between them.

---

## Move session dialog

Invoked via the context menu's "Move to..." item, or by dropping a session on a folder heading other than the source folder. It opens as a modal window titled "Move session" and blocks the main window while open.

The dialog shows a message stating how many sessions are being moved. Below it, a scrollable single-selection list (a ttk::treeview) shows one row per project folder that exists on disk, with the home directory abbreviated as "~". The current session's own folder is excluded. Below the list, a text entry labelled "Or enter a directory:" allows typing an arbitrary path; selecting a row in the list fills the entry. To the right of the entry is a "Browse..." button that opens the system folder chooser.

At the bottom, "Cancel" dismisses without moving, "Move" executes. Double-clicking a list row triggers a move immediately. Return in the entry is equivalent to "Move"; Escape anywhere is equivalent to "Cancel". A non-absolute path typed manually shows an error dialog and leaves the move dialog open.

---

## Status bar

A one-line label across the full width of the window bottom, with a sunken relief. When the session viewer loads a session, it shows that session's file path, with the line number in parentheses if a specific line was jumped to. While scanning or searching, progress is shown here as well. Otherwise it is blank.

---

## States the UI can be in

- **Just launched.** Toolbar at its defaults (7d, "this cwd only" auto-set per the launch directory). The session list is filling as the scanner runs. The session viewer pane is not yet present. The status bar shows scan progress.
- **Browse mode.** Scan complete, no criteria. The list shows collapsed folder headings; the viewer pane is still absent until something is opened.
- **Folder expanded.** One or more folder groups opened. Session headers visible under them.
- **Search running.** At least one criterion has a value. Matching sessions stream into the list with their snippets. Progress shown in the list strip and the window status bar. Cancel button is meaningful.
- **Search complete.** Summary in the list strip. Results stay until the filter changes.
- **Viewer open.** The right pane is present and holds a transcript. Subsequent clicks in the list replace that transcript.
- **Find bar active.** Find bar visible at the bottom of the viewer; matches highlighted in yellow.
- **Move dialog open.** Main window blocked. Modal move dialog in the foreground.
