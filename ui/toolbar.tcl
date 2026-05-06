package require Tcl 9
package require Tk

# ::csm::ui::Toolbar - the top-of-window controls.
#
# Owns the filter variables. Subscribers receive the full snapshot
# dict whenever any control changes:
#   window     24h | 7d | 30d | all
#   regex      list of pattern strings (empty list = no search; AND across all)
#   case       0 | 1
#   cwd_only   0 | 1
#   one_turn   0 | 1   (1 = exclude one-turn sessions, default on)
#   cwd        $env(PWD) at startup; constant after.

namespace eval ::csm::ui {}

# any_pattern snapshot - true iff the snapshot carries at least one
# non-empty regex pattern. Shared by app.tcl (results-pane visibility,
# search start/cancel) and tree.tcl (RegexActive flag).
proc ::csm::ui::any_pattern {snapshot} {
    if {![dict exists $snapshot regex]} { return 0 }
    foreach p [dict get $snapshot regex] { if {$p ne ""} { return 1 } }
    return 0
}

oo::class create ::csm::ui::Toolbar {
    variable Top              ;# parent frame path
    variable WindowVar
    variable CaseVar
    variable CwdOnlyVar
    variable OneTurnVar
    variable Cwd
    variable Subscribers
    variable DebounceAfter
    variable Patterns         ;# dict id -> "" (presence marker; values live in Pat$id ivars)
    variable NextId
    variable RowsBox          ;# inner frame holding pattern rows + the [+] button

    constructor {parent cwd} {
        set Top $parent
        set Cwd $cwd
        set WindowVar  7d
        set CaseVar    0
        set CwdOnlyVar 0
        set OneTurnVar 1
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

        # Regex box: AND-combined list of patterns. Empty until user clicks +.
        ttk::labelframe $Top.regexbox -text "Regex (AND)"
        pack $Top.regexbox -side top -fill x -padx 4 -pady 2

        ttk::frame $Top.regexbox.hdr
        pack $Top.regexbox.hdr -side top -fill x
        ttk::checkbutton $Top.regexbox.hdr.case -text "Aa" \
            -variable [my varname CaseVar] \
            -command [list [self] publish]
        pack $Top.regexbox.hdr.case -side right -padx 4

        set RowsBox $Top.regexbox.rows
        ttk::frame $RowsBox
        pack $RowsBox -side top -fill x

        ttk::button $RowsBox.add -text "+" -width 2 \
            -command [list [self] add_row]
        pack $RowsBox.add -side top -anchor w -pady 1

        # Row 2: secondary filter.
        ttk::frame $Top.row2
        pack $Top.row2 -side top -fill x -padx 4 -pady {2 4}
        ttk::checkbutton $Top.row2.oneturn -text "exclude one-turn sessions" \
            -variable [my varname OneTurnVar] \
            -command [list [self] publish]
        pack $Top.row2.oneturn -side left

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

    method add_row {{initial ""}} {
        incr NextId
        set id $NextId
        my eval [list variable Pat$id ""]
        if {$initial ne ""} { my eval [list set Pat$id $initial] }
        set row $RowsBox.r$id
        ttk::frame $row
        ttk::entry $row.e -textvariable [my varname Pat$id] -width 30
        ttk::button $row.x -text "−" -width 2 \
            -command [list [self] remove_row $id]
        pack $row.e -side left -fill x -expand 1
        pack $row.x -side left -padx {4 0}
        pack $row -side top -fill x -pady 1 -before $RowsBox.add
        bind $row.e <KeyRelease> [list [self] on_regex_change]
        dict set Patterns $id ""
        if {$initial eq ""} { focus $row.e }
        my publish
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
            focus $RowsBox.add
        }
        my publish
    }

    method on_regex_change {} {
        if {$DebounceAfter ne ""} { after cancel $DebounceAfter }
        set DebounceAfter [after 200 [list [self] publish]]
    }

    method snapshot {} {
        set patterns [list]
        foreach id [dict keys $Patterns] {
            set v [my eval [list set Pat$id]]
            if {$v ne ""} { lappend patterns $v }
        }
        return [dict create \
            window   $WindowVar \
            regex    $patterns \
            case     $CaseVar \
            cwd_only $CwdOnlyVar \
            one_turn $OneTurnVar \
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
