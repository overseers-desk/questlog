#!/usr/bin/env tclsh9.0
# Tests for linesman: sweep, rule, and tool_counts over fixture session
# records, covering parity with the audit counts coachman 1.11 carried,
# completeness gaps, compaction, interrupts, Bash opacity, and fork
# children. Run:
#   tclsh9.0 test/test-linesman.tcl
package require Tcl 9
package require json

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require linesman

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

set dir [file tempdir]
set root [file join $dir transcripts]
set proj [file join $root proj-x]
file mkdir $proj

# Write $lines to $path, one JSONL record per line.
proc jfile {path lines} {
    file mkdir [file dirname $path]
    set fd [open $path w]
    foreach l $lines { puts $fd $l }
    close $fd
}

# ── A: parity with coachman 1.11's tool_use_counts ─────────────────────────
# The old audit fixture: two Skill(linkedin) calls and a Bash call in the
# parent, Skill(facebook) in a subagent, a non-tool line, and a
# half-written final line.
jfile [file join $proj sid-a.jsonl] {
    {{"type":"user","message":{"role":"user","content":"go"}}}
    {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"linkedin"}}]}}}
    {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}},{"type":"tool_use","name":"Skill","input":{"skill":"linkedin"}}]}}}
}
set fd [open [file join $proj sid-a.jsonl] a]
puts -nonewline $fd "\{\"type\":\"assistant\",\"half"
close $fd
jfile [file join $proj sid-a subagents agent-1.jsonl] {
    {{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"facebook"}}]}}}
}

set by_name [linesman::tool_counts sid-a $root]
check "counts by name span parent and subagents" \
    [lsort -stride 2 $by_name] {Bash 1 Skill 3}
set by_skill [linesman::tool_counts sid-a $root Skill skill]
check "a named tool counts by the chosen input field" \
    [lsort -stride 2 $by_skill] {facebook 1 linkedin 2}
check "an uninvoked value reads as absent, not zero" \
    [dict exists $by_skill youtube] 0
check "a named tool alone counts under its own name" \
    [linesman::tool_counts sid-a $root Bash] {Bash 1}

set code [catch {linesman::tool_counts sid-none $root} msg opts]
check "a missing transcript raises" $code 1
check "the raise carries the NO_TRANSCRIPT errorcode" \
    [dict get $opts -errorcode] {LINESMAN NO_TRANSCRIPT}

set rec [linesman::sweep sid-a $root]
check "a half-written final line is a truncated_tail gap" \
    [lmap g [dict get $rec gaps] {dict get $g kind}] {truncated_tail}
check "the gap names the file's physical line" \
    [dict get [lindex [dict get $rec gaps] 0] line] 4
check "a record with gaps is not complete" [dict get $rec complete] 0

# ── B: whole record, evidence, forms ───────────────────────────────────────
jfile [file join $proj sid-b.jsonl] {
    {{"type":"user","message":{"role":"user","content":"go"}}}
    {}
    {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"linkedin"}}]}}}
    {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git  status"}},{"type":"tool_use","id":"toolu_b1","name":"Agent","input":{"subagent_type":"Explore","prompt":"look"}}]}}}
}
jfile [file join $proj sid-b subagents agent-1.jsonl] {
    {{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"facebook"}}]}}}
}
jfile [file join $proj sid-b subagents agent-1.meta.json] {
    {{"agentType":"Explore","description":"look","toolUseId":"toolu_b1","spawnDepth":1}}
}

set rec [linesman::sweep sid-b $root]
check "a record with every line parsed and every child present is complete" \
    [dict get $rec complete] 1

set r [linesman::rule $rec -tool Skill]
check "a positive ruling on found acts is yes" [dict get $r verdict] yes
check "the count spans parent and subagents" [dict get $r count] 2
check "evidence lines are physical lines, blanks counted" \
    [lmap e [dict get $r evidence] {dict get $e line}] {3 1}
check "evidence renders the act" \
    [dict get [lindex [dict get $r evidence] 0] rendered] "Skill(skill=linkedin)"

set r [linesman::rule $rec -tool Bash -field command -regexp {^git\y}]
check "a field regexp matches the act's input" [dict get $r verdict] yes
check "rendering collapses whitespace" \
    [dict get [lindex [dict get $r evidence] 0] rendered] "Bash(command=git status)"
check "two acts on one line share the line" \
    [dict get [lindex [dict get $r evidence] 0] line] 4

check "a complete record certifies an absent value as no" \
    [dict get [linesman::rule $rec -tool Skill -field skill -equals youtube] verdict] no
check "-none on an absent tool is yes when complete" \
    [dict get [linesman::rule $rec -tool WebFetch -none] verdict] yes
check "-spawned finds the subagent type" \
    [dict get [linesman::rule $rec -spawned Explore] verdict] yes
check "-spawned -none holds for an unspawned type" \
    [dict get [linesman::rule $rec -spawned general-purpose -none] verdict] yes
check "-atmost within the bound is yes" \
    [dict get [linesman::rule $rec -tool Skill -atmost 2] verdict] yes
check "-atmost over the bound is no" \
    [dict get [linesman::rule $rec -tool Skill -atmost 1] verdict] no

# ── C: a spawned child with no transcript ──────────────────────────────────
jfile [file join $proj sid-c.jsonl] {
    {{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_c1","name":"Agent","input":{"subagent_type":"deep-research","prompt":"dig"}}]}}}
}

set rec [linesman::sweep sid-c $root]
check "a spawn without its child transcript is a missing_child gap" \
    [lmap g [dict get $rec gaps] {dict get $g kind}] {missing_child}
check "the gap names the spawning tool_use id" \
    [dict get [lindex [dict get $rec gaps] 0] tool_use_id] toolu_c1
check "-none cannot certify over the gap" \
    [dict get [linesman::rule $rec -spawned deep-research -none] verdict] no
check "-none on another type degrades to not_provable" \
    [dict get [linesman::rule $rec -spawned general-purpose -none] verdict] not_provable
check "a zero count cannot certify no over the gap" \
    [dict get [linesman::rule $rec -tool WebSearch] verdict] not_provable

# ── D: compaction is not a gap and its prose is not evidence ───────────────
jfile [file join $proj sid-d.jsonl] {
    {{"type":"system","subtype":"compact_boundary","parentUuid":null,"content":"Conversation compacted","compactMetadata":{"trigger":"auto","preTokens":150000}}}
    {{"type":"user","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"role":"user","content":[{"type":"text","text":"Earlier the session invoked the Skill tool with skill linkedin twice."}]}}}
    {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"linkedin"}}]}}}
}

set rec [linesman::sweep sid-d $root]
check "compaction is not a gap" [dict get $rec complete] 1
check "summary prose is never evidence" \
    [linesman::tool_counts sid-d $root Skill skill] {linkedin 1}

# ── E: an interrupted act counts as issued and says so ─────────────────────
jfile [file join $proj sid-e.jsonl] {
    {{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_e1","name":"Write","input":{"file_path":"/seg/out.md","content":"draft"}}]}}}
    {{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_e1","content":"[Request interrupted by user]"}]}}}
}

set rec [linesman::sweep sid-e $root]
check "the cut-short call lands in interrupts" \
    [lmap i [dict get $rec interrupts] {dict get $i tool_use_id}] {toolu_e1}
check "an interrupted act still counts as issued" \
    [linesman::tool_counts sid-e $root Write] {Write 1}
set r [linesman::rule $rec -wrote "/seg/*"]
check "found evidence rules yes regardless" [dict get $r verdict] yes
check "the rendering says the call was cut short" \
    [string match "*(interrupted)" [dict get [lindex [dict get $r evidence] 0] rendered]] 1

# ── F: Bash opacity ────────────────────────────────────────────────────────
jfile [file join $proj sid-f.jsonl] {
    {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo x > /seg/out.md"}}]}}}
}
jfile [file join $proj sid-f2.jsonl] {
    {{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"linkedin"}}]}}}
}

set rec [linesman::sweep sid-f $root]
check "a -wrote absence beside Bash degrades to not_provable" \
    [dict get [linesman::rule $rec -wrote "/seg/*" -none] verdict] not_provable
check "the ruling carries the Bash count" \
    [dict get [linesman::rule $rec -wrote "/seg/*" -none] bash_ran] 1
check "-ignorebash scopes the ruling to tool events" \
    [dict get [linesman::rule $rec -wrote "/seg/*" -none -ignorebash] verdict] yes
check "a Bash-free record certifies the -wrote absence" \
    [dict get [linesman::rule [linesman::sweep sid-f2 $root] -wrote "/seg/*" -none] verdict] yes

# ── G: fork children belong to the record ──────────────────────────────────
jfile [file join $proj sid-g.jsonl] {
    {{"type":"user","message":{"role":"user","content":"go"}}}
}
jfile [file join $proj sid-g subagents agent-afork-1.jsonl] {
    {{"type":"fork-context-ref","agentId":"afork1","parentSessionId":"sid-g","parentLastUuid":"u1","contextLength":5}}
    {{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"linkedin"}}]}}}
}
jfile [file join $proj sid-g subagents agent-afork-1.meta.json] {
    {{"agentType":"fork","isFork":true,"description":"forked look","name":"look","spawnDepth":1}}
}

set rec [linesman::sweep sid-g $root]
check "a fork child with no toolUseId is not a gap" [dict get $rec complete] 1
check "a fork child's acts are the session's acts" \
    [linesman::tool_counts sid-g $root Skill skill] {linkedin 1}

file delete -force $dir

if {$failures == 0} {
    puts "\nAll tests passed."
} else {
    puts "\n$failures test(s) failed."
    exit 1
}
