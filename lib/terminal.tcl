package require Tcl 9

namespace eval ::fms::terminal {
    namespace export launch_tab resume_command
    variable Detected ""
}

# Build the compound resume command. claude has no flag for cwd, so cd is
# part of the command. fork=1 appends --fork-session.
proc ::fms::terminal::resume_command {cwd uuid {fork 0}} {
    set extra [expr {$fork ? " --fork-session" : ""}]
    return "cd [shquote $cwd] && claude --resume $uuid$extra"
}

# Detection order from design.md §Resume command and terminal integration:
#   1. macOS: $TERM_PROGRAM -> iTerm2 if set, else Terminal.app (always there)
#   2. $GNOME_TERMINAL_SERVICE  -> gnome-terminal
#   3. $KONSOLE_VERSION         -> konsole
#   4. parent process tree walk
#   5. fall back to first installed: ptyxis, gnome-terminal, konsole, xterm
proc ::fms::terminal::detect {} {
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
proc ::fms::terminal::walk_parents {} {
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
proc ::fms::terminal::launch_tab {cwd uuid {fork 0}} {
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
            # Terminal.app has no flag for cwd; "do script" runs a shell
            # command in a new window. Users who prefer tabs can set
            # Terminal > Settings > General > New windows open with: Tab.
            set shell "cd [shquote $cwd] && $inner"
            set as "tell application \"Terminal\"\nactivate\ndo script [asquote $shell]\nend tell"
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

proc ::fms::terminal::exec_ok {args} {
    if {[catch {exec {*}$args &} err]} {
        puts stderr "fms: terminal launch failed: $err"
        return 0
    }
    return 1
}

# Conservative shell-quote for a path that will appear inside a bash -c string.
proc ::fms::terminal::shquote {s} {
    return '[string map {' '\\''} $s]'
}

# AppleScript string literal: wrap in double quotes and escape \ and " only.
proc ::fms::terminal::asquote {s} {
    return \"[string map [list \\ \\\\ \" \\\"] $s]\"
}
