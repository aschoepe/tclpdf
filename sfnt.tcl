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
#
# FACE is the index of the face inside a TrueType COLLECTION, or the empty
# string for "no face was named" - which is what every caller that knows
# nothing of collections passes, and what keeps the refusal below in place for
# them. A file that is not a collection has one face and its number is 0.
proc ::tclpdf::sfnt::read {path {face {}}} {
  set bytes [::tclpdf::io read $path]
  return [parse $bytes $face]
}

# The same, WITHOUT reading the whole file - see the section "reading a face
# out of a large file" further down for what that is for and what it costs.
proc ::tclpdf::sfnt::openFace {path {face {}}} {
  set channel [::open $path rb]
  fconfigure $channel -translation binary
  try {
    set font [OpenFace $channel $path $face]
  } on error {message options} {
    ::close $channel
    return -options $options $message
  }
  # A face that needed no channel - the ordinary case - was read whole and
  # holds no handle; closing here is what keeps [closeFace] optional for it.
  if {![dict exists $font channel]} {
    ::close $channel
  }
  return $font
}

# Give back the file handle a face from [openFace] holds, if it holds one.
# Idempotent: a face read whole has none, and a face closed twice is closed
# once - a caller unwinding through several [finally] clauses must not have to
# know which of the two it has.
proc ::tclpdf::sfnt::closeFace {font} {
  if {[dict exists $font channel]} {
    catch {::close [dict get $font channel]}
  }
  return
}

proc ::tclpdf::sfnt::parse {bytes {face {}}} {
  if {[string range $bytes 0 3] eq "ttcf"} {
    # A COLLECTION IS NOT A FONT: it is a directory of faces that share their
    # tables, and there is no answer to "what is the unitsPerEm of this file".
    # Naming a face makes it one, and [Collection] rebuilds that face as a
    # standalone sfnt - the same bytes, a directory of their own - so that
    # everything below this line reads one face and knows nothing of
    # collections.
    if {$face eq {}} {
      return -code error -errorcode [list TCLPDF FONT UNSUPPORTED collection] \
          "tclpdf: this is a TrueType collection - name the face you want\
          with -face, or extract it first"
    }
    set bytes [Collection $bytes $face]
  } elseif {$face ne {} && (![string is integer -strict $face] || $face != 0)} {
    return -code error -errorcode [list TCLPDF FONT FACE $face] \
        "tclpdf: -face names the face inside a TrueType collection and this\
        file is a single face, which is face 0, not \"$face\""
  }
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
  set tables [Directory [string range $bytes 12 \
      [expr {12 + $numTables * 16 - 1}]] $numTables [string length $bytes] 0]
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
  dict set font underline [ParsePostUnderline $bytes $tables]
  dict set font names [ParseNames $bytes $tables]
  # The vertical metrics, or {} for the overwhelming majority of faces that
  # carry none. Read here with the rest because it is three short tables and
  # not one of the large ones; what it costs a Latin document is one dict
  # lookup that misses.
  dict set font vertical [ParseVertical $bytes $tables [dict get $font numGlyphs]]
  return $font
}

# The raw bytes of one table, or {} when it is absent.
#
# A STREAMED table is refused rather than answered with the empty string. A
# face opened by [openFace] leaves the bitmap tables in the file (see the
# section at the end of this file), and answering {} for one of them would say
# "this face has no sbix" to a caller holding a face that is nothing but sbix.
# [slice] and [extent] are the accessors for those.
proc ::tclpdf::sfnt::table {font name} {
  set tables [dict get $font tables]
  if {![dict exists $tables $name]} {
    if {[dict exists $font streamed] && $name in [dict get $font streamed]} {
      return -code error -errorcode [list TCLPDF FONT STREAMED $name] \
          "tclpdf: the \"$name\" table of this face is read from the file by\
          range and is not held in memory - read it with \[sfnt slice\]"
    }
    return {}
  }
  lassign [dict get $tables $name] position length
  return [string range [dict get $font bytes] $position [expr {$position + $length - 1}]]
}

# Has this face a table of this name, wherever it is held? A table left in the
# file by [openFace] is in no dictionary at all, and [dict exists] on the
# table directory answers "no" for exactly the tables that matter most - so
# the question is asked here rather than there. A table of zero length is
# still a table: a directory entry is what the face STATES about itself.
proc ::tclpdf::sfnt::hasTable {font name} {
  if {[dict exists [dict get $font tables] $name]} {
    return 1
  }
  return [expr {[dict exists $font fileTables]
      && [dict exists $font fileTables $name]}]
}

# How long one table is, whether it is held in memory or left in the file.
proc ::tclpdf::sfnt::extent {font name} {
  set tables [dict get $font tables]
  if {[dict exists $tables $name]} {
    return [lindex [dict get $tables $name] 1]
  }
  if {[dict exists $font fileTables] && [dict exists $font fileTables $name]} {
    return [lindex [dict get $font fileTables $name] 1]
  }
  return 0
}

# LENGTH bytes of one table, from START inside it - the accessor a table too
# large to hold is read through.
#
# A range that reaches past the end of the table comes back SHORT rather than
# refused, exactly as [binary scan] fills what it can: the caller reading a
# record out of a damaged table is the one that knows what a short record
# means, and it has to check the length either way.
proc ::tclpdf::sfnt::slice {font name start length} {
  if {$length <= 0} {
    return {}
  }
  set tables [dict get $font tables]
  if {[dict exists $tables $name]} {
    lassign [dict get $tables $name] position extent
    if {$start >= $extent} {
      return {}
    }
    if {$start + $length > $extent} {
      set length [expr {$extent - $start}]
    }
    return [string range [dict get $font bytes] [expr {$position + $start}] \
        [expr {$position + $start + $length - 1}]]
  }
  if {![dict exists $font fileTables] || ![dict exists $font fileTables $name]} {
    return {}
  }
  lassign [dict get $font fileTables $name] position extent
  if {$start >= $extent} {
    return {}
  }
  if {$start + $length > $extent} {
    set length [expr {$extent - $start}]
  }
  set channel [dict get $font channel]
  seek $channel [expr {$position + $start}]
  return [::read $channel $length]
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
  # DAMAGED and not METRICS: the em of an sfnt is head.unitsPerEm and the
  # format puts it between 16 and 16384 (ISO/IEC 14496-22, head) - a file
  # declaring 0 is broken, and there is nothing a caller can hand over to
  # make it readable. METRICS says "the metrics that go with this program are
  # missing, name them with -metrics", which is advice this case cannot use;
  # the class was the same for both until 2026-08-26, so a handler following
  # the manual asked for an AFM that would have changed nothing.
  if {$unitsPerEm == 0} {
    return -code error -errorcode [list TCLPDF FONT DAMAGED head] \
        "tclpdf: damaged font - the \"head\" table declares unitsPerEm 0,\
        and a glyph unit of nothing measures nothing"
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
#
# WHICH SUBTABLE. A face carries several, and the order of preference is
# HarfBuzz's (hb-ot-cmap-table.hh): (3,10) before (0,6) before (0,4) before
# (3,1) before the older Unicode encodings. The Windows records used to be
# ranked above EVERY platform-0 record, which put the BMP-only (3,1) ahead of
# a (0,4) table in format 12 - measured on a DejaVu Sans built with both, the
# face answered 5370 characters instead of 5918 and refused U+1F600, which it
# has. Platform 0 is the Unicode consortium's own and (0,4) is "Unicode 2.0+,
# full repertoire": it is the table a shaper reads, so it is the table this
# reads.
#
# THE BEST RECORD THIS PACKAGE CAN READ, not the best record: a face whose
# preferred subtable is in a format nobody here parses - 0, 2, 6, 13, 14 -
# falls through to the next one down rather than being refused for a table it
# carries an alternative to. Only when none of them can be read is the
# refusal raised, and it names the format of the best candidate.
proc ::tclpdf::sfnt::ParseCmap {bytes tables} {
  # Four bytes of header: the version and the number of subtables.
  set position [TableAt $tables cmap 4]
  binary scan $bytes @[expr {$position + 2}]Su numSubtables
  set candidates {}
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
    set score [CmapScore $platform $encoding]
    if {$score < 0} {
      continue
    }
    lappend candidates [list $score [expr {$position + $subOffset}]]
  }
  if {![llength $candidates]} {
    return -code error -errorcode [list TCLPDF FONT ENCODING cmap] \
        "tclpdf: the font has no usable Unicode cmap"
  }
  set unsupported {}
  foreach candidate [lsort -integer -decreasing -index 0 $candidates] {
    set best [lindex $candidate 1]
    # The chosen record's own offset is a second thing the file states and may
    # get wrong - it is counted from the start of the cmap table and may point
    # anywhere, the end of the file included.
    if {[binary scan $bytes @${best}Su format] != 1} {
      return -code error -errorcode [list TCLPDF FONT DAMAGED cmap] \
          "tclpdf: the font's cmap points its subtable at offset $best, which\
          is past the end of the file"
    }
    switch -- $format {
      4 {return [CmapFormat4 $bytes $best]}
      12 {return [CmapFormat12 $bytes $best]}
    }
    if {$unsupported eq {}} {
      set unsupported $format
    }
  }
  return -code error -errorcode [list TCLPDF FONT UNSUPPORTED cmap $unsupported] \
      "tclpdf: cmap format $unsupported is not supported -\
      tclpdf reads formats 4 and 12"
}

# How much a cmap record is worth, or -1 for one this package cannot address
# characters through. The order is HarfBuzz's; the numbers themselves mean
# nothing beyond it.
proc ::tclpdf::sfnt::CmapScore {platform encoding} {
  if {$platform == 3} {
    switch -- $encoding {
      10 {return 7}
      1 {return 4}
    }
    return -1
  }
  if {$platform != 0} {
    return -1
  }
  switch -- $encoding {
    6 {return 6}
    4 {return 5}
    3 {return 3}
    2 - 1 - 0 {return 2}
  }
  # A platform-0 record with an encoding nobody has registered - it is still
  # Unicode by platform, and it used to be taken; kept, below everything
  # named above.
  return 1
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
  # DAMAGED for the reason [ParseHead] gives at unitsPerEm: the em of a CFF
  # is its FontMatrix and nothing the caller can pass in replaces it.
  if {![string is double -strict $scale] || $scale <= 0} {
    return -code error -errorcode [list TCLPDF FONT DAMAGED cff] \
        "tclpdf: damaged font - the CFF font program states a FontMatrix\
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

  # The glyphs whose HEIGHT a font descriptor is built from: the cap height is
  # measured at the H, the ascender at the d or the b. Three glyphs out of
  # several hundred, so the charstring is walked for those and for nothing
  # else - see [CffTop] for what it costs and why the box of the whole face
  # is not an answer.
  set wantedTops {H d b}
  set tops {}
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
      if {$name in $wantedTops} {
        set top [CffTop $charstring $nominalWidthX $localSubrs $globalSubrs]
        if {$top ne {}} {
          # Whole font units: a charstring may state a fractional coordinate
          # and a descriptor states integers.
          dict set tops $name [expr {int(round($top))}]
        }
      }
    }
    incr glyph
  }
  dict set font widths $widths
  dict set font tops $tops

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
# ONE NUMBER out of a charstring (TN 5177, section 4): {value next}. The
# caller has read the byte and established that it begins a number - 28, or
# 32 and above. Written once because two walkers need it: [CffWidth], which
# stops at the first stem or move, and [CffTop], which runs the whole path.
proc ::tclpdf::sfnt::CffNumber {code at byte} {
  if {$byte == 28} {
    binary scan $code @[expr {$at + 1}]S value
    return [list $value [expr {$at + 3}]]
  }
  if {$byte <= 246} {
    return [list [expr {$byte - 139}] [expr {$at + 1}]]
  }
  if {$byte <= 250} {
    binary scan $code @[expr {$at + 1}]cu low
    return [list [expr {($byte - 247) * 256 + $low + 108}] [expr {$at + 2}]]
  }
  if {$byte <= 254} {
    binary scan $code @[expr {$at + 1}]cu low
    return [list [expr {-($byte - 251) * 256 - $low - 108}] [expr {$at + 2}]]
  }
  binary scan $code @[expr {$at + 1}]I fixed
  return [list [expr {$fixed / 65536.0}] [expr {$at + 5}]]
}

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
      lassign [CffNumber $code $at $byte] value at
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

# THE TOP OF ONE GLYPH, in charstring units - the highest y any point of its
# outline reaches - or {} where the charstring cannot be walked.
#
# WHY A CFF NEEDS THIS AT ALL. A font descriptor has to state a CapHeight
# (ISO 32000-2, Table 122), and a CFF states none: there is no head, no OS/2,
# nothing but the FontBBox of the whole face. Written from that box, the cap
# height of Nimbus Sans came out as 1075 - the top of the Aring, accent and
# all - where the face's capitals reach 729, and everything anchored at a cap
# height sat a third of an em too high. The letter H is where a cap height is
# measured, so the letter H is what is measured (font.tcl, [FontType1Metrics]).
#
# CONTROL POINTS COUNT AS POINTS, which makes the answer an upper bound
# rather than the exact extreme of a curve. For the three glyphs this is
# asked of - H, d, b - the top is a straight stem and the bound is exact;
# writing a curve solver for the general case would be a piece of its own and
# would change none of them. Measured against fontTools over the 33 CFF faces
# in the tree: the same number for every H.
#
# The walk is the Type 2 charstring machine (TN 5177, section 4.3), with the
# operators that MOVE the pen implemented and the rest skipped. A hintmask
# takes its mask bytes from the number of stems declared before it, which is
# why the stems are counted rather than only cleared.
proc ::tclpdf::sfnt::CffTop {charstring nominal subrs globalSubrs} {
  set biases [dict create local [CffBias [llength $subrs]] \
      global [CffBias [llength $globalSubrs]]]
  set frames {}
  set code $charstring
  set at 0
  set length [string length $code]
  set operands {}
  set x 0.0
  set y 0.0
  set top {}
  set stems 0
  set width 0
  while {1} {
    if {$at >= $length} {
      if {![llength $frames]} {
        return $top
      }
      lassign [lindex $frames end] code at
      set frames [lrange $frames 0 end-1]
      set length [string length $code]
      continue
    }
    binary scan $code @${at}cu byte
    if {$byte >= 32 || $byte == 28} {
      lassign [CffNumber $code $at $byte] value at
      lappend operands $value
      continue
    }
    incr at
    set count [llength $operands]
    switch -- $byte {
      1 - 3 - 18 - 23 {
        # The four stem operators: pairs, so an odd count means the first
        # operand is the width.
        incr stems [expr {$count / 2}]
        set operands {}
      }
      19 - 20 {
        # hintmask and cntrmask: the operands in front of them are an
        # implicit vstem, and the mask itself is one bit per stem.
        incr stems [expr {$count / 2}]
        set operands {}
        incr at [expr {($stems + 7) / 8}]
      }
      21 {
        # rmoveto, with the width in front of it where the count is odd.
        set start [expr {$count > 2 ? $count - 2 : 0}]
        set x [expr {$x + [lindex $operands $start]}]
        set y [expr {$y + [lindex $operands [expr {$start + 1}]]}]
        set top [CffHighest $top $y]
        set operands {}
      }
      22 {
        set x [expr {$x + [lindex $operands end]}]
        set top [CffHighest $top $y]
        set operands {}
      }
      4 {
        set y [expr {$y + [lindex $operands end]}]
        set top [CffHighest $top $y]
        set operands {}
      }
      5 {
        foreach {dx dy} $operands {
          if {$dy eq {}} {
            break
          }
          set x [expr {$x + $dx}]
          set y [expr {$y + $dy}]
          set top [CffHighest $top $y]
        }
        set operands {}
      }
      6 - 7 {
        # hlineto and vlineto alternate, starting with the one the operator
        # names.
        set horizontal [expr {$byte == 6}]
        foreach delta $operands {
          if {$horizontal} {
            set x [expr {$x + $delta}]
          } else {
            set y [expr {$y + $delta}]
            set top [CffHighest $top $y]
          }
          set horizontal [expr {!$horizontal}]
        }
        set operands {}
      }
      8 {
        foreach {a b c d e f} $operands {
          if {$f eq {}} {
            break
          }
          lassign [CffCurve $x $y $a $b $c $d $e $f $top] x y top
        }
        set operands {}
      }
      24 {
        # rcurveline: curves, then one line.
        set curves [lrange $operands 0 end-2]
        foreach {a b c d e f} $curves {
          if {$f eq {}} {
            break
          }
          lassign [CffCurve $x $y $a $b $c $d $e $f $top] x y top
        }
        set x [expr {$x + [lindex $operands end-1]}]
        set y [expr {$y + [lindex $operands end]}]
        set top [CffHighest $top $y]
        set operands {}
      }
      25 {
        # rlinecurve: lines, then one curve.
        set lines [lrange $operands 0 end-6]
        foreach {dx dy} $lines {
          if {$dy eq {}} {
            break
          }
          set x [expr {$x + $dx}]
          set y [expr {$y + $dy}]
          set top [CffHighest $top $y]
        }
        lassign [lrange $operands end-5 end] a b c d e f
        if {$f ne {}} {
          lassign [CffCurve $x $y $a $b $c $d $e $f $top] x y top
        }
        set operands {}
      }
      26 - 27 {
        # vvcurveto and hhcurveto: an odd operand in front is the deflection
        # of the first curve in the other direction.
        set first 0
        if {$count % 4} {
          set first [lindex $operands 0]
          set operands [lrange $operands 1 end]
        }
        foreach {a b c d} $operands {
          if {$d eq {}} {
            break
          }
          if {$byte == 26} {
            lassign [CffCurve $x $y $first $a $b $c 0 $d $top] x y top
          } else {
            lassign [CffCurve $x $y $a $first $b $c $d 0 $top] x y top
          }
          set first 0
        }
        set operands {}
      }
      30 - 31 {
        # vhcurveto and hvcurveto: curves alternating between the two
        # directions, with an optional last operand for the free end.
        set vertical [expr {$byte == 30}]
        set index 0
        while {$count - $index >= 4} {
          set last 0
          if {$count - $index == 5} {
            set last [lindex $operands [expr {$index + 4}]]
          }
          lassign [lrange $operands $index [expr {$index + 3}]] a b c d
          if {$vertical} {
            lassign [CffCurve $x $y 0 $a $b $c $d $last $top] x y top
          } else {
            lassign [CffCurve $x $y $a 0 $b $c $last $d $top] x y top
          }
          set vertical [expr {!$vertical}]
          incr index 4
        }
        set operands {}
      }
      10 - 29 {
        set which [expr {$byte == 10 ? {local} : {global}}]
        set table [expr {$byte == 10 ? $subrs : $globalSubrs}]
        if {!$count || [llength $frames] >= 10} {
          return $top
        }
        set index [expr {int([lindex $operands end]) + [dict get $biases $which]}]
        set operands [lrange $operands 0 end-1]
        if {$index < 0 || $index >= [llength $table]} {
          return $top
        }
        lappend frames [list $code $at]
        set code [lindex $table $index]
        set at 0
        set length [string length $code]
      }
      11 {
        set at $length
      }
      14 {
        return $top
      }
      12 {
        # The escaped operators. The four flex forms move the pen and are
        # walked; everything else is arithmetic on the stack and clears it.
        binary scan $code @${at}cu second
        incr at
        set top [CffFlex $second $operands x y $top]
        set operands {}
      }
      default {
        set operands {}
      }
    }
  }
}

# The higher of a top so far and one y - with {} meaning "nothing seen yet".
proc ::tclpdf::sfnt::CffHighest {top y} {
  if {$top eq {} || $y > $top} {
    return $y
  }
  return $top
}

# One cubic curve from the current point, as six deltas: {x y top} after it.
# The two control points count as points, which is what makes the answer an
# upper bound - see [CffTop].
proc ::tclpdf::sfnt::CffCurve {x y dx1 dy1 dx2 dy2 dx3 dy3 top} {
  set x [expr {$x + $dx1}]
  set y [expr {$y + $dy1}]
  set top [CffHighest $top $y]
  set x [expr {$x + $dx2}]
  set y [expr {$y + $dy2}]
  set top [CffHighest $top $y]
  set x [expr {$x + $dx3}]
  set y [expr {$y + $dy3}]
  return [list $x $y [CffHighest $top $y]]
}

# The four flex operators (12 34..37), which draw two curves through six
# points. Only the y of every point is wanted here, so each form is walked as
# the deltas it states; anything else escaped by 12 moves no pen and is
# ignored.
proc ::tclpdf::sfnt::CffFlex {second operands xName yName top} {
  upvar 1 $xName x $yName y
  switch -- $second {
    34 {
      # hflex: dx1 dx2 dy2 dx3 dx4 dx5 dx6 - the y returns to where it began.
      lassign $operands dx1 dx2 dy2 dx3 dx4 dx5 dx6
      if {$dx6 eq {}} {
        return $top
      }
      set start $y
      lassign [CffCurve $x $y $dx1 0 $dx2 $dy2 $dx3 0 $top] x y top
      lassign [CffCurve $x $y $dx4 0 $dx5 [expr {$start - $y}] $dx6 0 $top] \
          x y top
      return $top
    }
    35 {
      # flex: two full curves and a final flex depth, which is not a
      # coordinate.
      lassign $operands a b c d e f g h i j k l
      if {$l eq {}} {
        return $top
      }
      lassign [CffCurve $x $y $a $b $c $d $e $f $top] x y top
      lassign [CffCurve $x $y $g $h $i $j $k $l $top] x y top
      return $top
    }
    36 {
      # hflex1: dx1 dy1 dx2 dy2 dx3 dx4 dx5 dy5 dx6
      lassign $operands dx1 dy1 dx2 dy2 dx3 dx4 dx5 dy5 dx6
      if {$dx6 eq {}} {
        return $top
      }
      set start $y
      lassign [CffCurve $x $y $dx1 $dy1 $dx2 $dy2 $dx3 0 $top] x y top
      lassign [CffCurve $x $y $dx4 0 $dx5 $dy5 $dx6 [expr {$start - $y - $dy5}] \
          $top] x y top
      return $top
    }
    37 {
      # flex1: eleven deltas, the twelfth being whichever of dx6/dy6 closes
      # the figure back to where it started.
      lassign $operands a b c d e f g h i j k
      if {$k eq {}} {
        return $top
      }
      set startX $x
      set startY $y
      set sumX [expr {$a + $c + $e + $g + $i}]
      set sumY [expr {$b + $d + $f + $h + $j}]
      lassign [CffCurve $x $y $a $b $c $d $e $f $top] x y top
      if {abs($sumX + $k) > abs($sumY)} {
        set last [expr {$startY - $y - $h - $j}]
        lassign [CffCurve $x $y $g $h $i $j $k $last $top] x y top
      } else {
        set last [expr {$startX - $x - $g - $i}]
        lassign [CffCurve $x $y $g $h $i $j $last $k $top] x y top
      }
      return $top
    }
  }
  return $top
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
#   strikeout    {position size} of the strikeout stroke, yStrikeoutPosition
#                and yStrikeoutSize at 28 and 26 (version 0 fields, present
#                in every table long enough to hold them), or {} where the
#                table is shorter or states a size of 0
#
# The two heights are {} rather than a guess BECAUSE the two callers want
# different things from that: the font descriptor has to write a number and
# derives one (see [FontDescriptorPairs]), while [font info] reports what the
# file says and must not invent. One reader, two answers to the same "not
# stated".
proc ::tclpdf::sfnt::ParseOs2 {bytes tables} {
  set os2 [dict create fsType {} weightClass 400 capHeight {} xHeight {} \
      strikeout {}]
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
  if {$length >= 30} {
    binary scan $bytes @[expr {$position + 26}]SS strikeSize strikePosition
    if {$strikeSize > 0} {
      dict set os2 strikeout [list $strikePosition $strikeSize]
    }
  }
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

# Where the post table puts an underline: underlinePosition at offset 8 and
# underlineThickness at 10, both signed 16-bit in font units (OpenType,
# "post"). Answered as {position thickness}, or {} for a face without the
# table, with a table too short for the two fields, or with a thickness of
# 0 - a stated nothing is not a measurement, and the caller falls back to
# the size (textRun.tcl). Read for the underline a run asks for; nothing
# else in the package draws one.
proc ::tclpdf::sfnt::ParsePostUnderline {bytes tables} {
  if {![dict exists $tables post]} {
    return {}
  }
  lassign [dict get $tables post] position length
  if {$length < 12} {
    return {}
  }
  binary scan $bytes @[expr {$position + 8}]SS underlinePosition thickness
  if {$thickness <= 0} {
    return {}
  }
  return [list $underlinePosition $thickness]
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
    # The one restriction this package ACTS on, so the wording says so: bit 8
    # makes -subset 0 the default for the face (font.tcl, [FontEmbed]), and a
    # caller who wants a subset all the same writes -subset 1.
    append words "; no subsetting (bit 8), so the face is embedded whole\
        unless -subset 1 asks otherwise"
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

# -- the table directory ----------------------------------------------------

# The table directory of ONE face, checked, as a dict of tag -> {position
# length}. ENTRIES is the directory block itself - numTables entries of 16
# bytes - and TOTAL the length of the file the positions are measured in.
#
# Its own procedure since 2026-08-26, because there are now two ways in: a
# whole file in a string, and a face inside a collection read through a
# channel. The checks are the same for both and were the kind of thing that
# gets fixed in one copy.
#
# BASE is added to every position: a face of a collection has its directory
# at an offset and its table positions from the START OF THE FILE, so the
# base is 0 there too. It exists for the rebuilt face, whose directory says
# where the tables sit in the NEW string.
proc ::tclpdf::sfnt::Directory {entries numTables total base} {
  set tables {}
  for {set index 0} {$index < $numTables} {incr index} {
    set offset [expr {$index * 16}]
    # binary scan fills what it can and leaves the rest of the variables
    # unset, reporting how many it filled. Without that count a file whose
    # directory is cut short reads a table entry that is not there and fails
    # on an unset variable - a raw Tcl error where this package promises a
    # message of its own.
    if {[binary scan $entries @${offset}a4IuIuIu \
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
    if {$position + $length > $total} {
      return -code error -errorcode [list TCLPDF FONT DAMAGED directory] \
          "tclpdf: damaged font - the \"$name\" table is declared at\
          $position for $length bytes and the file is only\
          $total bytes long"
    }
    dict set tables $name [list [expr {$position + $base}] $length]
  }
  return $tables
}

# -- collections ------------------------------------------------------------
#
# A TrueType COLLECTION (ttcf) is a directory of faces that SHARE their
# tables: Apple Color Emoji holds two faces whose 21 and 22 table entries name
# the same twenty-one byte ranges, one of them 191 MB of artwork that would
# otherwise be in the file twice. So a face is not a slice of the file and
# cannot be handed on as one - what it is, is a table directory.
#
# WHAT IS BUILT HERE is that directory as a font of its own: an sfnt header, a
# directory sorted by tag, and the table bytes behind it. Everything above
# this line then reads one face and knows nothing of collections, and what
# [font embed] writes into the document is a face rather than a collection -
# which is what a /FontFile2 has to be.
#
# THE CHECKSUMS ARE COMPUTED and not copied. They could be copied - the table
# bytes are unchanged - but computing them is four lines, and the head table's
# checkSumAdjustment is wrong in the rebuilt file either way: it is a checksum
# over the WHOLE file, and this is a different file. Nothing reads it; a font
# validator would, and would be right.

# The offsets of the faces in a collection, checked against the file.
proc ::tclpdf::sfnt::CollectionFaces {header} {
  if {[string length $header] < 12} {
    return -code error -errorcode [list TCLPDF FONT DAMAGED collection] \
        "tclpdf: damaged font - the file begins with \"ttcf\" and ends inside\
        the collection header"
  }
  binary scan $header @8Iu count
  if {$count < 1} {
    return -code error -errorcode [list TCLPDF FONT DAMAGED collection] \
        "tclpdf: damaged font - this collection announces $count faces"
  }
  return $count
}

# Which face was asked for, checked against how many there are.
proc ::tclpdf::sfnt::CollectionIndex {face count} {
  if {![string is integer -strict $face] || $face < 0 || $face >= $count} {
    return -code error -errorcode [list TCLPDF FONT FACE $face] \
        "tclpdf: -face is the face inside this collection, 0 to\
        [expr {$count - 1}], not \"$face\""
  }
  return $face
}

# One face of a collection held in a string, as a standalone sfnt.
proc ::tclpdf::sfnt::Collection {bytes face} {
  set count [CollectionFaces $bytes]
  set face [CollectionIndex $face $count]
  set at [expr {12 + $face * 4}]
  if {[binary scan $bytes @${at}Iu base] != 1} {
    return -code error -errorcode [list TCLPDF FONT DAMAGED collection] \
        "tclpdf: damaged font - this collection announces $count faces and\
        the file ends inside the offset of face $face"
  }
  set total [string length $bytes]
  if {[binary scan $bytes @${base}a4Su signature numTables] != 2} {
    return -code error -errorcode [list TCLPDF FONT DAMAGED collection] \
        "tclpdf: damaged font - face $face of this collection is declared at\
        $base and the file is only $total bytes long"
  }
  set tables [Directory [string range $bytes [expr {$base + 12}] \
      [expr {$base + 12 + $numTables * 16 - 1}]] $numTables $total 0]
  set data {}
  dict for {tag entry} $tables {
    lassign $entry position length
    dict set data $tag [string range $bytes $position \
        [expr {$position + $length - 1}]]
  }
  return [Rebuild $signature $data]
}

# An sfnt built out of a signature and a dict of tag -> bytes.
proc ::tclpdf::sfnt::Rebuild {signature data} {
  set tags [lsort [dict keys $data]]
  set numTables [llength $tags]
  # The three numbers of the header after numTables are a binary search hint
  # and nothing else, but a wrong one is a wrong file: searchRange is 16 times
  # the largest power of two not exceeding numTables, entrySelector its
  # logarithm, rangeShift the remainder (ISO/IEC 14496-22, 5.2).
  set power 1
  set selector 0
  while {$power * 2 <= $numTables} {
    set power [expr {$power * 2}]
    incr selector
  }
  set searchRange [expr {$power * 16}]
  set header [binary format a4SuSuSuSu $signature $numTables $searchRange \
      $selector [expr {$numTables * 16 - $searchRange}]]
  set directory {}
  set body {}
  set position [expr {12 + $numTables * 16}]
  foreach tag $tags {
    set bytes [dict get $data $tag]
    set length [string length $bytes]
    append directory [binary format a4IuIuIu $tag [Checksum $bytes] \
        [expr {$position + [string length $body]}] $length]
    append body $bytes
    # EVERY TABLE STARTS ON A FOUR BYTE BOUNDARY (5.2), and the padding is
    # not counted in the length the directory states.
    if {$length % 4} {
      append body [string repeat \x00 [expr {4 - $length % 4}]]
    }
  }
  return $header$directory$body
}

# The table checksum of 5.2: the sum of the table's 32 bit words, zero-padded
# to a whole number of words, modulo 2^32.
proc ::tclpdf::sfnt::Checksum {bytes} {
  set length [string length $bytes]
  if {$length % 4} {
    append bytes [string repeat \x00 [expr {4 - $length % 4}]]
  }
  set sum 0
  binary scan $bytes Iu* words
  foreach word $words {
    set sum [expr {($sum + $word) & 0xFFFFFFFF}]
  }
  return $sum
}

# -- reading a face out of a large file -------------------------------------
#
# WHY THIS EXISTS: Apple Color Emoji is 192 123 488 bytes and 191 134 508 of
# them are one table - "sbix", a PNG per glyph per size. Reading the file the
# way [read] reads one costs 192 MB of memory to reach a cmap of 3580 bytes,
# and a document that sets sixty emoji needs sixty of those PNGs and nothing
# else. Measured before this existed: [io read] on that file took 1.1 s and
# the interpreter never gave the memory back.
#
# WHAT IS STREAMED, and it is a list rather than a size: "sbix", "CBDT" and
# "EBDT" are the tables that hold bitmap IMAGE data, and they are the only
# sfnt tables that reach hundreds of megabytes. Everything else about such a
# face - its cmap, its metrics, its morx, its outlines - comes to under a
# megabyte and is read whole, so the parsers above this line are unchanged and
# see a face exactly like any other.
#
# A SIZE LIMIT WAS THE OTHER CANDIDATE and is worse: it makes which tables a
# reader can see depend on how big they happen to be, so a face works on one
# machine's copy and refuses on another's. The list is a statement about the
# FORMAT and holds for every file.
#
# WHAT IT COSTS: the face is rebuilt (see [Collection]), so [font embed]
# without a subset writes the rebuilt face rather than the file's own bytes.
# That is why the rebuild is skipped entirely where nothing has to be
# streamed and the file is not a collection - the overwhelming majority of
# faces - and those go through [io read] and [parse] exactly as before.

namespace eval ::tclpdf::sfnt {
  variable streamedTables {sbix CBDT EBDT}
}

proc ::tclpdf::sfnt::OpenFace {channel path face} {
  variable streamedTables
  set total [file size $path]
  set header [::read $channel 12]
  set base 0
  set collection 0
  if {[string range $header 0 3] eq "ttcf"} {
    set collection 1
    set count [CollectionFaces $header]
    set index [CollectionIndex [expr {$face eq {} ? 0 : $face}] $count]
    seek $channel [expr {12 + $index * 4}]
    if {[binary scan [::read $channel 4] Iu base] != 1} {
      return -code error -errorcode [list TCLPDF FONT DAMAGED collection] \
          "tclpdf: damaged font - this collection announces $count faces and\
          the file ends inside the offset of face $index"
    }
    seek $channel $base
    set header [::read $channel 12]
  } elseif {$face ne {} && (![string is integer -strict $face] || $face != 0)} {
    return -code error -errorcode [list TCLPDF FONT FACE $face] \
        "tclpdf: -face names the face inside a TrueType collection and\
        \"$path\" is a single face, which is face 0, not \"$face\""
  }
  if {[binary scan $header a4Su signature numTables] != 2} {
    return -code error -errorcode [list TCLPDF FONT SOURCE sfnt] \
        "tclpdf: not a font file - too short"
  }
  seek $channel [expr {$base + 12}]
  set tables [Directory [::read $channel [expr {$numTables * 16}]] \
      $numTables $total 0]
  set streamed {}
  foreach tag $streamedTables {
    if {[dict exists $tables $tag]} {
      lappend streamed $tag
    }
  }
  if {!$collection && ![llength $streamed]} {
    # Nothing to gain: an ordinary face read exactly as [read] reads it, down
    # to the byte, so that everything downstream sees the file itself.
    return [parse [::tclpdf::io read $path]]
  }
  set data {}
  dict for {tag entry} $tables {
    if {$tag in $streamed} {
      continue
    }
    lassign $entry position length
    seek $channel $position
    dict set data $tag [::read $channel $length]
  }
  set font [parse [Rebuild $signature $data]]
  dict set font channel $channel
  dict set font path $path
  dict set font face [expr {$face eq {} ? 0 : $face}]
  dict set font fileTables $tables
  dict set font streamed $streamed
  return $font
}

package provide tclpdf::sfnt 1.12