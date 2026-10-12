package require Tcl 9
package require tallyman

# ::questlog::cost - questlog's host layer over the tallyman cost module.
#
# tallyman does the computation (parse token usage from transcript lines, price
# per model, split the wall clock). This file owns questlog's I/O around it: it
# reads the rate CSV into the rates dict tallyman prices against, reads a
# transcript's lines off disk to hand in, and supplies the human-gap rule from
# config. The pure formatters are tallyman's, re-exported here under the names
# the UI and CLI already call.

namespace eval ::questlog::cost {
    variable Rates [dict create]
    variable Loaded 0
}

# tallyman's formatters, under the ::questlog::cost names in use across the UI
# and CLI. Same signatures - these are aliases, not wrappers.
foreach _p {format_usd fmt_dur fmt_model model_label model_family split_secs} {
    interp alias {} ::questlog::cost::$_p {} tallyman::$_p
}
unset _p

# Load the rate table. CSV columns:
#   model,effective_from,input_per_mtok,output_per_mtok,
#   cache_write_per_mtok,cache_read_per_mtok,prompt_min_tokens
# Rates dict (tallyman's shape): model -> sorted list of
# {effective_from in out cw cr prompt_min}; a row without the last column
# prices every prompt length.
proc ::questlog::cost::load_rates {root} {
    variable Rates
    variable Loaded
    set csv_path [file join $root data anthropic-rates.csv]
    set Rates [dict create]
    set Loaded 0
    if {![file readable $csv_path]} {
        puts stderr "questlog: rates table not readable at $csv_path; cost column blank"
        return 0
    }
    set fh [open $csv_path r]
    chan configure $fh -encoding utf-8
    set n 0
    set lineno 0
    while {[chan gets $fh line] >= 0} {
        incr lineno
        if {$lineno == 1} continue
        set line [string trim $line]
        if {$line eq ""} continue
        if {[string index $line 0] eq "#"} continue
        set fields [split $line ,]
        if {[llength $fields] < 6 || [llength $fields] > 7} continue
        lassign $fields model ef ri ro rw rr pm
        set model [string trim $model]
        if {$pm eq ""} { set pm 0 }
        set existing [expr {[dict exists $Rates $model] ? [dict get $Rates $model] : [list]}]
        lappend existing [list $ef $ri $ro $rw $rr $pm]
        dict set Rates $model [lsort -index 0 $existing]
        incr n
    }
    close $fh
    set Loaded 1
    return $n
}

# Read a transcript's lines off disk and hand them to tallyman. `ok 0` on an
# unreadable file (tallyman never sees a file, so the empty-file result is the
# host's to build); otherwise tallyman's whole-transcript result dict.
proc ::questlog::cost::parse_file {path} {
    if {[catch {open $path r} fh]} {
        return [dict create per_model {} requests {} first_ts "" last_ts "" turns 0 stamps {} last_model "" ok 0]
    }
    chan configure $fh -encoding utf-8 -profile replace
    set lines [split [read $fh] "\n"]
    close $fh
    return [tallyman::parse_lines $lines]
}

# The human-gap rule from config, {threshold credit} in the seconds tallyman's
# split_secs reads.
proc ::questlog::cost::human_gap {} {
    return [list [expr {60 * [::questlog::config::get cost_human_gap_threshold_min]}] \
                 [expr {60 * [::questlog::config::get cost_human_gap_credit_min]}]]
}

# The rule in force as one clause, for the surfaces that show a human-time
# figure (the A/H heading's reveal, --shortstat's line, --json's time_basis):
# a reader meets the values that made the figure where they meet the figure.
proc ::questlog::cost::human_gap_rule {} {
    return "a pause of up to [::questlog::config::get cost_human_gap_threshold_min] min\
        counts in full, a longer one as [::questlog::config::get cost_human_gap_credit_min] min"
}

# Supply the config-driven human-gap rule and the loaded rate table, then price.
proc ::questlog::cost::build_cost_dict {res} {
    variable Rates
    return [tallyman::build_cost_dict $res $Rates {*}[human_gap]]
}

# Windowed spend for `--accrued-cost`: read the transcript's lines, supply the
# rule and rate table, and let tallyman anchor each request in [lo, hi].
proc ::questlog::cost::accrue_window {path lo hi} {
    variable Rates
    if {[catch {open $path r} fh]} {
        return [build_cost_dict [dict create per_model {} requests {} first_ts "" \
            last_ts "" turns 0 stamps {} last_model "" ok 0]]
    }
    chan configure $fh -encoding utf-8 -profile replace
    set lines [split [read $fh] "\n"]
    close $fh
    return [tallyman::accrue_lines $lines $lo $hi $Rates {*}[human_gap]]
}
