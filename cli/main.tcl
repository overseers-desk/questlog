package require Tcl 9
package require json

namespace eval ::questlog::cli::main {}

# Escape characters to output valid JSON strings.
proc ::questlog::cli::main::escape_json {str} {
    set map [list "\\" "\\\\" "\"" "\\\"" "\n" "\\n" "\r" "\\r" "\t" "\\t"]
    return [string map $map $str]
}

# Helper to format match records into JSON array elements
proc ::questlog::cli::main::format_matches {matches} {
    set parts [list]
    foreach m $matches {
        lappend parts [format {{"line":%d,"type":"%s","content":"%s"}} \
            [dict get $m line] \
            [escape_json [dict get $m type]] \
            [escape_json [dict get $m content]]]
    }
    return [join $parts ","]
}

# A cost_usd domain value to its JSON token. The cost module returns -1.0 for
# "no rate matched any model": a session with no priced usage, such as one
# holding only <synthetic> records or no assistant turns at all. The GUI renders
# that as a blank cell; JSON says null, in the same "no figure" sense, so a
# consumer never reads the internal sentinel as a negative cost. A genuine
# figure (including a true zero) passes through as the number.
proc ::questlog::cli::main::format_cost {usd} {
    if {$usd eq "" || $usd < 0} { return "null" }
    return $usd
}

# A seconds count for JSON: blank (unknown, under two timestamped records)
# serializes as null, a genuine figure passes through.
proc ::questlog::cli::main::format_secs {secs} {
    if {$secs eq ""} { return "null" }
    return $secs
}

# Print JSON to stdout. Hand-crafted serializer is extremely robust and
# completely free of external dependencies or type-guessing bugs.
proc ::questlog::cli::main::format_json {folders_dict} {
    set folder_parts [list]
    dict for {folder data} $folders_dict {
        set sessions [dict get $data sessions]
        set path [dict get $data project_path]
        
        set session_parts [list]
        foreach sess $sessions {
            set subagents_parts [list]
            foreach sub [dict get $sess subagents] {
                lappend subagents_parts [format {{"agent_id":"%s","agent_type":"%s","description":"%s","cost_usd":%s,"turns":%d,"duration_secs":%s,"human_secs":%s,"matches":[%s]}} \
                    [escape_json [dict get $sub agent_id]] \
                    [escape_json [dict get $sub agent_type]] \
                    [escape_json [dict get $sub description]] \
                    [format_cost [dict get $sub cost_usd]] \
                    [dict get $sub turns] \
                    [format_secs [dict get $sub duration_secs]] \
                    [format_secs [dict getdef $sub human_secs ""]] \
                    [format_matches [dict get $sub matches]]]
            }
            
            lappend session_parts [format {{"uuid":"%s","path":"%s","title":"%s","first_ts":"%s","cost_usd":%s,"turns":%d,"duration_secs":%s,"human_secs":%s,"matches":[%s],"subagents":[%s]}} \
                [escape_json [dict get $sess uuid]] \
                [escape_json [dict get $sess path]] \
                [escape_json [dict get $sess title]] \
                [escape_json [dict get $sess first_ts]] \
                [format_cost [dict get $sess cost_usd]] \
                [dict get $sess turns] \
                [format_secs [dict get $sess duration_secs]] \
                [format_secs [dict getdef $sess human_secs ""]] \
                [format_matches [dict get $sess matches]] \
                [join $subagents_parts ","]]
        }
        
        lappend folder_parts [format {{"folder":"%s","project_path":"%s","sessions":[%s]}} \
            [escape_json $folder] \
            [escape_json $path] \
            [join $session_parts ","]]
    }
    return "\[[join $folder_parts ","]\]"
}

# Render the --shortstat summary: a terse totals block over the same result set
# --json would emit. Sums the priced cost (the unknown sentinel and zero are
# skipped), the session and subagent counts, the turns, and the token categories
# that make up the cost. A non-zero limit capped the set, so it is named rather
# than left to read as a complete total.
proc ::questlog::cli::main::format_shortstat {stats limit} {
    set lines [list]
    lappend lines [format "sessions           %s"    [dict get $stats sessions]]
    lappend lines [format "subagent sessions  %s"    [dict get $stats subagents]]
    lappend lines [format "turns              %s"    [dict get $stats turns]]
    lappend lines [format "input tokens       %s"    [dict get $stats input_tokens]]
    lappend lines [format "output tokens      %s"    [dict get $stats output_tokens]]
    lappend lines [format "cache write tokens %s"    [dict get $stats cache_write_tokens]]
    lappend lines [format "cache read tokens  %s"    [dict get $stats cache_read_tokens]]
    lappend lines [format "total cost         \$%.2f" [dict get $stats cost]]
    if {$limit > 0} {
        lappend lines [format "limit applied      %s (totals cover the first %s sessions only)" \
            $limit $limit]
    }
    return [join $lines "\n"]
}

# Print command-line mode usage and exit.
proc ::questlog::cli::main::usage {} {
    puts stderr "usage: questlog \[--json|--shortstat\] \[bounds\] \[clauses\]"
    puts stderr ""
    puts stderr "A session is returned when its clauses hold. Each clause is one needle in an"
    puts stderr "optional region-list; clauses combine by one algebra: adjacency is AND, --or is"
    puts stderr "OR, --not negates the next clause. Precedence is NOT > AND > OR. There is no"
    puts stderr "grouping - a query that needs A AND (B OR C) is rejected; reorder to DNF instead."
    puts stderr ""
    puts stderr "output (one is required; each runs headless, no GUI):"
    puts stderr "  --json                  Emit the full result as JSON."
    puts stderr "  --shortstat             Emit a totals summary instead: session and subagent"
    puts stderr "                          counts, turns, tokens, and total cost over the result."
    puts stderr ""
    puts stderr "  Cost = the tokens recorded in each transcript priced at per-model API rates;"
    puts stderr "  computed here, an API-equivalent figure, not a number the harness billed."
    puts stderr "  By default a session's whole-transcript cost counts once it falls in the"
    puts stderr "  window; --accrued-cost instead counts only the spend dated inside the window."
    puts stderr ""
    puts stderr "clauses:"
    puts stderr "  --keyword\[:regions\] <needle>   Literal needle (aliases: --kw, --search). A bare"
    puts stderr "                                argument is the same as --keyword."
    puts stderr "  --regex\[:regions\] <needle>     Regex needle (aliases: --rx, --pattern)."
    puts stderr "  --tool:read <file>            A file read (by path suffix)."
    puts stderr "  --tool:write|edit|file <file> A file written / edited / touched."
    puts stderr "  --tool:<name> <key>           A use of a tool (Bash, Grep, ...) whose invocation"
    puts stderr "                                contains the key (empty key = any use)."
    puts stderr "  --or                          OR between the clause before and the clause after."
    puts stderr "  --not                         Negate the next clause."
    puts stderr ""
    puts stderr "regions (the :regions suffix on --keyword/--regex; comma-joins for OR):"
    puts stderr "  user, assistant, tool-use, tool-result, any (default). Unambiguous prefixes are"
    puts stderr "  accepted, e.g. --keyword:user,assi <needle>. Omit the suffix to match anywhere."
    puts stderr ""
    puts stderr "bounds (global, applied to the whole result - not clauses):"
    puts stderr "  --since <when>          Recency bound: a window (24h, 7d, 2w), a date (2026-04-01), or 'all'."
    puts stderr "  --until <when>          Older bound: up to a window ago (7d), a date (2026-04-01), or 'all' (no bound)."
    puts stderr "  --under <dir>           Only sessions located under the directory."
    puts stderr "  --accrued-cost          Count only spend dated inside the --since/--until window,"
    puts stderr "                          by each message's timestamp. Needs a time bound; --until"
    puts stderr "                          alone scans the whole corpus."
    puts stderr "  --limit <N>             Cap returned sessions (unset or 0 = unlimited)."
    puts stderr "  --limit-matches <N>     Cap snippets per session/subagent (0 = none)."
    puts stderr "  --case                  Case-sensitive keyword matching (default: insensitive)."
    exit 2
}

# Helper to filter and limit matches to the requested cap
proc ::questlog::cli::main::limit_matches {matches limit_cap {sub_path ""}} {
    set out [list]
    if {$limit_cap <= 0} { return $out }
    set idx 0
    foreach m $matches {
        if {$sub_path ne "" && [dict getdef $m path ""] ne $sub_path} continue
        if {$idx >= $limit_cap} break
        lappend out [dict create \
            "line" [dict get $m lineoff] \
            "type" [dict get $m btype] \
            "content" [dict get $m content]]
        incr idx
    }
    return $out
}

# Parse a CLI :regions suffix, exiting cleanly on a bad spec rather than dumping
# a stack trace. An empty suffix (no colon, or a bare "--keyword:") is the
# unrestricted default.
proc ::questlog::cli::main::regions {spec} {
    if {[catch {::questlog::search::parse_regions $spec} out]} {
        puts stderr "questlog: $out"
        exit 2
    }
    return $out
}

# The value following a clause flag; a missing one is an error rather than a
# silent empty needle (which would match every session).
proc ::questlog::cli::main::next_val {argvVar iVar flag} {
    upvar 1 $argvVar argv $iVar i
    incr i
    if {$i >= [llength $argv]} {
        puts stderr "questlog: $flag needs a value"
        ::questlog::cli::main::usage
    }
    return [lindex $argv $i]
}

# Append a leaf to the flat leaf list and the current AND-group, then clear the
# pending --not. The leaf already carries its negation, so the reset only guards
# the next clause.
proc ::questlog::cli::main::push_leaf {leavesVar curVar negVar leaf} {
    upvar 1 $leavesVar leaves $curVar cur $negVar pending_neg
    set id [llength $leaves]
    lappend leaves $leaf
    lappend cur [::questlog::match::tnode_leaf $id]
    set pending_neg 0
}

# parse_query argv - turn the clause and bound arguments into a query: the
# matcher clauses (leaves + boolean tree + nocase) and the global bounds (limit,
# limit_matches, under, since, until). The grammar is an OR (--or) of AND-groups
# (adjacency) of optionally-negated (--not) leaves; groups is the closed
# AND-groups and cur the one being built, while bounds ride outside the tree. A
# malformed query prints a message and exits through usage. Separated from run so
# the grammar is a unit a test can drive from argv to tree.
proc ::questlog::cli::main::parse_query {argv} {
    set limit 0
    set limit_matches -1
    set under ""
    set since ""
    set until ""
    set accrued 0
    set nocase 1
    set mode json
    set leaves [list]
    set groups [list]
    set cur [list]
    set pending_neg 0

    for {set i 0} {$i < [llength $argv]} {incr i} {
        set arg [lindex $argv $i]
        # Keyword and regex clauses carry an optional :regions suffix.
        if {[regexp {^--(?:keyword|kw|search)(?::(.*))?$} $arg -> rspec]} {
            set val [::questlog::cli::main::next_val argv i $arg]
            ::questlog::cli::main::push_leaf leaves cur pending_neg \
                [::questlog::match::kw_leaf $val [::questlog::cli::main::regions $rspec] $pending_neg]
            continue
        }
        if {[regexp {^--(?:regex|rx|pattern)(?::(.*))?$} $arg -> rspec]} {
            set val [::questlog::cli::main::next_val argv i $arg]
            ::questlog::cli::main::push_leaf leaves cur pending_neg \
                [::questlog::match::rx_leaf $val [::questlog::cli::main::regions $rspec] $pending_neg]
            continue
        }
        if {[string match --tool:* $arg]} {
            set selector [string range $arg [string length "--tool:"] end]
            set val [::questlog::cli::main::next_val argv i $arg]
            lassign [::questlog::search::tool_selector $selector] kind spec
            ::questlog::cli::main::push_leaf leaves cur pending_neg \
                [::questlog::match::tool_leaf $kind $spec $val $pending_neg]
            continue
        }
        switch -glob -- $arg {
            --json - --cmd { set mode json }
            --shortstat { set mode shortstat }
            --help - -h { ::questlog::cli::main::usage }
            --or {
                if {$pending_neg || [llength $cur] == 0} {
                    puts stderr "questlog: --or needs a clause on each side"
                    ::questlog::cli::main::usage
                }
                lappend groups [::questlog::match::tnode_and $cur]
                set cur [list]
            }
            --not {
                if {$pending_neg} {
                    puts stderr "questlog: --not --not is not allowed"
                    ::questlog::cli::main::usage
                }
                set pending_neg 1
            }
            --limit         { set limit [::questlog::cli::main::next_val argv i $arg] }
            --limit-matches { set limit_matches [::questlog::cli::main::next_val argv i $arg] }
            --since         { set since [::questlog::cli::main::next_val argv i $arg] }
            --until         { set until [::questlog::cli::main::next_val argv i $arg] }
            --accrued-cost  { set accrued 1 }
            --under         { set under [::questlog::cli::main::next_val argv i $arg] }
            --case          { set nocase 0 }
            "(" - ")" - "--(" - "--)" - --and {
                puts stderr "questlog: grouping is not supported - the flag algebra has no\
                    parentheses. Reorder to OR-of-ANDs, e.g. 'A B --or A C' for 'A AND (B OR C)'."
                exit 2
            }
            -* {
                puts stderr "Unknown option: $arg"
                ::questlog::cli::main::usage
            }
            default {
                ::questlog::cli::main::push_leaf leaves cur pending_neg \
                    [::questlog::match::kw_leaf $arg {} $pending_neg]
            }
        }
    }
    if {$pending_neg} {
        puts stderr "questlog: --not has no following clause"
        ::questlog::cli::main::usage
    }
    if {[llength $cur] > 0} {
        lappend groups [::questlog::match::tnode_and $cur]
    } elseif {[llength $groups] > 0} {
        puts stderr "questlog: --or needs a clause on each side"
        ::questlog::cli::main::usage
    }
    if {$limit eq "all"} { set limit 0 }

    # --since accepts a relative window (24h, 7d, 2w, ...) or an absolute date
    # (2026-04-01); "" or "all" mean no bound. Validate now so a bad spec fails
    # fast rather than at cutoff time.
    if {$since ne "" && $since ne "all"
        && [catch {::questlog::filter::parse_since $since}]} {
        puts stderr "questlog: --since: invalid '$since' (want 24h/7d/2w, a date 2026-04-01, or 'all')"
        ::questlog::cli::main::usage
    }
    # --until shares the since spec grammar; it is the upper edge of the window.
    if {$until ne "" && $until ne "all"
        && [catch {::questlog::filter::parse_since $until}]} {
        puts stderr "questlog: --until: invalid '$until' (want 24h/7d/2w, a date 2026-04-01, or 'all')"
        ::questlog::cli::main::usage
    }
    # --accrued-cost windows the spend, so it has no meaning without a window:
    # require a real --since or --until ("" and "all" both parse to {none}).
    if {$accrued
        && [lindex [::questlog::filter::parse_since $since] 0] eq "none"
        && [lindex [::questlog::filter::parse_since $until] 0] eq "none"} {
        puts stderr "questlog: --accrued-cost needs a time bound (--since and/or --until)"
        ::questlog::cli::main::usage
    }

    return [dict create \
        clauses [dict create leaves $leaves \
            tree [::questlog::match::tnode_or $groups] nocase $nocase] \
        limit $limit limit_matches $limit_matches under $under since $since \
        until $until accrued $accrued mode $mode]
}

# Apply a rename from the command line: `questlog rename <session.jsonl> [title]`.
# An empty or omitted title reverts the session to its auto title. The rename is
# a path-only domain op (::questlog::rename, in lib/), so it runs headless with
# no GUI and no display. Prints the effective title now in force.
proc ::questlog::cli::main::rename {argv} {
    if {[llength $argv] < 1 || [llength $argv] > 2} {
        puts stderr "usage: questlog rename <session.jsonl> \[title]"
        puts stderr "  Sets the session's custom title; an empty or omitted title reverts to the auto title."
        exit 2
    }
    set path [lindex $argv 0]
    if {![file isfile $path]} {
        puts stderr "questlog: no such session file: $path"
        exit 1
    }
    puts [::questlog::rename::apply $path [lindex $argv 1]]
}

# Print a finished session as the reading-view transcript:
# `questlog show <session.jsonl|uuid>`. The headless twin of the GUI reading
# view: it reuses the same emitter (::questlog::markdown::export_session) the
# viewer's copy/export-markdown actions use, so the two never drift, and asks it
# for record-number anchors so each turn can be cited. Runs with no GUI and no
# display. A session that cannot be read is a hard error.
proc ::questlog::cli::main::show {argv} {
    if {[llength $argv] != 1} {
        puts stderr "usage: questlog show <session.jsonl|uuid>"
        puts stderr "  Prints the session as a readable transcript, each turn anchored by its record number."
        exit 2
    }
    set path [resolve_session [lindex $argv 0]]
    set md [::questlog::markdown::export_session $path 1]
    if {$md eq ""} {
        puts stderr "questlog: could not read session: $path"
        exit 1
    }
    puts $md
}

# Resolve a `show` argument to a session jsonl path. An existing file is taken
# as-is; otherwise the argument is read as a session uuid and matched against
# <projects_root>/<folder>/<uuid>.jsonl across every folder. A uuid naming no
# session, or (defensively, since uuids are unique) more than one, is a hard
# error rather than a silent pick.
proc ::questlog::cli::main::resolve_session {arg} {
    if {[file isfile $arg]} { return $arg }
    set root [::questlog::path::projects_root]
    set hits [glob -nocomplain -- [file join $root * $arg.jsonl]]
    switch -- [llength $hits] {
        0 {
            puts stderr "questlog: no such session: $arg"
            exit 1
        }
        1 { return [lindex $hits 0] }
        default {
            puts stderr "questlog: ambiguous session uuid: $arg"
            foreach h [lsort $hits] { puts stderr "  $h" }
            exit 1
        }
    }
}

# The snapshot used for file/row SELECTION in accrued mode: the original with the
# until ceiling cleared, so a session revived after the ceiling (yet holding
# pre-ceiling, in-window messages) is not pruned. The since floor and under-scope
# stay - a file with mtime <= floor holds no in-window message, so it is a safe,
# tight prefilter. Pure, so a test can drive it.
proc ::questlog::cli::main::selection_snapshot_for {snapshot} {
    dict set snapshot until ""
    return $snapshot
}

# 1 iff an accrue_window result carries any in-window spend or activity. An
# unpriced model yields cost_usd -1.0 yet had real activity, so test the model
# breakdown and turn count, not the dollar figure.
proc ::questlog::cli::main::has_window_spend {cost_info} {
    return [expr {[dict size [dict getdef $cost_info model_breakdown {}]] > 0 \
        || [dict getdef $cost_info turns 0] > 0}]
}

# Run the command-line search engine.
proc ::questlog::cli::main::run {argv} {
    variable ::ROOT
    if {![info exists ROOT]} {
        set ROOT [file dirname [file dirname [file normalize [info script]]]]
    }

    # 1. Parse the query: clauses (the boolean tree of leaves) and global bounds.
    set q [::questlog::cli::main::parse_query $argv]
    set clauses       [dict get $q clauses]
    set limit         [dict get $q limit]
    set limit_matches [dict get $q limit_matches]
    set under         [dict get $q under]
    set since         [dict get $q since]
    set until         [dict get $q until]
    set accrued       [dict get $q accrued]
    set mode          [dict get $q mode]

    # If --limit-matches is not set, default to config defaults
    if {$limit_matches == -1} {
        set sess_limit [::questlog::config::get snippets_per_session]
        set sub_limit [::questlog::config::get snippets_per_subagent]
    } else {
        set sess_limit $limit_matches
        set sub_limit $limit_matches
    }

    # 2. The row-level scope snapshot: since, until, under. These ride outside
    # the boolean algebra as global filters. The CLI has no session-list view, so
    # it carries none of the list-view toggles; row_matches applies scope only.
    set snapshot [dict create \
        under [expr {$under eq "" ? {} : [list $under]}] \
        since $since \
        until $until]

    # In accrued mode, cost is windowed by each message's timestamp, so file/row
    # SELECTION must not apply the until ceiling (a session revived after it can
    # still hold in-window messages); the since floor is kept as a safe prefilter.
    # The window edges [acc_lo, acc_hi] come from the original bounds.
    if {$accrued} {
        set acc_lo [::questlog::filter::cutoff_for $snapshot]
        set acc_hi [::questlog::filter::ceiling_for $snapshot]
        set sel_snapshot [::questlog::cli::main::selection_snapshot_for $snapshot]
    } else {
        set sel_snapshot $snapshot
    }

    set scan [::questlog::Scan new {} {}]

    # Initialize rates for synchronous costing
    ::questlog::cost::load_rates $ROOT

    # 3. Discover on-disk files including subagents
    set paths [$scan list_paths_for $sel_snapshot 1]

    # Group matches by parent session and subagents
    set session_groups [dict create]

    foreach path $paths {
        # Check if this is a subagent file
        set is_child 0
        set folder [file tail [file dirname $path]]
        if {$folder eq "subagents"} {
            set is_child 1
            set sessdir [file dirname [file dirname $path]]
            set parent_path [file join [file dirname $sessdir] [file tail $sessdir].jsonl]
        } else {
            set parent_path $path
        }

        # If we reached the limit of sessions, we can stop sifting paths entirely!
        if {$limit > 0 && [dict size $session_groups] >= $limit && ![dict exists $session_groups $parent_path]} {
            break
        }

        # Match logic
        lassign [::questlog::match::scan_file $path $clauses] row matches
        if {$row eq ""} continue
        
        # Apply snapshot-level row filters (recency bound, one_turn, bookmarked, and under-folder)
        if {![::questlog::filter::row_matches $sel_snapshot $row]} {
            continue
        }

        # If filters are active, and no matches were found, this file doesn't pass
        if {[llength $matches] == 0 && [::questlog::search::clauses_any $clauses]} {
            continue
        }

        # Store matches and parent association
        if {[dict exists $session_groups $parent_path]} {
            set entry [dict get $session_groups $parent_path]
        } else {
            if {$limit > 0 && [dict size $session_groups] >= $limit} {
                continue
            }
            set entry [dict create parent_row "" parent_matches {} subagent_matches {}]
        }

        if {$is_child} {
            set sub_matches [dict get $entry subagent_matches]
            lappend sub_matches {*}$matches
            dict set entry subagent_matches $sub_matches
        } else {
            dict set entry parent_row $row
            dict set entry parent_matches $matches
        }
        dict set session_groups $parent_path $entry
    }

    # 4. Construct JSON Model
    set output_folders [dict create]

    # --shortstat accumulators, summed over the same result set as --json.
    set n_sessions 0; set n_subagents 0
    set total_cost 0.0; set total_turns 0
    set total_in 0; set total_out 0; set total_cw 0; set total_cr 0

    dict for {parent_path group_data} $session_groups {
        set parent_row [dict get $group_data parent_row]
        if {$parent_row eq ""} {
            # Parent session itself didn't match filters but subagent did; scan parent row
            set parent_row [$scan scan_path $parent_path]
            if {$parent_row eq ""} continue
        }

        set folder [dict get $parent_row folder]
        set parent_uuid [dict get $parent_row uuid]

        # Parent cost: whole-transcript by default, windowed under --accrued-cost.
        if {$accrued} {
            set cost_info [::questlog::cost::accrue_window $parent_path $acc_lo $acc_hi]
        } else {
            set cost_info [::questlog::cli::cost::compute_sync $parent_path]
        }
        set parent_cost [dict getdef $cost_info cost_usd ""]
        set parent_turns [dict getdef $cost_info turns 0]
        set parent_duration [dict getdef $cost_info duration_secs ""]
        set parent_human [dict getdef $cost_info human_secs ""]

        # Limit parent matches
        set limited_sess_matches [limit_matches [dict getdef $group_data parent_matches {}] $sess_limit]

        # Resolve subagents; under --accrued-cost drop those with no in-window
        # spend, and accumulate their totals in temporaries so the whole subtree
        # can be dropped (and never counted) if nothing in it landed in the window.
        set subagents_list [list]
        set sub_n 0
        set sub_cost_sum 0.0; set sub_turns_sum 0
        set sub_in_sum 0; set sub_out_sum 0; set sub_cw_sum 0; set sub_cr_sum 0
        foreach sub [$scan subagents_for $parent_path] {
            set sub_path [dict get $sub path]
            if {$accrued} {
                set sub_cost_info [::questlog::cost::accrue_window $sub_path $acc_lo $acc_hi]
                if {![::questlog::cli::main::has_window_spend $sub_cost_info]} continue
            } else {
                set sub_cost_info [::questlog::cli::cost::compute_sync $sub_path]
            }
            incr sub_n
            set sub_cost [dict getdef $sub_cost_info cost_usd ""]
            if {[string is double -strict $sub_cost] && $sub_cost > 0} {
                set sub_cost_sum [expr {$sub_cost_sum + $sub_cost}]
            }
            incr sub_turns_sum [dict getdef $sub_cost_info turns 0]
            set sub_in_sum  [expr {$sub_in_sum  + [dict getdef $sub_cost_info input_tokens 0]}]
            set sub_out_sum [expr {$sub_out_sum + [dict getdef $sub_cost_info output_tokens 0]}]
            set sub_cw_sum  [expr {$sub_cw_sum  + [dict getdef $sub_cost_info cache_write_tokens 0]}]
            set sub_cr_sum  [expr {$sub_cr_sum  + [dict getdef $sub_cost_info cache_read_tokens 0]}]

            # Find and limit matching snippets for this subagent if any
            set limited_sub_matches [limit_matches [dict getdef $group_data subagent_matches {}] $sub_limit $sub_path]

            lappend subagents_list [dict create \
                "agent_id" [dict get $sub agent_id] \
                "agent_type" [dict get $sub agent_type] \
                "description" [dict get $sub description] \
                "cost_usd" [dict getdef $sub_cost_info cost_usd ""] \
                "turns" [dict getdef $sub_cost_info turns 0] \
                "duration_secs" [dict getdef $sub_cost_info duration_secs ""] \
                "human_secs" [dict getdef $sub_cost_info human_secs ""] \
                "matches" $limited_sub_matches]
        }

        # In accrued mode, drop a whole subtree that contributed nothing to the
        # window (neither the parent nor any surviving subagent).
        if {$accrued && ![::questlog::cli::main::has_window_spend $cost_info] \
                && [llength $subagents_list] == 0} {
            continue
        }

        # The subtree is kept: commit it to the --shortstat totals now.
        incr n_sessions
        if {[string is double -strict $parent_cost] && $parent_cost > 0} {
            set total_cost [expr {$total_cost + $parent_cost}]
        }
        incr total_turns $parent_turns
        set total_in  [expr {$total_in  + [dict getdef $cost_info input_tokens 0]}]
        set total_out [expr {$total_out + [dict getdef $cost_info output_tokens 0]}]
        set total_cw  [expr {$total_cw  + [dict getdef $cost_info cache_write_tokens 0]}]
        set total_cr  [expr {$total_cr  + [dict getdef $cost_info cache_read_tokens 0]}]
        incr n_subagents $sub_n
        set total_cost   [expr {$total_cost + $sub_cost_sum}]
        incr total_turns $sub_turns_sum
        set total_in  [expr {$total_in  + $sub_in_sum}]
        set total_out [expr {$total_out + $sub_out_sum}]
        set total_cw  [expr {$total_cw  + $sub_cw_sum}]
        set total_cr  [expr {$total_cr  + $sub_cr_sum}]

        set session_json [dict create \
            "uuid" $parent_uuid \
            "path" $parent_path \
            "title" [dict getdef $parent_row slug "Unnamed Session"] \
            "first_ts" [dict get $parent_row first_ts] \
            "cost_usd" $parent_cost \
            "turns" $parent_turns \
            "duration_secs" $parent_duration \
            "human_secs" $parent_human \
            "matches" $limited_sess_matches \
            "subagents" $subagents_list]

        if {![dict exists $output_folders $folder]} {
            dict set output_folders $folder [dict create \
                "project_path" [$scan resolve_folder $folder] \
                "sessions" {}]
        }
        set folder_data [dict get $output_folders $folder]
        dict lappend folder_data sessions $session_json
        dict set output_folders $folder $folder_data
    }

    # Emit the result in the requested mode.
    if {$mode eq "shortstat"} {
        puts [format_shortstat [dict create \
            sessions $n_sessions subagents $n_subagents cost $total_cost \
            turns $total_turns input_tokens $total_in output_tokens $total_out \
            cache_write_tokens $total_cw cache_read_tokens $total_cr] $limit]
    } else {
        puts [format_json $output_folders]
    }
}
