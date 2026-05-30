package require Tcl 9
package require Tk

# ::questlog::ui::Toolbar - the top-of-window controls.
#
# Owns the filter state. Subscribers receive the full snapshot dict
# whenever any control changes:
#   window           24h | 7d | 30d | all
#   search           string (user's typed search; empty when blank)
#   search_case      0 | 1   (Aa toggle next to the search field)
#   under            list of absolute paths  (OR within, AND across clauses)
#   read             list of absolute paths
#   wrote            list of absolute paths
#   edited           list of absolute paths
#   pattern          list of regex strings   (case-sensitive, always)
#   under_auto       1 iff `under` is the launch-seeded chip, untouched
#   one_turn         0 | 1   (exclude one-turn sessions)
#   running_only     0 | 1
#   bookmarked_only  0 | 1
#   cwd              launch cwd, constant after startup

namespace eval ::questlog::ui {}

# any_criteria snapshot - true iff the snapshot carries a content-matching
# clause (search text, regex pattern, or a read/wrote/edited path). The
# `under` clause is a row-level scope, not a content match, so it does not
# count here; treating it as a criterion flips sessions.tcl into result-
# index mode and Search.start returns immediately because there is nothing
# to match, leaving the list empty. Shared by app.tcl (search start/cancel)
# and sessions.tcl (CriteriaActive flag: browse versus result-index mode).
proc ::questlog::ui::any_criteria {snapshot} {
    if {[dict exists $snapshot search] && [dict get $snapshot search] ne ""} {
        return 1
    }
    foreach k {read wrote edited pattern} {
        if {[dict exists $snapshot $k] && [llength [dict get $snapshot $k]] > 0} {
            return 1
        }
    }
    return 0
}

# Tokenise the search field's contents. Space-separated; double-quoted runs
# preserve a phrase. Trailing/leading whitespace ignored. Empty input yields
# an empty list.
proc ::questlog::ui::search_terms {s} {
    set out [list]
    set buf ""
    set in_quotes 0
    foreach ch [split $s ""] {
        if {$ch eq "\""} { set in_quotes [expr {!$in_quotes}]; continue }
        if {$ch eq " " && !$in_quotes} {
            if {$buf ne ""} { lappend out $buf; set buf "" }
            continue
        }
        append buf $ch
    }
    if {$buf ne ""} { lappend out $buf }
    return $out
}

# highlight_terms snapshot - terms for the result pane's in-place highlighter
# and the viewer's match index. Returns the tokenised search terms, matched
# literally downstream; the pattern row, while regex-typed, is uncommon and
# not highlighted in this pass.
proc ::questlog::ui::highlight_terms {snapshot} {
    set s ""
    if {[dict exists $snapshot search]} { set s [dict get $snapshot search] }
    return [::questlog::ui::search_terms $s]
}

oo::class create ::questlog::ui::Toolbar {
    variable Top
    variable Cwd
    variable Subscribers
    variable WindowVar
    variable SearchVar
    variable SearchCaseVar
    variable OneTurnVar
    variable RunningOnlyVar
    variable BookmarkedOnlyVar
    variable Clauses          ;# dict kind -> list of values
    variable UnderAuto        ;# 1 iff `under` is exactly the launch-seeded chip
    variable Restrict         ;# the padded content frame holding the restrict rows
    variable RestrictHd       ;# the heading label above that frame (the legend)
    variable AddRail          ;# the "add:" rail frame inside Restrict
    variable RowFrames        ;# dict kind -> widget path (present only when row exists)
    variable PopValue         ;# textvar for the add-dropdown's entry

    constructor {parent cwd} {
        set Top $parent
        set Cwd $cwd
        set WindowVar  7d
        set SearchVar  ""
        set SearchCaseVar 0
        set OneTurnVar 1
        set RunningOnlyVar    0
        set BookmarkedOnlyVar 0
        set Clauses [dict create under {} read {} wrote {} edited {} pattern {}]
        set UnderAuto 0
        set Subscribers [list]
        set RowFrames [dict create]
        set PopValue ""

        my build
    }

    method build {} {
        ttk::frame $Top

        # Search row: label, full-width entry, Aa toggle.
        ttk::frame $Top.search
        pack $Top.search -side top -fill x -padx 6 -pady {6 3}
        ttk::label $Top.search.label -text "Search:"
        pack $Top.search.label -side left -padx {0 6}
        ttk::entry $Top.search.e -textvariable [my varname SearchVar]
        # Placeholder microcopy (Tk 9 ttk entry); a harmless no-op if the build
        # lacks -placeholder.
        catch {$Top.search.e configure \
            -placeholder "type one or more words and press Enter; all must appear somewhere in the session"}
        pack $Top.search.e -side left -fill x -expand 1
        bind $Top.search.e <Return> [list [self] publish]
        ttk::checkbutton $Top.search.aa -text "Aa" \
            -variable [my varname SearchCaseVar] \
            -command [list [self] publish]
        pack $Top.search.aa -side left -padx {6 0}

        # Restrict group: a lightly-bordered box whose first inner line is the
        # heading (the legend sits inside, at the top, as in the design), then
        # the time row, the clause rows, and the add rail.
        ttk::frame $Top.restrict -relief solid -borderwidth 1 -padding {8 5}
        pack $Top.restrict -side top -fill x -padx 6 -pady {2 2}
        set Restrict $Top.restrict
        set RestrictHd $Restrict.hd
        ttk::label $RestrictHd -text "Restrict to sessions that…" -anchor w \
            -foreground [::questlog::theme::c muted]
        pack $RestrictHd -side top -fill x -pady {0 4}

        ttk::frame $Restrict.time
        pack $Restrict.time -side top -fill x -pady {0 3}
        ttk::label $Restrict.time.label -text "time" -width 18 -anchor w
        pack $Restrict.time.label -side left -padx {0 4}
        ttk::label $Restrict.time.rans -text "ran in the last"
        pack $Restrict.time.rans -side left -padx {0 8}
        foreach w {24h 7d 30d all} {
            ttk::radiobutton $Restrict.time.r$w -text $w \
                -variable [my varname WindowVar] -value $w \
                -command [list [self] publish]
            pack $Restrict.time.r$w -side left -padx 2
        }

        set AddRail $Restrict.add
        ttk::frame $AddRail
        pack $AddRail -side top -fill x -pady {4 0}
        ttk::label $AddRail.label -text "add:"
        pack $AddRail.label -side left -padx {0 4}
        foreach {k text} {under "+ folder" pattern "+ regex" read "+ Read" \
                          wrote "+ Write" edited "+ Edit"} {
            ttk::button $AddRail.b$k -text $text \
                -command [list [self] open_add $k]
            pack $AddRail.b$k -side left -padx {0 4}
        }

        # Row 2: legacy result-set filters, unchanged by this refactor.
        ttk::frame $Top.row2
        pack $Top.row2 -side top -fill x -padx 6 -pady {4 6}
        ttk::checkbutton $Top.row2.oneturn -text "exclude one-turn sessions" \
            -variable [my varname OneTurnVar] \
            -command [list [self] publish]
        pack $Top.row2.oneturn -side left
        ttk::checkbutton $Top.row2.running -text "running only" \
            -variable [my varname RunningOnlyVar] \
            -command [list [self] publish]
        pack $Top.row2.running -side left -padx {16 0}
        ttk::checkbutton $Top.row2.booked -text "bookmarked only" \
            -variable [my varname BookmarkedOnlyVar] \
            -command [list [self] publish]
        pack $Top.row2.booked -side left -padx {16 0}
    }

    # ---- public API --------------------------------------------------------

    method subscribe {cb} {
        lappend Subscribers $cb
    }

    method snapshot {} {
        return [dict create \
            window         $WindowVar \
            search         $SearchVar \
            search_case    $SearchCaseVar \
            under          [dict get $Clauses under] \
            read           [dict get $Clauses read] \
            wrote          [dict get $Clauses wrote] \
            edited         [dict get $Clauses edited] \
            pattern        [dict get $Clauses pattern] \
            under_auto     $UnderAuto \
            one_turn       $OneTurnVar \
            running_only   $RunningOnlyVar \
            bookmarked_only $BookmarkedOnlyVar \
            cwd            $Cwd]
    }

    method publish {} {
        set snap [my snapshot]
        foreach cb $Subscribers {
            if {[catch {{*}$cb $snap} err]} {
                puts stderr "questlog: toolbar subscriber failed: $err"
            }
        }
    }

    # Add a value to a clause, creating the row if needed. The first user
    # action on `under` clears the auto-applied flag, since the user is now
    # editing the row.
    method add_value {kind value} {
        set vals [dict get $Clauses $kind]
        if {$value in $vals} return
        lappend vals $value
        dict set Clauses $kind $vals
        if {$kind eq "under"} { set UnderAuto 0 }
        my rebuild_clause_rows
        my refresh_add_rail
        my publish
    }

    method remove_value {kind value} {
        set vals [dict get $Clauses $kind]
        set i [lsearch -exact $vals $value]
        if {$i < 0} return
        set vals [lreplace $vals $i $i]
        dict set Clauses $kind $vals
        if {$kind eq "under"} { set UnderAuto 0 }
        my rebuild_clause_rows
        my refresh_add_rail
        my publish
    }

    method clear_clause {kind} {
        dict set Clauses $kind [list]
        if {$kind eq "under"} { set UnderAuto 0 }
        my rebuild_clause_rows
        my refresh_add_rail
        my publish
    }

    # Seed the `under` row with the launch cwd. Marks UnderAuto so the
    # Show-all banner knows the chip was not user-typed. Any later edit
    # clears the flag.
    method seed_under {path} {
        dict set Clauses under [list $path]
        set UnderAuto 1
        my rebuild_clause_rows
        my refresh_add_rail
        my publish
    }

    # Drop the auto-applied under chip. Used by the "Show all" banner.
    method clear_under_auto {} {
        if {!$UnderAuto} return
        dict set Clauses under [list]
        set UnderAuto 0
        my rebuild_clause_rows
        my refresh_add_rail
        my publish
    }

    # ---- row management ----------------------------------------------------

    # Destroy every clause-row frame and reconstruct the present ones in
    # canonical reading order between the time row and the add rail.
    method rebuild_clause_rows {} {
        foreach k {under read wrote edited pattern} {
            if {[dict exists $RowFrames $k]} {
                destroy [dict get $RowFrames $k]
                dict unset RowFrames $k
            }
        }
        # type -> design criterion colour family (wrote=write, edited=edit,
        # pattern=regex).
        set ctype {under under read read wrote write edited edit pattern regex}
        foreach k {under read wrote edited pattern} {
            set vals [dict get $Clauses $k]
            if {[llength $vals] == 0} continue
            set t [dict get $ctype $k]
            set row $Restrict.row_$k
            ttk::frame $row
            # The type tag is a small tinted pill, colour-coded per type
            # (tk label so -background takes).
            label $row.label -text $t -width 8 -anchor center -padx 4 \
                -borderwidth 1 -relief solid \
                -background [::questlog::theme::c crit_${t}_bg] \
                -foreground [::questlog::theme::c crit_${t}_fg]
            pack $row.label -side left -padx {0 6} -pady 1
            ttk::button $row.x -text "×" -width 2 \
                -command [list [self] clear_clause $k]
            pack $row.x -side right -padx {4 0}
            ttk::frame $row.chips
            pack $row.chips -side left -fill x -expand 1
            my render_chips $k $row.chips
            pack $row -side top -fill x -before $AddRail -pady 1
            dict set RowFrames $k $row
        }
        my refresh_heading
    }

    # Update the restrict heading with a count of active clauses, so the legend
    # reads "Restrict to sessions that…  N active" (count omitted at zero).
    method refresh_heading {} {
        set n 0
        foreach k {under read wrote edited pattern} {
            if {[llength [dict get $Clauses $k]] > 0} { incr n }
        }
        set txt "Restrict to sessions that…"
        if {$n > 0} { append txt "   $n active" }
        $RestrictHd configure -text $txt
    }

    method render_chips {kind chips_frame} {
        set vals [dict get $Clauses $kind]
        set first 1
        set i 0
        foreach v $vals {
            if {!$first} {
                ttk::label $chips_frame.or$i -text "or" \
                    -foreground [::questlog::theme::c chip_or]
                pack $chips_frame.or$i -side left -padx 4
            }
            set chip $chips_frame.c$i
            ttk::frame $chip -borderwidth 1 -relief solid
            ttk::label $chip.t -text [my chip_display $kind $v]
            pack $chip.t -side left -padx {4 0}
            ttk::button $chip.x -text "×" -width 1 \
                -command [list [self] remove_value $kind $v]
            pack $chip.x -side left -padx {2 4}
            pack $chip -side left
            set first 0
            incr i
        }
        ttk::button $chips_frame.add -text "+ or" \
            -command [list [self] open_add $kind]
        pack $chips_frame.add -side left -padx 4
    }

    # Path-kind chips render as ~-abbreviated; pattern and others render raw.
    method chip_display {kind value} {
        if {$kind in {under read wrote edited}} {
            return [::questlog::path::pretty_home $value]
        }
        return $value
    }

    method refresh_add_rail {} {
        foreach k {under pattern read wrote edited} {
            set btn $AddRail.b$k
            if {[llength [dict get $Clauses $k]] > 0} {
                pack forget $btn
            } else {
                pack $btn -side left -padx {0 4}
            }
        }
    }

    # ---- add-value dropdown ------------------------------------------------

    # Dropdown anchored under the triggering button (either an add-rail
    # button or a chip-row's inline "+ or" button). For under/read/wrote/edited
    # the user can pick from the launch repo's working-tree changes (where
    # applicable) or open a file picker. For pattern the entry is the only
    # input.
    method open_add {kind} {
        set host [winfo toplevel $Top]
        set pop [expr {$host eq "." ? ".addpop" : "$host.addpop"}]
        destroy $pop
        ttk::frame $pop -relief solid -borderwidth 1 -padding 4
        set PopValue ""

        if {$kind in {wrote edited}} {
            set files [my git_modified_files]
            if {[llength $files] > 0} {
                set lb $pop.lb
                set n [llength $files]
                listbox $lb -height [expr {$n < 8 ? $n : 8}] -width 48 \
                    -activestyle none
                foreach f $files { $lb insert end $f }
                pack $lb -side top -fill x
                bind $lb <<ListboxSelect>> \
                    [list [self] dropdown_pick $kind $lb $pop]
                ttk::separator $pop.sep -orient horizontal
                pack $pop.sep -side top -fill x -pady 4
            }
        }

        ttk::frame $pop.row
        ttk::entry $pop.row.e -textvariable [my varname PopValue] -width 40
        pack $pop.row.e -side left -fill x -expand 1
        if {$kind in {under read wrote edited}} {
            ttk::button $pop.row.open -text "open…" \
                -command [list [self] pick_file $kind $pop]
            pack $pop.row.open -side left -padx {4 0}
        }
        ttk::button $pop.row.add -text "add" \
            -command [list [self] dropdown_add_entry $kind $pop]
        pack $pop.row.add -side left -padx {4 0}
        pack $pop.row -side top -fill x
        bind $pop.row.e <Return> [list [self] dropdown_add_entry $kind $pop]
        bind $pop <Escape> [list destroy $pop]

        set btn [my anchor_widget $kind]
        set rx [expr {[winfo rootx $btn] - [winfo rootx $host]}]
        set ry [expr {[winfo rooty $btn] - [winfo rooty $host] \
                      + [winfo height $btn]}]
        place $pop -x $rx -y $ry
        raise $pop
        focus $pop.row.e
    }

    # Anchor for the dropdown: the add-rail chip-button if no row exists,
    # otherwise the row's inline "+ or" button.
    method anchor_widget {kind} {
        if {[dict exists $RowFrames $kind]} {
            return [dict get $RowFrames $kind].chips.add
        }
        return $AddRail.b$kind
    }

    method dropdown_pick {kind lb pop} {
        set sel [$lb curselection]
        if {[llength $sel] == 0} return
        set val [$lb get [lindex $sel 0]]
        destroy $pop
        my add_value $kind $val
    }

    method dropdown_add_entry {kind pop} {
        set val [string trim $PopValue]
        destroy $pop
        if {$val ne ""} { my add_value $kind $val }
    }

    method pick_file {kind pop} {
        set f [tk_getOpenFile -initialdir $Cwd]
        if {$f eq ""} return
        destroy $pop
        my add_value $kind $f
    }

    method git_modified_files {} {
        if {[catch {exec git -C $Cwd rev-parse --show-toplevel} root]} {
            return [list]
        }
        set root [string trim $root]
        if {[catch {exec git -C $Cwd status --porcelain} out]} { return [list] }
        set files [list]
        foreach line [split $out \n] {
            if {$line eq ""} continue
            set rest [string range $line 3 end]
            if {[regexp {.* -> (.*)} $rest -> renamed]} { set rest $renamed }
            lappend files [file join $root $rest]
        }
        return $files
    }

}
