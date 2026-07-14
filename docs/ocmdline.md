# ocmdline

## NAME

ocmdline - an ordered command line whose parser and help share one table

## SYNOPSIS

```tcl
package require ocmdline

set cl [ocmdline new grep 2.1]
$cl section pattern {pattern selection:}
$cl option --regexp -section pattern -arg pattern -repeat \
    -fold {lappend patterns $value} \
    -help {{Match lines against this pattern.}}

try {
    set r [$cl parse $argv]
} trap {OCMDLINE HELP} {} {
    $cl print; exit 0
} trap {OCMDLINE VERSION} {} {
    puts [$cl version_line]; exit 0
} trap {OCMDLINE USAGE} {msg} {
    $cl abort $msg
}
```

## DESCRIPTION

A command-line tool usually spells its options in three places: the parsing loop, the help text, and the validation after. They drift and that is source of errors.

ocmdline keeps one table. An option is declared once, with its `-help` text required at declaration, and both questions asked of a command line are answered from that declaration: `parse` reads argv against it, `print` renders the help from it. The help's spelling of an option is the declared token itself, so an option cannot be accepted while absent from the help, appear in the help while unaccepted, or be printed under a spelling the parser does not answer to. Free prose (preamble, epilogue, section notes, refusal reasons) is checked against the same table at first use: a sentence naming an undeclared or misspelled option stops the program at start rather than misleading its reader.

Ordered, because the sequence of occurrences carries meaning that a settings dict throws away: a flag that negates the one after it, a flag that cuts the list in two, a flag repeated once per value. `parse` returns the occurrences in the order they were written, and the caller folds them into whatever they mean to it.

## DECLARATION

**$cl synopsis** *text*, **$cl preamble** *lines*, **$cl epilogue** *lines*
: The argument summary after `usage: <program>`, and free prose above and below the option blocks.

**$cl mode** *name* ?*-default*? ?*-help lines -section key*?
: A way of answering that changes which options make sense. Exactly one mode is the default; having no selecting flag, it declares its own `-help` and `-section` to print under.

**$cl section** *key* *title* ?*-note lines*?
: A titled block of the help.

**$cl option** *token* *-section key* *-help lines* ?*flags*?
: Declare an option. `-arg metavar` takes the next word as a value; `-suffix metavar` accepts a `:suffix`; `-repeat` allows repetition; `-selects mode` makes writing it choose a mode; `-fold script` is what an occurrence means, run by the caller in its own scope with `value` and `suffix` set; `-modes list` restricts it, with `-because text` appended to the refusal; `-check script` validates where the token is met; `-guard script` returns a restriction the current mode is weighed against; `-tag word` is an opaque caller label.

**$cl reject** *token* *message*
: A token known only to be refused with a better message than "unknown option".

**$cl subcommand** *name* *argspec* *help*
: A first-position word that bypasses the option grammar; its usage line prints from this declaration.

`--help` and `--version` are the module's own and need no declaration; declaring them is an error.

## PARSING

**$cl parse** *argv*
: Returns `{mode <name> occurrences {{name .. suffix .. value ..} ..}}`, or throws with `-errorcode` `{OCMDLINE HELP}`, `{OCMDLINE VERSION}`, or `{OCMDLINE USAGE}` (the message says how the line is malformed). Mode restrictions are weighed after every token is read, since the mode is only known then, and a refusal names the flag that would have made the option legal, worked out from the table rather than written into the message.

**$cl asks** *argv*
: `help`, `version`, or the empty string. For a caller that must not act (write a file, spend a second loading libraries) before knowing whether it will only print the help.

**$cl print** ?*channel*?, **$cl version_line**, **$cl abort** *msg*
: Render the help from the table; the version line; report a malformed line on stderr, print the help, exit 2.

**$cl fold_of** *name*, **$cl tag_of** *name*, **$cl subcommand_of** *argv*, **$cl subcommand_usage** *name*
: Read the table back.

## REQUIREMENTS

Tcl 9. No Tk, no dependencies.

## KEYWORDS

argv, command line, option parsing, getopt, usage, help
