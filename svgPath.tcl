#
# tclpdf - PDF generation for Tcl
#
# svgPath - turning SVG path data into PDF path operators
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# SVG has ten path commands in two spellings each; PDF has four operators.
# Everything else is arithmetic, and most of it is the elliptical arc.
#
# Measured over 1171 paths from 300 SVG files on this machine, "a" is the most
# frequent command of all - 1225 occurrences, ahead of "M" at 1222 and "c" at
# 804. That contradicts the reasonable guess that Bezier curves dominate, and
# it decides how much of this file is worth writing: PDF has no arc operator
# at all, so every one of those has to become up to four Bezier segments.
#
# The commands and what becomes of them:
#
#   M m   moveto            -> m
#   L l   lineto            -> l
#   H h   horizontal        -> l, the missing coordinate carried over
#   V v   vertical          -> l
#   C c   cubic Bezier      -> c
#   S s   smooth cubic      -> c, first control point mirrored
#   Q q   quadratic Bezier  -> c, degree-elevated (PDF has no quadratic)
#   T t   smooth quadratic  -> c
#   A a   elliptical arc    -> up to four c segments
#   Z z   close             -> h
#
# This is a private sub-module behind the [svg] facade.
#

package require Tcl 8.6.11-
package require tclpdf::pdfObj 1.0-
package require tclpdf::geometry 1.4-

namespace eval ::tclpdf::svgPath {
  namespace export {[a-z]*}
  namespace ensemble create
}

# Turn path data into PDF operators. The coordinate transform is a command
# prefix called with x and y, returning the pair in PDF space - that way this
# module knows nothing about pages, units or the y axis.
proc ::tclpdf::svgPath::operators {data transform} {
  set numbers {}
  set commands [Tokenize $data]
  set x 0.0
  set y 0.0
  set startX 0.0
  set startY 0.0
  # The reflected control point of the previous curve, for S and T.
  set lastControlX {}
  set lastControlY {}
  set previous {}
  set result {}

  foreach {command arguments} $commands {
    set relative [string is lower -strict $command]
    set upper [string toupper $command]
    set step [dict get {M 2 L 2 H 1 V 1 C 6 S 4 Q 4 T 2 A 7 Z 0} $upper]
    if {$step == 0} {
      append result "h\n"
      set x $startX
      set y $startY
      set previous Z
      continue
    }
    if {[llength $arguments] % $step} {
      return -code error -errorcode [list TCLPDF SVG PATH $command] \
          "tclpdf: path command \"$command\" takes groups of\
          $step numbers, got [llength $arguments]"
    }

    set first 1
    foreach group [Groups $arguments $step] {
      switch -- $upper {
        M {
          lassign $group dx dy
          set x [expr {$relative ? $x + $dx : $dx}]
          set y [expr {$relative ? $y + $dy : $dy}]
          if {$first} {
            append result "[Point $transform $x $y] m\n"
            set startX $x
            set startY $y
          } else {
            # A moveto with more than one pair continues as lineto - the
            # single most common way a hand-written parser loses geometry.
            append result "[Point $transform $x $y] l\n"
          }
          set lastControlX {}
        }
        L {
          lassign $group dx dy
          set x [expr {$relative ? $x + $dx : $dx}]
          set y [expr {$relative ? $y + $dy : $dy}]
          append result "[Point $transform $x $y] l\n"
          set lastControlX {}
        }
        H {
          set x [expr {$relative ? $x + [lindex $group 0] : [lindex $group 0]}]
          append result "[Point $transform $x $y] l\n"
          set lastControlX {}
        }
        V {
          set y [expr {$relative ? $y + [lindex $group 0] : [lindex $group 0]}]
          append result "[Point $transform $x $y] l\n"
          set lastControlX {}
        }
        C {
          lassign $group x1 y1 x2 y2 dx dy
          if {$relative} {
            set x1 [expr {$x + $x1}]
            set y1 [expr {$y + $y1}]
            set x2 [expr {$x + $x2}]
            set y2 [expr {$y + $y2}]
            set dx [expr {$x + $dx}]
            set dy [expr {$y + $dy}]
          }
          append result "[Point $transform $x1 $y1] [Point $transform $x2 $y2]\
              [Point $transform $dx $dy] c\n"
          set lastControlX $x2
          set lastControlY $y2
          set x $dx
          set y $dy
        }
        S {
          lassign $group x2 y2 dx dy
          if {$relative} {
            set x2 [expr {$x + $x2}]
            set y2 [expr {$y + $y2}]
            set dx [expr {$x + $dx}]
            set dy [expr {$y + $dy}]
          }
          # The first control point is the previous one mirrored through the
          # current point - unless the previous command was not a cubic, in
          # which case it coincides with the current point (SVG 8.3.6).
          if {$lastControlX ne {} && $previous in {C S}} {
            set x1 [expr {2 * $x - $lastControlX}]
            set y1 [expr {2 * $y - $lastControlY}]
          } else {
            set x1 $x
            set y1 $y
          }
          append result "[Point $transform $x1 $y1] [Point $transform $x2 $y2]\
              [Point $transform $dx $dy] c\n"
          set lastControlX $x2
          set lastControlY $y2
          set x $dx
          set y $dy
        }
        Q - T {
          if {$upper eq "Q"} {
            lassign $group qx qy dx dy
            if {$relative} {
              set qx [expr {$x + $qx}]
              set qy [expr {$y + $qy}]
              set dx [expr {$x + $dx}]
              set dy [expr {$y + $dy}]
            }
          } else {
            lassign $group dx dy
            if {$relative} {
              set dx [expr {$x + $dx}]
              set dy [expr {$y + $dy}]
            }
            if {$lastControlX ne {} && $previous in {Q T}} {
              set qx [expr {2 * $x - $lastControlX}]
              set qy [expr {2 * $y - $lastControlY}]
            } else {
              set qx $x
              set qy $y
            }
          }
          # Degree elevation: a quadratic curve is exactly a cubic whose
          # control points sit two thirds of the way to the single one. PDF
          # has no quadratic operator, and this conversion is exact - not an
          # approximation.
          set x1 [expr {$x + 2.0 / 3 * ($qx - $x)}]
          set y1 [expr {$y + 2.0 / 3 * ($qy - $y)}]
          set x2 [expr {$dx + 2.0 / 3 * ($qx - $dx)}]
          set y2 [expr {$dy + 2.0 / 3 * ($qy - $dy)}]
          append result "[Point $transform $x1 $y1] [Point $transform $x2 $y2]\
              [Point $transform $dx $dy] c\n"
          set lastControlX $qx
          set lastControlY $qy
          set x $dx
          set y $dy
        }
        A {
          lassign $group rx ry rotation large sweep dx dy
          if {$relative} {
            set dx [expr {$x + $dx}]
            set dy [expr {$y + $dy}]
          }
          append result [Arc $transform $x $y $rx $ry $rotation $large $sweep $dx $dy]
          set x $dx
          set y $dy
          set lastControlX {}
        }
      }
      set first 0
    }
    set previous $upper
  }
  return $result
}

# An elliptical arc as Bezier segments (SVG implementation notes F.6).
#
# The arc is given by its END POINT, which is convenient to write and useless
# to draw with: the centre has to be recovered first. That is what the bulk of
# this is - the actual curve is four lines at the end.
proc ::tclpdf::svgPath::Arc {transform x0 y0 rx ry rotation large sweep x1 y1} {
  set rx [expr {abs($rx)}]
  set ry [expr {abs($ry)}]
  if {$rx == 0 || $ry == 0 || ($x0 == $x1 && $y0 == $y1)} {
    # A degenerate arc is a straight line, and the specification says so
    # rather than leaving it undefined.
    return "[Point $transform $x1 $y1] l\n"
  }
  set pi [expr {acos(-1)}]
  set phi [expr {$rotation * $pi / 180.0}]
  set cosPhi [expr {cos($phi)}]
  set sinPhi [expr {sin($phi)}]

  # Step 1: the end point in the ellipse's own frame.
  set halfX [expr {($x0 - $x1) / 2.0}]
  set halfY [expr {($y0 - $y1) / 2.0}]
  set primeX [expr {$cosPhi * $halfX + $sinPhi * $halfY}]
  set primeY [expr {-$sinPhi * $halfX + $cosPhi * $halfY}]

  # Radii too small for the distance are scaled up until they fit, rather
  # than producing a curve that misses its own end point.
  set check [expr {$primeX * $primeX / ($rx * $rx) + $primeY * $primeY / ($ry * $ry)}]
  if {$check > 1} {
    set scale [expr {sqrt($check)}]
    set rx [expr {$rx * $scale}]
    set ry [expr {$ry * $scale}]
  }

  # Step 2: the centre.
  set numerator [expr {$rx * $rx * $ry * $ry - $rx * $rx * $primeY * $primeY -
      $ry * $ry * $primeX * $primeX}]
  if {$numerator < 0} {
    set numerator 0
  }
  set factor [expr {sqrt($numerator / ($rx * $rx * $primeY * $primeY +
      $ry * $ry * $primeX * $primeX))}]
  if {$large == $sweep} {
    set factor [expr {-$factor}]
  }
  set centrePrimeX [expr {$factor * $rx * $primeY / $ry}]
  set centrePrimeY [expr {-$factor * $ry * $primeX / $rx}]
  set centreX [expr {$cosPhi * $centrePrimeX - $sinPhi * $centrePrimeY + ($x0 + $x1) / 2.0}]
  set centreY [expr {$sinPhi * $centrePrimeX + $cosPhi * $centrePrimeY + ($y0 + $y1) / 2.0}]

  # Step 3: start angle and sweep.
  set startAngle [Angle 1 0 [expr {($primeX - $centrePrimeX) / $rx}] \
      [expr {($primeY - $centrePrimeY) / $ry}]]
  set delta [Angle [expr {($primeX - $centrePrimeX) / $rx}] \
      [expr {($primeY - $centrePrimeY) / $ry}] \
      [expr {(-$primeX - $centrePrimeX) / $rx}] \
      [expr {(-$primeY - $centrePrimeY) / $ry}]]
  if {!$sweep && $delta > 0} {
    set delta [expr {$delta - 2 * $pi}]
  } elseif {$sweep && $delta < 0} {
    set delta [expr {$delta + 2 * $pi}]
  }

  # Step 4: the curve itself - one Bezier segment per quarter turn or less.
  # That arithmetic is not written here: [shape arc] needs exactly the same
  # segments from the CENTRE parametrisation it is handed, so it lives in
  # geometry, where neither of its two callers owns it. What stays here is
  # steps 1 to 3, which are what the endpoint parametrisation costs.
  set result {}
  foreach segment [::tclpdf::geometry::arcSegments $centreX $centreY $rx $ry \
      $cosPhi $sinPhi $startAngle $delta] {
    lassign $segment x1 y1 x2 y2 endX endY
    append result "[Point $transform $x1 $y1] \
        [Point $transform $x2 $y2] [Point $transform $endX $endY] c\n"
  }
  return $result
}

# The signed angle between two vectors.
proc ::tclpdf::svgPath::Angle {ux uy vx vy} {
  set dot [expr {$ux * $vx + $uy * $vy}]
  set lengths [expr {sqrt(($ux * $ux + $uy * $uy) * ($vx * $vx + $vy * $vy))}]
  if {$lengths == 0} {
    return 0
  }
  set cosine [expr {$dot / $lengths}]
  # Rounding can push this a hair outside the domain of acos, and then the
  # whole path throws on a value that is mathematically exactly 1.
  if {$cosine > 1} {
    set cosine 1
  } elseif {$cosine < -1} {
    set cosine -1
  }
  set angle [expr {acos($cosine)}]
  if {$ux * $vy - $uy * $vx < 0} {
    return [expr {-$angle}]
  }
  return $angle
}

# Split path data into commands with their numbers.
#
# The lexical rules are looser than they look: separators are optional where
# the meaning is clear, so "M0 0L10 10" and "m.5.5" are both legal, and the
# second one is two numbers, not one. A plain [split] gets that wrong.
proc ::tclpdf::svgPath::Tokenize {data} {
  set result {}
  set command {}
  set numbers {}
  foreach token [regexp -all -inline \
      {[MmLlHhVvCcSsQqTtAaZz]|[-+]?(?:[0-9]*\.[0-9]+|[0-9]+\.?)(?:[eE][-+]?[0-9]+)?} $data] {
    if {[string is alpha -strict $token]} {
      if {$command ne {}} {
        lappend result $command $numbers
      }
      set command $token
      set numbers {}
    } else {
      lappend numbers $token
    }
  }
  if {$command ne {}} {
    lappend result $command $numbers
  }
  return $result
}

proc ::tclpdf::svgPath::Groups {values size} {
  set result {}
  for {set index 0} {$index < [llength $values]} {incr index $size} {
    lappend result [lrange $values $index [expr {$index + $size - 1}]]
  }
  return $result
}

proc ::tclpdf::svgPath::Point {transform x y} {
  lassign [uplevel #0 [list {*}$transform $x $y]] px py
  return "[::tclpdf::pdfObj num $px] [::tclpdf::pdfObj num $py]"
}

package provide tclpdf::svgPath 1.2
