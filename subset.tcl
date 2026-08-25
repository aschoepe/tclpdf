#
# tclpdf - PDF generation for Tcl
#
# subset - building a font that carries only the glyphs actually used
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# A private sub-module behind the font facade. Without it every document
# carries the whole face - measured on DejaVuSans, 757 076 bytes for an
# invoice that uses about eighty characters.
#
# Glyphs are RENUMBERED, starting at zero. The new number is then both the
# glyph id inside the file and the CID in the PDF, which is what lets
# CIDToGIDMap stay /Identity and keeps the subset small. Glyph 0 (.notdef)
# stays 0 - a reader is entitled to fall back on it.
#
# Composite glyphs are resolved RECURSIVELY. "a-umlaut" is not an outline of
# its own but a reference to "a" plus "dieresis", and a subset that copies
# only the composite leaves those two behind - the glyph then renders as
# nothing at all, in exactly the documents that carry German text.
#
# Which tables travel:
#
#   head hhea maxp   rewritten (glyph count, loca format; for an instance of
#                    a variable face also the bounding box and the hhea
#                    summary of advance, bearings and extent)
#   hmtx loca glyf   rebuilt from the chosen glyphs
#   vhea vmtx        rebuilt likewise, and ONLY where the face has them - the
#                    metric of vertical writing, which most faces carry none of
#   cvt fpgm prep    copied unchanged when present - the hinting programs,
#                    dropped only because they are not needed at all sizes
#
# cmap is deliberately NOT written: with Identity-H the PDF addresses glyphs
# directly and a cmap in the embedded file would be ignored, or worse, used.
#

package require Tcl 8.6.11-
package require tclpdf::sfnt 1.0-

namespace eval ::tclpdf::subset {
  namespace export {[a-z]*}
  namespace ensemble create
}

# Build a subset from a parsed font and a list of glyph ids.
#
# Returns a dict: bytes (the new font file), glyphs (old id -> new id) and
# order (new id -> old id).
proc ::tclpdf::subset::build {font glyphs {instanced {}}} {
  set loca [dict get $font loca]
  if {![llength $loca]} {
    return -code error -errorcode [list TCLPDF FONT SUBSET outlines] \
        "tclpdf: the font has no glyf/loca tables and cannot be\
        subsetted"
  }

  # Close over composites first: a glyph that references others drags them in.
  set wanted [dict create 0 1]
  foreach glyph $glyphs {
    dict set wanted $glyph 1
  }
  set queue [dict keys $wanted]
  while {[llength $queue]} {
    set glyph [lindex $queue 0]
    set queue [lrange $queue 1 end]
    foreach component [Components $font $glyph] {
      if {![dict exists $wanted $component]} {
        dict set wanted $component 1
        lappend queue $component
      }
    }
  }

  # Renumber. Sorting keeps the result reproducible - the same text must give
  # the same bytes, or two runs of the same report differ for no reason.
  set order [lsort -integer [dict keys $wanted]]

  # The instanced glyphs, when the caller has them, are stashed in the font
  # dictionary before anything reads a glyph: GlyphData picks them up, so the
  # component walk, the rewriting and the metrics below all see the moved
  # outlines without knowing that the face varies.
  if {[dict size $instanced]} {
    dict set font instanced $instanced
  }

  set mapping {}
  set newId 0
  foreach glyph $order {
    dict set mapping $glyph $newId
    incr newId
  }
  set count [llength $order]

  # glyf and loca, in the new numbering.
  set glyf {}
  set offsets {}
  foreach glyph $order {
    lappend offsets [string length $glyf]
    append glyf [Rewrite $font $glyph $mapping]
    # Every glyph starts on a two-byte boundary (the format requires it and
    # some readers rely on it).
    while {[string length $glyf] % 2} {
      append glyf \x00
    }
  }
  lappend offsets [string length $glyf]

  # Long loca format throughout: short format halves the offsets and only
  # works while the table stays under 128 KB. One format means one code path.
  set locaBytes {}
  foreach offset $offsets {
    append locaBytes [binary format Iu $offset]
  }

  # hmtx: one advance and one left side bearing per glyph, in the new order.
  #
  # The bearing used to be written as a flat zero, and that was a real defect
  # on two levels. A renderer places the outline at cursor plus bearing, so
  # EVERY glyph moved left by its own - measured across a line, between 8 and
  # 154 units per letter, which left the advances right and the gaps between
  # letters uneven. That much both rasterisers show. On top of it, CoreGraphics
  # shifts the COMPONENTS of a composite by their bearing as well, while
  # poppler places them from the glyf offset - which is why an a-dieresis fell
  # apart in Preview and looked correct in pdftoppm, and why the defect
  # survived two rounds of checking. In DejaVu Sans 6147 of 6253 glyphs have a
  # non-zero bearing, 765 of them negative.
  set hmtx {}
  foreach glyph $order {
    if {[dict exists $font instanced $glyph]} {
      append hmtx [binary format SuS \
          [dict get $font instanced $glyph advance] \
          [dict get $font instanced $glyph bearing]]
    } else {
      append hmtx [binary format SuS [::tclpdf::sfnt advance $font $glyph] \
          [::tclpdf::sfnt bearing $font $glyph]]
    }
  }

  set tables [dict create glyf $glyf loca $locaBytes hmtx $hmtx \
      head [Head $font] hhea [Hhea $font $count] maxp [Maxp $font $count]]

  # vmtx and vhea, and only for a face that has them.
  #
  # PDF does NOT read them - the vertical displacement of a glyph comes from
  # /W2 and /DW2 in the CID font (ISO 32000-2, 9.7.4.3), which font.tcl writes
  # from the same numbers. They are rebuilt all the same, for the reason the
  # bearings in hmtx above are written properly: the embedded file is a font,
  # and a font whose vhea announces 16776 vertical metrics over a vmtx holding
  # eleven is broken for everything that opens it as one. Dropping BOTH would
  # be consistent too - the cheaper answer, and the one that throws away what
  # the face knows the moment anything but Acrobat looks at the file.
  #
  # THE TWO HALVES ARE WRITTEN SEPARATELY, because a face may have either.
  # "hasVertical" is true of a face that carries nothing but a VORG table -
  # an origin per glyph and no heights at all - and such a face has no vhea
  # to rewrite. Writing vmtx for it and then asking [Vhea] for the header
  # meant refusing a perfectly sound font: TCLPDF FONT DAMAGED vhea, "is 0
  # bytes", raised at WRITE time after [font info] had answered "vertical 1"
  # and every [text] call had gone through - the document could not be
  # written at all. The vertical metrics come from vhea and vmtx together
  # (the header states how many pairs the table holds), so they are written
  # together or not at all; VORG travels on its own.
  if {[::tclpdf::sfnt hasVertical $font]} {
    if {[dict exists $font vertical advances]} {
      set vmtx {}
      foreach glyph $order {
        append vmtx [binary format SuS \
            [::tclpdf::sfnt verticalAdvance $font $glyph] \
            [::tclpdf::sfnt verticalBearing $font $glyph]]
      }
      dict set tables vmtx $vmtx
      dict set tables vhea [Vhea $font $count]
    }
    # VORG is carried over ONLY when it can be rewritten in the new numbering:
    # its keys are glyph ids, and copying it unchanged would point every entry
    # at whatever glyph inherited that number.
    if {[dict exists $font vertical origins]} {
      dict set tables VORG [Vorg $font $order]
    }
  }
  foreach optional {cvt fpgm prep} {
    # The table tags are four characters: "cvt " carries a trailing space.
    set tag [format %-4s $optional]
    set data [::tclpdf::sfnt table $font $tag]
    if {$data ne {}} {
      dict set tables $tag $data
    }
  }

  return [dict create bytes [Assemble $tables] glyphs $mapping order $order]
}

# The glyphs a composite refers to. An empty list for a simple glyph.
proc ::tclpdf::subset::Components {font glyph} {
  set data [GlyphData $font $glyph]
  if {[string length $data] < 10} {
    return {}
  }
  binary scan $data S numberOfContours
  if {$numberOfContours >= 0} {
    return {}
  }
  set components {}
  set position 10
  while {1} {
    if {$position + 4 > [string length $data]} {
      break
    }
    binary scan $data @${position}SuSu flags glyphIndex
    lappend components $glyphIndex
    incr position 4
    # ARG_1_AND_2_ARE_WORDS
    incr position [expr {($flags & 0x0001) ? 4 : 2}]
    if {$flags & 0x0008} {
      incr position 2
    } elseif {$flags & 0x0040} {
      incr position 4
    } elseif {$flags & 0x0080} {
      incr position 8
    }
    # MORE_COMPONENTS
    if {!($flags & 0x0020)} {
      break
    }
  }
  return $components
}

proc ::tclpdf::subset::GlyphData {font glyph} {
  # An instanced glyph stands in for the one in the file. Every reader of a
  # glyph goes through here, so the substitution is complete by construction -
  # the component walk and the rewriting see the moved outline too.
  if {[dict exists $font instanced $glyph]} {
    return [dict get $font instanced $glyph bytes]
  }
  set loca [dict get $font loca]
  if {$glyph + 1 >= [llength $loca]} {
    return {}
  }
  set start [lindex $loca $glyph]
  set stop [lindex $loca [expr {$glyph + 1}]]
  if {$stop <= $start} {
    # An empty glyph - a space, for instance. Legitimate, not an error.
    return {}
  }
  set glyf [::tclpdf::sfnt table $font glyf]
  return [string range $glyf $start [expr {$stop - 1}]]
}

# Copy a glyph, renumbering the component references inside a composite.
proc ::tclpdf::subset::Rewrite {font glyph mapping} {
  set data [GlyphData $font $glyph]
  if {[string length $data] < 10} {
    return $data
  }
  binary scan $data S numberOfContours
  if {$numberOfContours >= 0} {
    # Simple glyph: the outline holds no glyph ids, copy it as it is.
    return $data
  }
  set position 10
  while {1} {
    if {$position + 4 > [string length $data]} {
      break
    }
    binary scan $data @${position}SuSu flags glyphIndex
    if {[dict exists $mapping $glyphIndex]} {
      # Patch the id in place - the rest of the component record is untouched.
      set data [string replace $data [expr {$position + 2}] [expr {$position + 3}] \
          [binary format Su [dict get $mapping $glyphIndex]]]
    }
    incr position 4
    incr position [expr {($flags & 0x0001) ? 4 : 2}]
    if {$flags & 0x0008} {
      incr position 2
    } elseif {$flags & 0x0040} {
      incr position 4
    } elseif {$flags & 0x0080} {
      incr position 8
    }
    if {!($flags & 0x0020)} {
      break
    }
  }
  return $data
}

proc ::tclpdf::subset::Head {font} {
  set head [::tclpdf::sfnt table $font head]
  # indexToLocFormat to 1 (long), matching the loca written above. The
  # checksum adjustment at offset 8 is zeroed here - it covers the whole
  # file, so only Assemble, which has the whole file, can set it; the table
  # checksum of head is taken with the field at zero, as the format says.
  # (Until 2026-08-17 this comment promised the recomputation and Assemble
  # did not do it - the field shipped as 0 in every subset.)
  set head [string replace $head 8 11 [binary format Iu 0]]
  set head [string replace $head 50 51 [binary format S 1]]
  # xMin yMin xMax yMax at offset 36: the box of the DEFAULT outlines, which
  # is not the box of the outlines this file carries once they were moved
  # (varFont bounds has the measurements - up to 351 units off in the tree).
  # Set for an instance only, from the same union the font descriptor states,
  # so that head and /FontBBox agree; a face embedded as it came keeps its
  # header byte for byte, as it did before, and its box is the whole file's,
  # not the subset's - which is what fontTools' subsetter leaves there unless
  # told to recalculate, and what every document written so far carries.
  if {[dict exists $font instanced]} {
    package require tclpdf::varFont 1.0-
    set head [string replace $head 36 43 [binary format SSSS \
        {*}[::tclpdf::varFont bounds [dict get $font instanced]]]]
  }
  return $head
}

proc ::tclpdf::subset::Hhea {font count} {
  set hhea [::tclpdf::sfnt table $font hhea]
  # numberOfHMetrics has to match the hmtx written above, or a reader takes
  # the wrong widths for the tail of the font.
  set hhea [string replace $hhea 34 35 [binary format Su $count]]
  # advanceWidthMax, minLeftSideBearing, minRightSideBearing and xMaxExtent at
  # offset 10 (ISO/IEC 14496-22 "hhea") summarise the glyphs of the file, and
  # like the box in head they were measured on the DEFAULT outlines - up to
  # 377 units off once the outlines have moved (varFont hheaMetrics has the
  # measurements). Set for an instance only, from the same moved set the hmtx
  # and glyf above were written from; a face embedded as it came keeps the
  # file's numbers byte for byte, as before, and they describe the whole face
  # rather than the subset - which is what fontTools' subsetter leaves there
  # unless told to recalculate.
  if {[dict exists $font instanced]} {
    package require tclpdf::varFont 1.0-
    set hhea [string replace $hhea 10 17 [binary format SuSSS \
        {*}[::tclpdf::varFont hheaMetrics [dict get $font instanced]]]]
  }
  return $hhea
}

# vhea, with numOfLongVerMetrics matched to the vmtx written beside it - the
# same correction Hhea makes at the same offset, because vhea is hhea with the
# axes exchanged and keeps that field in the same place (ISO/IEC 14496-22).
#
# THE TABLE IS THERE AND IS LONG ENOUGH, and that is checked where the face is
# read rather than here: [sfnt ParseVertical] reads numOfLongVerMetrics out of
# the last two bytes of vhea, so it refuses a shorter one - TCLPDF FONT
# DAMAGED vhea - before any of this runs, and a face with no vhea at all never
# gets "vertical advances" and is not sent down this road. A second test here
# would be a refusal no fixture can reach.
proc ::tclpdf::subset::Vhea {font count} {
  set vhea [::tclpdf::sfnt table $font vhea]
  return [string replace $vhea 34 35 [binary format Su $count]]
}

# VORG in the new numbering. The default stays as it was - it describes the
# face, not a glyph - and only the glyphs that travel keep an entry of their
# own, renumbered. The entries must be sorted by glyph id (the format says
# so, and a reader is entitled to search them).
proc ::tclpdf::subset::Vorg {font order} {
  set origins [dict get $font vertical origins]
  set entries {}
  set new 0
  foreach glyph $order {
    if {[dict exists $origins $glyph]} {
      lappend entries [list $new [dict get $origins $glyph]]
    }
    incr new
  }
  set entries [lsort -integer -index 0 $entries]
  set bytes [binary format SuSuSSu 1 0 \
      [dict get $font vertical originDefault] [llength $entries]]
  foreach entry $entries {
    append bytes [binary format SuS {*}$entry]
  }
  return $bytes
}

proc ::tclpdf::subset::Maxp {font count} {
  set maxp [::tclpdf::sfnt table $font maxp]
  return [string replace $maxp 4 5 [binary format Su $count]]
}

# Put the tables back together with a valid table directory.
proc ::tclpdf::subset::Assemble {tables} {
  # Tags in ascending order - the format requires it, and a reader may binary
  # search the directory.
  set tags [lsort [dict keys $tables]]
  set count [llength $tags]
  # searchRange etc. are the usual binary-search hints: the largest power of
  # two not exceeding the table count, times 16.
  set power 1
  while {$power * 2 <= $count} {
    set power [expr {$power * 2}]
  }
  set searchRange [expr {$power * 16}]
  set entrySelector [expr {int(log($power) / log(2))}]
  set rangeShift [expr {$count * 16 - $searchRange}]

  set header [binary format IuSuSuSuSu 0x00010000 $count $searchRange \
      $entrySelector $rangeShift]
  set directoryLength [expr {12 + $count * 16}]

  set offset $directoryLength
  set directory {}
  set body {}
  foreach tag $tags {
    set data [dict get $tables $tag]
    set length [string length $data]
    append directory [binary format a4IuIuIu $tag [Checksum $data] $offset $length]
    append body $data
    # Every table starts on a four-byte boundary.
    set padding [expr {(4 - $length % 4) % 4}]
    append body [string repeat \x00 $padding]
    incr offset [expr {$length + $padding}]
  }
  set file $header$directory$body
  # head.checkSumAdjustment (OpenType 'head', ISO/IEC 14496-22 5.2.4): with
  # the field at zero, sum the whole file as 32-bit words and store
  # 0xB1B0AFBA minus that sum. A reader that verifies it - fontTools does,
  # FreeType does not - saw 0 and a checksum mismatch in every subset before
  # this. The head table's own directory checksum stays the one computed
  # above, over the zeroed field, which is what the format prescribes.
  if {[dict exists $tables head]} {
    set headOffset [expr {$directoryLength + [TableOffset $tags $tables head]}]
    set adjustment [expr {(0xB1B0AFBA - [Checksum $file]) & 0xFFFFFFFF}]
    set file [string replace $file [expr {$headOffset + 8}] \
        [expr {$headOffset + 11}] [binary format Iu $adjustment]]
  }
  return $file
}

# Where a table starts inside the body: the padded lengths of the tables that
# sort before it.
proc ::tclpdf::subset::TableOffset {tags tables tag} {
  set offset 0
  foreach candidate $tags {
    if {$candidate eq $tag} {
      return $offset
    }
    set length [string length [dict get $tables $candidate]]
    incr offset [expr {$length + (4 - $length % 4) % 4}]
  }
  return -code error -errorcode [list TCLPDF FONT SUBSET table] \
      "tclpdf: no table $tag in the subset"
}

# The table checksum: the sum of the 32-bit words, modulo 2^32.
proc ::tclpdf::subset::Checksum {data} {
  set padding [expr {(4 - [string length $data] % 4) % 4}]
  append data [string repeat \x00 $padding]
  binary scan $data Iu* words
  set sum 0
  foreach word $words {
    set sum [expr {($sum + $word) & 0xFFFFFFFF}]
  }
  return $sum
}

package provide tclpdf::subset 1.4
