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

### Single-file images (CI)

Self-contained executables that run on a host with no Tcl installed, one per platform. The `release-images` GitHub Actions workflow builds each from a static Tcl 9 + Tk + Thread (see `zipfs/build-selfcontained.sh`) and attaches it to the release. Coverage is linux x86_64, linux arm64, and macos arm64; macos x86_64 and windows are not built (see the workflow header for why).

The workflow runs automatically when a release is published (see [Publish](#publish-the-github-release) below). To run the matrix manually, e.g. a dry run before tagging:

```bash
gh workflow run release-images.yml --ref main
gh run watch          # follow the jobs to green
```

For a local self-contained build on the current platform:

```bash
zipfs/build-selfcontained.sh
# produces dist/questlog-<VERSION>-<os>-<arch>
```

For a quick local image stubbed on the host `wish9.0` (so it still needs the Tcl 9 runtime present), `tclsh9.0 zipfs/build.tcl`. The version in the filename is read from the launcher, so there is nothing extra to bump.

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

Publishing the release fires the `release-images` workflow, which builds the per-platform single-file images and attaches them to this release. Upload the `.deb` and `.rpm` (built locally above) alongside them:

```bash
gh release edit v<VERSION> \
  --title "v<VERSION>" \
  --notes-file /tmp/release-notes.md

gh release upload v<VERSION> \
  ../questlog_<VERSION>_all.deb \
  ~/rpmbuild/RPMS/noarch/questlog-<VERSION>-1.noarch.rpm \
  --clobber
```

Watch the single-file images land with `gh run watch`. If publishing is done through `gh release create ... --draft` then a separate publish step, the workflow fires on publish, not on the draft.

## Verify

- [ ] `brew tap SmartLayer/questlog https://github.com/SmartLayer/questlog && brew install questlog` succeeds on macOS.
- [ ] `questlog --version` prints the right version on macOS and Linux.
- [ ] Debian package installs cleanly: `sudo apt install ./questlog_<VERSION>_all.deb`.
- [ ] RPM installs cleanly: `sudo dnf install ./questlog-<VERSION>-1.noarch.rpm`.
- [ ] Single-file image from the release runs on a host with no Tcl installed: `./questlog-<VERSION>-linux-x86_64 --version`, then launch the GUI.
