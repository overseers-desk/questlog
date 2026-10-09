#!/usr/bin/env wish9.0
# The conversation UI class: the driver-agnostic surface composing the
# showman transcript, the prompt strip and the input strip around the
# one -on_send seam.
#
# Part A drives the render surface directly with the record-grade shapes
# (text turn, tool_use, tool_result, thinking) and asserts the repaint
# idempotency: repeated frames render nothing twice. Part B wires a real
# helmsman::Session behind the seam against the fake claude CLI (the
# claude_bin seam - no real CLI): a typed line leaves through the entry,
# the streamed reply renders once, a tool folds as detail, a permission
# and a question are answered by clicking the parked rows, a typed
# follow-up continues the session, and close disables the input.
#
# Runs under wish (it builds a Tk view); run-audit routes it to wish9.0 on
# the private Xvfb. Standalone: xvfb-run -a wish9.0 test/test-conversation.tcl

package require Tcl 9
package require Tk
package require json

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require helmsman
source [file join $ROOT ui conversation.tcl]

set fails 0
proc check {name got want} {
    if {$got eq $want} {
        puts "ok   - $name"
    } else {
        puts "FAIL - $name"
        puts "       got:  $got"
        puts "       want: $want"
        incr ::fails
    }
}
proc write_file {path content} {
    set fd [open $path w]
    puts -nonewline $fd $content
    close $fd
}

# await - run the event loop until the expr $cond (evaluated in the
# caller's scope) is true; 1 on success, 0 on timeout.
proc await {cond {timeout 10000}} {
    set deadline [expr {[clock milliseconds] + $timeout}]
    while {![uplevel 1 [list expr $cond]]} {
        if {[clock milliseconds] > $deadline} { return 0 }
        after 20 {set ::_tick 1}
        vwait ::_tick
    }
    return 1
}

# ============================================================================
# Part A - the render surface and the seam, no driver.
# ============================================================================

set sent {}
proc collect {ev} { lappend ::sent $ev }

ttk::frame .a
set C [::questlog::ui::Conversation new .a -on_send collect]
pack .a -fill both -expand 1
update idletasks

set V [$C viewer]
set T [$V textwidget]

# Visible characters of a term's first occurrence: 0 while elided, -1 absent.
proc vischars {term} {
    set m [$::T search -elide -- $term 1.0 end]
    if {$m eq ""} { return -1 }
    return [$::T count -displaychars $m "$m + [string length $term]c"]
}
# A region's stub line text ("" while no summary line stands).
proc stubline {n} {
    set s [dict get [$::V region_info $n] summary]
    if {$s eq ""} { return "" }
    return [$::T get $s "$s lineend"]
}

# ---- an assistant frame needs an exchange -----------------------------------
check "an assistant turn with no open exchange errors" \
    [catch {$C turn 99 assistant "orphan" 0}] 1

# ---- the operator's turn opens the exchange, once ---------------------------
$C turn 1 operator "What is in /etc?" 1
update idletasks
check "the operator's turn opens an exchange" [$V region_count] 1
check "its prompt renders visible" [expr {[vischars "What is in /etc?"] > 0}] 1
$C turn 1 operator "What is in /etc?" 1
check "a repeated operator frame opens nothing" [$V region_count] 1

# ---- assistant repaint frames replace, done finalizes -----------------------
$C turn 2 assistant "Let me" 0
$C turn 2 assistant "Let me look at" 0
$C turn 2 assistant "Let me look at the folder." 1
update idletasks
check "repaint frames render the text exactly once" \
    [llength [$V collect_matches "Let me look at the folder."]] 1
$C turn 2 assistant "Let me look at the folder." 1
update idletasks
check "a frame after done=1 is dropped" \
    [llength [$V collect_matches "Let me look at the folder."]] 1

# ---- record-grade detail: tool_use, tool_result, thinking -------------------
$C tool_use 2 1 Read [dict create file_path /etc/hosts]
$C tool_result 2 1 "127.0.0.1 localhost" 0
$C thinking 2 1 "pondering the folder"
update idletasks
check "the tool call renders as hidden detail" \
    [vischars "Read(file_path=/etc/hosts)"] 0
check "the tool result is hidden detail too" [vischars "127.0.0.1"] 0
check "thinking is hidden detail too" [vischars "pondering the folder"] 0
check "the stub tallies the detail" [stubline 0] \
    "▸ · 1 tool call · 1 thinking"
$C tool_use 2 1 Read [dict create file_path /etc/hosts]
$C tool_result 2 1 "127.0.0.1 localhost" 0
$C thinking 2 1 "pondering the folder"
update idletasks
check "repeated detail frames render nothing twice" [stubline 0] \
    "▸ · 1 tool call · 1 thinking"
$V detail_show 0
update idletasks
check "unfolding reveals the tool line" \
    [expr {[vischars "Read(file_path=/etc/hosts)"] > 0}] 1
$V detail_hide 0

# ---- working marker and the host's note -------------------------------------
$C working 1
update idletasks
check "working rides the stub" [stubline 0] \
    "▸ · 1 tool call · 1 thinking · working…"
$C working 0
$C note "driver hiccup, retrying"
update idletasks
check "a note renders as a visible SYSTEM line" \
    [expr {[vischars "driver hiccup, retrying"] > 0}] 1

# ---- the typed line leaves through the seam ---------------------------------
set E .a.input.e
.a.input.send invoke
check "an empty entry sends nothing" [llength $sent] 0
$E insert 0 "  tell me more  "
.a.input.send invoke
check "the typed line leaves trimmed through the seam" \
    [lindex $sent end] [dict create type send text "tell me more"]
check "the entry clears on send" [$E get] ""
check "the surface renders no echo of its own" [vischars "tell me more"] -1

# ---- the permission row -----------------------------------------------------
$C prompt_permission req-1 Bash [dict create command "ls /tmp"]
update idletasks
check "the permission parks" [$C prompts] req-1
set row [lindex [winfo children .a.prompts] 0]
check "the row names the call" [$row.lbl cget -text] \
    "Permission: Bash(command=ls /tmp)"
$C prompt_permission req-1 Bash [dict create command "ls /tmp"]
check "a repeated permission frame parks nothing twice" \
    [llength [winfo children .a.prompts]] 1
$row.deny invoke
check "deny leaves through the seam" [lindex $sent end] \
    [dict create type permission req_id req-1 allow 0]
check "the decided row is gone" [$C prompts] {}

# ---- the question row -------------------------------------------------------
set questions [list \
    [dict create question "Which colour?" header "Colour" \
        options [list [dict create label red] [dict create label blue]] \
        multiSelect false] \
    [dict create question "Which sizes?" header "Size" \
        options [list [dict create label S] [dict create label M]] \
        multiSelect true]]
$C prompt_question req-2 $questions
update idletasks
set row [lindex [winfo children .a.prompts] 0]
set before [llength $sent]
$row.answer invoke
check "an unanswered question refuses to leave" [llength $sent] $before
check "the refusing row stays parked" [$C prompts] req-2
$row.q0.o1 invoke          ;# blue
$row.q1.o0 invoke          ;# S
$row.q1.o1 invoke          ;# M
$row.answer invoke
set ev [lindex $sent end]
check "the answers leave through the seam" [dict get $ev type],[dict get $ev req_id] \
    question,req-2
check "single-select maps question text to the label" \
    [dict get $ev answers "Which colour?"] blue
check "multi-select labels are comma-joined" \
    [dict get $ev answers "Which sizes?"] "S, M"
check "the answered row is gone" [$C prompts] {}

# ---- prompt_dismiss (the driver withdrew it) --------------------------------
$C prompt_permission req-3 Read [dict create file_path /etc/passwd]
$C prompt_dismiss req-3
update idletasks
check "a dismissed prompt leaves without emitting" [$C prompts] {}

# ---- view-only toggle and closed --------------------------------------------
$C input_show 0
update idletasks
check "input_show 0 hides the strip" [winfo ismapped .a.input] 0
$C input_show 1
update idletasks
check "input_show 1 restores it" [winfo ismapped .a.input] 1

$C prompt_permission req-4 Bash [dict create command "sleep 9"]
$E insert 0 "leftover line"
set before [llength $sent]
$C closed
update idletasks
check "closed seals the open exchange" [$V live] -1
check "closed drops every parked prompt" [$C prompts] {}
check "closed disables the input" [$E instate disabled] 1
.a.input.send invoke
check "a click on the disabled strip sends nothing" [llength $sent] $before

# View-only construction: no seam, no input strip from the start.
ttk::frame .ro
set RO [::questlog::ui::Conversation new .ro -input 0]
pack .ro -fill both -expand 1
update idletasks
check "-input 0 starts with the strip hidden" [winfo ismapped .ro.input] 0
$RO turn 1 user "read-only prompt" 1
update idletasks
check "a view-only surface still renders turns" [[$RO viewer] region_count] 1
$RO destroy
destroy .ro

# ---- a streamed table stays text until the message settles -------------------
# A grid rebuilt on every repaint frame blanks and jumps its columns.
ttk::frame .tb
set TB [::questlog::ui::Conversation new .tb -input 0]
pack .tb -fill both -expand 1
set TV [$TB viewer]
set TT [$TV textwidget]
set table "Here:\n\n| a | b |\n|---|---|\n| one | two |\n| three | four |\n"
$TB turn 1 user "a table please" 1
foreach n [list 12 24 [string length $table]] {
    $TB turn 2 assistant [string range $table 0 $n-1] 0
    update
}
check "mid-stream the table is text, no grid" \
    [list [llength [winfo children $TT]] \
          [expr {[$TT search -- "| three | four |" 1.0 end] ne ""}]] {0 1}
$TV live_close
update
after idle {set ::idled 1}; vwait ::idled
check "after close the table is exactly one grid" \
    [list [llength [winfo children $TT]] \
          [expr {[llength [$TT dump -window 1.0 end]] / 3}] \
          [expr {[$TT search -- "| three | four |" 1.0 end] ne ""}]] {1 1 0}
$TB destroy
destroy .tb

# ============================================================================
# Part B - helmsman behind the seam, against the fake claude CLI.
# ============================================================================

# The fake claude for the interactive wire, as test-helmsman proves it:
# emits init, then serves user messages from stdin. "stream X" streams
# deltas then settles; "tooluse" emits a tool_use block inside a turn;
# "tool" parks a Bash can_use_tool and waits; "question" parks an
# AskUserQuestion and waits; anything else echoes.
proc write_fake {dir} {
    set path [file join $dir claude]
    write_file $path {#!/usr/bin/env tclsh9.0
package require json
fconfigure stdout -buffering none
proc emit {line} { puts stdout $line }
proc say {text} {
    emit "{\"type\":\"assistant\",\"message\":{\"content\":\[{\"type\":\"text\",\"text\":\"$text\"}\]},\"session_id\":\"$::sid\"}"
}
proc result {} {
    emit "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"ok\",\"total_cost_usd\":0.01,\"session_id\":\"$::sid\"}"
}
proc await_control {} {
    while {[gets stdin line] >= 0} {
        if {[catch {set d [json::json2dict $line]}]} continue
        if {[dict getdef $d type ""] eq "control_response"} { return $d }
    }
    exit 0
}
set sid sid-conv-1
emit "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$sid\"}"
set creq 0
while {[gets stdin line] >= 0} {
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

set QUIET [logger::init conversation-test-quiet]
${QUIET}::setlevel critical
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

# The glue, exactly as the module header sketches it: helmsman's events
# drive the render surface; the seam's intents drive helmsman.
set events {}
proc n_evs {type} {
    set n 0
    foreach ev $::events {
        if {[dict get $ev type] eq $type} { incr n }
    }
    return $n
}
proc last_ev {type} {
    set out {}
    foreach ev $::events {
        if {[dict get $ev type] eq $type} { set out $ev }
    }
    return $out
}
proc glue_send {ev} {
    switch -- [dict get $ev type] {
        send       { $::S send [dict get $ev text] }
        permission { $::S answer_permission [dict get $ev req_id] \
                         [dict get $ev allow] }
        question   { $::S answer_question [dict get $ev req_id] \
                         [dict get $ev answers] }
    }
}
proc glue_event {ev} {
    lappend ::events $ev
    set c $::B
    switch -- [dict get $ev type] {
        turn       { $c turn [dict get $ev turn_id] [dict get $ev role] \
                         [dict get $ev text] [dict get $ev done]
                     $c working [expr {![dict get $ev done]}] }
        tool       { $c tool_use [dict get $ev turn_id] [dict get $ev k] \
                         [dict get $ev name] [dict get $ev input] }
        permission { $c prompt_permission [dict get $ev req_id] \
                         [dict get $ev tool_name] [dict get $ev input] }
        question   { $c prompt_question [dict get $ev req_id] \
                         [dict get $ev questions] }
        permission_resolved { $c prompt_dismiss [dict get $ev req_id] }
        error      { $c note [dict get $ev message] }
        closed     { $c closed }
    }
}

destroy .a
ttk::frame .b
set B [::questlog::ui::Conversation new .b -on_send glue_send]
pack .b -fill both -expand 1
update idletasks
set BV [$B viewer]
set T [$BV textwidget]
set V $BV     ;# vischars/stubline read ::T and ::V
set BE .b.input.e

set S [FakeSession new $pdir $logd glue_event]
$S open
check "the live session opens" [await {[n_evs session] >= 1}] 1

# ---- a typed line: echo renders, the streamed reply settles once ------------
$BE insert 0 "stream world"
.b.input.send invoke
update idletasks
check "the typed line echoes as the operator's turn" \
    [expr {[vischars "stream world"] > 0}] 1
check "the echo opened the exchange" [expr {[$BV live] >= 0}] 1
check "the streamed reply settles" \
    [await {[llength [last_ev turn]] && [dict get [last_ev turn] done]
        && [dict get [last_ev turn] text] eq "Hello world"}] 1
set partials 0
foreach ev $events {
    if {[dict get $ev type] eq "turn" && [dict get $ev role] eq "assistant" \
            && ![dict get $ev done]} { incr partials }
}
check "at least one repaint frame preceded it" [expr {$partials >= 1}] 1
update idletasks
check "the repaint frames rendered the reply exactly once" \
    [llength [$BV collect_matches "Hello world"]] 1

# ---- a tool call folds as detail --------------------------------------------
$BE insert 0 "tooluse"
.b.input.send invoke
check "the tool's turn settles" \
    [await {[llength [last_ev turn]] && [dict get [last_ev turn] text] eq "read it"}] 1
update idletasks
check "the tool call renders as hidden detail" \
    [vischars "Read(file_path=/etc/hosts)"] 0
set tn [expr {[$BV region_count] - 1}]
check "the exchange's stub counts the call" \
    [string match "*1 tool call*" [stubline $tn]] 1
$BV detail_show $tn
update idletasks
check "unfolding reveals the record-grade line" \
    [expr {[vischars "Read(file_path=/etc/hosts)"] > 0}] 1

# ---- a permission parks; clicking Allow resumes the session -----------------
$BE insert 0 "tool"
.b.input.send invoke
check "the permission parks a row" \
    [await {[llength [$B prompts]] == 1}] 1
set row [lindex [winfo children .b.prompts] 0]
check "the row names the call" [$row.lbl cget -text] \
    "Permission: Bash(command=ls /tmp)"
$row.allow invoke
check "allowing resumes the session" \
    [await {[llength [last_ev turn]] && [dict get [last_ev turn] text] eq "bash allowed"}] 1
check "the decided row is gone" [$B prompts] {}

# ---- a question parks; clicking an option and Answer resumes ----------------
$BE insert 0 "question"
.b.input.send invoke
check "the question parks a row" \
    [await {[llength [$B prompts]] == 1}] 1
set row [lindex [winfo children .b.prompts] 0]
$row.q0.o1 invoke          ;# blue
$row.answer invoke
check "the answers resume the session" \
    [await {[llength [last_ev turn]] && [dict get [last_ev turn] text] eq "chose: blue"}] 1

# ---- a typed follow-up continues the same session ---------------------------
$BE insert 0 "follow up please"
.b.input.send invoke
check "the follow-up's reply settles" \
    [await {[llength [last_ev turn]] && [dict get [last_ev turn] text] eq "echo: follow up please"}] 1
update idletasks
check "the earlier reply still stands once" \
    [llength [$BV collect_matches "Hello world"]] 1
check "each typed line opened its own exchange" [$BV region_count] 5

# ---- close ------------------------------------------------------------------
$S close
check "close ends in exactly one closed event" [await {[n_evs closed] == 1}] 1
check "a graceful close raised no error" [n_evs error] 0
update idletasks
check "closed sealed the last exchange" [$BV live] -1
check "closed disabled the input" [$BE instate disabled] 1

file delete -force $dir

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
