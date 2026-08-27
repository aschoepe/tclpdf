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
  # TextBlockBreak; answers {width offset skipped} in the document unit.
  #
  # It wraps another band - the one the indents make - and narrows what that
  # one leaves: the offset it answers is measured from x, the left edge of
  # the block, exactly like the base band's, so the two compose instead of
  # one replacing the other.
  #
  # top is the y of the block's first baseline, and the band of line n runs
  # from one leading above its baseline down to the baseline itself - the
  # letters sit above the line, so that is the room the line actually needs.
  #
  # minimum is the least width worth setting anything in - the widest single
  # character of the text. A line whose free segment is narrower than that is
  # SKIPPED: the band moves down a line and looks again, and tells the breaker
  # how many lines it left empty. Answering a width of zero, or of a sliver,
  # did not do that: the breaker's character fallback took one character
  # anyway, and a shape wider than the column had the text running through
  # it one letter per line. Only a shape ever causes a skip - a column
  # narrower than the minimum with nothing in the way is answered as it is.
  #
  # AND THE SKIPPING STOPS AT THE FOOT OF THE PAGE. Until 2026-08-27 it did
  # not stop at all: the loop moved down one leading at a time until the
  # shapes let it through, and nothing said how far it might go. What that
  # cost was measured with the reviewer's probes - a rectangle 1e38 high, and
  # an -avoidMargin of 1e39 on a rectangle of 5 by 5 - and it is not a slow
  # answer but no answer: the walk is linear in the height of the obstacle,
  # so at 1e38 it never comes back, with -height max as well and in
  # [textHeight] just the same. Short of that it was silent rather than
  # endless: an obstacle 5000 mm high set the text at y = 5023 mm, off every
  # page there is, and answered as if it had drawn something.
  #
  # The bound is the page itself, which is where a line can be seen: a
  # baseline below the foot of the media box is not a line any more, so the
  # band stops looking there and answers the width underneath together with
  # the lines it left empty. The walk is therefore at most the height of the
  # page divided by the leading of the block. It is bounded HERE rather than
  # at the call because it is not a property of any one shape - a rectangle
  # reaching past the foot of the page is perfectly good input as long as it
  # lets the column through somewhere above it, which is exactly what the
  # loop finds out.
  method TextAvoidBand {shapes margin x top leading spacing minimum base line paragraph running} {
    lassign [{*}$base $line $paragraph $running] width offset
    set left [expr {$x + $offset}]
    set right [expr {$left + $width}]
    lassign [my page size] -> pageHeight
    set skipped 0
    while {1} {
      set baseline [expr {$top + ($running + $skipped) * $leading + $paragraph * $spacing}]
      set bandTop [expr {$baseline - $leading}]
      set bandBottom $baseline

      set blocked {}
      foreach shape $shapes {
        set interval [my TextAvoidInterval $shape $margin $bandTop $bandBottom]
        if {[llength $interval]} {
          lappend blocked $interval
        }
      }
      if {![llength $blocked]} {
        return [list $width $offset $skipped]
      }

      # The free segments of {left right}, in order. Sorting first is what
      # makes overlapping shapes collapse into one gap instead of cutting each
      # other into slivers.
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

      # The widest segment. Wide enough for a character, and the line is set
      # in it; otherwise the line stays empty and the next one is tried.
      set best {0 0}
      set bestWidth 0
      foreach segment $segments {
        lassign $segment from to
        if {$to - $from > $bestWidth} {
          set bestWidth [expr {$to - $from}]
          set best $segment
        }
      }
      if {$bestWidth >= $minimum && $bestWidth > 0} {
        return [list $bestWidth [expr {[lindex $best 0] - $x}] $skipped]
      }
      # THE WALK STOPS AT THE FOOT OF THE PAGE. Below it there is no line to
      # move to, so the band gives up looking and answers what it would have
      # answered once the shapes ended: the width and the offset of the band
      # underneath, and the number of lines it left empty. That number is
      # what the callers already read - [TextBlockNoRoom] compares it against
      # -height and hands the whole text back as the rest, which is how a
      # page the shapes cover completely ends up drawing nothing and
      # continuing on the next one (textFlow-11.2, -11.3). An answer rather
      # than a refusal for exactly that reason: "the shapes leave nothing on
      # this page" is a layout the package supports, and it was built in
      # round 7; what was missing is only that the walk had no end.
      if {$baseline > $pageHeight} {
        return [list $width $offset $skipped]
      }
      incr skipped
    }
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
  # would otherwise surface as a wrong wrap and not as an error. The margin
  # is the -avoidMargin of the call, checked with the shapes because it is
  # added to every one of them: "abc" there used to reach the band and fail
  # in Tcl's words.
  method TextAvoidCheck {shapes {margin 0}} {
    # [text::finite] rather than [string is double]: NaN is a double to Tcl,
    # and a NaN margin travelled into the band arithmetic where every
    # comparison against it is false - the shape then narrowed no line at all
    # and the text ran straight through it, in silence. The shapes themselves
    # are read by the pattern below, which has no spelling for NaN.
    # BELOW ZERO IS NOT A MARGIN. The manual has one sentence about it - it
    # "holds the text off" a shape - and a negative value does the opposite:
    # the band is widened into the shape and the lines run through it, which
    # is exactly what -avoid is asked for to prevent, and nothing says so.
    if {![::tclpdf::text::finite $margin] || $margin < 0} {
      return -code error -errorcode [list TCLPDF TEXT AVOID margin] \
          "tclpdf: -avoidMargin takes a distance of 0 or\
          more in the document unit - it is how far the text is held off the\
          shapes - not \"$margin\""
    }
    # AND A DISTANCE THE FILE CAN HOLD (Annex C.2, the range [pdfObj fits]
    # keeps, asked through [text::writable] like every other distance of a
    # block). The margin grows every shape on all four sides, so a magnitude
    # past the range does not narrow a line, it moves the band down for ever:
    # measured 2026-08-27, "-avoidMargin 1e39" on a rectangle of five
    # millimetres did not come back. The manual (:77) says a length beyond the
    # range is refused at the call; this is one of the four places where it
    # was not.
    if {![::tclpdf::text::writable $margin]} {
      return -code error -errorcode [list TCLPDF TEXT AVOID margin] \
          "tclpdf: -avoidMargin is \"$margin\", which is beyond the distance a\
          document can carry - [::tclpdf::text::rangeHint]"
    }
    foreach shape $shapes {
      # The numbers are checked here as well as the shape of the list: a
      # rectangle built from a value that turned out empty - the return of
      # a call that answers nothing, say - used to fail deep in the band
      # arithmetic with Tcl's own words. And the SIZE has to be one: a
      # rectangle of no width, or of a negative one, and a circle of no
      # radius are not shapes on the page - they passed, and the wrap was
      # whatever the band arithmetic made of them, in silence.
      set numbers [concat {*}[lrange $shape 1 end]]
      switch -- [lindex $shape 0] {
        rect {
          if {[llength $shape] < 3 || [llength $shape] > 4
              || [llength [lindex $shape 1]] != 2
              || [llength [lindex $shape 2]] != 2
              || [lsearch -not -regexp $numbers {^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$}] >= 0} {
            return -code error -errorcode [list TCLPDF TEXT AVOID rect] \
                "tclpdf: an avoided rectangle is\
                {rect {x y} {width height} ?margin?}, got \"$shape\""
          }
          lassign [lindex $shape 2] width height
          if {$width <= 0 || $height <= 0} {
            return -code error -errorcode [list TCLPDF TEXT AVOID rect] \
                "tclpdf: an avoided rectangle needs a width\
                and a height above zero, got {$width $height} in \"$shape\""
          }
        }
        circle {
          if {[llength $shape] < 3 || [llength $shape] > 4
              || [llength [lindex $shape 1]] != 2
              || [lsearch -not -regexp $numbers {^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$}] >= 0} {
            return -code error -errorcode [list TCLPDF TEXT AVOID circle] \
                "tclpdf: an avoided circle is\
                {circle {x y} radius ?margin?}, got \"$shape\""
          }
          if {[lindex $shape 2] <= 0} {
            return -code error -errorcode [list TCLPDF TEXT AVOID circle] \
                "tclpdf: an avoided circle needs a radius\
                above zero, got [lindex $shape 2] in \"$shape\""
          }
        }
        default {
          return -code error -errorcode [list TCLPDF TEXT AVOID shape] \
              "tclpdf: -avoid takes {rect {x y} {w h}} and\
              {circle {x y} r}, not \"[lindex $shape 0]\""
        }
      }
      # AND EVERY NUMBER OF THE SHAPE IS ONE THE DOCUMENT CAN CARRY. The
      # pattern above spells no NaN and no Inf, but it spells 1e38 perfectly
      # well, and a magnitude like that is not a shape on a page: the band
      # walks down it one line at a time (see TextAvoidBand), so
      # "-avoid {{rect {0 0} {300 1e38}}}" did not come back at all before
      # 2026-08-27. The band refuses that walk at the foot of the page now;
      # this refuses the number at the CALL, which is where the manual (:77)
      # says a length beyond the range of a PDF real is refused, and it names
      # the shape rather than the line the walk gave up on.
      foreach number $numbers {
        if {![::tclpdf::text::writable $number]} {
          return -code error \
              -errorcode [list TCLPDF TEXT AVOID [lindex $shape 0]] \
              "tclpdf: the avoided [lindex $shape 0] \"$shape\" carries\
              \"$number\", which is beyond the distance a document can carry -\
              [::tclpdf::text::rangeHint]"
        }
      }
    }
    return
  }
}

package provide tclpdf::textAvoid 1.5
