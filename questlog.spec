Name:           questlog
Version:        1.1.4
Release:        1%{?dist}
Summary:        GUI for finding, reading, and reopening past Claude Code sessions
License:        MIT
URL:            https://github.com/overseers-desk/questlog
Source0:        %{url}/archive/refs/tags/v%{version}.tar.gz#/%{name}-%{version}.tar.gz
BuildArch:      noarch

Requires:       tcl >= 9
Requires:       tk >= 9
Requires:       tcllib
Requires:       tcl-thread
Requires:       hicolor-icon-theme

%description
questlog is a Tk desktop tool that browses the JSONL logs Claude Code
writes under ~/.claude/projects/. It lists sessions grouped by project, runs
typed searches (regex over message content, or the files a built-in
Read/Write/Edit tool touched) that stream matches as snippets, segments long
conversations in a docked reading view, and reopens a session in its original
working directory.

%prep
%autosetup -n %{name}-%{version}

%build
# Pure Tcl; nothing to build.

%install
install -d %{buildroot}%{_datadir}/%{name}/lib %{buildroot}%{_datadir}/%{name}/ui %{buildroot}%{_datadir}/%{name}/cli %{buildroot}%{_datadir}/%{name}/data %{buildroot}%{_datadir}/%{name}/assets
cp lib/*.tcl %{buildroot}%{_datadir}/%{name}/lib/
cp ui/*.tcl  %{buildroot}%{_datadir}/%{name}/ui/
cp cli/*.tcl %{buildroot}%{_datadir}/%{name}/cli/
cp data/*.csv %{buildroot}%{_datadir}/%{name}/data/
cp config.tcl %{buildroot}%{_datadir}/%{name}/
cp assets/questlog.svg %{buildroot}%{_datadir}/%{name}/assets/
install -D -m 0755 questlog %{buildroot}%{_bindir}/questlog
sed -i 's|^set ROOT .*|set ROOT %{_datadir}/%{name}|' %{buildroot}%{_bindir}/questlog
install -D -m 0644 assets/questlog.desktop \
    %{buildroot}%{_datadir}/applications/questlog.desktop
# Icon theme: the .desktop's Icon=questlog resolves here. The hicolor file
# triggers rebuild the cache on install.
install -D -m 0644 assets/questlog.svg \
    %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/questlog.svg
install -D -m 0644 assets/questlog-256.png \
    %{buildroot}%{_datadir}/icons/hicolor/256x256/apps/questlog.png
install -D -m 0644 assets/questlog-512.png \
    %{buildroot}%{_datadir}/icons/hicolor/512x512/apps/questlog.png

%files
%license LICENSE
%doc README.md
%{_bindir}/questlog
%{_datadir}/%{name}/
%{_datadir}/applications/questlog.desktop
%{_datadir}/icons/hicolor/scalable/apps/questlog.svg
%{_datadir}/icons/hicolor/256x256/apps/questlog.png
%{_datadir}/icons/hicolor/512x512/apps/questlog.png

%changelog
* Sun Jun 28 2026 Weiwu Zhang <a@colourful.land> - 1.1.4-1
- Search criteria: a sentence-long regex no longer carries its delete button off-screen; the × anchors at the chip's left edge so the criterion stays removable

* Tue Jun 02 2026 Weiwu Zhang <a@colourful.land> - 1.1.2-1
- CLI: the --json search composes by one boolean algebra; --keyword and --regex each take an optional :regions suffix; --or widens to OR, --not negates the next clause; --scope removed; --case for case-sensitive keywords
- CLI: --shortstat emits a totals summary (session and subagent counts, turns, tokens, total cost) over the same result set as --json
- CLI: the default --limit is removed; a query returns every matching session unless --limit caps it
- CLI: --json emits null for an unknown cost rather than the -1.0 sentinel
- Time filter unified across CLI and GUI: --since takes a relative window (24h, 7d, 2w) or an absolute date (2026-04-01); the GUI time row gains a custom member with a date-picker popover
- Packaging: install the cli/ scripts so --json and --shortstat work from packages
* Mon Jun 01 2026 Weiwu Zhang <a@colourful.land> - 1.1.1-1
- Fix: duplicate token counting corrected by deduplicating on requestId
- Fix: folder heading overwrite bug fixed
- Subagent metrics fold up to the parent session level
- CLI: --json flag replaces --cli; --help/-h handled
- CLI: --since filters JSON output by recency (e.g. 24h, 7d, 2w); the launcher's --window flag was renamed to --since
- Cost module refactored as a pure domain library

* Mon Jun 01 2026 Weiwu Zhang <a@colourful.land> - 1.1.0-1
- Subagents surface under their parent session in the list and search
- Tool-call audit timeline in the session viewer
- Export a session as Markdown
- Turns and Duration columns; per-session actions menu (⋯)
- Sortable column headers for date, size, and cost; cost cells colour-coded by tier
- Folder cost totals shown in the cost column
- First-run welcome banner
- Search results batch-rendered at idle for a smooth fill; scan pauses while typing
- Launcher --window and --search prefill flags
- Ctrl+B folds the list column for focused reading
- Rounded controls, badges, and SVG criterion buttons
- Filter label and criterion subtitles; hover-reveal remove button on active criteria
- Proportional reading font with a chooser and --font flag
- Session grouping spine beside search-result snippets
- Match index ordered rarest-keyword-first
- Bold, italic, and inline-code rendering in the reading pane
- Left-ruled blockquotes with hover Copy and Collapse in the session viewer
- config.tcl consolidates all tuning constants (render slice, display caps, drag thresholds)
- Single-file image: arm64 archive-name token normalised; static self-contained interpreter

* Sat May 30 2026 Weiwu Zhang <a@colourful.land> - 1.0.2-1
- Fix: session list could hang over a large recent history; a session file
  above 64 KB aborted the scan under Tcl 9 strict UTF-8 decoding
- Single-file executable via zipfs mkimg (runs with the Tcl 9 runtime)
- Installation guide added (docs/installation.md)
- Runs on macOS (liveness, launch cwd, reveal-in-folder no longer Linux-only)
- Search runs on Enter instead of on every keystroke
- Right-click a search-result row to open its session menu
- Search hits marked by an amber background; design palette, pills, toolbar adopted

* Fri May 29 2026 Weiwu Zhang <a@colourful.land> - 1.0.1-1
- Project renamed from find-my-session to questlog; command is now questlog
- Session viewer is a persistent full-height pane from launch; single-click opens
- Match navigation moved into the viewer; match index shown as a floating overlay
- Search terms matched literally (not as regex) in both highlighters
- Search matches the whole session, not just the same line
- Toolbar scoped to the list column
- Assistant blockquotes rendered as collapsible copy boxes in the viewer
- Per-session token cost shown as a column in the session list
- Session slug shown; right-click menu includes a Rename action
- Show-all banner when a directory chip was auto-applied from the launch cwd
- Fix: empty session list when auto-applied directory chip was the only filter

* Mon May 25 2026 Weiwu Zhang <a@colourful.land> - 1.0.0-1
- Initial package
