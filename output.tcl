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

  # Everything both ways have in common: create the objects, fire the events,
  # hand back the trailer pairs. Split out when [writeChannel] appeared -
  # duplicating a sequence in which the ORDER of five events is the contract
  # is how two ways of writing end up producing different documents.
  method OutputBuild {} {
    if {![llength $tclpdfPages]} {
      return -code error "tclpdf: the document has no pages"
    }
    my emit beforeWrite

    set catalogNumber [$tclpdfWriter reserve]
    set pagesNumber [$tclpdfWriter reserve]

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
    set resourceNumber [$tclpdfWriter reserve]
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
    set contentNumber [my streamObject {} [dict get $page content]]

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
    }
    return [$tclpdfWriter put [dict get $page number] \
        [::tclpdf::pdfObj dictionary $pagePairs]]
  }

  method WriteMetadata {} {
    # Never compressed: PDF/A requires the XMP packet to be readable without
    # decoding, and a validator that cannot read it fails the file.
    return [$tclpdfWriter addStream {Type /Metadata Subtype /XML} $tclpdfXmp]
  }

  method WriteInfo {} {
    set pairs {}
    dict for {key value} $tclpdfInfo {
      lappend pairs $key [::tclpdf::pdfObj str $value]
    }
    if {![dict exists $tclpdfInfo CreationDate]} {
      lappend pairs CreationDate [::tclpdf::pdfObj str [::tclpdf::pdfObj date]]
    }
    return [$tclpdfWriter add [::tclpdf::pdfObj dictionary $pairs]]
  }
}

package provide tclpdf::output 1.0
