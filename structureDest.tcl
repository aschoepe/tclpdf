#
# tclpdf - PDF generation for Tcl
#
# structureDest - a link or a bookmark that points at a structure element
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
#   $doc link -structure intro ...          ;# link.tcl
#   $doc bookmark "Intro" -structure intro  ;# outline.tcl
#
# The GoTo action that takes a reader to a named element (ISO 32000-2
# 12.3.2.3), and the guard both takers of it - link and bookmark - have to
# make. The two destination objects it names are reserved here and filled
# by structureWrite.tcl once every element has its number.
#
# Split off from structure.tcl because it is a topic of its own: the tree is
# built while drawing, but a destination is something OTHER modules ask for
# and hand on - it neither adds to the tree nor writes it.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::document 1.0-

oo::define ::tclpdf::document::document {

  # The action that takes a reader to the named element, for the /A entry of
  # a link annotation or an outline item:
  #
  #   << /S /GoTo /SD <structure destination> /D <page destination> >>
  #
  # An action rather than a bare /Dest, because a GoTo is the one place that
  # holds BOTH targets (ISO 32000-2 Table 202): /SD names the element, /D the
  # page it begins on. A reader that knows 2.0 follows /SD to the content; an
  # older one skips the key it does not know and still lands on the right
  # page through /D. That pairing is what 12.3.2.3 recommends and what
  # PDF/UA-2 rests on.
  #
  # Both destinations are reserved now and filled at write time, and that
  # indirection is what makes this work at all: an annotation is written the
  # moment the link is drawn, while the element it points at gets its object
  # number - and its first page is settled - only when the tree is built. A
  # destination may be an indirect object (12.3.2), so the action can carry
  # references to objects that do not exist yet.
  #
  # The name does not have to be declared yet either - a link may point
  # forwards, at a section further down the document. It is checked when the
  # tree is written, where a mistyped one can still be named. Asking twice
  # for one name gets the same objects, so a caller may ask early and again
  # when it writes.
  method structureDestination {name} {
    set wanted [my state structureDestinations]
    if {![dict exists $wanted $name]} {
      dict set wanted $name [dict create \
          sd [my reservation structure.dest.$name] \
          d [my reservation structure.pagedest.$name]]
      my state structureDestinations $wanted
    }
    set numbers [dict get $wanted $name]
    return [::tclpdf::pdfObj dictionary [list S /GoTo \
        D [[my writer] ref [dict get $numbers d]] \
        SD [[my writer] ref [dict get $numbers sd]]]]
  }

  # The refusal both takers of a structure destination - link and bookmark -
  # have to make, kept once, beside the method it protects. caller names the
  # call for the message.
  #
  # Without a tree the destination would point at nothing. And it needs a 2.0
  # file: before ISO 32000-2 the first entry of a destination array has to be
  # a page object (ISO 32000-1, Table 151) - written anyway it would point a
  # validator and every reader at an object that is not a page. Both checked
  # where the caller is: left alone, the write failed later with "reserved
  # but never written" and no word about which call was at fault.
  method StructureDestinationGuard {caller} {
    if {[my state tagged] ne "1"} {
      return -code error "tclpdf: $caller needs a tagged document - a\
          structure destination points at an element of the tree. Call\
          \[\$doc tagged 1\] first"
    }
    if {[package vcompare [[my writer] version] 2.0] < 0} {
      return -code error "tclpdf: a structure destination is a syntax of\
          ISO 32000-2 (12.3.2.3) and this document is PDF\
          [[my writer] version] - raise the version, or use\
          \[\$doc ua -part 2\], which does it"
    }
    # Accepted - so the floor is pinned with the writer, the way [tagged]
    # and [ua] pin theirs: a later [configure -version 1.7] is refused
    # naming this call, instead of writing a 1.7 file that carries an /SD
    # destination no reader of that version knows.
    my RequireVersion 2.0 "$caller (a structure destination)"
    return
  }

}

package provide tclpdf::structureDest 1.0
