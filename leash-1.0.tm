package require Tcl 9
package provide leash 1.0

# leash - deferred work that cannot outlive its owner.
#
# An event-driven object schedules work naming itself: an [after] timer, an
# idle callback, a coroutine resume. The event queue holds that name with no
# knowledge of the object's lifetime, so destroying the object leaves the
# scheduled script to fire into a command that no longer exists - the
# "invalid command name ::oo::ObjNN" crash, a use-after-free at the level of
# names. Guarding call sites one by one does not hold: each guard checks the
# one lifetime its author had just seen crash, and the next incident lives in
# another. The cure is ownership, not vigilance: every deferred invocation
# belongs to the object that armed it, and dies with it.
#
# leash is a TclOO mixin that carries that rule. A host class declares
# `mixin leash` and arms deferred work only through the leash verbs; the
# mixin's destructor cancels whatever is still pending, so a destroyed
# object cannot be called back.
#
#   oo::class create Sonar {
#       mixin leash
#       method ping {} {
#           my later 300 [list [self] ping]        ;# repeating timer
#       }
#       method listen {} {
#           set co [my coro pump [namespace which my] run_pump]
#           ...                                     ;# $co dies with the object
#       }
#   }
#
#   my later <ms|idle> <script>   arm; returns a token
#   my forget <token>             cancel; fired or forgotten tokens no-op
#   my coro <name> <cmd ...>      coroutine in the object's own namespace;
#                                 returns the fully-qualified command
#
# A mixed-in class may keep its own destructor; leash chains to it. The
# self-unregister of fired timers follows the after mixin, and the
# object-namespace placement of coroutines the coro module, both from
# Dash-OS tcl-modules (MIT, github.com/Dash-OS/tcl-modules).
#
# Written against Tcl 9. MIT license, copyright (c) 2025 Weiwu Zhang.

oo::class create leash {
    variable LeashPending   ;# dict: token -> {after-id script}
    variable LeashSeq       ;# token counter

    # Arm `script` to run after `when` (milliseconds, or the word "idle").
    # The script runs at global level, exactly as a raw [after] script
    # would. Returns a token accepted by [my forget].
    method later {when script} {
        if {![info exists LeashPending]} {
            set LeashPending [dict create]
            set LeashSeq 0
        }
        set tok [incr LeashSeq]
        # The timer calls back through the instance namespace's `my`: that
        # command reaches the unexported method and is itself deleted with
        # the object, a second line of defence behind the destructor's
        # cancel.
        dict set LeashPending $tok \
            [list [after $when \
                [list [info object namespace [self]]::my LeashFire $tok]] \
                $script]
        return $tok
    }

    # Cancel a pending [my later]. A token that already fired, or was
    # already forgotten, is a no-op - callers need not track which.
    method forget {tok} {
        if {[info exists LeashPending] && [dict exists $LeashPending $tok]} {
            after cancel [lindex [dict get $LeashPending $tok] 0]
            dict unset LeashPending $tok
        }
    }

    # Create a coroutine owned by this object. A coroutine command lives in
    # whatever namespace its name says - not the object's - so a bare
    # [coroutine] would survive the object and resume into its remains.
    # Placing the command in the object's instance namespace has the object's
    # destruction delete it, with nothing to record or cancel. Callers keep
    # the returned fully-qualified name; a resume timer left pending simply
    # finds no command.
    method coro {name args} {
        set cmd [info object namespace [self]]::$name
        coroutine $cmd {*}$args
        return $cmd
    }

    # The only script a leash timer ever holds. Not exported - TclOO
    # leaves capitalised method names off the public interface - and
    # reached through the instance namespace's `my` instead. Unregisters
    # before running, so LeashPending lists pending work only and a
    # re-arming (repeating) timer never grows it.
    method LeashFire {tok} {
        set script [lindex [dict get $LeashPending $tok] 1]
        dict unset LeashPending $tok
        uplevel #0 $script
    }

    destructor {
        if {[info exists LeashPending]} {
            dict for {tok pair} $LeashPending {
                after cancel [lindex $pair 0]
            }
        }
        # Chain to the host class's own destructor where one exists; a bare
        # [next] errors when nothing follows.
        if {[self next] ne ""} { next }
    }
}
