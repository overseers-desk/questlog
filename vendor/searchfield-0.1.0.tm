package require Tcl 9
package require Tk
package require leash
package provide searchfield 0.1.0

namespace eval ::searchfield {}

# The typing grammar, both directions, in one home. split_terms tokenizes as
# the field does: whitespace separates terms, double quotes group words into
# one term, and a backslashed double quote is a literal quote wherever it
# stands. Empty terms are dropped, so a run of spaces or a bare "" adds
# nothing. join_terms is the inverse: a term holding whitespace is quoted, a
# literal quote is backslashed, and split_terms over the result returns the
# terms it was given, so joining a fragment's terms into one string and
# splitting it again loses nothing. A consumer feeding that string to a
# tokenizer of its own is bound by that tokenizer's grammar, which may not
# know this one's backslash rule.
proc ::searchfield::split_terms {s} {
    set out [list]
    set buf ""
    set inq 0
    set n [string length $s]
    for {set i 0} {$i < $n} {incr i} {
        set ch [string index $s $i]
        if {$ch eq "\\" && [string index $s [expr {$i + 1}]] eq "\""} {
            append buf "\""
            incr i
            continue
        }
        if {$ch eq "\""} { set inq [expr {!$inq}]; continue }
        if {!$inq && [string is space $ch]} {
            if {$buf ne ""} { lappend out $buf; set buf "" }
            continue
        }
        append buf $ch
    }
    if {$buf ne ""} { lappend out $buf }
    return $out
}

proc ::searchfield::join_terms {terms} {
    set parts [list]
    foreach t $terms {
        if {$t eq ""} continue
        set esc [string map [list "\"" "\\\""] $t]
        if {[regexp {\s} $t]} { set esc "\"$esc\"" }
        lappend parts $esc
    }
    return [join $parts " "]
}

# ::searchfield::SearchField - the typed half of a query: terms, case, region.
#
# The field owns one line of controls: an entry the user types terms into, a
# toggle for case-sensitive matching, a picker for the region the terms must
# match in, and a strip of consumer-supplied pills. What the terms are matched
# AGAINST - which corpus, at what cost, on which thread - is the owner's
# business entirely: the field tokenizes what is typed, hands it over, and asks
# nothing about it. It is one half of the shared query contract in
# docs/query-contract.md, the half that owns the `terms`, `case` and `region`
# keys; the other half is the query builder, and neither knows the other.
#
# Vocabulary, and the whole of the widget's world view:
#   term      one search token. A phrase - a term holding whitespace - is ONE
#             term however many words it holds, typed in double quotes; a
#             literal double quote is backslashed. The grammar lives in
#             split_terms/join_terms above, and nowhere else.
#   region    where the terms may match. -regions declares the vocabulary as a
#             dict of stable name to display label; the fragment carries the
#             name, the menu shows the label. The first declared name is the
#             resting default.
#   fragment  the dict {terms <list> case 0|1 region <name>}: what `fragment`
#             returns and the change callback carries. Every key is always
#             present, defaults included, so `dict get` on an owned key is
#             safe unconditionally. Terms the field is withholding for
#             promotion (below) are excluded, because re-reading `fragment` is
#             the canonical consumer path and half-typed structure is exactly
#             what withholding keeps away from a scan.
#   token     one consumer-supplied pill drawn inside the field, carried as
#             the dict {label <text> tag <opaque>}. Display only: no part of
#             terms, and the tag is opaque - a consumer mirroring builder
#             criteria uses criterion ids as tags.
#
# When callbacks fire: the one rule. Every callback fires on user action only,
# and every programmatic entry point is quiet - set_fragment, reset, tokens,
# configure, all of them. A user gesture in the field - a keystroke's debounced
# publish, Return, the case toggle, a region pick, a pill's close - fires its
# callback as ever. The rule exists because answering a query may be expensive:
# only the consumer knows when a batch of programmatic mutations is complete,
# so only the consumer decides when to react, and it says so by calling
# `publish` (fire the change callback once, now) or its own answer path.
#
# Publishing. `-live 1` publishes on a debounced cadence while the user types:
# a key release (or a paste) that changed the text arms a `-debounce`
# millisecond timer, and the timer's lapse publishes; a release that only moved
# the cursor or selected arms nothing. `-live 0` publishes on Return only.
# Return publishes at once in both modes, cancelling any pending debounce, so
# one Return is never two publishes. The case toggle and the region picker
# publish on the spot in both modes: each is one deliberate click, not a
# keystroke mid-burst.
#
# Tokens. The field renders the consumer's pill list inside itself, before the
# entry. `tokens $list` sets it; setting an unchanged list is a no-op - no
# relayout, no flicker, no caret disturbance - so a consumer may re-mirror on
# every publish without guarding. The field draws each label and hands the tag
# back through -removecommand when the pill's close affordance is clicked, or
# when Backspace at the entry's start reaches the last pill, so keyboard users
# remove tokens too. Handing back is ALL it does: the list is the consumer's,
# and the pill leaves when the consumer sets the survivors.
#
# Promotion (optional). A consumer may teach the field that some typed tokens
# are structure, not text. A typed term matching -promotepattern is withheld
# from `fragment`, and so from every publish, until promotion time - set by
# -promoteon: `return` (the default), `tokenend` (the term is complete: the
# text has moved past it, or ends on separating whitespace; Return completes
# the last term too), or `focusout`. At that moment each withheld term goes to
# -promotecommand with the term and the list of the pattern's capture groups
# appended, so the callback reuses the pattern's own parse. The callback
# returns the term's replacement: empty means consumed (its text leaves the
# field), anything else stays as a term - and is exempt from another test
# until the user next edits it, so a declining callback fires once, not on
# every keystroke after. Terms seeded through set_fragment pass into
# `fragment` untested, quiet in, quiet through, exempt until edited. When one
# user action both promotes and publishes (Return does), every promote call
# completes first and exactly one publish follows; a focusout promotion
# publishes nothing, since focus wanders for reasons that are not gestures on
# the query. Consumers with no promotion syntax set neither option.
#
# Lifecycle. `setup` runs once, on a frame the host creates, packs and in the
# end destroys; a second `setup` is an error, as is a frame that does not
# exist, though a build that fails hands the frame back and can be retried.
# Every widget the field builds is a child of that frame, the field's to
# create and destroy. Destroying the object takes the field's widgets with it
# and leaves the frame, which is the host's, standing empty. Destroying the
# frame first is allowed too: the object goes inert, and every method still
# answers rather than raising, so a host may tear the two down in either
# order, and a torn-down object is reusable by the next `setup`.
#
# The look. Every widget the field draws takes a ttk style named by a role in
# -styles, and the module names no colour and no font of its own. One role has
# a look the pattern cannot do without - a pill must at least have an outline -
# so the field dresses it, but ONLY while it still carries the style name it
# ships with: `SFPill.TFrame` is the field's, dressed when it is built and
# again on every theme change (a ttk style's configuration belongs to the
# theme it was made under). To own the look of a pill, name a style of your
# own: a style the field does not name, the field does not touch, ever. A
# pill's padding rides its style; a style that names none is padded from
# -gaps. Every gap the field leaves is in -gaps, in pixels, and nowhere else.
#
# The arrangement, and the widget paths, stable, so a host can reach a widget
# the field built (to hang a tooltip, to drive one from a test):
#   $top.l        the leading label (-label; not drawn when "")
#   $top.tok      the token strip, drawn while tokens are set
#     .p<i>         one pill; .t its text, .x its close affordance
#   $top.e        the entry, filling the width the row has
#   $top.inl      the word before the region picker (-inlabel; not drawn
#                 when "")
#   $top.scope    the region menubutton; $top.scope.m its menu. One declared
#                 region is no choice, so the picker and $top.inl are drawn
#                 only when -regions declares at least two.
#   $top.case     the case toggle
# Every other method of the class, and every variable, is unexported: the
# paths above and the tables below are the whole contract.
#
# Usage:
#   ::tcl::tm::path add $dir
#   package require searchfield
#
#   set sf [::searchfield::SearchField new]
#   $sf configure -label "Search:" -inlabel "in" \
#       -regions {any "anywhere" subject "Subject"} \
#       -live 1 -debounce 200 -changecommand [list apply_query]
#   $sf setup .host                   ;# a frame the host created and packed
#   $sf set_fragment {terms {foo "bar baz"} case 1}
#
# Methods:
#   The shared idiom (docs/query-contract.md):
#   fragment              the current fragment: {terms <list> case 0|1
#                         region <name>}, every key present, withheld terms
#                         excluded.
#   set_fragment frag     seed values quietly. A PARTIAL dict merges:
#                         {terms {foo}} changes the text and leaves case and
#                         region standing; keys the field does not own are
#                         ignored, so the whole saved query dict feeds it
#                         verbatim. A region no -regions name declares, terms
#                         that are not a list, or a case that is not boolean
#                         is an error raised before anything is written.
#                         Seeded terms land exempt from promotion.
#   reset                 back to the documented defaults, quietly: no terms,
#                         case 0, the first declared region.
#   publish               fire -changecommand once with the current fragment:
#                         the one door a consumer uses to react to its own
#                         batch of quiet mutations through the field's own
#                         code path.
#   setup frame           build the field into a frame the host owns. Once
#                         only, though a build that fails hands the frame back
#                         and can be retried.
#   configure ?args?      no arguments reads every option, one reads that
#                         option, pairs set them; a set applies all of them
#                         or, if one is bad, none. Options may be set before
#                         setup, the usual order, or after, where the field
#                         redraws on the spot; a redraw keeps whatever current
#                         values remain valid under the new declaration (a
#                         region the new -regions still names stands, one it
#                         dropped falls back to the first name).
#   cget -opt             read one option.
#
#   The field's own doors:
#   tokens ?list?         with a list, set the pills, quietly; setting an
#                         unchanged list is a no-op. Each element is
#                         {label <text> tag <opaque>}, and anything else is an
#                         error. Without arguments, read the current list.
#   owns_focus            1 while the entry holds the keyboard focus, so a
#                         host's global shortcut can decline while the user
#                         types.
#   is_typing             1 while the user is mid-burst: a live-mode keystroke
#                         whose debounce window has not lapsed. Always 0 with
#                         -live 0, where no keystroke advances the deadline.
#
# Options (`configure -opt value ...`):
#   -regions       dict of stable region name to display label, at least one;
#                  the fragment carries the name, the menu shows the label,
#                  and the first name is the resting default. With one region
#                  declared no picker is drawn, and the region rides the
#                  fragment as a constant.
#   -label         the leading label ("" draws none)
#   -inlabel       the word between the entry and the region picker ("" draws
#                  none)
#   -placeholder   the entry's hint text while empty ("" for none). A Tk
#                  without entry placeholders simply goes without the hint.
#   -casetext      the case toggle's text ("Aa")
#   -closetext     a pill's close affordance ("×")
#   -live          1 (default) to publish on the debounced cadence while the
#                  user types; 0 to publish on Return only. Return publishes
#                  in both modes.
#   -debounce      the live-mode pause, in milliseconds (200)
#   -changecommand a command prefix invoked with the fragment appended, every
#                  time a user gesture changes the query - the debounce's
#                  lapse, Return, the case toggle, a region pick - and only
#                  then; no programmatic door publishes anything (the one
#                  rule, above), and `publish` fires it on demand. The
#                  callback may raise, and the field does not catch it: the
#                  error travels as any error does - through Tk's background
#                  error handler when the gesture was a keystroke or a click,
#                  and to the caller when `publish` was the route.
#   -removecommand a command prefix invoked with a token's tag appended, when
#                  its pill's close affordance is clicked or Backspace at the
#                  entry's start reaches the last pill. The gesture moves no
#                  term, so it publishes nothing: the consumer that drops the
#                  token re-sets `tokens` and answers on its own path.
#   -promotecommand, -promotepattern, -promoteon
#                  promotion, as above. The pattern is checked at the door;
#                  -promoteon is return, tokenend or focusout (return).
#                  Promotion runs only while both the pattern and the command
#                  are set.
#   -styles        dict of role -> ttk style name; a partial dict merges over
#                  the defaults, and a role no widget has is an error. Roles:
#                  label entry scope case pill pilltext close.
#   -gaps          dict of role -> pixels; a partial dict merges over the
#                  defaults, and a role no gap has is an error. Roles: label
#                  (after the leading label), in (before the in-label, or the
#                  picker where no in-label is drawn), pick (between the
#                  in-label and the picker), case (before the case toggle),
#                  pill (between pills and within one, and after the strip).
#                  Defaults {label 6 in 6 pick 2 case 6 pill 4}.
#
# Requires Tcl 9 and Tk (the -placeholder hint needs Tk 9's ttk entry, and is
# skipped without it).

oo::class create ::searchfield::SearchField {
    mixin leash
    variable Top          ;# the frame the host owns and we build into
    variable Text         ;# the entry's text (its textvariable)
    variable LastText     ;# the text the change trigger last acted on
    variable Case         ;# 0|1, the case toggle's variable
    variable Region       ;# the declared name of the chosen region
    variable RegionLabel  ;# its display label (the menubutton's textvariable)
    variable Tokens       ;# the consumer's pills: {label <text> tag <opaque>} each
    variable Exempt       ;# terms promotion does not test: seeded, or kept
    variable Debounce     ;# leash token of the pending live publish, or ""
    variable TypingUntil  ;# clock-ms deadline through which the user counts as typing
    variable Opts         ;# widget options: the whole of the host-specific surface

    constructor {} {
        set Top ""
        set Text ""
        set LastText ""
        set Case 0
        set Tokens [list]
        set Exempt [list]
        set Debounce ""
        set TypingUntil 0
        set Opts [my default_opts]
        set Region [lindex [dict keys [my opt regions]] 0]
        set RegionLabel [dict get [my opt regions] $Region]
    }

    # The field takes its own with it: every widget it built carries a command
    # prefix naming this object, so leaving them standing would leave an entry
    # whose next keystroke raises "invalid command name". The frame is the
    # host's and stays. The pending debounce dies with the object through the
    # leash mixin's destructor, which chains here.
    destructor {
        if {$Top ne "" && [winfo exists $Top]} {
            destroy $Top.l $Top.tok $Top.e $Top.inl $Top.scope $Top.case
        }
    }

    # ---- options -----------------------------------------------------------

    method default_opts {} {
        return [dict create \
            regions        [dict create any "anywhere"] \
            label          "" \
            inlabel        "" \
            placeholder    "" \
            casetext       "Aa" \
            closetext      "×" \
            live           1 \
            debounce       200 \
            changecommand  "" \
            removecommand  "" \
            promotecommand "" \
            promotepattern "" \
            promoteon      return \
            styles         [dict create \
                label    SFLabel.TLabel \
                entry    SFEntry.TEntry \
                scope    SFScope.TMenubutton \
                case     SFCase.TCheckbutton \
                pill     SFPill.TFrame \
                pilltext SFPillText.TLabel \
                close    SFPillClose.TButton] \
            gaps           [dict create label 6 in 6 pick 2 case 6 pill 4]]
    }

    # No arguments reads the options, one argument reads that option, pairs
    # write. A write is all or nothing: every value is checked first, and a
    # redraw that fails rolls the whole configure back and re-lays the row as
    # it was. Options may be set before setup, the usual order, or after,
    # where the field redraws on the spot.
    method configure {args} {
        if {[llength $args] == 0} { return $Opts }
        if {[llength $args] == 1} { return [my cget [lindex $args 0]] }
        if {[llength $args] % 2} {
            error "searchfield: configure takes one option to read, or option/value pairs to set"
        }
        set staged $Opts
        foreach {opt val} $args {
            set k [string trimleft $opt -]
            if {![dict exists $staged $k]} { error "searchfield: unknown option $opt" }
            switch -- $k {
                regions {
                    if {[catch {dict size $val} n] || $n == 0} {
                        error "searchfield: -regions takes a dict of region name\
                               to label, with at least one region"
                    }
                }
                live {
                    if {![string is boolean -strict $val]} {
                        error "searchfield: live '$val' is not a true or false value"
                    }
                }
                debounce {
                    if {![string is integer -strict $val] || $val < 0} {
                        error "searchfield: debounce takes a count of milliseconds, not '$val'"
                    }
                }
                promotepattern {
                    if {$val ne "" && [catch {regexp -- $val ""} err]} {
                        error "searchfield: promotepattern is not a regexp: $err"
                    }
                }
                promoteon {
                    if {$val ni {return tokenend focusout}} {
                        error "searchfield: promoteon '$val' is not return, tokenend or focusout"
                    }
                }
                styles { set val [my merge_roles styles $val "style role" 0] }
                gaps   { set val [my merge_roles gaps   $val "gap"        1] }
            }
            dict set staged $k $val
        }
        set obefore $Opts
        set rbefore [list $Region $RegionLabel]
        set Opts $staged
        if {[catch {my apply_opts} err info]} {
            set Opts $obefore
            lassign $rbefore Region RegionLabel
            catch {my apply_opts}
            return -options $info $err
        }
        return
    }

    # A reconfigure keeps whatever current values remain valid under the
    # declaration now in force and drops the rest: a region the new -regions
    # still names stands, one it dropped falls back to the first name.
    method apply_opts {} {
        set names [dict keys [my opt regions]]
        if {$Region ni $names} { set Region [lindex $names 0] }
        set RegionLabel [dict get [my opt regions] $Region]
        my dress_styles
        my rebuild
    }

    method cget {opt} {
        set k [string trimleft $opt -]
        if {![dict exists $Opts $k]} { error "searchfield: unknown option $opt" }
        return [dict get $Opts $k]
    }

    method opt {k} { return [dict get $Opts $k] }
    method style {role} { return [dict get [my opt styles] $role] }
    method gap {role} { return [dict get [my opt gaps] $role] }

    # A partial -styles or -gaps dict, merged over what the field has. A role
    # the field draws nothing with would merge in and change nothing at all,
    # so it is refused for the reason a misspelt option is.
    method merge_roles {which val what numeric} {
        if {[catch {dict size $val}]} {
            error "searchfield: -$which takes a dict of $what to value"
        }
        set have [dict get $Opts $which]
        dict for {role v} $val {
            if {![dict exists $have $role]} {
                error "searchfield: unknown $what '$role'; the roles are:\
                       [join [dict keys $have] {, }]"
            }
            if {$numeric && (![string is integer -strict $v] || $v < 0)} {
                error "searchfield: $what '$role' takes a count of pixels, not '$v'"
            }
        }
        return [dict merge $have $val]
    }

    # The one style the pattern cannot do without: a pill drawn in an
    # unconfigured style is an invisible flat frame. The field dresses it when
    # it is built and again on every theme change, because a ttk style's
    # configuration belongs to the theme it was made under - and only while it
    # still carries the name the field ships with: a style the host has named
    # is the host's, and the field does not reach into it. It writes only what
    # differs, because `ttk::style configure` raises <<ThemeChanged>>, the
    # event that calls this method, and an unconditional write would re-raise
    # the event it is answering.
    method dress_styles {} {
        set mine [dict get [my default_opts] styles]
        set s [my style pill]
        if {$s ne [dict get $mine pill]} return
        set spec {-relief solid -borderwidth 1 -padding {4 1}}
        set cur [ttk::style configure $s]
        foreach {o v} $spec {
            if {![dict exists $cur $o] || [dict get $cur $o] ne $v} {
                ttk::style configure $s {*}$spec
                return
            }
        }
    }

    # ---- assembly ----------------------------------------------------------

    # Build the field into `parent`, a frame the host created and packed. A
    # build that fails hands the frame back and forgets it, so the object can
    # be set up again rather than be left refusing every attempt as a second
    # setup.
    method setup {parent} {
        if {$Top ne ""} { error "searchfield: setup has already run" }
        if {![winfo exists $parent]} {
            error "searchfield: setup: no such window '$parent'"
        }
        set Top $parent
        if {[catch {my build} err info]} {
            catch {destroy $parent.l $parent.tok $parent.e $parent.inl \
                       $parent.scope $parent.case}
            set Top ""
            return -options $info $err
        }
        return
    }

    method build {} {
        my dress_styles
        my build_row
        my render_tokens
        # A ttk style's configuration belongs to the theme it was made under,
        # so on a theme change the field lays its own style again. It touches
        # no other.
        bind $Top <<ThemeChanged>> [list [namespace which my] dress_styles]
        return
    }

    # A host may destroy the frame while the object lives, so every method
    # that draws asks first whether there is anything left to draw into. The
    # field then goes inert rather than raising into the host's next call.
    method drawable {} {
        return [expr {$Top ne "" && [winfo exists $Top]}]
    }

    # Redraw the row whole from the current state: what a reconfigure needs.
    # The entry's text, the case bit and the region ride their variables
    # through it untouched.
    method rebuild {} {
        if {![my drawable]} return
        destroy $Top.l $Top.tok $Top.e $Top.inl $Top.scope $Top.case
        my build_row
        my render_tokens
    }

    method build_row {} {
        if {[my opt label] ne ""} {
            ttk::label $Top.l -style [my style label] -text [my opt label]
            pack $Top.l -side left -padx [list 0 [my gap label]]
        }
        # The token strip; render_tokens packs it while it holds a pill.
        ttk::frame $Top.tok
        ttk::entry $Top.e -style [my style entry] -textvariable [my varname Text]
        # The placeholder hint is a Tk 9 ttk entry option; a build without it
        # simply goes without the hint.
        if {[my opt placeholder] ne ""} {
            catch {$Top.e configure -placeholder [my opt placeholder]}
        }
        pack $Top.e -side left -fill x -expand 1
        bind $Top.e <Return>    [list [namespace which my] user_return]
        bind $Top.e <BackSpace> [list [namespace which my] user_backspace]
        bind $Top.e <FocusOut>  [list [namespace which my] user_focusout]
        # The change trigger rides the key release, when the entry's class
        # binding has already written the text. A paste arrives without one:
        # the clipboard shortcut is caught by the virtual event, a
        # middle-click PRIMARY paste by the button release, both deferred to
        # idle so the class binding has inserted the text before the trigger
        # compares it.
        bind $Top.e <KeyRelease> [list [namespace which my] user_edit]
        bind $Top.e <<Paste>> [list [namespace which my] user_edit_deferred]
        bind $Top.e <ButtonRelease-2> [list [namespace which my] user_edit_deferred]
        # The region picker: a menubutton posts its menu anchored to itself,
        # so no transient popup nests. One declared region is no choice, so
        # the picker and the word before it are drawn only when there are at
        # least two.
        if {[dict size [my opt regions]] > 1} {
            if {[my opt inlabel] ne ""} {
                ttk::label $Top.inl -style [my style label] -text [my opt inlabel]
                pack $Top.inl -side left -padx [list [my gap in] [my gap pick]]
                set spad [list 0 0]
            } else {
                set spad [list [my gap in] 0]
            }
            ttk::menubutton $Top.scope -style [my style scope] \
                -textvariable [my varname RegionLabel] \
                -menu $Top.scope.m -direction below
            menu $Top.scope.m -tearoff 0
            dict for {name lbl} [my opt regions] {
                $Top.scope.m add command -label $lbl \
                    -command [list [namespace which my] user_region $name]
            }
            pack $Top.scope -side left -padx $spad
        }
        ttk::checkbutton $Top.case -style [my style case] -text [my opt casetext] \
            -variable [my varname Case] \
            -command [list [namespace which my] user_case]
        pack $Top.case -side left -padx [list [my gap case] 0]
    }

    # The pills, redrawn whole from the list. The strip sits before the entry
    # and is not drawn at all while the list is empty, so an unadorned field
    # is exactly an entry. A pill's padding rides its style with the rest of
    # its look; Tk will not hand a frame the padding its style names, so the
    # field reads it out of the style and applies it, and a style that names
    # none is padded from -gaps, so an undressed pill is still a pill.
    method render_tokens {} {
        if {![my drawable]} return
        foreach c [winfo children $Top.tok] { destroy $c }
        if {[llength $Tokens] == 0} {
            pack forget $Top.tok
            return
        }
        set g [my gap pill]
        set i 0
        foreach t $Tokens {
            set pill $Top.tok.p$i
            ttk::frame $pill -style [my style pill]
            set pad [ttk::style lookup [my style pill] -padding]
            if {$pad eq ""} { set pad [list $g 1] }
            $pill configure -padding $pad
            ttk::label $pill.t -style [my style pilltext] -text [dict get $t label]
            pack $pill.t -side left
            # -width 0: ttk's stock button style carries a nine to eleven
            # character minimum width, which would blow a "×" out to the size
            # of a dialog button.
            ttk::button $pill.x -style [my style close] -width 0 \
                -text [my opt closetext] \
                -command [list [namespace which my] user_remove $i]
            pack $pill.x -side left -padx [list $g 0]
            pack $pill -side left -padx [list 0 $g]
            incr i
        }
        pack $Top.tok -side left -before $Top.e -padx [list 0 $g]
    }

    # ---- the fragment ------------------------------------------------------

    # The current fragment. Every key the field owns is present, defaults
    # included; the terms promotion is withholding are excluded, so a consumer
    # re-reading `fragment` never sees half-typed structure.
    method fragment {} {
        set held [my withheld]
        set terms [list]
        foreach t [::searchfield::split_terms $Text] {
            set j [lsearch -exact $held $t]
            if {$j >= 0} { set held [lreplace $held $j $j]; continue }
            lappend terms $t
        }
        return [dict create terms $terms case $Case region $Region]
    }

    # Seed values quietly. A partial dict merges into the current fragment,
    # and keys the field does not own are ignored, so the whole saved query
    # dict feeds it verbatim. Everything is checked before anything is
    # written, so a bad key leaves nothing half set. Seeded terms land exempt
    # from promotion: quiet in, quiet through.
    method set_fragment {frag} {
        if {[catch {dict size $frag}]} { error "searchfield: the fragment is not a dict" }
        if {[dict exists $frag terms] && [catch {llength [dict get $frag terms]}]} {
            error "searchfield: terms is not a list"
        }
        if {[dict exists $frag case] \
                && ![string is boolean -strict [dict get $frag case]]} {
            error "searchfield: case '[dict get $frag case]' is not a true or false value"
        }
        if {[dict exists $frag region] \
                && ![dict exists [my opt regions] [dict get $frag region]]} {
            error "searchfield: region '[dict get $frag region]' is not one -regions declares"
        }
        if {[dict exists $frag terms]} {
            set terms [dict get $frag terms]
            my set_text [::searchfield::join_terms $terms]
            set Exempt $terms
        }
        if {[dict exists $frag case]} {
            set Case [expr {[dict get $frag case] ? 1 : 0}]
        }
        if {[dict exists $frag region]} {
            set Region [dict get $frag region]
            set RegionLabel [dict get [my opt regions] $Region]
        }
        return
    }

    # The documented defaults: no terms, case 0, the first declared region.
    method reset {} {
        my set_text ""
        set Exempt [list]
        set Case 0
        set Region [lindex [dict keys [my opt regions]] 0]
        set RegionLabel [dict get [my opt regions] $Region]
        return
    }

    # Fire -changecommand once with the current fragment. The field calls it
    # itself on every user gesture that changed the query; a consumer calls it
    # to react to its own batch of quiet mutations through the one code path.
    # Its error is not caught: it travels as any error does, and its return
    # value is not the field's to pass on.
    method publish {} {
        set cb [my opt changecommand]
        if {$cb eq ""} return
        {*}$cb [my fragment]
        return
    }

    # Every programmatic write of the entry's text lands here: the change
    # trigger keeps quiet about it (LastText moves with the text), the caret
    # lands at the end, and a pending live publish is dropped, since the
    # typing it answered has been written over.
    method set_text {s} {
        set Text $s
        set LastText $s
        if {$Debounce ne ""} { my forget $Debounce; set Debounce "" }
        set TypingUntil 0
        if {[my drawable]} { $Top.e icursor end }
    }

    # ---- the consumer's reads ----------------------------------------------

    method tokens {args} {
        if {[llength $args] == 0} { return $Tokens }
        if {[llength $args] > 1} { error "searchfield: tokens takes at most one list" }
        set new [list]
        foreach t [lindex $args 0] {
            if {[catch {dict size $t}] || ![dict exists $t label] \
                    || ![dict exists $t tag]} {
                error "searchfield: token is not a {label <text> tag <opaque>} dict: $t"
            }
            # Canonical key order, so an unchanged list re-sent with its keys
            # shuffled is still the no-op the contract promises.
            lappend new [dict create label [dict get $t label] tag [dict get $t tag]]
        }
        if {$new eq $Tokens} return
        set Tokens $new
        my render_tokens
        return
    }

    # 1 while the entry holds the keyboard, so a host's global shortcut can
    # decline and leave the entry's own bindings alone while the user types.
    method owns_focus {} {
        if {![my drawable]} { return 0 }
        return [expr {[focus] eq "$Top.e"}]
    }

    # 1 while the user is mid-burst: a live-mode keystroke whose debounce
    # window has not lapsed. Always 0 with -live 0, where no keystroke
    # advances the deadline.
    method is_typing {} {
        return [expr {[clock milliseconds] < $TypingUntil}]
    }

    # ---- the user's gestures -----------------------------------------------

    # A key release that changed the text. One that only moved the cursor or
    # selected, or the trailing release of the Return that just published,
    # leaves the text as it was and does nothing. An edit revokes the
    # exemption of any term it touched, runs tokenend promotion where that is
    # the promotion time, and in live mode (re)arms the debounce, so the
    # promote calls a keystroke owes complete before the publish it leads to.
    method user_edit {} {
        if {$Text eq $LastText} return
        set LastText $Text
        my prune_exempt
        if {[my opt promoteon] eq "tokenend"} { my promote_pending 1 }
        if {![my opt live]} return
        set ms [my opt debounce]
        set TypingUntil [expr {[clock milliseconds] + $ms}]
        if {$Debounce ne ""} { my forget $Debounce }
        set Debounce [my later $ms [list [namespace which my] debounce_fire]]
        return
    }

    method user_edit_deferred {} {
        my later idle [list [namespace which my] user_edit]
        return
    }

    method debounce_fire {} {
        set Debounce ""
        set TypingUntil 0
        my publish
        return
    }

    # Return publishes at once in both live modes, and one Return is one
    # publish: the pending debounce is cancelled, every promote call the
    # gesture owes completes first, and exactly one publish follows. Return
    # completes the last term, so it is a promotion moment under tokenend as
    # under its own mode; under focusout it promotes nothing, and the withheld
    # terms stay out of the publish.
    method user_return {} {
        if {$Debounce ne ""} { my forget $Debounce; set Debounce "" }
        set TypingUntil 0
        if {$Text ne $LastText} { set LastText $Text; my prune_exempt }
        if {[my opt promoteon] in {return tokenend}} { my promote_pending 0 }
        my publish
        return
    }

    # Leaving the field is the promotion moment under -promoteon focusout, and
    # only the promotion moment: no publish rides it, since focus wanders for
    # reasons that are not gestures on the query.
    method user_focusout {} {
        if {[my opt promoteon] eq "focusout"} { my promote_pending 0 }
        return
    }

    # A region pick. The one that names the region already chosen moves
    # nothing and publishes nothing.
    method user_region {name} {
        if {$name eq $Region} return
        set Region $name
        set RegionLabel [dict get [my opt regions] $name]
        my publish
        return
    }

    # The case toggle's click; the variable has already flipped.
    method user_case {} {
        my publish
        return
    }

    # A pill's close affordance: hand the tag back, and nothing else. The list
    # is the consumer's; the consumer that drops the token sets `tokens` with
    # the survivors. No term moved, so nothing publishes.
    method user_remove {i} {
        set cb [my opt removecommand]
        if {$cb eq ""} return
        {*}$cb [dict get [lindex $Tokens $i] tag]
        return
    }

    # Backspace at the entry's start reaches the last pill, so keyboard users
    # remove tokens too. The widget binding runs before the entry's class
    # binding, which at index 0 with nothing selected deletes nothing, so the
    # gesture is unambiguous: there is no character for it to mean.
    method user_backspace {} {
        if {![my drawable]} return
        if {[llength $Tokens] == 0} return
        if {[$Top.e index insert] != 0} return
        if {[$Top.e selection present]} return
        set cb [my opt removecommand]
        if {$cb eq ""} return
        {*}$cb [dict get [lindex $Tokens end] tag]
        return
    }

    # ---- promotion ---------------------------------------------------------

    # An edit revokes exemption: an exempt term the text no longer holds is
    # forgotten, so typing it again meets the pattern like any fresh token.
    # Exemption is per instance, not per spelling - two equal terms with one
    # exempt leave the other tested.
    method prune_exempt {} {
        if {[llength $Exempt] == 0} return
        set toks [::searchfield::split_terms $Text]
        set keep [list]
        foreach e $Exempt {
            set j [lsearch -exact $toks $e]
            if {$j < 0} continue
            set toks [lreplace $toks $j $j]
            lappend keep $e
        }
        set Exempt $keep
    }

    # The terms promotion is holding back: typed, matching -promotepattern,
    # and not exempt. Withheld from `fragment`, and so from every publish.
    method withheld {} {
        set pat [my opt promotepattern]
        if {$pat eq "" || [my opt promotecommand] eq ""} { return [list] }
        set ex $Exempt
        set out [list]
        foreach t [::searchfield::split_terms $Text] {
            set j [lsearch -exact $ex $t]
            if {$j >= 0} { set ex [lreplace $ex $j $j]; continue }
            if {[regexp -- $pat $t]} { lappend out $t }
        }
        return $out
    }

    # 1 while the text still ends inside its final term - no separating
    # whitespace after it, or a phrase still open - which is the term tokenend
    # is waiting on.
    method open_tail {} {
        set inq 0
        set n [string length $Text]
        for {set i 0} {$i < $n} {incr i} {
            set ch [string index $Text $i]
            if {$ch eq "\\" && [string index $Text [expr {$i + 1}]] eq "\""} {
                incr i
                continue
            }
            if {$ch eq "\""} { set inq [expr {!$inq}] }
        }
        if {$inq} { return 1 }
        if {$n == 0} { return 0 }
        return [expr {![string is space [string index $Text [expr {$n - 1}]]]}]
    }

    # The promotion pass. Every withheld term goes to -promotecommand with the
    # term and its capture groups appended; an empty return consumes it out of
    # the text, anything else stays as a term, exempt until the user next
    # edits it. `typing` is tokenend's mid-burst view: the final term, still
    # under the caret, is not yet a term at all and is spared. A pass that
    # moved nothing rewrites nothing, so the caret is not disturbed by a
    # keystroke that promoted no one.
    method promote_pending {typing} {
        set pat [my opt promotepattern]
        set cmd [my opt promotecommand]
        if {$pat eq "" || $cmd eq ""} return
        set toks [::searchfield::split_terms $Text]
        set n [llength $toks]
        if {$n == 0} return
        set spare [expr {$typing && [my open_tail] ? $n - 1 : -1}]
        set ex $Exempt
        set out [list]
        set moved 0
        for {set i 0} {$i < $n} {incr i} {
            set t [lindex $toks $i]
            set j [lsearch -exact $ex $t]
            if {$j >= 0} {
                set ex [lreplace $ex $j $j]
                lappend out $t
                continue
            }
            if {$i == $spare || ![regexp -- $pat $t]} {
                lappend out $t
                continue
            }
            set rep [{*}$cmd $t [lrange [regexp -inline -- $pat $t] 1 end]]
            set moved 1
            if {$rep ne ""} {
                lappend out $rep
                lappend Exempt $rep
            }
        }
        if {!$moved} return
        set s [::searchfield::join_terms $out]
        # Mid-typing the separator just typed stays, so the next word does not
        # weld onto the term before it.
        if {$typing && ![my open_tail] && $s ne ""} { append s " " }
        my set_text $s
        return
    }

    # Everything under the public contract is the field's own business: a host
    # binds to what the header documents, and the rest stays free to change.
    unexport default_opts apply_opts opt style gap merge_roles dress_styles \
        build build_row rebuild drawable render_tokens set_text \
        prune_exempt withheld open_tail promote_pending \
        user_edit user_edit_deferred user_return user_focusout user_region \
        user_case user_remove user_backspace debounce_fire
}
