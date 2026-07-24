package require Tcl 9
package require TclOO
package require json
package require json::write
package require coachman
package provide helmsman 1.0

# helmsman - drives one LIVE `claude` session interactively and reports
# what happens through a callback, for a GUI to render.
#
# coachman (this module's superclass) is the batch half: one prompt run
# to a finished product on disk. helmsman is the talker half: a running
# conversation with streamed replies, typed follow-up turns, and the two
# prompts the model raises mid-session - a tool-use permission, and an
# AskUserQuestion (itself a tool call, arriving on the same channel
# with a different answer shape) - each parked until the consumer
# answers. It draws
# nothing and knows nothing about widgets: the one callback given at
# construction receives typed events, and the consumer renders them.
#
# WIRE. The session is the claude CLI in bidirectional stream-json mode,
# exactly as the claude-agent-sdk drives it (verified against claude
# 2.1.218 and claude-agent-sdk 0.2.121):
#
#   claude --output-format stream-json --verbose --model M
#          --permission-prompt-tool stdio --include-partial-messages
#          [--resume=SID] ... --input-format stream-json
#
# stdin stays open across turns; each operator turn is one JSON line
#   {"type":"user","message":{"role":"user","content":TEXT},
#    "parent_tool_use_id":null,"session_id":"default"}
# and `--permission-prompt-tool stdio` routes every permission decision
# out as a control_request record the consumer answers through this
# class. AskUserQuestion arrives on the same channel (it is a tool), and
# its answer is not allow/deny but the answers themselves: allow with
# updatedInput = the original input plus an `answers` record mapping
# question text -> answer string (multi-select answers comma-joined),
# the shape the CLI's own input schema describes as "User answers
# collected by the permission component" (the description is visible
# in the claude binary's schema strings, not in any file of this
# tree).
#
# NON-BLOCKING, the load-bearing property. A GUI built on this must not
# freeze while the model streams, so the child's stdout is read only
# from the Tcl event loop: the channel is non-blocking, a chan event
# readable handler gets complete lines until fblocked, and every parsed
# record turns into a callback event as it arrives. There is no vwait,
# no blocking read, and no busy-wait anywhere in this class; writes go
# to a line-buffered non-blocking channel. The flip side: the consumer
# must run the event loop (a Tk GUI already does; a script drives it
# with vwait). Nothing flows while the loop is parked.
#
# EVENT CONTRACT. The callback is a command prefix invoked at global
# level with one dict argument carrying `type`:
#
#   session   {session_id S}   on the init record, and re-stamped after
#             each completed turn (a resumed session forks a fresh id;
#             the re-stamp doubles as the end-of-response signal a GUI
#             re-enables its input box on).
#   turn      {turn_id N role operator|assistant text T done 0|1}
#             the operator's turn once, complete, at send; the
#             assistant's turn repeatedly as it grows - every flush
#             repeats the turn's entire text so far, so a dropped frame
#             self-heals on the next one - and once more with done 1
#             carrying the authoritative settled text.
#   tool      {turn_id N k K label L}   a tool use inside turn N, k its
#             ordinal within the turn, label "<tool> - <first line of
#             its input>".
#   permission {req_id R tool_name T label L input DICT}   a tool-use
#             permission parked awaiting answer_permission.
#   question  {req_id R questions LIST}   an AskUserQuestion parked
#             awaiting answer_question; questions is the tool input's
#             questions array as a list of dicts (question, header,
#             options, multiSelect).
#   permission_resolved {req_id R}   a parked prompt nobody will answer
#             any more (withdrawn by the CLI, or swept by close), so the
#             consumer removes it; NOT emitted when answer_* settles it.
#   error     {message M}   the crash path; followed by closed.
#   closed    {}   exactly once when the session ends, however it ends.
#
# SYNOPSIS.
#
#   oo::class create MySession {
#       superclass helmsman::Session
#       method claude_bin {} { return /usr/local/bin/claude }
#   }
#   set s [MySession new $run_dir $log_dir {my_gui event}]
#   $s open                          ;# fresh session (or: -resume $sid)
#   $s send "What is in this repo?"  ;# returns the operator turn_id
#   ...events arrive via the callback as the event loop runs...
#   $s answer_permission $req_id 1   ;# or: 0 ?message?
#   $s answer_question $req_id {{Which colour?} blue}
#   $s close
#
# CONSTRUCTOR {prompt_dir log_dir on_event}. The first two are
# coachman's (the slug and the log home); on_event is the callback
# command prefix. The child's stderr lands in <log_prefix>-live.stderr.
#
# OPEN {?-model M? ?-resume SID? ?-args LIST?}. Spawns the child; the
# session id arrives as the first session event. -resume continues an
# existing session by id. -args splices extra words into the command
# line ahead of --input-format (a permission mode, an --add-dir grant).
# One session per instance at a time; open while open is an error.
#
# SEND {text}. Queues the operator's turn. Turns are serialized: a send
# while the assistant is mid-response waits for that response's result
# record, then goes out - so a GUI can let the operator type ahead.
# Returns the allocated turn_id synchronously (the echo renders at
# once); `queued` reports how many sends are waiting.
#
# CLOSE. Denies every parked prompt (a suspended can_use_tool blocks
# the CLI's loop, so EOF alone would leave it hanging), half-closes
# stdin, and lets the CLI exit on its own; a straggler is killed after
# a grace period. The closed event fires when the child's stdout
# actually ends. Idempotent.
#
# WHAT IS INHERITED, WHAT IS NOT. From coachman: the constructor's
# files-and-slug plumbing, the claude_bin seam (also the test seam:
# point it at a fake that speaks stream-json and the whole class runs
# without the real CLI), log_service, and the session_id accessor -
# helmsman re-stamps SessionId to the LIVE id on every init and result
# record, where batch capture is first-wins. The batch surface (call,
# resume, the watchdogs, the fix loop) remains available and untouched;
# batch permission_args is NOT overridden - the interactive flags live
# in interactive_permission_args, so a batch call on a helmsman
# instance still runs under coachman's posture. An instance drives one
# live session OR batch calls, not both at once, and the class holds
# that line itself: call and resume refuse while the live session is
# open, open refuses while a batch run is in flight.
#
# SEAMS a subclass overrides:
#   claude_bin                  - inherited; the CLI, and the test seam.
#   interactive_permission_args - the permission flags of the LIVE
#             session; default {--permission-prompt-tool stdio}, which
#             is what routes decisions to this class. Override to add
#             a --permission-mode, not to remove the stdio tool.
#   scrub_env - env vars unset for the child; default ANTHROPIC_API_KEY,
#             because a stray key silently switches the child from the
#             operator's subscription login to pay-as-you-go API
#             billing, discovered only on the invoice.

namespace eval helmsman {}

# helmsman::label - one line naming a tool call: "<tool> - <first line
# of its leading input value>". The input's first value is the salient
# one (a Bash call's command, a read's path); anything past the first
# line or 120 chars is the tool's business, not a label's.
proc helmsman::label {name input} {
    set detail ""
    catch {
        if {[llength $input] >= 2} { set detail [lindex $input 1] }
    }
    set detail [string trim $detail]
    set first [lindex [split $detail \n] 0]
    if {[string length $first] > 120} { set first [string range $first 0 119] }
    if {$first ne ""} { return "$name - $first" }
    return $name
}

# helmsman::_value_end - index of the last character of the JSON value
# starting at index i in raw. Strings honour escapes; containers are
# walked by depth with in-string state; a bare literal (number, true,
# false, null) ends before a delimiter.
proc helmsman::_value_end {raw i} {
    set len [string length $raw]
    set c [string index $raw $i]
    if {$c eq "\""} {
        incr i
        while {$i < $len} {
            set c [string index $raw $i]
            if {$c eq "\\"} { incr i 2; continue }
            if {$c eq "\""} { return $i }
            incr i
        }
        error "helmsman: unterminated JSON string"
    }
    if {$c eq "\{" || $c eq "\["} {
        set depth 0
        set instr 0
        while {$i < $len} {
            set c [string index $raw $i]
            if {$instr} {
                if {$c eq "\\"} { incr i 2; continue }
                if {$c eq "\""} { set instr 0 }
            } elseif {$c eq "\""} {
                set instr 1
            } elseif {$c eq "\{" || $c eq "\["} {
                incr depth
            } elseif {$c eq "\}" || $c eq "\]"} {
                incr depth -1
                if {$depth == 0} { return $i }
            }
            incr i
        }
        error "helmsman: unterminated JSON container"
    }
    set j $i
    while {$j < $len} {
        set c [string index $raw $j]
        if {$c eq "," || $c eq "\}" || $c eq "\]" || [string is space $c]} break
        incr j
    }
    return [expr {$j - 1}]
}

# helmsman::raw_get - the raw JSON text of member $key at the TOP level
# of the JSON object $raw, or "" when absent. Raw because a parsed dict
# cannot be re-encoded faithfully (json2dict loses type fidelity), and
# answering a permission means echoing the original input byte-true as
# updatedInput. Keys are compared undecoded; the CLI's member names
# carry no escapes.
proc helmsman::raw_get {raw key} {
    set len [string length $raw]
    set i 0
    while {$i < $len && [string index $raw $i] ne "\{"} { incr i }
    incr i
    while {$i < $len} {
        while {$i < $len} {
            set c [string index $raw $i]
            if {$c eq "," || [string is space $c]} { incr i } else break
        }
        if {$i >= $len || [string index $raw $i] eq "\}"} { return "" }
        if {[string index $raw $i] ne "\""} { return "" }
        set kend [helmsman::_value_end $raw $i]
        set k [string range $raw [expr {$i + 1}] [expr {$kend - 1}]]
        set i [expr {$kend + 1}]
        while {$i < $len && [string is space [string index $raw $i]]} { incr i }
        if {[string index $raw $i] ne ":"} { return "" }
        incr i
        while {$i < $len && [string is space [string index $raw $i]]} { incr i }
        set vend [helmsman::_value_end $raw $i]
        if {$k eq $key} { return [string range $raw $i $vend] }
        set i [expr {$vend + 1}]
    }
    return ""
}

oo::class create helmsman::Session {
    superclass coachman::Harness

    variable SessionId LogPrefix RunInFlight \
             OnEvent Chan ChildPid Opened Closing Busy SendQueue \
             TurnNo Turns CurTurn Parts FlushTimer LastTurnId ToolK \
             Pending KillTimer StderrFile

    constructor {prompt_dir log_dir on_event} {
        next $prompt_dir $log_dir
        set OnEvent    $on_event
        set Chan       ""
        set ChildPid   {}
        set Opened     0
        set Closing    0
        set Busy       0
        set SendQueue  {}
        set TurnNo     0
        set Turns      {}
        set CurTurn    ""
        set Parts      ""
        set FlushTimer ""
        set LastTurnId ""
        set ToolK      0
        set Pending    [dict create]
        set KillTimer  ""
        set StderrFile ""
    }

    destructor {
        my _cancel_timers
        if {$Chan ne ""} {
            catch {chan event $Chan readable {}}
            catch {chan close $Chan}
            set Chan ""
        }
        if {[llength $ChildPid]} {
            catch {exec kill {*}$ChildPid}
        }
    }

    # ── Seams ─────────────────────────────────────────────────────────

    # interactive_permission_args - the permission flags of the live
    # session. --permission-prompt-tool stdio is what routes every
    # permission decision out as a control_request for this class to
    # broker; without it the CLI decides alone. Deliberately separate
    # from coachman's permission_args so the inherited batch surface
    # keeps its own posture.
    method interactive_permission_args {} {
        return [list --permission-prompt-tool stdio]
    }

    # scrub_env - env vars unset for the child (restored in the parent
    # right after the spawn). See the header for the billing rationale.
    method scrub_env {} {
        return [list ANTHROPIC_API_KEY]
    }

    # ── Public surface ────────────────────────────────────────────────

    # call / resume - the inherited batch surface, refused while the
    # live session is open: batch and live share the harness's identity
    # (the slug's files, the tracked session id), and a batch run
    # beside a live session would fight it for both.
    method call {args} {
        if {$Opened} { error "helmsman: a live session is open; batch call refused" }
        next {*}$args
    }
    method resume {args} {
        if {$Opened} { error "helmsman: a live session is open; batch resume refused" }
        next {*}$args
    }

    method is_open  {} { return $Opened }
    method queued   {} { return [llength $SendQueue] }

    # snapshot - the turns so far ({turn_id role text state} dicts,
    # oldest first), for a reattaching view to re-render from.
    method snapshot {} { return $Turns }

    # pending_prompts - the parked prompts ({req_id kind label} dicts),
    # for a reattaching view to re-raise.
    method pending_prompts {} {
        set out {}
        dict for {rid p} $Pending {
            lappend out [dict create req_id $rid \
                kind [dict get $p kind] label [dict get $p label]]
        }
        return $out
    }

    # open - spawn the live session. See the header for the options.
    method open {args} {
        if {$Opened} { error "helmsman: session already open" }
        if {$RunInFlight} { error "helmsman: a batch run is in flight; open refused" }
        set model  sonnet
        set resume ""
        set extra  {}
        foreach {k v} $args {
            switch -- $k {
                -model  { set model $v }
                -resume { set resume $v }
                -args   { set extra $v }
                default { error "helmsman::open: unknown option \"$k\"" }
            }
        }
        set claude_bin [my claude_bin]
        if {$claude_bin eq ""} { error "helmsman: no claude binary (claude_bin)" }
        set cmd [list $claude_bin --output-format stream-json --verbose \
            --model $model {*}[my interactive_permission_args] \
            --include-partial-messages]
        if {$resume ne ""} { lappend cmd --resume=$resume }
        lappend cmd {*}$extra --input-format stream-json

        set StderrFile "[my log_prefix]-live.stderr"
        set saved [dict create]
        foreach v [my scrub_env] {
            if {[info exists ::env($v)]} {
                dict set saved $v $::env($v)
                unset ::env($v)
            }
        }
        try {
            set Chan [open "|[linsert $cmd end "2>$StderrFile"]" r+]
        } finally {
            dict for {k v} $saved { set ::env($k) $v }
        }
        set ChildPid [pid $Chan]
        chan configure $Chan -blocking 0 -buffering line \
            -translation lf -encoding utf-8
        # The readable handler is the whole read path: dispatched from
        # the event loop, guarded against the object being destroyed
        # with the callback still registered.
        chan event $Chan readable [list apply {obj {
            if {[llength [info commands $obj]]} { $obj on_readable }
        }} [self]]
        set Opened  1
        set Closing 0
        return
    }

    # send - queue one operator turn; returns its turn_id. Turns are
    # serialized on the result record (see the header).
    method send {text} {
        if {!$Opened || $Closing} { error "helmsman: no open session to send to" }
        incr TurnNo
        lappend Turns [dict create turn_id $TurnNo role operator \
            text $text state done]
        my _emit [dict create type turn turn_id $TurnNo role operator \
            text $text done 1]
        if {$Busy} {
            lappend SendQueue $text
        } else {
            set Busy 1
            my _write_user $text
        }
        return $TurnNo
    }

    # answer_permission - settle a parked tool-use permission. allow
    # true answers behavior allow with the original input echoed
    # byte-true as updatedInput; allow false denies with the message.
    # An unknown or already-settled req_id is a silent no-op (the
    # prompt may have been withdrawn racing the click).
    method answer_permission {req_id allow {message "denied by the operator"}} {
        if {![dict exists $Pending $req_id]} { return }
        set p [dict get $Pending $req_id]
        dict unset Pending $req_id
        if {$allow} {
            set resp "\{\"behavior\":\"allow\",\"updatedInput\":[dict get $p raw_input]\}"
        } else {
            set prev [::json::write indented]
            ::json::write indented false
            set resp [::json::write object \
                behavior [::json::write string deny] \
                message  [::json::write string $message]]
            ::json::write indented $prev
        }
        my _control_success $req_id $resp
        return
    }

    # answer_question - settle a parked AskUserQuestion with the
    # answers, not allow/deny: a dict mapping each question's text to
    # the chosen answer string (a multi-select's labels comma-joined by
    # the caller, "red, blue"). The reply is behavior allow with
    # updatedInput = the original input plus the answers record, the
    # shape the CLI's schema expects from the permission component.
    method answer_question {req_id answers} {
        if {![dict exists $Pending $req_id]} { return }
        set p [dict get $Pending $req_id]
        dict unset Pending $req_id
        set prev [::json::write indented]
        ::json::write indented false
        set pairs {}
        dict for {q a} $answers {
            lappend pairs $q [::json::write string $a]
        }
        set ans [::json::write object {*}$pairs]
        ::json::write indented $prev
        set raw [dict get $p raw_input]
        set inner [string trim [string range $raw 1 end-1]]
        if {$inner eq ""} {
            set upd "\{\"answers\":$ans\}"
        } else {
            # Original members first, our answers last: on a duplicate
            # key the last member wins in the CLI's parser.
            set upd "\{$inner,\"answers\":$ans\}"
        }
        my _control_success $req_id "\{\"behavior\":\"allow\",\"updatedInput\":$upd\}"
        return
    }

    # close - end the live session; see the header. Idempotent.
    method close {} {
        if {!$Opened || $Closing} { return }
        set Closing 1
        my _sweep_pending 1 "session closed"
        catch {chan close $Chan write}
        set KillTimer [after 5000 [list apply {pids {
            catch {exec kill {*}$pids}
        }} $ChildPid]]
        return
    }

    # ── The read path (event-loop dispatched) ─────────────────────────

    # on_readable - drain complete lines until the channel blocks; each
    # one becomes events via _on_record. No leading underscore: TclOO
    # leaves underscored methods unexported, and this one is dispatched
    # from the channel handler, outside the object.
    method on_readable {} {
        while 1 {
            set n [gets $Chan line]
            if {$n < 0} {
                if {[eof $Chan]} { my _on_eof; return }
                return  ;# fblocked: a partial line stays buffered
            }
            if {[string trim $line] eq ""} continue
            if {[catch {my _on_record $line} err]} {
                [my log_service]::warn \
                    "\[[my slug]\] helmsman: record dropped: $err"
            }
        }
    }

    method _on_record {line} {
        if {[catch {set d [::json::json2dict $line]}]} { return }
        if {![dict exists $d type]} { return }
        switch -- [dict get $d type] {
            system {
                if {[dict getdef $d subtype ""] eq "init" \
                        && [dict exists $d session_id]} {
                    set SessionId [dict get $d session_id]
                    my _emit [dict create type session session_id $SessionId]
                }
            }
            stream_event {
                set ev [dict getdef $d event {}]
                if {[dict getdef $ev type ""] ne "content_block_delta"} { return }
                set delta [dict getdef $ev delta {}]
                if {[dict getdef $delta type ""] eq "text_delta" \
                        && [dict getdef $delta text ""] ne ""} {
                    my _on_delta [dict get $delta text]
                }
            }
            assistant {
                set msg [dict getdef $d message {}]
                set blocks [dict getdef $msg content {}]
                # A message carrying both tool calls and text is one
                # turn whatever the block order: open it before a
                # leading tool_use, so the tool keys to the turn its
                # own text block is about to settle, not to the
                # previous exchange's.
                foreach block $blocks {
                    if {[dict getdef $block type ""] eq "text"} {
                        my _open_turn
                        break
                    }
                }
                foreach block $blocks {
                    switch -- [dict getdef $block type ""] {
                        tool_use {
                            my _on_tool [dict getdef $block name ""] \
                                [dict getdef $block input {}]
                        }
                        text {
                            my _finish_turn [dict getdef $block text ""]
                        }
                    }
                }
            }
            result {
                # The completed turn's re-stamp: a resumed session forks
                # a fresh id, and the consumer keeps pointing at the
                # live one. Also the serializer's tick: the next queued
                # send goes out now.
                if {[dict exists $d session_id]} {
                    set SessionId [dict get $d session_id]
                    my _emit [dict create type session session_id $SessionId]
                }
                set Busy 0
                if {[llength $SendQueue]} {
                    set next [lindex $SendQueue 0]
                    set SendQueue [lrange $SendQueue 1 end]
                    set Busy 1
                    my _write_user $next
                }
            }
            control_request {
                my _on_control $d $line
            }
            control_response {
                # A reply to a request this class sent; it sends none,
                # so absorb (a host subclass may write its own).
            }
            control_cancel_request {
                # The CLI withdrew a pending request: nobody will ever
                # answer it, so the consumer must drop the prompt.
                set rid [dict getdef $d request_id ""]
                if {[dict exists $Pending $rid]} {
                    dict unset Pending $rid
                    my _emit [dict create type permission_resolved req_id $rid]
                }
            }
        }
    }

    method _on_control {d line} {
        set rid [dict getdef $d request_id ""]
        set req [dict getdef $d request {}]
        if {[dict getdef $req subtype ""] ne "can_use_tool"} {
            # hook_callback / mcp_message: not this class's business;
            # answer with an error so the CLI is not left waiting.
            set prev [::json::write indented]
            ::json::write indented false
            set l [::json::write object \
                type [::json::write string control_response] \
                response [::json::write object \
                    subtype    [::json::write string error] \
                    request_id [::json::write string $rid] \
                    error      [::json::write string \
                        "helmsman handles only can_use_tool control requests"]]]
            ::json::write indented $prev
            my _write $l
            return
        }
        set tool  [dict getdef $req tool_name ""]
        set input [dict getdef $req input {}]
        # The raw input text is kept for the echo (see raw_get's note).
        set raw_req   [helmsman::raw_get $line request]
        set raw_input [helmsman::raw_get $raw_req input]
        if {$raw_input eq ""} { set raw_input "\{\}" }
        if {$tool eq "AskUserQuestion"} {
            dict set Pending $rid [dict create kind question \
                raw_input $raw_input label [helmsman::label $tool $input]]
            my _emit [dict create type question req_id $rid \
                questions [dict getdef $input questions {}]]
        } else {
            dict set Pending $rid [dict create kind permission \
                raw_input $raw_input label [helmsman::label $tool $input]]
            my _emit [dict create type permission req_id $rid \
                tool_name $tool label [helmsman::label $tool $input] \
                input $input]
        }
    }

    method _on_eof {} {
        my _cancel_timers
        catch {chan event $Chan readable {}}
        catch {chan close $Chan}
        set Chan ""
        set was_closing $Closing
        set Opened 0
        set Busy 0
        set SendQueue {}
        set CurTurn ""
        my _sweep_pending 0 ""
        if {!$was_closing} {
            my _emit [dict create type error \
                message "helmsman: session ended unexpectedly (stderr: $StderrFile)"]
        }
        set Closing 0
        my _emit [dict create type closed]
    }

    # ── The streamed assistant turn ───────────────────────────────────

    method _open_turn {} {
        if {$CurTurn eq ""} {
            incr TurnNo
            set CurTurn $TurnNo
            set Parts ""
            set ToolK 0
            lappend Turns [dict create turn_id $TurnNo role assistant \
                text "" state working]
        }
        return $CurTurn
    }

    method _on_delta {text} {
        my _open_turn
        append Parts $text
        # Deltas pool briefly and flush as one repaint carrying the
        # whole text so far - cheap for the GUI, self-healing on a
        # dropped frame.
        if {$FlushTimer eq ""} {
            set FlushTimer [after 80 [list apply {obj {
                if {[llength [info commands $obj]]} { $obj flush_stream }
            }} [self]]]
        }
    }

    # flush_stream - the pooled-delta repaint. No leading underscore:
    # dispatched from the timer, outside the object.
    method flush_stream {} {
        set FlushTimer ""
        if {$CurTurn eq ""} { return }
        my _set_turn $CurTurn $Parts working
        my _emit [dict create type turn turn_id $CurTurn role assistant \
            text $Parts done 0]
    }

    method _finish_turn {text} {
        # The assistant record's text block: the turn as the model
        # settled it, overriding whatever the deltas accumulated.
        set id [my _open_turn]
        if {$FlushTimer ne ""} { after cancel $FlushTimer; set FlushTimer "" }
        my _set_turn $id $text done
        my _emit [dict create type turn turn_id $id role assistant \
            text $text done 1]
        set LastTurnId $id
        set CurTurn ""
    }

    method _on_tool {name input} {
        # A tool use: a note row in the snapshot, and a tool event keyed
        # to the assistant turn it belongs to - the working turn (opened
        # for the whole message when its text is still to come), the one
        # just finished when the tool call trails the text block, or its
        # own row for a message of tool calls alone.
        set label [helmsman::label $name $input]
        incr TurnNo
        lappend Turns [dict create turn_id $TurnNo role tool \
            text $label state done]
        if {$CurTurn ne ""} {
            set tid $CurTurn
        } elseif {$LastTurnId ne ""} {
            set tid $LastTurnId
        } else {
            set tid $TurnNo
        }
        incr ToolK
        my _emit [dict create type tool turn_id $tid k $ToolK label $label]
    }

    method _set_turn {turn_id text state} {
        set i 0
        foreach row $Turns {
            if {[dict get $row turn_id] == $turn_id} {
                dict set row text $text
                dict set row state $state
                lset Turns $i $row
                return
            }
            incr i
        }
    }

    # ── Plumbing ──────────────────────────────────────────────────────

    method _emit {event} {
        if {[catch {uplevel #0 [linsert $OnEvent end $event]} err]} {
            [my log_service]::warn \
                "\[[my slug]\] helmsman: on_event callback failed: $err"
        }
    }

    method _write {line} {
        if {[catch {puts $Chan $line} err]} {
            my _emit [dict create type error \
                message "helmsman: write to session failed: $err"]
        }
    }

    method _write_user {text} {
        set prev [::json::write indented]
        ::json::write indented false
        set line [::json::write object \
            type [::json::write string user] \
            message [::json::write object \
                role    [::json::write string user] \
                content [::json::write string $text]] \
            parent_tool_use_id null \
            session_id [::json::write string default]]
        ::json::write indented $prev
        my _write $line
    }

    method _control_success {rid resp} {
        set prev [::json::write indented]
        ::json::write indented false
        set rid_json [::json::write string $rid]
        ::json::write indented $prev
        my _write "\{\"type\":\"control_response\",\"response\":\{\"subtype\":\"success\",\"request_id\":$rid_json,\"response\":$resp\}\}"
    }

    # _sweep_pending - drop every parked prompt, announcing each so the
    # consumer removes prompts nobody will ever answer. With deny true
    # a deny is written first: a suspended can_use_tool blocks the
    # CLI's loop, so closing without answering would leave it hanging
    # on a reply that never comes.
    method _sweep_pending {deny message} {
        set pending $Pending
        set Pending [dict create]
        dict for {rid p} $pending {
            if {$deny} {
                set prev [::json::write indented]
                ::json::write indented false
                set resp [::json::write object \
                    behavior [::json::write string deny] \
                    message  [::json::write string $message]]
                ::json::write indented $prev
                my _control_success $rid $resp
            }
            my _emit [dict create type permission_resolved req_id $rid]
        }
    }

    method _cancel_timers {} {
        if {$FlushTimer ne ""} { after cancel $FlushTimer; set FlushTimer "" }
        if {$KillTimer ne ""}  { after cancel $KillTimer;  set KillTimer "" }
    }
}
