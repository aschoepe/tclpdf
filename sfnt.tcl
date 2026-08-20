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
#   CFF   the header and the first Top DICT only - is the font CID-keyed?
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
  # OTTO means the outlines are CFF rather than TrueType. Everything ELSE in
  # such a file is the same sfnt structure - cmap, hmtx, head, OS/2, post are
  # all read below without knowing the difference. So the file is parsed here
  # and only the outline side is marked; what cannot be done with CFF outlines
  # (subsetting, which needs glyf) is decided where it is done, not here.
  set outlines truetype
  if {$signature eq "OTTO"} {
    set outlines cff
  }
  if {$signature eq "ttcf"} {
    return -code error "tclpdf: this is a TrueType collection - extract the\
        single face you want first"
  }
  if {$outlines eq "truetype" && $tag != 0x00010000 && $signature ne "true"} {
    return -code error "tclpdf: not a TrueType or OpenType font (signature\
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
  # An OTTO file without a CFF table has no outlines at all - the signature
  # promises them in that table and nowhere else (OpenType spec, "OTTO").
  set requiredTables {head hhea hmtx maxp}
  if {$outlines eq "cff"} {
    lappend requiredTables "CFF "
  }
  foreach required $requiredTables {
    if {![dict exists $tables $required]} {
      return -code error "tclpdf: the font has no \"$required\" table and\
          cannot be embedded"
    }
  }

  set font [dict create bytes $bytes tables $tables outlines $outlines]
  set font [dict merge $font [ParseHead $bytes $tables]]
  set font [dict merge $font [ParseMetrics $bytes $tables \
      [dict get $font numGlyphs]]]
  if {[dict exists $tables cmap]} {
    dict set font cmap [ParseCmap $bytes $tables]
  } else {
    dict set font cmap {}
  }
  # loca and glyf belong to TrueType outlines. A CFF font has neither, and its
  # outlines are not walked here at all - which is why it cannot be subsetted
  # by this package and goes in whole.
  if {$outlines eq "cff"} {
    dict set font loca {}
    dict set font cidKeyed [ParseCffCidKeyed $bytes $tables]
  } else {
    dict set font cidKeyed 0
    dict set font loca [ParseLoca $bytes $tables \
        [dict get $font indexToLocFormat] [dict get $font numGlyphs]]
  }
  dict set font fsType [ParseFsType $bytes $tables]
  dict set font italicAngle [ParsePost $bytes $tables]
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
      if {$code >= 0xD800 && $code <= 0xDFFF} {
        # Surrogate code points are not characters and OpenType forbids them
        # in a cmap; passed through, one would end up as a lone surrogate in
        # the ToUnicode CMap, whose targets ISO 32000-2 9.10.3 requires to be
        # well-formed UTF-16BE strings.
        continue
      }
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
  # The group count steers the loop below, so it is checked before it is
  # believed: a corrupt count read as an unsigned 32-bit value would send
  # the loop reading billions of groups past the end of the file.
  set room [expr {[string length $bytes] - $position - 16}]
  if {$nGroups * 12 > $room} {
    return -code error "tclpdf: the cmap table is damaged - format 12\
        declares $nGroups groups where only $room bytes follow"
  }
  set map {}
  for {set group 0} {$group < $nGroups} {incr group} {
    set at [expr {$position + 16 + $group * 12}]
    binary scan $bytes @${at}IuIuIu start end startGlyph
    # Same reason as above: end steers the inner loop, and a corrupt end of
    # 0xFFFFFFFF would keep it running for four billion iterations. Unicode
    # ends at 0x10FFFF, so anything beyond is damage, not data.
    if {$start > $end} {
      return -code error "tclpdf: the cmap table is damaged - format 12\
          group $group ends (0x[format %X $end]) before it starts\
          (0x[format %X $start])"
    }
    if {$end > 0x10FFFF} {
      return -code error "tclpdf: the cmap table is damaged - format 12\
          group $group ends at 0x[format %X $end], beyond the last Unicode\
          code point 0x10FFFF"
    }
    for {set code $start} {$code <= $end} {incr code} {
      if {$code >= 0xD800 && $code <= 0xDFFF} {
        # Surrogate code points are not characters and OpenType forbids them
        # in a cmap; passed through, one would end up as a lone surrogate in
        # the ToUnicode CMap, whose targets ISO 32000-2 9.10.3 requires to be
        # well-formed UTF-16BE strings.
        continue
      }
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
# Whether the CFF table holds a CID-keyed font - the one thing about CFF that
# has to be known before embedding, and the only thing read from that table.
#
# A CFF font is either name-keyed or CID-keyed, and the difference decides
# what a glyph number in the PDF MEANS. ISO 32000-1 9.7.4.2: for a CIDFontType0
# whose program is not CID-keyed the CID is the glyph index; for a CID-keyed
# one the CID is looked up in the program's charset. This package addresses
# glyphs by index through Identity-H, which is right for the first kind and
# silently wrong for the second wherever charset is not the identity - no
# validator notices, only the wrong glyph on the page. Measured on Hiragino
# Sans GB W3 (macOS): 288 of 29352 glyphs sit under a CID that is not their
# index.
#
# The mark is the ROS operator (escape 12 30) in the Top DICT, which a CID
# font MUST carry and MUST carry first (CFF spec, TN 5176 section 18). The
# whole DICT is walked nevertheless: it costs nothing and does not depend on a
# producer having read that sentence. To get there: header (TN 5176 section 6;
# hdrSize at byte 2), Name INDEX, Top DICT INDEX (section 5 for INDEX, section
# 4 for the DICT data). Nothing past the first Top DICT is read.
proc ::tclpdf::sfnt::ParseCffCidKeyed {bytes tables} {
  lassign [dict get $tables "CFF "] position length
  set cff [string range $bytes $position [expr {$position + $length - 1}]]
  if {[string length $cff] < 4} {
    return -code error "tclpdf: the CFF table is too short to hold a font"
  }
  binary scan $cff @2cu hdrSize
  lassign [CffIndex $cff $hdrSize] next -
  lassign [CffIndex $cff $next] - topDict
  if {$topDict eq {}} {
    # count 0: an INDEX with nothing in it. A CFF with no Top DICT describes
    # no font, so there is nothing to embed.
    return -code error "tclpdf: the CFF table has an empty Top DICT INDEX -\
        it describes no font"
  }
  return [CffDictHasOperator $topDict 12 30]
}

# One CFF INDEX (TN 5176 section 5): count, offSize, count+1 offsets that are
# 1-based into the data that follows. Returns the position just past the INDEX
# and its FIRST item - all this package ever needs from one. count 0 is a
# two-byte INDEX with no offSize and no data at all.
proc ::tclpdf::sfnt::CffIndex {cff at} {
  if {[binary scan $cff @${at}Su count] != 1} {
    return -code error "tclpdf: the CFF table is truncated"
  }
  if {$count == 0} {
    return [list [expr {$at + 2}] {}]
  }
  binary scan $cff @[expr {$at + 2}]cu offSize
  if {$offSize < 1 || $offSize > 4} {
    return -code error "tclpdf: the CFF table has an INDEX with offSize\
        $offSize, which the format does not allow (1 to 4)"
  }
  set at [expr {$at + 3}]
  set offsets {}
  # Two offsets suffice for the first item; the last one says where the INDEX
  # ends. offSize 3 has no binary-scan format, so every size is folded from
  # bytes.
  foreach index [list 0 1 $count] {
    if {[binary scan $cff @[expr {$at + $index * $offSize}]cu$offSize digits] != 1
        || [llength $digits] != $offSize} {
      return -code error "tclpdf: the CFF table is truncated"
    }
    set value 0
    foreach digit $digits {
      set value [expr {$value * 256 + $digit}]
    }
    lappend offsets $value
  }
  lassign $offsets first second last
  set data [expr {$at + ($count + 1) * $offSize - 1}]
  return [list [expr {$data + $last}] \
      [string range $cff [expr {$data + $first}] [expr {$data + $second - 1}]]]
}

# Whether a CFF DICT (TN 5176 section 4) carries the operator b0 - or, with b0
# 12, the escaped operator b1. Operands are skipped by their own encoding:
# 28 and 29 carry two and four bytes, 30 is a real number of nibbles up to one
# that is 0xf, 32 to 254 are integers of one to three bytes; 0 to 21 are
# operators, 12 the escape. Reading operands as operators would find the
# number 30 where no ROS is - hence the walk instead of a byte search.
proc ::tclpdf::sfnt::CffDictHasOperator {dict b0 {b1 {}}} {
  set length [string length $dict]
  set at 0
  while {$at < $length} {
    binary scan $dict @${at}cu byte
    if {$byte <= 21} {
      if {$byte == 12} {
        binary scan $dict @[expr {$at + 1}]cu escaped
        if {$b0 == 12 && $escaped == $b1} {
          return 1
        }
        incr at 2
      } else {
        if {$byte == $b0 && $b1 eq {}} {
          return 1
        }
        incr at
      }
    } elseif {$byte == 28} {
      incr at 3
    } elseif {$byte == 29} {
      incr at 5
    } elseif {$byte == 30} {
      incr at
      while {$at < $length} {
        binary scan $dict @${at}cu nibbles
        incr at
        if {($nibbles & 0x0f) == 0x0f || ($nibbles >> 4) == 0x0f} {
          break
        }
      }
    } elseif {$byte <= 246} {
      incr at
    } elseif {$byte <= 254} {
      incr at 2
    } else {
      # 22 to 27, 31 and 255 are reserved; one byte each, on the way past.
      incr at
    }
  }
  return 0
}

# fsType from OS/2, or {} for a face without that table: an absent
# permission is not permission 0, and [permission] says so.
proc ::tclpdf::sfnt::ParseFsType {bytes tables} {
  if {![dict exists $tables OS/2]} {
    return {}
  }
  lassign [dict get $tables OS/2] position -
  binary scan $bytes @[expr {$position + 8}]Su fsType
  return $fsType
}

# The italic angle the post table states (offset 4, 16.16 fixed), in degrees
# counter-clockwise from the vertical - so an oblique face reports a negative
# number, -12 for Nimbus Sans Oblique. Zero for an upright face and for a
# font without a post table.
#
# It goes into the font descriptor as /ItalicAngle, which Table 122 requires;
# it was written as a constant 0 for every face until this was read, and the
# header of this file claimed the table was read all along.
proc ::tclpdf::sfnt::ParsePost {bytes tables} {
  if {![dict exists $tables post]} {
    return 0
  }
  lassign [dict get $tables post] position length
  if {$length < 8} {
    return 0
  }
  binary scan $bytes @[expr {$position + 4}]I fixed
  set angle [expr {$fixed / 65536.0}]
  return [expr {$angle == int($angle) ? int($angle) : $angle}]
}

# What fsType permits, in words - the whole of it, not the low nibble alone.
#
# Bits 0-3 say whether embedding is allowed at all; bit 8 (0x0100) forbids
# SUBSETTING and bit 9 (0x0200) allows bitmaps only (OpenType "OS/2",
# fsType). Read as the low four bits only, 0x0100 answered "installable",
# which is the one word that must not be said of a face whose vendor forbids
# the very thing this package does to it. The two upper bits are appended
# where set, so the answer to a face that permits embedding but not
# subsetting names both. An empty fsType - no OS/2 table at all - is not 0:
# the file has stated nothing, and "unknown" is the honest word.
proc ::tclpdf::sfnt::permission {fsType} {
  if {$fsType eq {}} {
    return "unknown - the face has no OS/2 table and states no permission"
  }
  # Bits 1, 2 and 3 are mutually exclusive by the specification - a font that
  # sets several is malformed, and saying so beats picking one.
  set bits [expr {$fsType & 0x000F}]
  switch -- $bits {
    0 {set words "installable - no restriction on embedding"}
    2 {set words "restricted - the vendor does not permit embedding"}
    4 {set words "preview and print only"}
    8 {set words "editable"}
    default {
      set words "unclear - fsType $fsType sets several exclusive bits"
    }
  }
  if {$fsType & 0x0100} {
    append words "; no subsetting (bit 8)"
  }
  if {$fsType & 0x0200} {
    append words "; bitmap embedding only (bit 9)"
  }
  return $words
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
    set value [NameString $bytes $start $length $platform]
    set key [expr {$nameId == 6 ? "postScript" : "family"}]
    if {![dict exists $names $key]} {
      dict set names $key $value
    }
  }
  return $names
}

# One name record by its id, or the empty string.
#
# ParseNames keeps only the two names a PDF needs; this reaches any of them,
# which is what the named instances of a variable font are addressed by - their
# ids start at 256 and mean nothing without the table.
proc ::tclpdf::sfnt::name {parsed nameId} {
  set tables [dict get $parsed tables]
  if {![dict exists $tables name]} {
    return {}
  }
  set bytes [dict get $parsed bytes]
  lassign [dict get $tables name] position -
  binary scan $bytes @[expr {$position + 2}]SuSu count stringOffset
  for {set index 0} {$index < $count} {incr index} {
    set at [expr {$position + 6 + $index * 12}]
    binary scan $bytes @${at}SuSuSuSuSuSu platform encoding language id length offset
    if {$id != $nameId} {
      continue
    }
    set start [expr {$position + $stringOffset + $offset}]
    return [NameString $bytes $start $length $platform]
  }
  return {}
}

# One string from the name table, decoded by the platform that wrote it.
#
# Windows (3) and Unicode (0) platform strings are both UTF-16BE. Only the
# first was decoded here once, and platform 0 came out raw - with a NUL between
# every letter, which then went into the PDF as /HOVCJQ+#00T#00i#00m..., a name
# qpdf refuses ("null character not allowed in name token"). Whichever record
# comes FIRST wins, so that only showed on a font leading with platform 0 -
# measured over 210 faces on this machine, 20 of them do, Times New Roman among
# them. Macintosh (1) is one byte per character and must not come through here.
proc ::tclpdf::sfnt::NameString {bytes start length platform} {
  set value [string range $bytes $start [expr {$start + $length - 1}]]
  if {$platform != 3 && $platform != 0} {
    return $value
  }
  set decoded {}
  binary scan $value Su* units
  foreach unit $units {
    append decoded [format %c $unit]
  }
  return $decoded
}

package provide tclpdf::sfnt 1.5
