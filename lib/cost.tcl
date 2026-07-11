package require Tcl 9
package require json

# ::questlog::cost - per-session token cost computation.
#
# Domain module. Computes cost and the machine/human duration split; the
# composing cap comes from ::questlog::config (loaded everywhere
# build_cost_dict runs; the isolated cost worker calls parse_file only).

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

# Split the wall clock into machine and human seconds. `stamps` is a list of
# {epoch class} pairs in any order; the class of the record that ENDS a gap
# decides whose time the gap is. machine (model output, tool runs, subagent
# activity inside a turn) counts in full. human (the session waiting for the
# user: a typed prompt, a dialog answer) counts as composing time up to `cap`
# seconds; beyond the cap the user was away, and the excess is nobody's time,
# so resuming a session after hours or days credits at most one cap. neutral
# (harness records written during the user's absence or at the moment of
# return) counts for neither side. Returns {machine human}, both blank when
# fewer than two records carry a timestamp.
proc ::questlog::cost::split_secs {stamps cap} {
    if {[llength $stamps] < 2} { return [list "" ""] }
    set stamps [lsort -integer -index 0 $stamps]
    set machine 0
    set human 0
    set prev [lindex [lindex $stamps 0] 0]
    foreach pair [lrange $stamps 1 end] {
        lassign $pair e class
        set gap [expr {$e - $prev}]
        switch -- $class {
            machine { incr machine $gap }
            human   { incr human [expr {min($gap, $cap)}] }
        }
        set prev $e
    }
    return [list $machine $human]
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

# A model id (claude-opus-4-8, claude-sonnet-5, claude-haiku-4-5-20251001) to a
# short "Family Ver" label (Opus 4.8, Sonnet 5, Haiku 4.5) for the session
# list's Model cell. The family is the opus/sonnet/haiku/fable token; the
# version is the one or two numeric groups right after it, joined by a dot - a
# lone group prints bare (Sonnet 5), so the Claude 5 family whose id carries a
# single version number reads as a model rather than a blank cell. A trailing
# date suffix is stripped first so it is never mistaken for a version. Blank for
# an empty or unrecognised id, so the cell reads as "no figure".
proc ::questlog::cost::fmt_model {id} {
    regsub -- {-\d{6,}$} $id "" id
    if {![regexp {(opus|sonnet|haiku|fable)-(\d+)(?:-(\d+))?$} $id -> fam maj min]} {
        return ""
    }
    set fam [string totitle $fam]
    return [expr {$min eq "" ? "$fam $maj" : "$fam $maj.$min"}]
}

# The label a session is known by in the Model column and in the toolbar's model
# lens: the "Family Ver" reading when fmt_model recognises the id, otherwise the
# id itself with any date suffix trimmed. fmt_model alone blanks an id it does
# not price (a local model), which erased the only handle those sessions had:
# with no label they could be neither read off the list nor picked in the lens,
# so they were unfilterable. An empty id stays empty (no session, no label).
# Deliberately the label, not the raw id: two ids that differ only by a date
# suffix are one model, and one label makes them one lens entry.
proc ::questlog::cost::model_label {id} {
    set label [fmt_model $id]
    if {$label ne ""} { return $label }
    regsub -- {-\d{6,}$} $id "" id
    return $id
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

# Classify a record for split_secs: the class of the record ENDING a gap decides
# whose time the gap is (machine / human / neutral). Quotes inside message text
# arrive escaped (\"), so these plain-quote regexes cannot fire on conversation
# content. The one home for this rule, shared by parse_file (whole transcript)
# and accrue_window (a single window); ask_ids carries the AskUserQuestion
# tool_use ids seen so far, so a dialog answer's tool_result counts as the user.
proc ::questlog::cost::classify_stamp {line ask_ids} {
    # Written during the user's absence or at the moment of return (away recaps,
    # synthetic fillers, background-task exits): the gap before them is nobody's.
    if {[regexp {"subtype":"away_summary"} $line] \
            || [regexp {"model":"<synthetic>"} $line] \
            || [regexp {"content":"<task-notification>} $line]} {
        return neutral
    }
    # enqueue is the user typing into the queue; remove and the rest are
    # machine-initiated queue management.
    if {[regexp {"type":"queue-operation"} $line]} {
        return [expr {[regexp {"operation":"enqueue"} $line] ? "human" : "machine"}]
    }
    if {[regexp {"role":"user"} $line] && ![regexp {"isSidechain":true} $line]} {
        # A prompt the user wrote (string or array content), or a slash-command
        # echo: the user acting. A tool_result is machine work landing, except an
        # AskUserQuestion answer: the user returning to a dialog left open.
        if {![regexp {"type":"tool_result"} $line]} { return human }
        foreach {_ id} [regexp -all -inline {"tool_use_id":"([^"]+)"} $line] {
            if {[dict exists $ask_ids $id]} { return human }
        }
        return machine
    }
    return machine
}

proc ::questlog::cost::parse_file {path} {
    set req_usage [dict create]
    set dummy_req 0
    set first_ts ""
    set last_ts ""
    set turns 0
    set stamps [list]
    set ask_ids [dict create]
    set last_model ""
    if {[catch {open $path r} fh]} {
        return [dict create per_model {} first_ts "" last_ts "" turns 0 stamps {} last_model "" ok 0]
    }
    chan configure $fh -encoding utf-8 -profile replace
    while {[chan gets $fh line] >= 0} {
        if {$line eq ""} continue
        # file-history-snapshot records carry no top-level timestamp; the
        # regex below would read the nested snapshot.timestamp as the
        # record's time and turn the away gap before a resume into work.
        # They are no part of the conversation timeline, so skip outright.
        if {[regexp {"type":"file-history-snapshot"} $line]} continue
        # A turn is a prompt the user actually wrote: the shared is_user_turn
        # predicate, the same count the scanner records as nturns.
        if {[::questlog::jsonl::is_user_turn $line]} { incr turns }
        if {[regexp {"timestamp":"([^"]+)"} $line -> m]} {
            if {$first_ts eq ""} { set first_ts $m }
            set last_ts $m
            set e [iso_to_epoch $m]
            if {$e ne ""} {
                lappend stamps [list $e [classify_stamp $line $ask_ids]]
            }
        }
        if {![regexp {"type":"assistant"} $line]} continue
        if {[catch {::json::json2dict $line} rec]} continue
        if {![dict exists $rec message]} continue
        set msg [dict get $rec message]

        # Remember AskUserQuestion tool_use ids so the classifier above can
        # recognise their tool_result as the user answering a dialog. The
        # tool_use line always precedes its tool_result, so one pass suffices.
        if {[regexp {"name":"AskUserQuestion"} $line]} {
            foreach blk [dict getdef $msg content {}] {
                if {[dict getdef $blk type ""] eq "tool_use" \
                        && [dict getdef $blk name ""] eq "AskUserQuestion"} {
                    dict set ask_ids [dict get $blk id] 1
                }
            }
        }

        set req_id [dict getdef $rec requestId [dict getdef $msg requestId ""]]
        if {$req_id eq ""} { set req_id "dummy-[incr dummy_req]" }

        set model [dict getdef $msg model "unknown"]
        # The session's own (non-sidechain) last assistant model drives the
        # Model cell. A subagent runs as a sidechain inside this same file; its
        # records carry isSidechain, so skip them for the parent's label. Skip
        # harness-written <synthetic> fillers too: they carry no real model
        # and would blank the cell when they come last.
        if {$model ne "unknown" && $model ne "<synthetic>" \
                && ![regexp {"isSidechain":true} $line]} {
            set last_model $model
        }
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
        first_ts $first_ts last_ts $last_ts turns $turns stamps $stamps \
        last_model $last_model ok 1]
}

proc ::questlog::cost::build_cost_dict {res} {
    if {![dict get $res ok]} {
        return [dict create cost_usd 0.0 turns 0 duration_secs 0 human_secs 0 input_tokens 0 output_tokens 0 cache_write_tokens 0 cache_read_tokens 0 model_breakdown {} model ""]
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
    # Reading the cap here keeps the isolated cost worker config-free: the
    # worker runs parse_file only, and build_cost_dict runs on the main
    # thread (GUI) or in the CLI process, both of which load config.tcl.
    set cap [expr {60 * [::questlog::config::get cost_human_gap_cap_min]}]
    lassign [split_secs [dict get $res stamps] $cap] active human
    return [dict create \
        cost_usd $usd \
        input_tokens $in \
        output_tokens $out \
        cache_write_tokens $cw \
        cache_read_tokens $cr \
        model_breakdown $per_model \
        model [model_label [dict getdef $res last_model ""]] \
        turns $turns \
        duration_secs $active \
        human_secs $human]
}

# Cost accrued strictly inside the window [lo, hi] by each assistant message's
# own timestamp - the accounting unit for `--accrued-cost`. A separate pass from
# parse_file (which sums the whole transcript and runs in the GUI cost worker):
# here a requestId is the atomic unit of spend, anchored by the earliest
# timestamp of its assistant records, counted in full (max usage across all its
# records, regardless of each record's own ts) iff that anchor falls in the
# window. So a streamed request whose final, largest-usage record lands just past
# hi is still counted once, whole, in the window of its anchor. lo is the floor
# (a record at exactly lo is out, matching the mtime>cutoff convention); hi is
# the inclusive ceiling, or "" for no upper edge. Returns the build_cost_dict
# shape with every field windowed; an empty model_breakdown (cost_usd -1.0) with
# turns 0 marks a file with no in-window spend, the caller's drop signal.
proc ::questlog::cost::accrue_window {path lo hi} {
    set req_usage [dict create]
    set dummy_req 0
    set turns 0
    set stamps [list]
    set ask_ids [dict create]
    set last_model ""
    if {[catch {open $path r} fh]} {
        return [build_cost_dict [dict create per_model {} first_ts "" \
            last_ts "" turns 0 stamps {} last_model "" ok 0]]
    }
    chan configure $fh -encoding utf-8 -profile replace
    while {[chan gets $fh line] >= 0} {
        if {$line eq ""} continue
        if {[regexp {"type":"file-history-snapshot"} $line]} continue

        # The record's own epoch, fresh each line (no carry-over from a prior
        # record), and whether it lands in the window.
        set e ""
        if {[regexp {"timestamp":"([^"]+)"} $line -> m]} { set e [iso_to_epoch $m] }
        set in_win [expr {$e ne "" && $e > $lo && ($hi eq "" || $e <= $hi)}]

        # A turn is a typed user prompt, in-window (the shared is_user_turn
        # predicate, same as parse_file).
        if {$in_win && [::questlog::jsonl::is_user_turn $line]} {
            incr turns
        }
        if {$in_win} { lappend stamps [list $e [classify_stamp $line $ask_ids]] }

        if {![regexp {"type":"assistant"} $line]} continue
        if {[catch {::json::json2dict $line} rec]} continue
        if {![dict exists $rec message]} continue
        set msg [dict get $rec message]

        if {[regexp {"name":"AskUserQuestion"} $line]} {
            foreach blk [dict getdef $msg content {}] {
                if {[dict getdef $blk type ""] eq "tool_use" \
                        && [dict getdef $blk name ""] eq "AskUserQuestion"} {
                    dict set ask_ids [dict get $blk id] 1
                }
            }
        }

        set model [dict getdef $msg model "unknown"]
        if {$in_win && $model ne "unknown" && $model ne "<synthetic>" \
                && ![regexp {"isSidechain":true} $line]} {
            set last_model $model
        }
        if {![dict exists $msg usage]} continue
        set u [dict get $msg usage]
        set in_t  [dict getdef $u input_tokens 0]
        set out_t [dict getdef $u output_tokens 0]
        set cw_t  [dict getdef $u cache_creation_input_tokens 0]
        set cr_t  [dict getdef $u cache_read_input_tokens 0]

        set req_id [dict getdef $rec requestId [dict getdef $msg requestId ""]]
        if {$req_id eq ""} { set req_id "dummy-[incr dummy_req]" }

        # Anchor by earliest assistant-record ts; max usage across all records.
        if {[dict exists $req_usage $req_id]} {
            lassign [dict get $req_usage $req_id] at om oi oo ow or
            if {$om eq "unknown"} { set om $model }
            if {$e ne "" && ($at eq "" || $e < $at)} { set at $e }
            dict set req_usage $req_id [list $at $om \
                [expr {max($in_t, $oi)}] [expr {max($out_t, $oo)}] \
                [expr {max($cw_t, $ow)}] [expr {max($cr_t, $or)}]]
        } else {
            dict set req_usage $req_id [list $e $model $in_t $out_t $cw_t $cr_t]
        }
    }
    close $fh

    # Keep only requests whose anchor falls in the window; fold into per_model
    # and record the earliest in-window anchor, whose date selects the rate era
    # that actually billed (rather than the session's possibly-older start date).
    set per_model [dict create]
    set anchor_min ""
    dict for {_ v} $req_usage {
        lassign $v at mdl i o w r
        if {$at eq "" || !($at > $lo && ($hi eq "" || $at <= $hi))} continue
        lassign [dict getdef $per_model $mdl {0 0 0 0}] pi po pw pr
        dict set per_model $mdl [list [expr {$pi+$i}] [expr {$po+$o}] \
            [expr {$pw+$w}] [expr {$pr+$r}]]
        if {$anchor_min eq "" || $at < $anchor_min} { set anchor_min $at }
    }
    set first_ts [expr {$anchor_min eq "" ? "" \
        : [clock format $anchor_min -gmt 1 -format %Y-%m-%d]}]

    return [build_cost_dict [dict create per_model $per_model first_ts $first_ts \
        last_ts "" turns $turns stamps $stamps last_model $last_model ok 1]]
}

