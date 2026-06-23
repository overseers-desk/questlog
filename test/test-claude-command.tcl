#!/usr/bin/env tclsh9.0
# Unit tests for cli/claude_command.tcl: the Claude Code command install. The
# module keeps ~/.claude/commands/questlog.md byte-equal to COMMAND, skips when
# Claude Code is absent or a same-named skill supersedes it, and is idempotent.
# These drive it against a throwaway HOME so the real ~/.claude is untouched.
# Headless, no Tk. Run:
#   tclsh9.0 test/test-claude-command.tcl
package require Tcl 9

set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT cli claude_command.tcl]

set failures 0
proc check {name got want} {
    if {$got eq $want} {
        puts "ok   - $name"
    } else {
        puts "FAIL - $name"
        puts "       got:  $got"
        puts "       want: $want"
        incr ::failures
    }
}

proc read_file {path} {
    set fh [open $path r]
    chan configure $fh -encoding utf-8
    set t [read $fh]
    close $fh
    return $t
}

# ---- COMMAND frontmatter: the trigger surface a Claude Code session reads ----

set C $::questlog::claude::COMMAND
check "COMMAND opens with frontmatter at line 1" \
    [string match "---\nname: questlog\n*" $C] 1
check "COMMAND declares a description" \
    [regexp -line {^description: \S} $C] 1
check "COMMAND closes its frontmatter" \
    [regexp {^---\n.*?\n---\n} $C] 1
check "COMMAND ends with a single trailing newline" \
    [expr {[string index $C end] eq "\n" && [string index $C end-1] ne "\n"}] 1

# ---- Per-case HOME sandbox: the procs read $::env(HOME) live ------------------

set base [file join /tmp questlog-claude-test-[pid]]
file delete -force $base
set saved_home [expr {[info exists ::env(HOME)] ? $::env(HOME) : ""}]

proc use_home {dir} {
    set ::env(HOME) $dir
    file delete -force $dir
    file mkdir $dir
}

# Case 1: no ~/.claude at all -> superseded, refresh writes nothing.
use_home [file join $base no-claude]
check "superseded when ~/.claude is absent" [::questlog::claude::superseded] 1
::questlog::claude::refresh
check "refresh writes nothing without ~/.claude" \
    [file exists [::questlog::claude::command_file]] 0

# Case 2: ~/.claude present, no skill -> refresh installs the command, byte-equal.
use_home [file join $base with-claude]
file mkdir [file join $::env(HOME) .claude]
check "not superseded with ~/.claude and no skill" \
    [::questlog::claude::superseded] 0
::questlog::claude::refresh
set f [::questlog::claude::command_file]
check "refresh creates the command file" [file isfile $f] 1
check "installed file is byte-equal to COMMAND" \
    [read_file $f] $::questlog::claude::COMMAND

# Idempotent: a second refresh leaves the same content; a drifted file is healed.
::questlog::claude::refresh
check "second refresh keeps content equal" \
    [read_file $f] $::questlog::claude::COMMAND
set fh [open $f w]; puts $fh "stale"; close $fh
::questlog::claude::refresh
check "refresh rewrites a drifted file back to COMMAND" \
    [read_file $f] $::questlog::claude::COMMAND

# Case 3: a same-named skill supersedes the command -> refresh leaves it alone.
use_home [file join $base with-skill]
file mkdir [file join $::env(HOME) .claude]
file mkdir [::questlog::claude::skill_dir]
check "superseded when a same-named skill exists" \
    [::questlog::claude::superseded] 1
::questlog::claude::refresh
check "refresh writes no command when a skill supersedes" \
    [file exists [::questlog::claude::command_file]] 0

# ---- Cleanup -----------------------------------------------------------------

if {$saved_home ne ""} { set ::env(HOME) $saved_home }
file delete -force $base

if {$failures > 0} {
    puts "\n$failures test(s) failed"
    exit 1
}
puts "\nAll tests passed"
