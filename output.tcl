#
# tclpdf - PDF generation for Tcl
#
# output - turning a document into a file
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Split off document.tcl when that file passed the review limit. Writing is
# its own topic, and it is needed only once at the very end - so it is
# loaded lazily like any other topical module, and building a document that
# is never written does not pay for it.
#
# The order of the events fired here is the contract attachments and
# ZUGFeRD rely on; it is documented at the top of document.tcl.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::filter 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::output {}

oo::define ::tclpdf::document::document {

  # -- writing ------------------------------------------------------------

  method write {path} {
    set trailerPairs [my OutputBuild]
    $tclpdfWriter writeFile $path $trailerPairs
    my emit afterWrite $path
    return $path
  }

  # Write to an open channel instead of a file - a CGI response, a socket, a
  # pipe. The caller opens and closes it; the writer only configures the
  # translation, because that decides whether the bytes survive.
  #
  # The manual described this for four releases and the method did not exist:
  # [writeChannel] lived on the WRITER, took two arguments, and "$doc
  # writeChannel $fh" answered "unknown method". Nothing called it, which is
  # why nothing noticed.
  method writeChannel {channel} {
    set trailerPairs [my OutputBuild]
    $tclpdfWriter writeChannel $channel $trailerPairs
    # No path to pass on, so subscribers get an empty one - they use it for
    # logging, and an empty string says "there is no file" rather than lying
    # about one.
    my emit afterWrite {}
    return
  }

  # A writer object number that SURVIVES rebuilds. The first call under a key
  # reserves a fresh number, every later one answers the same number again -
  # so a builder that runs on every write puts OVER its objects instead of
  # allocating new ones.
  #
  # This is what makes a second [write] produce the same file instead of a
  # larger one. Build runs used to reserve fresh numbers every time: each
  # write added five core objects, and every subscriber that creates objects
  # (attachments, the output intent, the bookmark tree) added its own on top -
  # measured, a document with one attachment grew 1803 to 3299 to 4791 bytes
  # over three writes, embedding the attachment bytes anew each time. The file
  # stayed valid; the earlier objects were simply unreachable.
  #
  # Every builder that runs at write time goes through here, and any OUTSIDE
  # subscriber to beforeWrite or catalog that creates objects must do the
  # same - that is the idempotence contract documented in event.tcl.
  method reservation {key} {
    set numbers [my state reservations]
    if {![dict exists $numbers $key]} {
      dict set numbers $key [$tclpdfWriter reserve]
      my state reservations $numbers
    }
    return [dict get $numbers $key]
  }

  # Everything both ways have in common: create the objects, fire the events,
  # hand back the trailer pairs. Split out when [writeChannel] appeared -
  # duplicating a sequence in which the ORDER of five events is the contract
  # is how two ways of writing end up producing different documents.
  method OutputBuild {} {
    if {![llength $tclpdfPages]} {
      return -code error "tclpdf: the document has no pages"
    }
    my emit beforeWrite

    set catalogNumber [my reservation output.catalog]
    set pagesNumber [my reservation output.pages]

    # The resource dictionary is one INDIRECT object that every page points
    # at. It could be inherited from the page tree instead - ISO 32000-1
    # 7.7.3.4 provides for exactly that - but PDF/A forbids it: clause 6.2.2
    # requires every content stream to have an explicitly associated
    # Resources dictionary, and veraPDF fails a file that relies on
    # inheritance. Measured, not assumed: the first ZUGFeRD document written
    # here failed on "inheritedResourceNames == ''" and on nothing else
    # structural.
    #
    # One object referenced N times costs the same as inheritance did - a
    # logo used on five pages is still embedded once.
    set resourceNumber [my reservation output.resources]
    set kids {}
    set pageIndex 0
    foreach page $tclpdfPages {
      lappend kids [$tclpdfWriter ref \
          [my WritePage $page $pagesNumber $pageIndex $resourceNumber]]
      incr pageIndex
    }

    my emit resources
    set resourcePairs {}
    dict for {category entries} $tclpdfResources {
      set inner {}
      dict for {name value} $entries {
        lappend inner $name $value
      }
      lappend resourcePairs $category [::tclpdf::pdfObj dictionary $inner]
    }
    $tclpdfWriter put $resourceNumber [::tclpdf::pdfObj dictionary $resourcePairs]

    $tclpdfWriter put $pagesNumber [::tclpdf::pdfObj dictionary [list \
        Type /Pages \
        Kids [::tclpdf::pdfObj arr $kids] \
        Count [llength $tclpdfPages]]]

    my emit catalog
    set catalogPairs [list Type /Catalog Pages [$tclpdfWriter ref $pagesNumber]]
    if {$tclpdfXmp ne {}} {
      lappend catalogPairs Metadata [$tclpdfWriter ref [my WriteMetadata]]
    }
    dict for {key value} $tclpdfCatalog {
      lappend catalogPairs $key $value
    }
    $tclpdfWriter put $catalogNumber [::tclpdf::pdfObj dictionary $catalogPairs]

    set trailerPairs [list Root [$tclpdfWriter ref $catalogNumber]]
    my emit info
    if {[dict size $tclpdfInfo]} {
      lappend trailerPairs Info [$tclpdfWriter ref [my WriteInfo]]
    }

    return $trailerPairs
  }

  method WritePage {page pagesNumber index resourceNumber} {
    set contentNumber [my streamObject {} [dict get $page content] \
        [my reservation content.$index]]

    set pagePairs [list Type /Page Parent [::tclpdf::pdfObj ref $pagesNumber]]
    dict for {name box} [dict get $page boxes] {
      set key [string totitle $name]Box
      lappend pagePairs $key [::tclpdf::pdfObj arr [lmap number $box {
        ::tclpdf::pdfObj num $number
      }]]
    }
    if {[dict get $page rotate]} {
      lappend pagePairs Rotate [dict get $page rotate]
    }
    lappend pagePairs Resources [::tclpdf::pdfObj ref $resourceNumber] \
        Contents [$tclpdfWriter ref $contentNumber]
    # Annotations - links today, form fields later. Read out of the scratch
    # state rather than pushed in by the link module, so that a document
    # without links costs nothing and this file stays free of the topic.
    set annots [my state annots]
    if {[dict exists $annots $index]} {
      lappend pagePairs Annots [::tclpdf::pdfObj arr [dict get $annots $index]]
      # Tabs says in which order tabbing moves through the annotations, and
      # /S means "follow the structure tree". PDF/UA requires it on every
      # page that has annotations at all (7.18.1); without it the order is
      # whatever the array happens to be, which is drawing order.
      #
      # Written whenever there are annotations rather than only under a UA
      # claim: there is no case where the array order is the better answer,
      # and 2.0 makes /S the default for exactly that reason.
      lappend pagePairs Tabs /S
    }
    # The index into the ParentTree of a tagged document, reaching this file
    # the same way and for the same reason: a document without a structure
    # tree costs nothing, and the topic stays out of here.
    set structParents [my state structParents]
    if {[dict exists $structParents $index]} {
      lappend pagePairs StructParents [dict get $structParents $index]
    }
    return [$tclpdfWriter put [dict get $page number] \
        [::tclpdf::pdfObj dictionary $pagePairs]]
  }

  method WriteMetadata {} {
    # Never compressed: PDF/A requires the XMP packet to be readable without
    # decoding, and a validator that cannot read it fails the file.
    set number [my reservation output.metadata]
    return [$tclpdfWriter stream $number {Type /Metadata Subtype /XML} $tclpdfXmp]
  }

  method WriteInfo {} {
    # The generated date is stored back rather than made up per run: a second
    # write of an unchanged document has to come out byte-identical, and a
    # fresh timestamp is the one thing that would differ.
    if {![dict exists $tclpdfInfo CreationDate]} {
      # The file version decides how the zone offset is spelled: 2.0 dropped
      # the apostrophe after the minutes.
      #
      # The seconds come from [my Created] - the same value that feeds
      # xmp:CreateDate - rather than from a clock call of this method's own,
      # which could land one second after the packet's.
      dict set tclpdfInfo CreationDate \
          [::tclpdf::pdfObj date [my Created] [$tclpdfWriter version]]
    }
    set pairs {}
    dict for {key value} $tclpdfInfo {
      lappend pairs $key [::tclpdf::pdfObj str $value]
    }
    return [$tclpdfWriter put [my reservation output.info] \
        [::tclpdf::pdfObj dictionary $pairs]]
  }
}

package provide tclpdf::output 1.4
