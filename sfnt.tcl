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
#   OS/2  fsType, the weight class, the cap and x heights
#   post  italic angle
#   CFF   the header and the first Top DICT only - is the font CID-keyed?
#         A BARE CFF, one with no sfnt around it at all, is read whole
#         instead: see the section at the end of this file
#   vhea  number of vertical metrics
#   vmtx  advance heights and top side bearings - the metric of VERTICAL
#         writing, which hmtx says nothing about
#   VORG  the vertical origin of a CFF face, where it carries one
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
    return -code error -errorcode [list TCLPDF FONT SOURCE sfnt] \
        "tclpdf: not a font file - too short"
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
    return -code error -errorcode [list TCLPDF FONT UNSUPPORTED collection] \
        "tclpdf: this is a TrueType collection - extract the\
        single face you want first"
  }
  if {$outlines eq "truetype" && $tag != 0x00010000 && $signature ne "true"} {
    return -code error -errorcode [list TCLPDF FONT SOURCE sfnt] \
        "tclpdf: not a TrueType or OpenType font (signature\
        0x[format %08X $tag])"
  }

  binary scan $bytes @4Su numTables
  set tables {}
  for {set index 0} {$index < $numTables} {incr index} {
    set offset [expr {12 + $index * 16}]
    # binary scan fills what it can and leaves the rest of the variables
    # unset, reporting how many it filled. Without that count a file whose
    # directory is cut short reads a table entry that is not there and fails
    # on an unset variable - a raw Tcl error where this package promises a
    # message of its own.
    if {[binary scan $bytes @${offset}a4IuIuIu \
            name checksum position length] != 4} {
      return -code error -errorcode [list TCLPDF FONT DAMAGED directory] \
          "tclpdf: the font's table directory is cut short -\
          it announces $numTables tables and the file ends inside entry\
          [expr {$index + 1}]"
    }
    # A TAG APPEARS ONCE. The directory is a set, unique and sorted by tag
    # (OpenType, "Organization of an OpenType Font"), and a second entry for
    # a tag used to overwrite the first without a word - so a file could
    # carry two "head" tables and the reader would silently use whichever
    # came last. The sort order is NOT enforced beside it: files that keep
    # the tags out of order are in circulation and read correctly here, so
    # refusing them would cost more than it buys.
    if {[dict exists $tables $name]} {
      return -code error -errorcode [list TCLPDF FONT DAMAGED directory] \
          "tclpdf: the font's table directory names \"$name\" twice, and a\
          table directory is a set - there is no telling which of the two\
          the file means"
    }
    # THE ENTRY HAS TO POINT INTO THE FILE. Every parser below reads its
    # table through the offset out of this directory, and until this was
    # checked a truncated file or a corrupt offset sent [binary scan] past
    # the end, where it fills nothing and leaves its variables unset: what
    # reached the caller was "can't read \"fixed\": no such variable" with
    # errorCode TCL READ VARNAME, not a refusal of this package. Checked
    # HERE, once, for every table rather than at each of the six reads - the
    # directory is the one place a table's extent is established, and a guard
    # per read would be six copies of one rule.
    if {$position + $length > [string length $bytes]} {
      return -code error -errorcode [list TCLPDF FONT DAMAGED directory] \
          "tclpdf: damaged font - the \"$name\" table is declared at\
          $position for $length bytes and the file is only\
          [string length $bytes] bytes long"
    }
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
      return -code error -errorcode [list TCLPDF FONT TABLE $required] \
          "tclpdf: the font has no \"$required\" table and\
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
  set os2 [ParseOs2 $bytes $tables]
  dict set font os2 $os2
  dict set font fsType [dict get $os2 fsType]
  dict set font italicAngle [ParsePost $bytes $tables]
  dict set font names [ParseNames $bytes $tables]
  # The vertical metrics, or {} for the overwhelming majority of faces that
  # carry none. Read here with the rest because it is three short tables and
  # not one of the large ones; what it costs a Latin document is one dict
  # lookup that misses.
  dict set font vertical [ParseVertical $bytes $tables [dict get $font numGlyphs]]
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

# Where a table starts, refused where the directory declares it too short for
# the fixed fields the parser is about to read out of it.
#
# The extent check in [parse] settles that a table lies INSIDE the file; this
# settles that it is long enough for its own format, which is the second half
# of the same guarantee - a "head" declared as twenty bytes sits in the file
# and still cannot hold what a head holds, and reading indexToLocFormat out of
# it left [binary scan] with nothing to fill and the caller with an unset
# variable. The refusal names the DIRECTORY rather than the table, because the
# directory is where the length that is wrong was stated.
proc ::tclpdf::sfnt::TableAt {tables tag wanted} {
  lassign [dict get $tables $tag] position length
  if {$length < $wanted} {
    return -code error -errorcode [list TCLPDF FONT DAMAGED directory] \
        "tclpdf: damaged font - the directory declares the \"$tag\" table as\
        $length bytes, and a $tag table holds at least $wanted"
  }
  return $position
}

proc ::tclpdf::sfnt::ParseHead {bytes tables} {
  # 54 bytes is the whole of head, 6 the least a maxp can be (version 0.5,
  # which is numGlyphs and nothing else).
  set position [TableAt $tables head 54]
  binary scan $bytes @[expr {$position + 18}]Su unitsPerEm
  binary scan $bytes @[expr {$position + 36}]SSSS xMin yMin xMax yMax
  binary scan $bytes @[expr {$position + 44}]S macStyle
  binary scan $bytes @[expr {$position + 50}]S indexToLocFormat
  if {$unitsPerEm == 0} {
    return -code error -errorcode [list TCLPDF FONT METRICS unitsPerEm] \
        "tclpdf: the font declares unitsPerEm 0"
  }
  set maxpPosition [TableAt $tables maxp 6]
  binary scan $bytes @[expr {$maxpPosition + 4}]Su numGlyphs
  return [dict create unitsPerEm $unitsPerEm bbox [list $xMin $yMin $xMax $yMax] \
      macStyle $macStyle indexToLocFormat $indexToLocFormat numGlyphs $numGlyphs]
}

proc ::tclpdf::sfnt::ParseMetrics {bytes tables numGlyphs} {
  set position [TableAt $tables hhea 36]
  # The three numbers that make a line, in that order at offset 4: the
  # ascender, the descender (negative) and the gap BETWEEN two lines, which
  # is neither of the other two and which nothing here read until [font info]
  # was asked for it.
  binary scan $bytes @[expr {$position + 4}]SSS ascender descender lineGap
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
  # THE PAIRS ARE NOT OPTIONAL, unlike the bearings behind them: hhea says how
  # many there are and every one of them is a glyph's advance width. A file
  # that ends inside them is cut short, and reading on gave an unset variable
  # rather than a refusal. Measured against the FILE rather than against the
  # declared table length, so that the widespread habit of declaring hmtx a
  # few bytes short of its tail costs nothing.
  if {$hmtxPosition + $numberOfHMetrics * 4 > [string length $bytes]} {
    return -code error -errorcode [list TCLPDF FONT DAMAGED directory] \
        "tclpdf: damaged font - hhea announces $numberOfHMetrics horizontal\
        metrics and the file ends inside the \"hmtx\" table that holds them"
  }
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
      lineGap $lineGap \
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

# -- vertical metrics -------------------------------------------------------
#
# WHAT hmtx SAYS DOES NOT CARRY OVER. In horizontal writing a glyph advances
# by its width and sits on a baseline; in vertical writing it advances by its
# HEIGHT and hangs from a vertical origin, and neither number is in hmtx. The
# two are independent: in Noto Sans JP the Latin "A" is 654 units wide and
# 1000 units tall, and a vertical line set from the horizontal advances would
# come out at two thirds of its proper length with every glyph overlapping the
# one above it.
#
# THE THREE TABLES:
#
#   vhea  the header - numOfLongVerMetrics, laid out exactly like hhea
#   vmtx  numOfLongVerMetrics pairs of advance height and TOP side bearing,
#         then one bearing per remaining glyph, exactly like hmtx
#   VORG  the vertical origin outright, one y per glyph over a default. An
#         OpenType/CFF table: a TrueType face computes the origin from vmtx
#         instead, and Noto Sans JP - measured - carries no VORG at all
#
# THE ORIGIN IS NOT IN vmtx DIRECTLY, and this is the one place the format
# asks for arithmetic. The top side bearing is the gap between the vertical
# origin and the TOP OF THE GLYPH'S BOX, so the origin is yMax + tsb - which
# is why [verticalOriginY] needs the box handed to it: the box of an INSTANCE
# of a variable face is not the box in the file, and only font.tcl knows
# whether it is looking at one.
#
# {} throughout for a face that has none of it, because "no vertical metric"
# is a real answer and PDF has a defined default for it (ISO 32000-2,
# 9.7.4.3: /DW2 [880 -1000]). Making one up here would hide from the caller
# that it is the default they are getting.
proc ::tclpdf::sfnt::ParseVertical {bytes tables numGlyphs} {
  set vertical {}
  if {[dict exists $tables vhea] && [dict exists $tables vmtx]} {
    # vhea is hhea with the axes exchanged and is the same 36 bytes; the
    # number of long vertical metrics sits at its very end, so a shorter one
    # cannot be read at all. Refused rather than passed over, and under the
    # part subset.tcl already refuses a short vhea under.
    lassign [dict get $tables vhea] position vheaLength
    if {$vheaLength < 36} {
      return -code error -errorcode [list TCLPDF FONT DAMAGED vhea] \
          "tclpdf: the font's \"vhea\" table is $vheaLength bytes and cannot\
          describe its vertical metrics"
    }
    binary scan $bytes @[expr {$position + 4}]SS ascender descender
    # Offset 34, the same place hhea keeps numberOfHMetrics: vhea is that
    # header with the axes exchanged (ISO/IEC 14496-22, "vhea").
    binary scan $bytes @[expr {$position + 34}]Su numOfLongVerMetrics
    lassign [dict get $tables vmtx] vmtxPosition -
    set advances {}
    set bearings {}
    set last 0
    for {set glyph 0} {$glyph < $numOfLongVerMetrics} {incr glyph} {
      set at [expr {$vmtxPosition + $glyph * 4}]
      if {[binary scan $bytes @${at}SuS advance bearing] != 2} {
        break
      }
      lappend advances $advance
      lappend bearings $bearing
      set last $advance
    }
    # The tail: a bearing of its own per glyph, and the LAST advance for all
    # of them - the same rule hmtx follows, and getting it wrong the other way
    # gives every glyph past the table a height of zero.
    set extra [expr {$vmtxPosition + $numOfLongVerMetrics * 4}]
    for {set glyph $numOfLongVerMetrics} {$glyph < $numGlyphs} {incr glyph} {
      set at [expr {$extra + ($glyph - $numOfLongVerMetrics) * 2}]
      if {$at + 2 > [string length $bytes]} {
        lappend bearings 0
      } else {
        binary scan $bytes @${at}S bearing
        lappend bearings $bearing
      }
    }
    set vertical [dict create advances $advances bearings $bearings \
        lastAdvance $last numOfLongVerMetrics $numOfLongVerMetrics \
        ascender $ascender descender $descender]
  }
  if {[dict exists $tables VORG]} {
    lassign [dict get $tables VORG] position length
    if {$length >= 8} {
      binary scan $bytes @[expr {$position + 4}]SSu defaultOriginY count
      dict set vertical originDefault $defaultOriginY
      set origins {}
      for {set index 0} {$index < $count} {incr index} {
        set at [expr {$position + 8 + $index * 4}]
        if {[binary scan $bytes @${at}SuS glyph originY] != 2} {
          break
        }
        dict set origins $glyph $originY
      }
      dict set vertical origins $origins
    }
  }
  return $vertical
}

# Has this face a metric for vertical writing at all?
proc ::tclpdf::sfnt::hasVertical {font} {
  return [expr {[dict exists $font vertical]
      && [dict size [dict get $font vertical]] > 0}]
}

# The advance HEIGHT of a glyph, in font units, or {} where the face carries
# no vmtx. The caller decides what to do with {} - font.tcl falls back on the
# PDF default, which is the em.
proc ::tclpdf::sfnt::verticalAdvance {font glyph} {
  if {![dict exists $font vertical advances]} {
    return {}
  }
  set advances [dict get $font vertical advances]
  if {$glyph < [llength $advances]} {
    return [lindex $advances $glyph]
  }
  return [dict get $font vertical lastAdvance]
}

# The TOP side bearing of a glyph, in font units, or {} where there is none.
proc ::tclpdf::sfnt::verticalBearing {font glyph} {
  if {![dict exists $font vertical bearings]} {
    return {}
  }
  set bearings [dict get $font vertical bearings]
  if {$glyph < [llength $bearings]} {
    return [lindex $bearings $glyph]
  }
  return 0
}

# The y of a glyph's VERTICAL ORIGIN in font units - the point the glyph hangs
# from - or {} where the face says nothing about it.
#
# VORG wins where it exists, because it is the answer outright. Otherwise it
# is yMax + top side bearing, and YMAX IS THE CALLER'S to supply: for an
# instance of a variable face the box has moved, and this module knows nothing
# of instances. {} for yMax means an empty outline - a space - whose box is
# degenerate and counts as zero, which is what leaves the origin at the
# bearing alone.
proc ::tclpdf::sfnt::verticalOriginY {font glyph yMax} {
  if {[dict exists $font vertical origins $glyph]} {
    return [dict get $font vertical origins $glyph]
  }
  if {[dict exists $font vertical originDefault]} {
    return [dict get $font vertical originDefault]
  }
  set bearing [verticalBearing $font $glyph]
  if {$bearing eq {}} {
    return {}
  }
  return [expr {($yMax eq {} ? 0 : $yMax) + $bearing}]
}

# Unicode to glyph id. Formats 4 (BMP) and 12 (full range) are read; a font
# without either cannot be used for text.
proc ::tclpdf::sfnt::ParseCmap {bytes tables} {
  # Four bytes of header: the version and the number of subtables.
  set position [TableAt $tables cmap 4]
  binary scan $bytes @[expr {$position + 2}]Su numSubtables
  set best {}
  set bestScore -1
  for {set index 0} {$index < $numSubtables} {incr index} {
    set entry [expr {$position + 4 + $index * 8}]
    # The count steers the loop and is believed only as far as the file
    # reaches: a cmap announcing more subtables than it holds used to read a
    # record that is not there and fail on an unset variable.
    if {[binary scan $bytes @${entry}SuSuIu platform encoding subOffset] != 3} {
      return -code error -errorcode [list TCLPDF FONT DAMAGED cmap] \
          "tclpdf: the font's cmap announces $numSubtables subtables and the\
          file ends inside record [expr {$index + 1}]"
    }
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
    return -code error -errorcode [list TCLPDF FONT ENCODING cmap] \
        "tclpdf: the font has no usable Unicode cmap"
  }
  # The chosen record's own offset is a second thing the file states and may
  # get wrong - it is counted from the start of the cmap table and may point
  # anywhere, the end of the file included.
  if {[binary scan $bytes @${best}Su format] != 1} {
    return -code error -errorcode [list TCLPDF FONT DAMAGED cmap] \
        "tclpdf: the font's cmap points its subtable at offset $best, which is\
        past the end of the file"
  }
  switch -- $format {
    4 {return [CmapFormat4 $bytes $best]}
    12 {return [CmapFormat12 $bytes $best]}
    default {
      return -code error -errorcode [list TCLPDF FONT UNSUPPORTED cmap $format] \
          "tclpdf: cmap format $format is not supported -\
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
    return -code error -errorcode [list TCLPDF FONT DAMAGED cmap] \
        "tclpdf: the cmap table is damaged - format 12\
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
      return -code error -errorcode [list TCLPDF FONT DAMAGED cmap] \
          "tclpdf: the cmap table is damaged - format 12\
          group $group ends (0x[format %X $end]) before it starts\
          (0x[format %X $start])"
    }
    if {$end > 0x10FFFF} {
      return -code error -errorcode [list TCLPDF FONT DAMAGED cmap] \
          "tclpdf: the cmap table is damaged - format 12\
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
  # loca holds one offset per glyph plus a closing one, in the width head's
  # indexToLocFormat names. A file that ends inside it is cut short; reading
  # on gave an unset variable and, worse, a loca whose entries silently
  # stopped would have cut every glyph past that point out of the subset.
  set width [expr {$format == 0 ? 2 : 4}]
  if {$position + ($numGlyphs + 1) * $width > [string length $bytes]} {
    return -code error -errorcode [list TCLPDF FONT DAMAGED directory] \
        "tclpdf: damaged font - maxp announces $numGlyphs glyphs and the file\
        ends inside the \"loca\" table that locates them"
  }
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
    return -code error -errorcode [list TCLPDF FONT DAMAGED cff] \
        "tclpdf: the CFF table is too short to hold a font"
  }
  binary scan $cff @2cu hdrSize
  lassign [CffIndex $cff $hdrSize] next -
  lassign [CffIndex $cff $next] - topDict
  if {$topDict eq {}} {
    # count 0: an INDEX with nothing in it. A CFF with no Top DICT describes
    # no font, so there is nothing to embed.
    return -code error -errorcode [list TCLPDF FONT DAMAGED cff] \
        "tclpdf: the CFF table has an empty Top DICT INDEX -\
        it describes no font"
  }
  return [CffDictHasOperator $topDict 12 30]
}

# One CFF INDEX (TN 5176 section 5): count, offSize, count+1 offsets that are
# 1-based into the data that follows. Returns the position just past the INDEX
# and ALL its items. count 0 is a two-byte INDEX with no offSize and no data
# at all.
#
# Every item, not the first alone: the CID-keyed probe below wants one and the
# bare-CFF reader wants all of them - the charstrings ARE an INDEX, and so are
# the strings and the subroutines. Two readers, one cheap and one complete,
# would be the same offset arithmetic written twice, and an off-by-one in
# either yields glyph outlines cut in half rather than an error.
proc ::tclpdf::sfnt::CffItems {cff at} {
  if {[binary scan $cff @${at}Su count] != 1} {
    return -code error -errorcode [list TCLPDF FONT DAMAGED cff] \
        "tclpdf: the CFF table is truncated"
  }
  if {$count == 0} {
    return [list [expr {$at + 2}] {}]
  }
  binary scan $cff @[expr {$at + 2}]cu offSize
  if {$offSize < 1 || $offSize > 4} {
    return -code error -errorcode [list TCLPDF FONT DAMAGED cff] \
        "tclpdf: the CFF table has an INDEX with offSize\
        $offSize, which the format does not allow (1 to 4)"
  }
  set at [expr {$at + 3}]
  # offSize 3 has no binary-scan format, so every size is folded from bytes.
  if {[binary scan $cff @${at}cu[expr {($count + 1) * $offSize}] digits] != 1
      || [llength $digits] != ($count + 1) * $offSize} {
    return -code error -errorcode [list TCLPDF FONT DAMAGED cff] \
        "tclpdf: the CFF table is truncated"
  }
  set offsets {}
  set value 0
  set taken 0
  foreach digit $digits {
    set value [expr {$value * 256 + $digit}]
    if {[incr taken] == $offSize} {
      lappend offsets $value
      set value 0
      set taken 0
    }
  }
  set data [expr {$at + ($count + 1) * $offSize - 1}]
  set items {}
  for {set index 0} {$index < $count} {incr index} {
    lappend items [string range $cff \
        [expr {$data + [lindex $offsets $index]}] \
        [expr {$data + [lindex $offsets [expr {$index + 1}]] - 1}]]
  }
  return [list [expr {$data + [lindex $offsets $count]}] $items]
}

# The position past an INDEX and its FIRST item - what the CID-keyed probe
# wants of the Name and Top DICT INDEXes, both of which hold one item.
proc ::tclpdf::sfnt::CffIndex {cff at} {
  lassign [CffItems $cff $at] next items
  return [list $next [lindex $items 0]]
}

# A CFF DICT (TN 5176 section 4) as a Tcl dict of operator -> operands.
#
# The KEY is the operator as it is written: 5 for FontBBox, the two-element
# LIST {12 30} for ROS - the escape and the byte behind it. A list and not
# "12.30": that spelling was tried and is a trap, because a dotted pair of
# integers is also a valid number, and one [expr] anywhere near it turns
# "12.30" into 12.3 - which is UnderlinePosition, an operator most fonts do
# carry. Measured: every name-keyed CFF on this machine reported itself
# CID-keyed.
#
# The walk is by operand encoding and not by byte search, which is the whole
# point: 28 and 29 carry two and four bytes, 30 is a real number of nibbles up
# to one that is 0xf, 32 to 254 are integers of one to three bytes; 0 to 21
# are operators, 12 the escape. Reading operands as operators would find the
# number 30 where no ROS is.
#
# A real number (30) is decoded rather than skipped, because FontMatrix is one
# and it is what says how big the em is - a bare CFF has no head table to ask.
# The nibbles are: 0-9 the digits, a a decimal point, b and c the exponent
# with and without a minus, e a minus sign, f the end.
proc ::tclpdf::sfnt::CffDict {dict} {
  set length [string length $dict]
  set at 0
  set operands {}
  set result {}
  while {$at < $length} {
    binary scan $dict @${at}cu byte
    if {$byte <= 21} {
      if {$byte == 12} {
        binary scan $dict @[expr {$at + 1}]cu escaped
        dict set result [list 12 $escaped] $operands
        incr at 2
      } else {
        dict set result $byte $operands
        incr at
      }
      set operands {}
    } elseif {$byte == 28} {
      binary scan $dict @[expr {$at + 1}]S value
      lappend operands $value
      incr at 3
    } elseif {$byte == 29} {
      binary scan $dict @[expr {$at + 1}]I value
      lappend operands $value
      incr at 5
    } elseif {$byte == 30} {
      incr at
      set text {}
      set done 0
      while {$at < $length && !$done} {
        binary scan $dict @${at}cu pair
        incr at
        foreach nibble [list [expr {$pair >> 4}] [expr {$pair & 0x0f}]] {
          if {$nibble == 0x0f} {
            set done 1
            break
          }
          append text [lindex {0 1 2 3 4 5 6 7 8 9 . E E- {} -} $nibble]
        }
      }
      # A malformed real is not a number, and 0 is the only value that cannot
      # be mistaken for a measurement.
      lappend operands [expr {[string is double -strict $text] ? $text : 0}]
    } elseif {$byte <= 246} {
      lappend operands [expr {$byte - 139}]
      incr at
    } elseif {$byte <= 250} {
      binary scan $dict @[expr {$at + 1}]cu low
      lappend operands [expr {($byte - 247) * 256 + $low + 108}]
      incr at 2
    } elseif {$byte <= 254} {
      binary scan $dict @[expr {$at + 1}]cu low
      lappend operands [expr {-($byte - 251) * 256 - $low - 108}]
      incr at 2
    } else {
      # 22 to 27, 31 and 255 are reserved; one byte each, on the way past.
      incr at
    }
  }
  return $result
}

# Whether a CFF DICT carries the operator b0 - or, with b0 12, the escaped
# operator b1. The one question the CID-keyed probe asks, over the reader
# above rather than over a walk of its own.
proc ::tclpdf::sfnt::CffDictHasOperator {dict b0 {b1 {}}} {
  if {$b1 eq {}} {
    return [dict exists [CffDict $dict] $b0]
  }
  return [dict exists [CffDict $dict] [list $b0 $b1]]
}

# ---------------------------------------------------------------------------
# The bare CFF - the same outlines without the sfnt wrapper
# ---------------------------------------------------------------------------
#
# A .otf carries its outlines in a CFF table inside an sfnt, and everything a
# PDF wants BESIDE the outlines - the character map, the widths, the
# PostScript name - is read out of the sfnt tables around it. A bare CFF is
# that table on its own, as it falls out of a font compiler or out of another
# PDF, and it has none of them: no cmap, no hmtx, no name, no OS/2, no head.
#
# Every one of those answers is nevertheless IN the file, in the CFF's own
# structures, which is what this section reads:
#
#   Name INDEX     the PostScript name
#   Top DICT       FontBBox, ItalicAngle, FontMatrix (which says how big the
#                  em is, where head would have said unitsPerEm), and the
#                  offsets to everything below
#   String INDEX   the glyph names the standard 391 do not cover
#   charset        which glyph carries which name - the file's own index
#   Encoding       which byte reaches which glyph, the face's own opinion
#   Private DICT   defaultWidthX and nominalWidthX, without which no
#                  charstring's width can be read at all
#   CharStrings    one per glyph; the width is the optional first operand
#                  before the first stem, moveto or endchar
#
# THE WIDTH IS THE WORK. It is not a table: every charstring may or may not
# open with a width, and whether it does is decided by the PARITY of the
# operands before the first hint or move operator (TN 5177 section 3.1). Read
# wrong, every glyph gets defaultWidthX - which is a number the file states and
# which therefore looks entirely plausible in the PDF, while every line comes
# out the wrong length.

# The 391 standard strings (TN 5176 Appendix A). A SID below 391 names one of
# these; anything above indexes the font's own String INDEX. Without them a
# charset reads as numbers and no glyph can be found by name.
namespace eval ::tclpdf::sfnt {
  variable cffStandardStrings {
    .notdef space exclam quotedbl numbersign dollar percent ampersand
    quoteright parenleft parenright asterisk plus comma hyphen period slash
    zero one two three four five six seven eight nine colon semicolon less
    equal greater question at A B C D E F G H I J K L M N O P Q R S T U V W
    X Y Z bracketleft backslash bracketright asciicircum underscore quoteleft
    a b c d e f g h i j k l m n o p q r s t u v w x y z braceleft bar
    braceright asciitilde exclamdown cent sterling fraction yen florin
    section currency quotesingle quotedblleft guillemotleft guilsinglleft
    guilsinglright fi fl endash dagger daggerdbl periodcentered paragraph
    bullet quotesinglbase quotedblbase quotedblright guillemotright ellipsis
    perthousand questiondown grave acute circumflex tilde macron breve
    dotaccent dieresis ring cedilla hungarumlaut ogonek caron emdash AE
    ordfeminine Lslash Oslash OE ordmasculine ae dotlessi lslash oslash oe
    germandbls onesuperior logicalnot mu trademark Eth onehalf plusminus
    Thorn onequarter divide brokenbar degree thorn threequarters twosuperior
    registered minus eth multiply threesuperior copyright Aacute Acircumflex
    Adieresis Agrave Aring Atilde Ccedilla Eacute Ecircumflex Edieresis
    Egrave Iacute Icircumflex Idieresis Igrave Ntilde Oacute Ocircumflex
    Odieresis Ograve Otilde Scaron Uacute Ucircumflex Udieresis Ugrave
    Yacute Ydieresis Zcaron aacute acircumflex adieresis agrave aring atilde
    ccedilla eacute ecircumflex edieresis egrave iacute icircumflex
    idieresis igrave ntilde oacute ocircumflex odieresis ograve otilde
    scaron uacute ucircumflex udieresis ugrave yacute ydieresis zcaron
    exclamsmall Hungarumlautsmall dollaroldstyle dollarsuperior
    ampersandsmall Acutesmall parenleftsuperior parenrightsuperior
    twodotenleader onedotenleader zerooldstyle oneoldstyle twooldstyle
    threeoldstyle fouroldstyle fiveoldstyle sixoldstyle sevenoldstyle
    eightoldstyle nineoldstyle commasuperior threequartersemdash
    periodsuperior questionsmall asuperior bsuperior centsuperior dsuperior
    esuperior isuperior lsuperior msuperior nsuperior osuperior rsuperior
    ssuperior tsuperior ff ffi ffl parenleftinferior parenrightinferior
    Circumflexsmall hyphensuperior Gravesmall Asmall Bsmall Csmall Dsmall
    Esmall Fsmall Gsmall Hsmall Ismall Jsmall Ksmall Lsmall Msmall Nsmall
    Osmall Psmall Qsmall Rsmall Ssmall Tsmall Usmall Vsmall Wsmall Xsmall
    Ysmall Zsmall colonmonetary onefitted rupiah Tildesmall exclamdownsmall
    centoldstyle Lslashsmall Scaronsmall Zcaronsmall Dieresissmall
    Brevesmall Caronsmall Dotaccentsmall Macronsmall figuredash
    hypheninferior Ogoneksmall Ringsmall Cedillasmall questiondownsmall
    oneeighth threeeighths fiveeighths seveneighths onethird twothirds
    zerosuperior foursuperior fivesuperior sixsuperior sevensuperior
    eightsuperior ninesuperior zeroinferior oneinferior twoinferior
    threeinferior fourinferior fiveinferior sixinferior seveninferior
    eightinferior nineinferior centinferior dollarinferior periodinferior
    commainferior Agravesmall Aacutesmall Acircumflexsmall Atildesmall
    Adieresissmall Aringsmall AEsmall Ccedillasmall Egravesmall Eacutesmall
    Ecircumflexsmall Edieresissmall Igravesmall Iacutesmall
    Icircumflexsmall Idieresissmall Ethsmall Ntildesmall Ogravesmall
    Oacutesmall Ocircumflexsmall Otildesmall Odieresissmall OEsmall
    Oslashsmall Ugravesmall Uacutesmall Ucircumflexsmall Udieresissmall
    Yacutesmall Thornsmall Ydieresissmall 001.000 001.001 001.002 001.003
    Black Bold Book Light Medium Regular Roman Semibold
  }

  # The upper half of the CFF Standard Encoding, by code. The lower half is
  # not written out because it does not have to be: for codes 32 to 126 the
  # SID is the code less 31, which [CffStandardEncoding] folds out of the
  # standard strings above - one table instead of two that could disagree.
  variable cffStandardHigh {
    161 exclamdown 162 cent 163 sterling 164 fraction 165 yen 166 florin
    167 section 168 currency 169 quotesingle 170 quotedblleft
    171 guillemotleft 172 guilsinglleft 173 guilsinglright 174 fi 175 fl
    177 endash 178 dagger 179 daggerdbl 180 periodcentered 182 paragraph
    183 bullet 184 quotesinglbase 185 quotedblbase 186 quotedblright
    187 guillemotright 188 ellipsis 189 perthousand 191 questiondown
    193 grave 194 acute 195 circumflex 196 tilde 197 macron 198 breve
    199 dotaccent 200 dieresis 202 ring 203 cedilla 205 hungarumlaut
    206 ogonek 207 caron 208 emdash 225 AE 227 ordfeminine 232 Lslash
    233 Oslash 234 OE 235 ordmasculine 241 ae 245 dotlessi 248 lslash
    249 oslash 250 oe 251 germandbls
  }
}

# Are these bytes a bare CFF - a font program with no sfnt around it?
#
# The header is four bytes and only three of them say anything: major must be
# 1 (2 is CFF2, a different format with no charset and no encoding), hdrSize
# is where the Name INDEX begins and cannot lie before the header's own end,
# and offSize is 1 to 4 by the format. That is thin as signatures go - which is
# why this is asked LAST, after every other format has said no.
# Version 2 answers TRUE here, and that is the point rather than an oversight:
# this asks "is this a bare CFF-shaped program", not "can it be read". A CFF2
# that answered false fell through to the sfnt reader and was turned away as
# "not a TrueType or OpenType font", so the refusal written for it in
# [cffFont] - UNSUPPORTED cff2, which names the format and says why - could
# not be reached through [font embed] at all. Measured on 2026-08-24: the
# public road gave SOURCE sfnt for a CFF2 and the accurate answer existed
# three functions away. The header of a CFF2 is the same four bytes with a
# different major, so telling them apart is the reader's job and not this
# one's.
proc ::tclpdf::sfnt::isBareCff {bytes} {
  if {[string length $bytes] < 8} {
    return 0
  }
  binary scan $bytes cucucucu major minor hdrSize fourth
  if {$hdrSize < 4 || $hdrSize >= [string length $bytes]} {
    return 0
  }
  # The fourth byte is NOT the same field in the two versions: offSize in a
  # CFF, the high half of topDictLength in a CFF2 - which is zero for every
  # top dictionary under 256 bytes, so testing it as an offSize would have
  # rejected most real CFF2 files and sent them back to the sfnt reader, which
  # is the very detour this function was widened to end.
  if {$major == 2} {
    return 1
  }
  # A HEADER VERSION THIS READER DOES NOT KNOW is still a CFF header, and the
  # answer a caller needs is which READER turned the file away (doc/tclpdf.md,
  # TCLPDF FONT SOURCE): a bare CFF of version 3 used to fall through to the
  # sfnt reader and come back as "not a TrueType or OpenType font", which
  # sends a script looking for the wrong thing. [cffFont] names it a CFF and
  # says which version it is.
  #
  # THE BOUND IS NOT DECORATION. Three bytes of a CFF header say anything at
  # all, and the sfnt signatures begin with 0x00, "O" (OTTO) and "t" (true,
  # ttcf) - read as a major version those are 0, 79 and 116. Admitting any
  # non-zero major would claim every OTTO file for the CFF reader, so the
  # recogniser stops one version past the two the format has.
  if {$major == 3} {
    return 1
  }
  return [expr {$major == 1 && $fourth >= 1 && $fourth <= 4}]
}

# A bare CFF, read whole. The dict it answers with:
#
#   name         the PostScript name (Name INDEX, first entry)
#   family       FamilyName, or {} where the font states none
#   numGlyphs    the CharStrings INDEX count
#   unitsPerEm   from FontMatrix - 1000 for all but a handful of faces
#   bbox         FontBBox, in the font's own units
#   italicAngle  degrees counter-clockwise from the vertical
#   fixedPitch   isFixedPitch, as a boolean
#   stemV        StdVW from the Private DICT, or {} - the one value the
#                TrueType road has to estimate and this one can read
#   cidKeyed     whether the font is addressed by CID rather than by name
#   charset      glyph number -> glyph name
#   widths       glyph name -> advance width, in the font's own units
#   encoding     code -> glyph name, the face's OWN encoding
#
# Widths keyed by NAME and not by glyph number, because that is the question a
# PDF asks of this format: a bare CFF is embedded as a Type 1 equivalent and
# addressed by single bytes through an encoding, so what has to be looked up
# is "how wide is /eacute", never "how wide is glyph 217".
proc ::tclpdf::sfnt::cffFont {bytes} {
  if {[string length $bytes] < 8} {
    return -code error -errorcode [list TCLPDF FONT SOURCE cff] \
        "tclpdf: not a CFF font program - too short"
  }
  binary scan $bytes cucucucu major minor hdrSize offSize
  if {$major == 2} {
    return -code error -errorcode [list TCLPDF FONT UNSUPPORTED cff2] \
        "tclpdf: this is a CFF2 font program (header version\
        2.$minor), which is the variable-font format and carries neither a\
        charset nor an encoding - tclpdf reads CFF 1"
  }
  if {$major != 1} {
    return -code error -errorcode [list TCLPDF FONT SOURCE cff] \
        "tclpdf: not a CFF font program (header version\
        $major.$minor)"
  }
  lassign [CffItems $bytes $hdrSize] next names
  lassign [CffItems $bytes $next] next topDicts
  lassign [CffItems $bytes $next] next strings
  lassign [CffItems $bytes $next] next globalSubrs
  if {![llength $topDicts]} {
    return -code error -errorcode [list TCLPDF FONT DAMAGED cff] \
        "tclpdf: the CFF font program has an empty Top DICT\
        INDEX - it describes no font"
  }
  set top [CffDict [lindex $topDicts 0]]

  # NOT through [expr]. A string that comes OUT OF THE FILE never goes through
  # an expression, because expr reads a numeric literal wherever it sees one:
  # the family name "Infinity" comes back as Inf, "1e3" as 1000.0, and "nan"
  # raises "domain error: argument not in valid range". The ternary reads more
  # compactly and is wrong for exactly the values a font is free to carry.
  set family {}
  if {[dict exists $top 3]} {
    set family [CffString [lindex [dict get $top 3] 0] $strings]
  }
  set font [dict create \
      bytes $bytes \
      name [lindex $names 0] \
      cidKeyed [dict exists $top {12 30}] \
      italicAngle [expr {[dict exists $top {12 2}] ?
          [lindex [dict get $top {12 2}] 0] : 0}] \
      fixedPitch [expr {[dict exists $top {12 1}] &&
          [lindex [dict get $top {12 1}] 0] != 0}] \
      bbox [expr {[dict exists $top 5] && [llength [dict get $top 5]] == 4 ?
          [dict get $top 5] : {0 0 0 0}}] \
      family $family]

  # The em, out of FontMatrix. There is no head table here to state it, and
  # the matrix is the only place that says how big a glyph unit is: the usual
  # 0.001 is an em of 1000, and a face drawn on a 2048 grid writes
  # 0.00048828125. Taken as 1000 regardless, every width of such a face would
  # be out by the ratio - the text would measure right and draw at half size.
  set matrix {0.001 0 0 0.001 0 0}
  if {[dict exists $top {12 7}] && [llength [dict get $top {12 7}]] == 6} {
    set matrix [dict get $top {12 7}]
  }
  set scale [lindex $matrix 0]
  if {![string is double -strict $scale] || $scale <= 0} {
    return -code error -errorcode [list TCLPDF FONT METRICS fontMatrix] \
        "tclpdf: the CFF font program states a FontMatrix\
        whose first element is \"$scale\" - the em cannot be measured from it"
  }
  dict set font unitsPerEm [expr {round(1.0 / $scale)}]

  if {![dict exists $top 17]} {
    return -code error -errorcode [list TCLPDF FONT DAMAGED cff] \
        "tclpdf: the CFF font program has no CharStrings -\
        it holds no outlines"
  }
  lassign [CffItems $bytes [lindex [dict get $top 17] 0]] - charStrings
  set numGlyphs [llength $charStrings]
  if {$numGlyphs == 0} {
    return -code error -errorcode [list TCLPDF FONT DAMAGED cff] \
        "tclpdf: the CFF font program has an empty CharStrings\
        INDEX - it holds no outlines"
  }
  dict set font numGlyphs $numGlyphs

  # The Private DICT, which is where the two numbers live that a width cannot
  # be read without. A font may state neither, in which case both are 0 by the
  # format and every charstring carries its own width.
  set defaultWidthX 0
  set nominalWidthX 0
  set localSubrs {}
  dict set font stemV {}
  if {[dict exists $top 18] && [llength [dict get $top 18]] == 2} {
    lassign [dict get $top 18] size offset
    set private [CffDict [string range $bytes $offset \
        [expr {$offset + $size - 1}]]]
    if {[dict exists $private 20]} {
      set defaultWidthX [lindex [dict get $private 20] 0]
    }
    if {[dict exists $private 21]} {
      set nominalWidthX [lindex [dict get $private 21] 0]
    }
    # StdVW is operator 11 and StdHW is 10 - the VERTICAL stem is the one a
    # font descriptor calls StemV, and the two stand next to each other in the
    # DICT, which is how a reader of it picks the wrong one. Measured on
    # NimbusSans-Regular: StdVW 93, StdHW 81.
    if {[dict exists $private 11]} {
      dict set font stemV [expr {int([lindex [dict get $private 11] 0])}]
    }
    if {[dict exists $private 19]} {
      lassign [CffItems $bytes \
          [expr {$offset + [lindex [dict get $private 19] 0]}]] - localSubrs
    }
  }

  set charset [CffCharset $bytes \
      [expr {[dict exists $top 15] ? [lindex [dict get $top 15] 0] : 0}] \
      $numGlyphs $strings]
  dict set font charset $charset

  set widths {}
  set glyph 0
  foreach charstring $charStrings {
    # The same rule as the family name above, and here it was measured rather
    # than reasoned about: NimbusSans-Regular carries a glyph called
    # "infinity", and through the ternary its width was filed under the key
    # Inf - so /infinity had no width at all while the dictionary still held
    # 855 entries and looked complete. A glyph called "nan" would have thrown.
    set name {}
    if {[dict exists $charset $glyph]} {
      set name [dict get $charset $glyph]
    }
    if {$name ne {}} {
      dict set widths $name [CffWidth $charstring $defaultWidthX \
          $nominalWidthX $localSubrs $globalSubrs]
    }
    incr glyph
  }
  dict set font widths $widths

  dict set font encoding [CffEncoding $bytes \
      [expr {[dict exists $top 16] ? [lindex [dict get $top 16] 0] : 0}] \
      $charset]
  return $font
}

# One SID as the string it stands for: below 391 one of the standard strings,
# above it an entry of the font's own String INDEX. A SID neither covers is
# not an error - it names no glyph, and the glyph is then simply unreachable
# by name.
proc ::tclpdf::sfnt::CffString {sid strings} {
  variable cffStandardStrings
  if {$sid < 391} {
    return [lindex $cffStandardStrings $sid]
  }
  return [lindex $strings [expr {$sid - 391}]]
}

# The charset (TN 5176 section 13): glyph number -> glyph name.
#
# Offsets 0, 1 and 2 are not offsets but the three predefined charsets.
# ISOAdobe (0) is the identity - glyph n carries SID n - and is what a font
# that says nothing means. Expert (1) and ExpertSubset (2) are two tables of
# their own that no face measured on this machine uses; they are refused by
# name rather than silently read as ISOAdobe, which would name every glyph
# wrong and be visible only in the drawn page.
#
# Glyph 0 is .notdef in every format and is never listed.
proc ::tclpdf::sfnt::CffCharset {cff at numGlyphs strings} {
  if {$at == 1 || $at == 2} {
    return -code error -errorcode [list TCLPDF FONT UNSUPPORTED charset] \
        "tclpdf: the CFF font program uses the predefined\
        [expr {$at == 1 ? {Expert} : {ExpertSubset}}] charset, which tclpdf\
        does not read - re-generate the font with a charset of its own"
  }
  set charset [dict create 0 .notdef]
  if {$at == 0} {
    for {set glyph 1} {$glyph < $numGlyphs} {incr glyph} {
      dict set charset $glyph [CffString $glyph $strings]
    }
    return $charset
  }
  if {[binary scan $cff @${at}cu format] != 1} {
    return -code error -errorcode [list TCLPDF FONT DAMAGED cff] \
        "tclpdf: the CFF font program is truncated at its\
        charset"
  }
  incr at
  set glyph 1
  if {$format == 0} {
    while {$glyph < $numGlyphs} {
      if {[binary scan $cff @${at}Su sid] != 1} {
        return -code error -errorcode [list TCLPDF FONT DAMAGED charset] \
            "tclpdf: the CFF font program's charset is cut\
            short - it names [expr {$glyph - 1}] of $numGlyphs glyphs"
      }
      dict set charset $glyph [CffString $sid $strings]
      incr at 2
      incr glyph
    }
    return $charset
  }
  if {$format != 1 && $format != 2} {
    return -code error -errorcode [list TCLPDF FONT UNSUPPORTED charset] \
        "tclpdf: the CFF font program has a charset of format\
        $format, which the format does not define (0, 1 and 2)"
  }
  # Ranges: a first SID and how many FURTHER glyphs continue from it - one
  # byte of them in format 1, two in format 2. The names run on with the SIDs,
  # which is why a range can cover a whole alphabet in three bytes.
  set width [expr {$format == 1 ? 1 : 2}]
  while {$glyph < $numGlyphs} {
    if {[binary scan $cff @${at}Su sid] != 1
        || [binary scan $cff @[expr {$at + 2}][expr {$width == 1 ?
            {cu} : {Su}}] left] != 1} {
      return -code error -errorcode [list TCLPDF FONT DAMAGED charset] \
          "tclpdf: the CFF font program's charset is cut short\
          - it names [expr {$glyph - 1}] of $numGlyphs glyphs"
    }
    incr at [expr {2 + $width}]
    for {set index 0} {$index <= $left && $glyph < $numGlyphs} {incr index} {
      dict set charset $glyph [CffString [expr {$sid + $index}] $strings]
      incr glyph
    }
  }
  return $charset
}

# The face's OWN encoding (TN 5176 section 12): code -> glyph name.
#
# This is not what the PDF is addressed by - font.tcl imposes WinAnsiEncoding,
# as it does on a Type 1 program, so that the text can be extracted. It is
# read because it is the only thing that can say WHY a face reaches nothing
# through WinAnsi: a symbol face whose glyphs are named a1 to a191 covers 191
# codes of its own and not one WinAnsi name, and a refusal that can say so
# names the cause instead of the symptom.
#
# Offsets 0 and 1 are the two predefined encodings. The Expert one (1) is not
# expanded - it reaches only the expert glyph names, and no face here has one.
proc ::tclpdf::sfnt::CffEncoding {cff at charset} {
  if {$at == 0} {
    return [CffStandardEncoding $charset]
  }
  if {$at == 1} {
    return {}
  }
  if {[binary scan $cff @${at}cu first] != 1} {
    return -code error -errorcode [list TCLPDF FONT DAMAGED cff] \
        "tclpdf: the CFF font program is truncated at its\
        encoding"
  }
  set format [expr {$first & 0x7f}]
  set supplements [expr {$first & 0x80}]
  incr at
  set encoding {}
  if {$format == 0} {
    binary scan $cff @${at}cu count
    incr at
    for {set glyph 1} {$glyph <= $count} {incr glyph} {
      if {[binary scan $cff @${at}cu code] != 1} {
        break
      }
      incr at
      if {[dict exists $charset $glyph]} {
        dict set encoding $code [dict get $charset $glyph]
      }
    }
  } elseif {$format == 1} {
    binary scan $cff @${at}cu ranges
    incr at
    set glyph 1
    for {set range 0} {$range < $ranges} {incr range} {
      if {[binary scan $cff @${at}cucu code left] != 2} {
        break
      }
      incr at 2
      for {set index 0} {$index <= $left} {incr index} {
        if {[dict exists $charset $glyph]} {
          dict set encoding [expr {$code + $index}] [dict get $charset $glyph]
        }
        incr glyph
      }
    }
  } else {
    return -code error -errorcode [list TCLPDF FONT UNSUPPORTED encoding] \
        "tclpdf: the CFF font program has an encoding of\
        format $format, which the format does not define (0 and 1)"
  }
  # A supplement gives a SECOND code to a glyph already in the encoding, and
  # names it by SID rather than by glyph number - which is why the charset is
  # searched rather than indexed.
  if {$supplements} {
    binary scan $cff @${at}cu count
    incr at
    for {set index 0} {$index < $count} {incr index} {
      if {[binary scan $cff @${at}cuSu code sid] != 2} {
        break
      }
      incr at 3
      set name [CffString $sid {}]
      if {$name ne {} && $name in [dict values $charset]} {
        dict set encoding $code $name
      }
    }
  }
  return $encoding
}

# The CFF Standard Encoding, restricted to the glyphs this face actually has.
# Codes 32 to 126 carry SID code-31; the rest is the table above.
proc ::tclpdf::sfnt::CffStandardEncoding {charset} {
  variable cffStandardHigh
  set have {}
  dict for {- name} $charset {
    dict set have $name 1
  }
  set encoding {}
  for {set code 32} {$code <= 126} {incr code} {
    set name [CffString [expr {$code - 31}] {}]
    if {[dict exists $have $name]} {
      dict set encoding $code $name
    }
  }
  foreach {code name} $cffStandardHigh {
    if {[dict exists $have $name]} {
      dict set encoding $code $name
    }
  }
  return $encoding
}

# The advance width of one Type 2 charstring (TN 5177, section 3.1).
#
# THERE IS NO WIDTH FIELD. The width is an optional extra operand in front of
# the first hint, move or endchar operator, and whether it is there is decided
# by counting what stands before that operator: an odd count for the stem
# operators and the masks, more than the operator takes for rmoveto (2),
# hmoveto and vmoveto (1), one or five for endchar. Where it is there the
# width is nominalWidthX plus the value; where it is not, it is defaultWidthX.
#
# THE SUBROUTINES ARE FOLLOWED. A charstring may open with callsubr, and the
# width then sits inside the subroutine - measured on the CFF of
# NimbusSans-Regular, which begins 62 of its 855 charstrings that way. Stopping
# at the call would give all 62 the defaultWidthX: a number the file itself
# states, so it looks right everywhere except on the page. The bias on the
# index is the format's (107, 1131 or 32768 by the count) and is not
# negotiable - it is what makes the small negative numbers reach the middle of
# the array.
proc ::tclpdf::sfnt::CffWidth {charstring default nominal subrs globalSubrs} {
  set biases [dict create local [CffBias [llength $subrs]] \
      global [CffBias [llength $globalSubrs]]]
  set frames {}
  set code $charstring
  set at 0
  set length [string length $code]
  set operands {}
  while {1} {
    if {$at >= $length} {
      if {![llength $frames]} {
        return $default
      }
      lassign [lindex $frames end] code at
      set frames [lrange $frames 0 end-1]
      set length [string length $code]
      continue
    }
    binary scan $code @${at}cu byte
    if {$byte >= 32 || $byte == 28} {
      if {$byte == 28} {
        binary scan $code @[expr {$at + 1}]S value
        incr at 3
      } elseif {$byte <= 246} {
        set value [expr {$byte - 139}]
        incr at
      } elseif {$byte <= 250} {
        binary scan $code @[expr {$at + 1}]cu low
        set value [expr {($byte - 247) * 256 + $low + 108}]
        incr at 2
      } elseif {$byte <= 254} {
        binary scan $code @[expr {$at + 1}]cu low
        set value [expr {-($byte - 251) * 256 - $low - 108}]
        incr at 2
      } else {
        binary scan $code @[expr {$at + 1}]I fixed
        set value [expr {$fixed / 65536.0}]
        incr at 5
      }
      lappend operands $value
      continue
    }
    incr at
    set count [llength $operands]
    switch -- $byte {
      1 - 3 - 18 - 23 - 19 - 20 {
        # hstem, vstem, hstemhm, vstemhm and the two masks: the stems come in
        # pairs, so an odd operand is the width.
        return [expr {$count % 2 ? $nominal + [lindex $operands 0] : $default}]
      }
      21 {
        return [expr {$count > 2 ? $nominal + [lindex $operands 0] : $default}]
      }
      4 - 22 {
        return [expr {$count > 1 ? $nominal + [lindex $operands 0] : $default}]
      }
      14 {
        # endchar takes nothing, or the four operands of the deprecated seac.
        return [expr {$count == 1 || $count == 5 ?
            $nominal + [lindex $operands 0] : $default}]
      }
      10 - 29 {
        set which [expr {$byte == 10 ? {local} : {global}}]
        set table [expr {$byte == 10 ? $subrs : $globalSubrs}]
        if {!$count || [llength $frames] >= 10} {
          return $default
        }
        set index [expr {int([lindex $operands end]) + [dict get $biases $which]}]
        set operands [lrange $operands 0 end-1]
        if {$index < 0 || $index >= [llength $table]} {
          return $default
        }
        lappend frames [list $code $at]
        set code [lindex $table $index]
        set at 0
        set length [string length $code]
      }
      11 {
        # return: on to the end of this frame, which pops it above.
        set at $length
      }
      12 {
        incr at
        set operands {}
      }
      default {
        set operands {}
      }
    }
  }
}

# The bias a subroutine index is read through (TN 5177, section 4.7). It is
# not an optimisation: index -107 means the first subroutine of a small font,
# and without the bias it means nothing at all.
proc ::tclpdf::sfnt::CffBias {count} {
  if {$count < 1240} {
    return 107
  }
  if {$count < 33900} {
    return 1131
  }
  return 32768
}

# What OS/2 states, read ONCE: fsType, the weight class, and the two heights
# a font descriptor and [font info] both want.
#
#   fsType       the flag saying what the vendor permits, or {} for a face
#                with no OS/2 table at all - an absent permission is not
#                permission 0, and [permission] says so
#   weightClass  usWeightClass, 400 for a regular face; 400 where the table
#                is too short to hold it, which is the value that estimates
#                the StemV of an ordinary weight
#   capHeight    sCapHeight, and {} where the face does not state it: the
#                field only exists from version 2 of the table on, and a
#                version 2 face may still write 0
#   xHeight      sxHeight, under the same rule
#
# The two heights are {} rather than a guess BECAUSE the two callers want
# different things from that: the font descriptor has to write a number and
# derives one (see [FontDescriptorPairs]), while [font info] reports what the
# file says and must not invent. One reader, two answers to the same "not
# stated".
proc ::tclpdf::sfnt::ParseOs2 {bytes tables} {
  set os2 [dict create fsType {} weightClass 400 capHeight {} xHeight {}]
  if {![dict exists $tables OS/2]} {
    return $os2
  }
  lassign [dict get $tables OS/2] position length
  # A table too short for even the three fields read here counts as ABSENT
  # rather than as a refusal, which is the answer this parser already gives a
  # face with no OS/2 at all: nothing in it is required to embed a face, and
  # turning a whole font away over a stub table would be the harsher of the
  # two errors. Without the test the reads below fell off the end of the file
  # and left their variables unset.
  if {$length < 10} {
    return $os2
  }
  # version at 0, usWeightClass at 4 - xAvgCharWidth stands between them.
  binary scan $bytes @${position}Sux2Su version weightClass
  binary scan $bytes @[expr {$position + 8}]Su fsType
  dict set os2 fsType $fsType
  dict set os2 weightClass $weightClass
  # sxHeight at 86 and sCapHeight at 88, both from version 2 on (OpenType,
  # "OS/2"). A face that declares version 2 and ends before them is damaged
  # rather than informative, so the length is checked as well as the version.
  if {$version >= 2 && $length >= 90} {
    binary scan $bytes @[expr {$position + 86}]SS sxHeight sCapHeight
    if {$sxHeight > 0} {
      dict set os2 xHeight $sxHeight
    }
    if {$sCapHeight > 0} {
      dict set os2 capHeight $sCapHeight
    }
  }
  return $os2
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
  lassign [dict get $tables name] position length
  if {$length < 6} {
    return {}
  }
  binary scan $bytes @[expr {$position + 2}]SuSu count stringOffset
  set names {}
  for {set index 0} {$index < $count} {incr index} {
    set at [expr {$position + 6 + $index * 12}]
    # A record the file does not reach is where the table ends, whatever it
    # announced. NOT a refusal: the two names read here are what the face
    # CALLS itself, the document writes a name of its own where they are
    # missing, and no face is unusable for want of them.
    if {[binary scan $bytes @${at}SuSuSuSuSuSu \
            platform encoding language nameId length offset] != 6} {
      break
    }
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

package provide tclpdf::sfnt 1.9