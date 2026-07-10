#!/usr/bin/env tclsh9.0
# Stage questlog's payload and fold it into one executable with `zipfs mkimg`.
#
#   tclsh9.0 zipfs/build.tcl
#
# Stages the launcher, config.tcl, the Tcl modules, lib/, ui/, cli/,
# data/, assets/ and zipfs/main.tcl into a temporary
# directory, then stubs them onto a wish to make a single file. Two env vars
# select what kind of image:
#
#   QUESTLOG_WISH      Path to the wish used as the stub. Default: wish9.0 from
#                      PATH, which is dynamically linked, so the image still
#                      needs the Tcl 9 runtime on the host (tcl9.0, tk9.0,
#                      tcllib, tcl9.0-thread) and carries questlog's code only.
#   QUESTLOG_RUNTIME   Path to a runtime tree (tcl_library/, tk_library/,
#                      tcl_library/json/) to stage alongside the payload. Set
#                      together with a from-source static wish, this produces a
#                      self-contained image that needs no Tcl on the target.
#                      zipfs/build-selfcontained.sh builds both and calls here.
#
# The AppImage build reuses this script, run under a from-source tclsh9.0.

package require Tcl 9

set repo  [file dirname [file dirname [file normalize [info script]]]]

# Version is read from the launcher so it has exactly one home.
set launcher [file join $repo questlog]
set fh [open $launcher r]
set launcher_text [read $fh]
close $fh
set ver ""
foreach line [split $launcher_text \n] {
    if {[regexp {^set QUESTLOG_VERSION\s+(\S+)} $line -> ver]} break
}
if {$ver eq ""} {
    puts stderr "build: could not read QUESTLOG_VERSION from $launcher"
    exit 1
}

if {[info exists ::env(QUESTLOG_WISH)] && $::env(QUESTLOG_WISH) ne ""} {
    set wish $::env(QUESTLOG_WISH)
} else {
    set wish [lindex [auto_execok wish9.0] 0]
}
if {$wish eq "" || ![file executable $wish]} {
    puts stderr "build: wish stub not found (set QUESTLOG_WISH or install wish9.0)"
    exit 1
}

# Stage the archive contents. main.tcl and the launcher sit at the staging
# root so that, post-strip, they land at //zipfs:/app/main.tcl and
# //zipfs:/app/questlog (an mkimg image mounts at //zipfs:/app).
set stage /tmp/questlog-zipfs-stage-[pid]
file delete -force $stage
file mkdir $stage
file copy $launcher                       [file join $stage questlog]
file copy [file join $repo config.tcl]     [file join $stage config.tcl]
file copy [file join $repo zipfs main.tcl] [file join $stage main.tcl]
foreach f [glob -tails -directory $repo *.tm] {
    file copy [file join $repo $f] [file join $stage $f]
}
foreach d {lib ui cli data assets} {
    file copy [file join $repo $d] [file join $stage $d]
}

# A self-contained stub carries no script library of its own, so overlay the
# from-source runtime (tcl_library/, tk_library/, embedded json). An mkimg
# image mounts at //zipfs:/app, so these land at //zipfs:/app/tcl_library etc.,
# where the interpreter and every worker interp find them on the default
# auto_path.
if {[info exists ::env(QUESTLOG_RUNTIME)] && $::env(QUESTLOG_RUNTIME) ne ""} {
    set runtime $::env(QUESTLOG_RUNTIME)
    foreach name [glob -nocomplain -tails -directory $runtime *] {
        file copy [file join $runtime $name] [file join $stage $name]
    }
}

set distdir [file join $repo dist]
file mkdir $distdir
switch -- $tcl_platform(os) {
    Darwin  { set os macos }
    default { set os linux }
}
# Linux reports aarch64 where macOS reports arm64; normalise so an arm64 image
# carries the same token on either OS.
set arch [exec uname -m]
if {$arch eq "aarch64"} { set arch arm64 }
set out [file join $distdir "questlog-$ver-$os-$arch"]
file delete -force $out

# strip == stage makes archive paths root-relative; the stub wish provides the
# Tk-capable interpreter.
zipfs mkimg $out $stage $stage {} $wish
file attributes $out -permissions 0755
file delete -force $stage

puts "built $out"
