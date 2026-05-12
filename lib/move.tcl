package require Tcl 9

namespace eval ::csm::move {
    namespace export session
}

# Move a session jsonl into a different project folder.
# Returns the new absolute path. Errors propagate.
proc ::csm::move::session {src_path dst_folder_path} {
    if {![file isfile $src_path]} {
        error "source not found: $src_path"
    }
    if {![file isdirectory $dst_folder_path]} {
        error "destination folder not found: $dst_folder_path"
    }
    set src_folder [file dirname $src_path]
    if {[file normalize $src_folder] eq [file normalize $dst_folder_path]} {
        error "source and destination are the same folder"
    }
    set new_path [file join $dst_folder_path [file tail $src_path]]
    if {[file exists $new_path]} {
        error "destination already exists: $new_path"
    }
    file rename -- $src_path $new_path
    return $new_path
}
