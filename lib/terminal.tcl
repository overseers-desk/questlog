package require Tcl 9

namespace eval ::csm::terminal {
    namespace export launch_tab resume_command
    variable Detected ""
}

# Build the compound resume command. claude has no flag for cwd, so cd is
# part of the command. fork=1 appends --fork-session.
proc ::csm::terminal::resume_command {cwd uuid {fork 0}} {
    set extra [expr {$fork ? " --fork-session" : ""}]
    return "cd [shquote $cwd] && claude --resume $uuid$extra"
}

# Detection order from design.md §Resume command and terminal integration:
#   1. $GNOME_TERMINAL_SERVICE  -> gnome-terminal
#   2. $KONSOLE_VERSION         -> konsole
#   3. parent process tree walk
#   4. fall back to first installed: ptyxis, gnome-terminal, konsole, xterm
proc ::csm::terminal::detect {} {
    variable Detected
    if {$Detected ne ""} { return $Detected }

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
proc ::csm::terminal::walk_parents {} {
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
proc ::csm::terminal::launch_tab {cwd uuid {fork 0}} {
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
        xterm - alacritty - kitty - default {
            # No reliable tab CLI: fall back to a fresh window.
            set bin [expr {$t eq "" ? "xterm" : $t}]
            return [exec_ok $bin -e bash -c "cd [shquote $cwd] && $inner"]
        }
    }
}

proc ::csm::terminal::exec_ok {args} {
    if {[catch {exec {*}$args &} err]} {
        puts stderr "csm: terminal launch failed: $err"
        return 0
    }
    return 1
}

# Conservative shell-quote for a path that will appear inside a bash -c string.
proc ::csm::terminal::shquote {s} {
    return '[string map {' '\\''} $s]'
}
