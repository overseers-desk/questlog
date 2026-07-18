package require Tcl 9
package require Tk

# ::questlog::ui::theme - the single home for the app's colours and fonts.
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

namespace eval ::questlog::ui::theme {
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
        name            #0f5f6e
        user_bg         #dde9ff
        assistant_bg    #e0f1d9
        tool_bg         #fce8ce
        tool_result_bg  #f4dff5
        system_bg       #e8e8e8
        name_bg         #d5eef2
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
        onboard_bg      #e2eeff
        onboard_fg      #1d1d1d
        onboard_sub     #41597e
        onboard_accent  #1f6eed
        attr_running    #3ec25b
        attr_bookmarked #d6a30e
        chip_or         #808080
        crit_subtree_bg   #ece2f5
        crit_subtree_fg   #4a3677
        crit_subtree_bd   #c6b3df
        crit_file_bg    #e5e5e5
        crit_file_fg    #5a5f66
        crit_file_bd    #ccd1d7
        crit_tool_bg    #fce8ce
        crit_tool_fg    #7a4a14
        crit_tool_bd    #e6c79a
        crit_regex_bg   #fff4d6
        crit_regex_fg   #7a5d00
        crit_regex_bd   #e8c870
        crit_time_bg    #dde9ff
        crit_time_fg    #1c3a6a
        crit_time_bd    #b9cdf0
        crit_turns_bg   #d5eef2
        crit_turns_fg   #0f5f6e
        crit_turns_bd   #a9d5de
        op_either_bg    #edeef0
        op_either_fg    #5a5f66
        op_read_bg      #d9ebff
        op_read_fg      #1e4b80
        op_wrote_bg     #dff0d6
        op_wrote_fg     #2a5e1e
        model_opus      #5a3eb8
        model_opus_bg   #efe7ff
        model_opus_dot  #7c5cd6
        model_sonnet    #1f5aa8
        model_sonnet_bg #e3eefc
        model_sonnet_dot #3b82e0
        model_haiku     #1c7a4d
        model_haiku_bg  #e2f4ea
        model_haiku_dot #2fa66b
        model_fable     #a5316f
        model_fable_bg  #fbe3ef
        model_fable_dot #d1589e
        model_other     #5a5f66
        model_other_bg  #edeef0
        model_other_dot #9a9a9a
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
proc ::questlog::ui::theme::c {role} {
    variable Palette
    return [dict get $Palette $role]
}

proc ::questlog::ui::theme::hues {} {
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
proc ::questlog::ui::theme::set_body_font {spec} {
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
proc ::questlog::ui::theme::set_body_family {family} {
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
proc ::questlog::ui::theme::init {} {
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
    ::questlog::ui::theme::build_chrome
}

# A rounded-rectangle SVG string, authored directly in pixels (so it rasterises
# crisp at the display's physical resolution, no compositor upscaling). `sop` is
# the stroke opacity; a non-empty `dash` emits a dashed outline.
proc ::questlog::ui::theme::rrect_svg {w h r fill stroke sw {sop 1} {dash ""}} {
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
proc ::questlog::ui::theme::rrect_img {name w h r fill stroke sw {sop 1} {dash ""}} {
    set svg [::questlog::ui::theme::rrect_svg $w $h $r $fill $stroke $sw $sop $dash]
    if {$name in [image names]} { image delete $name }
    image create photo $name -data $svg -format svg
    return $name
}

# The shared snippet-badge pill for one block type.
proc ::questlog::ui::theme::badge_pill {type} {
    variable BadgePill
    return [dict getdef $BadgePill $type [dict get $BadgePill system]]
}

# Build the rounded image-element styles (toolbar) and the snippet-badge pills.
# ttk has no corner radius, but it composes image elements, and Tk 9 renders SVG
# in core; a 9-patch `-border` pins the rounded corners while the middle of the
# image stretches to the label, so one small SVG serves any button width. Sizes
# track font metrics so the controls match the text at any DPI. Run once from
# init, after the clam switch and the named fonts.
proc ::questlog::ui::theme::build_chrome {} {
    variable BadgePill
    # ---- rounded toolbar controls -----------------------------------------
    set ch [expr {[font metrics TkDefaultFont -linespace] + 10}]
    set r  [expr {max(5, int($ch * 0.30))}]
    set B  [expr {$r + 2}]              ;# 9-patch fixed-corner inset, image px
    set w  [expr {2 * $B + 8}]          ;# min width; the middle stretches
    # No control sets -background: clam's default fill already equals the toolbar
    # panel, so the pill images' transparent corners blend in with nothing to
    # tune. The element -padding is forced to 0 — it otherwise defaults to
    # -border, which would inset the label a second time over the style -padding.
    # add-rail ghost button: white fill, hairline border that darkens on hover.
    # Hover changes only the border (both images keep the white fill), and the
    # inherited -background state map is cleared so the window fill stays the
    # panel colour in every state — otherwise the active-state fill would show
    # through the image's transparent corners as a square on hover.
    rrect_img qlGhostN $w $ch $r [c chip_bg] [c ctrl_border]    1
    rrect_img qlGhostA $w $ch $r [c chip_bg] [c ctrl_border_hi] 1
    ttk::style element create Ghost.bg image [list qlGhostN active qlGhostA] \
        -border $B -padding 0 -sticky nsew
    ttk::style configure RGhost.TButton -relief flat -borderwidth 0 \
        -foreground [c ink] -anchor center -padding {12 3}
    ttk::style map RGhost.TButton -background {}
    ttk::style layout RGhost.TButton \
        {Ghost.bg -sticky nsew -children {Button.padding -sticky nsew \
            -children {Button.label -sticky nsew}}}
    # The inline add editor's text field: a rounded white plate built the same
    # 9-patch way as the chips, sized so a borderless entry and an open-file
    # glyph sit inside it and read as one control, rather than the entry showing
    # as a bare square box among the rounded chrome. Same fill and border as the
    # ghost button today; named apart so its tint can diverge later.
    rrect_img qlField $w $ch $r [c chip_bg] [c ctrl_border] 1
    ttk::style element create Field.bg image qlField -border $B -padding 0 -sticky nsew
    ttk::style layout Field.TFrame {Field.bg -sticky nsew}
    # faint × that removes one chip; no rounding needed.
    ttk::style configure ChipX.TButton -relief flat -borderwidth 0 \
        -padding {2 0} -background [c chip_bg] -foreground [c faint] \
        -focuscolor [c chip_bg]
    ttk::style map ChipX.TButton \
        -foreground [list active [c ink]] -background [list active [c chip_bg]]
    # per criterion type: the white value chip and the tinted type pill share
    # the type's hairline tint. Both are 9-patch, so a pill takes the width of
    # its own word - the criteria bar grids the pills into one column, which
    # aligns the connective words after them without giving any pill a width.
    foreach t {subtree file tool regex time turns} {
        rrect_img qlChip_$t $w $ch $r [c chip_bg] [c crit_${t}_bd] 1
        ttk::style element create Chip_$t.bg image qlChip_$t \
            -border $B -padding 0 -sticky nsew
        ttk::style layout Crit_$t.TFrame [list Chip_$t.bg -sticky nsew]

        rrect_img qlPill_$t $w $ch $r [c crit_${t}_bg] [c crit_${t}_bd] 1
        ttk::style element create Pill_$t.bg image qlPill_$t \
            -border $B -padding 0 -sticky nsew
        ttk::style layout Pill_$t.TLabel [list Pill_$t.bg -sticky nsew -children \
            {Label.padding -sticky nsew -children {Label.label -sticky nsew}}]
        ttk::style configure Pill_$t.TLabel -foreground [c crit_${t}_fg] \
            -anchor center -padding {8 1}
    }
    # ---- the criteria bar's own roles --------------------------------------
    # facetbar (facetbar-1.0.tm) names every widget it draws by a style role and
    # names no colour itself, so this is where the criteria bar gets its look.
    # The chips, the type pills, the delete × and the ghost add button are the
    # styles above, handed to the module per facet in ui/toolbar.tcl; these are
    # the rest of its roles. The disclosure sits on the panel fill in every
    # state, so its background map is pinned rather than left to brighten.
    set panel [ttk::style lookup . -background]
    ttk::style configure FacetHeading.TLabel -foreground [c muted]
    ttk::style configure FacetConn.TLabel -foreground [c ink]
    ttk::style configure FacetOr.TLabel -foreground [c chip_or]
    ttk::style configure FacetChipText.TLabel -background [c chip_bg] \
        -foreground [c ink] -font QLMono
    ttk::style configure FacetToggle.TButton -relief flat -borderwidth 0 \
        -padding {6 0} -background $panel -foreground [c muted] -focuscolor $panel
    ttk::style map FacetToggle.TButton \
        -background [list active $panel pressed $panel] \
        -foreground [list active [c ink]]
    # ---- the toolbar's view filters ---------------------------------------
    # Running and Bookmarked: two latching toggles, drawn as abutting plates so
    # the pair reads as one control, and either or both can be down. A pressed
    # filter is filled with the same blue the list paints a selected row with, so it
    # says what it is showing in the list's own colour. clam is a pure-Tk drawing
    # theme, so a Toolbutton honours the -background/-relief set here, unlike a
    # native theme.
    ttk::style configure Seg.Toolbutton -background [c chip_bg] -foreground [c ink] \
        -bordercolor [c ctrl_border] -borderwidth 1 -relief raised \
        -padding {10 2} -anchor center -focuscolor [c chip_bg]
    ttk::style map Seg.Toolbutton \
        -background [list selected [c sel] active [c strip]] \
        -bordercolor [list selected [c ctrl_border_hi]] \
        -relief [list selected sunken]
    # ---- list strip ------------------------------------------------------
    # The strip at the top of the session-list region, carrying the expand-all
    # button. It takes the list's column-header strip colour, so it ties to the
    # #ececec header band directly below it rather than to the toolbar panel
    # above.
    ttk::style configure LVStrip.TFrame -background [c strip]
    # The expand-all button shares the strip surface: flat on the band, the
    # muted heading ink brightening to full ink under the pointer.
    ttk::style configure LV.TButton -background [c strip] -foreground [c muted] \
        -borderwidth 0 -padding {6 0} -shiftrelief 0
    ttk::style map LV.TButton \
        -background [list active [c strip] pressed [c strip]] \
        -foreground [list active [c ink] pressed [c ink]]
    # The list-view filter controls share the strip surface with expand-all: the
    # running / bookmarked checkbuttons and the model menubutton sit flat on the
    # #ececec band in the muted heading ink, brightening to full ink under the
    # pointer, so the strip reads as one row of controls rather than raised widgets.
    ttk::style configure LV.TCheckbutton -background [c strip] -foreground [c muted] \
        -borderwidth 0 -padding {6 0} -focuscolor [c strip]
    ttk::style map LV.TCheckbutton \
        -background [list active [c strip] pressed [c strip]] \
        -foreground [list active [c ink] pressed [c ink]]
    ttk::style configure LV.TMenubutton -background [c strip] -foreground [c muted] \
        -borderwidth 0 -padding {6 0} -relief flat
    ttk::style map LV.TMenubutton \
        -background [list active [c strip] pressed [c strip]] \
        -foreground [list active [c ink] pressed [c ink]]
    # ---- notice banner ------------------------------------------------------
    # The top-of-window notice strip (e.g. running without the Thread package):
    # the warm recap cream with the amber ink already used for mid-range cost,
    # so it reads as advisory, not error.
    ttk::style configure Notice.TLabel -background [c recap] \
        -foreground [c cost_mid] -padding {10 4}
    # ---- the list's cut banner ---------------------------------------------
    # The strip above the list that names what the active filters contain and the
    # search never loaded (a session running right now, outside the window). It
    # takes the notice strip's cream and amber, because it says the same kind of
    # thing: the view is not the whole truth, and here is the remedy. The two
    # escapes are flat text buttons on that surface, brightening to full ink
    # under the pointer.
    ttk::style configure Cut.TFrame -background [c recap]
    ttk::style configure Cut.TLabel -background [c recap] -foreground [c cost_mid]
    ttk::style configure CutAct.TButton -background [c recap] \
        -foreground [c cost_mid] -borderwidth 0 -padding {6 0} -shiftrelief 0
    ttk::style map CutAct.TButton \
        -background [list active [c recap] pressed [c recap]] \
        -foreground [list active [c ink] pressed [c ink]]
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
    # The name-history breadcrumb rides the same badge column but carries a
    # longer word than the block types ("former name"), so its pill is sized to
    # that label rather than the shared "TOOL RESULT" width.
    set nbw [expr {[font measure QLBold "FORMER NAME"] + 16}]
    rrect_img qlBadge_names $nbw $bh $br [c name_bg] [c name] 1 0.30
    dict set BadgePill names qlBadge_names
}

# The criteria bar's spacing, scaled from the text.
#
# facetbar keeps every gap it leaves in -gaps, in pixels, and pads a chip whose
# style names no -padding from those same gaps (facetbar-1.0.tm). Crit_<t>.TFrame
# names none, so this one dict carries both the bar's gaps and its chip padding,
# and is the whole of what decides how much air the criteria bar has.
#
# The numbers are the module's own defaults, which fit the 19px line TkDefaultFont
# reports on a 96dpi screen. Scaling them by the line the font actually reports
# holds those proportions as the text grows: at 200% the line is 37px and the gaps
# roughly double with it, rather than the bar keeping a 4px gap under doubled text.
# The same font-metric sizing the rest of the chrome takes (build_chrome above).
proc ::questlog::ui::theme::crit_gaps {} {
    set ref 19   ;# the line height the defaults below are drawn for
    set lh [font metrics TkDefaultFont -linespace]
    set gaps [dict create chip 4 column 6 row 1 line 2 group 12 rail 4]
    dict for {role px} $gaps {
        dict set gaps $role [expr {max(1, round($px * $lh / double($ref)))}]
    }
    return $gaps
}
