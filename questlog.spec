Name:           questlog
Version:        1.0.0
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
* Mon May 25 2026 Weiwu Zhang <a@colourful.land> - 1.0.0-1
- Initial package
