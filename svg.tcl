#
# tclpdf - PDF generation for Tcl
#
# svg - drawing SVG as real vectors
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
#   $doc svg logo.svg -at {20 20} -width 40
#   $doc svg -data $markup -at {20 70} -size {60 30}
#
# Every path becomes PDF path operators rather than a rasterised picture, so
# the logo stays sharp at any zoom and the file stays small. That is the whole
# reason this module exists: a drawing embedded as a JPEG is a photograph of a
# drawing, and it can neither be scaled nor searched.
#
# What is covered was decided by measurement, not by reading the standard:
# 14995 SVG files on this machine, 300 of them in detail. The elliptical arc
# is the most frequent path command of all - ahead of moveto - and PDF has no
# arc operator, so that is where the work went.
#
# THAT COUNT HAS BEEN CORRECTED TWICE, and the second correction is the
# instructive one. The first reading was "<filter> and <animate> occur ZERO
# times, <mask> twice" - taken over a corpus that is 95.5 % three icon
# libraries (Tabler in two releases, FontAwesome), which are single-path
# files by construction. Taking those out left a SAMPLE of 167 files, and
# percentages of it read as "clipPath 7.8 %, mask 6.0 %, filter 4.2 %" -
# which became "twenty to forty times more frequent than first measured".
#
# Counted absolutely on 2026-08-25, over all 15046 SVG files on this machine
# and in both spellings - the element and the attribute, which agree:
#
#   clipPath   33 files    inside them 184 rect, 3 path, 1 polygon; not one
#                          carries a transform, and all 181 clipPathUnits
#                          say userSpaceOnUse
#   mask        4 files    all four maskUnits userSpaceOnUse
#   filter      2 files    the same publisher's documentation logo twice,
#                          and feColorMatrix is the only primitive in either
#
# The sample had excluded a 492-file collection in which 24 of the 33 clip
# paths live: clip-path came out too LOW and the other two too high. What
# follows from the real numbers is that the first two are worth building and
# the third is not - a per-pixel operation PDF has no operator for, in two
# files. Clip paths and masks are built (svgClip.tcl); filters are reported.
#
# What [svg info] was missing until 2026-08-24 is described at
# [SvgCountOnly]: everything under <defs> went uncounted, which is exactly
# where a filter and a mask are declared.
#
#   shapes      path, rect (rx/ry included), circle, ellipse, line, polyline,
#               polygon - all through the same painting code, so none of them
#               can drift from <path>
#   structure   g, svg, a, switch, defs, use, symbol; title/desc/metadata and
#               script are skipped on purpose
#   painting    fill, stroke, stroke-width, stroke-linecap, stroke-linejoin,
#               stroke-dasharray, fill-opacity, stroke-opacity, opacity
#               (a shape's own value as the product with the two; a group
#               element below one becomes a transparency group, so its
#               children overlap without darkening - SvgGroup in
#               svgElement.tcl), fill-rule, display, and the same set
#               inside a style="" attribute, which wins
#   geometry    transform (translate, scale, rotate about a point, skewX,
#               skewY, matrix), viewBox
#   visibility  clip-path and mask, both as the device PDF has for them: a
#               clipping path (W or W*, several shapes as subpaths of one)
#               and a luminosity soft mask, where the grey value IS the
#               alpha. userSpaceOnUse only - svgClip.tcl
#   fitting     preserveAspectRatio, all ten alignments with meet and slice,
#               and none. A caller's own -fitMode wins over the file's
#   text        text and tspan, with font-size, font-family (a list, first
#               name that resolves wins), font-weight (bold from 600 up),
#               text-anchor and fill
#   gradients   linearGradient and radialGradient through the shading module,
#               with objectBoundingBox (the default) measured against the
#               shape being filled, userSpaceOnUse, stops from attribute or
#               style, and one level of inheritance through href
#
# NOT covered, and each for a reason rather than by omission: filters and
# animation, CSS in a <style> block, spreadMethod and gradientTransform, and
# objectBoundingBox units for a clip path or a mask - which do not occur in
# the corpus at all. Every one of them is counted and reported by
# [svg info], so a caller can see what a drawing lost instead of finding out
# from the page.
#
# THE ONE THING THAT IS NOT REPORTABLE that way is an attribute, which is
# why preserveAspectRatio is read although no file on this machine carries
# one: an unknown ELEMENT can be counted, an ignored ATTRIBUTE leaves no
# trace anywhere. A drawing that said "slice" and came out centred looked
# like a drawing that had simply been placed.
#
# Anything else is skipped in silence, which is the right behaviour for a
# format where unknown elements are expected to be ignored (SVG 23.2) - but
# [$doc svg info] reports what was skipped, so it is not invisible.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::color 1.0-
package require tclpdf::geometry 1.0-
package require tclpdf::xml 1.0-
package require tclpdf::svgPath 1.0-
package require tclpdf::io 1.0-
package require tclpdf::afm 1.0-
package require tclpdf::text 1.0-
package require tclpdf::graphics 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::svg {
  namespace export {[a-z]*}
  namespace ensemble create

  # The properties that are inherited from a parent element (SVG 6.2). A
  # child that sets none of them draws exactly like its group - which is what
  # makes a grouped drawing come out right without walking back up the tree.
  # The coordinate transform handed to the path module. Inside a drawing the
  # coordinates are the SVG's own - the enclosing matrix does the mapping - so
  # this is the identity. A lambda rather than a method: TclOO does not export
  # a capitalised method, and the path module calls this once per point from
  # the global context.
  variable identity {apply {{x y} {list $x $y}}}

  variable inherited {
    fill stroke stroke-width stroke-linecap stroke-linejoin stroke-dasharray
    fill-opacity stroke-opacity fill-rule font-size font-family font-weight
    text-anchor
  }
}

oo::define ::tclpdf::document::document {

  # The drawing's own bracket count.
  #
  # [save] and [restore] write q and Q and keep no depth of their own, which is
  # right for a caller that pairs them itself. A drawing cannot: it walks a
  # tree of groups, each one bracketed, and it can stop anywhere in that tree.
  # So the two are counted here, and [svg] unwinds to zero however it leaves.
  method SvgSave {} {
    my state svgDepth [expr {[my state svgDepth] + 1}]
    my save
    return
  }

  method SvgRestore {} {
    my restore
    my state svgDepth [expr {[my state svgDepth] - 1}]
    return
  }

  # $doc svg <path> ?options?
  # $doc svg -data <markup> ?options?
  # $doc svg size <path>          -> the drawing's own size
  # $doc svg info                 -> what the last drawing skipped
  method svg {args} {
    if {[llength $args] && [lindex $args 0] eq "size"} {
      return [my SvgSize [lindex $args 1]]
    }
    if {[llength $args] && [lindex $args 0] eq "info"} {
      return [my state svgSkipped]
    }
    set path {}
    if {[llength $args] % 2} {
      set path [lindex $args 0]
      set args [lrange $args 1 end]
    }
    return [my SvgDraw $path $args]
  }

  method SvgDraw {path arguments} {
    set options [::tclpdf::option parse {
      data {} at {} size {} width {} height {} scale {} opacity {} alt {}
      artifact {} fit {} fitMode {} align center valign middle
    } $arguments "svg"]
    # WHICH OPTIONS THE CALLER NAMED, as opposed to which ones carry a
    # default. preserveAspectRatio has to yield to the caller and only to the
    # caller - and -align/-valign default to center/middle, so their VALUE
    # cannot tell the two apart. Without this list the file could never
    # decide anything, which is what made the attribute inert under -fit.
    dict set options given [lmap word $arguments {
      if {[string index $word 0] ne "-"} continue
      string range $word 1 end
    }]
    if {$path ne {}} {
      # Read as bytes, then decode: an SVG is UTF-8 unless its declaration
      # says otherwise (XML 4.3.3). Reading it as text would use the system
      # encoding, and a middle dot would come out as two characters - which
      # is exactly what happened before this line existed.
      set markup [my SvgDecode [::tclpdf::io read $path]]
    } elseif {[dict get $options data] ne {}} {
      set markup [dict get $options data]
    } else {
      return -code error -errorcode [list TCLPDF SVG ARGUMENT source] \
          "tclpdf: svg needs a file name or -data"
    }
    # The handle has to be released whatever happens - a tdom document is not
    # freed by itself, and an error while drawing would otherwise leak the
    # whole tree.
    # A drawing is one piece of marked content, like a picture: a Figure when
    # -alt describes it, an artifact otherwise. Bracketing per element would
    # scatter one illustration over dozens of leaves, and the elements of an
    # SVG mean nothing on their own.
    #
    # An artifact nobody asked for is remembered, as image.tcl does for a
    # picture: -artifact 1 says the drawing is decoration on purpose, and
    # without it or -alt the caller has not said - see [undescribedGraphics].
    # The marking itself is [GraphicMark] in image.tcl, shared with the
    # picture and the form placement; the top edge of -at is where the
    # placement begins, so that a destination at the Figure can name the
    # place on the page.
    # The alpha is checked - and its ExtGState made - before the mark and
    # the "q" are out: refused inside [SvgRoot] it left a q and the mark's
    # BDC/EMC around nothing. Same order as [FormPlace] in xObject.tcl; the
    # option carries the resource name from here on. -at and the sizes are
    # checked here too, before the mark: a bad corner used to leave an
    # empty BDC/EMC pair, and a zero -scale or a negative -width went into
    # the drawing's cm as a singular or a mirroring matrix (geometry.tcl,
    # checkFit). And the markup is PARSED before the mark as well: parsed
    # after it, markup that does not parse left the BDC and the -alt Figure
    # open, and whatever was drawn next became a child of that dead Figure.
    if {[dict get $options at] ne {}} {
      my GraphicsPoint [dict get $options at] -at svg
    }
    ::tclpdf::geometry checkFit $options svg
    # -fit and the anchors, through the same [fitCheck] the picture and the
    # form use. Added on 2026-08-24: a drawing already fitted itself into the
    # rectangle it was given - "xMidYMid meet", the default of
    # preserveAspectRatio - but the rectangle had to be named as a size, and
    # cover was not reachable at all.
    my fitCheck $options svg
    if {[dict get $options opacity] ne {}} {
      dict set options opacity [my GraphicsOpacity [dict get $options opacity]]
    }
    set root [::tclpdf::xml parse $markup]
    try {
      # Where the drawing will land, worked out before the mark: a Figure
      # carries the area it covers as an attribute (ISO 32000-2, 14.8.5.4.3),
      # and an attribute is fixed when the element is OPENED, which is what
      # the mark does. Handed on to [SvgRoot] rather than computed twice, so
      # that the box and the drawing's own matrix are the same numbers and
      # not two computations that agree today.
      # The tally is cleared HERE and not in [SvgRoot], which is where it
      # used to be: [SvgFit] reads preserveAspectRatio and can already have
      # something to report, and a reset after it threw that away - the one
      # refusal the attribute has went missing between the two calls.
      my state svgSkipped {}
      set fit [my SvgFit $root $options]
      lassign [my GraphicMark svg svg [dict get $options alt] \
          [dict get $options artifact] [expr {[dict get $options at] eq {} ?
          0 : [lindex [dict get $options at] 1]}] \
          [dict get $fit visible]] mark element
      try {
        return [my SvgRoot $root $options $fit]
      } finally {
        my GraphicUnmark $mark $element
      }
    } finally {
      ::tclpdf::xml release $root
    }
  }

  # Where a drawing lands, before a stroke of it is written: the viewBox, the
  # rectangle asked for, and the fit of the one into the other. Its own method
  # because the Figure's bounding box has to be known BEFORE the mark opens
  # the element - see [SvgDraw] - while the matrix built from the same numbers
  # is not written until [SvgRoot].
  #
  # Answers a dictionary: box {x y width height} is the viewBox in its own
  # units, extent {width height} and at {left top} the rectangle asked for in
  # the document unit, scale the factor onto it, inset {x y} and drawn
  # {width height} the fit in points, and area {left top width height} where
  # the drawing ACTUALLY ends up, in the document unit.
  # preserveAspectRatio, as the pair the fitting works with.
  #
  #   ?defer? <align> ?meet|slice?
  #
  # The caller's own options WIN over the file's: a script that says
  # -fitMode cover has asked for a covered box in this document, and a
  # drawing carrying "meet" must not quietly undo it. Without -fitMode the
  # file decides, and without either it is the default of both - meet.
  #
  # "defer" applies to a <use> pointing at an <image>, which this package
  # does not draw, so it is accepted and ignored rather than refused.
  method SvgAspect {root options} {
    set mode [dict get $options fitMode]
    if {$mode ne {}} {
      return [list xMidYMid [expr {$mode eq "cover" ? {slice} : {meet}}]]
    }
    set value [string trim [::tclpdf::xml attribute $root preserveAspectRatio]]
    if {$value eq {}} {
      return {xMidYMid meet}
    }
    set words [lrange [regexp -all -inline {[^\s]+} $value] 0 end]
    if {[lindex $words 0] eq "defer"} {
      set words [lrange $words 1 end]
    }
    set align [lindex $words 0]
    set meetOrSlice [lindex $words 1]
    if {$meetOrSlice eq {}} {
      set meetOrSlice meet
    }
    # An unreadable value is the default, which is what SVG 1.1 asks for
    # (7.8: "a value in error ... shall be the default"). Counted, because a
    # drawing whose fitting silently differs from what it says is exactly
    # what reading the attribute was meant to prevent.
    if {$align ni {none xMinYMin xMidYMin xMaxYMin xMinYMid xMidYMid xMaxYMid
        xMinYMax xMidYMax xMaxYMax} || $meetOrSlice ni {meet slice}} {
      my SvgSkipped preserveAspectRatio
      return {xMidYMid meet}
    }
    return [list $align $meetOrSlice]
  }

  # Which fraction of the leftover goes in front of the drawing, per axis.
  # Min keeps the near edge, Max the far one, Mid splits it - and under
  # slice the leftover is negative, so the same three fractions crop from
  # the same three sides.
  # The alignment as the two words [fitAnchor] takes, so that a named box is
  # anchored by the same code a picture's is. "none" names no edge - it fills
  # the box - and neither does the middle, which is already the default.
  method SvgAspectEdges {align} {
    if {$align eq "none"} {
      return {{} {}}
    }
    if {![regexp {^x(Min|Mid|Max)Y(Min|Mid|Max)$} $align -> x y]} {
      return {{} {}}
    }
    return [list [dict get {Min left Mid center Max right} $x] \
        [dict get {Min top Mid middle Max bottom} $y]]
  }

  method SvgAspectShare {align} {
    if {$align eq "none"} {
      return {0 0}
    }
    set shares {Min 0 Mid 0.5 Max 1}
    regexp {^x(Min|Mid|Max)Y(Min|Mid|Max)$} $align -> x y
    return [list [dict get $shares $x] [dict get $shares $y]]
  }

  method SvgFit {root options} {
    lassign [my SvgViewBox $root] boxX boxY boxWidth boxHeight
    # THE ATTRIBUTE IS READ FIRST, and that order is the whole of it: with
    # -fit, [fitExtent] has already cut the named box down to the drawing's
    # proportions by the time the scales are worked out, so both axes carry
    # the same factor and meet, slice and none become the same arithmetic.
    # Measured on 2026-08-25: under -fit, "none" wrote the same bytes as no
    # attribute at all and "slice" wrote a clip around a drawing that fitted
    # inside it. The attribute feeds the OPTIONS instead, which is where the
    # fitting already knows what to do with it.
    lassign [my SvgAspect $root $options] align meetOrSlice
    set given [expr {[dict exists $options given] ? [dict get $options given] : {}}]
    if {[dict get $options fit] ne {}} {
      if {"fitMode" ni $given} {
        dict set options fitMode [expr {$meetOrSlice eq "slice" ? {cover} : {contain}}]
      }
      lassign [my SvgAspectEdges $align] edge vedge
      if {$edge ne {} && "align" ni $given} {
        dict set options align $edge
      }
      if {$vedge ne {} && "valign" ni $given} {
        dict set options valign $vedge
      }
    }
    lassign [my SvgExtent $root $options $boxWidth $boxHeight] width height
    if {$align eq "none" && [dict get $options fit] ne {}} {
      # The one spelling that fills the named box on both axes rather than
      # keeping the drawing's shape.
      lassign [dict get $options fit] width height
    }
    lassign [expr {[dict get $options at] eq {} ? {0 0} : [dict get $options at]}] left top

    # THE ANCHOR MOVES THE CORNER, not the inset - which is where a first
    # attempt at this went wrong on 2026-08-24. [fitExtent] has already cut
    # the rectangle down to the fitted size by the time the inset is worked
    # out, so there is nothing left over inside it to move: the room is in
    # the BOX the caller named, between it and the fitted drawing. Same
    # arithmetic and same defaults as a picture's, through the same method.
    #
    # center and middle are the defaults because "xMidYMid meet" is what a
    # drawing did before this option existed - so a script written earlier
    # writes the same bytes, and only a caller who names an edge moves it.
    if {[dict get $options fit] ne {}} {
      lassign [my fitAnchor [list $left $top] $width $height $options] left top
    }

    # Fit, do not distort - and preserveAspectRatio is the attribute that
    # says how. Its default is "xMidYMid meet": the drawing keeps its
    # proportions, is scaled until it fits the rectangle in BOTH directions,
    # and is centred in what is left over.
    #
    # WHY IT IS READ AT ALL, given that it occurs in none of the 15046 files
    # measured on this machine on 2026-08-25: because it fails SILENTLY. An
    # element this package does not know is counted and [svg info] reports
    # it; an ATTRIBUTE it ignores leaves no trace anywhere - the drawing
    # simply comes out centred where the file said "slice" and cropped. That
    # is the one kind of omission this package does not allow itself, and
    # the arithmetic is the same min/max the pictures already use.
    #
    # Distorting is what "none" asks for and nothing else does: it turns a
    # circle into an ellipse whenever the rectangle has a different shape
    # than the viewBox, so it happens only where the file says so.
    # (align and meetOrSlice come from the ONE reading at the top of this
    # method. Asking a second time here would re-read the -fitMode that the
    # top just derived from the attribute, and "none" would come back as
    # "xMidYMid meet" - measured 2026-08-25, and the reason the attribute
    # looked inert twice over.)
    set requestedWidth [my distance $width]
    set requestedHeight [my distance $height]
    set fullX [expr {$requestedWidth / double($boxWidth)}]
    set fullY [expr {$requestedHeight / double($boxHeight)}]
    switch -- $align {
      none {
        # Each axis takes its own factor - the one case where the drawing
        # is stretched, and the file asked for it.
        set scaleX $fullX
        set scaleY $fullY
      }
      default {
        # meet fits inside the rectangle, slice covers it and hangs over.
        set scaleX [expr {$meetOrSlice eq "slice" ? max($fullX, $fullY)
            : min($fullX, $fullY)}]
        set scaleY $scaleX
      }
    }
    set scale $scaleX
    set drawnWidth [expr {$boxWidth * $scaleX}]
    set drawnHeight [expr {$boxHeight * $scaleY}]
    # Where the leftover goes - or, under slice, which part is cut off. Min
    # keeps the near edge, Max the far one, Mid splits it: that is the whole
    # of the ten alignment spellings, one fraction per axis.
    lassign [my SvgAspectShare $align] shareX shareY
    set insetX [expr {($requestedWidth - $drawnWidth) * $shareX}]
    set insetY [expr {($requestedHeight - $drawnHeight) * $shareY}]
    set unit [my cget -unit]
    # The area is the FITTED rectangle, not the one asked for: once a drawing
    # is fitted rather than stretched it is smaller than the rectangle and
    # sits centred in it, and the empty bands beside it are not the figure.
    #
    # AND UNDER SLICE IT IS CUT BACK, because there the drawing is LARGER
    # than the box and hangs over it. What hangs over is clipped away in
    # SvgRoot and no reader ever sees it, so 14.8.5.4.3 - the rectangle
    # enclosing the visible content - does not include it. Measured
    # 2026-08-25: a 2:1 drawing covered into a 40 mm box answered a box
    # reaching to x = -113 pt, over the left edge of the paper, while the
    # picture road at the same call answered the box. The same number is
    # what [svg] hands the caller for the caption.
    return [dict create \
        box [list $boxX $boxY $boxWidth $boxHeight] \
        extent [list $width $height] at [list $left $top] scale $scale \
        scaleX $scaleX scaleY $scaleY aspect [list $align $meetOrSlice] \
        inset [list $insetX $insetY] drawn [list $drawnWidth $drawnHeight] \
        area [list \
            [expr {$left + [::tclpdf::geometry fromPoints $insetX $unit]}] \
            [expr {$top + [::tclpdf::geometry fromPoints $insetY $unit]}] \
            [::tclpdf::geometry fromPoints $drawnWidth $unit] \
            [::tclpdf::geometry fromPoints $drawnHeight $unit]] \
        visible [my boxClipped [list \
            [expr {$left + [::tclpdf::geometry fromPoints $insetX $unit]}] \
            [expr {$top + [::tclpdf::geometry fromPoints $insetY $unit]}] \
            [::tclpdf::geometry fromPoints $drawnWidth $unit] \
            [::tclpdf::geometry fromPoints $drawnHeight $unit]] \
            [expr {$meetOrSlice eq "slice"
                ? [list {*}[expr {[dict get $options fit] eq {}
                    ? [list $left $top] : [dict get $options at]}] \
                  {*}[expr {[dict get $options fit] eq {}
                    ? [list $width $height] : [dict get $options fit]}]]
                : {}}]]]
  }

  method SvgRoot {root options fit} {
    if {[::tclpdf::xml name $root] ni {svg svg:svg}} {
      return -code error -errorcode [list TCLPDF SVG ROOT element] \
          "tclpdf: this is not an SVG document - the root\
          element is \"[::tclpdf::xml name $root]\""
    }
    lassign [dict get $fit box] boxX boxY boxWidth boxHeight
    lassign [dict get $fit drawn] drawnWidth drawnHeight
    lassign [dict get $fit area] areaLeft areaTop areaWidth areaHeight
    # One factor per axis: they differ only where preserveAspectRatio says
    # "none", which is the one spelling that stretches.
    set scaleX [dict get $fit scaleX]
    set scaleY [dict get $fit scaleY]

    # Everything is drawn inside one q/Q pair with a single matrix that maps
    # the viewBox onto the requested rectangle. The y axis is flipped HERE and
    # nowhere else: SVG counts downwards from the top left, PDF upwards from
    # the bottom left, and doing it per element is how half a drawing ends up
    # mirrored.
    #
    # The origin is the BOTTOM left corner of the area the drawing was fitted
    # into - the same rectangle the Figure carries, read off [SvgFit] rather
    # than added up a second time from the corner and the inset.
    lassign [my coords $areaLeft [expr {$areaTop + $areaHeight}]] originX originY

    my state svgDepth 0
    my SvgSave
    # A COVERED BOX IS CUT BACK TO THE BOX, exactly as a picture's and a form
    # placement's are: -fitMode cover scales the drawing until both edges are
    # covered, which leaves it hanging over the box on one axis, and the box
    # is what the caller asked to see. The rectangle is the one -at and -fit
    # name, before the anchor moved the drawing inside it. Inside the save,
    # so the matching restore takes it back - a clipping path lasts to the
    # end of the content stream otherwise.
    # SLICE IS THE SAME CASE and is cut back the same way, whether the
    # caller asked for it with -fitMode cover or the drawing asked for it
    # with preserveAspectRatio. Without -fit there is no named box, so what
    # is cut back to is the extent the drawing was given.
    lassign [dict get $fit aspect] -> meetOrSlice
    if {$meetOrSlice eq "slice"} {
      lassign [expr {[dict get $options at] eq {} ? {0 0}
          : [dict get $options at]}] clipLeft clipTop
      set clipSize [dict get $options fit]
      if {$clipSize eq {}} {
        set clipSize [dict get $fit extent]
      }
      my clip -at [list $clipLeft $clipTop] -size $clipSize
    }
    if {[dict get $options opacity] ne {}} {
      my content "[::tclpdf::pdfObj name [dict get $options opacity]] gs\n"
    }
    my content "[::tclpdf::pdfObj num $scaleX] 0 0\
        [::tclpdf::pdfObj num [expr {-$scaleY}]]\
        [::tclpdf::pdfObj num [expr {$originX - $boxX * $scaleX}]]\
        [::tclpdf::pdfObj num [expr {$originY + $drawnHeight +
            $boxY * $scaleY}]] cm\n"

    # The drawing's matrix, kept for the gradients: a pattern is bound to the
    # page's default space and would otherwise sit outside the shape it fills.
    my state svgBox [list $boxX $boxY $boxWidth $boxHeight]
    my state svgGradients {}
    # AND THE MASKS WITH THEM, for the reason svgPaint.tcl records for the
    # gradients: the cache is keyed on the SVG id, and two drawings in one
    # document may each carry a mask called "m" that means something
    # different. Left standing, the second drawing was handed the first
    # one's mask - measured 2026-08-25, both wrote /svgMask1.
    my state svgMaskNames {}
    # No transparency group is being captured yet - and none may be left
    # over from a drawing that failed halfway.
    my state svgGroupStack {}
    my state svgTransform [::tclpdf::geometry identity]
    my state svgMatrix [list $scaleX 0 0 [expr {-$scaleY}] \
        [expr {$originX - $boxX * $scaleX}] \
        [expr {$originY + $drawnHeight + $boxY * $scaleY}]]

    # Reusable pieces are collected first: a <use> may point forward.
    my state svgDefs [my SvgCollect $root [dict create]]
    # Whatever the drawing opened is closed even when it stops halfway. A
    # drawing CAN stop halfway - a face without the character asked for is the
    # usual reason - and until this was here, a caught error left the flipping
    # matrix in force: everything drawn afterwards came out upside down and
    # magnified, on a page that no tool complains about. The error is passed
    # on unchanged; only the brackets are settled.
    try {
      my SvgElement $root [dict create fill black stroke none]
    } finally {
      while {[my state svgDepth] > 0} {
        my SvgRestore
      }
    }
    # WHAT A READER SEES, not what was drawn - the two differ under slice,
    # where the drawing is larger than the box and the rest is clipped away.
    # Fitted rather than stretched it is the other way round: smaller than
    # the rectangle and centred in it. Either way a caller placing a caption
    # underneath needs the visible rectangle, and it is the same four
    # numbers the Figure got as its bounding box. The box the drawing is
    # PLACED in is the unclipped one, [dict get $fit area], and mixing the
    # two up glues the drawing to the corner of its box - measured on
    # 2026-08-25, caught by svg-aspect-30.7.
    return [dict get $fit visible]
  }

  # Decode a document according to its XML declaration, UTF-8 by default.
  method SvgDecode {bytes} {
    set encoding utf-8
    if {[regexp {<\?xml[^>]*encoding\s*=\s*["']([^"']+)["']} $bytes -> declared]} {
      set declared [string tolower $declared]
      # Only the two that occur: anything else is left as bytes rather than
      # guessed at, and shows up as mojibake instead of throwing.
      if {$declared in {iso-8859-1 latin1 iso8859-1}} {
        set encoding iso8859-1
      } elseif {$declared ni {utf-8 utf8}} {
        return $bytes
      }
    }
    if {[catch {encoding convertfrom $encoding $bytes} text]} {
      return $bytes
    }
    return $text
  }

  # The drawing's own size, for a caller who wants to place it unscaled.
  method SvgSize {path} {
    set root [::tclpdf::xml parse [my SvgDecode [::tclpdf::io read $path]]]
    try {
      lassign [my SvgViewBox $root] -> -> width height
    } finally {
      ::tclpdf::xml release $root
    }
    set unit [my cget -unit]
    return [list [::tclpdf::geometry fromPoints $width $unit] \
        [::tclpdf::geometry fromPoints $height $unit]]
  }

  # The user coordinate system: viewBox if there is one, otherwise the
  # width/height attributes, otherwise a square that at least draws something.
  method SvgViewBox {root} {
    set box [::tclpdf::xml attribute $root viewBox]
    if {$box ne {}} {
      lassign [regexp -all -inline {[-+0-9.eE]+} $box] x y width height
      if {$width > 0 && $height > 0} {
        return [list $x $y $width $height]
      }
    }
    set width [my SvgLength [::tclpdf::xml attribute $root width] 100]
    set height [my SvgLength [::tclpdf::xml attribute $root height] 100]
    return [list 0 0 $width $height]
  }

  method SvgExtent {root options boxWidth boxHeight} {
    set unit [my cget -unit]
    return [my fitExtent [::tclpdf::geometry fromPoints $boxWidth $unit] \
        [::tclpdf::geometry fromPoints $boxHeight $unit] $options]
  }

  # Everything with an id, for <use> to point at.

  method SvgFraction {value extent origin} {
    if {[string match {*%} $value]} {
      return [expr {$origin + [string trimright $value %] / 100.0 * $extent}]
    }
    if {![string is double -strict $value]} {
      return $origin
    }
    # Without units a number is a fraction (0..1) in the default mode and a
    # length in userSpaceOnUse - told apart by whether it stays inside 0..1,
    # which is what every drawing in the corpus relies on.
    if {$value >= 0 && $value <= 1} {
      return [expr {$origin + $value * $extent}]
    }
    return $value
  }

  # transform="" as a PDF matrix. Several functions compose left to right.
  method SvgTransform {text} {
    set matrix [::tclpdf::geometry identity]
    foreach {-> function arguments} [regexp -all -inline \
        {([a-zA-Z]+)\s*\(([^)]*)\)} $text] {
      set numbers [regexp -all -inline {[-+0-9.eE]+} $arguments]
      switch -- $function {
        translate {
          lassign $numbers tx ty
          set step [::tclpdf::geometry translate $tx [expr {$ty eq {} ? 0 : $ty}]]
        }
        scale {
          lassign $numbers sx sy
          set step [list $sx 0 0 [expr {$sy eq {} ? $sx : $sy}] 0 0]
        }
        rotate {
          lassign $numbers angle cx cy
          # A rotation about a point is three matrices - the same trap that
          # put a rotated shape off the page in stage 1.
          set step [::tclpdf::geometry rotate [expr {-$angle}]]
          if {$cx ne {}} {
            set step [::tclpdf::geometry multiply \
                [::tclpdf::geometry translate [expr {-$cx}] [expr {-$cy}]] \
                [::tclpdf::geometry multiply $step \
                    [::tclpdf::geometry translate $cx $cy]]]
          }
        }
        skewX {set step [::tclpdf::geometry skew [lindex $numbers 0] 0]}
        skewY {set step [::tclpdf::geometry skew 0 [lindex $numbers 0]]}
        matrix {set step $numbers}
        default {continue}
      }
      set matrix [::tclpdf::geometry multiply $step $matrix]
    }
    return $matrix
  }

  # A length with an optional unit. Percentages are not resolved - they need
  # the viewport, and every one measured was on the root element, which is
  # handled separately.
  method SvgLength {value {default 0}} {
    if {$value eq {} || $value eq "none"} {
      return $default
    }
    if {![regexp {^\s*([-+0-9.eE]+)\s*([a-z%]*)\s*$} $value -> number unit]} {
      return $default
    }
    switch -- $unit {
      {} - px - "" {return $number}
      pt {return [expr {$number * 96.0 / 72}]}
      mm {return [expr {$number * 96.0 / 25.4}]}
      cm {return [expr {$number * 96.0 / 2.54}]}
      in {return [expr {$number * 96.0}]}
      pc {return [expr {$number * 16.0}]}
    }
    return $number
  }
}

package provide tclpdf::svg 1.10