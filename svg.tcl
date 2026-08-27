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
#   painting    fill, stroke, stroke-width (a zero width paints no stroke,
#               SVG 11.4), stroke-linecap, stroke-linejoin, stroke-miterlimit
#               (whose initial value is 4 in SVG and 10 in PDF, so it is
#               always written), stroke-dasharray, stroke-dashoffset,
#               fill-opacity, stroke-opacity, opacity (a shape's own value as
#               the product with the two; a group element below one becomes a
#               transparency group, so its children overlap without darkening
#               - SvgGroup in svgElement.tcl), fill-rule, color and the
#               keyword currentColor, display, visibility, and the same set
#               inside a style="" attribute, which wins - !important and a
#               /* comment */ are stripped from a declaration rather than
#               taken for part of its value
#   geometry    transform (translate, scale, rotate about a point, skewX,
#               skewY, matrix), viewBox (a zero width or height there
#               disables the drawing, SVG 7.7), the viewport of a nested
#               <svg> and of a <symbol> reached through <use>, and lengths
#               with their units - px, pt, mm, cm, in, pc, em, ex and per
#               cent against the current viewport (SVG 4.2 and 7.10)
#   visibility  clip-path and mask, both as the device PDF has for them: a
#               clipping path (W or W*, several shapes as subpaths of one)
#               and a luminosity soft mask, where the grey value IS the
#               alpha - converted with the coefficients SVG 14.4 names, not
#               the ones a reader would use. userSpaceOnUse only - svgClip.tcl
#   fitting     preserveAspectRatio, all ten alignments with meet and slice,
#               and none. A caller's own -fitMode wins over the file's
#   text        text and tspan in document order, each tspan with its own
#               position and its own painting attributes, font-size,
#               font-family (a list, first name that resolves wins),
#               font-weight (bold from 600 up), text-anchor and fill; white
#               space is collapsed as XML 10.15 asks unless xml:space says
#               preserve
#   gradients   linearGradient and radialGradient through the shading module,
#               with objectBoundingBox (the default) measured against the
#               shape being filled - as an ELLIPSE on a box that is not
#               square (13.2.3) - userSpaceOnUse, stops from attribute or
#               style, offsets clamped into order the way 13.2.4 prescribes,
#               a single stop as a solid colour, and inheritance through
#               href of the stops AND of every attribute the element itself
#               does not state
#   switch      <switch> renders the first child whose requiredFeatures,
#               requiredExtensions and systemLanguage all hold (SVG 5.8)
#
# NOT covered, and each for a reason rather than by omission: filters and
# animation, CSS in a <style> block, spreadMethod and gradientTransform, and
# objectBoundingBox units for a clip path or a mask - which do not occur in
# the corpus at all. Every one of them is counted and reported by
# [svg info], so a caller can see what a drawing lost instead of finding out
# from the page. That sentence was HALF TRUE until 2026-08-27, and the half
# that was false is the reason it is spelled out here: a <style> block, a
# spreadMethod and a gradientTransform went by in silence, because two of
# them are attributes and the third stood in the list of elements this
# module has a case for. All three are counted now.
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
    fill stroke stroke-width stroke-linecap stroke-linejoin stroke-miterlimit
    stroke-dasharray stroke-dashoffset fill-opacity stroke-opacity fill-rule
    font-size font-family font-weight text-anchor color visibility
  }

  # How deep a <use> may nest, and how many elements the whole unfolding may
  # produce. Neither number is in the standard - SVG 1.1, 5.6 only calls a
  # cycle an error - and both are here for AVAILABILITY: a ten-level <use>
  # over ten copies each is 10^10 rectangles out of two kilobytes of markup,
  # and measured on 2026-08-27 thirteen levels already cost 6.8 s. Browsers
  # draw a line in the same place; twenty-five levels is past everything the
  # corpus contains, where the deepest file nests three.
  variable useDepthLimit 25
  variable useCountLimit 20000
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
    # The XML reader speaks its own language: tdom answers a malformed
    # document with "error ... at line 1 character 4" and an -errorcode of
    # NONE - measured 2026-08-26 on "-data {<svg}" - against the promise
    # that every refusal of this package begins with "tclpdf:" and carries a
    # TCLPDF code. Wrapped here rather than in xml.tcl because that module
    # serves XMP and ZUGFeRD as well, and each of them names its own topic.
    if {[catch {::tclpdf::xml parse $markup} root outcome]} {
      if {[lindex [dict get $outcome -errorcode] 0] ne "TCLPDF"} {
        return -code error -errorcode {TCLPDF SVG XML MALFORMED} \
            "tclpdf: the drawing is not well-formed XML - $root"
      }
      return -options $outcome $root
    }
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
      # EVERYTHING THAT CAN STILL REFUSE, ASKED BEFORE THE MARK. A colour
      # this package will not paint - a component that is a double but not a
      # finite one, a spelling [color parse] cannot read - used to be found
      # per element, while the elements before it were already on the page:
      # the drawing came out half done, and in a tagged document a Figure
      # with the caller's -alt stood around the fragment, describing a
      # picture that is not there. No validator sees that (measured
      # 2026-08-27: q/Q, BDC/EMC balanced, veraPDF ua1 conformant), and a
      # screen reader reads the description out. So the tree is walked once
      # for its paint values first, and a refusal then leaves the page
      # exactly as it was - the rule [pdf import] states as "every question
      # is asked before the first object number is handed out".
      #
      # The defs go with it, because the <use> cycle check needs them and it
      # belongs on the same side of the mark.
      my state svgDefs [my SvgCollect $root [dict create]]
      my SvgCheck $root
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
    # A viewBox of no area draws nothing (7.7). The arithmetic below divides
    # by both extents, so a substitute stands in for them and "render" is what
    # [SvgRoot] reads: the drawing is skipped and the caller is handed the
    # empty rectangle at -at. A NEGATIVE extent is an error and is reported;
    # a zero one is the norm's own answer and is not an omission - the same
    # distinction [SvgShape] makes for a rectangle's width.
    set render 1
    if {!([string is double -strict $boxWidth] &&
        [string is double -strict $boxHeight]) ||
        $boxWidth <= 0 || $boxHeight <= 0} {
      if {[string is double -strict $boxWidth] &&
          [string is double -strict $boxHeight] &&
          ($boxWidth < 0 || $boxHeight < 0)} {
        my SvgSkipped viewBox
      }
      set render 0
      set boxWidth 1
      set boxHeight 1
    }
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
    # AND IT GOES THROUGH THE ACTIVE CTM, which is the half of round 8's
    # Nr. 63 that belongs to this module. A drawing placed under [transform
    # -translate {50 0}] stands 50 mm further along, and both numbers this
    # method hands out - the one the caller is given back and the one the
    # Figure carries as its /BBox (ISO 32000-2, 14.8.5.4.3) - said where the
    # drawing would have been WITHOUT the transform. Clip first, then the
    # CTM: the clip is stated in the caller's own space, which the CTM maps.
    # [ctmBox] is page.tcl's, and it hands an untransformed box straight back.
    #
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
    if {!$render} {
      # Nothing is drawn, so nothing is visible: the answer is the empty
      # rectangle at the corner the caller named.
      return [dict create render 0 \
          box [list $boxX $boxY $boxWidth $boxHeight] \
          extent [list $width $height] at [list $left $top] scale $scale \
          scaleX $scaleX scaleY $scaleY aspect [list $align $meetOrSlice] \
          inset {0 0} drawn {0 0} area [list $left $top 0 0] \
          visible [my ctmBox [list $left $top 0 0]]]
    }
    return [dict create render 1 \
        box [list $boxX $boxY $boxWidth $boxHeight] \
        extent [list $width $height] at [list $left $top] scale $scale \
        scaleX $scaleX scaleY $scaleY aspect [list $align $meetOrSlice] \
        inset [list $insetX $insetY] drawn [list $drawnWidth $drawnHeight] \
        area [list \
            [expr {$left + [::tclpdf::geometry fromPoints $insetX $unit]}] \
            [expr {$top + [::tclpdf::geometry fromPoints $insetY $unit]}] \
            [::tclpdf::geometry fromPoints $drawnWidth $unit] \
            [::tclpdf::geometry fromPoints $drawnHeight $unit]] \
        visible [my ctmBox [my boxClipped [list \
            [expr {$left + [::tclpdf::geometry fromPoints $insetX $unit]}] \
            [expr {$top + [::tclpdf::geometry fromPoints $insetY $unit]}] \
            [::tclpdf::geometry fromPoints $drawnWidth $unit] \
            [::tclpdf::geometry fromPoints $drawnHeight $unit]] \
            [expr {$meetOrSlice eq "slice"
                ? [list {*}[expr {[dict get $options fit] eq {}
                    ? [list $left $top] : [dict get $options at]}] \
                  {*}[expr {[dict get $options fit] eq {}
                    ? [list $width $height] : [dict get $options fit]}]]
                : {}}]]]]
  }

  method SvgRoot {root options fit} {
    if {[::tclpdf::xml name $root] ni {svg svg:svg}} {
      return -code error -errorcode [list TCLPDF SVG ROOT element] \
          "tclpdf: this is not an SVG document - the root\
          element is \"[::tclpdf::xml name $root]\""
    }
    if {![dict get $fit render]} {
      # A viewBox with a zero extent (7.7). Nothing is written at all - not
      # even the drawing's own q/Q - so the page is exactly as it was.
      return [dict get $fit visible]
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
    # The viewport a per cent is measured against, and the font size an em
    # is (SVG 7.10, CSS 2.1 15.7). A nested <svg> or a <symbol> replaces the
    # first for its subtree; the element walk pushes and pops the second.
    my state svgViewport [list $boxWidth $boxHeight]
    my state svgFontSize 16
    # No <use> is open, and none of the two cycle guards holds anything from
    # a drawing that stopped halfway.
    my state svgUseStack {}
    my state svgUseCount 0
    my state svgClipStack {}
    my state svgLuminosity 0
    # The root <svg> is the one that does NOT open a viewport of its own -
    # SvgRoot's matrix is that viewport. Every <svg> below it does.
    my state svgAtRoot 1
    # No transparency group is being captured yet - and none may be left
    # over from a drawing that failed halfway.
    my state svgGroupStack {}
    my state svgTransform [::tclpdf::geometry identity]
    my state svgMatrix [list $scaleX 0 0 [expr {-$scaleY}] \
        [expr {$originX - $boxX * $scaleX}] \
        [expr {$originY + $drawnHeight + $boxY * $scaleY}]]

    # The reusable pieces were collected in [SvgDraw], before the mark: a
    # <use> may point forward, and the cycle check that reads them has to run
    # while the page can still be left untouched.
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

  # Everything a drawing can be refused for, asked before a byte is written.
  #
  # Only what is CHECKABLE without drawing: the paint values, which is the
  # class the refusals actually come from, and the <use> graph. A face that
  # has not got a character is not among them - that answer needs the text
  # measured - and it stays the one refusal that can arrive with part of the
  # drawing already on the page.
  #
  # The whole tree is walked, <defs> included: an element that is never
  # painted carries no risk here, and a walk that mirrored the drawing's own
  # decisions would be a second copy of the element switch. stop-color is
  # deliberately NOT among the properties - a gradient nobody uses must not
  # cost a drawing that draws fine today.
  method SvgCheck {node} {
    # ONE VALUE IS READ ONCE. A drawing out of an icon library is hundreds of
    # paths with the same three fills between them, and the walk is over the
    # whole tree - without the memo the pre-pass cost as much as the drawing
    # itself. The key is the property plus the value, because the refusal
    # names the property.
    set seen [dict create]
    my SvgCheckPaint $node seen
    my SvgCheckUse $node
    return
  }

  method SvgCheckPaint {node seenVariable} {
    upvar 1 $seenVariable seen
    set style [::tclpdf::xml attribute $node style]
    set declarations [expr {$style eq {} ? {} : [my SvgDeclarations $style]}]
    foreach property {fill stroke color} {
      set value [::tclpdf::xml attribute $node $property]
      if {[dict exists $declarations $property]} {
        set value [dict get $declarations $property]
      }
      if {$value eq {} || [dict exists $seen $property,$value]} {
        continue
      }
      dict set seen $property,$value 1
      if {![my SvgColourWanted $value]} {
        continue
      }
      lassign [my SvgColourValue $value $property] colour ->
      if {![my SvgColourWanted $colour]} {
        continue
      }
      # [color parse] and not [GraphicsColour]: the second records the colour
      # space as USED, and a drawing must not claim a space for an element
      # that may never be painted.
      ::tclpdf::color parse $colour
    }
    foreach child [::tclpdf::xml children $node] {
      my SvgCheckPaint $child seen
    }
    return
  }

  # Whether a paint value names a colour that has to be readable. A server, a
  # keyword and the empty string do not.
  method SvgColourWanted {value} {
    if {$value eq {} || [string match "url(*" $value]} {
      return 0
    }
    return [expr {[string tolower [string trim $value]] ni
        {none inherit currentcolor}}]
  }

  # A <use> that reaches itself, directly or round a corner (SVG 1.1, 5.6
  # calls it an error). Found here rather than while drawing, because the
  # answer while drawing was "restore without a save" from the graphics
  # bookkeeping, or - for a mask - Tcl's own "too many nested evaluations"
  # with no TCLPDF code at all (measured 2026-08-27).
  #
  # OVER THE REFERENCE GRAPH AND NOT OVER THE TREE, which is the whole point:
  # walking the tree through every <use> is the same exponential unfolding
  # the drawing itself does, so the check would have cost what it is there to
  # prevent. The graph has one node per id and one edge per <use> inside that
  # id's subtree, so it is linear in the document.
  method SvgCheckUse {node} {
    set edges [dict create]
    set top [my SvgUseEdges $node edges {}]
    dict set edges {} $top
    set colours [dict create]
    foreach id [dict keys $edges] {
      my SvgUseCycle $id $edges colours
    }
    return
  }

  # Every id a <use> below this node points at, and - for a node that has an
  # id - the same set recorded as that id's edges.
  method SvgUseEdges {node edgesVariable enclosing} {
    upvar 1 $edgesVariable edges
    set used {}
    if {[string map {svg: {}} [::tclpdf::xml name $node]] eq "use"} {
      set reference [::tclpdf::xml attribute $node href \
          [::tclpdf::xml attribute $node xlink:href]]
      set id [string trimleft [string trim $reference] #]
      if {$id ne {}} {
        lappend used $id
      }
    }
    foreach child [::tclpdf::xml children $node] {
      lappend used {*}[my SvgUseEdges $child edges $enclosing]
    }
    set own [::tclpdf::xml attribute $node id]
    if {$own ne {}} {
      dict set edges $own $used
    }
    return $used
  }

  # Depth-first over the reference graph: grey means "on the way down from
  # here", which is what a cycle runs into.
  method SvgUseCycle {id edges coloursVariable} {
    upvar 1 $coloursVariable colours
    if {[dict exists $colours $id]} {
      if {[dict get $colours $id] eq "grey"} {
        return -code error -errorcode [list TCLPDF SVG REFERENCE cycle] \
            "tclpdf: the drawing's <use> elements form a cycle at\
            \"#$id\" - a use that reaches itself has no rendering\
            (SVG 1.1, 5.6)"
      }
      return
    }
    dict set colours $id grey
    if {[dict exists $edges $id]} {
      foreach next [dict get $edges $id] {
        my SvgUseCycle $next $edges colours
      }
    }
    dict set colours $id black
    return
  }

  # Merge the element's own painting properties over the inherited ones. The
  # style="" attribute wins over presentation attributes (SVG 6.4).
  # A colour in the FUNCTIONAL notation, translated into what this package
  # writes. Everything else is handed on untouched: [color parse] already
  # reads "#rgb", "#rrggbb" and the named colours, and this is the one
  # spelling it does not.
  #
  # NOT A FLOURISH. SVG 1.1, 11.13.1 lists "rgb(255,255,255)" and
  # "rgb(100%,100%,100%)" among the four ways of writing a colour, and until
  # 2026-08-24 a drawing using it was refused OUTRIGHT - "colour component is
  # not a number: rgb(245," - so the whole file was lost over a notation the
  # standard names first. Measured over the SVG on this machine with the icon
  # libraries taken out: 6 of 167 files, one of them a floor plan, none of
  # them drawable.
  #
  # rgba() is CSS Color 3 rather than SVG 1.1, and it occurs twice in the same
  # corpus. Its fourth value is a real alpha, so it is multiplied into the
  # opacity property that belongs to the side it paints instead of being
  # dropped - a translucent colour drawn opaque is a wrong picture, and a
  # refused one is no picture at all.
  #
  # Returns a two-element list: the colour, and the alpha to fold in (1 where
  # there is none). Anything it cannot read is handed back unchanged, so the
  # refusal still comes from the colour module and still names the value.
  #
  # THE ATTRIBUTE IS AN ARGUMENT because the refusal below is the one that
  # cannot be handed on: a component that IS a double but is not finite has
  # nothing left for [color parse] to name - see [SvgColourFinite].
  method SvgColourValue {value attribute} {
    if {![regexp -nocase {^\s*rgba?\s*\((.*)\)\s*$} $value -> inside]} {
      return [list $value 1]
    }
    set parts {}
    foreach part [split [string map {, " "} $inside]] {
      set part [string trim $part]
      if {$part ne {}} {
        lappend parts $part
      }
    }
    if {[llength $parts] < 3} {
      return [list $value 1]
    }
    set channels {}
    foreach part [lrange $parts 0 2] {
      if {[string index $part end] eq "%"} {
        set number [string range $part 0 end-1]
        if {![string is double -strict $number]} {
          return [list $value 1]
        }
        my SvgColourFinite $number $value $attribute
        lappend channels [expr {max(0.0, min(1.0, $number / 100.0))}]
      } else {
        if {![string is double -strict $part]} {
          return [list $value 1]
        }
        my SvgColourFinite $part $value $attribute
        lappend channels [expr {max(0.0, min(1.0, $part / 255.0))}]
      }
    }
    set alpha 1
    if {[llength $parts] > 3 && [string is double -strict [lindex $parts 3]]} {
      my SvgColourFinite [lindex $parts 3] $value $attribute
      set alpha [expr {max(0.0, min(1.0, double([lindex $parts 3])))}]
    }
    return [list [linsert $channels 0 rgb] $alpha]
  }

  # A component of the functional notation, refused where it is a double to
  # Tcl but not a finite number.
  #
  # NOT the same road as the rest of [SvgColourValue]. What that method
  # cannot READ - "rgb(oops)" - it hands back untouched, and [color parse]
  # then refuses the whole value by name; NaN and Inf have no such second
  # chance, because they pass [string is double -strict] and go straight into
  # the clamp. min() and max() are arithmetic functions and [expr] refuses
  # NaN as their operand, so a drawing with "rgb(NaN,0,0)" died with Tcl's
  # own "floating point value is Not a Number" (measured 2026-08-27), against
  # the promise that every refusal begins with "tclpdf:"; Inf came through
  # the clamp as 1.0 and painted a channel the file never asked for. Since
  # 2026-08-27 the colour module refuses both in every component (TCLPDF
  # COLOUR COMPONENTS number), and this is the same rule at the one point
  # that never reaches it.
  #
  # The refusal names the ATTRIBUTE as well as the value: fill and stroke
  # carry the same notation, and the two are told apart nowhere downstream.
  # [option finite] is the package's one predicate for this - a second copy
  # is how two modules come to disagree about what a number is.
  method SvgColourFinite {number value attribute} {
    if {[::tclpdf::option finite $number]} {
      return
    }
    return -code error -errorcode [list TCLPDF SVG COLOUR $attribute] \
        "tclpdf: $attribute has a colour component that names no colour,\
        \"$number\" in \"$value\" - NaN and Inf are doubles to Tcl and paint\
        nothing"
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
  # A ZERO WIDTH OR HEIGHT IS NOT A MISSING viewBox. SVG 1.1, 7.7: "A
  # negative value for <width> or <height> is an error ... A value of zero
  # disables rendering of the element." Falling back to the width/height
  # attributes drew the whole picture where the file had said "draw nothing"
  # - measured 2026-08-27 against rsvg, which draws an empty page. The
  # degenerate box is handed on as it stands and [SvgFit] turns it into
  # "render 0"; only a viewBox that is not four numbers is no viewBox.
  method SvgViewBox {root} {
    set box [::tclpdf::xml attribute $root viewBox]
    if {$box ne {}} {
      set numbers [regexp -all -inline \
          {[-+]?(?:[0-9]*\.[0-9]+|[0-9]+\.?)(?:[eE][-+]?[0-9]+)?} $box]
      if {[llength $numbers] >= 4} {
        return [lrange $numbers 0 3]
      }
    }
    set width [my SvgLength [::tclpdf::xml attribute $root width] 100 x]
    set height [my SvgLength [::tclpdf::xml attribute $root height] 100 y]
    return [list 0 0 $width $height]
  }

  method SvgExtent {root options boxWidth boxHeight} {
    set unit [my cget -unit]
    return [my fitExtent [::tclpdf::geometry fromPoints $boxWidth $unit] \
        [::tclpdf::geometry fromPoints $boxHeight $unit] $options]
  }

  # Everything with an id, for <use> to point at.

  # A gradient coordinate, in the units the gradient states.
  #
  # WHICH MEANING A NUMBER HAS IS DECIDED BY gradientUnits ALONE (SVG 1.1,
  # 7.11), not by its magnitude. Until 2026-08-27 this method guessed:
  # anything inside 0..1 was a fraction and anything outside it a length.
  # Both halves were wrong where it mattered - under userSpaceOnUse x2="1"
  # is a length of one user unit and came out as the full width of the box,
  # and under objectBoundingBox a focus at -0.2, which the norm expressly
  # allows, was read as a length of -0.2 in the drawing.
  method SvgFraction {value extent origin units {axis x}} {
    set fractional [expr {$units ne "userSpaceOnUse"}]
    if {[string match {*%} $value]} {
      set number [string trimright $value %]
      if {![::tclpdf::option finite $number]} {
        return $origin
      }
      if {$fractional} {
        return [expr {$origin + $number / 100.0 * $extent}]
      }
      return [my SvgLength $value 0 $axis]
    }
    if {![string is double -strict $value]} {
      return $origin
    }
    if {$fractional} {
      return [expr {$origin + $value * $extent}]
    }
    return [my SvgLength $value 0 $axis]
  }

  # transform="" as a PDF matrix. Several functions compose left to right.
  #
  # THE TWO SKEW CASES ARE THE WAY ROUND THEY ARE because [geometry skew
  # alpha beta] answers {1 tan(alpha) tan(beta) 1 0 0} - the first argument
  # is b, the second is c. SVG 1.1, 7.6 makes skewX(a) the matrix with
  # b = 0 and c = tan(a), and skewY(a) its transpose. Passed the other way
  # round, which is how they stood until 2026-08-27, every skewX came out as
  # a skewY and back: "skewX(30)" wrote "1 0.57735 0 1 0 0 cm", and the two
  # fields of example 03.03 stood swapped under their own captions.
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
          #
          # AND THE ANGLE IS NOT NEGATED. SVG 1.1, 7.6 makes rotate(a)
          # "matrix(cos(a), sin(a), -sin(a), cos(a), 0, 0)", and [geometry
          # rotate] answers exactly those six numbers; SVG and PDF give
          # a b c d e f the same meaning, and the y flip of this module
          # stands OUTSIDE the element matrix, in SvgRoot. Negating turned
          # every rotation the other way - measured 2026-08-27 against
          # rsvg-convert, and against the counter-test example 03.03 prints
          # on its own page, where a matrix() worked out by hand and the
          # same rotation as a function came out mirrored to each other.
          set step [::tclpdf::geometry rotate $angle]
          if {$cx ne {}} {
            set step [::tclpdf::geometry multiply \
                [::tclpdf::geometry translate [expr {-$cx}] [expr {-$cy}]] \
                [::tclpdf::geometry multiply $step \
                    [::tclpdf::geometry translate $cx $cy]]]
          }
        }
        skewX {set step [::tclpdf::geometry skew 0 [lindex $numbers 0]]}
        skewY {set step [::tclpdf::geometry skew [lindex $numbers 0] 0]}
        matrix {set step $numbers}
        default {continue}
      }
      set matrix [::tclpdf::geometry multiply $step $matrix]
    }
    return $matrix
  }

  # A length with an optional unit (SVG 1.1, 4.2 and 7.10).
  #
  # ONE USER UNIT IS ONE POINT here, and that is what fixes the factor of
  # 4/3 this method carried until 2026-08-27: it converted the physical
  # units at 96 px to the inch, the CSS pixel, while [SvgExtent] read the
  # result as POINTS. A drawing that named its own size - width="50mm" -
  # came out 66.67 mm wide, a third too large, and [svg size] said so too.
  # The conversion belongs to the unit the rest of the drawing measures in,
  # so mm is 72/25.4 and pt is 1.
  #
  # AND THE EXPONENT ONLY COUNTS WITH A DIGIT BEHIND IT. The pattern was
  # [-+0-9.eE]+, which swallowed the "e" of "2em" and left "2e" - a value
  # that reached [pdfObj num] and cost the WHOLE drawing under a code from a
  # module the caller had never spoken to (TCLPDF PDFOBJ NUMBER 2e). The
  # grammar below is the one svgPath.tcl already tokenises with.
  #
  # axis says which viewport extent a per cent refers to (7.10): x, y, or d
  # for the normalised diagonal, which is what a radius and a dash pattern
  # take. em and ex resolve against the font size in force - see
  # [SvgFontSize].
  method SvgLength {value {default 0} {axis x}} {
    if {$value eq {} || $value eq "none"} {
      return $default
    }
    if {![regexp {^\s*([-+]?(?:[0-9]*\.[0-9]+|[0-9]+\.?)(?:[eE][-+]?[0-9]+)?)\s*([a-zA-Z%]*)\s*$} \
        $value -> number unit]} {
      return $default
    }
    switch -- [string tolower $unit] {
      {} - px {return $number}
      pt {return $number}
      mm {return [expr {$number * 72.0 / 25.4}]}
      cm {return [expr {$number * 72.0 / 2.54}]}
      in {return [expr {$number * 72.0}]}
      pc {return [expr {$number * 12.0}]}
      em {return [expr {$number * [my SvgFontSize]}]}
      ex {
        # Half an em, which is what CSS 2.1 4.3.2 allows where the face's own
        # x-height is not to hand - and here it is not: a length is read
        # before the face is resolved.
        return [expr {$number * [my SvgFontSize] / 2.0}]
      }
      % {
        set extent [my SvgViewportExtent $axis]
        if {$extent eq {}} {
          return $default
        }
        return [expr {$number / 100.0 * $extent}]
      }
    }
    # A unit this package does not know makes the value no <length> at all
    # (4.2), and a declaration in error falls back to its initial value.
    return $default
  }

  # The viewport a per cent is measured against, per axis. The drawing's own
  # viewBox while one is being drawn, and nothing before that - a per cent on
  # the ROOT width refers to a viewport that does not exist yet, so it falls
  # back rather than being measured against the drawing it is describing.
  method SvgViewportExtent {axis} {
    lassign [my state svgViewport] width height
    if {$width eq {} || $height eq {}} {
      return {}
    }
    switch -- $axis {
      y {return $height}
      d {
        # SVG 7.10: a per cent on a length that is neither horizontal nor
        # vertical uses sqrt((w^2 + h^2)/2).
        return [expr {sqrt(($width * $width + $height * $height) / 2.0)}]
      }
    }
    return $width
  }

  # The font size in force, for em and ex. Kept in the state because a length
  # is read from four modules and none of them carries the style dictionary
  # that far down; pushed and popped by [SvgElement] as the walk descends.
  # 16 is the CSS initial value of "medium" (CSS 2.1, 15.7).
  method SvgFontSize {} {
    set size [my state svgFontSize]
    if {![::tclpdf::option finite $size] || $size <= 0} {
      return 16
    }
    return $size
  }

  # One element counted as skipped, and the drawing's tally of what it lost.
  #
  # IT LIVES HERE and not with the element walk, which is where it stood
  # until 2026-08-27. [SvgAspect] reports an unreadable preserveAspectRatio,
  # and that runs in [SvgFit] - BEFORE [SvgRoot] has touched anything that
  # would load svgElement.tcl. As the first drawing of a process the report
  # then died with "unknown method SvgSkipped" and a TCL LOOKUP METHOD code,
  # against the promise that every refusal of this package carries a TCLPDF
  # one; after any healthy drawing the same file reported cleanly. In this
  # module the method exists as soon as [svg] can be called at all.
  method SvgSkipped {what} {
    set skipped [my state svgSkipped]
    dict incr skipped $what
    my state svgSkipped $skipped
    return
  }

  # A style="" attribute as a dictionary of declarations.
  #
  # ONE READER for the three that existed - the painting cascade, the stops
  # of a gradient and the clip properties - because each of them had its own
  # copy of the same regular expression and each would have had to learn the
  # two rules below separately.
  #
  # !important is part of the DECLARATION and not of the value (CSS 2.1,
  # 6.4.2): taken for part of it, "fill:#0a0 !important" reached the colour
  # module as a colour name and cost the whole drawing. A /* comment */ is
  # not part of a value either. Priority is not tracked - a style="" attribute
  # is one declaration block, so nothing can outrank anything inside it.
  method SvgDeclarations {text} {
    if {$text eq {}} {
      return {}
    }
    regsub -all {/\*.*?\*/} $text { } text
    set declarations [dict create]
    foreach {-> key value} [regexp -all -inline {([-a-zA-Z]+)\s*:\s*([^;]+)} $text] {
      regsub -nocase {\s*!\s*important\s*$} $value {} value
      dict set declarations [string tolower $key] [string trim $value]
    }
    return $declarations
  }

  # The luminosity of a colour, for the content of a <mask>.
  #
  # SVG 1.1, 14.4 names the coefficients: 0.2125 R + 0.7154 G + 0.0721 B.
  # ISO 32000-2, 8.6.5.4 names DIFFERENT ones for DeviceRGB -> DeviceGray -
  # 0.3, 0.59, 0.11 - and those are what a reader applies when the mask's
  # group says /DeviceGray and its content is painted in RGB. Measured
  # 2026-08-27 on a mask painted #ff0000: rsvg gave alpha 0.212, this package
  # 0.302, so a red mask was 42 % too opaque. Converting here, where every
  # colour of the mask passes through, is what makes the grey the norm's
  # grey rather than the reader's.
  method SvgLuminosity {colour} {
    if {![my state svgLuminosity]} {
      return $colour
    }
    switch -- [lindex $colour 0] {
      rgb {
        lassign [lindex $colour 1] red green blue
        return [list gray [expr {0.2125 * $red + 0.7154 * $green +
            0.0721 * $blue}]]
      }
      gray {return $colour}
    }
    return $colour
  }
}

package provide tclpdf::svg 1.12