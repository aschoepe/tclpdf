#
# tclpdf - PDF generation for Tcl
#
# colorFontBand - a gradient's VARYING alpha as bands of CONSTANT alpha
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# A private sub-module of colorFontPaint.tcl. It holds no state, touches no
# document and writes no object: it takes a colour line's alpha values and the
# geometry of the gradient they belong to, and answers with clip paths and the
# /ca that goes with each. WHICH construction a gradient ends up with, and
# what a gradient that cannot be banded gets instead, is colorFontPaint's
# business and not this file's.
#
# WHY THIS EXISTS AT ALL, and it is not a saving of bytes. A PDF shading has
# no alpha channel, so a colour line whose stops carry different alphas has to
# take its alpha from somewhere else. The exact construction is a LUMINOSITY
# SOFT MASK - a grey twin of the same shading, established with a "gs" - and
# it is exact: the alpha then varies continuously, the way the font wrote it.
#
# It is also the construction two readers get wrong. A soft mask's coordinate
# system is "the transformation matrix specified by the Matrix entry in the
# transparency group's form dictionary ... concatenated with the CURRENT
# TRANSFORMATION MATRIX AT THE MOMENT THE SOFT MASK IS ESTABLISHED with the gs
# operator" (ISO 32000-2, 11.6.5.1). Inside a Type 3 glyph that matrix carries
# the text matrix and the font matrix, so the mask travels with the letter.
# Measured on 2026-08-26 over seven readers on one page of skin tone ramps:
# five draw it right (Acrobat, Quartz, pdf.js, PDFium, poppler) and two anchor
# the mask at a matrix that is not the one in force, so the mask slides
# further off the glyph with every glyph along the line - the faces come out
# blank from the third position on (Apple PDFKit, PDF Gear).
#
# What is below has no mask, no transparency group and no form XObject in it.
# It is a clip path and a /ca, which is the plainest thing a content stream
# can hold and has no matrix in it for a reader to get wrong.
#
# WHAT THE BANDS ARE, and they are NOT strips laid side by side. Abutting
# clips SEAM: two neighbouring regions that share an edge each cover the
# boundary pixel partly, and the two partial coverages composite OVER each
# other rather than adding up. Measured with poppler at 400 dpi on 2026-08-26,
# forty abutting strips of one colour: at /ca 1 the shared edges came out 58
# grey levels of 255 lighter than the middle of a strip, at /ca 0.5 still 23.
# That is a visible comb, and finer strips only put more teeth in it.
#
# So the bands are NESTED and CUMULATIVE, which is the level-set picture of
# the same thing. Sort the alphas the colour line asks for: A1 < A2 < ... < An.
# The region where the alpha is at least Aj CONTAINS the region where it is at
# least Aj+1, so the regions nest. Paint the gradient over the first region at
# /ca b1, then over the second at /ca b2, and so on, letting each clip narrow
# the one before it:
#
#     bj = (Aj - Aj-1) / (1 - Aj-1),  A0 = 0
#
# because alpha composites as 1 - (1-a)(1-b). The colour is the same shading
# every time and a colour painted over itself is itself, so only the alpha
# accumulates - to exactly Aj inside the j-th region. And the boundary that
# seamed before is now the edge of an INCREMENT over a region that is already
# painted: at a half covered pixel the increment applies half, and the result
# lands BETWEEN the two levels instead of below both of them. The anti-
# aliasing that produced the comb produces the ramp.
#
# WHAT IT COSTS: the alpha is a staircase and no longer a slope. The step is
# [step] below, and the value a band is painted at is the CENTRE of the step
# it falls in, so no alpha is ever more than half a step from the one the font
# wrote.
#
# THE THREE GEOMETRIES, one per kind of gradient:
#
#   - a linear gradient's bands are RECTANGLES across the axis, computed in
#     the space the operators are written in and reaching past the box
#     sideways.
#   - a radial gradient's bands are CIRCLE RINGS, written as circles under the
#     even-odd rule: nested circles alternate in and out, so a list of them IS
#     a list of rings, and the outermost region takes the box as its outer
#     boundary. Only a gradient whose two circles are NESTED can be banded -
#     |c1-c0| < |r1-r0| - because only then is the region between two circles
#     of the family a ring at all. Measured over Noto Color Emoji: 7894 of its
#     7894 radial gradients with a varying alpha are nested, so the cone case
#     is a fallback nothing real is known to reach.
#   - a sweep gradient's bands are WEDGES, and it has them already: the fan of
#     Gouraud triangles it is drawn as is cut at four degrees and at every
#     colour stop, so one band is a run of neighbouring wedges.
#

package require Tcl 8.6.11-
package require tclpdf::pdfObj 1.0-
package require tclpdf::geometry 1.0-

namespace eval ::tclpdf::colorFontBand {
  namespace export {[a-z]*}
  namespace ensemble create

  # How fine the staircase is cut, in alpha. A band is painted at the centre
  # of its step, so half of this is the largest error there can be: 1/128 of
  # full opacity, which is two of 255 grey levels where the contrast is total.
  #
  # MEASURED AND NOT CHOSEN, at 400 dpi against the soft mask it replaces; the
  # numbers stand in docs/FEATURES.md. A coarser 1/16 shows as terraces on a
  # slow fade over a large glyph, 1/32 is at the edge of what a render shows,
  # 1/64 is not distinguishable from the mask, and 1/128 costs twice the
  # operators for a difference no render shows at all.
  variable step [expr {1.0 / 64}]

  # How many clip intervals all the bands of ONE gradient may cost together.
  # A colour line that fades up and down repeatedly - an unfolded repeat, say
  # - has one region per period per level, and that product is what runs
  # away. Past this the gradient goes back to the soft mask, which costs one
  # object whatever the colour line does.
  variable limit 256
}

# --- the bands -------------------------------------------------------------

# The bands of a colour line whose stops carry different alphas.
#
#   positions   the stop positions, 0 to 1 and increasing - what
#               [ColorFontPaintSpread] normalised them to
#   alphas      one alpha per position
#   low high    how far past the two ends of the axis the box being painted
#               reaches, in the same parameter; the alpha is constant there,
#               because that is what a PDF shading's /Extend does
#
# What comes back is a list of {increment intervals} to be painted IN ORDER
# with the clips NESTING - each interval list lies inside the one before it,
# so a reader that intersects them arrives at the right region without a q/Q
# in between. An interval is {from to} in the same parameter as "positions".
#
# The empty list means there is nothing to paint at all; the word "mask" means
# the colour line needs more regions than [limit] allows.
proc ::tclpdf::colorFontBand::plan {positions alphas low high} {
  # The knots of the piecewise linear alpha: the stops, and the two stretches
  # outside them where the shading pads and the alpha is the end stop's.
  set knots {}
  set values {}
  if {$low < [lindex $positions 0]} {
    lappend knots $low
    lappend values [lindex $alphas 0]
  }
  foreach position $positions alpha $alphas {
    lappend knots $position
    lappend values $alpha
  }
  if {$high > [lindex $positions end]} {
    lappend knots $high
    lappend values [lindex $alphas end]
  }
  set pieces {}
  foreach from [lrange $knots 0 end-1] to [lrange $knots 1 end] \
      first [lrange $values 0 end-1] second [lrange $values 1 end] {
    if {$to <= $from} {
      # A step in the colour line - two stops at one offset. It is a jump in
      # the alpha and spans no stretch of the axis, so it needs no band.
      continue
    }
    lappend pieces {*}[Cut $from $to $first $second]
  }
  return [Levels $pieces]
}

# The same for an alpha that is a STEP function rather than a slope: one value
# per cell, which is what a sweep gradient's fan of wedges hands over. The
# intervals that come back are {first past} over the cell numbers.
proc ::tclpdf::colorFontBand::cells {alphas} {
  set pieces {}
  set index 0
  foreach alpha $alphas {
    lappend pieces [list $index [incr index] $alpha]
  }
  return [Levels $pieces]
}

# The positions at which the alpha of a colour line crosses the step grid -
# the extra vertices a FAN needs, for the reason it needs one at every colour
# stop. A wedge carries ONE alpha, so a wedge spanning two bands would lose
# one of them; cut at the crossing, neither is lost.
#
# Empty where the alpha does not vary, which is the ordinary case: an opaque
# sweep is cut at four degrees and at its stops and nowhere else.
proc ::tclpdf::colorFontBand::crossings {positions alphas} {
  set marks {}
  foreach from [lrange $positions 0 end-1] to [lrange $positions 1 end] \
      first [lrange $alphas 0 end-1] second [lrange $alphas 1 end] {
    if {$to <= $from || $first == $second} {
      continue
    }
    # The first piece begins at the stop itself, which is a vertex already.
    foreach piece [lrange [Cut $from $to $first $second] 1 end] {
      lappend marks [lindex $piece 0]
    }
  }
  return [lsort -real -unique $marks]
}

# One stretch of the axis over which the alpha runs from one value to another,
# cut where it crosses the step grid - so that no piece spans two steps and
# the alpha at a piece's middle is the alpha of the whole of it to within half
# a step.
proc ::tclpdf::colorFontBand::Cut {from to first second} {
  variable step
  if {$first == $second} {
    return [list [list $from $to $first]]
  }
  set lowest [expr {min($first, $second)}]
  set highest [expr {max($first, $second)}]
  set marks {}
  for {set index [expr {int(floor($lowest / $step)) + 1}]
      } {$index * $step < $highest} {incr index} {
    lappend marks [expr {$from + ($index * $step - $first)
        / double($second - $first) * ($to - $from)}]
  }
  set pieces {}
  set previous $from
  foreach mark [linsert [lsort -real $marks] end $to] {
    if {$mark <= $previous} {
      continue
    }
    set middle [expr {($previous + $mark) / 2.0}]
    lappend pieces [list $previous $mark [expr {$first
        + ($middle - $from) / double($to - $from) * ($second - $first)}]]
    set previous $mark
  }
  return $pieces
}

# The pieces of an alpha, as the nested regions described at the head of this
# file. Every piece is quantised to the centre of its step first, so that
# neighbouring pieces within one step become ONE region and a whole document
# draws its bands from at most 1/[step] distinct ExtGState resources.
proc ::tclpdf::colorFontBand::Levels {pieces} {
  variable limit
  set merged {}
  foreach piece $pieces {
    lassign $piece from to alpha
    set level [Quantise $alpha]
    if {$level <= 0} {
      # Fully transparent. Left out rather than painted at nothing, and that
      # is also what makes the regions below it end where they should: a
      # colour line fading to zero stops being painted where it reaches zero.
      continue
    }
    if {[llength $merged] && [lindex $merged end 2] == $level
        && [lindex $merged end 1] == $from} {
      lset merged end 1 $to
    } else {
      lappend merged [list $from $to $level]
    }
  }
  if {![llength $merged]} {
    return {}
  }
  set layers {}
  set below 0.0
  set count 0
  foreach level [lsort -real -unique [lmap piece $merged {lindex $piece 2}]] {
    set intervals {}
    foreach piece $merged {
      if {[lindex $piece 2] < $level} {
        continue
      }
      if {[llength $intervals]
          && [lindex $intervals end 1] == [lindex $piece 0]} {
        lset intervals end 1 [lindex $piece 1]
      } else {
        lappend intervals [lrange $piece 0 1]
      }
    }
    incr count [llength $intervals]
    if {$count > $limit} {
      return mask
    }
    lappend layers [list [expr {($level - $below) / (1.0 - $below)}] $intervals]
    set below $level
    if {$below >= 1.0} {
      # Opaque from here on: 1 - (1-a)(1-b) is already 1, so a further
      # increment would be a division by zero as well as an operator that
      # changes nothing.
      break
    }
  }
  return $layers
}

# One alpha, snapped to the centre of the step it falls in. Nought and one
# keep themselves: a stretch the font says is invisible must not be painted at
# half a step, and one it says is opaque must not come out translucent.
proc ::tclpdf::colorFontBand::Quantise {alpha} {
  variable step
  if {$alpha >= 1.0} {
    return 1.0
  }
  if {$alpha <= 0.0} {
    return 0.0
  }
  return [expr {min(1.0, (floor($alpha / $step) + 0.5) * $step)}]
}

# --- linear ----------------------------------------------------------------

# How far past its two ends the axis has to be banded for the box to be
# covered: the corners of the box, projected onto the axis. A margin on top of
# that, so the outermost band ends OUTSIDE the box rather than on its edge,
# where the clip would show as an edge of its own.
proc ::tclpdf::colorFontBand::axis {from to box} {
  set range {}
  foreach corner [Corners $box] {
    lappend range [Along $from $to $corner]
  }
  set low [expr {min(0.0, [::tcl::mathfunc::min {*}$range])}]
  set high [expr {max(1.0, [::tcl::mathfunc::max {*}$range])}]
  set margin [expr {0.05 * ($high - $low) + 0.01}]
  return [list [expr {$low - $margin}] [expr {$high + $margin}]]
}

# The bands of a linear gradient as clip subpaths: a rectangle per interval,
# across the axis and wide enough for the box, in the space the operators are
# written in.
proc ::tclpdf::colorFontBand::strips {from to box intervals} {
  lassign $from x0 y0
  lassign $to x1 y1
  set dx [expr {$x1 - $x0}]
  set dy [expr {$y1 - $y0}]
  # A DOUBLE, because the caller's numbers may be whole ones: a colour font
  # writes its geometry in font units, and 80000 / 640000 is 0 in Tcl where
  # both sides are integers. The strips then all came out at the same place
  # and the clip held nothing.
  set square [expr {double($dx * $dx + $dy * $dy)}]
  set across {}
  foreach corner [Corners $box] {
    lassign $corner x y
    lappend across [expr {(($x - $x0) * -$dy + ($y - $y0) * $dx) / $square}]
  }
  set near [expr {[::tcl::mathfunc::min {*}$across] - 0.05}]
  set far [expr {[::tcl::mathfunc::max {*}$across] + 0.05}]
  set body {}
  foreach interval $intervals {
    lassign $interval first second
    append body [Polygon [list \
        [At $from $to $first $near] [At $from $to $second $near] \
        [At $from $to $second $far] [At $from $to $first $far]]]
  }
  return $body
}

# Where a point sits on the axis, counted the way a shading counts it: 0 at
# "from", 1 at "to".
proc ::tclpdf::colorFontBand::Along {from to point} {
  lassign $from x0 y0
  lassign $to x1 y1
  lassign $point x y
  set dx [expr {$x1 - $x0}]
  set dy [expr {$y1 - $y0}]
  return [expr {(($x - $x0) * $dx + ($y - $y0) * $dy)
      / double($dx * $dx + $dy * $dy)}]
}

# The point "along" down the axis and "across" to the side of it, both counted
# in units of the axis itself.
proc ::tclpdf::colorFontBand::At {from to along across} {
  lassign $from x0 y0
  lassign $to x1 y1
  set dx [expr {$x1 - $x0}]
  set dy [expr {$y1 - $y0}]
  return [list [expr {$x0 + $along * $dx - $across * $dy}] \
      [expr {$y0 + $along * $dy + $across * $dx}]]
}

# --- radial ----------------------------------------------------------------

# How far past its two circles a radial gradient has to be banded, and whether
# it can be banded at all.
#
# The empty list means the two circles are NOT nested - |c1-c0| >= |r1-r0|,
# the cone with a tip and a wedge outside it. The family's circles then cross
# one another and the region between two of them is not a ring, so there is no
# ring to clip to. Measured: not one of Noto Color Emoji's 7894 radial
# gradients with a varying alpha has that shape.
#
# Otherwise one end is the TIP, where the radius reaches nought and the
# gradient stops being painted, and the other is the first circle that holds
# the whole box - past which the last band's colour is all there is.
# |P - c(t)| <= |P - c0| + |t| |c1-c0| bounds the drift of the centre, so the
# parameter that covers the box is a division rather than a search.
proc ::tclpdf::colorFontBand::cone {c0 r0 c1 r1 box} {
  lassign $c0 x0 y0
  lassign $c1 x1 y1
  set drift [expr {hypot($x1 - $x0, $y1 - $y0)}]
  set grow [expr {$r1 - $r0}]
  if {abs($grow) <= $drift} {
    return {}
  }
  set reach 0
  foreach corner [Corners $box] {
    lassign $corner x y
    set reach [expr {max($reach, hypot($x - $x0, $y - $y0))}]
  }
  set tip [expr {-$r0 / double($grow)}]
  set cover [expr {($reach - $r0) / (abs($grow) - $drift)}]
  if {$grow < 0} {
    set cover [expr {-$cover}]
  }
  return [list [expr {min(0.0, $tip, $cover)}] [expr {max(1.0, $tip, $cover)}]]
}

# The bands of a radial gradient as clip subpaths, under the EVEN-ODD rule: a
# circle per interval end, in order of RADIUS, so that the parity alternates
# in and out and a list of circles is a list of rings.
#
# Two ends are not circles. A boundary at or below radius nought is the tip of
# the cone: the region reaches the centre and there is nothing to cut out of
# it, so no circle is written and the parity comes out odd, which is what puts
# the innermost disc inside. A boundary whose circle already holds the whole
# box becomes the BOX, which is the outermost subpath there can be, and
# everything past it lies outside the box and is dropped.
proc ::tclpdf::colorFontBand::rings {c0 r0 c1 r1 box intervals} {
  lassign $c0 x0 y0
  lassign $c1 x1 y1
  set grow [expr {$r1 - $r0}]
  set bounds {}
  foreach interval $intervals {
    foreach at $interval side {open close} {
      lappend bounds [list [expr {$r0 + $at * $grow}] \
          [expr {$x0 + $at * ($x1 - $x0)}] [expr {$y0 + $at * ($y1 - $y0)}] \
          $side]
    }
  }
  # The parameter runs one way and the radius may run the other, so the order
  # the circles have to be written in is the radius order and not the
  # caller's. Which end of a ring a boundary is swaps with it, which is why
  # the side travels along.
  set body {}
  foreach bound [lsort -real -index 0 $bounds] {
    lassign $bound radius cx cy side
    if {$radius <= 0} {
      continue
    }
    if {[Holds $cx $cy $radius $box]} {
      if {$side eq "close"} {
        append body [Rectangle $box]
      }
      break
    }
    append body [Circle $cx $cy $radius]
  }
  return $body
}

# Whether a circle holds the whole of a box.
proc ::tclpdf::colorFontBand::Holds {cx cy radius box} {
  foreach corner [Corners $box] {
    lassign $corner x y
    if {hypot($x - $cx, $y - $cy) > $radius} {
      return 0
    }
  }
  return 1
}

# --- sweep -----------------------------------------------------------------

# The bands of a sweep gradient as clip subpaths: one wedge per interval,
# drawn from the centre out over the rim points the fan already has. "wedges"
# is one {x0 y0 x1 y1} per wedge - its two rim points - and an interval names
# a run of them.
proc ::tclpdf::colorFontBand::sectors {centre wedges intervals} {
  set body {}
  foreach interval $intervals {
    lassign $interval first past
    set points [list $centre]
    foreach wedge [lrange $wedges $first [expr {$past - 1}]] {
      lappend points [lrange $wedge 0 1] [lrange $wedge 2 3]
    }
    append body [Polygon $points]
  }
  return $body
}

# --- paths -----------------------------------------------------------------

proc ::tclpdf::colorFontBand::Corners {box} {
  lassign $box x0 y0 x1 y1
  return [list [list $x0 $y0] [list $x1 $y0] [list $x1 $y1] [list $x0 $y1]]
}

# A closed polygon. Consecutive points that coincide are dropped: the wedges
# of a fan share their rim corners, so a run of them lists every inner corner
# twice and a sweep's clip would be twice the size it needs to be.
proc ::tclpdf::colorFontBand::Polygon {points} {
  set body {}
  set previous {}
  foreach point $points {
    if {$point eq $previous} {
      continue
    }
    append body "[Numbers $point] [expr {$body eq {} ? {m} : {l}}]\n"
    set previous $point
  }
  return "${body}h\n"
}

proc ::tclpdf::colorFontBand::Rectangle {box} {
  lassign $box x0 y0 x1 y1
  return "[Numbers [list $x0 $y0 [expr {$x1 - $x0}] [expr {$y1 - $y0}]]] re\n"
}

# A whole circle, through the arc approximation [shape arc] and svgPath use -
# four cubics, which is what everybody's circle is made of.
proc ::tclpdf::colorFontBand::Circle {cx cy radius} {
  set body "[Numbers [list [expr {$cx + $radius}] $cy]] m\n"
  foreach segment [::tclpdf::geometry arcSegments $cx $cy $radius $radius \
      1 0 0 [expr {2 * acos(-1)}]] {
    append body "[Numbers $segment] c\n"
  }
  return "${body}h\n"
}

# Coordinates the way the rest of the package writes them - [pdfObj num] is
# the one spelling of a PDF number there is.
proc ::tclpdf::colorFontBand::Numbers {values} {
  return [join [lmap value $values {::tclpdf::pdfObj num $value}] { }]
}

package provide tclpdf::colorFontBand 1.0
