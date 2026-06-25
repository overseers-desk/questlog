#!/usr/bin/env tclsh9.0
# The TextTree engine owns every text-mark mutation: the SessionList subclass
# drives the widget only through the primitive ensemble and holds no raw
# `$Text insert/delete/mark` of its own. This guards that boundary so a future
# change cannot quietly reintroduce the scattered mark surgery the engine was
# built to absorb (the base engine in ui/texttree.tcl keeps them by design).
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name\n  expected: $expected\n  actual:   $actual"
        incr ::fails
    } else { puts "ok:   $name" }
}

# Raw mutations in code, excluding comment lines (a `#`-leading line).
proc raw_mutations {path} {
    set hits [list]
    set fh [open $path r]
    set lineno 0
    foreach line [split [read $fh] \n] {
        incr lineno
        if {[regexp {^\s*#} $line]} continue
        if {[regexp {\$Text (insert|delete|mark)\M} $line]} {
            lappend hits "$lineno: [string trim $line]"
        }
    }
    close $fh
    return $hits
}

set hits [raw_mutations [file join $ROOT ui/sessions.tcl]]
if {[llength $hits]} { puts "  raw mutation sites:\n    [join $hits "\n    "]" }
check "ui/sessions.tcl holds no raw \$Text insert/delete/mark" 0 [llength $hits]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
