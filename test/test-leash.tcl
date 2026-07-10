#!/usr/bin/env tclsh9.0
# Tests for the leash module: that deferred work armed through an object dies
# with the object, that fired and forgotten tokens are inert, and that the
# mixin coexists with a host class's own destructor. The classes here are
# invented for the tests; the module knows nothing of any program that uses it.
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add $ROOT
package require leash

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name"
        puts "  expected: <$expected>"
        puts "  actual:   <$actual>"
        incr ::fails
    } else {
        puts "ok:   $name"
    }
}
# Run the event loop until pending timers this short have fired.
proc drain {{ms 50}} {
    set ::_drained 0
    after $ms {set ::_drained 1}
    vwait ::_drained
}

# A leashed object that counts how often its timers land.
oo::class create Counter {
    mixin leash
    variable N
    constructor {} { set N 0 }
    method bump {} { incr N }
    method count {} { return $N }
    method arm {when} { my later $when [list [self] bump] }
}

# -- a timer fires once, and its token is then inert -------------------------

set o [Counter new]
set tok [$o arm 1]
drain
check fired-once 1 [$o count]
$o forget $tok                      ;# already fired: must be a no-op
check forget-after-fire-noop 1 [$o count]
$o destroy

# -- forget cancels; double forget is a no-op --------------------------------

set o [Counter new]
set tok [$o arm 1]
$o forget $tok
$o forget $tok
drain
check forgotten-never-fires 0 [$o count]
$o destroy

# -- destroy with a timer pending: nothing runs, nothing errors --------------

set o [Counter new]
$o arm 1
set obj_name $o
$o destroy
set bg ""
proc bgerror {msg} { append ::bg $msg }
drain
check destroy-cancels-pending "" $bg
check object-gone "" [info commands $obj_name]
rename bgerror ""

# -- two leashed objects do not cross-cancel ---------------------------------

set a [Counter new]
set b [Counter new]
$a arm 1
$b arm 1
$a destroy
drain
check no-cross-cancel 1 [$b count]
$b destroy

# -- a repeating timer re-arms without growing the pending registry ----------

oo::class create Ticker {
    mixin leash
    variable N
    constructor {} { set N 0 }
    method tick {} {
        if {[incr N] < 3} { my later 1 [list [self] tick] }
    }
    method pending {} {
        my variable LeashPending
        return [dict size $LeashPending]
    }
    method count {} { return $N }
}
set t [Ticker new]
$t tick
drain
check repeat-runs-out 3 [$t count]
check registry-holds-pending-only 0 [$t pending]
$t destroy

# -- my coro places the coroutine in the object, and it dies with it ---------

oo::class create Pumper {
    mixin leash
    variable Log
    constructor {} { set Log {} }
    method start {} { return [my coro pump [namespace which my] run] }
    method run {} {
        lappend Log started
        yield
        lappend Log resumed
    }
    method log {} { return $Log }
}
set p [Pumper new]
set co [$p start]
check coro-in-instance-namespace 1 \
    [string equal [namespace qualifiers $co] [info object namespace $p]]
check coro-alive 1 [llength [info commands $co]]
$p destroy
check coro-died-with-object "" [info commands $co]
# a resume timer left pending finds no command: the guard pattern callers use
check orphan-resume-noop "" [expr {[llength [info commands $co]] ? [$co] : ""}]

# -- the coroutine still works while the object lives -------------------------

set p [Pumper new]
set co [$p start]
$co
check coro-resumes {started resumed} [$p log]
check coro-selfdeletes-on-return "" [info commands $co]
$p destroy

# -- mixin destructor chains into the host class's own destructor ------------

set ::chain {}
oo::class create Hosted {
    mixin leash
    destructor { lappend ::chain host }
}
set h [Hosted new]
$h later 1 {lappend ::chain leaked}
$h destroy
drain
check host-destructor-ran {host} $::chain

if {$fails} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
