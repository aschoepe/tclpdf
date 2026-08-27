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

# The elements this module has a case for - the same names its switch takes,
# in one place because [SvgCountOnly] has to know them too and a second copy
# would be a second answer. What is NOT here is what [svg info] reports as
# skipped, wherever it stands.
namespace eval ::tclpdf::svgElement {
  variable drawable {
    svg g a switch defs symbol linearGradient radialGradient clipPath mask
    stop title desc metadata style script use path rect circle ellipse line
    polyline polygon text tspan
  }
}

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

  # The element a url(#id) or an href points at, or the empty string when
  # nothing in the drawing carries that id.
  #
  # The lookup sits next to the walk that gathered them, and it sits here ONCE
  # because five roads asked the same three lines - the gradient, the three
  # clip and mask readers and <use> - and a dangling reference has to come
  # back the same way to all of them. Safe wherever it is called from: every
  # caller runs during a drawing, and [SvgRoot] fills the state by calling
  # [SvgCollect] above before the first element is drawn.
  method SvgDefinition {id} {
    set defs [my state svgDefs]
    if {$id eq {} || ![dict exists $defs $id]} {
      return {}
    }
    return [dict get $defs $id]
  }

  # Draw one element and its children, carrying the inherited properties down.
  method SvgElement {node inheritedStyle} {
    set style [my SvgStyle $node $inheritedStyle]
    set name [string map {svg: {}} [::tclpdf::xml name $node]]

    # display, read from the STYLE and not from the attribute. SVG 1.1, 6.4
    # makes a declaration in style="" beat the presentation attribute, and
    # 11.5 makes display:none mean the element and its children are not
    # rendered at all. Asking the attribute alone made style="display:none"
    # inert - measured 2026-08-27, and the header of svg.tcl claimed the
    # opposite. Not inherited: [SvgStyle] clears the slot per element.
    if {[string trim [dict get $style display]] eq "none"} {
      return
    }
    # em and ex are resolved against the font size in force (CSS 2.1, 4.3.2),
    # so the walk carries it: pushed here, put back where the transform is.
    set outerFontSize [my state svgFontSize]
    my state svgFontSize [my SvgFontSizeOf $style $outerFontSize]
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

    # What limits the element's visibility, opened AFTER its own transform:
    # a transform establishes a new user space for the element and its
    # descendants (SVG 1.1, 7.4), and clipPathUnits="userSpaceOnUse" names
    # "the user coordinate system in place when the clipPath is referenced"
    # (14.3.5) - which is that new one. Opened before the switch so that a
    # container clips its children as one, and closed after it.
    set clipDepth [my SvgClipEnter $node]

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
          my SvgContainer $name $node $style
        }
      }
      defs - symbol - linearGradient - radialGradient - clipPath - mask -
      title - desc - metadata - style - script {
        # Collected or deliberately ignored, but never drawn where they stand.
        #
        # A <defs> is still WALKED, and that is the fix of 2026-08-24 rather
        # than a change of mind about drawing it. Everything inside it was
        # invisible to the count as well as to the page: a real logo out of
        # the corpus carries two <filter>s, a <mask> and a <clipPath> in its
        # <defs>, and [svg info] answered "image 1" - the one skipped element
        # that happened to stand outside. A caller asking what was left out
        # got a truthful-looking answer that was missing the three things
        # that would have changed the picture.
        if {$name eq "defs"} {
          my SvgCountOnly $node
        }
        # A <style> BLOCK IS AN OMISSION and is counted as one. It stands in
        # the drawable list because the element switch has a case for it, and
        # that made [SvgCountOnly] pass it over as well - so a drawing whose
        # shapes take their colour from a class came out in the initial
        # colour and [svg info] was empty (measured 2026-08-27: black instead
        # of green, without a word). CSS in a <style> block is not built;
        # that it is not built is now visible.
        if {$name eq "style" && [string trim [::tclpdf::xml text $node]] ne {}} {
          my SvgSkipped style
        }
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
        # A path that stops at its first error is drawn as far as it goes
        # (SVG 8.3.9) and the loss is counted - an omission with no other
        # trace is the one thing this module does not allow itself.
        set operators [::tclpdf::svgPath operators \
            [::tclpdf::xml attribute $node d] $::tclpdf::svg::identity problem]
        if {$problem ne {}} {
          my SvgSkipped path-error
        }
        my SvgPaint $operators $style
      }
      rect - circle - ellipse - line - polyline - polygon {
        my SvgPaint [my SvgShape $name $node] $style
      }
      text - tspan {
        my SvgText $node $style
      }
      default {
        my SvgSkipped $name
      }
    }

    for {set bracket 0} {$bracket < $clipDepth} {incr bracket} {
      my SvgRestore
    }

    if {$transform ne {}} {
      my SvgRestore
      my state svgTransform $outerTransform
      my SvgGroupUnshift $outerRelative
    }
    my state svgFontSize $outerFontSize
    return
  }

  # The font size an em below this element means. font-size is itself a
  # length and may be written in em or per cent, both relative to the
  # ENCLOSING size (CSS 2.1, 15.7) - so the outer value is the reference and
  # is put back in place around the call.
  method SvgFontSizeOf {style outer} {
    set value [string trim [dict get $style font-size]]
    if {$value eq {} || $value eq "inherit"} {
      return $outer
    }
    set saved [my state svgFontSize]
    my state svgFontSize $outer
    try {
      if {[string match {*%} $value]} {
        set number [string trimright $value %]
        set size [expr {[::tclpdf::option finite $number]
            ? $number / 100.0 * $outer : $outer}]
      } else {
        set size [my SvgLength $value $outer d]
      }
    } finally {
      my state svgFontSize $saved
    }
    if {![::tclpdf::option finite $size] || $size <= 0} {
      return $outer
    }
    return $size
  }

  # The children of a container, or - for a <switch> - the FIRST child whose
  # conditions hold.
  #
  # SVG 1.1, 5.8: a <switch> "evaluates the requiredFeatures,
  # requiredExtensions and systemLanguage attributes on its direct child
  # elements ... the first direct child element whose attributes evaluate to
  # true is rendered ... the others are bypassed and therefore not rendered".
  # Drawn like a <g> - which is what happened until 2026-08-27 - a
  # multilingual label came out in every language at once, one on top of the
  # other, and nothing said so.
  #
  # A nested <svg> is a VIEWPORT of its own (7.2) and goes through
  # [SvgViewport]; the drawing's outermost one is not, because SvgRoot's
  # matrix already is that viewport.
  method SvgContainer {name node style} {
    if {$name eq "svg"} {
      if {[my state svgAtRoot]} {
        my state svgAtRoot 0
      } else {
        my SvgViewport $node $node $style
        return
      }
    }
    if {$name eq "switch"} {
      foreach child [::tclpdf::xml children $node] {
        if {[my SvgConditions $child]} {
          my SvgElement $child $style
          return
        }
      }
      return
    }
    foreach child [::tclpdf::xml children $node] {
      my SvgElement $child $style
    }
    return
  }

  # Whether the three conditional attributes of an element all hold (5.8.3
  # to 5.8.5). An attribute that is absent, or an empty string, is true; an
  # attribute this package cannot evaluate is FALSE, because the point of the
  # switch is that the alternative gets its turn.
  method SvgConditions {node} {
    # No extension and no feature string is claimed. An empty value is true
    # by the norm's own wording; anything named is not available here.
    foreach attribute {requiredExtensions requiredFeatures} {
      set value [::tclpdf::xml attribute $node $attribute]
      if {[::tclpdf::xml attribute $node $attribute x] ne "x" &&
          [string trim $value] ne {}} {
        return 0
      }
    }
    set languages [::tclpdf::xml attribute $node systemLanguage x]
    if {$languages eq "x"} {
      return 1
    }
    if {[string trim $languages] eq {}} {
      return 0
    }
    # 5.8.5: true if one of the comma-separated tags equals the user's
    # language or is a prefix of it followed by "-". The document's own
    # language is the closest this package has to a user preference; without
    # one, English - which is what the drawings in the corpus fall back to.
    set wanted [string tolower [my language]]
    if {$wanted eq {}} {
      set wanted en
    }
    foreach tag [split $languages ,] {
      set tag [string tolower [string trim $tag]]
      if {$tag eq {}} {
        continue
      }
      if {$tag eq $wanted || [string match "$tag-*" $wanted] ||
          [string match "$wanted-*" $tag]} {
        return 1
      }
    }
    return 0
  }

  # A nested viewport: a <svg> below the root, or a <symbol> reached through
  # a <use> (SVG 1.1, 7.2, 7.7 and 5.6).
  #
  # Both establish a new viewport, and both were drawn as if they were a <g>
  # - so a 50x50 window with its own viewBox came out at full size, and a
  # symbol whose viewBox says 10 units came out ten units wide instead of the
  # 80 the <use> asked for: a sixty-fourth of the area (measured 2026-08-27).
  # "viewport" carries x/y/width/height, "content" the viewBox and the
  # preserveAspectRatio - for a <symbol> the two are different elements.
  #
  # overflow is hidden by default for both (14.3.3), so the viewport clips.
  method SvgViewport {viewport content style {width {}} {height {}}} {
    set x [my SvgLength [::tclpdf::xml attribute $viewport x] 0 x]
    set y [my SvgLength [::tclpdf::xml attribute $viewport y] 0 y]
    if {$width eq {}} {
      set width [my SvgLength [::tclpdf::xml attribute $viewport width] {} x]
    }
    if {$height eq {}} {
      set height [my SvgLength [::tclpdf::xml attribute $viewport height] {} y]
    }
    lassign [my state svgViewport] outerWidth outerHeight
    if {$width eq {}} {
      set width $outerWidth
    }
    if {$height eq {}} {
      set height $outerHeight
    }
    # 7.7 again: a zero extent disables rendering, a negative one is an error.
    if {![string is double -strict $width] || ![string is double -strict $height] ||
        $width <= 0 || $height <= 0} {
      if {[string is double -strict $width] && [string is double -strict $height] &&
          ($width < 0 || $height < 0)} {
        my SvgSkipped viewport
      }
      return
    }
    lassign [my SvgViewBox $content] boxX boxY boxWidth boxHeight
    if {![string is double -strict $boxWidth] ||
        ![string is double -strict $boxHeight]} {
      return
    }
    if {$boxWidth <= 0 || $boxHeight <= 0} {
      # No viewBox of its own: the child coordinates ARE the viewport's, and
      # only the offset applies.
      if {[::tclpdf::xml attribute $content viewBox] ne {}} {
        return
      }
      lassign [list 0 0 $width $height] boxX boxY boxWidth boxHeight
    }
    lassign [my SvgAspect $content [dict create fitMode {} given {}]] \
        align meetOrSlice
    set fullX [expr {$width / double($boxWidth)}]
    set fullY [expr {$height / double($boxHeight)}]
    if {$align eq "none"} {
      set scaleX $fullX
      set scaleY $fullY
    } else {
      set scaleX [expr {$meetOrSlice eq "slice" ? max($fullX, $fullY)
          : min($fullX, $fullY)}]
      set scaleY $scaleX
    }
    lassign [my SvgAspectShare $align] shareX shareY
    set offsetX [expr {$x + ($width - $boxWidth * $scaleX) * $shareX}]
    set offsetY [expr {$y + ($height - $boxHeight * $scaleY) * $shareY}]
    set matrix [::tclpdf::geometry multiply \
        [::tclpdf::geometry translate [expr {-$boxX}] [expr {-$boxY}]] \
        [list $scaleX 0 0 $scaleY $offsetX $offsetY]]
    my SvgSave
    my content "[::tclpdf::pdfObj num $x] [::tclpdf::pdfObj num $y]\
        [::tclpdf::pdfObj num $width] [::tclpdf::pdfObj num $height] re W n\n"
    my content "[join [lmap number $matrix {::tclpdf::pdfObj num $number}] { }] cm\n"
    set outerTransform [my state svgTransform]
    my state svgTransform [::tclpdf::geometry multiply $matrix $outerTransform]
    set outerRelative [my SvgGroupShift $matrix]
    set outerViewport [my state svgViewport]
    my state svgViewport [list $boxWidth $boxHeight]
    try {
      foreach child [::tclpdf::xml children $content] {
        my SvgElement $child $style
      }
    } finally {
      my state svgViewport $outerViewport
      my state svgTransform $outerTransform
      my SvgGroupUnshift $outerRelative
      my SvgRestore
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

  # [SvgSkipped] - the one place that touches the tally - moved to svg.tcl on
  # 2026-08-27, because [SvgAspect] calls it before anything has loaded this
  # module. See there.

  # Walk a subtree WITHOUT drawing it, counting what this package would not
  # have drawn anyway. Everything under <defs> is reached by reference or not
  # at all, so nothing here paints; the point is the tally, which is what
  # [svg info] answers and what a caller checks before trusting a drawing.
  #
  # The elements this package DOES understand are not counted - a gradient in
  # <defs> is used through url(#...) and is no omission. What is counted is
  # what would have been counted anywhere else.
  method SvgCountOnly {node} {
    foreach child [::tclpdf::xml children $node] {
      set name [lindex [split [::tclpdf::xml name $child] :] end]
      # Only what this package would not have drawn WHEREVER it stood. A <g>
      # or a <path> under <defs> is reached through <use> or through the mask
      # that owns it, and counting those as omissions would bury the two
      # entries that matter under the shapes they are made of - measured on a
      # real logo, "filter 2 mask 1" came with "g 3 path 1" beside it and read
      # as if four different things had gone wrong.
      if {$name ni $::tclpdf::svgElement::drawable} {
        my SvgSkipped $name
      }
      my SvgCountOnly $child
    }
  }

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

  # Draw something into a form XObject instead of onto the page, and answer
  # the bytes together with the bounds they touched.
  #
  # Two callers need exactly this and no more - a transparency group and the
  # luminosity mask in svgClip.tcl - and the bookkeeping is the part that
  # must not drift between them: a bounds record pushed, the canvas
  # redirected, and BOTH put back even when the drawing raises. An error
  # while the children draw - a face refusal is the usual one - must not
  # leave the capture standing: the canvas holds brackets the page never
  # saw, and the unwinding in SvgRoot would close them on the page. The
  # content is discarded, the counters put back, the error passed on
  # unchanged.
  method SvgCapture {body} {
    set stack [my state svgGroupStack]
    lappend stack [dict create rel [::tclpdf::geometry identity] bounds {}]
    my state svgGroupStack $stack
    set depth [my state svgDepth]
    lassign [my state svgBox] -> -> boxWidth boxHeight
    my canvas push $boxWidth $boxHeight
    if {[catch {uplevel 1 $body} result options0]} {
      my canvas pop
      my state svgDepth $depth
      my state svgGroupStack [lrange [my state svgGroupStack] 0 end-1]
      return -options $options0 $result
    }
    set content [my canvas pop]
    set stack [my state svgGroupStack]
    set bounds [dict get [lindex $stack end] bounds]
    my state svgGroupStack [lrange $stack 0 end-1]
    return [list $content $bounds]
  }

  method SvgGroup {node style alpha} {
    lassign [my SvgCapture {
      if {[string map {svg: {}} [::tclpdf::xml name $node]] eq "use"} {
        my SvgUse $node $style
      } else {
        foreach child [::tclpdf::xml children $node] {
          my SvgElement $child $style
        }
      }
    }] content bounds
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
        set x [my SvgLength [::tclpdf::xml attribute $node x] 0 x]
        set y [my SvgLength [::tclpdf::xml attribute $node y] 0 y]
        set width [my SvgLength [::tclpdf::xml attribute $node width] 0 x]
        set height [my SvgLength [::tclpdf::xml attribute $node height] 0 y]
        # THE TWO KINDS OF BAD NUMBER THE NORM DISTINGUISHES (SVG 1.1, 9.2):
        # a negative width or height "is an error", a zero one "disables
        # rendering of the element". The error is reported and the element
        # left out - the rule this package follows wherever it cannot honour
        # what it was handed: nothing silently wrong, and [svg info] names
        # it. Written through, width="-20" became an "re" with a negative
        # operand and the rectangle grew the other way, which no reader
        # complains about. A zero is not an omission but the norm's own
        # answer, so it is not counted.
        if {$width < 0 || $height < 0} {
          my SvgSkipped rect-size
          return {}
        }
        if {$width == 0 || $height == 0} {
          return {}
        }
        # THE TWO RADII STAND IN FOR EACH OTHER (9.2): given one, the other
        # takes its value - which is what makes <rect ry="10"> round at all
        # instead of coming out square. Read as ABSENT rather than as zero,
        # because the norm makes "no rx" and rx="0" two different things.
        set rx [my SvgLength [::tclpdf::xml attribute $node rx] {} x]
        set ry [my SvgLength [::tclpdf::xml attribute $node ry] {} y]
        if {$rx eq {}} {
          set rx $ry
        } elseif {$ry eq {}} {
          set ry $rx
        }
        if {$rx ne {} && ($rx < 0 || $ry < 0)} {
          my SvgSkipped rect-radius
          return {}
        }
        # A zero radius disables the rounding, not the element.
        if {$rx eq {} || $rx == 0 || $ry == 0} {
          return "$x $y [$N num [expr {$width}]]\
              [$N num [expr {$height}]] re\n"
        }
        # AND EACH IS CAPPED AT HALF ITS SIDE (9.2). Uncapped, rx="40" on a
        # rectangle 20 wide put path points at x = -10 and x = 50 - outside
        # the shape they were supposed to round; and since svgClip.tcl draws
        # its clipping shapes through this same method, the clipping region
        # walked out of the rectangle with them.
        if {$rx > $width / 2.0} {
          set rx [expr {$width / 2.0}]
        }
        if {$ry > $height / 2.0} {
          set ry [expr {$height / 2.0}]
        }
        # A rounded rectangle as four arcs, written as path data so the arc
        # code is not duplicated here.
        set data "M[expr {$x + $rx}],$y H[expr {$x + $width - $rx}]\
            A$rx,$ry 0 0 1 [expr {$x + $width}],[expr {$y + $ry}]\
            V[expr {$y + $height - $ry}]\
            A$rx,$ry 0 0 1 [expr {$x + $width - $rx}],[expr {$y + $height}]\
            H[expr {$x + $rx}]\
            A$rx,$ry 0 0 1 $x,[expr {$y + $height - $ry}] V[expr {$y + $ry}]\
            A$rx,$ry 0 0 1 [expr {$x + $rx}],$y Z"
        return [::tclpdf::svgPath operators $data $::tclpdf::svg::identity]
      }
      circle - ellipse {
        set cx [my SvgLength [::tclpdf::xml attribute $node cx] 0 x]
        set cy [my SvgLength [::tclpdf::xml attribute $node cy] 0 y]
        if {$name eq "circle"} {
          set rx [my SvgLength [::tclpdf::xml attribute $node r] 0 d]
          set ry $rx
        } else {
          set rx [my SvgLength [::tclpdf::xml attribute $node rx] 0 x]
          set ry [my SvgLength [::tclpdf::xml attribute $node ry] 0 y]
        }
        # The same two rules as the rectangle, one section further on (9.3
        # and 9.4): a negative radius is an error, a zero radius "disables
        # rendering of the element". r="-20" used to come out as a circle of
        # radius 20 - a shape the file never asked for - and r="0" as a path
        # of three points on top of each other, which every reader draws as
        # nothing and none of them mentions.
        if {$rx < 0 || $ry < 0} {
          my SvgSkipped "$name-radius"
          return {}
        }
        if {$rx == 0 || $ry == 0} {
          return {}
        }
        set data "M[expr {$cx - $rx}],$cy A$rx,$ry 0 1 0 [expr {$cx + $rx}],$cy\
            A$rx,$ry 0 1 0 [expr {$cx - $rx}],$cy Z"
        return [::tclpdf::svgPath operators $data $::tclpdf::svg::identity]
      }
      line {
        return "[list [my SvgLength [::tclpdf::xml attribute $node x1] 0 x] \
            [my SvgLength [::tclpdf::xml attribute $node y1] 0 y]] m\n[list \
            [my SvgLength [::tclpdf::xml attribute $node x2] 0 x] \
            [my SvgLength [::tclpdf::xml attribute $node y2] 0 y]] l\n"
      }
      polyline - polygon {
        set numbers [regexp -all -inline \
            {[-+]?(?:[0-9]*\.[0-9]+|[0-9]+\.?)(?:[eE][-+]?[0-9]+)?} \
            [::tclpdf::xml attribute $node points]]
        # AN ODD NUMBER OF COORDINATES IS AN ERROR, and SVG 1.1, 9.6/9.7 say
        # what to do with it: "the element is in error ... the document shall
        # be rendered up to, but not including, the last properly specified
        # point". Written through, [foreach {x y}] left $y EMPTY and the
        # stream got "50  l" - an operator with one operand, which ISO
        # 32000-2, 7.8.2 does not allow, which poppler reports as "Too few
        # (1) args to 'l' operator" and which qpdf --check does not see at
        # all. A reader that leaves the operand on the stack shifts
        # everything after it.
        if {[llength $numbers] % 2} {
          set numbers [lrange $numbers 0 end-1]
          my SvgSkipped points
        }
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
  #
  # THREE GUARDS, and all three are about availability rather than about the
  # standard (which only says, in 5.6, that a cycle is an error). A use that
  # reaches itself used to end in "restore without a save" - a message about
  # this package's own bookkeeping, naming neither the use nor the cycle -
  # and a mask that masked itself in Tcl's "too many nested evaluations" with
  # no TCLPDF code at all. And the unfolding is EXPONENTIAL: measured
  # 2026-08-27, ten levels of ten copies took 0.63 s, thirteen took 6.8 s,
  # and the twenty-level file of 2314 bytes would have been a quarter of an
  # hour and ten million rectangles. The cycle itself is caught before the
  # drawing starts ([SvgCheck] in svg.tcl); what is left here is the depth,
  # the total, and a belt for the case a cycle is built out of nodes the
  # check could not follow.
  method SvgUse {node style} {
    set reference [::tclpdf::xml attribute $node href]
    if {$reference eq {}} {
      set reference [::tclpdf::xml attribute $node xlink:href]
    }
    set id [string trimleft [string trim $reference] #]
    set target [my SvgDefinition $id]
    if {$target eq {}} {
      return
    }
    set stack [my state svgUseStack]
    if {$id ne {} && $id in $stack} {
      my SvgSkipped use-cycle
      return
    }
    if {[llength $stack] >= $::tclpdf::svg::useDepthLimit} {
      my SvgSkipped use-depth
      return
    }
    set count [expr {[my state svgUseCount] + 1}]
    my state svgUseCount $count
    if {$count > $::tclpdf::svg::useCountLimit} {
      return -code error -errorcode [list TCLPDF SVG LIMIT use] \
          "tclpdf: the drawing's <use> elements unfold to more than\
          $::tclpdf::svg::useCountLimit copies - nesting them multiplies,\
          and this drawing would not finish"
    }
    set x [my SvgLength [::tclpdf::xml attribute $node x] 0 x]
    set y [my SvgLength [::tclpdf::xml attribute $node y] 0 y]
    my SvgSave
    set outerRelative {}
    if {$x != 0 || $y != 0} {
      my content "1 0 0 1 [::tclpdf::pdfObj num $x] [::tclpdf::pdfObj num $y] cm\n"
      # The offset moves the target's coordinates like any transform, so a
      # capture's relative matrix has to follow it too.
      set outerRelative [my SvgGroupShift [::tclpdf::geometry translate $x $y]]
    }
    my state svgUseStack [linsert $stack end $id]
    try {
      # A <symbol> is not drawn where it stands but IS drawn through a use,
      # and it brings a VIEWPORT with it (5.6: "width and height ... only
      # have an effect ... when the referenced element is an svg or a
      # symbol"; 7.7 for the viewBox). Taking its children directly - which
      # is what happened until 2026-08-27 - threw away both, and a symbol
      # whose viewBox says 10 units came out ten units wide where the use
      # asked for 80.
      set targetName [string map {svg: {}} [::tclpdf::xml name $target]]
      if {$targetName in {symbol svg}} {
        # The viewport element is the TARGET, not the use: the use's own x/y
        # are already in the stream as a translate above, and reading them a
        # second time would place the symbol twice as far along.
        my SvgViewport $target $target $style \
            [my SvgLength [::tclpdf::xml attribute $node width] {} x] \
            [my SvgLength [::tclpdf::xml attribute $node height] {} y]
      } else {
        my SvgElement $target $style
      }
    } finally {
      my state svgUseStack $stack
      my SvgGroupUnshift $outerRelative
      my SvgRestore
    }
    return
  }

  # Text inside a drawing.
  #
  # The enclosing matrix flips y so that SVG coordinates work; glyphs drawn
  # through it would come out mirrored. So the text is wrapped in a second
  # flip about its own baseline - two wrongs that are exactly one right, and
  # cheaper than keeping a second unflipped coordinate system around.
  #
  # A <text> IS A SEQUENCE, not a string. Until 2026-08-27 the element's own
  # character data was collected first and the text of every <tspan> appended
  # behind it, which put "A<tspan>B</tspan>C" on the page as "ACB"; a tspan's
  # own painting attributes were dropped, so a red letter came out black; and
  # its own x/y were never read, so a tspan placed elsewhere sat where its
  # parent did. SVG 1.1, 10.5 makes each tspan a piece with its own position
  # and its own properties, set in document order.
  method SvgText {node style} {
    # A <tspan> is drawn by the <text> that holds it. Reached on its own -
    # the element switch has a case for both names - it must not be set a
    # second time.
    if {[string map {svg: {}} [::tclpdf::xml name $node]] ne "text"} {
      return
    }
    set preserve [expr {[string trim [my SvgInherited $node xml:space]] eq "preserve"}]
    set runs [my SvgTextSpace [my SvgTextRuns $node $style $preserve] $preserve]
    if {![llength $runs]} {
      return
    }
    # x and y are coordinate LISTS (10.4), one value per character. Only the
    # first is honoured here - per-character placement would mean one Tm per
    # glyph - but reading the list is what keeps the rest of the values from
    # making the whole attribute unreadable: [SvgLength] answered its default
    # of 0 for "10 40 70", and the line jumped to the left edge of the
    # drawing.
    set penX [my SvgTextCoordinate [::tclpdf::xml attribute $node x] 0 x]
    set penY [my SvgTextCoordinate [::tclpdf::xml attribute $node y] 0 y]
    set total [llength $runs]
    set index 0
    while {$index < $total} {
      # ONE CHUNK: from a run that names an absolute position up to the one
      # before the next. text-anchor applies to a chunk as a whole (10.9),
      # so its width has to be known before the first glyph is placed.
      lassign [lindex $runs $index] -> chunkX chunkY chunkStyle
      if {$chunkX ne {}} {
        set penX $chunkX
      }
      if {$chunkY ne {}} {
        set penY $chunkY
      }
      set last $index
      while {$last + 1 < $total} {
        lassign [lindex $runs [expr {$last + 1}]] -> nextX nextY
        if {$nextX ne {} || $nextY ne {}} {
          break
        }
        incr last
      }
      set prepared {}
      set widths {}
      set chunkWidth 0
      for {set piece $index} {$piece <= $last} {incr piece} {
        lassign [lindex $runs $piece] string -> -> pieceStyle
        set face [my SvgTextFace $pieceStyle]
        set width [lindex [my TextPoints [dict get $face state] $string] 0]
        lappend prepared $face
        lappend widths $width
        set chunkWidth [expr {$chunkWidth + $width}]
      }
      switch -- [string trim [dict get $chunkStyle text-anchor]] {
        middle {set penX [expr {$penX - $chunkWidth / 2.0}]}
        end {set penX [expr {$penX - $chunkWidth}]}
      }
      for {set piece $index} {$piece <= $last} {incr piece} {
        lassign [lindex $runs $piece] string -> pieceY pieceStyle
        if {$pieceY ne {}} {
          set penY $pieceY
        }
        set face [lindex $prepared [expr {$piece - $index}]]
        set width [lindex $widths [expr {$piece - $index}]]
        my SvgTextShow $string $pieceStyle $face $penX $penY $width
        set penX [expr {$penX + $width}]
      }
      set index [expr {$last + 1}]
    }
    return
  }

  # The first value of a coordinate list (SVG 10.4), as a length.
  method SvgTextCoordinate {value default axis} {
    set value [string trim $value]
    if {$value eq {}} {
      return $default
    }
    set first [lindex [regexp -all -inline {[^\s,]+} $value] 0]
    return [my SvgLength $first $default $axis]
  }

  # The pieces of a <text> or a <tspan>, in document order: a list of
  # {string x y style}, where x and y are the empty string wherever the piece
  # simply continues where the one before it ended.
  method SvgTextRuns {node style preserve} {
    set runs {}
    set pending {}
    foreach part [::tclpdf::xml nodes $node] {
      lassign $part kind value
      if {$kind eq "text"} {
        if {$value ne {}} {
          lappend runs [list $value {} {} $style]
        }
        continue
      }
      set name [string map {svg: {}} [::tclpdf::xml name $value]]
      if {$name ni {tspan a}} {
        # textPath, tref and anything else: reported, like every element this
        # module does not draw.
        my SvgSkipped $name
        continue
      }
      set own [my SvgStyle $value $style]
      set space [string trim [::tclpdf::xml attribute $value xml:space]]
      set ownPreserve [expr {$space eq {} ? $preserve : ($space eq "preserve")}]
      set inner [my SvgTextRuns $value $own $ownPreserve]
      if {![llength $inner]} {
        continue
      }
      # The tspan's own position goes on its FIRST run; dx and dy are
      # relative and are added to whatever the pen has reached.
      set x [my SvgTextCoordinate [::tclpdf::xml attribute $value x] {} x]
      set y [my SvgTextCoordinate [::tclpdf::xml attribute $value y] {} y]
      if {$x ne {} || $y ne {}} {
        lassign [lindex $inner 0] string -> -> firstStyle
        lset inner 0 [list $string $x $y $firstStyle]
      }
      lappend runs {*}$inner
    }
    return $runs
  }

  # White space, over the whole element rather than per piece.
  #
  # XML 1.0 / SVG 1.1, 10.15 for xml:space="default": newlines are dropped,
  # tabs become spaces, runs of spaces collapse to one, and leading and
  # trailing space of the element goes. Under "preserve" newlines and tabs
  # become spaces and nothing else changes. [string trim] on each piece -
  # which is what happened until 2026-08-27 - did neither: "Hallo    Welt"
  # kept its four spaces and a preserved leading space was cut off.
  method SvgTextSpace {runs preserve} {
    set result {}
    foreach run $runs {
      lassign $run string x y style
      set string [string map [list \n { } \r { } \t { }] $string]
      if {!$preserve} {
        regsub -all {  +} $string { } string
      }
      lappend result [list $string $x $y $style]
    }
    if {!$preserve && [llength $result]} {
      lassign [lindex $result 0] string x y style
      lset result 0 [list [string trimleft $string] $x $y $style]
      lassign [lindex $result end] string x y style
      lset result end [list [string trimright $string] $x $y $style]
    }
    # A piece that is nothing but the space between two others still separates
    # them; one that is empty carries nothing at all.
    return [lmap run $result {
      if {[lindex $run 0] eq {}} continue
      set run
    }]
  }

  # The face one run is set in: the resolved state, the font, its resource
  # name and the size. Its own method because every run of a <text> asks the
  # same four questions and a tspan may answer them differently.
  method SvgTextFace {style} {
    set size [my SvgLength [dict get $style font-size] 12 d]
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
    # THE WEIGHT, and the document's own is not inherited: a drawing must
    # not come out bold because the running text around it happens to be.
    # SVG 10.10 spells it bold, bolder, or a number from 100 to 900, and CSS
    # 2.1 15.5 puts the line at 600 - which is where the corpus puts it too,
    # where 700 and 900 occur and 400 and 500 are the normal weights.
    #
    # A face that has no bold cut is the common case for an embedded family
    # under an alias, and it is REPORTED rather than silently set light: the
    # drawing then looks like the file with one difference the caller can
    # see in [svg info], instead of one nobody mentions. "bolder" is taken
    # as bold - relative to what, when the parent is the drawing itself, has
    # no answer this package could give.
    set weight [string trim [dict get $style font-weight]]
    set cut {}
    if {$weight in {bold bolder} ||
        ([string is integer -strict $weight] && $weight >= 600)} {
      set cut bold
      # WHETHER THERE IS A BOLD CUT AT ALL, and asking [TextResolve] does
      # not answer it: for an embedded family it hands the alias back
      # whatever the style, so a catch around it never fires and the drawing
      # came out light without a word. What answers it is the comparison -
      # an embedded family has one cut per alias, and a standard family has
      # a bold only where the AFM resolves it to a different face.
      #
      # AND THE THIRD ANSWER IS A REFUSAL. Since 2026-08-26 [afm resolve]
      # turns away a style the family has no cut for, which is right for a
      # [font] call - the caller asked for something that does not exist -
      # and is not an error HERE: SVG 10.10 and CSS 2.1 15.5 make font-weight
      # a wish that the face satisfies as best it can, and a family with one
      # cut satisfies it with that cut. Without the catch a drawing that says
      # font-family="Symbol" font-weight="bold" died with TCLPDF AFM STYLE
      # where it used to report the weight as skipped. So the refusal is read
      # as the answer it is - "no bold cut" - and joins the other two.
      if {[my TextEmbedded $family]
          || [catch {::tclpdf::afm resolve $family bold} boldCut]
          || $boldCut eq [::tclpdf::afm resolve $family {}]} {
        my SvgSkipped font-weight
        set cut {}
      }
    }
    # Everything after this goes through the same text state a [text] call
    # builds, which is what gives a drawing the embedded path: the same
    # measurement, the same resource, the same kerning and ligatures as the
    # running text around it.
    # Like every other text command: a drawing may be the first thing in the
    # document that sets a letter, and until now it was the one that never
    # needed the state.
    my TextInit
    set state [my TextMerge [list -family $family -style $cut -size $size]]
    return [dict create state $state font [dict get $state resolved] size $size]
  }

  # One run of a <text>, at the pen position the caller has worked out.
  method SvgTextShow {text style face x y width} {
    set state [dict get $face state]
    set font [dict get $face font]
    set size [dict get $face size]
    # visibility is read where the painting happens, exactly as it is for a
    # shape (SVG 11.5).
    if {[string tolower [string trim [dict get $style visibility]]] in
        {hidden collapse}} {
      return
    }
    set fill [dict get $style fill]
    # fill="none" MEANS NOT PAINTED (11.3). Turned into black - which is what
    # happened until 2026-08-27 - a line the file had asked to be invisible
    # stood on the page in the darkest colour there is.
    if {[string trim $fill] eq "none"} {
      return
    }
    # Measured BEFORE the face is registered, and that order is deliberate.
    # Measuring is what refuses a character the face cannot set, and a
    # registered resource outlives the failed drawing: a caught error left
    # Helvetica in the document, which is enough to make [pdfa] refuse to
    # write it. An attempt that came to nothing must leave nothing behind.
    set resource [my TextResource $font]
    # For a transparency group's BBox: one full size above and below the
    # baseline is generous for any face - a BBox clips, so the safe side is
    # the large one.
    if {[llength [my state svgGroupStack]]} {
      my SvgGroupBox $x [expr {$y - $size}] [expr {$x + $width}] [expr {$y + $size}]
    }
    # ASSEMBLED FIRST, WRITTEN AFTERWARDS - the order [SvgPaint] keeps, and
    # for the same reason. The flip used to go out as a bare "q ... cm"
    # BEFORE the colour was looked at, and a bare q is a bracket nothing
    # counted: when the paint could not be worked out, the unwinding in
    # [SvgRoot] closed that q instead of the drawing's own, the flipping
    # matrix stayed in force, and everything set afterwards came out upside
    # down and mirrored on a page qpdf finds nothing wrong with. Every value
    # below is settled before a byte reaches the stream, and the bracket goes
    # through SvgSave/SvgRestore like every other one in a drawing.
    if {[string match "url(*" $fill]} {
      # A PAINT SERVER ON <text>, through the same road a shape takes since
      # 2026-08-25 - the resolution used to sit inside [SvgPaint] and work
      # from a path's box, so a gradient on a line of text was reported and
      # the letters set in the initial colour. What a line of glyphs had to
      # gain first is a BOX: under the default
      # gradientUnits="objectBoundingBox" a gradient is measured in fractions
      # of the thing it fills, and until the text has been measured there is
      # nothing to take fractions of - which is why it is resolved down here
      # and not in [SvgStyle] with everything else.
      #
      # The box is the measured width by the face's own ascent and descent,
      # which is what this package calls a line everywhere else. It is the EM
      # box and NOT the ink box: SVG means the tight bounding box of the
      # glyphs, and that needs their outlines, which the text road does not
      # hand back. The difference is a few hundredths of an em at the top and
      # bottom edge, it shows only in a gradient running DOWN the line rather
      # than along it, and it keeps two lines of the same size in the same
      # colours whether or not one of them carries a "g".
      #
      # HOW OFTEN, counted on 2026-08-25 over all 14 998 SVG on this machine:
      # not one file paints a <text> with a paint server. What makes it worth
      # having is that it is no longer a road of its own - the shape road's
      # resolution became a building block, and this side only has to say
      # what its box is.
      set ascent [my TextFitAscent $font $size]
      set descent [my TextFitDescent $font $size]
      set resolved [my SvgPaintServer $fill \
          [list $x [expr {$y - $ascent}] $width [expr {$ascent + $descent}]]]
      if {$resolved eq {}} {
        # Nothing of that id, or a server this module cannot honour. The
        # house rule then: the text is set in the initial colour and the
        # substitution is reported - visible and complete, with [svg info]
        # saying what the file asked for instead.
        my SvgSkipped gradient
        set fill black
      } else {
        set fill $resolved
      }
    }
    if {$fill eq {}} {
      set fill black
    }
    set body "1 0 0 -1 0 [::tclpdf::pdfObj num [expr {2.0 * $y}]] cm\n"
    append body "[::tclpdf::color operator [my SvgLuminosity \
        [::tclpdf::color parse [my GraphicsColour $fill svg]]] fill]\n"
    # [TextResource] already returns PDF name syntax - running it through
    # [name] again escapes the slash into #2F, and the reader then looks for a
    # font whose name begins with a slash.
    append body "BT $resource [::tclpdf::pdfObj num $size] Tf\n"
    append body "1 0 0 1 [::tclpdf::pdfObj num $x] [::tclpdf::pdfObj num $y] Tm\n"
    append body [my TextShow $font $state $text 0]
    append body "ET\n"
    my SvgSave
    my content $body
    my SvgRestore
    return
  }

  # The box enclosing a set of path operators, in drawing coordinates. Needed
  # for a gradient in objectBoundingBox units, which is the default - and the
  # operators are the only description of the shape available here.
}

package provide tclpdf::svgElement 1.7
