# Homebrew formula for find-my-session.
# Install:
#   brew tap SmartLayer/find-my-session https://github.com/SmartLayer/find-my-session
#   brew install find-my-session

class FindMySession < Formula
  desc "GUI for finding, reading, and reopening past Claude Code sessions"
  homepage "https://github.com/SmartLayer/find-my-session"
  url "https://github.com/SmartLayer/find-my-session/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "d48fbd9f11ae6978eda5fa5c8b076e0d2e8de0600c6fe57abbd77553a75d1aaf"
  license "MIT"

  depends_on "tcl-tk"

  def install
    pkgshare.install "lib", "ui"

    # fms sources lib/ and ui/ relative to ROOT and runs under wish. Point ROOT
    # at the installed tree, and pin the shebang to Homebrew's keg-only wish9.0
    # (not on PATH, so #!/usr/bin/env wish9.0 would not resolve).
    wish = Formula["tcl-tk"].opt_bin/"wish9.0"
    cp "fms", "fms.install"
    inreplace "fms.install" do |s|
      s.sub!(/\A#![^\n]*/, "#!#{wish}")
      s.gsub!(/^set ROOT .*$/, "set ROOT #{pkgshare}")
    end
    libexec.install "fms.install" => "fms"
    chmod 0755, libexec/"fms"
    bin.install_symlink libexec/"fms"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/fms --version")
  end
end
