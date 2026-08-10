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
# Every shape ends in GraphicsStyle and GraphicsPaint from graphics.tcl -
# the style prologue and the painting operator exist once for all of them.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::graphics 1.0-
package require tclpdf::option 1.0-

namespace eval ::tclpdf::shape {}

oo::define ::tclpdf::document::document {

  # -- shapes -------------------------------------------------------------

  method line {args} {
    set options [::tclpdf::option parse {
      from {} to {} stroke black width {} dash {} cap {} join {} miter {} opacity {}
    } $args]
    if {[dict get $options from] eq {} || [dict get $options to] eq {}} {
      return -code error "tclpdf: line needs -from {x y} and -to {x y}"
    }
    lassign [my coords {*}[dict get $options from]] x0 y0
    lassign [my coords {*}[dict get $options to]] x1 y1
    my content [my GraphicsStyle $options 1]
    my content "[::tclpdf::pdfObj num $x0] [::tclpdf::pdfObj num $y0] m\
        [::tclpdf::pdfObj num $x1] [::tclpdf::pdfObj num $y1] l\n"
    # Through GraphicsPaint like every other shape rather than a hard-coded
    # "S": a line has no fill, so the operator comes out the same - but the
    # closing "Q" of the state guard does not exist twice.
    my content [my GraphicsPaint $options 1]
    return
  }

  # -at is the TOP left corner, because that is where a caller counting from
  # the top of the page expects a box to start.
  method rect {args} {
    set options [::tclpdf::option parse {
      at {} size {} fill {} stroke {} width {} dash {} radius 0
      cap {} join {} miter {} opacity {} rule nonzero
    } $args]
    if {[dict get $options at] eq {} || [dict get $options size] eq {}} {
      return -code error "tclpdf: rect needs -at {x y} and -size {w h}"
    }
    lassign [dict get $options at] left top
    lassign [dict get $options size] width height
    lassign [my coords $left [expr {$top + $height}]] x y
    set w [my distance $width]
    set h [my distance $height]
    my content [my GraphicsStyle $options 1]
    set radius [my distance [dict get $options radius]]
    if {$radius > 0} {
      my GraphicsRoundedRect $x $y $w $h $radius
    } else {
      my content "[::tclpdf::pdfObj num $x] [::tclpdf::pdfObj num $y]\
          [::tclpdf::pdfObj num $w] [::tclpdf::pdfObj num $h] re\n"
    }
    my content [my GraphicsPaint $options 1]
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
      cap {} join {} miter {} opacity {} rule nonzero
    } $args]
    if {[dict get $options at] eq {}} {
      return -code error "tclpdf: ellipse needs -at {x y}"
    }
    if {[dict get $options radius] ne {}} {
      set rx [my distance [dict get $options radius]]
      set ry $rx
    } elseif {[dict get $options size] ne {}} {
      lassign [dict get $options size] width height
      set rx [expr {[my distance $width] / 2.0}]
      set ry [expr {[my distance $height] / 2.0}]
    } else {
      return -code error "tclpdf: ellipse needs -radius or -size {w h}"
    }
    lassign [my coords {*}[dict get $options at]] cx cy
    my content [my GraphicsStyle $options 1]
    # Four Bezier arcs. 0.5523 is the classic magic number: the control point
    # distance that approximates a quarter circle to within 0.02 % - exact
    # arcs are not expressible as cubic Beziers at all.
    set kx [expr {$rx * 0.5522847498307936}]
    set ky [expr {$ry * 0.5522847498307936}]
    set N ::tclpdf::pdfObj
    my content "[$N num [expr {$cx - $rx}]] [$N num $cy] m\n"
    my content "[$N num [expr {$cx - $rx}]] [$N num [expr {$cy + $ky}]]\
        [$N num [expr {$cx - $kx}]] [$N num [expr {$cy + $ry}]]\
        [$N num $cx] [$N num [expr {$cy + $ry}]] c\n"
    my content "[$N num [expr {$cx + $kx}]] [$N num [expr {$cy + $ry}]]\
        [$N num [expr {$cx + $rx}]] [$N num [expr {$cy + $ky}]]\
        [$N num [expr {$cx + $rx}]] [$N num $cy] c\n"
    my content "[$N num [expr {$cx + $rx}]] [$N num [expr {$cy - $ky}]]\
        [$N num [expr {$cx + $kx}]] [$N num [expr {$cy - $ry}]]\
        [$N num $cx] [$N num [expr {$cy - $ry}]] c\n"
    my content "[$N num [expr {$cx - $kx}]] [$N num [expr {$cy - $ry}]]\
        [$N num [expr {$cx - $rx}]] [$N num [expr {$cy - $ky}]]\
        [$N num [expr {$cx - $rx}]] [$N num $cy] c\n"
    my content [my GraphicsPaint $options 1]
    return
  }

  method polygon {args} {
    set options [::tclpdf::option parse {
      points {} fill {} stroke {} width {} dash {} close 1
      cap {} join {} miter {} opacity {} rule nonzero
    } $args]
    set points [dict get $options points]
    if {[llength $points] < 4} {
      return -code error "tclpdf: polygon needs at least two points as {x y x y ...}"
    }
    my content [my GraphicsStyle $options 1]
    set operator m
    foreach {x y} $points {
      lassign [my coords $x $y] px py
      my content "[::tclpdf::pdfObj num $px] [::tclpdf::pdfObj num $py] $operator\n"
      set operator l
    }
    if {[dict get $options close]} {
      my content "h\n"
    }
    my content [my GraphicsPaint $options 1]
    return
  }

  # A cubic Bezier: -from, two control points, -to.
  method curve {args} {
    set options [::tclpdf::option parse {
      from {} c1 {} c2 {} to {} fill {} stroke black width {} dash {}
      cap {} join {} miter {} opacity {} rule nonzero close 0
    } $args]
    foreach key {from c1 c2 to} {
      if {[dict get $options $key] eq {}} {
        return -code error "tclpdf: curve needs -from, -c1, -c2 and -to"
      }
    }
    my content [my GraphicsStyle $options 1]
    lassign [my coords {*}[dict get $options from]] x0 y0
    my content "[::tclpdf::pdfObj num $x0] [::tclpdf::pdfObj num $y0] m\n"
    set numbers {}
    foreach key {c1 c2 to} {
      lassign [my coords {*}[dict get $options $key]] px py
      lappend numbers [::tclpdf::pdfObj num $px] [::tclpdf::pdfObj num $py]
    }
    my content "[join $numbers { }] c\n"
    if {[dict get $options close]} {
      my content "h\n"
    }
    my content [my GraphicsPaint $options 1]
    return
  }

  # Raw path construction for everything the shapes above do not cover. The
  # segments are given as a list of {move x y}, {line x y}, {curve x1 y1 x2 y2
  # x y} and {close} - in document coordinates, converted here.
  method path {args} {
    set options [::tclpdf::option parse {
      segments {} fill {} stroke {} width {} dash {} close 0
      cap {} join {} miter {} opacity {} rule nonzero
    } $args]
    my content [my GraphicsStyle $options 1]
    my ShapeSegments [dict get $options segments]
    if {[dict get $options close]} {
      my content "h\n"
    }
    my content [my GraphicsPaint $options 1]
    return
  }

  # Turn a segment list into path construction operators.
  #
  # Shared by [path] and [clip], which is the whole reason it exists: the two
  # differ only in what comes AFTER the path - a painting operator in one case,
  # "W n" in the other. Written twice they would drift, and the copy that does
  # not learn about a new segment kind is the one nobody tests.
  method ShapeSegments {segments} {
    if {![llength $segments]} {
      return -code error "tclpdf: -segments is empty - a path needs at least\
          a {move x y}"
    }
    foreach segment $segments {
      set kind [lindex $segment 0]
      set numbers {}
      foreach {x y} [lrange $segment 1 end] {
        lassign [my coords $x $y] px py
        lappend numbers [::tclpdf::pdfObj num $px] [::tclpdf::pdfObj num $py]
      }
      switch -- $kind {
        move {my content "[join $numbers { }] m\n"}
        line {my content "[join $numbers { }] l\n"}
        curve {my content "[join $numbers { }] c\n"}
        close {my content "h\n"}
        default {
          return -code error "tclpdf: unknown path segment \"$kind\" -\
              known are: move, line, curve, close"
        }
      }
    }
    return
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
    set operator W
    if {[dict get $options rule] eq "evenodd"} {
      append operator *
    }
    if {$hasPath} {
      set segments [dict get $options segments]
      my ShapeSegments $segments
      # Closed before it is used as a mask: an open path clips as if the last
      # point were joined to the first anyway (8.5.4), and writing it out keeps
      # what the file says and what a reader does in agreement. Not a second
      # time though - a caller who ended in {close} would otherwise get two.
      if {[lindex $segments end 0] ne "close"} {
        my content "h\n"
      }
      my content "$operator n\n"
      return
    }
    if {[dict get $options at] eq {} || [dict get $options size] eq {}} {
      return -code error "tclpdf: clip needs -at {x y} and -size {w h}"
    }
    lassign [dict get $options at] left top
    lassign [dict get $options size] width height
    lassign [my coords $left [expr {$top + $height}]] x y
    my content "[::tclpdf::pdfObj num $x] [::tclpdf::pdfObj num $y]\
        [::tclpdf::pdfObj num [my distance $width]]\
        [::tclpdf::pdfObj num [my distance $height]] re $operator n\n"
    return
  }

  # A rectangle with rounded corners, as four lines and four arcs.
  method GraphicsRoundedRect {x y width height radius} {
    set limit [expr {min($width, $height) / 2.0}]
    if {$radius > $limit} {
      set radius $limit
    }
    set k [expr {$radius * 0.5522847498307936}]
    set N ::tclpdf::pdfObj
    set right [expr {$x + $width}]
    set top [expr {$y + $height}]
    my content "[$N num [expr {$x + $radius}]] [$N num $y] m\n"
    my content "[$N num [expr {$right - $radius}]] [$N num $y] l\n"
    my content "[$N num [expr {$right - $radius + $k}]] [$N num $y]\
        [$N num $right] [$N num [expr {$y + $radius - $k}]]\
        [$N num $right] [$N num [expr {$y + $radius}]] c\n"
    my content "[$N num $right] [$N num [expr {$top - $radius}]] l\n"
    my content "[$N num $right] [$N num [expr {$top - $radius + $k}]]\
        [$N num [expr {$right - $radius + $k}]] [$N num $top]\
        [$N num [expr {$right - $radius}]] [$N num $top] c\n"
    my content "[$N num [expr {$x + $radius}]] [$N num $top] l\n"
    my content "[$N num [expr {$x + $radius - $k}]] [$N num $top]\
        [$N num $x] [$N num [expr {$top - $radius + $k}]]\
        [$N num $x] [$N num [expr {$top - $radius}]] c\n"
    my content "[$N num $x] [$N num [expr {$y + $radius}]] l\n"
    my content "[$N num $x] [$N num [expr {$y + $radius - $k}]]\
        [$N num [expr {$x + $radius - $k}]] [$N num $y]\
        [$N num [expr {$x + $radius}]] [$N num $y] c\n"
    my content "h\n"
    return
  }
}

package provide tclpdf::shape 1.0
