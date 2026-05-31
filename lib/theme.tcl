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
    # role -> colour, taken from the design source: the transcript/snippet role
    # set (screens.jsx SNIPPET_COLORS and the viewer's role map) and the
    # criterion-type set (tk-mac.jsx CRITERION_TYPE_COLORS). One foreground set
    # for USER/ASSISTANT/TOOL/etc is shared across the list, the viewer, and the
    # match index; each also has a pale pill background for the badge labels.
    # Inks and greys are the design's near-black and rgba-grey steps as hex.
    variable Palette {
        user            #1c3a6a
        assistant       #345f23
        tool            #7a4a14
        tool_result     #693f6e
        system          #555555
        user_bg         #dde9ff
        assistant_bg    #e0f1d9
        tool_bg         #fce8ce
        tool_result_bg  #f4dff5
        system_bg       #e8e8e8
        ink             #1d1d1d
        body            #262626
        snippet         #262626
        muted           #767676
        meta            #767676
        cost_mid        #7a5d00
        cost_outlier    #a02818
        faint           #999999
        folder          #1d1d1d
        section         #595959
        sessionhead     #1d1d1d
        compact         #767676
        sel             #d6e3fb
        drop            #dbe6fc
        recap           #f6ead4
        find            #ffec70
        strip           #ececec
        banner_bg       #fff5c2
        banner_fg       #5a4a0a
        banner_border   #e6d36a
        onboard_bg      #e2eeff
        onboard_fg      #1d1d1d
        onboard_sub     #41597e
        onboard_accent  #1f6eed
        glyph_running   #3ec25b
        glyph_bookmark  #d6a30e
        chip_or         #808080
        crit_under_bg   #ece2f5
        crit_under_fg   #4a3677
        crit_under_bd   #c6b3df
        crit_read_bg    #d9ebff
        crit_read_fg    #1e4b80
        crit_read_bd    #9bbfe6
        crit_write_bg   #ffd9d9
        crit_write_fg   #8a2828
        crit_write_bd   #e6a3a3
        crit_edit_bg    #dff5d9
        crit_edit_fg    #2a5e1e
        crit_edit_bd    #a5d495
        crit_regex_bg   #fff4d6
        crit_regex_fg   #7a5d00
        crit_regex_bd   #e8c870
    }
    # Hit highlight: the design marks a match with one pale yellow and no bold.
    # The list snippet mark is #fff59c; the viewer `find` mark is #ffec70.
    variable Hues {#fff59c}
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

# Apply a full font description ({family} size ?style?) to the reading body,
# as the font chooser hands back on a confirmed pick. QLBody is reconfigured in
# place, so every body-tagged run reflows live while the chrome and fenced-code
# runs keep QLMono. A spec Tk cannot resolve is reported on stderr rather than
# letting the callback's error reach bgerror.
proc ::questlog::theme::set_body_font {spec} {
    if {[catch {font configure QLBody {*}[font actual $spec]} err]} {
        puts stderr "questlog: cannot apply font '$spec': $err"
    }
}

# Set only the reading-body family, keeping the current size and style. This is
# the --font command line: -family takes the whole value, so a spaced family
# name ("DejaVu Serif") needs no list quoting and no size is injected. An
# unknown family is recorded as requested and resolves to a fallback at render.
proc ::questlog::theme::set_body_family {family} {
    if {[catch {font configure QLBody -family $family} err]} {
        puts stderr "questlog: cannot use font '$family': $err"
    }
}

# Create the named fonts and switch ttk to the clam base. Call once, after Tk
# is up and before any widget is built. The fonts are snapshots of the Tk
# named fonts, so the typeface stays native per platform while weight and the
# section size live here. QLBody is the reading-body font: a Tk text widget
# defaults its whole content to TkFixedFont (monospace), so the transcript body
# names QLBody (proportional TkTextFont) explicitly and reconfigures it live
# when the reader picks a font; fenced code keeps QLMono. QLList is the session
# list's proportional chrome font: also TkTextFont, but left fixed, so the
# reading-font chooser never disturbs the list and its tab-stop columns stay
# valid - the list is the index, the reading font is for the transcript. The chrome's current
# background is captured and reapplied under clam, so switching engines
# recolours nothing visible (clam's own beige would otherwise read as a
# change); on a platform whose background is a symbolic system colour the
# reapply is skipped and clam's default stands.
proc ::questlog::theme::init {} {
    if {"QLBold" ni [font names]} {
        font create QLBold     {*}[font actual TkTextFont] -weight bold
        font create QLBody     {*}[font actual TkTextFont]
        font create QLList     {*}[font actual TkTextFont]
        font create QLMono     {*}[font actual TkFixedFont]
        font create QLMonoBold {*}[font actual TkFixedFont] -weight bold
    }
    set bg [. cget -background]
    ttk::style theme use clam
    catch {ttk::style configure . -background $bg}
}
