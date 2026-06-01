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
        snippet_guide   #c6dbff
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
        chip_bg         #ffffff
        ctrl_border     #c4c4c4
        ctrl_border_hi  #9a9a9a
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
    # type -> shared rounded-pill photo for the session-list snippet badge,
    # filled once in build_chrome and looked up by render_snippet.
    variable BadgePill {}
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
# as the font chooser hands back on a confirmed pick. QLBody and its bold and
# italic variants are reconfigured in place from the picked family and size, so
# every body-tagged run (plain or emphasised) reflows live while the chrome and
# fenced-code runs keep QLMono. The base is forced to normal/roman and each
# variant to its own weight/slant, so a bold or italic source spec cannot leak
# the wrong face into a variant. A spec Tk cannot resolve is reported on stderr
# rather than letting the callback's error reach bgerror.
proc ::questlog::theme::set_body_font {spec} {
    if {[catch {
        set a [font actual $spec]
        set fam [dict get $a -family]
        set sz  [dict get $a -size]
        font configure QLBody           -family $fam -size $sz -weight normal -slant roman
        font configure QLBodyBold       -family $fam -size $sz -weight bold   -slant roman
        font configure QLBodyItalic     -family $fam -size $sz -weight normal -slant italic
        font configure QLBodyBoldItalic -family $fam -size $sz -weight bold   -slant italic
    } err]} {
        puts stderr "questlog: cannot apply font '$spec': $err"
    }
}

# Set only the reading-body family across QLBody and its bold/italic variants,
# keeping each one's size and style. This is the --font command line: -family
# takes the whole value, so a spaced family name ("DejaVu Serif") needs no list
# quoting and no size is injected. An unknown family is recorded as requested
# and resolves to a fallback at render.
proc ::questlog::theme::set_body_family {family} {
    if {[catch {
        foreach f {QLBody QLBodyBold QLBodyItalic QLBodyBoldItalic} {
            font configure $f -family $family
        }
    } err]} {
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
        # Bold and italic faces of the reading body, for inline emphasis. They
        # are kept in lockstep with QLBody by set_body_font/set_body_family, so
        # the reader's chosen face carries through to *bold* and *italic* spans;
        # inline `code` reuses QLMono.
        font create QLBodyBold       {*}[font actual TkTextFont] -weight bold
        font create QLBodyItalic     {*}[font actual TkTextFont] -slant italic
        font create QLBodyBoldItalic {*}[font actual TkTextFont] -weight bold -slant italic
    }
    set bg [. cget -background]
    ttk::style theme use clam
    catch {ttk::style configure . -background $bg}
    ::questlog::theme::build_chrome
}

# A rounded-rectangle SVG string, authored directly in pixels (so it rasterises
# crisp at the display's physical resolution, no compositor upscaling). `sop` is
# the stroke opacity; a non-empty `dash` emits a dashed outline.
proc ::questlog::theme::rrect_svg {w h r fill stroke sw {sop 1} {dash ""}} {
    set o [expr {$sw / 2.0}]
    set dattr [expr {$dash ne "" ? "stroke-dasharray=\"$dash\"" : ""}]
    set fattr [expr {$fill eq "none" ? "fill=\"none\"" : "fill=\"$fill\""}]
    return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$w\" height=\"$h\">\
<rect x=\"$o\" y=\"$o\" width=\"[expr {$w - $sw}]\" height=\"[expr {$h - $sw}]\"\
 rx=\"$r\" ry=\"$r\" $fattr stroke=\"$stroke\" stroke-width=\"$sw\"\
 stroke-opacity=\"$sop\" $dattr/></svg>"
}

# Create (or replace) a named photo from a rounded-rect SVG. Named Tk images
# persist for the interpreter's life, so the elements and badges that reference
# them stay drawn without a separate variable holding them.
proc ::questlog::theme::rrect_img {name w h r fill stroke sw {sop 1} {dash ""}} {
    set svg [::questlog::theme::rrect_svg $w $h $r $fill $stroke $sw $sop $dash]
    if {$name in [image names]} { image delete $name }
    image create photo $name -data $svg -format svg
    return $name
}

# The shared snippet-badge pill for one block type.
proc ::questlog::theme::badge_pill {type} {
    variable BadgePill
    return [dict getdef $BadgePill $type [dict get $BadgePill system]]
}

# Build the rounded image-element styles (toolbar) and the snippet-badge pills.
# ttk has no corner radius, but it composes image elements, and Tk 9 renders SVG
# in core; a 9-patch `-border` pins the rounded corners while the middle of the
# image stretches to the label, so one small SVG serves any button width. Sizes
# track font metrics so the controls match the text at any DPI. Run once from
# init, after the clam switch and the named fonts.
proc ::questlog::theme::build_chrome {} {
    variable BadgePill
    # ---- rounded toolbar controls -----------------------------------------
    set ch [expr {[font metrics TkDefaultFont -linespace] + 10}]
    set r  [expr {max(5, int($ch * 0.30))}]
    set B  [expr {$r + 2}]              ;# 9-patch fixed-corner inset, image px
    set w  [expr {2 * $B + 8}]          ;# min width; the middle stretches
    # add-rail ghost button: white fill, hairline border, darker on hover.
    rrect_img qlGhostN $w $ch $r [c chip_bg] [c ctrl_border]    1
    rrect_img qlGhostA $w $ch $r [c strip]   [c ctrl_border_hi] 1
    ttk::style element create Ghost.bg image [list qlGhostN active qlGhostA] \
        -border $B -sticky nsew
    ttk::style configure RGhost.TButton -relief flat -borderwidth 0 \
        -background [c strip] -foreground [c ink] -anchor center \
        -padding {12 3} -focuscolor [c strip]
    ttk::style layout RGhost.TButton \
        {Ghost.bg -sticky nsew -children {Button.padding -sticky nsew \
            -children {Button.label -sticky nsew}}}
    # faint × that removes one chip; no rounding needed.
    ttk::style configure ChipX.TButton -relief flat -borderwidth 0 \
        -padding {2 0} -background [c chip_bg] -foreground [c faint] \
        -focuscolor [c chip_bg]
    ttk::style map ChipX.TButton \
        -foreground [list active [c ink]] -background [list active [c chip_bg]]
    # The type pill is a fixed-size label image (text drawn centred over it), so
    # it is sized to the widest type word, not stretched like the 9-patch chips.
    set pw [expr {[font measure TkDefaultFont "regex"] + 20}]
    # per criterion type: the white value chip, the dashed "+ or", and the
    # tinted type pill all share the type's hairline tint.
    foreach t {under read write edit regex} {
        rrect_img qlChip_$t $w $ch $r [c chip_bg] [c crit_${t}_bd] 1
        ttk::style element create Chip_$t.bg image qlChip_$t -border $B -sticky nsew
        ttk::style layout Crit_$t.TFrame [list Chip_$t.bg -sticky nsew]
        ttk::style configure Crit_$t.TFrame -background [c chip_bg]

        rrect_img qlOr_$t $w $ch $r [c chip_bg] [c crit_${t}_fg] 1 0.8 "3,2"
        ttk::style element create Or_$t.bg image qlOr_$t -border $B -sticky nsew
        ttk::style configure ROr_$t.TButton -relief flat -borderwidth 0 \
            -background [c chip_bg] -foreground [c crit_${t}_fg] -anchor center \
            -padding {10 3} -focuscolor [c chip_bg]
        ttk::style layout ROr_$t.TButton \
            [list Or_$t.bg -sticky nsew -children {Button.padding -sticky nsew \
                -children {Button.label -sticky nsew}}]

        rrect_img qlPill_$t $pw $ch $r [c crit_${t}_bg] [c crit_${t}_bd] 1
    }
    # ---- rounded snippet-badge pills (shape only; Tk draws the label) ------
    set bh [font metrics QLBold -linespace]
    set bw [expr {[font measure QLBold "TOOL RESULT"] + 16}]
    set br [expr {max(4, int($bh * 0.34))}]
    foreach {t bgrole fgrole} {
        user        user_bg        user
        assistant   assistant_bg   assistant
        tool_use    tool_bg        tool
        tool_result tool_result_bg tool_result
        system      system_bg      system
    } {
        rrect_img qlBadge_$t $bw $bh $br [c $bgrole] [c $fgrole] 1 0.30
        dict set BadgePill $t qlBadge_$t
    }
}
