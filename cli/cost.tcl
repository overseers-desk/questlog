package require Tcl 9

namespace eval ::questlog::cli::cost {}

# Compute cost synchronously for a single file.
# This function is used exclusively by the CLI, which parses files synchronously
# on the main thread, unlike the GUI which uses the worker pool.
proc ::questlog::cli::cost::compute_sync {path} {
    set res [::questlog::cost::parse_file $path]
    return [::questlog::cost::build_cost_dict $res]
}
