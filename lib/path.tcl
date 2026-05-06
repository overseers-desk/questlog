package require Tcl 9

namespace eval ::csm::path {
    namespace export decode_folder encode_cwd projects_root pretty_home
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
# /home/weiwu/code/foo  ->  -home-weiwu-code-foo
# Used by the "this cwd only" toolbar filter.
proc ::csm::path::encode_cwd {cwd} {
    return [string map {/ -} $cwd]
}
