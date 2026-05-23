package require Tcl 9
package require Tk

# ::csm::ui::Toolbar - the top-of-window controls.
#
# Owns the filter variables. Subscribers receive the full snapshot
# dict whenever any control changes:
#   window     24h | 7d | 30d | all
#   criteria   list of {type regex|read|write|edit  value <string>};
#              empty = no search. AND across all, at session scope.
#   case       0 | 1   (regex matching/highlighting only)
#   cwd_only   0 | 1
#   one_turn   0 | 1   (1 = exclude one-turn sessions, default on)
#   cwd        $env(PWD) at startup; constant after.

namespace eval ::csm::ui {}

# any_criteria snapshot - true iff the snapshot carries at least one
# criterion with a non-empty value. Shared by app.tcl (results-pane
# visibility, search start/cancel) and tree.tcl (CriteriaActive flag).
proc ::csm::ui::any_criteria {snapshot} {
    if {![dict exists $snapshot criteria]} { return 0 }
    foreach c [dict get $snapshot criteria] {
        if {[dict get $c value] ne ""} { return 1 }
    }
    return 0
}

# regex_values snapshot - the values of the regex-type criteria only, for
# the result pane's in-place highlighter. Path criteria are not regex and
# are not highlighted.
proc ::csm::ui::regex_values {snapshot} {
    set out [list]
    if {![dict exists $snapshot criteria]} { return $out }
    foreach c [dict get $snapshot criteria] {
        if {[dict get $c type] eq "regex" && [dict get $c value] ne ""} {
            lappend out [dict get $c value]
        }
    }
    return $out
}

oo::class create ::csm::ui::Toolbar {
    variable Top              ;# parent frame path
    variable WindowVar
    variable CaseVar
    variable CwdOnlyVar
    variable OneTurnVar
    variable RunningOnlyVar
    variable BookmarkedOnlyVar
    variable Cwd
    variable Subscribers
    variable DebounceAfter
    variable Patterns         ;# dict id -> type (regex|read|write|edit); values live in Pat$id ivars
    variable NextId
    variable RowsBox          ;# inner frame holding criterion rows + the add buttons
    variable PopValue         ;# entry var for the criterion add dropdown

    constructor {parent cwd} {
        set Top $parent
        set Cwd $cwd
        set WindowVar  7d
        set CaseVar    0
        set CwdOnlyVar 0
        set OneTurnVar 1
        set RunningOnlyVar    0
        set BookmarkedOnlyVar 0
        set Subscribers [list]
        set DebounceAfter ""
        set Patterns [dict create]
        set NextId 0

        my build
    }

    method build {} {
        ttk::frame $Top

        # Row 1: window radios + cwd-only.
        ttk::frame $Top.row1
        pack $Top.row1 -side top -fill x -padx 4 -pady {4 2}

        ttk::label $Top.row1.win -text "Time:"
        pack $Top.row1.win -side left -padx {0 4}
        foreach w {24h 7d 30d all} {
            ttk::radiobutton $Top.row1.r$w -text $w \
                -variable [my varname WindowVar] -value $w \
                -command [list [self] publish]
            pack $Top.row1.r$w -side left
        }

        ttk::separator $Top.row1.sep1 -orient vertical
        pack $Top.row1.sep1 -side left -fill y -padx 8

        ttk::checkbutton $Top.row1.cwd -text "this cwd only" \
            -variable [my varname CwdOnlyVar] \
            -command [list [self] publish]
        pack $Top.row1.cwd -side left

        # Criteria box: AND-combined list of typed criteria, at session
        # scope. Empty until the user adds one. "Aa" governs regex case;
        # a path criterion matches case-sensitively when the recorded path
        # ends with the typed value (a bare filename matches any directory).
        ttk::labelframe $Top.criteria -text "Criteria (AND)"
        pack $Top.criteria -side top -fill x -padx 4 -pady 2

        ttk::frame $Top.criteria.hdr
        pack $Top.criteria.hdr -side top -fill x
        ttk::checkbutton $Top.criteria.hdr.case -text "Aa" \
            -variable [my varname CaseVar] \
            -command [list [self] publish]
        pack $Top.criteria.hdr.case -side right -padx 4

        set RowsBox $Top.criteria.rows
        ttk::frame $RowsBox
        pack $RowsBox -side top -fill x

        ttk::frame $RowsBox.add
        ttk::button $RowsBox.add.bregex -text "+ regex" \
            -command [list [self] open_add_dropdown regex $RowsBox.add.bregex]
        ttk::button $RowsBox.add.bread -text "+ Read" \
            -command [list [self] open_add_dropdown read $RowsBox.add.bread]
        ttk::button $RowsBox.add.bwrite -text "+ Write" \
            -command [list [self] open_add_dropdown write $RowsBox.add.bwrite]
        ttk::button $RowsBox.add.bedit -text "+ Edit" \
            -command [list [self] open_add_dropdown edit $RowsBox.add.bedit]
        pack $RowsBox.add.bregex $RowsBox.add.bread \
             $RowsBox.add.bwrite $RowsBox.add.bedit -side left -padx {0 4}
        pack $RowsBox.add -side top -anchor w -pady 1

        # Row 2: secondary filter.
        ttk::frame $Top.row2
        pack $Top.row2 -side top -fill x -padx 4 -pady {2 4}
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

        # If the launch cwd has no matching project folder on disk, dim
        # "this cwd only" so the user is not misled.
        set folder [::csm::path::encode_cwd $Cwd]
        set on_disk [file isdirectory [file join [::csm::path::projects_root] $folder]]
        if {$on_disk} {
            set CwdOnlyVar 1
        } else {
            $Top.row1.cwd configure -state disabled
        }
    }

    # Create a typed criterion row and register it. Returns the row id.
    method new_row {type value} {
        incr NextId
        set id $NextId
        my eval [list variable Pat$id ""]
        my eval [list set Pat$id $value]
        set row $RowsBox.r$id
        ttk::frame $row
        ttk::label $row.t -text $type -width 6 -anchor w
        ttk::entry $row.e -textvariable [my varname Pat$id] -width 30
        ttk::button $row.x -text "−" -width 2 \
            -command [list [self] remove_row $id]
        pack $row.t -side left -padx {0 4}
        pack $row.e -side left -fill x -expand 1
        pack $row.x -side left -padx {4 0}
        pack $row -side top -fill x -pady 1 -before $RowsBox.add
        bind $row.e <KeyRelease> [list [self] on_value_change]
        dict set Patterns $id $type
        return $id
    }

    method add_criterion_row {type value} {
        my new_row $type $value
        my publish
    }

    # A dropdown under a + button, anchored to it. For regex it is a single
    # pattern entry. For Read/Write/Edit, Write and Edit also list the launch
    # repo's working-tree changes to pick from, and all three add a file
    # chooser. Every type shares the manual entry and the "add" action;
    # confirming creates the row, which is then edit-or-remove only. Typing
    # happens here, not in a live row, so no search runs per keystroke.
    method open_add_dropdown {type btn} {
        set host [winfo toplevel $Top]
        set pop [expr {$host eq "." ? ".criteriapop" : "$host.criteriapop"}]
        destroy $pop
        ttk::frame $pop -relief solid -borderwidth 1 -padding 4
        set PopValue ""
        if {$type in {write edit}} {
            set files [my git_modified_files]
            if {[llength $files] > 0} {
                set lb $pop.lb
                set n [llength $files]
                listbox $lb -height [expr {$n < 8 ? $n : 8}] -width 48 \
                    -activestyle none
                foreach f $files { $lb insert end $f }
                pack $lb -side top -fill x
                bind $lb <<ListboxSelect>> \
                    [list [self] dropdown_pick_list $type $lb $pop]
                ttk::separator $pop.sep -orient horizontal
                pack $pop.sep -side top -fill x -pady 4
            }
        }
        ttk::frame $pop.row
        ttk::entry $pop.row.e -textvariable [my varname PopValue] -width 40
        ttk::button $pop.row.add -text "add" \
            -command [list [self] dropdown_add_entry $type $pop]
        pack $pop.row.e -side left -fill x -expand 1
        if {$type ne "regex"} {
            ttk::button $pop.row.open -text "open…" \
                -command [list [self] pick_file $type $pop]
            pack $pop.row.open -side left -padx {4 0}
        }
        pack $pop.row.add -side left -padx {4 0}
        pack $pop.row -side top -fill x
        bind $pop.row.e <Return> [list [self] dropdown_add_entry $type $pop]
        bind $pop <Escape> [list destroy $pop]
        set rx [expr {[winfo rootx $btn] - [winfo rootx $host]}]
        set ry [expr {[winfo rooty $btn] - [winfo rooty $host] \
                      + [winfo height $btn]}]
        place $pop -x $rx -y $ry
        raise $pop
        focus $pop.row.e
    }

    method dropdown_pick_list {type lb pop} {
        set sel [$lb curselection]
        if {[llength $sel] == 0} return
        set val [$lb get [lindex $sel 0]]
        destroy $pop
        my add_criterion_row $type $val
    }

    method dropdown_add_entry {type pop} {
        set val [string trim $PopValue]
        destroy $pop
        if {$val ne ""} { my add_criterion_row $type $val }
    }

    method pick_file {type pop} {
        set f [tk_getOpenFile -initialdir $Cwd]
        if {$f eq ""} return
        destroy $pop
        my add_criterion_row $type $f
    }

    # Absolute paths of the launch repo's working-tree changes (modified,
    # added, untracked). Empty when the launch cwd is not a git repo.
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

    method remove_row {id} {
        if {![dict exists $Patterns $id]} return
        destroy $RowsBox.r$id
        dict unset Patterns $id
        my eval [list unset -nocomplain Pat$id]
        # Move focus to the previous remaining row, else the [+] button.
        set remaining [dict keys $Patterns]
        if {[llength $remaining] > 0} {
            set last [lindex $remaining end]
            focus $RowsBox.r$last.e
        } else {
            focus $RowsBox.add.bregex
        }
        my publish
    }

    method on_value_change {} {
        if {$DebounceAfter ne ""} { after cancel $DebounceAfter }
        set DebounceAfter [after 200 [list [self] publish]]
    }

    method snapshot {} {
        set criteria [list]
        foreach id [dict keys $Patterns] {
            set v [my eval [list set Pat$id]]
            if {$v ne ""} {
                lappend criteria \
                    [dict create type [dict get $Patterns $id] value $v]
            }
        }
        return [dict create \
            window   $WindowVar \
            criteria $criteria \
            case     $CaseVar \
            cwd_only $CwdOnlyVar \
            one_turn $OneTurnVar \
            running_only    $RunningOnlyVar \
            bookmarked_only $BookmarkedOnlyVar \
            cwd      $Cwd]
    }

    method subscribe {cb} {
        lappend Subscribers $cb
    }

    method publish {} {
        set snap [my snapshot]
        foreach cb $Subscribers {
            if {[catch {{*}$cb $snap} err]} {
                puts stderr "csm: toolbar subscriber failed: $err"
            }
        }
    }

    method destroy {} {
        if {$DebounceAfter ne ""} { after cancel $DebounceAfter }
        next
    }
}
