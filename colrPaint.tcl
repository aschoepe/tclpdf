#
# tclpdf - PDF generation for Tcl
#
# colrPaint - the paint graph of COLR version 1
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# One topic, and a reading one, exactly as colr.tcl is: what version 1 of the
# COLR table says a base glyph LOOKS like. Nothing is drawn here, no PDF
# object is written, no outline is fetched - this module turns bytes into a
# tree of paint nodes and stops. colorFontPaint.tcl draws that tree.
#
# WHY IT IS NOT IN colr.tcl. Version 0 is two flat arrays of fixed width and
# has no recursion, no transform and no gradient; version 1 is a directed
# acyclic graph of thirty-two record formats with offsets inside offsets. The
# two share a table tag and nothing else - not a record, not a reader, not a
# failure mode - and a module holding both would hold two topics. colr.tcl
# reads the header, sees the version and hands the bytes here; a font that is
# version 0 never loads this file.
#
# THE SHAPE OF THE ANSWER. [paint] returns ONE tree per base glyph, in which
# every node is a dictionary with a "paint" key naming its kind:
#
#   layers      children {node ...}          bottom of the z-order first
#   solid       palette N alpha A
#   linear      line CL p0 {x y} p1 {x y} p2 {x y}
#   radial      line CL c0 {x y} r0 R c1 {x y} r1 R
#   sweep       line CL center {x y} start DEGREES end DEGREES
#   glyph       glyph N child NODE           the outline is a CLIP, not ink
#   transform   matrix {a b c d e f} child NODE
#   composite   mode NAME source NODE backdrop NODE
#
# and CL, a colour line, is {extend pad|repeat|reflect stops {{offset palette
# alpha} ...}} with the stops sorted by offset, which the format does not
# promise and the drawing rules require ("Color stops must be used in their
# stop offset order, which can be different from the order in which they are
# defined in the font").
#
# EIGHT KINDS FOR THIRTY-TWO FORMATS, and that collapse is the point of this
# module rather than a convenience:
#
#   - The sixteen Var formats (3, 5, 7, 9, 13, 15, 17, 19, 21, 23, 25, 27,
#     29, 31) carry the same fields as their twins plus a varIndexBase, an
#     index into an ItemVariationStore. tclpdf draws the DEFAULT INSTANCE of a
#     colour font - a Type 3 glyph is one drawing, and a drawing is one
#     instance - and at the default instance every delta is zero by
#     construction. So a Var paint is read as its twin and the varIndexBase is
#     read past. That is not an approximation: it is the default instance,
#     exactly. Measured on 2026-08-26 against Noto Color Emoji, the only real
#     version 1 face on this machine: itemVariationStoreOffset 0,
#     varIndexMapOffset 0, no fvar table, and not one Var paint among the
#     311486 paint nodes its 3993 colour glyphs are built from. That count is
#     VISITS over the trees this module hands back, one walk per base glyph -
#     so a paint table reached from two base glyphs is counted twice, and a
#     component named by PaintColrGlyph is counted once per use, because it is
#     expanded in place (see below). It is the number of paints the drawing
#     side ever sees, which is what the sentence above is about.
#   - The twenty transformation formats (12 to 31) are a translation, a scale,
#     a rotation, a skew or a matrix, each optionally about a centre. Every
#     one of them IS a matrix, and turning the angle into one here means the
#     drawing side has a single case and a single "cm" - a rotation about a
#     centre spelled as three matrices would otherwise be spelled twice, once
#     here and once there.
#   - PaintColrGlyph (11) names another base glyph and is EXPANDED in place,
#     so the tree the drawing side walks has no reference left in it. The
#     price is that a component used twenty times is read twenty times; the
#     alternative - a node that says "go and look there" - moves the cycle
#     guard into the drawing module, where the second copy of it would be.
#
# THE CYCLE, and why it is a guard rather than a depth limit. PaintColrLayers
# and PaintColrGlyph reach their children INDIRECTLY - through an index into
# the LayerList and through a glyph id - so unlike every other link they are
# not forward offsets and can point back up the tree. A font whose glyph A is
# built from glyph B and whose glyph B is built from glyph A is well formed by
# every offset check there is and recurses until the stack ends. The spec
# names the algorithm ("Applications should track paint tables within a path
# in the graph"), and that is what [Node] does: the offsets on the current
# path are a set, and a repeat is a refusal.
#
# REFUSED BY NAME, all of it below TCLPDF COLR so that a caller trapping the
# version 0 reader traps this one too:
#
#   - a cycle (CYCLE), and a graph deeper than 64 (DEPTH). The measured depth
#     of Noto Color Emoji is 9.
#   - a paint format this reader does not know (PAINT). The specification says
#     an unknown format "should be ignored" and the rest of the glyph drawn.
#     This package refuses instead, and the reason is the one that runs through
#     it: what is ignored comes out as a glyph that is missing a piece, valid,
#     printable and unreported. A future minor version of COLR is a reason to
#     extend this module, not a reason to print half a symbol.
#   - a PaintColrGlyph naming a glyph the BaseGlyphList has not got (REUSE).
#   - a layer slice reaching past the LayerList (LAYERS), and any offset that
#     leaves the table (TRUNCATED) - the same two words colr.tcl uses.
#   - a composite mode outside its enumeration (COMPOSITE), and the three
#     smaller enumerations that have no class of their own - a colour line's
#     extend mode, a ClipList format, a ClipBox format (UNSUPPORTED). All of
#     them for the reason PAINT gives above; see [Unsupported] for why the
#     ClipList is named rather than skipped, although it is called an
#     optimisation.
#
# NOT READ, deliberately: the ItemVariationStore and the DeltaSetIndexMap (see
# above - the default instance needs neither), and the version 0 arrays of a
# version 1 header, which stay colr.tcl's business. A version 1 font may carry
# both, and then a glyph is looked for here first and there second.
#

package require Tcl 8.6.11-
package require tclpdf::otLayout 1.0-
package require tclpdf::geometry 1.0-

namespace eval ::tclpdf::colrPaint {
  namespace export {[a-z]*}
  namespace ensemble create

  # The palette entry index that names no palette entry but the current text
  # colour - the same sentinel version 0 has (ISO/IEC 14496-22, 5.7.11), and
  # it means the same thing in a PaintSolid and in a colour stop.
  variable foreground 0xFFFF

  # How deep a paint graph may go before it is called damaged rather than
  # deep. Noto Color Emoji measures 9; 64 is far enough above every shape a
  # designer draws and far below what a Tcl recursion survives.
  variable maximum 64

  # The composite modes of the standard, by their numbers (Format 32). The
  # names are the spelling of the W3C Compositing and Blending specification
  # the table points at, with the twelve Porter-Duff modes first and the
  # fifteen blend modes after them.
  variable modes {
    0 clear 1 src 2 dest 3 srcOver 4 destOver 5 srcIn 6 destIn 7 srcOut
    8 destOut 9 srcAtop 10 destAtop 11 xor 12 plus
    13 screen 14 overlay 15 darken 16 lighten 17 colorDodge 18 colorBurn
    19 hardLight 20 softLight 21 difference 22 exclusion 23 multiply
    24 hue 25 saturation 26 color 27 luminosity
  }

  # The three ways a colour line goes on outside its stops (Extend enum).
  variable extends {0 pad 1 repeat 2 reflect}
}

# Read the version 1 part of a COLR table.
#
# "colr" is the whole table as bytes and its header has already been seen to
# say version 1 - colr.tcl does that and is the only caller. What comes back
# is the state the other commands work on:
#
#   base      base glyph id -> offset of its root paint, in table order
#   layers    the LayerList as a list of paint offsets, index 0 first
#   clips     glyph id -> {xMin yMin xMax yMax}, only for glyphs that have one
#   variable  1 when the table carries an ItemVariationStore - see the head
#             of this file for what that does and does not change
#
# The paint graphs are NOT walked here. A colour font has thousands of base
# glyphs and a document asks for a handful; what this does is read the three
# index structures, which is 6 bytes per base glyph, 4 per layer and 7 per
# clip record - and check that they fit inside the table, so that [paint] can
# read without checking again.
proc ::tclpdf::colrPaint::build {colr} {
  set state {}
  if {[::tclpdf::otLayout damaged {set state [Header $colr]}]} {
    Truncated "an offset in its version 1 part points past its end"
  }
  return $state
}

# The base glyph ids that have a version 1 paint graph, in table order.
proc ::tclpdf::colrPaint::glyphs {state} {
  return [dict keys [dict get $state base]]
}

# Has this glyph a version 1 colour description?
proc ::tclpdf::colrPaint::has {state glyph} {
  return [dict exists $state base $glyph]
}

# The clip box of one glyph as {xMin yMin xMax yMax} in font units, or the
# empty string where the table gives none.
#
# It is a precomputed bound and nothing else: "If a clip box is provided for a
# color glyph, the color glyph is bounded, and no inspection of the Paint
# graph is required to determine boundedness." A drawer may use it as a
# clipping rectangle, and has to compute the bound itself where there is none.
proc ::tclpdf::colrPaint::clip {state glyph} {
  if {![dict exists $state clips $glyph]} {
    return {}
  }
  return [dict get $state clips $glyph]
}

# The paint tree of one base glyph. The empty string where the glyph has no
# version 1 description - an answer, not a failure, exactly as [colr layers]
# answers the empty list.
proc ::tclpdf::colrPaint::paint {state glyph} {
  if {![dict exists $state base $glyph]} {
    return {}
  }
  set tree {}
  set offset [dict get $state base $glyph]
  if {[::tclpdf::otLayout damaged {
        set tree [Node $state $offset [dict create $offset 1] 0]
      }]} {
    Truncated "a paint table of glyph $glyph reaches past its end"
  }
  return $tree
}

# --- the header and its three index structures -----------------------------

proc ::tclpdf::colrPaint::Header {colr} {
  set baseList [::tclpdf::otLayout u32 $colr 14]
  set layerList [::tclpdf::otLayout u32 $colr 18]
  set clipList [::tclpdf::otLayout u32 $colr 22]
  set store [::tclpdf::otLayout u32 $colr 30]
  if {$baseList == 0} {
    # A version 1 header whose BaseGlyphList offset is NULL. The table may
    # still carry version 0 records - a font is free to describe some glyphs
    # the old way and some the new - so this is not an error here; colr.tcl
    # is what decides whether the font has any colour glyphs at all.
    return [dict create colr $colr base {} layers {} clips {} \
        variable [expr {$store != 0}]]
  }
  set base {}
  set count [::tclpdf::otLayout u32 $colr $baseList]
  set length [string length $colr]
  if {$baseList + 4 + $count * 6 > $length} {
    Truncated "its BaseGlyphList announces $count records at offset\
        $baseList and the table is only $length bytes long"
  }
  for {set index 0} {$index < $count} {incr index} {
    set at [expr {$baseList + 4 + $index * 6}]
    # The paint offset is measured from the START OF THE BaseGlyphList, not
    # from the start of the table - one of the two bases in this format, and
    # the one a reader gets wrong without noticing, because for a table whose
    # list happens to sit at offset 34 the difference is 34 bytes of plausible
    # record.
    dict set base [::tclpdf::otLayout u16 $colr $at] \
        [expr {$baseList + [::tclpdf::otLayout u32 $colr [expr {$at + 2}]]}]
  }
  set layers {}
  if {$layerList != 0} {
    set count [::tclpdf::otLayout u32 $colr $layerList]
    if {$layerList + 4 + $count * 4 > $length} {
      Truncated "its LayerList announces $count layers at offset $layerList\
          and the table is only $length bytes long"
    }
    for {set index 0} {$index < $count} {incr index} {
      lappend layers [expr {$layerList + [::tclpdf::otLayout u32 $colr \
          [expr {$layerList + 4 + $index * 4}]]}]
    }
  }
  return [dict create colr $colr base $base layers $layers \
      clips [ClipList $colr $clipList] variable [expr {$store != 0}]]
}

# The ClipList: a run of glyph ids per box, so one box serves a range.
#
# AN UNKNOWN FORMAT IS REFUSED HERE TOO, and the argument that it need not be
# does not hold. A ClipList is called an optimisation ("precomputed clip
# boxes"), so skipping one looks free: the glyph is then bounded from its own
# outlines instead. But the two answers are not the same answer. A clip box
# is a CLIP - a graph that paints outside every outline in it is bounded by
# the box and unbounded without it, which is the difference between a drawn
# glyph and TCLPDF COLORFONT UNBOUNDED - and where both exist the box may be
# SMALLER than the outlines, so a piece the font meant to cut off would be
# drawn. A format this reader does not know is therefore a table from a later
# minor version and named as one, exactly as an unknown paint format is.
proc ::tclpdf::colrPaint::ClipList {colr offset} {
  if {$offset == 0} {
    return {}
  }
  set listFormat [expr {[::tclpdf::otLayout u16 $colr $offset] >> 8}]
  if {$listFormat != 1} {
    Unsupported "ClipList format" $listFormat "the ClipList at offset $offset" \
        "ISO/IEC 14496-22 defines format 1 alone"
  }
  set count [::tclpdf::otLayout u32 $colr [expr {$offset + 1}]]
  set length [string length $colr]
  if {$offset + 5 + $count * 7 > $length} {
    Truncated "its ClipList announces $count records at offset $offset and\
        the table is only $length bytes long"
  }
  set clips {}
  for {set index 0} {$index < $count} {incr index} {
    set at [expr {$offset + 5 + $index * 7}]
    set first [::tclpdf::otLayout u16 $colr $at]
    set last [::tclpdf::otLayout u16 $colr [expr {$at + 2}]]
    set box [expr {$offset + [Offset24 $colr [expr {$at + 4}]]}]
    # ClipBox format 1 is four FWORDs; format 2 adds a varIndexBase behind
    # them, which the default instance does not need. Both start with the
    # same four numbers, so both are read the same way, and an unknown format
    # is named for the reason the head of this proc gives.
    set format [expr {[::tclpdf::otLayout u16 $colr $box] >> 8}]
    if {$format != 1 && $format != 2} {
      Unsupported "ClipBox format" $format \
          "the ClipBox at offset $box, which bounds glyph $first" \
          "ISO/IEC 14496-22 defines formats 1 and 2"
    }
    set rectangle [list [::tclpdf::otLayout s16 $colr [expr {$box + 1}]] \
        [::tclpdf::otLayout s16 $colr [expr {$box + 3}]] \
        [::tclpdf::otLayout s16 $colr [expr {$box + 5}]] \
        [::tclpdf::otLayout s16 $colr [expr {$box + 7}]]]
    for {set glyph $first} {$glyph <= $last} {incr glyph} {
      dict set clips $glyph $rectangle
    }
  }
  return $clips
}

# --- one paint node --------------------------------------------------------

# "path" is the set of paint offsets on the way here, which is what makes a
# cycle a refusal instead of a stack overflow; "depth" bounds a graph that is
# acyclic and still absurd.
proc ::tclpdf::colrPaint::Node {state offset path depth} {
  variable maximum
  variable modes
  if {$depth > $maximum} {
    return -code error -errorcode [list TCLPDF COLR DEPTH $depth] \
        "tclpdf: a paint graph of the font's \"COLR\" table is more than\
        $maximum tables deep - a colour glyph is drawn from a few dozen\
        shapes, and a graph this deep is damaged rather than detailed"
  }
  set colr [dict get $state colr]
  set format [expr {[::tclpdf::otLayout u16 $colr $offset] >> 8}]
  switch -- $format {
    1 {
      # PaintColrLayers: a slice of the LayerList, bottom of the z-order
      # first. numLayers is ONE byte - the format's own note says so, "to
      # minimize size for common scenarios" - and firstLayerIndex is four.
      set count [expr {[::tclpdf::otLayout u16 $colr $offset] & 0xFF}]
      set first [::tclpdf::otLayout u32 $colr [expr {$offset + 2}]]
      set layers [dict get $state layers]
      if {$first + $count > [llength $layers]} {
        return -code error -errorcode [list TCLPDF COLR LAYERS v1 $first \
            $count [llength $layers]] \
            "tclpdf: a paint table of the font's \"COLR\" table asks for\
            $count layers from index $first, which runs past the\
            [llength $layers] the LayerList has"
      }
      set children {}
      for {set index 0} {$index < $count} {incr index} {
        lappend children [Child $state [lindex $layers $first+$index] $path \
            $depth]
      }
      return [dict create paint layers children $children]
    }
    2 - 3 {
      return [dict create paint solid \
          palette [::tclpdf::otLayout u16 $colr [expr {$offset + 1}]] \
          alpha [Alpha $colr [expr {$offset + 3}]]]
    }
    4 - 5 {
      return [dict create paint linear \
          line [ColorLine $state $offset [expr {$format == 5}]] \
          p0 [Point $colr [expr {$offset + 4}]] \
          p1 [Point $colr [expr {$offset + 8}]] \
          p2 [Point $colr [expr {$offset + 12}]]]
    }
    6 - 7 {
      return [dict create paint radial \
          line [ColorLine $state $offset [expr {$format == 7}]] \
          c0 [Point $colr [expr {$offset + 4}]] \
          r0 [::tclpdf::otLayout u16 $colr [expr {$offset + 8}]] \
          c1 [Point $colr [expr {$offset + 10}]] \
          r1 [::tclpdf::otLayout u16 $colr [expr {$offset + 14}]]]
    }
    8 - 9 {
      # The two angles are F2DOT14 and count 180 degrees per 1.0 - AND THEY
      # CARRY A BIAS OF 1.0, which the two angles of PaintRotate and
      # PaintSkew do not: degrees = (value + 1.0) x 180. F2DOT14 stops just
      # short of 2.0, so without the bias a two-byte field reaches 358 and a
      # full turn is not writable at all; with it the range is -180 to +360
      # and 360 is the top of it, which is why the format spends the bias
      # here and nowhere else. Counter clockwise from the positive x axis,
      # and the order of the two decides the direction the colour line runs
      # in - see the drawing module.
      #
      # Read WITHOUT the bias every sweep comes out turned by half a circle,
      # and nothing reports it: the gradient is still a gradient, still the
      # right colours, still round. Measured 2026-08-26 against hb-view at
      # 400 dpi on a sweep stored as 30 to 200 - the two pictures differ in
      # 196713 pixels of 128164 by more than 64 grey levels. fontTools calls
      # the type BiasedAngle for the same reason ("a bias of 1.0 ... to allow
      # for encoding +360deg") and HarfBuzz writes (startAngle + 1) * pi.
      return [dict create paint sweep \
          line [ColorLine $state $offset [expr {$format == 9}]] \
          center [Point $colr [expr {$offset + 4}]] \
          start [expr {([F2Dot14 $colr [expr {$offset + 8}]] + 1.0) * 180.0}] \
          end [expr {([F2Dot14 $colr [expr {$offset + 10}]] + 1.0) * 180.0}]]
    }
    10 {
      return [dict create paint glyph \
          glyph [::tclpdf::otLayout u16 $colr [expr {$offset + 4}]] \
          child [Child $state \
              [expr {$offset + [Offset24 $colr [expr {$offset + 1}]]}] \
              $path $depth]]
    }
    11 {
      # PaintColrGlyph: the graph of another base glyph, incorporated here.
      # Expanded rather than referenced - see the head of this file - and the
      # cycle guard is what makes that safe.
      set glyph [::tclpdf::otLayout u16 $colr [expr {$offset + 1}]]
      if {![dict exists $state base $glyph]} {
        return -code error -errorcode [list TCLPDF COLR REUSE $glyph] \
            "tclpdf: a paint table of the font's \"COLR\" table re-uses the\
            colour glyph of glyph $glyph, and the BaseGlyphList has no record\
            for it - the graph is not well formed"
      }
      return [Child $state [dict get $state base $glyph] $path $depth]
    }
    12 - 13 {
      # The Affine2x3 the offset points at stores xx, yx, xy, yy, dx, dy - in
      # that order, which IS the order of the six operands of "cm" (a b c d
      # e f). The one field order in this format that needs no rearranging.
      set at [expr {$offset + [Offset24 $colr [expr {$offset + 4}]]}]
      set matrix {}
      foreach index {0 1 2 3 4 5} {
        lappend matrix [Fixed $colr [expr {$at + $index * 4}]]
      }
      return [Transform $state $offset $matrix $path $depth]
    }
    14 - 15 {
      return [Transform $state $offset [::tclpdf::geometry translate \
          [::tclpdf::otLayout s16 $colr [expr {$offset + 4}]] \
          [::tclpdf::otLayout s16 $colr [expr {$offset + 6}]]] $path $depth]
    }
    16 - 17 {
      return [Transform $state $offset [::tclpdf::geometry scale \
          [F2Dot14 $colr [expr {$offset + 4}]] \
          [F2Dot14 $colr [expr {$offset + 6}]]] $path $depth]
    }
    18 - 19 {
      return [Transform $state $offset [About $colr [expr {$offset + 8}] \
          [::tclpdf::geometry scale [F2Dot14 $colr [expr {$offset + 4}]] \
              [F2Dot14 $colr [expr {$offset + 6}]]]] $path $depth]
    }
    20 - 21 {
      return [Transform $state $offset [::tclpdf::geometry scale \
          [F2Dot14 $colr [expr {$offset + 4}]]] $path $depth]
    }
    22 - 23 {
      return [Transform $state $offset [About $colr [expr {$offset + 6}] \
          [::tclpdf::geometry scale [F2Dot14 $colr [expr {$offset + 4}]]]] \
          $path $depth]
    }
    24 - 25 {
      return [Transform $state $offset [::tclpdf::geometry rotate \
          [expr {[F2Dot14 $colr [expr {$offset + 4}]] * 180.0}]] $path $depth]
    }
    26 - 27 {
      return [Transform $state $offset [About $colr [expr {$offset + 6}] \
          [::tclpdf::geometry rotate \
              [expr {[F2Dot14 $colr [expr {$offset + 4}]] * 180.0}]]] \
          $path $depth]
    }
    28 - 29 {
      return [Transform $state $offset [Skew $colr [expr {$offset + 4}]] \
          $path $depth]
    }
    30 - 31 {
      return [Transform $state $offset [About $colr [expr {$offset + 8}] \
          [Skew $colr [expr {$offset + 4}]]] $path $depth]
    }
    32 {
      set mode [expr {[::tclpdf::otLayout u16 $colr [expr {$offset + 3}]] & 0xFF}]
      if {![dict exists $modes $mode]} {
        # "If an unrecognized value is encountered, COMPOSITE_CLEAR must be
        # used" - and CLEAR paints nothing. All 28 values are known here, so
        # this is a value outside the enumeration.
        return -code error -errorcode [list TCLPDF COLR COMPOSITE $mode] \
            "tclpdf: a PaintComposite table of the font's \"COLR\" table\
            names composite mode $mode, and the CompositeMode enumeration\
            ends at 27"
      }
      return [dict create paint composite mode [dict get $modes $mode] \
          source [Child $state \
              [expr {$offset + [Offset24 $colr [expr {$offset + 1}]]}] \
              $path $depth] \
          backdrop [Child $state \
              [expr {$offset + [Offset24 $colr [expr {$offset + 5}]]}] \
              $path $depth]]
    }
  }
  return -code error -errorcode [list TCLPDF COLR PAINT $format] \
      "tclpdf: the font's \"COLR\" table uses paint format $format, which\
      tclpdf does not know - ISO/IEC 14496-22 defines formats 1 to 32. A\
      later minor version of the table may add more; drawing the rest of the\
      glyph and leaving this piece out would produce a symbol that is missing\
      something with nothing reporting it"
}

# One step down, with the cycle guard around it.
#
# The guard is HERE and not in [Node] so that the check is written once for
# every kind of link there is - the forward offset of a transform, the layer
# list index of a PaintColrLayers, the expanded graph of a PaintColrGlyph -
# and so that a node cannot be entered without it.
proc ::tclpdf::colrPaint::Child {state offset path depth} {
  if {[dict exists $path $offset]} {
    return -code error -errorcode [list TCLPDF COLR CYCLE $offset] \
        "tclpdf: the paint graph of the font's \"COLR\" table comes back to\
        the paint table at offset $offset, so it is a cycle rather than a\
        tree - a colour glyph that contains itself has no drawing"
  }
  dict set path $offset 1
  return [Node $state $offset $path [expr {$depth + 1}]]
}

# A transformation node: the child, and the matrix that applies to it.
proc ::tclpdf::colrPaint::Transform {state offset matrix path depth} {
  set colr [dict get $state colr]
  return [dict create paint transform matrix $matrix \
      child [Child $state \
          [expr {$offset + [Offset24 $colr [expr {$offset + 1}]]}] \
          $path $depth]]
}

# The same transformation, applied about a centre rather than about the
# origin: move the centre to the origin, transform, move it back.
proc ::tclpdf::colrPaint::About {colr offset matrix} {
  set x [::tclpdf::otLayout s16 $colr $offset]
  set y [::tclpdf::otLayout s16 $colr [expr {$offset + 2}]]
  return [::tclpdf::geometry multiply \
      [::tclpdf::geometry multiply [::tclpdf::geometry translate \
          [expr {-$x}] [expr {-$y}]] $matrix] \
      [::tclpdf::geometry translate $x $y]]
}

# A skew, from the two angles the format stores. Both count 180 degrees per
# 1.0, as the rotation does.
#
# THE TWO ANGLES CROSS OVER, and that is the one line of this module a reader
# has to check rather than trust. The standard writes the equivalent matrix
# for x skew angle phi and y skew angle psi as xx = yy = 1, yx = tan(psi),
# xy = -tan(phi) - so in the six operands of "cm" (a b c d e f) the X angle
# governs c and the Y angle governs b, with a MINUS on the x one.
# [geometry skew] takes its two arguments the other way round - it returns
# {1 tan(alpha) tan(beta) 1 0 0}, alpha for b and beta for c - so alpha is
# the Y angle here and beta is the negated X angle. Written straight through,
# a skew comes out mirrored through the diagonal and nothing reports it.
proc ::tclpdf::colrPaint::Skew {colr offset} {
  return [::tclpdf::geometry skew \
      [expr {[F2Dot14 $colr [expr {$offset + 2}]] * 180.0}] \
      [expr {-[F2Dot14 $colr $offset] * 180.0}]]
}

# --- colour lines ----------------------------------------------------------

# The ColorLine of a gradient paint, as {extend E stops {{offset palette
# alpha} ...}} with the stops in offset order.
#
# SORTED HERE, once, because the format does not promise an order and the
# drawing rules require one: "Color stops must be used in their stop offset
# order, which can be different from the order in which they are defined in
# the font." [lsort -real -index 0] is stable in Tcl, which is what keeps the
# other rule as well - where two stops share an offset, the first one given
# governs below it and the last one at and above it, and a stable sort leaves
# them in the order the font wrote them.
proc ::tclpdf::colrPaint::ColorLine {state offset varying} {
  variable extends
  set colr [dict get $state colr]
  set at [expr {$offset + [Offset24 $colr [expr {$offset + 1}]]}]
  set extend [expr {[::tclpdf::otLayout u16 $colr $at] >> 8}]
  if {![dict exists $extends $extend]} {
    # Not in the enumeration, and REFUSED rather than read as pad - the rule
    # this module keeps for an unknown paint format and an unknown composite
    # mode, and for the same reason. Pad is plausible and looks right, and a
    # gradient that should have repeated and did not is a picture missing a
    # piece: valid, printable and unreported. The enumeration has three
    # values and this reader knows all three, so no font written to the
    # present edition can reach it.
    Unsupported "extend mode" $extend "the ColorLine at offset $at" \
        "the ColorStopExtend enumeration ends at 2"
  }
  set count [::tclpdf::otLayout u16 $colr [expr {$at + 1}]]
  set width [expr {$varying ? 10 : 6}]
  set stops {}
  for {set index 0} {$index < $count} {incr index} {
    set record [expr {$at + 3 + $index * $width}]
    lappend stops [list [F2Dot14 $colr $record] \
        [::tclpdf::otLayout u16 $colr [expr {$record + 2}]] \
        [Alpha $colr [expr {$record + 4}]]]
  }
  return [dict create extend [dict get $extends $extend] \
      stops [lsort -real -index 0 $stops]]
}

# --- the field types this format has and otLayout has not ------------------

# Offset24, three bytes big-endian. It exists in exactly one table - the
# offsets INSIDE a paint graph are three bytes wide to keep the graph small -
# which is why it is read here rather than in otLayout.tcl.
proc ::tclpdf::colrPaint::Offset24 {bytes offset} {
  return [expr {([::tclpdf::otLayout u16 $bytes $offset] << 8)
      | ([::tclpdf::otLayout u16 $bytes [expr {$offset + 1}]] & 0xFF)}]
}

# F2DOT14: a signed 16-bit fixed-point number with 14 fraction bits, so the
# range is -2.0 to just under 2.0.
proc ::tclpdf::colrPaint::F2Dot14 {bytes offset} {
  return [expr {[::tclpdf::otLayout s16 $bytes $offset] / 16384.0}]
}

# Fixed: signed 16.16, the type an Affine2x3 stores its six numbers in.
proc ::tclpdf::colrPaint::Fixed {bytes offset} {
  return [expr {(([::tclpdf::otLayout s16 $bytes $offset] << 16)
      | [::tclpdf::otLayout u16 $bytes [expr {$offset + 2}]]) / 65536.0}]
}

# An alpha field, which is an F2DOT14 and therefore able to say 1.9 and -0.5.
# Held to 0..1, because an alpha outside it is not a value a compositor has a
# meaning for and PDF's /ca is defined over that interval (11.6.4.4).
proc ::tclpdf::colrPaint::Alpha {bytes offset} {
  set value [F2Dot14 $bytes $offset]
  return [expr {$value < 0 ? 0.0 : ($value > 1 ? 1.0 : $value)}]
}

# A point, two FWORDs in font units.
proc ::tclpdf::colrPaint::Point {bytes offset} {
  return [list [::tclpdf::otLayout s16 $bytes $offset] \
      [::tclpdf::otLayout s16 $bytes [expr {$offset + 2}]]]
}

# --- refusals --------------------------------------------------------------

# The same wording and the same error code colr.tcl uses for a table that ends
# before its own header promises, so that a caller cannot tell from the code
# which of the two readers found it - and does not have to.
# A value outside the enumeration it belongs to, which is what a table from a
# later minor version of the format looks like from here.
#
# ONE CLASS FOR THE THREE PLACES THAT HAVE NO CLASS OF THEIR OWN - a colour
# line's extend mode, a ClipList format, a ClipBox format - because the answer
# a caller has to give is the same in all three: the face uses a construction
# this reader does not know, and there is no argument to change. The two
# enumerations that a font is likely to grow first, paint format and composite
# mode, keep the codes they had (TCLPDF COLR PAINT and TCLPDF COLR COMPOSITE)
# so that a caller trapping either goes on trapping it.
proc ::tclpdf::colrPaint::Unsupported {what value where defined} {
  return -code error -errorcode [list TCLPDF COLR UNSUPPORTED $what $value] \
      "tclpdf: $where in the font's \"COLR\" table names $what $value, and\
      $defined - so this is a table from a later minor version of the format.\
      Reading it as one of the values that ARE defined would draw a colour\
      glyph that differs from what the font says with nothing reporting it"
}

proc ::tclpdf::colrPaint::Truncated {detail} {
  return -code error -errorcode {TCLPDF COLR TRUNCATED COLR} \
      "tclpdf: the font's \"COLR\" table is cut short - $detail"
}

package provide tclpdf::colrPaint 1.2
