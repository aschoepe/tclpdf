#
# tclpdf - PDF generation for Tcl
#
# annotShape - the geometry annotations: line, square, circle, polygon,
#              polyline, and the file attachment
#
#   $doc annot line -from {20 40} -to {90 40} -contents "the correction"
#   $doc annot square -at {20 60} -size {50 20} -colour {0.8 0.1 0.1}
#   $doc annot polygon -points {{20 100} {60 90} {80 120}} -fill {1 1 0.6}
#   $doc annot attachment -at {180 40} -file invoice.xml -icon Paperclip
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# A private sub-module behind the annot facade, registered in the table of
# kinds in annot.tcl. Nothing loads this directly.
#
# WHAT THESE ARE, and why they are not just drawings. A line drawn with
# [$doc line] is content: it prints, it is part of the page, and a reader
# cannot switch it off or ask who put it there. The same line as an
# ANNOTATION is a remark ON the page - it carries an author, a date and a
# description, a reader lists it beside the other remarks, and printing it is
# a choice. That is the whole difference, and it is why the two exist side by
# side rather than one replacing the other.
#
# THE APPEARANCE IS DRAWN HERE, without the caller asking, exactly as
# annotMark.tcl draws its bands - and for the same reason. Table 166 requires
# /AP of every annotation, PDF/A fails a file without one (veraPDF 6.3.3),
# and unlike a note's symbol the picture is FULLY DETERMINED: a line is its
# two endpoints, its colour and its width, and there is nothing left for a
# reader to decide. Leaving it out would produce a document that validates
# nowhere and looks different in every reader.
#
# THE GEOMETRY IS THE CALLER'S OWN COORDINATES, top-left counted, like every
# other drawing call in this package - and NOT the PDF convention the
# annotation dictionary itself uses. /L, /Vertices and /Rect all count from
# the bottom left; the conversion happens in one place per kind, at the point
# the numbers are written, so nothing above the write has to know.
#
# WHY /IC IS NOT /C. A square, a circle and a polygon have two colours: /C is
# what the outline is drawn in, /IC what the inside is filled with
# (Table 176). The API spells them -colour and -fill, which are the words the
# drawing methods of this package already use, and an -fill nobody gave means
# no /IC and a shape you can see through - which is what a remark around
# something usually wants.
#
# WHAT IS NOT HERE. /Ink (12.5.6.13) is a freehand scribble and its data is a
# digitiser's, not a script's; /Caret, /Sound, /Movie, /Screen and /3D are
# behaviours or media rather than remarks. The link and the form widget are
# annotations too and stay in their own modules - see the head of annot.tcl.

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::geometry 1.0-
package require tclpdf::document 1.0-
package require tclpdf::annot 1.0-

namespace eval ::tclpdf::annotShape {
  # The kinds this module answers for: the subcommand, its /Subtype, and the
  # PDF version that first had it. Square, Circle and Line came with 1.3
  # (12.5.6.7 and 12.5.6.8); Polygon and PolyLine with 1.5 (12.5.6.9); the
  # file attachment with 1.3 (12.5.6.15).
  #
  # The subcommands themselves are registered in annot.tcl, which is where
  # the dispatcher has to know them before this file is loaded.
  variable shapes {
    line       {Line 1.3}
    square     {Square 1.3}
    circle     {Circle 1.3}
    polygon    {Polygon 1.5}
    polyline   {PolyLine 1.5}
    attachment {FileAttachment 1.3}
  }

  # The icons a reader draws for a file attachment (Table 184). Four, and no
  # more: ISO 32000-2 admits further names and no reader here draws one, which
  # is the same line [annot stamp] holds for its /Name.
  variable icons {Graph Paperclip PushPin Tag}
}

oo::define ::tclpdf::document::document {

  # The entry annot.tcl calls for every kind in the table above. One method
  # for six, because what they share - the options, the colour, the version
  # guard, the appearance, the write - is nearly all of it, and what differs
  # is the geometry each reads and the shape each draws.
  method AnnotShape {kind args} {
    variable ::tclpdf::annotShape::shapes
    lassign [dict get $shapes $kind] subtype version
    if {$kind eq "attachment"} {
      return [my AnnotAttachment $args]
    }
    set options [::tclpdf::option parse {
      at {} size {} from {} to {} points {} contents {} title {} colour {}
      color {} fill {} width {} opacity {} date {}
    } $args "annot $kind"]
    set options [my AnnotColourOption $options "annot $kind"]
    # An appearance is never taken from a caller here: the picture follows
    # from the geometry, so there is nothing to hand over. The option is in
    # the dictionary all the same because [AnnotWrite] reads it.
    dict set options appearance {}
    # The outline colour every shape has, because without one there is
    # nothing to see. Red, as the three line markups are: a remark drawn in
    # the text colour does not read as a remark.
    if {[dict get $options colour] eq {}} {
      dict set options colour {0.85 0.15 0.15}
    }
    set width [dict get $options width]
    if {$width eq {}} {
      set width 1
    }
    if {![string is double -strict $width] || $width <= 0} {
      return -code error -errorcode [list TCLPDF ANNOT WIDTH $kind $width] \
          "tclpdf: -width of annot $kind is the thickness of the line it is\
          drawn with, above zero, not \"$width\""
    }
    lassign [my AnnotShapeGeometry $kind $options] points box
    set rect [my AnnotShapeRect $kind $box $width "annot $kind"]
    my RequireVersion $version "annot $kind"
    set pairs [my AnnotShapePairs $kind $points $options $width]
    return [my AnnotWrite $subtype $rect $options $pairs 4 {} \
        [list AnnotShapeAppearance $kind $points $width]]
  }

  # The points each kind is made of, in the document unit and top-left
  # counted, plus the box that holds them. One place, so that the rectangle
  # and the appearance cannot come to disagree about where the shape is -
  # which is the defect that makes a reader clip half a drawing away.
  method AnnotShapeGeometry {kind options} {
    switch -- $kind {
      line {
        foreach key {from to} {
          if {[dict get $options $key] eq {}} {
            return -code error -errorcode [list TCLPDF ANNOT LINE $key] \
                "tclpdf: annot line needs -from {x y} and -to {x y} - the two\
                ends of the line, in the document unit"
          }
          ::tclpdf::option point [dict get $options $key] -$key "annot line"
        }
        set points [list [dict get $options from] [dict get $options to]]
      }
      square - circle {
        if {[dict get $options at] eq {} || [dict get $options size] eq {}} {
          return -code error -errorcode [list TCLPDF ANNOT BOX $kind] \
              "tclpdf: annot $kind needs -at {x y} and -size {width height} -\
              the top left corner and the extent of the rectangle it is drawn\
              in, exactly as \[\$doc rect\] takes them"
        }
        ::tclpdf::option point [dict get $options at] -at "annot $kind"
        ::tclpdf::option point [dict get $options size] -size "annot $kind"
        lassign [dict get $options at] left top
        lassign [dict get $options size] width height
        set points [list [list $left $top] \
            [list [expr {$left + $width}] [expr {$top + $height}]]]
      }
      polygon - polyline {
        set points [dict get $options points]
        if {[llength $points] < 2} {
          return -code error -errorcode [list TCLPDF ANNOT POINTS $kind] \
              "tclpdf: annot $kind needs -points, a list of at least two\
              {x y} pairs - a polygon of one point has no shape and nothing\
              to draw"
        }
        foreach point $points {
          ::tclpdf::option point $point -points "annot $kind"
        }
      }
    }
    set xs {}
    set ys {}
    foreach point $points {
      lassign $point x y
      lappend xs $x
      lappend ys $y
    }
    set left [::tcl::mathfunc::min {*}$xs]
    set top [::tcl::mathfunc::min {*}$ys]
    return [list $points [list $left $top \
        [expr {[::tcl::mathfunc::max {*}$xs] - $left}] \
        [expr {[::tcl::mathfunc::max {*}$ys] - $top}]]]
  }

  # /Rect, grown by half the line width on every side.
  #
  # NOT the bare box, and this is the trap the whole kind turns on: a line is
  # drawn ON its path, so half its thickness lies outside the points, and a
  # reader that clips to /Rect - which it may - cuts that half away. Measured
  # before the margin was here: a 3 mm line came out 1.5 mm and the ends were
  # square where they should have been round. Half the width plus a hair, so
  # that a join at a corner is inside as well.
  method AnnotShapeRect {kind box width context} {
    lassign $box left top boxWidth boxHeight
    set margin [expr {$width / 2.0 + 0.05}]
    return [my AnnotRectangle \
        [list [expr {$left - $margin}] [expr {$top - $margin}]] \
        [list [expr {$boxWidth + 2 * $margin}] \
            [expr {$boxHeight + 2 * $margin}]] $context]
  }

  # The entries that belong to the kind rather than to every annotation.
  method AnnotShapePairs {kind points options width} {
    set pairs {}
    switch -- $kind {
      line {
        # /L is the line itself, in PDF coordinates (Table 175).
        set flat {}
        foreach point $points {
          lassign [my coords {*}$point] x y
          lappend flat $x $y
        }
        lappend pairs L [::tclpdf::pdfObj arr \
            [lmap number $flat {::tclpdf::pdfObj num $number}]]
      }
      polygon - polyline {
        # /Vertices, likewise (Table 178).
        set flat {}
        foreach point $points {
          lassign [my coords {*}$point] x y
          lappend flat $x $y
        }
        lappend pairs Vertices [::tclpdf::pdfObj arr \
            [lmap number $flat {::tclpdf::pdfObj num $number}]]
      }
    }
    # /BS carries the line width for every one of them (Table 168): a reader
    # that draws the annotation itself needs it, and so does one that only
    # reports the annotation's properties.
    lappend pairs BS [::tclpdf::pdfObj dictionary \
        [list Type /Border W [::tclpdf::pdfObj num \
            [my distance $width]] S /S]]
    # /IC is the inside, and only the closed kinds have one (Table 176).
    if {[dict get $options fill] ne {} && $kind ne "line" && $kind ne "polyline"} {
      lappend pairs IC [my AnnotColourArray [dict get $options fill]]
    }
    return $pairs
  }

  # The appearance stream. The form, the failure, the /Resources and the
  # reservation are [AnnotAppearanceForm]'s in annot.tcl; what is here is
  # what to draw. The script runs in this frame, so "my" reaches the private
  # drawing method and the locals are in reach.
  method AnnotShapeAppearance {kind points width number rect options} {
    set left [dict get $rect left]
    set top [dict get $rect top]
    return [my AnnotAppearanceForm $rect annot.ap.$number {
      my AnnotShapeDraw $kind $points $left $top $options $width
    }]
  }

  # The drawing itself, in the form's own space.
  method AnnotShapeDraw {kind points left top options width} {
    set moved {}
    foreach point $points {
      lassign $point x y
      lappend moved [list [expr {$x - $left}] [expr {$y - $top}]]
    }
    set stroke [dict get $options colour]
    set fill [dict get $options fill]
    switch -- $kind {
      line {
        lassign $moved from to
        my line -from $from -to $to -stroke $stroke -width $width
      }
      square {
        lassign $moved corner far
        lassign $corner x y
        lassign $far farX farY
        set size [list [expr {$farX - $x}] [expr {$farY - $y}]]
        if {$fill ne {}} {
          my rect -at $corner -size $size -fill $fill -stroke $stroke \
              -width $width
        } else {
          my rect -at $corner -size $size -stroke $stroke -width $width
        }
      }
      circle {
        # An /Circle is an ELLIPSE inscribed in the rectangle (12.5.6.7), not
        # a circle - the name is the standard's and it is misleading enough
        # to be worth a line here.
        lassign $moved corner far
        lassign $corner x y
        lassign $far farX farY
        set size [list [expr {$farX - $x}] [expr {$farY - $y}]]
        if {$fill ne {}} {
          my ellipse -at $corner -size $size -fill $fill -stroke $stroke \
              -width $width
        } else {
          my ellipse -at $corner -size $size -stroke $stroke -width $width
        }
      }
      polygon {
        # [polygon] takes its points FLAT - x y x y - while the annotation
        # carries them as pairs, because that is how a caller writes a list of
        # corners and how /Vertices is read back. Flattened here, at the one
        # place the two meet.
        set flat {}
        foreach point $moved {
          lappend flat {*}$point
        }
        if {$fill ne {}} {
          my polygon -points $flat -fill $fill -stroke $stroke -width $width
        } else {
          my polygon -points $flat -stroke $stroke -width $width
        }
      }
      polyline {
        # Open, so it is drawn as a path rather than as a polygon: the
        # difference between the two IS whether the last point joins the
        # first, and a reader that sees /PolyLine expects it open.
        set previous {}
        foreach point $moved {
          if {$previous ne {}} {
            my line -from $previous -to $point -stroke $stroke -width $width
          }
          set previous $point
        }
      }
    }
    return
  }

  # -- the file attachment (12.5.6.15) -------------------------------------

  # A file that travels with the document and sits at a point on the page.
  #
  # THE FILE ITSELF IS [attach], and this does not duplicate a byte of it:
  # the embedding, the name tree, the MIME type, the sizes and the checksum
  # are attach.tcl's, and what this adds is the annotation that points at one
  # of them. So the option is -name, the name the attachment was given, and
  # not a path - a file attached twice would otherwise travel twice.
  #
  # WHY IT IS AN ANNOTATION AT ALL. An attachment reached through the
  # document's list is a file somebody has to know is there; the same file as
  # an annotation is a paperclip AT the paragraph it belongs to, which is what
  # an invoice with a delivery note attached to one line wants. Under
  # ZUGFeRD it is neither - the invoice XML is reached by /AF and belongs to
  # no page.
  method AnnotAttachment {arguments} {
    variable ::tclpdf::annotShape::icons
    set options [::tclpdf::option parse {
      at {} name {} icon Paperclip contents {} title {} colour {} color {}
      opacity {} date {} appearance {} size {}
    } $arguments "annot attachment"]
    set options [my AnnotColourOption $options "annot attachment"]
    if {[dict get $options at] eq {}} {
      return -code error -errorcode {TCLPDF ANNOT ATTACHMENT AT} \
          "tclpdf: annot attachment needs -at {x y} - where the icon sits on\
          the page"
    }
    ::tclpdf::option point [dict get $options at] -at "annot attachment"
    if {[dict get $options name] eq {}} {
      return -code error -errorcode {TCLPDF ANNOT ATTACHMENT NAME} \
          "tclpdf: annot attachment needs -name, the name an \[\$doc attach\]\
          call gave the file - the annotation points at a file that already\
          travels with the document rather than embedding a second copy"
    }
    if {[dict get $options icon] ni $icons} {
      return -code error -errorcode \
          [list TCLPDF ANNOT ATTACHMENT ICON [dict get $options icon]] \
          "tclpdf: -icon of annot attachment is one of the four of ISO\
          32000-1, Table 184 - [join $icons {, }] - not\
          \"[dict get $options icon]\""
    }
    # THE FILE SPECIFICATION IS attach.tcl's OBJECT, reached through its
    # reservation rather than through its number: the specifications are
    # written at write time, when it is certain nothing more will be added,
    # and a reservation is the stable name that exists before then. This is
    # the same device link.tcl uses for a destination on a page not yet
    # added.
    set index -1
    set position 0
    foreach entry [my state attachments] {
      if {[dict get $entry name] eq [dict get $options name]} {
        set index $position
      }
      incr position
    }
    if {$index < 0} {
      return -code error -errorcode \
          [list TCLPDF ANNOT ATTACHMENT UNKNOWN [dict get $options name]] \
          "tclpdf: no attachment named \"[dict get $options name]\" - attach\
          the file with \[\$doc attach\] first, and give this the same name.\
          The annotation points at a file that already travels with the\
          document; it does not embed a second copy"
    }
    set number [my reservation attach.spec.$index]
    my RequireVersion 1.3 "annot attachment"
    # The icon a reader draws is about 20 by 20 points wherever it is drawn
    # at all, and the standard states no size - so that is the rectangle
    # unless -appearance brought a picture with a size of its own. Measured
    # rather than guessed: the readers on this machine draw into whatever
    # /Rect says and none of them scales the icon.
    set size [dict get $options size]
    if {$size eq {} && [dict get $options appearance] ne {}} {
      set form [my AnnotForm [dict get $options appearance] "annot attachment"]
      set size [list \
          [::tclpdf::geometry fromPoints [dict get $form width] [my cget -unit]] \
          [::tclpdf::geometry fromPoints [dict get $form height] [my cget -unit]]]
    }
    if {$size eq {}} {
      set square [::tclpdf::geometry fromPoints 20 [my cget -unit]]
      set size [list $square $square]
    }
    set rect [my AnnotRectangle [dict get $options at] $size \
        "annot attachment"]
    set pairs [list FS [[my writer] ref $number]]
    # /Name is the reader's icon and /AP is a picture of ours, and Table 166
    # makes /AP win - so writing both would put a /Name in the file that
    # nothing ever draws. The same line [annot stamp] holds between its
    # -name and its -appearance.
    if {[dict get $options appearance] eq {}} {
      lappend pairs Name [::tclpdf::pdfObj name [dict get $options icon]]
    }
    # WITHOUT -appearance THERE IS NO APPEARANCE STREAM, and that is right
    # rather than an omission: the picture is the reader's icon, exactly as
    # it is for [annot note], and drawing one here would replace the icon
    # every reader knows with a drawing of ours. Under a claim that requires
    # an appearance [AnnotCheck] refuses it - the same answer the note gets -
    # and -appearance is the way through, naming a form built with
    # [form create], which is what a house icon is.
    return [my AnnotWrite FileAttachment $rect $options $pairs 4]
  }
}

package provide tclpdf::annotShape 1.0
