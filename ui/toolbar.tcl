package require Tcl 9
package require Tk
package require facetbar

# ::questlog::ui::Toolbar - the top-of-window controls.
#
# The criteria block (the "Restrict" box) is a ::facetbar::FacetBar: the chip
# strip, the connective, the inline add, the add rail, the collapse disclosure
# and the active count are the module's, and questlog hands it six descriptors
# saying what its criteria mean - the formatter that prints a value, the editor
# that picks one, the op pill a file value carries. The bar's model (facet id ->
# list of values) is where those six criteria live; `snapshot` reads it back into
# the keys below, which are what every subscriber has always seen.
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
#                    the corpus, not just the view - see lib/scope.tcl.
#   cwd              launch cwd, constant after startup
#
# The session-list lenses (running, bookmarked, model) are not here: they live
# on the list's own strip and re-filter the loaded rows in place, so no toolbar
# key carries them - see ui/sessions.tcl.

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
    variable MinTurnsModel    ;# the min_turns values the model held when the editor last read it
    variable Bar              ;# the ::facetbar::FacetBar holding the six criteria
    variable Restrict         ;# the bordered frame the bar is built into
    variable Clamp            ;# the frame Restrict is placed in: see fit_now
    variable AddText          ;# array kind -> the add-entry's pending text
    variable AddOp            ;# op for the next file value added (either|read|wrote)
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
        set MinTurnsModel [my turns_vals $MinTurnsVar]
        set Subscribers [list]
        array set AddText {subtree {} file {} tool {} pattern {}}
        set AddOp either
        set DebounceAfter ""
        set TypingUntil 0
        set LastQueryText ""

        my build
    }

    method build {} {
        ttk::frame $Top

        # The criteria bar draws through the rounded image-element styles built
        # once in theme::build_chrome and handed to the module by name: the white
        # value chip Crit_<t>.TFrame, the tinted type pill Pill_<t>.TLabel, the
        # faint × ChipX.TButton, the ghost add RGhost.TButton. The op pill on a
        # file chip is questlog's own widget, in the op_<op>_{bg,fg} colours.

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

        # Restrict group: the criteria bar, in a lightly-bordered box whose first
        # inner line is the heading (the legend sits inside, at the top, as in the
        # design). The box is the frame the module builds into; questlog owns the
        # border and the padding, facetbar owns everything within.
        #
        # Clamp is the box's parent, and the box is placed in it, not packed:
        # place passes no request up, so the width the box asks for stops here,
        # which is where it has to stop. A chip area is itself place-managed and
        # asks for the width of its widest chip, so a sentence-long path would
        # otherwise push that request up through the pane and widen the window,
        # when what it should do is wrap. -relwidth 1 hands the box the width the
        # clamp was given, which is the pane's, and the bar wraps inside it.
        #
        # The height still has to reach the window, so the clamp carries it, and
        # fit_now keeps it at whatever the box asks for. A placed child is always
        # given the height it requests, so every change in that request arrives
        # here as its <Configure> - which is the whole reason the box is placed
        # rather than packed with propagation off: pack would clip a box that grew
        # past the clamp and raise no <Configure> to say so, and the row that grew
        # (or the add rail below it) would silently go missing.
        set Clamp $Top.crit
        ttk::frame $Clamp
        pack $Clamp -side top -fill x -padx 6 -pady {2 2}
        set Restrict $Clamp.bar
        ttk::frame $Restrict -relief solid -borderwidth 1 -padding {8 5}
        place $Restrict -x 0 -y 0 -relwidth 1

        set Bar [::facetbar::FacetBar new]
        # The delete sits at the chip's left, against the usual side, because these
        # values are paths and patterns: a chip holding one can be wider than the
        # bar, and the end that runs out of view is the far one. A delete anchored
        # where the text starts stays reachable on every chip.
        # -gaps is where a host scales the bar, and the chips take their padding
        # from it too (their style names none), so the criteria bar's spacing
        # tracks the font like the rest of the chrome instead of holding the
        # module's raw pixels under text that has doubled. theme::crit_gaps says
        # what the numbers are.
        # The heading count is what the user has added, so it sums only the four
        # content criteria. since and min_turns carry a standing default that
        # restricts the corpus from the first frame; a count that tallied them
        # would read "2 active" on a bare launch where the user has chosen nothing.
        # Named out of -countables, they still hold their value and raise no count.
        $Bar configure -heading "Restrict to sessions that…" \
            -raillabel "Add filter" -changecb [list [self] on_criteria] \
            -delside left \
            -gaps [::questlog::ui::theme::crit_gaps] \
            -countables {subtree file pattern tool} \
            -styles {heading  FacetHeading.TLabel
                     toggle   FacetToggle.TButton
                     conn     FacetConn.TLabel
                     or       FacetOr.TLabel
                     chiptext FacetChipText.TLabel
                     del      ChipX.TButton
                     add      RGhost.TButton} \
            -facets [my facets]
        # The bar opens on the configured defaults, which are criteria like any
        # other: a seven-day window and a two-turn floor do restrict the corpus,
        # so the model holds them, the heading counts them, and a collapsed bar
        # shows them. set_model, so the opening state raises no publish - and
        # before setup, because an editor is a function of the model: drawn
        # against an empty one it would first reset the very variables the
        # defaults are being read out of.
        $Bar set_model [list since     [my since_vals $WindowVar] \
                             min_turns [my turns_vals $MinTurnsVar]]
        $Bar setup $Restrict
        # The resting face is the chip summary: the bar opens collapsed, showing
        # the seeded criteria as chips under the disclosure, and expands when the
        # user goes to edit one. A host-side call, so the module keeps its own
        # expanded default that every other host relies on.
        $Bar collapse
        # The box's height, whenever it changes: a chip added, a row revealed, the
        # disclosure folded, a chip wrapping to a second line at a narrower pane.
        # %h, from the event, and no path spliced into the script: bind runs its %
        # substitutions over whatever it is handed.
        bind $Restrict <Configure> [list [self] fit_now %h]
    }

    # Relax one criterion, for the list's cut banner: the lens member it names was
    # left on disk by exactly this criterion, so dropping it is what brings the
    # session into the next load. `search` drops every content criterion, not the
    # search box alone - a file, tool or regex clause decides what loads just as
    # the typed terms do, and clearing half of them would leave the session as
    # invisible as before while the banner claimed otherwise. One publish, as with
    # every other control here.
    method widen {criterion} {
        switch -- $criterion {
            since   { my quiet_set {since {}} }
            subtree { my quiet_set {subtree {}} }
            search {
                set SearchVar ""
                set LastQueryText ""
                my quiet_set {file {} tool {} pattern {}}
            }
            min_turns { my quiet_set {min_turns {}} }
            default   { return }
        }
        my publish
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

    # Clamp MinTurnsVar to 1..turn_count_cap and report the floor. The spinbox lets
    # a user type freely, so a non-integer or out-of-range value is coerced back to
    # a sane one (a blank or garbage entry snaps to 1) before it ever reaches the
    # snapshot; the visible value is rewritten too, so the field never shows the
    # rejected text. A floor of 1 excludes no session, so it is no criterion and
    # the facet holds no value there. Reported, not set: report_values leaves the
    # spinbox standing under the hand still on it. A floor that did not move is not
    # reported at all, which keeps the <FocusOut> that a rebuild raises from
    # publishing a change nobody made.
    method set_min_turns {} {
        set cap [::questlog::config::get turn_count_cap]
        if {![string is integer -strict $MinTurnsVar]} { set MinTurnsVar 1 }
        if {$MinTurnsVar < 1}    { set MinTurnsVar 1 }
        if {$MinTurnsVar > $cap} { set MinTurnsVar $cap }
        set want [my turns_vals $MinTurnsVar]
        # The commit is what makes the typed floor the model's, so this is where
        # the editor's picture of the model catches up with it (see turns_editor:
        # a later redraw must not mistake this floor for one it has yet to read).
        set MinTurnsModel $want
        if {$want eq [$Bar values min_turns]} return
        $Bar report_values min_turns $want
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
        if {[catch {::questlog::scope::parse_since $opt}]} {
            puts stderr "questlog: ignoring invalid --since '$opt'"
            return
        }
        if {$opt ni [::questlog::config::get since_presets]} { set CustomSpec $opt }
        my quiet_set [list since [my since_vals $opt]]
    }

    # Re-render only the custom-member sub-frame of the time row's editor. With no
    # custom spec the slot is empty; with one it is a radio in the same group,
    # labelled through the one display-string home, plus a clear button. The
    # radio's value-binding gives parked-to-restore for one click free. The
    # opener and edit affordances that drive the popover are added with it. The
    # slot is gone while the bar is collapsed, and the editor rebuilds it whole on
    # the next expand, so there is nothing to re-render then.
    method refresh_custom_member {} {
        set ed [my since_area]
        if {$ed eq ""} return
        set cf $ed.custom
        foreach c [winfo children $cf] { destroy $c }
        if {$CustomSpec eq ""} {
            ttk::button $cf.open -style RGhost.TButton -text "+ custom…" \
                -command [list [self] open_time_popover]
            pack $cf.open -side left
            return
        }
        ttk::radiobutton $cf.r -text [::questlog::scope::since_label $CustomSpec] \
            -variable [my varname WindowVar] -value $CustomSpec \
            -command [list [self] set_since]
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
    # set_values, not report_values: the row must be drawn again without the
    # member this just took off it.
    method clear_custom {} {
        set vals [$Bar values since]
        if {[lindex $vals 0] eq $CustomSpec} {
            set vals [my since_vals [::questlog::config::get since_default]]
        }
        set CustomSpec ""
        $Bar set_values since $vals
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
            lassign [::questlog::scope::parse_since $CustomSpec] kind val
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
        set loc [::questlog::scope::time_locale]
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
    # custom member, and publish. set_values draws the time row again, this time
    # with the custom member selected, and publishes the criterion in one step.
    method commit_time {} {
        if {$PopMode eq "relative"} {
            set unit [dict get {minutes m hours h days d weeks w} $PopUnit]
            set spec "[string trim $PopNum]$unit"
        } else {
            set spec $PopDate
        }
        if {[catch {::questlog::scope::parse_since $spec}]} { bell; return }
        set CustomSpec $spec
        my close_time_popover
        $Bar set_values since [my since_vals $spec]
    }

    method close_time_popover {} {
        if {$PopTop ne "" && [winfo exists $PopTop]} {
            grab release $PopTop
            destroy $PopTop
        }
        set PopTop ""
    }

    # The snapshot every subscriber reads. The six criteria come out of the bar's
    # model, back into the keys they have always had: the two facets that hold no
    # value at their floor (an "all" time bound, a one-turn floor) publish that
    # floor, since lib/scope.tcl reads a value there and not an absence.
    method snapshot {} {
        set m [$Bar model]
        return [dict create \
            since          [my since_value] \
            search         $SearchVar \
            search_case    $SearchCaseVar \
            search_regions $SearchScopeVar \
            subtree        [dict get $m subtree] \
            file           [dict get $m file] \
            tool           [dict get $m tool] \
            pattern        [dict get $m pattern] \
            min_turns      [my turns_value] \
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


    # ---- the criteria, as facetbar sees them -------------------------------

    # The six criteria as facetbar descriptors, in reading order. The module owns
    # the chips, the connective, the inline add, the rail, the disclosure and the
    # count; each descriptor hands back the business - what a value means
    # (format), how one is picked (editor), and, on a file value, the read/wrote/
    # either the criterion applies to (chipctl, the per-value control in a chip).
    #
    # time and min turns are `control` facets: one bounded choice each, edited by
    # the radio group and the spinbox the design draws rather than typed in and
    # chipped, hence `max 1`. They carry no connective, because the tag already
    # labels the row and an absolute date ("since 1/04/2026") has no preposition
    # that "ran in the last" would not break. Neither holds a value at its floor -
    # "all" is no time bound, and a floor of one turn excludes no session - so at
    # rest they raise no chip and count towards no criterion, which is what a
    # heading reading "Restrict to sessions that… N active" promises.
    #
    # regex and tool are tails: they wait on the add rail until they are asked
    # for, or until a launch seeds one with a value.
    method facets {} {
        return [list \
            [list id since label "time" mode control max 1 \
                 format [list [self] since_chip] \
                 editor [list [self] since_editor] \
                 tagstyle Pill_time.TLabel chipstyle Crit_time.TFrame] \
            [list id min_turns label "min turns" mode control max 1 \
                 editor [list [self] turns_editor] \
                 tagstyle Pill_turns.TLabel chipstyle Crit_turns.TFrame] \
            [list id subtree label "folder" conn "ran under" \
                 format [list [self] path_chip] \
                 editor [list [self] chip_editor] \
                 tagstyle Pill_subtree.TLabel chipstyle Crit_subtree.TFrame] \
            [list id file label "file" conn "touched" \
                 format [list [self] file_chip] \
                 editor [list [self] chip_editor] \
                 chipctl [list [self] file_op_pill] \
                 tagstyle Pill_file.TLabel chipstyle Crit_file.TFrame] \
            [list id pattern label "regex" conn "matches" tail 1 railtext "+ regex" \
                 editor [list [self] chip_editor] \
                 tagstyle Pill_regex.TLabel chipstyle Crit_regex.TFrame] \
            [list id tool label "tool" conn "used" tail 1 railtext "+ tool" \
                 format [list [self] tool_chip] \
                 editor [list [self] chip_editor] \
                 tagstyle Pill_tool.TLabel chipstyle Crit_tool.TFrame]]
    }

    # The bar's one door: a criterion changed, and the model is what it now is.
    # The whole snapshot goes out, as it does for every other control here, so a
    # subscriber never has to know which of the two halves of the toolbar moved.
    method on_criteria {model} { my publish }

    # Write facet values without waking the change callback: for the paths that
    # publish once themselves (the launch seed, the list's widen escape), where a
    # per-facet door would publish once per facet and start a search for each.
    # set_model takes the whole model, so it is merged over what the bar holds.
    method quiet_set {overrides} {
        $Bar set_model [dict merge [$Bar model] $overrides]
    }

    # A time spec, and a turn floor, as their facets hold them: no value at the
    # floor, since "all" bounds no time and a floor of one turn excludes no
    # session, and a criterion that restricts nothing is no criterion.
    method since_vals {spec} {
        return [expr {$spec eq "all" ? {} : [list $spec]}]
    }

    method turns_vals {n} {
        return [expr {$n <= 1 ? {} : [list $n]}]
    }

    # The two floors, read back for the snapshot: the keys lib/scope.tcl reads
    # carry a value even where the facet holds none.
    method since_value {} {
        set v [lindex [$Bar values since] 0]
        return [expr {$v eq "" ? "all" : $v}]
    }

    method turns_value {} {
        set v [lindex [$Bar values min_turns] 0]
        return [expr {$v eq "" ? 1 : $v}]
    }

    # Open a row's inline editor from outside the bar (a test, a driving script):
    # the bar reveals a tail row and expands itself if it has to.
    method begin_edit {kind} { $Bar begin_add $kind }

    # The criteria box's height, passed on to the clamp that holds it: place gives
    # a child the height it asks for, so this is that height, and the clamp is the
    # one frame between the bar and the window that still carries it upward.
    method fit_now {h} {
        if {$h > 1} { $Clamp configure -height $h }
    }

    # ---- the time facet's editor -------------------------------------------

    method since_chip {spec} { return [::questlog::scope::since_label $spec] }

    # The time row's whole editor: the preset radios, then the custom member. It
    # is a function of the facet's values, redrawn from them every time the row
    # is - so a time bound deleted from its chip while the bar was collapsed comes
    # back with "all" selected, and no radio is left showing a criterion that is
    # no longer applied.
    method since_editor {parent id values} {
        set WindowVar [expr {[llength $values] ? [lindex $values 0] : "all"}]
        foreach w [::questlog::config::get since_presets] {
            ttk::radiobutton $parent.r$w -text $w \
                -variable [my varname WindowVar] -value $w \
                -command [list [self] set_since]
            pack $parent.r$w -side left -padx 2
        }
        # The custom 5th member of the same single-select group: a relative window
        # or an absolute date the presets cannot express. Its own sub-frame, so
        # committing or clearing re-renders only this, never the presets.
        ttk::frame $parent.custom
        pack $parent.custom -side left -padx {6 0}
        my refresh_custom_member
    }

    # The time editor's area, at the widget path the module documents, or "" while
    # the bar is collapsed and there is no editor row to reach into.
    method since_area {} {
        set ed $Restrict.body.rows.ed_since
        return [expr {[winfo exists $ed] ? $ed : ""}]
    }

    # A radio in the time group was chosen. report_values, not set_values: the bar
    # must not rebuild the radio group under the click that just moved it.
    method set_since {} {
        set want [my since_vals $WindowVar]
        if {$want eq [$Bar values since]} return
        $Bar report_values since $want
    }

    # ---- the min-turns facet's editor ---------------------------------------

    # The minimum-turns scope floor: a spinbox over 1..turn_count_cap. 1 includes
    # all; a higher floor drops shorter sessions from the corpus (it is scope, not
    # a view toggle - see lib/scope.tcl). set_min_turns clamps to the valid range
    # and reports, so a bad keystroke can never leave an out-of-range value; it is
    # wired to the buttons (-command, <<Increment>>/<<Decrement>>) and to
    # <Return>/<FocusOut> for typed edits.
    #
    # A half-typed floor stands through a redraw, as a half-typed chip does. This
    # is the one editor here with typeable state the model has not been told about,
    # and every draw of its row would otherwise re-read the model over the top of
    # it: reveal a tail facet, collapse the bar, seed it from the launch query, and
    # the 5 that was typed but not entered would silently become the 2 that is in
    # force. So the model is read back only when the model itself moved (which is
    # what MinTurnsModel remembers); a redraw that carries the same floor through
    # leaves the spinbox exactly as the hand left it. The typed value is still not
    # published until it is committed - that part is the point.
    method turns_editor {parent id values} {
        if {$values ne $MinTurnsModel} {
            set MinTurnsVar [expr {[llength $values] ? [lindex $values 0] : 1}]
            set MinTurnsModel $values
        }
        set sb $parent.sb
        ttk::spinbox $sb -from 1 -to [::questlog::config::get turn_count_cap] \
            -width 3 -textvariable [my varname MinTurnsVar] \
            -command [list [self] set_min_turns]
        pack $sb -side left
        bind $sb <<Increment>>  [list [self] set_min_turns]
        bind $sb <<Decrement>>  [list [self] set_min_turns]
        bind $sb <Return>       [list [self] set_min_turns]
        bind $sb <FocusOut>     [list [self] set_min_turns]
    }

    # ---- the chip facets' editor --------------------------------------------

    # The inline add editor, built into the frame the bar hands over when a "+" is
    # pressed. Row-appropriate: file gets the op pill and an open-file glyph,
    # folder a directory glyph, tool the name picker, regex a bare mono field. The
    # typed text lives in AddText($id), so a redraw elsewhere in the bar leaves it
    # standing; Return commits through that row's own validator, Escape abandons.
    # The editor takes the caret itself, as the module asks it to: only the editor
    # knows which of the widgets it built is the one that takes typing.
    method chip_editor {parent id values} {
        if {$id eq "file"} {
            my op_pill $parent.op $AddOp [list [self] set_add_op] [my varname AddOp]
            pack $parent.op -side left -padx {0 3}
        }
        set mono [expr {$id eq "pattern"}]
        ttk::frame $parent.field -style Field.TFrame -padding {6 2}
        tk::entry $parent.field.e -width 22 -relief flat -borderwidth 0 \
            -highlightthickness 0 \
            -background [::questlog::ui::theme::c chip_bg] \
            -foreground [::questlog::ui::theme::c ink] \
            -textvariable [my varname AddText]($id) \
            -font [expr {$mono ? "QLMono" : "TkTextFont"}]
        set commit [switch -- $id {
            subtree { list [self] commit_folder_add }
            file    { list [self] commit_file_add }
            pattern { list [self] commit_pattern_add }
            tool    { list [self] commit_tool_add }
        }]
        bind $parent.field.e <Return> $commit
        bind $parent.field.e <Escape> [list [self] cancel_add $id]
        # The open glyph packs first against the right edge so the entry fills the
        # rest and its text never runs under it.
        switch -- $id {
            file    { my add_icon $parent.field.icon "\U0001F4C2" [list [self] browse_file] }
            subtree { my add_icon $parent.field.icon "\U0001F4C1" [list [self] browse_folder] }
        }
        pack $parent.field.e -side left -fill x -expand 1
        pack $parent.field -side left
        if {$id eq "tool"} {
            my build_tool_menu $parent.pick
            pack $parent.pick -side left -padx {3 0}
        }
        focus $parent.field.e
    }

    # Escape: the unconfirmed text goes with the editor it was typed into. The bar
    # closes that editor, and puts a tail row revealed only to be typed into back
    # on the rail.
    method cancel_add {kind} {
        set AddText($kind) ""
        $Bar cancel_add $kind
    }

    # ---- add-entry commit handlers (popup-free; inline in each row) ---------

    # The typed path is canonicalised (tilde-expanded, normalized) before it
    # becomes a chip, so the snapshot's subtree list only ever carries the
    # absolute form the row predicates compare against. A path that cannot be
    # expanded (an unknown ~user) stays in the editor with a bell rather than
    # becoming a chip that silently matches nothing. The text is cleared before
    # the value lands, because the bar leaves the editor open for the next value
    # and redraws it from AddText as it does.
    method commit_folder_add {} {
        set v [string trim $AddText(subtree)]
        if {$v eq ""} { my cancel_add subtree; return }
        if {[catch {::questlog::path::canon_dir $v} v]} { bell; return }
        set AddText(subtree) ""
        $Bar add_value subtree $v
    }

    method commit_file_add {} {
        set v [string trim $AddText(file)]
        if {$v eq ""} { my cancel_add file; return }
        # A ~-headed path expands the way the subtree editor's does (Tcl 9
        # expands ~ nowhere, and the matcher would compare it literally); a
        # bare path tail (main.tcl) stays untouched - matching from the right
        # is the feature.
        if {[string index $v 0] eq "~"} {
            if {[catch {::questlog::path::canon_dir $v} v]} { bell; return }
        }
        set AddText(file) ""
        $Bar add_value file [list $AddOp $v]
    }

    method commit_pattern_add {} {
        set v [string trim $AddText(pattern)]
        if {$v eq ""} { my cancel_add pattern; return }
        # An unparseable regex stays in the editor with a bell rather than
        # becoming a chip whose first execution would abort every search.
        if {[catch {regexp -- $v {}}]} { bell; return }
        set AddText(pattern) ""
        $Bar add_value pattern $v
    }

    # name "" reads the typed tool name; the quick-pick menu passes the name in.
    method commit_tool_add {{name ""}} {
        if {$name eq ""} { set name [string trim $AddText(tool)] }
        if {$name eq ""} { my cancel_add tool; return }
        set AddText(tool) ""
        $Bar add_value tool [list $name ""]
    }

    # The picked path goes through the same canonicaliser as a typed one, so a
    # dir reached both ways dedups to one chip.
    method browse_folder {} {
        set d [tk_chooseDirectory -initialdir $Cwd -mustexist 1]
        if {$d ne ""} { $Bar add_value subtree [::questlog::path::canon_dir $d] }
    }

    method browse_file {} {
        set f [tk_getOpenFile -initialdir $Cwd]
        if {$f ne ""} { $Bar add_value file [list $AddOp $f] }
    }

    # Add a value to a criterion from outside the bar: the launch query's seed,
    # normalised by the entry script into these same kinds. Deduped as a chip
    # commit is, and quiet, so a seeded criterion neither opens an editor nor
    # fires the change callback; the one publish here is what app.tcl expects.
    method add_value {kind value} {
        set vals [$Bar values $kind]
        if {$value in $vals} return
        my quiet_set [list $kind [linsert $vals end $value]]
        my publish
    }

    # ---- what a criterion's value means -------------------------------------

    # subtree chips render ~-abbreviated; a file chip shows its path, the op it
    # applies to being the pill inside the chip; tool shows its name (and key, if
    # set); a regex renders raw, and so needs no formatter at all.
    method path_chip {value} { return [::questlog::path::pretty_home $value] }

    method file_chip {value} {
        lassign $value op path
        return [::questlog::path::pretty_home $path]
    }

    method tool_chip {value} {
        lassign $value name key
        return [expr {$key eq "" ? $name : "$name: $key"}]
    }

    # The per-value control in a file chip: the op the criterion applies to. The
    # bar lays out whatever the callback leaves at $w, and reruns the formatter
    # when the value is written back.
    method file_op_pill {w id idx value} {
        lassign $value op path
        my op_pill $w $op [list [self] set_file_op $idx]
    }

    # Change the operation on the file value at index $idx (the op pill on a
    # chip). By index, not by value: an op edit can leave two file chips
    # value-equal, and a by-value write would then rewrite the first twin rather
    # than the chip the user pressed.
    method set_file_op {idx op} {
        set vals [$Bar values file]
        if {$idx < 0 || $idx >= [llength $vals]} return
        set pair [lindex $vals $idx]
        lset pair 0 $op
        $Bar set_value_at file $idx $pair
    }

    # The op for the next file value added. Bound to the add-area op pill's
    # label, so no redraw is needed to reflect the change.
    method set_add_op {op} { set AddOp $op }

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
}
