package require Tcl 9

namespace eval ::csm::path {
    namespace export decode_folder encode_cwd projects_root pretty_home \
        list_all_projects ensure_project_folder candidate_cwds_for
}

# Display-only: abbreviate a leading $HOME to ~. The model keeps absolute
# paths so encode_cwd, xdg-open and the resume command stay literal.
proc ::csm::path::pretty_home {path} {
    set home $::env(HOME)
    if {$path eq $home || [string match "$home/*" $path]} {
        return "~[string range $path [string length $home] end]"
    }
    return $path
}

# Root of the on-disk Claude session store.
proc ::csm::path::projects_root {} {
    return [file join $::env(HOME) .claude projects]
}

# Lossy fallback: -home-weiwu-code-foo  ->  /home/weiwu/code/foo.
# Only used when no jsonl record under the folder can be read for its .cwd.
# Note: this cannot recover hyphens in original path components - that is what
# cwd_from_record exists to fix.
proc ::csm::path::decode_folder {basename} {
    if {[string index $basename 0] eq "-"} {
        set s [string range $basename 1 end]
    } else {
        set s $basename
    }
    return /[string map {- /} $s]
}

# Encode an absolute path into the basename form Claude uses on disk.
# Used by the "this cwd only" toolbar filter and by ensure_project_folder.
proc ::csm::path::encode_cwd {cwd} {
    return [string map {/ -} $cwd]
}

# All project folder basenames currently on disk under ~/.claude/projects/.
# The move picker uses this so empty projects (no recent sessions) are
# still reachable as destinations.
proc ::csm::path::list_all_projects {} {
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
proc ::csm::path::ensure_project_folder {cwd} {
    set folder [encode_cwd $cwd]
    set dir [file join [projects_root] $folder]
    if {![file isdirectory $dir]} { file mkdir $dir }
    return $dir
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
proc ::csm::path::candidate_cwds_for {basename} {
    if {$basename eq ""} { return [list] }
    if {[string index $basename 0] eq "-"} {
        set rest [string range $basename 1 end]
    } else {
        set rest $basename
    }
    return [_walk "/" [split $rest -]]
}

proc ::csm::path::_walk {dir parts} {
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

proc ::csm::path::_encode_segment {name} {
    return [regsub -all {[^A-Za-z0-9]} $name -]
}
