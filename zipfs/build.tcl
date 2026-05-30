#!/usr/bin/env tclsh9.0
# Build the single-file questlog executable with `zipfs mkimg`.
#
#   tclsh9.0 zipfs/build.tcl
#
# Stages the launcher, lib/, ui/, data/ and zipfs/main.tcl into a temporary
# directory, then folds them into one executable stubbed with wish9.0. The
# produced file needs the Tcl 9 runtime present on the host (tcl9.0, tk9.0,
# tcllib, tcl-thread); it carries questlog's own code only. For a runtime-free
# artifact, see appimage/.
#
# The AppImage build reuses this script unchanged, run under a from-source
# tclsh9.0 so the payload is stubbed with that interpreter's wish9.0.

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

set wish [lindex [auto_execok wish9.0] 0]
if {$wish eq ""} {
    puts stderr "build: wish9.0 not found on PATH"
    exit 1
}

# Stage the archive contents. main.tcl and the launcher sit at the staging
# root so that, post-strip, they land at //zipfs:/main.tcl and //zipfs:/questlog.
set stage /tmp/questlog-zipfs-stage-[pid]
file delete -force $stage
file mkdir $stage
file copy $launcher                       [file join $stage questlog]
file copy [file join $repo zipfs main.tcl] [file join $stage main.tcl]
foreach d {lib ui data} {
    file copy [file join $repo $d] [file join $stage $d]
}

set distdir [file join $repo dist]
file mkdir $distdir
set out [file join $distdir "questlog-$ver-linux-[exec uname -m]"]
file delete -force $out

# strip == stage makes archive paths root-relative; infile == wish9.0 stubs a
# Tk-capable image.
zipfs mkimg $out $stage $stage {} $wish
file attributes $out -permissions 0755
file delete -force $stage

puts "built $out"
