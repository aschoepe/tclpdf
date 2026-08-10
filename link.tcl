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
      at {} size {} url {} page {} to {} zoom {} tooltip {}
    } $args "link"]
    if {[dict get $options at] eq {} || [dict get $options size] eq {}} {
      return -code error "tclpdf: link needs -at {x y} and -size {w h}"
    }
    if {[dict get $options url] eq {} && [dict get $options page] eq {}} {
      return -code error "tclpdf: link needs -url or -page"
    }
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
          S /URI URI [::tclpdf::pdfObj str [dict get $options url]]]]
    } else {
      lappend pairs Dest [my destination [dict get $options page] \
          [dict get $options to] [dict get $options zoom]]
    }
    set number [[my writer] add [::tclpdf::pdfObj dictionary $pairs]]
    my LinkRegister [my page current] [[my writer] ref $number]
    return $number
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

package provide tclpdf::link 1.0
