package require Tcl 9

# The one home of questlog's command line. Both the headless run and the GUI
# launch are the same query in the same grammar: `parse` turns argv into a
# neutral query dict, and the caller decides what to do with it. `--json` or
# `--shortstat` asks for the answer on stdout; without either, the query seeds
# the GUI's toolbar and the window opens on it.
#
# The dict is engine-neutral - no matcher leaves, no toolbar clauses - so
# cli/main.tcl folds it one way and the launcher's GUI seeding folds it another,
# neither owning the grammar. Nothing here requires Tk, so `--help` and every
# parse error answer without a display.
#
# A handful of features have no widget behind them (see gui_objection); asking
# for one without an output flag is an error naming the flag that would make it
# work, never a silent drop.
namespace eval ::questlog::cli::args {}

# Print the grammar and exit. channel/code parameterised: an explicit --help is
# an answer (stdout, exit 0); a parse error keeps the diagnostic contract
# (stderr, exit 2).
proc ::questlog::cli::args::usage {{channel stderr} {code 2}} {
    puts $channel "usage: questlog \[--json|--shortstat] \[bounds] \[clauses]"
    puts $channel "       questlog rename <session.jsonl> \[title]"
    puts $channel "       questlog show <session.jsonl|uuid>"
    puts $channel "       questlog install-claude-command"
    puts $channel "       questlog --version"
    puts $channel ""
    puts $channel "A session is returned when its clauses hold. Each clause is one needle in an"
    puts $channel "optional region-list; clauses combine by one algebra: adjacency is AND, --or is"
    puts $channel "OR, --not negates the next clause. Precedence is NOT > AND > OR. There is no"
    puts $channel "grouping - a query that needs A AND (B OR C) is rejected; reorder to DNF instead."
    puts $channel ""
    puts $channel "output:"
    puts $channel "  --json                  Emit the full result as JSON, headless."
    puts $channel "  --shortstat             Emit a totals summary instead, headless: session and"
    puts $channel "                          subagent counts, turns, tokens, and total cost."
    puts $channel "  neither                 Open the GUI on the query. Needs a display."
    puts $channel ""
    puts $channel "  Cost = the tokens recorded in each transcript priced at per-model API rates;"
    puts $channel "  computed here, an API-equivalent figure, not a number the harness billed."
    puts $channel "  By default a session's whole-transcript cost counts once it falls in the"
    puts $channel "  window; --accrued-cost instead counts only the spend dated inside the window."
    puts $channel ""
    puts $channel "clauses:"
    puts $channel "  --keyword\[:regions] <needle>   A literal needle."
    puts $channel "  --regex\[:regions] <needle>     A regex needle."
    puts $channel "  --tool:read <file>            A file read (by path suffix)."
    puts $channel "  --tool:write|edit|file <file> A file written / edited / touched."
    puts $channel "  --tool:<name> <key>           A use of a tool (Bash, Grep, ...) whose invocation"
    puts $channel "                                contains the key (empty key = any use)."
    puts $channel "  --or                          OR between the clause before and the clause after."
    puts $channel "  --not                         Negate the next clause. The whole query still"
    puts $channel "                                needs at least one positive clause."
    puts $channel ""
    puts $channel "regions (the :regions suffix on --keyword/--regex; comma-joins for OR):"
    puts $channel "  user, assistant, tool-use, tool-result, any (default). Unambiguous prefixes are"
    puts $channel "  accepted, e.g. --keyword:user,assi <needle>. Omit the suffix to match anywhere."
    puts $channel ""
    puts $channel "bounds (global, applied to the whole result - not clauses):"
    puts $channel "  --since <when>          Recency bound: a window (24h, 7d, 2w), a date (2026-04-01),"
    puts $channel "                          a precise instant (2026-04-01T13:37, ...T13:37:30), or 'all'."
    puts $channel "  --until <when>          Older bound: a window ago (7d), a date (covers the whole day),"
    puts $channel "                          a precise instant (2026-04-01T13:37\[:SS]), or 'all' (no bound)."
    puts $channel "  --subtree <dir>         Only sessions in the subtree of <dir>: the directory"
    puts $channel "                          itself and everything below it (~ is expanded)."
    puts $channel "  --accrued-cost          Count only spend dated inside the --since/--until window,"
    puts $channel "                          by each message's timestamp. Needs a time bound; --until"
    puts $channel "                          alone scans the whole corpus."
    puts $channel "  --limit <N>             Cap returned sessions (0, 'all', or unset = unlimited)."
    puts $channel "  --limit-matches <N>     Cap snippets per session/subagent (0 = no snippets)."
    puts $channel "  --case                  Case-sensitive keyword matching (default: insensitive)."
    puts $channel ""
    puts $channel "The GUI has no control for --or, --not, --until, --limit, --limit-matches,"
    puts $channel "--accrued-cost, a :regions suffix, or a keyword holding a double quote (the"
    puts $channel "search field quotes phrases with it), so those ask for --json or --shortstat."
    puts $channel ""
    puts $channel "display (the GUI's own, no meaning for a headless run):"
    puts $channel "  --font <family|spec>    The session viewer's reading font."
    puts $channel ""
    puts $channel "  --debug <n>             Write the diagnostic log (both output and the GUI)."
    exit $code
}

# A parse error: the message, then the grammar, then exit 2.
proc ::questlog::cli::args::fail {msg} {
    puts stderr "questlog: $msg"
    ::questlog::cli::args::usage
}

# The value following a flag; a missing one is an error rather than a silent
# empty needle (which would match every session).
proc ::questlog::cli::args::next_val {argvVar iVar flag} {
    upvar 1 $argvVar argv $iVar i
    incr i
    if {$i >= [llength $argv]} { fail "$flag needs a value" }
    return [lindex $argv $i]
}

# A bound carries one value, so it is given once: a second is a typo or a
# misreading of the grammar, and last-wins would answer a query nobody asked
# for. Clauses repeat freely - that is what the algebra is for.
proc ::questlog::cli::args::once {seenVar flag} {
    upvar 1 $seenVar seen
    if {[dict exists $seen $flag]} { fail "$flag given twice" }
    dict set seen $flag 1
}

# The block-type set a :regions suffix selects, exiting cleanly on a bad spec
# rather than dumping a stack trace. An empty suffix (no colon, or a bare
# "--keyword:") is the unrestricted default.
proc ::questlog::cli::args::regions {spec} {
    if {[catch {::questlog::search::parse_regions $spec} out]} { fail $out }
    return $out
}

# parse argv - the whole command line as one neutral query dict:
#
#   mode           gui | json | shortstat
#   groups         the OR-of-ANDs: a list of AND-groups, each a list of clause
#                  dicts {kind keyword|regex|tool, ..., neg 0|1}
#   since until subtree limit limit_matches accrued nocase font debug
#
# The grammar is an OR (--or) of AND-groups (adjacency) of optionally-negated
# (--not) clauses; groups is the closed AND-groups and cur the one being built,
# while bounds ride outside the tree. A malformed query prints a message and
# exits through usage.
proc ::questlog::cli::args::parse {argv} {
    set mode gui
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
    set seen [dict create]

    for {set i 0} {$i < [llength $argv]} {incr i} {
        set arg [lindex $argv $i]
        # Keyword and regex clauses carry an optional :regions suffix.
        if {[regexp {^--keyword(?::(.*))?$} $arg -> rspec]} {
            set val [next_val argv i $arg]
            lappend cur [dict create kind keyword value $val \
                regions [regions $rspec] neg $pending_neg]
            set pending_neg 0
            continue
        }
        if {[regexp {^--regex(?::(.*))?$} $arg -> rspec]} {
            set val [next_val argv i $arg]
            # Validate now: the pattern's first execution is deep inside the
            # scan, where a throw is a stack trace instead of a usage error.
            if {[catch {regexp -- $val {}} rxerr]} {
                fail "$arg: invalid pattern '$val': $rxerr"
            }
            lappend cur [dict create kind regex value $val \
                regions [regions $rspec] neg $pending_neg]
            set pending_neg 0
            continue
        }
        if {[string match --tool:* $arg]} {
            set selector [string range $arg [string length "--tool:"] end]
            set val [next_val argv i $arg]
            lassign [::questlog::search::tool_selector $selector] selkind selspec
            lappend cur [dict create kind tool selkind $selkind selspec $selspec \
                value $val neg $pending_neg]
            set pending_neg 0
            continue
        }
        # A pending --not may only be followed by a clause; letting a bound or
        # output flag through here would silently carry the negation across it
        # to whatever clause comes later.
        if {$pending_neg} {
            if {$arg eq "--not"} { fail "--not --not is not allowed" }
            fail "--not must be followed by a clause, not '$arg'"
        }
        switch -glob -- $arg {
            --json - --shortstat {
                if {$mode ne "gui"} { fail "choose one output: --json or --shortstat" }
                set mode [string range $arg 2 end]
            }
            --help { ::questlog::cli::args::usage stdout 0 }
            --or {
                if {[llength $cur] == 0} { fail "--or needs a clause on each side" }
                lappend groups $cur
                set cur [list]
            }
            --not            { set pending_neg 1 }
            --limit          { once seen $arg; set limit [next_val argv i $arg] }
            --limit-matches  { once seen $arg; set limit_matches [next_val argv i $arg] }
            --since          { once seen $arg; set since [next_val argv i $arg] }
            --until          { once seen $arg; set until [next_val argv i $arg] }
            --font           { once seen $arg; set font [next_val argv i $arg] }
            --debug          { once seen $arg; set debug [next_val argv i $arg] }
            --accrued-cost   { set accrued 1 }
            --subtree        {
                # Canonicalise here (tilde-expanded, absolute) so the filter
                # predicates compare against the form Claude records as a cwd;
                # an inexpandible ~user fails loud instead of matching nothing.
                once seen $arg
                set v [next_val argv i $arg]
                if {[catch {::questlog::path::canon_dir $v} subtree]} {
                    fail "--subtree: $subtree"
                }
            }
            --case           { set nocase 0 }
            "(" - ")" - "--(" - "--)" - --and {
                puts stderr "questlog: grouping is not supported - the flag algebra has no\
                    parentheses. Reorder to OR-of-ANDs, e.g. 'A B --or A C' for 'A AND (B OR C)'."
                exit 2
            }
            -* { fail "unknown option: $arg" }
            default {
                fail "unexpected argument '$arg' (a needle goes to --keyword or --regex)"
            }
        }
    }
    if {$pending_neg} { fail "--not has no following clause" }
    if {[llength $cur] > 0} {
        lappend groups $cur
    } elseif {[llength $groups] > 0} {
        fail "--or needs a clause on each side"
    }

    if {$limit eq "all"} { set limit 0 }
    # Counts must be counts: a swallowed flag or a typo would otherwise ride
    # through Tcl string comparison as "no cap" while claiming to be one.
    if {![string is integer -strict $limit] || $limit < 0} {
        fail "--limit: not a count: '$limit' (want a non-negative integer or 'all')"
    }
    if {$limit_matches ne -1 && (![string is integer -strict $limit_matches] || $limit_matches < 0)} {
        fail "--limit-matches: not a count: '$limit_matches'"
    }
    # A tree with no positive clause can only prove absence, and the result
    # model shows evidence (snippets of positive hits), so reject it loudly
    # rather than emit the silent empty set.
    set clauses [concat {*}$groups]
    if {[llength $clauses] > 0} {
        set any_pos 0
        foreach c $clauses { if {![dict get $c neg]} { set any_pos 1; break } }
        if {!$any_pos} {
            fail "a query needs at least one positive clause (--not only negates)"
        }
    }

    # --since accepts a relative window (24h, 7d, 2w, ...), an absolute date
    # (2026-04-01) or a precise instant (2026-04-01T13:37[:SS]); "" or "all" mean no
    # bound. Validate now so a bad spec fails fast rather than at cutoff time.
    if {$since ne "" && $since ne "all" && [catch {::questlog::filter::parse_since $since}]} {
        fail "--since: invalid '$since' (want 24h/7d/2w, 2026-04-01, 2026-04-01T13:37\[:SS\], or 'all')"
    }
    # --until shares the since spec grammar; it is the upper edge of the window.
    if {$until ne "" && $until ne "all" && [catch {::questlog::filter::parse_since $until}]} {
        fail "--until: invalid '$until' (want 24h/7d/2w, 2026-04-01, 2026-04-01T13:37\[:SS\], or 'all')"
    }
    # --accrued-cost windows the spend, so it has no meaning without a window:
    # require a real --since or --until ("" and "all" both parse to {none}).
    if {$accrued
        && [lindex [::questlog::filter::parse_since $since] 0] eq "none"
        && [lindex [::questlog::filter::parse_since $until] 0] eq "none"} {
        fail "--accrued-cost needs a time bound (--since and/or --until)"
    }
    # The reading font is the GUI's; a headless run has nothing to render with it.
    if {$mode ne "gui" && $font ne ""} {
        fail "--font is a GUI option and has no meaning with --$mode"
    }

    return [dict create mode $mode groups $groups \
        limit $limit limit_matches $limit_matches subtree $subtree \
        since $since until $until accrued $accrued nocase $nocase \
        font $font debug $debug]
}

# Weigh a GUI-bound query against what the toolbar can hold, and name the first
# part of it that has no control behind it - the empty string when the window
# can show the whole query. The GUI's search box ANDs its terms and its scope
# selector is one setting for the whole box, so an OR, a negation, or a
# per-clause region has nowhere to live; the bounds below have no widget at all.
# The objection names the flag that would run the query as asked, rather than
# dropping the part the window cannot show. Pure, so a test can drive it: the
# caller decides that an objection ends the run.
proc ::questlog::cli::args::gui_objection {q} {
    set headless "needs --json or --shortstat"
    if {[llength [dict get $q groups]] > 1} {
        return "--or $headless (the GUI ANDs its criteria)"
    }
    foreach c [concat {*}[dict get $q groups]] {
        if {[dict get $c neg]} { return "--not $headless (the GUI has no negated criterion)" }
        if {[dict get $c kind] ne "tool" && [llength [dict get $c regions]] > 0} {
            return "a :regions suffix $headless (the GUI's scope covers the whole search)"
        }
        # The search box splits on space and quotes a phrase with ", so a needle
        # carrying a " cannot be written into it. The headless matcher takes the
        # needle literally and has no such grammar.
        if {[dict get $c kind] eq "keyword" && [string first "\"" [dict get $c value]] >= 0} {
            return "a keyword holding a double quote $headless"
        }
    }
    # The unset values: no --until is "", no --limit is 0 (unlimited), no
    # --limit-matches is -1 (the config default). A --limit-matches of 0 is a
    # real request - no snippets - so it is not read as absence.
    if {[dict get $q until] ne ""}         { return "--until $headless" }
    if {[dict get $q limit] != 0}          { return "--limit $headless" }
    if {[dict get $q limit_matches] != -1} { return "--limit-matches $headless" }
    if {[dict get $q accrued]}             { return "--accrued-cost $headless" }
    return ""
}
