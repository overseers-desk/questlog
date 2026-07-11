package require Tcl 9

# ::questlog::ui::live - which sessions are running right now.
#
# Claude Code records every live session at ~/.claude/sessions/<pid>.json
# holding {pid, sessionId(=uuid), cwd, procStart, status, ...}. The file
# is not removed atomically on every kind of exit, and a pid can be
# recycled, so a record is trusted only when its pid is still alive AND
# /proc/<pid>/stat field 22 (start_time) equals the recorded procStart.
#
# A pure reader: every call re-reads the filesystem. No cached set, no
# generation token - the caller polls it and re-derives the UI from the
# result, so a stale UI cannot persist past one tick. A proc-namespace
# like path.tcl and terminal.tcl, not a class: there is no joint state
# to absorb.

namespace eval ::questlog::ui::live {
    namespace export running_uuids running_sessions
}

# Returns a dict: uuid -> {path <p> cwd <c>}. The path is where the
# running process would write (projects_root / encode_cwd(cwd) /
# uuid.jsonl); for a session the manager has moved this no longer names
# the on-disk file, so callers MATCH by uuid (stable across a move) and
# use the path only to scan a freshly-started session into view. The cwd
# is the project the session runs in, as the registry recorded it: it
# names a live session for a reader (the list's cut banner) without
# opening its transcript.
#
# This is the Running lens's whole membership, and it owes nothing to the
# search: a session running right now is here whether or not the search's
# window would have loaded its file.
proc ::questlog::ui::live::running_sessions {} {
    set dir [file join [file home] .claude sessions]
    if {![file isdirectory $dir]} { return [dict create] }
    set out [dict create]
    foreach f [glob -nocomplain -directory $dir -- *.json] {
        if {[catch {open $f r} fh]} continue
        set txt [read $fh]
        close $fh
        if {![regexp {"pid":\s*(\d+)} $txt -> pid]} continue
        if {![regexp {"sessionId":"([^"]+)"} $txt -> uuid]} continue
        if {![regexp {"procStart":"([^"]+)"} $txt -> procstart]
            && ![regexp {"procStart":\s*(\d+)} $txt -> procstart]} continue
        set cwd ""
        regexp {"cwd":"([^"]+)"} $txt -> cwd
        if {![proc_alive_matching $pid $procstart]} continue
        set path [file join [::questlog::path::projects_root] \
                      [::questlog::path::encode_cwd $cwd] $uuid.jsonl]
        dict set out $uuid [dict create path $path cwd $cwd]
    }
    return $out
}

# The same live set as uuid -> path, for the callers that only ever match a
# row's uuid and open its file (the running markers, the move and rename
# guards).
proc ::questlog::ui::live::running_uuids {} {
    set out [dict create]
    dict for {uuid s} [running_sessions] {
        dict set out $uuid [dict get $s path]
    }
    return $out
}

# True iff $pid is alive and, where the start_time can be read, its
# process start_time matches $procstart.
#
# Where /proc is available (Linux), match field 22 (start_time) of
# /proc/<pid>/stat against the recorded procStart; this distinguishes a
# live session from a recycled pid. field 2 (comm) may contain spaces and
# parentheses, so anchor on the LAST ')': the remainder begins at field 3,
# making field 22 the 20th token (index 19).
#
# Without /proc (macOS), fall back to a plain existence check via `kill -0`.
# The recorded procStart is the platform's own start-time encoding and is
# not re-derivable here, so the recycling guard is dropped: a pid reused
# within one poll interval could read as live. Accepted, because the only
# alternative off Linux is to report every session as not running. Keyed
# on whether the stat file is readable, not on the OS name, so the strict
# path is taken wherever the kernel actually exposes it.
proc ::questlog::ui::live::proc_alive_matching {pid procstart} {
    set p /proc/$pid/stat
    if {[file readable $p]} {
        if {[catch {open $p r} fh]} { return 0 }
        set stat [read $fh]
        close $fh
        set rparen [string last ) $stat]
        if {$rparen < 0} { return 0 }
        set rest [string range $stat [expr {$rparen + 2}] end]
        return [expr {[lindex $rest 19] eq $procstart}]
    }
    return [expr {![catch {exec kill -0 $pid}]}]
}
