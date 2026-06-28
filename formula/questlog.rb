# Homebrew formula for questlog.
# Install:
#   brew tap SmartLayer/questlog https://github.com/SmartLayer/questlog
#   brew install questlog

class Questlog < Formula
  desc "GUI for finding, reading, and reopening past Claude Code sessions"
  homepage "https://github.com/SmartLayer/questlog"
  url "https://github.com/SmartLayer/questlog/archive/refs/tags/v1.1.4.tar.gz"
  sha256 "0c16608a07264f1aa3c380d2366cec3ab7c42f9f0e92182e154d71a4dae0c239"
  license "MIT"

  depends_on "tcl-tk"

  def install
    pkgshare.install "config.tcl", "lib", "ui", "cli", "data"

    # questlog sources lib/ and ui/ relative to ROOT and runs under tclsh, loading
    # Tk only in GUI mode. Point ROOT at the installed tree, and pin the shebang to
    # Homebrew's keg-only tclsh9.0 (not on PATH, so #!/usr/bin/env tclsh9.0 would
    # not resolve); GUI mode's package require Tk resolves against the same keg.
    tclsh = Formula["tcl-tk"].opt_bin/"tclsh9.0"
    cp "questlog", "questlog.install"
    inreplace "questlog.install" do |s|
      s.sub!(/\A#![^\n]*/, "#!#{tclsh}")
      s.gsub!(/^set ROOT .*$/, "set ROOT #{pkgshare}")
    end
    libexec.install "questlog.install" => "questlog"
    chmod 0755, libexec/"questlog"
    bin.install_symlink libexec/"questlog"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/questlog --version")
  end
end
