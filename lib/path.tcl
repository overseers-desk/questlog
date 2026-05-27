package require Tcl 9

namespace eval ::questlog::path {
    namespace export encode_cwd projects_root pretty_home display_label \
        list_all_projects ensure_project_folder candidate_cwds_for \
        move_session set_bookmark clear_bookmark
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
# the only way the legitimate sinks in this module reach the
# filesystem. Idempotent: a second source of this file is a no-op.
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

# Display-only: abbreviate a leading $HOME to ~. The model keeps absolute
# paths so encode_cwd, xdg-open and the resume command stay literal.
proc ::questlog::path::pretty_home {path} {
    set home $::env(HOME)
    if {$path eq $home || [string match "$home/*" $path]} {
        return "~[string range $path [string length $home] end]"
    }
    return $path
}

# Root of the on-disk Claude session store.
proc ::questlog::path::projects_root {} {
    return [file join $::env(HOME) .claude projects]
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

# Pick the user-facing label for a project folder: the resolved cwd,
# abbreviated, when the folder could be resolved; otherwise the raw
# basename, which is honest about the failure rather than a fictional
# path. $cwd is whatever the canonical resolver returned ("" if it
# could not resolve the folder).
proc ::questlog::path::display_label {cwd folder_basename} {
    if {$cwd eq ""} { return $folder_basename }
    return [pretty_home $cwd]
}

# All project folder basenames currently on disk under ~/.claude/projects/.
# The move picker uses this so empty projects (no recent sessions) are
# still reachable as destinations.
proc ::questlog::path::list_all_projects {} {
    set root [projects_root]
    if {![file isdirectory $root]} { return [list] }
    set out [list]
    foreach d [glob -nocomplain -directory $root -type d -- *] {
        lappend out [file tail $d]
    }
    return [lsort $out]
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
    ::questlog::path::_real_file rename -- $src_path $new_path
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
