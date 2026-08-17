#
# tclpdf - PDF generation for Tcl
#
# geometry - units, page sizes and transformation matrices (8.3)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Infrastructure used by the document (page boxes) and by the graphics module
# (matrices) alike, which is why it is neither of them.
#
# PDF measures in points: 1 pt = 1/72 inch, and the origin sits in the BOTTOM
# left corner with y growing upwards. Both differ from what most callers
# expect, so the conversion belongs in one place instead of at every call.
#

package require Tcl 8.6.11-

namespace eval ::tclpdf::geometry {
  namespace export {[a-z]*}
  namespace ensemble create

  # How many points one unit is. The mm factor is 72/25.4 exactly - writing it
  # out rather than as a rounded constant keeps A4 at 595.28 x 841.89 pt.
  variable units {
    pt 1.0
    px 1.0
    mm 2.8346456692913385
    cm 28.346456692913385
    in 72.0
  }

  # Page sizes in MILLIMETRES, portrait. The ISO A series is defined that way,
  # and deriving the points from it keeps one rounding step instead of two.
  variable sizes {
    a0 {841 1189} a1 {594 841} a2 {420 594} a3 {297 420}
    a4 {210 297} a5 {148 210} a6 {105 148} a7 {74 105}
    b4 {250 353} b5 {176 250}
    c4 {229 324} c5 {162 229} c6 {114 162}
    dl {110 220}
    letter {215.9 279.4} legal {215.9 355.6} tabloid {279.4 431.8}
    executive {184.15 266.7}
  }
}

# Convert a value into points.
proc ::tclpdf::geometry::toPoints {value {unit mm}} {
  variable units
  set key [string tolower $unit]
  if {![dict exists $units $key]} {
    return -code error "tclpdf: unknown unit \"$unit\" - use pt, px, mm, cm or in"
  }
  if {![string is double -strict $value]} {
    return -code error "tclpdf: not a measurement: \"$value\""
  }
  return [expr {$value * [dict get $units $key]}]
}

# And back, for reporting positions to the caller in the unit they chose.
proc ::tclpdf::geometry::fromPoints {value {unit mm}} {
  variable units
  set key [string tolower $unit]
  if {![dict exists $units $key]} {
    return -code error "tclpdf: unknown unit \"$unit\" - use pt, px, mm, cm or in"
  }
  return [expr {$value / [dict get $units $key]}]
}

# A page size in points, as {width height}.
#
# The format may be a name ("a4"), or a two-element list in a unit
# ({210 297} mm). Orientation swaps the two - it is applied AFTER the size is
# known, so "a4 landscape" and "{297 210} mm" describe the same page.
# The size of a page in points.
#
# format is either a name from the table ("a4") or two numbers in the given
# unit. orientation is portrait, landscape, hoch or quer - or EMPTY, which
# means "as given" and only makes sense together with two numbers.
proc ::tclpdf::geometry::pageSize {format {orientation portrait} {unit mm}} {
  variable sizes
  if {[llength $format] == 2} {
    lassign $format width height
    set width [toPoints $width $unit]
    set height [toPoints $height $unit]
    if {$orientation eq {}} {
      # A size given as two numbers is taken as it stands. Applying the
      # default orientation to it would turn a 88 by 55 label into 55 by 88 -
      # the caller has already said which way round it goes by writing the
      # numbers in that order. A named format is different: "a4" IS 210 by
      # 297, and landscape turns it.
      return [list $width $height]
    }
  } else {
    set key [string tolower $format]
    if {![dict exists $sizes $key]} {
      return -code error "tclpdf: unknown page format \"$format\" -\
          known are: [join [lsort [dict keys $sizes]] {, }]"
    }
    lassign [dict get $sizes $key] width height
    set width [toPoints $width mm]
    set height [toPoints $height mm]
  }
  if {$orientation eq {}} {
    set orientation portrait
  }
  switch -- [string tolower $orientation] {
    portrait - hoch {
      # Given as landscape but asked for portrait: swap.
      if {$width > $height} {
        lassign [list $height $width] width height
      }
    }
    landscape - quer {
      if {$width < $height} {
        lassign [list $height $width] width height
      }
    }
    default {
      return -code error "tclpdf: orientation must be portrait or landscape,\
          not \"$orientation\""
    }
  }
  return [list $width $height]
}

# The names of all known page formats - for error messages and for tests.
proc ::tclpdf::geometry::formats {} {
  variable sizes
  return [lsort [dict keys $sizes]]
}

# A transformation matrix is the six numbers of the cm operator: {a b c d e f}.
proc ::tclpdf::geometry::identity {} {
  return {1 0 0 1 0 0}
}

proc ::tclpdf::geometry::translate {dx dy} {
  return [list 1 0 0 1 $dx $dy]
}

proc ::tclpdf::geometry::scale {sx {sy {}}} {
  if {$sy eq {}} {
    set sy $sx
  }
  return [list $sx 0 0 $sy 0 0]
}

# Rotation is counter-clockwise, in degrees, about the current origin - the
# same direction as in mathematics, because the PDF coordinate system already
# has y pointing up.
proc ::tclpdf::geometry::rotate {degrees} {
  set radians [expr {$degrees * acos(-1) / 180.0}]
  set cosine [expr {cos($radians)}]
  set sine [expr {sin($radians)}]
  return [list $cosine $sine [expr {-$sine}] $cosine 0 0]
}

proc ::tclpdf::geometry::skew {alpha beta} {
  set factor [expr {acos(-1) / 180.0}]
  return [list 1 [expr {tan($alpha * $factor)}] [expr {tan($beta * $factor)}] 1 0 0]
}

# Multiply two matrices. Order matters: [multiply $a $b] applies A first and
# then B, which is the order the cm operators appear in the content stream.
proc ::tclpdf::geometry::multiply {first second} {
  lassign $first a1 b1 c1 d1 e1 f1
  lassign $second a2 b2 c2 d2 e2 f2
  return [list \
      [expr {$a1 * $a2 + $b1 * $c2}] \
      [expr {$a1 * $b2 + $b1 * $d2}] \
      [expr {$c1 * $a2 + $d1 * $c2}] \
      [expr {$c1 * $b2 + $d1 * $d2}] \
      [expr {$e1 * $a2 + $f1 * $c2 + $e2}] \
      [expr {$e1 * $b2 + $f1 * $d2 + $f2}]]
}

# Apply a matrix to a point - needed to know where something ended up, for
# instance to place a link annotation over rotated text.
proc ::tclpdf::geometry::apply {matrix x y} {
  lassign $matrix a b c d e f
  return [list [expr {$a * $x + $c * $y + $e}] [expr {$b * $x + $d * $y + $f}]]
}

# Refuse a matrix a caller hands in raw - the -matrix option of transform,
# pattern create and shading - before it is written anywhere. Returns the
# matrix; the error names the owner ("pattern \"hatch\"", "transform",
# "shading axial") so the caller does not have to.
#
# Six numbers, no more and no fewer: a matrix is the six operands of cm
# (8.3.4, Table 75), and a reader given five has no rule for which one is
# missing. Numbers, and finite ones - Inf and NaN pass "string is double" but
# have no PDF spelling (7.3.3). And not singular: a*d - b*c = 0 collapses the
# space onto a line or a point, everything drawn under a cm like that or
# filled with such a pattern comes out invisible, and neither a reader nor a
# validator says why - it is a well-formed array in the right place.
#
# The determinant is compared with 0 exactly, not against a tolerance. The
# case that has to be caught is the caller who wrote {1 2 2 4 0 0} - two
# proportional columns, and 1*4 - 2*2 is exactly 0 in floating point. A small
# determinant, on the other hand, is a small matrix, not a singular one:
# {0.001 0 0 0.001 0 0} maps a coordinate space of thousands onto the page and
# a reader inverts it without trouble; a tolerance would refuse exactly such
# legitimate values while still letting through a rounded 1e-17 from a
# computed matrix that is as good as singular. Neither error can be told from
# the number alone, so only the exact case is refused.
proc ::tclpdf::geometry::check {matrix what} {
  if {[llength $matrix] != 6} {
    return -code error "tclpdf: -matrix of $what is six numbers {a b c d e f},\
        not [llength $matrix]"
  }
  foreach number $matrix {
    if {![string is double -strict $number] || [catch {expr {$number - $number}}]} {
      return -code error "tclpdf: -matrix of $what takes numbers, not \"$number\""
    }
  }
  lassign $matrix a b c d
  if {$a * $d - $b * $c == 0} {
    return -code error "tclpdf: -matrix of $what is singular ({$matrix}) -\
        a*d - b*c must not be zero, or everything under it collapses onto a\
        line"
  }
  return $matrix
}

package provide tclpdf::geometry 1.1
