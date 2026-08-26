#
# tclpdf - PDF generation for Tcl
#
# shape - the drawing primitives (8.5.2)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Split off graphics.tcl when that file passed the review limit: state
# handling and shape construction are two topics, and only the state half
# is needed by text and images as well.
#
# Every shape ends in ShapePaint, which joins GraphicsStyle and GraphicsPaint
# from graphics.tcl - the style prologue and the painting operator exist once
# for all of them - and writes the finished path in a single call.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::graphics 1.0-
package require tclpdf::option 1.0-
package require tclpdf::geometry 1.0-

namespace eval ::tclpdf::shape {}

# Refuse a malformed segment list by name, before anything is written or
# measured. A namespace proc rather than a private method because textPath is
# its second consumer: it flattens the same segment lists into a polyline, and
# without this check a wrong operand count or a non-number crashed in its
# arithmetic ("can't use non-numeric string...") where [path] refuses by name.
#
#   {move 2 line 2 curve 6 close 0}  -  the segment kinds and their operand
#   counts, stated once here for every consumer.
proc ::tclpdf::shape::checkSegments {segments} {
  if {![llength $segments]} {
    return -code error -errorcode [list TCLPDF SHAPE SEGMENTS empty] \
        "tclpdf: -segments is empty - a path needs at least\
        a {move x y}"
  }
  set operands {move 2 line 2 curve 6 close 0}
  set first 1
  foreach segment $segments {
    set kind [lindex $segment 0]
    if {![dict exists $operands $kind]} {
      return -code error -errorcode [list TCLPDF SHAPE SEGMENTS $kind] \
          "tclpdf: unknown path segment \"$kind\" -\
          known are: move, line, curve, close"
    }
    # A path begins with a move: "l" and "c" extend from the current
    # point, and before the first "m" there is none (8.5.2.1). A reader
    # may draw from wherever it happens to be, or nothing - so it is
    # refused here.
    if {$first && $kind ne "move"} {
      return -code error -errorcode [list TCLPDF SHAPE SEGMENTS move] \
          "tclpdf: a path starts with {move x y}, not\
          {$segment}"
    }
    set first 0
    # The count is checked, not just the numbers: {line 3} would otherwise
    # pair its 3 with nothing and go out as one operand short.
    if {[llength $segment] - 1 != [dict get $operands $kind]} {
      return -code error -errorcode [list TCLPDF SHAPE SEGMENTS $kind] \
          "tclpdf: path segment \"$kind\" takes\
          [dict get $operands $kind] numbers, not [expr {[llength $segment] - 1}]"
    }
    # The numbers themselves, through the one parser that owns the wording:
    # the converted value is not wanted here, only the refusal.
    foreach value [lrange $segment 1 end] {
      ::tclpdf::geometry::toPoints $value
    }
  }
  return
}

oo::define ::tclpdf::document::document {

  # -- shapes -------------------------------------------------------------

  method line {args} {
    set options [::tclpdf::option parse {
      from {} to {} stroke {} width {} dash {} cap {} join {} miter {} opacity {} blend {} overprint {}
    } $args]
    # ONE OPTION PER REFUSAL. The fourth word of a TCLPDF SHAPE ARGUMENT code
    # is the option that is wrong, spelt without its dash - the convention
    # STRUCTURE already states in the manual, and the one this file kept in
    # three different ways until 2026-08-26 (the command for one refusal, the
    # option for the next, the option WITH its dash for a third). A handler
    # cannot read a word that means three things.
    foreach key {from to} {
      if {[dict get $options $key] eq {}} {
        return -code error -errorcode [list TCLPDF SHAPE ARGUMENT $key] \
            "tclpdf: line needs -from {x y} and -to {x y}"
      }
    }
    # A line is drawn in black unless told otherwise - by its own -stroke, or
    # by the stroke colour [style] set before it.
    if {[dict get $options stroke] eq {} && [my streamState styleStroke] eq {}} {
      dict set options stroke black
    }
    lassign [my GraphicsPoint [dict get $options from] -from line] x0 y0
    lassign [my GraphicsPoint [dict get $options to] -to line] x1 y1
    # Through ShapePaint like every other shape rather than a hard-coded
    # "S": a line has no fill, so the operator comes out the same - but the
    # closing "Q" of the state guard does not exist twice.
    my ShapePaint line $options "[::tclpdf::pdfObj num $x0] [::tclpdf::pdfObj num $y0] m\
        [::tclpdf::pdfObj num $x1] [::tclpdf::pdfObj num $y1] l\n"
    return
  }

  # -at is the TOP left corner, because that is where a caller counting from
  # the top of the page expects a box to start.
  method rect {args} {
    set options [::tclpdf::option parse {
      at {} size {} fill {} stroke {} width {} dash {} radius 0
      cap {} join {} miter {} opacity {} blend {} overprint {} rule nonzero
    } $args]
    foreach key {at size} {
      if {[dict get $options $key] eq {}} {
        return -code error -errorcode [list TCLPDF SHAPE ARGUMENT $key] \
            "tclpdf: rect needs -at {x y} and -size {w h}"
      }
    }
    lassign [my ShapeBox $options rect] x y w h
    set radius [my ShapeRadius [dict get $options radius] -radius]
    if {$radius > 0} {
      # A NEGATIVE EXTENT AND A ROUNDED CORNER DO NOT GO TOGETHER. "re" takes
      # a negative width (8.5.2.1) and [ShapeBox] lets it through on purpose,
      # but the rounding arithmetic does not survive it: the cap
      # "min(w,h)/2" is then negative, the radius is capped to that negative
      # value and the four arcs run backwards - measured 2026-08-26, a red
      # band with two white lenses in it instead of a rounded rectangle.
      # Refused rather than normalised, because a caller who wrote a negative
      # size and a radius meant one of two different figures and this package
      # would have to guess which.
      foreach {axis extent} [list width $w height $h] {
        if {$extent < 0} {
          return -code error -errorcode [list TCLPDF SHAPE ARGUMENT radius] \
              "tclpdf: -radius of rect needs a -size with a positive\
              $axis, got \"[dict get $options size]\" - a rounded corner\
              has no meaning on a rectangle drawn backwards; drop the\
              -radius or give the corner it starts from"
        }
      }
      set path [my GraphicsRoundedRect $x $y $w $h $radius]
    } else {
      set path "[::tclpdf::pdfObj num $x] [::tclpdf::pdfObj num $y]\
          [::tclpdf::pdfObj num $w] [::tclpdf::pdfObj num $h] re\n"
    }
    my ShapePaint rect $options $path
    return
  }

  method circle {args} {
    return [my ellipse {*}$args]
  }

  # Takes either -radius (a circle) or -size {w h} (an ellipse); -at is the
  # CENTRE, unlike rect, because that is how a circle is described.
  method ellipse {args} {
    set options [::tclpdf::option parse {
      at {} radius {} size {} fill {} stroke {} width {} dash {}
      cap {} join {} miter {} opacity {} blend {} overprint {} rule nonzero
    } $args]
    if {[dict get $options at] eq {}} {
      return -code error -errorcode [list TCLPDF SHAPE ARGUMENT at] \
          "tclpdf: ellipse needs -at {x y}"
    }
    lassign [my ShapeRadii $options ellipse] rx ry what
    lassign [my GraphicsPoint [dict get $options at] -at $what] cx cy
    # Four Bezier arcs. 0.5523 is the classic magic number: the control point
    # distance that approximates a quarter circle to within 0.02 % - exact
    # arcs are not expressible as cubic Beziers at all.
    set kx [expr {$rx * 0.5522847498307936}]
    set ky [expr {$ry * 0.5522847498307936}]
    set N ::tclpdf::pdfObj
    set path "[$N num [expr {$cx - $rx}]] [$N num $cy] m\n"
    append path "[$N num [expr {$cx - $rx}]] [$N num [expr {$cy + $ky}]]\
        [$N num [expr {$cx - $kx}]] [$N num [expr {$cy + $ry}]]\
        [$N num $cx] [$N num [expr {$cy + $ry}]] c\n"
    append path "[$N num [expr {$cx + $kx}]] [$N num [expr {$cy + $ry}]]\
        [$N num [expr {$cx + $rx}]] [$N num [expr {$cy + $ky}]]\
        [$N num [expr {$cx + $rx}]] [$N num $cy] c\n"
    append path "[$N num [expr {$cx + $rx}]] [$N num [expr {$cy - $ky}]]\
        [$N num [expr {$cx + $kx}]] [$N num [expr {$cy - $ry}]]\
        [$N num $cx] [$N num [expr {$cy - $ry}]] c\n"
    append path "[$N num [expr {$cx - $kx}]] [$N num [expr {$cy - $ry}]]\
        [$N num [expr {$cx - $rx}]] [$N num [expr {$cy - $ky}]]\
        [$N num [expr {$cx - $rx}]] [$N num $cy] c\n"
    my ShapePaint $what $options $path
    return
  }

  # An arc of a circle or of an ellipse - a piece of what [ellipse] draws
  # whole, and the shape a dial, a pie chart or a rounded joint is made of.
  #
  # -at is the CENTRE, as it is for ellipse and for the same reason; -radius
  # draws a circular arc and -size {w h} an elliptical one, exactly one of
  # the two, and both are read by [ShapeRadius] so the refusals are the ones
  # ellipse already makes.
  #
  # THE ANGLES ARE IN DEGREES, 0 AT THREE O'CLOCK, AND THEY GROW
  # COUNTER-CLOCKWISE AS THE PAGE IS READ - 90 points up. That is the Tk
  # canvas convention, and it is the direction [geometry rotate] already
  # turns in. It is deliberately NOT the direction the document's own y axis
  # would suggest: y counts downwards there, so a caller who thought in raw
  # coordinates would expect 90 to point down. Angles are read off a drawing,
  # not off a coordinate system.
  #
  # -start defaults to 0, -extent is required. Tk gives -extent a default of
  # 90; here the caller says how far the arc sweeps rather than being given a
  # quarter turn nobody asked for - it is the one number that decides what
  # the shape IS.
  #
  # -style is arc (the curve alone, open), pieslice (plus the two radii, so a
  # wedge) or chord (plus the straight line back to the start).
  #
  # No -rotate: [ellipse] has none either, and an option that sits on one of
  # two shapes that are otherwise the same pair is an inconsistency, not a
  # feature. A turned ellipse is what [transform] is for. The segmenter
  # underneath can do it - it takes the cosine and sine of the tilt - and is
  # handed the untilted 1 and 0 here.
  method arc {args} {
    set options [::tclpdf::option parse {
      at {} radius {} size {} start 0 extent {} style arc
      fill {} stroke {} width {} dash {}
      cap {} join {} miter {} opacity {} blend {} overprint {} rule nonzero
    } $args]
    if {[dict get $options at] eq {}} {
      return -code error -errorcode [list TCLPDF SHAPE ARGUMENT at] \
          "tclpdf: arc needs -at {x y}"
    }
    lassign [my ShapeRadii $options arc] rx ry
    # AND A RADIUS THE FILE CAN HOLD. [ShapeRadius] refuses a negative one;
    # what it lets through is a radius so small that the whole arc rounds
    # onto one point - "100 100 m 100 100 100 100 100 100 c S" for
    # -radius 1e-9, measured 2026-08-26. That is the very cut
    # [geometry singular] draws for a matrix: the file is what counts, not
    # the value handed in, and a PDF real carries five decimals (7.3.3).
    # Refused here because -extent 0 is refused four lines down for the same
    # reason - "there is nothing to draw" - and a promise that 1e-9 walks
    # around is no promise.
    foreach {option value} [list radius $rx radius $ry] {
      if {[::tclpdf::pdfObj num $value] == 0} {
        return -code error -errorcode [list TCLPDF SHAPE ARGUMENT $option] \
            "tclpdf: the radii of arc come to nothing as the file would\
            write them (five decimals, 7.3.3) - the whole curve would round\
            onto its centre"
      }
    }
    if {[dict get $options extent] eq {}} {
      return -code error -errorcode [list TCLPDF SHAPE ARGUMENT extent] \
          "tclpdf: arc needs -extent, the angle it sweeps\
          in degrees"
    }
    # Both angles, and both of them numbers a trigonometric function can be
    # asked about. "Inf" and "NaN" pass [string is double] and then throw
    # from inside the arithmetic - the subtraction is the same question
    # [geometry check] asks of a matrix, and for the same reason: a value
    # with no PDF spelling (7.3.3) has to be turned away at the call.
    foreach option {start extent} {
      set value [dict get $options $option]
      if {![::tclpdf::option finite $value]} {
        return -code error -errorcode [list TCLPDF SHAPE ANGLE $option] \
            "tclpdf: -$option of arc is an angle in degrees,\
            not \"$value\""
      }
    }
    set start [dict get $options start]
    set extent [dict get $options extent]
    # An -extent of 0 is not an empty drawing, it is a question with no
    # answer: there is no curve, and the two ends of the sweep it would be
    # cut into coincide. Refused rather than quietly writing a "m" and a
    # painting operator over nothing.
    #
    # AND SO IS AN -extent THE FILE WOULD ROUND TO NOTHING. 1e-9 is not zero
    # to Tcl and is zero to the file: the two ends of the sweep come out as
    # the same five-decimal number and the curve is a point with three
    # control points on it (measured 2026-08-26). Same rule, same reason -
    # [geometry singular] states it for matrices.
    if {[::tclpdf::pdfObj num $extent] == 0} {
      return -code error -errorcode [list TCLPDF SHAPE ANGLE zero] \
          "tclpdf: -extent of arc is \"$extent\", which is 0 as the file\
          would write it (five decimals, 7.3.3) - there is nothing to draw"
    }
    # Beyond a full turn the curve runs over itself, and what a reader makes
    # of the overlap depends on the fill rule rather than on anything the
    # caller said.
    #
    # 360 EXACTLY IS DRAWN, in all three styles. It is the whole ellipse, and
    # a full pie is a figure someone means: a dial read all the way round, a
    # ring closed. The start and the end of the sweep coincide there, so the
    # two radii of a pieslice and the chord of a chord have length zero - the
    # path is redundant, not wrong, and "h" closes it either way. A special
    # case here would cost more than the line of nothing it saves.
    if {abs($extent) > 360} {
      return -code error -errorcode [list TCLPDF SHAPE ANGLE range] \
          "tclpdf: -extent of arc is at most 360 degrees in\
          either direction, not \"$extent\""
    }
    set style [dict get $options style]
    if {$style ni {arc pieslice chord}} {
      return -code error -errorcode [list TCLPDF SHAPE ARGUMENT style] \
          "tclpdf: -style of arc is arc, pieslice or chord,\
          not \"$style\""
    }
    set fullTurn [expr {abs($extent) == 360}]
    # AND THE ONE REFUSAL THAT IS NOT ABOUT A MALFORMED VALUE. -style arc is
    # an OPEN path, and PDF closes an open subpath implicitly before it fills
    # it (8.5.3.1) - so a filled -style arc would come out as a chord, drawn
    # correctly, looking like a shape nobody asked for and with nothing in
    # the file to explain it. Tk ignores -fill on an open arc without a word;
    # silence is the wrong answer here, because the caller who wrote it meant
    # one of the two closed styles and would never find out which.
    #
    # And this package is INCONSISTENT about it, deliberately: through [svg]
    # it fills implicitly closed arcs all day - svgPath writes open subpaths
    # and a "fill" in the drawing paints them under exactly this rule. The
    # difference is who spoke. There the FILE said it, and SVG 1.1 prescribes
    # the implicit close on fill itself, so obeying it is reading the document
    # as written. Here the CALLER said it, and the caller has a word of their
    # own for that very figure: -style chord. A silent detour to a shape that
    # already has a name is not a service.
    #
    # AND A FILL COLOUR OUT OF [style] COUNTS. Until 2026-08-26 only the
    # call's own -fill was asked about, four lines before the same command
    # reads [streamState styleFill] to decide the painting operator - so
    # "style -fill red" followed by "arc ... -style arc" wrote "B" and the
    # quarter circle came out as a filled chord, which is exactly the shape
    # the refusal below exists to prevent. The question is the same one
    # [GraphicsPaint] asks; asking it in two different ways is how the two
    # came to disagree.
    if {$style eq "arc" && ([dict get $options fill] ne {}
        || [my streamState styleFill] ne {})} {
      return -code error -errorcode [list TCLPDF SHAPE ARGUMENT fill] \
          "tclpdf: -style arc takes no -fill - PDF closes an\
          open path before filling it (8.5.3.1), so the result would silently\
          be a chord; ask for -style chord or -style pieslice"
    }
    # Stroked in black unless told otherwise, as a line and a curve are: an
    # arc with neither colour named would otherwise end in "n" and draw
    # nothing at all.
    if {[dict get $options stroke] eq {} && [dict get $options fill] eq {}
        && [my streamState styleStroke] eq {} && [my streamState styleFill] eq {}} {
      dict set options stroke black
    }
    # From here on the arithmetic is in PDF USER SPACE - [GraphicsPoint] has
    # already mirrored the centre, and there y grows upwards, which is the
    # frame the segmenter works in. That is why no angle is negated: the one
    # inversion the caller's downward y costs was paid by [coords], and
    # paying it twice would turn every arc the wrong way round. It is also
    # why the radii may be used as they stand - [ShapeRadius] returns points,
    # and points are what this frame measures in.
    lassign [my GraphicsPoint [dict get $options at] -at arc] cx cy
    set pi [expr {acos(-1)}]
    set startAngle [expr {$start * $pi / 180.0}]
    set delta [expr {$extent * $pi / 180.0}]
    set N ::tclpdf::pdfObj
    # Where the curve begins. Not read back out of the first segment: a
    # segment carries its two control points and its END, and the start is
    # the one point of the arc no "c" operand holds.
    set beginX [expr {$cx + $rx * cos($startAngle)}]
    set beginY [expr {$cy + $ry * sin($startAngle)}]
    if {$style eq "pieslice" && !$fullTurn} {
      # The subpath starts at the CENTRE, so the first radius is drawn as a
      # line and the second one falls out of the closing "h" below.
      set path "[$N num $cx] [$N num $cy] m\n"
      append path "[$N num $beginX] [$N num $beginY] l\n"
    } else {
      # A FULL TURN HAS NO WEDGE. At 360 degrees the two radii of a pieslice
      # fall on top of each other, and the comment above used to call that
      # "redundant, not wrong" - it is wrong: the line from the centre to the
      # rim is not of length zero, it is drawn once and STROKED once, and a
      # dial read all the way round came out with a spoke sticking out of it
      # (seen at 300 dpi on 2026-08-26). The closing "h" still closes the
      # ellipse, so the figure a caller asked for is what is painted.
      set path "[$N num $beginX] [$N num $beginY] m\n"
    }
    foreach segment [::tclpdf::geometry::arcSegments $cx $cy $rx $ry 1 0 \
        $startAngle $delta] {
      lassign $segment x1 y1 x2 y2 endX endY
      append path "[$N num $x1] [$N num $y1] [$N num $x2] [$N num $y2]\
          [$N num $endX] [$N num $endY] c\n"
    }
    if {$style ne "arc"} {
      # One "h" serves both closed styles, because both close back to where
      # the subpath began: the centre for a pieslice, the start of the curve
      # for a chord - which IS the chord.
      append path "h\n"
    }
    my ShapePaint arc $options $path
    return
  }

  method polygon {args} {
    set options [::tclpdf::option parse {
      points {} fill {} stroke {} width {} dash {} close 1
      cap {} join {} miter {} opacity {} blend {} overprint {} rule nonzero
    } $args]
    set points [dict get $options points]
    if {[llength $points] < 4} {
      return -code error -errorcode [list TCLPDF SHAPE POINTS count] \
          "tclpdf: polygon needs at least two points as {x y x y ...}"
    }
    # Pairs, so an even count: an odd one leaves a lone x that used to go out
    # as "x  m" - an operator short of its operands, in a path already begun.
    if {[llength $points] % 2} {
      return -code error -errorcode [list TCLPDF SHAPE POINTS pairs] \
          "tclpdf: -points is a list of pairs {x y x y ...},\
          but [llength $points] numbers were given"
    }
    set path {}
    set operator m
    foreach {x y} $points {
      lassign [my coords $x $y] px py
      append path "[::tclpdf::pdfObj num $px] [::tclpdf::pdfObj num $py] $operator\n"
      set operator l
    }
    if {[dict get $options close]} {
      append path "h\n"
    }
    my ShapePaint polygon $options $path
    return
  }

  # A cubic Bezier: -from, two control points, -to.
  method curve {args} {
    set options [::tclpdf::option parse {
      from {} c1 {} c2 {} to {} fill {} stroke {} width {} dash {}
      cap {} join {} miter {} opacity {} blend {} overprint {} rule nonzero close 0
    } $args]
    foreach key {from c1 c2 to} {
      if {[dict get $options $key] eq {}} {
        return -code error -errorcode [list TCLPDF SHAPE ARGUMENT $key] \
            "tclpdf: curve needs -from, -c1, -c2 and -to"
      }
    }
    # Stroked in black unless told otherwise, as a line is - by its own
    # options, or by a colour [style] set before it.
    if {[dict get $options stroke] eq {} && [dict get $options fill] eq {}
        && [my streamState styleStroke] eq {} && [my streamState styleFill] eq {}} {
      dict set options stroke black
    }
    lassign [my GraphicsPoint [dict get $options from] -from curve] x0 y0
    set path "[::tclpdf::pdfObj num $x0] [::tclpdf::pdfObj num $y0] m\n"
    set numbers {}
    foreach key {c1 c2 to} {
      lassign [my GraphicsPoint [dict get $options $key] -$key curve] px py
      lappend numbers [::tclpdf::pdfObj num $px] [::tclpdf::pdfObj num $py]
    }
    append path "[join $numbers { }] c\n"
    if {[dict get $options close]} {
      append path "h\n"
    }
    my ShapePaint curve $options $path
    return
  }

  # Raw path construction for everything the shapes above do not cover. The
  # segments are given as a list of {move x y}, {line x y}, {curve x1 y1 x2 y2
  # x y} and {close} - in document coordinates, converted here.
  method path {args} {
    set options [::tclpdf::option parse {
      segments {} fill {} stroke {} width {} dash {} close 0
      cap {} join {} miter {} opacity {} blend {} overprint {} rule nonzero
    } $args]
    set path [my ShapeSegments [dict get $options segments]]
    if {[dict get $options close]} {
      append path "h\n"
    }
    my ShapePaint path $options $path
    return
  }

  # Style, path, painting operator - written in ONE call, and only after
  # everything that can be refused has been. Each shape used to write the
  # style first and check its geometry afterwards, so a bad point left a "q"
  # open and a path without its painting operator; a validator sees neither,
  # the rest of the page is drawn in the wrong state, and in a tagged
  # document the mark stays open as well. The path arrives here as a finished
  # string for that reason: building it is where the numbers are checked.
  #
  # "what" is the shape's own name, carried down to the colour space record
  # (see [ColourUsed] in color.tcl) so that a PDF/A refusal can say "rect on
  # page 3" rather than "a colour somewhere".
  method ShapePaint {what options path} {
    set style [my GraphicsStyle $options 1 $what]
    my content $style$path[my GraphicsPaint $options 1]
    return
  }

  # A radius (or a diameter) as a length in points, refused below zero: a
  # negative one draws a mirrored shape or, for a rectangle, silently no
  # rounding at all, and neither is what anyone asked for.
  #
  # The option is named WITH its dash in the message and WITHOUT it in the
  # code, which is the convention for every fact behind TCLPDF SHAPE
  # ARGUMENT - see the note at [line].
  method ShapeRadius {value option} {
    if {![::tclpdf::option finite $value] || $value < 0} {
      return -code error -errorcode [list TCLPDF SHAPE ARGUMENT \
          [string trimleft $option -]] \
          "tclpdf: $option is a length of 0 or more, not \"$value\""
    }
    return [my distance $value]
  }

  # -radius or -size, EXACTLY ONE OF THE TWO, as {rx ry what} in points.
  #
  # Shared by [ellipse] and [arc], which describe their extent in the same
  # two words - and which each read them with a bare [lassign] and an
  # if/elseif until 2026-08-26, so that "-size {40 20 99}" drew a 40 by 20
  # ellipse with the third word dropped in silence and "-radius 10 -size
  # {40 20}" drew the circle and forgot the size. Both are what the manual
  # promises against ("two numbers each, and a third word is refused rather
  # than silently dropped", "exactly one of the two"), and both are what
  # [ShapeBox] has done right for [rect] since 2026-08-25.
  method ShapeRadii {options what} {
    set radius [dict get $options radius]
    set size [dict get $options size]
    if {$radius ne {} && $size ne {}} {
      return -code error -errorcode [list TCLPDF SHAPE ARGUMENT radius] \
          "tclpdf: $what takes either -radius or -size {w h}, not both -\
          one circle and one ellipse cannot be the same figure"
    }
    if {$radius ne {}} {
      set r [my ShapeRadius $radius -radius]
      # A shape with one radius IS a circle, whichever of the two names
      # drew it - and "circle on page 3" is what a caller who wrote
      # [circle] will look for.
      return [list $r $r [expr {$what eq "ellipse" ? "circle" : $what}]]
    }
    if {$size eq {}} {
      return -code error -errorcode [list TCLPDF SHAPE ARGUMENT radius] \
          "tclpdf: $what needs -radius or -size {w h}"
    }
    if {[llength $size] != 2} {
      return -code error -errorcode [list TCLPDF SHAPE ARGUMENT size] \
          "tclpdf: -size of $what is a size {w h}, not \"$size\""
    }
    lassign $size width height
    return [list [expr {[my ShapeRadius $width -size] / 2.0}] \
        [expr {[my ShapeRadius $height -size] / 2.0}] $what]
  }

  # Turn a segment list into path construction operators - returned as a
  # string, not written, so that nothing reaches the stream until every
  # segment has been read and found sound.
  #
  # Shared by [path] and [clip], which is the whole reason it exists: the two
  # differ only in what comes AFTER the path - a painting operator in one case,
  # "W n" in the other. Written twice they would drift, and the copy that does
  # not learn about a new segment kind is the one nobody tests.
  method ShapeSegments {segments} {
    # The refusals live in [checkSegments], shared with textPath - nothing
    # below runs until every segment has been found sound.
    ::tclpdf::shape::checkSegments $segments
    set result {}
    foreach segment $segments {
      set kind [lindex $segment 0]
      set numbers {}
      foreach {x y} [lrange $segment 1 end] {
        lassign [my coords $x $y] px py
        lappend numbers [::tclpdf::pdfObj num $px] [::tclpdf::pdfObj num $py]
      }
      switch -- $kind {
        move {append result "[join $numbers { }] m\n"}
        line {append result "[join $numbers { }] l\n"}
        curve {append result "[join $numbers { }] c\n"}
        close {append result "h\n"}
      }
    }
    return $result
  }

  # Clip to a rectangle or to an arbitrary path (8.5.4).
  #
  #   $doc clip -at {20 20} -size {50 30}
  #   $doc clip -segments {{move 20 20} {line 70 20} {line 45 60} {close}}
  #
  # The mechanism is the same either way and has one twist worth stating: the
  # path is built exactly as it would be for drawing, but instead of a painting
  # operator it ends in "W n". "W" makes it the clipping mask, "n" ends the path
  # WITHOUT drawing it - so the outline itself never appears, it only decides
  # what of everything drawn afterwards remains visible. "W*" applies the
  # even-odd rule, which is what leaves the hole in a ring open.
  #
  # Takes effect until the enclosing restore, so it wants a save around it -
  # and is therefore deliberately NOT wrapped in q/Q the way the shapes are.
  method clip {args} {
    set options [::tclpdf::option parse {at {} size {} segments {} rule nonzero} $args]
    set hasRect [expr {[dict get $options at] ne {} || [dict get $options size] ne {}}]
    set hasPath [expr {[dict get $options segments] ne {}}]
    if {$hasRect && $hasPath} {
      return -code error -errorcode [list TCLPDF SHAPE ARGUMENT segments] \
          "tclpdf: clip takes either -at with -size or\
          -segments, not both"
    }
    if {!$hasRect && !$hasPath} {
      return -code error -errorcode [list TCLPDF SHAPE ARGUMENT at] \
          "tclpdf: clip needs -at {x y} with -size {w h},\
          or -segments"
    }
    # The two rules of 8.5.3.3, and nothing else: a misspelt one used to
    # clip nonzero without a word.
    if {[dict get $options rule] ni {nonzero evenodd}} {
      return -code error -errorcode [list TCLPDF SHAPE ARGUMENT rule] \
          "tclpdf: -rule is nonzero or evenodd, not\
          \"[dict get $options rule]\""
    }
    set operator W
    if {[dict get $options rule] eq "evenodd"} {
      append operator *
    }
    if {$hasPath} {
      set segments [dict get $options segments]
      set path [my ShapeSegments $segments]
      # Closed before it is used as a mask: an open path clips as if the last
      # point were joined to the first anyway (8.5.4), and writing it out keeps
      # what the file says and what a reader does in agreement. Not a second
      # time though - a caller who ended in {close} would otherwise get two.
      if {[lindex $segments end 0] ne "close"} {
        append path "h\n"
      }
      my content "$path$operator n\n"
      return
    }
    foreach key {at size} {
      if {[dict get $options $key] eq {}} {
        return -code error -errorcode [list TCLPDF SHAPE ARGUMENT $key] \
            "tclpdf: clip needs -at {x y} and -size {w h}"
      }
    }
    lassign [my ShapeBox $options clip] x y w h
    my content "[::tclpdf::pdfObj num $x] [::tclpdf::pdfObj num $y]\
        [::tclpdf::pdfObj num $w] [::tclpdf::pdfObj num $h] re $operator n\n"
    return
  }

  # The box -at and -size name, as the four operands of "re": the corner
  # mirrored into PDF coordinates and the two lengths in points. Shared by
  # [rect] and [clip], which describe the same rectangle in the same two
  # words - and which each took it apart on their own until 2026-08-25.
  #
  # Both handed the pieces of a bare [lassign] straight to arithmetic, so
  # neither option was ever checked: measured, "-at {a b}" came out as
  # "can't use non-numeric string as operand of \"+\"" rather than a tclpdf:
  # refusal naming the option, "-size {10}" as "can't use empty string as
  # operand of \"+\"", and "-at {20 20 30}" was ACCEPTED with the third word
  # dropped in silence. The manual says of the shapes that -at is exactly two
  # numbers and that a refused shape leaves nothing behind in the page, and
  # [ellipse], [line] and [curve] already held to it by going through
  # [GraphicsPoint]. These two now go the same way.
  #
  # -size is held to the same count and to numbers, not to a sign: a
  # rectangle of no height is a line a stroke still draws, and "re" itself
  # takes a negative width (8.5.2.1). What it must not be is a word or a
  # missing half.
  method ShapeBox {options what} {
    my GraphicsPoint [dict get $options at] -at $what
    set size [dict get $options size]
    if {[llength $size] != 2} {
      return -code error -errorcode [list TCLPDF SHAPE SIZE $what] \
          "tclpdf: -size of $what is a size {w h}, not\
          \"$size\""
    }
    foreach value $size {
      if {![string is double -strict $value]} {
        return -code error -errorcode [list TCLPDF SHAPE SIZE $what] \
            "tclpdf: -size of $what takes numbers, not\
            \"$value\""
      }
    }
    lassign [dict get $options at] left top
    lassign $size width height
    return [list {*}[my coords $left [expr {$top + $height}]] \
        [my distance $width] [my distance $height]]
  }

  # A rectangle with rounded corners, as four lines and four arcs - returned,
  # not written, like every other path here.
  method GraphicsRoundedRect {x y width height radius} {
    set limit [expr {min($width, $height) / 2.0}]
    if {$radius > $limit} {
      set radius $limit
    }
    set k [expr {$radius * 0.5522847498307936}]
    set N ::tclpdf::pdfObj
    set right [expr {$x + $width}]
    set top [expr {$y + $height}]
    set path "[$N num [expr {$x + $radius}]] [$N num $y] m\n"
    append path "[$N num [expr {$right - $radius}]] [$N num $y] l\n"
    append path "[$N num [expr {$right - $radius + $k}]] [$N num $y]\
        [$N num $right] [$N num [expr {$y + $radius - $k}]]\
        [$N num $right] [$N num [expr {$y + $radius}]] c\n"
    append path "[$N num $right] [$N num [expr {$top - $radius}]] l\n"
    append path "[$N num $right] [$N num [expr {$top - $radius + $k}]]\
        [$N num [expr {$right - $radius + $k}]] [$N num $top]\
        [$N num [expr {$right - $radius}]] [$N num $top] c\n"
    append path "[$N num [expr {$x + $radius}]] [$N num $top] l\n"
    append path "[$N num [expr {$x + $radius - $k}]] [$N num $top]\
        [$N num $x] [$N num [expr {$top - $radius + $k}]]\
        [$N num $x] [$N num [expr {$top - $radius}]] c\n"
    append path "[$N num $x] [$N num [expr {$y + $radius}]] l\n"
    append path "[$N num $x] [$N num [expr {$y + $radius - $k}]]\
        [$N num [expr {$x + $radius - $k}]] [$N num $y]\
        [$N num [expr {$x + $radius}]] [$N num $y] c\n"
    append path "h\n"
    return $path
  }
}

package provide tclpdf::shape 1.8