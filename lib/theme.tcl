package require Tcl 9
package require Tk

# ::questlog::theme - the single home for the app's colours and fonts.
#
# The same semantic colour - the user-turn blue, the muted grey, the deep
# session-heading blue - was written as a bare hex literal at every tag that
# used it, across ui/sessions.tcl and ui/viewer.tcl, so the user blue had
# three homes (#06c twice, #1c3a6a once) and a change meant hunting each copy.
# Here every colour is named once and read by role; the text-widget tags and
# the ttk chrome both draw from this one table.
#
# The ttk base is clam, not the platform theme. clam is one pure-Tk drawing
# engine that honours `ttk::style configure` identically on every platform;
# aqua (macOS) ignores most style options and the X11 default theme honours a
# different subset, so a look tuned on one would not carry to the other. The
# text widgets that hold the list and the transcript are not ttk widgets - their
# colours are these same roles applied as tag config, identical on every OS.

namespace eval ::questlog::theme {
    # role -> colour. One value per role. Greys are kept distinct by use
    # (today's values) rather than merged; a later pass may consolidate them.
    variable Palette {
        user            #06c
        assistant       #222
        tool            #a60
        tool_result     #666
        muted           #888
        snippet         #333
        meta            #777
        folder          #555
        sessionhead     #143d8a
        section         #444
        compact         #a33
        sel             #aecbff
        drop            #cce5ff
        recap           #ffefd0
        strip           #e8e8e8
        find            yellow
        chip_or         gray
        strip_user      #1c3a6a
        strip_assistant #345f23
        strip_other     #7a4a14
    }
    # The list's hit-highlight hues, cycled one per search term.
    variable Hues {#fff59d #b3e5fc #f8bbd0 #c8e6c9}
}

# Colour for a role. Errors loudly on an unknown role rather than returning a
# default, so a typo surfaces at build time, not as an invisible miscolour.
proc ::questlog::theme::c {role} {
    variable Palette
    return [dict get $Palette $role]
}

proc ::questlog::theme::hues {} {
    variable Hues
    return $Hues
}

# Create the named fonts and switch ttk to the clam base. Call once, after Tk
# is up and before any widget is built. The fonts are snapshots of the Tk
# named fonts, so the typeface stays native per platform while weight and the
# section size live here. The chrome's current background is captured and
# reapplied under clam, so switching engines recolours nothing visible (clam's
# own beige would otherwise read as a change); on a platform whose background
# is a symbolic system colour the reapply is skipped and clam's default stands.
proc ::questlog::theme::init {} {
    if {"QLBold" ni [font names]} {
        font create QLBold    {*}[font actual TkTextFont] -weight bold
        font create QLMono    {*}[font actual TkFixedFont]
        font create QLSection {*}[font actual TkTextFont] -weight bold -size 11
    }
    set bg [. cget -background]
    ttk::style theme use clam
    catch {ttk::style configure . -background $bg}
}
