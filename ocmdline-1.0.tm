package require Tcl 9
package provide ocmdline 1.0

# ocmdline - an ordered command line.
#
# A command line is declared one option at a time, and the declaration answers
# both questions asked of it: `parse` reads argv against it, and `print` renders
# the help from it. The help's spelling of an option is the declared token
# itself, so an option cannot be accepted while absent from the help, appear in
# the help while unaccepted, or be printed under a spelling the parser does not
# answer to. Prose is read against the same table, so a sentence naming an
# option that was never declared stops the program at start rather than
# misleading its reader.
#
# Ordered, because the sequence of occurrences carries meaning that a settings
# dict throws away: a flag that negates the one after it, a flag that cuts the
# list in two, a flag repeated once per value. `parse` returns the occurrences
# in the order they were written, and the caller folds them into whatever they
# mean to it.
#
#   package require ocmdline
#   set cl [ocmdline new grep 2.1]
#   $cl section pattern {pattern selection:}
#   $cl option --regexp -section pattern -arg pattern -repeat \
#       -help {Match lines against this pattern.}
#   set r [$cl parse $argv]      ;# {mode <name> occurrences {{name .. suffix .. value ..} ..}}
#
# A mode is a way of answering that changes which options make sense. One mode
# is the default and needs no flag; the others are selected by an option
# declared `-selects`. An option restricted with `-modes` is refused in the
# others, and the refusal names the flag that would have made it legal, worked
# out from the table rather than written into the message.

oo::class create ocmdline {
    variable Program Version Synopsis Preamble Epilogue
    variable Modes DefaultMode Sections Options Rejects Subcommands Sealed

    constructor {program {version ""}} {
        set Program $program
        set Version $version
        set Synopsis "\[options]"
        set Preamble [list]
        set Epilogue [list]
        set Modes [dict create]
        set DefaultMode ""
        set Sections [list]
        set Options [dict create]
        set Rejects [dict create]
        set Subcommands [list]
        set Sealed 0
    }

    # The argument summary after "usage: <program>", and free prose above and
    # below the option blocks. Every option these name is checked at seal.
    method synopsis {text} { set Synopsis $text }
    method preamble {lines} { set Preamble $lines }
    method epilogue {lines} { set Epilogue $lines }

    # A way of answering. Exactly one mode is the default: it is what running
    # with no selecting flag means. Having no flag, it has nothing to print its
    # help from, so the default mode declares its own -help and the -section it
    # prints under; a mode a flag selects says nothing here, because that flag's
    # own declaration already describes it.
    method mode {name args} {
        set default 0
        set idx [lsearch -exact $args -default]
        if {$idx >= 0} {
            set default 1
            set args [lreplace $args $idx $idx]
            if {$DefaultMode ne ""} { error "ocmdline: two default modes: $DefaultMode and $name" }
            set DefaultMode $name
        }
        set spec [dict create help {} section "" default $default]
        foreach {k v} $args {
            set key [string range $k 1 end]
            if {$key ni {help section}} { error "ocmdline: mode $name: unknown declaration $k" }
            dict set spec $key $v
        }
        if {$default && ([dict get $spec help] eq "" || [dict get $spec section] eq "")} {
            error "ocmdline: the default mode $name needs -help and -section"
        }
        dict set Modes $name $spec
    }

    # A titled block of the help, with optional prose beneath its options.
    method section {key title args} {
        set note [list]
        if {[lindex $args 0] eq "-note"} { set note [lindex $args 1]; set args [lrange $args 2 end] }
        my NoLeftovers $key $args
        lappend Sections [dict create key $key title $title note $note]
    }

    # Declare an option. Its token is what the parser matches and what the help
    # prints; there is no third place to say it. -help is required: an option is
    # declared together with the words that describe it, or not at all.
    #
    #   -section <key>   the help block it prints under (required)
    #   -arg <metavar>   it takes the argument after it, shown as <metavar>
    #   -suffix <metavar>  it accepts a `:suffix`, shown as [:metavar]; a token
    #                    ending in ':' takes the suffix as part of itself
    #   -repeat          it may be written more than once
    #   -selects <mode>  writing it chooses that mode
    #   -fold <script>   what an occurrence of it means, run by the caller in
    #                    its own scope with `value` and `suffix` set. An option
    #                    does something: it declares -selects, or -fold, or both,
    #                    since one that does neither would print in the help and
    #                    then be a no-op.
    #   -modes <list>    it is legal only in these modes
    #   -because <text>  why, appended to the refusal -modes produces
    #   -check <script>  run where the token is met, with `value` and `suffix`
    #                    set; return an error message to reject it, or "" to
    #                    accept
    #   -tag <word>      an opaque label the caller reads back with `tag_of`,
    #                    to group options without keeping a list beside the table
    #   -guard <script>  run with `value` and `suffix` set; return {} when the
    #                    occurrence asks for nothing special, or a restriction
    #                    {subject <text> modes <list> because <text>} naming what
    #                    it asks for and where that is legal. The mode it was
    #                    written in decides whether the restriction bites.
    method option {name args} {
        set help [my TakeHelp $name args]
        set spec [dict create help $help section "" arg "" suffix "" repeat 0 \
            selects "" modes {} because "" check "" guard "" fold "" tag ""]
        set idx [lsearch -exact $args -repeat]
        if {$idx >= 0} {
            dict set spec repeat 1
            set args [lreplace $args $idx $idx]
        }
        foreach {k v} $args {
            set key [string range $k 1 end]
            if {![dict exists $spec $key] || $key in {help repeat}} {
                error "ocmdline: $name: unknown declaration $k"
            }
            dict set spec $key $v
        }
        if {[dict get $spec section] eq ""} { error "ocmdline: $name has no -section" }
        if {[string index $name end] eq ":" && [dict get $spec suffix] eq ""} {
            error "ocmdline: $name ends in a colon and so needs -suffix"
        }
        if {[dict get $spec selects] eq "" && [dict get $spec fold] eq ""} {
            error "ocmdline: $name does nothing: give it -selects or -fold"
        }
        my Reserved $name
        set clash [my SelectorOf [dict get $spec selects]]
        if {[dict get $spec selects] ne "" && $clash ne ""} {
            error "ocmdline: $name and $clash both select [dict get $spec selects]"
        }
        dict set Options $name $spec
    }

    # --help and --version are answered from the table itself, so a caller that
    # declared either would print a line the parser never reaches.
    method Reserved {token} {
        if {$token in {--help --version}} {
            error "ocmdline: $token is the module's own; it needs no declaration"
        }
    }

    # A token the parser knows only in order to refuse it with a better message
    # than "unknown option". It is not accepted, so it is not printed.
    method reject {token message} {
        my Reserved $token
        dict set Rejects $token $message
    }

    # A word in the first position that runs something other than the option
    # grammar. Its usage line is printed from this declaration.
    method subcommand {name argspec help} {
        lappend Subcommands [dict create name $name argspec $argspec help $help]
    }

    # How a subcommand is written, and what it does, for the subcommand that
    # finds its own arguments wrong. Printed from the one declaration, so it
    # cannot describe a spelling the dispatcher does not answer to.
    method subcommand_usage {name} {
        foreach s $Subcommands {
            if {[dict get $s name] ne $name} continue
            return [list [string trimright "usage: $Program $name [dict get $s argspec]"] \
                "  [dict get $s help]"]
        }
        error "ocmdline: no such subcommand: $name"
    }

    # Which of the module's own answers argv asks for - `help`, `version`, or ""
    # for neither. Reading argv costs nothing, so a caller that must not act
    # before it knows (one that would otherwise write a file, or spend a second
    # loading libraries) asks here first. `parse` answers the same two requests
    # on its own, for the caller with nothing to hold back.
    method asks {argv} {
        foreach tok $argv {
            if {$tok eq "--help"} { return help }
            if {$tok eq "--version" && $Version ne ""} { return version }
        }
        return ""
    }

    # What an occurrence of this option means, for the caller to run in its own
    # scope. Empty for an option whose whole effect is choosing a mode.
    method fold_of {name} { return [dict get $Options $name fold] }

    # The caller's own label for this option, or "".
    method tag_of {name} { return [dict get $Options $name tag] }

    # The subcommand argv asks for, or "" when it asks for the option grammar.
    method subcommand_of {argv} {
        set first [lindex $argv 0]
        foreach s $Subcommands {
            if {[dict get $s name] eq $first} { return $first }
        }
        return ""
    }

    # Parse argv into the ordered occurrences, or throw. The caller answers the
    # three throws: two of them are what the user asked for, the third is not.
    #
    #   {OCMDLINE HELP}     --help was written
    #   {OCMDLINE VERSION}  --version was written
    #   {OCMDLINE USAGE}    the command line is malformed; the message says how
    method parse {argv} {
        my Seal
        set occurrences [list]
        set mode $DefaultMode
        set chosen ""
        set seen [dict create]
        for {set i 0} {$i < [llength $argv]} {incr i} {
            set tok [lindex $argv $i]
            if {$tok eq "--help"} { return -code error -errorcode {OCMDLINE HELP} "" }
            if {$tok eq "--version" && $Version ne ""} {
                return -code error -errorcode {OCMDLINE VERSION} ""
            }
            if {[dict exists $Rejects $tok]} { my fail [dict get $Rejects $tok] }
            lassign [my Lookup $tok] name suffix
            if {$name eq ""} {
                if {[string match -* $tok]} { my fail "unknown option: $tok" }
                my fail "unexpected argument '$tok'"
            }
            set spec [dict get $Options $name]
            if {![dict get $spec repeat]} {
                if {[dict exists $seen $name]} { my fail "$name given twice" }
                dict set seen $name 1
            }
            set value ""
            if {[dict get $spec arg] ne ""} {
                incr i
                if {$i >= [llength $argv]} { my fail "$tok needs a value" }
                set value [lindex $argv $i]
            }
            set check [dict get $spec check]
            if {$check ne ""} {
                set why [eval $check]
                if {$why ne ""} { my fail $why }
            }
            set selects [dict get $spec selects]
            if {$selects ne ""} {
                if {$chosen ne "" && $chosen ne $selects} {
                    my fail "choose one output: [my ModeFlags [list $chosen $selects]]"
                }
                set chosen $selects
                set mode $selects
            }
            lappend occurrences [dict create name $name suffix $suffix value $value]
        }
        # The mode is known only once every token is read, so what a mode forbids
        # is weighed here rather than where the token was met.
        foreach o $occurrences {
            set spec [dict get $Options [dict get $o name]]
            set allowed [dict get $spec modes]
            if {[llength $allowed] && $mode ni $allowed} {
                my Refuse [dict create subject [dict get $o name] modes $allowed \
                    because [dict get $spec because]] $mode
            }
            set guard [dict get $spec guard]
            if {$guard ne ""} {
                set value [dict get $o value]
                set suffix [dict get $o suffix]
                set restriction [eval $guard]
                if {[llength $restriction] && $mode ni [dict get $restriction modes]} {
                    my Refuse $restriction $mode
                }
            }
        }
        return [dict create mode $mode occurrences $occurrences]
    }

    # Print what --version asks for.
    method version_line {} { return "$Program $Version" }

    # Throw a malformed-command-line error carrying this message.
    method fail {msg} { return -code error -errorcode {OCMDLINE USAGE} $msg }

    # Report a malformed command line and exit, for a caller whose own reading
    # of the occurrences finds them contradictory.
    method abort {msg} {
        puts stderr "$Program: $msg"
        my print stderr
        exit 2
    }

    # Print the help. Every option line is rendered from its declaration.
    method print {{channel stdout}} {
        my Seal
        foreach line $Preamble { puts $channel $line }
        if {[llength $Preamble]} { puts $channel "" }
        puts $channel "usage: $Program $Synopsis"
        foreach s $Subcommands {
            puts $channel [string trimright \
                "       $Program [dict get $s name] [dict get $s argspec]"]
        }
        if {$Version ne ""} { puts $channel "       $Program --version" }
        set w [my Width]
        foreach sec $Sections {
            puts $channel ""
            puts $channel [dict get $sec title]
            dict for {name spec} $Options {
                if {[dict get $spec section] ne [dict get $sec key]} continue
                my Entry $channel $w [my Spelling $name] [dict get $spec help]
            }
            # A mode no flag selects is described here, since it has no flag of
            # its own to print it.
            dict for {name m} $Modes {
                if {[dict get $m section] ne [dict get $sec key]} continue
                if {[my SelectorOf $name] ne ""} continue
                my Entry $channel $w "(neither)" [dict get $m help]
            }
            foreach line [dict get $sec note] { puts $channel $line }
        }
        puts $channel ""
        my Entry $channel $w --help {{Print this help and exit.}}
        if {$Version ne ""} {
            my Entry $channel $w --version {{Print the version and exit.}}
        }
        set restricted [my RestrictedLines]
        if {[llength $restricted]} {
            puts $channel ""
            foreach line $restricted { puts $channel $line }
        }
        foreach line $Epilogue { puts $channel $line }
    }

    # ---- rendering ---------------------------------------------------------

    # The token as the help shows it: the declared spelling, its suffix, and its
    # argument. Nothing here is a string the caller wrote.
    method Spelling {name} {
        set spec [dict get $Options $name]
        set suffix [dict get $spec suffix]
        set arg [dict get $spec arg]
        if {[string index $name end] eq ":"} {
            set out "$name<$suffix>"
        } elseif {$suffix ne ""} {
            set out "$name\[:$suffix]"
        } else {
            set out $name
        }
        if {$arg ne ""} { append out " <$arg>" }
        return $out
    }

    method Width {} {
        set w [string length "--version"]
        dict for {name spec} $Options {
            set w [expr {max($w, [string length [my Spelling $name]])}]
        }
        return [expr {max($w, [string length "(neither)"])}]
    }

    method Entry {channel w left help} {
        puts $channel [format "  %-*s  %s" $w $left [lindex $help 0]]
        foreach line [lrange $help 1 end] {
            puts $channel [format "  %-*s  %s" $w "" $line]
        }
    }

    # The flag that chooses a mode, or "" for the default mode.
    method SelectorOf {mode} {
        dict for {name spec} $Options {
            if {[dict get $spec selects] eq $mode} { return $name }
        }
        return ""
    }

    # The modes named as the flags that choose them, joined for a refusal to
    # quote: "--brief or --terse".
    method ModeFlags {modes} {
        set flags [list]
        foreach m $modes {
            set f [my SelectorOf $m]
            if {$f ne ""} { lappend flags $f }
        }
        return [join $flags " or "]
    }

    # The sentence naming what the default mode cannot do, from the options that
    # forbid it, so it cannot outlive them.
    method RestrictedLines {} {
        if {$DefaultMode eq ""} { return {} }
        # Options that forbid the default mode, gathered by the modes they do
        # allow: each set of modes earns its own sentence, so no option is
        # printed under a flag that would not in fact admit it.
        set byModes [dict create]
        dict for {name spec} $Options {
            set allowed [dict get $spec modes]
            if {[llength $allowed] && $DefaultMode ni $allowed} {
                dict lappend byModes $allowed $name
            }
        }
        set lines [list]
        dict for {allowed names} $byModes {
            lappend lines "Only with [my ModeFlags $allowed]: [join $names {, }]."
        }
        return $lines
    }

    # ---- refusal -----------------------------------------------------------

    # Refuse a restriction: what it is about, where it would be legal, and why.
    # The flags come from the table.
    method Refuse {restriction mode} {
        set subject [dict get $restriction subject]
        set allowed [dict get $restriction modes]
        set because [dict getdef $restriction because ""]
        set flags [my ModeFlags $allowed]
        if {$flags eq ""} {
            set msg "$subject is not available with [my SelectorOf $mode]"
        } else {
            set msg "$subject needs $flags"
        }
        if {$because ne ""} { append msg " ($because)" }
        set tok [my Undeclared $msg]
        if {$tok ne ""} {
            error "ocmdline: a refusal names an undeclared option: $tok"
        }
        my fail $msg
    }

    # ---- lookup ------------------------------------------------------------

    # The option a token names, and the suffix it carries. A token ending in ':'
    # swallows the rest as its suffix; an option declared with -suffix accepts
    # ':' and the rest. An undeclared token yields the empty name.
    method Lookup {tok} {
        if {[dict exists $Options $tok]} { return [list $tok ""] }
        dict for {name spec} $Options {
            if {[string index $name end] eq ":"} {
                if {[string match $name* $tok]} {
                    return [list $name [string range $tok [string length $name] end]]
                }
            } elseif {[dict get $spec suffix] ne "" && [string match $name:* $tok]} {
                return [list $name [string range $tok [expr {[string length $name] + 1}] end]]
            }
        }
        return [list "" ""]
    }

    # ---- declaration-time enforcement --------------------------------------

    # -help is what makes an option readable, so a declaration without it is not
    # a declaration. Raised where the caller wrote it.
    method TakeHelp {name argsVar} {
        upvar 1 $argsVar a
        set idx [lsearch -exact $a -help]
        if {$idx < 0} { error "ocmdline: $name declared without -help" }
        set help [lindex $a $idx+1]
        set a [lreplace $a $idx $idx+1]
        return $help
    }

    method NoLeftovers {name a} {
        if {[llength $a]} { error "ocmdline: $name: unknown declaration [lindex $a 0]" }
    }

    # The first option a line names that the table does not hold, or "". Every
    # word a reader could mistake for a flag is weighed: two dashes or one, with
    # or without a suffix.
    method Undeclared {line} {
        foreach tok [regexp -all -inline -- {--[A-Za-z][A-Za-z0-9-]*(?::[^ ,)\]<]*)?} $line] {
            if {$tok in {--help --version}} continue
            if {[dict exists $Rejects $tok]} continue
            lassign [my Lookup $tok] hit -
            if {$hit eq ""} { return $tok }
        }
        foreach tok [regexp -all -inline -line -- {(?:^|\s)(-[A-Za-z][A-Za-z0-9-]*)} $line] {
            if {[string index $tok 0] ne "-"} continue
            if {[dict exists $Rejects $tok]} continue
            lassign [my Lookup $tok] hit -
            if {$hit eq ""} { return $tok }
        }
        return ""
    }

    # Prose names options; the table decides whether they exist. A sentence that
    # names an undeclared or misspelled option stops the program the first time
    # anyone runs it, rather than teaching its reader a token the parser refuses.
    method Seal {} {
        if {$Sealed} return
        set Sealed 1
        if {$DefaultMode eq "" && [dict size $Modes]} {
            error "ocmdline: modes are declared but none is -default"
        }
        # A mode an option names must exist, or the refusal it produces would
        # point at a flag the help never prints.
        dict for {name spec} $Options {
            foreach m [concat [dict get $spec selects] [dict get $spec modes]] {
                if {$m ne "" && ![dict exists $Modes $m]} {
                    error "ocmdline: $name names an undeclared mode: $m"
                }
            }
        }
        # Every string a reader can meet: the blocks around the options, each
        # option's help and the reason its refusal gives, each mode's and each
        # subcommand's help, and what a rejected token says for itself.
        set prose $Preamble
        lappend prose $Synopsis {*}$Epilogue
        foreach sec $Sections { lappend prose {*}[dict get $sec note] }
        dict for {name spec} $Options {
            lappend prose {*}[dict get $spec help] [dict get $spec because]
        }
        dict for {name m} $Modes { lappend prose {*}[dict get $m help] }
        foreach s $Subcommands { lappend prose [dict get $s help] }
        dict for {token message} $Rejects { lappend prose $message }
        foreach line $prose {
            set tok [my Undeclared $line]
            if {$tok ne ""} {
                error "ocmdline: help text names an undeclared option: $tok"
            }
        }
    }
}
