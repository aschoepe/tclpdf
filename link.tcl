#
# tclpdf - PDF generation for Tcl
#
# link - clickable areas, as link annotations (12.5.6.5)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
#   $doc link -at {20 100} -size {60 6} -url https://example.org/
#   $doc link -at {20 110} -size {60 6} -page 3
#
# A link is not drawn - it is a rectangle laid over whatever is already there.
# Drawing the text and marking it up are two calls on purpose: the text may be
# a table cell, a heading or nothing at all.
#
# Two details matter for PDF/A and neither is obvious. The annotation must
# have its Print flag set (/F 4): an archived document has to look the same
# printed as on screen, and a validator rejects one that could differ. And it
# gets a zero-width border, because the default is a visible frame that no
# caller asked for.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::link {}

oo::define ::tclpdf::document::document {

  method link {args} {
    set options [::tclpdf::option parse {
      at {} size {} url {} page {} to {} zoom {} tooltip {} structure {}
    } $args "link"]
    if {[dict get $options at] eq {} || [dict get $options size] eq {}} {
      return -code error "tclpdf: link needs -at {x y} and -size {w h}"
    }
    if {[dict get $options url] eq {} && [dict get $options page] eq {}
        && [dict get $options structure] eq {}} {
      return -code error "tclpdf: link needs -url, -page or -structure"
    }
    # Annotation flags (/F) and actions (/A, the URI link) are PDF 1.1
    # (Reference 1.7, Table 8.15 and 8.5); a 1.0 file has neither.
    my RequireVersion 1.1 "link"
    lassign [dict get $options at] left top
    lassign [dict get $options size] width height
    lassign [my coords $left [expr {$top + $height}]] x0 y0
    lassign [my coords [expr {$left + $width}] $top] x1 y1

    set pairs [list Type /Annot Subtype /Link \
        Rect [::tclpdf::pdfObj arr [list \
            [::tclpdf::pdfObj num $x0] [::tclpdf::pdfObj num $y0] \
            [::tclpdf::pdfObj num $x1] [::tclpdf::pdfObj num $y1]]] \
        Border [::tclpdf::pdfObj arr {0 0 0}] \
        F 4]
    if {[dict get $options tooltip] ne {}} {
      lappend pairs Contents [::tclpdf::pdfObj str [dict get $options tooltip]]
    }
    if {[dict get $options url] ne {}} {
      lappend pairs A [::tclpdf::pdfObj dictionary [list \
          S /URI URI [::tclpdf::pdfObj str [my LinkUri [dict get $options url]]]]]
    } elseif {[dict get $options structure] ne {}} {
      # A structure destination names the ELEMENT rather than a place on a
      # page (12.3.2.3), so the link still lands on the right thing after the
      # content has moved. PDF/UA-2 asks for internal targets to be written
      # this way. It needs a tagged document and a 2.0 file, and the guard
      # says so rather than writing a destination that points at nothing.
      #
      # Written as an action (/A), not as /Dest: a GoTo carries the structure
      # destination in /SD AND a page destination in /D (32000-2 Table 202),
      # so a reader that does not know /SD still lands on the right page.
      # The method builds the pair; what it holds is described there.
      my StructureDestinationGuard "link -structure"
      lappend pairs A [my structureDestination [dict get $options structure]]
    } else {
      # The page may not exist yet - a link forward at a page added later
      # is allowed, and [destination] says at write time if it never came.
      lappend pairs Dest [my destination [dict get $options page] \
          [dict get $options to] [dict get $options zoom] \
          "link -page [dict get $options page] on page [my page current]"]
    }
    # Reserved before the dictionary is written, because the StructParent that
    # goes INTO it can only be asked for once the object has a number.
    set number [[my writer] add [::tclpdf::pdfObj dictionary $pairs]]
    if {[my state tagged] eq "1"} {
      set key [my StructureAnnotation $number]
      if {$key ne {}} {
        lappend pairs StructParent $key
        [my writer] put $number [::tclpdf::pdfObj dictionary $pairs]
      }
    }
    my LinkRegister [my page current] [[my writer] ref $number]
    return $number
  }

  # Which link annotations carry no Contents, by page. Empty when every one
  # of them has a description.
  #
  # PDF/UA makes Contents mandatory (7.18.5): a link is announced by that
  # text, and without it a reader says "link" and stops. The fact is
  # established here, where the annotations are, and judged by ua.tcl - the
  # same division as fonts.
  #
  # A tooltip is what fills it, so the fix is one option on the call that
  # created the link rather than anything structural.
  method linksWithoutContents {} {
    set missing {}
    dict for {page references} [my state annots] {
      foreach reference $references {
        if {![regexp {(\d+) 0 R} $reference -> number]} {
          continue
        }
        set body [[my writer] body $number]
        if {![regexp {/Subtype /Link\M} $body]} {
          continue
        }
        if {[regexp {/Contents\M} $body]} {
          continue
        }
        lappend missing [expr {$page + 1}]
      }
    }
    return $missing
  }

  # The URI as the file may carry it: 7-bit ASCII (ISO 32000-1 Table 206),
  # everything else percent-encoded from its UTF-8 bytes (RFC 3986 2.1).
  #
  # Handed to [str] as it came, a URL with an umlaut in it became a UTF-16BE
  # hex string - readable to a Tcl programmer and to no browser: what a reader
  # passes on is the bytes of the string, and the reader was never told which
  # encoding they were in. Measured with https://ü.de/ä, which arrived as
  # <feff0068...00fc...>.
  #
  # What stays as it is: the unreserved and the reserved characters of RFC
  # 3986 2.2 and 2.3, and the percent sign - so an already encoded %C3%BC is
  # not encoded a second time. Everything else, a space included, becomes
  # %XX per byte, which is what a browser does to the same address.
  method LinkUri {url} {
    set kept {ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789}
    append kept {-._~} {:/?#[]@} {!$&'()*+,;=} %
    set result {}
    foreach byte [split [encoding convertto utf-8 $url] {}] {
      if {[string first $byte $kept] >= 0} {
        append result $byte
      } else {
        binary scan $byte cu code
        append result [format %%%02X $code]
      }
    }
    return $result
  }

  # Annotations are collected per page and picked up when the page is
  # written. Kept in the scratch state rather than pushed into output.tcl, so
  # that a document without links costs nothing.
  method LinkRegister {page reference} {
    set annots [my state annots]
    dict lappend annots $page $reference
    my state annots $annots
    return
  }
}

package provide tclpdf::link 1.1
