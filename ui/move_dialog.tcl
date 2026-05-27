package require Tcl 9
package require Tk

# ::questlog::ui::move_dialog - modal picker for the "Move session to another
# project" operation. Lists every folder under ~/.claude/projects/, plus
# a free-text entry for a cwd that has no project folder yet. The single
# entry point `open` takes a callback; the caller routes the chosen cwd
# through ::questlog::path::ensure_project_folder and ::questlog::move::session.
#
# Single-instance: only one move dialog is open at a time (modal). Held
# in namespace vars rather than a class because there is no joint
# state across operations and no long-lived identity to track.

namespace eval ::questlog::ui::move_dialog {
    variable Top ""
    variable Tv ""
    variable EntryVar ""
    variable CurrentFolder ""
    variable OnDone ""
    variable RowToCwd [dict create]
}

proc ::questlog::ui::move_dialog::open {parent count current_folder on_done} {
    variable Top
    variable Tv
    variable EntryVar
    variable CurrentFolder
    variable OnDone
    variable RowToCwd

    set CurrentFolder $current_folder
    set OnDone $on_done
    set EntryVar ""
    set RowToCwd [dict create]

    set Top .fms_movedlg
    if {[winfo exists $Top]} { destroy $Top }
    toplevel $Top
    wm title $Top "Move session"
    wm transient $Top [winfo toplevel $parent]

    ttk::frame $Top.f -padding 10
    pack $Top.f -fill both -expand 1

    set noun [expr {$count == 1 ? "session" : "sessions"}]
    ttk::label $Top.f.src -text "Move $count $noun to:"
    pack $Top.f.src -side top -anchor w -pady {0 6}

    ttk::frame $Top.f.lf
    pack $Top.f.lf -side top -fill both -expand 1
    set Tv $Top.f.lf.tv
    ttk::treeview $Tv -columns {} -show {tree} -selectmode browse \
        -yscrollcommand [list $Top.f.lf.sb set]
    $Tv column #0 -anchor w -stretch 1 -width 400
    ttk::scrollbar $Top.f.lf.sb -orient vertical -command [list $Tv yview]
    grid $Tv          -row 0 -column 0 -sticky nsew
    grid $Top.f.lf.sb -row 0 -column 1 -sticky ns
    grid columnconfigure $Top.f.lf 0 -weight 1
    grid rowconfigure    $Top.f.lf 0 -weight 1

    ttk::label $Top.f.elbl -text "Or enter a directory:"
    pack $Top.f.elbl -side top -anchor w -pady {8 2}
    ttk::frame $Top.f.erow
    pack $Top.f.erow -side top -fill x
    ttk::entry $Top.f.erow.entry -textvariable ::questlog::ui::move_dialog::EntryVar
    ttk::button $Top.f.erow.browse -text "Browse..." \
        -command ::questlog::ui::move_dialog::browse
    pack $Top.f.erow.browse -side right -padx {6 0}
    pack $Top.f.erow.entry -side left -fill x -expand 1

    ttk::frame $Top.f.btn
    pack $Top.f.btn -side top -fill x -pady {10 0}
    ttk::button $Top.f.btn.cancel -text "Cancel" \
        -command ::questlog::ui::move_dialog::cancel
    ttk::button $Top.f.btn.ok -text "Move" \
        -command ::questlog::ui::move_dialog::confirm
    pack $Top.f.btn.ok     -side right
    pack $Top.f.btn.cancel -side right -padx {0 6}

    bind $Tv <Double-Button-1>      ::questlog::ui::move_dialog::confirm
    bind $Tv <<TreeviewSelect>>     ::questlog::ui::move_dialog::on_select
    bind $Top.f.erow.entry <Return> ::questlog::ui::move_dialog::confirm
    bind $Top <Escape>              ::questlog::ui::move_dialog::cancel
    wm protocol $Top WM_DELETE_WINDOW ::questlog::ui::move_dialog::cancel

    populate

    grab set $Top
    focus $Tv
}

proc ::questlog::ui::move_dialog::populate {} {
    variable Tv
    variable CurrentFolder
    variable RowToCwd
    # One row per real directory on disk that the folder basename could
    # decode to. Folders whose original directory no longer exists (the
    # "black hole" case) are skipped: moving into them would point a
    # resume command at nothing. ResolveFolder is intentionally bypassed
    # here; the dialog wants ground truth from the filesystem rather
    # than a cache that may have been seeded by an honest scan in the
    # current process.
    set seq 0
    foreach folder [::questlog::path::list_all_projects] {
        if {$folder eq $CurrentFolder} continue
        set cwds [::questlog::path::candidate_cwds_for $folder]
        foreach cwd $cwds {
            set iid [format "F:%d" [incr seq]]
            set label [::questlog::path::pretty_home $cwd]
            $Tv insert {} end -id $iid -text $label
            dict set RowToCwd $iid $cwd
        }
    }
}

# Pick a destination directory through the system folder chooser and
# prefill the entry with it. The chooser opens at the currently-entered
# directory when that is a real one (e.g. a list row was selected), else
# at the home directory.
proc ::questlog::ui::move_dialog::browse {} {
    variable Top
    variable EntryVar
    set start [string trim $EntryVar]
    if {![file isdirectory $start]} { set start $::env(HOME) }
    set dir [tk_chooseDirectory -parent $Top -mustexist 1 \
                 -title "Choose destination directory" -initialdir $start]
    if {$dir ne ""} { set EntryVar $dir }
}

proc ::questlog::ui::move_dialog::on_select {} {
    variable Tv
    variable EntryVar
    variable RowToCwd
    set sel [$Tv selection]
    if {[llength $sel] == 0} return
    set iid [lindex $sel 0]
    if {[dict exists $RowToCwd $iid]} {
        set EntryVar [dict get $RowToCwd $iid]
    }
}

proc ::questlog::ui::move_dialog::confirm {} {
    variable Top
    variable Tv
    variable EntryVar
    variable RowToCwd
    variable OnDone
    set cwd [string trim $EntryVar]
    if {$cwd eq ""} {
        set sel [$Tv selection]
        if {[llength $sel] == 0} return
        set cwd [dict get $RowToCwd [lindex $sel 0]]
    }
    if {![string match "/*" $cwd]} {
        tk_messageBox -parent $Top -icon error -title "Move session" \
            -message "Destination must be an absolute path."
        return
    }
    set cb $OnDone
    close_dialog
    {*}$cb $cwd
}

proc ::questlog::ui::move_dialog::cancel {} {
    close_dialog
}

proc ::questlog::ui::move_dialog::close_dialog {} {
    variable Top
    if {$Top ne "" && [winfo exists $Top]} {
        grab release $Top
        destroy $Top
    }
    set Top ""
}
