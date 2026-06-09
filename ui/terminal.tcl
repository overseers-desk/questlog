package require Tcl 9

namespace eval ::questlog::ui::terminal {
    namespace export launch_tab resume_command oneshot_command permission_flags
    variable Detected ""
}

# Build the compound resume command. claude has no flag for cwd, so cd is
# part of the command. fork=1 appends --fork-session.
proc ::questlog::ui::terminal::resume_command {cwd uuid {fork 0}} {
    set extra [expr {$fork ? " --fork-session" : ""}]
    return "cd [shquote $cwd] && claude --resume $uuid$extra"
}

# Build the shell command for one non-interactive resume turn, streamed back
# into the viewer. Like resume_command, cd carries the cwd. The turn is
# written to the session jsonl (the viewer tails that); stdout is only the
# turn's text and any error, so no --output-format is needed. perm_flags is
# the pre-built string from permission_flags; cwd and prompt are shell-quoted.
proc ::questlog::ui::terminal::oneshot_command {cwd uuid prompt perm_flags} {
    return "cd [shquote $cwd] && claude -p --resume $uuid $perm_flags [shquote $prompt]"
}

# Map a prompt-bar permission choice to claude flags. A -p turn cannot answer
# a permission prompt, so any tool access must be granted up front: read-only
# leaves the default mode (tools needing approval are skipped), the edit modes
# auto-accept, and full bypasses all checks.
proc ::questlog::ui::terminal::permission_flags {mode} {
    switch -- $mode {
        edits     { return "--permission-mode acceptEdits" }
        edits-git { return {--permission-mode acceptEdits --allowedTools "Bash(git*)"} }
        full      { return "--dangerously-skip-permissions" }
        default   { return "--permission-mode default" }
    }
}

# Detection order from design.md §Resume command and terminal integration:
#   1. macOS: $TERM_PROGRAM -> iTerm2 if set, else Terminal.app (always there)
#   2. $GNOME_TERMINAL_SERVICE  -> gnome-terminal
#   3. $KONSOLE_VERSION         -> konsole
#   4. parent process tree walk
#   5. fall back to first installed: ptyxis, gnome-terminal, konsole, xterm
proc ::questlog::ui::terminal::detect {} {
    variable Detected
    if {$Detected ne ""} { return $Detected }

    if {$::tcl_platform(os) eq "Darwin"} {
        if {[info exists ::env(TERM_PROGRAM)] \
            && $::env(TERM_PROGRAM) eq "iTerm.app"} {
            return [set Detected iterm2]
        }
        return [set Detected macterminal]
    }

    if {[info exists ::env(GNOME_TERMINAL_SERVICE)]} {
        return [set Detected gnome-terminal]
    }
    if {[info exists ::env(KONSOLE_VERSION)]} {
        return [set Detected konsole]
    }
    set parent [walk_parents]
    if {$parent ne ""} { return [set Detected $parent] }

    foreach bin {ptyxis gnome-terminal konsole xterm} {
        if {[auto_execok $bin] ne ""} {
            return [set Detected $bin]
        }
    }
    return [set Detected ""]
}

# Walk /proc/$PID/status upward looking for a known terminal binary name.
proc ::questlog::ui::terminal::walk_parents {} {
    set known {ptyxis gnome-terminal-server konsole xterm alacritty kitty}
    set pid [pid]
    for {set i 0} {$i < 10} {incr i} {
        set status_path /proc/$pid/status
        if {![file readable $status_path]} { return "" }
        set fh [open $status_path r]
        set txt [read $fh]
        close $fh
        set name ""
        set ppid 0
        foreach ln [split $txt \n] {
            if {[regexp {^Name:\s+(.*)$} $ln -> name]} { }
            if {[regexp {^PPid:\s+(\d+)$} $ln -> ppid]} { }
        }
        if {$name in $known} {
            # Map server names back to launchable CLIs.
            switch -- $name {
                gnome-terminal-server { return gnome-terminal }
                default { return $name }
            }
        }
        if {$ppid <= 1} { return "" }
        set pid $ppid
    }
    return ""
}

# Open a new terminal tab (or window) running "claude --resume <uuid>" in
# the given cwd. Returns 1 on success, 0 on failure.
proc ::questlog::ui::terminal::launch_tab {cwd uuid {fork 0}} {
    set t [detect]
    set extra [expr {$fork ? " --fork-session" : ""}]
    set inner "claude --resume $uuid$extra; exec bash"
    switch -- $t {
        ptyxis {
            return [exec_ok ptyxis --tab --working-directory=$cwd -- bash -c $inner]
        }
        gnome-terminal {
            return [exec_ok gnome-terminal --tab --working-directory=$cwd -- bash -c $inner]
        }
        konsole {
            return [exec_ok konsole --new-tab --workdir $cwd -e bash -c $inner]
        }
        macterminal {
            # Terminal.app has no scripting command for "new tab"; "do script"
            # always opens a new window. Match the Linux behaviour (tab in
            # the current window) by simulating Cmd-T via System Events when
            # a window already exists, then writing into the new front tab.
            # The first such invocation triggers a one-time macOS prompt to
            # grant Accessibility to osascript; with no Terminal window open
            # yet, fall back to a plain "do script" so the first launch
            # never depends on that permission.
            set shell "cd [shquote $cwd] && $inner"
            set as [string map [list %CMD% [asquote $shell]] {
tell application "Terminal"
    activate
    if (count of windows) = 0 then
        do script %CMD%
    else
        tell application "System Events" to keystroke "t" using {command down}
        delay 0.2
        do script %CMD% in selected tab of front window
    end if
end tell
}]
            return [exec_ok osascript -e $as]
        }
        iterm2 {
            # iTerm has first-class tab scripting; fall back to a new window
            # if none is open. Same shell command as Terminal.app.
            set shell "cd [shquote $cwd] && $inner"
            set as [string map [list %CMD% [asquote $shell]] {
tell application "iTerm"
    activate
    if (count of windows) = 0 then
        set w to (create window with default profile)
        tell current session of w to write text %CMD%
    else
        tell current window
            set t to (create tab with default profile)
            tell current session of t to write text %CMD%
        end tell
    end if
end tell
}]
            return [exec_ok osascript -e $as]
        }
        xterm - alacritty - kitty - default {
            # No reliable tab CLI: fall back to a fresh window.
            set bin [expr {$t eq "" ? "xterm" : $t}]
            return [exec_ok $bin -e bash -c "cd [shquote $cwd] && $inner"]
        }
    }
}

proc ::questlog::ui::terminal::exec_ok {args} {
    if {[catch {exec {*}$args &} err]} {
        puts stderr "questlog: terminal launch failed: $err"
        return 0
    }
    return 1
}

# Conservative shell-quote for a path that will appear inside a bash -c string.
proc ::questlog::ui::terminal::shquote {s} {
    return '[string map {' '\\''} $s]'
}

# AppleScript string literal: wrap in double quotes and escape \ and " only.
proc ::questlog::ui::terminal::asquote {s} {
    return \"[string map [list \\ \\\\ \" \\\"] $s]\"
}
