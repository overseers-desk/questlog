# Shared session context-action catalogue. Both the session-list right-click
# menu (ui/sessions.tcl) and the viewer's "⋯" overflow menu (ui/viewer.tcl)
# build their entries from here, so the two never drift.
#
# The action set is stateless: a target descriptor plus pure assembly. No
# per-instance state lives here, so it is a namespace of procs, not a class.
# The two hosts differ only in the context they pass.
#
# `populate $menu $ctx` clears the menu and re-adds the commands, returning the
# entry indices the host needs for the per-open `apply_state` pass. Rebuilding
# on every popup keeps the target current with no stale-capture hazard.
#
# ctx keys (single-session mode, the default):
#   target    dict {path uuid cwd folder}
#   parent    a window for dialogs (tk_getSaveFile / tk_messageBox -parent)
#   clipboard command prefix; invoked {*}$clip <string>
#   on_open   command prefix; invoked {*}$cb path   (omit to drop "Open in viewer")
#   on_move   command prefix; invoked {*}$cb [list path]
#   on_bookmark command prefix; invoked {*}$cb path
#   on_rename command prefix; invoked {*}$cb path
#
# ctx keys present only on a search-hit right-click (the list's snippet rows;
# the viewer's "⋯" menu never sets them, so it shows neither hit entry):
#   hit        dict {lineoff snippet}; adds "Copy this snippet", and - when
#              on_open is also present - "Open at this match". The snippet is
#              the model's full stored match text, resolved before it reaches
#              here (never from a script).
#   on_open_at command prefix; invoked {*}$cb path lineoff (opens at the match)
#
# ctx keys (mode=multi, a multi-selection): only the actions that apply to many
# sessions at once.
#   mode           "multi"
#   paths          the selected session paths
#   all_bookmarked 1 iff every path already carries the bookmark bit
#   on_move        command prefix; invoked {*}$cb $paths
#   on_bookmark_set command prefix; invoked {*}$cb $paths

namespace eval ::questlog::ui::session_actions {}

# Read a target field from the context.
proc ::questlog::ui::session_actions::tget {ctx key} {
    return [dict get [dict get $ctx target] $key]
}

proc ::questlog::ui::session_actions::populate {menu ctx} {
    $menu delete 0 end
    if {[dict getdef $ctx mode single] eq "multi"} {
        return [populate_multi $menu $ctx]
    }
    set indices [dict create resume_indices {} reveal_index -1 \
        bookmark_index -1]

    if {[dict exists $ctx on_open]} {
        $menu add command -label "Open in viewer" -accelerator "Return" \
            -command [concat [dict get $ctx on_open] [list [tget $ctx path]]]
        # A right-click on a search hit can open the session deep-linked to that
        # match's line - the same open the badge's left-click performs. Present
        # only when the pointer was on a hit; the viewer's menu never is.
        if {[dict exists $ctx hit]} {
            $menu add command -label "Open at this match" \
                -command [concat [dict get $ctx on_open_at] \
                    [list [tget $ctx path] [dict get $ctx hit lineoff]]]
        }
        $menu add separator
    }

    $menu add command -label "Copy resume command" -accelerator "Ctrl+R" \
        -command [list [namespace current]::act_copy_resume $ctx]
    dict lappend indices resume_indices [$menu index end]
    $menu add command -label "Copy session id" \
        -command [list [namespace current]::act_copy_uuid $ctx]
    $menu add command -label "Copy session path" \
        -command [list [namespace current]::act_copy_path $ctx]
    # One copy slot for a message body: on a hit right-click it copies the matched
    # snippet (the model's full stored match, already resolved into the ctx); with
    # no hit it copies the session's last assistant output. The two never both
    # show - a hit's evidence is the snippet, not the tail of the session.
    if {[dict exists $ctx hit]} {
        $menu add command -label "Copy this snippet" \
            -command [list [namespace current]::act_copy_snippet $ctx]
    } else {
        $menu add command -label "Copy last assistant output" \
            -command [list [namespace current]::act_copy_last_assistant $ctx]
    }
    $menu add command -label "Copy session as Markdown" \
        -command [list [namespace current]::act_copy_markdown $ctx]
    $menu add command -label "Export to .md..." \
        -command [list [namespace current]::act_export_markdown $ctx]

    $menu add separator
    $menu add command -label "Resume in new terminal tab" \
        -command [list [namespace current]::act_resume $ctx 0]
    dict lappend indices resume_indices [$menu index end]
    $menu add command -label "Resume forked" \
        -command [list [namespace current]::act_resume $ctx 1]
    dict lappend indices resume_indices [$menu index end]

    $menu add separator
    $menu add command -label "Move to..." \
        -command [concat [dict get $ctx on_move] [list [list [tget $ctx path]]]]
    $menu add command -label "Reveal folder" \
        -command [list [namespace current]::act_reveal $ctx]
    dict set indices reveal_index [$menu index end]

    $menu add separator
    # The Bookmark label is rewritten by apply_state to Add/Remove, so it is
    # addressed by index, not label.
    $menu add command -label "Bookmark" \
        -command [concat [dict get $ctx on_bookmark] [list [tget $ctx path]]]
    dict set indices bookmark_index [$menu index end]
    $menu add command -label "Rename..." \
        -command [concat [dict get $ctx on_rename] [list [tget $ctx path]]]

    return $indices
}

# The multi-selection menu: Move and Bookmark, the two actions defined over a
# set of sessions. Labels carry the count; the bookmark label states the
# tri-state outcome (remove from all when all already carry the bit, else add
# to all). Static, so no apply_state pass is needed.
proc ::questlog::ui::session_actions::populate_multi {menu ctx} {
    set paths [dict get $ctx paths]
    set n [llength $paths]
    $menu add command -label "Move $n sessions to..." \
        -command [concat [dict get $ctx on_move] [list $paths]]
    set bm_label [expr {[dict get $ctx all_bookmarked] \
        ? "Remove bookmark from $n sessions" : "Add bookmark to $n sessions"}]
    $menu add command -label $bm_label \
        -command [concat [dict get $ctx on_bookmark_set] [list $paths]]
    return [dict create resume_indices {} reveal_index -1 bookmark_index -1]
}

# Per-open dynamic pass: grey what the target cannot support and set the
# Bookmark label. state keys: is_bookmarked has_cwd has_folder. Rename carries
# no state here: it stays enabled on a running session and the rename dialog's
# OK button is what disables while the session is live.
proc ::questlog::ui::session_actions::apply_state {menu indices state} {
    set rstate [expr {[dict get $state has_cwd] ? "normal" : "disabled"}]
    foreach i [dict get $indices resume_indices] {
        $menu entryconfigure $i -state $rstate
    }
    $menu entryconfigure [dict get $indices reveal_index] \
        -state [expr {[dict get $state has_folder] ? "normal" : "disabled"}]
    $menu entryconfigure [dict get $indices bookmark_index] \
        -label [expr {[dict get $state is_bookmarked] \
            ? "Remove bookmark" : "Add bookmark"}]
}

# ---- Tier-1 actions: depend only on the target + clipboard/parent. ----------

proc ::questlog::ui::session_actions::act_copy_resume {ctx} {
    {*}[dict get $ctx clipboard] [::questlog::ui::terminal::resume_command \
        [tget $ctx cwd] [tget $ctx uuid]]
}
proc ::questlog::ui::session_actions::act_copy_uuid {ctx} {
    {*}[dict get $ctx clipboard] [tget $ctx uuid]
}
proc ::questlog::ui::session_actions::act_copy_path {ctx} {
    {*}[dict get $ctx clipboard] [tget $ctx path]
}
proc ::questlog::ui::session_actions::act_copy_last_assistant {ctx} {
    {*}[dict get $ctx clipboard] \
        [::logman::last_assistant_text [tget $ctx path]]
}
# The matched snippet the hit right-click carried: the model's full stored match
# text, resolved from the reveal registry before it reached the ctx.
proc ::questlog::ui::session_actions::act_copy_snippet {ctx} {
    {*}[dict get $ctx clipboard] [dict get $ctx hit snippet]
}
# The whole session as Markdown on the clipboard: the text-only transcript
# (USER/ASSISTANT/SYSTEM turns, segmented at compaction boundaries and idle gaps
# the way the viewer breaks it), with tool calls, results and thinking folded
# inline exactly as the viewer renders them. The CLI `questlog show` shares this
# emitter; the GUI leaves its record-number anchors off.
proc ::questlog::ui::session_actions::act_copy_markdown {ctx} {
    {*}[dict get $ctx clipboard] \
        [::questlog::markdown::export_session [tget $ctx path]]
}
# The same Markdown to a file the reader picks. A cancelled dialog returns
# empty and does nothing; a write failure is surfaced rather than swallowed.
proc ::questlog::ui::session_actions::act_export_markdown {ctx} {
    set path [tget $ctx path]
    set parent [dict get $ctx parent]
    set initial "[file rootname [file tail $path]].md"
    set dest [tk_getSaveFile -parent $parent -title "Export session to Markdown" \
        -defaultextension .md -initialfile $initial \
        -filetypes {{Markdown {.md}} {{All files} *}}]
    if {$dest eq ""} return
    set md [::questlog::markdown::export_session $path]
    if {[catch {
        set fh [open $dest w]
        chan configure $fh -encoding utf-8
        puts -nonewline $fh $md
        close $fh
    } err]} {
        tk_messageBox -parent $parent -icon error -title "Export session" \
            -message "Could not write $dest" -detail $err
    }
}
proc ::questlog::ui::session_actions::act_resume {ctx fork} {
    ::questlog::ui::terminal::launch_tab [tget $ctx cwd] [tget $ctx uuid] $fork
}
proc ::questlog::ui::session_actions::act_reveal {ctx} {
    set dir [file join [::questlog::path::projects_root] [tget $ctx folder]]
    set opener [expr {$::tcl_platform(os) eq "Darwin" ? "open" : "xdg-open"}]
    if {[catch {exec $opener $dir &} err]} {
        puts stderr "questlog: $opener failed: $err"
    }
}
