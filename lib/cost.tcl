package require Tcl 9
package require json

# ::questlog::cost - per-session token cost computation.
#
# Pure domain module. Computes cost and durations.

namespace eval ::questlog::cost {
    variable Rates [dict create]
    variable Loaded 0
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

# Format a USD amount as $X.XX, used for the session cells, the folder totals
# and the status strip alike. Blank for zero or unknown (negative), so an empty
# cell reads as "no figure" rather than a misleading $0.00.
proc ::questlog::cost::format_usd {usd} {
    if {$usd <= 0} { return "" }
    return [format "\$%.2f" $usd]
}

# Active work seconds: the wall-clock span with idle gaps removed. The gap
# between two consecutive records is idle when the later record is a typed
# human prompt, meaning the assistant had finished its turn and the session
# sat waiting for the user. Resuming a session after hours or days adds one
# such gap, so it contributes nothing; only the time the session was actually
# working (including the minutes a tool or subagent ran inside a turn) is
# counted. `stamps` is a list of {epoch is_human_prompt} pairs in any order.
# Blank when fewer than two records carry a timestamp.
proc ::questlog::cost::active_secs {stamps} {
    if {[llength $stamps] < 2} { return "" }
    set stamps [lsort -integer -index 0 $stamps]
    set active 0
    set prev [lindex [lindex $stamps 0] 0]
    foreach pair [lrange $stamps 1 end] {
        lassign $pair e is_human
        if {!$is_human} { incr active [expr {$e - $prev}] }
        set prev $e
    }
    return $active
}

# A second count as MM:SS, or H:MM:SS once it passes an hour, for the Duration
# cell. Blank for an empty/negative count so the cell reads as "no figure".
proc ::questlog::cost::fmt_dur {secs} {
    if {$secs eq "" || $secs < 0} { return "" }
    set h [expr {$secs / 3600}]
    set m [expr {($secs % 3600) / 60}]
    set s [expr {$secs % 60}]
    if {$h > 0} { return [format "%d:%02d:%02d" $h $m $s] }
    return [format "%02d:%02d" $m $s]
}

# ISO-8601 UTC timestamp (e.g. 2026-04-25T10:00:00.000Z) to epoch seconds.
# Tolerates a missing fractional part; empty on any parse failure.
proc ::questlog::cost::iso_to_epoch {ts} {
    if {![regexp {^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})} $ts \
              -> y mo d h mi s]} {
        return ""
    }
    if {[catch {clock scan "$y-$mo-$d $h:$mi:$s" \
            -gmt 1 -format "%Y-%m-%d %H:%M:%S"} e]} {
        return ""
    }
    return $e
}

proc ::questlog::cost::parse_file {path} {
    set req_usage [dict create]
    set dummy_req 0
    set first_ts ""
    set last_ts ""
    set turns 0
    set stamps [list]
    if {[catch {open $path r} fh]} {
        return [dict create per_model {} first_ts "" last_ts "" turns 0 stamps {} ok 0]
    }
    chan configure $fh -encoding utf-8 -profile replace
    while {[chan gets $fh line] >= 0} {
        if {$line eq ""} continue
        set user_prompt [regexp {"role":"user","content":"} $line]
        if {$user_prompt} { incr turns }
        if {[regexp {"timestamp":"([^"]+)"} $line -> m]} {
            if {$first_ts eq ""} { set first_ts $m }
            set last_ts $m
            set e [iso_to_epoch $m]
            if {$e ne ""} {
                # Idle time is the gap before a human turn: a user record that
                # is neither a tool result nor a subagent's own (sidechain)
                # prompt. Its content may be a string or an array (text plus a
                # pasted block), so key on the role and exclude tool-result and
                # sidechain records rather than on the string-content shape.
                set is_human [expr {[regexp {"role":"user"} $line] \
                    && ![regexp {"type":"tool_result"} $line] \
                    && ![regexp {"isSidechain":true} $line]}]
                lappend stamps [list $e $is_human]
            }
        }
        if {![regexp {"type":"assistant"} $line]} continue
        if {[catch {::json::json2dict $line} rec]} continue
        if {![dict exists $rec message]} continue
        set msg [dict get $rec message]

        set req_id [dict getdef $rec requestId [dict getdef $msg requestId ""]]
        if {$req_id eq ""} { set req_id "dummy-[incr dummy_req]" }

        set model [dict getdef $msg model "unknown"]
        if {![dict exists $msg usage]} continue
        set u [dict get $msg usage]
        set in_t  [dict getdef $u input_tokens 0]
        set out_t [dict getdef $u output_tokens 0]
        set cw_t  [dict getdef $u cache_creation_input_tokens 0]
        set cr_t  [dict getdef $u cache_read_input_tokens 0]

        if {[dict exists $req_usage $req_id]} {
            lassign [dict get $req_usage $req_id] om oi oo ow or
            if {$om eq "unknown"} { set om $model }
            dict set req_usage $req_id [list $om \
                [expr {max($in_t, $oi)}] [expr {max($out_t, $oo)}] \
                [expr {max($cw_t, $ow)}] [expr {max($cr_t, $or)}]]
        } else {
            dict set req_usage $req_id [list $model $in_t $out_t $cw_t $cr_t]
        }
    }
    close $fh

    set per_model [dict create]
    dict for {_ counts} $req_usage {
        lassign $counts m i o w r
        lassign [dict getdef $per_model $m {0 0 0 0}] pi po pw pr
        dict set per_model $m [list [expr {$pi+$i}] [expr {$po+$o}] [expr {$pw+$w}] [expr {$pr+$r}]]
    }

    return [dict create per_model $per_model \
        first_ts $first_ts last_ts $last_ts turns $turns stamps $stamps ok 1]
}

proc ::questlog::cost::build_cost_dict {res} {
    if {![dict get $res ok]} {
        return [dict create cost_usd 0.0 turns 0 duration_secs 0 input_tokens 0 output_tokens 0 cache_write_tokens 0 cache_read_tokens 0 model_breakdown {}]
    }
    set per_model [dict get $res per_model]
    set first_ts [dict get $res first_ts]
    set turns [dict get $res turns]

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
    return [dict create \
        cost_usd $usd \
        input_tokens $in \
        output_tokens $out \
        cache_write_tokens $cw \
        cache_read_tokens $cr \
        model_breakdown $per_model \
        turns $turns \
        duration_secs [active_secs [dict get $res stamps]]]
}

