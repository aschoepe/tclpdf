#
# tclpdf - PDF generation for Tcl
#
# colr - the colour tables of a colour font: COLR version 0 and CPAL
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# One topic, and a reading one: the two tables that say a glyph is drawn in
# more than one colour - ISO/IEC 14496-22:2019, 5.7.11 (COLR) and 5.7.12
# (CPAL). Nothing is drawn here, no PDF object is written and no font is
# embedded. This module answers two questions and stops: which layers make up
# a base glyph, and what colour a layer's palette index names. The outline of
# a layer glyph belongs to glyfOutline.tcl, and putting the layers on a page to
# the module that draws them.
#
# COLR version 0 is two flat arrays of fixed width, which is the whole reason
# this file is short. A base glyph record is {gID firstLayerIndex numLayers},
# six bytes; a layer record is {gID paletteIndex}, four. The base records are
# sorted by glyph id and the layer records are in z-order, bottom first. There
# is no recursion, no transform and no gradient - a layer is a plain glyph
# outline filled with one flat colour, and that is the format's entire model.
#
# CPAL is one array of BGRA bytes plus a list of starting points into it, one
# per palette. Palettes may OVERLAP: two palettes are free to name the same
# colour records, which is why the colours are resolved through the starting
# index rather than by slicing the array into equal blocks.
#
# THE TRAP, and it is the one thing that has to be right: a paletteIndex of
# 0xFFFF in a layer record is NOT palette entry 65535. It means "the current
# text colour", set by whoever draws the text and not by the font (5.7.11 and
# again 5.7.12, "Relationship to COLR and SVG Tables": the maximum real entry
# index is therefore 65534). Read as an index it points far past every real
# palette, and a reader that clamps or wraps instead of recognising it draws
# the wrong colour without ever failing. [colr color] is the only sanctioned
# way to resolve an index for that reason and returns the empty string for it.
#
# VERSION 1 IS A SECOND FORMAT IN THE SAME TABLE, and it is read by
# colrPaint.tcl, not here. Its header begins with the five version 0 fields
# and adds five offsets behind them: a BaseGlyphList that hangs a directed
# acyclic graph of paint tables off every colour glyph, a LayerList those
# graphs slice into, a ClipList of precomputed bounds, and two structures for
# variable fonts. A font may use BOTH - "a font may use the version 1
# structures for some base glyphs and the version 0 structures for other base
# glyphs" (5.7.11) - and Noto Color Emoji does the opposite: version 1 in the
# header with numBaseGlyphRecords 0 behind it, which a version 0 reader sees
# as a font without colour glyphs. So the version decides which of the two
# halves a glyph is looked for in, and neither half is a refusal any more.
# [build] loads colrPaint.tcl only for a version 1 table; a version 0 font
# never reads that file.
#
# What is refused, and refused BY NAME rather than answered with nothing:
#
#   - A COLR table above version 1. There is no version 2, and a header that
#     claims one describes records this reader would misread as version 1.
#   - A table with nothing in either half - numBaseGlyphRecords 0 and no
#     version 1 BaseGlyphList. Nothing to draw, and a caller that gets an
#     empty answer instead has no way to tell that from a font it forgot to
#     check.
#   - A COLR table without a CPAL table beside it. 5.7.11 says such a COLR is
#     not supported, and there would be no colours to name.
#   - A truncated table, an array offset that points past the table end, and a
#     base glyph record whose layers run past the end of the layer array.
#
# Every refusal carries an -errorcode below TCLPDF COLR, so a caller can trap
# the whole class by prefix without reading messages.
#
# Deliberately NOT read: the palette label and palette entry label arrays of
# CPAL version 1 (name table IDs for a palette picker - this package has no
# user interface to put them in). The palette TYPE array is read, because
# "usable on a light background" is a choice a document producer can actually
# make. The other ways a font can carry colour - the SVG table, CBDT/CBLC,
# sbix - are not this module's business at all.
#

package require Tcl 8.6.11-
package require tclpdf::sfnt 1.0-
package require tclpdf::otLayout 1.0-
package require tclpdf::color 1.0-

namespace eval ::tclpdf::colr {
  namespace export {[a-z]*}
  namespace ensemble create

  # The palette entry index that names no palette entry. See THE TRAP above.
  variable foreground 0xFFFF

  # Record widths of COLR version 0, 5.7.11.
  variable baseRecord 6
  variable layerRecord 4
}

# Does this font carry colour glyphs at all?
#
# Both tables, because one without the other is not a colour font. This looks
# at the table directory rather than fetching the tables: a COLR table of a
# real emoji font is well over a hundred kilobytes, and the answer is usually
# "no" - a caller asks this for every font it sets, and [build] once.
#
# The version is NOT looked at here, and does not have to be: both versions
# live in this one table and both need the CPAL beside it.
proc ::tclpdf::colr::has {font} {
  set tables [dict get $font tables]
  return [expr {[dict exists $tables COLR] && [dict exists $tables CPAL]}]
}

# Read both tables at once and hand back the state the other two commands
# work on. The keys a caller may read:
#
#   version      the CPAL version, 0 or 1
#   colrVersion  the COLR version, 0 or 1
#   glyphs    base glyph id -> {firstLayerIndex numLayers}, in table order -
#             the VERSION 0 records, which a version 1 table may also carry
#   entries   numPaletteEntries: how many colours every palette has
#   palettes  a list of palettes, each a list of entries, each {colour alpha}
#   types     the CPAL version 1 palette type flags, one per palette, or {}
#   version1  the state of the version 1 half, for [colr paint] and
#             [colr clip], or the empty string for a version 0 table
#
# A colour is what the rest of the package passes around - the output of
# [::tclpdf::color parse], so {rgb {r g b}} with components 0 to 1, and
# {gray v} where the three components agree. That collapse is not a
# rounding: a grey palette entry then goes out as "0.5 g" instead of
# "0.5 0.5 0.5 rg", and every consumer of a parsed colour already handles
# both. Alpha is kept BESIDE the colour and not folded into it, because in
# PDF it is not part of the colour at all: it belongs in an ExtGState.
#
# The layer records are not decoded here. They are the big half of the table -
# 33179 of them in Twemoji Mozilla against 3689 base glyphs, and decoding them
# all costs 26 ms on top of the 8 ms [build] itself takes - while a document
# asks for a handful of glyphs. What [build] does check is that the arrays
# fit inside the table and that no base glyph record reaches past the layer
# array, so that [layers] can read without checking again.
proc ::tclpdf::colr::build {font} {
  set colr [::tclpdf::sfnt table $font COLR]
  set cpal [::tclpdf::sfnt table $font CPAL]
  if {$colr eq {}} {
    return -code error -errorcode {TCLPDF COLR MISSING COLR} \
        "tclpdf: the font has no \"COLR\" table and has no colour glyphs"
  }
  if {$cpal eq {}} {
    return -code error -errorcode {TCLPDF COLR MISSING CPAL} \
        "tclpdf: the font has a \"COLR\" table but no \"CPAL\" table, so its\
        colour glyphs name colours that are not there (ISO/IEC 14496-22,\
        5.7.11)"
  }
  set state {}
  if {[::tclpdf::otLayout damaged {set state [Colr $colr]}]} {
    Truncated COLR "an offset in it points past its end"
  }
  set palettes {}
  if {[::tclpdf::otLayout damaged {set palettes [Cpal $cpal]}]} {
    Truncated CPAL "an offset in it points past its end"
  }
  return [dict merge $state $palettes]
}

# The layers of one base glyph, bottom first: a list of {glyph paletteIndex}.
#
# A glyph that is not a base glyph gets the empty list, and that is an answer,
# not a failure - most glyphs of a colour font are layers or plain outlines.
#
# The palette index is handed on as the table wrote it, 0xFFFF included.
# Resolve it with [colr color] and nothing else.
proc ::tclpdf::colr::layers {state glyph} {
  variable layerRecord
  if {![dict exists $state glyphs $glyph]} {
    return {}
  }
  lassign [dict get $state glyphs $glyph] first count
  set colr [dict get $state colr]
  set at [expr {[dict get $state layerOffset] + $first * $layerRecord}]
  set result {}
  for {set index 0} {$index < $count} {incr index} {
    lappend result [list [::tclpdf::otLayout u16 $colr $at] \
        [::tclpdf::otLayout u16 $colr [expr {$at + 2}]]]
    incr at $layerRecord
  }
  return $result
}

# One palette entry as {colour alpha}, or the EMPTY STRING when the layer asks
# for the current text colour instead of a palette entry.
#
# That empty answer is the reason this command exists rather than a [lindex]
# at the call site. 0xFFFF is a sentinel, not an index (5.7.11), and it is the
# ordinary way a font says "this layer takes whatever colour the text has" -
# an outline layer of a two-colour logo, for instance.
proc ::tclpdf::colr::color {state palette entry} {
  variable foreground
  if {$entry == $foreground} {
    return {}
  }
  set palettes [dict get $state palettes]
  if {![string is integer -strict $palette] || $palette < 0
      || $palette >= [llength $palettes]} {
    return -code error \
        -errorcode [list TCLPDF COLR PALETTE $palette [llength $palettes]] \
        "tclpdf: the font has [llength $palettes] colour\
        palette[expr {[llength $palettes] == 1 ? {} : {s}}], so there is no\
        palette $palette"
  }
  set one [lindex $palettes $palette]
  if {![string is integer -strict $entry] || $entry < 0
      || $entry >= [llength $one]} {
    return -code error \
        -errorcode [list TCLPDF COLR ENTRY $entry [llength $one]] \
        "tclpdf: a palette of this font has [llength $one]\
        entr[expr {[llength $one] == 1 ? {y} : {ies}}], so there is no entry\
        $entry"
  }
  return [lindex $one $entry]
}

# The paint tree of one base glyph of a VERSION 1 table, or the empty string:
# for a version 0 font, for a version 1 font whose glyph is described by the
# old records instead, and for a glyph the table says nothing about. What the
# tree looks like is colrPaint.tcl's subject.
#
# A caller draws a glyph by asking this FIRST and [layers] second. That order
# is the standard's: a font may describe some glyphs the new way and some the
# old, and where it describes one both ways the version 1 description is the
# one a version 1 reader is meant to use.
proc ::tclpdf::colr::paint {state glyph} {
  if {[dict get $state version1] eq {}} {
    return {}
  }
  return [::tclpdf::colrPaint paint [dict get $state version1] $glyph]
}

# The precomputed clip box of one version 1 colour glyph as {xMin yMin xMax
# yMax} in font units, or the empty string where the table gives none.
proc ::tclpdf::colr::clip {state glyph} {
  if {[dict get $state version1] eq {}} {
    return {}
  }
  return [::tclpdf::colrPaint clip [dict get $state version1] $glyph]
}

# --- COLR ------------------------------------------------------------------

proc ::tclpdf::colr::Colr {colr} {
  variable baseRecord
  variable layerRecord
  set version [::tclpdf::otLayout u16 $colr 0]
  if {$version > 1} {
    return -code error -errorcode [list TCLPDF COLR VERSION COLR $version] \
        "tclpdf: the font's \"COLR\" table is version $version; ISO/IEC\
        14496-22, 5.7.11 defines versions 0 and 1"
  }
  set count [::tclpdf::otLayout u16 $colr 2]
  set baseOffset [::tclpdf::otLayout u32 $colr 4]
  set layerOffset [::tclpdf::otLayout u32 $colr 8]
  set layerCount [::tclpdf::otLayout u16 $colr 12]
  # The version 1 half, read by the module that owns it. Loaded here and not
  # at the top of the file: a version 0 font is the common case and has no
  # use for twenty-eight paint formats.
  set paint {}
  set painted 0
  if {$version == 1} {
    package require tclpdf::colrPaint 1.0-
    set paint [::tclpdf::colrPaint build $colr]
    set painted [llength [::tclpdf::colrPaint glyphs $paint]]
  }
  if {$count == 0 && $painted == 0} {
    # A header with nothing behind it in either half. There is nothing to
    # draw, and the caller has to hear that rather than be handed a colour
    # font without colour glyphs - which is indistinguishable from a font it
    # never meant to ask about.
    return -code error -errorcode {TCLPDF COLR EMPTY COLR} \
        "tclpdf: the font's \"COLR\" table declares no base glyphs, in\
        version 0 records or in a version 1 BaseGlyphList, so it has no\
        colour glyphs to draw"
  }
  set length [string length $colr]
  if {$baseOffset + $count * $baseRecord > $length} {
    Truncated COLR "it announces $count base glyph records at offset\
        $baseOffset and is only $length bytes long"
  }
  if {$layerOffset + $layerCount * $layerRecord > $length} {
    Truncated COLR "it announces $layerCount layer records at offset\
        $layerOffset and is only $length bytes long"
  }
  set glyphs {}
  for {set index 0} {$index < $count} {incr index} {
    set at [expr {$baseOffset + $index * $baseRecord}]
    set glyph [::tclpdf::otLayout u16 $colr $at]
    set first [::tclpdf::otLayout u16 $colr [expr {$at + 2}]]
    set layers [::tclpdf::otLayout u16 $colr [expr {$at + 4}]]
    # The bound that a truncation check cannot catch: both numbers are inside
    # the table, and their SUM still walks off the end of the layer array into
    # whatever follows it. Checked here, once, so that [layers] does not have
    # to and cannot be handed a state that lies.
    if {$first + $layers > $layerCount} {
      return -code error \
          -errorcode [list TCLPDF COLR LAYERS $glyph $first $layers $layerCount] \
          "tclpdf: the font's \"COLR\" table gives glyph $glyph $layers layers\
          from index $first, which runs past the $layerCount layer records the\
          table has"
    }
    dict set glyphs $glyph [list $first $layers]
  }
  return [dict create colr $colr glyphs $glyphs layerOffset $layerOffset \
      layerRecords $layerCount version1 $paint colrVersion $version]
}

# --- CPAL ------------------------------------------------------------------

proc ::tclpdf::colr::Cpal {cpal} {
  set version [::tclpdf::otLayout u16 $cpal 0]
  if {$version > 1} {
    return -code error -errorcode [list TCLPDF COLR VERSION CPAL $version] \
        "tclpdf: the font's \"CPAL\" table is version $version; ISO/IEC\
        14496-22, 5.7.12 defines versions 0 and 1"
  }
  set entries [::tclpdf::otLayout u16 $cpal 2]
  set count [::tclpdf::otLayout u16 $cpal 4]
  set records [::tclpdf::otLayout u16 $cpal 6]
  set first [::tclpdf::otLayout u32 $cpal 8]
  # 5.7.12: at least one palette, at least one colour record per palette. An
  # empty CPAL is not permitted, and a font that has one is saying that its
  # colour glyphs have no colours.
  if {$entries == 0 || $count == 0 || $records == 0} {
    return -code error -errorcode {TCLPDF COLR EMPTY CPAL} \
        "tclpdf: the font's \"CPAL\" table is empty - $count\
        palette[expr {$count == 1 ? {} : {s}}] of $entries\
        entr[expr {$entries == 1 ? {y} : {ies}}] over $records colour\
        record[expr {$records == 1 ? {} : {s}}]"
  }
  set length [string length $cpal]
  if {$first + $records * 4 > $length} {
    Truncated CPAL "it announces $records colour records at offset $first and\
        is only $length bytes long"
  }
  set palettes {}
  for {set index 0} {$index < $count} {incr index} {
    set start [::tclpdf::otLayout u16 $cpal [expr {12 + $index * 2}]]
    # 5.7.12: numColorRecords shall be at least max(colorRecordIndices) +
    # numPaletteEntries. A palette that starts too late reads the colours of
    # nothing - the bytes behind the array, which in a real font are the
    # palette type array and would come out as four plausible colours.
    if {$start + $entries > $records} {
      return -code error \
          -errorcode [list TCLPDF COLR RECORDS $index $start $entries $records] \
          "tclpdf: palette $index of the font's \"CPAL\" table starts at\
          colour record $start and wants $entries of them, which runs past the\
          $records records the table has"
    }
    set palette {}
    for {set entry 0} {$entry < $entries} {incr entry} {
      # In range by the two checks above, so the bytes are read directly.
      # BGRA, in that order (5.7.12) - the one field order in the whole format
      # that is not the obvious one.
      set at [expr {$first + ($start + $entry) * 4}]
      binary scan $cpal @${at}cucucucu blue green red alpha
      # Through [color parse] rather than assembled here: the hexadecimal form
      # is exact (a byte over 255.0 is what [color parse] computes too), and
      # going through the package's own parser is what makes a palette entry
      # the same kind of value as any other colour in tclpdf - including the
      # collapse of an achromatic entry to {gray ...}.
      lappend palette [list \
          [::tclpdf::color parse [format {#%02x%02x%02x} $red $green $blue]] \
          [expr {$alpha / 255.0}]]
    }
    lappend palettes $palette
  }
  set types {}
  if {$version == 1} {
    # The three offsets of version 1 sit BEHIND the colorRecordIndices array,
    # so where they are depends on the number of palettes. Only the first of
    # them is read; see the head of this file for the other two.
    set typeOffset [::tclpdf::otLayout u32 $cpal [expr {12 + $count * 2}]]
    if {$typeOffset != 0} {
      if {$typeOffset + $count * 4 > $length} {
        Truncated CPAL "its palette type array for $count palettes starts at\
            offset $typeOffset and the table is only $length bytes long"
      }
      for {set index 0} {$index < $count} {incr index} {
        lappend types [::tclpdf::otLayout u32 $cpal \
            [expr {$typeOffset + $index * 4}]]
      }
    }
  }
  return [dict create version $version entries $entries palettes $palettes \
      types $types]
}

# --- refusals --------------------------------------------------------------

# One wording for every way a table can be too short, and one error code, so
# that a caller can tell "this font is damaged" from "this font is a kind of
# colour font tclpdf does not read". The detail says which array did not fit,
# because a font with two truncated tables is otherwise reported twice with
# the same sentence.
proc ::tclpdf::colr::Truncated {table detail} {
  return -code error -errorcode [list TCLPDF COLR TRUNCATED $table] \
      "tclpdf: the font's \"$table\" table is cut short - $detail"
}

package provide tclpdf::colr 1.1
