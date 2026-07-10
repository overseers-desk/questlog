package require Tcl 9
package require ocmdline

# questlog's command line, declared once. The ocmdline object below both parses
# argv and prints `--help`, so the grammar has one statement and no second list
# to fall out of step with it.
#
# `parse` folds the ordered occurrences into a neutral query dict: the clause
# groups of the boolean algebra, and the bounds that ride outside it. The dict
# names no matcher leaf and no toolbar clause, so cli/main.tcl folds it one way
# for the answer on stdout and the launcher folds it another to seed the GUI,
# neither owning the grammar.
#
# `--json` or `--shortstat` asks for the answer on stdout; without either, the
# query opens the GUI on itself. Nothing here requires Tk, so `--help` and every
# parse error answer without a display.

namespace eval ::questlog::cli::args {
    variable CL [ocmdline new questlog $::QUESTLOG_VERSION]
}

$::questlog::cli::args::CL synopsis {[--json|--shortstat] [bounds] [clauses]}

$::questlog::cli::args::CL preamble {
    {A session is returned when its clauses hold. Each clause is one needle in an}
    {optional region-list; clauses combine by one algebra: adjacency is AND, --or is}
    {OR, --not negates the next clause. Precedence is NOT > AND > OR. There is no}
    {grouping - a query that needs A AND (B OR C) is rejected; reorder to DNF instead.}
}

$::questlog::cli::args::CL subcommand rename {<session.jsonl> [title]} \
    {Set the session's custom title; an empty title reverts to the auto title.}
$::questlog::cli::args::CL subcommand show {<session.jsonl|uuid>} \
    {Print the session as a readable transcript.}
$::questlog::cli::args::CL subcommand install-claude-command {} \
    {Register questlog as a Claude Code command.}

# Without an output flag the query opens the GUI on itself; --json and
# --shortstat each answer it on stdout instead.
$::questlog::cli::args::CL mode gui -default -section output \
    -help {{Open the GUI on the query. Needs a display.}}
$::questlog::cli::args::CL mode json
$::questlog::cli::args::CL mode shortstat

# ---- output ----------------------------------------------------------------

$::questlog::cli::args::CL section output {output:} -note {
    {}
    {  Cost = the tokens recorded in each transcript priced at per-model API rates;}
    {  computed here, an API-equivalent figure, not a number the harness billed.}
    {  By default a session's whole-transcript cost counts once it falls in the}
    {  window; --accrued-cost instead counts only the spend dated inside the window.}
}
$::questlog::cli::args::CL option --json -section output -selects json \
    -help {{Emit the full result as JSON, headless.}}
$::questlog::cli::args::CL option --shortstat -section output -selects shortstat \
    -help {{Emit a totals summary instead, headless: session and subagent}
           {counts, turns, tokens, and total cost over the result.}}

# ---- clauses ---------------------------------------------------------------

$::questlog::cli::args::CL section clause {clauses:} -note {
    {}
    {A tool selector is read, write, edit or file for a file the session touched,}
    {or the name of a tool (Bash, Grep, ...) it used, whose value is then a key its}
    {invocation contains (an empty key = any use).}
    {}
    {A path-tail is matched from the right, as a literal, not a glob: 'scan.tcl' finds}
    {the file in any directory, and 'lib/scan.tcl' any path ending that way. The tail}
    {starts at a '/' or a '.', so '.tcl' and 'tcl' both find every Tcl file, while}
    {'an.tcl' finds none.}
    {}
    {A region-list confines a needle to part of the transcript: user, assistant,}
    {tool-use, tool-result, any (the default). Unambiguous prefixes are accepted, and}
    {a comma joins them for OR, e.g. --keyword:user,assi <needle>.}
}

# The GUI's search box splits its text on space and quotes a phrase with '"', and
# its scope selector is one setting for the whole box, so a needle carrying a
# quote and a per-clause region each have nowhere in the window to live.
$::questlog::cli::args::CL option --keyword -section clause -repeat \
    -suffix regions -arg needle \
    -check {::questlog::cli::args::check_regions $suffix} \
    -guard {::questlog::cli::args::keyword_restriction $value $suffix} \
    -help {{A literal needle.}}

$::questlog::cli::args::CL option --regex -section clause -repeat \
    -suffix regions -arg needle \
    -check {::questlog::cli::args::check_pattern $value $suffix} \
    -guard {::questlog::cli::args::regions_restriction $suffix} \
    -help {{A regex needle.}}

$::questlog::cli::args::CL option --tool: -section clause -repeat \
    -suffix selector -arg value \
    -help {{A file the session touched (by path-tail), or a tool it used.}}

$::questlog::cli::args::CL option --or -section clause -repeat \
    -modes {json shortstat} -because {the GUI ANDs its criteria} \
    -help {{OR between the clause before and the clause after.}}

$::questlog::cli::args::CL option --not -section clause -repeat \
    -modes {json shortstat} -because {the GUI has no negated criterion} \
    -help {{Negate the next clause. The whole query still}
           {needs at least one positive clause.}}

# ---- bounds ----------------------------------------------------------------

$::questlog::cli::args::CL section bound {bounds (global, applied to the whole result - not clauses):}

$::questlog::cli::args::CL option --since -section bound -arg when \
    -check {::questlog::cli::args::check_when --since $value} \
    -help {{Recency bound: a window (24h, 7d, 2w), a date (2026-04-01),}
           {a precise instant (2026-04-01T13:37, ...T13:37:30), or 'all'.}}

$::questlog::cli::args::CL option --until -section bound -arg when \
    -check {::questlog::cli::args::check_when --until $value} \
    -modes {json shortstat} \
    -help {{Older bound: a window ago (7d), a date (covers the whole day),}
           {a precise instant, or 'all' (no bound).}}

$::questlog::cli::args::CL option --subtree -section bound -arg dir \
    -check {::questlog::cli::args::check_subtree $value} \
    -help {{Only sessions in the subtree of <dir>: the directory}
           {itself and everything below it (~ is expanded).}}

$::questlog::cli::args::CL option --accrued-cost -section bound \
    -modes {json shortstat} \
    -help {{Count only spend dated inside the window, by each message's}
           {timestamp. Needs a time bound.}}

$::questlog::cli::args::CL option --limit -section bound -arg N \
    -check {::questlog::cli::args::check_count --limit $value 1} \
    -modes {json shortstat} \
    -help {{Cap returned sessions (0, 'all', or unset = unlimited).}}

$::questlog::cli::args::CL option --limit-matches -section bound -arg N \
    -check {::questlog::cli::args::check_count --limit-matches $value 0} \
    -modes {json shortstat} \
    -help {{Cap snippets per session/subagent (0 = no snippets).}}

$::questlog::cli::args::CL option --case -section bound \
    -help {{Case-sensitive keyword matching (default: insensitive).}}

# ---- display ---------------------------------------------------------------

$::questlog::cli::args::CL section display {display:}

$::questlog::cli::args::CL option --font -section display -arg family \
    -modes {gui} -because {the reading font is the GUI's} \
    -help {{The session viewer's reading font.}}

$::questlog::cli::args::CL option --debug -section display -arg n \
    -help {{Write the diagnostic log.}}

# The flag algebra has no parentheses, so the tokens someone reaches for say why
# rather than passing as unknown options.
foreach tok {( ) --( --) --and} {
    $::questlog::cli::args::CL reject $tok "grouping is not supported - the flag algebra has no\
        parentheses. Reorder to OR-of-ANDs, e.g. 'A B --or A C' for 'A AND (B OR C)'."
}

# ---- value checks ----------------------------------------------------------

# The region vocabulary lives in lib/search.tcl; a bad spec is a usage error
# rather than a stack trace deep in the scan.
proc ::questlog::cli::args::check_regions {suffix} {
    if {[catch {::questlog::search::parse_regions $suffix} out]} { return $out }
    return ""
}

# A pattern's first execution is deep inside the scan, where a throw is a stack
# trace instead of a usage error, so it is run against nothing here first.
proc ::questlog::cli::args::check_pattern {value suffix} {
    set why [check_regions $suffix]
    if {$why ne ""} { return $why }
    if {[catch {regexp -- $value {}} rxerr]} {
        return "--regex: invalid pattern '$value': $rxerr"
    }
    return ""
}

# --since and --until share one time-spec grammar; "" and 'all' mean no bound.
proc ::questlog::cli::args::check_when {flag value} {
    if {$value eq "all"} { return "" }
    if {[catch {::questlog::filter::parse_since $value}]} {
        return "$flag: invalid '$value' (want 24h/7d/2w, 2026-04-01, 2026-04-01T13:37\[:SS\], or 'all')"
    }
    return ""
}

# Counts must be counts: a swallowed flag or a typo would otherwise ride through
# Tcl string comparison as "no cap" while claiming to be one. --limit also spells
# its no-cap as 'all'.
proc ::questlog::cli::args::check_count {flag value allow_all} {
    if {$allow_all && $value eq "all"} { return "" }
    if {![string is integer -strict $value] || $value < 0} {
        set want [expr {$allow_all ? " or 'all'" : ""}]
        return "$flag: not a count: '$value' (want a non-negative integer$want)"
    }
    return ""
}

# Canonicalise (tilde-expanded, absolute) so the filter predicates compare
# against the form Claude records as a cwd; an inexpandible ~user fails loud
# instead of matching nothing.
proc ::questlog::cli::args::check_subtree {value} {
    if {[catch {::questlog::path::canon_dir $value} out]} { return "--subtree: $out" }
    return ""
}

# ---- what the window cannot hold -------------------------------------------

proc ::questlog::cli::args::regions_restriction {suffix} {
    if {$suffix eq "" || ![llength [::questlog::search::parse_regions $suffix]]} { return {} }
    return [dict create subject "a :regions suffix" modes {json shortstat} \
        because "the GUI's scope covers the whole search"]
}

proc ::questlog::cli::args::keyword_restriction {value suffix} {
    set r [regions_restriction $suffix]
    if {[llength $r]} { return $r }
    if {[string first "\"" $value] >= 0} {
        return [dict create subject "a keyword holding a double quote" \
            modes {json shortstat} because "the search field quotes phrases with it"]
    }
    return {}
}

# ---- the query -------------------------------------------------------------

# parse argv - the whole command line as one neutral query dict:
#
#   mode           gui | json | shortstat
#   groups         the OR-of-ANDs: a list of AND-groups, each a list of clause
#                  dicts {kind keyword|regex|tool, ..., neg 0|1}
#   since until subtree limit limit_matches accrued nocase font debug
#
# The grammar is an OR (--or) of AND-groups (adjacency) of optionally-negated
# (--not) clauses; groups is the closed AND-groups and cur the one being built,
# while bounds ride outside the tree. Throws as ocmdline does; `run` answers.
proc ::questlog::cli::args::parse {argv} {
    variable CL
    set p [$CL parse $argv]
    set mode [dict get $p mode]

    set limit 0
    set limit_matches -1
    set subtree ""
    set since ""
    set until ""
    set font ""
    set debug 0
    set accrued 0
    set nocase 1
    set groups [list]
    set cur [list]
    set pending_neg 0

    foreach o [dict get $p occurrences] {
        set name [dict get $o name]
        set value [dict get $o value]
        set suffix [dict get $o suffix]
        # A pending --not may only be followed by a clause; letting a bound or
        # output flag through here would silently carry the negation across it
        # to whatever clause comes later.
        if {$pending_neg && $name ni {--keyword --regex --tool:}} {
            if {$name eq "--not"} { $CL fail "--not --not is not allowed" }
            $CL fail "--not must be followed by a clause, not '$name'"
        }
        switch -- $name {
            --keyword {
                lappend cur [dict create kind keyword value $value \
                    regions [::questlog::search::parse_regions $suffix] neg $pending_neg]
                set pending_neg 0
            }
            --regex {
                lappend cur [dict create kind regex value $value \
                    regions [::questlog::search::parse_regions $suffix] neg $pending_neg]
                set pending_neg 0
            }
            --tool: {
                lassign [::questlog::search::tool_selector $suffix] selkind selspec
                lappend cur [dict create kind tool selkind $selkind selspec $selspec \
                    value $value neg $pending_neg]
                set pending_neg 0
            }
            --not { set pending_neg 1 }
            --or {
                if {![llength $cur]} { $CL fail "--or needs a clause on each side" }
                lappend groups $cur
                set cur [list]
            }
            --limit         { set limit [expr {$value eq "all" ? 0 : $value}] }
            --limit-matches { set limit_matches $value }
            --since         { set since $value }
            --until         { set until $value }
            --subtree       { set subtree [::questlog::path::canon_dir $value] }
            --font          { set font $value }
            --debug         { set debug $value }
            --accrued-cost  { set accrued 1 }
            --case          { set nocase 0 }
            --json - --shortstat {
                # Read already: an output flag chose the mode, which rides on
                # the parse rather than on any one occurrence.
            }
            default {
                # Declaring an option makes it parse and print; only this fold
                # gives it meaning. An option that reaches here would be
                # accepted, documented, and inert, so it stops the run instead.
                error "questlog: $name is declared but the query does not read it"
            }
        }
    }
    if {$pending_neg} { $CL fail "--not has no following clause" }
    if {[llength $cur]} {
        lappend groups $cur
    } elseif {[llength $groups]} {
        $CL fail "--or needs a clause on each side"
    }

    # A tree with no positive clause can only prove absence, and the result model
    # shows evidence (snippets of positive hits), so reject it loudly rather than
    # emit the silent empty set.
    set clauses [concat {*}$groups]
    if {[llength $clauses]} {
        set any_pos 0
        foreach c $clauses { if {![dict get $c neg]} { set any_pos 1; break } }
        if {!$any_pos} {
            $CL fail "a query needs at least one positive clause (--not only negates)"
        }
    }
    # --accrued-cost windows the spend, so it has no meaning without a window:
    # require a real --since or --until ("" and "all" both parse to {none}).
    if {$accrued
        && [lindex [::questlog::filter::parse_since $since] 0] eq "none"
        && [lindex [::questlog::filter::parse_since $until] 0] eq "none"} {
        $CL fail "--accrued-cost needs a time bound (--since and/or --until)"
    }

    return [dict create mode $mode groups $groups \
        limit $limit limit_matches $limit_matches subtree $subtree \
        since $since until $until accrued $accrued nocase $nocase \
        font $font debug $debug]
}

# The query, or the conventional answer to a command line that does not carry
# one: the help, the version, or the message and exit 2.
proc ::questlog::cli::args::run {argv} {
    variable CL
    try {
        return [::questlog::cli::args::parse $argv]
    } trap {OCMDLINE HELP} {} {
        $CL print stdout
        exit 0
    } trap {OCMDLINE VERSION} {} {
        puts [$CL version_line]
        exit 0
    } trap {OCMDLINE USAGE} {msg} {
        $CL abort $msg
    }
}

# The subcommand argv asks for, or "" for the query grammar.
proc ::questlog::cli::args::subcommand_of {argv} {
    variable CL
    return [$CL subcommand_of $argv]
}

# How a subcommand is written, for one that finds its own arguments wrong.
proc ::questlog::cli::args::subcommand_usage {name} {
    variable CL
    return [$CL subcommand_usage $name]
}
