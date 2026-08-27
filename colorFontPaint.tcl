#
# tclpdf - PDF generation for Tcl
#
# colorFontPaint - a COLR version 1 paint graph as a Type 3 glyph stream
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# THE JOINT for version 1, exactly as colorFont.tcl is the joint for version
# 0: colrPaint.tcl says what a colour glyph looks like, glyfPath.tcl turns an
# outline into path operators, shading.tcl and shadingMesh.tcl write
# gradients, graphics.tcl writes the alpha and the blend modes, and this file
# puts them together into the content stream of ONE Type 3 glyph. It reads no
# table and invents no operator that exists next door.
#
# THE FOUR DECISIONS a reader should be able to check, because each of them
# could plausibly have gone the other way:
#
# 1. "sh" IN A CLIP, NEVER A SHADING PATTERN. A gradient could be a pattern
#    and a shape could be filled with it - that is what [shading pattern] is
#    for on a page. Inside a font it is wrong, and wrong in a way that only
#    shows on the second use: a pattern's matrix maps pattern space to the
#    DEFAULT space of the parent content stream and ignores the matrix in
#    force when the shape is painted (8.7.2). A glyph is painted under the
#    text matrix and the font matrix, so the same glyph set twice on one line
#    would show two different slices of one page-fixed gradient. The "sh"
#    operator paints in CURRENT user space and fills the current clip, so it
#    travels with the glyph. That is why every gradient here is a clip with an
#    "sh" inside it and never a "scn".
#
# 2. THE FILL FOR AN UNBOUNDED PAINT IS A RECTANGLE, AND THE RECTANGLE IS
#    COMPUTED. PaintSolid and the three gradients are "inherently unbounded"
#    (the standard's words): they paint everywhere the clip allows. "sh" does
#    that by itself; a solid colour needs a path, and the path has to cover
#    the clip in the space the operators are being written in - which is not
#    glyph space once a PaintTransform has been entered. So the drawing
#    carries the accumulated matrix, and the box is the glyph's bounds mapped
#    back through its inverse ([geometry invert], added for this). A fixed
#    "big rectangle" would be wrong under a scale of 1/100.
#
# 3. THE BOUNDS ARE THE ClipList's WHERE THERE IS ONE, AND COMPUTED WHERE
#    THERE IS NOT. A version 1 glyph must be bounded - "applications must
#    confirm that the color glyph definition is bounded, and must not render
#    the color glyph if the defining graph is not bounded" - and the ClipList
#    is a precomputed answer for the glyphs that have one (1966 of Noto Color
#    Emoji's 3993, measured). Where there is none the graph is walked and the
#    outline boxes of its PaintGlyph nodes are unioned, which is what the
#    standard itself suggests. A glyph that comes out unbounded is REFUSED
#    rather than drawn against a guessed box.
#
# 4. TRANSPARENCY IS PDF'S, NOT AN APPROXIMATION. A colour line whose stops
#    carry different alpha values - 8730 of Noto Color Emoji's 18471 colour
#    lines, measured - cannot be a PDF shading, because a shading has no alpha
#    channel. It becomes a shading painted in BANDS OF CONSTANT ALPHA - the
#    same shading over and over, each time through a clip that narrows the
#    one before it and at a /ca that adds the next step of alpha, so that the
#    alpha accumulates to what the font asked for to within half a step of
#    1/64. The exact construction is a luminosity soft mask, a grey twin of
#    the shading established with a "gs", and it is still what a gradient
#    that cannot be banded gets - but a soft mask inside a Type 3 glyph is
#    the one construction in this file that readers disagree about, and the
#    bands are a clip and a /ca, which nothing can read two ways. See
#    colorFontBand.tcl for the measurement and the arithmetic.
#    PaintComposite likewise: the
#    fifteen blend modes go into an isolated transparency group with a /BM,
#    and the Porter-Duff modes that PDF has no operator for are built out of
#    an ALPHA soft mask taken from the other side's group, which is what
#    Source In and its seven relatives are by definition.
#
# WHAT IS REFUSED BY NAME, all of it below TCLPDF COLORFONT:
#
#   - COMPOSITE plus: "Plus"/"Lighter" adds the two colours and clamps. PDF
#     has fifteen blend modes and no additive one (11.3.5), and there is no
#     construction out of the others that produces it. Measured: Noto Color
#     Emoji uses two composite modes in its 578 PaintComposite tables, Source
#     In (316) and Soft Light (262), and neither is this one.
#   - FOREGROUND: a colour STOP whose palette index is the 0xFFFF sentinel.
#     The sentinel means "whatever colour the text has", which is decided when
#     the glyph is DRAWN; a shading's colours stand in the file and are
#     decided when it is DEFINED. A Type 3 glyph is defined once and set in
#     many colours, so there is no colour to write. In a PaintSolid the same
#     sentinel works and is honoured - that fill simply gets no colour
#     operator. Measured: not used by Noto Color Emoji, in none of its 18471
#     colour lines and none of its 111668 PaintSolid tables.
#   - UNBOUNDED: a glyph with no clip box whose graph paints outside every
#     outline - see decision 3.
#   - EMPTY: a graph that paints nothing at all, which is the blank-page trap
#     of [font embed] one level down. And COMPOSITE again, this time for a
#     SHAPE that is a composite glyph: assembling components is glyfOutline's
#     subject, and measured over the 129823 shapes of Noto Color Emoji not one
#     is a composite.
#
# What colrPaint.tcl refuses - a cycle, an unknown paint format, a slice past
# the LayerList - passes through with its own TCLPDF COLR code, so a caller
# trapping the reader traps it here too.
#
# WHAT IS APPROXIMATED, and it is two things, both stated where they are done:
#
#   - A SWEEP GRADIENT is a fan of Gouraud triangles (shading type 4). PDF has
#     no angular gradient at all, and the fan is the construction that keeps
#     the colour interpolation in the file rather than in a bitmap: one
#     triangle per wedge of at most 4 degrees, with a vertex forced at every
#     colour stop, the wedge's centre corner carrying the MEAN of its two rim
#     colours, and the outer radius pushed out by 1/cos of the half angle so
#     the chords cover the circle they approximate. Wedge by wedge rather than
#     as a chained fan, which is the one thing here that was got wrong first
#     and measured second - see [ColorFontPaintSweep].
#   - EXTEND repeat AND reflect are UNFOLDED: the colour line is copied along
#     its own axis until it covers the box being painted, and PDF then paints
#     one long pad gradient. PDF shadings have pad and nothing else
#     (/Extend is two booleans, Table 78). The unfolding is exact for as many
#     periods as it writes and capped at 64 of them; a font that needs more
#     has periods below rendering resolution. Measured: Noto Color Emoji uses
#     pad in all 18471 of its colour lines.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
# 1.5 for [geometry invert], which was added for the fill rectangle of an
# unbounded paint under a chain of transforms - see decision 2 above.
package require tclpdf::geometry 1.5-
package require tclpdf::color 1.0-
package require tclpdf::graphics 1.0-
# For [FormCount], which numbers the form XObjects a composite and a soft mask
# need. Named here rather than left to the lazy dispatcher in document.tcl:
# that one maps PUBLIC methods to topics and knows nothing of [FormCount], so
# the first PaintComposite used to die with "unknown method" - measured
# 2026-08-26. colorFont.tcl names [graphics] the same way and for the same
# reason.
package require tclpdf::xObject 1.0-
package require tclpdf::sfnt 1.0-
package require tclpdf::colr 1.1-
package require tclpdf::colrPaint 1.0-
# The bands of constant alpha a gradient's varying alpha becomes, and the clip
# paths that carry them - see decision 4 above.
package require tclpdf::colorFontBand 1.0-
package require tclpdf::colorFontRegion 1.0-
package require tclpdf::glyfOutline 1.0-
package require tclpdf::glyfPath 1.2-
package require tclpdf::pdfFunction 1.0-
package require tclpdf::shading 1.0-
package require tclpdf::document 1.0-
package require tclpdf::type3 1.2-

namespace eval ::tclpdf::colorFontPaint {
  # The finest a sweep gradient is cut into, in degrees. Four is what the
  # rendering comparison settled on; see [ColorFontPaintSweep].
  variable sweepStep 4.0

  # How many copies of a colour line an unfolded repeat or reflect may cost,
  # and how many colour stops the result may hold. Both are ceilings on a
  # construction that is otherwise unbounded - a colour line spanning 0.001 of
  # the axis would repeat a thousand times over the unit interval.
  variable periods 64
  variable stopLimit 512

  # The PDF blend mode of each COLR composite mode that has one. The fifteen
  # of 11.3.5 against the fifteen "separable" and "non-separable" blend modes
  # of the CompositeMode enumeration - the same list under two sets of names.
  variable blends {
    screen Screen overlay Overlay darken Darken lighten Lighten
    colorDodge ColorDodge colorBurn ColorBurn hardLight HardLight
    softLight SoftLight difference Difference exclusion Exclusion
    multiply Multiply hue Hue saturation Saturation color Color
    luminosity Luminosity
  }
}

oo::define ::tclpdf::document::document {

  # The content stream of one version 1 colour glyph.
  #
  # "record" is what [ColorFontRead] collected: char, glyph, width, the paint
  # tree and the clip box the table gave, if any. What comes back is the body
  # of the Type 3 glyph - everything after the d0, which type3.tcl writes.
  method ColorFontPaintStream {record alias} {
    set context [dict create alias $alias \
        what "a colour glyph of font \"$alias\"" \
        parsed [dict get $record parsed] state [dict get $record state] \
        palette [dict get $record palette] \
        matrix [::tclpdf::geometry identity]]
    set box [dict get $record clip]
    if {$box eq {}} {
      # No precomputed clip box: the bounds are what the graph paints inside.
      # An unbounded graph is refused here rather than drawn - see the head of
      # this file.
      set box [my ColorFontPaintBounds [dict get $record tree] \
          [::tclpdf::geometry identity] $context]
      if {$box eq "unbounded"} {
        return -code error -errorcode [list TCLPDF COLORFONT UNBOUNDED \
            [dict get $record u] $alias] \
            "tclpdf: character [dict get $record u] of this face has a\
            version 1 colour description that paints outside every outline in\
            it and no clip box to bound it - such a glyph \"must not be\
            rendered\" (ISO/IEC 14496-22, 5.7.11), because it has no size a\
            page could reserve for it"
      }
      if {$box eq {}} {
        my ColorFontPaintNothing $record $alias
      }
      set clipped 0
    } else {
      set clipped 1
    }
    dict set context box $box
    set body {}
    if {$clipped} {
      # The table's own bounds, as a clipping rectangle. Written only when the
      # table gave one: a box computed from the outlines already bounds
      # everything that is drawn, and a rectangle around it would be an
      # operator that clips nothing.
      append body [my ColorFontPaintBox $box] "W\nn\n"
    }
    set drawn [my ColorFontPaintNode [dict get $record tree] $context]
    if {$drawn eq {}} {
      # The blank-page trap of [font embed] one level down, and the same
      # answer: a graph that paints nothing - every shape empty, every fill
      # fully transparent - would put a glyph into the font that sets,
      # measures and extracts and draws nothing at all.
      my ColorFontPaintNothing $record $alias
    }
    return $body$drawn
  }

  # The refusal for a version 1 colour glyph that would come out blank. Its
  # code is the one version 0 uses for the same thing, because it is the same
  # thing: a font whose glyph is there and draws nothing.
  method ColorFontPaintNothing {record alias} {
    return -code error -errorcode [list TCLPDF COLORFONT EMPTY \
        [dict get $record u] $alias] \
        "tclpdf: the version 1 colour description of character\
        [dict get $record u] paints nothing at all - every shape in it is an\
        outline the face has not got, or every fill is fully transparent. A\
        font built from it comes out blank with nothing reporting it"
  }

  # WHICH CONSTRUCTION A COLOUR GLYPH GOT, counted per font.
  #
  # A caller cannot see this from the outside and it decides how the glyph
  # comes out in the two readers that misplace a soft mask inside a Type 3
  # glyph (colorFontBand.tcl says which and by how much): a gradient painted
  # in BANDS and a Source In answered with a CLIP or a constant /ca are read
  # the same way by every reader there is, while a soft MASK is not. So the
  # four are counted as they are written and kept under the font's alias,
  # where [font info] reports the masks among them - the one number a caller
  # has a decision to make about.
  #
  # Counted and not listed per glyph: the question a caller asks is "does
  # this document hold a construction I have to check in my reader", and the
  # answer to that is a number. The glyph that got it is in the file.
  method ColorFontPaintCount {context kind} {
    set counts [my state colorFont]
    set alias [dict get $context alias]
    if {![dict exists $counts $alias]} {
      dict set counts $alias [dict create bands 0 clip 0 constant 0 mask 0]
    }
    dict set counts $alias $kind \
        [expr {[dict get $counts $alias $kind] + 1}]
    my state colorFont $counts
    return
  }

  # A box {x0 y0 x1 y1} as the operands of "re", ready for W or f.
  method ColorFontPaintBox {box} {
    lassign $box x0 y0 x1 y1
    return "[::tclpdf::pdfObj num $x0] [::tclpdf::pdfObj num $y0]\
        [::tclpdf::pdfObj num [expr {$x1 - $x0}]]\
        [::tclpdf::pdfObj num [expr {$y1 - $y0}]] re\n"
  }

  # -- the bounds of a graph -------------------------------------------------

  # What a paint graph paints inside, in GLYPH units.
  #
  # THREE ANSWERS AND NOT TWO, which is the distinction this got wrong first
  # and measured second: a box; the empty string for a graph that paints
  # NOTHING, which is bounded in the strictest possible way; and the word
  # "unbounded" for one that paints outside every shape in it. Folding the
  # last two together turned a PaintGlyph naming an outline the face has not
  # got - a legal thing for a font to carry - into the refusal meant for a
  # glyph with no bounds at all.
  #
  # The rule is the standard's list of which formats are bounded: a PaintGlyph
  # is bounded by its outline whatever its child does, a fill of any kind is
  # unbounded, and everything else is bounded exactly when the sub-graphs it
  # holds are. A composite is treated as the union of its two sides, which is
  # a superset for every mode except Clear - and a superset is what a bound is
  # for.
  method ColorFontPaintBounds {node matrix context} {
    switch -- [dict get $node paint] {
      glyph {
        set outline [my ColorFontPaintOutline $context [dict get $node glyph]]
        if {![dict size $outline] || [dict get $outline type] eq "empty"} {
          return {}
        }
        lassign [dict get $outline bounds] x0 y0 x1 y1
        set box {}
        foreach corner [list [list $x0 $y0] [list $x1 $y0] [list $x1 $y1] \
            [list $x0 $y1]] {
          set box [my ColorFontPaintUnion $box \
              [my ColorFontPaintDot \
                  [::tclpdf::geometry apply $matrix {*}$corner]]]
        }
        return $box
      }
      layers {
        set box {}
        foreach child [dict get $node children] {
          set box [my ColorFontPaintUnion $box \
              [my ColorFontPaintBounds $child $matrix $context]]
        }
        return $box
      }
      transform {
        return [my ColorFontPaintBounds [dict get $node child] \
            [::tclpdf::geometry multiply [dict get $node matrix] $matrix] \
            $context]
      }
      composite {
        if {[dict get $node mode] eq "clear"} {
          return {}
        }
        return [my ColorFontPaintUnion \
            [my ColorFontPaintBounds [dict get $node source] $matrix $context] \
            [my ColorFontPaintBounds [dict get $node backdrop] $matrix \
                $context]]
      }
    }
    # solid, linear, radial, sweep: unbounded by definition, and the word
    # rather than the empty string - see above.
    return unbounded
  }

  # A point as a box of no size, so that [ColorFontPaintUnion] is the only
  # place that knows how two boxes combine.
  method ColorFontPaintDot {point} {
    lassign $point x y
    return [list $x $y $x $y]
  }

  method ColorFontPaintUnion {first second} {
    if {$first eq "unbounded" || $second eq "unbounded"} {
      # One unbounded piece makes the whole unbounded: there is no box that
      # holds it, whatever the other side does.
      return unbounded
    }
    if {$first eq {}} {
      return $second
    }
    if {$second eq {}} {
      return $first
    }
    lassign $first ax0 ay0 ax1 ay1
    lassign $second bx0 by0 bx1 by1
    return [list [expr {min($ax0, $bx0)}] [expr {min($ay0, $by0)}] \
        [expr {max($ax1, $bx1)}] [expr {max($ay1, $by1)}]]
  }

  # The glyph bounds as they have to be written in the space the operators are
  # in right now: the box, mapped back through the accumulated matrix.
  #
  # The preimage of a rectangle under an affine map is a parallelogram, and
  # the box around its four corners contains it exactly - so this is a cover
  # and not an estimate.
  method ColorFontPaintCover {context} {
    set matrix [dict get $context matrix]
    if {[::tclpdf::geometry singular $matrix]} {
      return {}
    }
    set back [::tclpdf::geometry invert $matrix]
    lassign [dict get $context box] x0 y0 x1 y1
    set box {}
    foreach corner [list [list $x0 $y0] [list $x1 $y0] [list $x1 $y1] \
        [list $x0 $y1]] {
      set box [my ColorFontPaintUnion $box \
          [my ColorFontPaintDot [::tclpdf::geometry apply $back {*}$corner]]]
    }
    return $box
  }

  # -- one node --------------------------------------------------------------

  method ColorFontPaintNode {node context} {
    switch -- [dict get $node paint] {
      layers {
        # Each layer in its own bracket: a layer that sets a colour or a clip
        # must not reach the one above it, and the z-order is the order the
        # table gives, bottom first.
        set body {}
        foreach child [dict get $node children] {
          set inner [my ColorFontPaintNode $child $context]
          if {$inner ne {}} {
            append body "q\n" $inner "Q\n"
          }
        }
        return $body
      }
      glyph {
        # The outline is a CLIP and not ink: "The glyph outline is not
        # rendered; only the fill is rendered." Nonzero winding, for the
        # reason glyfPath.tcl states at length.
        set operators [my ColorFontPaintPath $context [dict get $node glyph]]
        if {$operators eq {}} {
          return {}
        }
        set inner [my ColorFontPaintNode [dict get $node child] $context]
        if {$inner eq {}} {
          return {}
        }
        return "q\n$operators W\nn\n$inner Q\n"
      }
      transform {
        set matrix [dict get $node matrix]
        if {[::tclpdf::geometry singular $matrix]} {
          # A transform that flattens the plane onto a line. The standard
          # calls the gradients under such a transform degenerate and says
          # they must not be rendered; an outline under it has no area either.
          return {}
        }
        dict set context matrix \
            [::tclpdf::geometry multiply $matrix [dict get $context matrix]]
        set inner [my ColorFontPaintNode [dict get $node child] $context]
        if {$inner eq {}} {
          return {}
        }
        return "q\n[join [lmap value $matrix {
              ::tclpdf::pdfObj num $value 6
            }] { }] cm\n$inner Q\n"
      }
      solid {
        return [my ColorFontPaintSolid $node $context]
      }
      linear - radial - sweep {
        return [my ColorFontPaintGradient $node $context]
      }
      composite {
        return [my ColorFontPaintComposite $node $context]
      }
    }
    return -code error -errorcode [list TCLPDF COLORFONT PAINT \
        [dict get $node paint]] \
        "tclpdf: unknown paint node \"[dict get $node paint]\""
  }

  # The outline of one layer glyph, parsed. Composite glyphs are refused by
  # [glyfPath] one step further on; here an outline the face has not got reads
  # as empty, which is what makes a PaintGlyph naming a missing glyph draw
  # nothing rather than fail.
  method ColorFontPaintOutline {context glyph} {
    return [::tclpdf::glyfOutline parse [my ColorFontGlyphData \
        [dict get $context parsed] $glyph]]
  }

  # The same outline as path operators, in font units.
  method ColorFontPaintPath {context glyph} {
    set outline [my ColorFontPaintOutline $context $glyph]
    if {![dict size $outline] || [dict get $outline type] eq "empty"} {
      return {}
    }
    if {[dict get $outline type] eq "composite"} {
      return -code error -errorcode [list TCLPDF COLORFONT COMPOSITE \
          [dict get $context alias] $glyph] \
          "tclpdf: glyph $glyph, used as a shape by the version 1 colour\
          description of font \"[dict get $context alias]\", is a COMPOSITE\
          glyph - it draws other glyphs rather than an outline of its own,\
          and tclpdf assembles those only when a face is embedded. Measured\
          over the 129823 shapes of Noto Color Emoji, not one is a composite;\
          the shapes of a colour glyph are drawn figures rather than letters\
          with accents"
    }
    return [::tclpdf::glyfPath operators $outline]
  }


  # -- a solid fill ----------------------------------------------------------

  # PaintSolid: one colour over everything the clip allows.
  #
  # The 0xFFFF sentinel is honoured exactly as version 0 honours it - no
  # colour operator at all, so the fill takes the colour the text was set in.
  # That is the one thing a Type 3 glyph can do that a picture cannot.
  method ColorFontPaintSolid {node context} {
    set fill [my ColorFontPaintFill $node $context]
    if {![llength $fill]} {
      # Fully transparent, which [ColorFontPaintFill] answers as nothing at
      # all - and so does a fill of alpha 0.
      return {}
    }
    return [my ColorFontPaintFlat $context [lindex $fill 1] [lindex $fill 0]]
  }

  # A flat fill of the whole clip in one colour, at one alpha. The empty
  # colour spec is the 0xFFFF sentinel: no colour operator is written and the
  # fill takes whatever the text colour is.
  #
  # Reached from PaintSolid and from the three gradients, each of which
  # degenerates into a flat fill in a case the standard names - a colour line
  # of one stop, and one whose stops all sit at the same offset.
  method ColorFontPaintFlat {context spec alpha} {
    if {$alpha <= 0} {
      # Fully transparent. An operator that paints nothing is still an
      # operator a reader has to execute.
      return {}
    }
    set cover [my ColorFontPaintCover $context]
    if {$cover eq {}} {
      return {}
    }
    set body "q\n"
    if {$alpha < 1} {
      append body "[::tclpdf::pdfObj name [my GraphicsOpacity $alpha fill]] gs\n"
    }
    if {$spec ne {}} {
      append body [::tclpdf::color operator [::tclpdf::color parse \
          [my ColourUsed $spec [dict get $context what]]] fill] "\n"
    }
    append body [my ColorFontPaintBox $cover] "f\nQ\n"
    return $body
  }

  # A parsed colour back in the shape a caller writes one in - {rgb {r g b}}
  # has one element after the space name where "rgb r g b" has three, and
  # [ColourUsed] and [shading -colors] both take the second. The same two
  # lines colorFont.tcl writes for a version 0 layer.
  method ColorFontPaintSpec {colour} {
    return [linsert [lindex $colour 1] 0 [lindex $colour 0]]
  }

  # -- the three gradients ---------------------------------------------------

  # A gradient of any kind: resolve the colour line, then hand the geometry to
  # the builder that knows it.
  #
  # Everything that can be REFUSED is read before a single object is written -
  # the same order shading.tcl keeps and for the same reason: a shading
  # written for a gradient that is then thrown out is an object no reader ever
  # reaches and every validator counts.
  method ColorFontPaintGradient {node context} {
    set stops [my ColorFontPaintStops $node $context]
    if {![llength $stops]} {
      # "If the color line does not have any color stops, then transparent
      # black is used for the entire color line" - nothing to paint.
      return {}
    }
    if {[llength $stops] == 1} {
      # "If only one color stop is specified, that color is used for the
      # entire color line" - which is a flat fill in every respect.
      return [my ColorFontPaintFlat $context [lindex $stops 0 1] \
          [lindex $stops 0 2]]
    }
    set cover [my ColorFontPaintCover $context]
    if {$cover eq {}} {
      return {}
    }
    switch -- [dict get $node paint] {
      linear {return [my ColorFontPaintLinear $node $context $stops $cover]}
      radial {return [my ColorFontPaintRadial $node $context $stops $cover]}
      sweep {return [my ColorFontPaintSweep $node $context $stops $cover]}
    }
  }

  # The colour stops of a colour line as {offset spec alpha}, with the CPAL
  # entry's own alpha already multiplied into the stop's.
  method ColorFontPaintStops {node context} {
    set stops {}
    foreach stop [dict get $node line stops] {
      lassign $stop offset entry alpha
      set colour [::tclpdf::colr color [dict get $context state] \
          [dict get $context palette] $entry]
      if {$colour eq {}} {
        return -code error -errorcode [list TCLPDF COLORFONT FOREGROUND \
            [dict get $context alias]] \
            "tclpdf: a colour stop of a gradient in font\
            \"[dict get $context alias]\" names palette index 0xFFFF, the\
            sentinel for \"the colour the text has\" (ISO/IEC 14496-22,\
            5.7.11). A PDF shading carries its colours in the file and is\
            written when the font is defined, while the text colour is chosen\
            every time the glyph is set, so there is no colour to write. The\
            sentinel works in a solid fill, where the glyph simply sets no\
            colour of its own"
      }
      lappend stops [list $offset [my ColorFontPaintSpec [lindex $colour 0]] \
          [expr {$alpha * [lindex $colour 1]}]]
    }
    return $stops
  }

  # THE WIDTH A DEGENERATE COLOUR LINE IS OPENED TO, in the parameter of the
  # gradient it belongs to.
  #
  # A colour line whose stops ALL sit on one offset is not a gradient but a
  # STEP, and the standard says which colour lies on which side of it: "the
  # first one given in the font must be used for computing color values on
  # the color line below that stop offset, and the last one ... at or above".
  # Two colours meeting at a line, a circle or a ray - which is a shading with
  # /Extend [true true] and an axis of no length, and PDF has no such thing.
  # So the line is given an axis a TEN-THOUSANDTH of the stretch the box being
  # painted spans, and the extend does the rest: the first colour below it,
  # the last above it, exactly as the sentence asks.
  #
  # WHAT THE APPROXIMATION COSTS is the sharpness of the edge and nothing
  # else: the transition is a ten-thousandth of the glyph wide, a twentieth of
  # a pixel where a 1000 unit em is set at 72 pt and rendered at 400 dpi, so
  # the two colours meet inside one pixel and the raster shows the step the
  # font asked for.
  #
  # NOT THE SMALLEST NUMBER THAT DIFFERS, and that is the reason for a
  # fraction of the box rather than an absolute epsilon: the coordinates go
  # into the file as PDF reals of five decimals (7.3.3), and two ends that
  # round to the same number are a shading with no axis at all - while a
  # gradient under a scale of 1/100 has a box a hundred times as wide and
  # needs the same fraction of it.
  #
  # A degenerate box gets 1.0, which is the whole of a normalised colour line
  # and cannot be zero.
  method ColorFontPaintStep {low high} {
    set span [expr {abs($high - $low)}]
    if {$span <= 0} {
      set span 1.0
    }
    return [expr {$span / 10000.0}]
  }

  # -- extending a colour line -----------------------------------------------

  # A colour line copied along its own axis until it covers the stretch that
  # has to be painted - which is how the repeat and reflect extend modes are
  # drawn at all.
  #
  # PDF's /Extend is two booleans and means pad and nothing else (Table 78):
  # a shading holds the colour of its end stop beyond its end and has no
  # notion of starting over. The standard's own analogy is the way out - given
  # a sequence "ABC", repeat extends it to "...ABC ABC ABC..." and reflect to
  # "...ABC CBA ABC..." - so the copies are written into the stop list and PDF
  # then pads a line that is already long enough for nobody to see the end
  # of it.
  #
  # THE CAP IS 64 PERIODS AND 512 STOPS, and it is a real limit rather than a
  # formality: a colour line spanning 0.01 of a gradient's axis repeats a
  # hundred times over the axis alone, and a thousand times over a box twice
  # its length. Where the cap bites, what is written is the middle of the
  # range - the periods nearest the axis - and the pad beyond it holds the
  # colour of the last copy; at that density one period is a fraction of a
  # pixel, and the difference is a shade rather than a shape. Measured: Noto
  # Color Emoji uses pad in all 18471 of its colour lines, so nothing real is
  # known to reach this.
  method ColorFontPaintUnfold {node stops low high} {
    variable ::tclpdf::colorFontPaint::periods
    variable ::tclpdf::colorFontPaint::stopLimit
    set extend [dict get $node line extend]
    set first [lindex $stops 0 0]
    set last [lindex $stops end 0]
    set span [expr {$last - $first}]
    if {$extend eq "pad" || $span <= 0} {
      # Pad is what PDF does by itself, and a colour line of no length has
      # nothing to repeat - "if the extend mode is repeat or reflect, the
      # color line is ill-formed and nothing must be rendered".
      if {$span <= 0 && $extend ne "pad"} {
        return {}
      }
      return $stops
    }
    # Which copies the box needs, counted in whole periods away from the one
    # the font wrote.
    set below [expr {int(floor(($low - $first) / $span))}]
    set above [expr {int(ceil(($high - $last) / $span))}]
    if {$below > 0} {
      set below 0
    }
    if {$above < 0} {
      set above 0
    }
    set count [expr {$above - $below + 1}]
    if {$count > $periods} {
      # Too many. Keep the ones nearest the middle of what has to be painted,
      # which is where the eye is.
      set middle [expr {int(round((($low + $high) / 2.0 - $first) / $span))}]
      set below [expr {$middle - $periods / 2}]
      set above [expr {$below + $periods - 1}]
    }
    set result {}
    for {set copy $below} {$copy <= $above} {incr copy} {
      set base [expr {$first + $copy * $span}]
      # Reflect turns every other copy around, which is what makes the joins
      # invisible: the analogy in the standard is "ABC CBA ABC CBA".
      set turned [expr {$extend eq "reflect" && abs($copy) % 2 == 1}]
      set piece $stops
      if {$turned} {
        set piece {}
        foreach stop [lreverse $stops] {
          lappend piece [lreplace $stop 0 0 \
              [expr {$first + $last - [lindex $stop 0]}]]
        }
      }
      foreach stop $piece {
        set at [expr {[lindex $stop 0] + $copy * $span}]
        if {$extend eq "reflect" && [llength $result]
            && $at <= [lindex $result end 0]} {
          # THE JOINT BETWEEN TWO COPIES, and the two extend modes want
          # opposite things there. Under reflect the copy is turned around,
          # so the last stop of one and the first of the next carry the SAME
          # colour - "...ABC CBA ABC..." - and one of them is enough. Under
          # repeat they carry the LAST and the FIRST colour of the line -
          # "...ABC ABC..." - and that difference IS the repeat: dropping one
          # of the pair leaves the last colour standing to the end of the
          # box, which draws the first period and then pads. Measured
          # 2026-08-26 against hb-view: a red-to-blue line repeated over a
          # disc came out a solid blue disc where HarfBuzz drew the sawtooth.
          #
          # Two stops on one offset are what a step IS, and PDF's stitching
          # bounds must increase strictly (7.10.4) - [ColorFontPaintSpread]
          # already separates such a pair by the smallest step a PDF real
          # holds, for the steps a font writes by hand.
          continue
        }
        lappend result [lreplace $stop 0 0 $at]
      }
      if {[llength $result] > $stopLimit} {
        break
      }
    }
    return $result
  }

  # A colour line cut down to a stretch of itself, with the colours at the two
  # new ends interpolated rather than dropped.
  #
  # Needed by the radial gradient alone: an unfolded colour line can reach
  # past the tip of the cone into circles of negative radius, which Table 80
  # forbids, and cutting there changes nothing that was visible - "the cone is
  # painted on the side of the tip for which r >= 0".
  method ColorFontPaintClamp {stops low high} {
    set result {}
    foreach stop $stops {
      set at [lindex $stop 0]
      if {$at <= $low || $at >= $high} {
        continue
      }
      lappend result $stop
    }
    # The cut keeps the OPEN stretch between the two bounds, so where a bound
    # falls on a step the end that survives is the one facing inwards: the
    # colour just above the low bound, the colour just below the high one.
    # Either way the step itself is gone - both its stops were dropped above
    # - and the bounds are the cone-tip parameters of a radial gradient, so
    # one of them landing exactly on a stop offset is a coincidence rather
    # than a case. Named rather than left to the default because the default
    # is right for one end and not for the other.
    return [linsert [linsert $result 0 \
        [my ColorFontPaintAt $stops $low upper]] \
        end [my ColorFontPaintAt $stops $high lower]]
  }

  # The stop a colour line has at one position: an existing one where the
  # position falls on it, an interpolated one between the two it falls
  # between, and the nearest end outside the line.
  #
  # WHERE THE POSITION FALLS ON A STEP - two stops sharing one offset, which
  # the format allows - the standard says which of the two answers: "the
  # first one given must be used for computing color values below that
  # offset, and the last one at or above". So "upper", the default, is the
  # LAST stop there and "lower" the first, and a caller that needs both ends
  # of the step (the sweep's rim, below) asks twice. Getting this wrong is
  # invisible until the step lands exactly on a vertex: everywhere else the
  # walk interpolates and never sees the pair.
  method ColorFontPaintAt {stops position {side upper}} {
    set on [lsearch -all -real -exact -index 0 $stops $position]
    if {[llength $on]} {
      if {$side eq "lower"} {
        set stop [lindex $stops [lindex $on 0]]
      } else {
        set stop [lindex $stops [lindex $on end]]
      }
      return [lreplace $stop 0 0 $position]
    }
    set previous [lindex $stops 0]
    if {$position <= [lindex $previous 0]} {
      return [lreplace $previous 0 0 $position]
    }
    foreach stop [lrange $stops 1 end] {
      set at [lindex $stop 0]
      if {$position <= $at} {
        set span [expr {$at - [lindex $previous 0]}]
        if {$span <= 0} {
          return [lreplace $stop 0 0 $position]
        }
        set share [expr {($position - [lindex $previous 0]) / double($span)}]
        return [list $position \
            [my ColorFontPaintBlendSpec [lindex $previous 1] [lindex $stop 1] \
                $share] \
            [expr {[lindex $previous 2]
                + $share * ([lindex $stop 2] - [lindex $previous 2])}]]
      }
      set previous $stop
    }
    return [lreplace [lindex $stops end] 0 0 $position]
  }

  # The stop halfway between two stops, which is what a wedge's centre corner
  # carries - see [ColorFontPaintSweep].
  method ColorFontPaintMean {first second} {
    return [list [expr {([lindex $first 0] + [lindex $second 0]) / 2.0}] \
        [my ColorFontPaintBlendSpec [lindex $first 1] [lindex $second 1] 0.5] \
        [expr {([lindex $first 2] + [lindex $second 2]) / 2.0}]]
  }

  # Two colour specs mixed, component by component.
  #
  # Through [color promote], the same way shading.tcl reconciles a grey stop
  # with a coloured one: "white" and "#808080" parse as GREY, so a line from
  # white to steelblue holds one one-component colour and one three-component
  # one, and mixing them element-wise without promoting first would produce a
  # colour of one component that is then written as RGB.
  method ColorFontPaintBlendSpec {from to share} {
    set first [::tclpdf::color parse $from]
    set second [::tclpdf::color parse $to]
    set space [lindex $first 0]
    if {$space eq "gray" && [lindex $second 0] ne "gray"} {
      set space [lindex $second 0]
    }
    set first [::tclpdf::color promote $first $space]
    set second [::tclpdf::color promote $second $space]
    return [linsert [lmap a [lindex $first 1] b [lindex $second 1] {
      expr {$a + $share * ($b - $a)}
    }] 0 $space]
  }

  # -- linear ----------------------------------------------------------------

  # PaintLinearGradient: three points, and the third is a rotation.
  #
  # THE THIRD POINT is what makes this more than a PDF axial shading, and the
  # standard names the way back: "An implementation can derive a single
  # vector, from p0 to a point p3, by computing the orthogonal projection of
  # the vector from p0 to p1 onto a line perpendicular to line p0p2 and
  # passing through p0". The gradient from p0 to p3, with colours projecting
  # perpendicular to it, IS the gradient - and that is exactly what a PDF type
  # 2 shading paints. So the whole of the rotation is one projection here and
  # nothing at all downstream.
  #
  # The two degenerate cases the standard names are both a refusal to paint,
  # not an error: p1 or p2 equal to p0, and p0p2 parallel to p0p1 - the second
  # is the one that survives a careless reading, because the projection then
  # collapses to a point and a shading between two identical points paints the
  # whole plane in one colour.
  method ColorFontPaintLinear {node context stops cover} {
    lassign [dict get $node p0] x0 y0
    lassign [dict get $node p1] x1 y1
    lassign [dict get $node p2] x2 y2
    set vx [expr {$x1 - $x0}]
    set vy [expr {$y1 - $y0}]
    set ux [expr {$x2 - $x0}]
    set uy [expr {$y2 - $y0}]
    set square [expr {$ux * $ux + $uy * $uy}]
    if {$square == 0 || ($vx == 0 && $vy == 0)} {
      return {}
    }
    set share [expr {($vx * $ux + $vy * $uy) / double($square)}]
    set wx [expr {$vx - $share * $ux}]
    set wy [expr {$vy - $share * $uy}]
    set reach [expr {$wx * $wx + $wy * $wy}]
    if {$reach == 0} {
      return {}
    }
    # How far along the axis the box being painted reaches, so that an
    # unfolded repeat or reflect knows when to stop. The projection of a
    # corner onto the axis is its position on the colour line.
    set range {}
    foreach corner [my ColorFontPaintCorners $cover] {
      lassign $corner cx cy
      lappend range [expr {(($cx - $x0) * $wx + ($cy - $y0) * $wy) / $reach}]
    }
    set low [::tcl::mathfunc::min {*}$range]
    set high [::tcl::mathfunc::max {*}$range]
    set stops [my ColorFontPaintUnfold $node $stops $low $high]
    if {[llength $stops] < 2} {
      return {}
    }
    set first [lindex $stops 0 0]
    set last [lindex $stops end 0]
    if {$last - $first <= 0} {
      # Every stop at one offset: a STEP rather than a gradient, and it is
      # painted as one - see [ColorFontPaintStep].
      set last [expr {$first + [my ColorFontPaintStep $low $high]}]
    }
    return [my ColorFontPaintShading $context $stops axial [list \
        from [list [expr {$x0 + $first * $wx}] [expr {$y0 + $first * $wy}]] \
        to [list [expr {$x0 + $last * $wx}] [expr {$y0 + $last * $wy}]]] \
        $cover]
  }

  # -- radial ----------------------------------------------------------------

  # PaintRadialGradient: two circles, and PDF's type 3 shading is the same
  # thing under another name.
  #
  # "The drawing algorithm for radial gradients follows the HTML WHATWG Canvas
  # specification for createRadialGradient()", and 8.7.4.5.4 describes a type
  # 3 shading in the same terms: circles interpolated between the two given
  # ones, painted in order of increasing parameter so that the later ones
  # cover the earlier. The centres, the radii, the direction and the rule that
  # circles of negative radius are not painted all carry across unchanged -
  # which is why this method is short and the linear one is not.
  method ColorFontPaintRadial {node context stops cover} {
    lassign [dict get $node c0] x0 y0
    lassign [dict get $node c1] x1 y1
    set r0 [dict get $node r0]
    set r1 [dict get $node r1]
    if {$x0 == $x1 && $y0 == $y1 && $r0 == $r1} {
      # "If c0 = c1 and r0 = r1 then paint nothing and return."
      return {}
    }
    set reach [my ColorFontPaintCircleRange $node $cover]
    set stops [my ColorFontPaintUnfold $node $stops {*}$reach]
    if {[llength $stops] < 2} {
      return {}
    }
    set first [lindex $stops 0 0]
    set last [lindex $stops end 0]
    set span [expr {$r1 - $r0}]
    if {$last - $first <= 0} {
      # Every stop at one offset: a STEP rather than a gradient - see
      # [ColorFontPaintStep]. Answered HERE, before the cone is cut at its
      # tip, because that cut asks [ColorFontPaintClamp] for the colour AT
      # the low bound and would take the upper half of the step for both
      # halves - and because a degenerate line whose radii differ used to
      # leave the tip block through "return {}" and paint nothing at all.
      if {$r0 + $first * $span < 0} {
        # The step sits behind the tip, where "the cone is painted on the
        # side of the tip for which r(w) >= 0" leaves nothing of the line
        # below it: what is painted is all at or above the step.
        return [my ColorFontPaintFlat $context [lindex $stops end 1] \
            [lindex $stops end 2]]
      }
      set last [expr {$first + [my ColorFontPaintStep {*}$reach]}]
    } elseif {$span != 0} {
      # Both radii of a type 3 shading "shall not be negative" (Table 80), and
      # an unfolded colour line can reach past the tip of the cone into radii
      # that are. Cutting the line at the tip changes nothing that was
      # visible: "the cone is painted on the side of the tip for which
      # r(w) >= 0".
      set tip [expr {-$r0 / double($span)}]
      if {$span > 0 && $first < $tip} {
        set first $tip
      } elseif {$span < 0 && $last > $tip} {
        set last $tip
      }
      if {$last - $first <= 0} {
        return {}
      }
      set stops [my ColorFontPaintClamp $stops $first $last]
    }
    return [my ColorFontPaintShading $context $stops radial [list \
        focus [list [expr {$x0 + $first * ($x1 - $x0)}] \
            [expr {$y0 + $first * ($y1 - $y0)}]] \
        innerRadius [expr {$r0 + $first * $span}] \
        center [list [expr {$x0 + $last * ($x1 - $x0)}] \
            [expr {$y0 + $last * ($y1 - $y0)}]] \
        radius [expr {$r0 + $last * $span}]] $cover]
  }

  # Which stretch of the colour line a radial gradient has to cover for the
  # box to be painted: the positions whose CIRCLE passes through a corner.
  #
  # A point P takes the colour of the position w where |P - c(w)| = r(w), and
  # that is a quadratic in w. Its two roots bracket the positions that matter
  # for that corner; over the four corners they bracket the box. A corner with
  # no real root lies outside the cone and is not painted at all, so it
  # contributes nothing, and a box with no painted corner at all gets the
  # font's own interval back.
  #
  # Only used to decide how far an unfolded repeat or reflect has to run - a
  # pad gradient needs no range at all, since PDF pads it itself.
  method ColorFontPaintCircleRange {node cover} {
    lassign [dict get $node c0] x0 y0
    lassign [dict get $node c1] x1 y1
    set r0 [dict get $node r0]
    set dx [expr {$x1 - $x0}]
    set dy [expr {$y1 - $y0}]
    set dr [expr {[dict get $node r1] - $r0}]
    set a [expr {$dx * $dx + $dy * $dy - $dr * $dr}]
    set range {}
    foreach corner [my ColorFontPaintCorners $cover] {
      lassign $corner cx cy
      set px [expr {$cx - $x0}]
      set py [expr {$cy - $y0}]
      set b [expr {$px * $dx + $py * $dy + $r0 * $dr}]
      set c [expr {$px * $px + $py * $py - $r0 * $r0}]
      if {$a == 0} {
        if {$b != 0} {
          lappend range [expr {$c / (2.0 * $b)}]
        }
        continue
      }
      set discriminant [expr {$b * $b - $a * $c}]
      if {$discriminant < 0} {
        continue
      }
      set root [expr {sqrt($discriminant)}]
      lappend range [expr {($b - $root) / double($a)}] \
          [expr {($b + $root) / double($a)}]
    }
    if {![llength $range]} {
      return {0 1}
    }
    return [list [::tcl::mathfunc::min {*}$range] \
        [::tcl::mathfunc::max {*}$range]]
  }

  # -- sweep -----------------------------------------------------------------

  # PaintSweepGradient: colour by ANGLE around a centre, which PDF has no
  # shading type for.
  #
  # The construction is a fan of Gouraud triangles (shading type 4, 8.7.4.5.5)
  # from the centre outwards: each triangle spans a small angle and carries
  # the colour line's colour at its two outer corners, so the colour runs
  # around the fan the way it runs around the gradient. Three things make it
  # right rather than close:
  #
  #   - A VERTEX AT EVERY COLOUR STOP. Without one, a stop that falls inside a
  #     triangle is interpolated straight past - a three-stop line would come
  #     out as a two-stop one, and the middle colour would never appear.
  #   - THE STEP IS FOUR DEGREES at most, which bounds the error that is left:
  #     between two stops the colour then runs along a chord rather than along
  #     the arc, and over four degrees the two part by 1 - cos(2 deg), about
  #     0.06 % of the radius. A coarser step shows as facets on a slow
  #     gradient, which is why the number is not larger; a finer one costs
  #     vertices nobody can see.
  #   - THE RADIUS IS PUSHED OUT by 1/cos of the half step, because the outer
  #     edge of a wedge is a chord and a chord lies INSIDE the circle it
  #     spans. Without the correction the corners of the box fall through the
  #     scallops between the chords and stay unpainted, which looks like a
  #     ragged edge and nothing reports it.
  #
  # WEDGE BY WEDGE AND NOT AS A FAN, which is the one thing here that was got
  # wrong first and measured second. A fan shares ONE centre vertex, and a
  # Gouraud triangle interpolates linearly from its corners - so along every
  # ray the colour ran from the centre's single colour to the rim's, and the
  # whole disc was washed towards whatever colour the centre happened to
  # carry. Rendered at 150 dpi that is not a subtlety: a blue-green-red sweep
  # came out as a blue disc with tinted edges. Each wedge is therefore its own
  # triangle, and its centre corner carries the MEAN of the wedge's two rim
  # colours - so the colour anywhere inside a wedge stays within that wedge's
  # own four degrees of the colour line, and the error is half a step rather
  # than half a turn.
  #
  # Only ONE TURN is drawn: "for each position along the circular arc starting
  # from 0 up to but not including 360 ... Angle positions below 0 and equal
  # to or above 360 are not sampled for drawing the rays." So the fan is a
  # full circle and the colour line is read at the positions that circle needs
  # - which, when the start and end angles lie outside 0..360, is a slice out
  # of the middle of the line rather than the whole of it.
  method ColorFontPaintSweep {node context stops cover} {
    variable ::tclpdf::colorFontPaint::sweepStep
    lassign [dict get $node center] cx cy
    set start [dict get $node start]
    set turn [expr {[dict get $node end] - $start}]
    if {$turn == 0} {
      # "If the color line's extend mode is reflect or repeat and start and
      # end angle are equal, nothing shall be drawn."
      if {[dict get $node line extend] ne "pad"} {
        return {}
      }
      # With pad the whole colour line is squeezed onto the ONE ray at the
      # start angle, and pad then holds the first stop's colour on the side
      # of the ray the angles fall below and the last stop's on the side at
      # and above it - the same sentence [ColorFontPaintStep] is built on,
      # read around a centre instead of along an axis. So the turn is opened
      # to a ten-thousandth of the circle rather than replaced by a flat
      # fill, which took the upper half of the step for both halves of the
      # disc. Where the start angle lies outside 0 to 360 nothing is below
      # it, and the fan comes out in one colour as it should.
      set turn [my ColorFontPaintStep 0 360]
    }
    set stops [my ColorFontPaintUnfold $node $stops \
        [expr {min(-$start / $turn, (360.0 - $start) / $turn)}] \
        [expr {max(-$start / $turn, (360.0 - $start) / $turn)}]]
    if {[llength $stops] < 2} {
      return {}
    }
    # The angles a vertex is needed at: the regular step, plus every colour
    # stop that falls inside the turn.
    set angles {}
    for {set angle 0.0} {$angle < 360.0} {set angle [expr {$angle + $sweepStep}]} {
      lappend angles $angle
    }
    lappend angles 360.0
    # And the angles a STEP falls on, kept apart from the rest: two stops on
    # one offset are a hard colour jump, and a jump needs TWO vertices at one
    # angle - the colour below it closing the wedge underneath, the colour at
    # and above it opening the wedge over it. One vertex cannot hold both,
    # and [lsort -unique] below throws the second angle away in any case.
    #
    # The offset is carried along rather than recomputed from the angle: the
    # angle came out of this very expression, so it is the same double and
    # matches as a dict key, while ($angle - $start) / $turn need not land
    # back on the offset it came from.
    #
    # Measured 2026-08-26 by rendering: a sweep stepping from red to blue at
    # 0.4 of a turn from 0 to 180 degrees drew the jump as a four degree
    # wedge of red running into blue. TWO things did that and either alone
    # is enough - [ColorFontPaintAt] answered with the colour BELOW the step
    # at both vertices, and where a step angle falls on the regular grid,
    # which an unfolded repeat puts there at every period, [lsort -unique]
    # left one vertex where two were needed.
    set steps {}
    set seen {}
    foreach stop $stops {
      set offset [lindex $stop 0]
      set angle [expr {$start + $offset * $turn}]
      if {$angle >= 0 && $angle <= 360} {
        if {[dict exists $seen $offset]} {
          dict set steps $angle $offset
        } elseif {$angle > 0 && $angle < 360} {
          lappend angles $angle
        }
      }
      dict set seen $offset 1
    }
    # AND A VERTEX WHERE THE ALPHA CROSSES A BAND, for the reason there is one
    # at every colour stop: a wedge of the fan carries ONE alpha (see
    # [ColorFontPaintWedges]), so a wedge spanning two bands would lose one of
    # them and the fade would come out in four degree terraces. Nothing is
    # added where the alpha does not vary, which is every sweep that has no
    # fade in it at all.
    foreach offset [::tclpdf::colorFontBand crossings \
        [lmap stop $stops {lindex $stop 0}] \
        [lmap stop $stops {lindex $stop 2}]] {
      set angle [expr {$start + $offset * $turn}]
      if {$angle > 0 && $angle < 360} {
        lappend angles $angle
      }
    }
    set angles [lsort -real -unique $angles]
    # Far enough out to cover the box, and then far enough again for the
    # chords to reach where the arc would.
    set radius 0
    foreach corner [my ColorFontPaintCorners $cover] {
      lassign $corner x y
      set radius [expr {max($radius, hypot($x - $cx, $y - $cy))}]
    }
    set widest 0
    foreach previous [lrange $angles 0 end-1] next [lrange $angles 1 end] {
      set widest [expr {max($widest, $next - $previous)}]
    }
    set radius [expr {$radius / cos($widest * acos(-1) / 360.0) + 1}]
    # The rim, one vertex per angle - two where a step sits, and only the one
    # that faces into the circle at the two ends of it: nothing lies below 0
    # degrees or above 360 for the other one to close off.
    set rim {}
    foreach angle $angles {
      set radians [expr {$angle * acos(-1) / 180.0}]
      set x [expr {$cx + $radius * cos($radians)}]
      set y [expr {$cy + $radius * sin($radians)}]
      if {[dict exists $steps $angle]} {
        set offset [dict get $steps $angle]
        if {$angle > 0} {
          lappend rim [list $x $y [my ColorFontPaintAt $stops $offset lower]]
        }
        if {$angle < 360} {
          lappend rim [list $x $y [my ColorFontPaintAt $stops $offset upper]]
        }
      } else {
        lappend rim [list $x $y [my ColorFontPaintAt $stops \
            [expr {($angle - $start) / $turn}]]]
      }
    }
    # One triangle per wedge, each beginning a triangle of its own (edge flag
    # 0 three times, 8.7.4.5.5). See above for why they are not chained into
    # a fan.
    set vertices {}
    foreach inner [lrange $rim 0 end-1] outer [lrange $rim 1 end] {
      if {[lindex $inner 0] == [lindex $outer 0]
          && [lindex $inner 1] == [lindex $outer 1]} {
        # The two vertices of a step, which span no wedge at all. Writing the
        # zero-area triangle would be legal and paint nothing; leaving it out
        # keeps the vertex count honest.
        continue
      }
      lappend vertices [list $cx $cy \
          [my ColorFontPaintMean [lindex $inner 2] [lindex $outer 2]] 0] \
          [linsert $inner end 0] [linsert $outer end 0]
    }
    return [my ColorFontPaintMesh $context $vertices $cover]
  }

  # -- writing the shading ---------------------------------------------------

  # The four corners of a box, as points.
  method ColorFontPaintCorners {box} {
    lassign $box x0 y0 x1 y1
    return [list [list $x0 $y0] [list $x1 $y0] [list $x1 $y1] [list $x0 $y1]]
  }

  # An axial or radial shading, painted through the current clip.
  #
  # The geometry arrives in the words shading.tcl uses for it, and a -matrix
  # goes with it - not because anything is transformed, but because that is
  # what tells [ShadingCoords] the numbers are ALREADY in the space of the
  # stream. Without it they would go through [coords], which converts document
  # units to points and mirrors y against the page height; a glyph stream is
  # in font units and mirrors nothing, and the gradient would land somewhere
  # off the page - the same doubled-transform defect shading.tcl's own -matrix
  # exists to prevent inside an SVG drawing.
  method ColorFontPaintShading {context stops kind geometry cover} {
    lassign [my ColorFontPaintSpread $stops] positions colours alphas
    set options [dict merge [my ShadingDefaults $kind] $geometry \
        [list colors $colours stops $positions extend {1 1} \
            matrix [::tclpdf::geometry identity]]]
    # WHICH CONSTRUCTION CARRIES THE ALPHA, asked BEFORE anything is written -
    # the order the rest of this file keeps and for the same reason: a soft
    # mask written for a gradient that then turns out to band would be an
    # object no reader reaches and every validator counts. The claim on the
    # file's version comes after it for the same reason: a gradient that
    # paints nothing must not raise the version of a document that then holds
    # no gradient at all.
    set bands [my ColorFontPaintBands $kind $geometry $positions $alphas $cover]
    if {$bands eq "empty"} {
      return {}
    }
    my RequireVersion 1.3 "colour font gradient"
    set number [my ShadingObject $kind $options [dict get $context what]]
    set name [::tclpdf::pdfObj name [my ShadingResource $number]]
    if {$bands eq "mask"} {
      return "q\n[my ColorFontPaintAlpha $context $alphas $kind \
          [dict merge $options [list colors [lmap value $alphas {
            list gray $value
          }]]] $cover]$name sh\nQ\n"
    }
    return [my ColorFontPaintPour $context $bands $name]
  }

  # The bands one gradient's alpha becomes, as {increment clip} pairs: the
  # empty list for a colour line that needs no alpha at all, ONE pair with no
  # clip for one at a single alpha, the word "empty" for one that paints
  # nothing at all, and the word "mask" for one that cannot be banded and
  # falls back to the luminosity soft mask below.
  #
  # A single band's clip may in turn be the word "outside", which is a
  # radial's answer for a ring that lies wholly past the box - a THIRD thing
  # beside a clip and no clip, told apart in [ColorFontPaintPour]. Where
  # EVERY band answers that way the gradient paints nothing, and the answer
  # given here is "empty" rather than a list of bands to skip one by one.
  #
  # The arithmetic and the measurement behind it are colorFontBand.tcl's. What
  # is decided HERE is only which geometry each kind of gradient has - the
  # axis of a linear one, the two circles of a radial one - because that is
  # the part [shading] spells differently for each of them.
  method ColorFontPaintBands {kind geometry positions alphas cover} {
    set lowest [::tcl::mathfunc::min {*}$alphas]
    set highest [::tcl::mathfunc::max {*}$alphas]
    if {$lowest >= 1} {
      return {}
    }
    if {$highest <= 0} {
      # EVERY STOP FULLY TRANSPARENT, which is the gradient's form of the
      # answer [ColorFontPaintFlat] gives a solid at alpha 0: the fill paints
      # nothing. Said here, before the caller writes anything, because the
      # shading object and the ExtGState would otherwise stand in the file
      # for a fill no reader can see - and because a graph that is nothing
      # but such fills is TCLPDF COLORFONT EMPTY, which is what the manual
      # promises for "every fill in it is fully transparent" and what a
      # gradient used to slip past.
      return empty
    }
    if {$lowest == $highest} {
      # One alpha over the whole colour line: one /ca and no clip at all, the
      # same resource a translucent version 0 layer takes.
      return [list [list $lowest {}]]
    }
    my RequireVersion 1.4 "colour font gradient"
    if {$kind eq "axial"} {
      set from [dict get $geometry from]
      set to [dict get $geometry to]
      lassign [::tclpdf::colorFontBand axis $from $to $cover] low high
      set plan [::tclpdf::colorFontBand plan $positions $alphas $low $high]
      if {$plan eq "mask"} {
        return mask
      }
      return [lmap layer $plan {
        list [lindex $layer 0] [::tclpdf::colorFontBand strips $from $to \
            $cover [lindex $layer 1]]
      }]
    }
    if {$kind eq "radial"} {
      set c0 [dict get $geometry focus]
      set r0 [dict get $geometry innerRadius]
      set c1 [dict get $geometry center]
      set r1 [dict get $geometry radius]
      set reach [::tclpdf::colorFontBand cone $c0 $r0 $c1 $r1 $cover]
      if {![llength $reach]} {
        # The two circles are not nested, so the region between two of the
        # family's circles is not a ring at all - see [colorFontBand cone].
        return mask
      }
      set plan [::tclpdf::colorFontBand plan $positions $alphas {*}$reach]
      if {$plan eq "mask"} {
        return mask
      }
      set bands [lmap layer $plan {
        list [lindex $layer 0] [::tclpdf::colorFontBand rings $c0 $r0 $c1 $r1 \
            $cover [lindex $layer 1]]
      }]
      foreach band $bands {
        if {[lindex $band 1] ne "outside"} {
          return $bands
        }
      }
      # EVERY RING PAST EVERY CORNER OF THE BOX, which is the radial's form of
      # the answer a fully transparent colour line gets above: the fill paints
      # nothing. Said HERE, before the shading object and the ExtGState are
      # written, and for the same two reasons - neither may stand in the file
      # for a fill no reader reaches, and a graph that is nothing but such
      # fills is TCLPDF COLORFONT EMPTY rather than a glyph written blank.
      return empty
    }
    return mask
  }

  # One shading painted through its bands: each clip NARROWS the one before it
  # rather than standing beside it, and each /ca adds the next step of alpha
  # on top of what is already there. colorFontBand.tcl says why they nest - in
  # one sentence, because two regions that merely abut seam along the edge
  # they share and two that nest do not.
  #
  # THE SAME SHADING EVERY TIME, and that is what makes the colour come out
  # right: a colour painted over itself is itself, so only the alpha
  # accumulates.
  #
  # EVEN-ODD, because a radial gradient's bands are rings and a ring is two
  # circles. A linear gradient's bands are disjoint rectangles, where the two
  # fill rules agree.
  method ColorFontPaintPour {context bands name} {
    if {![llength $bands]} {
      return "q\n$name sh\nQ\n"
    }
    foreach band $bands {
      if {[lindex $band 1] ni {{} outside}} {
        # A band with a clip of its own, which is the staircase; one band
        # with no clip is the single /ca a colour line of one alpha takes,
        # and one that says "outside" is no band at all - it is not painted.
        my ColorFontPaintCount $context bands
        break
      }
    }
    set body "q\n"
    foreach band $bands {
      lassign $band alpha path
      if {$path eq "outside"} {
        # THE BAND'S REGION DOES NOT MEET THE BOX AT ALL, which [colorFontBand
        # rings] answers in a word because an empty path cannot say it: "W* n"
        # needs a path to clip to, and a band that arrives with no path is the
        # single /ca of a colour line at one alpha - it would take the WHOLE
        # box. Skipped, so that a ring lying past every corner of the box
        # paints what it covers, which is nothing. The bands NEST, so every
        # later one lies inside this one and answers the same way.
        continue
      }
      if {$path ne {}} {
        append body $path "W*\nn\n"
      }
      append body "[::tclpdf::pdfObj name [my GraphicsOpacity $alpha fill]] gs\n"
      append body "$name sh\n"
    }
    return "${body}Q\n"
  }

  # The same for the fan of a sweep gradient, whose colours sit in its
  # vertices rather than in a colour line.
  method ColorFontPaintMesh {context vertices cover} {
    set options [dict merge [my ShadingDefaults triangles] \
        [list vertices [lmap vertex $vertices {
          lreplace $vertex 2 2 [lindex $vertex 2 1]
        }] matrix [::tclpdf::geometry identity]]]
    set alphas [lmap vertex $vertices {lindex $vertex 2 2}]
    set bands [my ColorFontPaintWedges $vertices]
    if {$bands eq "empty"} {
      return {}
    }
    my RequireVersion 1.3 "colour font gradient"
    set number [my ShadingObject triangles $options [dict get $context what]]
    set name [::tclpdf::pdfObj name [my ShadingResource $number]]
    if {$bands eq "mask"} {
      return "q\n[my ColorFontPaintAlpha $context $alphas triangles \
          [dict merge $options [list vertices [lmap vertex $vertices {
            lreplace $vertex 2 2 [list gray [lindex $vertex 2 2]]
          }]]] $cover]$name sh\nQ\n"
    }
    return [my ColorFontPaintPour $context $bands $name]
  }

  # The bands of a sweep gradient, which needs no geometry of its own: the fan
  # is ALREADY cut into wedges - at four degrees, at every colour stop and,
  # since [ColorFontPaintSweep] adds them, wherever the alpha crosses a band.
  # So a band is a run of neighbouring wedges, and the alpha of one wedge is
  # the alpha its centre vertex carries, which is the mean of the wedge's two
  # rim colours - the same mean the colour there is taken at.
  method ColorFontPaintWedges {vertices} {
    set alphas {}
    set wedges {}
    foreach {middle inner outer} $vertices {
      lappend alphas [lindex $middle 2 2]
      lappend wedges [list [lindex $inner 0] [lindex $inner 1] \
          [lindex $outer 0] [lindex $outer 1]]
    }
    set lowest [::tcl::mathfunc::min {*}$alphas]
    set highest [::tcl::mathfunc::max {*}$alphas]
    if {$lowest >= 1} {
      return {}
    }
    if {$highest <= 0} {
      # Every wedge fully transparent - see [ColorFontPaintBands].
      return empty
    }
    if {$lowest == $highest} {
      return [list [list $lowest {}]]
    }
    my RequireVersion 1.4 "colour font gradient"
    set plan [::tclpdf::colorFontBand cells $alphas]
    if {$plan eq "mask"} {
      return mask
    }
    return [lmap layer $plan {
      list [lindex $layer 0] [::tclpdf::colorFontBand sectors \
          [lrange [lindex $vertices 0] 0 1] $wedges [lindex $layer 1]]
    }]
  }

  # The stops of a colour line, split into the three lists a shading takes and
  # the one it cannot: positions, colour specs, and the alpha values.
  #
  # The positions are normalised to 0..1 here, which is what the geometry
  # handed to [ColorFontPaintShading] was already adjusted for: a PDF shading
  # runs its function over the unit interval and puts stop offset 0 at one end
  # of its coordinates and 1 at the other, while a COLR colour line may span
  # any interval at all - 14419 of Noto Color Emoji's 18471 lines span
  # something other than exactly 0 to 1, measured, so this is the ordinary
  # case rather than the exception. The standard names the same construction
  # ("normalize the color line to the interval [0, 1] ... deriving alternate
  # geometric points").
  method ColorFontPaintSpread {stops} {
    set first [lindex $stops 0 0]
    set span [expr {[lindex $stops end 0] - $first}]
    set positions {}
    set colours {}
    set alphas {}
    set previous -1
    foreach stop $stops {
      lassign $stop offset spec alpha
      set at [expr {$span > 0 ? ($offset - $first) / double($span) : 0.0}]
      # Two stops at one offset are legal in the table and are a STEP in the
      # colour line; PDF's stitching function needs its bounds to increase
      # strictly (7.10.4), so the second of a pair is nudged by the smallest
      # step a PDF real can hold (7.3.3, five decimals). What comes out is the
      # step the font asked for, drawn over a hundred-thousandth of the axis.
      if {$at <= $previous} {
        set at [expr {$previous + 0.00001}]
      }
      if {$at > 1.0} {
        set at 1.0
      }
      set previous $at
      lappend positions $at
      lappend colours $spec
      lappend alphas $alpha
    }
    # AND A PASS BACK DOWN, because the one above can only push UP and the
    # axis ends at 1. Two stops sharing the HIGHEST offset - a hard step at
    # the end of a colour line, which the format allows - both landed on 1.0
    # and the shading was then refused for bounds that do not increase
    # (TCLPDF SHADING STOPS order), which is a legal font turned into an
    # error. Pushed down instead, the boundary moves by a hundred-thousandth
    # of the axis. It cannot cascade to the first stop: that would need every
    # stop at one offset, and a colour line of no length never reaches here.
    for {set index [expr {[llength $positions] - 2}]} {$index >= 0} {
        incr index -1} {
      if {[lindex $positions $index] >= [lindex $positions $index+1]} {
        lset positions $index \
            [expr {[lindex $positions $index+1] - 0.00001}]
      }
    }
    return [list $positions $colours $alphas]
  }

  # The alpha of a gradient THAT CANNOT BE BANDED, which is the fallback and
  # no longer the construction: since 40b9899a3b a colour line whose stops
  # carry different alphas is painted as nested bands of constant alpha
  # ([ColorFontPaintBands] and colorFontBand.tcl), and this is what is left
  # where the bands cannot be built - a radial gradient whose two circles are
  # not nested, a colour line needing more than 256 clip intervals, and a fan
  # whose wedges do the same. Measured over Noto Color Emoji: 7894 of its 7894
  # radial gradients with a varying alpha ARE nested, so of the 8730 colour
  # lines whose alpha varies the mask keeps none by this road.
  #
  # The mask's own content is the same shading geometry in DeviceGray with the
  # alpha values as grey levels, drawn into a transparency group; the group's
  # luminosity is then the alpha of everything painted under the "gs". It is
  # exact, and it is the one construction in this file that two readers get
  # wrong - see the head of colorFontBand.tcl for which and how far.
  #
  # THE FIRST TWO BRANCHES CANNOT BE REACHED FROM HERE and stand for what
  # they say rather than for what they do: the two callers ask
  # [ColorFontPaintBands] or [ColorFontPaintWedges] first and arrive only with
  # the word "mask", which neither of them says for an alpha that is opaque or
  # constant throughout. Left in place because this method answers "the alpha
  # of a gradient" and a caller reading it should not have to know the order
  # of the two. A colour line that is transparent from end to end has no
  # branch here at all: it is not an alpha to establish but a fill that paints
  # nothing, and it is answered as such one level up, before a shading object
  # exists to mask.
  method ColorFontPaintAlpha {context alphas kind options cover} {
    set lowest [::tcl::mathfunc::min {*}$alphas]
    set highest [::tcl::mathfunc::max {*}$alphas]
    if {$lowest >= 1} {
      return {}
    }
    if {$lowest == $highest} {
      return "[::tclpdf::pdfObj name [my GraphicsOpacity $lowest fill]] gs\n"
    }
    my RequireVersion 1.4 "colour font gradient"
    set number [my ShadingObject $kind $options [dict get $context what]]
    set content "q\n[my ColorFontPaintBox $cover]W\nn\n"
    append content \
        "[::tclpdf::pdfObj name [my ShadingResource $number]] sh\nQ\n"
    return "[::tclpdf::pdfObj name [my ColorFontPaintMask \
        [dict get $context alias] $content $cover]] gs\n"
  }

  # -- transparency groups ---------------------------------------------------

  # A form XObject holding glyph-space content, as a transparency group.
  # Returns its object number.
  #
  # WRITTEN HERE RATHER THAN THROUGH [form create], and the reason is the
  # space: that command takes a size in document units, runs a script through
  # the canvas stack and gives the form a BBox in points with y mirrored
  # against a page. These forms hold font units and no page, and their content
  # is a string that is already written. What is shared instead is the part
  # that matters - the group dictionary and the /Resources rule - and the
  # second of those is [Type3ResourcePairs], the same method that gives the
  # Type 3 font its own resources.
  #
  # THE RESOURCES ARE THE FORM'S OWN and never the document's shared
  # dictionary. A form inside a Type 3 glyph that pointed at the shared one
  # would point at a dictionary carrying that very font, and a validator
  # walking font -> XObject -> Resources -> Font -> font does not come back -
  # measured with veraPDF on the Type 3 font itself, which died with a
  # StackOverflowError and produced no report at all. PDF/A 6.2.2 wants an own
  # Resources here in any case.
  #
  # ISOLATED and NON-KNOCKOUT (I true, K false). Isolated is what makes a
  # blend mode inside the group blend against the group's own backdrop rather
  # than against the page under it, which is the whole point of using a group
  # for a PaintComposite; non-knockout is the ordinary stacking every layer of
  # a colour glyph wants.
  method ColorFontPaintForm {alias content box {group {S /Transparency I true K false}}} {
    lassign $box x0 y0 x1 y1
    return [my streamObject [list Type /XObject Subtype /Form FormType 1 \
        BBox [::tclpdf::pdfObj arr [lmap value [list $x0 $y0 $x1 $y1] {
          ::tclpdf::pdfObj num $value
        }]] \
        Group [::tclpdf::pdfObj dictionary $group] \
        Resources [::tclpdf::pdfObj dictionary \
            [my Type3ResourcePairs $alias [list $content]]]] $content]
  }

  # The same form, registered under a resource name so that it can be placed
  # with a "Do" - which is what a blend-mode group is for. A soft mask group
  # needs no name: an /SMask names its group by an indirect reference, and a
  # name in the document's XObject dictionary would be a resource nothing
  # mentions.
  method ColorFontPaintPlace {alias content box} {
    set resourceName XO[my FormCount]
    my resource XObject $resourceName \
        [[my writer] ref [my ColorFontPaintForm $alias $content $box]]
    return $resourceName
  }

  # An ExtGState carrying a LUMINOSITY soft mask: the group's brightness is
  # the alpha of whatever is painted under it.
  #
  # THE MASK IS IN THE SAME SPACE AS THE GLYPH, and that is the rule rather
  # than luck: "The mask's coordinate system shall be defined by concatenating
  # the transformation matrix specified by the Matrix entry in the
  # transparency group's form dictionary with the CURRENT TRANSFORMATION
  # MATRIX AT THE MOMENT THE SOFT MASK IS ESTABLISHED in the graphics state
  # with the gs operator" (11.6.5.1). The "gs" stands inside the glyph, under
  # the text matrix and the font matrix, so the mask travels with the letter -
  # the same property the "sh" of a gradient has and a shading pattern has
  # not. Had the rule been the other way about, a masked glyph would have been
  # right at one place on the page and wrong everywhere else.
  #
  # /BC [0] - black outside the group's box, so nothing outside it is painted.
  # The group states /CS /DeviceGray, which a luminosity mask must have (Table
  # 145: "the group shall have a colour space"), and which is also the space
  # the mask's own shading paints in.
  method ColorFontPaintMask {alias content box} {
    set name GM[my FormCount]
    my ColorFontPaintCount [dict create alias $alias] mask
    my resource ExtGState $name [[my writer] ref [[my writer] add \
        [::tclpdf::pdfObj dictionary [list Type /ExtGState \
            SMask [::tclpdf::pdfObj dictionary [list Type /Mask \
                S /Luminosity \
                G [[my writer] ref [my ColorFontPaintForm $alias $content \
                    $box {S /Transparency I true K false CS /DeviceGray}]] \
                BC [::tclpdf::pdfObj arr {0}]]]]]]]
    return $name
  }

  # -- compositing -----------------------------------------------------------

  # PaintComposite: two sub-graphs and a rule for combining them.
  #
  # FIVE OF THE TWENTY-EIGHT MODES ARE JUST AN ORDER - Clear paints nothing,
  # Source and Destination paint one side, Source Over and Destination Over
  # paint both in one order or the other - and those cost no machinery at all.
  #
  # FIFTEEN ARE PDF BLEND MODES under other names: the CompositeMode
  # enumeration's "separable" and "non-separable" halves are the fifteen of
  # ISO 32000-2, 11.3.5, and the standard says where they come from ("the
  # effect and processing rule of each mode are specified in Compositing and
  # Blending Level 1", which is where PDF's own definitions come from as
  # well). They are written as a /BM in an ExtGState - inside an ISOLATED
  # TRANSPARENCY GROUP holding both sides, because a blend mode blends against
  # everything already on the page and a composite is meant to blend against
  # its own backdrop only. Without the group a soft-light gradient over a
  # glyph would take the page's white into the calculation and come out pale.
  #
  # SEVEN ARE PORTER-DUFF MASKS. Source In is the source painted where the
  # backdrop is opaque, which in PDF is the source painted under an ALPHA soft
  # mask taken from the backdrop's group; Source Out is the same with the mask
  # inverted, which /TR does; and the other five are one or two of those in an
  # order. This is the branch Noto Color Emoji needs - 316 of its 578
  # composites are Source In - and it is the reason this file knows about soft
  # masks at all.
  #
  # ONE IS REFUSED: Plus adds the two colours and clamps, and PDF has no
  # additive blend mode and no construction that makes one.
  method ColorFontPaintComposite {node context} {
    variable ::tclpdf::colorFontPaint::blends
    set mode [dict get $node mode]
    set source [dict get $node source]
    set backdrop [dict get $node backdrop]
    switch -- $mode {
      clear {return {}}
      src {return [my ColorFontPaintNode $source $context]}
      dest {return [my ColorFontPaintNode $backdrop $context]}
      srcOver {return [my ColorFontPaintOver $context $backdrop $source]}
      destOver {return [my ColorFontPaintOver $context $source $backdrop]}
      plus {
        return -code error -errorcode [list TCLPDF COLORFONT COMPOSITE \
            [dict get $context alias] plus] \
            "tclpdf: a PaintComposite table of font\
            \"[dict get $context alias]\" asks for the Plus composite mode,\
            which adds the two colours and clamps the sum. PDF has fifteen\
            blend modes (ISO 32000-2, 11.3.5) and no additive one, and none\
            of the fifteen can be combined into it - so the glyph would come\
            out darker than the font says with nothing reporting it"
      }
    }
    if {[dict exists $blends $mode]} {
      return [my ColorFontPaintBlend $context $source $backdrop \
          [dict get $blends $mode]]
    }
    return [my ColorFontPaintPorterDuff $context $source $backdrop $mode]
  }

  # Two sub-graphs, the first one under the second. Each in its own bracket -
  # the lower one may set a colour or a clip that the upper one must not see.
  method ColorFontPaintOver {context lower upper} {
    set body {}
    foreach node [list $lower $upper] {
      set inner [my ColorFontPaintNode $node $context]
      if {$inner ne {}} {
        append body "q\n" $inner "Q\n"
      }
    }
    return $body
  }

  # A blend mode, applied to the source against the backdrop and against
  # nothing else. See [ColorFontPaintComposite] for why the group is not
  # optional.
  method ColorFontPaintBlend {context source backdrop mode} {
    set under [my ColorFontPaintNode $backdrop $context]
    set over [my ColorFontPaintNode $source $context]
    if {$over eq {}} {
      return $under
    }
    if {$under eq {}} {
      return $over
    }
    set cover [my ColorFontPaintCover $context]
    if {$cover eq {}} {
      return {}
    }
    my RequireVersion 1.4 "colour font composite"
    set content "q\n$under Q\nq\n"
    append content "[::tclpdf::pdfObj name [my GraphicsBlend $mode]] gs\n"
    append content "$over Q\n"
    return "[::tclpdf::pdfObj name [my ColorFontPaintPlace \
        [dict get $context alias] $content $cover]] Do\n"
  }

  # The seven Porter-Duff modes PDF has no operator for, each built out of one
  # or two alpha soft masks.
  #
  #   srcIn     the source where the backdrop is opaque
  #   srcOut    the source where the backdrop is NOT
  #   destIn    the backdrop where the source is opaque
  #   destOut   the backdrop where the source is NOT
  #   srcAtop   the backdrop, then the source where the backdrop is opaque
  #   destAtop  the source, then the backdrop where the source is opaque
  #   xor       each side where the other is not
  method ColorFontPaintPorterDuff {context source backdrop mode} {
    set cover [my ColorFontPaintCover $context]
    if {$cover eq {}} {
      return {}
    }
    my RequireVersion 1.4 "colour font composite"
    set alias [dict get $context alias]
    set under [my ColorFontPaintNode $backdrop $context]
    set over [my ColorFontPaintNode $source $context]
    # The NODE the mask is taken from travels beside the operators it was
    # drawn into, because two shapes of mask need no mask at all and only the
    # node says which - see [ColorFontPaintMasked].
    switch -- $mode {
      srcIn {
        return [my ColorFontPaintMasked $context $over $under $backdrop \
            $cover 0]
      }
      srcOut {
        return [my ColorFontPaintMasked $context $over $under $backdrop \
            $cover 1]
      }
      destIn {
        return [my ColorFontPaintMasked $context $under $over $source $cover 0]
      }
      destOut {
        return [my ColorFontPaintMasked $context $under $over $source $cover 1]
      }
      srcAtop {
        return [my ColorFontPaintAtop $context srcAtop $under $over \
            $backdrop $cover]
      }
      destAtop {
        return [my ColorFontPaintAtop $context destAtop $over $under \
            $source $cover]
      }
      xor {
        # BOTH sides mask here, so both have to be sharp - see
        # [ColorFontPaintAtop] for what the word means and why a side that is
        # anything else is refused rather than approximated.
        foreach {side body} [list $source $over $backdrop $under] {
          if {$body ne {} && ![my ColorFontPaintSharp $side $context]} {
            my ColorFontPaintTranslucent $context xor
          }
        }
        return "[my ColorFontPaintMasked $context $under $over $source $cover \
            1][my ColorFontPaintMasked $context $over $under $backdrop $cover \
            1]"
      }
    }
    return -code error -errorcode [list TCLPDF COLORFONT COMPOSITE $alias \
        $mode] "tclpdf: unknown composite mode \"$mode\""
  }

  # SOURCE ATOP and DESTINATION ATOP, which are the two modes whose formula
  # PDF's own compositing does NOT produce once the masking side is half
  # transparent.
  #
  # W3C Compositing and Blending 1, 9.1, which the standard names as the
  # definition of the modes: Source Atop is
  #
  #     Co = as x Cs x ab + ab x Cb x (1 - as),   ao = ab
  #
  # - the source where the backdrop is, the backdrop showing through by
  # (1 - as) and the result carrying the backdrop's own alpha. Painting the
  # backdrop and then the source under an alpha soft mask taken from it gives
  # as x ab x Cs + ab x Cb x (1 - as x ab) instead, because the mask multiplies
  # the source's alpha rather than restricting the composite: the two agree
  # exactly where ab is 0 or 1 and nowhere else. Measured 2026-08-26 against
  # hb-view at 400 dpi with a backdrop at alpha 0.5: (159, 113, 95) where the
  # formula asks for (223, 127, 159), and the green of the backdrop showing
  # through a source that should have covered it.
  #
  # SO THERE ARE THREE CASES AND THE THIRD IS A REFUSAL:
  #
  #   - THE MASKING SIDE IS SHARP - its alpha is 0 or 1 and nothing between,
  #     which is what a stack of opaque outlines is. Then the two formulas
  #     agree and the construction above is exact. This is every "atop" a
  #     colour face is likely to hold.
  #   - THE MASKING SIDE IS ONE LEVEL - one colour at ONE alpha over one
  #     region, which a PaintSolid is over the whole clip and a PaintGlyph
  #     over a solid is inside its outline. Then ab is a constant c inside
  #     that region and 0 outside it, and Co / ao is Cs x as + Cb x (1 - as):
  #     the two sides composited the ordinary way with the backdrop taken as
  #     OPAQUE, the whole of it at /ca c and clipped to the region. That is a
  #     group, a "gs" and a "W n", and it is the formula exactly rather than
  #     near it.
  #   - ANYTHING ELSE IS REFUSED, by name, the way Plus is. Written exactly it
  #     needs a knockout group whose backdrop is the other side, which PDF
  #     cannot build inside a glyph description; written the plain way it is a
  #     picture that differs from what the font says with nothing reporting
  #     it, which is the one outcome this file exists to prevent. Measured:
  #     Noto Color Emoji uses two composite modes in its 578 PaintComposite
  #     tables, Source In and Soft Light, and neither of these three is one of
  #     them.
  method ColorFontPaintAtop {context mode mask masked node cover} {
    if {$mask eq {}} {
      # The masking side paints nothing, so its alpha is 0 everywhere: both
      # formulas come out at nothing at all.
      return {}
    }
    if {[my ColorFontPaintSharp $node $context]} {
      return "q\n$mask Q\n[my ColorFontPaintMasked $context $masked $mask \
          $node $cover 0]"
    }
    set level [my ColorFontPaintLevel $node $context]
    if {![llength $level]} {
      my ColorFontPaintTranslucent $context $mode
    }
    lassign $level alpha spec region
    # The masking side OPAQUE and the other side over it: that is Co / ao,
    # and the /ca below turns it into Co and ao together.
    set content "q\n[my ColorFontPaintFlat $context $spec 1.0]Q\n"
    if {$masked ne {}} {
      append content "q\n$masked Q\n"
    }
    set body "q\n"
    if {$region ne {}} {
      append body $region "W\nn\n"
    }
    if {$alpha < 1} {
      append body "[::tclpdf::pdfObj name [my GraphicsOpacity $alpha fill]] gs\n"
    }
    append body "[::tclpdf::pdfObj name [my ColorFontPaintPlace \
        [dict get $context alias] $content $cover]] Do\nQ\n"
    return $body
  }

  # The refusal the three Porter-Duff modes that composite BOTH sides share.
  # Its code is the one Plus takes, because it is the same answer for the same
  # reason: PDF has no construction for this mode over this backdrop, and a
  # picture that differs from the font with nothing reporting it is not an
  # answer.
  method ColorFontPaintTranslucent {context mode} {
    return -code error -errorcode [list TCLPDF COLORFONT COMPOSITE \
        [dict get $context alias] $mode] \
        "tclpdf: a PaintComposite table of font\
        \"[dict get $context alias]\" asks for the $mode composite mode over a\
        side that is neither opaque nor one constant alpha inside one\
        outline. W3C Compositing and Blending 1, 9.1 - which ISO/IEC 14496-22\
        names as the definition of the mode - keeps the backdrop's own alpha\
        in the result, and PDF composites source OVER backdrop, which\
        multiplies the two: the two agree only where the masking side's alpha\
        is nought or one. Writing it anyway would draw a glyph that differs\
        from what the font says with nothing reporting it"
  }

  # Whether a sub-graph's ALPHA is SHARP - 1 where it paints and 0 where it
  # does not, with nothing in between.
  #
  # NOT THE QUESTION [ColorFontPaintBinary] ANSWERS, although the two look
  # alike: that one asks whether the region can be written as a CLIP PATH and
  # says no to a stack whose outlines wind against each other or whose sheer
  # shapes stick out, while this one asks only what the alpha IS. An alpha
  # soft mask taken from such a stack carries that alpha exactly whether or
  # not a clip could have been built from it, so the modes below turn on this
  # question and not on the other.
  method ColorFontPaintSharp {node context} {
    switch -- [dict get $node paint] {
      solid {
        set alpha [my ColorFontPaintOpacity $node $context \
            [dict get $node palette] [dict get $node alpha]]
        return [expr {$alpha <= 0 || $alpha >= 1}]
      }
      linear - radial - sweep {
        # ALL the stops opaque or ALL of them transparent, and not merely
        # every stop at one end or the other: a colour line running from
        # alpha 0 to alpha 1 has every value between them along its axis,
        # which is the fade this whole file is built around.
        set alphas [lmap stop [dict get $node line stops] {
          my ColorFontPaintOpacity $node $context [lindex $stop 1] \
              [lindex $stop 2]
        }]
        if {![llength $alphas]} {
          return 1
        }
        return [expr {[::tcl::mathfunc::min {*}$alphas] >= 1
            || [::tcl::mathfunc::max {*}$alphas] <= 0}]
      }
      glyph {
        # The outline is a clip, and clipping an alpha of 0 and 1 leaves an
        # alpha of 0 and 1.
        return [my ColorFontPaintSharp [dict get $node child] $context]
      }
      transform {
        if {[::tclpdf::geometry singular [dict get $node matrix]]} {
          return 1
        }
        return [my ColorFontPaintSharp [dict get $node child] $context]
      }
      layers {
        # One sharp layer over another is sharp: the union of two regions of
        # alpha 1 is a region of alpha 1.
        foreach child [dict get $node children] {
          if {![my ColorFontPaintSharp $child $context]} {
            return 0
          }
        }
        return 1
      }
    }
    # A PaintComposite, whose alpha is the two sides' composited - answered
    # NO rather than worked out, because the answer would have to repeat the
    # whole of [ColorFontPaintComposite] to get it right and the modes below
    # are refused for a side they cannot write exactly in any case.
    return 0
  }

  # One fill's alpha with the palette entry's own multiplied in - the two
  # places an alpha comes from, in one line, so that a caller asking "how
  # opaque is this" cannot forget the second.
  method ColorFontPaintOpacity {node context entry alpha} {
    set colour [::tclpdf::colr color [dict get $context state] \
        [dict get $context palette] $entry]
    if {$colour eq {}} {
      return $alpha
    }
    return [expr {$alpha * [lindex $colour 1]}]
  }

  # A sub-graph that paints ONE colour at ONE alpha over ONE region, as
  # {alpha spec path}: the empty path means the whole clip, which is what an
  # unbounded fill covers. The empty list for anything else.
  #
  # TWO SHAPES QUALIFY and no more, because the question is where the alpha is
  # CONSTANT and not merely where it is known: two translucent outlines that
  # overlap compose to 1 - (1-a)(1-a) in the overlap and are three levels
  # rather than one, and asking which pairs overlap is the region arithmetic
  # colorFontRegion.tcl does for the union - a different question with a
  # different answer.
  method ColorFontPaintLevel {node context} {
    set fill [my ColorFontPaintFill $node $context]
    if {[llength $fill]} {
      return [list {*}$fill {}]
    }
    set shapes [my ColorFontPaintShapes $node $context \
        [::tclpdf::geometry identity]]
    if {[llength $shapes] != 1 || [llength [lindex $shapes 0]] != 4} {
      return {}
    }
    set contours [my ColorFontPaintContours $context [lindex $shapes 0]]
    if {$contours eq "composite" || ![llength $contours]} {
      return {}
    }
    return [list [lindex $shapes 0 2] [lindex $shapes 0 3] \
        [::tclpdf::glyfPath render $contours]]
  }

  # One side painted under an ALPHA soft mask taken from the other.
  #
  # "inverted" turns the mask over with a /TR transfer function, which is what
  # separates Source In from Source Out: a two-operator PostScript calculator,
  # {1 exch sub}, written through the same [FunctionCalculator] a type 4
  # shading uses and pooled with it, so a glyph using both directions carries
  # one function object rather than two.
  #
  # AND THE TRANSFER FUNCTION REACHES BEYOND THE BOX, which is what makes
  # "out" work at all: "Outside the bounding box of the transparency group,
  # the mask value shall be the result of applying the transfer function to
  # the input value 0.0" (11.6.5.1). So where the backdrop's group does not
  # reach, an uninverted mask is 0 - nothing of the source shows, which is
  # Source In - and an inverted one is 1 - all of it shows, which is Source
  # Out. Neither needs a rule of its own.
  method ColorFontPaintMasked {context content group node cover inverted} {
    if {$content eq {}} {
      return {}
    }
    set alias [dict get $context alias]
    if {$group eq {}} {
      # Nothing to take a mask from. An empty backdrop is transparent
      # everywhere: "in" it draws nothing, "out" of it draws everything.
      #
      # An "if" and not an [expr] ternary, although the ternary held: a
      # content stream is DATA, and expr parses what it is handed - the trap
      # that once turned a glyph named "infinity" into Inf.
      if {$inverted} {
        return "q\n$content Q\n"
      }
      return {}
    }
    if {!$inverted} {
      # TWO SHAPES OF MASK NEED NO MASK, and both of them are exact rather
      # than close. Worth having for the same reason the bands of a gradient
      # are: a soft mask inside a Type 3 glyph is the one construction here
      # that readers disagree about (colorFontBand.tcl says which and how),
      # and a clip or a /ca is read the same way by all of them.
      #
      # Only the UNINVERTED direction. "Out" is the complement of the mask,
      # and the complement of a clip path is not a clip path.
      set flat [my ColorFontPaintUniform $node $context]
      if {$flat ne {}} {
        # A mask side that paints the whole clip at ONE alpha - a PaintSolid,
        # which is 54 of Noto Color Emoji's 316 Source In tables, measured,
        # and every one of them at an alpha below 1. "In" such a mask is the
        # source at that constant alpha, and the group is what makes the /ca
        # apply to the source's RESULT rather than to each of its fills.
        set placed [::tclpdf::pdfObj name [my ColorFontPaintPlace $alias \
            "q\n$content Q\n" $cover]]
        my ColorFontPaintCount $context constant
        if {$flat >= 1} {
          return "q\n$placed Do\nQ\n"
        }
        return "q\n[::tclpdf::pdfObj name [my GraphicsOpacity $flat fill]]\
            gs\n$placed Do\nQ\n"
      }
      set outline [my ColorFontPaintBinary $node $context]
      if {$outline ne {}} {
        # A mask side whose alpha is BINARY - 1 inside a set of outlines and
        # 0 outside them. "In" such a mask is a CLIP PATH and nothing more.
        # Which stacks qualify, and why the union of several outlines is a
        # question rather than a concatenation, is [ColorFontPaintBinary].
        #
        # No group either: a clip applies to every fill of the source
        # separately and to their result alike, which a soft mask does not -
        # that is why the masked case below needs one and this does not.
        my ColorFontPaintCount $context clip
        return "q\n$outline W\nn\n$content Q\n"
      }
    }
    set pairs [list Type /Mask S /Alpha \
        G [[my writer] ref [my ColorFontPaintForm $alias "q\n$group Q\n" \
            $cover]]]
    if {$inverted} {
      lappend pairs TR [[my writer] ref \
          [my FunctionCalculator {0 1} {0 1} {1 exch sub}]]
    }
    set name GA[my FormCount]
    my ColorFontPaintCount $context mask
    my resource ExtGState $name [[my writer] ref [[my writer] add \
        [::tclpdf::pdfObj dictionary [list Type /ExtGState \
            SMask [::tclpdf::pdfObj dictionary $pairs]]]]]
    # AND THE MASKED SIDE GOES INTO A TRANSPARENCY GROUP OF ITS OWN, which is
    # not tidiness: PDF does not COMPOSE soft masks, it REPLACES them. The
    # graphics state holds ONE /SMask, "a soft-mask dictionary ... or the
    # name None" (11.6.4), so a "gs" anywhere inside $content that sets a
    # mask of its own throws this one away and the Porter-Duff mode silently
    # does not happen. And $content sets one whenever it holds a gradient
    # that cannot be banded ([ColorFontPaintAlpha]) or a nested composite -
    # neither of them exotic. Inside a group the soft mask starts out as
    # None again ("the current soft mask shall be initialised to None",
    # 11.6.6) and the mask established out here applies to the group's
    # RESULT, which is what a Porter-Duff mode means in the first place.
    # Measured 2026-08-26: without the group, a Source In whose source was a
    # fading gradient drew the whole source instead of the intersection.
    #
    # The same construction [ColorFontPaintBlend] uses for the blend modes,
    # and for the neighbouring reason - there, isolation; here, the mask.
    return "q\n[::tclpdf::pdfObj name $name] gs\n[::tclpdf::pdfObj name \
        [my ColorFontPaintPlace $alias "q\n$content Q\n" $cover]] Do\nQ\n"
  }

  # The one alpha a sub-graph paints the WHOLE clip at, or the empty string
  # where it paints anything else. A PaintSolid is the case: it is unbounded
  # by definition, so it covers whatever clip it stands in, and its alpha is
  # a number in the table. A transform over one changes where it paints and
  # not that it paints everywhere.
  #
  # A gradient is deliberately NOT here even when all its stops share one
  # alpha: a radial gradient leaves the far side of its cone unpainted, and
  # "unbounded" for the bounds of a graph is not the same promise as "covers
  # every pixel of the clip".
  method ColorFontPaintUniform {node context} {
    return [lindex [my ColorFontPaintFill $node $context] 0]
  }

  # The same fill as {alpha spec}, which is what a caller that has to REPAINT
  # it needs - see [ColorFontPaintAtop], where the masking side is drawn once
  # more at full opacity inside a group. The spec is the empty string for the
  # 0xFFFF sentinel, exactly as [ColorFontPaintFlat] takes it.
  method ColorFontPaintFill {node context} {
    switch -- [dict get $node paint] {
      transform {
        if {[::tclpdf::geometry singular [dict get $node matrix]]} {
          return {}
        }
        return [my ColorFontPaintFill [dict get $node child] $context]
      }
      solid {
        set alpha [dict get $node alpha]
        set spec {}
        set colour [::tclpdf::colr color [dict get $context state] \
            [dict get $context palette] [dict get $node palette]]
        if {$colour ne {}} {
          set alpha [expr {$alpha * [lindex $colour 1]}]
          set spec [my ColorFontPaintSpec [lindex $colour 0]]
        }
        if {$alpha <= 0} {
          return {}
        }
        return [list $alpha $spec]
      }
    }
    return {}
  }

  # The clip path of a sub-graph whose alpha is BINARY - 1 inside a set of
  # outlines and 0 outside them - as path operators, or the empty string
  # where it is anything else. This is what turns a Source In into a clip.
  #
  # TWO KINDS OF STACK QUALIFY, and the second one is the flags.
  #
  #   - outlines filled OPAQUE and nothing else. Alpha 1 inside their union,
  #     0 outside it, and nothing in between.
  #   - the same with TRANSLUCENT shapes laid over them, PROVIDED each of
  #     those lies inside the opaque union. Then the alpha is still 1 there
  #     and still 0 outside, because outside the union there is nothing left
  #     to be translucent. Measured over Noto Color Emoji's 316 Source In
  #     tables: 250 are of this shape - the shimmer on a waving flag - and
  #     rendered at 300 dpi, 227 of the 250 shapes do lie inside.
  #
  # A shape that sticks out keeps the soft mask. So does one whose outline
  # winds both ways, for the reason below. Over the 316: 54 take the constant
  # alpha above, 168 the clip here, 94 the mask - and of the 250, 166 reach
  # the clip, 20 stick out and 64 hold an outline that winds both ways.
  #
  # THE UNION OF SEVERAL OUTLINES IS THE HARD PART. "W n" takes ONE path and
  # two clips INTERSECT rather than unite, so the outlines go into one path
  # under the nonzero rule - and that is their union only while none of them
  # winds against another. Measured at 300 dpi: concatenating the 250 stacks
  # as they stand differs from the true union in 120 of them, by as much as
  # 1.8 million pixels of a 2133 by 2133 page. So each outline is asked which
  # way it winds and the ones that disagree with the first are turned round,
  # which leaves the area each of them fills exactly where it was; an outline
  # that winds BOTH ways cannot be brought into line and ends the attempt.
  # colorFontRegion.tcl holds that arithmetic and the measurements behind it.
  #
  # A SINGLE opaque outline skips all of it: one path is its own union.
  method ColorFontPaintBinary {node context} {
    set shapes [my ColorFontPaintShapes $node $context \
        [::tclpdf::geometry identity]]
    if {![llength $shapes]} {
      return {}
    }
    set opaque {}
    set sheer {}
    foreach shape $shapes {
      set contours [my ColorFontPaintContours $context $shape]
      if {$contours eq "composite"} {
        # A shape that draws other glyphs. [ColorFontPaintPath] refuses one
        # with an error where it is DRAWN, because there the glyph would come
        # out wrong; here it only means the clip cannot be built, and the
        # soft mask below draws the same picture.
        return {}
      }
      if {![llength $contours]} {
        # An outline the face has not got, or an empty one. It encloses no
        # area, so it changes neither the union nor what lies inside it.
        continue
      }
      if {[lindex $shape 2] >= 1} {
        lappend opaque $contours
      } else {
        lappend sheer $contours
      }
    }
    if {![llength $opaque]} {
      return {}
    }
    set union {}
    set body {}
    if {[llength $opaque] == 1} {
      set contours [lindex $opaque 0]
      if {[llength $sheer]} {
        set union [::tclpdf::colorFontRegion flatten $contours]
      }
      set body [::tclpdf::glyfPath render $contours]
    } else {
      set reference 0
      foreach contours $opaque {
        set polygons [::tclpdf::colorFontRegion flatten $contours]
        set sign [::tclpdf::colorFontRegion sign $polygons]
        if {$sign == 0} {
          return {}
        }
        if {$reference == 0} {
          set reference $sign
        } elseif {$sign != $reference} {
          set contours [::tclpdf::colorFontRegion reverse $contours]
          set polygons [::tclpdf::colorFontRegion flatten $contours]
        }
        if {[llength $sheer]} {
          lappend union {*}$polygons
        }
        append body [::tclpdf::glyfPath render $contours]
      }
    }
    foreach contours $sheer {
      if {![::tclpdf::colorFontRegion inside \
          [::tclpdf::colorFontRegion flatten $contours] $union]} {
        return {}
      }
    }
    return $body
  }

  # The leaf shapes of a sub-graph that is nothing but FILLED OUTLINES: a
  # list of {matrix glyph alpha}, bottom first, or the empty list where the
  # graph holds anything else - a gradient, a composite, a fill without an
  # outline around it.
  #
  # The matrix is the one the shape's own coordinates have to be written
  # through, and it starts at the identity because the operators of this
  # sub-graph are written in the space of the node it was called for. A
  # transform is BAKED INTO THE COORDINATES here rather than written as a
  # "cm": a clip path is one path, and a "cm" in the middle of it would move
  # the subpaths after it and not the ones before.
  method ColorFontPaintShapes {node context matrix} {
    switch -- [dict get $node paint] {
      layers {
        set shapes {}
        foreach child [dict get $node children] {
          set piece [my ColorFontPaintShapes $child $context $matrix]
          if {![llength $piece]} {
            return {}
          }
          lappend shapes {*}$piece
        }
        return $shapes
      }
      transform {
        if {[::tclpdf::geometry singular [dict get $node matrix]]} {
          return {}
        }
        return [my ColorFontPaintShapes [dict get $node child] $context \
            [::tclpdf::geometry multiply [dict get $node matrix] $matrix]]
      }
      glyph {
        set child [dict get $node child]
        if {[my ColorFontPaintOpaque $child $context]} {
          return [list [list $matrix [dict get $node glyph] 1]]
        }
        # A translucent shape carries its COLOUR as well, which is what
        # [ColorFontPaintLevel] needs and what tells the two apart: a shape
        # of three elements is opaque, one of four is at the alpha and in the
        # colour named in it.
        set fill [my ColorFontPaintFill $child $context]
        if {![llength $fill]} {
          return {}
        }
        return [list [list $matrix [dict get $node glyph] {*}$fill]]
      }
    }
    return {}
  }

  # The contours of one shape, through its own matrix: the shape
  # [::tclpdf::glyfPath contours] returns, the empty list for an outline the
  # face has not got, and the word "composite" for one that draws other
  # glyphs instead of an outline of its own.
  method ColorFontPaintContours {context shape} {
    lassign $shape matrix glyph alpha
    set outline [my ColorFontPaintOutline $context $glyph]
    if {![dict size $outline] || [dict get $outline type] eq "empty"} {
      return {}
    }
    if {[dict get $outline type] ne "simple"} {
      return composite
    }
    return [::tclpdf::glyfPath contours $outline \
        [list ::tclpdf::geometry apply $matrix]]
  }

  # Whether a sub-graph fills everything it is given, fully opaque. Only the
  # unbounded fills can: a shape inside it covers its own outline and not the
  # clip around it, which is why [ColorFontPaintBinary] asks this of a
  # PaintGlyph's CHILD and never of the PaintGlyph.
  method ColorFontPaintOpaque {node context} {
    switch -- [dict get $node paint] {
      solid {
        return [expr {[my ColorFontPaintOpacity $node $context \
            [dict get $node palette] [dict get $node alpha]] >= 1}]
      }
      transform {
        if {[::tclpdf::geometry singular [dict get $node matrix]]} {
          return 0
        }
        return [my ColorFontPaintOpaque [dict get $node child] $context]
      }
      layers {
        foreach child [dict get $node children] {
          if {[my ColorFontPaintOpaque $child $context]} {
            return 1
          }
        }
        return 0
      }
    }
    return 0
  }
}

package provide tclpdf::colorFontPaint 1.3
