# Release checklist

## Before tagging

- [ ] Version in `questlog` script (`set QUESTLOG_VERSION`) matches target version.
- [ ] `debian/changelog` has an entry for the target version with all user-facing changes.
- [ ] `questlog.spec` `%changelog` has a matching entry.
- [ ] All changes committed and pushed to main.

## Tag

```bash
git tag -f v<VERSION>
git push origin -f refs/tags/v<VERSION>
```

(`-f` re-cuts an existing tag; omit for a first cut.)

## Build packages

### Debian / Ubuntu

```bash
dpkg-buildpackage -us -uc -b
# produces ../questlog_<VERSION>_all.deb
```

### RPM / Fedora

```bash
spectool -g -R questlog.spec           # download source tarball into rpmbuild/SOURCES
rpmbuild -ba questlog.spec
# produces ~/rpmbuild/RPMS/noarch/questlog-<VERSION>-1.noarch.rpm
```

### Single-file image (zipfs)

```bash
tclsh9.0 zipfs/build.tcl
# produces dist/questlog-<VERSION>-linux-<arch>
```

One executable carrying questlog's own code, built with `zipfs mkimg` and stubbed with `wish9.0`. It runs from anywhere with no install and no root, on hosts that have the Tcl 9 runtime (`tcl9.0`, `tk9.0`, `tcllib`, `tcl-thread`), the same set the `.deb` requires and present in current distro repos. The version in the filename is read from the launcher, so there is nothing extra to bump.

How users download and run it is in [installation.md](installation.md); link that section from the GitHub release notes.

## Update the Homebrew formula

GitHub generates the tarball from the tag. Fetch it and compute the sha256:

```bash
curl -L https://github.com/SmartLayer/questlog/archive/refs/tags/v<VERSION>.tar.gz \
  | sha256sum
```

Update `formula/questlog.rb`:

- `url` line: bump the version in the tarball URL.
- `sha256` line: paste the computed digest.

Commit and push:

```bash
git commit formula/questlog.rb -m "Update Homebrew formula sha256 for v<VERSION>"
git push
```

## Publish the GitHub release

```bash
gh release edit v<VERSION> \
  --title "v<VERSION>" \
  --notes-file /tmp/release-notes.md

gh release upload v<VERSION> \
  ../questlog_<VERSION>_all.deb \
  ~/rpmbuild/RPMS/noarch/questlog-<VERSION>-1.noarch.rpm \
  dist/questlog-<VERSION>-linux-x86_64 \
  --clobber
```

## Verify

- [ ] `brew tap SmartLayer/questlog https://github.com/SmartLayer/questlog && brew install questlog` succeeds on macOS.
- [ ] `questlog --version` prints the right version on macOS and Linux.
- [ ] Debian package installs cleanly: `sudo apt install ./questlog_<VERSION>_all.deb`.
- [ ] RPM installs cleanly: `sudo dnf install ./questlog-<VERSION>-1.noarch.rpm`.
- [ ] Single-file image runs: `./dist/questlog-<VERSION>-linux-x86_64 --version`, then launch the GUI.
