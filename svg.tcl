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
# 14995 SVG files on this machine, 300 of them in detail. <filter> and
# <animate> occur ZERO times, <mask> twice, <style> three times, and
# preserveAspectRatio not once. The elliptical arc is the most frequent path
# command of all - ahead of moveto - and PDF has no arc operator, so that is
# where the work went.
#
#   shapes      path, rect (rx/ry included), circle, ellipse, line, polyline,
#               polygon - all through the same painting code, so none of them
#               can drift from <path>
#   structure   g, svg, a, switch, defs, use, symbol; title/desc/metadata and
#               script are skipped on purpose
#   painting    fill, stroke, stroke-width, stroke-linecap, stroke-linejoin,
#               stroke-dasharray, opacity, fill-opacity, fill-rule, display,
#               and the same set inside a style="" attribute, which wins
#   geometry    transform (translate, scale, rotate about a point, skewX,
#               skewY, matrix), viewBox
#   fitting     the DEFAULT of preserveAspectRatio - xMidYMid meet: the
#               drawing keeps its proportions and is centred in the rectangle
#               asked for. The attribute itself is NOT read; its twenty
#               spellings wait for the first drawing that carries one
#   text        text and tspan, with font-size, font-family (a list, first
#               name that resolves wins), text-anchor and fill
#   gradients   linearGradient and radialGradient through the shading module,
#               with objectBoundingBox (the default) measured against the
#               shape being filled, userSpaceOnUse, stops from attribute or
#               style, and one level of inheritance through href
#
# NOT covered, and each for a reason rather than by omission: filters and
# animation (absent from the corpus), masks and clip paths (twice in 14995),
# CSS in a <style> block (three times), spreadMethod and gradientTransform
# (never), and stop-opacity, which needs a luminosity soft mask - one
# occurrence in the whole corpus, against a PDF/A risk that would have to be
# measured first.
#
# Known and open: a gradient whose axis runs in y comes out flat. The
# coordinates written are correct - the matrix handed to the pattern maps x
# and not y. See docs/STAND.md.
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
    fill-opacity stroke-opacity fill-rule font-size font-family text-anchor
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
      artifact {}
    } $arguments "svg"]
    if {$path ne {}} {
      # Read as bytes, then decode: an SVG is UTF-8 unless its declaration
      # says otherwise (XML 4.3.3). Reading it as text would use the system
      # encoding, and a middle dot would come out as two characters - which
      # is exactly what happened before this line existed.
      set markup [my SvgDecode [::tclpdf::io read $path]]
    } elseif {[dict get $options data] ne {}} {
      set markup [dict get $options data]
    } else {
      return -code error "tclpdf: svg needs a file name or -data"
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
    # option carries the resource name from here on.
    if {[dict get $options opacity] ne {}} {
      dict set options opacity [my GraphicsOpacity [dict get $options opacity]]
    }
    lassign [my GraphicMark svg svg [dict get $options alt] \
        [dict get $options artifact] [expr {[dict get $options at] eq {} ?
        0 : [lindex [dict get $options at] 1]}]] mark element
    set root [::tclpdf::xml parse $markup]
    try {
      return [my SvgRoot $root $options]
    } finally {
      ::tclpdf::xml release $root
      my GraphicUnmark $mark $element
    }
  }

  method SvgRoot {root options} {
    if {[::tclpdf::xml name $root] ni {svg svg:svg}} {
      return -code error "tclpdf: this is not an SVG document - the root\
          element is \"[::tclpdf::xml name $root]\""
    }
    my state svgSkipped {}

    lassign [my SvgViewBox $root] boxX boxY boxWidth boxHeight
    lassign [my SvgExtent $root $options $boxWidth $boxHeight] width height
    lassign [expr {[dict get $options at] eq {} ? {0 0} : [dict get $options at]}] left top

    # Everything is drawn inside one q/Q pair with a single matrix that maps
    # the viewBox onto the requested rectangle. The y axis is flipped HERE and
    # nowhere else: SVG counts downwards from the top left, PDF upwards from
    # the bottom left, and doing it per element is how half a drawing ends up
    # mirrored.
    # Fit, do not distort. The default of preserveAspectRatio is
    # "xMidYMid meet": the drawing keeps its proportions, is scaled until it
    # fits the rectangle in BOTH directions, and is centred in what is left
    # over. Measured over 14995 files, the attribute itself never occurs -
    # so only the default is implemented, and the twenty spellings of it are
    # a TODO waiting for the first drawing that needs one.
    #
    # Distorting instead would turn a circle into an ellipse whenever the
    # requested rectangle has a different shape than the viewBox, and there
    # is no reading at which that is what the caller asked for.
    set requestedWidth [my distance $width]
    set requestedHeight [my distance $height]
    set scale [expr {min($requestedWidth / double($boxWidth),
        $requestedHeight / double($boxHeight))}]
    set scaleX $scale
    set scaleY $scale
    set drawnWidth [expr {$boxWidth * $scale}]
    set drawnHeight [expr {$boxHeight * $scale}]
    # What is left over is split evenly - that is the "Mid" in xMidYMid.
    set insetX [expr {($requestedWidth - $drawnWidth) / 2.0}]
    set insetY [expr {($requestedHeight - $drawnHeight) / 2.0}]
    set unit [my cget -unit]
    lassign [my coords \
        [expr {$left + [::tclpdf::geometry fromPoints $insetX $unit]}] \
        [expr {$top + $height -
            [::tclpdf::geometry fromPoints $insetY $unit]}]] originX originY

    my state svgDepth 0
    my SvgSave
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
    # Where the drawing ACTUALLY ended up, not what was asked for: once it is
    # fitted rather than stretched it is smaller than the rectangle and sits
    # centred in it, and a caller placing a caption underneath needs to know
    # where.
    return [list \
        [expr {$left + [::tclpdf::geometry fromPoints $insetX $unit]}] \
        [expr {$top + [::tclpdf::geometry fromPoints $insetY $unit]}] \
        [::tclpdf::geometry fromPoints $drawnWidth $unit] \
        [::tclpdf::geometry fromPoints $drawnHeight $unit]]
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

package provide tclpdf::svg 1.3
