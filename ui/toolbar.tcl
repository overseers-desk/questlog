package require Tcl 9
package require Tk

# ::questlog::ui::Toolbar - the top-of-window controls.
#
# Owns the filter state. Subscribers receive the full snapshot dict
# whenever any control changes:
#   since            24h | 7d | 30d | all
#   search           string (user's typed search; empty when blank)
#   search_case      0 | 1   (Aa toggle next to the search field)
#   search_regions   any | user,assistant | tool-use | tool-result (region-spec
#                    for the search terms; see lib/search.tcl parse_regions)
#   subtree          list of absolute paths  (OR within, AND across clauses)
#   file             list of {op path} pairs (op: either | read | wrote)
#   tool             list of {name key} pairs (key matches the invocation text;
#                    empty key = any use of the tool)
#   pattern          list of regex strings   (case-sensitive, always)
#   min_turns        the minimum-turns scope floor (1 = include all). A scope
#                    filter alongside since/subtree: a session below the floor leaves
#                    the corpus, not just the view - see lib/filter.tcl.
#   listview         the session-list view toggles, grouped away from the search
#                    and scope keys above so no reader mistakes one for a search:
#                    running_only 0|1, bookmarked_only 0|1. They narrow what the
#                    left pane shows, not what is searched - see lib/sessionlist.tcl.
#   cwd              launch cwd, constant after startup

namespace eval ::questlog::ui {}

# any_criteria snapshot - true iff the snapshot carries a content-matching
# clause (search text, regex pattern, or a file/tool clause). The `subtree`
# clause is a row-level scope, not a content match, so it does not count here;
# treating it as a criterion flips sessions.tcl into result-index mode and
# Search.start returns immediately because there is nothing to match, leaving
# the list empty. Shared by app.tcl (search start/cancel) and sessions.tcl
# (CriteriaActive flag: browse versus result-index mode).
proc ::questlog::ui::any_criteria {snapshot} {
    # A search counts only when it tokenises to at least one term: a
    # whitespace-only or quotes-only box is no criterion, and treating it as
    # one cleared the list into a search that never starts.
    if {[dict exists $snapshot search] && [llength \
            [::questlog::search::search_terms [dict get $snapshot search]]] > 0} {
        return 1
    }
    foreach k {file tool pattern} {
        if {[dict exists $snapshot $k] && [llength [dict get $snapshot $k]] > 0} {
            return 1
        }
    }
    return 0
}

# highlight_terms snapshot - terms for the result pane's in-place highlighter
# and the viewer's match index. Returns the tokenised search terms, matched
# literally downstream; the pattern row, while regex-typed, is uncommon and
# not highlighted in this pass.
proc ::questlog::ui::highlight_terms {snapshot} {
    set s ""
    if {[dict exists $snapshot search]} { set s [dict get $snapshot search] }
    return [::questlog::search::search_terms $s]
}

oo::class create ::questlog::ui::Toolbar {
    mixin leash
    variable Top
    variable Cwd
    variable Subscribers
    variable WindowVar
    variable CustomSpec       ;# the committed/parked custom since spec, or "" when none
    variable PopTop           ;# the open custom-window popover toplevel, or ""
    variable PopMode          ;# the popover's chosen option: relative | absolute
    variable PopNum           ;# relative count (spinbox textvariable)
    variable PopUnit          ;# relative unit word: minutes | hours | days | weeks
    variable PopDate          ;# absolute ISO date chosen in the popover
    variable CalMonth         ;# YYYY-MM-01 the mini-calendar is showing
    variable SearchVar
    variable SearchCaseVar
    variable SearchScopeVar   ;# region-spec: any | user,assistant | tool-use | tool-result
    variable ScopeLabelVar    ;# the menubutton's friendly label for the scope
    variable MinTurnsVar
    variable RunningOnlyVar
    variable BookmarkedOnlyVar
    variable Clauses          ;# dict kind -> list of values; file/tool are pairs
    variable Restrict         ;# the padded content frame holding the restrict rows
    variable RestrictHd       ;# the heading label above that frame (the legend)
    variable AddRail          ;# the "add:" rail frame inside Restrict
    variable RowFrames        ;# dict kind -> widget path (present only when row exists)
    variable TailShown        ;# dict kind -> 1 for tail rows (tool/pattern) revealed
    variable AddText          ;# array kind -> the add-entry's pending text
    variable AddState         ;# array kind -> collapsed|editing (add affordance's morph state)
    variable AddOp            ;# op for the next file value added (either|read|wrote)
    variable EditFocusKind    ;# kind whose editor should hold focus across a rebuild, or ""
    variable DebounceAfter    ;# leash token of the pending live-search publish, or ""
    variable TypingUntil      ;# clock-ms deadline through which the user counts as typing
    variable LastQueryText    ;# search text the live trigger last acted on; gates out
                              ;# key releases that move the cursor or select but leave
                              ;# the query unchanged, so they raise no redundant search

    constructor {parent cwd} {
        set Top $parent
        set Cwd $cwd
        set WindowVar  [::questlog::config::get since_default]
        set CustomSpec ""
        set PopTop ""
        set PopMode relative
        set PopNum 3
        set PopUnit days
        set PopDate ""
        set CalMonth ""
        set SearchVar  ""
        set SearchCaseVar 0
        set SearchScopeVar any
        set ScopeLabelVar "anywhere"
        set MinTurnsVar [::questlog::config::get min_turns_default]
        set RunningOnlyVar    0
        set BookmarkedOnlyVar 0
        set Clauses [dict create subtree {} file {} tool {} pattern {}]
        set Subscribers [list]
        set RowFrames [dict create]
        set TailShown [dict create]
        array set AddText {subtree {} file {} tool {} pattern {}}
        array set AddState {subtree collapsed file collapsed tool collapsed pattern collapsed}
        set AddOp either
        set EditFocusKind ""
        set DebounceAfter ""
        set TypingUntil 0
        set LastQueryText ""

        my build
    }

    method build {} {
        ttk::frame $Top

        # The criterion controls (white value chip with a faint ×, the tinted
        # type pill, the colored op pill on each file chip, the ghost add
        # buttons) draw through the rounded image-element styles built once in
        # theme::build_chrome: RGhost.TButton, Crit_<t>.TFrame, ChipX.TButton,
        # the qlPill_<t> pill images, and the op_<op>_{bg,fg} palette colours.

        # Search row: label, full-width entry, scope picker, Aa toggle.
        ttk::frame $Top.search
        pack $Top.search -side top -fill x -padx 6 -pady {6 3}
        ttk::label $Top.search.label -text "Search:"
        pack $Top.search.label -side left -padx {0 6}
        ttk::entry $Top.search.e -textvariable [my varname SearchVar]
        # Placeholder microcopy (Tk 9 ttk entry); a harmless no-op if the build
        # lacks -placeholder. Live mode searches as typing pauses; enter mode
        # waits for Return, so the hint matches the configured trigger.
        set live [expr {[::questlog::config::get search_trigger] eq "live"}]
        set ph [expr {$live \
            ? "type one or more words; all must appear somewhere in the session" \
            : "type one or more words and press Enter; all must appear somewhere in the session"}]
        catch {$Top.search.e configure -placeholder $ph}
        pack $Top.search.e -side left -fill x -expand 1
        # Return always publishes at once and cancels any pending debounce. In
        # live mode a key release that changed the query text schedules a
        # debounced publish; one that only moved the cursor or selected does not.
        bind $Top.search.e <Return> [list [self] publish_now]
        if {$live} {
            bind $Top.search.e <KeyRelease> [list [self] on_search_change]
            # A paste arrives without a KeyRelease: the clipboard shortcut is
            # caught by the virtual event, a middle-click PRIMARY paste by the
            # button release. Deferred to idle so the class binding has
            # inserted the text before the debounce compares it.
            bind $Top.search.e <<Paste>> \
                [list [self] later idle [list [self] on_search_change]]
            bind $Top.search.e <ButtonRelease-2> \
                [list [self] later idle [list [self] on_search_change]]
        }
        # Scope picker: where the search terms must appear. A menubutton posts
        # its menu anchored to itself - no transient popup, so nothing nests.
        ttk::label $Top.search.inlbl -text "in"
        pack $Top.search.inlbl -side left -padx {6 2}
        my build_scope_menu $Top.search.scope
        pack $Top.search.scope -side left
        ttk::checkbutton $Top.search.aa -text "Aa" \
            -variable [my varname SearchCaseVar] \
            -command [list [self] publish]
        pack $Top.search.aa -side left -padx {6 0}

        # Restrict group: a lightly-bordered box whose first inner line is the
        # heading (the legend sits inside, at the top, as in the design), then
        # the time row, the persistent folder/file rows, any revealed tail rows,
        # and the add rail.
        ttk::frame $Top.restrict -relief solid -borderwidth 1 -padding {8 5}
        pack $Top.restrict -side top -fill x -padx 6 -pady {2 2}
        set Restrict $Top.restrict
        set RestrictHd $Restrict.hd
        ttk::label $RestrictHd -text "Restrict to sessions that…" -anchor w \
            -foreground [::questlog::ui::theme::c muted]
        pack $RestrictHd -side top -fill x -pady {0 4}

        ttk::frame $Restrict.time
        pack $Restrict.time -side top -fill x -pady {0 3}
        ttk::label $Restrict.time.label -text "time" -width 18 -anchor w
        pack $Restrict.time.label -side left -padx {0 4}
        foreach w [::questlog::config::get since_presets] {
            ttk::radiobutton $Restrict.time.r$w -text $w \
                -variable [my varname WindowVar] -value $w \
                -command [list [self] publish]
            pack $Restrict.time.r$w -side left -padx 2
        }
        # The custom 5th member of the same single-select group: a relative
        # window or an absolute date the presets cannot express. Its own
        # sub-frame so committing or clearing re-renders only this, never the
        # presets. No "ran in the last" prose: the time tag labels the row, so
        # an absolute date has no preposition to break.
        ttk::frame $Restrict.time.custom
        pack $Restrict.time.custom -side left -padx {6 0}
        my refresh_custom_member

        # Minimum-turns scope floor: a spinbox over 1..turn_count_cap. 1 includes
        # all; a higher floor drops shorter sessions from the corpus (it is scope,
        # not a view toggle - see lib/filter.tcl). The same -width-18 label as the
        # time row keeps the column aligned. set_min_turns clamps to the valid
        # range and publishes, so a bad keystroke can never leave an out-of-range
        # value; it is wired to the buttons (-command, <<Increment>>/<<Decrement>>)
        # and to <Return>/<FocusOut> for typed edits.
        ttk::frame $Restrict.minturns
        pack $Restrict.minturns -side top -fill x -pady {0 3}
        ttk::label $Restrict.minturns.label -text "min turns" -width 18 -anchor w
        pack $Restrict.minturns.label -side left -padx {0 4}
        set sb $Restrict.minturns.sb
        ttk::spinbox $sb -from 1 -to [::questlog::config::get turn_count_cap] \
            -width 3 -textvariable [my varname MinTurnsVar] \
            -command [list [self] set_min_turns]
        pack $sb -side left
        bind $sb <<Increment>>  [list [self] set_min_turns]
        bind $sb <<Decrement>>  [list [self] set_min_turns]
        bind $sb <Return>       [list [self] set_min_turns]
        bind $sb <FocusOut>     [list [self] set_min_turns]

        set AddRail $Restrict.add
        ttk::frame $AddRail
        pack $AddRail -side top -fill x -pady {4 0}
        ttk::label $AddRail.label -text "Add filter"
        pack $AddRail.label -side left -padx {0 4}
        foreach {k text} {pattern "+ regex" tool "+ tool"} {
            ttk::button $AddRail.b$k -text $text -style RGhost.TButton \
                -command [list [self] show_tail $k]
            pack $AddRail.b$k -side left -padx {0 4}
        }

        # The list-view toggles (running only / bookmarked only) are not part of
        # the toolbar's chrome: they belong to the session list, so app.tcl hosts
        # them at the top of the list region via build_listview_toggles. The
        # Toolbar still owns their state and the publish wiring; only their
        # on-screen home moved.

        # Render the persistent folder/file rows up front.
        my rebuild_clause_rows
        my refresh_add_rail
    }

    # Build the list-view toggles into a caller-owned frame, so they read as the
    # top of the session list (the region they filter) rather than as a search
    # control. The Toolbar keeps the state (RunningOnlyVar / BookmarkedOnlyVar)
    # and the publish wiring; only the widgets live in the passed parent. $parent
    # is styled by its host to match the list surface, and the checkbuttons take
    # the LV.TCheckbutton style so their background ties to that surface too. The
    # two sit flush right: pack bookmarked-only first with -side right, then
    # running-only, so the reading order stays "running only" then "bookmarked
    # only" while both hug the strip's right edge.
    method build_listview_toggles {parent} {
        ttk::checkbutton $parent.booked -text "bookmarked only" \
            -style LV.TCheckbutton \
            -variable [my varname BookmarkedOnlyVar] \
            -command [list [self] publish]
        pack $parent.booked -side right
        ttk::checkbutton $parent.running -text "running only" \
            -style LV.TCheckbutton \
            -variable [my varname RunningOnlyVar] \
            -command [list [self] publish]
        pack $parent.running -side right -padx {0 16}
    }

    # The search-scope picker. The value is the region-spec the search terms are
    # matched in (parsed by lib/search.tcl parse_regions); the label is the
    # friendly word shown on the button.
    method build_scope_menu {w} {
        ttk::menubutton $w -textvariable [my varname ScopeLabelVar] \
            -menu $w.m -direction below
        menu $w.m -tearoff 0
        foreach {val label} {any "anywhere" user,assistant "user + asst" \
                             tool-use "tool calls" tool-result "tool output" \
                             names "session names"} {
            $w.m add command -label $label \
                -command [list [self] set_scope $val $label]
        }
    }

    method set_scope {val label} {
        set SearchScopeVar $val
        set ScopeLabelVar $label
        my publish
    }

    # Clamp MinTurnsVar to 1..turn_count_cap and publish. The spinbox lets a user
    # type freely, so a non-integer or out-of-range value is coerced back to a
    # sane one (a blank or garbage entry snaps to 1) before it ever reaches the
    # snapshot; the visible value is rewritten too, so the field never shows the
    # rejected text.
    method set_min_turns {} {
        set cap [::questlog::config::get turn_count_cap]
        if {![string is integer -strict $MinTurnsVar]} { set MinTurnsVar 1 }
        if {$MinTurnsVar < 1}    { set MinTurnsVar 1 }
        if {$MinTurnsVar > $cap} { set MinTurnsVar $cap }
        my publish
    }

    # ---- public API --------------------------------------------------------

    # True while the search entry holds the keyboard, so the global Control-b
    # sidebar toggle declines and leaves the entry's own Control-b (cursor left)
    # alone while the user is typing.
    method owns_focus {} { return [expr {[focus] eq "$Top.search.e"}] }

    method subscribe {cb} {
        lappend Subscribers $cb
    }

    # Pre-fill the search field from a launch --keyword. The value is the raw
    # query string the search bar would hold; the one startup publish runs it.
    method set_search {text} { set SearchVar $text; set LastQueryText $text }

    # Press the Aa toggle from a launch --case. The checkbutton's own command
    # publishes; a launch value rides the one startup publish instead.
    method set_case {on} { set SearchCaseVar $on }

    # Pre-select the time row from a launch --since. A preset picks its radio;
    # any other spec the engine accepts (a relative window, an absolute date)
    # becomes the custom member. Validation goes through the one grammar home, so
    # this accepts exactly what the headless CLI does. A bad spec is ignored with
    # a warning, falling back to the default rather than leaving nothing selected.
    method set_window {opt} {
        if {[catch {::questlog::filter::parse_since $opt}]} {
            puts stderr "questlog: ignoring invalid --since '$opt'"
            return
        }
        if {$opt in [::questlog::config::get since_presets]} {
            set WindowVar $opt
        } else {
            set CustomSpec $opt
            set WindowVar $opt
            my refresh_custom_member
        }
    }

    # Re-render only the custom-member sub-frame of the (static) time row. With
    # no custom spec the slot is empty; with one it is a radio in the same group,
    # labelled through the one display-string home, plus a clear button. The
    # radio's value-binding gives parked-to-restore for one click free. The
    # opener and edit affordances that drive the popover are added with it.
    method refresh_custom_member {} {
        set cf $Restrict.time.custom
        foreach c [winfo children $cf] { destroy $c }
        if {$CustomSpec eq ""} {
            ttk::button $cf.open -style RGhost.TButton -text "+ custom…" \
                -command [list [self] open_time_popover]
            pack $cf.open -side left
            return
        }
        ttk::radiobutton $cf.r -text [::questlog::filter::since_label $CustomSpec] \
            -variable [my varname WindowVar] -value $CustomSpec \
            -command [list [self] publish]
        pack $cf.r -side left
        ttk::button $cf.edit -text "✎" -width 2 -style ChipX.TButton \
            -command [list [self] open_time_popover]
        pack $cf.edit -side left -padx {3 0}
        ttk::button $cf.x -text "×" -width 2 -style ChipX.TButton \
            -command [list [self] clear_custom]
        pack $cf.x -side left -padx {2 0}
    }

    # Drop the custom member back to the presets. If it was the active value,
    # reselect the default window so the row never sits with nothing chosen.
    method clear_custom {} {
        if {$WindowVar eq $CustomSpec} {
            set WindowVar [::questlog::config::get since_default]
        }
        set CustomSpec ""
        my refresh_custom_member
        my publish
    }

    # Open the custom-window popover (the move_dialog idiom: a transient toplevel
    # the window manager sizes and places from its packed content). It offers what
    # a preset radio cannot, a relative window or an absolute date via a calendar.
    # Scratch state is prefilled from the current custom spec, so reopening edits.
    method open_time_popover {} {
        set today [clock format [clock seconds] -format %Y-%m-%d]
        set PopMode relative
        set PopNum 3
        set PopUnit days
        set PopDate $today
        set CalMonth "[string range $today 0 6]-01"
        if {$CustomSpec ne ""} {
            lassign [::questlog::filter::parse_since $CustomSpec] kind val
            if {$kind eq "rel"} {
                foreach {word secs} {weeks 604800 days 86400 hours 3600 minutes 60} {
                    if {$val % $secs == 0} {
                        set PopNum [expr {$val / $secs}]
                        set PopUnit $word
                        break
                    }
                }
            } elseif {$kind eq "abs"} {
                set PopMode absolute
                set PopDate $CustomSpec
                set CalMonth "[string range $CustomSpec 0 6]-01"
            }
        }
        my build_popover
    }

    method build_popover {} {
        set p .ql_timepop
        if {[winfo exists $p]} { destroy $p }
        toplevel $p
        set PopTop $p
        wm title $p "Custom window"
        wm transient $p [winfo toplevel $Top]
        ttk::frame $p.f -padding 12
        pack $p.f -fill both -expand 1

        # Relative option: Last <N> <unit>.
        ttk::frame $p.f.rel
        pack $p.f.rel -side top -fill x -anchor w
        ttk::radiobutton $p.f.rel.rb -text "Last" \
            -variable [my varname PopMode] -value relative \
            -command [list [self] refresh_popover]
        pack $p.f.rel.rb -side left
        ttk::spinbox $p.f.rel.n -from 1 -to 999 -width 5 \
            -textvariable [my varname PopNum]
        pack $p.f.rel.n -side left -padx {6 4}
        ttk::combobox $p.f.rel.u -width 9 -state readonly \
            -values {minutes hours days weeks} \
            -textvariable [my varname PopUnit]
        pack $p.f.rel.u -side left

        # Absolute option: Since <date>, revealing the mini-calendar.
        ttk::frame $p.f.abs
        pack $p.f.abs -side top -fill x -anchor w -pady {10 0}
        ttk::radiobutton $p.f.abs.rb -text "Since" \
            -variable [my varname PopMode] -value absolute \
            -command [list [self] refresh_popover]
        pack $p.f.abs.rb -side left
        ttk::label $p.f.abs.d -textvariable [my varname PopDate]
        pack $p.f.abs.d -side left -padx {6 0}

        ttk::frame $p.f.cal
        pack $p.f.cal -side top -fill x -anchor w -pady {6 0}

        ttk::frame $p.f.btn
        pack $p.f.btn -side top -fill x -pady {12 0}
        ttk::button $p.f.btn.apply -text "Apply" -command [list [self] commit_time]
        ttk::button $p.f.btn.cancel -text "Cancel" -command [list [self] close_time_popover]
        pack $p.f.btn.apply -side right
        pack $p.f.btn.cancel -side right -padx {0 6}

        bind $p <Escape> [list [self] close_time_popover]
        wm protocol $p WM_DELETE_WINDOW [list [self] close_time_popover]

        my refresh_popover
        grab set $p
    }

    # Show the mini-calendar only in absolute mode; relative mode hides it.
    method refresh_popover {} {
        if {$PopTop eq "" || ![winfo exists $PopTop]} return
        if {$PopMode eq "absolute"} {
            my build_mini_calendar
        } else {
            foreach c [winfo children $PopTop.f.cal] { destroy $c }
        }
    }

    # Render the month grid for CalMonth into the popover's calendar slot. Month
    # length and the leading weekday come from clock math (leap years included),
    # not a table. Sunday-first; today is tinted, the chosen day filled.
    method build_mini_calendar {} {
        set cal $PopTop.f.cal
        foreach c [winfo children $cal] { destroy $c }
        set loc [::questlog::filter::time_locale]
        set anchor [clock scan $CalMonth -format %Y-%m-%d]
        set monthlabel [clock format $anchor -format "%B %Y" -locale $loc]
        set first_wd [scan [clock format $anchor -format %w] %d]
        set eom  [clock add [clock add $anchor 1 month] -1 day]
        set days [scan [clock format $eom -format %d] %d]
        set today [clock format [clock seconds] -format %Y-%m-%d]
        set y  [scan [string range $CalMonth 0 3] %d]
        set mo [scan [string range $CalMonth 5 6] %d]

        set g $cal.g
        frame $g -bg [::questlog::ui::theme::c chip_bg] \
            -bd 1 -relief solid -highlightthickness 0
        pack $g -side top -anchor w

        # Header: prev, month label, next.
        ttk::button $g.prev -style RGhost.TButton -text "‹" -width 2 \
            -command [list [self] cal_step -1]
        ttk::label  $g.lbl  -text $monthlabel -anchor center \
            -background [::questlog::ui::theme::c chip_bg]
        ttk::button $g.next -style RGhost.TButton -text "›" -width 2 \
            -command [list [self] cal_step 1]
        grid $g.prev -row 0 -column 0 -sticky w
        grid $g.lbl  -row 0 -column 1 -columnspan 5 -sticky ew
        grid $g.next -row 0 -column 6 -sticky e

        # Weekday header row (Sunday first).
        set wd 0
        foreach d {S M T W T F S} {
            label $g.wd$wd -text $d -width 3 -font QLList \
                -bg [::questlog::ui::theme::c chip_bg] \
                -fg [::questlog::ui::theme::c muted]
            grid $g.wd$wd -row 1 -column $wd
            incr wd
        }

        # Day cells.
        set col $first_wd
        set row 2
        for {set d 1} {$d <= $days} {incr d} {
            set iso [format "%04d-%02d-%02d" $y $mo $d]
            set b $g.d$d
            label $b -text $d -width 3 -font QLList \
                -bg [::questlog::ui::theme::c chip_bg] \
                -fg [::questlog::ui::theme::c ink]
            if {$iso eq $PopDate} {
                $b configure -bg [::questlog::ui::theme::c onboard_accent] -fg white
            } elseif {$iso eq $today} {
                $b configure -bg [::questlog::ui::theme::c sel]
            }
            bind $b <Button-1> [list [self] cal_pick $iso]
            grid $b -row $row -column $col -padx 1 -pady 1
            incr col
            if {$col > 6} { set col 0; incr row }
        }
    }

    method cal_step {n} {
        set anchor [clock scan $CalMonth -format %Y-%m-%d]
        set CalMonth [clock format [clock add $anchor $n month] -format %Y-%m-01]
        my build_mini_calendar
    }

    method cal_pick {iso} {
        set PopDate $iso
        set PopMode absolute
        my build_mini_calendar
    }

    # Assemble the chosen spec, validate it through the one grammar home (so the
    # popover can never emit a spec the engine would reject), commit it as the
    # custom member, and publish.
    method commit_time {} {
        if {$PopMode eq "relative"} {
            set unit [dict get {minutes m hours h days d weeks w} $PopUnit]
            set spec "[string trim $PopNum]$unit"
        } else {
            set spec $PopDate
        }
        if {[catch {::questlog::filter::parse_since $spec}]} { bell; return }
        set CustomSpec $spec
        set WindowVar $spec
        my close_time_popover
        my refresh_custom_member
        my publish
    }

    method close_time_popover {} {
        if {$PopTop ne "" && [winfo exists $PopTop]} {
            grab release $PopTop
            destroy $PopTop
        }
        set PopTop ""
    }

    method snapshot {} {
        return [dict create \
            since          $WindowVar \
            search         $SearchVar \
            search_case    $SearchCaseVar \
            search_regions $SearchScopeVar \
            subtree        [dict get $Clauses subtree] \
            file           [dict get $Clauses file] \
            tool           [dict get $Clauses tool] \
            pattern        [dict get $Clauses pattern] \
            min_turns      $MinTurnsVar \
            listview       [dict create \
                running_only    $RunningOnlyVar \
                bookmarked_only $BookmarkedOnlyVar] \
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

    # Live-search debounce: republish after a pause in typing. A key release
    # that left the query text unchanged (cursor moves with Home/End/arrows,
    # selection with Shift, bare modifiers, the trailing release of an Enter)
    # raises no search; only an actual edit arms the timer. The ttk entry has
    # already written SearchVar by KeyRelease, so comparing it is reliable.
    method on_search_change {} {
        if {$SearchVar eq $LastQueryText} {
            ::questlog::debug::log search "keyrelease '$SearchVar' unchanged; no re-search"
            return
        }
        set LastQueryText $SearchVar
        set ms [::questlog::config::get search_debounce_ms]
        ::questlog::debug::log search "keyrelease '$SearchVar' changed; (re)arm ${ms}ms debounce"
        # The user counts as typing through the debounce window, so the browse
        # scan can defer while they type (see scan_while_typing).
        set TypingUntil [expr {[clock milliseconds] + $ms}]
        if {$DebounceAfter ne ""} { my forget $DebounceAfter }
        set DebounceAfter [my later $ms [list [self] debounce_fire]]
    }

    method debounce_fire {} {
        set DebounceAfter ""
        set TypingUntil 0
        ::questlog::debug::log search "debounce elapsed; dispatching search '$SearchVar'"
        my publish
    }

    # Enter: cancel any pending debounce and publish now, so the search runs at
    # once and the trailing KeyRelease cannot fire a second, redundant search.
    method publish_now {} {
        if {$DebounceAfter ne ""} { my forget $DebounceAfter; set DebounceAfter "" }
        set TypingUntil 0
        set LastQueryText $SearchVar
        ::questlog::debug::log search "Return; dispatching search '$SearchVar'"
        my publish
    }

    # True while the user is mid-burst of typing in the search field: a recent
    # keystroke whose debounce window has not elapsed. The browse scan consults
    # this (via app.tcl) to defer while typing. False under search_trigger=enter,
    # where no keystroke advances the deadline.
    method is_typing {} {
        return [expr {[clock milliseconds] < $TypingUntil}]
    }

    # Add a value to a clause, creating/revealing the row as needed. For file
    # the value is an {op path} pair, for tool a {name key} pair, for subtree and
    # pattern a plain string.
    method add_value {kind value} {
        set vals [dict get $Clauses $kind]
        if {$value in $vals} return
        lappend vals $value
        dict set Clauses $kind $vals
        if {$kind in {tool pattern}} { dict set TailShown $kind 1 }
        my rebuild_clause_rows
        my refresh_add_rail
        my publish
    }

    # Remove the value at $idx - the chip whose x was clicked. By index, not
    # by value: an op edit can make two file chips value-equal, and a by-value
    # search would then delete the first twin rather than the clicked one.
    method remove_value_at {kind idx} {
        set vals [dict get $Clauses $kind]
        if {$idx < 0 || $idx >= [llength $vals]} return
        dict set Clauses $kind [lreplace $vals $idx $idx]
        my rebuild_clause_rows
        my refresh_add_rail
        my publish
    }

    # Change the operation on the file value at index $idx (the op pill on a
    # chip). Republishes since the matched tool set changes.
    method set_file_op {idx op} {
        set vals [dict get $Clauses file]
        if {$idx < 0 || $idx >= [llength $vals]} return
        set pair [lindex $vals $idx]
        lset pair 0 $op
        lset vals $idx $pair
        dict set Clauses file $vals
        my rebuild_clause_rows
        my publish
    }

    # The op for the next file value added. Bound to the add-area op pill's
    # label, so no rebuild is needed to reflect the change.
    method set_add_op {op} { set AddOp $op }

    # Reveal a tail row (regex or tool) and open its editor for immediate typing.
    method show_tail {kind} {
        my begin_edit $kind
        my refresh_add_rail
    }

    # Morph a row's collapsed [+]/[+ or] button into the inline editor in place.
    # A tail row is also marked shown. EditFocusKind records which editor holds
    # focus across this rebuild and any later collateral one (a chip removed in
    # another row, an op changed). The rebuild draws the editor; focus_add lands
    # the caret.
    method begin_edit {kind} {
        set AddState($kind) editing
        set EditFocusKind $kind
        if {$kind in {tool pattern}} { dict set TailShown $kind 1 }
        my rebuild_clause_rows
        my focus_add $kind
    }

    # Collapse the editor back to its button, discarding any unconfirmed text.
    # No publish, since nothing was added.
    method cancel_edit {kind} {
        set AddState($kind) collapsed
        set AddText($kind) ""
        if {$EditFocusKind eq $kind} { set EditFocusKind "" }
        my rebuild_clause_rows
    }

    # Put the caret in a row's editor entry once the rebuild has drawn it.
    method focus_add {kind} {
        catch {focus [dict get $RowFrames $kind].chips.add.field.e}
    }

    # ---- add-entry commit handlers (popup-free; inline in each row) ---------

    # The typed path is canonicalised (tilde-expanded, normalized) before it
    # becomes a chip, so the snapshot's subtree list only ever carries the
    # absolute form the row predicates compare against. A path that cannot be
    # expanded (an unknown ~user) stays in the editor with a bell rather than
    # becoming a chip that silently matches nothing.
    method commit_folder_add {} {
        set v [string trim $AddText(subtree)]
        if {$v eq ""} { my cancel_edit subtree; return }
        if {[catch {::questlog::path::canon_dir $v} v]} { bell; return }
        set AddText(subtree) ""
        set AddState(subtree) collapsed
        my add_value subtree $v
    }

    method commit_file_add {} {
        set v [string trim $AddText(file)]
        if {$v eq ""} { my cancel_edit file; return }
        # A ~-headed path expands the way the subtree editor's does (Tcl 9
        # expands ~ nowhere, and the matcher would compare it literally); a
        # bare path tail (main.tcl) stays untouched - matching from the right
        # is the feature.
        if {[string index $v 0] eq "~"} {
            if {[catch {::questlog::path::canon_dir $v} v]} { bell; return }
        }
        set AddText(file) ""
        set AddState(file) collapsed
        my add_value file [list $AddOp $v]
    }

    method commit_pattern_add {} {
        set v [string trim $AddText(pattern)]
        if {$v eq ""} { my cancel_edit pattern; return }
        # An unparseable regex stays in the editor with a bell rather than
        # becoming a chip whose first execution would abort every search.
        if {[catch {regexp -- $v {}}]} { bell; return }
        set AddText(pattern) ""
        set AddState(pattern) collapsed
        my add_value pattern $v
    }

    # name "" reads the typed tool name; the quick-pick menu passes the name in.
    method commit_tool_add {{name ""}} {
        if {$name eq ""} { set name [string trim $AddText(tool)] }
        if {$name eq ""} { my cancel_edit tool; return }
        set AddText(tool) ""
        set AddState(tool) collapsed
        my add_value tool [list $name ""]
    }

    # The picked path goes through the same canonicaliser as a typed one, so a
    # dir reached both ways dedups to one chip.
    method browse_folder {} {
        set d [tk_chooseDirectory -initialdir $Cwd -mustexist 1]
        if {$d ne ""} {
            set AddState(subtree) collapsed
            my add_value subtree [::questlog::path::canon_dir $d]
        }
    }

    method browse_file {} {
        set f [tk_getOpenFile -initialdir $Cwd]
        if {$f ne ""} { set AddState(file) collapsed; my add_value file [list $AddOp $f] }
    }

    # ---- row management ----------------------------------------------------

    # Destroy every clause-row frame and reconstruct the present ones in
    # canonical reading order between the time row and the add rail. The folder
    # and file rows are persistent (always shown, with a ghost add entry when
    # empty); the tool and pattern tail rows show once revealed or non-empty.
    method rebuild_clause_rows {} {
        foreach k {subtree file tool pattern} {
            if {[dict exists $RowFrames $k]} {
                destroy [dict get $RowFrames $k]
                dict unset RowFrames $k
            }
        }
        # kind -> styling type; pattern draws in the regex tint.
        set ctype {subtree subtree file file tool tool pattern regex}
        foreach k {subtree file pattern tool} {
            set vals [dict get $Clauses $k]
            set persistent [expr {$k in {subtree file}}]
            set shown [expr {$persistent || [dict getdef $TailShown $k 0] \
                             || [llength $vals] > 0}]
            if {!$shown} continue
            set t [dict get $ctype $k]
            set row $Restrict.row_$k
            ttk::frame $row
            # The type tag is a rounded tinted pill: the qlPill_<t> image gives
            # the shape and fill, the display word is drawn centred over it, and
            # the label background matches the panel so the pill's corners blend.
            # The display word is the user-facing English for the styling type,
            # decoupled from the identifier: the subtree pill reads "under".
            label $row.label -image qlPill_$t -compound center \
                -text [dict get {subtree under file file tool tool regex regex} $t] \
                -anchor center -borderwidth 0 \
                -background [ttk::style lookup . -background] \
                -foreground [::questlog::ui::theme::c crit_${t}_fg]
            pack $row.label -side left -padx {0 6} -pady 1
            ttk::label $row.conn -text [dict get {
                subtree "ran under" file "touched" tool "used" pattern "matches"
            } $k]
            pack $row.conn -side left -padx {0 6}
            ttk::frame $row.chips
            pack $row.chips -side left -fill x -expand 1
            my render_chips $k $t $row.chips
            pack $row -side top -fill x -before $AddRail -pady 1
            dict set RowFrames $k $row
        }
        my refresh_heading
        # A rebuild destroys the focused editor entry; if a row is mid-edit,
        # restore the caret so a collateral rebuild (a chip removed elsewhere, an
        # op changed) does not silently drop focus while the user is typing.
        if {$EditFocusKind ne "" && $AddState($EditFocusKind) eq "editing"} {
            my focus_add $EditFocusKind
        }
    }

    # Update the restrict heading with a count of active clauses, so the legend
    # reads "Restrict to sessions that…  N active" (count omitted at zero).
    method refresh_heading {} {
        set n 0
        foreach k {subtree file tool pattern} {
            if {[llength [dict get $Clauses $k]] > 0} { incr n }
        }
        set txt "Restrict to sessions that…"
        if {$n > 0} { append txt "   $n active" }
        $RestrictHd configure -text $txt
    }

    # Render a row's value chips into $cf, then the inline add affordance. A
    # file chip carries an op pill; a tool chip shows its name (and key, if any).
    method render_chips {kind type cf} {
        set white [::questlog::ui::theme::c chip_bg]
        set vals [dict get $Clauses $kind]
        set i 0
        foreach v $vals {
            if {$i > 0} {
                ttk::label $cf.or$i -text "or" \
                    -foreground [::questlog::ui::theme::c chip_or]
                pack $cf.or$i -side left -padx 4
            }
            set chip $cf.c$i
            ttk::frame $chip -style Crit_$type.TFrame -padding {4 1}
            # The × packs first so it anchors at the chip's left edge: a
            # sentence-long criterion grows its text rightward off-screen, but the
            # delete button stays reachable in the viewport.
            ttk::button $chip.x -text "×" -width 2 -style ChipX.TButton \
                -command [list [self] remove_value_at $kind $i]
            pack $chip.x -side left -padx {0 2}
            if {$kind eq "file"} {
                lassign $v op path
                my op_pill $chip.op $op [list [self] set_file_op $i]
                pack $chip.op -side left -padx {0 4}
                label $chip.t -text [::questlog::path::pretty_home $path] \
                    -background $white -foreground [::questlog::ui::theme::c ink] -font QLMono
            } else {
                label $chip.t -text [my chip_display $kind $v] \
                    -background $white -foreground [::questlog::ui::theme::c ink] -font QLMono
            }
            pack $chip.t -side left
            pack $chip -side left
            incr i
        }
        my render_add $kind $cf
    }

    # The inline add affordance for a row: collapsed to a single ghost button, or
    # morphed in place into a row-appropriate editor. AddState($kind) decides
    # which form to draw; the morph itself is just a rebuild_clause_rows.
    method render_add {kind cf} {
        if {$AddState($kind) eq "editing"} {
            my render_editor $kind $cf
        } else {
            my render_add_button $kind $cf
        }
    }

    # The collapsed affordance: "+" on an empty row, "+ or" once the row carries
    # a value. It packs after the last chip, so "+ or" reads as "OR another".
    method render_add_button {kind cf} {
        set has [expr {[llength [dict get $Clauses $kind]] > 0}]
        ttk::button $cf.add -style RGhost.TButton \
            -text [expr {$has ? "+ or" : "+"}] \
            -command [list [self] begin_edit $kind]
        pack $cf.add -side left -padx {4 0}
    }

    # The expanded inline editor, built where the add button was. Row-appropriate:
    # file gets an op pill and an open-file glyph, folder a directory glyph, tool
    # the name picker, regex a bare mono field. The entry's text lives in
    # AddText($kind) so it survives the rebuilds other edits trigger; Return
    # commits, Escape cancels. The borderless entry plus the glyph sit inside a
    # rounded Field.TFrame plate so the pair reads as one control.
    method render_editor {kind cf} {
        set ae $cf.add
        ttk::frame $ae
        if {$kind eq "file"} {
            my op_pill $ae.op $AddOp [list [self] set_add_op] [my varname AddOp]
            pack $ae.op -side left -padx {0 3}
        }
        set mono [expr {$kind eq "pattern"}]
        ttk::frame $ae.field -style Field.TFrame -padding {6 2}
        tk::entry $ae.field.e -width 22 -relief flat -borderwidth 0 \
            -highlightthickness 0 \
            -background [::questlog::ui::theme::c chip_bg] \
            -foreground [::questlog::ui::theme::c ink] \
            -textvariable [my varname AddText]($kind) \
            -font [expr {$mono ? "QLMono" : "TkTextFont"}]
        set commit [switch -- $kind {
            subtree { list [self] commit_folder_add }
            file    { list [self] commit_file_add }
            pattern { list [self] commit_pattern_add }
            tool    { list [self] commit_tool_add }
        }]
        bind $ae.field.e <Return> $commit
        bind $ae.field.e <Escape> [list [self] cancel_edit $kind]
        # The open glyph packs first against the right edge so the entry fills the
        # rest and its text never runs under it.
        switch -- $kind {
            file  { my add_icon $ae.field.icon "\U0001F4C2" [list [self] browse_file] }
            subtree { my add_icon $ae.field.icon "\U0001F4C1" [list [self] browse_folder] }
        }
        pack $ae.field.e -side left -fill x -expand 1
        pack $ae.field -side left
        if {$kind eq "tool"} {
            my build_tool_menu $ae.pick
            pack $ae.pick -side left -padx {3 0}
        }
        pack $ae -side left -padx {4 0}
    }

    # A small clickable open glyph at the right edge of an add field. Mouse-only
    # (no tab stop); it shares the field's fill so it reads as part of the field.
    method add_icon {w glyph cmd} {
        label $w -text $glyph -background [::questlog::ui::theme::c chip_bg] \
            -borderwidth 0 -highlightthickness 0 -cursor hand2 -takefocus 0
        bind $w <Button-1> $cmd
        pack $w -side right -padx {2 4}
    }

    # A colored operation pill on a file chip (or the add area). It posts a menu
    # anchored to itself; selecting an op runs $cmdprefix with the op appended.
    # When $tvar is given the label tracks that variable (the add-area pill);
    # otherwise the label is the fixed $op of an existing chip.
    method op_pill {w op cmdprefix {tvar ""}} {
        set bg [::questlog::ui::theme::c op_${op}_bg]
        set fg [::questlog::ui::theme::c op_${op}_fg]
        menubutton $w -menu $w.m -indicatoron 1 -relief raised -borderwidth 1 \
            -background $bg -foreground $fg -activebackground $bg \
            -activeforeground $fg -padx 4 -pady 0 -font QLList -takefocus 1
        if {$tvar ne ""} { $w configure -textvariable $tvar } else { $w configure -text $op }
        menu $w.m -tearoff 0
        foreach o {either read wrote} {
            $w.m add command -label $o -command [concat $cmdprefix [list $o]]
        }
    }

    method build_tool_menu {w} {
        ttk::menubutton $w -text "pick ▾" -menu $w.m -direction below
        menu $w.m -tearoff 0
        foreach name {Bash Read Edit Write Grep Glob WebSearch WebFetch Task} {
            $w.m add command -label $name \
                -command [list [self] commit_tool_add $name]
        }
    }

    # subtree chips render ~-abbreviated; tool shows name (and key, if set);
    # pattern renders the raw regex. file chips are handled in render_chips.
    method chip_display {kind value} {
        switch -- $kind {
            subtree { return [::questlog::path::pretty_home $value] }
            tool {
                lassign $value name key
                return [expr {$key eq "" ? $name : "$name: $key"}]
            }
            default { return $value }
        }
    }

    method refresh_add_rail {} {
        foreach k {pattern tool} {
            set btn $AddRail.b$k
            set shown [expr {[dict getdef $TailShown $k 0] \
                             || [llength [dict get $Clauses $k]] > 0}]
            if {$shown} {
                pack forget $btn
            } else {
                pack $btn -side left -padx {0 4}
            }
        }
    }

}
