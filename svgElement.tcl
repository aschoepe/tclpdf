#
# tclpdf - PDF generation for Tcl
#
# svgElement - walking the element tree: shapes, use, text
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# One method per thing an SVG element can be. They share the inherited
# style and the current transformation, and each one ends by handing a
# path to the core - which is what makes an SVG drawing real vectors
# rather than a picture of one.
#
# A private sub-module behind the svg facade: nothing loads this directly, and
# the methods stay private to the document class. Split off when svg.tcl had
# grown to 864 lines - the drawing kept gaining features and the file kept
# taking them.
#

package require Tcl 8.6.11-
package require tclpdf::document 1.0-

oo::define ::tclpdf::document::document {

  method SvgCollect {node defs} {
    set id [::tclpdf::xml attribute $node id]
    if {$id ne {}} {
      dict set defs $id $node
    }
    foreach child [::tclpdf::xml children $node] {
      set defs [my SvgCollect $child $defs]
    }
    return $defs
  }

  # Draw one element and its children, carrying the inherited properties down.
  method SvgElement {node inheritedStyle} {
    set style [my SvgStyle $node $inheritedStyle]
    set name [string map {svg: {}} [::tclpdf::xml name $node]]

    if {[::tclpdf::xml attribute $node display] eq "none"} {
      return
    }
    set transform [::tclpdf::xml attribute $node transform]
    if {$transform ne {}} {
      # The transformation is applied to the content stream AND carried in
      # the state. The stream needs it to draw; the state needs it because a
      # pattern is bound to the page's default space and knows nothing about
      # the group it is used in - a gradient inside a translated group would
      # otherwise be placed as if the group were at the origin.
      set outerTransform [my state svgTransform]
      my state svgTransform [::tclpdf::geometry multiply \
          [my SvgTransform $transform] $outerTransform]
      my SvgSave
      my content "[join [lmap number [my SvgTransform $transform] {
        ::tclpdf::pdfObj num $number
      }] { }] cm\n"
    }

    switch -- $name {
      svg - g - a - switch {
        foreach child [::tclpdf::xml children $node] {
          my SvgElement $child $style
        }
      }
      defs - symbol - linearGradient - radialGradient - clipPath -
      title - desc - metadata - style - script {
        # Collected or deliberately ignored, but never drawn where they stand.
      }
      use {
        my SvgUse $node $style
      }
      path {
        my SvgPaint [::tclpdf::svgPath operators \
            [::tclpdf::xml attribute $node d] $::tclpdf::svg::identity] $style
      }
      rect - circle - ellipse - line - polyline - polygon {
        my SvgPaint [my SvgShape $name $node] $style
      }
      text - tspan {
        my SvgText $node $style
      }
      default {
        set skipped [my state svgSkipped]
        dict incr skipped $name
        my state svgSkipped $skipped
      }
    }

    if {$transform ne {}} {
      my SvgRestore
      my state svgTransform $outerTransform
    }
    return
  }

  # The basic shapes, as path operators - so they go through exactly the same
  # painting code as <path> and cannot drift from it.
  method SvgShape {name node} {
    set N ::tclpdf::pdfObj
    switch -- $name {
      rect {
        set x [my SvgLength [::tclpdf::xml attribute $node x] 0]
        set y [my SvgLength [::tclpdf::xml attribute $node y] 0]
        set width [my SvgLength [::tclpdf::xml attribute $node width] 0]
        set height [my SvgLength [::tclpdf::xml attribute $node height] 0]
        set rx [my SvgLength [::tclpdf::xml attribute $node rx] 0]
        if {$rx <= 0} {
          return "$x $y [$N num [expr {$width}]]\
              [$N num [expr {$height}]] re\n"
        }
        # A rounded rectangle as four arcs, written as path data so the arc
        # code is not duplicated here.
        set data "M[expr {$x + $rx}],$y H[expr {$x + $width - $rx}]\
            A$rx,$rx 0 0 1 [expr {$x + $width}],[expr {$y + $rx}]\
            V[expr {$y + $height - $rx}]\
            A$rx,$rx 0 0 1 [expr {$x + $width - $rx}],[expr {$y + $height}]\
            H[expr {$x + $rx}]\
            A$rx,$rx 0 0 1 $x,[expr {$y + $height - $rx}] V[expr {$y + $rx}]\
            A$rx,$rx 0 0 1 [expr {$x + $rx}],$y Z"
        return [::tclpdf::svgPath operators $data $::tclpdf::svg::identity]
      }
      circle - ellipse {
        set cx [my SvgLength [::tclpdf::xml attribute $node cx] 0]
        set cy [my SvgLength [::tclpdf::xml attribute $node cy] 0]
        if {$name eq "circle"} {
          set rx [my SvgLength [::tclpdf::xml attribute $node r] 0]
          set ry $rx
        } else {
          set rx [my SvgLength [::tclpdf::xml attribute $node rx] 0]
          set ry [my SvgLength [::tclpdf::xml attribute $node ry] 0]
        }
        set data "M[expr {$cx - $rx}],$cy A$rx,$ry 0 1 0 [expr {$cx + $rx}],$cy\
            A$rx,$ry 0 1 0 [expr {$cx - $rx}],$cy Z"
        return [::tclpdf::svgPath operators $data $::tclpdf::svg::identity]
      }
      line {
        return "[list [my SvgLength [::tclpdf::xml attribute $node x1] 0] \
            [my SvgLength [::tclpdf::xml attribute $node y1] 0]] m\n[list \
            [my SvgLength [::tclpdf::xml attribute $node x2] 0] \
            [my SvgLength [::tclpdf::xml attribute $node y2] 0]] l\n"
      }
      polyline - polygon {
        set numbers [regexp -all -inline {[-+0-9.eE]+} \
            [::tclpdf::xml attribute $node points]]
        set result {}
        set operator m
        foreach {x y} $numbers {
          append result "$x $y $operator\n"
          set operator l
        }
        if {$name eq "polygon"} {
          append result "h\n"
        }
        return $result
      }
    }
    return {}
  }

  # A <use> draws whatever its href points at, at an offset.
  method SvgUse {node style} {
    set reference [::tclpdf::xml attribute $node href]
    if {$reference eq {}} {
      set reference [::tclpdf::xml attribute $node xlink:href]
    }
    set id [string trimleft $reference #]
    set defs [my state svgDefs]
    if {$id eq {} || ![dict exists $defs $id]} {
      return
    }
    set x [my SvgLength [::tclpdf::xml attribute $node x] 0]
    set y [my SvgLength [::tclpdf::xml attribute $node y] 0]
    set target [dict get $defs $id]
    my SvgSave
    if {$x != 0 || $y != 0} {
      my content "1 0 0 1 [::tclpdf::pdfObj num $x] [::tclpdf::pdfObj num $y] cm\n"
    }
    # A <symbol> is not drawn where it stands but IS drawn through a use -
    # so its children are taken directly rather than going through the
    # element switch, which would skip it again.
    if {[string map {svg: {}} [::tclpdf::xml name $target]] eq "symbol"} {
      foreach child [::tclpdf::xml children $target] {
        my SvgElement $child $style
      }
    } else {
      my SvgElement $target $style
    }
    my SvgRestore
    return
  }

  # Text inside a drawing.
  #
  # The enclosing matrix flips y so that SVG coordinates work; glyphs drawn
  # through it would come out mirrored. So the text is wrapped in a second
  # flip about its own baseline - two wrongs that are exactly one right, and
  # cheaper than keeping a second unflipped coordinate system around.
  method SvgText {node style} {
    set text [string trim [::tclpdf::xml text $node]]
    foreach child [::tclpdf::xml children $node] {
      if {[string map {svg: {}} [::tclpdf::xml name $child]] eq "tspan"} {
        append text [string trim [::tclpdf::xml text $child]]
      }
    }
    if {$text eq {}} {
      return
    }
    set x [my SvgLength [::tclpdf::xml attribute $node x] 0]
    set y [my SvgLength [::tclpdf::xml attribute $node y] 0]
    set size [my SvgLength [dict get $style font-size] 12]
    if {$size <= 0} {
      set size 12
    }

    # font-family is a comma-separated wish list; the first name that resolves
    # wins, and helvetica catches the rest. A drawing must not fail because it
    # asks for a face nobody has.
    #
    # An EMBEDDED face resolves under its alias, so font-family="Roboto" finds
    # it after [font embed Roboto]. That used to be the worst way to write it:
    # an unknown name fell back quietly, and the KNOWN one aborted the drawing
    # a few lines further down, where the AFM path met a face it had no
    # metrics for.
    set family helvetica
    foreach candidate [split [dict get $style font-family] ,] {
      set candidate [string trim $candidate "\"' "]
      if {$candidate eq {}} {
        continue
      }
      if {![catch {my TextResolve $candidate {}}]} {
        set family $candidate
        break
      }
    }
    # -style is emptied deliberately: the document may currently be set to
    # bold, and a drawing must not inherit that - SVG says what it wants
    # through font-family, and font-weight is not read here.
    #
    # Everything after this goes through the same text state a [text] call
    # builds, which is what gives a drawing the embedded path: the same
    # measurement, the same resource, the same kerning and ligatures as the
    # running text around it.
    # Like every other text command: a drawing may be the first thing in the
    # document that sets a letter, and until now it was the one that never
    # needed the state.
    my TextInit
    set state [my TextMerge [list -family $family -style {} -size $size]]
    set font [dict get $state resolved]
    # Measured BEFORE the face is registered, and that order is deliberate.
    # Measuring is what refuses a character the face cannot set, and a
    # registered resource outlives the failed drawing: a caught error left
    # Helvetica in the document, which is enough to make [pdfa] refuse to
    # write it. An attempt that came to nothing must leave nothing behind.
    set width [lindex [my TextPoints $state $text] 0]
    set resource [my TextResource $font]
    switch -- [dict get $style text-anchor] {
      middle {set x [expr {$x - $width / 2.0}]}
      end {set x [expr {$x - $width}]}
    }

    set fill [dict get $style fill]
    if {$fill eq {} || $fill eq "none"} {
      set fill black
    }
    my content "q 1 0 0 -1 0 [::tclpdf::pdfObj num [expr {2.0 * $y}]] cm\n"
    my content "[::tclpdf::color operator [::tclpdf::color parse [my GraphicsColour $fill svg]] fill]\n"
    # [TextResource] already returns PDF name syntax - running it through
    # [name] again escapes the slash into #2F, and the reader then looks for a
    # font whose name begins with a slash.
    my content "BT $resource [::tclpdf::pdfObj num $size] Tf\n"
    my content "1 0 0 1 [::tclpdf::pdfObj num $x] [::tclpdf::pdfObj num $y] Tm\n"
    my content [my TextShow $font $state $text 0]
    my content "ET\nQ\n"
    return
  }

  # The box enclosing a set of path operators, in drawing coordinates. Needed
  # for a gradient in objectBoundingBox units, which is the default - and the
  # operators are the only description of the shape available here.
}

package provide tclpdf::svgElement 1.1
