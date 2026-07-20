package require Tcl 9
package provide must 1.0

# must - the substring a regular expression cannot match without.
#
# A regex run over bulk text spends most of its time proving haystacks
# irrelevant. A plain substring scan proves the same thing far cheaper
# whenever some literal is known to appear in every match: GNU grep derives
# such a string (its dfamust) and skips with Boyer-Moore, ripgrep feeds its
# literals to a prefilter, Hyperscan matches literal factors before waking
# its automata, and trigram indexes answer the question per document instead
# of per line. must is that idea for Tcl: from an Advanced Regular
# Expression (ARE) pattern it derives a factor - a substring every match
# must contain - so a caller can gate
# lines, files, or index lookups with [string first] and run the regex only
# where the factor appears.
#
#   must::factor ?-nocase? ?-expanded? pat -> {factor nocase}
#     The required factor and its case mode. nocase 1 means the pattern
#     folds case (a leading (?i), or the -nocase option): the factor comes
#     back lowered and must be sought in a lowered haystack. {"" 0} means no
#     factor could be soundly extracted; such a pattern cannot be gated, and
#     every haystack stays a candidate.
#
#   must::filter ?-nocase? ?-expanded? pat -> a test command prefix
#     [{*}$cmd $haystack] returns 0 only when the haystack provably holds no
#     match. A pattern with no factor yields the always-1 command, so a
#     skip loop built on the filter stays sound with no special case:
#
#       set keep [must::filter $pat]
#       foreach line $lines {
#           if {![{*}$keep $line]} continue     ;# cannot match: skip
#           if {[regexp -- $pat $line]} { ... } ;# factor present: verify
#       }
#
# The extractor reads the pattern string alone, and regexp's command-line
# flags change what a pattern means, so MIRROR THE FLAGS YOU MATCH WITH:
# a caller running [regexp -nocase] must pass -nocase here (or embed (?i)),
# and one running [regexp -expanded] must pass -expanded, which forfeits
# the factor as an in-pattern (?x) does. Gating a -nocase match with an
# unflagged factor is a silent-loss trap: the factor tests
# case-exactly, regexp matches case-blind, and the differing lines are
# skipped. The newline flags (-line and kin) need no mirroring; they move
# what ^ $ . mean, never what a literal run requires.
#
# The contract is one-sided: a factor is necessary, never sufficient. A
# haystack containing the factor may still not match; a haystack without it
# cannot. The extractor forfeits - returns no factor - on any construct it
# does not fully model: a *** director, a (?...) group past the start
# (options, non-capturing, lookahead), a leading (?...) block carrying the
# expanded, quoted, or Basic-RE (BRE) letters, a variable-length escape
# (hex, Unicode, control, octal, or a multi-digit backreference), an
# alternation outside any group, an opening brace that never closes its
# bound, and a pattern regexp itself rejects. A malformed pattern also merely forfeits: the filter
# passes everything and the caller's own regexp raises the error at the
# match site. A forfeit costs pruning, never correctness; the other way
# round, a factor's pruning power is only as good as the factor is rare
# (a one-character factor gates little), and the factor is a substring of
# the match text itself - a caller gating a transformed representation of
# that text (an escaped, encoded, or wrapped form) owns the question of
# whether its transform preserves the factor's characters.

namespace eval must {
    namespace export factor filter
}

# The required factor of $pat as {factor nocase}, {"" 0} when none. Literal
# runs are collected only at group depth 0, since a group may be quantified
# away whole; a quantifier drops the character before it from its run,
# because that character may match zero times - dropping a merely-repeated
# one (+, {1,n}) costs pruning, not soundness. The i option is legal only in
# a leading (?...) block in ARE, so a mid-pattern case flip cannot reach a
# collected run.
# Of several surviving runs the first longest wins.
proc must::factor {args} {
    set none [list "" 0]
    set nocase 0
    set pat [lindex $args end]
    foreach opt [lrange $args 0 end-1] {
        switch -- $opt {
            -nocase   { set nocase 1 }
            -expanded { return $none }
            default   { error "unknown option \"$opt\": must be -nocase or -expanded" }
        }
    }
    if {[catch {regexp -- $pat {}}]} { return $none }
    if {[string range $pat 0 2] eq "***"} { return $none }
    set i 0
    set n [string length $pat]
    if {[string range $pat 0 1] eq "(?"} {
        set close [string first ")" $pat]
        if {$close < 0} { return $none }
        set flags [string range $pat 2 [expr {$close - 1}]]
        if {![regexp {^[icesmnpwt]+$} $flags]} { return $none }
        if {[string first i $flags] >= 0} { set nocase 1 }
        set i [expr {$close + 1}]
    }
    set runs [list]
    set run ""
    set depth 0
    while {$i < $n} {
        set c [string index $pat $i]
        switch -exact -- $c {
            "|" {
                if {$depth == 0} { return $none }
                incr i
            }
            "(" {
                if {[string index $pat [expr {$i + 1}]] eq "?"} { return $none }
                incr depth
                if {$run ne ""} { lappend runs $run; set run "" }
                incr i
            }
            ")" {
                incr depth -1
                if {$run ne ""} { lappend runs $run; set run "" }
                incr i
            }
            "\\" {
                # An escape contributes nothing to a literal run - it is a
                # class, a boundary, or one escaped char we do not harvest -
                # so the run breaks here. A fixed two-char escape (\d, \.,
                # \m ...) is stepped over whole. A variable-length one - hex
                # \xhh, \uwxyz, \Ustuvwxyz, control \cX, an octal, a
                # multi-digit backreference - has a length this scanner does
                # not measure, so rather than risk harvesting its tail as
                # literal text its pattern forfeits.
                if {$run ne ""} { lappend runs $run; set run "" }
                if {[string index $pat [expr {$i + 1}]]
                        in {x u U c 0 1 2 3 4 5 6 7 8 9}} { return $none }
                incr i 2
            }
            "\[" {
                set i [must::_bracket_end $pat $i]
                if {$i < 0} { return $none }
                if {$run ne ""} { lappend runs $run; set run "" }
            }
            "*" - "+" - "?" - "\{" {
                if {$run ne ""} { set run [string range $run 0 end-1] }
                if {$run ne ""} { lappend runs $run; set run "" }
                if {$c eq "\{"} {
                    # An opening brace with no valid bound is an ordinary
                    # char in ARE; modelling that split is not worth it, so
                    # no factor.
                    set close [string first "\}" $pat $i]
                    if {$close < 0} { return $none }
                    set i [expr {$close + 1}]
                } else {
                    incr i
                }
            }
            "." - "^" - "\$" - "\}" - "\]" {
                if {$run ne ""} { lappend runs $run; set run "" }
                incr i
            }
            default {
                if {$depth == 0} {
                    append run $c
                } elseif {$run ne ""} {
                    lappend runs $run
                    set run ""
                }
                incr i
            }
        }
    }
    if {$run ne ""} { lappend runs $run }
    set best ""
    foreach r $runs {
        if {[string length $r] > [string length $best]} { set best $r }
    }
    if {$best eq ""} { return $none }
    return [list [expr {$nocase ? [string tolower $best] : $best}] $nocase]
}

# A test command prefix for $pat: [{*}$cmd $haystack] is 1 when the haystack
# could contain a match, 0 when the missing factor proves it cannot. The
# factor-less pattern gets the always-1 command, keeping the caller's skip
# loop sound without a branch on extractability. Options as for factor.
proc must::filter {args} {
    lassign [must::factor {*}$args] fac fold
    if {$fac eq ""} { return [list must::_any] }
    return [list must::_has $fac $fold]
}

proc must::_any {hay} { return 1 }

proc must::_has {fac fold hay} {
    if {$fold} { set hay [string tolower $hay] }
    return [expr {[string first $fac $hay] >= 0}]
}

# The index just past the bracket expression opening at $i, or -1 when it
# never closes. A ] first (after an optional ^) is literal; a backslash
# escape hides its char (ARE, unlike POSIX, keeps \ special in brackets, so
# \] does not close); and the [: :], [= =], [. .] forms are
# skipped whole - a bare ] inside [.tab.] does not close the bracket.
proc must::_bracket_end {pat i} {
    set n [string length $pat]
    incr i
    if {[string index $pat $i] eq "^"} { incr i }
    if {[string index $pat $i] eq "\]"} { incr i }
    while {$i < $n} {
        set c [string index $pat $i]
        if {$c eq "\\"} { incr i 2; continue }
        if {$c eq "\["} {
            set d [string index $pat [expr {$i + 1}]]
            if {$d in {: = .}} {
                set close [string first "${d}\]" $pat [expr {$i + 2}]]
                if {$close < 0} { return -1 }
                set i [expr {$close + 2}]
                continue
            }
        }
        if {$c eq "\]"} { return [expr {$i + 1}] }
        incr i
    }
    return -1
}
