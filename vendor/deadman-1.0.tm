package require Tcl 9
package provide deadman 1.0

# deadman - a subprocess watchdog: run a command in its own process group,
# stream its stdout, and kill the whole tree on stall, wall-clock, or the
# caller's say-so, reporting an honest exit code and a cause.
#
# A pipe to a child reports what the child prints, not whether it is still
# earning its keep. Left alone the child can go quiet and hold the pipe
# open forever (stall), grind on past any useful deadline (wall), or breach
# a bound only the caller can measure (poll). And killing it is never one
# kill: signalling the pid alone leaves forked grandchildren running, a
# child that traps TERM needs escalation to KILL, and a pipe whose write
# end escaped into an orphan never delivers EOF at all. Each hazard has a
# known cure; scattering the cures across callers is how one is always
# missing. deadman owns them all in one place.
#
#   set res [deadman::run {sh -c make} -stall 60000 -wall 600000]
#   # -> {cause exit exit 0 signal {} stdout {...}}
#
#   set h [deadman::run $argv -out run.log -poll {30000 checkQuota} \
#              -done ranOut]
#   proc checkQuota {h} { if {[quotaGone]} { deadman::kill $h quota } }
#   proc ranOut {res}   { ...same result dict, appended to the cmd... }
#
#   deadman::run argv ?-stdin s? ?-out chan-or-file? ?-err file-or-stdout?
#       ?-line cmd? ?-stall ms? ?-wall ms? ?-poll {ms cmd}? ?-grace ms?
#       ?-done cmd?
#     Run a command. Sync without -done: an internal vwait runs the event
#     loop until the child is reaped, then returns the result dict. With
#     -done: returns a handle at once and invokes cmd at completion with
#     the result dict appended (a coroutine name works as cmd).
#   deadman::kill h ?cause?
#     The caller's own breach: kill the tree now. cause (default "kill")
#     lands verbatim in the result. First cause to land wins; later kills
#     of the same run no-op.
#   deadman::cancel h
#     Kill and tear down; no callbacks fire, no result is delivered. (A
#     sync run cancelled from inside one of its own callbacks is released
#     with cause "cancel" - leaving its vwait parked forever is worse.)
#
# The result dict: cause is what deadman did - "exit" for a natural death
# (even one signalled from outside; the signal is still named), "stall",
# "wall", or the kill caller's token. exit is the child's exit code, signal
# the signal name when the child died by one (exit stays 0-or-code), and
# stdout the collected output, present only when -out did not claim the
# stream. -stall/-wall of 0 or absent switch that detector off. With -poll
# the stall check rides the poll tick, callback first, so a poll kill on a
# shared tick names its own cause instead of being masked as a stall.
#
# Details that exist because their absence once bit:
#   group   setsid launches the child as its own process-group lead (for
#           this pipe shape it execs in place, no fork: a pipeline child
#           is never already a group leader), so kill -TERM -<pid>
#           reaches the grandchildren. No setsid on PATH (gsetsid is
#           probed too, for g-prefixed coreutils): same pipe path, but
#           kills reach the lead pid only.
#   stall   the progress clock is seeded at spawn, not at epoch - so the
#           first tick measures idleness from launch instead of reading an
#           instant false stall - and advances on every stdout line.
#   kill    TERM the group, -grace ms later KILL it, another grace later
#           force-close the pipe, so even an orphan holding the write end
#           open cannot wedge the run. The bare -- escorting the negative
#           pid is not decoration: kill(1) reads an unescorted -<pid> as
#           the -1 broadcast and signals every process the caller owns.
#   stdin   fed as UTF-8 bytes on a binary channel (a text-mode write
#           raises at the first char above U+00FF and truncates), written
#           blocking so the whole input drains past the pipe buffer, write
#           half closed so the child sees EOF, and only then does the read
#           half go non-blocking.
#   reap    the exit status is mined from the [close] error's -errorcode:
#           CHILDSTATUS carries the exit code, CHILDKILLED the signal name.
#   ghosts  every timer and fileevent callback re-checks that its run
#           still exists and no-ops otherwise, every after-token is stored
#           in the run record and cancelled on every exit path, and handles
#           are per-interp serials, never pids (pids get reused). Nothing
#           armed for one run can fire into a torn-down one.
#
# Written against Tcl 9; no dependencies beyond it.

namespace eval ::deadman {
    variable runs           ;# handle -> run record dict
    array set runs {}
    variable sync           ;# handle -> result dict; releases a sync waiter
    array set sync {}
    variable seq 0          ;# handle serial, monotonic per interp
    variable wrap_probed 0  ;# setsid resolved once per interp
    variable wrap ""
}

# Resolve the group-launch wrapper: setsid, or gsetsid where coreutils
# carry the g prefix. Empty means no group - kills degrade to the lead pid.
proc ::deadman::Wrap {} {
    variable wrap_probed
    variable wrap
    if {!$wrap_probed} {
        set wrap [auto_execok setsid]
        if {$wrap eq ""} { set wrap [auto_execok gsetsid] }
        set wrap_probed 1
    }
    return $wrap
}

# Run a command under the watchdog. See the header for the contract.
proc ::deadman::run {argv args} {
    variable runs
    variable sync
    variable seq

    if {[llength $argv] == 0} { error "deadman::run: empty command" }
    if {[llength $args] % 2} { error "deadman::run: options come in pairs" }
    set opt [dict create -stdin "" -out "" -err "" -line "" \
        -stall 0 -wall 0 -poll "" -grace 10000 -done ""]
    set has_stdin 0
    foreach {k v} $args {
        if {![dict exists $opt $k]} { error "deadman::run: unknown option $k" }
        if {$k eq "-stdin"} { set has_stdin 1 }
        dict set opt $k $v
    }
    foreach k {-stall -wall -grace} {
        set v [dict get $opt $k]
        if {![string is entier -strict $v] || $v < 0} {
            error "deadman::run: $k wants a millisecond count, got \"$v\""
        }
    }
    set poll_ms 0
    set poll_cmd ""
    if {[dict get $opt -poll] ne ""} {
        if {[llength [dict get $opt -poll]] != 2} {
            error "deadman::run: -poll wants {ms cmd}"
        }
        lassign [dict get $opt -poll] poll_ms poll_cmd
        if {![string is entier -strict $poll_ms] || $poll_ms <= 0 \
                || $poll_cmd eq ""} {
            error "deadman::run: -poll wants {ms cmd} with ms > 0"
        }
    }

    # The stdout sink, resolved before the spawn so a bad -out path fails
    # with no child left behind. An existing channel is used (and left
    # open, it is the caller's); anything else is a file path, opened
    # line-buffered so the tee lands as lines arrive.
    set outspec [dict get $opt -out]
    set out ""
    set out_owned 0
    if {$outspec ne ""} {
        if {$outspec in [chan names]} {
            set out $outspec
        } else {
            set out [open $outspec w]
            fconfigure $out -buffering line
            set out_owned 1
        }
    }

    # Launch. Stderr goes to the -err file, else to this process's own
    # stderr: an unredirected pipeline stderr would surface as a [close]
    # error and corrupt the reap. Only stdout flows up the pipe.
    set wrap [Wrap]
    set pipeline [list |]
    if {$wrap ne ""} { lappend pipeline {*}$wrap }
    lappend pipeline {*}$argv
    if {[dict get $opt -err] eq "stdout"} {
        # Merge stderr into the watched stream (a file named stdout wants
        # a ./ prefix).
        lappend pipeline 2>@1
    } elseif {[dict get $opt -err] ne ""} {
        lappend pipeline 2> [dict get $opt -err]
    } else {
        lappend pipeline 2>@ stderr
    }
    if {[catch {open $pipeline [expr {$has_stdin ? "r+" : "r"}]} chan opts]} {
        if {$out_owned} { catch {close $out} }
        return -options $opts $chan
    }
    set lead [lindex [pid $chan] 0]

    # The stdin dance, in this exact order (see the header's stdin note):
    # binary channel, UTF-8 bytes, blocking write, half-close, and only
    # then non-blocking. The write is caught: a child that exits before
    # reading breaks the pipe, and the reap below tells that story better
    # than an error here would. The blocking write runs before any timer
    # is armed: a child that backpressures its stdout past the pipe
    # buffer while stdin is still undrained holds the launch, and no
    # detector can fire. An event-driven drain is the upgrade if that
    # ever bites a real caller.
    if {$has_stdin} {
        fconfigure $chan -buffering none -translation binary
        catch {
            puts -nonewline $chan \
                [encoding convertto utf-8 [dict get $opt -stdin]]
            flush $chan
        }
        catch {close $chan write}
    }
    # The tcl8 profile matters: under Tcl 9's default strict profile one
    # undecodable byte on stdout makes [gets] throw persistently with no
    # EOF, and the drain would spin on the fileevent forever. Permissive
    # decoding suits a watchdog; the child's bytes are its own business.
    fconfigure $chan -blocking 0 -buffering line \
        -encoding utf-8 -translation auto -profile tcl8

    set h "dm[incr seq]"
    set runs($h) [dict create \
        chan $chan \
        lead $lead \
        group [expr {$wrap ne ""}] \
        out $out \
        out_owned $out_owned \
        line [dict get $opt -line] \
        capture [expr {$outspec eq ""}] \
        buf "" \
        stall [dict get $opt -stall] \
        poll_ms $poll_ms \
        poll_cmd $poll_cmd \
        grace [dict get $opt -grace] \
        done [dict get $opt -done] \
        cause "" \
        last [clock milliseconds] \
        tick_after "" wall_after "" grace_after "" force_after ""]
    # The progress clock (last) is seeded at spawn, just above, so the
    # first tick measures idleness from now, not from epoch 0.

    fileevent $chan readable [list ::deadman::Drain $h]
    if {[dict get $opt -wall] > 0} {
        dict set runs($h) wall_after \
            [after [dict get $opt -wall] [list ::deadman::kill $h wall]]
    }
    if {$poll_cmd ne "" || [dict get $opt -stall] > 0} { ArmTick $h }

    if {[dict get $opt -done] ne ""} { return $h }
    vwait ::deadman::sync($h)
    set res $sync($h)
    unset sync($h)
    return $res
}

# The caller's own breach: record the cause (first one wins), TERM the
# tree, and arm the grace escalation. The pipe stays open - the child's
# last words still drain - and the natural EOF path finishes the run.
proc ::deadman::kill {h {cause kill}} {
    variable runs
    if {![info exists runs($h)]} { return }
    if {[dict get $runs($h) cause] ne ""} { return }
    dict set runs($h) cause $cause
    # The breach detectors have done their job; only the escalation
    # ladder ticks from here.
    foreach t {tick_after wall_after} {
        set tok [dict get $runs($h) $t]
        if {$tok ne ""} { after cancel $tok; dict set runs($h) $t "" }
    }
    Signal $runs($h) TERM
    dict set runs($h) grace_after \
        [after [dict get $runs($h) grace] [list ::deadman::Escalate $h]]
}

# Kill and tear down with no callbacks and no result. The record goes
# first, so nothing armed can fire into the teardown; then timers, pipe,
# child, sink. A sync waiter is released (see the header).
proc ::deadman::cancel {h} {
    variable runs
    variable sync
    if {![info exists runs($h)]} { return }
    set r $runs($h)
    unset runs($h)
    foreach t {tick_after wall_after grace_after force_after} {
        if {[dict get $r $t] ne ""} { after cancel [dict get $r $t] }
    }
    set chan [dict get $r chan]
    catch {fileevent $chan readable {}}
    Signal $r TERM
    Signal $r KILL
    catch {close $chan}
    if {[dict get $r out_owned]} { catch {close [dict get $r out]} }
    if {[dict get $r done] eq ""} {
        set res [dict create cause cancel exit 0 signal ""]
        if {[dict get $r capture]} { dict set res stdout "" }
        set sync($h) $res
    }
}

# Signal the child's process group (negative pid: setsid made the group id
# the lead pid) and then the lead itself, in case the group send is
# refused. Without a group, only the lead is reachable. The -- escort is
# what scopes the group send: kill(1) reads an unescorted -<pid> as the
# -1 broadcast.
proc ::deadman::Signal {r sig} {
    set lead [dict get $r lead]
    if {[dict get $r group]} { catch {exec kill -$sig -- -$lead} }
    catch {exec kill -$sig $lead}
}

# Run a caller callback at global scope; an error in it is rethrown from
# an [after 0] so it lands in bgerror instead of unwinding the run.
proc ::deadman::Protect {script} {
    if {[catch {uplevel #0 $script} err opts]} {
        after 0 [list ::deadman::Rethrow $err $opts]
    }
}
proc ::deadman::Rethrow {err opts} {
    return -options $opts $err
}

# Arm the shared detector tick: at the poll cadence when a poll is set,
# else at whatever remains of the stall allowance.
proc ::deadman::ArmTick {h} {
    variable runs
    set r $runs($h)
    if {[dict get $r poll_cmd] ne ""} {
        set delay [dict get $r poll_ms]
    } else {
        set idle [expr {[clock milliseconds] - [dict get $r last]}]
        set delay [expr {max(10, [dict get $r stall] - $idle)}]
    }
    dict set runs($h) tick_after [after $delay [list ::deadman::Tick $h]]
}

# One detector tick. The run can have finished between two ticks, so gate
# on the record's existence; a fired token acting on a later run would be
# a use-after-free at the level of names. The poll callback runs before
# the stall check, so a poll kill on this tick names its own cause.
proc ::deadman::Tick {h} {
    variable runs
    if {![info exists runs($h)]} { return }
    dict set runs($h) tick_after ""
    set r $runs($h)
    if {[dict get $r cause] ne ""} { return }
    if {[dict get $r poll_cmd] ne ""} {
        Protect [list {*}[dict get $r poll_cmd] $h]
        # The callback may have killed (cause set, grace armed) or
        # cancelled (record gone) this very run.
        if {![info exists runs($h)]} { return }
        if {[dict get $runs($h) cause] ne ""} { return }
    }
    if {[dict get $r stall] > 0} {
        set idle [expr {[clock milliseconds] - [dict get $runs($h) last]}]
        if {$idle >= [dict get $r stall]} {
            kill $h stall
            return
        }
    }
    ArmTick $h
}

# Grace expired with the pipe still open: the child ignored TERM, so KILL
# the group, and give EOF one more grace before forcing the pipe shut.
proc ::deadman::Escalate {h} {
    variable runs
    if {![info exists runs($h)]} { return }
    dict set runs($h) grace_after ""
    Signal $runs($h) KILL
    dict set runs($h) force_after \
        [after [dict get $runs($h) grace] [list ::deadman::ForceClose $h]]
}

# EOF never landed even after KILL - an orphan outside the group still
# holds the write end. Close our end regardless: the reap's wait is on
# the pipeline's lead, dead since the KILL, not on the orphan, so a lost
# child forfeits nothing but its buffered tail and the recorded cause
# tells the story.
proc ::deadman::ForceClose {h} {
    variable runs
    if {![info exists runs($h)]} { return }
    dict set runs($h) force_after ""
    Reap $h
}

# Tee available stdout lines to the sink (or the capture buffer), feed the
# per-line callback, and advance the progress clock. On EOF, reap. Every
# kill path ends here too: the group signal closes the child's stdout, so
# EOF fires for every termination cause (except the forced close above).
proc ::deadman::Drain {h} {
    variable runs
    if {![info exists runs($h)]} { return }
    set r $runs($h)
    set chan [dict get $r chan]
    set out [dict get $r out]
    set capture [dict get $r capture]
    set linecmd [dict get $r line]
    while {1} {
        # A -line callback may have cancelled the run mid-loop; the
        # channel is gone with it, so re-check before touching it.
        if {![info exists runs($h)]} { return }
        if {[catch {gets $chan line} n]} { set n -1 }
        if {$n < 0} {
            if {[eof $chan]} { Reap $h }
            return
        }
        dict set runs($h) last [clock milliseconds]
        if {$out ne ""} {
            catch {puts $out $line}
        } elseif {$capture} {
            dict append runs($h) buf $line\n
        }
        if {$linecmd ne ""} { Protect [list {*}$linecmd $line] }
    }
}

# Reap the child at pipe close. A non-zero exit or a death by signal
# surfaces as a [close] error; mine its -errorcode rather than propagate:
# CHILDSTATUS carries the exit code, CHILDKILLED the signal name. The
# channel goes blocking first: a non-blocking [close] reports nothing.
# The wait it buys is bounded, since the pipeline's lead is dead or
# exiting on every path here - EOF means it closed stdout, and the forced
# close follows a KILL. (A lead that shuts its stdout by hand and lives
# on would hold the reap; with a stall or wall armed it is killed before
# that matters, and a child built to outlive its stdout is outside this
# module's remit.)
proc ::deadman::Reap {h} {
    variable runs
    set chan [dict get $runs($h) chan]
    fileevent $chan readable {}
    catch {fconfigure $chan -blocking 1}
    set ecode 0
    set sig ""
    if {[catch {close $chan} _ opts]} {
        set e [dict get $opts -errorcode]
        switch -- [lindex $e 0] {
            CHILDSTATUS { set ecode [lindex $e 2] }
            CHILDKILLED { set sig [lindex $e 2] }
        }
    }
    Finish $h $ecode $sig
}

# Deliver the result and dismantle the run: the record goes first so a
# late tick no-ops, every remaining timer is cancelled, the owned sink is
# closed. cause "exit" means deadman did nothing - the child died its own
# death, signalled or not.
proc ::deadman::Finish {h ecode sig} {
    variable runs
    variable sync
    set r $runs($h)
    unset runs($h)
    foreach t {tick_after wall_after grace_after force_after} {
        if {[dict get $r $t] ne ""} { after cancel [dict get $r $t] }
    }
    if {[dict get $r out_owned]} { catch {close [dict get $r out]} }
    set cause [dict get $r cause]
    if {$cause eq ""} { set cause exit }
    set res [dict create cause $cause exit $ecode signal $sig]
    if {[dict get $r capture]} { dict set res stdout [dict get $r buf] }
    if {[dict get $r done] ne ""} {
        uplevel #0 [list {*}[dict get $r done] $res]
    } else {
        set sync($h) $res
    }
}
