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
                lappend subagents_parts [format {{"agent_id":"%s","agent_type":"%s","description":"%s","cost_usd":%s,"turns":%d,"duration_secs":%s,"matches":[%s]}} \
                    [escape_json [dict get $sub agent_id]] \
                    [escape_json [dict get $sub agent_type]] \
                    [escape_json [dict get $sub description]] \
                    [expr {[dict get $sub cost_usd] eq "" ? "null" : [dict get $sub cost_usd]}] \
                    [dict get $sub turns] \
                    [expr {[dict get $sub duration_secs] eq "" ? "null" : [dict get $sub duration_secs]}] \
                    [format_matches [dict get $sub matches]]]
            }
            
            lappend session_parts [format {{"uuid":"%s","path":"%s","title":"%s","first_ts":"%s","cost_usd":%s,"turns":%d,"duration_secs":%s,"matches":[%s],"subagents":[%s]}} \
                [escape_json [dict get $sess uuid]] \
                [escape_json [dict get $sess path]] \
                [escape_json [dict get $sess title]] \
                [escape_json [dict get $sess first_ts]] \
                [expr {[dict get $sess cost_usd] eq "" ? "null" : [dict get $sess cost_usd]}] \
                [dict get $sess turns] \
                [expr {[dict get $sess duration_secs] eq "" ? "null" : [dict get $sess duration_secs]}] \
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

# Print command-line mode usage and exit.
proc ::questlog::cli::main::usage {} {
    puts stderr "usage: questlog --json \[bounds\] \[clauses\]"
    puts stderr ""
    puts stderr "A session is returned when its clauses hold. Each clause is one needle in an"
    puts stderr "optional region-list; clauses combine by one algebra: adjacency is AND, --or is"
    puts stderr "OR, --not negates the next clause. Precedence is NOT > AND > OR. There is no"
    puts stderr "grouping - a query that needs A AND (B OR C) is rejected; reorder to DNF instead."
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
    puts stderr "  --since <dur>           Only sessions active in the last <dur> (e.g. 24h, 7d, 2w)."
    puts stderr "  --under <dir>           Only sessions located under the directory."
    puts stderr "  --limit <N>             Cap returned sessions (default: 50, 0 = unlimited)."
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

# Run the command-line search engine.
proc ::questlog::cli::main::run {argv} {
    variable ::ROOT
    if {![info exists ROOT]} {
        set ROOT [file dirname [file dirname [file normalize [info script]]]]
    }

    # 1. Parse arguments into a clause tree plus the global bounds. Clauses build
    # an OR (--or) of AND-groups (adjacency) of optionally-negated (--not)
    # leaves: groups is the closed AND-groups, cur the one being built.
    set limit 50
    set limit_matches -1
    set under ""
    set since ""
    set nocase 1
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
            --json - --cmd {}
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

    # --since accepts an open duration (24h, 7d, 2w, ...); "" or "all" mean no
    # bound. Validate now so a bad spec fails fast rather than at cutoff time.
    if {$since ne "" && $since ne "all"
        && [catch {::questlog::filter::parse_since $since}]} {
        puts stderr "questlog: --since: invalid duration '$since' (e.g. 24h, 7d, 2w, or 'all')"
        ::questlog::cli::main::usage
    }

    # If --limit-matches is not set, default to config defaults
    if {$limit_matches == -1} {
        set sess_limit [::questlog::config::get snippets_per_session]
        set sub_limit [::questlog::config::get snippets_per_subagent]
    } else {
        set sess_limit $limit_matches
        set sub_limit $limit_matches
    }

    # 2. Assemble the clause tree and the row-level bounds snapshot. The bounds
    # (since, under, one_turn) ride outside the boolean algebra as global filters.
    set clauses [dict create leaves $leaves \
        tree [::questlog::match::tnode_or $groups] nocase $nocase]
    set snapshot [dict create \
        under [expr {$under eq "" ? {} : [list $under]}] \
        since $since \
        one_turn 0]

    set scan [::questlog::Scan new {} {}]

    # Initialize rates for synchronous costing
    ::questlog::cost::load_rates $ROOT

    # 3. Discover on-disk files including subagents
    set paths [$scan list_paths_for $snapshot 1]

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
        if {![::questlog::filter::row_matches $snapshot $row]} {
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

    dict for {parent_path group_data} $session_groups {
        set parent_row [dict get $group_data parent_row]
        if {$parent_row eq ""} {
            # Parent session itself didn't match filters but subagent did; scan parent row
            set parent_row [$scan scan_path $parent_path]
            if {$parent_row eq ""} continue
        }

        set folder [dict get $parent_row folder]
        set parent_uuid [dict get $parent_row uuid]

        # Calculate parent cost synchronously
        set cost_info [::questlog::cli::cost::compute_sync $parent_path]
        set parent_cost [dict getdef $cost_info cost_usd ""]
        set parent_turns [dict getdef $cost_info turns 0]
        set parent_duration [dict getdef $cost_info duration_secs ""]

        # Limit parent matches
        set limited_sess_matches [limit_matches [dict getdef $group_data parent_matches {}] $sess_limit]

        # Resolve subagents of this session
        set subagents_list [list]
        foreach sub [$scan subagents_for $parent_path] {
            set sub_path [dict get $sub path]
            set sub_cost_info [::questlog::cli::cost::compute_sync $sub_path]
            
            # Find and limit matching snippets for this subagent if any
            set limited_sub_matches [limit_matches [dict getdef $group_data subagent_matches {}] $sub_limit $sub_path]

            lappend subagents_list [dict create \
                "agent_id" [dict get $sub agent_id] \
                "agent_type" [dict get $sub agent_type] \
                "description" [dict get $sub description] \
                "cost_usd" [dict getdef $sub_cost_info cost_usd ""] \
                "turns" [dict getdef $sub_cost_info turns 0] \
                "duration_secs" [dict getdef $sub_cost_info duration_secs ""] \
                "matches" $limited_sub_matches]
        }

        set session_json [dict create \
            "uuid" $parent_uuid \
            "path" $parent_path \
            "title" [dict getdef $parent_row slug "Unnamed Session"] \
            "first_ts" [dict get $parent_row first_ts] \
            "cost_usd" $parent_cost \
            "turns" $parent_turns \
            "duration_secs" $parent_duration \
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

    # Print JSON output to stdout
    puts [format_json $output_folders]
}
