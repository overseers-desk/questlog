#!/usr/bin/env wish9.0
# The search field, driven standalone through the widgets it builds: the entry,
# the scope menu, the case toggle, the pills. What is covered, in order: the
# typing grammar in both directions; the fragment's always-present keys; the
# quiet programmatic doors against the publishing user gestures; the live
# debounce and Return in both live modes; the region picker; the token pills
# and their two removal routes; and promotion in all three -promoteon modes,
# with the withheld-from-fragment rule, the promote-then-one-publish ordering
# and the kept-term exemption.

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require searchfield

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name\n  expected: <$expected>\n  actual:   <$actual>"
        incr ::fails
    } else { puts "ok:   $name" }
}
proc refused {name script pattern} {
    set caught [catch {uplevel 1 $script} err]
    if {!$caught || ![string match $pattern $err]} {
        puts "FAIL: $name\n  expected an error matching: $pattern\n  actual:   $err"
        incr ::fails
    } else { puts "ok:   $name" }
}

# ---- the harness ----------------------------------------------------------
#
# Every section gets a fresh field in a fresh host frame. The change callback
# and the promotion callback both append to one ::log, so an ordering check
# reads the interleaving straight off it. The promotion callback returns
# whatever ::promote_ret holds: "" consumes the token, anything else keeps it
# as a term.
set FN 0
proc mkfield {args} {
    set f .host[incr ::FN]
    ttk::frame $f
    pack $f -fill x
    set sf [::searchfield::SearchField new]
    $sf configure -debounce 50 -changecommand [list rec publish] {*}$args
    $sf setup $f
    update
    set ::log [list]
    return [list $sf $f]
}
proc rec {what args} { lappend ::log [list $what {*}$args] }
proc promo {tok subs} { rec promote $tok $subs; return $::promote_ret }
proc pubs {} { llength [lsearch -all -index 0 $::log publish] }
proc last_pub {} {
    set idxs [lsearch -all -index 0 $::log publish]
    return [lindex [lindex $::log [lindex $idxs end]] 1]
}
proc log_kinds {} { lmap it $::log { lindex $it 0 } }
# Key events land on the focus window, and no window manager runs on the test
# display, so the focus is forced before each synthetic key.
proc type {e s} {
    focus -force $e; update
    $e insert end $s
    event generate $e <KeyRelease> -keysym space
}
proc hit_return {e} { focus -force $e; update; event generate $e <Return> }
proc drain {ms} { set ::_t 0; after $ms {set ::_t 1}; vwait ::_t }
update

# ---- the grammar, in both directions --------------------------------------

check "whitespace splits, quotes group" {a {b c} d} \
    [::searchfield::split_terms {a "b c" d}]
check "a backslashed quote is a literal, inside a phrase" {{say "hi" now}} \
    [::searchfield::split_terms {"say \"hi\" now"}]
check "and outside one" {d"e} [lindex [::searchfield::split_terms {d\"e}] 0]
check "runs of whitespace add no term" {a b} \
    [::searchfield::split_terms "  a \t  b  "]
check "join quotes a phrase and escapes a literal quote" {a "b c" d\"e} \
    [::searchfield::join_terms {a {b c} d"e}]
check "the round trip loses nothing" [list a {b c} {d"e}] \
    [::searchfield::split_terms [::searchfield::join_terms [list a {b c} {d"e}]]]

# ---- the fragment's keys, and the quiet doors ------------------------------

lassign [mkfield -regions {any "anywhere" sub "Subject line"}] sf f

check "every owned key is present from the first read" \
    {terms {} case 0 region any} [$sf fragment]

# The typed text tokenizes through the one grammar.
$f.e insert end {hello "big world"}
check "the entry's text reaches the fragment tokenized" {hello {big world}} \
    [dict get [$sf fragment] terms]
$f.e delete 0 end

# set_fragment merges a PARTIAL dict and ignores foreign keys, quietly.
$sf set_fragment {terms {a b}}
check "seeding terms leaves case and region standing" {terms {a b} case 0 region any} \
    [$sf fragment]
$sf set_fragment {case 1 region sub}
check "seeding case and region leaves the terms standing" {terms {a b} case 1 region sub} \
    [$sf fragment]
check "and the picker shows the region's label" "Subject line" [$f.scope cget -text]
$sf set_fragment {criteria {{kind q op "" value x}} bogus 1}
check "keys the field does not own are ignored" {terms {a b} case 1 region sub} \
    [$sf fragment]
refused "a region no -regions name declares is refused" \
    {$sf set_fragment {region nope}} "*region 'nope'*"
check "and the refusal wrote nothing" {terms {a b} case 1 region sub} [$sf fragment]

# reset returns to the documented defaults; none of the doors published.
$sf tokens {{label L tag 1}}
$sf reset
check "reset returns the documented defaults" {terms {} case 0 region any} \
    [$sf fragment]
check "no programmatic door published" 0 [pubs]
$sf publish
check "publish fires the callback exactly once" 1 [pubs]
check "with the current fragment appended" {terms {} case 0 region any} [last_pub]
destroy $f; $sf destroy

# ---- live debounce, and Return in both live modes --------------------------

lassign [mkfield -live 1] sf f
type $f.e abc
check "a keystroke publishes nothing at once" 0 [pubs]
check "the user counts as typing through the debounce window" 1 [$sf is_typing]
drain 250
check "the debounce's lapse publishes once" 1 [pubs]
check "with the typed terms" abc [dict get [last_pub] terms]
check "and the burst is over" 0 [$sf is_typing]

# Return cancels the pending debounce, so one gesture is one publish.
set ::log [list]
type $f.e " def"
hit_return $f.e
check "Return publishes at once" 1 [pubs]
drain 250
check "and the cancelled debounce adds no second publish" 1 [pubs]
check "the Return publish carries the full terms" {abc def} \
    [dict get [last_pub] terms]
destroy $f; $sf destroy

lassign [mkfield -live 0] sf f
type $f.e abc
drain 250
check "with -live 0 typing never publishes" 0 [pubs]
hit_return $f.e
check "and Return publishes once" 1 [pubs]
check "with the typed terms" abc [dict get [last_pub] terms]
destroy $f; $sf destroy

# ---- the region picker -----------------------------------------------------

lassign [mkfield -regions {any "anywhere" sub "Subject line" body "Body text"}] sf f
$f.scope.m invoke 2
check "a menu pick moves the fragment's region" body [dict get [$sf fragment] region]
check "and the picker's label" "Body text" [$f.scope cget -text]
check "and publishes once" 1 [pubs]
check "with the region in the fragment" body [dict get [last_pub] region]
$f.scope.m invoke 2
check "re-picking the chosen region moves nothing and publishes nothing" 1 [pubs]
$f.case invoke
check "the case toggle publishes with the bit flipped" {2 1} \
    [list [pubs] [dict get [last_pub] case]]
destroy $f; $sf destroy

# ---- tokens ----------------------------------------------------------------

set ::removed [list]
lassign [mkfield -removecommand {rec2}] sf f
proc rec2 {tag} { lappend ::removed $tag }

$sf tokens {{label "file: a.tcl" tag 7} {label "tool: Bash" tag 9}}
update idletasks
check "the pills are drawn in order, labels the consumer's" \
    {{file: a.tcl} {tool: Bash}} \
    [list [$f.tok.p0.t cget -text] [$f.tok.p1.t cget -text]]

# An unchanged list is a no-op: the same widgets stand, key order regardless.
set id0 [winfo id $f.tok.p0]
$sf tokens {{tag 7 label "file: a.tcl"} {label "tool: Bash" tag 9}}
check "an unchanged list re-set is a no-op" 1 [expr {[winfo id $f.tok.p0] == $id0}]

# The close affordance hands the tag back and removes nothing itself.
$f.tok.p0.x invoke
check "the close glyph routes the tag to -removecommand" {7} $::removed
check "and the pill stands until the consumer re-sets the list" 1 \
    [winfo exists $f.tok.p0]
check "no term moved, so nothing published" 0 [pubs]

# Backspace at the entry's start reaches the last pill; anywhere else it is a
# plain backspace.
focus -force $f.e; update
$f.e insert end xy
$f.e icursor 0
event generate $f.e <BackSpace>
check "Backspace at the start routes the last pill's tag" {7 9} $::removed
$f.e icursor end
event generate $f.e <BackSpace>
check "Backspace mid-text reaches no pill" {7 9} $::removed
refused "a token without a tag is refused" \
    {$sf tokens {{label bare}}} "*token is not a*"
$sf tokens {}
update idletasks
check "an empty list takes the strip away" 0 [winfo ismapped $f.tok]
destroy $f; $sf destroy

# ---- promotion: return mode ------------------------------------------------

set PAT {^([a-z]+):(\S+)$}
set ::promote_ret ""
lassign [mkfield -live 1 -promotepattern $PAT -promotecommand promo] sf f

type $f.e "tool:bash plain"
check "a matching typed token is withheld from the fragment" plain \
    [dict get [$sf fragment] terms]
drain 250
check "and from the live publish" {1 plain} \
    [list [pubs] [dict get [last_pub] terms]]

set ::log [list]
hit_return $f.e
check "Return promotes first, then publishes exactly once" {promote publish} \
    [log_kinds]
check "the callback gets the token and the pattern's captures" \
    {promote tool:bash {tool bash}} [lindex $::log 0]
check "an empty return consumes the token out of the field" plain [$f.e get]
check "and the one publish carries the surviving terms" plain \
    [dict get [last_pub] terms]

# A kept term is exempt until the user edits it.
set ::promote_ret "sess:9"
type $f.e " sess:9"
set ::log [list]
hit_return $f.e
check "a non-empty return keeps the token as a term" {plain sess:9} \
    [dict get [last_pub] terms]
set ::log [list]
hit_return $f.e
check "the kept term is not re-promoted" {publish} [log_kinds]
type $f.e "x"
check "until the user edits it, when it is withheld again" plain \
    [dict get [$sf fragment] terms]

# Terms seeded through set_fragment are never tested.
$sf set_fragment [list terms {tool:bash also}]
set ::log [list]
hit_return $f.e
check "seeded terms pass untested: no promote call, one publish" {publish} \
    [log_kinds]
check "and they ride the fragment whole" {tool:bash also} \
    [dict get [last_pub] terms]
destroy $f; $sf destroy

# ---- promotion: tokenend mode ----------------------------------------------

set ::promote_ret ""
lassign [mkfield -live 1 -promoteon tokenend \
             -promotepattern $PAT -promotecommand promo] sf f
type $f.e "tool:bash"
check "the token under the caret is not yet a token" {} [log_kinds]
check "though the fragment already withholds it" {} [dict get [$sf fragment] terms]
type $f.e " "
check "the completing whitespace promotes at once" {promote} [log_kinds]
drain 250
check "and the debounced publish follows the promotion" {promote publish} \
    [log_kinds]
check "with the token consumed" {} [dict get [last_pub] terms]
destroy $f; $sf destroy

# ---- promotion: focusout mode ----------------------------------------------

set ::promote_ret ""
lassign [mkfield -live 0 -promoteon focusout \
             -promotepattern $PAT -promotecommand promo] sf f
type $f.e "tool:bash stays"
event generate $f.e <FocusOut>
check "leaving the field promotes the withheld token" \
    {promote tool:bash {tool bash}} [lindex $::log 0]
check "and publishes nothing" 0 [pubs]
check "the consumed token's text is gone" stays [$f.e get]
destroy $f; $sf destroy

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
