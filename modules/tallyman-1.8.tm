package require Tcl 9
package require json
package require logman
package provide tallyman 1.8

# tallyman - prices a Claude Code session's token usage.
#
# A session transcript is a stream of JSONL records; the assistant records
# carry a `usage` block (input, output, cache-write, cache-read token counts)
# and the model that produced them. tallyman reads those counts, dedupes the
# several stream records that report one request, prices each request against
# a time-versioned rate table, and sums per model. It also splits the
# wall clock into machine and human time, reads the context occupancy off the
# final request, and renders the short labels a caller shows for a model id
# or a duration.
#
# tallyman is filesystem-free: it never opens a file and never parses a rate
# file. The caller owns all I/O - it reads the transcript's lines off disk and
# hands them in as a list, and it builds the rate table into a dict and hands
# that in too. tallyman only computes. The rate table's format, where it lives,
# and how it is loaded are the caller's business, not tallyman's.
#
# The transcript lines are the raw lines of a Claude Code session `.jsonl`
# transcript, one JSON record per line, passed in as a Tcl list. tallyman reads
# a record's `type`, `timestamp`, and `isSidechain`, and for assistant records
# `requestId`, `message.model`, and `message.usage` (`input_tokens`,
# `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`,
# and `cache_creation.ephemeral_1h_input_tokens`, the writes kept for an
# hour); several stream records sharing one `requestId` are a single request,
# deduped by taking the max usage across them.
#
#   set res   [tallyman::parse_lines $lines]     ;# lines: a list of JSONL lines
#   set costd [tallyman::build_cost_dict $res $rates $threshold $credit]
#   dict get $costd cost_usd
#     ;# $threshold and $credit, in seconds, are the human-gap rule (see
#     ;# split_secs): a pause up to $threshold is composing time in full, a
#     ;# longer one is the user away and back, worth $credit.
#
# For spend inside a date window rather than the whole transcript, use
#   accrue_lines $lines $lo $hi $rates $threshold $credit
# where lo/hi are epoch-second window bounds (hi "" for no upper edge).
#
# Rates dict: model -> sorted list of
#   {effective_from in out cw cr ?prompt_min? ?cw_1h?}
# each rate a price per million tokens. The rows sharing a model's latest
# effective_from at or before a request's date are the era that billed it; a
# sixth element, the smallest prompt length (one request's input + cache-write
# + cache-read tokens) a row prices, splits an era into cards for a model
# billed by prompt length (Haiku 5.5 from 100,001 tokens), and reads as 0 when
# absent; a seventh is the price of a cache write kept for an hour, which
# Anthropic bills above the five-minute write in cw, and reads as cw when
# absent. A model absent from the dict (a local model, or one no rate covers)
# prices as nothing, so an unpriced session reads as a blank figure rather than
# a false zero.

namespace eval tallyman {}

# ── rates ──────────────────────────────────────────────────────────────────

# The row that billed a request: the model's latest era at or before date,
# and within it the card whose prompt_min is the largest not above
# prompt_len. Empty if no row matches (unknown model, date before the first
# listed era, or an era whose every card starts above prompt_len).
proc tallyman::rate_for {rates model date {prompt_len 0}} {
    if {![dict exists $rates $model]} { return "" }
    set era ""
    foreach row [dict get $rates $model] {
        set ef [lindex $row 0]
        if {[string compare $ef $date] <= 0 && [string compare $ef $era] > 0} {
            set era $ef
        }
    }
    if {$era eq ""} { return "" }
    set best ""
    set best_min -1
    foreach row [dict get $rates $model] {
        if {[lindex $row 0] ne $era} continue
        set min [lindex $row 5]
        if {$min eq ""} { set min 0 }
        if {$min <= $prompt_len && $min > $best_min} {
            set best $row
            set best_min $min
        }
    }
    return $best
}

# requests, a list of {model in out cw cr ?cw_1h? ?date?} with one entry per
# request, + the session's date -> USD. Each request is priced on its own row
# in the era of its own date (the session's date stands in for a request
# without one), so a model billed by prompt length pays the card each request
# fell on and a session that crosses a price change pays each side its own;
# cw is every cache write and cw_1h the part kept for an hour, priced at the
# row's hour rate where it has one. -1 signals "no rate row found for any
# request" -> caller shows blank.
proc tallyman::compute_usd {requests rates session_date} {
    set total 0.0
    set any 0
    foreach req $requests {
        lassign $req model in out cw cr cw1h date
        if {$cw1h eq ""} { set cw1h 0 }
        if {$date eq ""} { set date $session_date }
        set row [rate_for $rates $model $date [expr {$in + $cw + $cr}]]
        if {$row eq ""} continue
        lassign $row _ ri ro rw rr _ rw1h
        if {$rw1h eq ""} { set rw1h $rw }
        # A record can report more hour-kept writes than writes in all: a
        # server-side fallback's record carries the refused attempt's split
        # beside the served attempt's total, and the served attempt is the
        # one billed, so the hour part is capped at the total.
        if {$cw1h > $cw} { set cw1h $cw }
        set cw5m [expr {$cw - $cw1h}]
        set total [expr {$total + ($in * $ri + $out * $ro \
            + $cw5m * $rw + $cw1h * $rw1h + $cr * $rr) / 1000000.0}]
        set any 1
    }
    if {!$any} { return -1.0 }
    return $total
}

# ── formatters ─────────────────────────────────────────────────────────────

# Format a USD amount as $X.XX. Blank for zero or unknown (negative), so an
# empty cell reads as "no figure" rather than a misleading $0.00.
proc tallyman::format_usd {usd} {
    if {$usd <= 0} { return "" }
    return [format "\$%.2f" $usd]
}

# A second count as MM:SS, or H:MM:SS once it passes an hour. Blank for an
# empty/negative count so the cell reads as "no figure".
proc tallyman::fmt_dur {secs} {
    if {$secs eq "" || $secs < 0} { return "" }
    set h [expr {$secs / 3600}]
    set m [expr {($secs % 3600) / 60}]
    set s [expr {$secs % 60}]
    if {$h > 0} { return [format "%d:%02d:%02d" $h $m $s] }
    return [format "%02d:%02d" $m $s]
}

# A model id (claude-opus-4-8, claude-sonnet-5, claude-haiku-4-5-20251001) to a
# short "Family Ver" label (Opus 4.8, Sonnet 5, Haiku 4.5). The family is the
# opus/sonnet/haiku/fable token; the version is the one or two numeric groups
# right after it, joined by a dot - a lone group prints bare (Sonnet 5), so the
# Claude 5 family whose id carries a single version number reads as a model
# rather than a blank. A trailing date suffix is stripped first so it is never
# mistaken for a version. Blank for an empty or unrecognised id.
proc tallyman::fmt_model {id} {
    regsub -- {-\d{6,}$} $id "" id
    if {![regexp {(opus|sonnet|haiku|fable)-(\d+)(?:-(\d+))?$} $id -> fam maj min]} {
        return ""
    }
    set fam [string totitle $fam]
    return [expr {$min eq "" ? "$fam $maj" : "$fam $maj.$min"}]
}

# The label a session is known by: the "Family Ver" reading when fmt_model
# recognises the id, otherwise the id itself with any date suffix trimmed.
# fmt_model alone blanks an id it does not price (a local model), which would
# erase the only handle those sessions have. An empty id stays empty.
# Deliberately the label, not the raw id: two ids that differ only by a date
# suffix are one model, and one label makes them one entry.
proc tallyman::model_label {id} {
    set label [fmt_model $id]
    if {$label ne ""} { return $label }
    regsub -- {-\d{6,}$} $id "" id
    return $id
}

# A model id's context window in tokens, the denominator context_pct is
# computed against. Per Anthropic's model catalog: the Claude 5 family
# (fable, and its Mythos sibling), Opus/Sonnet from 4.6 and Haiku from 5
# carry a native 1M window; on older models Claude Code marks the 1M
# long-context beta with a "[1m]" suffix on the id. Everything else - Haiku
# before 5, pre-4.6 Opus/Sonnet, old-scheme ids, local models - reads as
# 200k, the widest window such a transcript can truthfully claim.
proc tallyman::model_context_window {id} {
    if {[string match {*\[1m\]*} $id]} { return 1000000 }
    regsub -- {-\d{6,}$} $id "" id
    if {[regexp {(opus|sonnet|haiku|fable|mythos)-(\d+)(?:-(\d+))?$} $id -> fam maj min]} {
        if {$min eq ""} { set min 0 }
        switch -- $fam {
            fable - mythos { return 1000000 }
            opus - sonnet {
                if {$maj > 4 || ($maj == 4 && $min >= 6)} { return 1000000 }
            }
            haiku {
                if {$maj >= 5} { return 1000000 }
            }
        }
    }
    return 200000
}

# The opus/sonnet/haiku/fable family token of a model id, lowercased, or "" for
# an id fmt_model does not recognise (an old-scheme claude-3-5-sonnet-... or a
# local model). Reuses fmt_model's exact anchored family/version regexp, so
# "known family" here means the same thing as "gets a Family Ver label" there.
proc tallyman::model_family {id} {
    regsub -- {-\d{6,}$} $id "" id
    if {[regexp {(opus|sonnet|haiku|fable)-(\d+)(?:-(\d+))?$} $id -> fam]} {
        return [string tolower $fam]
    }
    return ""
}

# ── duration split ─────────────────────────────────────────────────────────

# Split the wall clock into machine and human seconds. `stamps` is a list of
# {epoch class} pairs in any order; the class of the record that ENDS a gap
# decides whose time the gap is. machine (model output, tool runs, subagent
# activity inside a turn) counts in full. human (the session waiting for the
# user: a typed prompt, a dialog answer) is composing time in full when the
# gap is at most `threshold` seconds - reading, thinking, a form filled in
# between two prompts; a longer gap means the user went away and came back,
# and is worth `credit` seconds however long it ran, so resuming a session
# after hours or days credits one return. A single cap cannot serve both
# pauses: it discards most of a twenty-minute pause or inflates a night
# away. neutral (harness records written during the user's absence or at
# the moment of return) counts for neither side. Returns {machine human},
# both blank when fewer than two records carry a timestamp.
proc tallyman::split_secs {stamps threshold credit} {
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
            human   { incr human [expr {$gap <= $threshold ? $gap : $credit}] }
        }
        set prev $e
    }
    return [list $machine $human]
}

# ── timeline helpers ───────────────────────────────────────────────────────

# ISO-8601 UTC timestamp (e.g. 2026-04-25T10:00:00.000Z) to epoch seconds.
# Tolerates a missing fractional part; empty on any parse failure.
proc tallyman::_iso_to_epoch {ts} {
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

# Classify a record for split_secs: the class of the record ENDING a gap
# decides whose time the gap is (machine / human / neutral). Quotes inside
# message text arrive escaped (\"), so these plain-quote regexes cannot fire on
# conversation content. ask_ids carries the AskUserQuestion tool_use ids seen so
# far, so a dialog answer's tool_result counts as the user returning.
proc tallyman::_classify_stamp {line ask_ids} {
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

# ── transcript compute ─────────────────────────────────────────────────────

# Fold a transcript's raw JSONL lines into a result dict:
#   {per_model {model -> {in out cw cr}}
#    requests {{model in out cw cr cw_1h date} ...}
#    first_ts  last_ts  turns  stamps {{epoch class} ...}  last_model
#    ctx_tokens  ctx_model  ok}
# `ok` is always 1 - the caller decides what an unreadable file means and builds
# its own ok-0 result for that case. Dedupes the several stream records that
# report one requestId by taking the max usage per request: requests carries
# those per-request maxima, each with the hour-kept part of its cache writes
# and the UTC date of its earliest record, which compute_usd prices one by
# one, and per_model their sums.
#
# ctx_tokens is the context occupancy at the transcript's end: the input +
# cache-read + cache-write tokens of the last assistant record that carries a
# real usage block - what the final request actually sent, which is how full
# the window is if the session is resumed. Post-compact records report the
# compacted context, so the figure survives an auto-compact honestly.
# ctx_model is that record's own model id, raw (it may carry the "[1m]"
# long-context suffix), for the window the figure is measured against.
# Sidechain records are other contexts interleaved into a session's file, so
# they never set the pair - except in a subagent's own transcript, where every
# record is marked sidechain and the sidechain reading is the file's own; a
# non-sidechain record wins whenever one exists at all.
proc tallyman::parse_lines {lines} {
    set req_usage [dict create]
    set dummy_req 0
    set first_ts ""
    set last_ts ""
    set stamps [list]
    set ask_ids [dict create]
    set last_model ""
    set ctx_tokens ""
    set ctx_model ""
    set side_ctx_tokens ""
    set side_ctx_model ""
    foreach line $lines {
        if {$line eq ""} continue
        # file-history-snapshot records carry no top-level timestamp; the regex
        # below would read the nested snapshot.timestamp as the record's time and
        # turn the away gap before a resume into work. They are no part of the
        # conversation timeline, so skip outright.
        if {[regexp {"type":"file-history-snapshot"} $line]} continue
        # The request log is no part of it either, and stamped a few ms after
        # the record it was sent for, it would end the gap before a prompt as
        # machine time.
        if {[::logman::is_request_log $line]} continue
        # A turn is a prompt the user actually wrote: the drafts of a message
        # edited before the assistant answered are one prompt, and a turn a
        # rewind abandoned is none (kept_turns, once the whole file is read).
        ::logman::note_line $line turnstate
        # An assistant record is parsed here, since its time is its own
        # timestamp field: a tool input on the line can carry one too, which
        # the first-string reading would take. Any other line's time is the
        # first timestamp string on it.
        set rec ""
        if {[regexp {"type":"assistant"} $line] && ![catch {::json::json2dict $line} parsed] \
                && [dict exists $parsed message]} {
            set rec $parsed
        }
        set m ""
        if {$rec ne ""} {
            set m [dict getdef $rec timestamp ""]
        } else {
            regexp {"timestamp":"([^"]+)"} $line -> m
        }
        if {$m ne ""} {
            if {$first_ts eq ""} { set first_ts $m }
            set last_ts $m
            set e [_iso_to_epoch $m]
            if {$e ne ""} {
                lappend stamps [list $e [_classify_stamp $line $ask_ids]]
            }
        }
        if {$rec eq ""} continue
        set msg [dict get $rec message]

        # Remember AskUserQuestion tool_use ids so the classifier can recognise
        # their tool_result as the user answering a dialog. The tool_use line
        # always precedes its tool_result, so one pass suffices.
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
        # model label. A subagent runs as a sidechain inside this same file; its
        # records carry isSidechain, so skip them for the parent's label. Skip
        # harness-written <synthetic> fillers too: they carry no real model and
        # would blank the label when they come last.
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
        # cache_creation splits the writes by how long they are kept; a null
        # there, or a count that is not a whole number, is no split.
        if {[catch {dict getdef [dict getdef $u cache_creation {}] ephemeral_1h_input_tokens 0} w1_t]
                || ![string is integer -strict $w1_t]} {
            set w1_t 0
        }

        # The context this request sent. A <synthetic> filler and a zero-usage
        # record say nothing about occupancy, so they never overwrite the last
        # real reading.
        set ctx [expr {$in_t + $cw_t + $cr_t}]
        if {$ctx > 0 && $model ne "<synthetic>"} {
            if {[regexp {"isSidechain":true} $line]} {
                set side_ctx_tokens $ctx
                set side_ctx_model $model
            } else {
                set ctx_tokens $ctx
                set ctx_model $model
            }
        }

        # A request's date is its earliest record's, UTC.
        set day [string range $m 0 9]
        if {[dict exists $req_usage $req_id]} {
            lassign [dict get $req_usage $req_id] om oi oo ow or ow1 od
            if {$om eq "unknown"} { set om $model }
            if {$od eq "" || ($day ne "" && [string compare $day $od] < 0)} { set od $day }
            dict set req_usage $req_id [list $om \
                [expr {max($in_t, $oi)}] [expr {max($out_t, $oo)}] \
                [expr {max($cw_t, $ow)}] [expr {max($cr_t, $or)}] \
                [expr {max($w1_t, $ow1)}] $od]
        } else {
            dict set req_usage $req_id [list $model $in_t $out_t $cw_t $cr_t $w1_t $day]
        }
    }
    if {$ctx_tokens eq ""} {
        set ctx_tokens $side_ctx_tokens
        set ctx_model $side_ctx_model
    }

    set per_model [dict create]
    dict for {_ counts} $req_usage {
        lassign $counts m i o w r
        lassign [dict getdef $per_model $m {0 0 0 0}] pi po pw pr
        dict set per_model $m [list [expr {$pi+$i}] [expr {$po+$o}] [expr {$pw+$w}] [expr {$pr+$r}]]
    }

    return [dict create per_model $per_model requests [dict values $req_usage] \
        first_ts $first_ts last_ts $last_ts \
        turns [llength [::logman::kept_turns turnstate]] stamps $stamps \
        last_model $last_model ctx_tokens $ctx_tokens ctx_model $ctx_model \
        ok 1]
}

# A parse_lines result + the rate table + the human-gap rule (threshold and
# credit, seconds, as split_secs reads them) -> the caller-facing cost dict:
#   {cost_usd input_tokens output_tokens cache_write_tokens cache_read_tokens
#    model_breakdown model turns duration_secs human_secs context_pct}
# context_pct is ctx_tokens as a whole percentage of ctx_model's window, ""
# when the transcript carries no usage at all (an empty or windowed result),
# so the cell reads as "no figure" rather than a false 0%.
proc tallyman::build_cost_dict {res rates threshold credit} {
    if {![dict get $res ok]} {
        return [dict create cost_usd 0.0 turns 0 duration_secs 0 human_secs 0 input_tokens 0 output_tokens 0 cache_write_tokens 0 cache_read_tokens 0 model_breakdown {} model "" context_pct ""]
    }
    set per_model [dict get $res per_model]
    set first_ts [dict get $res first_ts]
    set turns [dict get $res turns]

    # The session's date stands in for a request that carries none.
    set session_date [string range $first_ts 0 9]
    if {$session_date eq ""} {
        set session_date [clock format [clock seconds] -format %Y-%m-%d]
    }
    set usd [compute_usd [dict get $res requests] $rates $session_date]
    set in 0; set out 0; set cw 0; set cr 0
    dict for {_ c} $per_model {
        lassign $c i o w r
        incr in $i; incr out $o; incr cw $w; incr cr $r
    }
    lassign [split_secs [dict get $res stamps] $threshold $credit] active human
    set ctx [dict getdef $res ctx_tokens ""]
    set ctx_pct [expr {$ctx eq "" ? "" : round(100.0 * $ctx \
        / [model_context_window [dict getdef $res ctx_model ""]])}]
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
        human_secs $human \
        context_pct $ctx_pct]
}

# Cost accrued strictly inside the window [lo, hi] by each assistant message's
# own timestamp - the accounting unit for a windowed spend query. A separate
# pass from parse_lines (which sums the whole transcript): here a requestId is
# the atomic unit of spend, anchored by the earliest timestamp of its assistant
# records, counted in full (max usage across all its records, regardless of each
# record's own ts) iff that anchor falls in the window. So a streamed request
# whose final, largest-usage record lands just past hi is still counted once,
# whole, in the window of its anchor. lo is the floor (a record at exactly lo is
# out); hi is the inclusive ceiling, or "" for no upper edge. Returns the
# build_cost_dict shape with every field windowed; an empty model_breakdown
# (cost_usd -1.0) with turns 0 marks a window with no in-window spend.
proc tallyman::accrue_lines {lines lo hi rates threshold credit} {
    set req_usage [dict create]
    set dummy_req 0
    set stamps [list]
    set ask_ids [dict create]
    set last_model ""
    foreach line $lines {
        if {$line eq ""} continue
        if {[regexp {"type":"file-history-snapshot"} $line]} continue
        if {[::logman::is_request_log $line]} continue

        # The record's own epoch, fresh each line, and whether it lands in the
        # window: an assistant record's from its parsed timestamp field (a
        # tool input on the line can carry one too), any other line's from
        # the first timestamp string on it.
        set rec ""
        if {[regexp {"type":"assistant"} $line] && ![catch {::json::json2dict $line} parsed] \
                && [dict exists $parsed message]} {
            set rec $parsed
        }
        set e ""
        if {$rec ne ""} {
            set e [_iso_to_epoch [dict getdef $rec timestamp ""]]
        } elseif {[regexp {"timestamp":"([^"]+)"} $line -> m]} {
            set e [_iso_to_epoch $m]
        }
        set in_win [expr {$e ne "" && $e > $lo && ($hi eq "" || $e <= $hi)}]

        # The run state advances over every line, in the window or not, so a
        # window opening mid-run still knows whether a prompt starts a turn;
        # only the counting is windowed, each turn tagged with its window.
        ::logman::note_line $line turnstate $in_win
        if {$in_win} { lappend stamps [list $e [_classify_stamp $line $ask_ids]] }

        if {$rec eq ""} continue
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
        # cache_creation splits the writes by how long they are kept; a null
        # there, or a count that is not a whole number, is no split.
        if {[catch {dict getdef [dict getdef $u cache_creation {}] ephemeral_1h_input_tokens 0} w1_t]
                || ![string is integer -strict $w1_t]} {
            set w1_t 0
        }

        set req_id [dict getdef $rec requestId [dict getdef $msg requestId ""]]
        if {$req_id eq ""} { set req_id "dummy-[incr dummy_req]" }

        # Anchor by earliest assistant-record ts; max usage across all records.
        if {[dict exists $req_usage $req_id]} {
            lassign [dict get $req_usage $req_id] at om oi oo ow or ow1
            if {$om eq "unknown"} { set om $model }
            if {$e ne "" && ($at eq "" || $e < $at)} { set at $e }
            dict set req_usage $req_id [list $at $om \
                [expr {max($in_t, $oi)}] [expr {max($out_t, $oo)}] \
                [expr {max($cw_t, $ow)}] [expr {max($cr_t, $or)}] \
                [expr {max($w1_t, $ow1)}]]
        } else {
            dict set req_usage $req_id [list $e $model $in_t $out_t $cw_t $cr_t $w1_t]
        }
    }

    # Keep only requests whose anchor falls in the window: they are the requests
    # priced, each in the era of its anchor's UTC date, folded into per_model
    # for the breakdown.
    set requests [list]
    set per_model [dict create]
    dict for {_ v} $req_usage {
        lassign $v at mdl i o w r w1
        if {$at eq "" || !($at > $lo && ($hi eq "" || $at <= $hi))} continue
        lappend requests [list $mdl $i $o $w $r $w1 \
            [clock format $at -gmt 1 -format %Y-%m-%d]]
        lassign [dict getdef $per_model $mdl {0 0 0 0}] pi po pw pr
        dict set per_model $mdl [list [expr {$pi+$i}] [expr {$po+$o}] \
            [expr {$pw+$w}] [expr {$pr+$r}]]
    }

    return [build_cost_dict [dict create per_model $per_model requests $requests \
        first_ts "" last_ts "" \
        turns [llength [lsearch -all -exact [::logman::kept_turns turnstate] 1]] \
        stamps $stamps \
        last_model $last_model ok 1] $rates $threshold $credit]
}
