#!/usr/bin/env tclsh9.0
# Tests for helmsman's interactive session driver against a fake claude
# that speaks bidirectional stream-json: streamed deltas then done, a
# tool event inside a turn, a permission parked and answered (allow and
# deny), an AskUserQuestion parked and answered with answers, a second
# typed turn queued behind the first, resume-by-id, and close. Run:
#   tclsh9.0 test/test-helmsman.tcl
package require Tcl 9
package require json

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require helmsman

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
proc write_file {path content} {
    set fd [open $path w]
    puts -nonewline $fd $content
    close $fd
}
proc read_file {path} {
    set fd [open $path r]
    set s [read $fd]
    close $fd
    return $s
}

# await - run the event loop until the expr $cond (evaluated in the
# caller's scope) is true; 1 on success, 0 on timeout. helmsman is
# entirely event-loop driven, so every assertion on arriving events
# rides this.
proc await {cond {timeout 10000}} {
    set deadline [expr {[clock milliseconds] + $timeout}]
    while {![uplevel 1 [list expr $cond]]} {
        if {[clock milliseconds] > $deadline} { return 0 }
        after 20 {set ::_tick 1}
        vwait ::_tick
    }
    return 1
}

# The collected events, and filters over them.
set events {}
proc on_event {ev} { lappend ::events $ev }
proc evs {type} {
    set out {}
    foreach ev $::events {
        if {[dict get $ev type] eq $type} { lappend out $ev }
    }
    return $out
}
proc n_evs {type} { return [llength [evs $type]] }
proc last_ev {type} { return [lindex [evs $type] end] }

set QUIET [logger::init helmsman-test-quiet]
${QUIET}::setlevel critical

# write_fake - a stand-in claude CLI for the INTERACTIVE wire: appends
# its argv to FAKE_ARGV_LOG, emits the init record, then serves user
# messages read from stdin. Every line either way lands in
# FAKE_WIRE_LOG ("<< " received, ">> " sent) so tests can assert the
# exact control_response payloads and their ordering. The user text is
# the script: "stream X" streams deltas then settles the turn, "tooluse"
# emits a tool_use block, "tool" parks a Bash can_use_tool and waits,
# "question" parks an AskUserQuestion and waits, anything else echoes.
proc write_fake {dir} {
    set path [file join $dir claude]
    write_file $path {#!/usr/bin/env tclsh9.0
package require json
set wire [open $::env(FAKE_WIRE_LOG) a]
fconfigure $wire -buffering line
fconfigure stdout -buffering none
set af [open $::env(FAKE_ARGV_LOG) a]
puts $af $::argv
close $af
proc emit {line} {
    puts $::wire ">> $line"
    puts stdout $line
}
proc say {text} {
    emit "{\"type\":\"assistant\",\"message\":{\"content\":\[{\"type\":\"text\",\"text\":\"$text\"}\]},\"session_id\":\"$::sid\"}"
}
proc result {} {
    emit "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"ok\",\"total_cost_usd\":0.01,\"session_id\":\"$::sid\"}"
}
proc await_control {} {
    while {[gets stdin line] >= 0} {
        puts $::wire "<< $line"
        if {[catch {set d [json::json2dict $line]}]} continue
        if {[dict getdef $d type ""] eq "control_response"} { return $d }
    }
    exit 0
}
set sid sid-live-1
foreach a $::argv {
    if {[string match --resume=* $a]} { set sid sid-resumed }
}
emit "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$sid\"}"
set creq 0
while {[gets stdin line] >= 0} {
    puts $::wire "<< $line"
    if {[catch {set d [json::json2dict $line]}]} continue
    if {[dict getdef $d type ""] ne "user"} continue
    set text [dict get $d message content]
    switch -glob -- $text {
        {stream *} {
            set what [string range $text 7 end]
            emit "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hel\"}},\"session_id\":\"$sid\"}"
            emit "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"lo $what\"}},\"session_id\":\"$sid\"}"
            after 120
            say "Hello $what"
            result
        }
        tooluse {
            emit "{\"type\":\"assistant\",\"message\":{\"content\":\[{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"Read\",\"input\":{\"file_path\":\"/etc/hosts\"}},{\"type\":\"text\",\"text\":\"read it\"}\]},\"session_id\":\"$sid\"}"
            result
        }
        tool {
            incr creq
            emit "{\"type\":\"control_request\",\"request_id\":\"creq_$creq\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"Bash\",\"input\":{\"command\":\"ls /tmp\"},\"tool_use_id\":\"toolu_b$creq\"}}"
            set r [await_control]
            set b [dict get $r response response behavior]
            if {$b eq "allow"} { say "bash allowed" } else { say "bash denied" }
            result
        }
        question {
            incr creq
            emit "{\"type\":\"control_request\",\"request_id\":\"creq_$creq\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"AskUserQuestion\",\"input\":{\"questions\":\[{\"question\":\"Which colour?\",\"header\":\"Colour\",\"options\":\[{\"label\":\"red\"},{\"label\":\"blue\"}\],\"multiSelect\":false}\]},\"tool_use_id\":\"toolu_q$creq\"}}"
            set r [await_control]
            set choice none
            catch {
                set choice [dict get $r response response updatedInput answers {Which colour?}]
            }
            say "chose: $choice"
            result
        }
        default {
            say "echo: $text"
            result
        }
    }
}
}
    file attributes $path -permissions 0o755
    return $path
}

# The subclass under test: the fake binary via the inherited claude_bin
# seam, and a quiet logger.
oo::class create FakeSession {
    superclass helmsman::Session
    method log_service {} { return $::QUIET }
    method claude_bin {} { return $::FAKE }
}

set dir [file tempdir]
set FAKE [write_fake $dir]
set logd [file join $dir logs]
set pdir [file join $dir row-1]
file mkdir $pdir
set ::env(FAKE_ARGV_LOG) [file join $dir argv.log]
set ::env(FAKE_WIRE_LOG) [file join $dir wire.log]

# ---- raw JSON helpers ------------------------------------------------------

# The fixtures carry an unbalanced brace inside a string and a decoy
# "input" inside a value; built with escapes because a braced Tcl word
# cannot hold an unbalanced brace.
set nested_raw "\{\"a\":1,\"input\":\{\"x\":\"y\{z\",\"n\":\[1,2\]\},\"b\":true\}"
check "raw_get returns a nested object byte-true" \
    [helmsman::raw_get $nested_raw input] "\{\"x\":\"y\{z\",\"n\":\[1,2\]\}"
set decoy_raw "\{\"a\":\"\\\"input\\\": trap\",\"input\":\{\"k\":1\}\}"
check "raw_get skips a key named inside a string value" \
    [helmsman::raw_get $decoy_raw input] "\{\"k\":1\}"
check "raw_get on an absent key is empty" \
    [helmsman::raw_get "\{\"a\":1\}" input] {}
check "label is tool and first line of the leading input value" \
    [helmsman::label Bash {command "ls /tmp\nrm x"}] "Bash — ls /tmp"
check "label without input is the bare tool name" \
    [helmsman::label WebSearch {}] WebSearch

# ---- open: argv and the init session event ---------------------------------

set s [FakeSession new $pdir $logd on_event]
$s open
check "open reports open" [$s is_open] 1
check "the init session event arrives" \
    [await {[n_evs session] >= 1}] 1
check "the session event carries the live id" \
    [dict get [last_ev session] session_id] sid-live-1
check "session_id re-stamps to the live id" [$s session_id] sid-live-1

set a [lindex [split [string trim [read_file $::env(FAKE_ARGV_LOG)]] \n] 0]
check "stream-json rides both directions" \
    [expr {[lsearch -exact $a --input-format] >= 0
        && [lsearch -exact $a --output-format] >= 0}] 1
check "permission decisions route over stdio" \
    [expr {[lsearch -exact $a --permission-prompt-tool] >= 0
        && [lsearch -exact $a stdio] >= 0}] 1
check "partial messages are requested" \
    [expr {[lsearch -exact $a --include-partial-messages] >= 0}] 1
check "the model defaults to sonnet" \
    [expr {[lsearch -exact $a sonnet] >= 0}] 1

# ---- a streamed turn: deltas then done -------------------------------------

set tid [$s send "stream world"]
check "send returns the operator turn id" $tid 1
check "the operator turn event is immediate and done" \
    [dict get [lindex [evs turn] 0] role],[dict get [lindex [evs turn] 0] done] \
    operator,1
check "the settled assistant turn arrives" \
    [await {[llength [evs turn]] > 0
        && [dict get [last_ev turn] role] eq "assistant"
        && [dict get [last_ev turn] done]}] 1
set partials {}
foreach ev [evs turn] {
    if {[dict get $ev role] eq "assistant" && ![dict get $ev done]} {
        lappend partials $ev
    }
}
check "at least one streamed partial preceded it" \
    [expr {[llength $partials] >= 1}] 1
check "the partial repeats the whole text so far (a prefix of the final)" \
    [string equal [string range "Hello world" 0 \
        [expr {[string length [dict get [lindex $partials 0] text]] - 1}]] \
        [dict get [lindex $partials 0] text]] 1
check "the settled turn carries the authoritative text" \
    [dict get [last_ev turn] text] "Hello world"
check "the result re-stamps the session (end-of-response signal)" \
    [expr {[n_evs session] >= 2}] 1

# ---- a tool use inside a turn ----------------------------------------------

$s send tooluse
check "the tool event arrives" [await {[n_evs tool] >= 1}] 1
check "the tool label names the call" \
    [dict get [last_ev tool] label] "Read — /etc/hosts"
check "the tool turn's settled text follows" \
    [await {[dict get [last_ev turn] text] eq "read it"}] 1

# ---- a permission parks, allowing resumes ----------------------------------

$s send tool
check "the permission parks" [await {[n_evs permission] >= 1}] 1
set perm [last_ev permission]
check "the permission names the tool" [dict get $perm tool_name] Bash
check "the permission carries a label" \
    [dict get $perm label] "Bash — ls /tmp"
check "the prompt is listed as pending" \
    [dict get [lindex [$s pending_prompts] 0] kind] permission
$s answer_permission [dict get $perm req_id] 1
check "allowing resumes the session" \
    [await {[dict get [last_ev turn] text] eq "bash allowed"}] 1
check "the answered prompt leaves pending" [llength [$s pending_prompts]] 0

set resp_lines {}
foreach l [split [read_file $::env(FAKE_WIRE_LOG)] \n] {
    if {[string match {<< *control_response*} $l]} {
        lappend resp_lines [string range $l 3 end]
    }
}
set r [json::json2dict [lindex $resp_lines 0]]
check "the allow reply is a success control_response" \
    [dict get $r response subtype],[dict get $r response request_id] \
    success,creq_1
check "the allow reply answers behavior allow" \
    [dict get $r response response behavior] allow
check "updatedInput echoes the original input byte-true" \
    [dict get $r response response updatedInput] [dict create command "ls /tmp"]

# ---- a permission denied ---------------------------------------------------

$s send tool
check "a second permission parks" [await {[n_evs permission] >= 2}] 1
$s answer_permission [dict get [last_ev permission] req_id] 0 "not today"
check "denying resumes the session too" \
    [await {[dict get [last_ev turn] text] eq "bash denied"}] 1
set resp_lines {}
foreach l [split [read_file $::env(FAKE_WIRE_LOG)] \n] {
    if {[string match {<< *control_response*} $l]} {
        lappend resp_lines [string range $l 3 end]
    }
}
set r [json::json2dict [lindex $resp_lines 1]]
check "the deny reply answers behavior deny with the message" \
    [dict get $r response response behavior],[dict get $r response response message] \
    "deny,not today"

# ---- an AskUserQuestion parks, the answers resume --------------------------

$s send question
check "the question parks" [await {[n_evs question] >= 1}] 1
set q [last_ev question]
set q1 [lindex [dict get $q questions] 0]
check "the question event carries the questions array" \
    [dict get $q1 question] "Which colour?"
set labels {}
foreach o [dict get $q1 options] { lappend labels [dict get $o label] }
check "with its options" $labels {red blue}
$s answer_question [dict get $q req_id] [dict create "Which colour?" blue]
check "answering the question resumes the session" \
    [await {[dict get [last_ev turn] text] eq "chose: blue"}] 1
set resp_lines {}
foreach l [split [read_file $::env(FAKE_WIRE_LOG)] \n] {
    if {[string match {<< *control_response*} $l]} {
        lappend resp_lines [string range $l 3 end]
    }
}
set r [json::json2dict [lindex $resp_lines 2]]
set upd [dict get $r response response updatedInput]
check "the question reply is allow, not a bare permission verdict" \
    [dict get $r response response behavior] allow
check "the answers record maps question text to the answer" \
    [dict get $upd answers] [dict create "Which colour?" blue]
check "the original questions ride along in updatedInput" \
    [dict get [lindex [dict get $upd questions] 0] question] "Which colour?"

# ---- a second typed turn queues behind the first ---------------------------

set before [llength [evs turn]]
$s send "stream one"
$s send "stream two"
check "the second send queues while the first is in flight" [$s queued] 1
check "both replies settle, in order" \
    [await {[dict get [last_ev turn] text] eq "Hello two"
        && [dict get [last_ev turn] done]}] 1
set texts {}
foreach ev [lrange [evs turn] $before end] {
    if {[dict get $ev role] eq "assistant" && [dict get $ev done]} {
        lappend texts [dict get $ev text]
    }
}
check "the first reply preceded the second" $texts {{Hello one} {Hello two}}
check "the queue drained" [$s queued] 0

# ---- snapshot --------------------------------------------------------------

set roles {}
foreach row [$s snapshot] { lappend roles [dict get $row role] }
check "the snapshot holds operator, assistant and tool rows" \
    [expr {"operator" in $roles && "assistant" in $roles && "tool" in $roles}] 1

# ---- close -----------------------------------------------------------------

$s close
check "close ends in exactly one closed event" \
    [await {[n_evs closed] == 1}] 1
check "a graceful close is not an error" [n_evs error] 0
check "the session reports closed" [$s is_open] 0

# ---- resume-by-id ----------------------------------------------------------

set events {}
set s2 [FakeSession new $pdir $logd on_event]
$s2 open -resume sid-old
check "the resumed session announces itself" \
    [await {[n_evs session] >= 1}] 1
check "the resumed session's id is the forked one" \
    [dict get [last_ev session] session_id] sid-resumed
set lines [split [string trim [read_file $::env(FAKE_ARGV_LOG)]] \n]
check "the child was resumed by id" \
    [expr {[lsearch -exact [lindex $lines end] --resume=sid-old] >= 0}] 1
$s2 close
check "the resumed session closes" [await {[n_evs closed] == 1}] 1

file delete -force $dir

if {$failures == 0} {
    puts "\nAll tests passed."
} else {
    puts "\n$failures test(s) failed."
    exit 1
}
