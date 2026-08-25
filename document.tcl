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
      tclpdfInfo tclpdfXmp tclpdfResources tclpdfCatalog tclpdfState \
      tclpdfCanvas tclpdfTrailer

  constructor {args} {
    next
    set tclpdfOption {
      format a4
      orientation portrait
      unit mm
      version 1.7
      compress 1
      typeArea {}
    }
    # The state exists before the first configure: configure records there
    # whether an orientation was asked for (see below).
    set tclpdfState {}
    my configure {*}$args
    set tclpdfWriter [::tclpdf::writer::pdf new [dict get $tclpdfOption version]]
    set tclpdfPages {}
    set tclpdfCurrent -1
    set tclpdfXmp {}
    set tclpdfResources {}
    set tclpdfCatalog {}
    set tclpdfTrailer {}
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
  #
  # Handed on only when THIS call changed it. pdfa and ua raise the writer's
  # version by themselves, and handing the option on unconditionally undid
  # that: measured, "pdfa -part 3" put the writer at 1.7 and the next
  # "configure -unit pt" put it back at 1.4. The writer refuses a version
  # below what the document already uses, so the option is set only after
  # the writer took it.
  method configure {args} {
    set options [::tclpdf::option parse $tclpdfOption $args "the document"]
    # The type area is checked here, once, rather than by everyone who reads
    # it: two or four numbers in the document unit, none of them negative.
    # Whether it leaves room on a page is a question of the page, and is
    # asked when a page is measured against it (see [page typeArea]).
    set area [dict get $options typeArea]
    if {$area ne {}} {
      if {[catch {llength $area} count] || $count ni {2 4}} {
        return -code error -errorcode [list TCLPDF DOCUMENT ARGUMENT typeArea] \
            "tclpdf: -typeArea takes {top bottom} or\
            {top bottom left right}, got \"$area\""
      }
      foreach value $area {
        if {![string is double -strict $value] || $value < 0} {
          return -code error -errorcode [list TCLPDF DOCUMENT ARGUMENT typeArea] \
              "tclpdf: -typeArea takes distances of 0 or\
              more, not \"$value\""
        }
      }
      # The margins are kept in the document unit, and follow it: a call
      # that changes -unit and does not restate -typeArea has the stored
      # margins re-expressed in the new unit. Measured before 2026-08-18:
      # "tclpdf new -typeArea {25 25}" and then "configure -unit pt" gave
      # margins of 25 pt, not 70.87 - the numbers stayed and the unit
      # under them changed. The page boxes are kept in points and never had
      # this; the margins keep the unit so that [cget -typeArea] answers what
      # the caller wrote, exactly, until the unit moves. A -typeArea given
      # in the same call as -unit is in that unit.
      set from [dict get $tclpdfOption unit]
      set to [dict get $options unit]
      if {$from ne $to && "typeArea" ni [lmap {name ->} $args {
        string trimleft $name -
      }]} {
        dict set options typeArea [lmap value $area {
          ::tclpdf::geometry fromPoints \
              [::tclpdf::geometry toPoints $value $from] $to
        }]
      }
    }
    # -compress is read as a boolean by every stream that is written, and
    # a value that is not one used to fail there - "expected boolean value
    # but got foo" out of the first write, a raw Tcl message naming no
    # option - or, for "-compress 2", to be silently taken as true.
    if {![string is boolean -strict [dict get $options compress]]} {
      return -code error -errorcode [list TCLPDF DOCUMENT ARGUMENT compress] \
          "tclpdf: -compress takes a boolean, not\
          \"[dict get $options compress]\""
    }
    if {[info exists tclpdfWriter]
        && [dict get $options version] ne [dict get $tclpdfOption version]} {
      $tclpdfWriter version [dict get $options version]
    }
    # Whether the caller SAID which way round, or is living with the default.
    # It matters for a page size given as two numbers: those are taken as
    # they stand unless an orientation was asked for - here, or on the page
    # add itself (see PageAdd). The default "portrait" is not a request.
    foreach {option value} $args {
      if {[string trimleft $option -] eq "orientation"} {
        dict set tclpdfState orientationStated 1
      }
    }
    set tclpdfOption $options
    return
  }

  method cget {option} {
    set name [string trimleft $option -]
    if {![dict exists $tclpdfOption $name]} {
      return -code error -errorcode [list TCLPDF DOCUMENT ARGUMENT $option] \
          "tclpdf: unknown option \"$option\""
    }
    return [dict get $tclpdfOption $name]
  }

  # The writer, for modules that need to create objects of their own. Topical
  # modules go through here rather than keeping a writer instance around.
  method writer {} {
    return $tclpdfWriter
  }

  # A feature that exists only from a certain PDF version on, called BEFORE
  # the module writes it: "my RequireVersion 1.4 opacity". Refuses when the
  # document is older, remembers it otherwise - the writer holds both halves,
  # see [require] there. Not raised behind the caller's back: whoever set
  # -version 1.3 said what the file may contain, and a feature that does not
  # fit is a mistake to name, not to paper over.
  # THE CODE IS PUT ON HERE rather than in [require]. Every refusal this
  # package makes carries an -errorcode - it is what a caller catches on
  # instead of matching an English sentence - and the version refusal was the
  # one that came back as NONE: a caller who wanted to answer "then write it
  # as PDF 1.5" had to read the message to find out that was the fault.
  # [require] is the writer's and is called from there as well; the document
  # is where every topical module asks, so this is where the code goes on.
  # The version asked for is in it, because that is the number the caller
  # needs to raise the document to.
  method RequireVersion {version feature} {
    if {[catch {$tclpdfWriter require $version $feature} message options]} {
      if {[dict get $options -errorcode] eq "NONE"} {
        dict set options -errorcode [list TCLPDF VERSION $version]
      }
      return -options $options $message
    }
    return
  }

  # The counterpart: a claim that binds the file to a version AT MOST, made
  # BEFORE the module records it: "my LimitVersion 1.7 PDF/A-3". Refuses when
  # the document is already past it, remembers it otherwise - so that a later
  # [configure -version 2.0] is refused naming the claim, see [limit] there.
  method LimitVersion {version feature} {
    return [$tclpdfWriter limit $version $feature]
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
  # A destination on a page that does not exist YET is allowed: a "back to
  # the contents" link on page one points at the last page, which is added
  # last. Such a target becomes an indirect object, reserved now and filled
  # on beforeWrite when every page is there - the same trick as a structure
  # destination. A page that is still missing then is an error naming what
  # asked for it, so the caller learns which call was wrong rather than
  # "no such page" from somewhere inside the write. Negative and non-integer
  # pages are refused at once: no later page can make them right.
  #
  # The page is the first argument - it is the destination's subject, as the
  # alias is [font embed]'s - and the point and the magnification are options
  # under the names [link] already uses for the same two choices: -to and
  # -zoom.
  method destination {page args} {
    set options [::tclpdf::option parse {to {} zoom {}} $args "destination"]
    return [my Destination $page \
        [dict get $options to] [dict get $options zoom] {}]
  }

  # The worker behind [destination], and the form link and bookmark call:
  # ASKER is the wording of the write-time error when the page never comes
  # ("bookmark \"Contents\"", "link -page 9 on page 0"). It is an argument of
  # the machinery, not of the public method - as an option it would name
  # internals in the manual, and a direct caller's forward destination is
  # still reported, as "a destination".
  method Destination {page at zoom asker} {
    if {![string is integer -strict $page] || $page < 0} {
      return -code error -errorcode [list TCLPDF DOCUMENT PAGE $page] \
          "tclpdf: no such page: $page - the document has\
          [llength $tclpdfPages] page(s)"
    }
    if {$page >= [llength $tclpdfPages]} {
      set pending [my state pendingDestinations]
      set key [llength $pending]
      set number [my reservation destination.pending.$key]
      lappend pending [list $number $page $at $zoom $asker]
      my state pendingDestinations $pending
      if {[llength $pending] == 1} {
        my onSelf beforeWrite DestinationResolve
      }
      return [$tclpdfWriter ref $number]
    }
    return [my DestinationArray $page $at $zoom]
  }

  # Fill the destinations that pointed forward, now that the pages exist.
  # Runs on every write; the objects are reserved once and written over.
  method DestinationResolve {} {
    foreach entry [my state pendingDestinations] {
      lassign $entry number page at zoom asker
      if {$page >= [llength $tclpdfPages]} {
        return -code error -errorcode [list TCLPDF DOCUMENT PAGE $page] \
            "tclpdf: [expr {$asker eq {} ? "a destination" : $asker}]\
            points at page $page and the document has\
            [llength $tclpdfPages] page(s) - add the page, or point elsewhere"
      }
      $tclpdfWriter put $number [my DestinationArray $page $at $zoom]
    }
    return
  }

  method DestinationArray {page at zoom} {
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
      SvgCapture svgElement
      SvgElement svgElement
      SvgShape svgElement
      SvgUse svgElement
      SvgText svgElement
      SvgBounds svgPaint
      SvgPaint svgPaint
      SvgStyle svgPaint
      SvgGradient svgPaint
      SvgStops svgPaint
      SvgClipEnter svgClip
      SvgClipReference svgClip
      SvgClipRuleOf svgClip
      SvgClipOperators svgClip
      SvgClipMask svgClip
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
      fitCheck page
      fitAnchor page
      boxClipped page
      save graphics
      restore graphics
      transform graphics
      style graphics
      opacity graphics
      blend graphics
      GraphicsColour graphics
      GraphicsOpacity graphics
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
      AnnotationOnPage output
      form xObject
      FormBegin xObject
      FormEnd xObject
      layer layer
      pdf import
      attach attach
      attachments attach
      attachmentsWithoutDescription attach
      font text
      colorFont colorFont
      fontsWithoutProgram font
      FontKind font
      FontResource font
      FontToUnicode font
      text text
      textWidth text
      textLines textBlock
      leader leader
      textHeight textBlock
      image image
      undescribedGraphics image
      GraphicMark image
      GraphicUnmark image
      ColourSpaceUsed color
      colourSpacesUsed color
      icc color
      shading shading
      pattern pattern
      table table
      pdfa pdfa
      encrypt encrypt
      sign sign
      field field
      FieldEnlist field
      FieldRectangle field
      xmpSchema xmp
      xmpRaw xmp
      zugferd zugferd
      link link
      linksWithoutContents link
      annot annot
      pageNumbers pageNumber
      pageLabels pageLabel
      textPath textPath
      bookmark outline
      bookmarks outline
      svg svg
      viewerPreferences viewerPreferences
      initialView viewerPreferences
      ua ua
      tagged structure
      structure structure
      StructureMark structure
      StructureAnnotation structure
      StructureExpansion structure
      StructureBegin structure
      StructureEnd structure
      StructureWrite structureWrite
      structureReport structureReport
      structureDestination structureDest
      StructureDestinationGuard structureDest
    }
    if {[dict exists $topics $method]} {
      set topic [dict get $topics $method]
      package require tclpdf::$topic
      # -private matters: a topic may consist entirely of private methods,
      # and [info object methods -all] lists only the exported ones. Without
      # it the module loads correctly and the check below then denies it.
      if {$method ni [info object methods [self] -all -private]} {
        return -code error -errorcode [list TCLPDF DOCUMENT MODULE $topic] \
            "tclpdf: module $topic does not provide \"$method\""
      }
      return [my $method {*}$args]
    }
    next $method {*}$args
  }

  # -- resources, catalog, metadata ---------------------------------------

  # Register a resource: category is one of the eight entries of the resource
  # dictionary (ISO 32000-2, Table 34); value is already PDF syntax, usually a
  # reference. Told apart by the NUMBER of arguments, for the reason spelled
  # out at [state] below: with a default parameter, "clear this" and "read
  # this" are the same call and the caller silently gets the wrong one of the
  # two.
  method resource {category args} {
    # Checked against the table rather than trusted: a misspelt category used
    # to land in the file without a word, as a dictionary no reader looks up.
    if {$category ni {ExtGState ColorSpace Pattern Shading XObject Font
        ProcSet Properties}} {
      return -code error -errorcode [list TCLPDF DOCUMENT RESOURCE $category] \
          "tclpdf: resource category is ExtGState, ColorSpace,\
          Pattern, Shading, XObject, Font, ProcSet or Properties, not\
          \"$category\""
    }
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
        return -code error -errorcode [list TCLPDF DOCUMENT RESOURCE arguments] \
            "tclpdf: resource takes a category, a name and at\
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
        return -code error -errorcode [list TCLPDF DOCUMENT STATE arguments] \
            "tclpdf: state takes a key and at most one value"
      }
    }
  }

  # The moment the document was created, read from the clock ONCE and kept.
  # Two consumers name it: xmp:CreateDate in the packet and CreationDate in
  # the Info dictionary. Fed from two separate clock calls during the first
  # write, they can straddle a second boundary - and then disagree for the
  # life of the file, since both are stored back for the sake of a
  # byte-identical second write.
  method Created {} {
    set created [my state created]
    if {$created eq {}} {
      set created [my state created [clock seconds]]
    }
    return $created
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
      return -code error -errorcode [list TCLPDF DOCUMENT CATALOG arguments] \
          "tclpdf: catalogEntry takes a key and at most one value"
    }
    set value [lindex $args 0]
    if {$value eq {}} {
      dict unset tclpdfCatalog $key
      return {}
    }
    dict set tclpdfCatalog $key $value
    return $value
  }

  # -- strings on their way into the file ---------------------------------
  #
  # Every string a module writes into an OBJECT goes out through these three
  # rather than calling pdfObj directly. The reason is encryption: a PDF is
  # encrypted string by string and stream by stream (ISO 32000-2, 7.6.2),
  # not as a file - so the string constructors are where a cipher has to sit,
  # and a module reaching past them writes the one string in the document
  # that a reader cannot decrypt.
  #
  # Without an encryptor these are pdfObj with one stack frame more; the
  # state key is empty and stays empty until something sets it, so a
  # document that is never encrypted pays a dict lookup per string.
  #
  # The encryptor is a command prefix and it is asked for the FINISHED PDF
  # syntax, not for encrypted bytes to hand on to pdfObj:
  #
  #   {*}$prefix str      $text     -> a string object for that text
  #   {*}$prefix hexStr   $bytes    -> a string object for those bytes
  #   {*}$prefix bytesStr $bytes    -> a string object for those bytes
  #
  # Measured 2026-08-20, and the reason for that shape: [pdfObj str] decides
  # between a literal string and UTF-16BE by looking at the value, so
  # feeding it ciphertext turns six encrypted bytes into
  # <feff008f002a000000c300ff0041> - the cipher's own bytes encoded a second
  # time, which no reader can undo. Which spelling encrypted bytes get is
  # the cipher's decision, exactly as the metadata question is at the
  # stream seam.
  method Str {value} {
    set prefix [my state stringEncryptor]
    if {$prefix eq {}} {
      return [::tclpdf::pdfObj str $value]
    }
    return [{*}$prefix str $value]
  }

  method HexStr {bytes} {
    set prefix [my state stringEncryptor]
    if {$prefix eq {}} {
      return [::tclpdf::pdfObj hexStr $bytes]
    }
    return [{*}$prefix hexStr $bytes]
  }

  method BytesStr {bytes} {
    set prefix [my state stringEncryptor]
    if {$prefix eq {}} {
      return [::tclpdf::pdfObj bytesStr $bytes]
    }
    return [{*}$prefix bytesStr $bytes]
  }

  # A trailer entry - the same handle for the file trailer (7.5.5) that
  # [catalogEntry] is for the catalog. The core writes /Root, /Info, /Size
  # and /ID and nothing else; everything a trailer can otherwise carry -
  # /Encrypt above all, which is the entry a reader looks for BEFORE it
  # reads anything else - is a subscriber's business and reaches the file
  # through here.
  #
  # Deliberately the twin of [catalogEntry] down to the error message: two
  # entry points that behave differently in the corners are two things to
  # learn instead of one. The value is PDF syntax, as everywhere a value is
  # handed to pdfObj; an empty value REMOVES the key.
  method trailerEntry {key args} {
    if {[llength $args] == 0} {
      if {[dict exists $tclpdfTrailer $key]} {
        return [dict get $tclpdfTrailer $key]
      }
      return {}
    }
    if {[llength $args] > 1} {
      return -code error -errorcode [list TCLPDF DOCUMENT TRAILER arguments] \
          "tclpdf: trailerEntry takes a key and at most one value"
    }
    set value [lindex $args 0]
    if {$value eq {}} {
      dict unset tclpdfTrailer $key
      return {}
    }
    dict set tclpdfTrailer $key $value
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
      return -code error -errorcode [list TCLPDF DOCUMENT LANGUAGE $tag] \
          "tclpdf: \"$tag\" is not a language tag - expected\
          something like de, de-DE or en-GB (RFC 3066)"
    }
    # /Lang in the catalog is PDF 1.4 (Reference 1.7, Table 3.25).
    my RequireVersion 1.4 "language"
    my catalogEntry Lang [my Str $tag]
    return $tag
  }

  # Document information (14.3.3). Keys are Title, Author, Subject, Keywords,
  # Creator, Producer - the text strings - plus CreationDate and ModDate,
  # which are PDF dates, and Trapped, which is a NAME (ISO 32000-1, Table
  # 317: True, False or Unknown). Those three are checked here at the call:
  # "info CreationDate yesterday" used to reach the file verbatim, and
  # "info Trapped True" was written as the string (True), which no reader
  # takes for the name /True. The two dates are mirrored into the XMP packet
  # under the properties the table pairs them with; Trapped is not, and
  # xmp.tcl says why.
  method info {key args} {
    if {[llength $args] == 0} {
      if {[dict exists $tclpdfInfo $key]} {
        return [dict get $tclpdfInfo $key]
      }
      return {}
    }
    if {[llength $args] > 1} {
      return -code error -errorcode [list TCLPDF DOCUMENT INFO arguments] \
          "tclpdf: info takes a key and at most one value"
    }
    set value [lindex $args 0]
    if {$value eq {}} {
      # An empty value REMOVES the key. Writing it as an empty string instead
      # would put "/Title ()" into the file, which is not the same as having
      # no title, and PDF/A wants the XMP and the info dictionary to agree.
      dict unset tclpdfInfo $key
      return {}
    }
    switch -- $key {
      CreationDate - ModDate {
        my CheckDate $value "info $key"
      }
      Trapped {
        if {$value ni {True False Unknown}} {
          return -code error -errorcode [list TCLPDF DOCUMENT INFO Trapped] \
              "tclpdf: info Trapped takes True, False or\
              Unknown - a name, ISO 32000-1 Table 317 - not \"$value\""
        }
        # The key is PDF 1.3 (Reference 1.7, Table 10.2).
        my RequireVersion 1.3 "info Trapped"
      }
    }
    dict set tclpdfInfo $key $value
    return $value
  }

  # A PDF date (7.9.4) - "D:YYYYMMDDHHmmSSOHH'mm'", every part after the
  # year optional, as [pdfObj date] writes it and as 2.0 spells it without
  # the closing apostrophe - checked before it is stored anywhere. Two
  # callers: [info] for CreationDate and ModDate, and [attach] for -date;
  # each names itself, so the message says which call was wrong.
  method CheckDate {value what} {
    if {[::tclpdf::document::parseDate $value] eq {}} {
      return -code error -errorcode [list TCLPDF DOCUMENT DATE $what] \
          "tclpdf: $what takes a PDF date such as\
          D:20260818120000+02'00' (ISO 32000-1, 7.9.4) - pdfObj date writes\
          one from a clock value - not \"$value\""
    }
    return
  }

  # XMP metadata, set as raw XML (14.3.2). Raw on purpose: PDF/A and ZUGFeRD
  # prescribe the exact wording including the extension schema, and a
  # generator that "helps" is precisely what breaks those.
  method metadata {args} {
    if {[llength $args] > 1} {
      return -code error -errorcode [list TCLPDF DOCUMENT METADATA arguments] \
          "tclpdf: metadata takes at most one XMP packet"
    }
    if {[llength $args] == 1} {
      # A metadata stream is PDF 1.4 (Reference 1.7, 10.2.2). Checked here
      # because this is the one road every packet takes - the caller's own
      # and the one [XmpCatalog] builds for pdfa and ua, both of which raise
      # the version themselves.
      my RequireVersion 1.4 "metadata"
      # Stored as TEXT, and answered as text: what a caller sets is what
      # they read back. It is encoded to UTF-8 ONCE, when the stream is
      # written (WriteMetadata in output.tcl) - the packet's own BOM in its
      # xpacket instruction declares UTF-8 (XMP part 1, ISO 19005 6.6.2.1),
      # and the writer refuses text in a stream anyway. The encoding used
      # to happen here, which stored bytes: [metadata] then answered UTF-8
      # bytes, and "$doc metadata [$doc metadata]" - the manual's "kept as
      # given" taken at its word - encoded them a second time, so a title
      # "Müller" went out as "MÃ¼ller".
      set tclpdfXmp [lindex $args 0]
    }
    return $tclpdfXmp
  }

  # The events this document fires - see the head of this file. The bus
  # (event.tcl) holds no PDF knowledge and asks here; a subscription to any
  # other name is refused there naming these, rather than accepted for an
  # event that never comes.
  method events {} {
    return {pageAdded beforeWrite resources catalog info afterWrite}
  }

}

# The fields of a PDF date string (7.9.4): a dict of year month day hour
# minute second sign zoneHour zoneMinute, the absent ones empty - or an
# empty string when the text is not a PDF date. The syntax is
# D:YYYYMMDDHHmmSSOHH'mm', each part after the year optional but only in
# order; O is +, - or Z. ISO 32000-1 asks for the apostrophe after the zone
# minutes as well and 2.0 dropped it, so it is optional here - both are
# read as the same moment. The ranges are checked too: a month 13 is as
# little a date as "yesterday" is, and would reach the file the same way.
#
# One parser for two readers: [CheckDate] refuses at the call, and xmp.tcl
# turns the same fields into the XMP form for the packet.
proc ::tclpdf::document::parseDate {value} {
  if {![regexp {^D:(\d{4})(?:(\d{2})(?:(\d{2})(?:(\d{2})(?:(\d{2})(?:(\d{2})(?:([-+Z])(?:(\d{2})(?:'(\d{2})'?)?)?)?)?)?)?)?)?$} \
      $value -> year month day hour minute second sign zoneHour zoneMinute]} {
    return {}
  }
  foreach {field low high} {month 1 12 day 1 31 hour 0 23 minute 0 59
      second 0 59 zoneHour 0 23 zoneMinute 0 59} {
    set number [set $field]
    if {$number ne {} && ([scan $number %d] < $low || [scan $number %d] > $high)} {
      return {}
    }
  }
  return [dict create year $year month $month day $day hour $hour \
      minute $minute second $second sign $sign zoneHour $zoneHour \
      zoneMinute $zoneMinute]
}

package provide tclpdf::document 1.13