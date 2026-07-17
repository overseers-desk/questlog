#!/usr/bin/env tclsh9.0
package require Tcl 9
package require TclOO
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
source [file join $ROOT config.tcl]
source [file join $ROOT lib path.tcl]
source [file join $ROOT lib scope.tcl]
source [file join $ROOT lib jsonl.tcl]
source [file join $ROOT lib match.tcl]
source [file join $ROOT lib scan.tcl]

# Synthetic projects tree under /tmp/questlog-test-since.
proc ::questlog::path::projects_root {} { return /tmp/questlog-test-since }

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name  expected=<$expected>  actual=<$actual>"
        incr ::fails
    } else {
        puts "ok:   $name"
    }
}

# ---- parse_since: the one home for a since value (typed normal form) -
check parse_24h   {rel 86400}   [::questlog::scope::parse_since 24h]
check parse_7d    {rel 604800}  [::questlog::scope::parse_since 7d]
check parse_30d   {rel 2592000} [::questlog::scope::parse_since 30d]
check parse_2w    {rel 1209600} [::questlog::scope::parse_since 2w]
check parse_90m   {rel 5400}    [::questlog::scope::parse_since 90m]
check parse_empty {none}        [::questlog::scope::parse_since ""]
check parse_all   {none}        [::questlog::scope::parse_since all]
check parse_bad_unit  1 [catch {::questlog::scope::parse_since 3x}]
check parse_bad_word  1 [catch {::questlog::scope::parse_since abc}]
check parse_bad_order 1 [catch {::questlog::scope::parse_since d7}]

# ---- parse_since: absolute ISO date -> {abs <local-midnight-epoch>} --
set abs_epoch [clock scan 2026-04-01 -format "%Y-%m-%d"]
check parse_abs_kind  abs        [lindex [::questlog::scope::parse_since 2026-04-01] 0]
check parse_abs_epoch $abs_epoch [lindex [::questlog::scope::parse_since 2026-04-01] 1]
check parse_bad_day   1 [catch {::questlog::scope::parse_since 2026-02-30}]
check parse_bad_month 1 [catch {::questlog::scope::parse_since 2026-13-01}]
check parse_bad_short 1 [catch {::questlog::scope::parse_since 2026-4-1}]

# ---- parse_since: precise instant -> {absdt <epoch>} ----------------
set dt_hm  [clock scan {2026-04-01 13:37}    -format "%Y-%m-%d %H:%M"]
set dt_hms [clock scan {2026-04-01 13:37:30} -format "%Y-%m-%d %H:%M:%S"]
check parse_dt_kind   absdt   [lindex [::questlog::scope::parse_since 2026-04-01T13:37] 0]
check parse_dt_hm     $dt_hm  [lindex [::questlog::scope::parse_since 2026-04-01T13:37] 1]
check parse_dt_hms    $dt_hms [lindex [::questlog::scope::parse_since 2026-04-01T13:37:30] 1]
# A space separator works when the token is quoted (same instant as the T form).
check parse_dt_space  $dt_hm  [lindex [::questlog::scope::parse_since {2026-04-01 13:37}] 1]
check parse_bad_hour  1 [catch {::questlog::scope::parse_since 2026-04-01T25:00}]
check parse_bad_min   1 [catch {::questlog::scope::parse_since 2026-04-01T13:60}]
# A bare date stays day-granular (abs), not absdt - the common case is unchanged.
check parse_dt_bare_date abs [lindex [::questlog::scope::parse_since 2026-04-01] 0]

# ---- cutoff_for: "all" => no bound; relative => now - secs; abs => epoch-1
check cutoff_all 0 [::questlog::scope::cutoff_for [dict create since all]]
set now [clock seconds]
set c7 [::questlog::scope::cutoff_for [dict create since 7d]]
check cutoff_7d_within 1 [expr {abs(($now - 604800) - $c7) <= 2}]
check cutoff_abs [expr {$abs_epoch - 1}] \
    [::questlog::scope::cutoff_for [dict create since 2026-04-01]]

# ---- ceiling_for: no until => no bound; rel => now - secs; abs => end of day
check ceiling_none "" [::questlog::scope::ceiling_for [dict create]]
check ceiling_all  "" [::questlog::scope::ceiling_for [dict create until all]]
set u7 [::questlog::scope::ceiling_for [dict create until 7d]]
check ceiling_7d_within 1 [expr {abs(($now - 604800) - $u7) <= 2}]
# An absolute until covers the whole named day: the last second before next midnight.
check ceiling_abs [expr {[clock add $abs_epoch 1 day] - 1}] \
    [::questlog::scope::ceiling_for [dict create until 2026-04-01]]
# A datetime cutoff/ceiling pins to the named second (cutoff epoch-1, ceiling exact).
check cutoff_dt  [expr {$dt_hm - 1}] \
    [::questlog::scope::cutoff_for [dict create since 2026-04-01T13:37]]
check ceiling_dt $dt_hm \
    [::questlog::scope::ceiling_for [dict create until 2026-04-01T13:37]]

# ---- since_label: the one display-string home -----------------------
check label_all  all          [::questlog::scope::since_label all]
check label_week {1 week}     [::questlog::scope::since_label 7d]
check label_2w   {2 weeks}    [::questlog::scope::since_label 2w]
check label_6h   {6 hours}    [::questlog::scope::since_label 6h]
check label_90m  {90 minutes} [::questlog::scope::since_label 90m]
# The abs label tracks the locale, so assert against the same formatter rather
# than a fixed string (otherwise the test would read en_AU on one box, C on another).
check label_abs \
    "since [string trim [clock format $abs_epoch -format %x -locale [::questlog::scope::time_locale]]]" \
    [::questlog::scope::since_label 2026-04-01]

# ---- list_paths_for: a since bound prunes the scan corpus ----------
::questlog::path::_real_file delete -force /tmp/questlog-test-since
::questlog::path::_real_file mkdir /tmp/questlog-test-since/-home-test-code-foo

set recent /tmp/questlog-test-since/-home-test-code-foo/recent.jsonl
set fh [open $recent w]
puts $fh {{"type":"user","message":{"content":"recent"},"cwd":"/home/test/code/foo"}}
close $fh

set old /tmp/questlog-test-since/-home-test-code-foo/old.jsonl
set fh [open $old w]
puts $fh {{"type":"user","message":{"content":"old"},"cwd":"/home/test/code/foo"}}
close $fh
file mtime $old [expr {[clock seconds] - 40*24*3600}]

set s [::questlog::Scan new {} {}]
set lp7 [$s list_paths_for [dict create since 7d]]
check since_7d_keeps_recent 1 [expr {$recent in $lp7}]
check since_7d_drops_old    0 [expr {$old in $lp7}]
set lpall [$s list_paths_for [dict create since all]]
check since_all_keeps_recent 1 [expr {$recent in $lpall}]
check since_all_keeps_old    1 [expr {$old in $lpall}]

# ---- list_paths_for: an until bound prunes the recent end ----------
# since all isolates the upper bound; without it cutoff_for would apply the
# configured since_default floor and drop the 40-day-old fixture on its own.
set lpu30 [$s list_paths_for [dict create since all until 30d]]
check until_30d_drops_recent 0 [expr {$recent in $lpu30}]
check until_30d_keeps_old    1 [expr {$old in $lpu30}]
# since and until together bracket a window: 60d..30d ago keeps only the 40d-old one.
set lpwin [$s list_paths_for [dict create since 60d until 30d]]
check window_keeps_old    1 [expr {$old in $lpwin}]
check window_drops_recent 0 [expr {$recent in $lpwin}]
$s destroy

# ---- row_matches: the until ceiling, day-inclusive, bookmark-blind -
# Each snapshot says "since all" so only the until bound under test is in force.
set rowR [dict create mtime $now]
set rowO [dict create mtime [expr {$now - 40*86400}]]
check rm_until_keeps_old     1 [::questlog::scope::row_matches [dict create since all until 30d] $rowO]
check rm_until_drops_recent  0 [::questlog::scope::row_matches [dict create since all until 30d] $rowR]
check rm_no_until_keeps_recent 1 [::questlog::scope::row_matches [dict create since all] $rowR]
# A bookmark is a session attribute, never a window exemption: the until
# ceiling drops a bookmarked row exactly like a plain one, so a window audit
# is exact.
set rowRbk [dict create mtime $now bookmarked 1]
check rm_until_bookmark_obeys 0 [::questlog::scope::row_matches [dict create since all until 30d] $rowRbk]
# An absolute until keeps the whole named day and drops the day after.
set eod  [dict create mtime [expr {[clock add $abs_epoch 1 day] - 1}]]
set next [dict create mtime [clock add $abs_epoch 1 day]]
check rm_until_abs_keeps_eod  1 [::questlog::scope::row_matches [dict create since all until 2026-04-01] $eod]
check rm_until_abs_drops_next 0 [::questlog::scope::row_matches [dict create since all until 2026-04-01] $next]

::questlog::path::_real_file delete -force /tmp/questlog-test-since

if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
