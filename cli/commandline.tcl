package require Tcl 9
package require ocmdline

# questlog's command line. The ocmdline object below is its one statement: the
# same declaration answers argv and renders `--help`.
#
# It sits beside the headless answer rather than inside it, because both answers
# read it: cli/main.tcl would carry its JSON emitters into every GUI launch, and
# the launcher would put the grammar out of reach of a test that drives it
# without opening a window.
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

namespace eval ::questlog::cli::commandline {
    variable CL [ocmdline new questlog $::QUESTLOG_VERSION]
}

$::questlog::cli::commandline::CL synopsis {[--json|--markdown|--shortstat] [bounds] [clauses]}

$::questlog::cli::commandline::CL preamble {
    {A session is returned when its clauses hold. Each clause is one needle in an}
    {optional region-list; clauses combine by one algebra: adjacency is AND, --or is}
    {OR, --not negates the next clause. Precedence is NOT > AND > OR. There is no}
    {grouping - a query that needs A AND (B OR C) is rejected; reorder to DNF instead.}
}

$::questlog::cli::commandline::CL subcommand rename {<session.jsonl> [title]} \
    {Set the session's custom title; an empty or omitted title reverts to the auto title.}
$::questlog::cli::commandline::CL subcommand show {<session.jsonl|uuid>} \
    {Print the session as a readable transcript.}
$::questlog::cli::commandline::CL subcommand install-claude-command {} \
    {Register questlog as a Claude Code command.}

# Without an output flag the query opens the GUI on itself; --json and
# --shortstat each answer it on stdout instead.
$::questlog::cli::commandline::CL mode gui -default -section output \
    -help {{Open the GUI on the query. Needs a display.}}
$::questlog::cli::commandline::CL mode json
$::questlog::cli::commandline::CL mode markdown
$::questlog::cli::commandline::CL mode shortstat

# ---- output ----------------------------------------------------------------

$::questlog::cli::commandline::CL section output {output:} -note {
    {}
    {  Cost = the tokens recorded in each transcript priced at per-model API rates;}
    {  computed here, an API-equivalent figure, not a number the harness billed.}
    {  By default a session's whole-transcript cost counts once it falls in the}
    {  window; --accrued-cost instead counts only the spend dated inside the window.}
}
$::questlog::cli::commandline::CL option --json -section output -selects json \
    -help {{Emit the full result as JSON, headless.}}
$::questlog::cli::commandline::CL option --markdown -section output -selects markdown \
    -help {{Emit the result as markdown, headless: each matching session with}
           {its hits, rendered as reading-view turns.}}
$::questlog::cli::commandline::CL option --shortstat -section output -selects shortstat \
    -help {{Emit a totals summary instead, headless: session and subagent}
           {counts, turns, tokens, and total cost over the result.}}

# ---- context ---------------------------------------------------------------

$::questlog::cli::commandline::CL section context {context (--json/--markdown; whole messages around each hit):}

$::questlog::cli::commandline::CL option --before-context -section context -arg N \
    -check {::questlog::cli::commandline::check_count --before-context $value 0} \
    -modes {json markdown} -because {the totals and the GUI show no per-hit context} \
    -fold {set ctx_before $value} \
    -help {{Show N messages before each hit (grep -B).}}
$::questlog::cli::commandline::CL option -B -section context -arg N \
    -check {::questlog::cli::commandline::check_count -B $value 0} \
    -modes {json markdown} -because {the totals and the GUI show no per-hit context} \
    -fold {set ctx_before $value} \
    -help {{Alias for --before-context.}}

$::questlog::cli::commandline::CL option --after-context -section context -arg N \
    -check {::questlog::cli::commandline::check_count --after-context $value 0} \
    -modes {json markdown} -because {the totals and the GUI show no per-hit context} \
    -fold {set ctx_after $value} \
    -help {{Show N messages after each hit (grep -A).}}
$::questlog::cli::commandline::CL option -A -section context -arg N \
    -check {::questlog::cli::commandline::check_count -A $value 0} \
    -modes {json markdown} -because {the totals and the GUI show no per-hit context} \
    -fold {set ctx_after $value} \
    -help {{Alias for --after-context.}}

$::questlog::cli::commandline::CL option --context -section context -arg N \
    -check {::questlog::cli::commandline::check_count --context $value 0} \
    -modes {json markdown} -because {the totals and the GUI show no per-hit context} \
    -fold {set ctx_before $value; set ctx_after $value} \
    -help {{Show N messages on each side (grep -C; sets before and after).}}
$::questlog::cli::commandline::CL option -C -section context -arg N \
    -check {::questlog::cli::commandline::check_count -C $value 0} \
    -modes {json markdown} -because {the totals and the GUI show no per-hit context} \
    -fold {set ctx_before $value; set ctx_after $value} \
    -help {{Alias for --context.}}

# ---- clauses ---------------------------------------------------------------

$::questlog::cli::commandline::CL section clause {clauses:} -note {
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
    {tool-use, tool-result, any (the default). names is not a transcript slice but}
    {the session's name history - every title it has worn - so --keyword:names finds}
    {a session by a name it once bore. Unambiguous prefixes are accepted, and a comma}
    {joins them for OR, e.g. --keyword:user,assi <needle>.}
}

# The GUI's search box splits its text on space and quotes a phrase with '"', and
# its scope selector is one setting for the whole box, so a needle carrying a
# quote and a per-clause region each have nowhere in the window to live.
$::questlog::cli::commandline::CL option --keyword -section clause -repeat -tag clause \
    -suffix regions -arg needle \
    -check {::questlog::cli::commandline::check_regions $suffix} \
    -guard {::questlog::cli::commandline::keyword_restriction $value $suffix} \
    -fold {lappend cur [dict create kind keyword value $value \
               regions [::questlog::search::parse_regions $suffix] neg $pending_neg]
           set pending_neg 0} \
    -help {{A literal needle.}}

$::questlog::cli::commandline::CL option --regex -section clause -repeat -tag clause \
    -suffix regions -arg needle \
    -check {::questlog::cli::commandline::check_pattern $value $suffix} \
    -guard {::questlog::cli::commandline::regions_restriction $suffix} \
    -fold {lappend cur [dict create kind regex value $value \
               regions [::questlog::search::parse_regions $suffix] neg $pending_neg]
           set pending_neg 0} \
    -help {{A regex needle.}}

$::questlog::cli::commandline::CL option --tool: -section clause -repeat -tag clause \
    -suffix selector -arg value \
    -fold {lassign [::questlog::search::tool_selector $suffix] selkind selspec
           lappend cur [dict create kind tool selkind $selkind selspec $selspec \
               value $value neg $pending_neg]
           set pending_neg 0} \
    -help {{A file the session touched (by path-tail), or a tool it used.}}

$::questlog::cli::commandline::CL option --or -section clause -repeat \
    -modes {json markdown shortstat} -because {the GUI ANDs its criteria} \
    -fold {if {![llength $cur]} { $CL fail "--or needs a clause on each side" }
           lappend groups $cur
           set cur [list]} \
    -help {{OR between the clause before and the clause after.}}

$::questlog::cli::commandline::CL option --not -section clause -repeat \
    -modes {json markdown shortstat} -because {the GUI has no negated criterion} \
    -fold {set pending_neg 1} \
    -help {{Negate the next clause. The whole query still}
           {needs at least one positive clause.}}

# ---- bounds ----------------------------------------------------------------

$::questlog::cli::commandline::CL section bound {bounds (global, applied to the whole result - not clauses):}

$::questlog::cli::commandline::CL option --since -fold {set since $value} -section bound -arg when \
    -check {::questlog::cli::commandline::check_when --since $value} \
    -help {{Recency bound: a window (24h, 7d, 2w), a date (2026-04-01),}
           {a precise instant (2026-04-01T13:37, ...T13:37:30), or 'all'.}}

$::questlog::cli::commandline::CL option --until -fold {set until $value} -section bound -arg when \
    -check {::questlog::cli::commandline::check_when --until $value} \
    -modes {json markdown shortstat} \
    -help {{Older bound: a window ago (7d), a date (covers the whole day),}
           {a precise instant, or 'all' (no bound).}}

$::questlog::cli::commandline::CL option --subtree -fold {set subtree [::questlog::path::canon_dir $value]} -section bound -arg dir \
    -check {::questlog::cli::commandline::check_subtree $value} \
    -help {{Only sessions in the subtree of <dir>: the directory}
           {itself and everything below it (~ is expanded).}}

$::questlog::cli::commandline::CL option --accrued-cost -fold {set accrued 1} -section bound \
    -modes {json markdown shortstat} \
    -help {{Count only spend dated inside the window, by each message's}
           {timestamp. Needs a time bound.}}

$::questlog::cli::commandline::CL option --limit -fold {set limit [expr {$value eq "all" ? 0 : $value}]} -section bound -arg N \
    -check {::questlog::cli::commandline::check_count --limit $value 1} \
    -modes {json markdown shortstat} \
    -help {{Cap returned sessions (0, 'all', or unset = unlimited).}}

$::questlog::cli::commandline::CL option --limit-matches -fold {set limit_matches $value} -section bound -arg N \
    -check {::questlog::cli::commandline::check_count --limit-matches $value 0} \
    -modes {json markdown shortstat} \
    -help {{Cap snippets per session/subagent (0 = no snippets).}}

$::questlog::cli::commandline::CL option --case -fold {set nocase 0} -section bound \
    -help {{Case-sensitive keyword matching (default: insensitive).}}

# ---- display ---------------------------------------------------------------

$::questlog::cli::commandline::CL section display {display:}

$::questlog::cli::commandline::CL option --font -fold {set font $value} -section display -arg family \
    -modes {gui} -because {the reading font is the GUI's} \
    -help {{The session viewer's reading font.}}

$::questlog::cli::commandline::CL option --debug -fold {set debug $value} -section display -arg n \
    -help {{Write the diagnostic log.}}

# The flag algebra has no parentheses, so the tokens someone reaches for say why
# rather than passing as unknown options.
foreach tok {( ) --( --) --and} {
    $::questlog::cli::commandline::CL reject $tok "grouping is not supported - the flag algebra has no\
        parentheses. Reorder to OR-of-ANDs, e.g. 'A B --or A C' for 'A AND (B OR C)'."
}

# ---- value checks ----------------------------------------------------------

# The region vocabulary lives in lib/search.tcl; a bad spec is a usage error
# rather than a stack trace deep in the scan.
proc ::questlog::cli::commandline::check_regions {suffix} {
    if {[catch {::questlog::search::parse_regions $suffix} out]} { return $out }
    return ""
}

# A pattern's first execution is deep inside the scan, where a throw is a stack
# trace instead of a usage error, so it is run against nothing here first.
proc ::questlog::cli::commandline::check_pattern {value suffix} {
    set why [check_regions $suffix]
    if {$why ne ""} { return $why }
    if {[catch {regexp -- $value {}} rxerr]} {
        return "--regex: invalid pattern '$value': $rxerr"
    }
    return ""
}

# --since and --until share one time-spec grammar; "" and 'all' mean no bound.
proc ::questlog::cli::commandline::check_when {flag value} {
    if {$value eq "all"} { return "" }
    if {[catch {::questlog::filter::parse_since $value}]} {
        return "$flag: invalid '$value' (want 24h/7d/2w, 2026-04-01, 2026-04-01T13:37\[:SS\], or 'all')"
    }
    return ""
}

# Counts must be counts: a swallowed flag or a typo would otherwise ride through
# Tcl string comparison as "no cap" while claiming to be one. --limit also spells
# its no-cap as 'all'.
proc ::questlog::cli::commandline::check_count {flag value allow_all} {
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
proc ::questlog::cli::commandline::check_subtree {value} {
    if {[catch {::questlog::path::canon_dir $value} out]} { return "--subtree: $out" }
    return ""
}

# ---- what the window cannot hold -------------------------------------------

proc ::questlog::cli::commandline::regions_restriction {suffix} {
    if {$suffix eq "" || ![llength [::questlog::search::parse_regions $suffix]]} { return {} }
    return [dict create subject "a :regions suffix" modes {json markdown shortstat} \
        because "the GUI's scope covers the whole search"]
}

proc ::questlog::cli::commandline::keyword_restriction {value suffix} {
    set r [regions_restriction $suffix]
    if {[llength $r]} { return $r }
    if {[string first "\"" $value] >= 0} {
        return [dict create subject "a keyword holding a double quote" \
            modes {json markdown shortstat} because "the search field quotes phrases with it"]
    }
    return {}
}

# ---- the query -------------------------------------------------------------

# parse argv - the whole command line as one neutral query dict:
#
#   mode           gui | json | markdown | shortstat
#   groups         the OR-of-ANDs: a list of AND-groups, each a list of clause
#                  dicts {kind keyword|regex|tool, ..., neg 0|1}
#   since until subtree limit limit_matches accrued nocase ctx_before ctx_after
#   font debug
#
# The grammar is an OR (--or) of AND-groups (adjacency) of optionally-negated
# (--not) clauses; groups is the closed AND-groups and cur the one being built,
# while bounds ride outside the tree. Throws as ocmdline does; `run` answers.
proc ::questlog::cli::commandline::parse {argv} {
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
    set ctx_before 0
    set ctx_after 0
    set groups [list]
    set cur [list]
    set pending_neg 0

    # Each occurrence runs the fold its own declaration carries, so no option
    # can be written into the grammar without a meaning, and none is reached by
    # a name this loop has to know.
    foreach o [dict get $p occurrences] {
        set name [dict get $o name]
        set value [dict get $o value]
        set suffix [dict get $o suffix]
        # A pending --not may only be followed by a clause; letting a bound or
        # output flag through here would silently carry the negation across it
        # to whatever clause comes later.
        if {$pending_neg && [$CL tag_of $name] ne "clause"} {
            if {$name eq "--not"} { $CL fail "--not --not is not allowed" }
            $CL fail "--not must be followed by a clause, not '$name'"
        }
        set fold [$CL fold_of $name]
        if {$fold ne ""} { eval $fold }
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
        ctx_before $ctx_before ctx_after $ctx_after \
        font $font debug $debug]
}

# The query, or the conventional answer to a command line that does not carry
# one: the help, the version, or the message and exit 2.
proc ::questlog::cli::commandline::run {argv} {
    variable CL
    try {
        return [::questlog::cli::commandline::parse $argv]
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
proc ::questlog::cli::commandline::subcommand_of {argv} {
    variable CL
    return [$CL subcommand_of $argv]
}

# How a subcommand is written, for one that finds its own arguments wrong.
proc ::questlog::cli::commandline::subcommand_usage {name} {
    variable CL
    return [$CL subcommand_usage $name]
}

# Which of the command line's own answers argv asks for - `help`, `version`, or
# "" for neither.
proc ::questlog::cli::commandline::asks {argv} {
    variable CL
    return [$CL asks $argv]
}
