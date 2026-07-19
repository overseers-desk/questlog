#!/usr/bin/env tclsh9.0
# Parity test: the search worker thread and the main interpreter must produce
# identical scan_file / leaf_record_hit output. A worker sources lib/jsonl.tcl and
# lib/match.tcl through worker_prelude instead of carrying copies, so this is
# the guard that the two sides cannot drift - it runs the real prelude and
# WorkerScript in a real thread and diffs the results. Run:
#   tclsh9.0 test/test-worker-parity.tcl
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
source [file join $ROOT config.tcl]
source [file join $ROOT lib jsonl.tcl]
source [file join $ROOT lib match.tcl]
source [file join $ROOT lib search.tcl]
# Main-interp caps, as the launcher injects them.
::questlog::match::set_caps [dict create \
    content_cap     [::questlog::config::get content_cap] \
    snippet_lead    [::questlog::config::get snippet_lead] \
    snippet_trail   [::questlog::config::get snippet_trail] \
    tool_param_cap  [::questlog::config::get tool_param_cap] \
    tool_render_cap [::questlog::config::get tool_render_cap]]

if {[catch {package require Thread}]} {
    puts "skip: Thread package unavailable"
    exit 0
}

set fails 0
proc check {name a b} {
    if {$a eq $b} {
        puts "ok:   $name"
    } else {
        puts "FAIL: $name"
        puts "  main:   <$a>"
        puts "  worker: <$b>"
        incr ::fails
    }
}

# A fixture session exercising each cap path: a content block past content_cap,
# a tool_use parameter past tool_param_cap, a tool_result, and an edit on a
# known path. NEEDLE appears in several block kinds so a terms search matches.
set long [string repeat "x" 500]
set bigparam [string repeat "p" 200]
set fix [file join [file dirname [info script]] _parity_fixture.jsonl]
set fh [open $fix w]
chan configure $fh -encoding utf-8 -translation lf
puts $fh "{\"type\":\"user\",\"cwd\":\"/tmp/proj\",\"timestamp\":\"2026-05-24T17:00:00Z\",\"message\":{\"content\":\"find the NEEDLE here $long\"}}"
puts $fh "{\"type\":\"assistant\",\"message\":{\"content\":\[{\"type\":\"text\",\"text\":\"the NEEDLE again\"},{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"echo $bigparam NEEDLE\"}}\]}}"
puts $fh "{\"type\":\"assistant\",\"message\":{\"content\":\[{\"type\":\"tool_use\",\"name\":\"Edit\",\"input\":{\"file_path\":\"/a/b.tcl\",\"old_string\":\"x\",\"new_string\":\"y\"}}\]}}"
puts $fh "{\"type\":\"user\",\"message\":{\"content\":\"second turn\"}}"
close $fh

proc mk_clauses {args} {
    set snap [dict create search "" search_case 0 search_regions any \
        pattern {} file {} tool {}]
    foreach {k v} $args {
        switch -- $k {
            terms    { dict set snap search $v }
            patterns { dict set snap pattern $v }
            files    { dict set snap file $v }
            tools    { dict set snap tool $v }
            regions  { dict set snap search_regions $v }
        }
    }
    return [::questlog::search::build_clauses $snap]
}

# Stand up a worker exactly as start_threaded does.
set wscript "[::questlog::search::worker_prelude $::ROOT]$::questlog::search::WorkerScript"
set tid [thread::create $wscript]

foreach {name clauses} [list \
    terms_only     [mk_clauses terms NEEDLE] \
    file_wrote     [mk_clauses files {{wrote b.tcl}}] \
    terms_and_file [mk_clauses terms NEEDLE files {{wrote /a/b.tcl}}] \
    tool_bash      [mk_clauses tools {{Bash NEEDLE}}] \
    no_match       [mk_clauses terms ZZZNOPE]] {
    set main_res   [::questlog::match::scan_file $fix $clauses]
    set worker_res [thread::send $tid [list ::questlog::match::scan_file $fix $clauses]]
    check "scan_file parity: $name" $main_res $worker_res
}

# leaf_record_hit directly on a crafted record, so the tool_param_cap path (the
# rendered tool_use a keyword leaf snippets through) is proven mirrored rather
# than merely present.
set rec [::questlog::jsonl::parse_line "{\"type\":\"assistant\",\"message\":{\"content\":\[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"echo $bigparam\"}}\]}}"]
set leaf [::questlog::match::kw_leaf echo {} 0]
set main_rh   [::questlog::match::leaf_record_hit $leaf $rec 1]
set worker_rh [thread::send $tid [list ::questlog::match::leaf_record_hit $leaf $rec 1]]
check "leaf_record_hit parity (cap path)" $main_rh $worker_rh

thread::release $tid
file delete $fix

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
