#
# tclpdf - PDF generation for Tcl
#
# kernGpos - pair kerning out of the GPOS table
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Behind kern.tcl, which owns the precedence between this and the old "kern"
# table and is the only caller. Nothing else should require this module.
#
# The walk to the lookups - script, language system, feature, lookup list,
# coverage - is the same one GSUB needs and lives in otLayout.tcl. What stays
# here is the part that is GPOS and only GPOS: the value record, and pair
# positioning as the one lookup type kerning is written in.
#
# Everything else GPOS can do - marks, cursive attachment, contextual
# positioning - is deliberately not read. A writer that places glyphs one
# after another has no use for it.
#
# The pairs are NOT expanded into a flat table. A class based subtable pairs
# every glyph of one class with every glyph of another, so expanding it can
# turn a few hundred entries into millions. The subtables are kept as they are
# and asked per pair instead.
#

package require Tcl 8.6.11-
package require tclpdf::sfnt 1.0-
package require tclpdf::otLayout 1.0-

namespace eval ::tclpdf::kernGpos {
  namespace export {[a-z]*}
  namespace ensemble create

  # Pair positioning, and the number an extension lookup carries in GPOS.
  variable pairType 2
  variable extensionType 9
}

# Does the resolved language system have kerning lookups? This is the question
# the precedence rule of the specification asks (8.16), and it has to be
# answerable without reading the pairs themselves - an empty result is not the
# same answer as "no lookups", which is why this is its own command.
proc ::tclpdf::kernGpos::lookups {font} {
  set gpos [::tclpdf::sfnt table $font GPOS]
  if {$gpos eq {}} {
    return {}
  }
  if {[Damaged {set indices [::tclpdf::otLayout featureLookups $gpos kern]}]} {
    # A damaged GPOS table is not a reason to refuse the document: the text is
    # then set without kerning, which is what a font without GPOS would give.
    return {}
  }
  return $indices
}

# Run a script, and say whether it failed on DAMAGED FONT DATA. Anything else
# is re-raised - only the bounds checks of otLayout raise TCLPDF LAYOUT, so a
# mistake in this file surfaces instead of turning into "no kerning".
proc ::tclpdf::kernGpos::Damaged {script} {
  set code [catch {uplevel 1 $script} result options]
  if {!$code} {
    return 0
  }
  if {[lrange [dict get $options -errorcode] 0 1] eq {TCLPDF LAYOUT}} {
    return 1
  }
  return -options $options $result
}

# The subtables of all kerning lookups, in lookup order, prepared for [value].
proc ::tclpdf::kernGpos::subtables {font} {
  set gpos [::tclpdf::sfnt table $font GPOS]
  if {$gpos eq {}} {
    return {}
  }
  return [Collect $gpos]
}

# The adjustment for one pair, in font units. Zero when no subtable knows it.
#
# Lookups are applied one after another and their adjustments add up; within
# one lookup the first subtable that knows the pair wins, which is how the
# specification has subtables searched.
proc ::tclpdf::kernGpos::value {prepared left right} {
  set total 0
  foreach lookup $prepared {
    foreach subtable $lookup {
      lassign $subtable kind data
      set found 0
      switch -- $kind {
        pairs {
          if {[dict exists $data $left,$right]} {
            set total [expr {$total + [dict get $data $left,$right]}]
            set found 1
          }
        }
        classes {
          lassign $data coverage first second matrix
          if {[dict exists $coverage $left]} {
            # Class 0 is not a hole: it is "everything the class definition
            # does not name", and the matrix has a row and a column for it.
            set one 0
            set two 0
            if {[dict exists $first $left]} {
              set one [dict get $first $left]
            }
            if {[dict exists $second $right]} {
              set two [dict get $second $right]
            }
            if {[dict exists $matrix $one,$two]} {
              set total [expr {$total + [dict get $matrix $one,$two]}]
            }
            # Coverage decides, not the matrix cell: a zero cell is a decision
            # of the font, and the next subtable must not overrule it.
            set found 1
          }
        }
      }
      if {$found} {
        break
      }
    }
  }
  return $total
}

# --- the GPOS side ---------------------------------------------------------

# One lookup at a time, and a damaged one costs only itself - see the same
# boundary in liga.tcl for why it does not sit around the whole walk.
proc ::tclpdf::kernGpos::Collect {gpos} {
  variable pairType
  variable extensionType
  set indices {}
  if {[Damaged {set indices [::tclpdf::otLayout featureLookups $gpos kern]}]} {
    return {}
  }
  set prepared {}
  foreach index $indices {
    set subtables {}
    if {[Damaged {
      set lookup [::tclpdf::otLayout lookup $gpos $index]
      if {$lookup ne {}} {
        foreach offset [::tclpdf::otLayout subtables $gpos $lookup $pairType \
            $extensionType] {
          set entry [PairPos $gpos $offset]
          if {[llength $entry]} {
            lappend subtables $entry
          }
        }
      }
    }]} {
      continue
    }
    if {[llength $subtables]} {
      lappend prepared $subtables
    }
  }
  return $prepared
}

# How many bytes one value record occupies, and where its XAdvance sits.
#
# Every set bit means two bytes, whether it is a value or a device offset.
# Only XAdvance is of interest here: it adjusts the advance of the first glyph
# of the pair, which is what kerning is. XPlacement would move the glyph
# without moving the ones after it.
proc ::tclpdf::kernGpos::ValueSize {format} {
  set size 0
  for {set bit 0} {$bit < 8} {incr bit} {
    if {$format & (1 << $bit)} {
      incr size 2
    }
  }
  return $size
}

proc ::tclpdf::kernGpos::XAdvanceAt {format} {
  if {!($format & 0x0004)} {
    return -1
  }
  set at 0
  foreach bit {0x0001 0x0002} {
    if {$format & $bit} {
      incr at 2
    }
  }
  return $at
}

proc ::tclpdf::kernGpos::XAdvance {bytes offset format} {
  set at [XAdvanceAt $format]
  if {$at < 0} {
    return 0
  }
  return [::tclpdf::otLayout s16 $bytes [expr {$offset + $at}]]
}

proc ::tclpdf::kernGpos::PairPos {gpos subtable} {
  set format [::tclpdf::otLayout u16 $gpos $subtable]
  set coverage [expr {$subtable + [::tclpdf::otLayout u16 $gpos \
      [expr {$subtable + 2}]]}]
  set format1 [::tclpdf::otLayout u16 $gpos [expr {$subtable + 4}]]
  set format2 [::tclpdf::otLayout u16 $gpos [expr {$subtable + 6}]]
  # A subtable that adjusts nothing horizontally is of no use here, and
  # skipping it early saves walking a class matrix for nothing.
  if {[XAdvanceAt $format1] < 0} {
    return {}
  }
  set size1 [ValueSize $format1]
  set size2 [ValueSize $format2]
  switch -- $format {
    1 {
      set glyphs [::tclpdf::otLayout coverage $gpos $coverage]
      set pairSetCount [::tclpdf::otLayout u16 $gpos [expr {$subtable + 8}]]
      set pairs {}
    # The array beside a coverage table is ordered BY COVERAGE INDEX, not by
    # the order the glyphs happen to come out of the table (ISO/IEC 14496-22,
    # p. 270). The two coincide for a conforming format 2 coverage, whose
    # ranges must be in glyph id order - which is why a running counter worked
    # everywhere it was tried. A font that breaks that rule would get the
    # wrong set silently, so the index the table already carries is used.
      dict for {left index} $glyphs {
        if {$index >= $pairSetCount} {
          continue
        }
        set pairSet [expr {$subtable + [::tclpdf::otLayout u16 $gpos \
            [expr {$subtable + 10 + $index * 2}]]}]
        set pairCount [::tclpdf::otLayout u16 $gpos $pairSet]
        set stride [expr {2 + $size1 + $size2}]
        for {set at 0} {$at < $pairCount} {incr at} {
          set record [expr {$pairSet + 2 + $at * $stride}]
          set right [::tclpdf::otLayout u16 $gpos $record]
          set adjust [XAdvance $gpos [expr {$record + 2}] $format1]
          if {$adjust != 0} {
            dict set pairs $left,$right $adjust
          }
        }
      }
      if {![dict size $pairs]} {
        return {}
      }
      return [list pairs $pairs]
    }
    2 {
      set glyphs [::tclpdf::otLayout coverage $gpos $coverage]
      set first [::tclpdf::otLayout classDef $gpos [expr {$subtable +
          [::tclpdf::otLayout u16 $gpos [expr {$subtable + 8}]]}]]
      set second [::tclpdf::otLayout classDef $gpos [expr {$subtable +
          [::tclpdf::otLayout u16 $gpos [expr {$subtable + 10}]]}]]
      set class1Count [::tclpdf::otLayout u16 $gpos [expr {$subtable + 12}]]
      set class2Count [::tclpdf::otLayout u16 $gpos [expr {$subtable + 14}]]
      set stride [expr {$size1 + $size2}]
      set matrix {}
      for {set one 0} {$one < $class1Count} {incr one} {
        set row [expr {$subtable + 16 + $one * $class2Count * $stride}]
        for {set two 0} {$two < $class2Count} {incr two} {
          set adjust [XAdvance $gpos [expr {$row + $two * $stride}] $format1]
          if {$adjust != 0} {
            dict set matrix $one,$two $adjust
          }
        }
      }
      if {![dict size $matrix]} {
        return {}
      }
      return [list classes [list $glyphs $first $second $matrix]]
    }
  }
  return {}
}

package provide tclpdf::kernGpos 1.2
