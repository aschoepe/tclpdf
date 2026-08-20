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
      page {} at {} parent {} open 1 structure {}
    } $args "bookmark"]
    if {[dict get $options structure] ne {}} {
      # Checked here, where the caller is: left alone, the write would fail
      # later with "reserved but never written" and no word about which call
      # was at fault. What is checked, and why, stands at the guard.
      my StructureDestinationGuard "bookmark -structure"
      # And requested NOW, not first in OutlineWrite: the structure tree
      # writer fills the destination objects at beforeWrite, the outline is
      # built later, on the catalog event - a destination first asked for
      # there is reserved after the filler has run and stays empty. The call
      # is idempotent, so OutlineWrite asking again gets the same object.
      my structureDestination [dict get $options structure]
    }
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
    if {[dict get $options structure] eq {}} {
      # A negative or non-integer page is refused here; a page that does
      # not exist YET is allowed, because a bookmark may point forward at a
      # page added later - and if it never comes, the write says so, naming
      # this bookmark by its title. That is [Destination]'s asker argument.
      if {![string is integer -strict $page] || $page < 0} {
        return -code error "tclpdf: no such page: $page - the document has\
            [my page count] page(s)"
      }
      # Asked for NOW for the same reason as the structure destination
      # above: a page destination that points forward is an indirect object
      # filled on beforeWrite, and the outline is built later, on catalog.
      # Kept in the entry so OutlineWrite writes the very same reference.
      set dest [my Destination $page [dict get $options at] {} \
          "bookmark \"$title\""]
    }
    set id [llength $entries]
    set parent [dict get $options parent]
    if {$parent ne {} && ($parent < 0 || $parent >= $id)} {
      return -code error "tclpdf: no such bookmark: $parent"
    }
    lappend entries [dict create title $title page $page \
        at [dict get $options at] parent $parent \
        structure [dict get $options structure] \
        dest [expr {[info exists dest] ? $dest : {}}] \
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
      set pairs [list Title [my Str [dict get $entry title]] \
          Parent [expr {$parent eq {} ? [[my writer] ref $rootNumber] :
              [[my writer] ref [dict get [lindex $entries $parent] number]]}]]
      # A page target is a plain /Dest; an element target is a GoTo action
      # under /A, because only an action can carry the structure destination
      # (/SD) and a page destination (/D) side by side - see
      # [structureDestination] for why both are wanted.
      if {[dict get $entry structure] ne {}} {
        lappend pairs A [my structureDestination [dict get $entry structure]]
      } else {
        lappend pairs Dest [dict get $entry dest]
      }
      if {$position > 0} {
        lappend pairs Prev [[my writer] ref \
            [dict get [lindex $entries [lindex $siblings $position-1]] number]]
      }
      if {$position < [llength $siblings] - 1} {
        lappend pairs Next [[my writer] ref \
            [dict get [lindex $entries [lindex $siblings $position+1]] number]]
      }
      if {[dict exists $children $index]} {
        # /Count is the number of VISIBLE descendants (Table 153), not of
        # children - what [OutlineVisible] counts - and negative on a closed
        # item, where it says how many would appear on opening it.
        set own [dict get $children $index]
        set count [my OutlineVisible $children $entries $index]
        lappend pairs \
            First [[my writer] ref [dict get [lindex $entries [lindex $own 0]] number]] \
            Last [[my writer] ref [dict get [lindex $entries [lindex $own end]] number]] \
            Count [expr {[dict get $entry open] ? $count : -$count}]
      }
      [my writer] put [dict get $entry number] [::tclpdf::pdfObj dictionary $pairs]
      incr index
    }

    # The root counts every item that is visible when the outline opens
    # (Table 152) - the top level and whatever the open ones show.
    set top [dict get $children {}]
    [my writer] put $rootNumber [::tclpdf::pdfObj dictionary [list \
        Type /Outlines \
        First [[my writer] ref [dict get [lindex $entries [lindex $top 0]] number]] \
        Last [[my writer] ref [dict get [lindex $entries [lindex $top end]] number]] \
        Count [my OutlineVisible $children $entries {}]]]
    my catalogEntry Outlines [[my writer] ref $rootNumber]
    # A document with bookmarks should open showing them - otherwise the work
    # of adding them is invisible until the reader goes looking.
    if {[my catalogEntry PageMode] eq {}} {
      my catalogEntry PageMode /UseOutlines
    }
    return
  }

  # How many descendants of an item a reader shows (ISO 32000-1 Tables 152
  # and 153): its children, and through every open child that child's own
  # visible descendants - a closed child counts once and hides what is under
  # it. The root is the item with the empty parent id.
  #
  # Counting direct children instead put 1 on a chapter with one open
  # section that had two subsections, where 3 was due, and 1 on the root of
  # a three-level tree that opens showing three items - a reader that trusts
  # the number showed the tree one level short.
  method OutlineVisible {children entries index} {
    if {![dict exists $children $index]} {
      return 0
    }
    set count 0
    foreach child [dict get $children $index] {
      incr count
      if {[dict get [lindex $entries $child] open]} {
        incr count [my OutlineVisible $children $entries $child]
      }
    }
    return $count
  }

}

package provide tclpdf::outline 1.4
