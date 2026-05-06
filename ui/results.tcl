package require Tcl 9
package require Tk

# ::csm::ui::Results - the search-result pane.
#
# Hidden until the toolbar's regex becomes non-empty. Once visible, it
# remains visible (even on zero matches) until the regex is cleared.
# Each row is one match; the same session may produce many rows.
#
# resolve_folder is supplied as a callback (from app.tcl) so the pane
# does not hold a direct reference to Scan.

oo::class create ::csm::ui::Results {
    variable Top
    variable StatusVar
    variable CancelCb
    variable ResolveFolder
    variable Tv
    variable RowIndex      ;# iid -> {path lineoff}
    variable NextId
    variable MatchCount
    variable OnSelect
    variable OnOpen
    variable AllMatches    ;# arrival-ordered list of match dicts
    variable Scope         ;# {type none|folder|session  key <s>}

    constructor {parent resolve_cb cancel_cb on_select on_open} {
        set Top $parent
        set ResolveFolder $resolve_cb
        set CancelCb $cancel_cb
        set OnSelect $on_select
        set OnOpen   $on_open
        set StatusVar "Idle"
        set RowIndex [dict create]
        set NextId 0
        set MatchCount 0
        set AllMatches [list]
        set Scope [dict create type none key ""]

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

        set Tv $Top.tv
        ttk::treeview $Tv -columns {project time snippet} -show {headings} \
            -yscrollcommand [list $Top.sb set]
        $Tv heading project -text "Project"
        $Tv heading time    -text "When"
        $Tv heading snippet -text "Match"
        $Tv column  project -anchor w -width 220 -stretch 0
        $Tv column  time    -anchor w -width 120 -stretch 0
        $Tv column  snippet -anchor w -stretch 1

        ttk::scrollbar $Top.sb -orient vertical -command [list $Tv yview]

        grid $Top.bar -row 0 -column 0 -columnspan 2 -sticky ew
        grid $Tv      -row 1 -column 0 -sticky nsew
        grid $Top.sb  -row 1 -column 1 -sticky ns
        grid columnconfigure $Top 0 -weight 1
        grid rowconfigure    $Top 1 -weight 1

        bind $Tv <<TreeviewSelect>> [list [self] on_select]
        bind $Tv <Double-Button-1>  [list [self] on_double]
    }

    method clear {} {
        $Tv delete [$Tv children {}]
        set RowIndex [dict create]
        set NextId 0
        set MatchCount 0
        set AllMatches [list]
        set Scope [dict create type none key ""]
        set StatusVar "Idle"
    }

    method add_match {is_first path lineoff ts snippet folder} {
        incr MatchCount
        set entry [dict create \
            path $path lineoff $lineoff ts $ts \
            snippet $snippet folder $folder]
        lappend AllMatches $entry
        if {[my in_scope $path $folder]} {
            my insert_row $entry
        }
    }

    # set_scope - rebuild visible rows from AllMatches under a new scope.
    # type is one of {none folder session}; key is "" for none, the folder
    # basename for folder, the session jsonl path for session.
    method set_scope {type key} {
        set Scope [dict create type $type key $key]
        $Tv delete [$Tv children {}]
        set RowIndex [dict create]
        set NextId 0
        foreach entry $AllMatches {
            if {[my in_scope [dict get $entry path] [dict get $entry folder]]} {
                my insert_row $entry
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

    method insert_row {entry} {
        set iid R$NextId
        incr NextId
        set folder [dict get $entry folder]
        set proj_label [{*}$ResolveFolder $folder]
        set when [my fmt_time [dict get $entry ts]]
        $Tv insert {} end -id $iid -values \
            [list $proj_label $when [dict get $entry snippet]]
        dict set RowIndex $iid \
            [list [dict get $entry path] [dict get $entry lineoff]]
    }

    method set_progress {done total matches} {
        set StatusVar "Searching … $done / $total sessions   matches: $matches"
    }

    method set_done {total matches} {
        set StatusVar "Done. $total sessions, $matches matches."
    }

    method cancel {} {
        if {$CancelCb ne ""} {
            {*}$CancelCb
        }
        set StatusVar "Cancelled."
    }

    method on_select {} {
        set sel [$Tv selection]
        if {[llength $sel] == 0} return
        set iid [lindex $sel 0]
        if {[dict exists $RowIndex $iid]} {
            lassign [dict get $RowIndex $iid] path lineoff
            {*}$OnSelect $path $lineoff
        }
    }

    method on_double {} {
        set sel [$Tv selection]
        if {[llength $sel] == 0} return
        set iid [lindex $sel 0]
        if {[dict exists $RowIndex $iid]} {
            lassign [dict get $RowIndex $iid] path lineoff
            {*}$OnOpen $path $lineoff
        }
    }

    method fmt_time {iso} {
        if {$iso eq ""} { return "" }
        if {[catch {clock scan $iso -format "%Y-%m-%dT%H:%M:%S.%QZ" -gmt 1} e]} {
            if {[catch {clock scan $iso -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1} e]} {
                return $iso
            }
        }
        return [clock format $e -format "%a %H:%M"]
    }
}
