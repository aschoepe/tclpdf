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
#   6. HVAR    the advance widths vary too, and a wrong one shifts every
#              following glyph
#
# Steps 1 to 3 are here. What is not yet built is named in TODO.md rather than
# implied by silence.
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
  return $result
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

# The 16.16 fixed point number the format uses for axis values.
proc ::tclpdf::varFont::Fixed {value} {
  return [expr {$value / 65536.0}]
}

package provide tclpdf::varFont 1.0
