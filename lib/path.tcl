package require Tcl 9

namespace eval ::questlog::path {
    namespace export encode_cwd projects_root pretty_home display_label \
        list_all_projects ensure_project_folder candidate_cwds_for \
        move_session set_bookmark clear_bookmark launch_cwd canon_dir \
        container_tree
}

# Architectural gate. Rename Tcl's `file` command and replace it with a
# dispatcher that rejects the mutating subcommands. Anything outside
# this file that tries to mkdir, rename, delete or copy a path will
# fail loudly at the call site instead of silently producing an orphan
# folder under ~/.claude/projects/. Read-only subcommands (isdirectory,
# mtime, size, dirname, tail, join, normalize, exists, isfile, ...)
# pass through untouched - the rest of the codebase uses them
# constantly for legitimate non-mutating purposes.
#
# The original `file` is preserved as ::questlog::path::_real_file and is
# the way the legitimate sinks reach the filesystem: this module's own
# move/bookmark/mkdir, and ::questlog::ui::state, which writes its XDG flag
# directory through the same hatch. Idempotent: a second source of this file
# is a no-op.
if {[info commands ::questlog::path::_real_file] eq ""} {
    rename file ::questlog::path::_real_file
    proc file {subcmd args} {
        if {$subcmd in {rename mkdir delete copy attributes link}} {
            set caller "top-level"
            catch {set caller [info level -1]}
            return -code error \
                "file $subcmd is restricted to ::questlog::path::* (called from $caller): $args"
        }
        return [::questlog::path::_real_file $subcmd {*}$args]
    }
}

# Canonical absolute form of a user-typed directory path (the subtree bound's
# entry points: the toolbar's folder editor and the CLI's --subtree). Tcl 9
# expands ~ nowhere - file normalize treats a leading ~ as an ordinary
# relative segment - so a typed ~/x would ride through every comparison as
# a literal and the bound would silently match nothing. Expand the tilde
# here and normalize, so the predicates in ::questlog::scan only ever see
# the same absolute form Claude Code records as a session cwd. A ~user for
# an unknown user throws (the caller turns that into its own loud failure);
# existence is not required, since scoping to a since-deleted directory is
# how sessions of a removed repo are found.
proc ::questlog::path::canon_dir {dir} {
    if {$dir eq ""} { return "" }
    return [file normalize [file tildeexpand $dir]]
}

# Display-only: abbreviate a leading $HOME to ~. The model keeps absolute
# paths so encode_cwd, xdg-open and the resume command stay literal.
proc ::questlog::path::pretty_home {path} {
    set home [file home]
    if {$path eq $home || [string match "$home/*" $path]} {
        return "~[string range $path [string length $home] end]"
    }
    return $path
}

# Root of the on-disk Claude session store.
proc ::questlog::path::projects_root {} {
    return [file join [::questlog::config::claude_dir] projects]
}

# The directory questlog was launched from. Prefer the shell's logical
# $PWD, which preserves the symlinked path the user cd'd through (the same
# form Claude Code records as a session cwd), and fall back to the physical
# getcwd when $PWD is unset. $PWD is exported by interactive shells but not
# by GUI launchers (Finder, Spotlight, the Dock, a .desktop entry), so
# reading $::env(PWD) directly would error there; [pwd] is always defined.
proc ::questlog::path::launch_cwd {} {
    if {[info exists ::env(PWD)] && [file isdirectory $::env(PWD)]} {
        return $::env(PWD)
    }
    return [pwd]
}

# Encode an ABSOLUTE path into the basename form Claude uses on disk:
# every non-alphanumeric character collapses to '-'. This matches Claude
# Code's own encoding, so it can be compared against on-disk basenames
# and used to create the destination folder for a move. The inverse is
# not algorithmic - see candidate_cwds_for, which walks the filesystem.
#
# Normalises first so that callers that pass a trailing slash, doubled
# slashes, '.', '..' or other un-canonical forms produce the same basename
# Claude itself would have written for the canonical cwd. The input must
# be an absolute path; for encoding a bare directory-entry name (single
# component, no slashes) use _encode_segment.
proc ::questlog::path::encode_cwd {cwd} {
    if {$cwd eq ""} { return "" }
    return [_encode_segment [file normalize $cwd]]
}

# Pure regsub: every non-alphanumeric character to '-'. No normalisation,
# no filesystem touch. The right tool for encoding a bare directory name
# obtained from glob (e.g. inside _walk), where calling file normalize
# would (mis-)resolve the bare name against the process cwd.
proc ::questlog::path::_encode_segment {name} {
    return [regsub -all {[^A-Za-z0-9]} $name -]
}

# The user-facing label for a project folder: its resolved cwd relative to
# the cwd of the folder it sits under, or abbreviated and absolute when it
# sits under none; otherwise the raw basename, which is honest about the
# failure rather than a fictional path. $cwd is whatever the canonical
# resolver returned ("" if it could not resolve the folder).
proc ::questlog::path::display_label {cwd folder_basename {parent_cwd ""}} {
    if {$cwd eq ""} { return $folder_basename }
    if {$parent_cwd eq ""} { return [pretty_home $cwd] }
    set pre [expr {$parent_cwd eq "/" ? "/" : "$parent_cwd/"}]
    return [string range $cwd [string length $pre] end]
}

# Every project folder basename on disk under ~/.claude/projects/, sorted:
# what exists whether or not the session list has loaded a session from it.
proc ::questlog::path::list_all_projects {} {
    set root [projects_root]
    if {![file isdirectory $root]} { return [list] }
    return [lsort [lmap d [glob -nocomplain -directory $root -type d -- *] { file tail $d }]]
}

# Return the project-folder path for a cwd, creating it if absent.
# Used when moving a session into a project that has no folder yet.
# This is the single user-input -> filesystem gate: if the cwd does not
# name a real directory, refuse rather than silently create an orphan
# project folder from a typo'd path. The mkdir reaches through the
# private _real_file because the public `file` is the trap from above.
proc ::questlog::path::ensure_project_folder {cwd} {
    if {$cwd eq ""} { error "destination cwd is empty" }
    set normalized [file normalize $cwd]
    if {![file isdirectory $normalized]} {
        error "no such directory: $normalized"
    }
    set folder [encode_cwd $normalized]
    set dir [file join [projects_root] $folder]
    if {![file isdirectory $dir]} { ::questlog::path::_real_file mkdir $dir }
    return $dir
}

# Move a session jsonl into the project folder for $dst_cwd. The single
# legitimate file-rename sink in the program. Validates twice: the
# destination cwd must already name a real directory (defensive against
# any future caller that skipped ensure_project_folder), and the
# source file must exist. The actual rename goes through _real_file
# because the public `file` is the trap.
proc ::questlog::path::move_session {src_path dst_cwd} {
    if {![file isfile $src_path]} {
        error "source not found: $src_path"
    }
    if {$dst_cwd eq ""} { error "destination cwd is empty" }
    set normalized [file normalize $dst_cwd]
    if {![file isdirectory $normalized]} {
        error "no such directory: $normalized"
    }
    set dst_folder [ensure_project_folder $normalized]
    set src_folder [file dirname $src_path]
    if {[file normalize $src_folder] eq [file normalize $dst_folder]} {
        error "source and destination are the same folder"
    }
    set new_path [file join $dst_folder [file tail $src_path]]
    if {[file exists $new_path]} {
        error "destination already exists: $new_path"
    }
    # A session's subagent transcripts live in a sidecar dir named for its uuid
    # (<folder>/<uuid>/subagents/agent-*.jsonl). Move it alongside the jsonl in the
    # same operation, or the chevron, child rows and their cost vanish on the next
    # rescan and the files are orphaned in the source folder.
    set uuid [file rootname [file tail $src_path]]
    set src_side [file join $src_folder $uuid]
    set dst_side [file join $dst_folder $uuid]
    set move_side [file isdirectory $src_side]
    if {$move_side && [file exists $dst_side]} {
        error "destination already exists: $dst_side"
    }
    ::questlog::path::_real_file rename -- $src_path $new_path
    if {$move_side} {
        ::questlog::path::_real_file rename -- $src_side $dst_side
    }
    return $new_path
}

# Bookmark a session by setting the owner-execute bit on its jsonl, and
# clear it by removing that bit. The +x bit is the whole bookmark store -
# no sidecar, no database - and a rename preserves it, so a bookmark
# follows a moved session for free. These are the only legitimate callers
# of the trapped `file attributes`; like move_session they reach the
# filesystem through _real_file. The symbolic u+x / u-x form touches only
# the owner-execute bit, leaving read/write bits untouched (0644 <-> 0744).
proc ::questlog::path::set_bookmark {path} {
    if {![file isfile $path]} { error "session not found: $path" }
    ::questlog::path::_real_file attributes $path -permissions u+x
    return 1
}

proc ::questlog::path::clear_bookmark {path} {
    if {![file isfile $path]} { error "session not found: $path" }
    ::questlog::path::_real_file attributes $path -permissions u-x
    return 1
}

# Find every real directory on disk whose Claude-encoded basename equals
# $basename. Claude Code replaces every non-alphanumeric in the cwd with
# '-', which loses the boundary between '/', '.', '-', '_' and so on.
# Recover ambiguities by walking the filesystem level by level: at each
# step glob the current directory and accept any child whose own encoded
# form equals one of the next 1..k '-'-segments of the remaining basename.
# Returns the list of recovered paths. Empty list means the original
# directory is gone (a "black hole" that should not be offered as a
# destination). A list of length > 1 means the basename is genuinely
# ambiguous and the caller has to present each candidate.
proc ::questlog::path::candidate_cwds_for {basename} {
    if {$basename eq ""} { return [list] }
    if {[string index $basename 0] eq "-"} {
        set rest [string range $basename 1 end]
    } else {
        set rest $basename
    }
    return [_walk "/" [split $rest -]]
}

proc ::questlog::path::_walk {dir parts} {
    if {[llength $parts] == 0} { return [list $dir] }
    set entries [concat \
        [glob -nocomplain -directory $dir -type d -tails -- *] \
        [glob -nocomplain -directory $dir -type d -tails -- .*]]
    set entries [lsearch -all -inline -not -exact $entries .]
    set entries [lsearch -all -inline -not -exact $entries ..]
    set out [list]
    set n [llength $parts]
    for {set k 1} {$k <= $n} {incr k} {
        set encoded [join [lrange $parts 0 [expr {$k-1}]] -]
        foreach entry $entries {
            if {[_encode_segment $entry] eq $encoded} {
                foreach r [_walk [file join $dir $entry] \
                                 [lrange $parts $k end]] {
                    lappend out $r
                }
            }
        }
    }
    return $out
}

# Group resolved folder directories into the tree the session list draws.
# `entries` is a list of {key dir} pairs, one per folder under the projects
# root, dir its absolute directory. `groups` holds pairs of the same shape for
# project folders with no sessions in view. Returns the root nodes; each node
# is a dict {label dir keys children}, where keys names the folders at that
# directory and children holds nodes of the same shape.
#
# The container rule decides which directories become rows: one that holds a
# folder from entries, or a group folder over two or more rows. Any other is
# not a row, and its label is pushed down into each of its children. A lone
# child reads as a merge, "infrastructure/energy"; several read as promotion,
# each carrying the prefix. A root's label is absolute because everything
# above it was pushed down; a nested label is one segment.
proc ::questlog::path::container_tree {entries {groups {}}} {
    set trie [dict create keys {} kids {}]
    foreach pair $entries {
        lassign $pair key dir
        set at {}
        foreach seg [lrange [file split $dir] 1 end] {
            lappend at kids $seg
            if {![dict exists $trie {*}$at]} {
                dict set trie {*}$at [dict create keys {} kids {}]
            }
        }
        set held [dict get $trie {*}$at keys]
        lappend held $key
        dict set trie {*}$at keys $held
    }
    set gkey [dict create]
    foreach pair $groups { dict set gkey [lindex $pair 1] [lindex $pair 0] }
    return [_emit_nodes $trie "/" "/" $gkey]
}

# One trie node's contribution to its parent's child list: itself when it holds
# folders, or is a group over two or more rows; otherwise its children with its
# label pushed into theirs.
proc ::questlog::path::_emit_nodes {trie label dir gkey} {
    set out [list]
    foreach seg [lsort -dictionary [dict keys [dict get $trie kids]]] {
        foreach node [_emit_nodes [dict get $trie kids $seg] $seg \
                          [file join $dir $seg] $gkey] {
            lappend out $node
        }
    }
    set keys [dict get $trie keys]
    if {[llength $keys] == 0 && [dict exists $gkey $dir] && [llength $out] >= 2} {
        set keys [list [dict get $gkey $dir]]
    }
    if {[llength $keys] == 0} {
        return [lmap node $out {
            dict set node label [file join $label [dict get $node label]]
        }]
    }
    return [list [dict create label $label dir $dir keys $keys children $out]]
}
