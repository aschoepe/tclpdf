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
    set currentX {}
    set currentY {}
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
          set currentX $x
          set currentY $y
        }
        m - l {
          if {[llength $numbers] >= 2} {
            set points [lrange $numbers 0 1]
            lassign $numbers currentX currentY
          }
        }
        c {
          # THE CURVE, not the hull of its control points. SVG 1.1, 7.11 asks
          # for "the tightest fitting rectangle" in the object's own user
          # space, and a cubic reaches its extremes at the roots of its
          # derivative - which for a drawn arc lie well inside the control
          # polygon. Measured 2026-08-27 on "M0,10 C0,110 100,110 100,10 Z":
          # the real lower edge is y = 85 and the control points sit at
          # y = 110, so an objectBoundingBox gradient ran only 75 % of its
          # ramp inside the shape and the bottom stayed grey.
          if {[llength $numbers] >= 6} {
            lassign $numbers x1 y1 x2 y2 x3 y3
            set points [list $x3 $y3]
            if {$currentX ne {}} {
              lappend points {*}[my SvgCurveExtrema \
                  $currentX $currentY $x1 $y1 $x2 $y2 $x3 $y3]
            } else {
              lappend points $x1 $y1 $x2 $y2
            }
            set currentX $x3
            set currentY $y3
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

  # The points a cubic Bezier actually reaches between its end points, per
  # axis: the roots of the derivative that lie in 0..1, evaluated. The end
  # points themselves are added by the caller.
  #
  # B'(t) = 3(1-t)^2 (p1-p0) + 6(1-t)t (p2-p1) + 3t^2 (p3-p2), which is the
  # quadratic a t^2 + b t + c with a = -p0+3p1-3p2+p3, b = 2(p0-2p1+p2),
  # c = p1-p0. At most two roots per axis, so at most four extra points.
  method SvgCurveExtrema {x0 y0 x1 y1 x2 y2 x3 y3} {
    set points {}
    foreach axis {x y} {
      if {$axis eq "x"} {
        lassign [list $x0 $x1 $x2 $x3] p0 p1 p2 p3
      } else {
        lassign [list $y0 $y1 $y2 $y3] p0 p1 p2 p3
      }
      set a [expr {-$p0 + 3.0 * $p1 - 3.0 * $p2 + $p3}]
      set b [expr {2.0 * ($p0 - 2.0 * $p1 + $p2)}]
      set c [expr {$p1 - $p0}]
      set roots {}
      if {abs($a) < 1e-12} {
        if {abs($b) > 1e-12} {
          lappend roots [expr {-$c / $b}]
        }
      } else {
        set discriminant [expr {$b * $b - 4.0 * $a * $c}]
        if {$discriminant >= 0} {
          set root [expr {sqrt($discriminant)}]
          lappend roots [expr {(-$b + $root) / (2.0 * $a)}] \
              [expr {(-$b - $root) / (2.0 * $a)}]
        }
      }
      foreach t $roots {
        if {$t <= 0 || $t >= 1} {
          continue
        }
        set u [expr {1.0 - $t}]
        set value [expr {$u * $u * $u * $p0 + 3.0 * $u * $u * $t * $p1 +
            3.0 * $u * $t * $t * $p2 + $t * $t * $t * $p3}]
        # The caller reads PAIRS, so the other axis is filled with a value
        # that is on the curve anyway - the start point. An extreme of x says
        # nothing about y and must not be read as one.
        if {$axis eq "x"} {
          lappend points $value $y0
        } else {
          lappend points $x0 $value
        }
      }
    }
    return $points
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
    # A ZERO STROKE WIDTH PAINTS NOTHING. SVG 1.1, 11.4: "A zero value causes
    # no stroke to be painted." ISO 32000-2, 8.4.3.2 says the opposite for
    # PDF - "0 w" is the thinnest line the device can render, which on a
    # platesetter is thinner still - so writing the number through put a red
    # hairline on a page where the file asked for nothing, and no checker
    # says a word about it. A NEGATIVE width is an error and the property
    # falls back to its initial value of 1, which is the line below.
    set width [my SvgLength [dict get $style stroke-width] 1 d]
    if {$width < 0} {
      set width 1
    }
    set hasStroke [expr {$stroke ne "none" && $stroke ne {} && $width > 0}]
    if {!$hasFill && !$hasStroke} {
      return
    }
    # visibility is inherited and is read WHERE THE PAINTING HAPPENS, not on
    # the way down (SVG 1.1, 11.5): a child that says "visible" under a
    # hidden group is drawn, which is only possible if the walk descends into
    # the group. "collapse" is the same as "hidden" outside a table.
    if {[string tolower [string trim [dict get $style visibility]]] in
        {hidden collapse}} {
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
      append body "[::tclpdf::color operator [my SvgLuminosity \
          [::tclpdf::color parse [my GraphicsColour $fill svg]]] fill]\n"
    }
    if {$hasStroke} {
      append body "[::tclpdf::color operator [my SvgLuminosity \
          [::tclpdf::color parse [my GraphicsColour $stroke svg]]] stroke]\n"
      append body "[::tclpdf::pdfObj num $width] w\n"
      set caps {butt 0 round 1 square 2}
      if {[dict exists $caps [dict get $style stroke-linecap]]} {
        append body "[dict get $caps [dict get $style stroke-linecap]] J\n"
      }
      set joins {miter 0 round 1 bevel 2}
      set join [string trim [dict get $style stroke-linejoin]]
      if {[dict exists $joins $join]} {
        append body "[dict get $joins $join] j\n"
      }
      # THE MITER LIMIT IS ALWAYS WRITTEN where the join is a miter, and the
      # reason is a difference in the two initial values: SVG 1.1, 11.4 makes
      # stroke-miterlimit 4, ISO 32000-2, 8.4.3.5 makes the PDF one 10. A
      # file that says nothing therefore came out with spikes SVG would have
      # cut off - measured 2026-08-27, every corner under 28.96 degrees
      # differs from rsvg. A value below 1 is an error and the property falls
      # back (11.4).
      if {$join eq {} || $join eq "miter" || $join eq "inherit"} {
        set limit [my SvgLength [dict get $style stroke-miterlimit] 4 d]
        if {$limit < 1} {
          set limit 4
        }
        append body "[::tclpdf::pdfObj num $limit] M\n"
      }
      set dash [my SvgDashArray [dict get $style stroke-dasharray]]
      if {[llength $dash]} {
        # The second operand of "d" is the phase (8.4.3.6), which is exactly
        # what stroke-dashoffset names - it was written as a fixed 0. A
        # negative value is an error and the property is ignored (11.4).
        set phase [my SvgLength [dict get $style stroke-dashoffset] 0 d]
        if {$phase < 0} {
          set phase 0
        }
        append body "\[[join $dash { }]\] [::tclpdf::pdfObj num $phase] d\n"
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
  # The answer is the finished PAINT VALUE and not a pattern name, because a
  # gradient with exactly one stop is a solid colour (13.2.4) and a radial one
  # of radius zero is the colour of its last stop (13.2.3) - two cases that
  # have no pattern at all. [SvgGradient] returns whichever it is.
  method SvgPaintServer {value box} {
    if {![string match "url(*" $value]} {
      return {}
    }
    set saved [my state svgShapeBox]
    my state svgShapeBox $box
    try {
      set resolved [my SvgGradient [string trim [string range $value 4 end-1] "#'\" "]]
    } finally {
      my state svgShapeBox $saved
    }
    return $resolved
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

  # The style cascade of one element - the painting properties it inherits
  # with its own written over them (SVG 6.4). The functional colour notation
  # is read in svg.tcl, at [SvgColourValue].

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
    # display is NOT inherited (SVG 1.1, 11.5): a group that is not rendered
    # takes its children with it, but a child of a rendered group does not
    # inherit "none" from a sibling's declaration. So the slot is emptied
    # before the element's own value is read, exactly as opacity's is.
    dict set style display {}
    foreach key {fill stroke stroke-width stroke-linecap stroke-linejoin
        stroke-miterlimit stroke-dasharray stroke-dashoffset fill-opacity
        stroke-opacity fill-rule opacity font-size font-family font-weight
        text-anchor color display visibility} {
      if {![dict exists $style $key]} {
        dict set style $key {}
      }
      set value [::tclpdf::xml attribute $node $key]
      if {$value ne {}} {
        dict set style $key $value
      }
    }
    # A declaration in style="" beats the presentation attribute (SVG 6.4).
    # Read through [SvgDeclarations], which is where !important and a CSS
    # comment are taken off the value - until 2026-08-27 "fill:#0a0
    # !important" reached the colour module whole and cost the drawing.
    dict for {key value} [my SvgDeclarations [::tclpdf::xml attribute $node style]] {
      dict set style $key $value
    }
    # currentColor, which is a <paint> in its own right (SVG 4.2 and 11.3):
    # it stands for the value of the "color" property, whose initial value is
    # black. Resolved HERE, before anything downstream sees it - handed on
    # untouched it reached [color parse] as a colour name and cost the whole
    # drawing, and it is the spelling both icon libraries in the corpus use
    # for "take the colour of your surroundings".
    set current [string trim [dict get $style color]]
    if {$current eq {} || [string equal -nocase $current currentColor] ||
        [string equal -nocase $current inherit]} {
      set current black
    } else {
      set current [lindex [my SvgColourValue $current color] 0]
    }
    dict set style color $current
    foreach key {fill stroke} {
      if {[string equal -nocase [string trim [dict get $style $key]] currentColor]} {
        dict set style $key $current
      }
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
  # A gradient with everything it inherits through href, as
  # {kind attributes stops}.
  #
  # SVG 1.1, 13.2.4 makes the inheritance cover the ATTRIBUTES as well as the
  # stops: "if this element has no defined gradient stops, and the referenced
  # element does ... then this element inherits" is one sentence of it, and
  # the list of attributes above it - gradientUnits, gradientTransform,
  # spreadMethod, the end points, the circle - is the other. Only the stops
  # were followed until 2026-08-27, so a gradient that took its geometry from
  # a base and stated only its own colours came out with the DEFAULTS: a
  # vertical ramp ran horizontally, and nothing said so.
  #
  # The chain is walked with the ids seen on it, because href may point back:
  # a cycle ends the walk instead of the process.
  method SvgGradientChain {id} {
    set kind {}
    set attributes [dict create]
    set stops {}
    set seen [dict create]
    set current [string trim $id]
    while {$current ne {} && ![dict exists $seen $current]} {
      dict set seen $current 1
      set node [my SvgDefinition $current]
      if {$node eq {}} {
        break
      }
      set name [string map {svg: {}} [::tclpdf::xml name $node]]
      if {$name ni {linearGradient radialGradient}} {
        break
      }
      if {$kind eq {}} {
        set kind $name
      }
      # The nearer element wins, which is what "an attribute the element does
      # not state is taken from the one it references" means.
      foreach key {gradientUnits gradientTransform spreadMethod
          x1 y1 x2 y2 cx cy r fx fy} {
        set value [::tclpdf::xml attribute $node $key]
        if {$value ne {} && ![dict exists $attributes $key]} {
          dict set attributes $key $value
        }
      }
      if {![llength $stops]} {
        set stops [my SvgStops $node]
      }
      set current [string trimleft [string trim [::tclpdf::xml attribute \
          $node href [::tclpdf::xml attribute $node xlink:href]]] #]
    }
    return [list $kind $attributes $stops]
  }

  # A number in objectBoundingBox units: a fraction, or a per cent of one.
  # Values outside 0..1 are legal there (13.2.3 puts a focus outside the box).
  method SvgUnitValue {value default} {
    if {[string match {*%} $value]} {
      set value [string trimright $value %]
      if {![::tclpdf::option finite $value]} {
        return $default
      }
      return [expr {$value / 100.0}]
    }
    if {![::tclpdf::option finite $value]} {
      return $default
    }
    return $value
  }

  method SvgGradient {id} {
    lassign [my SvgGradientChain $id] kind attributes stops
    if {$kind eq {}} {
      return {}
    }
    # THE TWO SILENT OMISSIONS. Neither is built - a spreadMethod other than
    # pad needs /Extend to repeat, which PDF's two booleans cannot do, and a
    # gradientTransform would have to be folded into a pattern matrix that
    # already carries three transforms. Until 2026-08-27 both went by without
    # a word, against the promise at the top of svg.tcl that a caller can see
    # what a drawing lost; an ignored ATTRIBUTE is exactly the kind of
    # omission that leaves no other trace.
    if {[dict exists $attributes spreadMethod] &&
        [dict get $attributes spreadMethod] ni {pad {}}} {
      my SvgSkipped spreadMethod
    }
    if {[dict exists $attributes gradientTransform]} {
      my SvgSkipped gradientTransform
    }
    if {![llength $stops]} {
      return {}
    }
    # ONE STOP IS A COLOUR, not nothing. SVG 1.1, 13.2.4: "If one gradient
    # stop is defined, then paint with the solid colour fill using the colour
    # defined for that gradient stop." Only NO stop means the paint server
    # cannot be resolved. Measured 2026-08-27: a one-stop gradient made the
    # element vanish and was reported as an unresolvable gradient.
    if {[llength $stops] == 1} {
      if {[lindex [lindex $stops 0] 2] != 1} {
        my SvgSkipped stop-opacity
      }
      return [lindex [lindex $stops 0] 1]
    }
    foreach stop $stops {
      if {[lindex $stop 2] != 1} {
        # A per-stop alpha is a luminosity /SMask running along the same
        # axis, which is a gradient of its own; reported rather than dropped
        # in silence, so the drawing does not quietly come out opaque.
        my SvgSkipped stop-opacity
        break
      }
    }

    lassign [my state svgBox] boxX boxY boxWidth boxHeight
    set units [expr {[dict exists $attributes gradientUnits]
        ? [dict get $attributes gradientUnits] : {objectBoundingBox}}]
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
    set arguments [list -colors $colors -stops $offsets]
    set stated [list x1 0 y1 0 x2 1 y2 0 cx 0.5 cy 0.5 r 0.5 fx {} fy {}]
    foreach {key fallback} $stated {
      if {[dict exists $attributes $key]} {
        dict set stated $key [dict get $attributes $key]
      }
    }
    if {$kind eq "linearGradient"} {
      set x1 [my SvgFraction [dict get $stated x1] $frameWidth $frameX $units x]
      set y1 [my SvgFraction [dict get $stated y1] $frameHeight $frameY $units y]
      set x2 [my SvgFraction [dict get $stated x2] $frameWidth $frameX $units x]
      set y2 [my SvgFraction [dict get $stated y2] $frameHeight $frameY $units y]
      lappend arguments -from [list $x1 $y1] -to [list $x2 $y2] \
          -at [list $frameX $frameY] -size [list $frameWidth $frameHeight] \
          -matrix $matrix
      set sub axial
    } elseif {$units eq "userSpaceOnUse"} {
      set cx [my SvgFraction [dict get $stated cx] $frameWidth $frameX $units x]
      set cy [my SvgFraction [dict get $stated cy] $frameHeight $frameY $units y]
      set r [my SvgFraction [dict get $stated r] $frameWidth 0 $units d]
      if {$r <= 0} {
        return [lindex [lindex $stops end] 1]
      }
      lappend arguments -center [list $cx $cy] -radius $r \
          -at [list $frameX $frameY] -size [list $frameWidth $frameHeight] \
          -matrix $matrix
      set sub radial
    } else {
      # A RADIAL GRADIENT IN objectBoundingBox UNITS IS AN ELLIPSE on a box
      # that is not square. SVG 1.1, 7.11 maps the UNIT SQUARE onto the
      # bounding box, and 13.2.3 defines the gradient as a circle in that
      # square - so the mapping belongs in the pattern's matrix, not in the
      # radii. Worked out per axis as it was until 2026-08-27, cx and cy came
      # out right and r could only be a scalar: on a 100x40 rectangle the
      # circle of r = 50 ran out of the shape at the top and bottom and went
      # dark too early at the sides. Written as a matrix, fx/fy and an r
      # beyond 1 come out right of their own accord.
      set cx [my SvgUnitValue [dict get $stated cx] 0.5]
      set cy [my SvgUnitValue [dict get $stated cy] 0.5]
      set r [my SvgUnitValue [dict get $stated r] 0.5]
      if {$r <= 0} {
        # 13.2.3: "A value of zero will cause the area to be painted as a
        # single colour using the colour and opacity of the last gradient
        # stop."
        return [lindex [lindex $stops end] 1]
      }
      lappend arguments -center [list $cx $cy] -radius $r \
          -at {0 0} -size {1 1} \
          -matrix [::tclpdf::geometry multiply \
              [list $frameWidth 0 0 $frameHeight $frameX $frameY] $matrix]
      if {[dict get $stated fx] ne {} && [dict get $stated fy] ne {}} {
        lappend arguments -focus [list \
            [my SvgUnitValue [dict get $stated fx] $cx] \
            [my SvgUnitValue [dict get $stated fy] $cy]]
      }
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
    dict set known $key [list pattern $name]
    my state svgGradients $known
    return [list pattern $name]
  }

  # The stops of a gradient, as {offset colour opacity} triples. stop-color
  # and stop-opacity may sit in an attribute or inside style="" - both occur,
  # the second more often.
  #
  # THE OFFSETS COME OUT IN ORDER, because the norm says how. SVG 1.1,
  # 13.2.4: "Each gradient offset value is required to be equal to or greater
  # than the previous ... If a given gradient stop's offset value is not equal
  # to or greater than all previous offset values, then the offset value is
  # adjusted to be equal to the largest of all previous offset values" - and
  # the whole range is clamped to 0..1. Handed through as they stood, an
  # out-of-order pair reached [shading] and cost the WHOLE drawing under
  # TCLPDF SHADING STOPS order, where the standard has an express repair
  # instruction. That refusal stays right for a caller who passes -stops
  # itself; here the file is repaired the way a reader would.
  #
  # PDF wants them STRICTLY increasing (7.10.4: Domain0 < Bounds0 < ... ), so
  # a clamped-to-equal pair is nudged apart by a hair rather than merged - the
  # hard colour transition the norm means is then still a transition. A stop
  # for which no room is left at the end of the ramp is dropped and reported.
  method SvgStops {node} {
    set stops {}
    set previous {}
    foreach child [::tclpdf::xml children $node] {
      if {[string map {svg: {}} [::tclpdf::xml name $child]] ne "stop"} {
        continue
      }
      set declarations [my SvgDeclarations [::tclpdf::xml attribute $child style]]
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
      if {[::tclpdf::option finite $offset]} {
        set offset [expr {max(0.0, min(1.0, double($offset)))}]
        if {$previous ne {} && $offset <= $previous} {
          # A HAIR, and not a hair's breadth: the offsets are compared as the
          # FILE will carry them, five decimals (7.3.3), so anything below
          # 1e-5 is the same number once written and [shading] refuses the
          # pair it was given to separate.
          set offset [expr {min(1.0, $previous + 1e-4)}]
        }
        if {$previous ne {} && $offset <= $previous} {
          my SvgSkipped stop-offset
          continue
        }
        set previous $offset
      }
      set colour [::tclpdf::xml attribute $child stop-color]
      if {[dict exists $declarations stop-color]} {
        set colour [dict get $declarations stop-color]
      }
      if {$colour eq {} || [string match "url(*" $colour]} {
        set colour black
      }
      set opacity [::tclpdf::xml attribute $child stop-opacity]
      if {[dict exists $declarations stop-opacity]} {
        set opacity [dict get $declarations stop-opacity]
      }
      if {![::tclpdf::option finite $opacity]} {
        set opacity 1
      }
      lappend stops [list $offset $colour [expr {max(0.0, min(1.0, $opacity))}]]
    }
    return $stops
  }
}

package provide tclpdf::svgPaint 1.8
