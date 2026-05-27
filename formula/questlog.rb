# Homebrew formula for questlog.
# Install:
#   brew tap SmartLayer/questlog https://github.com/SmartLayer/questlog
#   brew install questlog

class Questlog < Formula
  desc "GUI for finding, reading, and reopening past Claude Code sessions"
  homepage "https://github.com/SmartLayer/questlog"
  url "https://github.com/SmartLayer/questlog/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "d48fbd9f11ae6978eda5fa5c8b076e0d2e8de0600c6fe57abbd77553a75d1aaf"
  license "MIT"

  depends_on "tcl-tk"

  def install
    pkgshare.install "lib", "ui", "data"

    # questlog sources lib/ and ui/ relative to ROOT and runs under wish. Point ROOT
    # at the installed tree, and pin the shebang to Homebrew's keg-only wish9.0
    # (not on PATH, so #!/usr/bin/env wish9.0 would not resolve).
    wish = Formula["tcl-tk"].opt_bin/"wish9.0"
    cp "questlog", "questlog.install"
    inreplace "questlog.install" do |s|
      s.sub!(/\A#![^\n]*/, "#!#{wish}")
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
