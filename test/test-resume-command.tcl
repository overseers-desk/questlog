#!/usr/bin/env tclsh9.0
# Verify the one-shot resume command builder and the permission-mode flag map.
# A -p resume turn cannot answer a permission prompt, so the flags grant tool
# access up front; the command shell-quotes the cwd and prompt and carries cd
# (claude has no cwd flag).

package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT ui terminal.tcl]

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name  expected=<$expected>  actual=<$actual>"
        incr ::fails
    } else {
        puts "ok:   $name"
    }
}

# ---- permission_flags --------------------------------------------------
check perm_readonly "--permission-mode default" \
    [::questlog::ui::terminal::permission_flags readonly]
check perm_unknown_falls_back "--permission-mode default" \
    [::questlog::ui::terminal::permission_flags whatever]
check perm_edits "--permission-mode acceptEdits" \
    [::questlog::ui::terminal::permission_flags edits]
check perm_edits_git {--permission-mode acceptEdits --allowedTools "Bash(git*)"} \
    [::questlog::ui::terminal::permission_flags edits-git]
check perm_full "--dangerously-skip-permissions" \
    [::questlog::ui::terminal::permission_flags full]

# ---- oneshot_command ---------------------------------------------------
check cmd_plain \
    {cd '/home/me/code' && claude -p --resume abc123 --permission-mode default 'do the thing'} \
    [::questlog::ui::terminal::oneshot_command /home/me/code abc123 "do the thing" \
        [::questlog::ui::terminal::permission_flags readonly]]

# cwd with a space stays one shell word.
check cmd_cwd_space \
    {cd '/home/a b/code' && claude -p --resume u1 --permission-mode acceptEdits 'hi'} \
    [::questlog::ui::terminal::oneshot_command "/home/a b/code" u1 "hi" \
        [::questlog::ui::terminal::permission_flags edits]]

# An apostrophe in the prompt is single-quote escaped ('\'').
check cmd_prompt_apostrophe \
    {cd '/p' && claude -p --resume u2 --dangerously-skip-permissions 'it'\''s done'} \
    [::questlog::ui::terminal::oneshot_command /p u2 "it's done" \
        [::questlog::ui::terminal::permission_flags full]]

# The git flags pass through verbatim, parens kept inside double quotes.
check cmd_edits_git \
    {cd '/p' && claude -p --resume u3 --permission-mode acceptEdits --allowedTools "Bash(git*)" 'commit it'} \
    [::questlog::ui::terminal::oneshot_command /p u3 "commit it" \
        [::questlog::ui::terminal::permission_flags edits-git]]

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
