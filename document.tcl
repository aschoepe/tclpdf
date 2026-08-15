#
# tclpdf - PDF generation for Tcl
#
# document - the object a caller works with
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Holds pages, resources and metadata, and turns them into objects when the
# file is written. It inherits the event emitter, so attachments, ZUGFeRD and
# the PDF/A output intent can add objects and catalog keys from the outside -
# see event.tcl for why that is the one decision that cannot be retrofitted.
#
# The events fired while writing, in order:
#
#   beforeWrite   nothing has been written yet - the moment to create objects
#   resources     the shared resource dictionary is being assembled
#   catalog       catalog entries are being collected
#   info          the document information dictionary is being collected
#   afterWrite    the file is complete, the path is passed on
#
# The first four fire on EVERY write. A subscriber that creates objects must
# hold its numbers through [reservation] and write over them - the contract is
# spelled out in event.tcl.
#
# Resources live on the page TREE, not on each page: /Resources is an
# inheritable page attribute (7.7.3.4), so one dictionary serves every page
# and a logo used on five pages is embedded once.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::filter 1.0-
package require tclpdf::writer 1.0-
package require tclpdf::event 1.0-
package require tclpdf::geometry 1.0-

namespace eval ::tclpdf::document {}

oo::class create ::tclpdf::document::document {
  superclass ::tclpdf::event::emitter

  variable tclpdfWriter tclpdfOption tclpdfPages tclpdfCurrent \
      tclpdfInfo tclpdfXmp tclpdfResources tclpdfCatalog tclpdfState tclpdfCanvas

  constructor {args} {
    next
    set tclpdfOption {
      format a4
      orientation portrait
      unit mm
      version 1.7
      compress 1
    }
    my configure {*}$args
    set tclpdfWriter [::tclpdf::writer::pdf new [dict get $tclpdfOption version]]
    set tclpdfPages {}
    set tclpdfCurrent -1
    set tclpdfXmp {}
    set tclpdfResources {}
    set tclpdfCatalog {}
    set tclpdfState {}
    set tclpdfCanvas {}
    set tclpdfInfo [dict create Producer "tclpdf [package provide tclpdf]"]
  }

  destructor {
    if {[info exists tclpdfWriter] && [info object isa object $tclpdfWriter]} {
      $tclpdfWriter destroy
    }
  }

  # -- options ------------------------------------------------------------

  # The writer is created once, in the constructor, and it carries the PDF
  # version - so a later [configure -version] has to be handed on to it.
  # Without that the option and the file disagreed: [cget -version] answered
  # 1.4 while the file still began with %PDF-1.7, and nothing anywhere said so.
  # The constructor calls this before the writer exists, hence the guard.
  method configure {args} {
    set tclpdfOption [::tclpdf::option parse $tclpdfOption $args "the document"]
    if {[info exists tclpdfWriter]} {
      $tclpdfWriter version [dict get $tclpdfOption version]
    }
    return
  }

  method cget {option} {
    set name [string trimleft $option -]
    if {![dict exists $tclpdfOption $name]} {
      return -code error "tclpdf: unknown option \"$option\""
    }
    return [dict get $tclpdfOption $name]
  }

  # The writer, for modules that need to create objects of their own. Topical
  # modules go through here rather than keeping a writer instance around.
  method writer {} {
    return $tclpdfWriter
  }

  # A content stream object, deflated when the document is set to compress.
  #
  # Extracted when the second module needed it (form XObjects and tiling
  # patterns build a stream the same way, and the page content stream makes
  # three). Left as a copy it is the classic divergence bug: one of them
  # eventually learns a new filter and the others do not.
  method streamObject {pairs content {number {}}} {
    if {[dict get $tclpdfOption compress]} {
      set content [::tclpdf::filter encodeFlate $content]
      lappend pairs Filter /FlateDecode
    }
    # With a number the stream goes OVER that object instead of into a fresh
    # one - what a builder needs when it runs once per write (see
    # [reservation] in output.tcl).
    if {$number eq {}} {
      return [$tclpdfWriter addStream $pairs $content]
    }
    return [$tclpdfWriter stream $number $pairs $content]
  }


  # A destination inside this document (12.3.2) - where a link or a bookmark
  # points.
  #
  # In the core because it needs the page's object number and the coordinate
  # mirroring, and because links and bookmarks would otherwise each spell it
  # out: two copies of the same array, one of which eventually learns about
  # /FitH and the other does not.
  method destination {page {at {}} {zoom {}}} {
    if {![string is integer -strict $page] || $page < 0 ||
        $page >= [llength $tclpdfPages]} {
      return -code error "tclpdf: no such page: $page - the document has\
          [llength $tclpdfPages] page(s)"
    }
    set target [$tclpdfWriter ref [dict get [my Page $page] number]]
    if {$at eq {}} {
      # /Fit shows the whole page rather than inventing a position the caller
      # did not give.
      return [::tclpdf::pdfObj arr [list $target /Fit]]
    }
    lassign [my coords {*}$at $page] x y
    return [::tclpdf::pdfObj arr [list $target /XYZ \
        [::tclpdf::pdfObj num $x] [::tclpdf::pdfObj num $y] \
        [expr {$zoom eq {} ? "null" : [::tclpdf::pdfObj num $zoom]}]]]
  }

  # -- topical methods ----------------------------------------------------

  # Which module provides which method. This table is the ONLY place where the
  # core knows the topics exist, and it holds no logic - the implementations
  # live in the modules and attach themselves with [oo::define] when loaded.
  #
  # The point is that loading tclpdf stays cheap: a caller who writes text
  # never loads the image code, and a module can be added without touching
  # anything here except one line.
  method unknown {method args} {
    set topics {
      SvgCollect svgElement
      SvgElement svgElement
      SvgShape svgElement
      SvgUse svgElement
      SvgText svgElement
      SvgBounds svgPaint
      SvgPaint svgPaint
      SvgStyle svgPaint
      SvgGradient svgPaint
      SvgStops svgPaint
      page page
      PageAdd page
      PageSize page
      PageBox page
      PageIndex page
      Page page
      content page
      canvas page
      coords page
      distance page
      extent page
      fitExtent page
      save graphics
      restore graphics
      transform graphics
      style graphics
      opacity graphics
      blend graphics
      line shape
      rect shape
      circle shape
      ellipse shape
      polygon shape
      curve shape
      path shape
      clip shape
      write output
      reservation output
      writeChannel output
      form xObject
      attach attach
      attachments attach
      attachmentsWithoutDescription attach
      font text
      fontsWithoutProgram font
      text text
      textWidth text
      textLines textBlock
      leader leader
      textHeight textBlock
      image image
      shading shading
      pattern pattern
      table table
      pdfa pdfa
      zugferd zugferd
      link link
      linksWithoutContents link
      pageNumbers pageNumber
      textPath textPath
      bookmark outline
      bookmarks outline
      svg svg
      viewerPreferences viewerPreferences
      ua ua
      tagged structure
      structure structure
      structureReport structure
      StructureMark structure
      StructureAnnotation structure
      structureDestination structure
      StructureBegin structure
      StructureEnd structure
    }
    if {[dict exists $topics $method]} {
      set topic [dict get $topics $method]
      package require tclpdf::$topic
      # -private matters: a topic may consist entirely of private methods,
      # and [info object methods -all] lists only the exported ones. Without
      # it the module loads correctly and the check below then denies it.
      if {$method ni [info object methods [self] -all -private]} {
        return -code error "tclpdf: module $topic does not provide \"$method\""
      }
      return [my $method {*}$args]
    }
    next $method {*}$args
  }

  # -- resources, catalog, metadata ---------------------------------------

  # Register a resource: category is Font, XObject, ExtGState, ColorSpace,
  # Pattern or Shading; value is already PDF syntax, usually a reference.
  # Told apart by the NUMBER of arguments, for the reason spelled out at
  # [state] below: with a default parameter, "clear this" and "read this" are
  # the same call and the caller silently gets the wrong one of the two.
  method resource {category args} {
    switch -- [llength $args] {
      0 {
        # The whole category - what the PDF/A check needs to walk every font
        # actually used, without each module having to keep a second list.
        if {[dict exists $tclpdfResources $category]} {
          return [dict get $tclpdfResources $category]
        }
        return {}
      }
      1 {
        set name [lindex $args 0]
        if {[dict exists $tclpdfResources $category $name]} {
          return [dict get $tclpdfResources $category $name]
        }
        return {}
      }
      2 {
        lassign $args name value
        if {$value eq {}} {
          if {[dict exists $tclpdfResources $category $name]} {
            dict unset tclpdfResources $category $name
          }
          return $name
        }
        dict set tclpdfResources $category $name $value
        return $name
      }
      default {
        return -code error "tclpdf: resource takes a category, a name and at\
            most one value"
      }
    }
  }

  # Subscribe one of the object's OWN methods to an event, private ones
  # included.
  #
  # [on] takes a command prefix and the bus calls it from the global context,
  # so a private method is out of reach there: TclOO does not export a method
  # whose name starts with a capital, and "$doc AttachWrite" fails with
  # "unknown method" even though the method exists. Every topical module that
  # hooks into the write run needs this - attachments today, ZUGFeRD and the
  # output intent next - so it belongs here rather than being worked around
  # once per module.
  method onSelf {event methodName} {
    oo::objdefine [self] export $methodName
    return [my on $event [list apply {{name document} {
      $document $name
    }} $methodName]]
  }

  # Scratch state for a topical module - the current font, an image alias
  # table, where a table left off. Kept apart from [resource] ON PURPOSE:
  # everything handed to [resource] is written into the PDF resource
  # dictionary, and a Tcl value put there produces a structurally broken file.
  #
  # Measured the hard way: the text module first stored its font state through
  # [resource], and the result was
  #   /Resources << /tclpdfTextState << /current family helvetica style {} ...
  # inside the page tree. qpdf reported "unable to find page tree" while
  # poppler still rendered the text - so it looked fine and was not.
  # Reading and writing are told apart by the NUMBER of arguments, not by the
  # value. With a default parameter the two are indistinguishable: "my state
  # svgSkipped {}" reads as "clear it" and did the opposite - it returned the
  # value and left it standing. The SVG module counted skipped elements into
  # a total that never reset, and reported gradients in drawings that have
  # none.
  #
  # There is no way to spot that from the call site, which is what makes it
  # worth an [args] rather than a default.
  method state {key args} {
    switch -- [llength $args] {
      0 {
        if {[dict exists $tclpdfState $key]} {
          return [dict get $tclpdfState $key]
        }
        return {}
      }
      1 {
        dict set tclpdfState $key [lindex $args 0]
        return [lindex $args 0]
      }
      default {
        return -code error "tclpdf: state takes a key and at most one value"
      }
    }
  }

  # A catalog entry - how a subscriber adds /AF, /Names or /OutputIntents
  # without the core knowing about them.
  method catalogEntry {key args} {
    if {[llength $args] == 0} {
      if {[dict exists $tclpdfCatalog $key]} {
        return [dict get $tclpdfCatalog $key]
      }
      return {}
    }
    if {[llength $args] > 1} {
      return -code error "tclpdf: catalogEntry takes a key and at most one value"
    }
    set value [lindex $args 0]
    if {$value eq {}} {
      dict unset tclpdfCatalog $key
      return {}
    }
    dict set tclpdfCatalog $key $value
    return $value
  }

  # The natural language of the document (14.9.2): a language tag as in
  # RFC 3066 - "de", "de-DE", "en-GB". Read with no argument.
  #
  #   $doc language de-DE
  #
  # It goes into the CATALOG, not the info dictionary, and it is what lets a
  # screen reader pronounce the text and a search engine index it correctly.
  # PDF/A-3a and PDF/UA require it; 3b does not, which is why it is offered
  # rather than forced.
  #
  # Written as a PDF string, so a tag is never mistaken for a name object.
  method language {{tag {}}} {
    if {$tag eq {}} {
      set current [my catalogEntry Lang]
      if {$current eq {}} {
        return {}
      }
      # Hand back what was put in, not the PDF spelling of it.
      return [string range $current 1 end-1]
    }
    if {![regexp {^[A-Za-z]{1,8}(-[A-Za-z0-9]{1,8})*$} $tag]} {
      return -code error "tclpdf: \"$tag\" is not a language tag - expected\
          something like de, de-DE or en-GB (RFC 3066)"
    }
    my catalogEntry Lang [::tclpdf::pdfObj str $tag]
    return $tag
  }

  # Document information (14.3.3). Keys are Title, Author, Subject, Keywords,
  # Creator, Producer.
  method info {key args} {
    if {[llength $args] == 0} {
      if {[dict exists $tclpdfInfo $key]} {
        return [dict get $tclpdfInfo $key]
      }
      return {}
    }
    if {[llength $args] > 1} {
      return -code error "tclpdf: info takes a key and at most one value"
    }
    set value [lindex $args 0]
    if {$value eq {}} {
      # An empty value REMOVES the key. Writing it as an empty string instead
      # would put "/Title ()" into the file, which is not the same as having
      # no title, and PDF/A wants the XMP and the info dictionary to agree.
      dict unset tclpdfInfo $key
      return {}
    }
    dict set tclpdfInfo $key $value
    return $value
  }

  # XMP metadata, set as raw XML (14.3.2). Raw on purpose: PDF/A and ZUGFeRD
  # prescribe the exact wording including the extension schema, and a
  # generator that "helps" is precisely what breaks those.
  method metadata {args} {
    if {[llength $args] > 1} {
      return -code error "tclpdf: metadata takes at most one XMP packet"
    }
    if {[llength $args] == 1} {
      set tclpdfXmp [lindex $args 0]
    }
    return $tclpdfXmp
  }

}

package provide tclpdf::document 1.4
