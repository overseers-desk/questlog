# leash

## NAME

leash - deferred work that cannot outlive its owner

## SYNOPSIS

```tcl
package require leash

oo::class create Sonar {
    mixin leash
    method ping {} {
        my later 300 [list [self] ping]     ;# repeating timer
    }
    method listen {} {
        set co [my coro pump [namespace which my] run_pump]
    }
}
```

## DESCRIPTION

An event-driven TclOO object schedules work naming itself: an `after` timer, an idle callback, a coroutine resume. The event queue holds that name with no knowledge of the object's lifetime, so destroying the object leaves the scheduled script to fire into a command that no longer exists. The result is the `invalid command name ::oo::Obj42` crash, a use-after-free at the level of names.

Guarding call sites one by one does not hold: each guard checks the one lifetime its author had just seen crash, and the next incident lives in another. The cure is ownership, not vigilance. Every deferred invocation belongs to the object that armed it, and dies with it.

leash is a mixin that carries that rule. A host class declares `mixin leash` and arms deferred work only through the leash verbs; the mixin's destructor cancels whatever is still pending, so a destroyed object cannot be called back.

## METHODS

**my later** *when* *script*
: Arm *script* to run after *when* (milliseconds, or the word `idle`). The script runs at global level, exactly as a raw `after` script would. Returns a token.

**my forget** *token*
: Cancel a pending `later`. A token that already fired, or was already forgotten, is a no-op; callers need not track which.

**my coro** *name* *cmd* ?*arg ...*?
: Create a coroutine owned by this object. A bare `coroutine` command lives in whatever namespace its name says, not the object's, so it would survive the object and resume into its remains. leash places the command in the object's instance namespace instead; destroying the object deletes it, with nothing to record or cancel. Returns the fully-qualified command name.

## NOTES

A mixed-in class may keep its own destructor; leash chains to it.

The timer fires through the instance namespace's `my`, which is itself deleted with the object: a second line of defence behind the destructor's cancel.

The self-unregister of fired timers follows the after mixin, and the object-namespace placement of coroutines the coro module, both from Dash-OS tcl-modules (MIT, github.com/Dash-OS/tcl-modules).

## REQUIREMENTS

Tcl 9. No Tk.

## KEYWORDS

after, timer, coroutine, TclOO, mixin, lifetime, destructor
