#!/usr/bin/env wish9.0
# A standalone demo of the StreamTree widget: a tree drawn in one Tk text widget,
# with a right-pinned sortable, resizable metadata strip. It loads only the
# streamtree module and a host supplies content and look through the hooks and
# options - no questlog app code is involved.
#
# Run it with bare wish:   wish9.0 examples/streamtree-demo.tcl
#
# Try: click a column heading to sort (click again to flip); drag a column
# boundary (the cursor turns to a resize arrow) to widen a column; click a
# folder heading to fold it.

package require Tcl 9
package require Tk

set HERE [file dirname [file normalize [info script]]]
::tcl::tm::path add [file dirname $HERE]
package require streamtree

font create DemoList {*}[font actual TkTextFont]
font create DemoBold {*}[font actual TkTextFont] -weight bold

# A two-level tree: languages (folders) over files (rows). Each file carries a
# size and a line count laid in the right-pinned columns.
oo::class create DemoList {
    superclass ::streamtree::StreamTree
    variable Top Text Nodes Roots NextId ColTabs ColRightX ColW ColWMeasured \
        ColWOverride ColMinW ColGap SubjectMax FolderLabelMax LayoutW \
        RelayoutPending SortKey SortDir ResortTimer AtTop Opts \
        ResizeCol ResizeX0 ResizeW0 FolderId
    constructor {parent} {
        set FolderId [dict create]
        my configure -listfont DemoList -headfont DemoBold \
            -colours [dict create strip #e8eef2 muted #5a6b78 ink #102a43]
        ttk::frame $parent.bar
        pack $parent.bar -side top -fill x
        ttk::label $parent.bar.t -text "StreamTree demo - sortable, resizable columns"
        pack $parent.bar.t -side left -padx 6 -pady 4
        my setup $parent
        my configure_tags
        my set_sort size
    }

    # ---- engine hooks ----
    method column_spec {} {
        return {{size Size {9999 KB} right 1} {lines Lines {99999} right 1}}
    }
    method subject_sort_id {} { return name }
    method default_sort_dir {id} { return [expr {$id eq "name" ? "asc" : "desc"}] }
    method row_tags {kind} { return [expr {$kind eq "folder" ? "folderhead" : "filerow"}] }
    method start_gravity {kind} { return right }

    method render_subject {node max} {
        if {[my node_field $node kind] eq "folder"} {
            set marker [expr {[my node_field $node expanded] ? "▾" : "▸"}]
            set n [llength [my node_field $node children]]
            return [dict create subject "$marker [my node_pget $node label] ($n)" tags {} meta_run 0]
        }
        return [dict create subject [my truncate_px [my node_pget $node label] $max DemoList] \
            tags {} meta_run 1]
    }
    method cell_values {node} {
        if {[my node_field $node kind] eq "folder"} { return {{size {}} {lines {}}} }
        return [list [list size "[my node_pget $node size] KB"] \
                     [list lines [my node_pget $node lines]]]
    }
    method cell_tag {node col} { return meta }
    method sort_key {payload col} {
        switch $col {
            size  { return [dict getdef $payload size 0] }
            lines { return [dict getdef $payload lines 0] }
            name  { return [dict getdef $payload label ""] }
        }
        return 0
    }
    method subject_label {} { return "File" }
    method sort_siblings {ids} {
        if {[llength $ids] == 0} { return $ids }
        set keyed [lmap id $ids { list $id [my sort_key [my node_payload $id] $SortKey] }]
        set num [expr {$SortKey in {size lines}}]
        set dir [expr {$SortDir eq "asc" ? "-increasing" : "-decreasing"}]
        set cmp [expr {$num ? "-real" : "-dictionary"}]
        return [lmap e [lsort $cmp -index 1 $dir $keyed] { lindex $e 0 }]
    }
    method on_node_created {id} {
        if {[my node_field $id kind] eq "folder"} {
            dict set FolderId [my node_field $id key] $id
        }
    }
    method on_row_rendered {id} {
        if {[my node_field $id kind] eq "folder"} {
            $Text tag bind [my node_field $id tag] <Button-1> \
                [list [self] toggle [my node_field $id key]]
        }
    }
    method configure_tags {} {
        $Text tag configure folderhead -font DemoBold -foreground [my colour ink] \
            -spacing1 10 -spacing3 2 -wrap none
        $Text tag configure filerow -lmargin1 16 -lmargin2 16 -spacing3 1 \
            -foreground [my colour ink] -font DemoList -wrap none
        $Text tag configure meta -foreground [my colour muted]
    }

    # ---- demo data / interaction ----
    method toggle {folder} {
        set id [dict get $FolderId $folder]
        if {[my node_field $id expanded]} { my collapse $id } else { my expand $id }
        my item $id
    }
    method add_folder {name files} {
        set fid [my insert "" folder $name [dict create label $name]]
        my node_set $fid expanded 1
        foreach {fname size lines} $files {
            my insert $fid file "$name/$fname" [dict create label $fname size $size lines $lines]
        }
        my item $fid
    }

    # One streamed arrival: a synthetic file lands in a random folder, bracketed
    # by the anchors so the reader's line never moves, then the debounced resort
    # seats it under the active sort. This is the widget's core contract on
    # display: leave streaming on, scroll anywhere, and read undisturbed.
    variable StreamN
    method stream_one {} {
        if {![info exists StreamN]} { set StreamN 0 }
        set folder [lindex [dict keys $FolderId] \
            [expr {int(rand() * [dict size $FolderId])}]]
        set name "arrival[incr StreamN].tcl"
        my anchor_save
        my insert [dict get $FolderId $folder] file "$folder/$name" \
            [dict create label $name size [expr {1 + int(rand()*99)}] \
                 lines [expr {10 + int(rand()*2000)}]]
        my item [dict get $FolderId $folder]
        my anchor_restore
        my schedule_resort
    }
}

pack [ttk::frame .f] -fill both -expand 1
.f configure -width 760 -height 520
set d [DemoList new .f]
$d add_folder Tcl    {streamtree.tm 41 1140  sessions.tcl 92 2470  drag.tcl 4 110}
$d add_folder Python {parser.py 18 520  model.py 33 980  cli.py 7 240}
$d add_folder Rust   {lib.rs 12 360  main.rs 5 150}
# The folders streamed in live in arrival order; one rebuild seats them under
# the active sort (Size, descending) so the initial view matches the heading.
$d rebuild

# The streaming showcase: rows pour in while the reading position holds; with
# "Follow tail" on, the view latches to the bottom instead (the tail -f
# contract) until scrolled away.
set ::streaming 0
set ::following 0
proc stream_tick {} {
    if {!$::streaming} return
    $::d stream_one
    after 400 stream_tick
}
proc follow_toggle {} {
    $::d configure -autofollow $::following
    if {$::following} { $::d follow }
}
ttk::checkbutton .f.bar.stream -text "Stream rows" -variable ::streaming \
    -command stream_tick
ttk::checkbutton .f.bar.follow -text "Follow tail" -variable ::following \
    -command follow_toggle
ttk::label .f.bar.at -text ""
pack .f.bar.at .f.bar.follow .f.bar.stream -side right -padx 6
bind .f <<AtBottom>>   {.f.bar.at configure -text "at tail"}
bind .f <<LeftBottom>> {.f.bar.at configure -text ""}
update
wm title . "StreamTree demo"
