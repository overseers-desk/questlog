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
    puts stderr "usage: questlog --json \[options\] \[search_term\]"
    puts stderr "options:"
    puts stderr "  --limit <N>             Limit the number of returned sessions (default: 50, use 0 for unlimited)"
    puts stderr "  --limit-matches <N>     Limit matched snippets per session/subagent (0 = none)"
    puts stderr "  --search <key>          Search for a key in session contents"
    puts stderr "  --scope <where>         Restrict the search to: anywhere | text | tool-call | tool-output"
    puts stderr "  --since <dur>           Only sessions active in the last <dur> (e.g. 24h, 7d, 2w); default all"
    puts stderr "  --pattern <regex>       Filter sessions by regex content pattern (alias: --regex)"
    puts stderr "  --tool:read <file>      Filter sessions that read a file (by path suffix)"
    puts stderr "  --tool:write <file>     Filter sessions that wrote a file"
    puts stderr "  --tool:edit <file>      Filter sessions that edited a file"
    puts stderr "  --tool:file <file>      Filter sessions that touched a file (read, wrote, or created)"
    puts stderr "  --tool:<name> <key>     Filter sessions that used a tool (Bash, Grep, ...) whose"
    puts stderr "                          invocation contains the key (empty key = any use)"
    puts stderr "  --under <dir>           Filter sessions located under the specified directory"
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

# Run the command-line search engine.
proc ::questlog::cli::main::run {argv} {
    variable ::ROOT
    if {![info exists ROOT]} {
        set ROOT [file dirname [file dirname [file normalize [info script]]]]
    }

    # 1. Parse Arguments
    set limit 50
    set limit_matches -1
    set search_key ""
    set pattern ""
    set under ""
    set since ""
    set files [list]   ;# {op path} pairs feeding the file clause
    set tools [list]   ;# {name key} pairs feeding the tool clause
    set scope anywhere

    for {set i 0} {$i < [llength $argv]} {incr i} {
        set arg [lindex $argv $i]
        switch -glob -- $arg {
            --json - --cmd {}
            --help - -h { ::questlog::cli::main::usage }
            --limit         { set limit [lindex $argv [incr i]] }
            --limit-matches { set limit_matches [lindex $argv [incr i]] }
            --search        { set search_key [lindex $argv [incr i]] }
            --pattern - --regex { set pattern [lindex $argv [incr i]] }
            --scope         { set scope [lindex $argv [incr i]] }
            --since         { set since [lindex $argv [incr i]] }
            --under         { set under [lindex $argv [incr i]] }
            --tool:* {
                set selector [string range $arg [string length "--tool:"] end]
                set val [lindex $argv [incr i]]
                lassign [::questlog::search::tool_selector $selector] kind spec
                if {$kind eq "file"} {
                    lappend files [list $spec $val]
                } else {
                    lappend tools [list $spec $val]
                }
            }
            -* {
                puts stderr "Unknown option: $arg"
                ::questlog::cli::main::usage
            }
            default { set search_key $arg }
        }
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

    # 2. Build the query criteria snapshot
    set snapshot [dict create \
        search $search_key \
        search_case 0 \
        search_scope $scope \
        pattern [expr {$pattern eq "" ? {} : [list $pattern]}] \
        file  $files \
        tool  $tools \
        under [expr {$under eq "" ? {} : [list $under]}] \
        since $since \
        one_turn 0]

    set clauses [::questlog::search::build_clauses $snapshot]
    set scan [::questlog::Scan new {} {}]

    # Initialize rates for synchronous costing
    ::questlog::cost::load_rates $ROOT

    # Determine if any query or directory filters are active
    set has_filters [expr {
        [::questlog::search::clauses_any $clauses] ||
        [llength [dict get $snapshot under]] > 0
    }]

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
