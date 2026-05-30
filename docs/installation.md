# Installing questlog

questlog runs on Linux and macOS. Pick one of the methods below, then see the Running section of the [README](../README.md) for the GUI and the command-line criteria.

Released artifacts are on the [releases page](https://github.com/SmartLayer/questlog/releases); the version appears in each filename.

## Linux

### Debian / Ubuntu

Download `questlog_<version>_all.deb` and install it. apt pulls the Tcl 9 runtime as dependencies:

```
sudo apt install ./questlog_<version>_all.deb
```

### Fedora / RHEL

Download `questlog-<version>-1.noarch.rpm` and install it:

```
sudo dnf install ./questlog-<version>-1.noarch.rpm
```

### Single-file image

One executable carrying questlog's own code, with nothing to install. Download `questlog-<version>-linux-x86_64`, make it executable, and run it:

```
chmod +x questlog-<version>-linux-x86_64
./questlog-<version>-linux-x86_64
```

It needs the Tcl 9 runtime present on the host: `tcl9.0`, `tk9.0`, `tcllib`, and `tcl-thread`, the same set the `.deb` declares, available from current distribution repositories. Use this when you want a single file to drop on a machine or a USB stick, or to run without root, on a host that already has or can add that runtime.

## macOS

Install through Homebrew, which pulls `tcl-tk` (9.x) as a dependency:

```
brew tap SmartLayer/questlog https://github.com/SmartLayer/questlog
brew install questlog
```
