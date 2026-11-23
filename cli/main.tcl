package require Tcl 9
package require json

namespace eval ::questlog::cli::main {}

# Escape characters to output valid JSON strings: the short forms plus every
# remaining C0 control as \u00XX, so transcript content carrying ANSI or other
# control bytes cannot break the emitted document (jq refuses raw controls).
# The map is built once, at source time.
namespace eval ::questlog::cli::main {
    variable JsonEscapeMap [list "\\" "\\\\" "\"" "\\\""]
    variable _shorts [dict create "\b" "\\b" "\f" "\\f" "\n" "\\n" "\r" "\\r" "\t" "\\t"]
    for {set _i 0} {$_i < 32} {incr _i} {
        set _c [format %c $_i]
        lappend JsonEscapeMap $_c [dict getdef $_shorts $_c [format "\\u%04x" $_i]]
    }
    unset -nocomplain _i _c _shorts
}
proc ::questlog::cli::main::escape_json {str} {
    variable JsonEscapeMap
    return [string map $JsonEscapeMap $str]
}

# A context window (grep -A/-B/-C) as JSON array elements: each turn its
# physical line, reading-view role label, full body, and whether it is the hit.
proc ::questlog::cli::main::format_window {turns} {
    set parts [list]
    foreach t $turns {
        lappend parts [format {{"line":%d,"role":"%s","text":"%s","match":%s}} \
            [dict get $t line] \
            [escape_json [dict get $t role]] \
            [escape_json [dict get $t text]] \
            [expr {[dict get $t match] ? "true" : "false"}]]
    }
    return [join $parts ","]
}

# Helper to format match records into JSON array elements. A match carries a
# "window" only under a context flag; it is added beside line/type/content, so a
# consumer reading only the snippet is unaffected.
proc ::questlog::cli::main::format_matches {matches} {
    set parts [list]
    foreach m $matches {
        set fields [format {"line":%d,"type":"%s","content":"%s"} \
            [dict get $m line] \
            [escape_json [dict get $m type]] \
            [escape_json [dict get $m content]]]
        if {[dict exists $m window]} {
            append fields ",\"window\":\[[format_window [dict get $m window]]\]"
        }
        lappend parts "{$fields}"
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

# ---- totals ----------------------------------------------------------------
#
# A query answers which sessions match; these answer what they came to. One
# accumulator serves every surface: --shortstat prints it over the result and
# again per folder, --json hangs it on each folder object, --markdown renders it
# under each folder heading. Its keys are the shortstat stats dict's keys, so
# there is one name per number rather than one per surface.
#
# The caveat below travels with the figures, not with the documentation,
# because a reader meets a total at the moment they need to distrust it;
# TimeCaveat states what to distrust and why.
namespace eval ::questlog::cli::main {
    variable TimeCaveat "whole-session wall clock: concurrent sessions double\
count, a subagent's time is its parent's and is not added again, and a session\
that only partly concerned the query counts whole"
}

# The caveat with the human-gap rule in force behind it: what --json's
# time_basis carries and --markdown closes on, so a consumer reading only the
# totals still reads the values that made the human figure.
proc ::questlog::cli::main::time_basis {} {
    variable TimeCaveat
    return "$TimeCaveat; human time: [::questlog::cost::human_gap_rule] (--human-gap)"
}

proc ::questlog::cli::main::totals_zero {} {
    return [dict create sessions 0 subagents 0 turns 0 \
        input_tokens 0 output_tokens 0 cache_write_tokens 0 cache_read_tokens 0 \
        cost_usd 0.0 duration_secs 0 human_secs 0 first_ts "" last_ts "" days {}]
}

# The calendar day an ISO transcript timestamp fell on, in the reader's own
# timezone: the corpus stamps UTC, and a day boundary read in UTC would split a
# working day (or join two) for anyone not on it. An unparseable or empty stamp
# yields "" and is counted as no day.
proc ::questlog::cli::main::local_day {ts} {
    if {[catch {clock scan [string range $ts 0 18] \
            -format "%Y-%m-%dT%H:%M:%S" -gmt 1} epoch]} { return "" }
    return [clock format $epoch -format %Y-%m-%d]
}

# Fold one session's or subagent's cost dict into an accumulator. kind is the
# count it lands in (sessions or subagents); ts is the session's first
# timestamp, which only a parent session carries, so the span and the day set
# count sessions rather than transcripts. A subagent adds its turns, tokens
# and cost but no time: it runs inside a Task bracket of its parent, whose
# duration_secs already covers that clock, and its own transcript holds no
# human turn to time (the rule the session list's recompute_parent_totals
# keeps for a row). The cost sentinel (-1.0, no rate matched) adds nothing to
# cost. The one contribution is built as an accumulator of its own and merged,
# so widening a span is written once, in totals_merge.
proc ::questlog::cli::main::totals_add {tot ci kind {ts ""}} {
    set one [totals_zero]
    dict incr one $kind
    set fields {turns input_tokens output_tokens cache_write_tokens cache_read_tokens}
    if {$kind eq "sessions"} { lappend fields duration_secs human_secs }
    foreach f $fields {
        set v [dict getdef $ci $f 0]
        if {[string is integer -strict $v]} { dict incr one $f $v }
    }
    set c [dict getdef $ci cost_usd ""]
    if {[string is double -strict $c] && $c > 0} { dict set one cost_usd $c }
    if {[set day [local_day $ts]] ne ""} {
        dict set one days $day 1
        dict set one first_ts $ts
        dict set one last_ts $ts
    }
    return [totals_merge $tot $one]
}

# Fold one accumulator into another: how a folder's totals reach the result's,
# so the whole and its parts are summed once, by one rule. The day sets union,
# so a day two folders share counts once.
proc ::questlog::cli::main::totals_merge {a b} {
    foreach f {sessions subagents turns input_tokens output_tokens \
               cache_write_tokens cache_read_tokens duration_secs human_secs} {
        dict incr a $f [dict get $b $f]
    }
    dict set a cost_usd [expr {[dict get $a cost_usd] + [dict get $b cost_usd]}]
    dict for {d _} [dict get $b days] { dict set a days $d 1 }
    set bf [dict get $b first_ts]
    if {$bf ne "" && ([dict get $a first_ts] eq ""
            || [string compare $bf [dict get $a first_ts]] < 0)} {
        dict set a first_ts $bf
    }
    if {[string compare [dict get $b last_ts] [dict get $a last_ts]] > 0} {
        dict set a last_ts [dict get $b last_ts]
    }
    return $a
}

# An accumulator as a JSON object: the counts and tokens as they stand, the
# span as the two ISO stamps --json already speaks, the day set as its size, and
# the caveat as a field so a consumer reading only the totals still reads it.
proc ::questlog::cli::main::format_totals_json {tot} {
    return [format {{"sessions":%d,"subagent_sessions":%d,"turns":%d,"input_tokens":%d,"output_tokens":%d,"cache_write_tokens":%d,"cache_read_tokens":%d,"cost_usd":%.6f,"human_secs":%d,"duration_secs":%d,"first_ts":"%s","last_ts":"%s","days":%d,"time_basis":"%s"}} \
        [dict get $tot sessions] [dict get $tot subagents] [dict get $tot turns] \
        [dict get $tot input_tokens] [dict get $tot output_tokens] \
        [dict get $tot cache_write_tokens] [dict get $tot cache_read_tokens] \
        [dict get $tot cost_usd] [dict get $tot human_secs] [dict get $tot duration_secs] \
        [escape_json [dict get $tot first_ts]] [escape_json [dict get $tot last_ts]] \
        [dict size [dict get $tot days]] [escape_json [time_basis]]]
}

# An accumulator as one middot-separated line, for the surfaces meant to be
# read: a folder heading in --markdown, a folder row in --shortstat. Times use
# fmt_dur, the format the session list's Duration column and md_meta use. A span
# inside one day prints that day rather than repeating it.
proc ::questlog::cli::main::totals_line {tot} {
    set parts [list [count_label [dict get $tot sessions] session]]
    if {[dict get $tot subagents] > 0} {
        lappend parts [count_label [dict get $tot subagents] "subagent session"]
    }
    lappend parts [count_label [dict get $tot turns] turn] \
        "human [::questlog::cost::fmt_dur [dict get $tot human_secs]]" \
        "machine [::questlog::cost::fmt_dur [dict get $tot duration_secs]]" \
        [format {$%.2f} [dict get $tot cost_usd]]
    set lo [local_day [dict get $tot first_ts]]
    set hi [local_day [dict get $tot last_ts]]
    if {$lo ne ""} { lappend parts [expr {$lo eq $hi ? $lo : "$lo to $hi"}] }
    lappend parts [count_label [dict size [dict get $tot days]] day]
    return [join $parts " · "]
}

proc ::questlog::cli::main::count_label {n word} {
    return "$n $word[expr {$n == 1 ? {} : {s}}]"
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
        
        # The folder's totals ride beside its sessions, so a consumer reading a
        # folder reads what it came to without walking the array. A caller with
        # no totals (a serializer test, a fixture) gets a folder object with no
        # totals field.
        set tail ""
        if {[dict exists $data totals]} {
            set tail ",\"totals\":[format_totals_json [dict get $data totals]]"
        }
        lappend folder_parts [format {{"folder":"%s","project_path":"%s","sessions":[%s]%s}} \
            [escape_json $folder] \
            [escape_json $path] \
            [join $session_parts ","] \
            $tail]
    }
    return "\[[join $folder_parts ","]\]"
}

# Render the --shortstat summary: a terse totals block over the same result set
# --json would emit. Sums the priced cost (the unknown sentinel and zero are
# skipped), the session and subagent counts, the turns, the token categories
# that make up the cost, the human and machine time, and the calendar reach of
# the result - its first and last session and how many distinct days hold one. A
# non-zero limit capped the set, so it is named rather than left to read as a
# complete total. `folders` is a list of {label totals cost} rows, printed under
# the whole as the breakdown by project folder, dearest first: the breakdown
# answers "what did this project cost me", so the answer heads the list.
proc ::questlog::cli::main::format_shortstat {stats limit {folders {}}} {
    set lines [list]
    lappend lines [format "sessions           %s"    [dict get $stats sessions]]
    lappend lines [format "subagent sessions  %s"    [dict get $stats subagents]]
    lappend lines [format "turns              %s"    [dict get $stats turns]]
    lappend lines [format "input tokens       %s"    [dict get $stats input_tokens]]
    lappend lines [format "output tokens      %s"    [dict get $stats output_tokens]]
    lappend lines [format "cache write tokens %s"    [dict get $stats cache_write_tokens]]
    lappend lines [format "cache read tokens  %s"    [dict get $stats cache_read_tokens]]
    lappend lines [format "total cost         \$%.2f" [dict get $stats cost_usd]]
    lappend lines [format "human time         %s (%s)" \
        [::questlog::cost::fmt_dur [dict get $stats human_secs]] [::questlog::cost::human_gap_rule]]
    lappend lines [format "machine time       %s"    [::questlog::cost::fmt_dur [dict get $stats duration_secs]]]
    lappend lines [format "first session      %s"    [local_day [dict get $stats first_ts]]]
    lappend lines [format "last session       %s"    [local_day [dict get $stats last_ts]]]
    lappend lines [format "days with sessions %s"   [dict size [dict get $stats days]]]
    if {$limit > 0} {
        lappend lines [format "limit applied      %s (totals cover the first %s sessions only)" \
            $limit $limit]
    }
    lappend lines "" "time is $::questlog::cli::main::TimeCaveat."
    if {[llength $folders] > 1} {
        lappend lines "" "by folder:"
        foreach pair [lsort -real -decreasing -index 2 $folders] {
            lappend lines "  [lindex $pair 0]" "    [totals_line [lindex $pair 1]]"
        }
    }
    return [join $lines "\n"]
}


# A cost_usd domain value to its markdown token: blank for the "no figure"
# sentinel (unpriced or no assistant turns), a "$0.00"-style figure otherwise.
# The markdown twin of format_cost, which serves the same distinction as null.
proc ::questlog::cli::main::md_cost {usd} {
    if {$usd eq "" || $usd < 0} { return "" }
    return [format {$%.2f} $usd]
}

# The one-line identity/metadata line under a session or subagent heading,
# carrying the same fields --json does: a session's uuid (which
# `questlog show <uuid>` reopens) or a subagent's agent_id (show has no entry
# point for one, so it identifies but does not reopen), the first timestamp when
# present (subagents carry none), the turn count, the duration and human time
# when timed (both via fmt_dur's MM:SS/H:MM:SS, the same format the session
# list's Duration column uses), and the cost when priced.
proc ::questlog::cli::main::md_meta {ident ts turns dur human usd} {
    set parts [list $ident]
    if {$ts ne ""} { lappend parts $ts }
    lappend parts "$turns turns"
    set d [::questlog::cost::fmt_dur $dur]
    if {$d ne ""} { lappend parts "duration $d" }
    set h [::questlog::cost::fmt_dur $human]
    if {$h ne ""} { lappend parts "human $h" }
    set c [md_cost $usd]
    if {$c ne ""} { lappend parts $c }
    return [join $parts " · "]
}

# A match list rendered to markdown. Without a context flag a match is its
# one-line snippet, headed by the same [#N] record anchor the JSON "line" field
# and the reading view use. Under context the match carries a window: its whole
# messages, each a **[#N] ROLE** turn as in the reading-view export, the hit's
# own turn tagged (match), the run closed by a rule.
proc ::questlog::cli::main::format_md_matches {matches} {
    set out [list]
    foreach m $matches {
        if {[dict exists $m window]} {
            foreach t [dict get $m window] {
                set tag [expr {[dict get $t match] ? " (match)" : ""}]
                lappend out "**\[#[dict get $t line]] [dict get $t role]$tag**" \
                    "" [dict get $t text] ""
            }
            lappend out "---"
        } else {
            lappend out "- **\[#[dict get $m line]] [dict get $m type]** [dict get $m content]"
        }
    }
    return [join $out "\n"]
}

# Render the whole result to markdown - the same folders/sessions/subagents/
# matches model --json emits, as a document meant to be read and analysed rather
# than parsed. Folders head the document, each session its title and identity
# line, each hit its anchored snippet; subagents nest under their parent. Reuses
# the [#N] anchor style of the reading-view export so the two markdown surfaces
# read alike.
proc ::questlog::cli::main::format_markdown {folders_dict} {
    set out [list]
    dict for {folder data} $folders_dict {
        set path [dict get $data project_path]
        lappend out "# [expr {$path ne {} ? $path : $folder}]"
        if {[dict exists $data totals]} {
            lappend out "" "*[totals_line [dict get $data totals]]*"
        }
        foreach sess [dict get $data sessions] {
            lappend out "" "## [dict get $sess title]"
            lappend out [md_meta [dict get $sess uuid] [dict get $sess first_ts] \
                [dict get $sess turns] [dict get $sess duration_secs] \
                [dict get $sess human_secs] [dict get $sess cost_usd]]
            lappend out "`[dict get $sess path]`"
            set mm [format_md_matches [dict get $sess matches]]
            if {$mm ne ""} { lappend out "" $mm }
            foreach sub [dict get $sess subagents] {
                lappend out "" "### subagent [dict get $sub agent_type]: [dict get $sub description]"
                lappend out [md_meta [dict get $sub agent_id] "" \
                    [dict get $sub turns] [dict get $sub duration_secs] \
                    [dict get $sub human_secs] [dict get $sub cost_usd]]
                set sm [format_md_matches [dict get $sub matches]]
                if {$sm ne ""} { lappend out "" $sm }
            }
        }
        lappend out ""
    }
    # The caveat closes the document rather than heading each folder: it holds
    # for every figure above it, and repeating it per folder would drown them.
    if {[dict size $folders_dict]} {
        lappend out "---" "*Totals are [time_basis].*"
    }
    return [join $out "\n"]
}

# Trim and cap a session's or subagent's matches, and under grep-style
# context (before/after > 0) attach each match's window: the whole messages
# around the hit, read back from the session file by physical line. A match
# already carries its file path and physical line, so the window is read here at
# emission (only for the matches actually shown), not buffered during the scan.
#
# Under dialogue a hit that lives in the machinery (a tool call, its result, a
# thinking block) is dropped, keeping only hits in what the user or assistant
# said; a kept hit's context window is drawn through the same dialogue selection
# (context_window's dialogue mode), so its turns carry only prose and the
# excerpt reads as conversation. A roles list narrows that to one side, so
# --dialogue:user answers with the prompts alone and the window around each.
proc ::questlog::cli::main::limit_matches {matches limit_cap {sub_path ""} {before 0} {after 0} {dialogue 0} {roles {}}} {
    set keep [expr {[llength $roles] ? $roles : {user assistant}}]
    set out [list]
    if {$limit_cap <= 0} { return $out }
    set idx 0
    foreach m $matches {
        if {$sub_path ne "" && [dict getdef $m path ""] ne $sub_path} continue
        if {$dialogue && [dict get $m btype] ni $keep} continue
        if {$idx >= $limit_cap} break
        set entry [dict create \
            "line" [dict get $m lineoff] \
            "type" [dict get $m btype] \
            "content" [dict get $m content]]
        if {$before > 0 || $after > 0} {
            dict set entry window [::logman::context_window \
                [dict get $m path] [dict get $m lineoff] $before $after \
                $dialogue $roles]
        }
        lappend out $entry
        incr idx
    }
    return $out
}

# fold q - the neutral query dict's clause groups as the matcher's
# {leaves tree nocase} form: each group's clauses AND together, the groups OR.
# The grammar itself lives in cli/commandline.tcl; this is the one place its
# vocabulary meets the matcher's leaves.
proc ::questlog::cli::main::fold {q} {
    set leaves [list]
    set ornodes [list]
    foreach group [dict get $q groups] {
        set andnodes [list]
        foreach c $group {
            set neg [dict get $c neg]
            set val [dict get $c value]
            switch -- [dict get $c kind] {
                keyword { set leaf [::questlog::match::kw_leaf $val [dict get $c regions] $neg] }
                regex   { set leaf [::questlog::match::rx_leaf $val [dict get $c regions] $neg] }
                tool    { set leaf [::questlog::match::tool_leaf [dict get $c selkind] \
                                        [dict get $c selspec] $val $neg] }
            }
            lappend andnodes [::questlog::match::tnode_leaf [llength $leaves]]
            lappend leaves $leaf
        }
        lappend ornodes [::questlog::match::tnode_and $andnodes]
    }
    return [dict create leaves $leaves \
        tree [::questlog::match::tnode_or $ornodes] nocase [dict get $q nocase]]
}

# Apply a rename from the command line: `questlog rename <session.jsonl> [title]`.
# A subcommand handed the wrong arguments prints how it is written, from the
# declaration in cli/commandline.tcl that the dispatcher reads, and exits 2.
proc ::questlog::cli::main::misuse {name} {
    foreach line [::questlog::cli::commandline::subcommand_usage $name] { puts stderr $line }
    exit 2
}

# An empty or omitted title reverts the session to its auto title. The rename is
# a path-only domain op (::questlog::rename, in lib/), so it runs headless with
# no GUI and no display. Prints the effective title now in force.
proc ::questlog::cli::main::rename {argv} {
    if {[llength $argv] < 1 || [llength $argv] > 2} { ::questlog::cli::main::misuse rename }
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
    set dialogue 0
    set roles [list]
    set rest [list]
    foreach a $argv {
        if {$a eq "--dialogue" || [string match "--dialogue:*" $a]} {
            set dialogue 1
            if {[catch {::questlog::search::dialogue_roles \
                    [string range $a [string length "--dialogue:"] end]} out]} {
                puts stderr "questlog: $out"
                exit 2
            }
            set roles $out
        } else {
            lappend rest $a
        }
    }
    if {[llength $rest] != 1} { ::questlog::cli::main::misuse show }
    set path [resolve_session [lindex $rest 0]]
    set md [::questlog::markdown::export_session $path 1 $dialogue $roles]
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
# pre-ceiling, in-window messages) is not pruned. The since floor and subtree bound
# stay - a file with mtime <= floor holds no in-window message, so it is a safe,
# tight pre-gate. Pure, so a test can drive it.
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

# ---- parallel file work (issue #17) -----------------------------------------

# Worker count for the CLI's file pool: 0 when Thread is unavailable or
# QUESTLOG_THREADS=0 (the single-thread fallback), the env override when set,
# else a core-based default. Same formula and config band as the search
# fan-out's picker (::questlog::config stays the one home for the numbers).
proc ::questlog::cli::main::worker_count {} {
    if {![::questlog::search::thread_available]} { return 0 }
    set v [::questlog::search::env_threads]
    if {$v ne ""} { return $v }
    set cores 0
    if {![catch {exec nproc} out] && [string is integer -strict [string trim $out]]} {
        set cores [string trim $out]
    } elseif {![catch {exec sysctl -n hw.ncpu} out]
              && [string is integer -strict [string trim $out]]} {
        set cores [string trim $out]
    }
    if {$cores < 2} { return [::questlog::config::get search_threads_fallback] }
    set n [expr {$cores - [::questlog::config::get search_threads_reserve]}]
    set lo [::questlog::config::get search_threads_min]
    set hi [::questlog::config::get search_threads_max]
    if {$n < $lo} { set n $lo }
    if {$n > $hi} { set n $hi }
    return $n
}

# A fixed-size tpool whose workers can run both the matcher (scan_file) and the
# cost parse (compute_sync / accrue_window), or "" for the single-thread path.
# minworkers = maxworkers: a min-0 pool never grows past the one worker it
# lazily spawns (issue #56), so the pass would run serially through it. Each
# worker sources the matcher (via worker_prelude, which also bakes the display
# caps) and the cost layer, then loads the rate table, so it can price a file
# whole rather than shipping raw token tallies back. Its config is this
# interp's as it stands, not a fresh read of the launcher's defaults: a rule
# the command line moved (--human-gap) has to price in the worker as it does
# here. Built once, reused for both phases; the caller releases it.
proc ::questlog::cli::main::worker_pool {n} {
    if {$n <= 0} { return "" }
    set root $::ROOT
    set initcmd "::tcl::tm::path add [list [file join $root modules]]
::tcl::tm::path add [list [file join $root vendor]]
set ::questlog_config_only 1; source [list $::QUESTLOG_LAUNCHER]
set ::questlog::config::Config [list $::questlog::config::Config]
[::questlog::search::worker_prelude $root]
source [list [file join $root lib cost.tcl]]
source [list [file join $root cli cost.tcl]]
::questlog::cost::load_rates [list $root]"
    return [tpool::create -minworkers $n -maxworkers $n -initcmd $initcmd]
}

# Run a dict of {key -> command-list} jobs, returning {key -> result}. On the
# pool the jobs run in parallel and are gathered as they finish; without one
# (the single-thread fallback) each runs inline in this interp - the same call
# the synchronous CLI always made, so the two paths return identical results and
# the no-Thread path raises no new warning.
proc ::questlog::cli::main::run_jobs {pool jobs} {
    set out [dict create]
    if {$pool eq ""} {
        dict for {key cmd} $jobs { dict set out $key [{*}$cmd] }
        return $out
    }
    set h2k [dict create]
    set pending [list]
    dict for {key cmd} $jobs {
        set h [tpool::post -nowait $pool $cmd]
        dict set h2k $h $key
        lappend pending $h
    }
    while {[llength $pending]} {
        foreach h [tpool::wait $pool $pending pending] {
            dict set out [dict get $h2k $h] [tpool::get $pool $h]
        }
    }
    return $out
}

# Answer the query on stdout. q is the neutral dict cli/commandline.tcl parsed
# from the command line; its clause groups become the matcher's boolean tree and
# its bounds ride outside as global bounds.
proc ::questlog::cli::main::run {q} {
    variable ::ROOT
    if {![info exists ROOT]} {
        set ROOT [file dirname [file dirname [file normalize [info script]]]]
    }

    set clauses       [::questlog::cli::main::fold $q]
    set limit         [dict get $q limit]
    set limit_matches [dict get $q limit_matches]
    set subtree       [dict get $q subtree]
    set since         [dict get $q since]
    set until         [dict get $q until]
    set accrued       [dict get $q accrued]
    set ctx_before    [dict get $q ctx_before]
    set ctx_after     [dict get $q ctx_after]
    set dialogue      [dict get $q dialogue]
    set dialogue_roles [dict get $q dialogue_roles]
    set mode          [dict get $q mode]

    # If --limit-matches is not set, default to config defaults
    if {$limit_matches == -1} {
        set sess_limit [::questlog::config::get snippets_per_session]
        set sub_limit [::questlog::config::get snippets_per_subagent]
    } else {
        set sess_limit $limit_matches
        set sub_limit $limit_matches
    }

    # Ride the display caps in on the clauses dict so scan_file retires a file's
    # leaf walk once it has buffered the earliest cap of raw hits (lib/match.tcl).
    # Only the CLI does this; the GUI reads exact match totals. Under --dialogue
    # the caps stay off: limit_matches drops tool/thinking hits before counting,
    # so a raw-hit cap could retire before the user/assistant hits it keeps.
    if {!$dialogue} {
        dict set clauses snippet_cap $sess_limit
        dict set clauses snippet_cap_child $sub_limit
    }

    # 2. The row-level bounds snapshot: since, until, subtree. These ride outside
    # the boolean algebra as global bounds. The CLI has no session-list view, so
    # it carries no view filters; row_in_bounds applies bounds only.
    set snapshot [dict create \
        subtree [expr {$subtree eq "" ? {} : [list $subtree]}] \
        since $since \
        until $until]

    # In accrued mode, cost is windowed by each message's timestamp, so file/row
    # SELECTION must not apply the until ceiling (a session revived after it can
    # still hold in-window messages); the since floor is kept as a safe pre-gate.
    # The window edges [acc_lo, acc_hi] come from the original bounds.
    if {$accrued} {
        set acc_lo [::questlog::scan::cutoff_for $snapshot]
        set acc_hi [::questlog::scan::ceiling_for $snapshot]
        set sel_snapshot [::questlog::cli::main::selection_snapshot_for $snapshot]
    } else {
        set sel_snapshot $snapshot
    }

    set scan [::questlog::Scan new {} {}]

    # Rates for the single-thread fallback's own pricing (each worker loads its
    # own copy).
    ::questlog::cost::load_rates $ROOT

    # 3. Discover on-disk files including subagents
    set paths [$scan list_paths_for $sel_snapshot 1]

    # The heavy per-file work runs on a fixed-size worker pool (issue #17): the
    # matcher here, the cost parse below. The grouping, bounds and accrued logic
    # stay on this thread, reading the results. Without Thread the pool is "" and
    # run_jobs runs each call inline - the CLI's original synchronous path.
    # Below two files per worker the pool cannot pay back its ~150ms setup, so a
    # small result stays inline: a handful of files answers faster serially than
    # it would after spinning up threads.
    set nw [::questlog::cli::main::worker_count]
    set pool [::questlog::cli::main::worker_pool \
        [expr {[llength $paths] >= 2 * $nw ? $nw : 0}]]

    # Match every discovered file, in parallel when threaded.
    set scan_jobs [dict create]
    foreach path $paths {
        dict set scan_jobs $path [list ::questlog::match::scan_file $path $clauses]
    }
    set scanned [::questlog::cli::main::run_jobs $pool $scan_jobs]

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

        # Quota full: skip paths that would open a NEW session group, but keep
        # sifting - later (older-mtime) subagent files of sessions already in
        # the result still contribute their snippets. In accrued mode the cap
        # cannot be enforced here at all (whether a session has in-window
        # spend is only known at emission), so it lands on the output loop.
        if {$limit > 0 && !$accrued && [dict size $session_groups] >= $limit
            && ![dict exists $session_groups $parent_path]} {
            continue
        }

        # Match result, computed in parallel above.
        lassign [dict get $scanned $path] row matches
        if {$row eq ""} continue
        
        # Apply the snapshot's row bounds (recency bound and subtree).
        # Stamp residence first: scan_file rows carry no folder_cwd, and the
        # subtree predicate reads it as the authority. A subagent's corpus
        # membership is its parent's (list_paths_for admits children with
        # their parent), so its own mtime is not re-tested against the window;
        # the subtree bound and floors still apply to it.
        set row [$scan stamp_subtree $row]
        set row_snapshot [expr {$is_child \
            ? [dict replace $sel_snapshot since all until all] : $sel_snapshot}]
        if {![::questlog::scan::row_in_bounds $row_snapshot $row]} {
            continue
        }

        # If clauses are active, and no matches were found, this file does not pass
        if {[llength $matches] == 0 && [::questlog::search::clauses_any $clauses]} {
            continue
        }

        # Store matches and parent association
        if {[dict exists $session_groups $parent_path]} {
            set entry [dict get $session_groups $parent_path]
        } else {
            if {$limit > 0 && !$accrued && [dict size $session_groups] >= $limit} {
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

    # Cost every session and subagent that survived grouping, in parallel
    # (issue #17). Under --accrued-cost the window edges ride the job; otherwise
    # it is the whole-file compute_sync. Some accrued subtrees are dropped in the
    # loop below, so a few of these costs go unused - the parallel pass more than
    # pays for that. The output loop reads each cost from here rather than
    # computing it inline.
    set cost_jobs [dict create]
    dict for {pp gd} $session_groups {
        foreach cp [linsert [lmap sub [$scan subagents_for $pp] {dict get $sub path}] 0 $pp] {
            if {$accrued} {
                dict set cost_jobs $cp [list ::questlog::cost::accrue_window $cp $acc_lo $acc_hi]
            } else {
                dict set cost_jobs $cp [list ::questlog::cli::cost::compute_sync $cp]
            }
        }
    }
    set costs [::questlog::cli::main::run_jobs $pool $cost_jobs]
    if {$pool ne ""} { tpool::release $pool }

    # 4. Construct JSON Model
    set output_folders [dict create]

    # Totals, accumulated per folder over the same result set --json emits and
    # merged into the whole below. The result-wide figure --shortstat prints is
    # the sum of the folder figures, by the one fold, so the two cannot disagree.
    set folder_totals [dict create]
    set n_sessions 0

    dict for {parent_path group_data} $session_groups {
        set parent_row [dict get $group_data parent_row]
        if {$parent_row eq ""} {
            # Parent session itself matched no clause but a subagent did; scan parent row
            set parent_row [$scan scan_path $parent_path]
            if {$parent_row eq ""} continue
        }
        # The scan_file row now carries the slug (one extractor, issue #30), so the
        # emitted title is the session's real name without a second read.

        set folder [dict get $parent_row folder]
        set parent_uuid [dict get $parent_row uuid]

        # Parent cost: whole-transcript by default, windowed under --accrued-cost;
        # computed in parallel above.
        set cost_info [dict get $costs $parent_path]
        set parent_cost [dict getdef $cost_info cost_usd ""]
        set parent_turns [dict getdef $cost_info turns 0]
        set parent_duration [dict getdef $cost_info duration_secs ""]
        set parent_human [dict getdef $cost_info human_secs ""]

        # Limit parent matches
        set limited_sess_matches [limit_matches [dict getdef $group_data parent_matches {}] $sess_limit "" $ctx_before $ctx_after $dialogue $dialogue_roles]

        # Resolve subagents; under --accrued-cost drop those with no in-window
        # spend, and accumulate their totals in temporaries so the whole subtree
        # can be dropped (and never counted) if nothing in it landed in the window.
        set subagents_list [list]
        set sub_totals [::questlog::cli::main::totals_zero]
        foreach sub [$scan subagents_for $parent_path] {
            set sub_path [dict get $sub path]
            set sub_cost_info [dict get $costs $sub_path]
            # In accrued mode drop a subagent with no in-window spend.
            if {$accrued && ![::questlog::cli::main::has_window_spend $sub_cost_info]} continue
            set sub_totals [::questlog::cli::main::totals_add \
                $sub_totals $sub_cost_info subagents]

            # Find and limit matching snippets for this subagent if any
            set limited_sub_matches [limit_matches [dict getdef $group_data subagent_matches {}] $sub_limit $sub_path $ctx_before $ctx_after $dialogue $dialogue_roles]

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
        # window (neither the parent nor any surviving subagent), and enforce
        # --limit on the sessions actually emitted - grouping could not know
        # which subtrees would survive to be counted.
        if {$accrued && ![::questlog::cli::main::has_window_spend $cost_info] \
                && [llength $subagents_list] == 0} {
            continue
        }
        if {$accrued && $limit > 0 && $n_sessions >= $limit} continue

        # The subtree is kept: commit it to its folder's totals now. The date
        # span and the day set follow the session, so its subagents (which carry
        # no first timestamp of their own) neither widen nor re-count a day.
        incr n_sessions
        set ftot [dict getdef $folder_totals $folder [::questlog::cli::main::totals_zero]]
        set ftot [::questlog::cli::main::totals_add \
            $ftot $cost_info sessions [dict get $parent_row first_ts]]
        dict set folder_totals $folder \
            [::questlog::cli::main::totals_merge $ftot $sub_totals]

        set session_json [dict create \
            "uuid" $parent_uuid \
            "path" $parent_path \
            "title" [expr {[dict getdef $parent_row slug ""] ne "" \
                ? [dict get $parent_row slug] : "Unnamed Session"}] \
            "first_ts" [dict get $parent_row first_ts] \
            "cost_usd" $parent_cost \
            "turns" $parent_turns \
            "duration_secs" $parent_duration \
            "human_secs" $parent_human \
            "matches" $limited_sess_matches \
            "subagents" $subagents_list]

        if {![dict exists $output_folders $folder]} {
            # The published contract: the directory to cd into, empty when it
            # no longer exists (the resolver still names a gone one by its path).
            set project_path [$scan resolve_folder $folder]
            if {![file isdirectory $project_path]} { set project_path "" }
            dict set output_folders $folder [dict create \
                "project_path" $project_path \
                "sessions" {}]
        }
        set folder_data [dict get $output_folders $folder]
        dict lappend folder_data sessions $session_json
        dict set output_folders $folder $folder_data
    }

    # Hang each folder's totals on its object, and fold them into the whole.
    set whole [::questlog::cli::main::totals_zero]
    set breakdown [list]
    dict for {folder ftot} $folder_totals {
        set whole [::questlog::cli::main::totals_merge $whole $ftot]
        dict set output_folders $folder totals $ftot
        set path [dict get $output_folders $folder project_path]
        lappend breakdown [list [expr {$path ne "" ? $path : $folder}] $ftot \
            [dict get $ftot cost_usd]]
    }

    # Emit the result in the requested mode.
    if {$mode eq "shortstat"} {
        puts [format_shortstat $whole $limit $breakdown]
    } elseif {$mode eq "markdown"} {
        puts [format_markdown $output_folders]
    } else {
        puts [format_json $output_folders]
    }
}
