#
# tclpdf - PDF generation for Tcl
#
# otLayout - the part of OpenType Layout that GPOS and GSUB have in common
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Infrastructure, not a topic: kernGpos.tcl reads pair kerning through it and
# liga.tcl reads ligatures. Nothing here knows about either.
#
# The two tables are navigated identically. ISO/IEC 14496-22:2019 prints the
# same six steps for GSUB (S. 266) as for GPOS: find the script, take its
# language system or the default one, follow the feature indices into the
# feature list, and assemble the lookups from the lookup list in the order
# that list gives. Only the payload of a subtable differs, and that stays in
# the calling module.
#
# Where the two do NOT agree, the caller says so: the extension lookup is
# type 9 in GPOS and type 7 in GSUB. Passing it in is the whole reason
# [subtables] takes two type numbers.
#

package require Tcl 8.6.11-

namespace eval ::tclpdf::otLayout {
  namespace export {[a-z]*}
  namespace ensemble create
}

# --- reading the bytes -----------------------------------------------------
#
# All offsets are relative to the start of the table that was handed in, and
# every one of them is checked. A layout table is the part of a font most
# likely to be damaged or truncated, and an unchecked [binary scan] past the
# end returns an empty variable rather than failing - which then travels on as
# a glyph number.
#
# A failure here carries the error code TCLPDF LAYOUT RANGE. That is what lets
# a caller swallow a damaged font without also swallowing a mistake in this
# package: a typo or a wrong argument count raises with a different code and
# must not be turned into "this font has no ligatures".

proc ::tclpdf::otLayout::u16 {bytes offset} {
  if {$offset < 0 || $offset + 2 > [string length $bytes]} {
    return -code error -errorcode {TCLPDF LAYOUT RANGE} \
        "tclpdf: layout offset $offset is outside the table"
  }
  binary scan $bytes @${offset}Su value
  return $value
}

proc ::tclpdf::otLayout::s16 {bytes offset} {
  if {$offset < 0 || $offset + 2 > [string length $bytes]} {
    return -code error -errorcode {TCLPDF LAYOUT RANGE} \
        "tclpdf: layout offset $offset is outside the table"
  }
  binary scan $bytes @${offset}S value
  return $value
}

proc ::tclpdf::otLayout::u32 {bytes offset} {
  if {$offset < 0 || $offset + 4 > [string length $bytes]} {
    return -code error -errorcode {TCLPDF LAYOUT RANGE} \
        "tclpdf: layout offset $offset is outside the table"
  }
  binary scan $bytes @${offset}Iu value
  return $value
}

proc ::tclpdf::otLayout::tag {bytes offset} {
  if {$offset < 0 || $offset + 4 > [string length $bytes]} {
    return -code error -errorcode {TCLPDF LAYOUT RANGE} \
        "tclpdf: layout offset $offset is outside the table"
  }
  return [string range $bytes $offset [expr {$offset + 3}]]
}

# --- finding the features --------------------------------------------------

# The default language system of the script tclpdf writes for.
#
# tclpdf has no script or language API, so one script has to be picked:
# "latn" if the font has it, "DFLT" otherwise, and failing both the first in
# the list.
#
# The order matters and is measured, not guessed. In DejaVu Sans the "latn"
# script reaches kerning lookups 14 AND 15 while "DFLT" and every other script
# reach only 15 - taking DFLT first therefore loses the whole Latin pair
# kerning and leaves a subtable of twenty glyphs behind.
#
# What this gives up: text in another script is treated with the Latin
# lookups. Resolving the script from the text itself is the honest fix and
# needs a script API this package does not have.
proc ::tclpdf::otLayout::langSys {table} {
  set scriptList [u16 $table 4]
  set count [u16 $table $scriptList]
  set byTag {}
  set firstOffset {}
  for {set index 0} {$index < $count} {incr index} {
    set record [expr {$scriptList + 2 + $index * 6}]
    set name [tag $table $record]
    set offset [expr {$scriptList + [u16 $table [expr {$record + 4}]]}]
    dict set byTag $name $offset
    if {$firstOffset eq {}} {
      set firstOffset $offset
    }
  }
  set script {}
  foreach name {latn DFLT} {
    if {[dict exists $byTag $name]} {
      set script [dict get $byTag $name]
      break
    }
  }
  if {$script eq {} && $firstOffset ne {}} {
    set script $firstOffset
  }
  if {$script eq {}} {
    return {}
  }
  set defaultOffset [u16 $table $script]
  if {$defaultOffset == 0} {
    return {}
  }
  return [expr {$script + $defaultOffset}]
}

# The lookup indices of every feature with this tag, in lookup order.
#
# A font may carry more than one record for the same tag, so this collects all
# of them rather than stopping at the first. The required feature is checked
# separately: it is named by its own field and does NOT appear in the feature
# index list, so a font whose ligatures are the required feature - Arabic
# lam-alef is the standing example - would otherwise come out empty.
#
# The result is sorted by lookup index because the specification applies
# lookups in the order of the lookup list, not in the order the feature names
# them.
proc ::tclpdf::otLayout::featureLookups {table wanted} {
  set langSys [langSys $table]
  if {$langSys eq {}} {
    return {}
  }
  set featureList [u16 $table 6]
  set required [u16 $table [expr {$langSys + 2}]]
  set count [u16 $table [expr {$langSys + 4}]]
  set features {}
  if {$required != 0xFFFF} {
    lappend features $required
  }
  for {set index 0} {$index < $count} {incr index} {
    lappend features [u16 $table [expr {$langSys + 6 + $index * 2}]]
  }
  set featureCount [u16 $table $featureList]
  set indices {}
  foreach featureIndex $features {
    if {$featureIndex >= $featureCount} {
      continue
    }
    set record [expr {$featureList + 2 + $featureIndex * 6}]
    if {[tag $table $record] ne $wanted} {
      continue
    }
    set feature [expr {$featureList + [u16 $table [expr {$record + 4}]]}]
    set lookupCount [u16 $table [expr {$feature + 2}]]
    for {set at 0} {$at < $lookupCount} {incr at} {
      set lookupIndex [u16 $table [expr {$feature + 4 + $at * 2}]]
      if {$lookupIndex ni $indices} {
        lappend indices $lookupIndex
      }
    }
  }
  return [lsort -integer $indices]
}

# The subtable offsets of one lookup, keeping only the wanted type.
#
# An extension lookup is not a type of its own: it holds a 32 bit offset so
# that a lookup can reach past the 64 KiB an Offset16 spans, and the type it
# wraps is what counts. Which number that is differs between the two tables,
# so the caller passes it in.
#
# The lookup header is variable: markFilteringSet is present only when flag
# 0x0010 is set. It is not read here - nothing after it is needed - but the
# subtable offsets sit BEFORE it, so the layout is safe either way.
proc ::tclpdf::otLayout::subtables {table lookup wantedType extensionType} {
  set type [u16 $table $lookup]
  set count [u16 $table [expr {$lookup + 4}]]
  set offsets {}
  for {set at 0} {$at < $count} {incr at} {
    set subtable [expr {$lookup + [u16 $table [expr {$lookup + 6 + $at * 2}]]}]
    set kind $type
    if {$type == $extensionType} {
      set kind [u16 $table [expr {$subtable + 2}]]
      set subtable [expr {$subtable + [u32 $table [expr {$subtable + 4}]]}]
    }
    if {$kind == $wantedType} {
      lappend offsets $subtable
    }
  }
  return $offsets
}

# The offset of one lookup within the lookup list, or {} when out of range.
proc ::tclpdf::otLayout::lookup {table index} {
  set lookupList [u16 $table 8]
  if {$index >= [u16 $table $lookupList]} {
    return {}
  }
  return [expr {$lookupList + [u16 $table [expr {$lookupList + 2 + $index * 2}]]}]
}

# --- the two tables every subtable format uses -----------------------------

# Coverage as a dict glyph -> coverage index. The index is what parallel
# arrays are numbered by - pair sets in GPOS, ligature sets in GSUB - so the
# order matters and a plain set would not do.
proc ::tclpdf::otLayout::coverage {table offset} {
  set format [u16 $table $offset]
  set glyphs {}
  switch -- $format {
    1 {
      set count [u16 $table [expr {$offset + 2}]]
      for {set index 0} {$index < $count} {incr index} {
        dict set glyphs [u16 $table [expr {$offset + 4 + $index * 2}]] $index
      }
    }
    2 {
      set count [u16 $table [expr {$offset + 2}]]
      for {set index 0} {$index < $count} {incr index} {
        set record [expr {$offset + 4 + $index * 6}]
        set start [u16 $table $record]
        set end [u16 $table [expr {$record + 2}]]
        set at [u16 $table [expr {$record + 4}]]
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
proc ::tclpdf::otLayout::classDef {table offset} {
  set format [u16 $table $offset]
  set classes {}
  switch -- $format {
    1 {
      set start [u16 $table [expr {$offset + 2}]]
      set count [u16 $table [expr {$offset + 4}]]
      for {set index 0} {$index < $count} {incr index} {
        set class [u16 $table [expr {$offset + 6 + $index * 2}]]
        if {$class != 0} {
          dict set classes [expr {$start + $index}] $class
        }
      }
    }
    2 {
      set count [u16 $table [expr {$offset + 2}]]
      for {set index 0} {$index < $count} {incr index} {
        set record [expr {$offset + 4 + $index * 6}]
        set start [u16 $table $record]
        set end [u16 $table [expr {$record + 2}]]
        set class [u16 $table [expr {$record + 4}]]
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

package provide tclpdf::otLayout 1.0
