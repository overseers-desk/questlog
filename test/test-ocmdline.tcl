#!/usr/bin/env tclsh9.0
# Tests for the ocmdline module: that a declaration is the only way to make an
# option exist, that it exists in the help and in the parser together or not at
# all, and that the ordered occurrences come back in the order they were written.
# The command lines here are invented for the tests; the module knows nothing of
# any program that uses it.
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add $ROOT
package require ocmdline

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
# The error a script raises, or "" when it raises none.
proc raises {script} {
    if {[catch {uplevel 1 $script} e]} { return $e }
    return ""
}
# The usage message a malformed command line produces, or "" when it parses.
proc usage_error {cl argv} {
    if {[catch {$cl parse $argv} e opts] &&
        [lrange [dict get $opts -errorcode] 0 1] eq {OCMDLINE USAGE}} { return $e }
    return ""
}
# The help as one string.
proc help_text {cl} {
    set f [file join [file dirname [info script]] _ocmdline_help.txt]
    set h [open $f w]
    $cl print $h
    close $h
    set h [open $f r]; set t [read $h]; close $h
    file delete $f
    return $t
}

# A grammar with one of everything, rebuilt per test that mutates it.
proc grammar {} {
    set cl [ocmdline new mailer 3.2]
    $cl synopsis {[--brief] [options]}
    $cl section pick {selection:}
    $cl section out {output:}
    $cl mode full -default -section out -help {{Print every header.}}
    $cl mode brief -section out
    $cl option --brief -section out -selects brief -help {{Print one line each.}}
    $cl option --from -section pick -repeat -suffix domain -arg address \
        -tag address -fold {lappend from $value} -help {{Mail from this address.}}
    $cl option --before -section pick -arg date -fold {set before $value} \
        -help {{Mail older than this date.}}
    $cl option --verbose -section out -fold {set verbose 1} \
        -help {{Say more while working.}}
    return $cl
}

# ---- a declaration is the only way to make an option exist -----------------
# Each of these is a defect the module makes unwritable: the call itself fails,
# where it is written, rather than producing a grammar that parses one thing and
# prints another.
check no_help    {ocmdline: --x declared without -help} \
    [raises {[ocmdline new p] option --x -section s}]
check no_section {ocmdline: --x has no -section} \
    [raises {[ocmdline new p] option --x -fold {set x 1} -help {{Do a thing.}}}]
check bad_decl   {ocmdline: --x: unknown declaration -colour} \
    [raises {[ocmdline new p] option --x -section s -colour red -help {{Do a thing.}}}]
check colon_needs_suffix {ocmdline: --tool: ends in a colon and so needs -suffix} \
    [raises {[ocmdline new p] option --tool: -section s -fold {set t 1} -help {{Use a tool.}}}]
check two_defaults {ocmdline: two default modes: a and b} \
    [raises {set c [ocmdline new p]
             $c mode a -default -section s -help {{A.}}
             $c mode b -default -section s -help {{B.}}}]

# Prose is checked against the same table, so a sentence naming an option that
# was never declared stops the program rather than teaching a reader a token the
# parser refuses. The check runs at the first parse or print, by which time
# every declaration has been made.
set cl [grammar]
$cl preamble {{Write --form to choose an address.}}
check prose_undeclared {ocmdline: help text names an undeclared option: --form} \
    [raises {$cl parse {}}]
set cl [grammar]
$cl preamble {{Write --from to choose an address.}}
check prose_declared "" [raises {$cl parse {}}]

# ---- the help prints what the parser accepts, and nothing else -------------
set cl [grammar]
set h [help_text $cl]
foreach opt {--brief --from --before --verbose --help --version} {
    check "help_lists $opt" 1 [expr {[string first $opt $h] >= 0}]
}
# The spelling is generated from the declaration: the token, its suffix, its
# argument. No caller writes it out, so none can write it differently.
check help_spelling 1 [expr {[string first {--from[:domain] <address>} $h] >= 0}]
check help_synopsis 1 [expr {[string first {usage: mailer [--brief] [options]} $h] >= 0}]
check help_default_mode 1 [string match "*(neither)*Print every header.*" $h]
# A mode a flag selects is described by that flag alone, so its help appears once.
check help_no_double_brief 1 [expr {[regexp -all -- {Print one line each} $h] == 1}]

# ---- ordered occurrences ---------------------------------------------------
# The sequence is the meaning: a repeated option keeps every occurrence, in
# order, each with the suffix and value written beside it.
set cl [grammar]
set p [$cl parse {--from a@x --from:work b@y --verbose}]
check occ_order {--from --from --verbose} [lmap o [dict get $p occurrences] { dict get $o name }]
check occ_values {a@x b@y {}} [lmap o [dict get $p occurrences] { dict get $o value }]
check occ_suffix {{} work {}} [lmap o [dict get $p occurrences] { dict get $o suffix }]

# ---- modes -----------------------------------------------------------------
set cl [grammar]
check mode_default full  [dict get [$cl parse {}] mode]
check mode_selected brief [dict get [$cl parse {--brief}] mode]

# ---- what a malformed command line says ------------------------------------
set cl [grammar]
check err_unknown  {unknown option: --nope}         [usage_error $cl {--nope}]
check err_bare     {unexpected argument 'stray'}    [usage_error $cl {stray}]
check err_novalue  {--before needs a value}         [usage_error $cl {--before}]
check err_twice    {--before given twice}           [usage_error $cl {--before 1 --before 2}]
check err_repeat_ok ""                              [usage_error $cl {--from a --from b}]

# A rejected token is not accepted, so it is not printed; it exists only to say
# something better than "unknown option".
set cl [grammar]
$cl reject --and {use adjacency, not --and}
check err_reject {use adjacency, not --and} [usage_error $cl {--and}]
check reject_unprinted 0 [expr {[string first {use adjacency} [help_text $cl]] >= 0}]

# ---- a value the option refuses --------------------------------------------
set cl [grammar]
$cl option --count -section pick -arg n -fold {set count $value} \
    -check {expr {[string is integer -strict $value] ? "" : "--count: not a number: '$value'"}} \
    -help {{How many to print.}}
check err_check  {--count: not a number: 'lots'} [usage_error $cl {--count lots}]
check check_pass "" [usage_error $cl {--count 4}]

# ---- a value only some modes can answer ------------------------------------
# The refusal names the flag that would have made it legal, worked out from the
# table, so it cannot outlive the flag it names.
set cl [grammar]
$cl option --wrap -section out -arg cols -fold {set wrap $value} \
    -modes {brief} -because {full output never wraps} -help {{Wrap at this column.}}
check err_mode {--wrap needs --brief (full output never wraps)} [usage_error $cl {--wrap 72}]
check mode_ok  "" [usage_error $cl {--brief --wrap 72}]

# A restriction the value asks for, rather than the option's presence: the guard
# reads the occurrence and names what it asks for.
set cl [grammar]
$cl option --sort -section out -arg key -fold {set sort $value} \
    -guard {expr {$value eq "size" ? [dict create subject {sorting by size} \
        modes brief because {full output has no size column}] : {}}} \
    -help {{Sort by this key.}}
check err_guard {sorting by size needs --brief (full output has no size column)} \
    [usage_error $cl {--sort size}]
check guard_quiet "" [usage_error $cl {--sort date}]
check guard_mode_ok "" [usage_error $cl {--brief --sort size}]

# An option legal only in the flagless default mode names the flag that excludes
# it, since there is no flag to point at instead.
set cl [grammar]
$cl option --pager -section out -fold {set pager 1} -modes {full} \
    -because {one line needs no pager} -help {{Page the output.}}
check err_default_only {--pager is not available with --brief (one line needs no pager)} \
    [usage_error $cl {--brief --pager}]

# The help's summary of what the default mode cannot do says, of every restricted
# option, the same flag the parser demands of it. Options restricted to different
# modes each get their own sentence, so none is listed under a flag that would
# not admit it.
set cl [ocmdline new t]
$cl section s {s:}
$cl mode full -default -section s -help {{Everything.}}
$cl mode brief -section s
$cl mode wide -section s
$cl option --brief -section s -selects brief -help {{Brief.}}
$cl option --wide -section s -selects wide -help {{Wide.}}
$cl option --one -section s -fold {set one 1} -modes {brief} -help {{Only brief.}}
$cl option --two -section s -fold {set two 1} -modes {wide} -help {{Only wide.}}
set h [help_text $cl]
check restricted_by_brief 1 [expr {[string first {Only with --brief: --one.} $h] >= 0}]
check restricted_by_wide  1 [expr {[string first {Only with --wide: --two.} $h] >= 0}]
# The parser demands of each option exactly the flag the help named for it.
check restricted_agrees_one {--one needs --brief} [usage_error $cl {--one}]
check restricted_agrees_two {--two needs --wide}  [usage_error $cl {--two}]

# ---- one flag per mode ------------------------------------------------------
# Two flags choosing one mode would leave a refusal naming whichever was
# declared first, so the second declaration is refused instead.
check err_two_selectors {ocmdline: --terse and --brief both select brief} \
    [raises {set c [grammar]
             $c option --terse -section out -selects brief -help {{Also brief.}}}]

# A mode an option names must have been declared, or a refusal would point at a
# flag the help never prints.
check err_undeclared_mode {ocmdline: --wide names an undeclared mode: roomy} \
    [raises {set c [grammar]
             $c option --wide -section out -fold {set wide 1} -modes {roomy} -help {{Roomy.}}
             $c parse {}}]

# ---- --help and --version answer from the table ----------------------------
# Declaring either would print a line the parser never reaches, so neither can
# be declared, nor shadowed by a rejected token.
check err_reserved_option {ocmdline: --help is the module's own; it needs no declaration} \
    [raises {[ocmdline new p] option --help -section s -fold {set h 1} -help {{Mine.}}}]
check err_reserved_reject {ocmdline: --version is the module's own; it needs no declaration} \
    [raises {[ocmdline new p] reject --version {no}}]

# `asks` reads argv for the module's own answers without touching anything else,
# for a caller that must hold back a side effect until it knows.
set cl [grammar]
check asks_help    help    [$cl asks {--from a --help}]
check asks_version version [$cl asks {--version}]
check asks_neither ""      [$cl asks {--from a}]

# An option is written with two dashes, so prose naming a single-dash word names
# something the parser will not answer to.
check err_prose_single_dash {ocmdline: help text names an undeclared option: -f} \
    [raises {set c [grammar]
             $c preamble {{Write -f to choose an address.}}
             $c parse {}}]

# ---- --help and --version are the module's, not the caller's ---------------
set cl [grammar]
check help_throws  {OCMDLINE HELP} \
    [catch {$cl parse {--help}} e opts; lrange [dict get $opts -errorcode] 0 1]
check version_throws {OCMDLINE VERSION} \
    [catch {$cl parse {--version}} e opts; lrange [dict get $opts -errorcode] 0 1]
check version_line {mailer 3.2} [$cl version_line]

# An option that neither chooses a mode nor carries a fold would print in the
# help and then mean nothing, so it cannot be declared.
check err_inert {ocmdline: --idle does nothing: give it -selects or -fold} \
    [raises {set c [grammar]; $c option --idle -section out -help {{Nothing.}}}]

# Every string a reader can meet answers to the table: the reason a refusal
# gives, and what a rejected token says for itself.
check err_because_undeclared {ocmdline: help text names an undeclared option: --typeface} \
    [raises {set c [grammar]
             $c option --wrap -section out -fold {set w 1} -modes {brief} \
                 -because {use --typeface} -help {{Wrap.}}
             $c parse {}}]
check err_reject_undeclared {ocmdline: help text names an undeclared option: --group} \
    [raises {set c [grammar]
             $c reject --and {use --group instead}
             $c parse {}}]

# A guard names its reason at refusal time, so that reason answers to the table
# too, rather than sending a reader after a flag that does not exist.
check err_guard_undeclared {ocmdline: a refusal names an undeclared option: --plain} \
    [raises {set c [grammar]
             $c option --sort -section out -arg key -fold {set s 1} \
                 -guard {dict create subject {sorting} modes brief because {try --plain}} \
                 -help {{Sort.}}
             $c parse {--sort size}}]

# ---- subcommands -----------------------------------------------------------
set cl [grammar]
$cl subcommand send {<file>} {Send the file.}
check sub_hit  send [$cl subcommand_of {send x}]
check sub_miss ""   [$cl subcommand_of {--brief}]
check sub_usage 1 [expr {[string first {mailer send <file>} [help_text $cl]] >= 0}]

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
