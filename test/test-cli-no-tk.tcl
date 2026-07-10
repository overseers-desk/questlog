#!/usr/bin/env tclsh9.0
# A GUI dialog popping up during a headless run was a recurring annoyance. Tk
# enters the process only through the ui/ layer, so the command-line path (the
# launcher, config.tcl, lib/, cli/) must stay Tk-free: no `package require Tk`,
# and no library sourcing a ui/ file. This test reads those files and fails if
# either creeps back in. The launcher is the one legitimate sourcer of ui/ (its
# GUI branch), so it is checked only for the require.
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name"
        puts "  expected: $expected"
        puts "  actual:   $actual"
        incr ::fails
    } else {
        puts "ok:   $name"
    }
}

proc slurp {path} {
    set fh [open $path r]
    set t [read $fh]
    close $fh
    return $t
}

# requires_tk: 1 when the file has a `package require Tk/Ttk`.
proc requires_tk {body} {
    return [regexp -line {^[ \t]*package require (?:Tk|Ttk|tk|ttk)} $body]
}

# sources_ui: 1 when a source line names the ui/ directory.
proc sources_ui {body} {
    return [regexp -line {^[ \t]*source.*\mui\M.*\.tcl} $body]
}

# The launcher is the sole legitimate sourcer of ui/, so it is require-checked
# only. The libraries the CLI path sources must be free of both.
set launcher [file join $ROOT questlog]
check "questlog launcher: no 'package require Tk'" 0 [requires_tk [slurp $launcher]]

set lib_files [list [file join $ROOT config.tcl]]
foreach d {lib cli} {
    lappend lib_files {*}[lsort [glob -nocomplain [file join $ROOT $d *.tcl]]]
}
# A module one of those files requires is on the headless path with them, so it
# answers to the same rule. The set is read from their `package require` lines
# rather than listed here, so a module added to the path is checked without this
# test being told about it. A module only the GUI requires (a Tk widget, say) is
# named in no headless file and stays out of scope.
foreach f $lib_files {
    foreach pkg [regexp -all -inline -line {^\s*package require (\w+)} [slurp $f]] {
        if {[string match "package require*" $pkg]} continue
        lappend lib_files {*}[glob -nocomplain [file join $ROOT $pkg-*.tm]]
    }
}
foreach f $lib_files {
    set rel [file join [file tail [file dirname $f]] [file tail $f]]
    set body [slurp $f]
    check "$rel: no 'package require Tk'" 0 [requires_tk $body]
    check "$rel: does not source a ui/ file" 0 [sources_ui $body]
}

if {$fails} { puts "\n$fails test(s) failed"; exit 1 }
puts "\nAll tests passed"
