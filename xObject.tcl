#
# tclpdf - PDF generation for Tcl
#
# xObject - form XObjects, drawn once and placed many times (8.10)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# A form XObject is a piece of content stored ONCE and referenced wherever it
# appears - a logo on five pages is stored once, not five times, and the file
# stops growing with the page count.
#
# Usage:
#
#   $doc form create letterhead -size {210 40} -script {
#     $doc rect -at {0 0} -size {210 40} -fill {0.9 0.9 0.95}
#     $doc text "Musterfirma GmbH" -at {10 15} -size 14
#   }
#   $doc form place letterhead -at {0 0}
#   $doc page add
#   $doc form place letterhead -at {0 0}      ;# no second copy in the file
#
# Inside the script coordinates count from the FORM's top left corner, exactly
# as they count from the page's everywhere else - {0 0} is the top left, y
# grows downwards, and every drawing method works unchanged. What differs is
# only the reference: [coords] mirrors against the form height instead of the
# page height, which is what the canvas stack in the core is for.
#
# Keeping one convention matters more than it looks. PDF itself puts a form's
# origin at its BOTTOM left, and passing that through to the caller would mean
# the same [rect] call behaves differently depending on where it stands.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::filter 1.0-
package require tclpdf::geometry 1.0-
package require tclpdf::graphics 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::xObject {}

oo::define ::tclpdf::document::document {

  # $doc form create <name> -size {w h} -script {...}
  # $doc form place  <name> ?-at {x y}? ?-scale 1.5? ?-rotate 15?
  # $doc form names
  # $doc form size <name>
  method form {subcommand args} {
    switch -- $subcommand {
      create {return [my FormCreate {*}$args]}
      place {return [my FormPlace {*}$args]}
      names {return [dict keys [my state forms]]}
      size {return [my FormSize {*}$args]}
      default {
        return -code error "tclpdf: unknown form subcommand \"$subcommand\" -\
            known are: create, place, names, size"
      }
    }
  }

  method FormCreate {name args} {
    set options [::tclpdf::option parse {size {} script {} unit {}} $args \
        "form create"]
    if {[dict get $options size] eq {}} {
      return -code error "tclpdf: form create needs -size {width height}"
    }
    # An empty -script is allowed: a form with no content is a valid object
    # and useful as a placeholder. Only the size is genuinely required, since
    # the bounding box cannot be guessed from an empty script.
    set forms [my state forms]
    if {[dict exists $forms $name]} {
      return -code error "tclpdf: a form named \"$name\" already exists"
    }
    # Two lengths above zero, checked BEFORE the script runs - the same
    # check a tiling pattern makes: a form of no width has a BBox with no
    # inside and no reader draws it, and one number instead of two used to
    # run the script and fail afterwards, at the BBox.
    if {[llength [dict get $options size]] != 2} {
      return -code error "tclpdf: -size of form \"$name\" is {width height},\
          not \"[dict get $options size]\""
    }
    lassign [my extent [dict get $options size] [dict get $options unit]] \
        widthPoints heightPoints
    if {$widthPoints <= 0 || $heightPoints <= 0} {
      return -code error "tclpdf: -size of form \"$name\" is\
          {[dict get $options size]} - a form needs a width and a height above zero"
    }

    # The script draws onto a temporary page whose height is the form height -
    # that way [coords] mirrors against the right value and every existing
    # drawing method works unchanged inside a form.
    my FormBegin $widthPoints $heightPoints
    set failed [catch {uplevel #0 [dict get $options script]} result options0]
    set content [my FormEnd]
    if {$failed} {
      return -options $options0 $result
    }

    set pairs [list Type /XObject Subtype /Form FormType 1 \
        BBox [::tclpdf::pdfObj arr [list 0 0 \
            [::tclpdf::pdfObj num $widthPoints] \
            [::tclpdf::pdfObj num $heightPoints]]]]
    # A transparency group (11.6.6), so that [FormPlace] -opacity fades the
    # form as ONE object. Without the group a form is treated as if its
    # objects were painted directly onto the page (8.10.1), and the alpha set
    # before the Do applies to each of them separately: where two shapes
    # inside the form overlap, the second is composited over the first at
    # half strength - measured, two opaque rectangles at -opacity 0.5 came out
    # (191 63 63) in the overlap, the black one showing through the red, and
    # (255 127 127) with the group. No validator sees the difference.
    #
    # Written for every form, not only for one placed with -opacity: the
    # object is written here and placed later, possibly many times, and a
    # group at alpha 1 with the Normal blend mode composites the same as no
    # group (11.6.6) - measured with poppler, the examples with forms render
    # to the same pixels except along the form's edge, where the group's
    # anti-aliasing differs by one row. Isolated (I true), so the contents
    # composite against a transparent backdrop rather than the page: a blend
    # mode set before the Do then applies to the form once, not to each
    # shape against the page.
    #
    # No CS: the group then composites in the space of the page it is
    # painted onto, which without a page group is the device's native space
    # (ISO 32000-1, Table 147 - CS is optional unless the group is the G of a
    # luminosity soft mask, and defaults to the parent's). Naming one is a
    # claim PDF/A checks: a group /CS /DeviceRGB is "use of DeviceRGB", and
    # ISO 19005-2, 6.2.4.3 allows that only under an RGB output intent -
    # measured with veraPDF, one failed check (6.2.4.3-2) for a CMYK and for
    # a GRAY intent, none for sRGB. Following the intent instead would mean
    # reading the profile's colour space here, which pdfa.tcl already does at
    # write time, and deciding at [form create] what [pdfa] may only declare
    # afterwards. Left out, the group is clean under every intent (0 failed
    # checks with sRGB, GRAY and CMYK profiles), and poppler renders the same
    # pixels with and without it, the overlap included.
    #
    # Groups exist since PDF 1.4 - a document set to an older version gets
    # none, and -opacity then acts per object as before.
    if {[package vcompare [[my writer] version] 1.4] >= 0} {
      lappend pairs Group [::tclpdf::pdfObj dictionary {S /Transparency I true}]
    }
    # PDF/A 6.2.2: a content stream that references other objects - a font,
    # a picture - must have its OWN Resources dictionary; inheriting is valid
    # PDF and forbidden here. veraPDF rejects the file, qpdf says nothing.
    # The same one indirect object every page points at, so nothing is
    # embedded twice.
    lappend pairs Resources [[my writer] ref [my reservation output.resources]]
    set number [my streamObject $pairs $content]
    set resourceName XO[my FormCount]
    my resource XObject $resourceName [[my writer] ref $number]
    dict set forms $name [dict create resource $resourceName \
        width $widthPoints height $heightPoints]
    my state forms $forms
    return $name
  }

  method FormPlace {name args} {
    set options [::tclpdf::option parse \
        {at {} scale 1 rotate 0 opacity {} alt {} artifact {}} $args "form place"]
    set forms [my state forms]
    if {![dict exists $forms $name]} {
      return -code error "tclpdf: no form named \"$name\" - known are:\
          [join [dict keys $forms] {, }]"
    }
    set form [dict get $forms $name]
    # Every value is checked before anything is written - the mark, the
    # "q": -at, -scale, -rotate, and the alpha last, since that one makes
    # its ExtGState as it passes ([GraphicsOpacity] refuses first and
    # creates second). Measured before 2026-08-18: "-rotate x" and
    # "-at {1}" were read after the mark and the q were out and left both
    # open; "-scale 0" went out as a singular cm, and "-scale -1" put the
    # form mirrored above and left of the corner it was given. A factor
    # above zero is what a size wants; turning is what -rotate is for.
    if {[dict get $options at] ne {}} {
      my GraphicsPoint [dict get $options at] -at "form place"
    }
    set scale [dict get $options scale]
    if {![string is double -strict $scale] || $scale <= 0} {
      return -code error "tclpdf: -scale of form place is a factor above zero,\
          not \"$scale\""
    }
    if {![string is double -strict [dict get $options rotate]]} {
      return -code error "tclpdf: -rotate of form place is an angle in\
          degrees, not \"[dict get $options rotate]\""
    }
    set alpha {}
    if {[dict get $options opacity] ne {}} {
      set alpha [my GraphicsOpacity [dict get $options opacity]]
    }
    # -at names the TOP left corner, like rect - so the placement matches how
    # the rest of the API is used, even though the form's own origin is at its
    # bottom left.
    #
    # The whole placement is worked out HERE, above the mark, and still nothing
    # is written. The mark needs it: a Figure carries the rectangle it covers
    # as an attribute (ISO 32000-2, 14.8.5.4.3), and an attribute is fixed when
    # the element is OPENED - which is what the mark does. Of the two ways out
    # this is the harmless one; the other, marking after the invocation, would
    # put the BDC behind the content it is supposed to bracket. Everything that
    # can be refused was refused above, so what stands here is arithmetic.
    lassign [expr {[dict get $options at] eq {} ? {0 0} : [dict get $options at]}] x y
    set heightUnit [::tclpdf::geometry fromPoints [dict get $form height] \
        [my cget -unit]]
    lassign [my coords $x [expr {$y + $heightUnit * $scale}]] px py
    set matrix [::tclpdf::geometry translate $px $py]
    if {[dict get $options rotate] != 0} {
      set matrix [::tclpdf::geometry multiply \
          [::tclpdf::geometry rotate [dict get $options rotate]] $matrix]
    }
    if {$scale != 1} {
      set matrix [::tclpdf::geometry multiply \
          [::tclpdf::geometry scale $scale] $matrix]
    }

    # The invocation is content on the page: a Figure when -alt describes it,
    # an artifact otherwise. Unmarked content is a defect under PDF/UA, and a
    # reusable block is decoration more often than not.
    #
    # More often is not always, so an artifact nobody asked for is remembered,
    # as image.tcl does for a picture: -artifact 1 says decoration on purpose,
    # and without it or -alt the caller has not said - see
    # [undescribedGraphics]. The marking itself is [GraphicMark] in image.tcl,
    # shared with the picture and the drawing; the top edge of -at is where
    # the placement begins, so that a destination at the Figure can name the
    # place on the page, and [FormBox] is the area the Figure covers.
    lassign [my GraphicMark form "form place" [dict get $options alt] \
        [dict get $options artifact] $y [my FormBox $form $matrix]] mark element

    my save
    if {$alpha ne {}} {
      my content "[::tclpdf::pdfObj name $alpha] gs\n"
    }
    my content "[join [lmap number $matrix {::tclpdf::pdfObj num $number}] { }] cm\n"
    my content "[::tclpdf::pdfObj name [dict get $form resource]] Do\n"
    my restore
    my GraphicUnmark $mark $element
    return $name
  }

  # The area a placement covers, as {left top width height} in the document
  # unit and counted from the top - the bounding box its Figure carries. ISO
  # 32000-2, 14.8.5.4.3 asks for "the rectangle that completely encloses its
  # visible content", and for a form that rectangle is the form's own BBox
  # where it lands on the page.
  #
  # Worked out by putting the form's four corners through the VERY matrix that
  # goes into the stream, rather than by repeating the placement arithmetic:
  # the box cannot then drift from the drawing, and -rotate is covered without
  # a case of its own. A turned form gets the upright box AROUND the turned
  # one, which is what "completely encloses" asks for. Writing the untouched
  # rectangle instead would leave part of the figure outside the box and cover
  # page that is not the figure, and nothing downstream can tell that the four
  # numbers are the wrong ones. Leaving the attribute off whenever -rotate is
  # given was the other candidate, and it is defensible - but it says nothing
  # in exactly the case where saying it exactly costs four points through a
  # matrix, and the corners of a rectangle turned in the plane have no error
  # term.
  #
  # The corners come out in PDF points and go back through the inverse of
  # [coords] - [coords 0 0] IS the caller's origin in PDF points, media box
  # offset and page height included. The attribute is given in the document
  # unit and counted from the top, which is the one spelling structure.tcl
  # converts, for every bbox alike.
  # The area the invocation covers, for the Figure's /BBox. The arithmetic
  # itself is [PlacedBox] in page.tcl, shared with the picture: a form is
  # placed through its own size, a picture through the unit square, and the
  # rest is the same question.
  method FormBox {form matrix} {
    return [my PlacedBox [dict get $form width] [dict get $form height] $matrix]
  }

  method FormSize {name} {
    set forms [my state forms]
    if {![dict exists $forms $name]} {
      return -code error "tclpdf: no form named \"$name\""
    }
    set form [dict get $forms $name]
    set unit [my cget -unit]
    return [list [::tclpdf::geometry fromPoints [dict get $form width] $unit] \
        [::tclpdf::geometry fromPoints [dict get $form height] $unit]]
  }

  method FormCount {} {
    set count [my state formCount]
    if {$count eq {}} {
      set count 0
    }
    incr count
    my state formCount $count
    return $count
  }

  # Redirect drawing into the form. The canvas stack in the core does the
  # work, so every existing method - shapes, text, even a nested form - keeps
  # working inside a form without knowing that forms exist.
  # A form is a content stream of its own, and an MCID is unique per STREAM,
  # not per page. Marking inside one would put numbers into the tree that the
  # page's stream does not have, and the XObject would need a StructParents
  # entry of its own (14.7.5.2). So the marking is suspended while the body
  # runs, and [FormPlace] brackets the invocation instead - which is also the
  # arrangement the norm names first: the whole Do inside one sequence, and
  # none inside the XObject.
  method FormBegin {width height} {
    my state structureFormSuspend [my state structureSuspend]
    my state structureSuspend 1
    my canvas push $width $height
    return
  }

  method FormEnd {} {
    my state structureSuspend [my state structureFormSuspend]
    return [my canvas pop]
  }
}

package provide tclpdf::xObject 1.4