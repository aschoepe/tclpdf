#
# tclpdf - PDF generation for Tcl
#
# sfnt - reading TrueType font files
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# A private sub-module behind the font facade - nothing outside font.tcl and
# subset.tcl loads this. It knows the file format and nothing about PDF.
#
# Only what embedding actually needs is parsed:
#
#   head  units per em, the bounding box, the loca format
#   hhea  number of horizontal metrics
#   hmtx  advance widths
#   maxp  number of glyphs
#   cmap  Unicode to glyph id (formats 4 and 12)
#   loca  where each glyph sits in glyf
#   glyf  the outlines - only walked, never interpreted
#   OS/2  fsType, the flag saying what the vendor permits
#   post  italic angle
#
# All values are big-endian regardless of the machine, which is what every
# "S"/"I" in the binary scans below is about. Getting one wrong yields a font
# that a reader loads and renders as garbage, without an error.
#

package require Tcl 8.6.11-
package require tclpdf::io 1.0-

namespace eval ::tclpdf::sfnt {
  namespace export {[a-z]*}
  namespace ensemble create
}

# Read a font file and return everything the other modules need, as a dict.
proc ::tclpdf::sfnt::read {path} {
  set bytes [::tclpdf::io read $path]
  return [parse $bytes]
}

proc ::tclpdf::sfnt::parse {bytes} {
  if {[string length $bytes] < 12} {
    return -code error "tclpdf: not a font file - too short"
  }
  binary scan $bytes Iu tag
  # 0x00010000 is TrueType outlines, "true" is the old Apple spelling, "ttcf"
  # a collection. OTTO means CFF outlines, which cannot be embedded as
  # FontFile2 - saying so is more useful than failing later on a missing glyf.
  set signature [string range $bytes 0 3]
  if {$signature eq "OTTO"} {
    return -code error "tclpdf: this is an OpenType/CFF font - tclpdf embeds\
        TrueType outlines (FontFile2). Convert it to TTF first"
  }
  if {$signature eq "ttcf"} {
    return -code error "tclpdf: this is a TrueType collection - extract the\
        single face you want first"
  }
  if {$tag != 0x00010000 && $signature ne "true"} {
    return -code error "tclpdf: not a TrueType font (signature\
        0x[format %08X $tag])"
  }

  binary scan $bytes @4Su numTables
  set tables {}
  for {set index 0} {$index < $numTables} {incr index} {
    set offset [expr {12 + $index * 16}]
    binary scan $bytes @${offset}a4IuIuIu name checksum position length
    dict set tables $name [list $position $length]
  }
  # cmap is NOT required: a subset built by subset.tcl deliberately carries
  # none, because with Identity-H the PDF addresses glyphs directly. Demanding
  # it here would make the package unable to re-read its own output.
  foreach required {head hhea hmtx maxp} {
    if {![dict exists $tables $required]} {
      return -code error "tclpdf: the font has no \"$required\" table and\
          cannot be embedded"
    }
  }

  set font [dict create bytes $bytes tables $tables]
  set font [dict merge $font [ParseHead $bytes $tables]]
  set font [dict merge $font [ParseMetrics $bytes $tables \
      [dict get $font numGlyphs]]]
  if {[dict exists $tables cmap]} {
    dict set font cmap [ParseCmap $bytes $tables]
  } else {
    dict set font cmap {}
  }
  dict set font loca [ParseLoca $bytes $tables [dict get $font indexToLocFormat] \
      [dict get $font numGlyphs]]
  dict set font fsType [ParseFsType $bytes $tables]
  dict set font names [ParseNames $bytes $tables]
  return $font
}

# The raw bytes of one table, or {} when it is absent.
proc ::tclpdf::sfnt::table {font name} {
  set tables [dict get $font tables]
  if {![dict exists $tables $name]} {
    return {}
  }
  lassign [dict get $tables $name] position length
  return [string range [dict get $font bytes] $position [expr {$position + $length - 1}]]
}

proc ::tclpdf::sfnt::ParseHead {bytes tables} {
  lassign [dict get $tables head] position -
  binary scan $bytes @[expr {$position + 18}]Su unitsPerEm
  binary scan $bytes @[expr {$position + 36}]SSSS xMin yMin xMax yMax
  binary scan $bytes @[expr {$position + 44}]S macStyle
  binary scan $bytes @[expr {$position + 50}]S indexToLocFormat
  if {$unitsPerEm == 0} {
    return -code error "tclpdf: the font declares unitsPerEm 0"
  }
  lassign [dict get $tables maxp] maxpPosition -
  binary scan $bytes @[expr {$maxpPosition + 4}]Su numGlyphs
  return [dict create unitsPerEm $unitsPerEm bbox [list $xMin $yMin $xMax $yMax] \
      macStyle $macStyle indexToLocFormat $indexToLocFormat numGlyphs $numGlyphs]
}

proc ::tclpdf::sfnt::ParseMetrics {bytes tables numGlyphs} {
  lassign [dict get $tables hhea] position -
  binary scan $bytes @[expr {$position + 4}]SS ascender descender
  binary scan $bytes @[expr {$position + 34}]Su numberOfHMetrics
  lassign [dict get $tables hmtx] hmtxPosition -

  # hmtx holds numberOfHMetrics PAIRS of advance width and left side bearing;
  # every glyph beyond that repeats the LAST advance and keeps a bearing of its
  # own in a short array behind the pairs. A monospaced font stores exactly one
  # pair, and reading only that many widths would leave every other glyph at
  # zero.
  #
  # The bearing is not decoration: a renderer places the outline at cursor plus
  # bearing, so a wrong value MOVES THE GLYPH - and since every glyph has its
  # own, the gaps between letters go uneven rather than the line shifting as a
  # whole. Combining marks sit at negative x, so for them the error is most of
  # an em.
  set widths {}
  set bearings {}
  set last 0
  for {set glyph 0} {$glyph < $numberOfHMetrics} {incr glyph} {
    binary scan $bytes @[expr {$hmtxPosition + $glyph * 4}]SuS advance bearing
    lappend widths $advance
    lappend bearings $bearing
    set last $advance
  }
  set extra [expr {$hmtxPosition + $numberOfHMetrics * 4}]
  for {set glyph $numberOfHMetrics} {$glyph < $numGlyphs} {incr glyph} {
    set at [expr {$extra + ($glyph - $numberOfHMetrics) * 2}]
    if {$at + 2 > [string length $bytes]} {
      # A font may end the table early. Those glyphs have no bearing of their
      # own, and zero is the only honest answer.
      lappend bearings 0
    } else {
      binary scan $bytes @${at}S bearing
      lappend bearings $bearing
    }
  }
  return [dict create ascender $ascender descender $descender \
      numberOfHMetrics $numberOfHMetrics widths $widths bearings $bearings \
      lastWidth $last]
}

# The advance width of a glyph, in font units.
proc ::tclpdf::sfnt::advance {font glyph} {
  set widths [dict get $font widths]
  if {$glyph < [llength $widths]} {
    return [lindex $widths $glyph]
  }
  return [dict get $font lastWidth]
}

# The left side bearing of a glyph, in font units. Always equal to the glyph's
# xMin in a well-formed font - head flag bit 1 says so - which is why a
# renderer may use either and why writing a wrong one goes unnoticed for a long
# time.
proc ::tclpdf::sfnt::bearing {font glyph} {
  set bearings [dict get $font bearings]
  if {$glyph < [llength $bearings]} {
    return [lindex $bearings $glyph]
  }
  return 0
}

# Unicode to glyph id. Formats 4 (BMP) and 12 (full range) are read; a font
# without either cannot be used for text.
proc ::tclpdf::sfnt::ParseCmap {bytes tables} {
  lassign [dict get $tables cmap] position -
  binary scan $bytes @[expr {$position + 2}]Su numSubtables
  set best {}
  set bestScore -1
  for {set index 0} {$index < $numSubtables} {incr index} {
    set entry [expr {$position + 4 + $index * 8}]
    binary scan $bytes @${entry}SuSuIu platform encoding subOffset
    # Preference: Windows/UCS-4 (3,10), Windows/BMP (3,1), Unicode (0,x).
    set score -1
    if {$platform == 3 && $encoding == 10} {
      set score 3
    } elseif {$platform == 3 && $encoding == 1} {
      set score 2
    } elseif {$platform == 0} {
      set score 1
    }
    if {$score > $bestScore} {
      set bestScore $score
      set best [expr {$position + $subOffset}]
    }
  }
  if {$best eq {}} {
    return -code error "tclpdf: the font has no usable Unicode cmap"
  }
  binary scan $bytes @${best}Su format
  switch -- $format {
    4 {return [CmapFormat4 $bytes $best]}
    12 {return [CmapFormat12 $bytes $best]}
    default {
      return -code error "tclpdf: cmap format $format is not supported -\
          tclpdf reads formats 4 and 12"
    }
  }
}

proc ::tclpdf::sfnt::CmapFormat4 {bytes position} {
  binary scan $bytes @[expr {$position + 6}]Su segCountX2
  set segCount [expr {$segCountX2 / 2}]
  set endBase [expr {$position + 14}]
  set startBase [expr {$endBase + $segCountX2 + 2}]
  set deltaBase [expr {$startBase + $segCountX2}]
  set rangeBase [expr {$deltaBase + $segCountX2}]
  set map {}
  for {set segment 0} {$segment < $segCount} {incr segment} {
    set two [expr {$segment * 2}]
    binary scan $bytes @[expr {$endBase + $two}]Su end
    binary scan $bytes @[expr {$startBase + $two}]Su start
    binary scan $bytes @[expr {$deltaBase + $two}]S delta
    binary scan $bytes @[expr {$rangeBase + $two}]Su rangeOffset
    if {$start > $end || $start == 0xFFFF} {
      continue
    }
    for {set code $start} {$code <= $end} {incr code} {
      if {$rangeOffset == 0} {
        set glyph [expr {($code + $delta) & 0xFFFF}]
      } else {
        # The infamous indirection: rangeOffset counts BYTES from its own
        # position in the array, not from the start of the table.
        set at [expr {$rangeBase + $two + $rangeOffset + ($code - $start) * 2}]
        if {$at + 1 >= [string length $bytes]} {
          continue
        }
        binary scan $bytes @${at}Su glyph
        if {$glyph != 0} {
          set glyph [expr {($glyph + $delta) & 0xFFFF}]
        }
      }
      if {$glyph != 0} {
        dict set map $code $glyph
      }
    }
  }
  return $map
}

proc ::tclpdf::sfnt::CmapFormat12 {bytes position} {
  binary scan $bytes @[expr {$position + 12}]Iu nGroups
  set map {}
  for {set group 0} {$group < $nGroups} {incr group} {
    set at [expr {$position + 16 + $group * 12}]
    binary scan $bytes @${at}IuIuIu start end startGlyph
    for {set code $start} {$code <= $end} {incr code} {
      dict set map $code [expr {$startGlyph + $code - $start}]
    }
  }
  return $map
}

# Glyph offsets. The loca table is either 16-bit (halved offsets) or 32-bit,
# and which one is decided by head.indexToLocFormat - reading the wrong width
# yields offsets that are off by a factor of two and glyphs made of noise.
proc ::tclpdf::sfnt::ParseLoca {bytes tables format numGlyphs} {
  if {![dict exists $tables loca]} {
    # A font without glyf/loca (CFF outlines) - already rejected above, but a
    # subset cannot be built either way.
    return {}
  }
  lassign [dict get $tables loca] position -
  set offsets {}
  for {set index 0} {$index <= $numGlyphs} {incr index} {
    if {$format == 0} {
      binary scan $bytes @[expr {$position + $index * 2}]Su value
      lappend offsets [expr {$value * 2}]
    } else {
      binary scan $bytes @[expr {$position + $index * 4}]Iu value
      lappend offsets $value
    }
  }
  return $offsets
}

# The embedding permission the vendor recorded (OS/2, offset 8).
#
# tclpdf reads and reports it but does not refuse on it: no PDF reader and no
# validator enforces it either, and a package that silently declines to embed
# a font the user owns a licence for is the more harmful of the two errors.
proc ::tclpdf::sfnt::ParseFsType {bytes tables} {
  if {![dict exists $tables OS/2]} {
    return 0
  }
  lassign [dict get $tables OS/2] position -
  binary scan $bytes @[expr {$position + 8}]Su fsType
  return $fsType
}

# What fsType permits, in words.
proc ::tclpdf::sfnt::permission {fsType} {
  # Bits 1, 2 and 3 are mutually exclusive by the specification - a font that
  # sets several is malformed, and saying so beats picking one.
  set bits [expr {$fsType & 0x000F}]
  switch -- $bits {
    0 {return "installable - no restriction on embedding"}
    2 {return "restricted - the vendor does not permit embedding"}
    4 {return "preview and print only"}
    8 {return "editable"}
    default {
      return "unclear - fsType $fsType sets several exclusive bits"
    }
  }
}

# The PostScript name and the family name, from the name table.
proc ::tclpdf::sfnt::ParseNames {bytes tables} {
  if {![dict exists $tables name]} {
    return {}
  }
  lassign [dict get $tables name] position -
  binary scan $bytes @[expr {$position + 2}]SuSu count stringOffset
  set names {}
  for {set index 0} {$index < $count} {incr index} {
    set at [expr {$position + 6 + $index * 12}]
    binary scan $bytes @${at}SuSuSuSuSuSu platform encoding language nameId length offset
    if {$nameId ni {1 6}} {
      continue
    }
    set start [expr {$position + $stringOffset + $offset}]
    set value [string range $bytes $start [expr {$start + $length - 1}]]
    if {$platform == 3} {
      # Windows platform strings are UTF-16BE.
      set decoded {}
      binary scan $value Su* units
      foreach unit $units {
        append decoded [format %c $unit]
      }
      set value $decoded
    }
    set key [expr {$nameId == 6 ? "postScript" : "family"}]
    if {![dict exists $names $key]} {
      dict set names $key $value
    }
  }
  return $names
}

package provide tclpdf::sfnt 1.0
