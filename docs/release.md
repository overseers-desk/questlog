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
  --clobber
```

## Verify

- [ ] `brew tap SmartLayer/questlog https://github.com/SmartLayer/questlog && brew install questlog` succeeds on macOS.
- [ ] `questlog --version` prints the right version on macOS and Linux.
- [ ] Debian package installs cleanly: `sudo apt install ./questlog_<VERSION>_all.deb`.
- [ ] RPM installs cleanly: `sudo dnf install ./questlog-<VERSION>-1.noarch.rpm`.
