#!/usr/bin/env wish9.0
# The reply column: within each turn, the reply (the answer after the work)
# renders under the `reply` tag the Viewer sets as a serif column on cream,
# and the work before it does not. This drives a real Viewer over a
# synthetic session and asserts on the tag ranges in its text widget:
#   1. an end_turn reply after tool_use records is marked, its message split
#      across two records marked whole, the earlier text (stop_reason
#      tool_use) not;
#   2. a turn written before stop_reason was recorded (null throughout)
#      marks the run of text records after its last tool result;
#   3. an injected isMeta record mid-turn does not split the turn, and the
#      refusal before it marks nothing;
#   4. a turn a stop hook reopened marks both of its end_turn replies.
# It also checks the faces inside the column (bold and headings keep their
# weight in the serif, inline and fenced code stay mono) and that the
# reading-font picker moves the serif's size but not its family.
#
# Runs under wish (it builds a Viewer, so it needs Tk); run-audit routes it to
# wish9.0 on the private Xvfb. Standalone: DISPLAY=:99 wish9.0 test-reply-column.tcl

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
set ::questlog_config_only 1; source [file join $ROOT questlog]
foreach f {lib/debug.tcl lib/path.tcl lib/match.tcl \
           lib/cost.tcl ui/theme.tcl ui/reveal.tcl ui/viewer.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

set fails 0
proc check {name got want} {
    if {$got eq $want} {
        puts "ok   - $name"
    } else {
        puts "FAIL - $name"
        puts "       got:  $got"
        puts "       want: $want"
        incr ::fails
    }
}

# ---- synthetic session --------------------------------------------------------
set tmpbase [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set TMP [file join $tmpbase ql-reply-test-[pid]]
::questlog::path::_real_file mkdir $TMP
set JP [file join $TMP session.jsonl]

# One assistant record: stop_reason sr ("" writes null), content blocks json.
proc asst {ts id sr blocks} {
    set s [expr {$sr eq "" ? "null" : "\"$sr\""}]
    return "{\"type\":\"assistant\",\"timestamp\":\"$ts\",\"message\":{\"id\":\"$id\",\"role\":\"assistant\",\"model\":\"claude-opus-4-1\",\"stop_reason\":$s,\"content\":\[$blocks\]}}"
}
proc tblock {s} { return "{\"type\":\"text\",\"text\":\"$s\"}" }
proc call {} { return {{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}} }
proc result {ts} {
    return "{\"type\":\"user\",\"timestamp\":\"$ts\",\"message\":{\"role\":\"user\",\"content\":\[{\"type\":\"tool_result\",\"tool_use_id\":\"t1\",\"content\":\"out\"}\]}}"
}
proc prompt {ts s {src typed}} {
    set p [expr {$src eq "" ? "" : ",\"promptSource\":\"$src\""}]
    return "{\"type\":\"user\",\"cwd\":\"/tmp/proj\"$p,\"timestamp\":\"$ts\",\"message\":{\"role\":\"user\",\"content\":\"$s\"}}"
}

set L {}
# Turn 1: work, then a reply split across two records of one message. The
# reply holds a heading, a bold span, an inline code span and a fenced block.
lappend L [prompt 2026-10-01T10:00:00Z "first question"]
lappend L [asst 2026-10-01T10:00:01Z m1 tool_use [tblock "OPENWORK system two paragraph"]]
lappend L [asst 2026-10-01T10:00:02Z m1 tool_use [call]]
lappend L [result 2026-10-01T10:00:03Z]
lappend L [asst 2026-10-01T10:00:04Z m2 tool_use [tblock "PROGRESSWORK now checking"]]
lappend L [asst 2026-10-01T10:00:05Z m2 tool_use [call]]
lappend L [result 2026-10-01T10:00:06Z]
lappend L [asst 2026-10-01T10:00:07Z m3 end_turn {{"type":"thinking","thinking":"THINKREPLY"}}]
lappend L [asst 2026-10-01T10:00:08Z m3 end_turn [tblock "REPLYONE plain\\n\\n## HEADWORD here\\n\\nsome **BOLDWORD** and `CODESPAN` too\\n\\n```\\nFENCEWORD\\n```"]]
lappend L [asst 2026-10-01T10:00:09Z m3 end_turn [tblock "REPLYONETAIL closes it"]]
# Turn 2: an old file, stop_reason null throughout.
lappend L [prompt 2026-10-01T11:00:00Z "second question" ""]
lappend L [asst 2026-10-01T11:00:01Z m4 "" [tblock "OLDWORK before the call"]]
lappend L [asst 2026-10-01T11:00:02Z m4 "" [call]]
lappend L [result 2026-10-01T11:00:03Z]
lappend L [asst 2026-10-01T11:00:04Z m5 "" [tblock "OLDREPLYA first half"]]
lappend L [asst 2026-10-01T11:00:05Z m5 "" [tblock "OLDREPLYB second half"]]
# Turn 3: a refusal, the safeguard notice (isMeta), the reply.
lappend L [prompt 2026-10-01T12:00:00Z "third question"]
lappend L [asst 2026-10-01T12:00:01Z m6 tool_use [tblock "METAWORK looking first"]]
lappend L [asst 2026-10-01T12:00:02Z m6 tool_use [call]]
lappend L [result 2026-10-01T12:00:03Z]
lappend L [asst 2026-10-01T12:00:04Z m7 refusal [tblock "REFUSEDWORK cut off"]]
lappend L {{"type":"user","isMeta":true,"refusedMessageId":"m7","timestamp":"2026-10-01T12:00:05Z","message":{"role":"user","content":"Your response above was stopped by a safety classifier. Continue."}}}
lappend L [asst 2026-10-01T12:00:06Z m8 end_turn [tblock "METAREPLY after the stand-in"]]
# Turn 4: a stop hook reopens the turn after its first reply.
lappend L [prompt 2026-10-01T13:00:00Z "fourth question"]
lappend L [asst 2026-10-01T13:00:01Z m9 end_turn [tblock "HOOKFIRST reply"]]
lappend L {{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-10-01T13:00:02Z","content":"Stop hook feedback: keep going"}}
lappend L [asst 2026-10-01T13:00:03Z m10 tool_use [tblock "HOOKWORK one more look"]]
lappend L [asst 2026-10-01T13:00:04Z m10 tool_use [call]]
lappend L [result 2026-10-01T13:00:05Z]
lappend L [asst 2026-10-01T13:00:06Z m11 end_turn [tblock "HOOKSECOND reply"]]

set fh [open $JP w]
fconfigure $fh -encoding utf-8
foreach l $L { puts $fh $l }
close $fh

set V [::questlog::ui::Viewer new .v]
pack .v -fill both -expand 1
$V show $JP 0 {}
update idletasks
update
set Text [$V textwidget]
set NS [info object namespace $V]

# 1 iff the first character of token carries tag.
proc tagged {token tag} {
    set i [$::Text search -elide -exact -- $token 1.0 end]
    if {$i eq ""} { return "absent" }
    return [expr {$tag in [$::Text tag names $i]}]
}
# The font that wins at token: the highest-priority tag there setting -font.
proc face {token} {
    set i [$::Text search -elide -exact -- $token 1.0 end]
    set f ""
    foreach t [$::Text tag names $i] {
        set v [$::Text tag cget $t -font]
        if {$v ne ""} { set f $v }
    }
    return $f
}

# The isMeta notice sits inside turn 3: four turns, not five.
check "four turns: the stand-in prompt splits none" [llength [set ${NS}::Turns]] 4

# 1. end_turn after tool_use records.
check "opening paragraph (tool_use) is work"   [tagged OPENWORK reply] 0
check "progress line (tool_use) is work"        [tagged PROGRESSWORK reply] 0
check "end_turn reply is marked"                [tagged REPLYONE reply] 1
check "the message's second record is marked"   [tagged REPLYONETAIL reply] 1
check "thinking in the reply message is not"    [tagged THINKREPLY reply] 0
check "the reply opens on its own line" \
    [$Text compare [$Text search -exact REPLYONE 1.0 end] == \
        "[$Text search -exact REPLYONE 1.0 end] linestart"] 1
check "the column's first character takes reply-top" [tagged "REPLYONE plain" reply-top] 1
check "the role label stays outside the column" \
    [expr {"reply" in [$Text tag names "[$Text search -exact REPLYONE 1.0 end] -1 line linestart"]}] 0

# Faces inside the column.
check "plain reply text is the serif"           [face REPLYONE] QLReply
check "a heading keeps its weight in the serif" [face HEADWORD] QLReplyBold
check "a bold span keeps its weight in the serif" [face BOLDWORD] QLReplyBold
check "inline code stays mono"                  [face CODESPAN] QLMono
check "fenced code stays mono"                  [face FENCEWORD] QLMono
check "fenced code lies inside the column"      [tagged FENCEWORD reply] 1
check "work text keeps the body face"           [face OPENWORK] QLBody

# 2. null stop_reason: the trailing text run after the last tool result.
check "old-file work before the call is not marked" [tagged OLDWORK reply] 0
check "old-file trailing run, first record"         [tagged OLDREPLYA reply] 1
check "old-file trailing run, second record"        [tagged OLDREPLYB reply] 1

# 3. the turn with an injected notice.
check "work before the refusal is not marked"   [tagged METAWORK reply] 0
check "the refused text is not marked"          [tagged REFUSEDWORK reply] 0
check "the reply after the stand-in is marked"  [tagged METAREPLY reply] 1

# 4. a stop hook's reopened turn: both end_turn replies.
check "the first reply is marked"               [tagged HOOKFIRST reply] 1
check "work after the hook is not marked"       [tagged HOOKWORK reply] 0
check "the second reply is marked"              [tagged HOOKSECOND reply] 1

# The column's look comes from the theme.
check "column ground is the theme's reply cream" \
    [$Text tag cget reply -background] [::questlog::ui::theme::c reply]
check "column family is the platform serif" \
    [font actual QLReply -family] [font actual serif -family]

# The reading-font picker moves the serif's size, never its family.
set serif [font actual QLReply -family]
::questlog::ui::theme::set_body_font [list [font actual TkFixedFont -family] 17]
check "picker moves the body family" \
    [font actual QLBody -family] [font actual TkFixedFont -family]
check "picker leaves the serif family"  [font actual QLReply -family] $serif
check "picker carries the size to the serif" [font configure QLReply -size] 17
check "and to its bold" [font configure QLReplyBold -size] 17

::questlog::path::_real_file delete -force $TMP
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
