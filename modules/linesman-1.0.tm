package require Tcl 9
package require json
package provide linesman 1.0

# linesman - rules on assertions of fact about one finished Claude Code
# session, read from its .jsonl transcript after the whistle.
#
# A caller asserts; linesman rules: this session invoked skill S, called
# tool T with input matching M, wrote path P, spawned a subagent of type A,
# did so at most N times, did none of those. A ruling carries the evidence
# located (file and physical line per hit) and the record's completeness,
# so the caller can show why, not merely whether.
#
# THE RECORD. A session's record is its parent transcript
# <root>/<folder>/<sid>.jsonl plus every subagent transcript
# <root>/<folder>/<sid>/subagents/agent-*.jsonl, root normally
# ~/.claude/projects. Subagents live flat in that one directory whatever
# their spawn depth. Each has a sidecar agent-*.meta.json whose toolUseId
# names the Agent tool_use that spawned it; a fork child carries no
# toolUseId (agentType "fork") and is a legitimate part of the record, its
# acts swept like any other. An act is a tool_use block in an assistant
# record. Records flagged isCompactSummary or isVisibleInTranscriptOnly
# are display prose, not acts, and are never evidence: compaction is
# in-place, the summary is lossy, and the pre-compaction blocks it
# summarises are still present as structured records in the same file.
#
# THE RULING. rule takes one subject (-tool, -wrote, -spawned) and one
# form (at-least-once by default, -none, -atmost N) and returns a verdict:
# yes, no, or not_provable. Found evidence rules regardless of
# completeness; an absence only certifies on a whole record. That
# asymmetry is the module's point: a negative over an incomplete record
# degrades to not_provable, never to "did not happen".
#
# COMPLETENESS is returned fields, not a subsystem. sweep reports gaps of
# three kinds: truncated_tail (the file's last line is a half-written
# record, so the tail of the session is unaccounted for), unparsed_line (a
# record that would not parse), missing_child (an Agent call whose
# subagent transcript is absent, so that child's acts are unaccounted
# for). complete is 1 iff there are no gaps. Beside the gaps ride
# api_errors (assistant turns that failed at the API, so intended acts may
# be absent) and interrupts (tool calls the user cut short: the act was
# issued but did not run to completion; it still counts as issued). A
# session with no transcript at all raises with -errorcode
# {LINESMAN NO_TRANSCRIPT}: absence of the record is a different fact from
# a record showing nothing, and must stay distinguishable. An unreadable
# transcript raises rather than reading as empty, for the same reason.
#
# BASH OPACITY. A Bash command's filesystem effects leave no tool_use
# evidence: a session can write a file through redirection and show no
# Write act. Rulings bind to harness events, so a -wrote absence on a
# session that ran Bash at all is not certifiable: it degrades to
# not_provable, and bash_ran carries the count. A caller for whom shell
# writes are out of scope opts out with -ignorebash. linesman does not
# parse command strings.
#
# EPISODES. sweep rules on one session id. Resumption is in-place in the
# transcript format (one file holds a session across sittings), so there
# is no session chain to discover; where a caller's own records link
# several sessions into one work episode, the caller sweeps each sid and
# combines the rulings, owning the linkage fact itself.
#
# SYNOPSIS
#   set rec [linesman::sweep $sid ~/.claude/projects]
#   linesman::rule $rec -tool Skill -field skill -equals linkedin
#     ;# {verdict yes count 2 evidence {{file ... line 41 rendered ...}} ...}
#   linesman::rule $rec -spawned general-purpose -none
#   linesman::rule $rec -wrote "/segment/*" -none -ignorebash
#   linesman::tool_counts $sid $root Skill skill   ;# {linkedin 2 facebook 1}
#
# LINEAGE. tool_counts is coachman 1.11's tool_use_counts, migrated:
# coachman drives sessions, tallyman meters them, deadman supervises them
# live; ruling on the finished record is linesman's seat.
#
# DEPENDENCY. Tcl 9 and Tcllib json only. Self-contained by design:
# questlog's lib/ is source-loaded application code, not a package, so
# the format knowledge a ruling rests on lives here.

namespace eval linesman {}

# ── the sweep ──────────────────────────────────────────────────────────────

# sweep sid root - read session $sid's whole record under $root into one
# dict: acts, children, gaps, api_errors, interrupts, bash_ran, complete.
# Every non-empty line is parsed; there is no prefilter, because "all
# lines parsed" is the completeness verdict and a prefilter cannot certify
# a negative. Line numbers are 1-based physical lines, blanks counted.
proc linesman::sweep {sid root} {
    set parents [glob -nocomplain -directory $root -types f -- */${sid}.jsonl]
    if {[llength $parents] == 0} {
        return -code error -errorcode {LINESMAN NO_TRANSCRIPT} \
            "no transcript for session $sid under $root"
    }
    set parent [lindex $parents 0]
    set subdir [file join [file dirname $parent] $sid subagents]

    # Children and their meta sidecars. spawn_ids collects the toolUseIds
    # whose child transcripts exist; fork metas have none and add nothing.
    set children {}
    set spawn_ids {}
    foreach cf [lsort [glob -nocomplain -directory $subdir -types f -- agent-*.jsonl]] {
        set metafile "[file rootname $cf].meta.json"
        set meta {}
        if {[file exists $metafile]} {
            set fd [open $metafile r]
            fconfigure $fd -encoding utf-8 -profile replace
            set raw [read $fd]
            close $fd
            if {[catch {::json::json2dict $raw} meta]} { set meta {} }
        }
        if {[dict exists $meta toolUseId]} {
            lappend spawn_ids [dict get $meta toolUseId]
        }
        lappend children [dict create file $cf meta $meta]
    }

    set acts {}
    set gaps {}
    set api_errors {}
    set interrupts {}
    set bash_ran 0
    set actpos [dict create]    ;# tool_use id -> index into acts

    set files [list $parent]
    foreach c $children { lappend files [dict get $c file] }
    foreach f $files {
        set fd [open $f r]
        fconfigure $fd -encoding utf-8 -profile replace
        set data [read $fd]
        close $fd
        set lines [split $data \n]
        # A newline-terminated file splits into a trailing empty element
        # that is no physical line; a non-terminated one ends in a
        # half-written record, the truncated tail.
        set tail -1
        if {[lindex $lines end] eq ""} {
            set lines [lrange $lines 0 end-1]
        } else {
            set tail [llength $lines]
        }
        set n 0
        foreach line $lines {
            incr n
            if {$line eq ""} continue
            if {[catch {::json::json2dict $line} d]} {
                set kind [expr {$n == $tail ? "truncated_tail" : "unparsed_line"}]
                lappend gaps [dict create kind $kind file $f line $n]
                continue
            }
            if {[dict getdef $d isCompactSummary 0] ||
                [dict getdef $d isVisibleInTranscriptOnly 0]} continue
            set t [dict getdef $d type ""]
            if {$t eq "assistant"} {
                if {[dict getdef $d isApiErrorMessage 0]} {
                    lappend api_errors [dict create file $f line $n]
                }
                set content [dict getdef [dict getdef $d message {}] content {}]
                # Prose string content is not a block array and may not
                # even parse as a Tcl list; only arrays carry acts.
                if {[catch {llength $content}]} continue
                foreach blk $content {
                    if {[catch {dict getdef $blk type ""} bt] || $bt ne "tool_use"} continue
                    set name [dict getdef $blk name ""]
                    if {$name eq ""} continue
                    set id [dict getdef $blk id ""]
                    lappend acts [dict create file $f line $n tool $name \
                        id $id input [dict getdef $blk input {}] interrupted 0]
                    if {$id ne ""} { dict set actpos $id [expr {[llength $acts] - 1}] }
                    if {$name eq "Bash"} { incr bash_ran }
                }
            } elseif {$t eq "user"} {
                set content [dict getdef [dict getdef $d message {}] content {}]
                if {[catch {llength $content}]} continue
                foreach blk $content {
                    if {[catch {dict getdef $blk type ""} bt] || $bt ne "tool_result"} continue
                    set c [dict getdef $blk content ""]
                    if {![string match {*\[Request interrupted by user*} $c]} continue
                    set tuid [dict getdef $blk tool_use_id ""]
                    lappend interrupts [dict create file $f line $n tool_use_id $tuid]
                    if {[dict exists $actpos $tuid]} {
                        set p [dict get $actpos $tuid]
                        lset acts $p [dict replace [lindex $acts $p] interrupted 1]
                    }
                }
            }
        }
    }

    # An Agent call whose child transcript is absent leaves that child's
    # acts unaccounted for: a gap, not a zero.
    foreach a $acts {
        if {[dict get $a tool] ni {Agent Task}} continue
        set id [dict get $a id]
        if {$id eq "" || $id in $spawn_ids} continue
        lappend gaps [dict create kind missing_child \
            file [dict get $a file] line [dict get $a line] tool_use_id $id]
    }

    return [dict create \
        sid $sid root $root parent $parent files $files \
        acts $acts children $children \
        complete [expr {[llength $gaps] == 0}] gaps $gaps \
        api_errors $api_errors interrupts $interrupts bash_ran $bash_ran]
}

# ── the ruling ─────────────────────────────────────────────────────────────

# The tool families of the write/edit ops, as questlog's search presents
# them: wrote is the created-or-edited merge, write and edit the finer ops.
proc linesman::_op_toolset {op} {
    switch -- $op {
        read    { return {Read} }
        write   { return {Write} }
        edit    { return {Edit MultiEdit NotebookEdit} }
        wrote   { return {Write Edit MultiEdit NotebookEdit} }
        default { return -code error "unknown op \"$op\": read, write, edit, or wrote" }
    }
}

# Render an act as Tool(key=value, ...), whitespace-collapsed, uncapped,
# suffixed when the user cut the call short.
proc linesman::_render {act} {
    set parts {}
    dict for {k v} [dict get $act input] {
        lappend parts "${k}=[regsub -all {\s+} $v { }]"
    }
    set s "[dict get $act tool]([join $parts {, }])"
    if {[dict get $act interrupted]} { append s " (interrupted)" }
    return $s
}

# rule record ?options? - rule on one assertion over a swept record.
# Subject (exactly one):
#   -tool T ?-field F -equals V|-match GLOB|-regexp RE?   the act is a call
#       of tool T, optionally with input field F matching; a missing field
#       never matches
#   -wrote GLOB ?-op read|write|edit|wrote?   the act touches a path
#       matching GLOB through the op's tool family (default wrote); the
#       path is input.file_path, or notebook_path for notebook edits
#   -spawned A   the act spawns a subagent of type A
# Form: at least once by default; -none asserts zero; -atmost N bounds.
# -ignorebash scopes a -wrote ruling to tool events even when Bash ran.
# Returns: verdict (yes|no|not_provable), count, evidence (a {file line
# rendered} dict per hit), and the record's completeness fields (complete,
# gaps, api_errors, interrupts, bash_ran) carried through.
proc linesman::rule {record args} {
    set subject ""
    set tool ""; set field ""; set matcher ""; set pattern ""
    set glob ""; set op wrote; set agent ""
    set form least1; set atmost 0; set ignorebash 0
    for {set i 0} {$i < [llength $args]} {incr i} {
        set opt [lindex $args $i]
        switch -- $opt {
            -tool - -wrote - -spawned {
                if {$subject ne ""} { return -code error "one subject per ruling" }
                set subject [string range $opt 1 end]
                set val [lindex $args [incr i]]
                switch -- $subject {
                    tool    { set tool $val }
                    wrote   { set glob $val }
                    spawned { set agent $val }
                }
            }
            -field      { set field [lindex $args [incr i]] }
            -equals - -match - -regexp {
                if {$matcher ne ""} { return -code error "one matcher per ruling" }
                set matcher [string range $opt 1 end]
                set pattern [lindex $args [incr i]]
            }
            -op         { set op [lindex $args [incr i]] }
            -none       { set form none }
            -atmost     { set form atmost; set atmost [lindex $args [incr i]] }
            -ignorebash { set ignorebash 1 }
            default     { return -code error "unknown option \"$opt\"" }
        }
    }
    if {$subject eq ""} {
        return -code error "a ruling needs a subject: -tool, -wrote, or -spawned"
    }
    if {($field eq "") != ($matcher eq "")} {
        return -code error "-field and a matcher (-equals/-match/-regexp) go together"
    }

    set hits {}
    foreach a [dict get $record acts] {
        set name [dict get $a tool]
        switch -- $subject {
            tool {
                if {$name ne $tool} continue
                if {$field ne ""} {
                    set input [dict get $a input]
                    if {![dict exists $input $field]} continue
                    set v [dict get $input $field]
                    switch -- $matcher {
                        equals { if {$v ne $pattern} continue }
                        match  { if {![string match $pattern $v]} continue }
                        regexp { if {![regexp -- $pattern $v]} continue }
                    }
                }
            }
            wrote {
                if {$name ni [linesman::_op_toolset $op]} continue
                set input [dict get $a input]
                set path [dict getdef $input file_path \
                    [dict getdef $input notebook_path ""]]
                if {$path eq "" || ![string match $glob $path]} continue
            }
            spawned {
                if {$name ni {Agent Task}} continue
                if {[dict getdef [dict get $a input] subagent_type ""] ne $agent} continue
            }
        }
        lappend hits $a
    }

    set count [llength $hits]
    # An absence certifies only on a whole record, and a -wrote absence
    # not even then while Bash ran: shell writes leave no tool event.
    set certifiable [dict get $record complete]
    if {$subject eq "wrote" && [dict get $record bash_ran] > 0 && !$ignorebash} {
        set certifiable 0
    }
    switch -- $form {
        least1 {
            if {$count >= 1}      { set verdict yes } \
            elseif {$certifiable} { set verdict no } \
            else                  { set verdict not_provable }
        }
        none {
            if {$count >= 1}      { set verdict no } \
            elseif {$certifiable} { set verdict yes } \
            else                  { set verdict not_provable }
        }
        atmost {
            if {$count > $atmost} { set verdict no } \
            elseif {$certifiable} { set verdict yes } \
            else                  { set verdict not_provable }
        }
    }

    set evidence {}
    foreach a $hits {
        lappend evidence [dict create file [dict get $a file] \
            line [dict get $a line] rendered [linesman::_render $a]]
    }
    return [dict create verdict $verdict count $count evidence $evidence \
        complete [dict get $record complete] gaps [dict get $record gaps] \
        api_errors [dict get $record api_errors] \
        interrupts [dict get $record interrupts] \
        bash_ran [dict get $record bash_ran]]
}

# ── the migrated audit ─────────────────────────────────────────────────────

# tool_counts sid root ?toolname? ?inputfield? - counts of tool_use acts
# across session $sid's record. Bare, a dict of tool name to count. With
# $toolname alone, that tool's count under its own name. With $toolname
# and $inputfield, a dict of that input field's values to counts across
# the tool's calls, the shape a did-it-invoke-the-skill audit reads
# (tool Skill, field skill). Raises with -errorcode
# {LINESMAN NO_TRANSCRIPT} when no transcript for $sid exists under
# $root. Counts are returned even when the record has gaps; a caller
# that needs the completeness verdict sweeps and rules instead.
proc linesman::tool_counts {sid root {toolname ""} {inputfield ""}} {
    set counts [dict create]
    foreach a [dict get [linesman::sweep $sid $root] acts] {
        set name [dict get $a tool]
        if {$toolname eq ""} {
            dict incr counts $name
            continue
        }
        if {$name ne $toolname} continue
        if {$inputfield eq ""} {
            dict incr counts $name
            continue
        }
        set v [dict getdef [dict get $a input] $inputfield ""]
        if {$v ne ""} { dict incr counts $v }
    }
    return $counts
}
