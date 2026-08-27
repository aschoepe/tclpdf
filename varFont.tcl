#
# tclpdf - PDF generation for Tcl
#
# varFont - reading the variation tables of an OpenType variable font
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# A private sub-module behind the font facade - nothing outside font.tcl and
# subset.tcl loads this. It knows the file format and nothing about PDF.
#
# WHAT A VARIABLE FONT IS, and why this module has to exist at all. Such a file
# carries ONE set of outlines plus a rule for bending them: `fvar` names the
# axes (weight, width, optical size), `gvar` holds the point deltas that belong
# to each region of the axis space. What sits in `glyf` is the DEFAULT
# instance - the point where every axis is at its default value.
#
# PDF HAS NOWHERE TO PUT AN AXIS VALUE. Not in the font dictionary, not in the
# descriptor. So a variable font can only be embedded as ONE fixed instance,
# and there are two ways to get one: take the default that is already in
# `glyf` - which is what tclpdf did until now - or compute the outlines for a
# chosen point and embed those. This module is the second way.
#
# THE ORDER OF WORK, because each step depends on the one before:
#
#   1. fvar    which axes exist, and their minimum, default and maximum
#   2. avar    the optional warping of an axis - a font may say that halfway
#              along the slider is not halfway along the design
#   3. normalise  a user value on the axis becomes -1 .. 0 .. 1
#   4. gvar    the deltas for a glyph, per region, scaled by how far the
#              chosen point sits inside that region
#   5. IUP     points a delta does not mention are interpolated from their
#              neighbours - the expensive half, and the one that decides
#              whether the result looks right
#   6. advances the advance widths vary too, and a wrong one shifts every
#              following glyph. They are read off the PHANTOM POINTS of gvar,
#              which every glyph carries - the empty ones included - and not
#              from HVAR: every variable face in the tree ships an HVAR, but
#              the two sources are built from the same deltas, and an
#              instancer that pins every axis drops HVAR after applying the
#              phantom points. Measured against fontTools' instancer: the
#              space of Roboto comes out at 490, 499, 508, 509 and 510 units
#              for wght 100, 300, 400, 700 and 900 from either source.
#
# Steps 1 to 6 are here, plus the PostScript name of an instance (TN 5902),
# the bounding box of a moved face, which the subset and the font descriptor
# both state, and the hhea summary of its advances and bearings.
#

package require Tcl 8.6.11-

namespace eval ::tclpdf::varFont {
  namespace export {[a-z]*}
  namespace ensemble create
}

# Does this font vary at all?
proc ::tclpdf::varFont::isVariable {parsed} {
  return [dict exists [dict get $parsed tables] fvar]
}

# The axes of a variable font, in the order fvar lists them - which is the
# order everything else in the format refers to them by, so it must not be
# sorted.
#
# Each entry: {tag minimum default maximum flags nameId}. The three values are
# in the axis's own units - points for optical size, the 1..1000 scale for
# weight - not normalised; that is [normalise] below.
proc ::tclpdf::varFont::axes {parsed} {
  set bytes [dict get $parsed bytes]
  lassign [dict get [dict get $parsed tables] fvar] at -
  binary scan $bytes @[expr {$at + 4}]SuSuSuSu axesOffset - axisCount axisSize
  set result {}
  for {set index 0} {$index < $axisCount} {incr index} {
    set position [expr {$at + $axesOffset + $index * $axisSize}]
    binary scan $bytes @${position}a4IIISuSu tag minimum default maximum flags nameId
    lappend result [list $tag [Fixed $minimum] [Fixed $default] \
        [Fixed $maximum] $flags $nameId]
  }
  return $result
}

# The named instances - the points on the axes the designer thought worth
# naming, which is what a static family would ship as separate files.
#
# Each entry: {nameId {tag value tag value ...} postScriptNameId}. The
# coordinates are in axis units, as in [axes].
proc ::tclpdf::varFont::instances {parsed} {
  set bytes [dict get $parsed bytes]
  lassign [dict get [dict get $parsed tables] fvar] at -
  binary scan $bytes @[expr {$at + 4}]SuSuSuSuSuSu axesOffset countSizePairs \
      axisCount axisSize instanceCount instanceSize
  set tags {}
  foreach axis [axes $parsed] {
    lappend tags [lindex $axis 0]
  }
  set start [expr {$at + $axesOffset + $axisCount * $axisSize}]
  set result {}
  for {set index 0} {$index < $instanceCount} {incr index} {
    set position [expr {$start + $index * $instanceSize}]
    binary scan $bytes @${position}SuSu nameId flags
    set coordinates {}
    for {set axis 0} {$axis < $axisCount} {incr axis} {
      binary scan $bytes @[expr {$position + 4 + $axis * 4}]I value
      lappend coordinates [lindex $tags $axis] [Fixed $value]
    }
    # The PostScript name id is optional: instanceSize tells whether it is
    # there. Reading it unconditionally would take two bytes of the next
    # record.
    set postScript {}
    if {$instanceSize >= 4 + $axisCount * 4 + 2} {
      binary scan $bytes @[expr {$position + 4 + $axisCount * 4}]Su postScript
    }
    lappend result [list $nameId $coordinates $postScript]
  }
  return $result
}

# A user coordinate on one axis, normalised to -1 .. 0 .. 1.
#
# This is the arithmetic of OpenType 1.8, "Coordinate scales and normalization"
# - the default value becomes 0, the minimum -1, the maximum 1, and everything
# between is linear on ITS OWN SIDE of the default. The two sides are scaled
# separately: an axis running 100 .. 400 .. 900 has 250 at -0.5 and 650 at
# +0.5, which are different distances in user units.
proc ::tclpdf::varFont::normalise {axis value} {
  lassign $axis tag minimum default maximum
  if {$value < $minimum} {
    set value $minimum
  } elseif {$value > $maximum} {
    set value $maximum
  }
  if {$value == $default} {
    return 0.0
  }
  if {$value < $default} {
    if {$default == $minimum} {
      return 0.0
    }
    return [expr {-1.0 * ($default - $value) / ($default - $minimum)}]
  }
  if {$maximum == $default} {
    return 0.0
  }
  return [expr {1.0 * ($value - $default) / ($maximum - $default)}]
}

# The same for a whole set of axes, given as {tag value tag value ...}. An axis
# the caller does not mention stays at its default, which is 0 after
# normalising - so a caller may name only the one axis it cares about.
#
# The result is a LIST in fvar order, not a dictionary: everything downstream
# indexes axes by position, because that is how gvar and avar refer to them.
proc ::tclpdf::varFont::coordinates {parsed wanted} {
  set result {}
  foreach axis [axes $parsed] {
    set tag [lindex $axis 0]
    if {[dict exists $wanted $tag]} {
      lappend result [normalise $axis [dict get $wanted $tag]]
    } else {
      lappend result 0.0
    }
  }
  if {[dict exists [dict get $parsed tables] avar]} {
    set result [Warp $parsed $result]
  }
  # Quantised to F2DOT14 - the representation the format itself uses for a
  # normalised coordinate, in avar and in every tuple record. Carrying full
  # double precision further would compute with a point on the axis that the
  # font cannot express, and measured against an independent implementation
  # that showed up as single glyphs landing one unit off.
  return [lmap value $result {expr {[Round [expr {$value * 16384}]] / 16384.0}}]
}

# avar: the font's own correction of the normalised value.
#
# A designer may say that the middle of the weight slider is not the middle of
# the design - that 500 should behave like 0.4 rather than like 0.5. avar is a
# piecewise linear mapping per axis that says so, and skipping it does not
# fail, it just gives slightly wrong outlines. Measured: New York carries one
# (66 bytes), SF Mono does not.
proc ::tclpdf::varFont::Warp {parsed values} {
  set bytes [dict get $parsed bytes]
  lassign [dict get [dict get $parsed tables] avar] at -
  binary scan $bytes @[expr {$at + 6}]Su axisCount
  set position [expr {$at + 8}]
  set result {}
  for {set index 0} {$index < $axisCount} {incr index} {
    binary scan $bytes @${position}Su pairCount
    incr position 2
    set from {}
    set to {}
    for {set pair 0} {$pair < $pairCount} {incr pair} {
      binary scan $bytes @${position}SS fromValue toValue
      lappend from [expr {$fromValue / 16384.0}]
      lappend to [expr {$toValue / 16384.0}]
      incr position 4
    }
    if {$index < [llength $values]} {
      lappend result [Piecewise [lindex $values $index] $from $to]
    }
  }
  # An avar with fewer axes than fvar is malformed; the untouched values are
  # kept rather than dropped, so the caller still gets one value per axis.
  return [concat $result [lrange $values [llength $result] end]]
}

# One value through a piecewise linear mapping given as two parallel lists.
proc ::tclpdf::varFont::Piecewise {value from to} {
  set count [llength $from]
  if {$count < 2} {
    return $value
  }
  if {$value <= [lindex $from 0]} {
    return [lindex $to 0]
  }
  if {$value >= [lindex $from end]} {
    return [lindex $to end]
  }
  for {set index 1} {$index < $count} {incr index} {
    set upper [lindex $from $index]
    if {$value <= $upper} {
      set lower [lindex $from [expr {$index - 1}]]
      if {$upper == $lower} {
        return [lindex $to $index]
      }
      set share [expr {($value - $lower) / double($upper - $lower)}]
      set a [lindex $to [expr {$index - 1}]]
      set b [lindex $to $index]
      return [expr {$a + $share * ($b - $a)}]
    }
  }
  return $value
}

# Every glyph of a face, moved to one point in the axis space.
#
# Returns glyph id -> {bytes advance bearing}. An EMPTY glyph - a space - is in
# the result too, with no bytes: it has no outline to move, but its advance
# varies like any other, through the phantom points that gvar carries for it
# as well. Roboto's space grows from 490 to 510 units between wght 100 and
# 900; skipping the empty glyphs here left it at the default 508 for every
# weight, and measured against fontTools that was the one advance out of
# 1326 that disagreed.
#
# The whole face at once rather than the glyphs a document happens to use, and
# the reason is the composites: a subset closes over them AFTER this, and a
# component instanced at a different point than the glyph using it would tear
# the letter apart. Measured at 67 ms for Roboto's 1326 glyphs.
#
# TWO PASSES, and the composites are why. A composite's bounding box and left
# side bearing follow the outlines of its components AS MOVED, and a component
# may sit anywhere in the glyph order - Roboto's dieresis is glyph 106, the
# A-dieresis that places it glyph 671, but nothing forbids the reverse. So
# every glyph is moved first, and only then does each composite get its box
# and bearing from the moved set. Measured 2026-08-17 over the seven variable
# faces in the tree at wght maximum: with the header's box and bearing carried
# over, 6 207 of 6 275 composites had a box off by 10 units or more (up to 376
# in Roboto Black, 515 at the wght 100 wdth 62.5 corner of NotoSans) and 4 280
# a bearing off by that much (up to 224, Roboto's Iota with tonos) - Roboto's
# A-dieresis 33, D-caron and r-caron 123, Cyrillic short I 87 units. Neither
# poppler nor CoreGraphics show it, because both place a glyph at xMin minus
# bearing and the two stale values agree with each other - measured, the
# renders before and after are byte-identical. The file was wrong all the
# same: head flag bit 1 promises lsb = xMin, and the box is what a reader is
# told the glyph covers. The second pass costs about 10 ms for Roboto's 1326
# glyphs (88 to 98 ms, measured the same day on the same machine).
proc ::tclpdf::varFont::all {parsed coordinates} {
  package require tclpdf::glyfOutline 1.0-
  set glyf [::tclpdf::sfnt table $parsed glyf]
  set loca [dict get $parsed loca]
  set outlines {}
  set moved {}
  for {set glyph 0} {$glyph < [llength $loca] - 1} {incr glyph} {
    set start [lindex $loca $glyph]
    set stop [lindex $loca [expr {$glyph + 1}]]
    set data [expr {$start >= $stop ? {} :
        [string range $glyf $start [expr {$stop - 1}]]}]
    set outline [::tclpdf::glyfOutline parse $data]
    set entry [instance $parsed $glyph $outline $coordinates]
    dict set outlines $glyph [dict get $entry outline]
    dict set moved $glyph $entry
  }
  set result {}
  dict for {glyph entry} $moved {
    set outline [dict get $entry outline]
    set bearing [dict get $entry bearing]
    if {[dict size $outline] && [dict get $outline type] eq "composite"} {
      set bounds [::tclpdf::glyfOutline bounds $outlines $glyph]
      dict set outline bounds $bounds
      # The same rule as for a simple glyph: the bearing is measured from the
      # moved phantom point 1 to the moved xMin.
      set bearing [Round [expr {[lindex $bounds 0] - [dict get $entry origin]}]]
    }
    set bytes [::tclpdf::glyfOutline compose $outline]
    set record [dict create bytes $bytes \
        advance [dict get $entry advance] bearing $bearing]
    if {[dict exists $entry verticalOrigin]} {
      # The TOP side bearing of the instance follows its outline, exactly as
      # the left one does above: the origin is where the glyph hangs from and
      # yMax is where its ink begins, so the distance between the two is what
      # vmtx states. Taken from the composed bytes rather than from the
      # outline dictionary, because that is where the moved box ends up - and
      # it is the same ten bytes font.tcl reads for the same number.
      set top 0
      if {[string length $bytes] >= 10} {
        binary scan $bytes @8S top
      }
      dict set record verticalOrigin [dict get $entry verticalOrigin]
      dict set record verticalBearing \
          [expr {[dict get $entry verticalOrigin] - $top}]
      if {[dict exists $entry verticalAdvance]} {
        dict set record verticalAdvance [dict get $entry verticalAdvance]
      }
    }
    dict set result $glyph $record
  }
  return $result
}

# The bounding box of a moved face: the union of the boxes of every glyph
# [all] returned, {xMin yMin xMax yMax} in font units - the four zeros on a
# set with no outline at all.
#
# It is what the header of the file carries for the DEFAULT position (head
# xMin..yMax, ISO/IEC 14496-22 "head"), and it changes when the outlines do:
# measured 2026-08-17 over the seven variable faces in the tree at their axis
# corners against the box the file declares, Roboto reaches 130 units further
# right at wght 900 and stops 327 units short at wght 100 wdth 75, NotoSans
# gains 57 units at the top at wght 900, NotoSerifTibetan drops 351 units
# below the file's yMin at wght 900. Both places that state a box for the
# embedded font - the head table of the subset and /FontBBox in the font
# descriptor (ISO 32000-1 9.8.1, Table 122: the smallest rectangle enclosing
# ALL glyphs of the font placed at one origin) - take it from here for an
# instance, so that a font that carries only moved outlines does not describe
# the outlines it left behind. Read off the eight header bytes of each glyph
# record rather than the points: [all] wrote them from the moved points
# (glyfOutline compose, and bounds for a composite), so they are already
# right and cost nothing to sum.
proc ::tclpdf::varFont::bounds {instanced} {
  set result {}
  dict for {glyph entry} $instanced {
    set bytes [dict get $entry bytes]
    if {[string length $bytes] < 10} {
      continue
    }
    binary scan $bytes @2SSSS xMin yMin xMax yMax
    if {![llength $result]} {
      set result [list $xMin $yMin $xMax $yMax]
      continue
    }
    lassign $result left bottom right top
    set result [list [expr {min($left, $xMin)}] [expr {min($bottom, $yMin)}] \
        [expr {max($right, $xMax)}] [expr {max($top, $yMax)}]]
  }
  if {![llength $result]} {
    return {0 0 0 0}
  }
  return $result
}

# The horizontal summary of a moved face - what the hhea table states about
# ALL its glyphs (ISO/IEC 14496-22 "hhea", the four fields at offset 10):
# {advanceWidthMax minLeftSideBearing minRightSideBearing xMaxExtent}, in
# font units. Same footing as [bounds]: the file's numbers describe the
# DEFAULT outlines, and they move with them - measured 2026-08-17 over the
# seven variable faces in the tree at their axis corners against the file's
# hhea, Roboto's advanceWidthMax drops from 2378 to 2101 at wght 100 wdth 75
# and its xMaxExtent grows from 2353 to 2483 at wght 900; NotoSans's
# minRightSideBearing is 377 units off at wght 100 wdth 62.5, NotoSerifTibetan
# reaches 105 units further at wght 900. At the default position the four
# reproduce the file's for five of the seven faces (Bitcount and
# NotoSansSymbols declare numbers their default outlines do not reach, as
# they do in head).
#
# The rule is the format's, and it is also what fontTools' hhea recalc does:
# advanceWidthMax is the maximum over EVERY glyph of hmtx, empty ones
# included - a wide blank glyph has an advance like any other; the other
# three are taken over the glyphs WITH contours only, so a space (no bytes,
# no box) does not push minLeftSideBearing to zero for a face whose every
# outline starts right of the origin. minRightSideBearing is aw - (lsb +
# xMax - xMin), xMaxExtent is lsb + (xMax - xMin), both from the moved
# bearing [all] measured and the box it wrote into the glyph header - the
# same numbers the subset's hmtx and glyf carry, so the summary and the
# glyphs agree by construction. A set without an outline gives {awMax 0 0 0}.
proc ::tclpdf::varFont::hheaMetrics {instanced} {
  set advanceMax 0
  set minLeft {}
  set minRight {}
  set extent {}
  dict for {glyph entry} $instanced {
    set advance [dict get $entry advance]
    if {$advance > $advanceMax} {
      set advanceMax $advance
    }
    set bytes [dict get $entry bytes]
    if {[string length $bytes] < 10} {
      continue
    }
    binary scan $bytes SSxxS contours xMin xMax
    if {$contours == 0} {
      continue
    }
    set bearing [dict get $entry bearing]
    set width [expr {$xMax - $xMin}]
    set right [expr {$advance - ($bearing + $width)}]
    set reach [expr {$bearing + $width}]
    if {$minLeft eq {} || $bearing < $minLeft} {
      set minLeft $bearing
    }
    if {$minRight eq {} || $right < $minRight} {
      set minRight $right
    }
    if {$extent eq {} || $reach > $extent} {
      set extent $reach
    }
  }
  if {$minLeft eq {}} {
    return [list $advanceMax 0 0 0]
  }
  return [list $advanceMax $minLeft $minRight $extent]
}

# One glyph, moved to the chosen point in the axis space.
#
# Returns a dictionary: outline (the glyf dictionary with its points moved),
# advance, bearing and origin - the x of the moved phantom point 1, which is
# what a bearing is measured from. A composite comes back with its component
# OFFSETS moved and its box and bearing as they were: those depend on the
# components' outlines, which this proc has not seen, and [all] sets them once
# every glyph is moved.
#
# The four phantom points are what makes the advance vary: they are appended to
# the point list, gvar shifts them like any other point, and the distance
# between the first two IS the advance width. An HVAR table, where the face
# has one - all seven variable faces in the tree do - carries the same
# deltas a second time for readers that do not walk gvar; a full instance
# needs only one source, and this is the one that also moves the outline.
#
# AND THE OTHER TWO PHANTOM POINTS ARE THE VERTICAL METRIC, which is the same
# argument one writing mode over. Phantom point 3 sits at the glyph's VERTICAL
# ORIGIN - the point it hangs from, yMax plus the top side bearing - and
# phantom point 4 an advance height below it (ISO/IEC 14496-22 "gvar", the
# four points appended to every glyph). So an instance's origin and height
# come from the same deltas its width does, and a VVAR table carries them a
# second time for a reader that does not walk gvar, exactly as HVAR carries
# the width.
#
# WHY IT MATTERS, and it is not a rounding: the vertical origin used to be
# built from the INSTANCED yMax and the DEFAULT top side bearing. Those two
# move in opposite directions by design - a heavier weight grows upward and
# the face lowers the bearing to keep the origin where it is - so the sum
# drifted with every step along the axis. Measured on NotoSansSymbols with
# -direction ttb: the arrows hang at 1470 and 1474 at wght 100 and at 1492
# and 1504 at wght 900, where fontTools and the face's own VVAR say 1480 at
# every weight - up to 24 units of the em, and /W2 said so in the file.
proc ::tclpdf::varFont::instance {parsed glyph outline coordinates} {
  set advance [::tclpdf::sfnt advance $parsed $glyph]
  set bearing [lindex [dict get $parsed bearings] $glyph]
  # The default vertical origin, before anything moves: yMax of the glyph as
  # the FILE has it plus the top side bearing. {} for a face that says nothing
  # about vertical writing, and then nothing vertical is answered at all.
  set verticalAdvance [::tclpdf::sfnt verticalAdvance $parsed $glyph]
  set verticalOrigin [::tclpdf::sfnt verticalOriginY $parsed $glyph \
      [expr {[dict exists $outline bounds] ?
          [lindex [dict get $outline bounds] 3] : {}}]]
  set simple [expr {[dict size $outline] && [dict get $outline type] eq "simple"}]
  set composite [expr {[dict size $outline] &&
      [dict get $outline type] eq "composite"}]
  # A composite has one variation point per COMPONENT, not per outline point:
  # what varies is where each piece is placed. An a-dieresis whose accent stays
  # put while the letter below it grows heavier is the visible failure.
  set points [expr {$simple ? [llength [dict get $outline x]] :
      ($composite ? [llength [dict get $outline components]] : 0)}]

  # Phantom 1 sits at the horizontal origin, phantom 2 an advance further on.
  # Their default positions have to be right, not just their deltas: IUP puts
  # unreferenced points between their neighbours, and the phantoms are
  # neighbours to nothing - but the advance is read off their positions.
  set phantomX [expr {$simple || $composite ?
      [lindex [dict get $outline bounds] 0] - $bearing : 0}]
  lassign [deltas $parsed $glyph $coordinates $outline [expr {$points + 4}]] dx dy

  set shiftFirst [lindex $dx $points]
  set shiftSecond [lindex $dx [expr {$points + 1}]]
  set movedAdvance [Round [expr {$advance + $shiftSecond - $shiftFirst}]]
  if {$movedAdvance < 0} {
    set movedAdvance 0
  }
  set origin [expr {$phantomX + $shiftFirst}]
  # The vertical pair, moved by the deltas of phantom points 3 and 4.
  set vertical {}
  if {$verticalOrigin ne {}} {
    set shiftTop [lindex $dy [expr {$points + 2}]]
    set shiftBottom [lindex $dy [expr {$points + 3}]]
    dict set vertical verticalOrigin [Round [expr {$verticalOrigin + $shiftTop}]]
    if {$verticalAdvance ne {}} {
      set moved [Round [expr {$verticalAdvance + $shiftTop - $shiftBottom}]]
      dict set vertical verticalAdvance [expr {$moved < 0 ? 0 : $moved}]
    }
  }
  if {$composite} {
    # Only offsets move. A component placed by matching two point numbers
    # (without ARGS_ARE_XY_VALUES) has no offset to shift, and the standard
    # says so explicitly - shifting the point numbers instead would attach the
    # piece to a different point of the base glyph.
    set moved {}
    set index 0
    foreach component [dict get $outline components] {
      lassign $component flags number arguments transform
      if {$flags & 0x0002} {
        lassign $arguments x y
        set arguments [list \
            [Round [expr {$x + [lindex $dx $index]}]] \
            [Round [expr {$y + [lindex $dy $index]}]]]
      }
      lappend moved [list $flags $number $arguments $transform]
      incr index
    }
    dict set outline components $moved
    return [dict merge [dict create outline $outline advance $movedAdvance \
        bearing $bearing origin $origin] $vertical]
  }
  if {!$simple} {
    return [dict merge [dict create outline $outline advance $movedAdvance \
        bearing $bearing origin $origin] $vertical]
  }

  # Rounding happens ONCE, on the sum of every region - rounding each region as
  # it is added loses up to half a unit per region, and a glyph in the middle
  # of the axis space is the sum of four of them.
  set xs {}
  set ys {}
  foreach x [dict get $outline x] y [dict get $outline y] \
      shiftX [lrange $dx 0 [expr {$points - 1}]] \
      shiftY [lrange $dy 0 [expr {$points - 1}]] {
    lappend xs [Round [expr {$x + $shiftX}]]
    lappend ys [Round [expr {$y + $shiftY}]]
  }
  dict set outline x $xs
  dict set outline y $ys
  # The left side bearing follows the outline: a renderer places the glyph at
  # cursor plus bearing, so keeping the old one would move a widened letter
  # sideways rather than let it grow.
  set movedBearing [expr {[llength $xs] ?
      [Round [expr {[::tcl::mathfunc::min {*}$xs] - $origin}]] :
      $bearing}]
  return [dict merge [dict create outline $outline advance $movedAdvance \
      bearing $movedBearing origin $origin] $vertical]
}

# The deltas for one glyph at one point in the axis space.
#
# Returns two lists - the x and the y shift of every point, in font units, as
# real numbers. The caller adds them to the default outline and rounds; adding
# them one region at a time and rounding in between loses about a unit per
# region, which is visible at small sizes.
#
# The point count has to be passed in because gvar does not carry it: a tuple
# may say "all points", and only the outline knows how many that is. It counts
# the FOUR PHANTOM POINTS as well - two horizontal, two vertical - which is how
# a variable font varies its advance width without HVAR.
proc ::tclpdf::varFont::deltas {parsed glyph coordinates outline count} {
  set tables [dict get $parsed tables]
  if {![dict exists $tables gvar]} {
    return [list [lrepeat $count 0.0] [lrepeat $count 0.0]]
  }
  set bytes [dict get $parsed bytes]
  lassign [dict get $tables gvar] at -
  binary scan $bytes @[expr {$at + 4}]SuSuI axisCount sharedCount sharedOffset
  binary scan $bytes @[expr {$at + 12}]SuSuI glyphCount flags dataOffset
  if {$glyph >= $glyphCount} {
    return [list [lrepeat $count 0.0] [lrepeat $count 0.0]]
  }

  # Bit 0 of flags: the offsets are either uint16 halved - exactly as in loca -
  # or uint32. Reading the wrong width gives an offset into the middle of
  # another glyph's data, which decodes as garbage rather than failing.
  if {$flags & 1} {
    binary scan $bytes @[expr {$at + 20 + $glyph * 4}]IuIu start stop
  } else {
    binary scan $bytes @[expr {$at + 20 + $glyph * 2}]SuSu start stop
    set start [expr {$start * 2}]
    set stop [expr {$stop * 2}]
  }
  if {$start >= $stop} {
    # Equal offsets mean this glyph does not vary at all.
    return [list [lrepeat $count 0.0] [lrepeat $count 0.0]]
  }

  set shared [Shared $bytes [expr {$at + $sharedOffset}] $sharedCount $axisCount]
  return [Tuples $bytes [expr {$at + $dataOffset + $start}] \
      [expr {$at + $dataOffset + $stop}] $axisCount $shared $coordinates \
      $outline $count]
}

# The shared tuple records: peak coordinates a tuple can refer to by index
# instead of carrying its own.
proc ::tclpdf::varFont::Shared {bytes at countTuples axisCount} {
  set result {}
  for {set index 0} {$index < $countTuples} {incr index} {
    set peak {}
    for {set axis 0} {$axis < $axisCount} {incr axis} {
      binary scan $bytes @[expr {$at + ($index * $axisCount + $axis) * 2}]S value
      lappend peak [expr {$value / 16384.0}]
    }
    lappend result $peak
  }
  return $result
}

# One glyph's variation data: a header per tuple, then the serialised data.
proc ::tclpdf::varFont::Tuples {bytes at end axisCount shared coordinates outline count} {
  set dx [lrepeat $count 0.0]
  set dy [lrepeat $count 0.0]
  binary scan $bytes @${at}SuSu tupleCount dataOffset
  # Bit 15 says every tuple uses one shared list of point numbers, which then
  # sits at the front of the data area.
  set sharePoints [expr {$tupleCount & 0x8000}]
  set tupleCount [expr {$tupleCount & 0x0FFF}]
  set header [expr {$at + 4}]
  set data [expr {$at + $dataOffset}]

  set sharedPoints {}
  if {$sharePoints} {
    lassign [Points $bytes $data $end] sharedPoints data
  }

  for {set index 0} {$index < $tupleCount} {incr index} {
    binary scan $bytes @${header}SuSu size tupleIndex
    incr header 4
    set peak {}
    if {$tupleIndex & 0x8000} {
      # An embedded peak, right behind the header.
      for {set axis 0} {$axis < $axisCount} {incr axis} {
        binary scan $bytes @${header}S value
        incr header 2
        lappend peak [expr {$value / 16384.0}]
      }
    } else {
      set peak [lindex $shared [expr {$tupleIndex & 0x0FFF}]]
    }
    set from {}
    set to {}
    if {$tupleIndex & 0x4000} {
      # An intermediate region: the tuple applies between these two corners
      # rather than symmetrically around zero.
      foreach which {from to} {
        set values {}
        for {set axis 0} {$axis < $axisCount} {incr axis} {
          binary scan $bytes @${header}S value
          incr header 2
          lappend values [expr {$value / 16384.0}]
        }
        set $which $values
      }
    }
    set scalar [Scalar $peak $from $to $coordinates]
    set next [expr {$data + $size}]
    if {$scalar != 0} {
      set position $data
      if {$tupleIndex & 0x2000} {
        lassign [Points $bytes $position $end] private position
        set points $private
      } else {
        set points $sharedPoints
      }
      # An empty point list means every point, phantom points included.
      set wanted [expr {[llength $points] ? [llength $points] : $count}]
      lassign [Packed $bytes $position $end $wanted] xs position
      lassign [Packed $bytes $position $end $wanted] ys position

      # Spread this region's deltas over all points before scaling. The order
      # matters and the standard is explicit about it (7.3.4.4): interpolation
      # works on the DEFAULT positions and the UNSCALED deltas of this one
      # region. Interpolating the running sum instead would mix regions that
      # reference different points, and the result depends on the order the
      # tuples happen to sit in the file.
      if {[llength $points]} {
        lassign [Interpolate $outline $count $points $xs $ys] xs ys
        set points {}
      }
      if {![llength $points]} {
        set points {}
        for {set p 0} {$p < $count} {incr p} {
          lappend points $p
        }
      }
      foreach point $points x $xs y $ys {
        if {$point >= $count} {
          continue
        }
        lset dx $point [expr {[lindex $dx $point] + $scalar * $x}]
        lset dy $point [expr {[lindex $dy $point] + $scalar * $y}]
      }
    }
    set data $next
  }
  return [list $dx $dy]
}

# IUP - the points a tuple does not mention, worked out from the ones it does.
#
# A tuple usually names only the points that actually move, and the rest are
# not "unchanged": they follow their neighbours, so that a stem which moves
# takes its serif with it. The standard calls this inferring unreferenced
# points (7.3.4.4).
#
# CONTOUR BY CONTOUR, because the two neighbours of a point have to be on the
# same outline - interpolating the top of an "i" from the bottom of its dot
# would tear the glyph apart. Phantom points belong to no contour and keep
# whatever the tuple gave them.
#
# Returns full-length x and y delta lists, one entry per point.
proc ::tclpdf::varFont::Interpolate {outline count points xs ys} {
  set dx [lrepeat $count 0.0]
  set dy [lrepeat $count 0.0]
  set given {}
  foreach point $points x $xs y $ys {
    if {$point < $count} {
      lset dx $point [expr {double($x)}]
      lset dy $point [expr {double($y)}]
      dict set given $point 1
    }
  }
  if {![dict size $outline] || [dict get $outline type] ne "simple"} {
    return [list $dx $dy]
  }
  set px [dict get $outline x]
  set py [dict get $outline y]
  set first 0
  foreach last [dict get $outline ends] {
    # Which points of THIS contour the tuple named.
    set referenced {}
    for {set point $first} {$point <= $last} {incr point} {
      if {[dict exists $given $point]} {
        lappend referenced $point
      }
    }
    if {![llength $referenced]} {
      # Not one point named: the contour does not move at all.
      set first [expr {$last + 1}]
      continue
    }
    if {[llength $referenced] == 1} {
      # A single named point carries the whole contour, unchanged in shape.
      set only [lindex $referenced 0]
      for {set point $first} {$point <= $last} {incr point} {
        lset dx $point [lindex $dx $only]
        lset dy $point [lindex $dy $only]
      }
      set first [expr {$last + 1}]
      continue
    }
    # Every unnamed point sits between two named ones, following the contour
    # round - so the search wraps from the last point back to the first.
    #
    # The two directions are worked out SEPARATELY and from the same pair of
    # neighbours: a point may sit between them horizontally and outside them
    # vertically, and then it interpolates in x and copies in y.
    set total [expr {$last - $first + 1}]
    for {set point $first} {$point <= $last} {incr point} {
      if {[dict exists $given $point]} {
        continue
      }
      set before [Neighbour $referenced $point $first $total -1]
      set after [Neighbour $referenced $point $first $total 1]
      lset dx $point [Between [lindex $px $point] \
          [lindex $px $before] [lindex $dx $before] \
          [lindex $px $after] [lindex $dx $after]]
      lset dy $point [Between [lindex $py $point] \
          [lindex $py $before] [lindex $dy $before] \
          [lindex $py $after] [lindex $dy $after]]
    }
    set first [expr {$last + 1}]
  }
  return [list $dx $dy]
}

# The nearest referenced point in one direction, wrapping around the contour.
proc ::tclpdf::varFont::Neighbour {referenced point first total direction} {
  for {set step 1} {$step <= $total} {incr step} {
    set index [expr {($point - $first + $direction * $step) % $total + $first}]
    if {$index in $referenced} {
      return $index
    }
  }
  return $point
}

# One inferred delta, from the two neighbours that surround the point.
#
# The three cases of 7.3.4.4, and each one is a decision about what "between"
# means when the neighbours sit on top of each other or the point does not sit
# between them at all.
proc ::tclpdf::varFont::Between {target beforeAt beforeDelta afterAt afterDelta} {
  if {$beforeAt == $afterAt} {
    # The neighbours are at the same coordinate: they can only agree or
    # disagree, and a disagreement has no direction to resolve it.
    return [expr {$beforeDelta == $afterDelta ? $beforeDelta : 0.0}]
  }
  set lower [expr {min($beforeAt, $afterAt)}]
  set upper [expr {max($beforeAt, $afterAt)}]
  if {$target <= $lower} {
    return [expr {$beforeAt < $afterAt ? $beforeDelta : $afterDelta}]
  }
  if {$target >= $upper} {
    return [expr {$beforeAt > $afterAt ? $beforeDelta : $afterDelta}]
  }
  set share [expr {double($target - $beforeAt) / ($afterAt - $beforeAt)}]
  return [expr {(1.0 - $share) * $beforeDelta + $share * $afterDelta}]
}

# How much a region contributes at the chosen point: 1 at its peak, falling to
# 0 at its edges, and 0 outside. The product over all axes.
#
# An axis whose peak is zero does not take part - that is what lets a tuple
# describe a region in one axis while ignoring the others, and treating it as
# "peak 0 means the value must be 0" would switch most tuples off.
proc ::tclpdf::varFont::Scalar {peak from to coordinates} {
  set scalar 1.0
  set axisCount [llength $peak]
  for {set axis 0} {$axis < $axisCount} {incr axis} {
    set p [lindex $peak $axis]
    if {$p == 0} {
      continue
    }
    set value [expr {$axis < [llength $coordinates] ?
        [lindex $coordinates $axis] : 0.0}]
    if {$value == $p} {
      continue
    }
    if {[llength $from]} {
      set start [lindex $from $axis]
      set end [lindex $to $axis]
    } else {
      # Without an intermediate record the region runs from zero to the peak.
      set start [expr {min(0.0, $p)}]
      set end [expr {max(0.0, $p)}]
    }
    # AN ILL-FORMED REGION IS IGNORED, AXIS AND ALL, and the delta counts in
    # full - which is what the specification says in as many words, in the
    # pseudocode of ISO/IEC 14496-22:2019 7.1.7:
    #
    #   if (startCoords[i] > peakCoords[i] || peakCoords[i] > endCoords[i])
    #     AS = 1; /* Not an error, apply the delta */
    #   else if (startCoords[i] < 0 && endCoords[i] > 0 && peakCoords[i] != 0)
    #     AS = 1;
    #
    # An axis whose three numbers are out of order, and one whose region
    # straddles the default with a peak somewhere else, describe no region at
    # all; the reading that stands is "this axis says nothing", not "this
    # region is off" and not a share of the way in. Only a damaged file
    # reaches it - no face this package ships carries such a tuple, and
    # fontTools writes none - but the two readings differ by the whole delta:
    # measured on a Roboto built for it, an advance of 1261 units where
    # HarfBuzz and fontTools both say 1300, and outline points up to 36 units
    # away.
    if {$start > $p || $p > $end || ($start < 0 && $end > 0)} {
      continue
    }
    if {$value <= $start || $value >= $end} {
      return 0.0
    }
    if {$value < $p} {
      set scalar [expr {$scalar * ($value - $start) / ($p - $start)}]
    } else {
      set scalar [expr {$scalar * ($end - $value) / ($end - $p)}]
    }
  }
  return $scalar
}

# Packed point numbers: a count, then runs of cumulative differences.
#
# Returns the numbers and the position after them. A count of zero means "all
# points" and is reported as an empty list, which the caller turns into the
# full range - it cannot be done here, because the point count is not known at
# this level.
proc ::tclpdf::varFont::Points {bytes at end} {
  binary scan $bytes @${at}cu first
  incr at
  if {$first & 0x80} {
    binary scan $bytes @${at}cu second
    incr at
    set count [expr {(($first & 0x7F) << 8) | $second}]
  } else {
    set count $first
  }
  if {$count == 0} {
    return [list {} $at]
  }
  set points {}
  set current 0
  while {[llength $points] < $count && $at < $end} {
    binary scan $bytes @${at}cu control
    incr at
    set run [expr {($control & 0x7F) + 1}]
    for {set index 0} {$index < $run && [llength $points] < $count} {incr index} {
      if {$control & 0x80} {
        binary scan $bytes @${at}Su step
        incr at 2
      } else {
        binary scan $bytes @${at}cu step
        incr at
      }
      incr current $step
      lappend points $current
    }
  }
  return [list $points $at]
}

# Packed deltas: a control byte, then that many values as zero, byte or short.
proc ::tclpdf::varFont::Packed {bytes at end count} {
  set values {}
  while {[llength $values] < $count && $at < $end} {
    binary scan $bytes @${at}cu control
    incr at
    set run [expr {($control & 0x3F) + 1}]
    for {set index 0} {$index < $run && [llength $values] < $count} {incr index} {
      if {$control & 0x80} {
        lappend values 0
      } elseif {$control & 0x40} {
        binary scan $bytes @${at}S value
        incr at 2
        lappend values $value
      } else {
        binary scan $bytes @${at}c value
        incr at
        lappend values $value
      }
    }
  }
  # A short data run leaves the rest at zero rather than short-changing the
  # point list, which would shift every delta after it onto the wrong point.
  while {[llength $values] < $count} {
    lappend values 0
  }
  return [list $values $at]
}

# The PostScript name of one instance, by Adobe Technical Note #5902.
#
# The face has ONE name of its own - name id 6, "Roboto-Regular" - and it names
# the default. Every other point on the axes is a different font as far as a
# PDF is concerned, and calling them all Roboto-Regular labels a Black cut as
# the Regular one. The note settles what to call them instead:
#
#   a named instance   the fvar record's own postScriptNameID when it has one
#                      (Roboto-Bold), else the family prefix, a hyphen and the
#                      instance's subfamily name with everything but ASCII
#                      letters and digits removed (NotoSansSymbols-Bold)
#   any other point    the family prefix and, per axis away from its default,
#                      "_" value tag: Roboto_620wght, Roboto_620wght_87wdth
#
# The family prefix is name id 25 where the font gives one, else name id 16
# and, failing that, name id 1, stripped to ASCII letters and digits. A point
# that happens to coincide with a named instance takes that instance's name
# whichever way it was asked for - -axes {wght 700} IS Bold.
#
# axes is a dictionary tag -> user value covering the axes the caller set; the
# rest are at their defaults.
# THE METRICS OF AN INSTANCE, out of MVAR: a dictionary of the four-letter
# value tags to the delta, in font units, that the chosen point on the axes
# adds to what the file's own tables state.
#
# WHY IT MATTERS. head, hhea and OS/2 hold ONE set of numbers, the default
# instance's, exactly as glyf holds one set of outlines. The outlines are
# moved by gvar; the metrics are moved by MVAR (ISO/IEC 14496-22, MVAR), and
# a font descriptor written without it states the DEFAULT's ascender, cap
# height and x height over the INSTANCE's glyphs. Measured on
# BitcountPropSingle at wght 700 slnt -8: fontTools' instancer writes
# sCapHeight 660, the descriptor said 600. Four of the eight variable faces
# in this tree carry an MVAR.
#
# THE STORE IS THE SAME MACHINE gvar uses, one region at a time - a list of
# regions, each with a start, a peak and an end per axis, and a scalar per
# region computed exactly as [Scalar] computes it there. What differs is the
# indexing: a value tag names an outer and an inner index into a table of
# delta sets rather than a glyph.
#
# {} where the face has no MVAR, where its version is not 1, or where the
# table is too short for what it announces - a metric that cannot be read is
# left at the file's value rather than guessed at.
proc ::tclpdf::varFont::metrics {parsed coordinates} {
  # The table is located the way every other table is located in this module -
  # out of the directory in the parsed dictionary - so that varFont keeps to
  # the one thing it depends on and does not reach into the sfnt reader.
  set tables [dict get $parsed tables]
  if {![dict exists $tables MVAR]} {
    return {}
  }
  lassign [dict get $tables MVAR] position length
  if {$length < 12} {
    return {}
  }
  set bytes [string range [dict get $parsed bytes] $position \
      [expr {$position + $length - 1}]]
  binary scan $bytes SuSuSuSuSuSu major minor - recordSize count storeOffset
  if {$major != 1 || $count == 0 || $storeOffset == 0 || $recordSize < 8} {
    return {}
  }
  set store [ItemStore $bytes $storeOffset $coordinates]
  if {![llength $store]} {
    return {}
  }
  set result {}
  for {set index 0} {$index < $count} {incr index} {
    set at [expr {12 + $index * $recordSize}]
    if {[binary scan $bytes @${at}a4SuSu tag outer inner] != 3} {
      break
    }
    set delta [Delta $bytes $store $outer $inner]
    if {$delta ne {}} {
      dict set result $tag $delta
    }
  }
  return $result
}

# An ItemVariationStore as {scalars sets}: the scalar of every region at the
# chosen point, and one description per delta-set table - {itemCount
# wordCount longWords regions at rowSize}.
proc ::tclpdf::varFont::ItemStore {bytes at coordinates} {
  if {[binary scan $bytes @${at}SuIuSu format regionOffset dataCount] != 3} {
    return {}
  }
  if {$format != 1 || $dataCount == 0} {
    return {}
  }
  set scalars [Regions $bytes [expr {$at + $regionOffset}] $coordinates]
  if {![llength $scalars]} {
    return {}
  }
  set sets {}
  for {set index 0} {$index < $dataCount} {incr index} {
    if {[binary scan $bytes @[expr {$at + 8 + $index * 4}]Iu dataOffset] != 1} {
      return {}
    }
    set data [expr {$at + $dataOffset}]
    if {[binary scan $bytes @${data}SuSuSu itemCount wordCount regionCount] != 3} {
      return {}
    }
    set long [expr {($wordCount & 0x8000) != 0}]
    set wordCount [expr {$wordCount & 0x7FFF}]
    set regions {}
    for {set region 0} {$region < $regionCount} {incr region} {
      if {[binary scan $bytes @[expr {$data + 6 + $region * 2}]Su which] != 1} {
        return {}
      }
      lappend regions $which
    }
    # A row holds wordCount WIDE deltas and the rest narrow ones - four and
    # two bytes where LONG_WORDS is set, two and one where it is not.
    set wide [expr {$long ? 4 : 2}]
    set narrow [expr {$long ? 2 : 1}]
    lappend sets [list $itemCount $wordCount $long $regions \
        [expr {$data + 6 + $regionCount * 2}] \
        [expr {$wordCount * $wide + ($regionCount - $wordCount) * $narrow}]]
  }
  return [list $scalars $sets]
}

# The scalar of every variation region at the chosen point - the computation
# gvar makes per tuple, over the region list of an item variation store.
proc ::tclpdf::varFont::Regions {bytes at coordinates} {
  if {[binary scan $bytes @${at}SuSu axisCount regionCount] != 2} {
    return {}
  }
  set scalars {}
  for {set region 0} {$region < $regionCount} {incr region} {
    set peak {}
    set from {}
    set to {}
    for {set axis 0} {$axis < $axisCount} {incr axis} {
      set entry [expr {$at + 4 + ($region * $axisCount + $axis) * 6}]
      if {[binary scan $bytes @${entry}SSS start middle end] != 3} {
        return {}
      }
      lappend from [expr {$start / 16384.0}]
      lappend peak [expr {$middle / 16384.0}]
      lappend to [expr {$end / 16384.0}]
    }
    lappend scalars [Scalar $peak $from $to $coordinates]
  }
  return $scalars
}

# One delta out of a store, by its outer and inner index, rounded to whole
# font units - or {} where the indices point at no row.
proc ::tclpdf::varFont::Delta {bytes store outer inner} {
  lassign $store scalars sets
  if {$outer >= [llength $sets]} {
    return {}
  }
  lassign [lindex $sets $outer] itemCount wordCount long regions at rowSize
  if {$inner >= $itemCount} {
    return {}
  }
  set position [expr {$at + $inner * $rowSize}]
  set total 0.0
  set index 0
  foreach region $regions {
    if {$index < $wordCount} {
      set format [expr {$long ? {I} : {S}}]
      set width [expr {$long ? 4 : 2}]
    } else {
      set format [expr {$long ? {S} : {c}}]
      set width [expr {$long ? 2 : 1}]
    }
    if {[binary scan $bytes @${position}$format value] != 1} {
      return {}
    }
    incr position $width
    incr index
    set scalar [expr {$region < [llength $scalars] ?
        [lindex $scalars $region] : 0.0}]
    if {$scalar != 0.0} {
      set total [expr {$total + $scalar * $value}]
    }
  }
  return [Round $total]
}

proc ::tclpdf::varFont::postScriptName {parsed axes} {
  set full {}
  set defaults {}
  foreach axis [axes $parsed] {
    lassign $axis tag - default
    dict set defaults $tag $default
    dict set full $tag [expr {[dict exists $axes $tag] ?
        double([dict get $axes $tag]) : double($default)}]
  }
  set prefix [::tclpdf::sfnt name $parsed 25]
  if {$prefix eq {}} {
    set prefix [::tclpdf::sfnt name $parsed 16]
    if {$prefix eq {}} {
      set prefix [::tclpdf::sfnt name $parsed 1]
    }
    regsub -all {[^A-Za-z0-9]} $prefix {} prefix
  }
  foreach entry [instances $parsed] {
    lassign $entry nameId coordinates postScriptId
    set same 1
    dict for {tag value} $coordinates {
      if {[dict get $full $tag] != $value} {
        set same 0
        break
      }
    }
    if {!$same} {
      continue
    }
    if {$postScriptId ne {} && $postScriptId != 0xFFFF} {
      set name [::tclpdf::sfnt name $parsed $postScriptId]
      if {$name ne {}} {
        return $name
      }
    }
    set style [::tclpdf::sfnt name $parsed $nameId]
    regsub -all {[^A-Za-z0-9]} $style {} style
    if {$style ne {}} {
      return "$prefix-$style"
    }
    break
  }
  set name $prefix
  dict for {tag value} $full {
    if {$value == [dict get $defaults $tag]} {
      continue
    }
    # The shortest decimal that names the value: an integer as such, anything
    # else without trailing zeros. The note asks for what round-trips through
    # 16.16 fixed; six places are more than that format can distinguish.
    if {$value == int($value)} {
      set text [expr {int($value)}]
    } else {
      set text [string trimright [string trimright [format %.6f $value] 0] .]
    }
    append name _$text[string trim $tag]
  }
  return $name
}

# Rounding, the way the format prescribes it - and NOT the way Tcl's round()
# does it.
#
# OpenType, "Coordinate scales and normalization": for fractional values of 0.5
# and higher take the next higher integer, otherwise truncate. That is rounding
# towards +infinity, so -2.5 becomes -2. Tcl's round() goes away from zero and
# makes it -3.
#
# Measured against an independent implementation on Roboto at wght 700: with
# round() 117 of 583 glyphs came out one unit off, all of them on the negative
# side; with this one, none.
proc ::tclpdf::varFont::Round {value} {
  return [expr {int(floor($value + 0.5))}]
}

# The 16.16 fixed point number the format uses for axis values.
proc ::tclpdf::varFont::Fixed {value} {
  return [expr {$value / 65536.0}]
}

package provide tclpdf::varFont 1.4
