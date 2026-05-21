package require Tcl 9

# ::csm::cli - parse a command-line criterion chain into the same criteria
# the toolbar produces, so csm can launch the GUI pre-seeded with them. A
# leading criterion-type token (regex|read|write|edit) is the signal that a
# chain follows; otherwise the -regex flag still prefills a regex criterion.
# Tokens pair up as type then value.
#
#   csm <type> <value> [<type> <value> ...]
#
# read/write/edit match by path suffix; regex matches content. The GUI then
# behaves normally - the time window stays the user's to set.

namespace eval ::csm::cli {}

proc ::csm::cli::usage {} {
    puts stderr "usage: csm <type> <value> \[<type> <value> ...\]"
    puts stderr "  type: regex | read | write | edit"
    exit 2
}

# A leading criterion-type token means a criteria chain follows.
proc ::csm::cli::is_cli {argv} {
    return [expr {[llength $argv] > 0
                  && [lindex $argv 0] in {regex read write edit}}]
}

# Parse "type value type value ..." into a list of {type T value V} dicts.
proc ::csm::cli::parse {argv} {
    if {[llength $argv] == 0 || [llength $argv] % 2 != 0} { ::csm::cli::usage }
    set criteria [list]
    foreach {type value} $argv {
        if {$type ni {regex read write edit} || $value eq ""} {
            ::csm::cli::usage
        }
        lappend criteria [dict create type $type value $value]
    }
    return $criteria
}
