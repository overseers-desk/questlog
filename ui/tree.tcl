package require Tcl 9
package require Tk

# ::csm::ui::Tree - the project / session tree pane.
#
# Two levels: project folders, sessions. Folders are inserted on demand
# in the order rows arrive - which equals mtime-DESC order because the
# Scan coroutine pre-sorts its path list. Sessions appear under their
# folder in arrival order.
#
# The tree does not hold a reference to Scan directly. Two callbacks
# from app.tcl give it the resolve-folder display path and the per-path
# lookup it needs (for right-click-menu metadata).
#
# iid scheme:
#   folder iid:   F:<folder-basename>
#   session iid:  S:<jsonl-path>

oo::class create ::csm::ui::Tree {
    variable Top
    variable Tv
    variable Snapshot
    variable RegexActive
    variable MatchedSessions
    variable ResolveFolder    ;# cb: folder -> display path
    variable LookupSession    ;# cb: path -> row dict
    variable OnSelect
    variable OnOpen
    variable OnScopeChange    ;# cb: type key -> publish results-pane scope
    variable Menu
    variable MenuTarget
    variable FolderCount      ;# dict fiid -> int (number of inserted sessions)
    variable FolderBytes      ;# dict fiid -> int (sum of inserted sessions' sizes)

    constructor {parent resolve_cb lookup_cb on_select on_open on_scope_change} {
        set Top $parent
        set ResolveFolder $resolve_cb
        set LookupSession $lookup_cb
        set OnSelect $on_select
        set OnOpen   $on_open
        set OnScopeChange $on_scope_change
        set Snapshot [dict create]
        set MatchedSessions [dict create]
        set RegexActive 0
        set FolderCount [dict create]
        set FolderBytes [dict create]

        my build
    }

    method build {} {
        ttk::frame $Top
        set Tv $Top.tv
        ttk::treeview $Tv -columns {when size} -show {tree headings} \
            -yscrollcommand [list $Top.sb set]
        $Tv heading #0   -text "Sessions"
        $Tv heading when -text "When"
        $Tv heading size -text "Size"
        $Tv column  #0   -anchor w -stretch 1
        $Tv column  when -anchor w -stretch 0 -width 130
        # Size column wide enough to always show the widest formatted value
        # (e.g. "999.9 G") with cell padding - avoids silent clipping that
        # leaves the user staring at a stray "8" with no unit.
        set f [ttk::style lookup Treeview -font]
        if {$f eq ""} { set f TkDefaultFont }
        set sw [expr {[font measure $f "  999.9 G  "]}]
        $Tv column  size -anchor e -stretch 0 -width $sw -minwidth $sw

        ttk::scrollbar $Top.sb -orient vertical -command [list $Tv yview]

        grid $Tv      -row 0 -column 0 -sticky nsew
        grid $Top.sb  -row 0 -column 1 -sticky ns
        grid columnconfigure $Top 0 -weight 1
        grid rowconfigure    $Top 0 -weight 1

        bind $Tv <<TreeviewSelect>> [list [self] on_select]
        bind $Tv <Double-Button-1>  [list [self] on_double]
        bind $Tv <Button-3>         [list [self] on_right %X %Y %x %y]

        my build_menu
    }

    method build_menu {} {
        set Menu $Top.menu
        # tk::menu has no ttk equivalent.
        menu $Menu -tearoff 0
        $Menu add command -label "Open in viewer"          -command [list [self] menu_open]
        $Menu add separator
        $Menu add command -label "Copy resume command"     -command [list [self] menu_copy_resume]
        $Menu add command -label "Copy session id"         -command [list [self] menu_copy_uuid]
        $Menu add command -label "Copy session path"       -command [list [self] menu_copy_path]
        $Menu add command -label "Copy last assistant output" \
            -command [list [self] menu_copy_last_assistant]
        $Menu add separator
        $Menu add command -label "Resume in new terminal tab" \
            -command [list [self] menu_resume 0]
        $Menu add command -label "Resume forked"           -command [list [self] menu_resume 1]
        $Menu add separator
        $Menu add command -label "Reveal folder"           -command [list [self] menu_reveal]
    }

    # apply_filter snapshot - clear the tree, set state for the new
    # window. Rows will arrive via on_scan_row (or update_match while a
    # search is active).
    method apply_filter {snapshot} {
        set Snapshot $snapshot
        set RegexActive [::csm::ui::any_pattern $snapshot]
        set MatchedSessions [dict create]
        set FolderCount [dict create]
        set FolderBytes [dict create]
        $Tv delete [$Tv children {}]
    }

    # on_scan_row row - called by app on every row Scan publishes. Insert
    # the session under its folder, creating the folder if not yet
    # present. In regex-active mode, only insert sessions that have
    # matched the user regex (tracked in MatchedSessions).
    method on_scan_row {row} {
        # Apply current snapshot filters.
        if {![my row_matches_snapshot $row]} return
        set path [dict get $row path]
        set folder [dict get $row folder]
        if {$RegexActive && ![dict exists $MatchedSessions $path]} return
        my ensure_folder $folder
        my insert_session $folder $row
    }

    method row_matches_snapshot {row} {
        set window [my dict_or $Snapshot window 7d]
        set one_turn [my dict_or $Snapshot one_turn 1]
        set cwd_only [my dict_or $Snapshot cwd_only 0]
        set cwd      [my dict_or $Snapshot cwd ""]
        set cutoff 0
        if {$window ne "all"} {
            set hours [dict get {24h 24 7d 168 30d 720} $window]
            set cutoff [expr {[clock seconds] - $hours*3600}]
        }
        if {[dict get $row mtime] <= $cutoff} { return 0 }
        if {$one_turn && ![dict get $row is_multi]} { return 0 }
        if {$cwd_only && $cwd ne ""} {
            set cwd_folder [::csm::path::encode_cwd $cwd]
            if {[dict get $row folder] ne $cwd_folder} { return 0 }
        }
        return 1
    }

    method ensure_folder {folder} {
        set fiid F:$folder
        if {[$Tv exists $fiid]} return
        set label [::csm::path::pretty_home [{*}$ResolveFolder $folder]]
        $Tv insert {} end -id $fiid -text $label -values [list "" ""] -open 0
        dict set FolderCount $fiid 0
        dict set FolderBytes $fiid 0
    }

    method render_folder {fiid} {
        set n [dict get $FolderCount $fiid]
        set b [dict get $FolderBytes $fiid]
        if {$n > 0} {
            $Tv item $fiid -values [list "($n)" [my fmt_size $b]]
        } else {
            $Tv item $fiid -values [list "" ""]
        }
    }

    method insert_session {folder row} {
        set path [dict get $row path]
        set siid S:$path
        if {[$Tv exists $siid]} return
        set label [my session_label $row]
        set when  [my fmt_time [dict get $row mtime]]
        set bytes [dict get $row size]
        $Tv insert F:$folder end -id $siid -text $label \
            -values [list $when [my fmt_size $bytes]]
        set fiid F:$folder
        dict incr FolderCount $fiid 1
        dict incr FolderBytes $fiid $bytes
        my render_folder $fiid
    }

    method session_label {row} {
        set body [dict get $row first_user]
        if {$body eq ""} {
            set body [dict get $row uuid]
        }
        return $body
    }

    method fmt_time {epoch} {
        if {$epoch eq "" || $epoch == 0} { return "" }
        return [clock format $epoch -format "%a %d %b %H:%M"]
    }

    method fmt_size {bytes} {
        if {$bytes eq "" || $bytes == 0} { return "" }
        if {$bytes < 1024}        { return "${bytes} B" }
        if {$bytes < 1048576}     { return "[expr {$bytes / 1024}] K" }
        if {$bytes < 1073741824}  { return "[format %.1f [expr {$bytes / 1048576.0}]] M" }
        return "[format %.1f [expr {$bytes / 1073741824.0}]] G"
    }

    # Streaming match update from Search. is_first means the session is
    # newly matched; subsequent matches in the same session add to the
    # result pane only.
    method update_match {is_first path lineoff ts content folder} {
        if {!$is_first} return
        if {[dict exists $MatchedSessions $path]} return
        dict set MatchedSessions $path 1
        my ensure_folder $folder
        set siid S:$path
        if {[$Tv exists $siid]} return
        set row [{*}$LookupSession $path]
        if {$row eq ""} return
        my insert_session $folder $row
    }

    method on_select {} {
        set sel [$Tv selection]
        if {[llength $sel] == 0} {
            {*}$OnScopeChange none ""
            return
        }
        set iid [lindex $sel 0]
        if {[string match "S:*" $iid]} {
            set path [string range $iid 2 end]
            {*}$OnSelect $path
            {*}$OnScopeChange session $path
        } elseif {[string match "F:*" $iid]} {
            set folder [string range $iid 2 end]
            {*}$OnScopeChange folder $folder
        }
    }

    method on_double {} {
        set sel [$Tv selection]
        if {[llength $sel] == 0} return
        set iid [lindex $sel 0]
        if {[string match "S:*" $iid]} {
            set path [string range $iid 2 end]
            {*}$OnOpen $path
        }
    }

    method on_right {X Y x y} {
        set iid [$Tv identify item $x $y]
        if {$iid eq "" || ![string match "S:*" $iid]} return
        $Tv selection set $iid
        $Tv focus $iid
        set path [string range $iid 2 end]
        set row [{*}$LookupSession $path]
        if {$row eq ""} return
        set folder [dict get $row folder]
        set uuid   [dict get $row uuid]
        set cwd_hint [dict get $row cwd_hint]
        set cwd [expr {$cwd_hint ne "" ? $cwd_hint : [{*}$ResolveFolder $folder]}]
        set MenuTarget [list path $path uuid $uuid cwd $cwd folder $folder]
        tk_popup $Menu $X $Y
    }

    method menu_target_get {key} { return [dict get $MenuTarget $key] }

    method menu_open {} {
        {*}$OnOpen [my menu_target_get path]
    }

    method menu_copy_resume {} {
        my clipboard_set [::csm::terminal::resume_command \
            [my menu_target_get cwd] [my menu_target_get uuid]]
    }

    method menu_copy_uuid {} { my clipboard_set [my menu_target_get uuid] }
    method menu_copy_path {} { my clipboard_set [my menu_target_get path] }

    method menu_copy_last_assistant {} {
        my clipboard_set [::csm::jsonl::last_assistant_text \
            [my menu_target_get path]]
    }

    method menu_resume {fork} {
        ::csm::terminal::launch_tab \
            [my menu_target_get cwd] \
            [my menu_target_get uuid] \
            $fork
    }

    method menu_reveal {} {
        set folder [my menu_target_get folder]
        set dir [file join [::csm::path::projects_root] $folder]
        if {[catch {exec xdg-open $dir &} err]} {
            puts stderr "csm: xdg-open failed: $err"
        }
    }

    method clipboard_set {s} {
        clipboard clear
        clipboard append $s
    }

    method select_path {path} {
        set siid S:$path
        if {![$Tv exists $siid]} {
            set row [{*}$LookupSession $path]
            if {$row eq ""} return
            my ensure_folder [dict get $row folder]
            my insert_session [dict get $row folder] $row
        }
        if {[$Tv exists $siid]} {
            $Tv see $siid
            $Tv selection set $siid
            $Tv focus $siid
        }
    }

    method dict_or {d k default} {
        if {[dict exists $d $k]} { return [dict get $d $k] }
        return $default
    }
}
