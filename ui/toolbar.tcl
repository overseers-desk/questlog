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
#   under            list of absolute paths  (OR within, AND across clauses)
#   file             list of {op path} pairs (op: either | read | wrote)
#   tool             list of {name key} pairs (key matches the invocation text;
#                    empty key = any use of the tool)
#   pattern          list of regex strings   (case-sensitive, always)
#   under_auto       1 iff `under` is the launch-seeded chip, untouched
#   one_turn         0 | 1   (exclude one-turn sessions)
#   running_only     0 | 1
#   bookmarked_only  0 | 1
#   cwd              launch cwd, constant after startup

namespace eval ::questlog::ui {}

# any_criteria snapshot - true iff the snapshot carries a content-matching
# clause (search text, regex pattern, or a file/tool clause). The `under`
# clause is a row-level scope, not a content match, so it does not count here;
# treating it as a criterion flips sessions.tcl into result-index mode and
# Search.start returns immediately because there is nothing to match, leaving
# the list empty. Shared by app.tcl (search start/cancel) and sessions.tcl
# (CriteriaActive flag: browse versus result-index mode).
proc ::questlog::ui::any_criteria {snapshot} {
    if {[dict exists $snapshot search] && [dict get $snapshot search] ne ""} {
        return 1
    }
    foreach k {file tool pattern} {
        if {[dict exists $snapshot $k] && [llength [dict get $snapshot $k]] > 0} {
            return 1
        }
    }
    return 0
}

# Tokenise the search field's contents. Space-separated; double-quoted runs
# preserve a phrase. Trailing/leading whitespace ignored. Empty input yields
# an empty list.
proc ::questlog::ui::search_terms {s} {
    set out [list]
    set buf ""
    set in_quotes 0
    foreach ch [split $s ""] {
        if {$ch eq "\""} { set in_quotes [expr {!$in_quotes}]; continue }
        if {$ch eq " " && !$in_quotes} {
            if {$buf ne ""} { lappend out $buf; set buf "" }
            continue
        }
        append buf $ch
    }
    if {$buf ne ""} { lappend out $buf }
    return $out
}

# highlight_terms snapshot - terms for the result pane's in-place highlighter
# and the viewer's match index. Returns the tokenised search terms, matched
# literally downstream; the pattern row, while regex-typed, is uncommon and
# not highlighted in this pass.
proc ::questlog::ui::highlight_terms {snapshot} {
    set s ""
    if {[dict exists $snapshot search]} { set s [dict get $snapshot search] }
    return [::questlog::ui::search_terms $s]
}

oo::class create ::questlog::ui::Toolbar {
    variable Top
    variable Cwd
    variable Subscribers
    variable WindowVar
    variable SearchVar
    variable SearchCaseVar
    variable SearchScopeVar   ;# region-spec: any | user,assistant | tool-use | tool-result
    variable ScopeLabelVar    ;# the menubutton's friendly label for the scope
    variable OneTurnVar
    variable RunningOnlyVar
    variable BookmarkedOnlyVar
    variable Clauses          ;# dict kind -> list of values; file/tool are pairs
    variable UnderAuto        ;# 1 iff `under` is exactly the launch-seeded chip
    variable Restrict         ;# the padded content frame holding the restrict rows
    variable RestrictHd       ;# the heading label above that frame (the legend)
    variable AddRail          ;# the "add:" rail frame inside Restrict
    variable RowFrames        ;# dict kind -> widget path (present only when row exists)
    variable TailShown        ;# dict kind -> 1 for tail rows (tool/pattern) revealed
    variable AddText          ;# array kind -> the add-entry's pending text
    variable AddState         ;# array kind -> collapsed|editing (add affordance's morph state)
    variable AddOp            ;# op for the next file value added (either|read|wrote)
    variable EditFocusKind    ;# kind whose editor should hold focus across a rebuild, or ""
    variable DebounceAfter    ;# after-id of the pending live-search publish, or ""
    variable TypingUntil      ;# clock-ms deadline through which the user counts as typing

    constructor {parent cwd} {
        set Top $parent
        set Cwd $cwd
        set WindowVar  [::questlog::config::get since_default]
        set SearchVar  ""
        set SearchCaseVar 0
        set SearchScopeVar any
        set ScopeLabelVar "anywhere"
        set OneTurnVar 1
        set RunningOnlyVar    0
        set BookmarkedOnlyVar 0
        set Clauses [dict create under {} file {} tool {} pattern {}]
        set UnderAuto 0
        set Subscribers [list]
        set RowFrames [dict create]
        set TailShown [dict create]
        array set AddText {under {} file {} tool {} pattern {}}
        array set AddState {under collapsed file collapsed tool collapsed pattern collapsed}
        set AddOp either
        set EditFocusKind ""
        set DebounceAfter ""
        set TypingUntil 0

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
        # live mode a keystroke also schedules a debounced publish.
        bind $Top.search.e <Return> [list [self] publish_now]
        if {$live} {
            bind $Top.search.e <KeyRelease> [list [self] on_search_change %K]
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
        ttk::label $Restrict.time.rans -text "ran in the last"
        pack $Restrict.time.rans -side left -padx {0 8}
        foreach w [::questlog::config::get since_presets] {
            ttk::radiobutton $Restrict.time.r$w -text $w \
                -variable [my varname WindowVar] -value $w \
                -command [list [self] publish]
            pack $Restrict.time.r$w -side left -padx 2
        }

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

        # Row 2: legacy result-set filters, unchanged by this refactor.
        ttk::frame $Top.row2
        pack $Top.row2 -side top -fill x -padx 6 -pady {4 6}
        ttk::checkbutton $Top.row2.oneturn -text "exclude one-turn sessions" \
            -variable [my varname OneTurnVar] \
            -command [list [self] publish]
        pack $Top.row2.oneturn -side left
        ttk::checkbutton $Top.row2.running -text "running only" \
            -variable [my varname RunningOnlyVar] \
            -command [list [self] publish]
        pack $Top.row2.running -side left -padx {16 0}
        ttk::checkbutton $Top.row2.booked -text "bookmarked only" \
            -variable [my varname BookmarkedOnlyVar] \
            -command [list [self] publish]
        pack $Top.row2.booked -side left -padx {16 0}

        # Render the persistent folder/file rows up front.
        my rebuild_clause_rows
        my refresh_add_rail
    }

    # The search-scope picker. The value is the region-spec the search terms are
    # matched in (parsed by lib/search.tcl parse_regions); the label is the
    # friendly word shown on the button.
    method build_scope_menu {w} {
        ttk::menubutton $w -textvariable [my varname ScopeLabelVar] \
            -menu $w.m -direction below
        menu $w.m -tearoff 0
        foreach {val label} {any "anywhere" user,assistant "user + asst" \
                             tool-use "tool calls" tool-result "tool output"} {
            $w.m add command -label $label \
                -command [list [self] set_scope $val $label]
        }
    }

    method set_scope {val label} {
        set SearchScopeVar $val
        set ScopeLabelVar $label
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

    # Pre-fill the search field (a launch --search). The value is the raw query
    # string the search bar would hold; the one startup publish runs it.
    method set_search {text} { set SearchVar $text }

    # Pre-select the time-window radio (a launch --since). An unknown option is
    # ignored with a warning so a typo falls back to the default rather than
    # leaving the radio set with no selection.
    method set_window {opt} {
        if {$opt in [::questlog::config::get since_presets]} {
            set WindowVar $opt
        } else {
            puts stderr "questlog: ignoring unknown --since '$opt'\
                (want one of: [::questlog::config::get since_presets])"
        }
    }

    method snapshot {} {
        return [dict create \
            since          $WindowVar \
            search         $SearchVar \
            search_case    $SearchCaseVar \
            search_regions $SearchScopeVar \
            under          [dict get $Clauses under] \
            file           [dict get $Clauses file] \
            tool           [dict get $Clauses tool] \
            pattern        [dict get $Clauses pattern] \
            under_auto     $UnderAuto \
            one_turn       $OneTurnVar \
            running_only   $RunningOnlyVar \
            bookmarked_only $BookmarkedOnlyVar \
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

    # Live-search debounce: republish after a pause in typing. The keysym is
    # passed so the trailing KeyRelease of an Enter (handled by publish_now)
    # does not re-arm the timer.
    method on_search_change {{key ""}} {
        if {$key in {Return KP_Enter}} return
        # The user counts as typing through the debounce window, so the browse
        # scan can defer while they type (see scan_while_typing).
        set TypingUntil [expr {[clock milliseconds] + [::questlog::config::get search_debounce_ms]}]
        if {$DebounceAfter ne ""} { after cancel $DebounceAfter }
        set DebounceAfter [after [::questlog::config::get search_debounce_ms] \
            [list [self] debounce_fire]]
    }

    method debounce_fire {} {
        set DebounceAfter ""
        set TypingUntil 0
        my publish
    }

    # Enter: cancel any pending debounce and publish now, so the search runs at
    # once and the trailing KeyRelease cannot fire a second, redundant search.
    method publish_now {} {
        if {$DebounceAfter ne ""} { after cancel $DebounceAfter; set DebounceAfter "" }
        set TypingUntil 0
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
    # the value is an {op path} pair, for tool a {name key} pair, for under and
    # pattern a plain string. The first user action on `under` clears the auto
    # flag, since the user is now editing the row.
    method add_value {kind value} {
        set vals [dict get $Clauses $kind]
        if {$value in $vals} return
        lappend vals $value
        dict set Clauses $kind $vals
        if {$kind eq "under"} { set UnderAuto 0 }
        if {$kind in {tool pattern}} { dict set TailShown $kind 1 }
        my rebuild_clause_rows
        my refresh_add_rail
        my publish
    }

    method remove_value {kind value} {
        set vals [dict get $Clauses $kind]
        set i [lsearch -exact $vals $value]
        if {$i < 0} return
        set vals [lreplace $vals $i $i]
        dict set Clauses $kind $vals
        if {$kind eq "under"} { set UnderAuto 0 }
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

    method commit_folder_add {} {
        set v [string trim $AddText(under)]
        if {$v eq ""} { my cancel_edit under; return }
        set AddText(under) ""
        set AddState(under) collapsed
        my add_value under $v
    }

    method commit_file_add {} {
        set v [string trim $AddText(file)]
        if {$v eq ""} { my cancel_edit file; return }
        set AddText(file) ""
        set AddState(file) collapsed
        my add_value file [list $AddOp $v]
    }

    method commit_pattern_add {} {
        set v [string trim $AddText(pattern)]
        if {$v eq ""} { my cancel_edit pattern; return }
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

    method browse_folder {} {
        set d [tk_chooseDirectory -initialdir $Cwd -mustexist 1]
        if {$d ne ""} { set AddState(under) collapsed; my add_value under $d }
    }

    method browse_file {} {
        set f [tk_getOpenFile -initialdir $Cwd]
        if {$f ne ""} { set AddState(file) collapsed; my add_value file [list $AddOp $f] }
    }

    # Seed the `under` row with the launch cwd. Marks UnderAuto so the
    # Show-all banner knows the chip was not user-typed. Any later edit
    # clears the flag.
    method seed_under {path} {
        dict set Clauses under [list $path]
        set UnderAuto 1
        my rebuild_clause_rows
        my refresh_add_rail
        my publish
    }

    # Drop the auto-applied under chip. Used by the "Show all" banner.
    method clear_under_auto {} {
        if {!$UnderAuto} return
        dict set Clauses under [list]
        set UnderAuto 0
        my rebuild_clause_rows
        my refresh_add_rail
        my publish
    }

    # ---- row management ----------------------------------------------------

    # Destroy every clause-row frame and reconstruct the present ones in
    # canonical reading order between the time row and the add rail. The folder
    # and file rows are persistent (always shown, with a ghost add entry when
    # empty); the tool and pattern tail rows show once revealed or non-empty.
    method rebuild_clause_rows {} {
        foreach k {under file tool pattern} {
            if {[dict exists $RowFrames $k]} {
                destroy [dict get $RowFrames $k]
                dict unset RowFrames $k
            }
        }
        # kind -> styling type; pattern draws in the regex tint.
        set ctype {under under file file tool tool pattern regex}
        foreach k {under file pattern tool} {
            set vals [dict get $Clauses $k]
            set persistent [expr {$k in {under file}}]
            set shown [expr {$persistent || [dict getdef $TailShown $k 0] \
                             || [llength $vals] > 0}]
            if {!$shown} continue
            set t [dict get $ctype $k]
            set row $Restrict.row_$k
            ttk::frame $row
            # The type tag is a rounded tinted pill: the qlPill_<t> image gives
            # the shape and fill, the type name is drawn centred over it, and the
            # label background matches the panel so the pill's corners blend.
            label $row.label -image qlPill_$t -compound center \
                -text $t -anchor center -borderwidth 0 \
                -background [ttk::style lookup . -background] \
                -foreground [::questlog::ui::theme::c crit_${t}_fg]
            pack $row.label -side left -padx {0 6} -pady 1
            ttk::label $row.conn -text [dict get {
                under "ran under" file "touched" tool "used" pattern "matches"
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
        foreach k {under file tool pattern} {
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
            ttk::button $chip.x -text "×" -width 2 -style ChipX.TButton \
                -command [list [self] remove_value $kind $v]
            pack $chip.x -side left -padx {2 0}
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
            under   { list [self] commit_folder_add }
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
            under { my add_icon $ae.field.icon "\U0001F4C1" [list [self] browse_folder] }
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

    # under chips render ~-abbreviated; tool shows name (and key, if set);
    # pattern renders the raw regex. file chips are handled in render_chips.
    method chip_display {kind value} {
        switch -- $kind {
            under { return [::questlog::path::pretty_home $value] }
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

    method destroy {} {
        if {[info exists DebounceAfter] && $DebounceAfter ne ""} {
            after cancel $DebounceAfter
        }
        next
    }

}
