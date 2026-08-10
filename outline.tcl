#
# tclpdf - PDF generation for Tcl
#
# outline - bookmarks, the navigation tree a reader shows beside the page
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
#   set chapter [$doc bookmark "Rechnungen" -page 0]
#   $doc bookmark "Rechnung 2026-0815" -page 1 -parent $chapter
#
# The tree is collected while the document is written and turned into objects
# at the end, because every entry needs the object numbers of its siblings -
# the format is a doubly linked list at each level, not a nested structure.
# Building it as it goes would mean patching earlier objects.
#
# For PDF/A this is optional but wanted: an archived document of any length is
# unusable without it, and a validator has nothing to say either way.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::outline {}

oo::define ::tclpdf::document::document {

  # $doc bookmark <title> ?-page N? ?-at {x y}? ?-parent id? ?-open 1?
  # $doc bookmarks              -> the entries collected so far
  method bookmark {title args} {
    set options [::tclpdf::option parse {
      page {} at {} parent {} open 1
    } $args "bookmark"]
    set entries [my state outline]
    if {$entries eq {}} {
      my onSelf catalog OutlineWrite
    }
    set page [dict get $options page]
    if {$page eq {}} {
      set page [my page current]
    }
    if {$page < 0} {
      return -code error "tclpdf: a bookmark needs a page - add one first"
    }
    set id [llength $entries]
    set parent [dict get $options parent]
    if {$parent ne {} && ($parent < 0 || $parent >= $id)} {
      return -code error "tclpdf: no such bookmark: $parent"
    }
    lappend entries [dict create title $title page $page \
        at [dict get $options at] parent $parent \
        open [dict get $options open] number {}]
    my state outline $entries
    return $id
  }

  method bookmarks {} {
    return [my state outline]
  }

  # Turn the collected entries into objects. Two passes: reserve every number
  # first, then fill them in - an entry needs the numbers of its neighbours,
  # and half of those come after it.
  method OutlineWrite {} {
    set entries [my state outline]
    if {![llength $entries]} {
      return
    }
    # Numbers survive rebuilds - this runs on every write, and reserving
    # fresh ones per run left the previous tree unreachable in the file.
    set rootNumber [my reservation outline.root]
    set index 0
    foreach entry $entries {
      dict set entry number [my reservation outline.$index]
      lset entries $index $entry
      incr index
    }

    # Children by parent, in the order they were added.
    set children [dict create {} {}]
    set index 0
    foreach entry $entries {
      dict lappend children [dict get $entry parent] $index
      incr index
    }

    set index 0
    foreach entry $entries {
      set parent [dict get $entry parent]
      set siblings [dict get $children $parent]
      set position [lsearch -exact $siblings $index]
      # [str], not the UTF-16 helper directly: it already picks the encoding,
      # and a title of "Rechnung" stays readable in the file that way.
      set pairs [list Title [::tclpdf::pdfObj str [dict get $entry title]] \
          Parent [expr {$parent eq {} ? [[my writer] ref $rootNumber] :
              [[my writer] ref [dict get [lindex $entries $parent] number]]}] \
          Dest [my destination [dict get $entry page] [dict get $entry at]]]
      if {$position > 0} {
        lappend pairs Prev [[my writer] ref \
            [dict get [lindex $entries [lindex $siblings $position-1]] number]]
      }
      if {$position < [llength $siblings] - 1} {
        lappend pairs Next [[my writer] ref \
            [dict get [lindex $entries [lindex $siblings $position+1]] number]]
      }
      if {[dict exists $children $index]} {
        set own [dict get $children $index]
        lappend pairs \
            First [[my writer] ref [dict get [lindex $entries [lindex $own 0]] number]] \
            Last [[my writer] ref [dict get [lindex $entries [lindex $own end]] number]] \
            Count [expr {[dict get $entry open] ? [llength $own] : -[llength $own]}]
      }
      [my writer] put [dict get $entry number] [::tclpdf::pdfObj dictionary $pairs]
      incr index
    }

    set top [dict get $children {}]
    [my writer] put $rootNumber [::tclpdf::pdfObj dictionary [list \
        Type /Outlines \
        First [[my writer] ref [dict get [lindex $entries [lindex $top 0]] number]] \
        Last [[my writer] ref [dict get [lindex $entries [lindex $top end]] number]] \
        Count [llength $top]]]
    my catalogEntry Outlines [[my writer] ref $rootNumber]
    # A document with bookmarks should open showing them - otherwise the work
    # of adding them is invisible until the reader goes looking.
    if {[my catalogEntry PageMode] eq {}} {
      my catalogEntry PageMode /UseOutlines
    }
    return
  }

}

package provide tclpdf::outline 1.1
