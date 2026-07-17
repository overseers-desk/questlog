# Event-loop responsiveness probe. Pings the questlog interp via Tk `send`
# every 100ms and logs round-trips to $PING_LOG; a blocked event loop in the
# app shows as a long round-trip. Run under wish on the same display as the
# app (see measure.sh).
package require Tk
wm withdraw .
set f [open $::env(PING_LOG) w]
fconfigure $f -buffering line
proc ping {} {
    set t0 [clock milliseconds]
    set ok [expr {![catch {send questlog {clock milliseconds}}]}]
    set t1 [clock milliseconds]
    puts $::f "$t0 $t1 [expr {$t1 - $t0}] $ok"
    after 100 ping
}
ping
