#!/usr/bin/env tclsh9.0
# Unit tests for cli/main.tcl's --markdown serializer. It renders the same
# folders/sessions/subagents/matches model --json emits, as a readable document:
# folder headers, a session title and identity line, each hit an anchored
# snippet, subagents nested. The unpriced-cost sentinel (-1.0) renders as no cost
# figure, the markdown twin of --json's null. Run:
#   tclsh9.0 test/test-cli-markdown.tcl
package require Tcl 9

set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT cli main.tcl]
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

# One folder, one priced session carrying a hit and one unpriced (-1.0) subagent
# that also carries a hit.
set folders [dict create proj-folder [dict create \
    project_path /home/user/proj \
    sessions [list \
        [dict create uuid s1 path /p/s1.jsonl title "Real Work" \
            first_ts 2026-06-02T13:00:00.000Z cost_usd 0.4216 turns 5 \
            duration_secs 600 human_secs 120 \
            matches [list [dict create line 12 type assistant \
                content "a hit on scan_file here"]] \
            subagents [list \
                [dict create agent_id a1 agent_type Explore description "scout the code" \
                    cost_usd -1.0 turns 2 duration_secs "" human_secs "" \
                    matches [list [dict create line 3 type tool_use \
                        content "Bash(command=grep scan_file)"]]]]]]]]

set out [::questlog::cli::main::format_markdown $folders]

check "markdown: the project path heads the folder" \
    [regexp -- {(?m)^# /home/user/proj$} $out] 1
check "markdown: the session title is an h2" \
    [regexp -- {(?m)^## Real Work$} $out] 1
check "markdown: the session identity line carries uuid, ts, turns and cost" \
    [regexp -- {s1 · 2026-06-02T13:00:00.000Z · 5 turns · \$0.42} $out] 1
check "markdown: the session path is a backticked line" \
    [regexp -- {`/p/s1.jsonl`} $out] 1
check "markdown: a hit renders as an anchored snippet bullet" \
    [regexp -- {- \*\*\[#12\] assistant\*\* a hit on scan_file here} $out] 1
check "markdown: a subagent nests under its parent" \
    [regexp -- {(?m)^### subagent Explore: scout the code$} $out] 1
check "markdown: an unpriced subagent shows turns but no cost figure" \
    [regexp -- {a1 · 2 turns\n} $out] 1
check "markdown: the -1.0 sentinel never reaches the page" \
    [regexp -- {-1} $out] 0
check "markdown: the subagent's own hit renders" \
    [regexp -- {- \*\*\[#3\] tool_use\*\* Bash\(command=grep scan_file\)} $out] 1

# ---- context: a match with a window renders full turns, the hit tagged ------

# Under -A/-B/-C a match carries a window instead of just a snippet: its whole
# messages as **[#N] ROLE** blocks, the hit tagged (match), the run closed by a
# rule. The full body is shown, not the char-window snippet.
set wfolders [dict create f [dict create project_path /p sessions [list \
    [dict create uuid s path /p/s.jsonl title "T" first_ts "" cost_usd "" turns 2 \
        duration_secs "" human_secs "" subagents {} \
        matches [list [dict create line 40 type assistant content "snip" window [list \
            [dict create line 38 role USER text "the question" match 0] \
            [dict create line 40 role ASSISTANT text "the full reply" match 1]]]]]]]]
set wout [::questlog::cli::main::format_markdown $wfolders]
check "markdown window: a context turn is a full anchored role block" \
    [regexp -- {(?m)^\*\*\[#38\] USER\*\*$} $wout] 1
check "markdown window: the hit turn is tagged (match)" \
    [regexp -- {(?m)^\*\*\[#40\] ASSISTANT \(match\)\*\*$} $wout] 1
check "markdown window: the full body is rendered" \
    [regexp -- {the full reply} $wout] 1
check "markdown window: no snippet bullet stands in for a windowed match" \
    [regexp -- {- \*\*\[#40\]} $wout] 0

if {$failures == 0} {
    puts "\nAll tests passed."
} else {
    puts "\n$failures test(s) failed."
    exit 1
}
