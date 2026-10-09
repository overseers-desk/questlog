package require Tcl 9
package require Tk
package provide streamdoc 1.3

namespace eval ::streamdoc {}

# ::streamdoc::StreamDoc - the generic "streaming document of foldable
# regions" base class.
#
# A StreamDoc owns an append-only document rendered into a single read-only
# text widget: chrome (free text between regions) interleaved with REGIONS,
# each a header line, a body, and an optional trailing summary line. The
# host supplies every character through the content door and the hooks
# (Template Method); the base class owns the marks, the two elide layers and
# the streaming contract, and never looks inside a payload.
#
# A region's header is its first line; the body is everything after it.
# A region tracks its position with two real marks:
#   r#Ns  left gravity, at the header line's first char. Left gravity keeps
#         it put when the header is inserted at it.
#   r#Ne  right gravity while the region is open: content emitted at the
#         append point carries it forward on its own. region_close seals it
#         to left gravity; the next region's header, inserted at the same
#         spot, would otherwise drag it along.
# Plus r#Nm at the summary line's first char while one stands. Gravity does
# the bookkeeping; the document streams without index arithmetic.
#
# Two elide layers per region, owned by the base class - no other code
# may mutate a tag's -elide:
#   f#N  the fold range [header +1line linestart, end): whole logical lines
#        only, never the header's own newline - eliding it would visually
#        join adjacent headers when everything is folded.
#   d#N  the region's detail content (lines the host tags with detail_tag),
#        hidden by default. Configured after f#N, which gives it the higher
#        tag priority: where both cover a char, the detail elide wins, and
#        unfolding a region does not spill its hidden detail. fold forces
#        d#N back to hidden, the same rule from the other side. No host tag
#        laid over a region may set an explicit -elide of its own, or it
#        would override the fold; tags that leave -elide unset never do.
#
# Content enters through the door, inside `batch`: append_open / emit /
# emit_window / append_close. While a region is open the door feeds it,
# popping any standing summary line first and re-appending it at close
# (the summary pop, internal to the base class); between regions the door
# appends chrome at the tail. `savepoint` and `rewind` let a caller re-emit
# a provisional tail; the summary pop is a rewind to the summary's mark.
#
# Glyphs: the first char of a header line and of a summary line is a state
# glyph from the -glyphs pair. fold/unfold and detail_show/hide swap it with
# a same-length replace, so every index downstream stays true. A first char
# that is not one of the pair is left alone; glyphless headers work.
#
# View anchoring: `batch` brackets a streamed mutation with anchor_save /
# anchor_restore, so content landing below a parked reader never moves the
# line they are on. With -autofollow on and the reader at the tail, the view
# latches there and follows appends (the tail -f contract; "the tail latch"
# below says what lets go). <<AtBottom>> / <<LeftBottom>> fire on the host
# frame at the edges, and `follow` jumps back to the tail.
#
# Find (Ctrl-F): a bar under the text whose entry collects every literal
# hit, folded and hidden text included, tags it `find`, and steps through
# the hits with wraparound, each one through `reveal`. The base class lays
# the tag and sets no colours; the host configures `find` for the look.
#
# Hooks the host overrides, each with a working default:
#   summary_text payload    the summary phrase; "" takes no summary line
#   region_tags payload     tags laid on the summary line the base class writes
#   on_region_rendered n    wire a just-closed region (bindings, indices)
#   on_reveal idx           runs first in reveal, before anything scrolls
#   place_find frame        where the find bar sits; default the row below
#   find_chrome_tags        tags whose text find skips; default `summary`
#   find_bound              where the text search stops; default `end`
#   find_extra term nocase  {index excerpt} hits the text search cannot see
#   find_excerpt idx        the excerpt a hit shows
#   on_find_collected / on_find_stepped i / find_cleared

oo::class create ::streamdoc::StreamDoc {
    variable Top          ;# the host frame setup built into
    variable Text         ;# the document text widget
    variable Regions      ;# per-region dicts, in document order:
                          ;# {start end summary open folded shown payload}
    variable Cur          ;# index of the open region, or -1
    variable Opts         ;# widget options decoupling the base class from any host
    variable NextSave     ;# savepoint mark counter
    variable Latched      ;# 1 while the view is held on the tail
    variable FollowAfter  ;# the pending idle re-follow, "" none
    variable Pressed      ;# 1 while a button-1 press that began on the text is held
    variable AnchorY      ;# the anchored line's y, for its pixel offset
    variable WasAtBottom  ;# last observed bottom state, edges fire the events
    variable Find         ;# the find bar's frame
    variable FindVar      ;# the find entry's text
    variable FindPos      ;# the "N of M" readout, "" while cleared
    variable FindMatches  ;# hit indices (or marks) in document order
    variable FindCur      ;# 0-based hit last shown, -1 none
    variable FindNocase   ;# 1 matches regardless of case
    variable FindExcerpt  ;# index -> excerpt, for find_extra hits
    variable LastFindVar  ;# the term the match set was collected for
    variable LastNocase   ;# and its case; a change in either recollects

    # ---- structural invariant ----------------------------------------
    #
    # The mark contract every mutation must preserve: each region's [start,end)
    # is well-formed, starts on a line start, and the regions are ordered and
    # disjoint down the buffer; a standing summary mark sits inside its region;
    # the open region's end rides the buffer tail. A violation means a mark
    # desynced. Gated on the STREAMDOC_AUDIT env var so production pays
    # nothing; when on, it logs the first violation with the call chain and
    # latches off, naming the primitive that broke the contract. Every
    # primitive calls this at its tail.
    method check_invariant {where} {
        if {![info exists ::env(STREAMDOC_AUDIT)]} return
        if {[info exists ::STREAMDOC_AUDIT_TRIPPED]} return
        set probs [list]
        set prev_end ""
        set prev_n -1
        set n -1
        foreach R $Regions {
            incr n
            set s [dict get $R start]
            set e [dict get $R end]
            if {[catch {$Text index $s} si]} { lappend probs "region $n: unresolvable start"; continue }
            if {[catch {$Text index $e} ei]} { lappend probs "region $n: unresolvable end"; continue }
            if {[$Text compare $e < $s]} {
                lappend probs "region $n: end($ei) before start($si)"
            }
            if {[$Text compare $s != "$s linestart"]} {
                lappend probs "region $n: start($si) off its line start"
            }
            if {$prev_end ne "" && [$Text compare $s < $prev_end]} {
                lappend probs "region $n: start($si) overlaps region $prev_n end($prev_end)"
            }
            if {[dict get $R summary]} {
                if {[catch {$Text index r#${n}m} mi]} {
                    lappend probs "region $n: unresolvable summary mark"
                } elseif {[$Text compare r#${n}m < $s] || [$Text compare r#${n}m >= $e]} {
                    lappend probs "region $n: summary($mi) outside \[$si,$ei)"
                }
            }
            set prev_end $ei
            set prev_n $n
        }
        if {$Cur >= 0} {
            set e [dict get [lindex $Regions $Cur] end]
            if {![catch {$Text index $e}] \
                    && [$Text compare $e != "end - 1 chars"]} {
                lappend probs "open region $Cur end([$Text index $e]) adrift of the tail([$Text index "end - 1 chars"])"
            }
        }
        if {[llength $probs]} {
            set ::STREAMDOC_AUDIT_TRIPPED 1
            puts stderr "INVARIANT @ $where : [join $probs {; }] | end=[$Text index end]"
            for {set l [info level]} {$l > 0} {incr l -1} {
                puts stderr "   <- [string range [info level $l] 0 70]"
            }
        }
    }

    # ---- widget options ----------------------------------------------
    #
    # The base class takes its host-specific look as options; its body holds no
    # host references. Defaults are a plain Tk look so the widget runs
    # standalone; a host overrides them through `configure` before the
    # body is built.
    method default_opts {} {
        return [dict create \
            font TkTextFont \
            glyphs [list ▸ ▾] \
            autofollow 0]
    }
    method configure {args} {
        if {![info exists Opts]} { set Opts [my default_opts] }
        set known [my default_opts]
        foreach {opt val} $args {
            set k [string trimleft $opt -]
            if {![dict exists $known $k]} { error "unknown option $opt" }
            if {$k eq "glyphs" && ([llength $val] != 2 \
                    || [string length [lindex $val 0]] != 1 \
                    || [string length [lindex $val 1]] != 1)} {
                error "-glyphs takes two single-char glyphs {closed open}"
            }
            dict set Opts $k $val
        }
    }
    method opt {k} {
        if {![info exists Opts]} { set Opts [my default_opts] }
        return [dict get $Opts $k]
    }

    # ---- body assembly -----------------------------------------------

    # The whole construction ritual in one call: seed the base class's state and
    # build the document text, its scrollbar and the find bar into `parent` (a frame the
    # host owns and packs). A subclass constructor calls `my configure ...`
    # first when it overrides the look, then `my setup $parent`.
    method setup {parent} {
        set Top $parent
        set Regions [list]
        set Cur -1
        set NextSave 0
        text $parent.text -wrap word -state disabled \
            -yscrollcommand [list [self] on_yscroll] \
            -borderwidth 0 -highlightthickness 0 -padx 8 -pady 8 \
            -font [my opt font] -insertwidth 0
        ttk::scrollbar $parent.sb -orient vertical \
            -command [list [self] scroll_to]
        grid $parent.text -row 0 -column 0 -sticky nsew
        grid $parent.sb   -row 0 -column 1 -sticky ns
        grid columnconfigure $parent 0 -weight 1
        grid rowconfigure    $parent 0 -weight 1
        set Text $parent.text
        my find_seed
        my latch_seed
        my build_find
    }

    # The text widget, for tag configuration, tag bindings, and painting at
    # the door through a painter that takes a widget and an index.
    method textwidget {} { return $Text }

    # Text widget yview update: forward to the scrollbar, and edge-detect the
    # tail so a host can mirror the tail -f contract: <<AtBottom>> fires on the
    # host frame when the view reaches the last line, <<LeftBottom>> when the
    # reader scrolls away from it.
    method on_yscroll {args} {
        $Top.sb set {*}$args
        set now [expr {[lindex $args 1] >= 0.999}]
        if {![info exists WasAtBottom]} { set WasAtBottom $now; return }
        if {$now != $WasAtBottom} {
            set WasAtBottom $now
            event generate $Top [expr {$now ? "<<AtBottom>>" : "<<LeftBottom>>"}]
        }
    }

    # Jump to the tail and latch there. With -autofollow on the view keeps
    # following streamed appends until the reader scrolls away.
    method follow {} {
        set Latched 1
        $Text yview moveto 1
    }

    # ---- the tail latch --------------------------------------------------
    #
    # The latch is let go only by the reader: wheel and touchpad scrolling
    # and the scroll keys on the text, the scrollbar and `scroll_to`, a fold
    # or detail toggle, a reveal away from the last line. Everything else
    # that moves the tail - an append, an embedded window realised or grown
    # late, a resize of the text - leaves it held and re-follows on idle. It
    # takes hold through `follow`, or at a batch that finds the view on the
    # tail.
    #
    # The view moves only on the reader's own action, and an autoscan no
    # press on this text started is not the reader's. The Text class starts
    # one on <B1-Leave> and stops it on <B1-Enter> or the release; a press
    # held from another widget keeps those under that widget's grab, and a
    # stray <B1-Leave> would scroll on to the end of the document. So the
    # leave reaches the class only while Pressed. A release that went to
    # another grab leaves Pressed set; the pointer back over the text with
    # button 1 up (mask 256) clears it.
    method latch_seed {} {
        if {[info exists Latched]} return
        set Latched 0
        set FollowAfter ""
        set Pressed 0
        set tag [my bindtag $Text]
        foreach ev {<MouseWheel> <Shift-MouseWheel> <Button-4> <Button-5>
                <TouchpadScroll> <Prior> <Next> <Up> <Down> <Home> <End>} {
            catch {bind $tag $ev [list [self] latch_release]}
        }
        bind $tag <Configure> [list [self] refollow_later]
        set pressed [my varname Pressed]
        bind $tag <ButtonPress-1> [list set $pressed 1]
        bind $tag <ButtonRelease-1> [list set $pressed 0]
        foreach ev {<Enter> <Motion>} {
            bind $tag $ev "if {!(%s & 256)} [list [list set $pressed 0]]"
        }
        bind $tag <B1-Leave> "if {!\[[list set $pressed]\]} break"
    }
    method latch_release {} { set Latched 0 }
    method latched {} {
        return [expr {[my opt autofollow] && [info exists Latched] && $Latched}]
    }

    # streamdoc's bindings on a host widget w go on the tag streamdoc$w,
    # inserted once into w's bindtags just after w's own: the host's bindings
    # on w run first and a `break` there stops streamdoc's; the class's run
    # after, unless streamdoc's script breaks.
    method bindtag {w} {
        set tag streamdoc$w
        set tags [bindtags $w]
        if {$tag ni $tags} {
            set i [lsearch -exact $tags $w]
            bindtags $w [linsert $tags [expr {$i + 1}] $tag]
        }
        return $tag
    }

    # A scroll on the reader's behalf: forwards to the text's yview and lets
    # go of the latch. The scrollbar's command, and the way a host scrolls.
    method scroll_to {args} {
        if {[llength $args]} { set Latched 0 }
        return [$Text yview {*}$args]
    }

    # One idle re-follow at a time, by which point the growth has landed.
    method refollow_later {} {
        if {![my latched] || $FollowAfter ne ""} return
        set FollowAfter [after idle [list [self] refollow]]
    }
    method refollow {} {
        set FollowAfter ""
        if {[my latched] && [lindex [$Text yview] 1] < 1.0} {
            $Text yview moveto 1
        }
    }

    # An embedded window's <Configure>: realised or resized. One in view or
    # below it, which for a latched view is the tail, re-follows.
    method window_grew {w} {
        if {![my latched] || [catch {$Text index $w} i]} return
        if {[$Text compare $i >= @0,0]} { my refollow_later }
    }
    method window_watch {w} {
        bind $w <Configure> +[list [self] window_grew $w]
        return $w
    }
    # -create's script, run where Tk would run it, its window watched; ""
    # is Tk's "no window" and passes through.
    method window_realise {script} {
        set w [uplevel #0 $script]
        if {$w ne ""} { my window_watch $w }
        return $w
    }

    # A host may keep the widgets past the instance; nothing streamdoc bound
    # on them may call it after. That includes the wrapper round a built
    # window's -create script: Tk runs the script again if the window is
    # destroyed, so every window gets the host's script back, built or not.
    destructor {
        if {[info exists FollowAfter] && $FollowAfter ne ""} {
            after cancel $FollowAfter
        }
        foreach v {Text Top} {
            if {![info exists $v] || ![winfo exists [set $v]]} continue
            set tag streamdoc[set $v]
            foreach ev [bind $tag] { bind $tag $ev {} }
        }
        if {[info exists Find] && [winfo exists $Find]} { destroy $Find }
        if {[info exists Top] && [winfo exists $Top.sb]
                && [$Top.sb cget -command] eq [list [self] scroll_to]} {
            $Top.sb configure -command {}
        }
        if {![info exists Text] || ![winfo exists $Text]} return
        if {[$Text cget -yscrollcommand] eq [list [self] on_yscroll]} {
            $Text configure -yscrollcommand {}
        }
        foreach {- w i} [$Text dump -window 1.0 end] {
            if {$w ne "" && [winfo exists $w]} {
                set watch [list [self] window_grew $w]
                set lines [split [bind $w <Configure>] \n]
                bind $w <Configure> [join [lsearch -all -inline -exact \
                    -not $lines $watch] \n]
            }
            set c [$Text window cget $i -create]
            if {[string is list $c] && [llength $c] == 3
                    && [lrange $c 0 1] eq [list [self] window_realise]} {
                $Text window configure $i -create [lindex $c 2]
            }
        }
    }

    # ---- view-anchoring around streaming appends -----------------------
    #
    # A streamed append must not shift what the reader is looking at. The
    # document is append-only, so two cases cover it: with -autofollow on and
    # the latch held, keep the view on the tail so appends keep scrolling into
    # view, then once more on idle for growth that lands after the batch;
    # otherwise pin the character that was at the top of the viewport, so a
    # summary pop or rewind near the tail cannot tug the view. The pin keeps
    # that line's pixel offset too: `yview` on a mark alone would snap a tall
    # line part-scrolled off the top, an embedded table say, to its top edge.
    method anchor_save {} {
        if {[my opt autofollow] && [lindex [$Text yview] 1] >= 0.999} {
            set Latched 1
        }
        $Text mark set AnchorTop @0,0
        $Text mark gravity AnchorTop left
        set AnchorY [lindex [$Text dlineinfo AnchorTop] 1]
    }
    method anchor_restore {} {
        if {[my latched]} {
            $Text yview moveto 1
            my refollow_later
        } else {
            catch {
                $Text yview AnchorTop
                set y [lindex [$Text dlineinfo AnchorTop] 1]
                if {$AnchorY ne "" && $y ne "" && $y != $AnchorY} {
                    $Text yview scroll [expr {$y - $AnchorY}] pixels
                }
            }
        }
        catch {$Text mark unset AnchorTop}
    }

    # Run a script with the widget editable and the view anchored once,
    # restoring the prior state after. A streaming flush brackets many emits in
    # one batch so the reader's scroll position is saved and restored a single
    # time; the content door runs inside one.
    method batch {script} {
        set st [$Text cget -state]
        $Text configure -state normal
        my anchor_save
        set code [catch {uplevel 1 $script} res opts]
        my anchor_restore
        $Text configure -state $st
        return -options $opts $res
    }

    # ---- hooks ---------------------------------------------------------
    #
    # Working defaults so the base class runs as-is: no summary line, a plain
    # `summary` styling tag on any summary the host's override does produce,
    # and no per-region wiring.
    method summary_text {payload} { return "" }
    method region_tags {payload} { return [list summary] }
    method on_region_rendered {n} {}
    method on_reveal {idx} {}

    # ---- region lifecycle ----------------------------------------------

    # Open a region at the tail: elide tags (f#N strictly before d#N - the
    # priority order above), boundary marks, registry entry. The host then
    # emits the header line and body through the door. Returns the region's
    # index, the handle every other primitive takes.
    method region_open {payload} {
        if {$Cur >= 0} { error "a region is already open" }
        set n [llength $Regions]
        $Text tag configure f#$n -elide 0
        $Text tag configure d#$n -elide 1
        $Text mark set r#${n}s "end - 1 chars"
        $Text mark gravity r#${n}s left
        $Text mark set r#${n}e "end - 1 chars"
        $Text mark gravity r#${n}e right
        lappend Regions [dict create start r#${n}s end r#${n}e \
            summary 0 open 1 folded 0 shown 0 payload $payload]
        set Cur $n
        my check_invariant region_open
        return $n
    }

    # Lay f#N over region n's whole body, [header +1line linestart, end).
    # The one writer of the fold range: close, streamed append, and fold all
    # cover through here, so a range fix lands once.
    method cover_fold {n} {
        set R [lindex $Regions $n]
        set body [$Text index "[dict get $R start] +1line linestart"]
        set e [dict get $R end]
        if {[$Text compare $body < $e]} { $Text tag add f#$n $body $e }
    }

    # Close the open region. The fold range goes on whole here, covering
    # whatever part a fold during the stream laid.
    method region_close {} {
        if {$Cur < 0} return
        set n $Cur
        my summary_sync
        set R [lindex $Regions $n]
        my cover_fold $n
        set e [dict get $R end]
        $Text mark gravity $e left
        dict set R open 0
        lset Regions $n $R
        set Cur -1
        my on_region_rendered $n
        my check_invariant region_close
    }

    # reset: empty the document - drop every region's marks and elide tags,
    # wipe the buffer and clear the store. The base of a fresh feed. The
    # first call also seeds the base class's state; a host with bespoke widget
    # assembly (its own text widget in Text) starts here instead of setup.
    method reset {} {
        if {![info exists Regions]} {
            set Regions [list]
            set Cur -1
            set NextSave 0
        }
        # The buffer goes, and every hit index with it.
        my find_seed
        my latch_seed
        set FindMatches [list]
        set FindCur -1
        set FindPos ""
        set FindExcerpt [dict create]
        set st [$Text cget -state]
        $Text configure -state normal
        set n -1
        foreach R $Regions {
            incr n
            catch {$Text mark unset r#${n}s r#${n}e r#${n}m}
            $Text tag delete f#$n d#$n
        }
        $Text delete 1.0 end
        set Regions [list]
        set Cur -1
        $Text configure -state $st
        my check_invariant reset
    }

    # ---- content door ---------------------------------------------------
    #
    # Every character the host writes goes through here, inside `batch`.
    # With a region open the door feeds it. Any standing summary line is
    # popped first, a rewind to its mark, and append_close re-appends it
    # with the current payload; that is the one legal rewrite window a
    # mid-document summary gets. The pop keeps streamed content inside the
    # region instead of under its summary. With no region open the door
    # appends chrome at the tail. Emitted text is expected in whole
    # newline-terminated lines; the audit names the region whose header
    # lands mid-line when it is not.
    method append_open {} {
        if {$Cur >= 0 && [dict get [lindex $Regions $Cur] summary]} {
            my rewind r#${Cur}m
        }
        $Text mark set __emit "end - 1 chars"
        $Text mark gravity __emit right
        return __emit
    }
    method emit {mark text tags} {
        set i0 [$Text index $mark]
        $Text insert $mark $text $tags
        return [list $i0 [$Text index $mark]]
    }
    # The window, or the one -create builds, is watched so that its growth at
    # the tail re-follows a latched view.
    method emit_window {mark args} {
        set i0 [$Text index $mark]
        if {[dict exists $args -create]} {
            dict set args -create \
                [list [self] window_realise [dict get $args -create]]
        }
        if {[dict exists $args -window]} {
            my window_watch [dict get $args -window]
        }
        $Text window create $mark {*}$args
        return [list $i0 [$Text index $mark]]
    }
    method append_close {mark} {
        $Text mark unset $mark
        if {$Cur >= 0} {
            set n $Cur
            set R [lindex $Regions $n]
            if {[dict get $R folded]} {
                # A region folded mid-stream: the fresh lines landed past the
                # fold tag's range, so re-cover the body up to the new end.
                my cover_fold $n
            }
            my summary_sync
        }
        my check_invariant append_close
    }

    # The open door's mark, for a caller that did not open it.
    method door {} {
        if {"__emit" ni [$Text mark names]} { error "no door is open" }
        return __emit
    }

    # A left-gravity mark at the append point, for a later rewind. Left
    # gravity keeps it at the boundary while emits push past it; the mark
    # names where the provisional content began.
    method savepoint {} {
        set m "sd#[incr NextSave]"
        $Text mark set $m "end - 1 chars"
        $Text mark gravity $m left
        return $m
    }

    # Delete from a saved mark to the open region's end, so the caller can
    # re-emit that tail. The mark survives (left gravity holds it at the cut)
    # and a feed can rewind to the same point again; `discard` releases it
    # when the caller is done. A summary line standing past the mark goes with the
    # cut, and its bookkeeping with it - the summary pop is this primitive
    # applied to the summary's own mark.
    method rewind {mark} {
        if {$Cur < 0} { error "rewind with no open region" }
        set n $Cur
        set R [lindex $Regions $n]
        if {[$Text compare $mark < [dict get $R start]]} {
            error "rewind mark precedes the open region"
        }
        set st [$Text cget -state]
        $Text configure -state normal
        # Pin the cut as an index first: the summary pop below may unset the
        # very mark the caller handed in (the summary's own).
        set cut [$Text index $mark]
        if {[dict get $R summary] && [$Text compare r#${n}m >= $mark]} {
            $Text mark unset r#${n}m
            dict set R summary 0
            lset Regions $n $R
        }
        $Text delete $cut [dict get $R end]
        $Text configure -state $st
        my check_invariant rewind
    }
    method discard {mark} {
        catch {$Text mark unset $mark}
    }

    # ---- summary line ----------------------------------------------------

    # Make the open region's trailing summary reflect its current payload:
    # pop the old line if one stands, re-append if the summary_text hook has a
    # phrase for it. Legal only on the open region, whose summary is the last
    # content line - the rewrite splices no index before it. Closed regions
    # never come here; only their 1-char glyph may change, via swap_glyph.
    method summary_sync {} {
        if {$Cur < 0} return
        set n $Cur
        set st [$Text cget -state]
        $Text configure -state normal
        if {[dict get [lindex $Regions $n] summary]} { my rewind r#${n}m }
        set R [lindex $Regions $n]
        set txt [my summary_text [dict get $R payload]]
        if {$txt ne ""} {
            lassign [my opt glyphs] closed open
            set g [expr {[dict get $R shown] ? $open : $closed}]
            set em [dict get $R end]
            set i0 [$Text index $em]
            # Tagged f#N explicitly, so a region folded mid-stream keeps its
            # fresh summary hidden with the rest of its lines; never d#N - the
            # summary is the visible toggle for the hidden detail.
            $Text insert $em "$g $txt\n" \
                [list {*}[my region_tags [dict get $R payload]] f#$n]
            $Text mark set r#${n}m $i0
            $Text mark gravity r#${n}m left
            dict set R summary 1
            lset Regions $n $R
        }
        $Text configure -state $st
        my check_invariant summary_sync
    }

    # ---- fold and detail layers -------------------------------------------
    #
    # Each is a reader's action and lets go of the tail latch: a reader at
    # the tail unfolding the last region keeps the header they clicked.

    method fold {n} {
        set Latched 0
        set R [lindex $Regions $n]
        if {[dict get $R folded]} return
        # An open region's fold range is unsealed; cover what stands now, and
        # append_close re-covers as more streams in. Closed regions re-add
        # their fixed range - idempotent over region_close's add.
        my cover_fold $n
        $Text tag configure f#$n -elide 1
        $Text tag configure d#$n -elide 1   ;# re-folding re-hides detail
        dict set R folded 1
        dict set R shown 0
        lset Regions $n $R
        lassign [my opt glyphs] closed open
        my swap_glyph [dict get $R start] $closed
        if {[dict get $R summary]} { my swap_glyph r#${n}m $closed }
        my check_invariant fold
    }

    method unfold {n} {
        set Latched 0
        set R [lindex $Regions $n]
        if {![dict get $R folded]} return
        # d#N stays hidden: unfolding shows the region's prose and summary,
        # not its detail - that is detail_show's decision.
        $Text tag configure f#$n -elide 0
        dict set R folded 0
        lset Regions $n $R
        lassign [my opt glyphs] closed open
        my swap_glyph [dict get $R start] $open
        my check_invariant unfold
    }

    method toggle {n} {
        if {[dict get [lindex $Regions $n] folded]} {
            my unfold $n
        } else {
            my fold $n
        }
    }

    method detail_show {n} {
        set Latched 0
        set R [lindex $Regions $n]
        if {[dict get $R shown]} return
        $Text tag configure d#$n -elide 0
        dict set R shown 1
        lset Regions $n $R
        if {[dict get $R summary]} {
            my swap_glyph r#${n}m [lindex [my opt glyphs] 1]
        }
        my check_invariant detail_show
    }

    method detail_hide {n} {
        set Latched 0
        set R [lindex $Regions $n]
        if {![dict get $R shown]} return
        $Text tag configure d#$n -elide 1
        dict set R shown 0
        lset Regions $n $R
        if {[dict get $R summary]} {
            my swap_glyph r#${n}m [lindex [my opt glyphs] 0]
        }
        my check_invariant detail_hide
    }

    method detail_toggle {n} {
        if {[dict get [lindex $Regions $n] shown]} {
            my detail_hide $n
        } else {
            my detail_show $n
        }
    }

    # Fold every region: the table-of-contents reading, one header per region.
    method fold_all {} {
        set Latched 0
        for {set n 0} {$n < [llength $Regions]} {incr n} { my fold $n }
    }
    method expand_all {} {
        set Latched 0
        for {set n 0} {$n < [llength $Regions]} {incr n} { my unfold $n }
    }

    # Swap a 1-char state glyph with a same-length replace, so every index
    # downstream stays true. Callers arrive from click handlers on the
    # disabled document as often as from inside a batch, hence the -state
    # round trip. A glyphless header line keeps its first char.
    method swap_glyph {idx glyph} {
        set cur [$Text get $idx]
        lassign [my opt glyphs] closed open
        if {$cur ne $closed && $cur ne $open} return
        if {$cur eq $glyph} return
        set tags [lsearch -all -inline -not -exact [$Text tag names $idx] sel]
        set st [$Text cget -state]
        $Text configure -state normal
        $Text replace $idx "$idx +1c" $glyph $tags
        $Text configure -state $st
    }

    # ---- queries ----------------------------------------------------------

    # The region containing a text index; -1 for chrome and for the preamble
    # before the first region. The open region owns everything from its
    # header down to the tail.
    method region_at {idx} {
        set i [$Text index $idx]
        for {set n [expr {[llength $Regions] - 1}]} {$n >= 0} {incr n -1} {
            set R [lindex $Regions $n]
            if {[$Text compare $i < [dict get $R start]]} continue
            if {[$Text compare $i < [dict get $R end]]} { return $n }
            return -1
        }
        return -1
    }

    # A region's state for a host-side read, the boundary and summary line
    # positions resolved from the marks: {start end summary open folded shown
    # payload}, summary "" while no summary line stands.
    method region_info {n} {
        set R [lindex $Regions $n]
        return [dict create \
            start [$Text index [dict get $R start]] \
            end [$Text index [dict get $R end]] \
            summary [expr {[dict get $R summary] ? [$Text index r#${n}m] : ""}] \
            open [dict get $R open] \
            folded [dict get $R folded] \
            shown [dict get $R shown] \
            payload [dict get $R payload]]
    }

    method region_count {} { return [llength $Regions] }
    method live {} { return $Cur }
    method folded {n} { return [dict get [lindex $Regions $n] folded] }
    method shown {n} { return [dict get [lindex $Regions $n] shown] }
    # The elide tag the host lays on a region's detail content as it emits.
    method detail_tag {n} { return "d#$n" }
    method payload {n} { return [dict get [lindex $Regions $n] payload] }
    method payload_set {n payload} {
        set R [lindex $Regions $n]
        dict set R payload $payload
        lset Regions $n $R
    }

    # ---- reveal -------------------------------------------------------------

    # The one jump gate: `see` cannot land on an elided char, so unfold the
    # target's region first, and show its detail only when the index itself
    # sits in the detail layer - jumping to a visible line must not spill the
    # region's hidden blocks. The scroll must wait for the reshaped line
    # metrics. An un-elide moves thousands of display lines and the relayout
    # registers through an idle handler; a bare `see` in the same callback
    # scrolls to where the target used to be. A targeted `count -update`
    # fires too early, and so does a bare `sync`, both ahead of the idle
    # relayout that invalidates the metrics. Hence: drain idletasks, then
    # sync, then scroll. Click-latency price, paid only on a jump.
    #
    # align `see` is Tk's: a target near the view scrolls just into it, a
    # far one is centred. `top` puts the head of the index's line on the top
    # edge, so a hit deep in a wrapped line still shows where the line
    # begins, or as near as the widget scrolls in the last screenful.
    # on_reveal runs ahead of all of it, so a window the scroll realises is
    # born in the state the host set.
    #
    # A jump is the reader's: it lets go of the tail latch, unless its target
    # sits on the last line, where a held latch stays held.
    method reveal {idx {align see}} {
        set how [dict create see [list see $idx] top [list yview "$idx linestart"]]
        if {![dict exists $how $align]} {
            error "bad align \"$align\": must be [join [dict keys $how] { or }]"
        }
        my on_reveal $idx
        set held [expr {[my latched]
            && [$Text compare "$idx linestart" >= "end - 2 chars linestart"]}]
        set n [my region_at $idx]
        if {$n >= 0} {
            if {[dict get [lindex $Regions $n] folded]} { my unfold $n }
            if {"d#$n" in [$Text tag names $idx]} { my detail_show $n }
        }
        set Latched $held
        update idletasks
        $Text sync
        $Text {*}[dict get $how $align]
    }

    # ---- find (Ctrl-F) ------------------------------------------------------

    # Seed the find state once; setup and reset both come here, so a host
    # with bespoke assembly that starts at reset has it too.
    method find_seed {} {
        if {[info exists FindMatches]} return
        set FindVar ""
        set FindPos ""
        set FindMatches [list]
        set FindCur -1
        set FindNocase 1
        set FindExcerpt [dict create]
        set LastFindVar ""
        set LastNocase 1
    }

    # Build the bar, unplaced until find_show. The Aa box reads "match
    # case", so it is checked while FindNocase is 0.
    method build_find {} {
        set Find $Top.find
        ttk::frame $Find
        ttk::label $Find.lbl -text "Find:"
        ttk::entry $Find.e -textvariable [my varname FindVar] -width 30
        ttk::label $Find.pos -textvariable [my varname FindPos]
        ttk::checkbutton $Find.case -text "Aa" -variable [my varname FindNocase] \
            -onvalue 0 -offvalue 1 -command [list [self] find_typing]
        ttk::button $Find.prev -text "Prev" -command [list [self] find_prev]
        ttk::button $Find.next -text "Next" -command [list [self] find_next]
        ttk::button $Find.close -text "✕" -command [list [self] find_hide]
        pack $Find.lbl -side left -padx 4
        pack $Find.e -side left -fill x -expand 1
        foreach w {pos case prev next close} { pack $Find.$w -side left -padx 2 }
        # break: the Text class binds Control-f to a cursor move.
        bind [my bindtag $Top] <Control-f> [list [self] find_show]
        bind [my bindtag $Text] <Control-f> "[list [self] find_show]; break"
        bind [my bindtag $Text] <Escape> [list [self] find_hide]
        bind $Find.e <Escape> [list [self] find_hide]
        bind $Find.e <Return> [list [self] find_next]
        bind $Find.e <Shift-Return> [list [self] find_prev]
        bind $Find.e <KeyRelease> [list [self] find_typing]
    }

    # The default place: the grid row under the text and scrollbar, which
    # setup grids at row 0.
    method place_find {frame} {
        grid $frame -row 1 -column 0 -columnspan 2 -sticky ew
    }

    method find_show {} {
        my place_find $Find
        focus $Find.e
        $Find.e selection range 0 end
    }

    # Unplaced through whichever manager place_find chose. The insert mark
    # stays on the last hit, so the keyboard picks up the document there.
    method find_hide {} {
        set mgr [winfo manager $Find]
        if {$mgr ne ""} { $mgr forget $Find }
        my find_clear
        if {[string match $Find* [focus]]} { focus $Text }
    }

    method find_clear {} {
        $Text tag remove find 1.0 end
        set FindMatches [list]
        set FindCur -1
        set FindPos ""
        set FindExcerpt [dict create]
        my find_cleared
        my check_invariant find_clear
    }

    # Tag every hit of a literal term `find` and return the hits in document
    # order. Existing `find` tags stay, so a host collecting term by term
    # keeps them all lit. -elide finds folded and hidden text; reveal opens
    # it on the jump. A hit starting under a find_chrome_tags tag is skipped.
    # find_extra hits are merged in by resolved index and keep their
    # excerpts; an index named twice counts once, under its first excerpt. A
    # text hit drops any excerpt an earlier collect left at its index, so it
    # always excerpts its line.
    method collect {term nocase} {
        if {$term eq ""} { return [list] }
        set opts [list -elide -count len]
        if {$nocase} { lappend opts -nocase }
        set skip [my find_chrome_tags]
        set bound [my find_bound]
        set hits [list]
        set start 1.0
        while {1} {
            set len 0
            set m [$Text search {*}$opts -- $term $start $bound]
            if {$m eq ""} break
            set start "$m + ${len}c"
            set chrome 0
            foreach tg [$Text tag names $m] {
                if {$tg in $skip} { set chrome 1; break }
            }
            if {$chrome} continue
            $Text tag add find $m "$m + ${len}c"
            dict unset FindExcerpt $m
            lappend hits $m
        }
        foreach hit [my find_extra $term $nocase] {
            lassign $hit idx excerpt
            set idx [$Text index $idx]
            if {$idx in $hits} continue
            dict set FindExcerpt $idx $excerpt
            lappend hits $idx
        }
        my check_invariant collect
        return [lsort -command [list [self] cmp_index] $hits]
    }

    # The bar's collection: a fresh match set for one term, under the case
    # box, nothing shown yet. The entry takes the term too, so a step after
    # a host's call walks this set instead of recollecting for the entry's
    # old text.
    method collect_matches {pattern} {
        $Text tag remove find 1.0 end
        set FindExcerpt [dict create]
        set FindMatches [my collect $pattern $FindNocase]
        set FindCur -1
        set FindVar $pattern
        set LastFindVar $pattern
        set LastNocase $FindNocase
        my update_find_readout
        my on_find_collected
        return $FindMatches
    }

    method find_next {} { my find_step 1 }
    method find_prev {} { my find_step -1 }

    # Step dir hits with wraparound, recollecting first when the term or the
    # case box changed since the set was collected. A set a host filled
    # itself steps as it stands while the entry still holds the last term.
    method find_step {dir} {
        if {![llength $FindMatches] || $FindVar ne $LastFindVar
                || $FindNocase != $LastNocase} {
            my collect_matches $FindVar
        }
        set total [llength $FindMatches]
        if {!$total} {
            # "0 of 0" tells a search that found nothing from no search yet.
            set FindPos "0 of 0"
            catch {bell}
            return
        }
        if {$FindCur < 0} {
            set FindCur [expr {$dir > 0 ? 0 : $total - 1}]
        } else {
            set FindCur [expr {($FindCur + $dir) % $total}]
        }
        set idx [lindex $FindMatches $FindCur]
        my reveal $idx
        $Text mark set insert $idx
        my on_find_stepped $FindCur
        my update_find_readout
    }

    method update_find_readout {} {
        set total [llength $FindMatches]
        if {!$total} { set FindPos ""; return }
        set FindPos "[expr {$FindCur < 0 ? 1 : $FindCur + 1}] of $total"
    }

    # An edited term or a flipped case box strands the readout: blank it
    # until the next step recollects.
    method find_typing {} {
        if {$FindVar ne $LastFindVar || $FindNocase != $LastNocase} {
            set FindPos ""
        }
    }

    # Document order for lsort; marks and indices compare alike.
    method cmp_index {a b} {
        if {[$Text compare $a < $b]} { return -1 }
        if {[$Text compare $a > $b]} { return 1 }
        return 0
    }

    method find_chrome_tags {} { return [list summary] }
    method find_bound {} { return end }
    method find_extra {term nocase} { return [list] }
    method find_excerpt {idx} {
        set idx [$Text index $idx]
        if {[dict exists $FindExcerpt $idx]} { return [dict get $FindExcerpt $idx] }
        return [$Text get "$idx linestart" "$idx lineend"]
    }
    method on_find_collected {} {}
    method on_find_stepped {i} {}
    method find_cleared {} {}
}
