package require Tcl 9
package require Tk

# ::questlog::ui::LabelsWindow - the bookmarked sessions with what each waits
# on. Rows show the stored label at once; a stale or missing one is handed to
# labels::run and its row updates when the record comes back. Not modal: the
# main window stays usable while claude works.

oo::class create ::questlog::ui::LabelsWindow {
    variable Top Tv Detail Rows Actions Menu

    # actions: the session_actions callbacks {on_move on_bookmark on_rename}
    # the main list's right-click is given, so a row's menu is the list's.
    constructor {parent actions} {
        set Top .qllabels
        set Actions $actions
        set Rows [dict create]
        toplevel $Top
        wm title $Top "Bookmarked sessions"
        wm transient $Top [winfo toplevel $parent]
        wm protocol $Top WM_DELETE_WINDOW [list wm withdraw $Top]

        ttk::frame $Top.f -padding 10
        pack $Top.f -fill both -expand 1

        ttk::frame $Top.f.lf
        pack $Top.f.lf -side top -fill both -expand 1
        set Tv $Top.f.lf.tv
        ttk::treeview $Tv -columns {glyph title project ctx waiting next} \
            -show headings -selectmode browse \
            -yscrollcommand [list $Top.f.lf.sb set]
        foreach {col head w stretch} {
            glyph "" 3 0  title Session 22 0  project Project 16 0
            ctx ctx% 5 0  waiting "Waiting on" 9 0  next "Next step" 40 1
        } {
            $Tv heading $col -text $head -anchor w
            $Tv column $col -anchor w -stretch $stretch \
                -width [expr {$w * [font measure TkDefaultFont 0]}]
        }
        ttk::scrollbar $Top.f.lf.sb -orient vertical -command [list $Tv yview]
        pack $Top.f.lf.sb -side right -fill y
        pack $Tv -side left -fill both -expand 1
        bind $Tv <<TreeviewSelect>> [list [self] show_detail]
        set Menu $Top.menu
        menu $Menu -tearoff 0
        bind $Tv <Button-3> [list [self] popup %x %y %X %Y]

        set Detail $Top.f.detail
        text $Detail -height 6 -width 80 -wrap word -relief flat
        $Detail configure -state disabled
        pack $Detail -side top -fill x -pady {6 6}

        ttk::frame $Top.f.btns
        pack $Top.f.btns -side top -fill x
        ttk::button $Top.f.btns.resume -text Resume -command [list [self] resume]
        ttk::button $Top.f.btns.relabel -text Re-label -command [list [self] relabel]
        pack $Top.f.btns.relabel $Top.f.btns.resume -side right -padx {6 0}
    }

    # members: uuid -> {path cwd}. Replaces the rows, raises the window, and
    # labels whatever is stale.
    method show {members} {
        $Tv delete [$Tv children {}]
        set Rows [dict create]
        dict for {uuid m} $members {
            set path [dict get $m path]
            set rec [::questlog::labels::read $uuid]
            dict set Rows $uuid [dict create path $path cwd [dict get $m cwd] rec $rec]
            $Tv insert {} end -id $uuid
            if {[::questlog::labels::stale $rec $path]} {
                my label $uuid
            } else {
                my redraw $uuid
            }
        }
        wm deiconify $Top
        raise $Top
    }

    method label {uuid} {
        dict set Rows $uuid busy 1
        my redraw $uuid
        ::questlog::labels::run [dict get $Rows $uuid path] $uuid \
            [list [self] on_label]
    }

    method on_label {uuid rec} {
        if {![dict exists $Rows $uuid]} return
        dict set Rows $uuid rec $rec
        dict set Rows $uuid busy 0
        my redraw $uuid
        if {[$Tv selection] eq $uuid} { my show_detail }
    }

    method glyph {uuid} {
        set row [dict get $Rows $uuid]
        if {[dict getdef $row busy 0]} { return ⏳ }
        set rec [dict get $row rec]
        if {[dict getdef $rec status ""] eq "failed"} { return ⚠ }
        return [dict getdef {yes 🟢 ruling 🟡 peer 🔵 nothing ⚪} \
            [dict getdef $rec waiting_on ""] ""]
    }

    method redraw {uuid} {
        set row [dict get $Rows $uuid]
        set rec [dict get $row rec]
        set title [dict getdef $rec title ""]
        if {$title eq ""} { set title [string range $uuid 0 7] }
        set ctx [dict getdef $rec ctx_pct ""]
        $Tv item $uuid -values [list [my glyph $uuid] $title \
            [file tail [dict get $row cwd]] [expr {$ctx eq "" ? "" : "$ctx%"}] \
            [dict getdef $rec waiting_on ""] [dict getdef $rec next_step ""]]
    }

    method show_detail {} {
        set uuid [$Tv selection]
        set text ""
        if {$uuid ne ""} {
            set rec [dict get $Rows $uuid rec]
            foreach {k head} {question Question next_step "Next step"
                              blocker Blocker error Error} {
                set v [dict getdef $rec $k ""]
                if {$v ne ""} { append text "$head: $v\n" }
            }
        }
        $Detail configure -state normal
        $Detail delete 1.0 end
        $Detail insert end [string trimright $text]
        $Detail configure -state disabled
    }

    method popup {x y X Y} {
        set uuid [$Tv identify item $x $y]
        if {$uuid eq ""} return
        $Tv selection set $uuid
        set path [dict get $Rows $uuid path]
        set cwd [dict get $Rows $uuid cwd]
        set ctx [dict merge $Actions [dict create \
            target [dict create path $path uuid $uuid cwd $cwd \
                folder [file tail [file dirname $path]]] \
            parent $Top \
            clipboard {apply {{s} {clipboard clear; clipboard append $s}}}]]
        set state [dict create is_bookmarked [file executable $path] \
            has_cwd [file isdirectory $cwd] has_folder 1]
        ::questlog::ui::session_actions::apply_state $Menu \
            [::questlog::ui::session_actions::populate $Menu $ctx] $state
        tk_popup $Menu $X $Y
    }

    method menu {} { return $Menu }

    method relabel {} {
        set uuid [$Tv selection]
        if {$uuid ne ""} { my label $uuid }
    }

    # The shell command Resume runs for the selected row, "" when none.
    method resume_command {} {
        set uuid [$Tv selection]
        if {$uuid eq ""} { return "" }
        return [::questlog::ui::terminal::resume_command \
            [dict get $Rows $uuid cwd] $uuid]
    }

    method resume {} {
        set uuid [$Tv selection]
        if {$uuid eq ""} return
        ::questlog::ui::terminal::launch_tab [dict get $Rows $uuid cwd] $uuid
    }

    method tree {} { return $Tv }
}
