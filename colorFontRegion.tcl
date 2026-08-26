#
# tclpdf - PDF generation for Tcl
#
# colorFontRegion - what several filled outlines add up to
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# A private sub-module of colorFontPaint.tcl, and a sibling of
# colorFontBand.tcl. It holds no state, touches no document and writes no
# object: it takes CONTOURS in the shape [::tclpdf::glyfPath contours]
# returns - already carrying whatever transform the caller wanted - and
# answers two questions about the area they enclose under the nonzero winding
# rule. It knows nothing about fonts, colour or PDF.
#
# WHY THIS EXISTS. A Source In composition draws its source where the
# backdrop's alpha is 1 and nothing where it is 0. Where the backdrop is a
# stack of OPAQUE outlines that is a clip path over their union and nothing
# more, and a clip path is read alike by every reader while a soft mask
# inside a Type 3 glyph is not - colorFontBand.tcl names the two readers that
# get it wrong and why. Measured over Noto Color Emoji's 316 Source In
# tables, 250 of them are a stack of opaque outlines with a TRANSLUCENT shape
# laid over it, the shimmer on a waving flag. Their alpha is 1 inside the
# union and the translucent shape's own alpha outside it, so the mask is
# binary exactly when that shape lies INSIDE the union - a question about
# where outlines lie rather than about what the paint graph says.
#
# TWO QUESTIONS, and the first one is the one that is easy to miss.
#
# 1. IS THE CLIP EVEN THE UNION? Several outlines go into a clip as ONE path,
#    because "W n" takes one path and two clips INTERSECT rather than unite.
#    A path of several subpaths under the nonzero rule is the union of them
#    only while none of them winds against another: where a positive one
#    overlaps a negative one the winding numbers add to zero and the clip has
#    a hole exactly where the union has ink. Measured at 300 dpi over the 250
#    stacks: concatenating them as they stand differs from the union in 120
#    of the 250, by as much as 1.8 million pixels of a 2133 by 2133 page. It
#    is not a corner case, it is half of them.
#
#    The cure for most of it is to turn the outlines that run the wrong way
#    round ([reverse]), which leaves the area each of them fills exactly
#    where it was. What decides "the wrong way" is [sign], and it is NOT the
#    signed area: one of these outlines crosses itself into two lobes of
#    opposite winding whose areas nearly cancel - measured at -50.9 units
#    against a bounding box of a million - so its area says one thing and the
#    ink says another. [sign] asks the winding rule itself, at every face of
#    the outline's own arrangement, and answers "no answer" for a shape that
#    winds both ways. Such a shape cannot be made to agree with its
#    neighbours by turning it round, and the caller keeps the soft mask.
#
# 2. DOES THE TRANSLUCENT SHAPE LIE INSIDE? [inside], and the hard part is
#    the SHARED EDGE, which is the ordinary case rather than the exception.
#    The shimmer of a flag is the flag's own outline with a second contour
#    added - the same control points, to the unit - so its boundary does not
#    lie NEAR the opaque one, it lies ON it. A test that asks "is this vertex
#    inside that region" is undefined on the boundary and answers by
#    rounding; every one of the 250 would have come out at random.
#
#    So the test is over the FACES of the arrangement rather than over the
#    vertices. A region is contained iff no face of the plane lies in one and
#    not in the other, and every face of an arrangement of closed curves
#    touches an edge - so probing each edge from both sides at a small offset
#    reaches them all. Two conditions, and both are needed:
#
#      - just INSIDE the inner region, along its own boundary, the outer
#        region must be there too. This catches the inner region sticking
#        out.
#      - just OUTSIDE the outer region, along its own boundary, the inner
#        region must NOT be there. This catches a hole of the outer region
#        lying inside the inner one, which the first condition cannot see.
#
#    On a shared edge both probes sit at the same offset from the same
#    points, so the answer is the same on both sides and the coincidence
#    decides nothing - which is what makes the test usable at all.
#
# THE OFFSET IS SMALL ON PURPOSE. Too large a step walks across a thin
# protrusion and reports containment that is not there; too small a one lands
# on the wrong side of a chord where a curve was flattened differently in the
# two outlines and reports no containment where there is some. The first
# error draws wrongly, the second only keeps a soft mask, so the offset is
# chosen small: a millionth of the bounding diagonal.
#
# EDGES ARE PROBED AT THREE POINTS, not at the midpoint alone. Two contours
# that cross divide each other's edges, and a face may touch an edge over a
# stretch that does not contain its middle. Three samples along a piece that
# is already short - a cubic is cut into at least four - is the cheap end of
# a trade that has no exact end short of intersecting every pair of edges.
#
# CHECKED AGAINST A RASTERISER. Every question above was also put as a probe
# page per case and rendered with poppler at 300 dpi, one fill per outline
# for a true union and a black pixel left over for a piece that sticks out:
# the union arithmetic over all 250 stacks, and the containment of all 250
# translucent shapes: 227 of the shapes lie inside and 23 stick out, and the
# dark area of those 23 grows with the SQUARE of the resolution, so it is
# real area and not an anti-aliased edge. The answers here agree with the
# pixels on all 250, and where they refuse they refuse safely - a soft mask
# costs bytes, a wrong clip costs the picture. The whole tally, and what the
# caller does with it, is in docs/FEATURES.md.
#
# THE WINDING RULE IS ASKED OFTEN, so an outline is INDEXED before it is
# asked: the edges are bucketed by the y they span, and a query looks at the
# one bucket its y falls in. Without it the tests here are quadratic in the
# points of a glyph, and a flag of fifteen hundred outlines is not a
# theoretical size in this face.
#

package require Tcl 8.6.11-

namespace eval ::tclpdf::colorFontRegion {
  namespace export {[a-z]*}
  namespace ensemble create

  # How far off an edge a face is probed, as a fraction of the bounding
  # diagonal. See the head of this file for why the error is one-sided.
  variable offset 1e-6

  # Where along an edge it is probed, as fractions of its length.
  variable along {0.25 0.5 0.75}

  # How many straight pieces one cubic is cut into, at most and at least.
  # The floor keeps a small curve from becoming a triangle; the ceiling keeps
  # a glyph-sized one from costing points nothing looks at.
  variable least 4
  variable most 24

  # How many edges one bucket of the index holds on average, and how many
  # buckets there may be. Four is flat enough that a query reads a handful of
  # edges; the ceiling stops a glyph of a hundred thousand points from
  # building a hundred thousand empty lists.
  variable perBucket 4
  variable buckets 4096
}

# --- flattening ------------------------------------------------------------

# Contours as POLYGONS: a list of point lists, each closed implicitly, with
# every cubic cut into straight pieces.
#
# The input is what [::tclpdf::glyfPath contours] returns, so a caller that
# needs a transform applies it there and this file never sees a matrix. A
# contour of fewer than three points encloses no area and is dropped.
proc ::tclpdf::colorFontRegion::flatten {contours} {
  variable least
  variable most
  set polygons {}
  foreach contour $contours {
    set current [lindex $contour 0]
    set polygon [list $current]
    foreach segment [lrange $contour 1 end] {
      if {[lindex $segment 0] eq "l"} {
        set current [lrange $segment 1 2]
        lappend polygon $current
        continue
      }
      lassign $segment - x1 y1 x2 y2 x3 y3
      lassign $current x0 y0
      set span [expr {max(abs($x1 - $x0) + abs($y1 - $y0),
          abs($x2 - $x1) + abs($y2 - $y1),
          abs($x3 - $x2) + abs($y3 - $y2))}]
      set steps [expr {int(ceil(sqrt($span)))}]
      if {$steps < $least} {
        set steps $least
      } elseif {$steps > $most} {
        set steps $most
      }
      for {set index 1} {$index <= $steps} {incr index} {
        set t [expr {double($index) / $steps}]
        set u [expr {1.0 - $t}]
        set a [expr {$u * $u * $u}]
        set b [expr {3 * $u * $u * $t}]
        set c [expr {3 * $u * $t * $t}]
        set d [expr {$t * $t * $t}]
        lappend polygon [list \
            [expr {$a * $x0 + $b * $x1 + $c * $x2 + $d * $x3}] \
            [expr {$a * $y0 + $b * $y1 + $c * $y2 + $d * $y3}]]
      }
      set current [list $x3 $y3]
    }
    if {[llength $polygon] >= 3} {
      lappend polygons $polygon
    }
  }
  return $polygons
}

# The box {x0 y0 x1 y1} around a set of polygons, or the empty string for no
# polygons at all.
proc ::tclpdf::colorFontRegion::bounds {polygons} {
  set box {}
  foreach polygon $polygons {
    foreach point $polygon {
      lassign $point x y
      if {$box eq {}} {
        set box [list $x $y $x $y]
        continue
      }
      lset box 0 [expr {min([lindex $box 0], $x)}]
      lset box 1 [expr {min([lindex $box 1], $y)}]
      lset box 2 [expr {max([lindex $box 2], $x)}]
      lset box 3 [expr {max([lindex $box 3], $y)}]
    }
  }
  return $box
}

# --- the winding rule ------------------------------------------------------

# Polygons indexed for the winding test: the box they cover, the bucketing of
# the y axis, and one list of edges per bucket holding every edge whose y
# range reaches into it.
#
# A HORIZONTAL EDGE IS DROPPED HERE, and dropping it is the whole of what the
# crossing test needs to say about it: an edge counts where it crosses the
# ray's y, and one that lies along the ray crosses it nowhere.
proc ::tclpdf::colorFontRegion::region {polygons} {
  variable perBucket
  variable buckets
  set box [bounds $polygons]
  if {$box eq {}} {
    return [list {} 0 0 {}]
  }
  lassign $box - low - high
  set edges {}
  foreach polygon $polygons {
    lassign [lindex $polygon end] x0 y0
    foreach point $polygon {
      lassign $point x1 y1
      if {$y0 != $y1} {
        lappend edges [list $x0 $y0 $x1 $y1]
      }
      set x0 $x1
      set y0 $y1
    }
  }
  set count [expr {([llength $edges] + $perBucket - 1) / $perBucket}]
  if {$count < 1} {
    set count 1
  } elseif {$count > $buckets} {
    set count $buckets
  }
  set span [expr {double($high - $low)}]
  if {$span <= 0} {
    set count 1
    set span 1.0
  }
  # Filled through an array and assembled afterwards: [lset] into a list of
  # lists copies the sublist it grows, which turns a bucket of a thousand
  # edges into a thousand copies of itself.
  array set bucket {}
  foreach edge $edges {
    lassign $edge - y0 - y1
    set first [expr {int(((($y0 < $y1 ? $y0 : $y1) - $low) / $span) * $count)}]
    set last [expr {int(((($y0 > $y1 ? $y0 : $y1) - $low) / $span) * $count)}]
    if {$first < 0} {
      set first 0
    }
    if {$last >= $count} {
      set last [expr {$count - 1}]
    }
    for {set index $first} {$index <= $last} {incr index} {
      lappend bucket($index) $edge
    }
  }
  set table {}
  for {set index 0} {$index < $count} {incr index} {
    if {[info exists bucket($index)]} {
      lappend table $bucket($index)
    } else {
      lappend table {}
    }
  }
  return [list $box $low $span $table]
}

# The nonzero winding number of a point against an indexed region. Zero means
# the point is outside the filled area, anything else means inside.
#
# The crossing test is the half-open one - an edge counts at its lower end and
# not at its upper - so a ray through a vertex crosses once rather than twice
# or not at all.
proc ::tclpdf::colorFontRegion::winding {region px py} {
  lassign $region box low span table
  if {$box eq {}} {
    return 0
  }
  lassign $box bx0 by0 bx1 by1
  if {$py < $by0 || $py > $by1 || $px < $bx0 || $px > $bx1} {
    return 0
  }
  set count [llength $table]
  set bucket [expr {int((($py - $low) / $span) * $count)}]
  if {$bucket < 0} {
    set bucket 0
  } elseif {$bucket >= $count} {
    set bucket [expr {$count - 1}]
  }
  set total 0
  foreach edge [lindex $table $bucket] {
    lassign $edge x0 y0 x1 y1
    if {$y0 <= $py} {
      if {$y1 > $py
          && ($x1 - $x0) * ($py - $y0) - ($px - $x0) * ($y1 - $y0) > 0} {
        incr total
      }
    } elseif {$y1 <= $py
        && ($x1 - $x0) * ($py - $y0) - ($px - $x0) * ($y1 - $y0) < 0} {
      incr total -1
    }
  }
  return $total
}

# --- which way an outline winds --------------------------------------------

# 1 where the winding number of these polygons is never negative and
# somewhere positive, -1 where it is never positive and somewhere negative,
# and 0 where it is BOTH - or where there is no area at all.
#
# NOT THE SIGNED AREA, and the difference is not academic. One outline of
# Noto Color Emoji - a stripe of a flag, drawn as a band that crosses itself
# - encloses two lobes of opposite winding whose areas all but cancel: -50.9
# square units inside a bounding box of a million. Its area says it runs
# clockwise, its ink says half of it does not, and a clip built on the area
# came out with the band missing. So the winding rule is asked directly, at
# every face of the outline's own arrangement.
#
# WHAT THE ANSWER IS FOR: several outlines are clipped to as ONE path, and
# the nonzero rule makes that their union only while none of them winds
# against another. One answer per outline, [reverse] for the ones that
# disagree, and 0 for one that cannot be brought into line at all.
proc ::tclpdf::colorFontRegion::sign {polygons} {
  set region [region $polygons]
  if {[lindex $region 0] eq {}} {
    return 0
  }
  set positive 0
  set negative 0
  foreach point [Probes $polygons [Step [lindex $region 0]]] {
    set value [winding $region {*}$point]
    if {$value > 0} {
      set positive 1
    } elseif {$value < 0} {
      set negative 1
    }
    if {$positive && $negative} {
      return 0
    }
  }
  if {$positive} {
    return 1
  }
  if {$negative} {
    return -1
  }
  return 0
}

# Contours running the other way round, in the same shape they came in.
#
# A closed contour is a start point and the segments that leave it; turning it
# round means walking the segments backwards, each one ending where it began,
# and starting at the point the last of them reached. A cubic keeps its two
# control points and swaps them, because the first of them belongs to the end
# the curve leaves.
#
# Turning a WHOLE outline round leaves the area it fills exactly where it
# was: every contour of it changes sign together, so an outer contour stays
# outer and a hole stays a hole. Turning some contours and not others would
# not, which is why this takes the whole set.
proc ::tclpdf::colorFontRegion::reverse {contours} {
  set turned {}
  foreach contour $contours {
    set segments [lrange $contour 1 end]
    if {![llength $segments]} {
      lappend turned $contour
      continue
    }
    set ends [list [lindex $contour 0]]
    foreach segment $segments {
      lappend ends [lrange $segment end-1 end]
    }
    set one [list [lindex $ends end]]
    for {set index [expr {[llength $segments] - 1}]} {$index >= 0} \
        {incr index -1} {
      set segment [lindex $segments $index]
      set from [lindex $ends $index]
      if {[lindex $segment 0] eq "l"} {
        lappend one [list l {*}$from]
      } else {
        lassign $segment - x1 y1 x2 y2 - -
        lappend one [list c $x2 $y2 $x1 $y1 {*}$from]
      }
    }
    lappend turned $one
  }
  return $turned
}

# --- containment -----------------------------------------------------------

# Whether the area of "inner" lies inside the area of "outer", both under the
# nonzero winding rule and both as [flatten] returns them.
#
# A shared boundary counts as inside: the two regions this is asked about
# share one, to the control point. The head of this file says how that is
# managed and what was measured.
proc ::tclpdf::colorFontRegion::inside {inner outer} {
  if {![llength $inner]} {
    # No area at all is inside anything, including nothing.
    return 1
  }
  if {![llength $outer]} {
    return 0
  }
  set step [Step [bounds [concat $inner $outer]]]
  if {$step <= 0} {
    return 0
  }
  set within [region $inner]
  set around [region $outer]
  # The faces of BOTH arrangements, because a face of the plane may touch an
  # edge of one and none of the other: the inner region sticking out is found
  # from its own edges, a hole of the outer region lying inside it only from
  # the outer one's.
  foreach point [concat [Probes $inner $step] [Probes $outer $step]] {
    if {[winding $within {*}$point] != 0
        && [winding $around {*}$point] == 0} {
      return 0
    }
  }
  return 1
}

# How far a probe steps off an edge, for a box.
proc ::tclpdf::colorFontRegion::Step {box} {
  variable offset
  if {$box eq {}} {
    return 0
  }
  lassign $box x0 y0 x1 y1
  return [expr {$offset * (abs($x1 - $x0) + abs($y1 - $y0))}]
}

# The faces of an arrangement, reached from its own edges: three points along
# every edge, stepped off it by "step" to each side. Every face of an
# arrangement of closed curves touches an edge, so this reaches all of them;
# what each probe is IN is the caller's question and not this one's.
proc ::tclpdf::colorFontRegion::Probes {polygons step} {
  variable along
  set points {}
  foreach polygon $polygons {
    lassign [lindex $polygon end] x0 y0
    foreach point $polygon {
      lassign $point x1 y1
      set dx [expr {$x1 - $x0}]
      set dy [expr {$y1 - $y0}]
      set length [expr {hypot($dx, $dy)}]
      if {$length > 0} {
        set nx [expr {-$dy / $length * $step}]
        set ny [expr {$dx / $length * $step}]
        foreach fraction $along {
          set mx [expr {$x0 + $dx * $fraction}]
          set my [expr {$y0 + $dy * $fraction}]
          lappend points [list [expr {$mx + $nx}] [expr {$my + $ny}]] \
              [list [expr {$mx - $nx}] [expr {$my - $ny}]]
        }
      }
      set x0 $x1
      set y0 $y1
    }
  }
  return $points
}

package provide tclpdf::colorFontRegion 1.0
