package require Tcl 9
package require json
package require json::write
package require logman
package require tallyman

# ::questlog::labels - what each session waits on (the user's go-ahead, the
# user's decision, another session, or nothing), asked of claude from the
# session's first prompt, its last prompts and its last reply, and kept as one
# JSON file per session uuid under the XDG state directory. Derived data: losing a file costs a re-run. The scanner never
# reads the store, so session data keeps its one home in the list's node store.

namespace eval ::questlog::labels {
    # The test seam: a bare name is resolved on PATH at exec time.
    variable claude_bin claude
    variable MODEL sonnet
    variable MAX_RUNNING 4
    variable running 0
    variable queue {}
}

# $XDG_STATE_HOME/questlog/labels, else ~/.local/state/questlog/labels. Not
# ui::state::dir, since lib/ must not depend on ui/.
proc ::questlog::labels::dir {} {
    if {[info exists ::env(XDG_STATE_HOME)] && $::env(XDG_STATE_HOME) ne ""} {
        set base $::env(XDG_STATE_HOME)
    } else {
        set base [file join [file home] .local state]
    }
    return [file join $base questlog labels]
}

proc ::questlog::labels::read {uuid} {
    set f [file join [dir] $uuid.json]
    if {![file isfile $f]} { return "" }
    if {[catch {
        set fh [open $f r]
        chan configure $fh -encoding utf-8
        set rec [::json::json2dict [::read $fh]]
        close $fh
    }]} { return "" }
    return $rec
}

proc ::questlog::labels::write {uuid rec} {
    set fields {}
    dict for {k v} $rec {
        if {$k in {ctx_pct src_mtime src_size} && [string is double -strict $v]} {
            lappend fields $k $v
        } else {
            lappend fields $k [::json::write string $v]
        }
    }
    set d [dir]
    if {![file isdirectory $d]} { ::questlog::path::_real_file mkdir $d }
    set fh [open [file join $d $uuid.json] w]
    chan configure $fh -encoding utf-8
    puts $fh [::json::write object {*}$fields]
    close $fh
}

# True when the transcript changed since rec was labelled, or rec is empty.
proc ::questlog::labels::stale {rec path} {
    if {$rec eq "" || ![file isfile $path]} { return 1 }
    return [expr {[dict getdef $rec src_mtime ""] != [file mtime $path]
        || [dict getdef $rec src_size ""] != [file size $path]}]
}

# The fields read off the transcript without claude: title (last agentName),
# ctx_pct of the last request, and the size and mtime the label is valid for.
proc ::questlog::labels::computed {path} {
    set mtime [file mtime $path]
    set size [file size $path]
    set fh [open $path r]
    chan configure $fh -encoding utf-8 -profile replace
    set lines [split [::read $fh] \n]
    seek $fh 0
    set title [lindex [::questlog::match::last_seen $fh] 0]
    close $fh
    set u [tallyman::parse_lines $lines]
    set ctx_pct ""
    if {[dict get $u ctx_tokens] ne ""} {
        set win [tallyman::model_context_window [dict get $u ctx_model]]
        set ctx_pct [expr {round(100.0 * [dict get $u ctx_tokens] / $win)}]
    }
    return [dict create title $title ctx_pct $ctx_pct \
        src_mtime $mtime src_size $size]
}

# {first recent last_reply}: the first typed prompt (300 chars), the last six
# typed prompts, and the last assistant text.
proc ::questlog::labels::extract {path} {
    set prompts {}
    set fh [open $path r]
    chan configure $fh -encoding utf-8 -profile replace
    while {[chan gets $fh line] >= 0} {
        if {![::logman::is_user_turn $line]} continue
        set rec [::logman::parse_line $line]
        if {$rec eq ""} continue
        set text [string trim [::logman::extract_text $rec]]
        if {$text ne ""} { lappend prompts $text }
    }
    close $fh
    set recent {}
    foreach p [lrange $prompts end-5 end] {
        lappend recent [string range $p 0 1499]
    }
    return [dict create \
        first [string range [lindex $prompts 0] 0 299] \
        recent $recent \
        last_reply [string range [::logman::last_assistant_text $path] end-5999 end]]
}

proc ::questlog::labels::prompt {tail} {
    set recent ""
    foreach p [dict get $tail recent] { append recent "---\n$p\n" }
    return "Below is the start and end of a paused Claude Code session. Say what it waits on.

Reply with one JSON object and nothing else, with exactly these keys:
- \"waiting_on\": one of \"yes\" (a fix is designed and awaits the user's go-ahead), \"ruling\" (the user must make a decision), \"peer\" (the work was handed to another session), \"nothing\" (finished or idle).
- \"question\": when waiting_on is \"ruling\", the decision in one line; else \"\".
- \"next_step\": one sentence, what a resumed session would do first.
- \"blocker\": what stops it running unattended, or \"\".

First user prompt:
[dict get $tail first]

Last user prompts, oldest first:
$recent
Last assistant reply:
[dict get $tail last_reply]
"
}

# Label the session at path in the background, write its record, then call
# done_cb uuid rec. At most MAX_RUNNING claude processes run; the rest queue.
proc ::questlog::labels::run {path uuid done_cb} {
    variable queue
    lappend queue [list $path $uuid $done_cb]
    _pump
}

proc ::questlog::labels::_pump {} {
    variable queue
    variable running
    variable MAX_RUNNING
    while {$running < $MAX_RUNNING && [llength $queue]} {
        set queue [lassign $queue job]
        lassign $job path uuid done_cb
        incr running
        if {[catch {_start $path $uuid $done_cb} err]} {
            _finish $path $uuid $done_cb "" $err
        }
    }
}

proc ::questlog::labels::_start {path uuid done_cb} {
    variable claude_bin
    variable MODEL
    set text [prompt [extract $path]]
    set fh [open |[list $claude_bin -p --output-format stream-json --verbose \
        --model $MODEL $text << ""] r]
    chan configure $fh -blocking 0 -encoding utf-8
    set buf [namespace current]::_buf($fh)
    set $buf ""
    chan event $fh readable [list [namespace current]::_readable $fh $path $uuid $done_cb]
}

proc ::questlog::labels::_readable {fh path uuid done_cb} {
    variable _buf
    append _buf($fh) [::read $fh]
    if {![chan eof $fh]} return
    set out $_buf($fh)
    unset _buf($fh)
    chan configure $fh -blocking 1
    set err ""
    if {[catch {close $fh} cerr]} { set err "claude failed: $cerr" }
    _finish $path $uuid $done_cb $out $err
}

proc ::questlog::labels::_finish {path uuid done_cb out err} {
    variable running
    incr running -1
    if {$err eq "" && [catch {_parse $out} fields]} { set err $fields }
    set rec {}
    catch {set rec [computed $path]}
    if {$err eq ""} {
        set rec [dict merge $rec $fields [dict create status ok]]
    } else {
        set rec [dict merge $rec [dict create status failed error $err]]
    }
    catch {write $uuid $rec}
    after idle [list {*}$done_cb $uuid $rec]
    _pump
}

# The model's fields (those of prompt's reply) from claude's stream-json
# output: the first assistant text block holding the object, possibly in a code fence. The
# result envelope's own `result` is only the final turn, and a hook that
# reopens the turn (a stop hook on the user's machine) makes the model's
# reply to it the final turn, with the label a block earlier.
proc ::questlog::labels::_parse {out} {
    set texts {}
    foreach line [split $out \n] {
        if {[catch {::json::json2dict $line} rec] || [dict getdef $rec type ""] ne "assistant"} continue
        foreach block [dict getdef [dict getdef $rec message {}] content {}] {
            if {[dict getdef $block type ""] eq "text"} { lappend texts [dict get $block text] }
        }
    }
    if {![llength $texts]} {
        error "unparsable claude output: [string range $out 0 199]"
    }
    foreach text $texts {
        set a [string first "\{" $text]
        set b [string last "\}" $text]
        if {$a < 0 || [catch {::json::json2dict [string range $text $a $b]} obj]
                || ![dict exists $obj waiting_on]} continue
        set fields {}
        foreach k {waiting_on question next_step blocker} {
            dict set fields $k [dict getdef $obj $k ""]
        }
        return $fields
    }
    error "unparsable model reply: [string range [lindex $texts end] 0 199]"
}
