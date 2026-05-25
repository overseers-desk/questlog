package require Tcl 9
package require Tk

# Glyphs for the status markers. The single home for both; the toolbar
# toggles are plain text, so these characters live only here.
namespace eval ::fms::ui {
    variable GLYPH_RUNNING  ●
    variable GLYPH_BOOKMARK ★
}

# ::fms::ui::SessionList - the left pane: one read-only text widget that is
# both the session browser and the search-result index in a single list.
#
# Layout, top to bottom, as tagged regions in the one text widget:
#   folder heading   - the project label, a drop target for moves
#   session header   - glyphs, label, time, and (when searching) a match count
#   snippet rows     - up to three per session: a block-type label and a
#                      hit-centred snippet with the matched term in bold
#
# Two display states share the widget. With no criteria it browses: every
# session that passes the snapshot filter appears as a header, grouped by
# folder. With criteria it indexes: only matching sessions appear, each with
# its snippets. A single click opens the session in the docked viewer and
# anchors it to the relevant line.
#
# A text widget is the list; position is tracked with text marks:
#   TailMark   right-gravity, always just before the implicit final newline.
#   <folder>   fmark left-gravity at the heading start; femark right-gravity
#              at the end of the folder's session group (new sessions land
#              here); htag, a per-folder tag on the heading line for drop
#              hit-testing.
#   <session>  smark left-gravity at the header start; semark right-gravity
#              at the session's end (new snippets land here); stag, a
#              per-session tag carrying the click/drag bindings.
# Gravity makes a mid-document insert push every mark to its right along
# with it, so folder grouping streams without bespoke shuffling.
#
# Anti-self-scroll: every streaming insert is bracketed by anchor_save /
# anchor_restore, which pins the top visible line back to the top, so a late
# match inserted above the viewport never shifts what the reader is on.

oo::class create ::fms::ui::SessionList {
    variable Top
    variable Text
    variable StatusVar
    variable CancelCb
    variable ResolveFolder    ;# cb: folder -> display cwd
    variable LookupSession    ;# cb: path -> row dict
    variable OnOpen           ;# cb: path lineno -> open + anchor in viewer
    variable OnMoveRequest    ;# cb: paths -> open move picker
    variable OnDropMove       ;# cb: paths folder -> direct move
    variable OnBookmarkToggle ;# cb: path -> flip the +x bookmark bit
    variable OnScanPath       ;# cb: path -> row (synchronous single-file scan)
    variable Snapshot
    variable CriteriaActive
    variable RunningSet       ;# dict uuid -> 1, replaced wholesale each tick
    variable Query            ;# {regex <list> nocase 0|1} for hit highlighting
    variable HitTags
    variable Folders          ;# folder -> {fmark femark htag}
    variable FolderOrder      ;# folders in arrival (mtime-desc) order
    variable SessionsByFolder ;# folder -> ordered list of paths
    variable Sessions         ;# path -> session dict (see model_add_session)
    variable HtagFolder       ;# htag -> folder, for drop hit-testing
    variable Selected         ;# currently selected session path, or ""
    variable NextId
    variable Menu
    variable MenuPath
    variable MenuTarget
    variable BookmarkIndex    ;# menu index of the Bookmark entry (its label mutates)

    constructor {parent resolve_cb lookup_cb on_open on_move_request \
                 on_drop_move on_bookmark_toggle on_scan_path cancel_cb} {
        set Top $parent
        set ResolveFolder $resolve_cb
        set LookupSession $lookup_cb
        set OnOpen $on_open
        set OnMoveRequest $on_move_request
        set OnDropMove $on_drop_move
        set OnBookmarkToggle $on_bookmark_toggle
        set OnScanPath $on_scan_path
        set CancelCb $cancel_cb
        set StatusVar "Idle"
        set Snapshot [dict create]
        set CriteriaActive 0
        set RunningSet [dict create]
        set Query [dict create regex [list] nocase 0]
        set Selected ""
        set NextId 0
        my reset_model
        my build
    }

    method reset_model {} {
        set Folders [dict create]
        set FolderOrder [list]
        set SessionsByFolder [dict create]
        set Sessions [dict create]
        set HtagFolder [dict create]
        set Selected ""
    }

    method build {} {
        ttk::frame $Top

        ttk::frame $Top.bar
        pack $Top.bar -side top -fill x
        ttk::label $Top.bar.status -textvariable [my varname StatusVar]
        pack $Top.bar.status -side left -padx 4 -pady 2
        ttk::button $Top.bar.cancel -text "Cancel" -command [list [self] cancel]
        pack $Top.bar.cancel -side right -padx 4 -pady 2

        ttk::frame $Top.body
        pack $Top.body -side top -fill both -expand 1
        text $Top.body.t -wrap word -state disabled -exportselection 0 \
            -yscrollcommand [list $Top.body.sb set] \
            -borderwidth 0 -highlightthickness 0 -padx 4 -pady 4 -cursor arrow \
            -takefocus 0
        ttk::scrollbar $Top.body.sb -orient vertical \
            -command [list $Top.body.t yview]
        grid $Top.body.t  -row 0 -column 0 -sticky nsew
        grid $Top.body.sb -row 0 -column 1 -sticky ns
        grid columnconfigure $Top.body 0 -weight 1
        grid rowconfigure    $Top.body 0 -weight 1
        set Text $Top.body.t
        # This is a list, not editable text: make the click-drag text selection
        # invisible (it otherwise paints rows grey, active and inactive) and
        # hide the insert cursor.
        $Text configure -insertwidth 0 -inactiveselectbackground "" \
            -selectbackground [$Text cget -background] \
            -selectforeground [$Text cget -foreground]

        $Text mark set TailMark "end-1c"
        $Text mark gravity TailMark right

        my configure_tags
        # This is an object list, not editable text. Block the Text class's
        # selection gestures so a click never starts a text selection (which
        # would grab the X PRIMARY clipboard and, via tk::TextAutoScan, run a
        # self-scrolling drag-select). The per-tag click/drag bindings fire
        # first; these widget-level breaks stop the class bindings that follow.
        # B1-Motion still drives drag-to-move, then breaks the class handler.
        bind $Text <B1-Motion> {::fms::ui::drag::motion %X %Y; break}
        foreach ev {<Button-1> <Double-Button-1> <Triple-Button-1> \
                    <Shift-Button-1> <Control-Button-1> <B1-Leave>} {
            bind $Text $ev break
        }
        my build_menu
    }

    method configure_tags {} {
        # Folder heading: the outermost level, bold, with a wide gap above so
        # each project group reads as a section.
        $Text tag configure folderhead \
            -font {-weight bold} -foreground "#555" -spacing1 14 -spacing3 3
        # Session header: one line, the block's "title" (like a search result
        # heading), indented under its folder. Rows are separated by the gap
        # above each and the bold title colour; no background band. The
        # selected row gets a highlight for click feedback.
        $Text tag configure sessionhead -lmargin1 12 -lmargin2 28 \
            -spacing1 6 -spacing3 2 -foreground "#143d8a"
        $Text tag configure selected -background "#aecbff"
        $Text tag configure drop-candidate -background "#cce5ff"

        # Snippet rows: type label in a left column, content wrapping under it.
        # Indented past the header so each block reads title-then-evidence.
        set f [ttk::style lookup TkDefaultFont -font]
        if {$f eq ""} { set f TkDefaultFont }
        set lm 36
        set tw [font measure $f "tool_result   "]
        set content_col [expr {$lm + $tw}]
        $Text configure -tabs [list $content_col left]
        $Text tag configure snippet -lmargin1 $lm -lmargin2 $content_col \
            -foreground "#333" -spacing3 1
        $Text tag configure type-user        -foreground "#06c" -font {-weight bold}
        $Text tag configure type-assistant   -foreground "#222" -font {-weight bold}
        $Text tag configure type-tool_use    -foreground "#a60" -font {-weight bold}
        $Text tag configure type-tool_result -foreground "#666" -font {-weight bold}
        $Text tag configure type-system      -foreground "#888" -font {-weight bold}
        # Metadata prefix: a fixed-width font so the time and size columns at
        # the front of each session line align down the list without tab math.
        $Text tag configure meta -font TkFixedFont -foreground "#777"

        set HitTags [list]
        set hues {#fff59d #b3e5fc #f8bbd0 #c8e6c9}
        for {set i 0} {$i < [llength $hues]} {incr i} {
            set t hit-$i
            $Text tag configure $t -background [lindex $hues $i] -font {-weight bold}
            lappend HitTags $t
        }
    }

    method build_menu {} {
        set Menu $Top.cmenu
        menu $Menu -tearoff 0
        $Menu add command -label "Open in viewer" -command [list [self] menu_open]
        $Menu add separator
        $Menu add command -label "Copy resume command" \
            -command [list [self] menu_copy_resume]
        $Menu add command -label "Copy session id" \
            -command [list [self] menu_copy_uuid]
        $Menu add command -label "Copy session path" \
            -command [list [self] menu_copy_path]
        $Menu add command -label "Copy last assistant output" \
            -command [list [self] menu_copy_last_assistant]
        $Menu add separator
        $Menu add command -label "Resume in new terminal tab" \
            -command [list [self] menu_resume 0]
        $Menu add command -label "Resume forked" -command [list [self] menu_resume 1]
        $Menu add separator
        $Menu add command -label "Move to..." -command [list [self] menu_move]
        $Menu add command -label "Reveal folder" -command [list [self] menu_reveal]
        $Menu add separator
        $Menu add command -label "Bookmark" -command [list [self] menu_bookmark]
        # Addressed by index, not label: on_session_right rewrites this label
        # to Add/Remove bookmark, so a label lookup would fail on the next open.
        set BookmarkIndex [$Menu index end]
        set MenuTarget [dict create]
        set MenuPath ""
    }

    # ---- view-anchoring around streaming inserts ----------------------
    #
    # A streaming insert must not shift what the reader is looking at. Two
    # cases: if the reader is at the very top (the default while browsing or
    # watching results arrive), keep them pinned to the absolute top so the
    # newest content and the folder heading stay in view; if they have
    # scrolled into the list, pin the character that was at the top so an
    # insert above it scrolls to compensate and their line does not move.

    variable AtTop
    method anchor_save {} {
        set AtTop [expr {[lindex [$Text yview] 0] <= 0.0001}]
        $Text mark set AnchorTop @0,0
        $Text mark gravity AnchorTop left
    }
    method anchor_restore {} {
        if {[info exists AtTop] && $AtTop} {
            $Text yview moveto 0
        } else {
            catch {$Text yview AnchorTop}
        }
        catch {$Text mark unset AnchorTop}
    }

    # ---- filter / clear ----------------------------------------------

    method clear {} {
        $Text configure -state normal
        $Text delete 1.0 end
        my purge_tags_and_marks
        $Text mark set TailMark "end-1c"
        $Text mark gravity TailMark right
        $Text configure -state disabled
        my reset_model
        set StatusVar "Idle"
    }

    # Drop the per-region tags and position marks left behind by a cleared
    # body, so neither accumulates across filter changes.
    method purge_tags_and_marks {} {
        foreach t [$Text tag names] {
            if {[string match "s#*" $t] || [string match "f#*" $t] \
                || [string match "n#*" $t]} {
                $Text tag delete $t
            }
        }
        foreach m [$Text mark names] {
            if {[string match "sm*" $m] || [string match "se*" $m] \
                || [string match "fm*" $m] || [string match "fe*" $m]} {
                $Text mark unset $m
            }
        }
    }

    method apply_filter {snapshot} {
        set Snapshot $snapshot
        set CriteriaActive [::fms::ui::any_criteria $snapshot]
        my clear
    }

    method set_query {regex_list nocase} {
        set Query [dict create regex $regex_list nocase $nocase]
    }

    # ---- snapshot membership -----------------------------------------

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
        if {[dict get $row mtime] <= $cutoff && !$bk} { return 0 }
        if {$one_turn && ![dict get $row is_multi]} { return 0 }
        if {$cwd_only && $cwd ne ""} {
            set cwd_folder [::fms::path::encode_cwd $cwd]
            if {[dict get $row folder] ne $cwd_folder} { return 0 }
        }
        return 1
    }

    # ---- streaming inserts -------------------------------------------

    # Browse-mode row from Scan. Skipped under running-only (the reconciler
    # owns the display then) and when criteria are active (the result index
    # is built from matches, not the scan stream).
    method on_scan_row {row} {
        if {[my dict_or $Snapshot running_only 0]} return
        if {$CriteriaActive} return
        if {![my row_matches_snapshot $row]} return
        set path [dict get $row path]
        if {[dict exists $Sessions $path]} return
        $Text configure -state normal
        my anchor_save
        my model_add_session $path $row
        if {[my folder_expanded [dict get $row folder]]} { my render_session $path }
        my anchor_restore
        $Text configure -state disabled
    }

    # Match record from Search. The first match for a session creates its
    # card; later matches bump the count and add a snippet (capped at three).
    method add_match {match} {
        set path [dict get $match path]
        set btype [dict get $match btype]
        set content [dict get $match content]
        set lineoff [dict get $match lineoff]
        $Text configure -state normal
        my anchor_save
        if {![dict exists $Sessions $path]} {
            set row [{*}$LookupSession $path]
            if {$row eq ""} { set row [dict create folder [dict get $match folder]] }
            my model_add_session $path $row $lineoff
        }
        # Search folders are expanded, so render the session if it is not yet.
        if {[my folder_expanded [dict get $Sessions $path folder]] \
            && ![dict get $Sessions $path rendered]} {
            my render_session $path
        }
        my add_snippet $path $btype $content $lineoff
        my anchor_restore
        $Text configure -state disabled
    }

    method folder_expanded {folder} {
        if {![dict exists $Folders $folder]} { return 0 }
        return [dict get [dict get $Folders $folder] expanded]
    }

    # Record a session in the model without drawing it. A collapsed folder
    # holds its sessions here only; they are drawn lazily on expand. This is
    # what keeps a folded list cheap and free of hidden (elided) lines.
    method model_add_session {path row {first_lineno 0}} {
        set folder [dict get $row folder]
        my ensure_folder $folder
        set label [my session_label $path $row]
        set when  [my fmt_time [my dict_or $row mtime 0]]
        set size  [my dict_or $row size 0]
        set uuid  [my dict_or $row uuid [file rootname [file tail $path]]]
        dict set Sessions $path [dict create \
            folder $folder label $label when $when size $size uuid $uuid \
            count 0 first_lineno $first_lineno snippets [list] \
            stag "" smark "" semark "" rendered 0]
        dict lappend SessionsByFolder $folder $path
        my bump_folder_count $folder 1
    }

    # Draw a session that the model already knows, inserting its header (and
    # any stored snippets) at the folder's append point. Idempotent.
    method render_session {path} {
        if {[dict get $Sessions $path rendered]} return
        set folder [dict get $Sessions $path folder]
        set femark [dict get [dict get $Folders $folder] femark]
        set stag "s#[incr NextId]"
        set sstart [$Text index $femark]
        set meta [my session_meta_text $path]
        $Text insert $femark "$meta[my session_title_text $path]\n" \
            [list sessionhead $stag]
        $Text tag add meta $sstart "$sstart + [string length $meta]c"
        set smark "sm[incr NextId]"
        $Text mark set $smark $sstart
        $Text mark gravity $smark left
        set send [$Text index "$smark lineend +1c"]
        set semark "se[incr NextId]"
        $Text mark set $semark $send
        $Text mark gravity $semark left
        $Text mark set $femark $send
        dict set Sessions $path stag $stag
        dict set Sessions $path smark $smark
        dict set Sessions $path semark $semark
        dict set Sessions $path rendered 1
        $Text tag bind $stag <ButtonPress-1> \
            [list [self] on_session_press $path %X %Y]
        $Text tag bind $stag <ButtonRelease-1> \
            [list [self] on_session_release $path %X %Y]
        $Text tag bind $stag <Double-Button-1> \
            [list [self] on_session_open $path]
        $Text tag bind $stag <Button-3> \
            [list [self] on_session_right $path %X %Y]
        foreach snip [dict get $Sessions $path snippets] {
            lassign $snip btype content lineoff
            my render_snippet $path $btype $content $lineoff
        }
        if {$Selected eq $path} {
            $Text tag add selected $smark "$smark lineend"
        }
    }

    # Accumulate a match in the model (count, capped snippet list) and draw
    # the snippet row when the session is on screen.
    method add_snippet {path btype content lineoff} {
        dict set Sessions $path count [expr {[dict get $Sessions $path count] + 1}]
        my redraw_header $path
        if {[llength [dict get $Sessions $path snippets]] >= 3} return
        set sn [dict get $Sessions $path snippets]
        lappend sn [list $btype $content $lineoff]
        dict set Sessions $path snippets $sn
        if {[dict get $Sessions $path rendered]} {
            my render_snippet $path $btype $content $lineoff
        }
    }

    method render_snippet {path btype content lineoff} {
        set semark [dict get $Sessions $path semark]
        set ntag "n#[incr NextId]"
        set type_tag type-$btype
        if {[lsearch -exact [$Text tag names] $type_tag] < 0} {
            set type_tag type-system
        }
        # Build at a temporary right-gravity mark so the pieces land in order;
        # semark is left gravity and would otherwise reverse successive inserts.
        set tmp tmpsnip
        $Text mark set $tmp [$Text index $semark]
        $Text mark gravity $tmp right
        $Text insert $tmp $btype [list snippet $type_tag $ntag]
        $Text insert $tmp "\t" [list snippet $ntag]
        set cstart [$Text index $tmp]
        $Text insert $tmp $content [list snippet $ntag]
        set cend [$Text index $tmp]
        $Text insert $tmp "\n" [list snippet $ntag]
        my tag_hits_in_range $cstart $cend $content
        $Text tag bind $ntag <ButtonRelease-1> \
            [list [self] on_snippet_click $path]
        $Text tag bind $ntag <Double-Button-1> \
            [list [self] on_snippet_open $path $lineoff]
        # Advance this session's end and the folder's append point past the
        # snippet (the session receiving snippets is always its folder's last).
        $Text mark set $semark [$Text index $tmp]
        $Text mark unset $tmp
        set folder [dict get $Sessions $path folder]
        if {[dict exists $Folders $folder]} {
            $Text mark set [dict get [dict get $Folders $folder] femark] \
                [$Text index $semark]
        }
    }

    method session_label {path row} {
        set body [my dict_or $row first_user ""]
        if {$body eq ""} { set body [my dict_or $row uuid [file rootname [file tail $path]]] }
        return $body
    }

    # The fixed-width metadata prefix (monospace tag): time then size, each in
    # a constant character column so they align down the list.
    method session_meta_text {path} {
        set s [dict get $Sessions $path]
        set when [dict get $s when]
        set size [my fmt_size [dict get $s size]]
        return [format "%-16s %7s   " $when $size]
    }

    # The proportional-font title: glyphs, the first-prompt preview, and the
    # match count when searching. Follows the metadata prefix on the line.
    method session_title_text {path} {
        set s [dict get $Sessions $path]
        set running [dict exists $RunningSet [dict get $s uuid]]
        set bk [my session_bookmarked $path]
        set g [my glyph_cell $running $bk]
        set line ""
        if {$g ne ""} { append line "$g " }
        append line [dict get $s label]
        set count [dict get $s count]
        if {$count > 0} {
            append line "   ·   $count [expr {$count == 1 ? {match} : {matches}}]"
        }
        return $line
    }

    method session_bookmarked {path} {
        set row [{*}$LookupSession $path]
        if {$row ne ""} { return [my dict_or $row bookmarked 0] }
        return [file executable $path]
    }

    # Rewrite a session header line in place (glyphs, count). Leaves the
    # surrounding lines untouched, so a per-tick glyph refresh never shifts
    # the view.
    method redraw_header {path} {
        set s [dict get $Sessions $path]
        if {![dict get $s rendered]} return
        set smark [dict get $s smark]
        set stag  [dict get $s stag]
        set meta [my session_meta_text $path]
        $Text delete $smark "$smark lineend"
        $Text insert $smark "$meta[my session_title_text $path]" \
            [list sessionhead $stag]
        $Text tag add meta $smark "$smark + [string length $meta]c"
        if {$Selected eq $path} {
            $Text tag add selected $smark [dict get $s semark]
        }
    }

    method ensure_folder {folder} {
        if {[dict exists $Folders $folder]} return
        set label [::fms::path::display_label [{*}$ResolveFolder $folder] $folder]
        set htag  "f#[incr NextId]"
        # Browsing opens folders collapsed (an overview of projects); a search
        # opens them expanded so the matches under each folder are visible. A
        # collapsed folder draws only its heading - its sessions live in the
        # model and are rendered lazily on expand, so there are no hidden lines.
        set expanded [expr {$CriteriaActive ? 1 : 0}]
        set fmark  "fm[incr NextId]"
        set femark "fe[incr NextId]"
        dict set Folders $folder [dict create fmark $fmark femark $femark \
            htag $htag label $label count 0 expanded $expanded]
        set fstart [$Text index TailMark]
        $Text insert TailMark "[my folder_heading_text $folder]\n" \
            [list folderhead $htag]
        $Text mark set $fmark $fstart
        $Text mark gravity $fmark left
        $Text mark set $femark [$Text index TailMark]
        $Text mark gravity $femark left
        dict set HtagFolder $htag $folder
        dict set SessionsByFolder $folder [list]
        lappend FolderOrder $folder
        $Text tag bind $htag <Button-1> [list [self] toggle_folder $folder]
    }

    method folder_heading_text {folder} {
        set f [dict get $Folders $folder]
        set marker [expr {[dict get $f expanded] ? "▾" : "▸"}]
        # Bind the marker to the label with a non-breaking space so -wrap word
        # cannot strand the triangle alone on a line when the path is long.
        set line "$marker\u00A0[dict get $f label]"
        set n [dict get $f count]
        if {$n > 0} { append line "  ($n)" }
        return $line
    }

    method redraw_folder_heading {folder} {
        if {![dict exists $Folders $folder]} return
        set f [dict get $Folders $folder]
        set fmark [dict get $f fmark]
        $Text delete $fmark "$fmark lineend"
        $Text insert $fmark [my folder_heading_text $folder] \
            [list folderhead [dict get $f htag]]
    }

    method toggle_folder {folder} {
        if {![dict exists $Folders $folder]} return
        set exp [expr {![dict get [dict get $Folders $folder] expanded]}]
        dict set Folders $folder expanded $exp
        $Text configure -state normal
        if {$exp} { my expand_folder $folder } else { my collapse_folder $folder }
        my redraw_folder_heading $folder
        $Text configure -state disabled
    }

    method expand_folder {folder} {
        foreach path [my dict_or $SessionsByFolder $folder {}] {
            my render_session $path
        }
    }

    # Delete every rendered line of the folder's body and drop the per-session
    # render marks; the sessions remain in the model and redraw on the next
    # expand. No hidden text is left behind.
    method collapse_folder {folder} {
        set f [dict get $Folders $folder]
        set fmark [dict get $f fmark]
        set femark [dict get $f femark]
        set bodystart [$Text index "$fmark lineend +1c"]
        $Text delete $bodystart $femark
        $Text mark set $femark $bodystart
        foreach path [my dict_or $SessionsByFolder $folder {}] {
            if {![dict exists $Sessions $path]} continue
            if {![dict get $Sessions $path rendered]} continue
            catch {$Text mark unset [dict get $Sessions $path smark] \
                                    [dict get $Sessions $path semark]}
            dict set Sessions $path rendered 0
            dict set Sessions $path stag ""
            dict set Sessions $path smark ""
            dict set Sessions $path semark ""
        }
        # Drop the now-empty per-session / per-snippet tags left by the delete.
        foreach tg [$Text tag names] {
            if {([string match "s#*" $tg] || [string match "n#*" $tg]) \
                && [llength [$Text tag ranges $tg]] == 0} {
                $Text tag delete $tg
            }
        }
    }

    method bump_folder_count {folder delta} {
        if {![dict exists $Folders $folder]} return
        dict set Folders $folder count \
            [expr {[dict get [dict get $Folders $folder] count] + $delta}]
        my redraw_folder_heading $folder
    }

    method glyph_cell {running bookmarked} {
        set s ""
        if {$running}    { append s $::fms::ui::GLYPH_RUNNING }
        if {$bookmarked} { append s $::fms::ui::GLYPH_BOOKMARK }
        return $s
    }

    method tag_hits_in_range {start end snippet} {
        set patterns [dict get $Query regex]
        if {[llength $patterns] == 0} return
        set nocase [dict get $Query nocase]
        set hue_count [llength $HitTags]
        if {$hue_count == 0} return
        set re_opts [list -indices -all -inline]
        if {$nocase} { lappend re_opts -nocase }
        set i 0
        foreach pat $patterns {
            if {$pat eq ""} { incr i; continue }
            set tag [lindex $HitTags [expr {$i % $hue_count}]]
            if {[catch {regexp {*}$re_opts -- $pat $snippet} hits]} { incr i; continue }
            foreach span $hits {
                lassign $span s e
                set ts [$Text index "$start + ${s}c"]
                set te [$Text index "$start + [expr {$e + 1}]c"]
                $Text tag add $tag $ts $te
            }
            incr i
        }
    }

    # ---- selection / open --------------------------------------------

    # Select the whole session object - its header and any snippets - as one
    # highlighted block (the full-width region, not a text run).
    method select {path} {
        if {$Selected ne "" && [dict exists $Sessions $Selected] \
            && [dict get $Sessions $Selected rendered]} {
            set os [dict get $Sessions $Selected]
            catch {$Text tag remove selected [dict get $os smark] [dict get $os semark]}
        }
        set Selected $path
        if {[dict exists $Sessions $path] && [dict get $Sessions $path rendered]} {
            set s [dict get $Sessions $path]
            $Text tag add selected [dict get $s smark] [dict get $s semark]
        }
    }

    method open_session {path {lineno -1}} {
        if {$lineno < 0} {
            set lineno 0
            if {[dict exists $Sessions $path]} {
                set lineno [dict get [dict get $Sessions $path] first_lineno]
            }
        }
        {*}$OnOpen $path $lineno
    }

    # A plain click selects (and, having armed a drag on press, lets a drag
    # win if the pointer moved). Opening the viewer is a double-click, so a
    # single click can begin a drag without also loading the reading view.
    method on_session_release {path X Y} {
        set was_drag [::fms::ui::drag::release $X $Y]
        if {$was_drag} return
        my select $path
    }

    method on_session_open {path} {
        my select $path
        my open_session $path
    }

    method on_snippet_click {path} { my select $path }

    method on_snippet_open {path lineno} {
        my select $path
        my open_session $path $lineno
    }

    # ---- drag-to-move -------------------------------------------------

    method on_session_press {path X Y} {
        ::fms::ui::drag::watch $Text $X $Y [list $path] \
            [list [self] handle_drop] \
            [list [self] drag_hit] [list [self] drag_paint]
    }

    method drag_hit {X Y} {
        set lx [expr {$X - [winfo rootx $Text]}]
        set ly [expr {$Y - [winfo rooty $Text]}]
        set idx [$Text index @$lx,$ly]
        foreach t [$Text tag names $idx] {
            if {[dict exists $HtagFolder $t]} { return [dict get $HtagFolder $t] }
        }
        return ""
    }

    method drag_paint {old new} {
        if {$old ne "" && [dict exists $Folders $old]} {
            set fm [dict get [dict get $Folders $old] fmark]
            catch {$Text tag remove drop-candidate $fm "$fm lineend"}
        }
        if {$new ne "" && [dict exists $Folders $new]} {
            set fm [dict get [dict get $Folders $new] fmark]
            $Text tag add drop-candidate $fm "$fm lineend"
        }
    }

    method handle_drop {paths target_folder} {
        {*}$OnDropMove $paths $target_folder
    }

    # ---- right-click menu --------------------------------------------

    method on_session_right {path X Y} {
        set row [{*}$LookupSession $path]
        set uuid [file rootname [file tail $path]]
        set folder ""
        set cwd ""
        if {$row ne ""} {
            set folder [my dict_or $row folder ""]
            set uuid [my dict_or $row uuid $uuid]
        }
        if {$folder eq "" && [dict exists $Sessions $path]} {
            set folder [dict get [dict get $Sessions $path] folder]
        }
        if {$folder ne ""} { set cwd [{*}$ResolveFolder $folder] }
        set MenuPath $path
        set MenuTarget [dict create path $path uuid $uuid cwd $cwd folder $folder]

        set rstate [expr {$cwd ne "" ? "normal" : "disabled"}]
        foreach lbl {"Copy resume command" "Resume in new terminal tab" \
                     "Resume forked"} {
            $Menu entryconfigure $lbl -state $rstate
        }
        $Menu entryconfigure "Reveal folder" \
            -state [expr {$folder ne "" ? "normal" : "disabled"}]
        $Menu entryconfigure $BookmarkIndex \
            -label [expr {[file executable $path] ? "Remove bookmark" : "Add bookmark"}]
        tk_popup $Menu $X $Y
    }

    method menu_target_get {key} { return [dict get $MenuTarget $key] }
    method menu_open {} { my open_session $MenuPath }
    method menu_copy_resume {} {
        my clipboard_set [::fms::terminal::resume_command \
            [my menu_target_get cwd] [my menu_target_get uuid]]
    }
    method menu_copy_uuid {} { my clipboard_set [my menu_target_get uuid] }
    method menu_copy_path {} { my clipboard_set $MenuPath }
    method menu_copy_last_assistant {} {
        my clipboard_set [::fms::jsonl::last_assistant_text [my menu_target_get path]]
    }
    method menu_resume {fork} {
        ::fms::terminal::launch_tab [my menu_target_get cwd] \
            [my menu_target_get uuid] $fork
    }
    method menu_reveal {} {
        set dir [file join [::fms::path::projects_root] [my menu_target_get folder]]
        if {[catch {exec xdg-open $dir &} err]} {
            puts stderr "fms: xdg-open failed: $err"
        }
    }
    method menu_move {} { {*}$OnMoveRequest [list $MenuPath] }
    method menu_bookmark {} { {*}$OnBookmarkToggle $MenuPath }
    method clipboard_set {s} { clipboard clear; clipboard append $s }

    # ---- running / bookmark reconciliation ---------------------------

    # Re-derive the running glyph for every shown session from a fresh
    # running set, surfacing running sessions that are not yet shown and
    # dropping rows that no longer pass a running-only / bookmarked-only
    # filter. Idempotent: running it twice is a no-op, and a missed tick
    # self-corrects on the next.
    method reconcile_running {running} {
        set RunningSet $running
        set running_only    [my dict_or $Snapshot running_only 0]
        set bookmarked_only [my dict_or $Snapshot bookmarked_only 0]

        $Text configure -state normal
        my anchor_save
        if {$running_only || !$CriteriaActive} {
            dict for {uuid path} $running {
                if {[dict exists $Sessions $path]} continue
                set row [{*}$LookupSession $path]
                if {$row eq "" && [file isfile $path]} {
                    set row [{*}$OnScanPath $path]
                }
                if {$row eq "" || ![dict size $row]} continue
                # OnScanPath above is not a pure read: scan_path -> publish_row
                # fires OnRow, which in browse mode is on_scan_row, which has
                # already added (and rendered) this session. Re-check so we do
                # not add it a second time. A running session that on_scan_row
                # filtered out (out of window / one-turn) is still absent here
                # and is added below, so running sessions always surface.
                if {[dict exists $Sessions $path]} continue
                my model_add_session $path $row
                if {[my folder_expanded [dict get $row folder]]} {
                    my render_session $path
                }
            }
        }
        foreach path [my all_session_paths] {
            if {![dict exists $Sessions $path]} continue
            set uuid [dict get [dict get $Sessions $path] uuid]
            set is_running [dict exists $running $uuid]
            # A session that is not running and whose backing jsonl is gone is
            # a phantom in every mode - a Resume-forked session quit before any
            # input leaves no file, but its cached Rows row outlives the file
            # and would otherwise keep it (and its folder count) forever. A
            # still-running session is exempt: its file may be mid-creation.
            if {!$is_running && ![file isfile $path]} {
                my forget_session $path
                continue
            }
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
                set keep 1
            } else {
                set keep [expr {($row ne "" && [my row_matches_snapshot $row]) || $is_running}]
            }
            if {!$keep} { my forget_session $path; continue }
            my redraw_header $path
        }
        my anchor_restore
        $Text configure -state disabled
    }

    method reconcile_one {path} {
        if {![dict exists $Sessions $path]} return
        $Text configure -state normal
        my redraw_header $path
        $Text configure -state disabled
    }

    method all_session_paths {} {
        set out [list]
        foreach folder $FolderOrder {
            foreach path [my dict_or $SessionsByFolder $folder {}] { lappend out $path }
        }
        return $out
    }

    # ---- removal / relocation ----------------------------------------

    method forget_session {path} {
        if {![dict exists $Sessions $path]} return
        set s [dict get $Sessions $path]
        set folder [dict get $s folder]
        if {[dict get $s rendered]} {
            $Text delete [dict get $s smark] [dict get $s semark]
            catch {$Text mark unset [dict get $s smark] [dict get $s semark]}
        }
        dict unset Sessions $path
        if {$Selected eq $path} { set Selected "" }
        set lst [my dict_or $SessionsByFolder $folder {}]
        set i [lsearch -exact $lst $path]
        if {$i >= 0} { dict set SessionsByFolder $folder [lreplace $lst $i $i] }
        if {[llength [my dict_or $SessionsByFolder $folder {}]] == 0} {
            my forget_folder $folder
        } else {
            my bump_folder_count $folder -1
        }
    }

    method forget_folder {folder} {
        if {![dict exists $Folders $folder]} return
        set f [dict get $Folders $folder]
        set fmark [dict get $f fmark]
        set femark [dict get $f femark]
        $Text delete $fmark $femark
        catch {$Text mark unset $fmark $femark}
        dict unset HtagFolder [dict get $f htag]
        dict unset Folders $folder
        dict unset SessionsByFolder $folder
        set i [lsearch -exact $FolderOrder $folder]
        if {$i >= 0} { set FolderOrder [lreplace $FolderOrder $i $i] }
    }

    # After a move renames the file, re-key the model and rebuild the view
    # so the session appears under its new folder. A full rebuild keeps the
    # mark scheme consistent; moves are rare, so the cost is not on a hot path.
    method relocate_card {old_path new_path new_folder} {
        if {![dict exists $Sessions $old_path]} return
        set s [dict get $Sessions $old_path]
        set old_folder [dict get $s folder]
        dict set s folder $new_folder
        dict unset Sessions $old_path
        dict set Sessions $new_path $s
        set lst [my dict_or $SessionsByFolder $old_folder {}]
        set i [lsearch -exact $lst $old_path]
        if {$i >= 0} { dict set SessionsByFolder $old_folder [lreplace $lst $i $i] }
        if {![dict exists $SessionsByFolder $new_folder]} {
            dict set SessionsByFolder $new_folder [list]
            lappend FolderOrder $new_folder
        }
        dict lappend SessionsByFolder $new_folder $new_path
        if {$Selected eq $old_path} { set Selected $new_path }
        my redraw_all
    }

    method redraw_all {} {
        $Text configure -state normal
        my anchor_save
        $Text delete 1.0 end
        my purge_tags_and_marks
        $Text mark set TailMark "end-1c"
        $Text mark gravity TailMark right
        # Snapshot the model, remember each folder's expanded state, then
        # rebuild the model and re-render only the expanded folders' bodies.
        set saved $Sessions
        set order $FolderOrder
        set byfolder $SessionsByFolder
        set wasexp [dict create]
        dict for {f fd} $Folders { dict set wasexp $f [dict get $fd expanded] }
        set Folders [dict create]
        set FolderOrder [list]
        set SessionsByFolder [dict create]
        set HtagFolder [dict create]
        set Sessions [dict create]
        foreach folder $order {
            foreach path [my dict_or $byfolder $folder {}] {
                if {![dict exists $saved $path]} continue
                set s [dict get $saved $path]
                my model_add_session $path \
                    [dict create folder [dict get $s folder] \
                         uuid [dict get $s uuid] mtime 0 \
                         size [dict get $s size] \
                         first_user [dict get $s label]] \
                    [dict get $s first_lineno]
                dict set Sessions $path label [dict get $s label]
                dict set Sessions $path when [dict get $s when]
                dict set Sessions $path snippets [dict get $s snippets]
                dict set Sessions $path count [dict get $s count]
            }
            if {[dict exists $wasexp $folder] && [dict exists $Folders $folder]} {
                dict set Folders $folder expanded [dict get $wasexp $folder]
            }
        }
        foreach folder $FolderOrder {
            if {[dict get [dict get $Folders $folder] expanded]} {
                foreach path [my dict_or $SessionsByFolder $folder {}] {
                    my render_session $path
                }
            }
            my redraw_folder_heading $folder
        }
        if {$Selected ne "" && [dict exists $Sessions $Selected] \
            && [dict get $Sessions $Selected rendered]} {
            set sm [dict get [dict get $Sessions $Selected] smark]
            $Text tag add selected $sm "$sm lineend"
        }
        my anchor_restore
        $Text configure -state disabled
    }

    # ---- status ------------------------------------------------------

    method set_progress {done total matches} {
        set StatusVar "Searching … $done / $total sessions   matches: $matches"
    }
    method set_done {total matches} {
        set StatusVar "Done. $total sessions, $matches matches."
    }
    method cancel {} {
        if {$CancelCb ne ""} { {*}$CancelCb }
        set StatusVar "Cancelled."
    }

    # ---- formatting helpers ------------------------------------------

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

    method dict_or {d k default} {
        if {[dict exists $d $k]} { return [dict get $d $k] }
        return $default
    }
}
