package require Tcl 9
package require Tk
package provide streamdoc 1.0

namespace eval ::streamdoc {}

# ::streamdoc::StreamDoc - the generic "streaming document of foldable
# regions" engine.
#
# A StreamDoc owns an append-only document rendered into a single read-only
# text widget: chrome (free text between regions) interleaved with REGIONS,
# each a header line, a body, and an optional trailing summary line. The
# host supplies every character through the content door and the hooks
# (Template Method); the engine owns the marks, the two elide layers and
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
# Two elide layers per region, engine-owned - no other code may mutate a
# tag's -elide:
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
# popping any standing summary line first and re-appending it at close (the
# summary transaction, engine-internal); between regions the door appends
# chrome at the tail. `savepoint` takes a left-gravity mark at the append
# point and `rewind mark` deletes from it to the open region's end, so a
# caller can re-emit a provisional tail; the summary pop is built on it.
#
# Glyphs: the first char of a header line and of a summary line is a state
# glyph from the -glyphs pair. fold/unfold and detail_show/hide swap it with
# a same-length replace, so every index downstream stays true. A first char
# that is not one of the pair is left alone; glyphless headers work.
#
# Anti-self-scroll: `batch` brackets a streamed mutation with anchor_save /
# anchor_restore, so content landing below a parked reader never moves the
# line they are on. With -autofollow on and the reader at the tail, the view
# latches there and follows appends (the tail -f contract), released the
# moment they scroll away; <<AtBottom>> / <<LeftBottom>> fire on the host
# frame at the edges, and `follow` jumps back to the tail.
#
# Hooks the host overrides, each with a working default:
#   summary_text payload    the summary phrase; "" takes no summary line
#   region_tags payload     tags laid on the engine-written summary line
#   on_region_rendered n    wire a just-closed region (bindings, indices)

oo::class create ::streamdoc::StreamDoc {
    variable Top          ;# the host frame setup built into
    variable Text         ;# the document text widget
    variable Regions      ;# per-region dicts, in document order:
                          ;# {start end summary open folded shown payload}
    variable Cur          ;# index of the open region, or -1
    variable Opts         ;# widget options decoupling the engine from any host
    variable NextSave     ;# savepoint mark counter
    variable AtBottom     ;# tail-latch state across a streaming batch
    variable WasAtBottom  ;# last observed bottom state, edges fire the events

    # ---- structural invariant ----------------------------------------
    #
    # The mark contract every mutation must preserve: each region's [start,end)
    # is well-formed, starts on a line start, and the regions are ordered and
    # disjoint down the buffer; a standing summary mark sits inside its region;
    # the open region's end rides the buffer tail. A violation means a mark
    # desynced - the class of fault behind a fold that swallows its neighbour.
    # Gated on the STREAMDOC_AUDIT env var so production pays nothing; when on,
    # it logs the first violation with the call chain and latches off, naming
    # the primitive that broke the contract. Every primitive calls this at its
    # tail.
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
    # The engine takes its host-specific look as options; its body holds no
    # host references. The lot: the document font, the closed/open glyph
    # pair, and the tail latch. Defaults are a plain Tk look so the widget
    # runs standalone; a host overrides them through `configure` before the
    # body is built.
    method engine_default_opts {} {
        return [dict create \
            font TkTextFont \
            glyphs [list ▸ ▾] \
            autofollow 0]
    }
    method configure {args} {
        if {![info exists Opts]} { set Opts [my engine_default_opts] }
        set known [my engine_default_opts]
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
        if {![info exists Opts]} { set Opts [my engine_default_opts] }
        return [dict get $Opts $k]
    }

    # ---- body assembly -----------------------------------------------

    # The whole construction ritual in one call: seed the engine state and
    # build the document text and its scrollbar into `parent` (a frame the
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
            -command [list $parent.text yview]
        grid $parent.text -row 0 -column 0 -sticky nsew
        grid $parent.sb   -row 0 -column 1 -sticky ns
        grid columnconfigure $parent 0 -weight 1
        grid rowconfigure    $parent 0 -weight 1
        set Text $parent.text
    }

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
        $Text yview moveto 1
    }

    # ---- view-anchoring around streaming appends -----------------------
    #
    # A streamed append must not shift what the reader is looking at. The
    # document is append-only, so two cases cover it: with -autofollow on and
    # the reader at the tail, keep them latched there so appends keep scrolling
    # into view; otherwise pin the character that was at the top of the
    # viewport, so a summary pop or rewind near the tail cannot tug the view.
    method anchor_save {} {
        set AtBottom [expr {[lindex [$Text yview] 1] >= 0.999}]
        $Text mark set AnchorTop @0,0
        $Text mark gravity AnchorTop left
    }
    method anchor_restore {} {
        if {[my opt autofollow] && [info exists AtBottom] && $AtBottom} {
            $Text yview moveto 1
        } else {
            catch {$Text yview AnchorTop}
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

    # Close the open region. The summary is written through summary_sync,
    # the same appender the streaming path uses. The fold tag then goes over
    # the whole body in one definitive add, which subsumes any incremental
    # fold-during-stream adds. Last the end mark's gravity is sealed; the
    # next insert at the tail would otherwise drag the mark along.
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
    # first call also seeds the engine state; a host with bespoke widget
    # assembly (its own text widget in Text) starts here instead of setup.
    method reset {} {
        if {![info exists Regions]} {
            set Regions [list]
            set Cur -1
            set NextSave 0
        }
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
    method emit_window {mark args} {
        set i0 [$Text index $mark]
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

    method fold {n} {
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
        for {set n 0} {$n < [llength $Regions]} {incr n} { my fold $n }
    }
    method expand_all {} {
        for {set n 0} {$n < [llength $Regions]} {incr n} { my unfold $n }
    }

    # Swap a 1-char state glyph in place: a same-length replace, so every
    # index downstream stays true. Re-applies the tags found under the old
    # glyph (minus a transient sel) and runs under a saved and restored
    # -state, because callers arrive from click handlers on the disabled
    # document as often as from inside a batch. A char outside the glyph pair
    # is left alone, so a glyphless header line never loses its first char.
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
    # region's hidden blocks. The see must wait for the reshaped line
    # metrics. An un-elide moves thousands of display lines and the relayout
    # registers through an idle handler; a bare `see` in the same callback
    # scrolls to where the target used to be. A targeted `count -update`
    # fires too early, and so does a bare `sync`, both ahead of the idle
    # relayout that invalidates the metrics. Hence: drain idletasks, then
    # sync, then see. Click-latency price, paid only on a jump.
    method reveal {idx} {
        set n [my region_at $idx]
        if {$n >= 0} {
            if {[dict get [lindex $Regions $n] folded]} { my unfold $n }
            if {"d#$n" in [$Text tag names $idx]} { my detail_show $n }
        }
        update idletasks
        $Text sync
        $Text see $idx
    }
}
