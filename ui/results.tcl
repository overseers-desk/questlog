package require Tcl 9
package require Tk

# ::csm::ui::Results - the search-result pane.
#
# One read-only text widget rendering one card per session that has
# matches. Each card is a header line (project, time, count) plus a
# typed row per matching content block: type label in a left column
# (user, assistant, tool_use, tool_result, system) followed by the
# cleaned content with regex hits highlighted in place. The rendered
# content is the message body extracted from the JSONL record by Search,
# never a raw line.
#
# Public surface (called from app.tcl): clear, add_match, set_scope,
# set_progress, set_done, cancel, set_query.

oo::class create ::csm::ui::Results {
    variable Top
    variable StatusVar
    variable CancelCb
    variable ResolveFolder
    variable Text
    variable OnSelect
    variable OnOpen
    variable OnMoveRequest
    variable OnDropMove
    variable DropTarget       ;# tree widget path used as drop surface
    variable AllMatches    ;# arrival-ordered list of match dicts
    variable Scope         ;# {type none|folder|session  key <s>}
    variable Query         ;# {regex <list>  nocase 0|1}
    variable Cards         ;# path -> card dict (hmark emark count ctag project when first_lineno)
    variable HitTags       ;# list of hit-<i> tag names for per-pattern colour
    variable NextId        ;# monotonic id for unique mark and tag names
    variable Menu
    variable MenuPath

    constructor {parent resolve_cb cancel_cb on_select on_open \
                 on_move_request on_drop_move drop_target} {
        set Top $parent
        set ResolveFolder $resolve_cb
        set CancelCb $cancel_cb
        set OnSelect $on_select
        set OnOpen   $on_open
        set OnMoveRequest $on_move_request
        set OnDropMove $on_drop_move
        set DropTarget $drop_target
        set StatusVar "Idle"
        set AllMatches [list]
        set Scope [dict create type none key ""]
        set Query [dict create regex [list] nocase 0]
        set Cards [dict create]
        set NextId 0
        set MenuPath ""

        my build
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
        # text widget - no ttk equivalent.
        text $Top.body.t -wrap word -state disabled \
            -yscrollcommand [list $Top.body.sb set] \
            -borderwidth 0 -highlightthickness 0 -padx 4 -pady 4
        ttk::scrollbar $Top.body.sb -orient vertical \
            -command [list $Top.body.t yview]
        grid $Top.body.t  -row 0 -column 0 -sticky nsew
        grid $Top.body.sb -row 0 -column 1 -sticky ns
        grid columnconfigure $Top.body 0 -weight 1
        grid rowconfigure    $Top.body 0 -weight 1
        set Text $Top.body.t

        $Text tag configure card-header \
            -font {-weight bold} -spacing1 8 -spacing3 2 -foreground "#444"
        # Row paragraph: small left margin for the type label, content
        # column begins where the tab stop lands. Wrapped continuations
        # align under the content column via lmargin2.
        set f [ttk::style lookup TkDefaultFont -font]
        if {$f eq ""} { set f TkDefaultFont }
        set lm 16
        set tw [font measure $f "tool_result   "]
        set content_col [expr {$lm + $tw}]
        $Text configure -tabs [list $content_col left]
        $Text tag configure row \
            -lmargin1 $lm -lmargin2 $content_col -spacing1 6
        # Type-label foregrounds. Mirrors ui/viewer.tcl:76-78 for the
        # three primary types; muted greys for tool_result and system.
        $Text tag configure type-user        -foreground "#06c" -font {-weight bold}
        $Text tag configure type-assistant   -foreground "#222" -font {-weight bold}
        $Text tag configure type-tool_use    -foreground "#a60" -font {-weight bold}
        $Text tag configure type-tool_result -foreground "#666" -font {-weight bold}
        $Text tag configure type-system      -foreground "#888" -font {-weight bold}
        # The clickable tag is a hover hint only; per-region tags carry
        # the actual <Button-1> binding.
        $Text tag configure clickable
        $Text tag bind clickable <Enter> [list $Text configure -cursor hand2]
        $Text tag bind clickable <Leave> [list $Text configure -cursor ""]

        set HitTags [list]
        set hues {#fff59d #b3e5fc #f8bbd0 #c8e6c9}
        for {set i 0} {$i < [llength $hues]} {incr i} {
            set t hit-$i
            $Text tag configure $t -background [lindex $hues $i]
            lappend HitTags $t
        }

        bind $Text <B1-Motion> [list ::csm::ui::drag::motion %X %Y]
        bind $Text <Button-3>  [list [self] on_right %X %Y %x %y]

        my build_menu
    }

    method build_menu {} {
        set Menu $Top.cmenu
        menu $Menu -tearoff 0
        $Menu add command -label "Move to..." -command [list [self] menu_move]
    }

    method clear {} {
        $Text configure -state normal
        $Text delete 1.0 end
        foreach t [$Text tag names] {
            if {[string match "ck*" $t] || [string match "fr*" $t]} {
                $Text tag delete $t
            }
        }
        $Text configure -state disabled
        set AllMatches [list]
        set Scope [dict create type none key ""]
        set Cards [dict create]
        set NextId 0
        set StatusVar "Idle"
    }

    method set_query {regex_list nocase} {
        set Query [dict create regex $regex_list nocase $nocase]
    }

    method add_match {match} {
        set entry [dict create \
            path    [dict get $match path] \
            lineoff [dict get $match lineoff] \
            ts      [dict get $match ts] \
            btype   [dict get $match btype] \
            content [dict get $match content] \
            folder  [dict get $match folder]]
        lappend AllMatches $entry
        if {[my in_scope [dict get $entry path] [dict get $entry folder]]} {
            my render_entry $entry
        }
    }

    # set_scope - rebuild visible cards from AllMatches under a new scope.
    method set_scope {type key} {
        set Scope [dict create type $type key $key]
        $Text configure -state normal
        $Text delete 1.0 end
        foreach t [$Text tag names] {
            if {[string match "ck*" $t] || [string match "fr*" $t]} {
                $Text tag delete $t
            }
        }
        $Text configure -state disabled
        set Cards [dict create]
        foreach entry $AllMatches {
            if {[my in_scope [dict get $entry path] [dict get $entry folder]]} {
                my render_entry $entry
            }
        }
    }

    method in_scope {path folder} {
        set type [dict get $Scope type]
        if {$type eq "none"}    { return 1 }
        set key [dict get $Scope key]
        if {$type eq "session"} { return [expr {$path eq $key}] }
        if {$type eq "folder"}  { return [expr {$folder eq $key}] }
        return 1
    }

    method render_entry {entry} {
        $Text configure -state normal
        set path [dict get $entry path]
        if {[dict exists $Cards $path]} {
            my append_to_card $entry
        } else {
            my create_card $entry
        }
        $Text configure -state disabled
    }

    method create_card {entry} {
        set path    [dict get $entry path]
        set folder  [dict get $entry folder]
        set ts      [dict get $entry ts]
        set btype   [dict get $entry btype]
        set content [dict get $entry content]
        set lineoff [dict get $entry lineoff]

        set proj  [::csm::path::display_label [{*}$ResolveFolder $folder] $folder]
        set when  [my fmt_time $ts]
        set count 1

        set ctag "ck[incr NextId]"
        $Text tag configure $ctag
        $Text tag bind $ctag <ButtonPress-1> \
            [list [self] on_card_press $path %X %Y]
        $Text tag bind $ctag <ButtonRelease-1> \
            [list [self] on_card_release $path %X %Y]
        $Text tag bind $ctag <Double-Button-1> \
            [list [self] on_card_double $path]

        # Header start mark (left gravity) so we can rewrite the header
        # line in place when the count grows.
        set hmark "h[incr NextId]"
        $Text mark set $hmark "end-1c"
        $Text mark gravity $hmark left

        $Text insert end "[my format_header $proj $when $count]\n" \
            [list card-header clickable $ctag]

        my insert_row end $path $btype $content $lineoff

        # Trailing newline closes the card visually.
        $Text insert end "\n"

        # End-of-card mark: just before the trailing newline, right
        # gravity so subsequent inserts at the mark land before it and
        # the mark moves forward.
        set emark "e[incr NextId]"
        $Text mark set $emark "end-2c"
        $Text mark gravity $emark right

        dict set Cards $path [dict create \
            hmark $hmark emark $emark count $count ctag $ctag \
            project $proj when $when first_lineno $lineoff]
    }

    method append_to_card {entry} {
        set path    [dict get $entry path]
        set btype   [dict get $entry btype]
        set content [dict get $entry content]
        set lineoff [dict get $entry lineoff]
        set card  [dict get $Cards $path]
        set emark [dict get $card emark]
        set count [expr {[dict get $card count] + 1}]
        dict set Cards $path count $count

        my redraw_header $path

        my insert_row $emark $path $btype $content $lineoff
    }

    method redraw_header {path} {
        set card  [dict get $Cards $path]
        set hmark [dict get $card hmark]
        set ctag  [dict get $card ctag]
        set proj  [dict get $card project]
        set when  [dict get $card when]
        set count [dict get $card count]
        $Text delete $hmark "$hmark lineend +1c"
        $Text insert $hmark "[my format_header $proj $when $count]\n" \
            [list card-header clickable $ctag]
    }

    method format_header {proj when count} {
        set noun [expr {$count == 1 ? "match" : "matches"}]
        return "$proj  ·  $when  ·  $count $noun"
    }

    method insert_row {pos path btype content lineoff} {
        set ftag "fr[incr NextId]"
        $Text tag configure $ftag
        $Text tag bind $ftag <ButtonPress-1> \
            [list [self] on_frag_press $path $lineoff %X %Y]
        $Text tag bind $ftag <ButtonRelease-1> \
            [list [self] on_frag_release $path $lineoff %X %Y]
        $Text tag bind $ftag <Double-Button-1> \
            [list [self] on_frag_double $path $lineoff]

        set type_tag type-$btype
        # Fall back to a known type if Search emits something unexpected.
        if {[lsearch -exact [$Text tag names] $type_tag] < 0} {
            set type_tag type-system
        }

        $Text insert $pos $btype [list row $type_tag clickable $ftag]
        $Text insert $pos "\t" [list row clickable $ftag]
        set start [$Text index $pos]
        $Text insert $pos $content [list row clickable $ftag]
        set end [$Text index "$start + [string length $content]c"]
        $Text insert $pos "\n" row
        my tag_hits_in_range $start $end $content
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
            if {[catch {regexp {*}$re_opts -- $pat $snippet} hits]} {
                incr i
                continue
            }
            foreach span $hits {
                lassign $span s e
                set ts [$Text index "$start + ${s}c"]
                set te [$Text index "$start + [expr {$e + 1}]c"]
                $Text tag add $tag $ts $te
            }
            incr i
        }
    }

    method on_card_press {path X Y} {
        ::csm::ui::drag::watch $Text $DropTarget $X $Y $path \
            [list [self] handle_drop]
    }

    method on_card_release {path X Y} {
        set was_drag [::csm::ui::drag::release $X $Y]
        if {!$was_drag} { my on_card_click $path }
    }

    method on_frag_press {path lineno X Y} {
        ::csm::ui::drag::watch $Text $DropTarget $X $Y $path \
            [list [self] handle_drop]
    }

    method on_frag_release {path lineno X Y} {
        set was_drag [::csm::ui::drag::release $X $Y]
        if {!$was_drag} { my on_frag_click $path $lineno }
    }

    method handle_drop {path target_folder} {
        {*}$OnDropMove [list $path] $target_folder
    }

    method on_card_click {path} {
        if {![dict exists $Cards $path]} return
        set lineno [dict get $Cards $path first_lineno]
        {*}$OnSelect $path $lineno
    }

    method on_card_double {path} {
        if {![dict exists $Cards $path]} return
        set lineno [dict get $Cards $path first_lineno]
        {*}$OnOpen $path $lineno
    }

    method on_frag_click  {path lineno} { {*}$OnSelect $path $lineno }
    method on_frag_double {path lineno} { {*}$OnOpen   $path $lineno }

    method on_right {X Y x y} {
        # Resolve the click position to a card by looking for a ck* tag
        # at the index. Tag names at the position include the card's
        # ctag (which encodes nothing about path) plus card-header,
        # clickable, and so on. We reverse-look it up via Cards.
        set idx [$Text index @$x,$y]
        set tags [$Text tag names $idx]
        set hit ""
        foreach t $tags {
            if {[string match "ck*" $t]} { set hit $t; break }
        }
        if {$hit eq ""} return
        dict for {p card} $Cards {
            if {[dict get $card ctag] eq $hit} {
                set MenuPath $p
                tk_popup $Menu $X $Y
                return
            }
        }
    }

    method menu_move {} {
        if {$MenuPath ne ""} { {*}$OnMoveRequest [list $MenuPath] }
    }

    # Re-key the in-memory match list and rebuild the card under the new
    # path. Called after the underlying jsonl has been renamed.
    method relocate_card {old_path new_path new_folder} {
        set updated [list]
        foreach entry $AllMatches {
            if {[dict get $entry path] eq $old_path} {
                dict set entry path $new_path
                dict set entry folder $new_folder
            }
            lappend updated $entry
        }
        set AllMatches $updated
        if {[dict exists $Cards $old_path]} {
            set card [dict get $Cards $old_path]
            set hmark [dict get $card hmark]
            set emark [dict get $card emark]
            $Text configure -state normal
            $Text delete $hmark "$emark +1c"
            $Text configure -state disabled
            dict unset Cards $old_path
        }
        foreach entry $AllMatches {
            if {[dict get $entry path] ne $new_path} continue
            if {![my in_scope $new_path $new_folder]} continue
            my render_entry $entry
        }
    }

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

    method fmt_time {iso} {
        if {$iso eq ""} { return "" }
        regsub {\.\d+Z$} $iso "Z" iso
        if {[catch {clock scan $iso -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1} e]} {
            return $iso
        }
        return [clock format $e -format "%a %H:%M"]
    }
}
