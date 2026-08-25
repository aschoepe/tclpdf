#
# tclpdf - PDF generation for Tcl
#
# shading - gradients and function shadings, types 1, 2 and 3 (8.7.4.5)
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
# Seven shading types exist, and they fall into two halves. The three here -
# 1 function-based, 2 axial, 3 radial - are a DICTIONARY plus a function, and
# the function is where the colour comes from. The four in shadingMesh.tcl -
# 4 to 7 - are a STREAM of packed points and colours, and share nothing with
# these but the resource name and the colour space; they are loaded when one
# is asked for and not before.
#
# Shading type 1 needs a function of TWO inputs, which neither type 2 nor
# type 3 is (7.10.2: an exponential and a stitching function both take one).
# So it brings the one function type this package did not have before, type 4,
# the PostScript calculator - which is also the point of the shading: the
# caller writes the colour as a calculation over the rectangle instead of as
# a run along an axis.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::color 1.0-
package require tclpdf::geometry 1.0-
package require tclpdf::pdfFunction 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::shading {}

oo::define ::tclpdf::document::document {

  # $doc shading axial|radial|function|triangles|lattice|coons|tensor ...
  # $doc shading pattern <name> <kind> ...
  # $doc shading names
  method shading {subcommand args} {
    switch -- $subcommand {
      axial - radial - function - triangles - lattice - coons - tensor {
        return [my ShadingPaint $subcommand $args]
      }
      pattern {return [my ShadingPattern {*}$args]}
      names {return [dict keys [my state shadings]]}
      default {
        return -code error -errorcode [list TCLPDF SHADING KIND $subcommand] \
            "tclpdf: unknown shading subcommand \"$subcommand\"\
            - known are: axial, radial, function, triangles, lattice, coons,\
            tensor, pattern, names"
      }
    }
  }

  # Which shadings are a dictionary with a function in it and which are a
  # stream of points. Asked in four places, and the day a type moves sides
  # is the day three of them are found and the fourth is not.
  method ShadingKinds {} {
    return {axial radial function triangles lattice coons tensor}
  }

  method ShadingIsMesh {kind} {
    return [expr {$kind in {triangles lattice coons tensor}}]
  }

  # Paint into a rectangle. The clip is what bounds it: [sh] covers the whole
  # clipping region, and without one it would flood the page.
  #
  # A mesh is the exception: it paints only the triangles or patches it holds
  # and bounds itself, so the rectangle is optional there - given, it still
  # clips, which is how a mesh is cut to a shape.
  method ShadingPaint {kind arguments} {
    set options [my ShadingOptions $kind $arguments "shading $kind"]
    my ShadingRect $kind $options "shading $kind"
    # -at and -size were checked in ShadingOptions, so the clip below
    # cannot refuse: with -from and -to given the shading itself never
    # reads -at, and a bad corner used to surface only in [clip] - after
    # the function and the shading were written and the mark and the "q"
    # were out.
    set number [my ShadingObject $kind $options "shading $kind"]
    # A gradient is content on the page like any shape: part of an open
    # Figure, decoration otherwise. Without the bracket it would belong to no
    # element at all, which PDF/UA counts as a defect.
    set mark {}
    if {[my state tagged] eq "1"} {
      set mark [my StructureMark auto]
      my content [my StructureBegin $mark]
    }
    my save
    if {[dict get $options at] ne {}} {
      my clip -at [dict get $options at] -size [dict get $options size]
    }
    set resourceName [my ShadingResource $number]
    my content "[::tclpdf::pdfObj name $resourceName] sh\n"
    my restore
    if {[llength $mark]} {
      my content [my StructureEnd $mark]
    }
    return $resourceName
  }

  # Register a gradient as a pattern, usable as a fill anywhere.
  method ShadingPattern {name kind args} {
    set shadings [my state shadings]
    if {[dict exists $shadings $name]} {
      return -code error "tclpdf: a shading pattern named \"$name\" already exists"
    }
    if {$kind ni [my ShadingKinds]} {
      return -code error -errorcode [list TCLPDF SHADING KIND $kind] \
          "tclpdf: shading pattern kind must be one of\
          [join [my ShadingKinds] {, }], not \"$kind\""
    }
    set options [my ShadingOptions $kind $args "shading pattern \"$name\""]
    my ShadingRect $kind $options "shading pattern"
    set number [my ShadingObject $kind $options "shading pattern \"$name\""]
    # PatternType 2 is a shading pattern: the shading itself, plus the matrix
    # that maps it into the page.
    #
    # Usually none is needed - the coordinates are already in page space, the
    # space a caller thinks in. But a pattern is bound to the DEFAULT space of
    # the PARENT CONTENT STREAM - the page here, a form's own space inside a
    # form - and ignores whatever matrix is active when the shape is painted
    # (8.7.2). Inside an SVG drawing, which sits under a matrix of
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
    # Without a matrix the end points went through [coords] and mean a place
    # in THIS stream - a use in another one is refused rather than drawn
    # somewhere else (pattern.tcl, PatternAnchor). With one the caller has
    # said which space the numbers are in, which is how the SVG path works.
    if {[dict get $options matrix] eq {}} {
      # Loaded the same way graphics.tcl loads it when a colour reads
      # {pattern <name>}: the pattern module owns the registry that spans
      # both kinds, and nothing here needs it until a gradient is placed.
      package require tclpdf::pattern
      my PatternAnchor $name
    }
    return $name
  }

  # The rectangle, and which kinds have to have one.
  #
  # A gradient and a function shading are painted through [sh], which floods
  # the whole clipping region - without a rectangle they would cover the
  # page, so both require one, and the function shading reads it a second
  # time to place its domain. A mesh paints only where its triangles are; a
  # rectangle there is a clip and nothing else, and is optional. Half of one
  # is refused either way: -at without -size used to reach [clip], which
  # refuses it - after the shading was written.
  method ShadingRect {kind options what} {
    set at [dict get $options at]
    set size [dict get $options size]
    if {$at ne {} && $size ne {}} {
      return
    }
    if {$at eq {} && $size eq {} && [my ShadingIsMesh $kind]} {
      return
    }
    return -code error -errorcode [list TCLPDF SHADING RECT $what] \
        "tclpdf: $what needs -at {x y} and -size {w h}"
  }

  # The defaults of one kind, which is also the list of options it takes: a
  # -perRow on a gradient or an -angle on a mesh is a caller who has the wrong
  # kind in mind, and one dictionary of every option there is would accept
  # both and write neither.
  method ShadingDefaults {kind} {
    set common {at {} size {} matrix {}}
    switch -- $kind {
      axial - radial {
        # The order is the order the message "known are: ..." prints, and
        # -at and -size lead it because they are the two that are required.
        return {at {} size {} colors {} stops {} angle 0 extend {1 1}
            from {} to {} center {} radius {} innerRadius 0 focus {} matrix {}}
      }
      function {return [dict merge $common {space {} expression {} domain {0 1 0 1}}]}
      triangles {return [dict merge $common {vertices {}}]}
      lattice {return [dict merge $common {vertices {} perRow {}}]}
      coons - tensor {return [dict merge $common {patches {}}]}
    }
    return -code error -errorcode [list TCLPDF SHADING KIND $kind] \
        "tclpdf: unknown shading kind \"$kind\" - known are:\
        [join [my ShadingKinds] {, }]"
  }

  # The options of the kind that was asked for, and every value that a later
  # step would read AFTER something is written checked right here - BEFORE
  # ShadingObject, which writes the function and the shading dictionary and
  # records the colour space. Until the -matrix was, five numbers or a
  # singular matrix went into the /Matrix as they stood, and a letter failed
  # at the number formatting - after function and shading were out, two
  # objects without a consumer. Measured again before 2026-08-18: "-at
  # {a b}" with -from and -to given, "-size {50}" and "-extend 1" left the
  # same two orphans and a colour space record for a gradient that never
  # reached the page, and a third number in -from or -to went to [coords]
  # as a page index. The direct forms take the matrix check although they
  # write no matrix: the value there stands for the cm the caller has in
  # force, and a singular one is a gradient nobody will see. "what" names
  # the caller for the messages.
  #
  # Only the options the kind HAS are checked here - a mesh has no -extend
  # and no -from, and [dict exists] is what says so rather than a second
  # list of which kind takes which.
  method ShadingOptions {kind arguments what} {
    set options [::tclpdf::option parse [my ShadingDefaults $kind] \
        $arguments $what]
    if {[dict get $options matrix] ne {}} {
      ::tclpdf::geometry check [dict get $options matrix] $what
    }
    # Points and the size: exactly two numbers each. Not through [coords]
    # here - under a -matrix they are read as they stand - only counted and
    # checked as numbers.
    foreach {key noun} {at point size size from point to point center point focus point} {
      if {![dict exists $options $key]} {
        continue
      }
      set value [dict get $options $key]
      if {$value eq {}} {
        continue
      }
      set shape [expr {$noun eq "point" ? "{x y}" : "{w h}"}]
      if {[llength $value] != 2} {
        return -code error "tclpdf: -$key of $what is a $noun $shape, not\
            \"$value\""
      }
      foreach number $value {
        if {![string is double -strict $number]} {
          return -code error "tclpdf: -$key of $what takes numbers, not\
              \"$number\""
        }
      }
    }
    # AND A SIZE IS A SIZE: two lengths ABOVE zero, the very check
    # [image place] takes ([checkFit] in geometry.tcl, which reads -size out
    # of the dict handed to it). Measured on 2026-08-25, before this stood
    # here: "-size {0 0}" on a function shading wrote "/Matrix
    # [0 0 0 85.03937 0 0]" - singular, so the shading covers nothing and no
    # reader says why - and on an axial one a "0 0 re W n" clip, a clipping
    # path of no area with the "sh" inside it. A negative one turned the
    # rectangle inside out. Run AFTER the shape check above, which words its
    # refusals in this module's own terms; what is left for [checkFit] here
    # is the sign.
    ::tclpdf::geometry checkFit $options $what
    # /Extend is two booleans (Table 78, Table 80): whether the gradient
    # goes on beyond its start and its end. One value used to pass the
    # start and fail on the missing end - after everything was written.
    if {[dict exists $options extend]} {
      set extend [dict get $options extend]
      if {[llength $extend] != 2 || ![string is boolean -strict [lindex $extend 0]]
          || ![string is boolean -strict [lindex $extend 1]]} {
        return -code error "tclpdf: -extend of $what is two booleans\
            {start end}, not \"$extend\""
      }
    }
    return $options
  }

  # Which builder makes the object. The three dictionary types are here; the
  # four stream types are a module of their own, loaded when one is asked for
  # - a document that draws no mesh never reads it.
  method ShadingObject {kind options what} {
    switch -- $kind {
      axial - radial {return [my ShadingGradientObject $kind $options $what]}
      function {return [my ShadingFunctionObject $options $what]}
      default {
        package require tclpdf::shadingMesh
        return [my ShadingMeshObject $kind $options $what]
      }
    }
  }

  # The colours of a shading, whatever holds them: the stops of a gradient,
  # the vertices of a mesh, the corners of a patch. Returns {space parsed}.
  #
  # Shared because the rule is the same one everywhere and is not obvious:
  # ONE colour space for the whole shading, since the dictionary names it
  # once. A mesh gets it over all its vertices at once rather than per
  # triangle - a grey corner among coloured ones is promoted, and a mesh
  # whose first patch is grey and whose second is red is one RGB mesh, not a
  # refusal.
  method ShadingColours {specs what} {
    set parsed [lmap spec $specs {::tclpdf::color parse $spec}]
    # A grey stop takes the space of the coloured ones: "white" is grey since
    # names with equal components are, and {white steelblue} is an RGB
    # gradient. The first non-grey stop decides; all grey stays grey.
    set coloured {}
    foreach colour $parsed {
      if {[lindex $colour 0] ne "gray"} {
        set coloured [lindex $colour 0]
        break
      }
    }
    if {$coloured ne {}} {
      set parsed [lmap colour $parsed {::tclpdf::color promote $colour $coloured}]
    }
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
    # AND NOT A PATTERN. ISO 32000-2, 8.7.4.5.1 with Tables 78 and 80: the
    # ColorSpace of a shading dictionary "shall not be a Pattern colour
    # space" - a shading is what a pattern is MADE of, and a shading painted
    # in patterns has no way down to actual ink.
    #
    # This is the one special space that got through. Lab, ICCBased and
    # DeviceN are refused by [::tclpdf::color space] before they arrive,
    # Separation by the line above - and {pattern <name>} parses cleanly and
    # answers "Pattern", so it walked straight into the dictionary. Measured
    # on 2026-08-25: "/ColorSpace /Pattern" stood in the file, qpdf --check
    # passed it, and poppler warned once and drew NOTHING. Asked here rather
    # than in each builder because every one of the seven types collects its
    # colours through this method - the stops of a gradient, the vertices of
    # a mesh, the corners of a patch.
    if {$space eq "Pattern"} {
      return -code error -errorcode {TCLPDF SHADING PATTERN} \
          "tclpdf: a shading cannot be painted in a pattern - ISO 32000-2,\
          8.7.4.5.1 says the colour space of a shading shall not be a Pattern\
          colour space, and a reader given one draws nothing at all. A shading\
          is what a shading pattern is made of: build the gradient in device\
          colours and register it with \"shading pattern\", rather than naming\
          a pattern among its colours"
    }
    return [list $space $parsed]
  }

  # The shading dictionary of types 2 and 3. Both share everything except how
  # the geometry is spelled, so they share a method. "what" names the caller
  # for the colour space record.
  method ShadingGradientObject {kind options what} {
    set colors [dict get $options colors]
    if {[llength $colors] < 2} {
      return -code error "tclpdf: a shading needs at least two -colors"
    }
    lassign [my ShadingColours $colors $what] space parsed
    # The coordinates BEFORE the function object goes out: a refused corner
    # used to leave a function without a consumer behind.
    set coords [my ShadingCoords $kind $options]
    set stops [my ShadingStops [llength $parsed] [dict get $options stops]]
    # Shadings, sh and PatternType 2 are PDF 1.3 (Reference 1.7, 4.6.3).
    # AFTER the last value that can be refused - a refused shading must not
    # pin the version floor, or a later "configure -version 1.2" would be
    # refused over a shading that never made it into the file - and before
    # the function object goes out, so a version refusal leaves no object.
    my RequireVersion 1.3 "shading"
    set function [my ShadingFunction $parsed $stops]
    # Only now, past the last value that can be refused, the colour space
    # record: a gradient's space counts like a painted colour for the PDF/A
    # intent check (ISO 19005-2, 6.2.4.3 - measured with veraPDF: a
    # DeviceRGB shading fails under a CMYK intent, painted directly or
    # through a pattern), and a shading that was refused must not be on
    # record.
    my ColourSpaceUsed $space $what
    set pairs [list ShadingType [expr {$kind eq "axial" ? 2 : 3}] \
        ColorSpace /$space \
        Coords [::tclpdf::pdfObj arr $coords] \
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
    # Both radii of a type 3 shading are lengths and shall not be negative
    # (Table 80, r0 and r1 >= 0). A reader given one may draw the circles
    # inside out or nothing at all.
    foreach {option value} [list -radius $radius \
        -innerRadius [dict get $options innerRadius]] {
      if {![string is double -strict $value] || $value < 0} {
        return -code error "tclpdf: $option is a length of 0 or more, not \"$value\""
      }
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

  # Check and complete the -stops: spread evenly when not given, held to
  # count, range and order otherwise. Apart from [ShadingFunction] so that
  # the last value a shading can be refused over is judged BEFORE the
  # version floor is pinned and before any function object is written.
  method ShadingStops {count stops} {
    if {$stops eq {}} {
      for {set index 0} {$index < $count} {incr index} {
        lappend stops [expr {$index / double($count - 1)}]
      }
      return $stops
    }
    if {[llength $stops] != $count} {
      return -code error "tclpdf: -stops has [llength $stops] values but there\
          are $count colours"
    }
    # The inner stops become the Bounds of the stitching function, and
    # those shall be in increasing order and strictly inside the domain
    # (7.10.4: Domain0 < Bounds0 < ... < Domain1). Two equal stops make a
    # segment of no width; one outside 0..1 or out of order makes a
    # function a reader has no way to evaluate.
    set previous {}
    foreach stop $stops {
      if {![string is double -strict $stop] || $stop < 0 || $stop > 1} {
        return -code error "tclpdf: -stops are numbers from 0 to 1, not \"$stop\""
      }
      if {$previous ne {} && $stop <= $previous} {
        return -code error "tclpdf: -stops must increase strictly:\
            [join $stops { }]"
      }
      set previous $stop
    }
    return $stops
  }

  # The colour function. Two colours are one type 2; more are a type 3 that
  # stitches one type 2 per segment (7.10.3, 7.10.4). The stops arrive
  # checked and completed, from [ShadingStops]; the functions themselves are
  # written by pdfFunction.tcl, which is where a separation's tint transform
  # gets its type 2 as well.
  method ShadingFunction {parsed stops} {
    set count [llength $parsed]
    if {$count == 2} {
      return [my ShadingSegment [lindex $parsed 0] [lindex $parsed 1]]
    }
    set functions {}
    set bounds {}
    for {set index 0} {$index < $count - 1} {incr index} {
      lappend functions [my ShadingSegment \
          [lindex $parsed $index] [lindex $parsed $index+1]]
      if {$index > 0} {
        lappend bounds [lindex $stops $index]
      }
    }
    return [my FunctionStitching $functions $bounds]
  }

  # One straight interpolation between two colours: the colour of a stop is
  # the C0 or C1 of a type 2.
  method ShadingSegment {from to} {
    return [my FunctionExponential [lindex $from 1] [lindex $to 1]]
  }

  # -- shading type 1, function-based (8.7.4.5.3) ----------------------------

  # A rectangle in shading space whose colour at every point is what a
  # function returns for that point. No axis, no circles, no stops: the
  # caller writes the colour as a calculation.
  #
  #   $doc shading function -at {20 20} -size {60 40} -space rgb \
  #       -expression {2 copy add 2 div 3 1 roll pop pop dup 1 exch sub 0.5}
  #
  # /Domain is the rectangle the FUNCTION is written over, {0 1 0 1} unless
  # said otherwise, and /Matrix is what puts that rectangle on the page. The
  # matrix is derived from -at and -size rather than asked for: the caller
  # already says where the shading goes, in the same two options every other
  # kind uses, and a second way to say it would be a second way to get it
  # wrong. (-matrix keeps the meaning it has everywhere else in this module -
  # the space the coordinates are given in, written into the PATTERN.)
  method ShadingFunctionObject {options what} {
    set space [my ShadingSpace [dict get $options space] $what]
    set domain [my ShadingDomain [dict get $options domain] $what]
    set expression [my ShadingExpression [dict get $options expression] $what]
    set matrix [my ShadingMatrix $options $domain]
    # The /Matrix of a type 1 shading (Table 77) is built here rather than
    # handed in, so [::tclpdf::geometry check] never sees it - but it is
    # written into the file like any other and collapses the same way. Judged
    # over the numbers that reach the file, which is what [singular] is for:
    # a box small enough to round to nothing maps the whole domain onto a
    # point, and the shading covers nothing.
    if {[::tclpdf::geometry singular $matrix]} {
      return -code error "tclpdf: the box -at and -size give $what is too\
          small to place a shading in: its /Matrix comes out as\
          {[join [lmap value $matrix {::tclpdf::pdfObj num $value}] { }]},\
          which is singular, and a reader draws nothing under it. A PDF real\
          holds five decimals (7.3.3), so an extent below 0.00001 pt is zero\
          as far as the file is concerned"
    }
    # Everything above can still refuse; from here on objects are written.
    my RequireVersion 1.3 "shading"
    my ColourSpaceUsed [lindex $space 0] $what
    set function [my FunctionCalculator $domain \
        [::tclpdf::pdfFunction unitRange [lindex $space 1]] $expression]
    return [[my writer] add [::tclpdf::pdfObj dictionary [list \
        ShadingType 1 \
        ColorSpace /[lindex $space 0] \
        Domain [::tclpdf::pdfObj arr [lmap value $domain {::tclpdf::pdfObj num $value}]] \
        Matrix [::tclpdf::pdfObj arr [lmap value $matrix {::tclpdf::pdfObj num $value}]] \
        Function [[my writer] ref $function]]]]
  }

  # -space of a function shading: {name components}. A shading names its
  # space by family in the dictionary, so the three device families are what
  # can stand there - the same three a gradient's stops may be in, and the
  # words are the ones [color parse] uses to name a space.
  method ShadingSpace {space what} {
    switch -- [string tolower $space] {
      gray - grey {return {DeviceGray 1}}
      rgb {return {DeviceRGB 3}}
      cmyk {return {DeviceCMYK 4}}
    }
    return -code error -errorcode [list TCLPDF SHADING SPACE $what] \
        "tclpdf: -space of $what is gray, rgb or cmyk, not \"$space\" - the\
        function returns one number per component, and the dictionary names\
        the space by family"
  }

  # -domain of a function shading: {x0 x1 y0 y1}, the rectangle the function
  # is written over (Table 77). Both spans have to be real: x0 equal to x1
  # gives a shading of no width, which the file carries and the page does not
  # show.
  method ShadingDomain {domain what} {
    if {[llength $domain] != 4} {
      return -code error -errorcode [list TCLPDF SHADING DOMAIN $what] \
          "tclpdf: -domain of $what is {x0 x1 y0 y1}, not \"$domain\""
    }
    foreach value $domain {
      if {![string is double -strict $value]} {
        return -code error -errorcode [list TCLPDF SHADING DOMAIN $what] \
            "tclpdf: -domain of $what takes numbers, not \"$value\""
      }
    }
    lassign $domain x0 x1 y0 y1
    if {$x0 >= $x1 || $y0 >= $y1} {
      return -code error -errorcode [list TCLPDF SHADING DOMAIN $what] \
          "tclpdf: -domain of $what is {x0 x1 y0 y1} with x0 below x1 and y0\
          below y1, not \"$domain\" - a domain of no width has no area to\
          paint"
    }
    return $domain
  }

  # The /Matrix that maps the domain rectangle onto the rectangle of -at and
  # -size (Table 77). Both corners go the same road the coordinates of every
  # other kind go: through [coords] without -matrix, as they stand with one.
  # The two are then sorted, because [coords] mirrors y and the corner that
  # was the top becomes the larger number - so that the domain's y runs UP
  # the page, the way a caller writing a calculation expects it to.
  method ShadingMatrix {options domain} {
    lassign [dict get $options at] left top
    lassign [dict get $options size] width height
    if {[dict get $options matrix] eq {}} {
      lassign [my coords $left $top] ax ay
      lassign [my coords [expr {$left + $width}] [expr {$top + $height}]] bx by
    } else {
      set ax $left
      set ay $top
      set bx [expr {$left + $width}]
      set by [expr {$top + $height}]
    }
    lassign $domain x0 x1 y0 y1
    set scaleX [expr {(max($ax, $bx) - min($ax, $bx)) / ($x1 - $x0)}]
    set scaleY [expr {(max($ay, $by) - min($ay, $by)) / ($y1 - $y0)}]
    return [list $scaleX 0 0 $scaleY \
        [expr {min($ax, $bx) - $x0 * $scaleX}] \
        [expr {min($ay, $by) - $y0 * $scaleY}]]
  }

  # -expression: the body of a type 4 function, the PostScript calculator of
  # 7.10.5 - WITHOUT the outer braces, which pdfFunction.tcl writes.
  #
  # Two inputs are on the stack, x and y in domain coordinates, and what is
  # left when the expression ends is the colour, one number per component.
  # Whether the right NUMBER of them is left cannot be decided by reading:
  # [if], [ifelse] and [roll] make it depend on the values.
  #
  # Only the missing option is answered here, and only because that message
  # is this module's own: it names -expression and says what the two numbers
  # on the stack are, which is knowledge a shading has and a function does
  # not. Everything the BODY can be wrong about - an unknown operator, a
  # brace too many, the outer braces - is read by [checkCalculator], which
  # reads the generated tint transform of a DeviceN space the same way.
  #
  # Read HERE and not in the builder: a refusal has to come before the
  # version floor is pinned and before a single object is written, or a
  # refused shading leaves an object behind that no reader ever reaches and
  # every validator counts (shading-10.4 and 10.5 measure exactly that).
  method ShadingExpression {expression what} {
    if {[string trim $expression] eq {}} {
      return -code error -errorcode [list TCLPDF SHADING EXPRESSION $what] \
          "tclpdf: $what needs -expression, the body of a PostScript\
          calculator function (ISO 32000-2, 7.10.5) - it takes x and y from\
          the stack and leaves one number per colour component"
    }
    return [::tclpdf::pdfFunction checkCalculator $expression \
        "-expression of $what" [list TCLPDF SHADING EXPRESSION $what]]
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

package provide tclpdf::shading 1.6