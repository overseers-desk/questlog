package require Tcl 9

# ::questlog::cli - parse a command-line criterion chain into the same criteria
# the toolbar produces, so questlog can launch the GUI pre-seeded with them. A
# leading criterion-type token (pattern|read|wrote|edited) is the signal that a
# chain follows; otherwise the -regex flag still prefills a pattern criterion.
# Tokens pair up as type then value.
#
#   questlog <type> <value> [<type> <value> ...]
#
# read/wrote/edited match by path suffix; pattern matches content. The older
# regex/write/edit words are accepted as aliases of pattern/wrote/edited. The
# GUI then behaves normally - the time window stays the user's to set.

namespace eval ::questlog::cli {
    # Accepted criterion words mapped to the canonical toolbar clause kind.
    # pattern/read/wrote/edited are canonical; regex/write/edit are aliases, so
    # the parse output never needs a downstream translation table.
    variable Kinds [dict create \
        pattern pattern  regex pattern \
        read    read \
        wrote   wrote    write wrote \
        edited  edited   edit  edited]
}

proc ::questlog::cli::usage {} {
    puts stderr "usage: questlog <type> <value> \[<type> <value> ...\]"
    puts stderr "  type: pattern | read | wrote | edited  (aliases: regex, write, edit)"
    exit 2
}

# A leading criterion-type token means a criteria chain follows.
proc ::questlog::cli::is_cli {argv} {
    variable Kinds
    return [expr {[llength $argv] > 0 && [dict exists $Kinds [lindex $argv 0]]}]
}

# Parse "type value type value ..." into a list of {type T value V} dicts,
# normalising each word to its canonical toolbar kind.
proc ::questlog::cli::parse {argv} {
    variable Kinds
    if {[llength $argv] == 0 || [llength $argv] % 2 != 0} { ::questlog::cli::usage }
    set criteria [list]
    foreach {type value} $argv {
        if {![dict exists $Kinds $type] || $value eq ""} {
            ::questlog::cli::usage
        }
        lappend criteria [dict create type [dict get $Kinds $type] value $value]
    }
    return $criteria
}
