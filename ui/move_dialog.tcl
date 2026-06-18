package require Tcl 9
package require Tk

# ::questlog::ui::move_dialog - modal picker for the "Move session to another
# project" operation. Lists every folder under ~/.claude/projects/, plus
# a free-text entry for a cwd that has no project folder yet. The single
# entry point `open` takes a callback; the caller routes the chosen cwd
# through ::questlog::path::ensure_project_folder and ::questlog::path::move_session.
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
    variable LiveCb ""        ;# cb: () -> display names of selected sessions
                              ;# that are live right now (empty = none)
    variable LivePoll ""      ;# after-id of the live-state recheck, or ""
    variable LiveNames {}     ;# the names from the last recheck; the confirm guard
}

# live_cb returns the display names of the selected sessions that are running
# right now. A live session cannot be moved (renaming its jsonl would split the
# transcript out from under the running process), so while any are live the
# Move button is disabled and a tip names them. The dialog rechecks on a timer,
# so closing the session in its terminal re-enables Move with no reopen - the
# same live-tracking the rename dialog uses.
proc ::questlog::ui::move_dialog::open {parent count current_folder on_done live_cb} {
    variable Top
    variable Tv
    variable EntryVar
    variable CurrentFolder
    variable OnDone
    variable RowToCwd
    variable LiveCb
    variable LiveNames

    set CurrentFolder $current_folder
    set OnDone $on_done
    set LiveCb $live_cb
    set LiveNames {}
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

    # Tip shown only while a selected session is live: it names the offenders
    # and why Move is blocked. Empty (and zero-height) otherwise.
    ttk::label $Top.f.tip -anchor w -justify left \
        -foreground [::questlog::ui::theme::c muted] \
        -wraplength 380 -text ""
    pack $Top.f.tip -side top -fill x -pady {6 0}

    bind $Tv <Double-Button-1>      ::questlog::ui::move_dialog::confirm
    bind $Tv <<TreeviewSelect>>     ::questlog::ui::move_dialog::on_select
    bind $Top.f.erow.entry <Return> ::questlog::ui::move_dialog::confirm
    bind $Top <Escape>              ::questlog::ui::move_dialog::cancel
    wm protocol $Top WM_DELETE_WINDOW ::questlog::ui::move_dialog::cancel

    populate
    track_live

    grab set $Top
    focus $Tv
}

# Recheck which selected sessions are live and reflect it: Move disabled with a
# naming tip while any are, enabled with no tip once none are. Reschedules until
# the dialog closes, so a session quitting in its terminal re-enables Move.
proc ::questlog::ui::move_dialog::track_live {} {
    variable Top
    variable LiveCb
    variable LivePoll
    variable LiveNames
    if {$Top eq "" || ![winfo exists $Top]} { set LivePoll ""; return }
    set LiveNames [expr {$LiveCb eq "" ? {} : [{*}$LiveCb]}]
    if {[llength $LiveNames] > 0} {
        $Top.f.btn.ok state disabled
        set quoted [lmap n $LiveNames { format {'%s'} $n }]
        set lead [expr {[llength $LiveNames] == 1 \
            ? "This session is still live and cannot be moved" \
            : "These sessions are still live and cannot be moved"}]
        $Top.f.tip configure -text "$lead: [join $quoted {, }]. Close it first."
    } else {
        $Top.f.btn.ok state !disabled
        $Top.f.tip configure -text ""
    }
    set LivePoll [after 300 ::questlog::ui::move_dialog::track_live]
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
    if {$dir eq ""} return
    # Some choosers return the picked folder relative to -initialdir rather
    # than absolute (observed under XWayland). Anchor it back to the start
    # directory we handed in, then normalise, so the entry always holds the
    # absolute path the rest of the dialog requires.
    if {![string match "/*" $dir]} { set dir [file join $start $dir] }
    set EntryVar [file normalize $dir]
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
    variable LiveNames
    # The Treeview double-click and entry Return reach confirm directly, past
    # the disabled button, so the live guard lives here too.
    if {[llength $LiveNames] > 0} { bell; return }
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
    variable LivePoll
    if {$LivePoll ne ""} { after cancel $LivePoll; set LivePoll "" }
    if {$Top ne "" && [winfo exists $Top]} {
        grab release $Top
        destroy $Top
    }
    set Top ""
}
