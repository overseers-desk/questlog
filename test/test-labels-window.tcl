#!/usr/bin/env wish9.0
# The labels window against three bookmarked sessions, two with fresh stored
# labels and one stale: rows sort by state then ctx%, the fresh glyphs show at
# once, the stale row reads labelling until the fake claude replies, and Resume
# names the row's cwd and uuid. Run on a headless display: DISPLAY=:99 wish9.0 test/test-labels-window.tcl
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
puts {{"type":"assistant","message":{"content":[{"type":"text","text":"{\"state\":\"ready\",\"question\":\"\",\"next_step\":\"Commit it.\",\"blocker\":\"\",\"successor\":\"\"}"}]}}}
}]
::questlog::path::_real_file attributes $fake -permissions 0755
set ::questlog::labels::claude_bin $fake

set body [join {
    {{"type":"user","cwd":"/w","message":{"role":"user","content":"fix it"}}}
    {{"type":"assistant","message":{"model":"claude-sonnet-4-5","role":"assistant","content":[{"type":"text","text":"Done?"}]}}}
} \n]\n
set members [dict create]
foreach {uuid cwd} {aaaaaaaa-fresh /work/alpha bbbbbbbb-stale /work/beta cccccccc-ready /work/gamma dddddddd-ready /work/delta} {
    set p [file join $tmp $uuid.jsonl]
    write_file $p $body
    dict set members $uuid [dict create path $p cwd $cwd]
}
set fp [dict get $members aaaaaaaa-fresh path]
::questlog::labels::write aaaaaaaa-fresh [dict create status ok state needs_answer \
    question "A or B?" next_step "Pick one." blocker "" successor "" title "fresh one" \
    ctx_pct 12 src_mtime [file mtime $fp] src_size [file size $fp]]
set rp [dict get $members cccccccc-ready path]
::questlog::labels::write cccccccc-ready [dict create status ok state ready \
    question "" next_step "Push it." blocker "" successor "" title "ready one" \
    ctx_pct 50 src_mtime [file mtime $rp] src_size [file size $rp]]
set dp [dict get $members dddddddd-ready path]
::questlog::labels::write dddddddd-ready [dict create status ok state ready \
    next_step "Tag it." title "lean one" \
    ctx_pct 5 src_mtime [file mtime $dp] src_size [file size $dp]]
::questlog::labels::write bbbbbbbb-stale [dict create status ok state done \
    src_mtime 1 src_size 1]

set W [::questlog::ui::LabelsWindow new . {on_move list on_bookmark list on_rename list}]
$W show $members
set tv [$W tree]
check "rows sorted by state then ctx%, labelling last" \
    {dddddddd-ready cccccccc-ready aaaaaaaa-fresh bbbbbbbb-stale} [$tv children {}]
check "fresh row shows its state, title and question at once" \
    {{❓ needs_answer} {fresh one} alpha 12% 0m {A or B?}} \
    [$tv item aaaaaaaa-fresh -values]
check "stale row reads labelling" {⏳ labelling} [lindex [$tv item bbbbbbbb-stale -values] 0]

write_file [file join $tmp go] ""
after 10000 {set ::timeout 1}
while {[lindex [$tv item bbbbbbbb-stale -values] 0] eq "⏳ labelling" && ![info exists ::timeout]} {
    vwait ::questlog::labels::running
    update
}
update
check "stale row updates from the reply" {{▶ ready} {Commit it.}} \
    [lmap i {0 5} {lindex [$tv item bbbbbbbb-stale -values] $i}]
check "arrivals do not re-sort" \
    {dddddddd-ready cccccccc-ready aaaaaaaa-fresh bbbbbbbb-stale} [$tv children {}]
$W sort
check "a sort places the arrival by its state" \
    {dddddddd-ready cccccccc-ready bbbbbbbb-stale aaaaaaaa-fresh} [$tv children {}]

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
