#!/usr/bin/env wish9.0
# A minimal host over the StreamDoc engine: chrome and regions through the
# content door, the two elide layers, summary sync while a region streams,
# rewind, reveal onto an elided target, and the anchor contract (a parked
# reader unmoved by appends below; the autofollow latch at the tail). Audit
# gate on throughout; the last check asserts it never tripped.

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add $ROOT
package require streamdoc
set ::env(STREAMDOC_AUDIT) 1

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name\n  expected: $expected\n  actual:   $actual"
        incr ::fails
    } else { puts "ok:   $name" }
}
proc tripped {} { return [expr {[info exists ::STREAMDOC_AUDIT_TRIPPED] ? 1 : 0}] }

oo::class create Feed {
    superclass ::streamdoc::StreamDoc
    method summary_text {payload} {
        set n [dict getdef $payload notes 0]
        if {!$n} { return "" }
        return "· $n note[expr {$n == 1 ? "" : "s"}]"
    }
}

pack [ttk::frame .f] -fill both -expand 1
set d [Feed new]
$d setup .f
set T .f.text
$T configure -width 46 -height 10
update

# search with -elide so elided targets still resolve; count -displaychars
# then says whether the line is actually displayed (0 = fully elided).
proc at {pat} { return [$::T search -elide $pat 1.0] }
proc vis {pat} {
    set i [at $pat]
    if {$i eq ""} { return -1 }
    return [$::T count -displaychars $i "$i lineend"]
}
proc has {pat} { return [expr {[at $pat] ne ""}] }

# ---- chrome before any region -------------------------------------------
$d batch {
    set m [$d append_open]
    $d emit $m "prologue chrome\n" {}
    $d emit_window $m -window [ttk::label $T.w0 -text badge]
    $d emit $m "\n" {}
    $d append_close $m
}
check "chrome belongs to no region" -1 [$d region_at [at "prologue"]]
check "no region yet" 0 [$d region_count]

# ---- a region with detail and a summary ----------------------------------
$d batch {
    set r0 [$d region_open [dict create notes 2]]
    set m [$d append_open]
    $d emit $m "▾ First region\n" {}
    $d emit $m "visible body line\n" {}
    $d emit $m "hidden note A\nhidden note B\n" [list [$d detail_tag $r0]]
    $d append_close $m
    $d region_close
}
update
check "region takes index 0" 0 $r0
check "header resolves to its region" 0 [$d region_at [at "First region"]]
check "summary line written from the hook" 1 [has "· 2 notes"]
check "summary carries the default styling tag" 1 \
    [expr {"summary" in [$T tag names [at "· 2 notes"]]}]
check "detail lines are elided by default" 0 [vis "hidden note A"]
check "body line is displayed" 17 [vis "visible body line"]

$d detail_show 0
check "detail_show reveals the notes" 13 [vis "hidden note A"]
check "summary glyph follows detail state" "▾" [$T get "[at {· 2 notes}] -2c"]
$d detail_hide 0
check "detail_hide re-elides" 0 [vis "hidden note A"]
check "summary glyph back to closed" "▸" [$T get "[at {· 2 notes}] -2c"]

$d fold 0
check "fold elides the body" 0 [vis "visible body line"]
check "fold elides the summary" 0 [vis "· 2 notes"]
check "fold leaves the header visible" 1 [expr {[vis "First region"] > 0}]
check "header glyph flips closed" 1 [has "▸ First region"]
$d unfold 0
check "unfold restores the body" 17 [vis "visible body line"]
check "unfold keeps detail hidden" 0 [vis "hidden note A"]
check "header glyph flips open" 1 [has "▾ First region"]
check "no audit trip after fold/detail cycling" 0 [tripped]

# ---- streaming into an open region: summary pop and re-append ------------
$d batch {
    set r1 [$d region_open [dict create notes 0]]
    set m [$d append_open]
    $d emit $m "▾ Second region\nalpha\n" {}
    $d append_close $m
}
check "empty summary phrase takes no summary line" 0 [has "0 note"]
$d payload_set $r1 [dict create notes 1]
$d batch {
    set m [$d append_open]
    $d emit $m "beta\n" {}
    $d append_close $m
}
check "summary appears once the payload counts" 1 [has "· 1 note"]
$d batch {
    set m [$d append_open]
    $d emit $m "gamma\n" {}
    $d append_close $m
}
set doc [$T get 1.0 end]
check "streamed line lands above the summary" 1 \
    [expr {[string first "gamma" $doc] < [string first "· 1 note" $doc]}]
check "popped summary re-appends, not duplicates" 1 [regexp -all {· 1 note} $doc]

# ---- rewind: provisional tail deleted, caller re-emits --------------------
$d batch {
    set m [$d append_open]
    set sp [$d savepoint]
    $d emit $m "provisional tail\n" {}
    $d rewind $sp
    $d emit $m "final tail\n" {}
    $d append_close $m
    $d discard $sp
}
check "rewind removed the provisional emit" 0 [has "provisional tail"]
check "the re-emit landed" 1 [has "final tail"]
check "rewind kept the summary trailing" 1 \
    [expr {[string first "final tail" [$T get 1.0 end]] \
         < [string first "· 1 note" [$T get 1.0 end]]}]
$d region_close
check "close leaves no open region" -1 [$d live]
check "no audit trip after streaming and rewind" 0 [tripped]

# ---- reveal onto an elided target -----------------------------------------
$d fold 0
set idx [at "hidden note A"]
$d reveal $idx
update
check "reveal unfolds the target's region" 1 [expr {[vis "visible body line"] > 0}]
check "reveal shows the detail holding the target" 1 [expr {[vis "hidden note A"] > 0}]
check "reveal lands the target in the viewport" 1 [expr {[$T bbox $idx] ne ""}]

# ---- anchor contract --------------------------------------------------------
for {set i 0} {$i < 25} {incr i} {
    $d batch {
        $d region_open [dict create]
        set m [$d append_open]
        $d emit $m "▾ filler $i\nfiller body $i\n" {}
        $d append_close $m
        $d region_close
    }
}
update
$T yview moveto 0.35
update
set before [$T index @0,0]
$d batch {
    $d region_open [dict create]
    set m [$d append_open]
    $d emit $m "▾ below the fold\nmore content\n" {}
    $d append_close $m
    $d region_close
}
update
check "a parked reader's viewport survives appends below" $before [$T index @0,0]
check "the parked reader is not dragged to the tail" 1 \
    [expr {[lindex [$T yview] 1] < 0.999}]

set ::at ""
bind .f <<AtBottom>>   {set ::at bottom}
bind .f <<LeftBottom>> {set ::at away}
$d configure -autofollow 1
$d follow
update
check "<<AtBottom>> fires on reaching the tail" bottom $::at
$d batch {
    $d region_open [dict create]
    set m [$d append_open]
    $d emit $m "▾ latched arrival\nits body\n" {}
    $d append_close $m
    $d region_close
}
update
check "the autofollow latch keeps the tail in view" 1 \
    [expr {[lindex [$T yview] 1] >= 0.999}]
$T yview moveto 0
update
check "<<LeftBottom>> fires on scrolling away" away $::at

check "audit gate never tripped" 0 [tripped]
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
