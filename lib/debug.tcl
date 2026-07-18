package require Tcl 9

# ::questlog::debug - an opt-in diagnostic log, off unless the launcher saw
# -debug 1.
#
# Nothing is opened and nothing is written unless the run was started with
# -debug 1, so a normal launch pays no cost and leaves no file (the gate issue
# #4 asked for). When enabled it instruments the viewer's fragile spots (the
# per-record line keying, the match-index highlight pass, and scroll_to_line
# resolution) so a future regression there is caught in a log rather than by
# eye.
#
# Same shape as ::questlog::config and ::questlog::theme: a namespace of pure
# procs over a little module state, no class. The gate also lives in config as
# `debug_enabled`, so any module can ask the one question the one way; this
# module owns the channel and the writing.

namespace eval ::questlog::debug {
    variable Enabled 0       ;# 1 once enable succeeds in opening the log
    variable Chan ""         ;# the open append channel, "" until init succeeds
    variable Warned 0        ;# 1 once an open failure has been reported, to warn once
    # The log lives under /var/local/log (note: plural), one file for the app.
    # The directory is created on first use; a packaged install may need it made
    # once by hand with the right ownership.
    variable Dir  /var/local/log/questlog
    variable Path /var/local/log/questlog/questlog.log
}

# Turn logging on and open the channel. Called by the launcher when -debug 1 was
# passed. Idempotent: a second call with the channel already open is a no-op.
# Returns 1 if logging is live afterward, 0 if the open failed (and the app then
# runs exactly as if -debug were absent).
proc ::questlog::debug::enable {} {
    variable Enabled
    variable Chan
    if {$Chan ne ""} { return 1 }
    if {![my_open]} { return 0 }
    set Enabled 1
    log session "==== started pid [pid] [clock format [clock seconds]] ===="
    return 1
}

# 1 iff logging is live. The hot-path guard: a disabled run answers 0 here and
# every log call below short-circuits before formatting anything.
proc ::questlog::debug::enabled {} {
    variable Enabled
    return $Enabled
}

# Open the append channel, creating the directory if needed. On any failure warn
# once on stderr and leave the channel closed, so logging stays off rather than
# crashing a debug run over a missing or unwritable directory. Internal.
proc ::questlog::debug::my_open {} {
    variable Chan
    variable Dir
    variable Path
    variable Warned
    catch {file mkdir $Dir}
    if {[catch {open $Path a} ch]} {
        if {!$Warned} {
            puts stderr "questlog debug: cannot open $Path ($ch); logging disabled."
            puts stderr "questlog debug: create it once with:\
                sudo mkdir -p $Dir && sudo chown [my_user] $Dir"
            set Warned 1
        }
        return 0
    }
    chan configure $ch -encoding utf-8 -profile replace
    set Chan $ch
    return 1
}

# Best-effort current user, for the help line above. Falls back to a placeholder
# when the environment names no user.
proc ::questlog::debug::my_user {} {
    foreach v {USER LOGNAME} {
        if {[info exists ::env($v)] && $::env($v) ne ""} { return $::env($v) }
    }
    return "<you>"
}

# Append one diagnostic line under a category, e.g. `log render "line 42 ..."`.
# A no-op unless enabled, so call sites can be unconditional. The category is a
# short tag (render, index, match, scroll, session, search) for grepping the log. The
# write is wrapped so a broken channel never propagates into the UI.
proc ::questlog::debug::log {category msg} {
    variable Enabled
    variable Chan
    if {!$Enabled || $Chan eq ""} return
    catch {
        puts $Chan "[clock milliseconds] [pid] $category $msg"
        flush $Chan
    }
}
