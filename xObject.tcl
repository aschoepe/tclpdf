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
    lassign [my extent [dict get $options size] [dict get $options unit]] \
        widthPoints heightPoints

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
    # shape against the page. The group colour space is DeviceRGB, the space
    # this writer paints with by default and the one the default sRGB output
    # intent describes (ISO 19005-2, 6.2.4.3 wants them consistent); a
    # document painting in CMYK still composites correctly through an RGB
    # group, only the blending happens in RGB. Optional for an isolated
    # group on a page, but stating it keeps every reader on the same space.
    #
    # Groups exist since PDF 1.4 - a document set to an older version gets
    # none, and -opacity then acts per object as before.
    if {[package vcompare [[my writer] version] 1.4] >= 0} {
      lappend pairs Group [::tclpdf::pdfObj dictionary \
          {S /Transparency CS /DeviceRGB I true}]
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
    # The alpha is checked - and its ExtGState made - before anything is
    # written: refused after [save] it left a q without its Q in the stream
    # (measured, "q\n" and nothing else). [GraphicsOpacity] refuses first
    # and creates second, so a bad value leaves no resource either.
    set alpha {}
    if {[dict get $options opacity] ne {}} {
      set alpha [my GraphicsOpacity [dict get $options opacity]]
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
    # place on the page.
    lassign [my GraphicMark form "form place" [dict get $options alt] \
        [dict get $options artifact] [expr {[dict get $options at] eq {} ?
        0 : [lindex [dict get $options at] 1]}]] mark element
    lassign [expr {[dict get $options at] eq {} ? {0 0} : [dict get $options at]}] x y

    # -at names the TOP left corner, like rect - so the placement matches how
    # the rest of the API is used, even though the form's own origin is at its
    # bottom left.
    set height [dict get $form height]
    set heightUnit [::tclpdf::geometry fromPoints $height [my cget -unit]]
    lassign [my coords $x [expr {$y + $heightUnit * [dict get $options scale]}]] px py

    my save
    if {$alpha ne {}} {
      my content "[::tclpdf::pdfObj name $alpha] gs\n"
    }
    set matrix [::tclpdf::geometry translate $px $py]
    if {[dict get $options rotate] != 0} {
      set matrix [::tclpdf::geometry multiply \
          [::tclpdf::geometry rotate [dict get $options rotate]] $matrix]
    }
    if {[dict get $options scale] != 1} {
      set matrix [::tclpdf::geometry multiply \
          [::tclpdf::geometry scale [dict get $options scale]] $matrix]
    }
    my content "[join [lmap number $matrix {::tclpdf::pdfObj num $number}] { }] cm\n"
    my content "[::tclpdf::pdfObj name [dict get $form resource]] Do\n"
    my restore
    my GraphicUnmark $mark $element
    return $name
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

package provide tclpdf::xObject 1.1
