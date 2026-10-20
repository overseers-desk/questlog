#!/usr/bin/env wish9.0
# The labels window against two bookmarked sessions, one with a fresh stored
# label and one stale: both rows appear, the fresh glyph at once, the stale row
# reads labelling until the fake claude replies, and Resume names the row's cwd
# and uuid. Run on a headless display: DISPLAY=:99 wish9.0 test/test-labels-window.tcl
package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
foreach f {lib/path.tcl lib/match.tcl lib/labels.tcl ui/theme.tcl \
           ui/terminal.tcl ui/session_actions.tcl ui/labels_window.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init
wm withdraw .

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name"
        puts "  expected: <$expected>"
        puts "  actual:   <$actual>"
        incr ::fails
    } else {
        puts "ok:   $name"
    }
}
proc write_file {path content} {
    set fd [open $path w]
    puts -nonewline $fd $content
    close $fd
}

set tmp [::questlog::path::_real_file tempdir]
set ::env(XDG_STATE_HOME) [file join $tmp state]

# The fake claude waits for a go file, so the test sees the row mid-label.
set fake [file join $tmp claude]
write_file $fake [string map [list @GO@ [file join $tmp go]] {#!/usr/bin/env tclsh9.0
while {![file exists {@GO@}]} { after 50 }
puts {{"type":"assistant","message":{"content":[{"type":"text","text":"{\"waiting_on\":\"yes\",\"question\":\"\",\"next_step\":\"Commit it.\",\"blocker\":\"\"}"}]}}}
}]
::questlog::path::_real_file attributes $fake -permissions 0755
set ::questlog::labels::claude_bin $fake

set body [join {
    {{"type":"user","cwd":"/w","message":{"role":"user","content":"fix it"}}}
    {{"type":"assistant","message":{"model":"claude-sonnet-4-5","role":"assistant","content":[{"type":"text","text":"Done?"}]}}}
} \n]\n
set members [dict create]
foreach {uuid cwd} {aaaaaaaa-fresh /work/alpha bbbbbbbb-stale /work/beta} {
    set p [file join $tmp $uuid.jsonl]
    write_file $p $body
    dict set members $uuid [dict create path $p cwd $cwd]
}
set fp [dict get $members aaaaaaaa-fresh path]
::questlog::labels::write aaaaaaaa-fresh [dict create status ok waiting_on ruling \
    question "A or B?" next_step "Pick one." blocker "" title "fresh one" \
    ctx_pct 12 src_mtime [file mtime $fp] src_size [file size $fp]]
::questlog::labels::write bbbbbbbb-stale [dict create status ok waiting_on nothing \
    src_mtime 1 src_size 1]

set W [::questlog::ui::LabelsWindow new . {on_move list on_bookmark list on_rename list}]
$W show $members
set tv [$W tree]
check "two rows" {aaaaaaaa-fresh bbbbbbbb-stale} [$tv children {}]
check "fresh row shows its glyph and title at once" {🟡 {fresh one} alpha 12% ruling {Pick one.}} \
    [$tv item aaaaaaaa-fresh -values]
check "stale row reads labelling" ⏳ [lindex [$tv item bbbbbbbb-stale -values] 0]

write_file [file join $tmp go] ""
after 10000 {set ::timeout 1}
while {[lindex [$tv item bbbbbbbb-stale -values] 0] eq "⏳" && ![info exists ::timeout]} {
    vwait ::questlog::labels::running
    update
}
update
check "stale row updates from the reply" {🟢 yes {Commit it.}} \
    [lmap i {0 4 5} {lindex [$tv item bbbbbbbb-stale -values] $i}]

$tv selection set aaaaaaaa-fresh
update
check "Resume names the row's cwd and uuid" \
    "cd '/work/alpha' && claude --resume aaaaaaaa-fresh" [$W resume_command]

# A right-click opens the list's session menu on the row under the pointer.
wm deiconify .qllabels
update
lassign [$tv bbox bbbbbbbb-stale] bx by
after 300 {[$W menu] unpost}
event generate $tv <Button-3> -x [expr {$bx + 5}] -y [expr {$by + 5}] \
    -rootx 10 -rooty 10
update
set m [$W menu]
set resume_cmd ""
for {set i 0} {$i <= [$m index end]} {incr i} {
    if {[$m type $i] eq "command" && [$m entrycget $i -label] eq "Resume in new terminal tab"} {
        set resume_cmd [$m entrycget $i -command]
    }
}
check "right-click selects the row" bbbbbbbb-stale [$tv selection]
check "its menu resumes that uuid in its cwd" {/work/beta bbbbbbbb-stale} \
    [lmap k {cwd uuid} {dict getdef [lindex $resume_cmd 1] target $k ""}]

puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
