#
# tclpdf - PDF generation for Tcl
#
# textAvoid - flowing a paragraph around shapes
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
#   $doc text $body -at {20 40} -width 170 -height 120 \
#       -avoid {{rect {20 40} {60 30}} {circle {150 90} 22}}
#
# A picture sits in the column and the text runs around it. The mechanism is
# the line band that textBlock.tcl already breaks against: instead of one
# width for every line, each line asks what is free at ITS height.
#
# Per line that is interval arithmetic. The line occupies a horizontal band;
# every shape that reaches into the band forbids an interval of x; what is
# left are the free segments, and the line is set in the widest of them. A
# rectangle forbids its own width; a circle forbids a chord that narrows
# towards its top and bottom - which is what makes text follow a round shape
# instead of its bounding box.
#
# Deliberately NOT here: several segments per line. A line broken around both
# sides of a shape reads as two columns that are not there, and every case in
# the invoice and letter corpus this package was built for wants the text
# beside the picture, not through it.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::geometry 1.0-
package require tclpdf::document 1.0-
package require tclpdf::textBlock 1.0-

namespace eval ::tclpdf::textAvoid {}

oo::define ::tclpdf::document::document {

  # The band command for a column with obstacles. Called per line by
  # TextBlockBreak; answers {width offset} in the document unit.
  #
  # top is the y of the block's first baseline, and the band of line n runs
  # from one leading above its baseline down to the baseline itself - the
  # letters sit above the line, so that is the room the line actually needs.
  method TextAvoidBand {shapes margin left top width leading spacing line paragraph running} {
    set baseline [expr {$top + $running * $leading + $paragraph * $spacing}]
    set bandTop [expr {$baseline - $leading}]
    set bandBottom $baseline

    set right [expr {$left + $width}]
    set blocked {}
    foreach shape $shapes {
      set interval [my TextAvoidInterval $shape $margin $bandTop $bandBottom]
      if {[llength $interval]} {
        lappend blocked $interval
      }
    }
    if {![llength $blocked]} {
      return [list $width 0]
    }

    # The free segments of {left right}, in order. Sorting first is what makes
    # overlapping shapes collapse into one gap instead of cutting each other
    # into slivers.
    set segments {}
    set cursor $left
    foreach interval [lsort -real -index 0 $blocked] {
      lassign $interval from to
      if {$to <= $cursor} {
        continue
      }
      if {$from > $cursor} {
        lappend segments [list $cursor [expr {min($from, $right)}]]
      }
      set cursor [expr {max($cursor, $to)}]
      if {$cursor >= $right} {
        break
      }
    }
    if {$cursor < $right} {
      lappend segments [list $cursor $right]
    }

    # The widest segment, and never a negative width: a line completely
    # covered gets nothing to set, and the breaker then moves its words to the
    # next line rather than producing a line of single characters.
    set best {0 0}
    set bestWidth 0
    foreach segment $segments {
      lassign $segment from to
      if {$to - $from > $bestWidth} {
        set bestWidth [expr {$to - $from}]
        set best $segment
      }
    }
    if {$bestWidth <= 0} {
      return [list 0 0]
    }
    return [list $bestWidth [expr {[lindex $best 0] - $left}]]
  }

  # Which x interval a shape forbids in the band between two y values, or the
  # empty list if it does not reach into the band at all.
  #
  # The margin grows the shape on every side before it is measured - text that
  # touches a picture reads as a mistake, and the distance wanted there is a
  # property of the layout, not of the shape. A shape may carry its own margin
  # as a fourth element, which then wins over the one given for the block.
  method TextAvoidInterval {shape margin bandTop bandBottom} {
    set kind [lindex $shape 0]
    if {[llength $shape] > 3} {
      set margin [lindex $shape 3]
    }
    switch -- $kind {
      rect {
        lassign [lindex $shape 1] x y
        lassign [lindex $shape 2] width height
        set x [expr {$x - $margin}]
        set y [expr {$y - $margin}]
        set width [expr {$width + 2 * $margin}]
        set height [expr {$height + 2 * $margin}]
        if {$y + $height <= $bandTop || $y >= $bandBottom} {
          return {}
        }
        return [list $x [expr {$x + $width}]]
      }
      circle {
        lassign [lindex $shape 1] cx cy
        set radius [expr {[lindex $shape 2] + $margin}]
        if {$cy + $radius <= $bandTop || $cy - $radius >= $bandBottom} {
          return {}
        }
        # The widest chord the band cuts out of the circle: at the band edge
        # nearest the centre, or through the centre if the band contains it.
        if {$bandTop <= $cy && $cy <= $bandBottom} {
          set distance 0
        } elseif {$bandBottom < $cy} {
          set distance [expr {$cy - $bandBottom}]
        } else {
          set distance [expr {$bandTop - $cy}]
        }
        set half [expr {sqrt($radius * $radius - $distance * $distance)}]
        return [list [expr {$cx - $half}] [expr {$cx + $half}]]
      }
      default {
        # Not reachable through [text], which checks the whole list first -
        # but a module calling in directly deserves the same message rather
        # than a second wording of it.
        my TextAvoidCheck [list $shape]
      }
    }
  }

  # Check the list once, at the call, rather than per line - a typo in a shape
  # would otherwise surface as a wrong wrap and not as an error.
  method TextAvoidCheck {shapes} {
    foreach shape $shapes {
      switch -- [lindex $shape 0] {
        rect {
          if {[llength $shape] < 3 || [llength $shape] > 4
              || [llength [lindex $shape 1]] != 2
              || [llength [lindex $shape 2]] != 2} {
            return -code error "tclpdf: an avoided rectangle is\
                {rect {x y} {width height} ?margin?}, got \"$shape\""
          }
        }
        circle {
          if {[llength $shape] < 3 || [llength $shape] > 4
              || [llength [lindex $shape 1]] != 2} {
            return -code error "tclpdf: an avoided circle is\
                {circle {x y} radius ?margin?}, got \"$shape\""
          }
        }
        default {
          return -code error "tclpdf: -avoid takes {rect {x y} {w h}} and\
              {circle {x y} r}, not \"[lindex $shape 0]\""
        }
      }
    }
    return
  }
}

package provide tclpdf::textAvoid 1.0
