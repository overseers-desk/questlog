package require Tcl 9
package require Tk

# ::questlog::ui::error_box - a modal error dialog whose text can be selected
# and copied. It takes tk_messageBox's -parent, -title, -message and -detail.
# tk_messageBox draws its text as a label, which cannot be selected, so an
# error naming a path or a session id could only be retyped.

proc ::questlog::ui::error_box {args} {
    set o [dict merge {-parent . -title "" -message "" -detail ""} $args]
    set top .ql_errorbox
    if {[winfo exists $top]} { destroy $top }
    toplevel $top
    wm title $top [dict get $o -title]
    wm transient $top [winfo toplevel [dict get $o -parent]]

    ttk::frame $top.f -padding 12
    pack $top.f -fill both -expand 1
    ttk::label $top.f.icon -image ::tk::icons::error
    set t $top.f.t
    text $t -wrap word -width 48 -height 1 -borderwidth 0 -highlightthickness 0 \
        -font QLBold -background [ttk::style lookup TFrame -background] -cursor xterm
    # Focus stays on OK, so a mouse selection is always the inactive one.
    $t configure -inactiveselectbackground [$t cget -selectbackground]
    $t tag configure detail -font QLBody
    $t insert end [dict get $o -message]
    if {[dict get $o -detail] ne ""} { $t insert end "\n\n[dict get $o -detail]" detail }
    $t configure -state disabled
    ttk::button $top.f.ok -text OK -command [list destroy $top]

    grid $top.f.icon -row 0 -column 0 -sticky n -padx {0 12}
    grid $t          -row 0 -column 1 -sticky nsew
    grid $top.f.ok   -row 1 -column 0 -columnspan 2 -pady {12 0}
    grid columnconfigure $top.f 1 -weight 1
    grid rowconfigure    $top.f 0 -weight 1

    # A disabled text widget still selects under the mouse but never takes
    # focus, so Ctrl-C reaches the dialog through the focused OK button.
    bind $top <<Copy>> [list tk_textCopy $t]
    bind $top <Return> [list destroy $top]
    bind $top <Escape> [list destroy $top]

    update idletasks
    $t configure -height [$t count -update -displaylines 1.0 end]
    grab set $top
    focus $top.f.ok
    tkwait window $top
}
