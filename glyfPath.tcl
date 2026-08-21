#
# tclpdf - PDF generation for Tcl
#
# glyfPath - the outline of a TrueType glyph as PDF path operators
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# A private sub-module. It takes what [::tclpdf::glyfOutline parse] returns -
# raw points in font units - and writes the m/l/c/h operators that draw them.
# It knows nothing about fonts, pages or colour, and holds no state: the same
# outline always produces the same operators.
#
# WHY THIS EXISTS. Everywhere else the package hands a glyph to the VIEWER and
# lets it rasterise: a Tj names glyph numbers, and the outline never appears in
# the file. A colour font is the one case where that is not enough - each layer
# of a COLR glyph has to be FILLED in its own colour, and filling means having
# the path. [glyfOutline] stops one step short of it: it delivers points, and
# points are not segments.
#
# THE TWO THINGS THAT GO WRONG HERE, and why they are not exotic:
#
#   1. A point is either ON the curve or off it, and two off-curve points in a
#      row have an IMPLIED on-curve point exactly halfway between them. The
#      format leaves it out because a rasteriser can compute it, so a converter
#      that takes the points at face value drops half the segments of any
#      rounded glyph. Off-curve pairs are not a corner case: they are how a
#      quarter circle is drawn whenever one quadratic is too coarse.
#
#   2. A contour may BEGIN with an off-curve point. There is no rule that the
#      first point is on the curve - the designer's start point is wherever the
#      outline was closed. A converter that starts drawing at point zero then
#      begins at a control point, and every following segment is off by one.
#      An outline may even consist of off-curve points only (a circle drawn as
#      four quadratics with implied joints); then the start is the midpoint
#      between the last point and the first.
#
# Both are handled by rotating the contour onto its first on-curve point before
# walking it, so that the walk itself has one rule: an off-curve point is a
# control point, and its segment ends at the next on-curve point - real or
# implied.
#
# QUADRATIC TO CUBIC. TrueType curves are quadratic Beziers, PDF has only the
# cubic operator "c". The conversion is DEGREE ELEVATION and it is exact, not
# an approximation: a quadratic with control point Q from P0 to P1 is the cubic
# whose two control points sit two thirds of the way from each end point to Q.
# The same three lines stand in svgPath.tcl (Q/T commands); see the note there.
#
# THE WINDING RULE IS NONZERO - "f" or "B", never "f*" or "B*". TrueType says
# so (ISO/IEC 14496-22, "glyf"): an outer contour is wound one way, an inner
# one the other, and the winding numbers cancel where they overlap. That is
# what makes the counter of an "O" a hole rather than a black disc.
#
# Even-odd would draw the same "O", which is exactly why the mistake survives
# testing: for contours that merely NEST, both rules agree. They part where
# contours OVERLAP - a stroke crossing itself, an accent laid over a letter,
# any glyph carrying the OVERLAP_SIMPLE flag ([glyfOutline] keeps it for that
# reason) - and there even-odd punches holes into solid ink. So the caller
# appends "f" (or "B" to fill and stroke); this module never writes the fill
# operator itself, because only the caller knows whether the path is being
# filled, clipped ("W n") or used as a Type 3 glyph shape.
#
# NO SCALING HAPPENS HERE. The coordinates go out in FONT UNITS, exactly as
# they came in, and dividing by unitsPerEm is the caller's business. Three
# reasons, in the order they matter:
#
#   - The Type 3 font this feeds carries a /FontMatrix, and that matrix exists
#     to hold precisely this scale factor. Applying it here as well would apply
#     it twice, and applying it here INSTEAD would put a per-font constant into
#     every one of the thousands of numbers of every glyph stream.
#   - Font units are integers. [pdfObj num] writes an integer as an integer,
#     so an unscaled stream is both shorter and exact; scaled to text space it
#     becomes 0.05127 and rounds.
#   - unitsPerEm lives in "head", which this module would otherwise have to
#     read - and then it would know about fonts.
#
# A caller that does need other coordinates passes a transform: a command
# prefix called with x and y that returns the pair, the same contract svgPath
# uses. It has to be AFFINE - control points and implied midpoints are computed
# after it has been applied, and only an affine map leaves a Bezier a Bezier.
#
# COMPOSITE GLYPHS ARE NOT RESOLVED HERE. A composite has no points of its own,
# only references to other glyphs with an offset and a transform; assembling
# them is [glyfOutline]'s subject, not this one, and writing a second walker
# here would be the same logic twice. Such an outline is refused with an error
# that says so rather than silently drawing nothing.
#

package require Tcl 8.6.11-
package require tclpdf::pdfObj 1.0-

namespace eval ::tclpdf::glyfPath {
  namespace export {[a-z]*}
  namespace ensemble create
}

# The contours of a glyph as segments, one list per contour:
#
#   {{x y} segment segment ...}
#
# The first element is the START point - where a moveto goes - and each
# segment is either
#
#   {l x y}                        a straight line to x y
#   {c x1 y1 x2 y2 x y}            a cubic Bezier, both control points first
#
# The contour is CLOSED implicitly: the straight line from the last segment's
# end back to the start is not listed, because closepath draws it. A contour
# whose last segment is a curve already ends on the start point, and then the
# closepath adds nothing - which is the correct outcome either way.
#
# "glyph" is what [::tclpdf::glyfOutline parse] returns. An empty glyph - a
# space - has no contours and yields the empty list. Contours of fewer than two
# points are dropped: they enclose no area, so filling them draws nothing, and
# a stray moveto in a Type 3 glyph stream is noise a reader has to skip.
proc ::tclpdf::glyfPath::contours {glyph {transform {}}} {
  if {![dict exists $glyph type]} {
    return -code error "tclpdf: not a parsed glyph outline"
  }
  switch -- [dict get $glyph type] {
    empty {
      return {}
    }
    composite {
      return -code error "tclpdf: a composite glyph has no outline of its own\
          - resolve its components into a simple outline first"
    }
    simple {}
    default {
      return -code error "tclpdf: unknown glyph type\
          \"[dict get $glyph type]\""
    }
  }
  set xs [dict get $glyph x]
  set ys [dict get $glyph y]
  set flags [dict get $glyph flags]
  set count [llength $xs]

  # The transform is applied to every point BEFORE any segment is built, so
  # that implied midpoints and elevated control points are computed in the
  # target coordinates. For an affine map that is the same curve, and it costs
  # one call per point instead of three per curve.
  set points {}
  foreach x $xs y $ys flag $flags {
    if {[llength $transform]} {
      lassign [uplevel #0 [list {*}$transform $x $y]] x y
    }
    # Only the on-curve bit says anything about the shape; [glyfOutline] keeps
    # OVERLAP_SIMPLE in the same list, and it is not about this point.
    lappend points [list $x $y [expr {$flag & 1}]]
  }

  set result {}
  set start 0
  foreach end [dict get $glyph ends] {
    # A malformed font can hand out ends that do not grow, or one past the
    # points that are there. Clamping keeps the walk inside the list rather
    # than turning empty coordinates into arithmetic errors.
    if {$end >= $count} {
      set end [expr {$count - 1}]
    }
    if {$end >= $start} {
      set contour [Contour [lrange $points $start $end]]
      if {[llength $contour]} {
        lappend result $contour
      }
      set start [expr {$end + 1}]
    }
  }
  return $result
}

# One contour's points to segments. Points are {x y onCurve}, already
# transformed.
proc ::tclpdf::glyfPath::Contour {points} {
  set count [llength $points]
  if {$count < 2} {
    return {}
  }

  # Where the pen goes down. Starting at point zero regardless is the mistake
  # this exists to avoid: point zero may be a control point.
  set first -1
  for {set index 0} {$index < $count} {incr index} {
    if {[lindex $points $index 2]} {
      set first $index
      break
    }
  }
  if {$first < 0} {
    # No on-curve point at all. The contour is a closed chain of quadratics
    # joined at implied midpoints, and any of those midpoints will do as the
    # start; the one between the last point and the first keeps the points in
    # their original order.
    set startPoint [Middle [lindex $points end] [lindex $points 0]]
    set queue $points
  } else {
    set startPoint [lrange [lindex $points $first] 0 1]
    # Rotate: the points after the start, then the ones before it. The start
    # point itself is not in the queue - the contour ends on it.
    set queue [concat [lrange $points [expr {$first + 1}] end] \
        [lrange $points 0 [expr {$first - 1}]]]
  }

  lassign $startPoint currentX currentY
  set segments {}
  set control {}
  foreach point $queue {
    lassign $point x y onCurve
    if {$onCurve} {
      if {[llength $control]} {
        lappend segments [Cubic $currentX $currentY $control $x $y]
        set control {}
      } else {
        lappend segments [list l $x $y]
      }
      set currentX $x
      set currentY $y
    } else {
      if {[llength $control]} {
        # Two off-curve points in a row: the segment ends halfway between
        # them, at the point the font does not store.
        lassign [Middle $control $point] midX midY
        lappend segments [Cubic $currentX $currentY $control $midX $midY]
        set currentX $midX
        set currentY $midY
      }
      set control [list $x $y]
    }
  }
  # Back to the start. A held control point makes that closing segment a
  # curve; otherwise closepath draws the straight line and nothing is added.
  if {[llength $control]} {
    lappend segments \
        [Cubic $currentX $currentY $control {*}[lrange $startPoint 0 1]]
  }
  if {![llength $segments]} {
    return {}
  }
  return [linsert $segments 0 $startPoint]
}

# The point halfway between two points - the on-curve point that two
# consecutive off-curve points imply.
proc ::tclpdf::glyfPath::Middle {a b} {
  return [list [expr {([lindex $a 0] + [lindex $b 0]) / 2.0}] \
      [expr {([lindex $a 1] + [lindex $b 1]) / 2.0}]]
}

# Degree elevation: the quadratic from x0 y0 over the control point to x1 y1,
# as the cubic that IS it. Both control points sit two thirds of the way from
# their end point towards the single quadratic one - exact, not fitted.
proc ::tclpdf::glyfPath::Cubic {x0 y0 control x1 y1} {
  lassign $control qx qy
  return [list c [expr {$x0 + 2.0 / 3 * ($qx - $x0)}] \
      [expr {$y0 + 2.0 / 3 * ($qy - $y0)}] \
      [expr {$x1 + 2.0 / 3 * ($qx - $x1)}] \
      [expr {$y1 + 2.0 / 3 * ($qy - $y1)}] $x1 $y1]
}

# The same outline as a PDF path: one "m" per contour, "l" and "c" for the
# segments, "h" to close it. Nothing else - no fill, no stroke, no colour and
# no graphics state.
#
# The caller appends the painting operator, and it has to be a NONZERO one:
# "f", "B", or "W n" for a clip. See the note at the top of this file for why
# "f*" is wrong even though it draws most glyphs correctly.
proc ::tclpdf::glyfPath::operators {glyph {transform {}}} {
  set result {}
  foreach contour [contours $glyph $transform] {
    append result "[Numbers [lindex $contour 0]] m\n"
    foreach segment [lrange $contour 1 end] {
      append result "[Numbers [lrange $segment 1 end]] [lindex $segment 0]\n"
    }
    append result "h\n"
  }
  return $result
}

# Coordinates the way the rest of the package writes them. There is one
# spelling for a PDF number and it lives in [pdfObj num]; a second one here
# would drift from it in the first case that rounds.
proc ::tclpdf::glyfPath::Numbers {values} {
  return [join [lmap value $values {::tclpdf::pdfObj num $value}] { }]
}

package provide tclpdf::glyfPath 1.0
