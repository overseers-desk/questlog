Name:           questlog
Version:        1.0.2
Release:        1%{?dist}
Summary:        GUI for finding, reading, and reopening past Claude Code sessions
License:        MIT
URL:            https://github.com/SmartLayer/questlog
Source0:        %{url}/archive/refs/tags/v%{version}.tar.gz#/%{name}-%{version}.tar.gz
BuildArch:      noarch

Requires:       tcl >= 9
Requires:       tk >= 9
Requires:       tcllib
Requires:       tcl-thread

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
install -d %{buildroot}%{_datadir}/%{name}/lib %{buildroot}%{_datadir}/%{name}/ui %{buildroot}%{_datadir}/%{name}/data
cp lib/*.tcl %{buildroot}%{_datadir}/%{name}/lib/
cp ui/*.tcl  %{buildroot}%{_datadir}/%{name}/ui/
cp data/*.csv %{buildroot}%{_datadir}/%{name}/data/
install -D -m 0755 questlog %{buildroot}%{_bindir}/questlog
sed -i 's|^set ROOT .*|set ROOT %{_datadir}/%{name}|' %{buildroot}%{_bindir}/questlog
install -D -m 0644 questlog.desktop \
    %{buildroot}%{_datadir}/applications/questlog.desktop

%files
%license LICENSE
%doc README.md
%{_bindir}/questlog
%{_datadir}/%{name}/
%{_datadir}/applications/questlog.desktop

%changelog
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
