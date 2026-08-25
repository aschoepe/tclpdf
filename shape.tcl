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
    return -code error "tclpdf: -segments is empty - a path needs at least\
        a {move x y}"
  }
  set operands {move 2 line 2 curve 6 close 0}
  set first 1
  foreach segment $segments {
    set kind [lindex $segment 0]
    if {![dict exists $operands $kind]} {
      return -code error "tclpdf: unknown path segment \"$kind\" -\
          known are: move, line, curve, close"
    }
    # A path begins with a move: "l" and "c" extend from the current
    # point, and before the first "m" there is none (8.5.2.1). A reader
    # may draw from wherever it happens to be, or nothing - so it is
    # refused here.
    if {$first && $kind ne "move"} {
      return -code error "tclpdf: a path starts with {move x y}, not\
          {$segment}"
    }
    set first 0
    # The count is checked, not just the numbers: {line 3} would otherwise
    # pair its 3 with nothing and go out as one operand short.
    if {[llength $segment] - 1 != [dict get $operands $kind]} {
      return -code error "tclpdf: path segment \"$kind\" takes\
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
    if {[dict get $options from] eq {} || [dict get $options to] eq {}} {
      return -code error "tclpdf: line needs -from {x y} and -to {x y}"
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
    if {[dict get $options at] eq {} || [dict get $options size] eq {}} {
      return -code error "tclpdf: rect needs -at {x y} and -size {w h}"
    }
    lassign [my ShapeBox $options rect] x y w h
    set radius [my ShapeRadius [dict get $options radius] -radius]
    if {$radius > 0} {
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
      return -code error "tclpdf: ellipse needs -at {x y}"
    }
    if {[dict get $options radius] ne {}} {
      set rx [my ShapeRadius [dict get $options radius] -radius]
      set ry $rx
      # A shape with one radius IS a circle, whichever of the two names
      # drew it - and "circle on page 3" is what a caller who wrote [circle]
      # will look for.
      set what circle
    } elseif {[dict get $options size] ne {}} {
      set what ellipse
      lassign [dict get $options size] width height
      set rx [expr {[my ShapeRadius $width -size] / 2.0}]
      set ry [expr {[my ShapeRadius $height -size] / 2.0}]
    } else {
      return -code error "tclpdf: ellipse needs -radius or -size {w h}"
    }
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

  method polygon {args} {
    set options [::tclpdf::option parse {
      points {} fill {} stroke {} width {} dash {} close 1
      cap {} join {} miter {} opacity {} blend {} overprint {} rule nonzero
    } $args]
    set points [dict get $options points]
    if {[llength $points] < 4} {
      return -code error "tclpdf: polygon needs at least two points as {x y x y ...}"
    }
    # Pairs, so an even count: an odd one leaves a lone x that used to go out
    # as "x  m" - an operator short of its operands, in a path already begun.
    if {[llength $points] % 2} {
      return -code error "tclpdf: -points is a list of pairs {x y x y ...},\
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
        return -code error "tclpdf: curve needs -from, -c1, -c2 and -to"
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
  method ShapeRadius {value option} {
    if {![string is double -strict $value] || $value < 0} {
      return -code error "tclpdf: $option is a length of 0 or more, not \"$value\""
    }
    return [my distance $value]
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
      return -code error "tclpdf: clip takes either -at with -size or\
          -segments, not both"
    }
    if {!$hasRect && !$hasPath} {
      return -code error "tclpdf: clip needs -at {x y} with -size {w h},\
          or -segments"
    }
    # The two rules of 8.5.3.3, and nothing else: a misspelt one used to
    # clip nonzero without a word.
    if {[dict get $options rule] ni {nonzero evenodd}} {
      return -code error "tclpdf: -rule is nonzero or evenodd, not\
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
    if {[dict get $options at] eq {} || [dict get $options size] eq {}} {
      return -code error "tclpdf: clip needs -at {x y} and -size {w h}"
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
      return -code error "tclpdf: -size of $what is a size {w h}, not\
          \"$size\""
    }
    foreach value $size {
      if {![string is double -strict $value]} {
        return -code error "tclpdf: -size of $what takes numbers, not\
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

package provide tclpdf::shape 1.5