package require Tcl 9
package require TclOO
package require logger
package require json
package require json::write
package require deadman
package provide coachman 1.5

# coachman - drives one harnessed `claude -p` CLI session.
#
# A harness wraps a single claude session with the machinery a validated
# agent run needs: stream-json invocation, usage-limit-window recovery
# (classify the block, wait until the stated reset, retry), session
# resume for fix loops, a per-stage cost ledger, and stall/cost-cap
# watchdogs via deadman. The verdict rule the harness commits to: the
# deliverable on disk is the source of truth, not the claude envelope.
# A killed or truncated turn may still hold real work in its product,
# and the caller validates that product. Two namespace procs serve that
# rule from outside the class: coachman::transcript_assistant_text
# recovers every assistant text block from a stream-json transcript
# (the envelope's `result` is only the final turn, which a turn after
# the product displaces), and coachman::extract_between cuts a
# marker-delimited product out of that text.
#
# BOUNDS. Dollars, not time, bound a run. The cost watchdog polls the
# session's real spend (see COST METER) against a per-session cap, and
# the stall watchdog kills a child silent past its timeout. There is
# deliberately no wall-clock cap: a slow turn still paying its way is
# not a fault, and the two watchdogs cover what a timeout would (the
# hung child, the runaway spender).
#
# COST METER. The cap needs a meter. The default session_cost_usd
# prices the tracked session (the parent plus its subagents) from the
# stream transcripts under transcripts_root, using the tallyman module
# and the anthropic-rates.tcl table beside this file. Both are
# dependencies of the default only: a host that overrides
# session_cost_usd needs neither, and a zero cap needs no meter. With a
# cap armed and either missing, call and resume refuse to run: an
# unmetered cap is a promise the harness cannot keep, and refusing
# loudly beats running unbounded behind a warning.
#
# CONCURRENCY. Harnesses are parallel-safe per instance: each owns its
# slug's files and ledger, and instances share nothing but the logger
# service and the rates cache. Every long wait (the child run, the
# usage-window sleep) is coroutine-aware: inside a coroutine it yields
# to the event loop, so a job loop can drive many harnesses on one
# thread; outside one it blocks, so a standalone script needs no event
# loop of its own.
#
# DEPENDENCY. Besides Tcllib (json, json::write, logger), coachman needs
# `deadman` 1.0 or later on the module path: the process watchdog that
# owns the child's pipe, stall clock, and group kill. deadman's home,
# man page, and test suite are in the teatotal module shelf; vendor a
# copy beside this file. `package require coachman` fails without it.
# The default cost meter additionally wants `tallyman` (authored beside
# this module) and anthropic-rates.tcl; both optional, see COST METER.
#
# SYNOPSIS. Subclass, point the injections at your own services, drive:
#
#   oo::class create MyHarness {
#       superclass coachman::Harness
#       method claude_bin {} { return /usr/local/bin/claude }
#       method prompt_root {} { return /opt/myapp }   ;# see load_prompt
#   }
#   set h [MyHarness new $run_dir $log_dir]
#   set rc [$h call build "$log_dir/build" "Write me a haiku."]
#   # rc 0: the haiku is on disk at $log_dir/build (the log_file arg)
#
# CONSTRUCTOR {prompt_dir log_dir}.
#   prompt_dir - the run's own directory. Two uses only: its file tail
#                becomes the slug that names this harness's files, and
#                an optional meta.env inside it tunes the watchdogs.
#                Prompt TEMPLATES do not come from here (see prompt_root).
#   log_dir    - where the product, transcript and ledger are written.
#                Created if absent.
#
# DRIVE. `call stage log_file prompt ?args?` runs a fresh session;
# `resume stage log_file prompt ?args?` continues the captured one (it
# needs a prior call that reached a session id). Extra args are spliced
# into the claude command line; a `--model X` pair among them overrides
# the sonnet default. Both return the same code:
#
#   0  success; the product is written to $log_file
#   1  hard failure (no claude binary, no result in the output)
#   2  external kill, stall, or truncated turn - the product on disk may
#      still hold real work, so validate it rather than discard it
#   3  cost cap tripped; the run was killed deliberately
#      (finalise_resume is the bounded recovery: see that method)
#
# A usage-limit block never reaches the caller: it is classified inside,
# waited out, and retried.
#
# `abort` cancels an in-flight coroutine-driven run from outside; the
# killed call returns 2 with its fail_cause naming the abort, and an
# abort during the usage-window sleep wakes and ends the run at once.
# See the method for the synchronous-mode limit and intended callers.
#
# FILES per call, given `log_file`:
#   $log_file           the product (the turn's result text)
#   ${log_file}.json    the stream-json transcript
#   ${log_file}.stderr  the child's stderr
#   <log_dir>/<slug>-cost.jsonl   the ledger, one record per invocation,
#                       summed by `cost_total`. The constructor TRUNCATES
#                       this file, so one harness owns one slug's ledger.
#
# META.ENV, optional, in prompt_dir, lines of KEY=value:
#   WORKER_COST_CAP_USD  dollar ceiling for one session (0 disables)
#   STALL_TIMEOUT_SECS   silence before a stall kill (0 disables)
#
# INJECTIONS. A subclass overrides only what it needs:
#
#   log_service      - logger service for runtime output
#                      (default: a cached `coachman` service)
#   prompt_root      - directory under which load_prompt resolves
#                      prompts/<name>.txt. No template tree ships with
#                      this module, so a subclass that calls load_prompt
#                      overrides this; the default (the module's own
#                      directory) suits only a caller that puts templates
#                      beside it.
#   claude_bin       - path to the claude CLI
#                      (default: `claude`, resolved on PATH). Also the
#                      test seam: pointed at a fake that speaks
#                      stream-json, the whole harness runs without the
#                      real CLI.
#   session_cost_usd - USD spent so far by a session; feeds the cost cap.
#                      Default: the tallyman-backed transcript meter
#                      (see COST METER), which refuses an armed cap when
#                      tallyman or the rates table is absent.
#   transcripts_root - where the claude CLI writes session transcripts
#                      (default ~/.claude/projects); the default meter
#                      globs it by session id.
#   cost_rates       - the tallyman rates dict the default meter prices
#                      with (default: anthropic-rates.tcl beside this
#                      module; {} refuses an armed cap).
#   permission_args  - the claude permission flags the session runs under.
#                      The default suits unattended batch runs and grants
#                      the session broad tool access; an interactive or
#                      untrusted caller overrides it.
#   recovery_posture / continuation_prompt - how an interrupted `call`
#                      is re-issued after a usage-window reset
#   after_resume / report_fix_failure - fix-loop hooks
#
# and supplies the validator and prompt-builder methods named in the
# run_fix_loop contract (documented at that method).

namespace eval coachman {
    # The module's own directory, captured at load time: the default
    # prompt_root, under which load_prompt resolves prompts/<name>.txt,
    # and where cost_rates looks for anthropic-rates.tcl.
    variable module_dir [file dirname [file normalize [info script]]]
    # Default logger service; created on first use by log_service and
    # cached here so every harness in the process shares one.
    variable log ""
    # Default rates table, lazily sourced from anthropic-rates.tcl by
    # cost_rates and cached; rates_loaded discriminates not-yet-read
    # from read-and-absent.
    variable rates {}
    variable rates_loaded 0
}

# Lightweight file helpers.
proc coachman::_read_file {path} {
    set fd [open $path r]
    set content [read $fd]
    close $fd
    return $content
}

proc coachman::_write_file {path content} {
    set fd [open $path w]
    puts -nonewline $fd $content
    close $fd
}

# extract_between - the text between two marker lines, exclusive of the
# markers. Companion to transcript_assistant_text for a product the
# prompt asked to be delimited (PRODUCT_START/PRODUCT_END, say).
proc coachman::extract_between {text start_marker end_marker} {
    set lines [split $text \n]
    set collecting 0
    set result {}
    foreach line $lines {
        if {$line eq $end_marker && $collecting} {
            break
        }
        if {$collecting} {
            lappend result $line
        }
        if {$line eq $start_marker} {
            set collecting 1
        }
    }
    return [join $result \n]
}

# transcript_assistant_text - every assistant text block from a
# stream-json transcript, in order, newline-separated. The envelope's
# `result` is only the final turn's text, which a turn after the
# product (a Stop hook's reply, say) displaces; reading the whole
# transcript recovers a marker-delimited product regardless of what was
# said after it. Returns "" when the file is absent or holds no
# assistant text.
proc coachman::transcript_assistant_text {json_file} {
    if {![file exists $json_file]} { return "" }
    set chunks {}
    set fd [open $json_file r]
    try {
        while {[gets $fd line] >= 0} {
            set line [string trim $line]
            if {$line eq ""} continue
            if {[catch {set obj [::json::json2dict $line]}]} continue
            if {![dict exists $obj type] || [dict get $obj type] ne "assistant"} continue
            if {![dict exists $obj message]} continue
            set msg [dict get $obj message]
            if {![dict exists $msg content]} continue
            foreach block [dict get $msg content] {
                if {[dict exists $block type] && [dict get $block type] eq "text" \
                        && [dict exists $block text]} {
                    lappend chunks [dict get $block text]
                }
            }
        }
    } finally {
        close $fd
    }
    return [join $chunks \n]
}

# _session_files - the transcript files of session $sid under $root:
# the parent JSONL plus any subagent transcripts beside it. Empty list
# before the transcript appears. Globbed by session id rather than by
# reconstructing the project directory from a cwd (the caller's cwd is
# not deterministic here; UUID collision risk is negligible).
proc coachman::_session_files {sid root} {
    set parents [glob -nocomplain -directory $root -types f -- */${sid}.jsonl]
    if {[llength $parents] == 0} { return {} }
    set parent [lindex $parents 0]
    set files [list $parent]
    set subdir [file join [file dirname $parent] $sid subagents]
    foreach sub [glob -nocomplain -directory $subdir -types f -- *.jsonl] {
        lappend files $sub
    }
    return $files
}

# tool_use_counts - post-hoc audit of a session's tool calls: counts of
# tool_use blocks across session $sid's transcripts (the parent plus
# its subagents) under $root. Bare, a dict of tool name to count. With
# $toolname alone, that tool's count under its own name. With $toolname
# and $inputfield, a dict of that input field's values to counts across
# the tool's calls, the shape a did-it-invoke-the-skill audit reads
# (tool Skill, field skill). Raises with -errorcode
# {COACHMAN NO_TRANSCRIPT} when no transcript for $sid exists under
# $root, a distinguishable absence: an empty dict means the session
# made no matching calls, which is a different fact. A cheap string
# prefilter runs before each json parse; long sessions run to
# megabytes and json2dict is slow per line.
proc coachman::tool_use_counts {sid root {toolname ""} {inputfield ""}} {
    set files [coachman::_session_files $sid $root]
    if {[llength $files] == 0} {
        return -code error -errorcode {COACHMAN NO_TRANSCRIPT} \
            "no transcript for session $sid under $root"
    }
    if {$toolname ne ""} {
        set prefilter "*\"name\":\"$toolname\"*"
    } else {
        set prefilter "*\"type\":\"tool_use\"*"
    }
    set counts [dict create]
    foreach f $files {
        # An unreadable transcript raises rather than reading as zero
        # calls: a silent zero would forge a "tool never invoked"
        # verdict downstream, the opposite of what an audit is for.
        set fd [open $f r]
        fconfigure $fd -encoding utf-8 -profile replace
        try {
            while {[gets $fd line] >= 0} {
                if {![string match $prefilter $line]} continue
                if {[catch {set d [::json::json2dict $line]}]} continue
                set msg [dict getdef $d message [dict create]]
                foreach blk [dict getdef $msg content {}] {
                    if {[dict getdef $blk type ""] ne "tool_use"} continue
                    set name [dict getdef $blk name ""]
                    if {$name eq ""} continue
                    if {$toolname eq ""} {
                        dict incr counts $name
                        continue
                    }
                    if {$name ne $toolname} continue
                    if {$inputfield eq ""} {
                        dict incr counts $name
                        continue
                    }
                    set input [dict getdef $blk input [dict create]]
                    set v [dict getdef $input $inputfield ""]
                    if {$v ne ""} { dict incr counts $v }
                }
            }
        } finally {
            close $fd
        }
    }
    return $counts
}

oo::class create coachman::Harness {
    variable Slug LogPrefix CostLog SessionId PromptDir LogDir \
             WorkerCostCapUsd CostKilled \
             StallKilled CallerKilled StallTimeoutMs UsageResetSecs \
             FailCause DeadmanHandle AbortRequested SleepTimer SleepCoro

    constructor {prompt_dir log_dir} {
        set PromptDir $prompt_dir
        set LogDir    $log_dir
        set Slug      [file tail $prompt_dir]
        set LogPrefix [file join $log_dir $Slug]
        set CostLog   "${LogPrefix}-cost.jsonl"
        set SessionId ""
        set CostKilled 0
        set StallKilled 0
        set CallerKilled 0
        set UsageResetSecs 0
        set FailCause ""
        set DeadmanHandle ""
        set AbortRequested 0
        set SleepTimer ""
        set SleepCoro ""
        # The per-session cost cap is the sole budget circuit-breaker: it
        # bounds a runaway think/retry loop that spends fast (BOUNDS in
        # the header holds the no-wall-clock rationale). The prompt
        # dir's meta.env tunes the default per run (key
        # WORKER_COST_CAP_USD). Zero disables the watchdog; so does an
        # unmetered session_cost_usd (see that method).
        set WorkerCostCapUsd 10.0
        # Per-session stall watchdog: SIGTERM a child that has emitted no
        # stdout for STALL_TIMEOUT_SECS, catching a hung tool call that the
        # cost cap would only reach much later (or never, with the cap
        # disabled). The default ships enabled but conservative, long
        # enough that a slow subagent turn or web fetch does not trip it.
        # Zero disables. Stored in ms for direct comparison with clock
        # milliseconds.
        set StallTimeoutMs 600000
        if {[file exists [file join $prompt_dir meta.env]]} {
            set meta [my load_meta]
            # A non-numeric value would otherwise detonate later as an
            # obscure expr error at the first cap comparison; keep the
            # default and say so instead.
            set cap [dict getdef $meta WORKER_COST_CAP_USD $WorkerCostCapUsd]
            if {[string is double -strict $cap]} {
                set WorkerCostCapUsd $cap
            } else {
                [my log_service]::warn \
                    "\[$Slug\] meta.env WORKER_COST_CAP_USD='$cap' is not a number; keeping \$$WorkerCostCapUsd"
            }
            set secs [dict getdef $meta STALL_TIMEOUT_SECS 600]
            if {[string is double -strict $secs]} {
                set StallTimeoutMs [expr {int($secs * 1000)}]
            } else {
                [my log_service]::warn \
                    "\[$Slug\] meta.env STALL_TIMEOUT_SECS='$secs' is not a number; keeping [expr {$StallTimeoutMs / 1000}]s"
            }
        }
        file mkdir $log_dir
        set fd [open $CostLog w]; close $fd
    }

    # Public accessors, used by subclasses and driver scripts.
    method slug        {} { return $Slug }
    method log_prefix  {} { return $LogPrefix }
    method session_id  {} { return $SessionId }
    method prompt_dir  {} { return $PromptDir }
    method log_dir     {} { return $LogDir }
    method cost_cap    {} { return $WorkerCostCapUsd }
    method stall_timeout {} { return [expr {$StallTimeoutMs / 1000}] }
    method fail_cause  {} { return $FailCause }

    # ── Host override points ──────────────────────────────────────────
    #
    # Four methods carry the harness's reach into its host. Each has a
    # working default, so a subclass overrides only what it needs.

    # log_service - the logger service runtime output goes through, used
    # as [my log_service]::error / ::warn / ::info. Per-run context (the
    # slug, the stage) goes in the message body; logger adds the
    # timestamp, service tag, and level. Default: a `coachman` service,
    # created once and cached in the namespace. A host overrides this to
    # route output into its own service.
    method log_service {} {
        if {$::coachman::log eq ""} {
            set ::coachman::log [logger::init coachman]
        }
        return $::coachman::log
    }

    # prompt_root - the directory that holds the prompts/ template tree
    # load_prompt reads from. Default: the directory this module was
    # loaded from. A host overrides this to point at its own templates.
    method prompt_root {} {
        return $::coachman::module_dir
    }

    # claude_bin - the claude CLI to invoke. Default: the bare name,
    # resolved on PATH at exec time. A host overrides this to pin a
    # discovered or configured binary; an empty return fails the
    # invocation in _invoke.
    method claude_bin {} {
        return claude
    }

    # transcripts_root - where the claude CLI writes session transcripts;
    # the default meter globs it by session id. A host overrides this
    # when its CLI is configured elsewhere; tests point it at fixtures.
    method transcripts_root {} {
        return [file join $::env(HOME) .claude projects]
    }

    # cost_rates - the tallyman rates dict the default meter prices
    # with. Default: anthropic-rates.tcl beside this module (generated
    # from the anthropic-rates.csv source of truth), sourced once per
    # process and cached. Returns {} when the file is absent, which
    # leaves the meter dormant.
    method cost_rates {} {
        if {!$::coachman::rates_loaded} {
            set path [file join $::coachman::module_dir anthropic-rates.tcl]
            if {[file exists $path]} {
                set ::coachman::rates [source $path]
            }
            set ::coachman::rates_loaded 1
        }
        return $::coachman::rates
    }

    # session_cost_usd - USD spent so far by session $sid (the parent
    # session plus its subagents), priced from the stream transcripts
    # by tallyman. Feeds budget_poll. Reads 0.0 before the transcript
    # appears, so the watchdog can call it from the first poll. Errors
    # when tallyman or the rates table is absent; _assert_metered runs
    # the same check at call/resume entry, so an armed cap never
    # reaches the poll unmetered.
    method session_cost_usd {sid} {
        set rates [my cost_rates]
        if {[llength $rates] == 0} {
            error "coachman: session_cost_usd unmetered - no rates table (see cost_rates)"
        }
        if {[catch {package require tallyman}]} {
            error "coachman: session_cost_usd unmetered - tallyman is not on the module path"
        }
        set files [coachman::_session_files $sid [my transcripts_root]]
        if {[llength $files] == 0} { return 0.0 }
        # Sum token usage per model across the parent and every subagent
        # file, then price once. Reading each file's lines is ours
        # (tallyman does no I/O); the dedup of a request split across
        # stream records is tallyman's.
        set per_model [dict create]
        foreach f $files {
            if {[catch {open $f r} fd]} continue
            fconfigure $fd -encoding utf-8 -profile replace
            set lines [split [read $fd] "\n"]
            close $fd
            set res [tallyman::parse_lines $lines]
            dict for {m c} [dict get $res per_model] {
                lassign $c i o w r
                lassign [dict getdef $per_model $m {0 0 0 0}] pi po pw pr
                dict set per_model $m [list [expr {$pi+$i}] [expr {$po+$o}] \
                    [expr {$pw+$w}] [expr {$pr+$r}]]
            }
        }
        # The session is spending now, so today's date selects the rate
        # era. compute_usd returns -1.0 when no model matched any rate
        # (an unpriced local model, or usage not yet landed); the meter
        # reads that as 0.
        set today [clock format [clock seconds] -format %Y-%m-%d]
        set usd [tallyman::compute_usd $per_model $rates $today]
        return [expr {$usd < 0 ? 0.0 : $usd}]
    }

    # _assert_metered - the fail-loud guard on an armed cost cap: a cap
    # above zero whose meter cannot price (no rates table, or no
    # tallyman) is a promise the harness cannot keep, so the run is
    # refused at entry rather than run unbounded behind a warning. Only
    # the DEFAULT meter needs rates and tallyman; a host that overrides
    # session_cost_usd brings its own arithmetic and passes, which the
    # implementer of the method in the call chain decides.
    method _assert_metered {} {
        if {$WorkerCostCapUsd <= 0} { return }
        lassign [lindex [info object call [self] session_cost_usd] 0] \
            calltype methodname cls methodtype
        if {$cls ne "::coachman::Harness"} { return }
        if {[llength [my cost_rates]] == 0} {
            error "coachman: cost cap \$$WorkerCostCapUsd armed but unmetered - no rates table beside the module; supply cost_rates, override session_cost_usd, or set the cap to 0"
        }
        if {[catch {package require tallyman}]} {
            error "coachman: cost cap \$$WorkerCostCapUsd armed but unmetered - tallyman is not on the module path; vendor it beside the module, override session_cost_usd, or set the cap to 0"
        }
    }

    # ──────────────────────────────────────────────────────────────────

    # _fail - record a terminal FAIL cause and log it. The recorded cause
    # is read back by the caller (via fail_cause, only when a run returns
    # non-zero) and surfaced in its end-of-run report. Last write before
    # a non-zero return wins; an intermediate cause on a path that later
    # recovers is never read.
    method _fail {msg} { set FailCause $msg; [my log_service]::error $msg }

    # Per-session cost cap in USD for a single run (parent session plus
    # its subagents). Zero disables the watchdog.
    method set_worker_cost_cap {usd} {
        set WorkerCostCapUsd $usd
    }

    # Per-session stall timeout in seconds. Zero disables. Fractional
    # values are accepted so tests can drive a sub-second timeout; the
    # stored ms count is a whole number, as the watchdog requires.
    method set_stall_timeout {secs} {
        set StallTimeoutMs [expr {int($secs * 1000)}]
    }

    # permission_args - the claude permission flags this harness runs
    # under. The default is unrestricted; a subclass whose sessions fan
    # out into tools or subagents it wants fenced overrides this with an
    # explicit allow-list.
    method permission_args {} {
        return [list --dangerously-skip-permissions]
    }

    # Load prompts/<name>.txt (under prompt_root) and apply __KEY__ →
    # value substitutions from the subs dict. Keys in subs are passed
    # without the __..__ wrapping; this method adds them.
    method load_prompt {name subs} {
        set path [file join [my prompt_root] prompts "${name}.txt"]
        set tmpl [::coachman::_read_file $path]
        set map {}
        dict for {k v} $subs {
            lappend map "__${k}__" $v
        }
        return [string map $map $tmpl]
    }

    # Read prompt_dir/meta.env into a dict.
    method load_meta {} {
        set meta [dict create]
        set fd [open [file join $PromptDir meta.env] r]
        while {[gets $fd line] >= 0} {
            if {[regexp {^([A-Z_]+)=(.*)$} $line -> key val]} {
                set val [string trim $val "\""]
                dict set meta $key $val
            }
        }
        close $fd
        return $meta
    }

    # call - run a fresh claude session. Returns a terminal code: 0 success,
    # 1 hard failure, 2 external kill / stall / incomplete, 3 deliberate budget
    # kill (cost cap). The usage-window block (code 4) is consumed inside
    # _with_recovery and never reaches here.
    #
    # SESSION CAPTURE IS FIRST-WINS, and that is a contract, not an accident.
    # The harness tracks ONE session: the first that `call` gets an id from.
    # `resume` continues that one, and the cost meter prices it. A later `call`
    # runs a genuinely separate session and deliberately does NOT become the
    # tracked one.
    #
    # This is what lets a caller keep a persistent session while running
    # context-isolated side sessions off the same harness: one session drafts
    # and later resumes to revise, and a throwaway session invoked by `call`
    # between the two reviews the draft on a clean context. Under last-wins the
    # throwaway would steal the tracked id, and the revise prompt would land in
    # its context instead, silently. A caller that wants every call tracked
    # builds a harness per session, or overrides this method.
    method call {stage log_file prompt args} {
        my _assert_metered
        set rc [my _with_recovery call $stage $log_file $prompt {*}$args]
        # Capture whenever the stream produced an id (including an incomplete
        # or budget-killed run) so an interrupted call can still be resumed and
        # the cost meter can find the transcript.
        if {$SessionId eq ""} {
            set SessionId [my _extract_session_id "${log_file}.json"]
        }
        return $rc
    }

    # resume - resume the captured session with a fix/revision prompt.
    # Fails while no call has captured a session id (capture also happens
    # on an interrupted or budget-killed call whose init event landed).
    method resume {stage log_file prompt args} {
        if {$SessionId eq ""} {
            error "coachman::Harness::resume: no session id captured yet - a call must reach one first"
        }
        my _assert_metered
        return [my _with_recovery resume $stage $log_file $prompt --resume $SessionId {*}$args]
    }

    # abort - cancel the in-flight run: the outside kill path a caller
    # such as a GUI cancel button or a job-loop shutdown would reach
    # for. Three states answer it. A live child: its group is killed
    # with cause `caller`, and the abort MARK (AbortRequested), not the
    # recorded cause, is what stops the run - deadman's first-cause-wins
    # rule can hand the kill to a watchdog that fired first, and without
    # the mark the stall-retry loop would run fresh attempts over the
    # caller's abort. A usage-window sleep between attempts: the run is
    # marked and, in coroutine mode, woken at once to fail rather than
    # sleeping out a reset nobody wants. Idle: a no-op returning 0.
    # Returns 1 whenever a live run was told to stop; the interrupted
    # call returns 2 (the validate-the-product path) with fail_cause
    # naming the abort, unretried. Only a coroutine-driven run holds a
    # handle or a wakeable sleep: deadman's synchronous mode blocks its
    # caller until the child is reaped, so a synchronous caller is
    # itself parked inside the very run it would abort.
    method abort {} {
        if {$DeadmanHandle ne ""} {
            set AbortRequested 1
            deadman::kill $DeadmanHandle caller
            return 1
        }
        if {$SleepCoro ne ""} {
            set AbortRequested 1
            my sleep_wake
            return 1
        }
        return 0
    }

    # sleep_wake - the single wake path for the usage-window sleep: the
    # reset timer and abort both land here, and the first arrival clears
    # SleepCoro so the second is a no-op. Without this funnel, a timer
    # that fired just before an abort would queue a second resume into a
    # coroutine already moving again, and the stray resume would land on
    # whatever yield that coroutine parks at next (in a job loop, the
    # next job's child wait). Resumes from the event loop, not the
    # caller's stack, and the guard leaves nothing to fire into if the
    # coroutine was torn down first. Carries no leading underscore:
    # dispatched from the timer, outside the object.
    method sleep_wake {} {
        if {$SleepCoro eq ""} { return }
        after cancel $SleepTimer
        set co $SleepCoro
        set SleepCoro ""
        set SleepTimer ""
        after 0 [list apply {co {
            if {[llength [info commands $co]]} { $co }
        }} $co]
    }

    # finalise_resume - the bounded recovery for a cost-cap kill (a call
    # that returned 3). The budget SIGTERM typically lands after the
    # expensive work and its product are on disk but before the cheap
    # closing steps the prompt orders last, so discarding the session
    # loses near-all the spend. Resume it once with a finalise-only
    # prompt (host-supplied; it opens no new expensive work), under the
    # old cap plus $headroom. The bump is the trap this method encodes:
    # the meter prices the resumed session CUMULATIVELY, so a fresh
    # small cap would re-trip on the first poll; the new cap sits above
    # the spend already booked. Returns the resume's code (1 when no
    # session id was ever captured, so there is nothing to resume); the
    # caller validates the on-disk product either way.
    method finalise_resume {stage log_file prompt {headroom 2.0}} {
        if {$SessionId eq ""} {
            [my log_service]::warn \
                "\[$Slug\] Cost cap fired before a session_id was captured - cannot resume to finalise"
            return 1
        }
        my set_worker_cost_cap [expr {$WorkerCostCapUsd + $headroom}]
        set rc [my resume $stage $log_file $prompt]
        if {$rc != 0} {
            [my log_service]::warn \
                "\[$Slug\] Finalise resume did not close cleanly (rc=$rc); validate the on-disk product anyway"
        }
        return $rc
    }

    # cost_total - sum `cost` fields across the JSONL ledger.
    method cost_total {} {
        set total 0.0
        if {![file exists $CostLog]} { return $total }
        set fd [open $CostLog r]
        while {[gets $fd line] >= 0} {
            set line [string trim $line]
            if {$line eq ""} continue
            if {[catch {set d [::json::json2dict $line]}]} continue
            set total [expr {$total + [dict getdef $d cost 0]}]
        }
        close $fd
        return $total
    }

    # _with_recovery - the recovery layer call/resume route through. _invoke
    # classifies and returns; this method owns the one interruption class
    # _invoke cannot resolve on its own: a usage-window block (code 4), where
    # the subscription limit is reached and resets at a stated time. It waits
    # until the reset and re-invokes, bounded by max_retries; on exhaustion it
    # returns the terminal 1. Because rc==4 is consumed here, no caller ever
    # sees it.
    #
    # After the reset, how to re-issue depends on the entrypoint and the
    # per-stage posture:
    #   - resume-initiated (entry=resume): $args already carries --resume and
    #     the resume's own prompt; replay verbatim to continue the session.
    #   - call-initiated (entry=call), posture resume (the default everywhere):
    #     the interrupted work is worth preserving, so switch to --resume
    #     <captured sid> plus a continuation prompt for the remaining attempts.
    #     session_id is captured from json_file here, before the next _invoke
    #     truncates it.
    #   - call-initiated, posture restart (per-stage override): re-issue fresh
    #     with the original prompt+args, clearing SessionId so the new session
    #     is metered by its own init event, not the dead one.
    method _with_recovery {entry stage log_file prompt args} {
        set AbortRequested 0
        set max_retries 5
        # A stall kill is a recoverable interruption, not a verdict on the
        # work: a session that emitted only thinking tokens then fell silent
        # past the stall timeout produced nothing on disk to validate, and the
        # silence is often a usage-limit window the CLI never surfaced as a
        # resets-string for the rc==4 path to catch. Retry it on a fresh
        # session rather than dropping the job with no product. Each retry
        # already spaces itself by one stall_timeout of wall clock.
        #
        # Stall retries carry their own ceiling, but they share the loop's
        # attempt counter with the usage-window retries, so max_retries is
        # the bound on invocations of any kind: two stalls leave three
        # usage-window attempts, not five. That is the intended reading -
        # the two classes have separate ceilings, one shared budget.
        set max_stall_retries 2
        set stall_attempt 0
        set json_file "${log_file}.json"
        for {set attempt 1} {1} {incr attempt} {
            set rc [my _invoke $stage $log_file $prompt {*}$args]
            # The abort mark outranks the recorded kill cause: an abort
            # that lost deadman's first-cause-wins race to a watchdog
            # (or landed on a run whose envelope still completed) must
            # still end the run here, not be retried over. It also
            # outranks a budget classification - the caller's stop and
            # the cap's stop both want the run dead, and the caller
            # asked by name.
            if {$AbortRequested} {
                my _fail "FAIL ($stage: aborted by caller): $Slug"
                return 2
            }
            if {$rc == 2 && $StallKilled} {
                if {$stall_attempt >= $max_stall_retries} {
                    my _fail \
                        "FAIL ($stage: stalled after $max_stall_retries fresh-session retries): $Slug"
                    return 2
                }
                incr stall_attempt
                [my log_service]::warn \
                    "\[$Slug\] Stalled (retry $stall_attempt/$max_stall_retries) — restarting on a fresh session"
                # A resume-initiated stall replays verbatim on its own session
                # (restarting fresh would discard the work that session holds); a
                # call-initiated one clears the captured session so the retry is
                # metered by a fresh init event, not the hung one.
                if {$entry ne "resume" && [lsearch -exact $args --resume] < 0} {
                    set SessionId ""
                }
                continue
            }
            if {$rc != 4} { return $rc }
            if {$attempt >= $max_retries} {
                my _fail "FAIL ($stage: credit limit after $max_retries retries): $Slug"
                return 1
            }
            [my log_service]::warn "\[$Slug\] Credit limit hit (attempt $attempt/$max_retries). Sleeping [expr {$UsageResetSecs / 60}]m until reset..."
            # A usage-window reset can be an hour out; inside a coroutine-
            # driven job loop that wait must not freeze the loop, so resume
            # the coroutine when the timer fires (guarded, so a torn-down
            # coroutine leaves nothing to fire into) rather than parking the
            # whole process on a vwait. Outside a coroutine the vwait
            # fallback keeps a standalone run working.
            if {[info coroutine] ne ""} {
                # The sleep state is held on the instance so abort can
                # end it early; both the reset timer and abort wake
                # through sleep_wake, the funnel that makes the second
                # waker a no-op. After the wake, the mark check at the
                # top of the next iteration's _invoke return is too late
                # (it would re-invoke first), so check it here.
                set SleepCoro [info coroutine]
                set SleepTimer [after [expr {$UsageResetSecs * 1000}] \
                    [list [self] sleep_wake]]
                yield
                if {$AbortRequested} {
                    my _fail "FAIL ($stage: aborted by caller): $Slug"
                    return 2
                }
            } else {
                after [expr {$UsageResetSecs * 1000}] \
                    [list set [my varname _wake] 1]
                vwait [my varname _wake]
            }

            # Already in resume mode (either a resume-initiated call, or a
            # call already converted on an earlier block), so replay verbatim.
            # The lsearch guard is what stops a second --resume being added.
            if {$entry eq "resume" || [lsearch -exact $args --resume] >= 0} {
                continue
            }
            if {[my recovery_posture $stage] eq "resume" \
                    && [set sid [my _extract_session_id $json_file]] ne ""} {
                set SessionId $sid
                set prompt [my continuation_prompt $stage]
                set args [linsert $args 0 --resume $sid]
            } else {
                set SessionId ""
            }
        }
    }

    # recovery_posture - for a usage-window block on an initial `call`, whether
    # to resume-continue the interrupted session (the default everywhere) or
    # restart it fresh. A stage whose interrupted work is not worth preserving
    # may override to "restart". Resume-initiated calls ignore this; they
    # always continue their own session.
    method recovery_posture {stage} { return resume }

    # continuation_prompt - the prompt sent when resuming a `call` after the
    # usage window resets. It must tell the agent to continue from the work
    # already in the session, the opposite of a cost-cap finalise prompt's
    # "stop all further work". Generic by default; a subclass may point it at
    # a task-specific continuation prompt.
    method continuation_prompt {stage} {
        return "The previous turn of this task was paused by a subscription usage-limit window, which has now reset. The budget is fine. Do not restart from scratch or repeat work already done. Continue the task from where you left off, using everything already gathered in this session, and finish it."
    }

    # _invoke - run the claude CLI once and classify the outcome; it does not
    # wait or retry. Codes: 0 success, 1 hard failure, 2 external kill / stall /
    # incomplete, 3 cost-cap budget kill, 4 usage-window blocked (the reset
    # seconds ride UsageResetSecs; _with_recovery consumes it). Writes the
    # product on success and appends the cost-log entry.
    method _invoke {stage log_file prompt args} {
        set json_file "${log_file}.json"

        set claude_bin [my claude_bin]
        if {$claude_bin eq ""} {
            my _fail "FAIL ($stage: claude not found): $Slug"
            return 1
        }
        # --model rides immediately after -p so the model is the first thing
        # visible in `ps ax` output rather than scrolled off past the flags.
        # Default to sonnet unless the caller supplied --model (fix-loop
        # attempt 3 escalates to opus; a caller may pass its own model); pull
        # the caller's pair out of args so it is not repeated.
        set model sonnet
        set idx [lsearch -exact $args --model]
        if {$idx >= 0} {
            set model [lindex $args [expr {$idx + 1}]]
            set args [lreplace $args $idx [expr {$idx + 1}]]
        }
        # permission_args goes before the boolean flags, never last: claude's
        # --allowedTools/--disallowedTools are variadic (<tools...>), so a tool
        # list immediately ahead of the prompt eats it and -p is left with no
        # input. Keep a non-variadic flag between them.
        set cmd [concat \
            [list $claude_bin -p --model $model] [my permission_args] \
            [list --output-format stream-json --verbose] $args [list $prompt]]

        # Verdict rule this harness commits to: the deliverable on disk
        # is the source of truth, not the claude envelope. stream-json
        # writes one JSONL event per line as work happens, so
        # _stream_result recovers the final result object when the turn
        # closes, and _extract_session_id recovers session_id from the
        # first (init) event even when it does not. Record real elapsed
        # and the true exit code so a kill is reported honestly.
        set t0 [clock seconds]
        set CostKilled 0
        set StallKilled 0
        set CallerKilled 0
        # deadman owns the pipe, the stall clock, and the group kill; the
        # budget check rides its poll tick (budget_poll below), and a cost
        # kill beats a stall on a shared tick because the poll callback
        # runs before the stall check.
        set dm [list -out $json_file -err "${log_file}.stderr" \
            -stall $StallTimeoutMs]
        if {$WorkerCostCapUsd > 0} {
            lappend dm -poll \
                [list [my _cost_poll_ms] [list [self] budget_poll $json_file]]
        }
        # Inside a coroutine (a coroutine-driven job loop) deadman completes
        # into the coroutine: hand it [info coroutine] as -done and yield, so
        # the minutes-long claude run drives the loop instead of freezing it,
        # and the result dict arrives as the yield's value. Called outside a
        # coroutine (a standalone or a test run) deadman's own vwait blocks
        # until the child is reaped.
        if {[info coroutine] ne ""} {
            # The returned handle is the outside kill path: abort reaches
            # it while the run is in flight. Cleared once the result
            # lands, so abort on an idle harness stays a no-op.
            set DeadmanHandle [deadman::run $cmd {*}$dm -done [info coroutine]]
            set r [yield]
            set DeadmanHandle ""
        } else {
            set r [deadman::run $cmd {*}$dm]
        }
        set exit_code [dict get $r exit]
        switch -- [dict get $r cause] {
            cost   { set CostKilled 1 }
            stall  { set StallKilled 1 }
            caller { set CallerKilled 1 }
        }
        set elapsed [expr {[clock seconds] - $t0}]

        set parsed [my _stream_result $json_file]

        # A deliberate budget kill is a circuit-breaker on the EXPENSIVE
        # work: resuming that work re-spends the very budget the cap
        # exists to bound. The cost watchdog SIGTERM (CostKilled) is that
        # kill: it fails the run with return 3 to mark the cap tripped.
        # A subclass's pipeline may read return 3 as a signal to recover
        # the spend via finalise_resume (a single bounded finalise-only
        # resume; see that method), or treat it as a terminal fail. An
        # external kill or a truncated-
        # but-incomplete stream is a different animal (the turn may have
        # done real work the disk product still holds), so that path keeps
        # return 2, the validate-the-product / resume route.
        if {[llength $parsed] == 0} {
            if {$CostKilled} {
                my _fail \
                    "FAIL ($stage: cost cap \$$WorkerCostCapUsd reached — budget kill): $Slug"
                return 3
            }
            # A caller abort is an external kill by request: return 2 (the
            # product may hold real work), and because StallKilled stays 0
            # the recovery loop does not retry it - an auto-retried abort
            # would defeat the abort.
            if {$CallerKilled} {
                my _fail \
                    "FAIL ($stage: aborted by caller): $Slug"
                return 2
            }
            # A stall kill is the same animal as an external kill for
            # recovery (the disk product may hold real work), so it shares
            # return 2 (validate-the-product). Check it AFTER CostKilled so a
            # cost kill is never downgraded to a resumable stall; the cause
            # string distinguishes the two in the log.
            if {$StallKilled} {
                my _fail \
                    "FAIL ($stage: stalled — no output for >= [my stall_timeout]s; [my _failure_cause $log_file $json_file $exit_code]): $Slug"
                return 2
            }
            my _fail \
                "FAIL ($stage: ended without result after ${elapsed}s; [my _failure_cause $log_file $json_file $exit_code]): $Slug"
            return 2
        }
        # A complete envelope landed despite a budget kill (the work
        # finished just before SIGTERM): the product verdict stands, so
        # fall through to the success path below. A genuinely complete
        # product validates cleanly without resuming.

        if {[dict exists $parsed is_error] && [dict get $parsed is_error] eq "true"} {
            set result_text [dict getdef $parsed result ""]
            if {[string match -nocase *hit*your*limit*resets* $result_text]} {
                # Usage-window block. Classify and return 4; _with_recovery
                # owns the wait and the retry. The reset seconds ride
                # UsageResetSecs. (The string match and reset-time scrape are
                # the only prose-dependent code in the harness, kept here in
                # one place so there is a single home to harden if a future
                # CLI exposes a structured usage-limit signal.)
                set UsageResetSecs [my _credit_wait_secs $result_text]
                return 4
            }
        }

        if {![dict exists $parsed result]} {
            my _fail "FAIL ($stage: no result in output; [my _failure_cause $log_file $json_file $exit_code]): $Slug"
            return 1
        }

        set fd [open $log_file w]
        try {
            puts -nonewline $fd [dict get $parsed result]
        } finally {
            close $fd
        }

        set _prev_indent [::json::write indented]
        ::json::write indented false
        set cost_entry [::json::write object \
            stage [::json::write string $stage] \
            cost [dict getdef $parsed total_cost_usd 0]]
        ::json::write indented $_prev_indent
        set fd [open $CostLog a]
        try {
            puts $fd $cost_entry
        } finally {
            close $fd
        }

        return 0
    }

    # budget_poll - the cost breach detector, dispatched from deadman's
    # poll tick. Prices this run (the parent session plus its subagents,
    # via session_cost_usd) and, once the spend crosses WorkerCostCapUsd,
    # kills the run with cause `cost` so _invoke fails it fast.
    # session_id comes from the growing json_file (the init event lands
    # within the first second), never from the captured SessionId: under
    # first-wins capture a later side `call` runs a different session
    # than the tracked one, and pricing the tracked id would leave the
    # running session uncapped. Until the init event lands there is
    # nothing safe to price, so the tick passes. Carries no leading
    # underscore: TclOO leaves underscored methods unexported, and this
    # one is dispatched from outside the object.
    method budget_poll {json_file h} {
        if {$WorkerCostCapUsd <= 0} { return }
        set sid [my _extract_session_id $json_file]
        if {$sid eq ""} { return }
        set cost [my session_cost_usd $sid]
        if {$cost >= $WorkerCostCapUsd} {
            [my log_service]::warn \
                "\[$Slug\] Cost cap: \$[format %.2f $cost] >= \$$WorkerCostCapUsd — SIGTERM worker group"
            deadman::kill $h cost
        }
    }

    # The watchdog poll interval in ms. A method so tests can shorten it
    # without touching the production cadence (30s: long enough that the
    # cost read stays a negligible fraction of wall time, short enough to
    # catch a runaway within one $-cap's worth of overspend).
    method _cost_poll_ms {} { return 30000 }

    # _stream_result - the final result object from a stream-json
    # transcript, or {} when no complete result line was written (the turn
    # was killed or truncated). Tolerates a half-written trailing line.
    method _stream_result {json_file} {
        if {![file exists $json_file]} { return {} }
        set result {}
        set fd [open $json_file r]
        try {
            while {[gets $fd line] >= 0} {
                set line [string trim $line]
                if {$line eq ""} continue
                if {[catch {set obj [::json::json2dict $line]}]} continue
                if {[dict exists $obj type] && [dict get $obj type] eq "result"} {
                    set result $obj
                }
            }
        } finally {
            close $fd
        }
        return $result
    }

    # _extract_session_id - session_id from the first stream-json event that
    # carries it (the init event), so it survives a kill that prevented the
    # final result object from being written.
    method _extract_session_id {json_file} {
        if {![file exists $json_file]} { return "" }
        set sid ""
        set fd [open $json_file r]
        try {
            while {[gets $fd line] >= 0} {
                set line [string trim $line]
                if {$line eq ""} continue
                if {[catch {set obj [::json::json2dict $line]}]} continue
                if {[dict exists $obj session_id]} {
                    set sid [dict get $obj session_id]
                    break
                }
            }
        } finally {
            close $fd
        }
        return $sid
    }

    # _failure_cause - assemble a one-line cause string for a FAIL log when
    # the turn produced no usable result. A claude exit with empty stdout
    # would otherwise leave the operator with "rc=error" and nothing else;
    # surface the child exit code (already in hand), the tail of the stderr
    # file, and the last stream event that did land, so an empty-artefact
    # failure becomes diagnosable instead of undetermined.
    method _failure_cause {log_file json_file exit_code} {
        set parts [list "exit $exit_code"]
        set stderr_file "${log_file}.stderr"
        if {[file exists $stderr_file] && [file size $stderr_file] > 0} {
            set fd [open $stderr_file r]
            try {
                set lines [split [read $fd] \n]
            } finally {
                close $fd
            }
            set kept {}
            foreach line $lines {
                set line [string trim $line]
                if {$line ne ""} { lappend kept $line }
            }
            if {[llength $kept] > 0} {
                set n [llength $kept]
                set start [expr {$n > 5 ? $n - 5 : 0}]
                lappend parts "stderr: [join [lrange $kept $start end] { | }]"
            }
        }
        if {[file exists $json_file]} {
            set fd [open $json_file r]
            set last ""
            try {
                while {[gets $fd line] >= 0} {
                    set line [string trim $line]
                    if {$line eq ""} continue
                    if {[catch {set obj [::json::json2dict $line]}]} continue
                    set last $obj
                }
            } finally {
                close $fd
            }
            if {$last ne ""} {
                set ev [dict getdef $last type "?"]
                set sub [dict getdef $last subtype ""]
                if {$sub ne ""} { append ev "/$sub" }
                lappend parts "last event: $ev"
            }
        }
        return [join $parts {, }]
    }

    # Parse "resets 3am (Australia/Brisbane)" → seconds to sleep. The zone
    # is whatever the message states in parentheses; a message that names
    # none is read in the system's own zone, which is the best available
    # guess for where the caller is. An hour is the fallback whenever the
    # string does not parse: long enough to be worth waiting, short enough
    # that a wrong guess costs one retry rather than a night.
    method _credit_wait_secs {msg} {
        if {![regexp {resets (\d{1,2}(?::\d{2})?\s*[ap]m)} $msg -> reset_time]} {
            return 3600
        }
        set tzargs {}
        if {[regexp {\(([^)]+)\)} $msg -> found_tz]} {
            set tzargs [list -timezone :$found_tz]
        }
        set now_epoch [clock seconds]
        if {[catch {
            set reset_epoch [clock scan "today $reset_time" {*}$tzargs]
        }]} {
            return 3600
        }
        if {$reset_epoch <= $now_epoch} {
            if {[catch {
                set reset_epoch [clock scan "tomorrow $reset_time" {*}$tzargs]
            }]} {
                return 3600
            }
        }
        set wait [expr {$reset_epoch - $now_epoch + 120}]
        if {$wait < 60} { set wait 60 }
        return $wait
    }

    # ── Fix loop ──────────────────────────────────────────────────────
    #
    # A subclass wraps a max_fix=3 retry around a task-specific
    # validator. Validate, accept on no-error, otherwise log + resume
    # with a fix prompt + retry. Attempt 3 escalates to opus. After
    # max_fix rounds, run a final validation and report failure if
    # errors remain.
    #
    # Subclass contract:
    #   $validator_method      - `my <name> $attempt` returns a list of
    #                            error dicts (severity, code, message).
    #   $prompt_builder_method - `my <name> $attempt $hard $error_text`
    #                            returns the fix prompt string.
    # Optional overrides: after_resume, report_fix_failure.
    method run_fix_loop {validator_method prompt_builder_method} {
        set max_fix 3
        for {set attempt 1} {$attempt <= $max_fix} {incr attempt} {
            set errors [my $validator_method $attempt]
            set hard [my hard_errors_from $errors]
            if {[llength $hard] == 0} {
                if {$attempt > 1} {
                    [my log_service]::info "\[$Slug\] Validation passed after $attempt attempt(s)."
                }
                return 0
            }
            set error_text [my format_errors $hard]
            [my log_service]::warn "\[$Slug\] Validation failed (attempt $attempt/$max_fix):\n$error_text"
            set fix_log "${LogPrefix}-fix${attempt}.log"
            set fix_prompt [my $prompt_builder_method $attempt $hard $error_text]
            set model_args {}
            if {$attempt == 3} { set model_args [list --model opus] }
            if {[my resume "fix${attempt}" $fix_log $fix_prompt {*}$model_args]} {
                return 1
            }
            my after_resume
        }
        # Final pass after exhausting retries.
        set errors [my $validator_method final]
        set hard [my hard_errors_from $errors]
        if {[llength $hard] > 0} {
            my report_fix_failure $hard $max_fix
            return 1
        }
        return 0
    }

    # Filter to error-severity entries only.
    method hard_errors_from {errors} {
        set hard {}
        foreach e $errors {
            if {[dict get $e severity] eq "error"} { lappend hard $e }
        }
        return $hard
    }

    # Format a hard-error list as bullet lines for fix prompts.
    method format_errors {hard} {
        set lines {}
        foreach e $hard {
            lappend lines "- \[[dict get $e code]\] [dict get $e message]"
        }
        return [join $lines \n]
    }

    # Hook fired after a successful resume (the agent rewrote the output
    # file). Default no-op; a subclass whose validator caches parsed
    # output overrides this to drop that cache so the next iteration
    # sees fresh bytes.
    method after_resume {} {}

    # Default failure message when the loop exits with errors remaining.
    # A subclass may override to include detail from the errors.
    method report_fix_failure {hard max_fix} {
        my _fail "FAIL (validation failed after $max_fix retries): $Slug"
    }
}
