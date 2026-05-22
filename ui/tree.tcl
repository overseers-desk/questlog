package require Tcl 9
package require Tk

# Glyphs for the status column. The single home for both markers; the
# toolbar toggles are plain text, so these characters live only here.
namespace eval ::csm::ui {
    variable GLYPH_RUNNING  ●
    variable GLYPH_BOOKMARK ★
}

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
    variable CriteriaActive
    variable MatchedSessions
    variable ResolveFolder    ;# cb: folder -> display path
    variable LookupSession    ;# cb: path -> row dict
    variable OnSelect
    variable OnOpen
    variable OnScopeChange    ;# cb: type key -> publish results-pane scope
    variable OnMoveRequest    ;# cb: path -> open picker
    variable OnDropMove       ;# cb: path folder -> direct move
    variable Menu
    variable MenuTarget
    variable MenuPaths        ;# list of selected session paths the menu acts on
    variable PressIid         ;# session iid pressed; resolves a suppressed click
    variable PressBroke       ;# 1 when on_press suppressed the class selection
    variable FolderCount      ;# dict fiid -> int (number of inserted sessions)
    variable FolderBytes      ;# dict fiid -> int (sum of inserted sessions' sizes)
    variable RunningSet       ;# dict uuid -> 1, replaced wholesale each tick
    variable OnBookmarkToggle ;# cb: path -> flip the +x bookmark bit
    variable OnScanPath       ;# cb: path -> row (synchronous single-file scan)
    variable OpenMenuIndex
    variable MoveMenuIndex
    variable BookmarkMenuIndex

    constructor {parent resolve_cb lookup_cb on_select on_open on_scope_change \
                 on_move_request on_drop_move on_bookmark_toggle on_scan_path} {
        set Top $parent
        set ResolveFolder $resolve_cb
        set LookupSession $lookup_cb
        set OnSelect $on_select
        set OnOpen   $on_open
        set OnScopeChange $on_scope_change
        set OnMoveRequest $on_move_request
        set OnDropMove $on_drop_move
        set OnBookmarkToggle $on_bookmark_toggle
        set OnScanPath $on_scan_path
        set Snapshot [dict create]
        set MatchedSessions [dict create]
        set CriteriaActive 0
        set FolderCount [dict create]
        set FolderBytes [dict create]
        set RunningSet [dict create]
        set MenuPaths [list]
        set PressBroke 0
        set PressIid ""

        my build
    }

    method build {} {
        ttk::frame $Top
        set Tv $Top.tv
        ttk::treeview $Tv -columns {flags when size} -show {tree headings} \
            -selectmode extended -yscrollcommand [list $Top.sb set]
        $Tv heading #0    -text "Sessions"
        $Tv heading flags -text "⚑"
        $Tv heading when  -text "When"
        $Tv heading size  -text "Size"
        $Tv column  #0    -anchor w -stretch 1
        set f [ttk::style lookup Treeview -font]
        if {$f eq ""} { set f TkDefaultFont }
        # Status column: both glyphs plus padding, never clipped.
        set gw [expr {[font measure $f "  ●★  "]}]
        $Tv column  flags -anchor center -stretch 0 -width $gw -minwidth $gw
        $Tv column  when  -anchor w -stretch 0 -width 130
        # Size column wide enough to always show the widest formatted value
        # (e.g. "999.9 G") with cell padding - avoids silent clipping that
        # leaves the user staring at a stray "8" with no unit.
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
        bind $Tv <ButtonPress-1>    [list [self] on_press %s %X %Y %x %y]
        bind $Tv <B1-Motion>        [list ::csm::ui::drag::motion %X %Y]
        bind $Tv <ButtonRelease-1>  [list [self] on_release %X %Y]

        my build_menu
    }

    method build_menu {} {
        set Menu $Top.menu
        # tk::menu has no ttk equivalent.
        menu $Menu -tearoff 0
        # Open and Move carry the selection count in their label when a
        # group is selected, so they are addressed by stored index (the
        # label is not stable across popups), as the bookmark entry is.
        $Menu add command -label "Open in viewer"          -command [list [self] menu_open]
        set OpenMenuIndex [$Menu index end]
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
        $Menu add command -label "Move to..."              -command [list [self] menu_move]
        set MoveMenuIndex [$Menu index end]
        $Menu add command -label "Reveal folder"           -command [list [self] menu_reveal]
        $Menu add separator
        # Label is rewritten per-target in on_right (Add/Remove bookmark),
        # so it is addressed by stored index, not by its (changing) label.
        $Menu add command -label "Bookmark" -command [list [self] menu_bookmark]
        set BookmarkMenuIndex [$Menu index end]
    }

    # apply_filter snapshot - clear the tree, set state for the new
    # window. Rows will arrive via on_scan_row (or update_match while a
    # search is active).
    method apply_filter {snapshot} {
        set Snapshot $snapshot
        set CriteriaActive [::csm::ui::any_criteria $snapshot]
        set MatchedSessions [dict create]
        set FolderCount [dict create]
        set FolderBytes [dict create]
        $Tv delete [$Tv children {}]
    }

    # on_scan_row row - called by app on every row Scan publishes. Insert
    # the session under its folder, creating the folder if not yet
    # present. When criteria are active, only insert sessions that have
    # matched (tracked in MatchedSessions).
    method on_scan_row {row} {
        # Under running-only the reconciler is the sole authority for what
        # is displayed; suppress the streaming insert. Rows is still
        # populated (publish_row ran before this callback fired).
        if {[my dict_or $Snapshot running_only 0]} return
        # Apply current snapshot filters.
        if {![my row_matches_snapshot $row]} return
        set path [dict get $row path]
        set folder [dict get $row folder]
        if {$CriteriaActive && ![dict exists $MatchedSessions $path]} return
        my ensure_folder $folder
        my insert_session $folder $row
    }

    method row_matches_snapshot {row} {
        set window [my dict_or $Snapshot window 7d]
        set one_turn [my dict_or $Snapshot one_turn 1]
        set cwd_only [my dict_or $Snapshot cwd_only 0]
        set cwd      [my dict_or $Snapshot cwd ""]
        set bookmarked_only [my dict_or $Snapshot bookmarked_only 0]
        set bk [my dict_or $row bookmarked 0]
        if {$bookmarked_only && !$bk} { return 0 }
        set cutoff 0
        if {$window ne "all"} {
            set hours [dict get {24h 24 7d 168 30d 720} $window]
            set cutoff [expr {[clock seconds] - $hours*3600}]
        }
        # A bookmark pins the row past the time window.
        if {[dict get $row mtime] <= $cutoff && !$bk} { return 0 }
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
        set label [::csm::path::display_label [{*}$ResolveFolder $folder] $folder]
        $Tv insert {} end -id $fiid -text $label -values [list "" "" ""] -open 0
        dict set FolderCount $fiid 0
        dict set FolderBytes $fiid 0
    }

    method render_folder {fiid} {
        set n [dict get $FolderCount $fiid]
        set b [dict get $FolderBytes $fiid]
        if {$n > 0} {
            $Tv item $fiid -values [list "" "($n)" [my fmt_size $b]]
        } else {
            $Tv item $fiid -values [list "" "" ""]
        }
    }

    method insert_session {folder row} {
        set path [dict get $row path]
        set siid S:$path
        if {[$Tv exists $siid]} return
        set label [my session_label $row]
        set when  [my fmt_time [dict get $row mtime]]
        set bytes [dict get $row size]
        set flags [my glyph_cell [dict exists $RunningSet [dict get $row uuid]] \
                       [my dict_or $row bookmarked 0]]
        $Tv insert F:$folder end -id $siid -text $label \
            -values [list $flags $when [my fmt_size $bytes]]
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

    # The status-column string for a row: a pure function of the two
    # flags, never derived by stripping a previous cell value.
    method glyph_cell {running bookmarked} {
        set s ""
        if {$running}    { append s $::csm::ui::GLYPH_RUNNING }
        if {$bookmarked} { append s $::csm::ui::GLYPH_BOOKMARK }
        return $s
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

    # Match-record update from Search. is_first means the session is newly
    # matched; subsequent rows of the same session add to the result pane
    # only, so the tree acts on the first row alone.
    method update_match {match} {
        if {![dict get $match is_first]} return
        set path [dict get $match path]
        if {[dict exists $MatchedSessions $path]} return
        dict set MatchedSessions $path 1
        set folder [dict get $match folder]
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
        set sessions [my selected_session_iids]
        if {[llength $sessions] > 1} {
            {*}$OnSelect "[llength $sessions] sessions selected"
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

    # Session iids (S:*) in the current selection, in tree order. Folder
    # rows the user may have caught in an extended selection are dropped;
    # every group operation works on sessions only.
    method selected_session_iids {} {
        set out [list]
        foreach iid [$Tv selection] {
            if {[string match "S:*" $iid]} { lappend out $iid }
        }
        return $out
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
        # Right-clicking a row outside the selection replaces it with that
        # one row; right-clicking a row already in a multi-selection keeps
        # the whole group so the menu acts on it.
        if {[lsearch -exact [my selected_session_iids] $iid] < 0} {
            $Tv selection set $iid
            $Tv focus $iid
        }
        set MenuPaths [list]
        foreach siid [my selected_session_iids] {
            lappend MenuPaths [string range $siid 2 end]
        }
        set n [llength $MenuPaths]

        # MenuTarget holds the clicked row's metadata for the single-only
        # actions (resume, reveal, copy-resume, copy-last-assistant).
        set path [string range $iid 2 end]
        set row [{*}$LookupSession $path]
        if {$row eq ""} return
        set folder [dict get $row folder]
        set uuid   [dict get $row uuid]
        set cwd [{*}$ResolveFolder $folder]
        set MenuTarget [list path $path uuid $uuid cwd $cwd folder $folder]

        # Single-only entries: meaningless or unwieldy over a group, so
        # disabled while several sessions are selected.
        set single [expr {$n == 1 ? "normal" : "disabled"}]
        foreach lbl {"Copy last assistant output" "Reveal folder"} {
            $Menu entryconfigure $lbl -state $single
        }
        # The resume actions are single-only AND need a real project
        # directory to cd into; disable when the folder cannot be resolved.
        set rstate [expr {($n == 1 && $cwd ne "") ? "normal" : "disabled"}]
        foreach lbl {"Copy resume command" "Resume in new terminal tab" \
                     "Resume forked"} {
            $Menu entryconfigure $lbl -state $rstate
        }

        # Count-bearing labels signal the group size.
        $Menu entryconfigure $OpenMenuIndex -label \
            [expr {$n > 1 ? "Open $n sessions in viewer" : "Open in viewer"}]
        $Menu entryconfigure $MoveMenuIndex -label \
            [expr {$n > 1 ? "Move $n sessions to..." : "Move to..."}]

        # Bookmark drives the whole group to one state. The bits are read
        # fresh so the label matches reality even if it changed out of band.
        $Menu entryconfigure $BookmarkMenuIndex \
            -label [expr {[my all_bookmarked $MenuPaths] \
                              ? "Remove bookmark" : "Add bookmark"}]
        tk_popup $Menu $X $Y
    }

    # 1 when every path is currently bookmarked (the +x bit is set).
    method all_bookmarked {paths} {
        foreach p $paths { if {![file executable $p]} { return 0 } }
        return 1
    }

    method menu_target_get {key} { return [dict get $MenuTarget $key] }

    method menu_open {} {
        foreach p $MenuPaths { {*}$OnOpen $p }
    }

    method menu_copy_resume {} {
        my clipboard_set [::csm::terminal::resume_command \
            [my menu_target_get cwd] [my menu_target_get uuid]]
    }

    method menu_copy_uuid {} {
        set out [list]
        foreach p $MenuPaths { lappend out [my path_uuid $p] }
        my clipboard_set [join $out \n]
    }
    method menu_copy_path {} { my clipboard_set [join $MenuPaths \n] }

    method path_uuid {path} {
        set row [{*}$LookupSession $path]
        if {$row ne "" && [dict exists $row uuid]} { return [dict get $row uuid] }
        return [file rootname [file tail $path]]
    }

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

    method menu_move {} {
        {*}$OnMoveRequest $MenuPaths
    }

    # Drive the whole group to one bookmark state: clear all when all are
    # set, otherwise set all. Only rows whose bit differs from the target
    # are toggled, so the per-path toggle callback reaches the target
    # without flipping already-correct rows. For one selection this is the
    # plain toggle.
    method menu_bookmark {} {
        set target [expr {![my all_bookmarked $MenuPaths]}]
        foreach p $MenuPaths {
            if {[file executable $p] != $target} { {*}$OnBookmarkToggle $p }
        }
    }

    method on_press {state X Y x y} {
        set iid [$Tv identify item $x $y]
        if {![string match "S:*" $iid]} return
        # A modified click (Shift 0x1, Control 0x4) is a selection gesture,
        # not a drag: leave it to the class bindings to extend or toggle.
        if {($state & 0x1) || ($state & 0x4)} return
        set PressBroke 0
        set PressIid ""
        set presel [my selected_session_iids]
        if {[lsearch -exact $presel $iid] >= 0 && [llength $presel] > 1} {
            # Pressing a member of a multi-selection starts a group drag.
            # Suppress the class binding that would collapse the selection
            # to this one row; resolve the click-to-single in on_release if
            # no drag follows.
            set PressBroke 1
            set PressIid $iid
            set paths [list]
            foreach siid $presel { lappend paths [string range $siid 2 end] }
            ::csm::ui::drag::watch $Tv $Tv $X $Y $paths [list [self] handle_drop]
            return -code break
        }
        ::csm::ui::drag::watch $Tv $Tv $X $Y [list [string range $iid 2 end]] \
            [list [self] handle_drop]
    }

    method on_release {X Y} {
        set was_drag [::csm::ui::drag::release $X $Y]
        if {!$was_drag && $PressBroke} {
            $Tv selection set $PressIid
            $Tv focus $PressIid
        }
        set PressBroke 0
        set PressIid ""
    }

    method handle_drop {paths target_folder} {
        {*}$OnDropMove $paths $target_folder
    }

    # Re-key after a successful move. Removes the old S:* iid, decrements
    # the source folder's counters (deleting the folder iid if empty),
    # and rewrites the MatchedSessions key when criteria mode is active so
    # the subsequent on_scan_row reinsert passes the criteria guard.
    # Remove a session row and fix up its folder's counters, deleting the
    # folder when it becomes empty. The single removal path, shared by
    # relocate_session and reconcile_running so the counters never diverge.
    method forget_session {siid} {
        if {![$Tv exists $siid]} return
        set path [string range $siid 2 end]
        set fiid [$Tv parent $siid]
        set bytes 0
        set row [{*}$LookupSession $path]
        if {$row ne ""} { set bytes [dict get $row size] }
        $Tv delete $siid
        if {$fiid ne "" && [dict exists $FolderCount $fiid]} {
            dict incr FolderCount $fiid -1
            dict incr FolderBytes $fiid [expr {-1 * $bytes}]
            if {[dict get $FolderCount $fiid] <= 0} {
                $Tv delete $fiid
                dict unset FolderCount $fiid
                dict unset FolderBytes $fiid
            } else {
                my render_folder $fiid
            }
        }
    }

    method relocate_session {old_path new_path} {
        my forget_session S:$old_path
        if {[dict exists $MatchedSessions $old_path]} {
            dict unset MatchedSessions $old_path
            dict set MatchedSessions $new_path 1
        }
    }

    # Re-derive the running glyph (and membership, when a filter is active)
    # for every visible row from the fresh running set. Idempotent: it
    # diffs the set against the tree's own S:* children, never a shadow, so
    # running it twice is a no-op and a missed tick self-corrects on the
    # next. Called every poll and after on_filter rebuilds the tree.
    method reconcile_running {running} {
        set RunningSet $running
        set running_only    [my dict_or $Snapshot running_only 0]
        set bookmarked_only [my dict_or $Snapshot bookmarked_only 0]

        # uuid -> 1 for currently-displayed rows (the display truth).
        set displayed [dict create]
        foreach siid [my all_session_iids] {
            dict set displayed [my iid_uuid $siid] 1
        }

        # Ensure every running session is on screen. Match by uuid (stable
        # across a move); a moved session is already displayed under its
        # new path, so the reconstructed registry path is used only for a
        # genuinely-fresh insert. While a criteria search is active the tree
        # mirrors the matched sessions, so a running session that did not
        # match is not force-shown (unless running-only mode asks for it).
        if {$running_only || !$CriteriaActive} {
            dict for {uuid path} $running {
                if {[dict exists $displayed $uuid]} continue
                set row [{*}$LookupSession $path]
                if {$row eq "" && [file isfile $path]} {
                    set row [{*}$OnScanPath $path]
                }
                if {$row eq "" || ![dict size $row]} continue
                my ensure_folder [dict get $row folder]
                my insert_session [dict get $row folder] $row
                dict set displayed $uuid 1
            }
        }

        # Membership + decoration over a fresh snapshot of the rows (the
        # ensure step may have inserted some). forget_session may delete a
        # folder, so guard each iid with an existence check.
        foreach siid [my all_session_iids] {
            if {![$Tv exists $siid]} continue
            set path [string range $siid 2 end]
            set uuid [my iid_uuid $siid]
            set is_running [dict exists $running $uuid]
            set row [{*}$LookupSession $path]
            set bk 0
            if {$row ne ""} { set bk [my dict_or $row bookmarked 0] }
            if {$running_only && $bookmarked_only} {
                set keep [expr {$is_running && $bk}]
            } elseif {$running_only} {
                set keep $is_running
            } elseif {$bookmarked_only} {
                set keep $bk
            } elseif {$CriteriaActive} {
                # A search is active: membership is the matched set, mirroring
                # the results pane; running-ness and cwd_only do not add rows.
                set keep [dict exists $MatchedSessions $path]
            } else {
                set keep [expr {($row ne "" && [my row_matches_snapshot $row]) \
                                || $is_running}]
            }
            if {!$keep} { my forget_session $siid; continue }
            set want [my glyph_cell $is_running $bk]
            if {[$Tv set $siid flags] ne $want} { $Tv set $siid flags $want }
        }
    }

    # Refresh a single row's status cell from current truth. Used for
    # immediate feedback after a bookmark toggle, without waiting a tick.
    method reconcile_one {path} {
        set siid S:$path
        if {![$Tv exists $siid]} return
        set is_running [dict exists $RunningSet [my iid_uuid $siid]]
        set row [{*}$LookupSession $path]
        set bk 0
        if {$row ne ""} { set bk [my dict_or $row bookmarked 0] }
        set want [my glyph_cell $is_running $bk]
        if {[$Tv set $siid flags] ne $want} { $Tv set $siid flags $want }
    }

    # Flat snapshot of every session iid currently in the tree.
    method all_session_iids {} {
        set out [list]
        foreach fiid [$Tv children {}] {
            foreach siid [$Tv children $fiid] { lappend out $siid }
        }
        return $out
    }

    method iid_uuid {siid} {
        return [file rootname [file tail [string range $siid 2 end]]]
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

    # The internal tree widget path; used by the results pane to know
    # where to drop sessions during a drag.
    method tv_path {} { return $Tv }

    method dict_or {d k default} {
        if {[dict exists $d $k]} { return [dict get $d $k] }
        return $default
    }
}
