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
          foreach child [::tclpdf::xml children $node] {
            my SvgElement $child $style
          }
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

  # One element counted as skipped. The one place that touches the tally, so
  # that the three callers cannot drift - the element switch, the paint road
  # when it cannot resolve a reference, and the walk through <defs>.
  method SvgSkipped {what} {
    set skipped [my state svgSkipped]
    dict incr skipped $what
    my state svgSkipped $skipped
  }

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
        set x [my SvgLength [::tclpdf::xml attribute $node x] 0]
        set y [my SvgLength [::tclpdf::xml attribute $node y] 0]
        set width [my SvgLength [::tclpdf::xml attribute $node width] 0]
        set height [my SvgLength [::tclpdf::xml attribute $node height] 0]
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
        set rx [my SvgLength [::tclpdf::xml attribute $node rx] {}]
        set ry [my SvgLength [::tclpdf::xml attribute $node ry] {}]
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
        set cx [my SvgLength [::tclpdf::xml attribute $node cx] 0]
        set cy [my SvgLength [::tclpdf::xml attribute $node cy] 0]
        if {$name eq "circle"} {
          set rx [my SvgLength [::tclpdf::xml attribute $node r] 0]
          set ry $rx
        } else {
          set rx [my SvgLength [::tclpdf::xml attribute $node rx] 0]
          set ry [my SvgLength [::tclpdf::xml attribute $node ry] 0]
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
    set target [my SvgDefinition [string trimleft $reference #]]
    if {$target eq {}} {
      return
    }
    set x [my SvgLength [::tclpdf::xml attribute $node x] 0]
    set y [my SvgLength [::tclpdf::xml attribute $node y] 0]
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
      if {[my TextEmbedded $family] ||
          [::tclpdf::afm resolve $family bold] eq [::tclpdf::afm resolve $family {}]} {
        my SvgSkipped font-weight
        set cut {}
      }
    }
    #
    # Everything after this goes through the same text state a [text] call
    # builds, which is what gives a drawing the embedded path: the same
    # measurement, the same resource, the same kerning and ligatures as the
    # running text around it.
    # Like every other text command: a drawing may be the first thing in the
    # document that sets a letter, and until now it was the one that never
    # needed the state.
    my TextInit
    set state [my TextMerge [list -family $family -style $cut -size $size]]
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

    # ASSEMBLED FIRST, WRITTEN AFTERWARDS - the order [SvgPaint] keeps, and
    # for the same reason. The flip used to go out as a bare "q ... cm"
    # BEFORE the colour was looked at, and a bare q is a bracket nothing
    # counted: when the paint could not be worked out, the unwinding in
    # [SvgRoot] closed that q instead of the drawing's own, the flipping
    # matrix stayed in force, and everything set afterwards came out upside
    # down and mirrored on a page qpdf finds nothing wrong with. Every value
    # below is settled before a byte reaches the stream, and the bracket goes
    # through SvgSave/SvgRestore like every other one in a drawing.
    set fill [dict get $style fill]
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
    if {$fill eq {} || $fill eq "none"} {
      set fill black
    }
    set body "1 0 0 -1 0 [::tclpdf::pdfObj num [expr {2.0 * $y}]] cm\n"
    append body "[::tclpdf::color operator [::tclpdf::color parse \
        [my GraphicsColour $fill svg]] fill]\n"
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

package provide tclpdf::svgElement 1.5
