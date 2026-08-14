#
# tclpdf - PDF generation for Tcl
#
# glyfOutline - the points of a TrueType glyph, read and written back
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# A private sub-module behind the font facade. It knows the glyf format and
# nothing else - no PDF, no variations, no font object.
#
# WHY THIS EXISTS. Until now tclpdf only ever WALKED glyf: the subsetter copies
# a glyph's bytes and rewrites the component numbers of a composite, without
# ever asking where the points are. Instancing a variable font is the first
# thing that has to move them, and moving a point means decoding the whole
# packed representation and building it again.
#
# THE FORMAT, and why it is packed the way it is. A simple glyph stores its
# points as DELTAS to the previous point, each one either a byte or a short,
# and the flag byte that says which may itself repeat. So nothing about a point
# can be read without having read every point before it - there is no random
# access, and a writer has to make the same decisions in the same order.
#
# COMPOSITES ARE NOT DECODED into points. A composite says "draw glyph 36 here
# and glyph 700 there", and its variation deltas move those offsets, not any
# outline. So [parse] reports it as a composite with its components and leaves
# the outlines to the glyphs it names.
#

package require Tcl 8.6.11-

namespace eval ::tclpdf::glyfOutline {
  namespace export {[a-z]*}
  namespace ensemble create

  # Flags of a simple glyph, ISO/IEC 14496-22 table "Simple glyph flags".
  variable ON_CURVE 0x01
  variable X_SHORT 0x02
  variable Y_SHORT 0x04
  variable REPEAT 0x08
  variable X_SAME 0x10
  variable Y_SAME 0x20
  # Everything that is NOT about how a coordinate was packed, and therefore has
  # to survive the round trip. OVERLAP_SIMPLE tells a rasteriser the contours
  # may overlap and are to be filled non-zero; dropping it changes how the glyph
  # is filled.
  #
  # Measured, and worth knowing for anything that compares two files: the
  # STATIC cuts set it - Roboto-Regular on all 583 of its simple glyphs,
  # Bitcount-Regular on both of its - while the VARIABLE fonts of the same
  # families set it on none. So a glyph instanced from a variable font will
  # differ from the shipped static one in this flag even when every point
  # matches.
  variable KEEP 0x41
}

# One glyph's data, as a dictionary.
#
#   type        simple | composite | empty
#   bounds      {xMin yMin xMax yMax}
#   ends        the last point index of each contour
#   flags       one per point, only the on-curve bit kept
#   x, y        absolute coordinates in font units, one per point
#   instructions  the hinting program, carried through untouched
#   bytes       the original data, for the cases that are passed through
#
# An empty glyph - a space - has no data at all in glyf, which is not the same
# as a glyph with zero contours.
proc ::tclpdf::glyfOutline::parse {data} {
  variable KEEP
  variable X_SHORT
  variable Y_SHORT
  variable REPEAT
  variable X_SAME
  variable Y_SAME
  if {[string length $data] == 0} {
    return [dict create type empty bytes {}]
  }
  binary scan $data SSSSS contours xMin yMin xMax yMax
  set result [dict create bounds [list $xMin $yMin $xMax $yMax] bytes $data]
  if {$contours < 0} {
    lassign [Components $data] components position
    dict set result type composite
    dict set result components $components
    # A hinting program may follow the component list, announced by the last
    # component's flags.
    set instructions {}
    if {[llength $components] &&
        ([lindex $components end 0] & 0x0100)} {
      binary scan $data @${position}Su length
      set instructions [string range $data [expr {$position + 2}] \
          [expr {$position + 1 + $length}]]
    }
    dict set result instructions $instructions
    return $result
  }
  dict set result type simple
  set ends {}
  for {set index 0} {$index < $contours} {incr index} {
    binary scan $data @[expr {10 + $index * 2}]Su end
    lappend ends $end
  }
  dict set result ends $ends
  set position [expr {10 + $contours * 2}]
  binary scan $data @${position}Su instructionLength
  incr position 2
  dict set result instructions \
      [string range $data $position [expr {$position + $instructionLength - 1}]]
  incr position $instructionLength

  # The number of points is not stored: it is one more than the last contour's
  # end. A glyph with no contours has none, which is legal and happens.
  set count [expr {[llength $ends] ? [lindex $ends end] + 1 : 0}]

  # Flags first, because a flag says how many bytes its point occupies - the
  # coordinates cannot be located until every flag is known.
  set flags {}
  while {[llength $flags] < $count} {
    binary scan $data @${position}cu flag
    incr position
    lappend flags $flag
    if {$flag & $REPEAT} {
      binary scan $data @${position}cu repeat
      incr position
      for {set again 0} {$again < $repeat} {incr again} {
        lappend flags $flag
      }
    }
  }
  # A malformed font can repeat past the end; keeping the extra flags would
  # misread every coordinate after it.
  set flags [lrange $flags 0 [expr {$count - 1}]]

  foreach {axis short same} [list x $X_SHORT $X_SAME y $Y_SHORT $Y_SAME] {
    set values {}
    set current 0
    foreach flag $flags {
      if {$flag & $short} {
        binary scan $data @${position}cu delta
        incr position
        incr current [expr {$flag & $same ? $delta : -$delta}]
      } elseif {!($flag & $same)} {
        binary scan $data @${position}S delta
        incr position 2
        incr current $delta
      }
      lappend values $current
    }
    dict set result $axis $values
  }
  dict set result flags [lmap flag $flags {expr {$flag & $KEEP}}]
  return $result
}

# The components of a composite glyph.
#
# Each one: {flags glyph arguments transform}. The arguments are a pair, and
# what they MEAN depends on flag 0x0002 - either an offset in font units or a
# pair of point numbers to align. Only the first kind varies, which is why the
# flags travel with them rather than being decoded away.
#
# The transform is kept as raw bytes: a scale, a two-by-two matrix or nothing.
# Nothing here has any reason to look inside it, and re-encoding an F2DOT14 is
# a way to lose a bit for no gain.
proc ::tclpdf::glyfOutline::Components {data} {
  set position 10
  set result {}
  set more 1
  while {$more} {
    binary scan $data @${position}SuSu flags glyph
    incr position 4
    if {$flags & 0x0001} {
      binary scan $data @${position}SS first second
      incr position 4
    } else {
      # Byte arguments are SIGNED when they are offsets and unsigned when they
      # are point numbers - the same two bytes, read two ways.
      if {$flags & 0x0002} {
        binary scan $data @${position}cc first second
      } else {
        binary scan $data @${position}cucu first second
      }
      incr position 2
    }
    set size 0
    if {$flags & 0x0008} {
      set size 2
    } elseif {$flags & 0x0040} {
      set size 4
    } elseif {$flags & 0x0080} {
      set size 8
    }
    set transform [string range $data $position [expr {$position + $size - 1}]]
    incr position $size
    lappend result [list $flags $glyph [list $first $second] $transform]
    set more [expr {$flags & 0x0020}]
  }
  return [list $result $position]
}

# A composite glyph back to bytes, with the component offsets as they now are.
#
# The argument width is decided again rather than kept: a delta can push an
# offset past what a byte holds, and writing it back into the old width is how
# an accent ends up on the other side of the letter.
proc ::tclpdf::glyfOutline::Composite {glyph} {
  set data [binary format S -1]
  append data [binary format SSSS {*}[dict get $glyph bounds]]
  set components [dict get $glyph components]
  set last [expr {[llength $components] - 1}]
  set index 0
  foreach component $components {
    lassign $component flags number arguments transform
    lassign $arguments first second
    set words [expr {$flags & 0x0002 ?
        ($first < -128 || $first > 127 || $second < -128 || $second > 127) :
        ($first > 255 || $second > 255)}]
    if {$words} {
      set flags [expr {$flags | 0x0001}]
    } else {
      set flags [expr {$flags & ~0x0001}]
    }
    # MORE_COMPONENTS has to say the truth about THIS list, not about the one
    # that was read - a rewritten composite with the old bit set runs on into
    # whatever follows it.
    if {$index < $last} {
      set flags [expr {$flags | 0x0020}]
    } else {
      set flags [expr {$flags & ~0x0020}]
    }
    append data [binary format SuSu $flags $number]
    if {$words} {
      append data [binary format SS $first $second]
    } elseif {$flags & 0x0002} {
      append data [binary format cc $first $second]
    } else {
      append data [binary format cucu $first $second]
    }
    append data $transform
    incr index
  }
  # WE_HAVE_INSTRUCTIONS on the last component means a hinting program follows
  # the component list. It is carried through untouched.
  if {[dict exists $glyph instructions] &&
      [string length [dict get $glyph instructions]]} {
    append data [binary format Su [string length [dict get $glyph instructions]]]
    append data [dict get $glyph instructions]
  }
  return $data
}

# The other direction: a glyph dictionary back to glyf bytes.
#
# The bounds are recomputed rather than carried over - after moving points they
# are wrong, and a wrong bounding box makes a reader clip the glyph.
proc ::tclpdf::glyfOutline::compose {glyph} {
  variable X_SHORT
  variable Y_SHORT
  variable REPEAT
  variable X_SAME
  variable Y_SAME
  if {[dict get $glyph type] eq "composite"} {
    return [Composite $glyph]
  }
  if {[dict get $glyph type] ne "simple"} {
    return [dict get $glyph bytes]
  }
  set ends [dict get $glyph ends]
  set xs [dict get $glyph x]
  set ys [dict get $glyph y]
  if {![llength $ends]} {
    # No contours: the four zero bounds and nothing else. Writing the point
    # arrays of an empty glyph would produce a glyph a reader cannot skip.
    return [binary format SSSSSS 0 0 0 0 0 0]
  }

  # Flags and coordinates are built together, because the flag records how the
  # coordinate was encoded - deciding twice is how the two come apart.
  set flagBytes {}
  foreach axis {x y} {
    set [set axis]Bytes {}
  }
  set previousX 0
  set previousY 0
  foreach kept [dict get $glyph flags] x $xs y $ys {
    # The kept flags go back out unchanged; only the packing bits are decided
    # here, from the delta that is actually being written.
    set flag $kept
    foreach {axis value previous short same} [list \
        x $x $previousX $X_SHORT $X_SAME y $y $previousY $Y_SHORT $Y_SAME] {
      set delta [expr {$value - $previous}]
      if {$delta == 0} {
        set flag [expr {$flag | $same}]
      } elseif {abs($delta) <= 255} {
        set flag [expr {$flag | $short}]
        if {$delta > 0} {
          set flag [expr {$flag | $same}]
        }
        append ${axis}Bytes [binary format cu [expr {abs($delta)}]]
      } else {
        append ${axis}Bytes [binary format S $delta]
      }
    }
    lappend flagBytes $flag
    set previousX $x
    set previousY $y
  }

  # Runs of identical flags collapse into one flag plus a count. Skipping this
  # is legal and costs about a fifth of the table.
  set packed {}
  for {set index 0} {$index < [llength $flagBytes]} {incr index} {
    set flag [lindex $flagBytes $index]
    set repeat 0
    while {$repeat < 255 && [lindex $flagBytes [expr {$index + $repeat + 1}]] eq $flag} {
      incr repeat
    }
    if {$repeat} {
      append packed [binary format cucu [expr {$flag | $REPEAT}] $repeat]
      incr index $repeat
    } else {
      append packed [binary format cu $flag]
    }
  }

  set instructions [dict get $glyph instructions]
  set data [binary format S [llength $ends]]
  append data [binary format SSSS {*}[Bounds $xs $ys]]
  foreach end $ends {
    append data [binary format Su $end]
  }
  append data [binary format Su [string length $instructions]] $instructions
  append data $packed $xBytes $yBytes
  return $data
}

# The bounding box of a set of points. On an empty set the four zeros a reader
# expects, rather than an error - a glyph may legitimately have no points.
proc ::tclpdf::glyfOutline::Bounds {xs ys} {
  if {![llength $xs]} {
    return {0 0 0 0}
  }
  return [list [::tcl::mathfunc::min {*}$xs] [::tcl::mathfunc::min {*}$ys] \
      [::tcl::mathfunc::max {*}$xs] [::tcl::mathfunc::max {*}$ys]]
}

package provide tclpdf::glyfOutline 1.0
