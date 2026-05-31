package require Tcl 9

# ::questlog::state - the app's one piece of cross-launch state: small UI flags
# under the XDG state directory. The session model is never persisted (the
# JSONL under ~/.claude/projects is its source of truth, re-read each launch);
# this holds only flags like "the first-run welcome was dismissed", which have
# no home in the filesystem the app already reads. A flag is an empty marker
# file named for the flag, so presence is the boolean.

namespace eval ::questlog::state {}

# The flag directory: $XDG_STATE_HOME/questlog, else ~/.local/state/questlog.
proc ::questlog::state::dir {} {
    if {[info exists ::env(XDG_STATE_HOME)] && $::env(XDG_STATE_HOME) ne ""} {
        set base $::env(XDG_STATE_HOME)
    } else {
        set base [file join $::env(HOME) .local state]
    }
    return [file join $base questlog]
}

# True when the named flag was set in this or a previous run.
proc ::questlog::state::flag_get {name} {
    return [file exists [file join [::questlog::state::dir] $name]]
}

# Record the named flag, creating the state directory if needed. The mkdir
# goes through path.tcl's _real_file escape hatch, the same one its own
# filesystem sinks use, since the architectural gate there blocks a bare `file
# mkdir`. A write failure (read-only home, etc.) is reported on stderr and
# swallowed: being unable to remember a dismissal must never block the app.
proc ::questlog::state::flag_set {name} {
    set d [::questlog::state::dir]
    if {[catch {
        if {![file isdirectory $d]} { ::questlog::path::_real_file mkdir $d }
        close [open [file join $d $name] w]
    } err]} {
        puts stderr "questlog: cannot record state '$name': $err"
    }
}
