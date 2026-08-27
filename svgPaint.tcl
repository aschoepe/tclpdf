#
# tclpdf - PDF generation for Tcl
#
# svgPaint - what a shape is filled and stroked with
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Bounding box, paint, style cascade and gradients. The bounding box is
# here rather than with the shapes because it is READ BACK from the
# operators a shape produced: objectBoundingBox gradients need the extent
# of the thing they fill, and only the finished path knows it.
#
# A private sub-module behind the svg facade: nothing loads this directly, and
# the methods stay private to the document class. Split off when svg.tcl had
# grown to 864 lines - the drawing kept gaining features and the file kept
# taking them.
#

package require Tcl 8.6.11-
package require tclpdf::document 1.0-

oo::define ::tclpdf::document::document {

  method SvgBounds {operators} {
    # The operators are read WITH their letters, not as a flat list of
    # numbers. A rectangle is "x y w h re": pairing the numbers blindly reads
    # "w h" as a second point, and a rectangle at y=55 of height 45 comes out
    # as a box from 45 to 55 instead of 55 to 100.
    #
    # That was not cosmetic - it is what made every gradient with a vertical
    # axis come out flat, while the horizontal ones looked right because
    # their box happened to be correct by accident.
    set minX {}
    foreach line [split $operators \n] {
      set fields [regexp -all -inline -- {[-0-9.]+|[a-zA-Z*]+} $line]
      set operator [lindex $fields end]
      set numbers [lrange $fields 0 end-1]
      set points {}
      switch -- $operator {
        re {
          lassign $numbers x y width height
          if {$height eq {}} {
            continue
          }
          set points [list $x $y [expr {$x + $width}] [expr {$y + $height}]]
        }
        m - l {
          if {[llength $numbers] >= 2} {
            set points [lrange $numbers 0 1]
          }
        }
        c {
          # All three control points: the curve stays inside their hull, so
          # this is an upper bound and never cuts the shape short.
          if {[llength $numbers] >= 6} {
            set points [lrange $numbers 0 5]
          }
        }
        default {continue}
      }
      foreach {x y} $points {
        if {$y eq {}} {
          break
        }
        if {$minX eq {}} {
          lassign [list $x $x $y $y] minX maxX minY maxY
          continue
        }
        set minX [expr {min($minX, $x)}]
        set maxX [expr {max($maxX, $x)}]
        set minY [expr {min($minY, $y)}]
        set maxY [expr {max($maxY, $y)}]
      }
    }
    if {$minX eq {}} {
      return {}
    }
    return [list $minX $minY [expr {$maxX - $minX}] [expr {$maxY - $minY}]]
  }

  # Fill and stroke a completed path, then paint it.
  method SvgPaint {operators style} {
    if {$operators eq {}} {
      return
    }
    # Now the shape is known, so a gradient measured in fractions of it can
    # be resolved. What cannot be resolved - a filter, a dangling id - is
    # left unpainted rather than guessed at, and counted for [svg info].
    my state svgShapeBox [my SvgBounds $operators]
    foreach key {fill stroke} {
      set value [dict get $style $key]
      if {![string match "url(*" $value]} {
        continue
      }
      set resolved [my SvgPaintServer $value [my state svgShapeBox]]
      if {$resolved ne {}} {
        dict set style $key $resolved
      } else {
        dict set style $key none
        my SvgSkipped gradient
      }
    }
    set fill [dict get $style fill]
    set stroke [dict get $style stroke]
    set hasFill [expr {$fill ne "none" && $fill ne {}}]
    set hasStroke [expr {$stroke ne "none" && $stroke ne {}}]
    if {!$hasFill && !$hasStroke} {
      return
    }
    # Assembled first, written afterwards: a colour the parser refuses used
    # to arrive after a bare [save] that nothing counted, and the drawing's
    # unwinding at the end could not close it. Every value below is checked
    # or defaulted before a byte reaches the stream, and the bracket goes
    # through SvgSave/SvgRestore like every other one in a drawing.
    set body {}
    if {$hasFill} {
      # Through GraphicsColour rather than straight into the parser: that is
      # what turns a pattern ALIAS into the resource name the content stream
      # needs. Without it the operator names the alias and the reader reports
      # an unknown pattern - a page with the shapes drawn and nothing in them.
      append body "[::tclpdf::color operator [::tclpdf::color parse [my GraphicsColour $fill svg]] fill]\n"
    }
    if {$hasStroke} {
      append body "[::tclpdf::color operator [::tclpdf::color parse [my GraphicsColour $stroke svg]] stroke]\n"
      # A negative width is an error in SVG and the property is then
      # ignored, which leaves the initial value of 1 (SVG 1.1, 11.4).
      set width [my SvgLength [dict get $style stroke-width] 1]
      if {$width < 0} {
        set width 1
      }
      append body "[::tclpdf::pdfObj num $width] w\n"
      set caps {butt 0 round 1 square 2}
      if {[dict exists $caps [dict get $style stroke-linecap]]} {
        append body "[dict get $caps [dict get $style stroke-linecap]] J\n"
      }
      set joins {miter 0 round 1 bevel 2}
      if {[dict exists $joins [dict get $style stroke-linejoin]]} {
        append body "[dict get $joins [dict get $style stroke-linejoin]] j\n"
      }
      set dash [my SvgDashArray [dict get $style stroke-dasharray]]
      if {[llength $dash]} {
        append body "\[[join $dash { }]\] 0 d\n"
      }
    }
    # Three properties, two operands: fill-opacity goes into /ca,
    # stroke-opacity into /CA, and opacity into both. For a SHAPE that
    # product is its own value - a container's own factor never arrives
    # here on PDF 1.4 or later, it is applied once to the finished
    # transparency group (SvgGroup in svgElement.tcl). What remains
    # approximate is the shape itself: /ca and /CA are exact wherever fill
    # and stroke do not overlap, and off by the overlap where they do.
    # Each value is clamped, not refused: SVG defines them as
    # numbers clamped to 0..1, so 1.5 is opaque and -0.2 is invisible. One
    # "gs" when the two sides agree, one per side when they differ; nothing
    # at 1, which is the initial state anyway. Measured before 2026-08-18
    # only fill-opacity was applied, and opacity and stroke-opacity were
    # read and dropped although the header claimed them.
    #
    # THE TEST IS [option finite], not [string is double -strict]. Both are
    # true of "NaN", and only the second lets it into the clamp - where
    # min() and max() are arithmetic functions and [expr] refuses NaN as an
    # operand, so fill-opacity="NaN" died with Tcl's "floating point value is
    # Not a Number" and no error code at all (measured 2026-08-27). Neither
    # NaN nor Inf is an SVG <number> (SVG 1.1, 4.2), so the declaration is in
    # error and the property is ignored, which is what this branch has always
    # done with a value that is no number - not refused, because unlike a
    # colour an opacity has an initial value to fall back to (SVG 1.1, 14.5).
    set group [dict get $style opacity]
    if {![::tclpdf::option finite $group]} {
      set group 1
    }
    set alphas {}
    foreach key {fill-opacity stroke-opacity} {
      set alpha [dict get $style $key]
      if {![::tclpdf::option finite $alpha]} {
        set alpha 1
      }
      lappend alphas [expr {max(0.0, min(1.0, $alpha)) * max(0.0, min(1.0, $group))}]
    }
    lassign $alphas fillAlpha strokeAlpha
    if {$fillAlpha == $strokeAlpha} {
      if {$fillAlpha != 1} {
        append body "[::tclpdf::pdfObj name [my GraphicsOpacity $fillAlpha both]] gs\n"
      }
    } else {
      foreach {alpha which} [list $fillAlpha fill $strokeAlpha stroke] {
        if {$alpha != 1} {
          append body "[::tclpdf::pdfObj name [my GraphicsOpacity $alpha $which]] gs\n"
        }
      }
    }
    append body $operators
    set evenOdd [expr {[dict get $style fill-rule] eq "evenodd"}]
    if {$hasFill && $hasStroke} {
      append body [expr {$evenOdd ? "B*\n" : "B\n"}]
    } elseif {$hasFill} {
      append body [expr {$evenOdd ? "f*\n" : "f\n"}]
    } else {
      append body "S\n"
    }
    # While a transparency group is being captured (SvgGroup) its BBox is
    # collected from the shapes as they are painted - the operators are the
    # only description of the extent there is. A stroke reaches beyond the
    # path: half the width at an edge, and a miter spike up to the miter
    # limit of 10 times half the width (8.4.3.5) - so a stroked shape is
    # padded by five widths. A BBox clips, so too small is a defect and too
    # large is only a bigger group.
    if {[llength [my state svgGroupStack]] && [my state svgShapeBox] ne {}} {
      lassign [my state svgShapeBox] boxX boxY boxWidth boxHeight
      set pad [expr {$hasStroke ? $width * 5 : 0}]
      my SvgGroupBox [expr {$boxX - $pad}] [expr {$boxY - $pad}] \
          [expr {$boxX + $boxWidth + $pad}] [expr {$boxY + $boxHeight + $pad}]
    }
    my SvgSave
    my content $body
    my SvgRestore
    return
  }

  # A paint value that names a paint server - url(#id) - as the value to paint
  # with: {pattern <resource>}, or the empty string when there is no such
  # server or it cannot be honoured. The caller then reports it through
  # [svg info] and paints something visible instead.
  #
  # THE BOX IS AN ARGUMENT rather than read from the state, and that is the
  # whole reason this is a building block instead of four lines inside
  # [SvgPaint]. A shape has its box the moment its operators exist; a line of
  # text has none until it has been measured - and under the default
  # gradientUnits="objectBoundingBox" that box IS the gradient's coordinate
  # system, so whoever knows it has to say so. It is put into the state around
  # the call, where [SvgGradient] has always looked for it.
  method SvgPaintServer {value box} {
    if {![string match "url(*" $value]} {
      return {}
    }
    set saved [my state svgShapeBox]
    my state svgShapeBox $box
    set resolved [my SvgGradient [string trim [string range $value 4 end-1] "#'\" "]]
    my state svgShapeBox $saved
    if {$resolved eq {}} {
      return {}
    }
    return [list pattern $resolved]
  }

  # A stroke-dasharray as the lengths of a PDF dash array, or an empty list
  # for a solid line.
  #
  # SVG numbers may carry an exponent - "1e-3" is a length - and the old
  # pattern [0-9.]+ cut it into 1 and 3, so a dash written that way came out
  # coarser and one entry longer, with nothing to say so. Negative values
  # make the whole property an error and it is ignored (SVG 1.1, 11.4); a
  # sum of zero is rendered as if none were given. Both are what a PDF reader
  # would need anyway: 8.4.3.6 wants the lengths non-negative and not all
  # zero.
  method SvgDashArray {value} {
    if {$value eq {} || $value eq "none"} {
      return {}
    }
    set numbers [regexp -all -inline -- \
        {[-+]?(?:[0-9]*\.)?[0-9]+(?:[eE][-+]?[0-9]+)?} $value]
    if {![llength $numbers]} {
      return {}
    }
    set sum 0
    foreach number $numbers {
      if {$number < 0} {
        return {}
      }
      set sum [expr {$sum + $number}]
    }
    if {$sum == 0} {
      return {}
    }
    return [lmap number $numbers {::tclpdf::pdfObj num $number}]
  }

  # Merge the element's own painting properties over the inherited ones. The
  # style="" attribute wins over presentation attributes (SVG 6.4).
  # A colour in the FUNCTIONAL notation, translated into what this package
  # writes. Everything else is handed on untouched: [color parse] already
  # reads "#rgb", "#rrggbb" and the named colours, and this is the one
  # spelling it does not.
  #
  # NOT A FLOURISH. SVG 1.1, 11.13.1 lists "rgb(255,255,255)" and
  # "rgb(100%,100%,100%)" among the four ways of writing a colour, and until
  # 2026-08-24 a drawing using it was refused OUTRIGHT - "colour component is
  # not a number: rgb(245," - so the whole file was lost over a notation the
  # standard names first. Measured over the SVG on this machine with the icon
  # libraries taken out: 6 of 167 files, one of them a floor plan, none of
  # them drawable.
  #
  # rgba() is CSS Color 3 rather than SVG 1.1, and it occurs twice in the same
  # corpus. Its fourth value is a real alpha, so it is multiplied into the
  # opacity property that belongs to the side it paints instead of being
  # dropped - a translucent colour drawn opaque is a wrong picture, and a
  # refused one is no picture at all.
  #
  # Returns a two-element list: the colour, and the alpha to fold in (1 where
  # there is none). Anything it cannot read is handed back unchanged, so the
  # refusal still comes from the colour module and still names the value.
  #
  # THE ATTRIBUTE IS AN ARGUMENT because the refusal below is the one that
  # cannot be handed on: a component that IS a double but is not finite has
  # nothing left for [color parse] to name - see [SvgColourFinite].
  method SvgColourValue {value attribute} {
    if {![regexp -nocase {^\s*rgba?\s*\((.*)\)\s*$} $value -> inside]} {
      return [list $value 1]
    }
    set parts {}
    foreach part [split [string map {, " "} $inside]] {
      set part [string trim $part]
      if {$part ne {}} {
        lappend parts $part
      }
    }
    if {[llength $parts] < 3} {
      return [list $value 1]
    }
    set channels {}
    foreach part [lrange $parts 0 2] {
      if {[string index $part end] eq "%"} {
        set number [string range $part 0 end-1]
        if {![string is double -strict $number]} {
          return [list $value 1]
        }
        my SvgColourFinite $number $value $attribute
        lappend channels [expr {max(0.0, min(1.0, $number / 100.0))}]
      } else {
        if {![string is double -strict $part]} {
          return [list $value 1]
        }
        my SvgColourFinite $part $value $attribute
        lappend channels [expr {max(0.0, min(1.0, $part / 255.0))}]
      }
    }
    set alpha 1
    if {[llength $parts] > 3 && [string is double -strict [lindex $parts 3]]} {
      my SvgColourFinite [lindex $parts 3] $value $attribute
      set alpha [expr {max(0.0, min(1.0, double([lindex $parts 3])))}]
    }
    return [list [linsert $channels 0 rgb] $alpha]
  }

  # A component of the functional notation, refused where it is a double to
  # Tcl but not a finite number.
  #
  # NOT the same road as the rest of [SvgColourValue]. What that method
  # cannot READ - "rgb(oops)" - it hands back untouched, and [color parse]
  # then refuses the whole value by name; NaN and Inf have no such second
  # chance, because they pass [string is double -strict] and go straight into
  # the clamp. min() and max() are arithmetic functions and [expr] refuses
  # NaN as their operand, so a drawing with "rgb(NaN,0,0)" died with Tcl's
  # own "floating point value is Not a Number" (measured 2026-08-27), against
  # the promise that every refusal begins with "tclpdf:"; Inf came through
  # the clamp as 1.0 and painted a channel the file never asked for. Since
  # 2026-08-27 the colour module refuses both in every component (TCLPDF
  # COLOUR COMPONENTS number), and this is the same rule at the one point
  # that never reaches it.
  #
  # The refusal names the ATTRIBUTE as well as the value: fill and stroke
  # carry the same notation, and the two are told apart nowhere downstream.
  # [option finite] is the package's one predicate for this - a second copy
  # is how two modules come to disagree about what a number is.
  method SvgColourFinite {number value attribute} {
    if {[::tclpdf::option finite $number]} {
      return
    }
    return -code error -errorcode [list TCLPDF SVG COLOUR $attribute] \
        "tclpdf: $attribute has a colour component that names no colour,\
        \"$number\" in \"$value\" - NaN and Inf are doubles to Tcl and paint\
        nothing"
  }

  method SvgStyle {node inheritedStyle} {
    set style $inheritedStyle
    # opacity is not inherited but MULTIPLIED (SVG 1.1, 14.5): it applies to
    # the element as a whole, children included, so a child inside a group
    # at 0.5 is at 0.5 times its own. The style carries the product; the
    # element's own value is collected on its own below and folded in.
    set groupOpacity 1
    if {[dict exists $style opacity] \
        && [::tclpdf::option finite [dict get $style opacity]]} {
      set groupOpacity [dict get $style opacity]
    }
    dict set style opacity {}
    foreach key {fill stroke stroke-width stroke-linecap stroke-linejoin
        stroke-dasharray fill-opacity stroke-opacity fill-rule opacity
        font-size font-family font-weight text-anchor} {
      if {![dict exists $style $key]} {
        dict set style $key {}
      }
      set value [::tclpdf::xml attribute $node $key]
      if {$value ne {}} {
        dict set style $key $value
      }
    }
    foreach {-> key value} [regexp -all -inline {([-a-z]+)\s*:\s*([^;]+)} \
        [::tclpdf::xml attribute $node style]] {
      dict set style $key [string trim $value]
    }
    # The functional notation, resolved here so that everything downstream
    # sees the one spelling the package writes - and so that an rgba() alpha
    # reaches the opacity of the side it belongs to rather than being lost
    # between them.
    foreach {key opacityKey} {fill fill-opacity stroke stroke-opacity} {
      set value [dict get $style $key]
      if {$value eq {} || $value eq "none"} {
        continue
      }
      lassign [my SvgColourValue $value $key] colour alpha
      dict set style $key $colour
      if {$alpha != 1} {
        set was [dict get $style $opacityKey]
        if {![::tclpdf::option finite $was]} {
          set was 1
        }
        dict set style $opacityKey [expr {$was * $alpha}]
      }
    }
    set own [dict get $style opacity]
    if {![::tclpdf::option finite $own]} {
      set own 1
    }
    set own [expr {max(0.0, min(1.0, $own))}]
    # The element's OWN factor, kept apart from the product: a container
    # whose own opacity is below one becomes a transparency group
    # (SvgGroup), and there the factor is applied once to the finished
    # group rather than multiplied into every child.
    dict set style ownOpacity $own
    dict set style opacity [expr {$groupOpacity * $own}]
    # A url(#...) reference is left STANDING here and resolved in SvgPaint.
    # It cannot be done at this point: a gradient in the default units is
    # measured in fractions of the shape it fills, and the shape does not
    # exist yet - the style is worked out before the path operators are.
    return $style
  }

  # A <linearGradient> or <radialGradient> as a shading pattern.
  #
  # gradientUnits is the trap. The default, objectBoundingBox, measures in
  # fractions of the shape being filled, not in drawing coordinates - so
  # x1="0" x2="1" means "left edge to right edge of whatever this fills". The
  # bounding box is worked out from the path operators, because at this point
  # they are the only description of the shape there is.
  #
  # The resource name is NOT the SVG id. A pattern is bound to the page and
  # carries the drawing's matrix - and under objectBoundingBox the filled
  # shape's box on top of that - so the same id can need a different object
  # per drawing and per shape. Named after the id, the second registration
  # collided with the first and the shape went unfilled: the same file drawn
  # at four sizes had colour only in the first one, and a second file whose
  # gradient happened to share an id lost its own. The names come from a
  # document-wide counter instead, and the reuse key is what actually makes
  # two uses interchangeable: the gradient plus every argument of the pattern.
  method SvgGradient {id} {
    set node [my SvgDefinition $id]
    if {$node eq {}} {
      return {}
    }
    set kind [string map {svg: {}} [::tclpdf::xml name $node]]
    if {$kind ni {linearGradient radialGradient}} {
      return {}
    }

    # Stops. A gradient inheriting them through href is followed once - that
    # is the only case measured in the corpus.
    set stops [my SvgStops $node]
    if {[llength $stops] < 2} {
      set reference [::tclpdf::xml attribute $node href \
          [::tclpdf::xml attribute $node xlink:href]]
      set inheritedFrom [my SvgDefinition [string trimleft $reference #]]
      if {$inheritedFrom ne {}} {
        set stops [my SvgStops $inheritedFrom]
      }
    }
    if {[llength $stops] < 2} {
      return {}
    }

    lassign [my state svgBox] boxX boxY boxWidth boxHeight
    set units [::tclpdf::xml attribute $node gradientUnits objectBoundingBox]
    if {$units eq "userSpaceOnUse"} {
      set frameX $boxX
      set frameY $boxY
      set frameWidth $boxWidth
      set frameHeight $boxHeight
    } else {
      # In fractions of the shape - and the shape is what is about to be
      # filled, so its box is taken from the operators just built.
      lassign [my state svgShapeBox] frameX frameY frameWidth frameHeight
      if {$frameWidth eq {} || $frameWidth <= 0} {
        lassign [list $boxX $boxY $boxWidth $boxHeight] \
            frameX frameY frameWidth frameHeight
      }
    }

    set colors {}
    set offsets {}
    foreach stop $stops {
      lappend colors [lindex $stop 1]
      lappend offsets [lindex $stop 0]
    }

    # The pattern's matrix is the group transformation followed by the
    # drawing's own - in that order, because the shape's coordinates pass
    # through the group first. Leaving the group out is what put every
    # gradient inside a translated group in the wrong place, while the ones
    # at the top level looked right.
    #
    # Inside a transparency group's form (SvgGroup) the anchor changes: a
    # pattern maps to the default space of its parent CONTENT STREAM, and
    # for a shape captured into the form that is the form's space, onto
    # which the CTM at the Do is applied again. Measured with pdftoppm, the
    # full chain there ran the drawing's scale twice and a gradient came
    # out stretched to a single colour - so within a capture the matrix is
    # only the path from the shape's coordinates to the form's.
    set stack [my state svgGroupStack]
    if {[llength $stack]} {
      set matrix [dict get [lindex $stack end] rel]
    } else {
      set matrix [::tclpdf::geometry multiply [my state svgTransform] \
          [my state svgMatrix]]
    }
    set arguments [list -colors $colors -stops $offsets -matrix $matrix]
    if {$kind eq "linearGradient"} {
      set x1 [my SvgFraction [::tclpdf::xml attribute $node x1 0] $frameWidth $frameX]
      set y1 [my SvgFraction [::tclpdf::xml attribute $node y1 0] $frameHeight $frameY]
      set x2 [my SvgFraction [::tclpdf::xml attribute $node x2 1] $frameWidth $frameX]
      set y2 [my SvgFraction [::tclpdf::xml attribute $node y2 0] $frameHeight $frameY]
      lappend arguments -from [list $x1 $y1] -to [list $x2 $y2] \
          -at [list $frameX $frameY] -size [list $frameWidth $frameHeight]
      set sub axial
    } else {
      set cx [my SvgFraction [::tclpdf::xml attribute $node cx 0.5] $frameWidth $frameX]
      set cy [my SvgFraction [::tclpdf::xml attribute $node cy 0.5] $frameHeight $frameY]
      set r [my SvgFraction [::tclpdf::xml attribute $node r 0.5] \
          [expr {max($frameWidth, $frameHeight)}] 0]
      lappend arguments -center [list $cx $cy] -radius $r \
          -at [list $frameX $frameY] -size [list $frameWidth $frameHeight]
      set sub radial
    }
    # Reuse only what is genuinely interchangeable: same gradient, same
    # geometry, same matrix. Two shapes sharing one userSpaceOnUse gradient
    # under the same transformation stay one object; under objectBoundingBox
    # each shape's box differs and each gets its own.
    set known [my state svgGradients]
    set key [list $id $sub $arguments]
    if {[dict exists $known $key]} {
      return [dict get $known $key]
    }
    set sequence [my state svgGradientSeq]
    if {$sequence eq {}} {
      set sequence 0
    }
    my state svgGradientSeq [incr sequence]
    set name svgGradient$sequence
    # No catch around the registration. It used to swallow the name collision
    # into "no pattern", and a swallowed error looks like a design choice -
    # four drawings of the same file, three of them without colour. With
    # unique names a failure here is a real defect and must be heard.
    my shading pattern $name $sub {*}$arguments
    dict set known $key $name
    my state svgGradients $known
    return $name
  }

  # The stops of a gradient, as {offset colour} pairs. stop-color may sit in
  # an attribute or inside style="" - both occur, the second more often.
  method SvgStops {node} {
    set stops {}
    foreach child [::tclpdf::xml children $node] {
      if {[string map {svg: {}} [::tclpdf::xml name $child]] ne "stop"} {
        continue
      }
      set offset [::tclpdf::xml attribute $child offset 0]
      if {[string match {*%} $offset]} {
        # Only a number gets divided. offset="NaN%" and offset="oops%" both
        # went into [expr] as an operand of "/" and came back in Tcl's words
        # rather than this package's (measured 2026-08-27); handed on
        # untouched they take the same road as offset="NaN" without the per
        # cent, which [shading] refuses by name.
        set number [string trimright $offset %]
        if {[::tclpdf::option finite $number]} {
          set offset [expr {$number / 100.0}]
        } else {
          set offset $number
        }
      }
      set colour [::tclpdf::xml attribute $child stop-color]
      foreach {-> key value} [regexp -all -inline {([-a-z]+)\s*:\s*([^;]+)} \
          [::tclpdf::xml attribute $child style]] {
        if {$key eq "stop-color"} {
          set colour [string trim $value]
        }
      }
      if {$colour eq {} || [string match "url(*" $colour]} {
        set colour black
      }
      lappend stops [list $offset $colour]
    }
    return $stops
  }

  # A gradient coordinate: a fraction of the frame, or a length in it.
}

package provide tclpdf::svgPaint 1.7
