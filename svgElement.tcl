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
      # otherwise be placed as if the group were at the origin. A
      # transparency group being captured needs it a third time, relative to
      # the group's own space, for the BBox - that is SvgGroupShift.
      set matrix [my SvgTransform $transform]
      set outerTransform [my state svgTransform]
      my state svgTransform [::tclpdf::geometry multiply $matrix $outerTransform]
      set outerRelative [my SvgGroupShift $matrix]
      my SvgSave
      my content "[join [lmap number $matrix {
        ::tclpdf::pdfObj num $number
      }] { }] cm\n"
    }

    switch -- $name {
      svg - g - a - switch {
        # A container whose own opacity is below one is not multiplied down
        # (SVG 14.5 allows that only as an approximation) but rendered as a
        # transparency group: the children composite among themselves first,
        # and the group's alpha applies once to the result - so overlapping
        # children come out no darker than a single one.
        if {[my SvgGroupWanted $style]} {
          my SvgGroup $node [my SvgGroupStyle $style $inheritedStyle] \
              [dict get $style ownOpacity]
        } else {
          foreach child [::tclpdf::xml children $node] {
            my SvgElement $child $style
          }
        }
      }
      defs - symbol - linearGradient - radialGradient - clipPath -
      title - desc - metadata - style - script {
        # Collected or deliberately ignored, but never drawn where they stand.
      }
      use {
        # A <use> renders its target as a group of its own (SVG 5.6), so its
        # opacity is a group opacity like a <g>'s.
        if {[my SvgGroupWanted $style]} {
          my SvgGroup $node [my SvgGroupStyle $style $inheritedStyle] \
              [dict get $style ownOpacity]
        } else {
          my SvgUse $node $style
        }
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
      my SvgGroupUnshift $outerRelative
    }
    return
  }

  # -- transparency groups ------------------------------------------------
  #
  # A group element with opacity below one, rendered exactly: the children
  # are captured into a form XObject with /Group << /S /Transparency >> -
  # the same canvas redirection [form create] uses - and the form is painted
  # once through an ExtGState carrying the group's alpha. Without the group
  # the alpha applies to every child separately, and where two children
  # overlap the upper one composites over the lower AGAIN: measured with
  # pdftoppm, two red circles in a group at 0.5 came out (255 63 63) in the
  # overlap against (255 127 127) for a single circle, and identical with
  # the group.

  # Does this element get one? Only when its own factor is below one, and
  # only on a version that has transparency (1.4) - on an older version the
  # factor stays multiplied down, and the gs it would need is refused with
  # the version in the message, as every alpha is.
  method SvgGroupWanted {style} {
    return [expr {[dict get $style ownOpacity] < 1 &&
        [package vcompare [[my writer] version] 1.4] >= 0}]
  }

  # The style the children draw with: the inherited product WITHOUT the
  # element's own factor - that one is applied once, to the finished group.
  method SvgGroupStyle {style inheritedStyle} {
    set product 1
    if {[dict exists $inheritedStyle opacity] &&
        [string is double -strict [dict get $inheritedStyle opacity]]} {
      set product [dict get $inheritedStyle opacity]
    }
    dict set style opacity $product
    return $style
  }

  method SvgGroup {node style alpha} {
    # The capture: a bounds record for the BBox, and the canvas redirection
    # from the core - every drawing method keeps working, only the bytes
    # land in the form instead of the page.
    set stack [my state svgGroupStack]
    lappend stack [dict create rel [::tclpdf::geometry identity] bounds {}]
    my state svgGroupStack $stack
    set depth [my state svgDepth]
    lassign [my state svgBox] -> -> boxWidth boxHeight
    my canvas push $boxWidth $boxHeight
    # An error while the children draw - a face refusal is the usual one -
    # must not leave the capture standing: the canvas holds brackets the
    # page never saw, and the unwinding in SvgRoot would close them on the
    # page. The content is discarded, the counters put back, the error
    # passed on unchanged.
    if {[set failed [catch {
      if {[string map {svg: {}} [::tclpdf::xml name $node]] eq "use"} {
        my SvgUse $node $style
      } else {
        foreach child [::tclpdf::xml children $node] {
          my SvgElement $child $style
        }
      }
    } result options0]]} {
      my canvas pop
      my state svgDepth $depth
      my state svgGroupStack [lrange [my state svgGroupStack] 0 end-1]
      return -options $options0 $result
    }
    set content [my canvas pop]
    set stack [my state svgGroupStack]
    set bounds [dict get [lindex $stack end] bounds]
    my state svgGroupStack [lrange $stack 0 end-1]
    # Nothing drawn, nothing to fade: a group of skipped elements ends here,
    # and no empty XObject is written.
    if {$bounds eq {}} {
      return
    }
    # The group's extent counts for an ENCLOSING capture too - the bounds
    # are in this element's local space, which is what the parent's relative
    # matrix maps.
    my SvgGroupBox {*}$bounds
    # No /CS in the group, for the same measured reason as in [FormCreate]:
    # naming a colour space is a claim PDF/A checks against the output
    # intent (ISO 19005-2, 6.2.4.3), and without one the group composites in
    # the parent's space under every intent. Isolated, so the children
    # composite against a transparent backdrop rather than the page - that
    # is what makes the alpha apply to the group ONCE.
    set pairs [list Type /XObject Subtype /Form FormType 1 \
        BBox [::tclpdf::pdfObj arr [lmap value $bounds {::tclpdf::pdfObj num $value}]] \
        Group [::tclpdf::pdfObj dictionary {S /Transparency I true}] \
        Resources [[my writer] ref [my reservation output.resources]]]
    # An own sequence, like the gradients': the form counter lives with
    # [form create], and a drawing must not depend on that module.
    set sequence [my state svgGroupSeq]
    if {$sequence eq {}} {
      set sequence 0
    }
    my state svgGroupSeq [incr sequence]
    set resourceName svgGroup$sequence
    my resource XObject $resourceName \
        [[my writer] ref [my streamObject $pairs $content]]
    my SvgSave
    my content "[::tclpdf::pdfObj name [my GraphicsOpacity $alpha both]] gs\n"
    my content "[::tclpdf::pdfObj name $resourceName] Do\n"
    my SvgRestore
    return
  }

  # Union a box in the current local coordinates into the innermost open
  # capture, mapped through its relative matrix. Quiet when none is open.
  method SvgGroupBox {x0 y0 x1 y1} {
    set stack [my state svgGroupStack]
    if {![llength $stack]} {
      return
    }
    set entry [lindex $stack end]
    set relative [dict get $entry rel]
    set bounds [dict get $entry bounds]
    # All four corners: a rotation turns an edge into a diagonal, and two
    # corners alone would cut the box short.
    foreach {x y} [list $x0 $y0 $x1 $y0 $x0 $y1 $x1 $y1] {
      lassign [::tclpdf::geometry apply $relative $x $y] mappedX mappedY
      if {$bounds eq {}} {
        set bounds [list $mappedX $mappedY $mappedX $mappedY]
        continue
      }
      lassign $bounds minX minY maxX maxY
      set bounds [list [expr {min($minX, $mappedX)}] [expr {min($minY, $mappedY)}] \
          [expr {max($maxX, $mappedX)}] [expr {max($maxY, $mappedY)}]]
    }
    dict set entry bounds $bounds
    lset stack end $entry
    my state svgGroupStack $stack
    return
  }

  # A transformation entered below the innermost capture: the relative
  # matrix follows it, exactly as svgTransform follows it for the page.
  # Returns what SvgGroupUnshift needs to put back - the empty string when
  # no capture is open, and putting that back is a no-op.
  method SvgGroupShift {matrix} {
    set stack [my state svgGroupStack]
    if {![llength $stack]} {
      return {}
    }
    set entry [lindex $stack end]
    set outer [dict get $entry rel]
    dict set entry rel [::tclpdf::geometry multiply $matrix $outer]
    lset stack end $entry
    my state svgGroupStack $stack
    return $outer
  }

  method SvgGroupUnshift {outer} {
    if {$outer eq {}} {
      return
    }
    set stack [my state svgGroupStack]
    set entry [lindex $stack end]
    dict set entry rel $outer
    lset stack end $entry
    my state svgGroupStack $stack
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
    set outerRelative {}
    if {$x != 0 || $y != 0} {
      my content "1 0 0 1 [::tclpdf::pdfObj num $x] [::tclpdf::pdfObj num $y] cm\n"
      # The offset moves the target's coordinates like any transform, so a
      # capture's relative matrix has to follow it too.
      set outerRelative [my SvgGroupShift [::tclpdf::geometry translate $x $y]]
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
    my SvgGroupUnshift $outerRelative
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
    # For a transparency group's BBox: one full size above and below the
    # baseline is generous for any face - a BBox clips, so the safe side is
    # the large one.
    if {[llength [my state svgGroupStack]]} {
      my SvgGroupBox $x [expr {$y - $size}] [expr {$x + $width}] [expr {$y + $size}]
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

package provide tclpdf::svgElement 1.3
