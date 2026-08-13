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
# What is read here is the smallest path through OpenType Layout that yields
# pair kerning: script list -> language system -> "kern" feature -> lookup list
# -> pair positioning. Everything else GPOS can do - marks, cursive attachment,
# contextual positioning - is deliberately not read. A writer that places
# glyphs one after another has no use for it.
#
# The pairs are NOT expanded into a flat table. A class based subtable pairs
# every glyph of one class with every glyph of another, so expanding it can
# turn a few hundred entries into millions. The subtables are kept as they are
# and asked per pair instead.
#

package require Tcl 8.6.11-
package require tclpdf::sfnt 1.0-

namespace eval ::tclpdf::kernGpos {
  namespace export {[a-z]*}
  namespace ensemble create
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
  if {[catch {KernLookupIndices $gpos} indices]} {
    # A damaged GPOS table is not a reason to refuse the document: the text is
    # then set without kerning, which is what a font without GPOS would give.
    return {}
  }
  return $indices
}

# The subtables of all kerning lookups, in lookup order, prepared for [value].
proc ::tclpdf::kernGpos::subtables {font} {
  set gpos [::tclpdf::sfnt table $font GPOS]
  if {$gpos eq {}} {
    return {}
  }
  if {[catch {Collect $gpos} prepared]} {
    return {}
  }
  return $prepared
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

# --- the walk through the table -------------------------------------------

proc ::tclpdf::kernGpos::U16 {bytes offset} {
  if {$offset < 0 || $offset + 2 > [string length $bytes]} {
    return -code error "tclpdf: GPOS offset $offset is outside the table"
  }
  binary scan $bytes @${offset}Su value
  return $value
}

proc ::tclpdf::kernGpos::S16 {bytes offset} {
  if {$offset < 0 || $offset + 2 > [string length $bytes]} {
    return -code error "tclpdf: GPOS offset $offset is outside the table"
  }
  binary scan $bytes @${offset}S value
  return $value
}

proc ::tclpdf::kernGpos::U32 {bytes offset} {
  if {$offset < 0 || $offset + 4 > [string length $bytes]} {
    return -code error "tclpdf: GPOS offset $offset is outside the table"
  }
  binary scan $bytes @${offset}Iu value
  return $value
}

proc ::tclpdf::kernGpos::Tag {bytes offset} {
  if {$offset < 0 || $offset + 4 > [string length $bytes]} {
    return -code error "tclpdf: GPOS offset $offset is outside the table"
  }
  return [string range $bytes $offset [expr {$offset + 3}]]
}

# The feature indices of the language system tclpdf writes for.
#
# tclpdf has no script or language API, so one script has to be picked: "latn"
# if the font has it, "DFLT" otherwise, and failing both the first in the list.
#
# The order matters and is measured, not guessed. In DejaVu Sans the "latn"
# script reaches kerning lookups 14 AND 15 while "DFLT" and every other script
# reach only 15 - taking DFLT first therefore loses the whole Latin pair
# kerning and leaves a subtable of twenty glyphs behind. Across the fonts
# shipped with the examples "latn" is a superset everywhere and smaller
# nowhere; Niconne carries no DFLT at all.
#
# What this gives up: text in another script is kerned with the Latin lookups.
# In the fonts measured here that is the same data - DejaVu points cyrl, grek
# and the rest at lookup 15, which "latn" includes - but a font that kerns
# Cyrillic differently would be kerned wrongly. Resolving the script from the
# text itself is the honest fix and needs a script API this package does not
# have.
proc ::tclpdf::kernGpos::LangSys {gpos} {
  set scriptList [U16 $gpos 4]
  set count [U16 $gpos $scriptList]
  set byTag {}
  set firstOffset {}
  for {set index 0} {$index < $count} {incr index} {
    set record [expr {$scriptList + 2 + $index * 6}]
    set tag [Tag $gpos $record]
    set offset [expr {$scriptList + [U16 $gpos [expr {$record + 4}]]}]
    dict set byTag $tag $offset
    if {$firstOffset eq {}} {
      set firstOffset $offset
    }
  }
  set script {}
  foreach tag {latn DFLT} {
    if {[dict exists $byTag $tag]} {
      set script [dict get $byTag $tag]
      break
    }
  }
  if {$script eq {} && $firstOffset ne {}} {
    set script $firstOffset
  }
  if {$script eq {}} {
    return {}
  }
  set defaultOffset [U16 $gpos $script]
  if {$defaultOffset == 0} {
    return {}
  }
  return [expr {$script + $defaultOffset}]
}

# The lookup indices of every "kern" feature of that language system.
#
# A font may carry more than one "kern" record - one per language system - so
# this collects all of them rather than stopping at the first. The required
# feature is checked separately: it is named by its own field and does NOT
# appear in the feature index list, so a font whose kerning is the required
# feature would otherwise come out unkerned.
proc ::tclpdf::kernGpos::KernLookupIndices {gpos} {
  set langSys [LangSys $gpos]
  if {$langSys eq {}} {
    return {}
  }
  set featureList [U16 $gpos 6]
  set required [U16 $gpos [expr {$langSys + 2}]]
  set count [U16 $gpos [expr {$langSys + 4}]]
  set wanted {}
  if {$required != 0xFFFF} {
    lappend wanted $required
  }
  for {set index 0} {$index < $count} {incr index} {
    lappend wanted [U16 $gpos [expr {$langSys + 6 + $index * 2}]]
  }
  set featureCount [U16 $gpos $featureList]
  set indices {}
  foreach featureIndex $wanted {
    if {$featureIndex >= $featureCount} {
      continue
    }
    set record [expr {$featureList + 2 + $featureIndex * 6}]
    if {[Tag $gpos $record] ne "kern"} {
      continue
    }
    set feature [expr {$featureList + [U16 $gpos [expr {$record + 4}]]}]
    set lookupCount [U16 $gpos [expr {$feature + 2}]]
    for {set at 0} {$at < $lookupCount} {incr at} {
      set lookupIndex [U16 $gpos [expr {$feature + 4 + $at * 2}]]
      if {$lookupIndex ni $indices} {
        lappend indices $lookupIndex
      }
    }
  }
  # Lookup order, not feature order, is what the specification applies.
  return [lsort -integer $indices]
}

proc ::tclpdf::kernGpos::Collect {gpos} {
  set indices [KernLookupIndices $gpos]
  if {![llength $indices]} {
    return {}
  }
  set lookupList [U16 $gpos 8]
  set lookupCount [U16 $gpos $lookupList]
  set prepared {}
  foreach lookupIndex $indices {
    if {$lookupIndex >= $lookupCount} {
      continue
    }
    set lookup [expr {$lookupList + [U16 $gpos [expr {$lookupList + 2 + $lookupIndex * 2}]]}]
    set type [U16 $gpos $lookup]
    set subtableCount [U16 $gpos [expr {$lookup + 4}]]
    set subtables {}
    for {set at 0} {$at < $subtableCount} {incr at} {
      set subtable [expr {$lookup + [U16 $gpos [expr {$lookup + 6 + $at * 2}]]}]
      set kind $type
      # Type 9 is not a positioning type of its own: it only holds a 32 bit
      # offset so that a lookup can reach past the 64 KiB an Offset16 spans.
      if {$type == 9} {
        set kind [U16 $gpos [expr {$subtable + 2}]]
        set subtable [expr {$subtable + [U32 $gpos [expr {$subtable + 4}]]}]
      }
      if {$kind != 2} {
        continue
      }
      set entry [PairPos $gpos $subtable]
      if {[llength $entry]} {
        lappend subtables $entry
      }
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
  return [S16 $bytes [expr {$offset + $at}]]
}

proc ::tclpdf::kernGpos::PairPos {gpos subtable} {
  set format [U16 $gpos $subtable]
  set coverage [expr {$subtable + [U16 $gpos [expr {$subtable + 2}]]}]
  set format1 [U16 $gpos [expr {$subtable + 4}]]
  set format2 [U16 $gpos [expr {$subtable + 6}]]
  # A subtable that adjusts nothing horizontally is of no use here, and
  # skipping it early saves walking a class matrix for nothing.
  if {[XAdvanceAt $format1] < 0} {
    return {}
  }
  set size1 [ValueSize $format1]
  set size2 [ValueSize $format2]
  switch -- $format {
    1 {
      set glyphs [Coverage $gpos $coverage]
      set pairSetCount [U16 $gpos [expr {$subtable + 8}]]
      set pairs {}
      set index 0
      foreach left [dict keys $glyphs] {
        if {$index >= $pairSetCount} {
          break
        }
        set pairSet [expr {$subtable + [U16 $gpos [expr {$subtable + 10 + $index * 2}]]}]
        set pairCount [U16 $gpos $pairSet]
        set stride [expr {2 + $size1 + $size2}]
        for {set at 0} {$at < $pairCount} {incr at} {
          set record [expr {$pairSet + 2 + $at * $stride}]
          set right [U16 $gpos $record]
          set adjust [XAdvance $gpos [expr {$record + 2}] $format1]
          if {$adjust != 0} {
            dict set pairs $left,$right $adjust
          }
        }
        incr index
      }
      if {![dict size $pairs]} {
        return {}
      }
      return [list pairs $pairs]
    }
    2 {
      set glyphs [Coverage $gpos $coverage]
      set first [ClassDef $gpos [expr {$subtable + [U16 $gpos [expr {$subtable + 8}]]}]]
      set second [ClassDef $gpos [expr {$subtable + [U16 $gpos [expr {$subtable + 10}]]}]]
      set class1Count [U16 $gpos [expr {$subtable + 12}]]
      set class2Count [U16 $gpos [expr {$subtable + 14}]]
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

# Coverage as a dict glyph -> coverage index. The index is what format 1 pair
# sets are numbered by, so the order matters and a plain set would not do.
proc ::tclpdf::kernGpos::Coverage {gpos offset} {
  set format [U16 $gpos $offset]
  set glyphs {}
  switch -- $format {
    1 {
      set count [U16 $gpos [expr {$offset + 2}]]
      for {set index 0} {$index < $count} {incr index} {
        dict set glyphs [U16 $gpos [expr {$offset + 4 + $index * 2}]] $index
      }
    }
    2 {
      set count [U16 $gpos [expr {$offset + 2}]]
      for {set index 0} {$index < $count} {incr index} {
        set record [expr {$offset + 4 + $index * 6}]
        set start [U16 $gpos $record]
        set end [U16 $gpos [expr {$record + 2}]]
        set at [U16 $gpos [expr {$record + 4}]]
        for {set glyph $start} {$glyph <= $end} {incr glyph} {
          dict set glyphs $glyph [expr {$at + $glyph - $start}]
        }
      }
    }
  }
  return $glyphs
}

# A class definition as a dict glyph -> class. Glyphs that are not named
# belong to class 0 and are simply absent here.
proc ::tclpdf::kernGpos::ClassDef {gpos offset} {
  set format [U16 $gpos $offset]
  set classes {}
  switch -- $format {
    1 {
      set start [U16 $gpos [expr {$offset + 2}]]
      set count [U16 $gpos [expr {$offset + 4}]]
      for {set index 0} {$index < $count} {incr index} {
        set class [U16 $gpos [expr {$offset + 6 + $index * 2}]]
        if {$class != 0} {
          dict set classes [expr {$start + $index}] $class
        }
      }
    }
    2 {
      set count [U16 $gpos [expr {$offset + 2}]]
      for {set index 0} {$index < $count} {incr index} {
        set record [expr {$offset + 4 + $index * 6}]
        set start [U16 $gpos $record]
        set end [U16 $gpos [expr {$record + 2}]]
        set class [U16 $gpos [expr {$record + 4}]]
        if {$class == 0} {
          continue
        }
        for {set glyph $start} {$glyph <= $end} {incr glyph} {
          dict set classes $glyph $class
        }
      }
    }
  }
  return $classes
}

package provide tclpdf::kernGpos 1.0
