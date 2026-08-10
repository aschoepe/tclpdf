#
# tclpdf - PDF generation for Tcl
#
# shading - axial and radial gradients, shading types 2 and 3 (8.7.4.5)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Two ways to use a gradient, and they differ in more than spelling:
#
#   $doc shading axial -at {20 20} -size {80 30} -colors {white steelblue}
#       paints it straight away, clipped to the rectangle. The [sh] operator
#       fills the current clip, so the clip IS the shape.
#
#   $doc shading pattern sky axial -at {20 20} -size {80 30} -colors {...}
#       registers it as a pattern, after which any shape can use it:
#       $doc circle -at {60 35} -radius 15 -fill {pattern sky}
#
# The second exists because [sh] cannot fill a circle without a clipping path
# around it, and building that by hand for every shape is exactly the sort of
# thing a caller should not have to do.
#
# Colour stops: two colours give a type 2 (exponential) function directly.
# More than two are stitched together with a type 3 function, one type 2 per
# segment - which is how a multi-stop gradient is expressed in PDF at all.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::color 1.0-
package require tclpdf::geometry 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::shading {}

oo::define ::tclpdf::document::document {

  # $doc shading axial ...
  # $doc shading radial ...
  # $doc shading pattern <name> axial|radial ...
  # $doc shading names
  method shading {subcommand args} {
    switch -- $subcommand {
      axial {return [my ShadingPaint axial $args]}
      radial {return [my ShadingPaint radial $args]}
      pattern {return [my ShadingPattern {*}$args]}
      names {return [dict keys [my state shadings]]}
      default {
        return -code error "tclpdf: unknown shading subcommand \"$subcommand\"\
            - known are: axial, radial, pattern, names"
      }
    }
  }

  # Paint into a rectangle. The clip is what bounds it: [sh] covers the whole
  # clipping region, and without one it would flood the page.
  method ShadingPaint {kind arguments} {
    set options [my ShadingOptions $arguments]
    if {[dict get $options at] eq {} || [dict get $options size] eq {}} {
      return -code error "tclpdf: shading $kind needs -at {x y} and -size {w h}"
    }
    set number [my ShadingObject $kind $options]
    my save
    my clip -at [dict get $options at] -size [dict get $options size]
    set resourceName [my ShadingResource $number]
    my content "[::tclpdf::pdfObj name $resourceName] sh\n"
    my restore
    return $resourceName
  }

  # Register a gradient as a pattern, usable as a fill anywhere.
  method ShadingPattern {name kind args} {
    set shadings [my state shadings]
    if {[dict exists $shadings $name]} {
      return -code error "tclpdf: a shading pattern named \"$name\" already exists"
    }
    if {$kind ni {axial radial}} {
      return -code error "tclpdf: shading pattern kind must be axial or radial,\
          not \"$kind\""
    }
    set options [my ShadingOptions $args]
    if {[dict get $options at] eq {} || [dict get $options size] eq {}} {
      return -code error "tclpdf: shading pattern needs -at {x y} and -size {w h}"
    }
    set number [my ShadingObject $kind $options]
    # PatternType 2 is a shading pattern: the shading itself, plus the matrix
    # that maps it into the page.
    #
    # Usually none is needed - the coordinates are already in page space, the
    # space a caller thinks in. But a pattern is bound to the DEFAULT space of
    # the page and ignores whatever matrix is active when the shape is
    # painted (8.7.3.1). Inside an SVG drawing, which sits under a matrix of
    # its own, that means the shape gets filled in the right place and the
    # gradient inside it sits somewhere else - wrong size, wrong direction,
    # usually so far off that the area comes out flat. Nothing reports it; it
    # looks like "gradients do not quite work".
    #
    # So a caller drawing under a transform passes it in here.
    set pairs [list Type /Pattern PatternType 2 Shading [[my writer] ref $number]]
    if {[dict get $options matrix] ne {}} {
      lappend pairs Matrix [::tclpdf::pdfObj arr [lmap number \
          [dict get $options matrix] {::tclpdf::pdfObj num $number}]]
    }
    set patternNumber [[my writer] add [::tclpdf::pdfObj dictionary $pairs]]
    set resourceName Sp[my ShadingCount]
    my resource Pattern $resourceName [[my writer] ref $patternNumber]
    dict set shadings $name $resourceName
    my state shadings $shadings
    return $name
  }

  method ShadingOptions {arguments} {
    return [::tclpdf::option parse {
      at {} size {} colors {} stops {} angle 0 extend {1 1}
      from {} to {} center {} radius {} innerRadius 0 focus {} matrix {}
    } $arguments "shading"]
  }

  # The shading dictionary itself. Both types share everything except how the
  # geometry is spelled, so they share a method.
  method ShadingObject {kind options} {
    set colors [dict get $options colors]
    if {[llength $colors] < 2} {
      return -code error "tclpdf: a shading needs at least two -colors"
    }
    set parsed [lmap spec $colors {::tclpdf::color parse $spec}]
    set space [::tclpdf::color space [lindex $parsed 0]]
    foreach colour $parsed {
      if {[::tclpdf::color space $colour] ne $space} {
        return -code error "tclpdf: all colours of a shading must be in one\
            colour space, got $space and [::tclpdf::color space $colour]"
      }
    }
    if {$space eq "Separation"} {
      return -code error "tclpdf: a shading in a separation colour space is\
          not supported - give the alternate space directly"
    }
    set function [my ShadingFunction $parsed [dict get $options stops]]
    set pairs [list ShadingType [expr {$kind eq "axial" ? 2 : 3}] \
        ColorSpace /$space \
        Coords [::tclpdf::pdfObj arr [my ShadingCoords $kind $options]] \
        Function [[my writer] ref $function]]
    lassign [dict get $options extend] extendStart extendEnd
    lappend pairs Extend [::tclpdf::pdfObj arr \
        [list [expr {$extendStart ? "true" : "false"}] \
            [expr {$extendEnd ? "true" : "false"}]]]
    return [[my writer] add [::tclpdf::pdfObj dictionary $pairs]]
  }

  # Where the gradient runs. Given -from/-to (or -center/-radius) those win;
  # otherwise it is derived from the rectangle, which is the common case.
  method ShadingCoords {kind options} {
    # With a matrix the coordinates are NOT put through [coords]: they are
    # already in the space the matrix maps from, and the matrix carries both
    # the scaling and the y flip. Doing both applies the transform twice -
    # the gradient then lands far outside its shape, which fills flat in one
    # colour and reads as "gradients do not work" rather than as a doubled
    # transform.
    set mapped [expr {[dict get $options matrix] eq {}}]
    lassign [dict get $options at] left top
    lassign [dict get $options size] width height
    if {$kind eq "axial"} {
      if {[dict get $options from] ne {} && [dict get $options to] ne {}} {
        if {$mapped} {
          lassign [my coords {*}[dict get $options from]] x0 y0
          lassign [my coords {*}[dict get $options to]] x1 y1
        } else {
          lassign [dict get $options from] x0 y0
          lassign [dict get $options to] x1 y1
        }
      } else {
        # -angle counts clockwise from "left to right", the way a reader
        # describes a gradient, and is turned into the two end points of the
        # rectangle's diameter in that direction.
        set radians [expr {[dict get $options angle] * acos(-1) / 180.0}]
        set centreX [expr {$left + $width / 2.0}]
        set centreY [expr {$top + $height / 2.0}]
        set reach [expr {(abs($width * cos($radians)) +
            abs($height * sin($radians))) / 2.0}]
        lassign [my coords [expr {$centreX - $reach * cos($radians)}] \
            [expr {$centreY - $reach * sin($radians)}]] x0 y0
        lassign [my coords [expr {$centreX + $reach * cos($radians)}] \
            [expr {$centreY + $reach * sin($radians)}]] x1 y1
      }
      return [list [::tclpdf::pdfObj num $x0] [::tclpdf::pdfObj num $y0] \
          [::tclpdf::pdfObj num $x1] [::tclpdf::pdfObj num $y1]]
    }

    if {[dict get $options center] ne {}} {
      set centre [dict get $options center]
    } else {
      set centre [list [expr {$left + $width / 2.0}] [expr {$top + $height / 2.0}]]
    }
    set focus [expr {[dict get $options focus] ne {} ?
        [dict get $options focus] : $centre}]
    if {[dict get $options radius] ne {}} {
      set radius [dict get $options radius]
    } else {
      set radius [expr {max($width, $height) / 2.0}]
    }
    if {$mapped} {
      lassign [my coords {*}$focus] fx fy
      lassign [my coords {*}$centre] cx cy
      set inner [my distance [dict get $options innerRadius]]
      set outer [my distance $radius]
    } else {
      lassign $focus fx fy
      lassign $centre cx cy
      set inner [dict get $options innerRadius]
      set outer $radius
    }
    return [list [::tclpdf::pdfObj num $fx] [::tclpdf::pdfObj num $fy] \
        [::tclpdf::pdfObj num $inner] \
        [::tclpdf::pdfObj num $cx] [::tclpdf::pdfObj num $cy] \
        [::tclpdf::pdfObj num $outer]]
  }

  # The colour function. Two colours are one type 2; more are a type 3 that
  # stitches one type 2 per segment (7.10.3, 7.10.4).
  method ShadingFunction {parsed stops} {
    set count [llength $parsed]
    if {$stops eq {}} {
      set stops {}
      for {set index 0} {$index < $count} {incr index} {
        lappend stops [expr {$index / double($count - 1)}]
      }
    } elseif {[llength $stops] != $count} {
      return -code error "tclpdf: -stops has [llength $stops] values but there\
          are $count colours"
    }
    if {$count == 2} {
      return [my ShadingSegment [lindex $parsed 0] [lindex $parsed 1]]
    }
    set functions {}
    set bounds {}
    set encode {}
    for {set index 0} {$index < $count - 1} {incr index} {
      lappend functions [[my writer] ref [my ShadingSegment \
          [lindex $parsed $index] [lindex $parsed $index+1]]]
      if {$index > 0} {
        lappend bounds [::tclpdf::pdfObj num [lindex $stops $index]]
      }
      lappend encode 0 1
    }
    return [[my writer] add [::tclpdf::pdfObj dictionary [list \
        FunctionType 3 \
        Domain [::tclpdf::pdfObj arr {0 1}] \
        Functions [::tclpdf::pdfObj arr $functions] \
        Bounds [::tclpdf::pdfObj arr $bounds] \
        Encode [::tclpdf::pdfObj arr $encode]]]]
  }

  # One straight interpolation between two colours. N 1 makes it linear, which
  # is what "gradient" means to everyone who is not writing a raytracer.
  method ShadingSegment {from to} {
    set c0 [lmap value [lindex $from 1] {::tclpdf::pdfObj num $value}]
    set c1 [lmap value [lindex $to 1] {::tclpdf::pdfObj num $value}]
    return [[my writer] add [::tclpdf::pdfObj dictionary [list \
        FunctionType 2 \
        Domain [::tclpdf::pdfObj arr {0 1}] \
        C0 [::tclpdf::pdfObj arr $c0] \
        C1 [::tclpdf::pdfObj arr $c1] \
        N 1]]]
  }

  method ShadingResource {number} {
    set resourceName Sh[my ShadingCount]
    my resource Shading $resourceName [[my writer] ref $number]
    return $resourceName
  }

  method ShadingCount {} {
    set count [my state shadingCount]
    if {$count eq {}} {
      set count 0
    }
    incr count
    my state shadingCount $count
    return $count
  }
}

package provide tclpdf::shading 1.0
