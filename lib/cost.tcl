package require Tcl 9
package require Thread
package require json

# ::questlog::cost - per-session token cost computation.
#
# Runs as a second pass after the main scan. The scan keeps its early-break
# on first-prompt extraction; cost needs every assistant turn, so it ships
# the work to a tpool of worker threads. One worker job per JSONL: open,
# regex the lines whose `"type":"assistant"` matters, JSON-parse those,
# accumulate per-model {input,output,cache_creation_input,cache_read_input}
# token counts. Workers send results back to the main thread via
# thread::send -async; on_worker_result updates Scan.Rows + the list row.
#
# A late result from a prior cancel is discarded by epoch.
#
# Singleton; one running app needs one cost scanner. Held in namespace
# variables, not a class, because all three of the issue-67 criteria
# (named globals, joint state, tell-don't-ask) collapse to one named
# global that meaningfully mutates (Epoch), so a class would be
# scaffolding around what is essentially four procs over an epoch.

namespace eval ::questlog::cost {
    variable Rates [dict create]
    variable Loaded 0
    variable WorkerScript ""

    variable Pool ""
    variable MainTid ""
    variable Epoch 0
    variable OnResult ""
}

# Load the rate table. CSV columns:
#   model,effective_from,input_per_mtok,output_per_mtok,
#   cache_write_per_mtok,cache_read_per_mtok
# Rates dict: model -> sorted list of {effective_from in out cw cr}.
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
        if {[llength $fields] != 6} continue
        lassign $fields model ef ri ro rw rr
        set model [string trim $model]
        set existing [expr {[dict exists $Rates $model] ? [dict get $Rates $model] : [list]}]
        lappend existing [list $ef $ri $ro $rw $rr]
        dict set Rates $model [lsort -index 0 $existing]
        incr n
    }
    close $fh
    set Loaded 1
    return $n
}

# Pick the rate row whose effective_from <= session_date. Empty if no
# row matches (unknown model, or date before the first listed era).
proc ::questlog::cost::rate_for {model session_date} {
    variable Rates
    if {![dict exists $Rates $model]} { return "" }
    set best ""
    foreach row [dict get $Rates $model] {
        set ef [lindex $row 0]
        if {[string compare $ef $session_date] <= 0} { set best $row }
    }
    return $best
}

# per_model dict {model -> {in out cw cr}} + session date -> USD.
# -1 signals "no rate row found for any model" -> UI shows blank.
proc ::questlog::cost::compute_usd {per_model session_date} {
    set total 0.0
    set any 0
    dict for {model counts} $per_model {
        set row [rate_for $model $session_date]
        if {$row eq ""} continue
        lassign $row _ ri ro rw rr
        lassign $counts in out cw cr
        set total [expr {$total + \
            ($in * $ri + $out * $ro + $cw * $rw + $cr * $rr) / 1000000.0}]
        set any 1
    }
    if {!$any} { return -1.0 }
    return $total
}

# Compact dollar format for the list column.
proc ::questlog::cost::format_cost {usd} {
    if {$usd < 0 || $usd == 0} { return "" }
    if {$usd < 0.01}            { return "<1¢" }
    if {$usd < 1.0}             { return [format "%d¢" [expr {int(round($usd*100))}]] }
    return [format "\$%.2f" $usd]
}

# Compact dollar format for aggregate totals (folder, status strip).
proc ::questlog::cost::format_total {usd} {
    if {$usd <= 0} { return "" }
    return [format "\$%.2f" $usd]
}

# Sourced into each tpool worker once at creation. Worker interpreters
# share nothing with the main interp, so the file-reading procs live here.
set ::questlog::cost::WorkerScript {
    package require Tcl 9
    package require Thread
    package require json

    proc compute_cost {path} {
        set per_model [dict create]
        set first_ts ""
        if {[catch {open $path r} fh]} {
            return [dict create per_model {} first_ts "" ok 0]
        }
        chan configure $fh -encoding utf-8 -profile replace
        while {[chan gets $fh line] >= 0} {
            if {$line eq ""} continue
            if {$first_ts eq "" && [regexp {"timestamp":"([^"]+)"} $line -> m]} {
                set first_ts $m
            }
            if {![regexp {"type":"assistant"} $line]} continue
            if {[catch {::json::json2dict $line} rec]} continue
            if {![dict exists $rec message]} continue
            set msg [dict get $rec message]
            set model ""
            if {[dict exists $msg model]} { set model [dict get $msg model] }
            if {![dict exists $msg usage]} continue
            set u [dict get $msg usage]
            set in_t  [expr {[dict exists $u input_tokens] ? [dict get $u input_tokens] : 0}]
            set out_t [expr {[dict exists $u output_tokens] ? [dict get $u output_tokens] : 0}]
            set cw_t  [expr {[dict exists $u cache_creation_input_tokens] ? [dict get $u cache_creation_input_tokens] : 0}]
            set cr_t  [expr {[dict exists $u cache_read_input_tokens] ? [dict get $u cache_read_input_tokens] : 0}]
            if {$model eq ""} { set model unknown }
            if {[dict exists $per_model $model]} {
                lassign [dict get $per_model $model] pi po pw pr
                dict set per_model $model [list \
                    [expr {$pi+$in_t}] [expr {$po+$out_t}] \
                    [expr {$pw+$cw_t}] [expr {$pr+$cr_t}]]
            } else {
                dict set per_model $model [list $in_t $out_t $cw_t $cr_t]
            }
        }
        close $fh
        return [dict create per_model $per_model first_ts $first_ts ok 1]
    }

    proc dispatch_main {path tid epoch} {
        set r [compute_cost $path]
        thread::send -async $tid \
            [list ::questlog::cost::on_worker_result $path $epoch $r]
    }
}

# Initialise the singleton scanner. Called once at app start, after
# load_rates so the rate table is in place before any worker fires.
proc ::questlog::cost::init {on_result} {
    variable Pool
    variable MainTid
    variable Epoch
    variable OnResult
    variable WorkerScript
    set OnResult $on_result
    set Epoch 0
    set MainTid [thread::id]
    set Pool [tpool::create -minworkers 0 -maxworkers 4 -initcmd $WorkerScript]
}

# Queue a cost task for one session path. Returns immediately; the
# result arrives later on the main thread via on_worker_result.
proc ::questlog::cost::start_one {path} {
    variable Pool
    variable MainTid
    variable Epoch
    if {$Pool eq ""} return
    tpool::post -nowait $Pool [list dispatch_main $path $MainTid $Epoch]
}

# Bump epoch so late results from prior posts are discarded. The pool
# stays alive; the next start_one carries the new epoch.
proc ::questlog::cost::cancel {} {
    variable Epoch
    incr Epoch
}

# Worker callback - eval'd in the main thread from thread::send -async.
proc ::questlog::cost::on_worker_result {path epoch result} {
    variable Epoch
    variable OnResult
    if {$epoch != $Epoch} return
    if {![dict get $result ok]} return
    set per_model [dict get $result per_model]
    set first_ts  [dict get $result first_ts]
    set session_date [string range $first_ts 0 9]
    if {$session_date eq ""} {
        set session_date [clock format [clock seconds] -format %Y-%m-%d]
    }
    set usd [compute_usd $per_model $session_date]
    set in 0; set out 0; set cw 0; set cr 0
    dict for {_ c} $per_model {
        lassign $c i o w r
        incr in $i; incr out $o; incr cw $w; incr cr $r
    }
    set cost_dict [dict create \
        cost_usd $usd \
        input_tokens $in output_tokens $out \
        cache_write_tokens $cw cache_read_tokens $cr \
        model_breakdown $per_model]
    if {$OnResult ne ""} { {*}$OnResult $path $cost_dict }
}
