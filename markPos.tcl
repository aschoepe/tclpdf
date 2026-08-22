#
# tclpdf - PDF generation for Tcl
#
# markPos - where a combining mark sits: GPOS mark attachment
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# One topic: the three GPOS lookups that attach a mark to something -
# MarkToBase (type 4), MarkToLigature (type 5) and MarkToMark (type 6),
# ISO/IEC 14496-22:2019, 6.3.3. Nothing else. The walk to the lookups is
# otLayout.tcl's, the glyph classes a lookup flag filters by are gdef.tcl's,
# and the pair kerning of kernGpos.tcl shares nothing with this file: types
# 4, 5 and 6 carry no ValueRecord at all.
#
# Why a producer needs it. Without it a combining mark is drawn at the pen
# position, which for a mark of zero advance means: on top of the glyph that
# follows it, at the baseline. Measured in DejaVu Sans, "b" + U+0300 puts the
# grave 510 units to the left and 373 units up from where it lands untouched -
# a quarter of an em in each direction, and visibly the wrong glyph carrying
# the accent.
#
# THE RULE, and it is the whole file (verified against HarfBuzz 14.3.1):
#
#   dx = baseAnchor.x - markAnchor.x - SUM advance(g)   g from the base up to
#   dy = baseAnchor.y - markAnchor.y                    but not including the
#                                                       mark itself
#
# The sum is there because the offset is applied at the pen position of the
# MARK, while the anchors are both stated in their own glyph's coordinate
# system. Everything between the base and the mark - the base's own advance,
# and every glyph the lookup flag left out of the sequence - has to be walked
# back over.
#
# Offsets CHAIN. A mark attached to a mark inherits the offset of the mark it
# hangs on, which is what stacks a Vietnamese tone mark above a vowel
# diacritic instead of on top of it. The chain is resolved once at the end
# rather than while the lookups run: a lookup may attach to a glyph that a
# later lookup moves again, and adding as we go would then use a position
# that no longer holds.
#
# What is NOT here, deliberately:
#
#   - Lookup type 3, cursive attachment. A different topic with a different
#     caller (forms.tcl); the anchor reader they will share already sits in
#     otLayout.tcl for that reason.
#   - Device and VariationIndex tables behind an anchor. See otLayout::anchor.
#   - A language-specific language system. Every script is read, but only its
#     DEFAULT language system; what a face puts behind "TRK " or "ROM " alone
#     stays unread, and choosing between them would need a language API this
#     package does not have.
#
# EVERY SCRIPT, IN TWO TIERS - the one place this file differs from the rest
# of the package, and the shape of the difference is the whole design.
#
# otLayout::langSys picks ONE script by name - "latn", else "DFLT", else the
# first in the table - and kern.tcl and liga.tcl go through it. For marks that
# is not enough, and not academically: the Hebrew nikud of DejaVu Sans hang
# off "hebr" in lookups 5 to 9, the Latin path reaches 4, 12 and 13, and every
# point therefore came out at offset zero - drawn at the pen position, beside
# its letter instead of under it. A mark belongs to the script of its LETTER,
# and this module never sees the letters: [offsets] is handed glyph numbers.
#
# Reading every script's mark lookups as ONE list was tried first and is
# wrong. Measured on Arimo: its Cyrillic mark lookup covers U+0300 and the
# capital schwa U+018F both, sits after the Latin one in the lookup list, and
# therefore won - putting the grave 57 units further left than HarfBuzz does.
# Seven pairs in that face, and every one of them a face the package sets
# correctly today. A wider net that moves a mark this package already places
# right is not an improvement.
#
# So the resolved script keeps the last word and the rest of the table is a
# FALLBACK: a lookup of another script is offered a mark only when the
# resolved script left that mark where it lay. Nothing that is placed today
# moves - measured over the 26 faces of examples/assets/fonts, 343 567
# base-and-mark pairs of which 292 687 had an answer before, and not one of
# them came out differently - and a Hebrew point that nothing placed at all
# gets placed. The order within each tier stays the lookup list's, which is
# what the specification prescribes; between the tiers it cannot, and that is
# the price - named here rather than hidden, because a face whose "latn" and
# "hebr" lookups both attach the SAME mark in sequence would need them
# interleaved. No face measured does.
#
# This does not fall out of step with the script the kerning was read under:
# tier one IS that script. The honest fix above all of it is still a script
# API, and that is not this file.
#

package require Tcl 8.6.11-
package require tclpdf::sfnt 1.0-
package require tclpdf::otLayout 1.0-
package require tclpdf::gdef 1.0-

namespace eval ::tclpdf::markPos {
  namespace export {[a-z]*}
  namespace ensemble create

  # The features that carry mark attachment. "mark" and "mkmk" are the two
  # every face uses; "abvm" and "blwm" are the Indic pair for marks above and
  # below, and they are not theoretical - Noto Sans carries both, measured.
  # All four go down in ONE call because the specification applies lookups in
  # the order of the lookup list, not feature by feature (S. 217).
  variable featureTags {mark mkmk abvm blwm}

  # The three lookup types read here, and the number an extension lookup
  # carries in GPOS.
  variable types {4 5 6}
  variable extensionType 9

  # The lookupFlag bit that means "ignore marks". Used as a ready-made filter
  # to answer one question gdef.tcl has no other name for: is this glyph a
  # mark? See [Marks].
  variable ignoreMarks 0x0008
}

# Prepare a font for mark attachment, or {} for a font that has none.
#
# Everything is read here, once: the coverage tables, the mark classes and
# every anchor. Unlike the class matrix of pair kerning there is nothing to
# blow up - a BaseArray holds exactly baseCount * markClassCount anchors and
# not one more, so reading it eagerly costs what the font itself costs.
#
# The result is cached by the caller (font.tcl, [FontLayoutState]), and {} is
# an answer like any other: a face without mark lookups is asked once.
#
# TWO TIERS, and the reason is in the file header. The lookups of the script
# otLayout::langSys resolves come first and are authoritative; every other
# script's mark lookups come after them as a FALLBACK, consulted only for a
# mark the first tier left where it lay.
proc ::tclpdf::markPos::build {font} {
  variable featureTags
  variable types
  variable extensionType
  set gpos [::tclpdf::sfnt table $font GPOS]
  if {$gpos eq {}} {
    return {}
  }
  set indices {}
  set every {}
  if {[::tclpdf::otLayout damaged {
      set indices [::tclpdf::otLayout featureLookups $gpos $featureTags]
      set every [::tclpdf::otLayout featureLookupsAnyScript $gpos \
          $featureTags]}]} {
    # A damaged GPOS costs the mark positions, not the document: the text is
    # then set the way a font without these lookups would set it.
    return {}
  }
  set fallback {}
  foreach index $every {
    if {$index ni $indices} {
      lappend fallback $index
    }
  }
  if {![llength $indices] && ![llength $fallback]} {
    return {}
  }
  set gdef [::tclpdf::gdef build $font]
  set lookups [Lookups $gpos $gdef $indices 0]
  lappend lookups {*}[Lookups $gpos $gdef $fallback 1]
  if {![llength $lookups]} {
    return {}
  }
  return [dict create font $font units [dict get $font unitsPerEm] \
      marks [Marks $gdef] lookups $lookups]
}

# The readable lookups of a list of indices, as {filter subtables fallback},
# in lookup order.
proc ::tclpdf::markPos::Lookups {gpos gdef indices fallback} {
  variable types
  variable extensionType
  set lookups {}
  foreach entry [::tclpdf::otLayout collectTyped $gpos $indices $types \
      $extensionType] {
    lassign $entry flag markSet typed
    set subtables {}
    # The error boundary sits inside the loop, not around the walk: one
    # unreadable lookup must cost only itself, or a face with four good mark
    # lookups and one broken one comes out with none.
    if {[::tclpdf::otLayout damaged {
        set subtables [Subtables $gpos $typed]}]} {
      continue
    }
    if {![llength $subtables]} {
      continue
    }
    lappend lookups [list [::tclpdf::gdef filter $gdef $flag $markSet] \
        $subtables $fallback]
  }
  return $lookups
}

# The offsets of a glyph run, in thousandths of the em: one {dx dy} per glyph,
# positionally aligned with the run that was handed in, {0 0} for every glyph
# nothing attached.
#
# RUN is the structure font.tcl carries, a flat list of {glyph codes} pairs -
# the same one [FontRunKern] is given, and for the same reason: a lookup that
# ignores marks sees the run WITHOUT them, so the question cannot be asked two
# glyphs at a time.
#
# Thousandths, not font units, because that is what a PDF text object is
# written in and what kern.tcl already answers in. Two units would mean two
# conversions, and measuring and drawing would drift apart between them.
proc ::tclpdf::markPos::run {state run} {
  set count [llength $run]
  if {$state eq {} || $count < 2} {
    return [lrepeat $count {0 0}]
  }
  set glyphs [lmap item $run {lindex $item 0}]
  set units [dict get $state units]
  set scaled {}
  foreach offset [offsets $state $glyphs] {
    lassign $offset dx dy
    if {$dx == 0 && $dy == 0} {
      # The common case by far, and it stays an EXACT zero rather than
      # becoming 0.0: this command promises {0 0} for a glyph nothing moved,
      # and a caller that skips the untouched glyphs should be able to test
      # for it without knowing about floating point.
      lappend scaled {0 0}
      continue
    }
    lappend scaled [list [expr {$dx * 1000.0 / $units}] \
        [expr {$dy * 1000.0 / $units}]]
  }
  return $scaled
}

# The same, in FONT UNITS and from a plain glyph list.
#
# Public because that is the unit the specification, the font and every
# measurement are stated in: a test that wants to say "the grave moves 510
# units left" should not have to divide by the em first, and neither should
# the next reader of this file.
proc ::tclpdf::markPos::offsets {state glyphs} {
  set count [llength $glyphs]
  if {$state eq {} || $count < 2} {
    return [lrepeat $count {0 0}]
  }
  # own: the offset a mark has relative to the glyph it hangs on.
  # attached: which glyph that is, or {} for a glyph nothing attached.
  set own [lrepeat $count {0 0}]
  set attached [lrepeat $count {}]
  set anything 0
  # What the RESOLVED script settled, kept aside before the fallback tier
  # begins. The two tiers are one loop because the lookups come in one list in
  # lookup order, and the boundary is the first fallback lookup in it.
  set locked [lrepeat $count {}]
  set frozen 0
  foreach lookup [dict get $state lookups] {
    lassign $lookup filter subtables fallback
    if {$fallback && !$frozen} {
      set locked $attached
      set frozen 1
    }
    # An EMPTY filter keeps every index - that is gdef.tcl's own contract for
    # a lookup that filters nothing, and asking it unconditionally is one
    # branch fewer than spelling the identity case out here.
    set visible [::tclpdf::gdef keep $filter $glyphs]
    set seen [llength $visible]
    # A mark needs something before it, so the first visible glyph is never a
    # candidate. Within one lookup every glyph is offered before the next
    # lookup runs, which is the order the specification prescribes (S. 217).
    for {set at 1} {$at < $seen} {incr at} {
      set index [lindex $visible $at]
      # A FALLBACK lookup - one that belongs to a script other than the one
      # the package resolved - never overrules an answer the RESOLVED script
      # gave. Measured on Arimo: its Cyrillic mark lookup covers U+0300 and
      # U+018F both, and puts the grave over the capital schwa 57 units
      # further left than the Latin lookup does. HarfBuzz places it where the
      # Latin lookup says, so the second tier has to stay out of the way where
      # the first one spoke.
      #
      # Among THEMSELVES the fallback lookups keep the ordinary rule and the
      # last one wins, because they are still one lookup list in the order the
      # specification prescribes. Letting the first win instead cost 32 of the
      # 1170 Hebrew pairs of Liberation Sans their refinement: its lookup 1
      # attaches a holam that lookups 27 to 34 then move 25 units further,
      # which is where HarfBuzz leaves it.
      if {$fallback && [lindex $locked $index] ne {}} {
        continue
      }
      set found [Attach $state $subtables $visible $at $glyphs]
      if {![llength $found]} {
        continue
      }
      lassign $found partner dx dy
      # ASSIGNED, not added: an attachment says where the mark IS, and a
      # second lookup that knows better replaces the first answer rather than
      # adding to it. Only the chain, resolved below, adds anything. This is
      # what HarfBuzz does, and two lookups attaching the same mark is rare
      # enough that any other reading would be untested guesswork.
      lset own $index [list $dx $dy]
      lset attached $index $partner
      set anything 1
    }
  }
  set result [lrepeat $count {0 0}]
  if {!$anything} {
    return $result
  }
  # The chain, resolved in one forward pass. A mark always attaches to a glyph
  # BEFORE it, so by the time index is reached its parent is already final and
  # no recursion is needed.
  set font [dict get $state font]
  for {set index 0} {$index < $count} {incr index} {
    set parent [lindex $attached $index]
    if {$parent eq {}} {
      continue
    }
    lassign [lindex $own $index] dx dy
    lassign [lindex $result $parent] px py
    set dx [expr {$dx + $px}]
    set dy [expr {$dy + $py}]
    # Walk back over everything from the parent up to the mark: the parent's
    # own advance and every glyph in between, whether the lookup saw it or
    # not. The advances are the font's, because the font's are what the
    # content stream will place the glyphs by.
    for {set at $parent} {$at < $index} {incr at} {
      set dx [expr {$dx - [::tclpdf::sfnt advance $font [lindex $glyphs $at]]}]
    }
    lset result $index [list $dx $dy]
  }
  return $result
}

# The readable subtables of one lookup, in the order the lookup names them.
# A subtable of a format this file does not know is left out rather than
# refused: the ones beside it still position their marks.
proc ::tclpdf::markPos::Subtables {gpos typed} {
  set subtables {}
  foreach pair $typed {
    lassign $pair type offset
    set one [Subtable $gpos $type $offset]
    if {[llength $one]} {
      lappend subtables $one
    }
  }
  return $subtables
}

# --- one glyph against one lookup ------------------------------------------

# What this lookup does to the glyph at position AT of the visible list:
# {partner dx dy} in font units, or {} if no subtable of it applies.
#
# The subtables of a lookup are searched in order and the first that has an
# answer wins - including the case where the mark is covered but the partner's
# anchor for its class is NULL, which is not an answer and lets the next
# subtable try. That is the reading HarfBuzz settled on, and the alternative
# (mark covered, therefore done) silently drops marks in faces that split
# their classes over two subtables.
proc ::tclpdf::markPos::Attach {state subtables visible at glyphs} {
  set index [lindex $visible $at]
  set glyph [lindex $glyphs $index]
  foreach subtable $subtables {
    lassign $subtable type coverage records partnerCoverage anchors
    if {![dict exists $coverage $glyph]} {
      continue
    }
    lassign [lindex $records [dict get $coverage $glyph]] class markAnchor
    if {$markAnchor eq {}} {
      continue
    }
    set partner [Partner $state $type $visible $at $glyphs]
    if {$partner eq {}} {
      continue
    }
    set partnerGlyph [lindex $glyphs $partner]
    if {![dict exists $partnerCoverage $partnerGlyph]} {
      continue
    }
    set byClass [lindex $anchors [dict get $partnerCoverage $partnerGlyph]]
    if {$type == 5} {
      # Which component of the ligature carries the mark is not in the font -
      # see [LigatureArray]. The last one, and the comment there says why.
      set byClass [lindex $byClass end]
    }
    # Two ways a font can leave this row without the anchor the mark asks for,
    # and both used to be answered by [lindex] handing back the empty string
    # from beyond the end of a list - which reads like a NULL offset and is
    # not one:
    #
    #   the mark names a CLASS the subtable does not have. markClass is
    #   bounded by markClassCount (6.3.3), and a row holds exactly that many
    #   anchors, so a larger class is a mark this subtable cannot place;
    #
    #   the LigatureAttach has NO COMPONENTS at all - componentCount 0, so
    #   there is no row to take the last of (see [LigatureArray]).
    #
    # Either way the next subtable gets its turn, which is what a mark without
    # an anchor is entitled to here. Said in one line rather than left to an
    # index that happens to be out of range.
    if {$class >= [llength $byClass]} {
      continue
    }
    set partnerAnchor [lindex $byClass $class]
    if {$partnerAnchor eq {}} {
      continue
    }
    lassign $markAnchor mx my
    lassign $partnerAnchor bx by
    return [list $partner [expr {$bx - $mx}] [expr {$by - $my}]]
  }
  return {}
}

# The glyph this mark attaches to: an index into the run, or {} when there is
# none.
#
# For MarkToMark (type 6) the specification is explicit (S. 227): "the glyph
# preceding the mark1 glyph in glyph string order (skipping glyphs according
# to LookupFlags)". So: the previous visible glyph, and whether it is the
# right one is decided by mark2Coverage, not here.
#
# For MarkToBase and MarkToLigature it is the previous NON-MARK glyph, and the
# extra condition is not in the layout of the subtable - the specification
# says only "work backward from the mark to the preceding ligature glyph"
# (S. 225). It is measured, against HarfBuzz: in DejaVu Sans, "b" + U+0300 +
# U+0301 puts BOTH marks at -510,373, which can only happen if the acute
# looked past the grave and found the "b". Every mark lookup in that face sets
# lookupFlag 0, so taking the previous visible glyph would hand the acute a
# grave that no baseCoverage lists, and the second mark of every doubly
# accented word would fall back to the baseline.
#
# Without a GDEF class definition nothing is a mark and this degrades to the
# previous visible glyph, which is the best a font that classifies nothing
# allows.
proc ::tclpdf::markPos::Partner {state type visible at glyphs} {
  if {$type == 6} {
    return [lindex $visible [expr {$at - 1}]]
  }
  set marks [dict get $state marks]
  for {set back [expr {$at - 1}]} {$back >= 0} {incr back -1} {
    set index [lindex $visible $back]
    if {![::tclpdf::gdef ignored $marks [lindex $glyphs $index]]} {
      return $index
    }
  }
  return {}
}

# A filter that answers one question: is this glyph a mark?
#
# gdef.tcl has no command of that name and does not need one - a filter built
# from the ignoreMarks bit alone answers it exactly, through the same [ignored]
# every lookup flag goes through. Building a second reader of the GDEF class
# definition here would be the copy the house rule forbids.
proc ::tclpdf::markPos::Marks {gdef} {
  variable ignoreMarks
  return [::tclpdf::gdef filter $gdef $ignoreMarks]
}

# --- the subtables ---------------------------------------------------------

# One subtable, read whole: {type markCoverage markRecords partnerCoverage
# anchors}, or {} when it is of a format this does not know.
#
# The three types share their header to the byte. The specification says so of
# type 6 in as many words - "identical in form to the MarkToBase attachment
# subtable" (S. 227) - and type 5 differs only in what hangs off the last
# offset. One reader therefore serves all three, and the type travels along so
# the two consumers below know which shape they are looking at.
proc ::tclpdf::markPos::Subtable {gpos type offset} {
  # Every one of the three has exactly one format, numbered 1. A subtable
  # numbered otherwise is from a later specification than this reader.
  if {[::tclpdf::otLayout u16 $gpos $offset] != 1} {
    return {}
  }
  # THE FOUR OFFSETS ARE REQUIRED, and an offset of 0 in this header does not
  # mean "the table starts here" - it means the table is not there. Every
  # offset in these four fields is counted from the beginning of the subtable
  # (6.3.3), so 0 would point at the subtable's own format field: taken at
  # face value the reader found a coverage table of format 1 with 8 entries in
  # the header bytes, matched a glyph against them and produced an anchor out
  # of the offsets themselves. An invented anchor is worse than none, so a
  # subtable that leaves any of the four out is left alone whole - the same
  # answer an unknown format gets.
  set positions {}
  foreach field {2 4 8 10} {
    set at [::tclpdf::otLayout u16 $gpos [expr {$offset + $field}]]
    if {$at == 0} {
      return {}
    }
    lappend positions [expr {$offset + $at}]
  }
  lassign $positions markCoverage partnerCoverage markArray partnerArray
  set classCount [::tclpdf::otLayout u16 $gpos [expr {$offset + 6}]]
  if {$classCount == 0} {
    return {}
  }
  set records [MarkArray $gpos $markArray]
  if {![llength $records]} {
    return {}
  }
  if {$type == 5} {
    set anchors [LigatureArray $gpos $partnerArray $classCount]
  } else {
    set anchors [AnchorArray $gpos $partnerArray $classCount]
  }
  if {![llength $anchors]} {
    return {}
  }
  return [list $type [::tclpdf::otLayout coverage $gpos $markCoverage] \
      $records [::tclpdf::otLayout coverage $gpos $partnerCoverage] $anchors]
}

# The MarkArray (S. 241): one {class anchor} per mark, in mark coverage order.
#
# The class is an INDEX into the partner's anchor array, and class 0 is a real
# class. The specification is emphatic about it because the Class Definition
# table two pages earlier means the opposite by the same number: "A class
# value can be zero (0), but the MarkRecord must explicitly assign that class
# value."
proc ::tclpdf::markPos::MarkArray {gpos offset} {
  set count [::tclpdf::otLayout u16 $gpos $offset]
  set records {}
  for {set index 0} {$index < $count} {incr index} {
    set record [expr {$offset + 2 + $index * 4}]
    set class [::tclpdf::otLayout u16 $gpos $record]
    set at [::tclpdf::otLayout u16 $gpos [expr {$record + 2}]]
    set anchor {}
    if {$at != 0} {
      set anchor [::tclpdf::otLayout anchor $gpos [expr {$offset + $at}]]
    }
    lappend records [list $class $anchor]
  }
  return $records
}

# A BaseArray or a Mark2Array (S. 225 and S. 228): one list of classCount
# anchors per covered glyph, in coverage order, with {} for the NULL offsets
# the specification allows.
#
# The two are one table under two names. A Mark2Record and a BaseRecord are
# both "an array of offsets to Anchor tables, one per mark class, counted from
# the beginning of the enclosing array" - and writing that twice would be one
# reader too many for a difference that is only in the caption.
proc ::tclpdf::markPos::AnchorArray {gpos offset classCount} {
  set count [::tclpdf::otLayout u16 $gpos $offset]
  set anchors {}
  for {set index 0} {$index < $count} {incr index} {
    lappend anchors [AnchorRow $gpos $offset \
        [expr {$offset + 2 + $index * $classCount * 2}] $classCount]
  }
  return $anchors
}

# The LigatureArray (S. 226): one list of components per covered ligature,
# each component a list of classCount anchors.
proc ::tclpdf::markPos::LigatureArray {gpos offset classCount} {
  set count [::tclpdf::otLayout u16 $gpos $offset]
  set ligatures {}
  for {set index 0} {$index < $count} {incr index} {
    set at [::tclpdf::otLayout u16 $gpos [expr {$offset + 2 + $index * 2}]]
    if {$at == 0} {
      lappend ligatures {}
      continue
    }
    set attach [expr {$offset + $at}]
    set components [::tclpdf::otLayout u16 $gpos $attach]
    # componentCount 0 leaves the ligature with no row at all. Kept as the
    # empty list it is - [Attach] says in as many words what that means for a
    # mark that lands on such a ligature.
    set rows {}
    for {set component 0} {$component < $components} {incr component} {
      # The ComponentRecord offsets are counted from the LigatureAttach
      # table, NOT from the LigatureArray - the one place in these three
      # types where the base of an offset changes.
      lappend rows [AnchorRow $gpos $attach \
          [expr {$attach + 2 + $component * $classCount * 2}] $classCount]
    }
    lappend ligatures $rows
  }
  return $ligatures
}

# One row of anchor offsets, ordered by mark class: BASE is what they are
# counted from, RECORD is where they start.
proc ::tclpdf::markPos::AnchorRow {gpos base record classCount} {
  set row {}
  for {set class 0} {$class < $classCount} {incr class} {
    set at [::tclpdf::otLayout u16 $gpos [expr {$record + $class * 2}]]
    if {$at == 0} {
      lappend row {}
      continue
    }
    lappend row [::tclpdf::otLayout anchor $gpos [expr {$base + $at}]]
  }
  return $row
}

package provide tclpdf::markPos 1.1
