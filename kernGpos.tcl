#
# tclpdf - PDF generation for Tcl
#
# kernGpos - the GPOS lookups that change how far a glyph advances
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
# coverage - is the same one GSUB needs and lives in otLayout.tcl. Whether a
# contextual RULE matches at a position is the same question again and lives
# in gsubContext.tcl. What stays here is the part that is GPOS and only GPOS:
# the value record, and the four lookup types that put a number on it.
#
# THE LOOKUP TYPES THIS READS (ISO/IEC 14496-22:2019, 6.3, S. 218-239):
#
#   1 Single      one covered glyph gets one value record
#   2 Pair        two glyphs get one value record each
#   3 Cursive     a letter is hung on the exit point of the one before it
#   7 Contextual          a SEQUENCE matches and the adjustments are named
#   8 Chaining contextual   by lookup index rather than written out
#   9 Extension   a 32 bit offset in front of a lookup of any other type
#
# TYPES 7 AND 8 ARE GSUB'S TYPES 5 AND 6 TO THE BYTE. The specification prints
# the two pairs in two places (6.3.5/6.3.6 against 6.3.7/6.3.8) and the tables
# are the same under other captions: the same three formats, the same rule
# sets, the same SequenceLookupRecords - a PosLookupRecord IS a
# SequenceLookupRecord. So the number is translated where the subtable is read
# and gsubContext.tcl reads it, rather than a second reader of the same bytes
# being written here. What differs is only what a record MEANS, and that is
# this file's half.
#
# WHY THEY ARE READ AT ALL. Until 2026-08-26 only type 2 was, and the manual
# said "from its GPOS table where it has kerning lookups" without a limit.
# Measured against hb-shape over 78 Arabic, Persian and Urdu words: Noto Sans
# Arabic kerns 12 of them through a chaining lookup and this package set them
# 40 units per reh too wide, Scheherazade New 14 of them and 190 units per
# affected pair, Noto Kufi Arabic and Amiri one each. No validator sees it -
# the glyphs are right, they stand in the wrong places.
#
# WHAT A VALUE RECORD MAY SAY HERE is X placement and X advance. Y placement
# and Y advance are read by no caller: a horizontal line places its glyphs by
# the advances in the font dictionary and the marks by markPos.tcl, and a
# vertical one turns kerning off altogether (text.tcl, [TextMerge]). Device
# and VariationIndex tables behind a value are skipped for the reason given at
# otLayout::anchor - resolving one means resolving the item variation store,
# whose arithmetic exists once already.
#
# THE PAIRS ARE NOT EXPANDED into a flat table. A class based subtable pairs
# every glyph of one class with every glyph of another, so expanding it can
# turn a few hundred entries into millions. The subtables are kept as they are
# and asked per pair instead.
#
# What each lookup ignores is settled here rather than in kern.tcl: the flag
# comes out of the lookup header, the classes out of GDEF, and gdef.tcl turns
# the two into a filter. A lookup that filters nothing carries an empty one,
# which is the case this has to stay cheap for.
#
# CURSIVE ATTACHMENT IS READ IN TWO HALVES and this file has the horizontal
# one. A type 3 lookup says "the entry point of this letter sits on the exit
# point of the one before it", which is two statements at once: how far the
# first letter advances - this file - and how far off the baseline the second
# one sits - markPos.tcl, which answers in an {x y} offset per glyph. The
# array of anchors is read ONCE, by otLayout::entryExit, and the two halves
# take the coordinates they can use.
#
# What that is worth: Noto Nastaliq Urdu draws its words as a staircase and
# every letter of it came out on the baseline; Amiri pulls one letter 42 units
# into the one before it. Measured against hb-shape over 78 Arabic, Persian
# and Urdu words.
#
# Mark attachment (types 4 to 6) is markPos.tcl's alone: it moves a glyph off
# the pen without moving the pen, which cannot be said in the one number a gap
# between two glyphs holds.
#

package require Tcl 8.6.11-
package require tclpdf::sfnt 1.0-
package require tclpdf::otLayout 1.0-
package require tclpdf::gdef 1.0-
package require tclpdf::gsubContext 1.0-

namespace eval ::tclpdf::kernGpos {
  namespace export {[a-z]*}
  namespace ensemble create

  # The lookup types read, and the number an extension lookup carries in GPOS
  # - 9 here, where GSUB uses 7.
  variable kinds {1 single 2 pair 3 cursive 7 context 8 chain}
  variable extensionType 9

  # The features read here. "kern" is the one the precedence rule of 8.16 is
  # about and the only one [lookups] answers for; "curs" rides along because
  # its horizontal half is the same kind of answer - see the head of this
  # file.
  variable featureTags {kern curs}

  # The two numbers of the GSUB types that carry the same bytes as GPOS 7 and
  # 8, for gsubContext.tcl - see the head of this file.
  variable contextTypes {context 5 chain 6}

  # How far a contextual lookup may reach into another one, and how much work
  # one [run] may spend doing it. Both are HarfBuzz's and both are explained
  # at gsubApply.tcl, which is bounded by the same two numbers for the same
  # reason: a lookup may name itself, directly or round a cycle.
  variable maxDepth 64
  variable opsFactor 64
  variable opsFloor 16384
  variable ops 0
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
  if {[::tclpdf::otLayout damaged {
      set indices [::tclpdf::otLayout featureLookupsAnyScript $gpos kern]}]} {
    # A damaged GPOS table is not a reason to refuse the document: the text is
    # then set without kerning, which is what a font without GPOS would give.
    return {}
  }
  return $indices
}

# All positioning lookups of the kern and curs features, prepared for
# evaluation by [run]: {lookups nested marks font}, where lookups is a list of
# {filter subtables} in lookup order, nested a dict of the same keyed by
# lookup index holding every lookup a contextual rule can reach, marks the
# filter that answers "is this glyph a mark", and font the face.
proc ::tclpdf::kernGpos::prepare {font} {
  set gpos [::tclpdf::sfnt table $font GPOS]
  if {$gpos eq {}} {
    return {}
  }
  return [table $gpos [::tclpdf::gdef build $font] $font]
}

# The same from the TABLE rather than from the face, which is what a test
# assembling a GPOS out of bytes has - and what keeps such a test out of the
# reading path it is not about. FONT is what cursive attachment asks for the
# plain advance of a glyph; everything else works without it.
proc ::tclpdf::kernGpos::table {gpos gdef {font {}}} {
  variable featureTags
  set indices {}
  if {[::tclpdf::otLayout damaged {
      set indices [::tclpdf::otLayout featureLookupsAnyScript $gpos \
          $featureTags]}]} {
    return {}
  }
  set references {}
  set prepared [Collect $gpos $gdef $indices references]
  if {![llength $prepared]} {
    return {}
  }
  # THE MARKS travel with the prepared lookups because [Place] needs them in a
  # right-to-left line: text.tcl draws a base and the marks hanging on it in
  # LOGICAL order inside one cluster and turns only the clusters round
  # ([TextCluster]), so the gap that lands in front of a base glyph on the
  # page is the one behind the LAST mark of its cluster. See [Clusters].
  return [list $prepared [Nested $gpos $gdef $references] \
      [::tclpdf::gdef marks $gdef] $font]
}

# --- the GPOS side ---------------------------------------------------------

# One entry {filter subtables} per LOOKUP, in lookup order, and the lookup
# indices the contextual rules among them name.
#
# PER LOOKUP AND NOT PER SUBTABLE: the specification applies a lookup to one
# position by trying its subtables in order and stopping at the first that
# applies (S. 217), which is not the same thing as walking the run once per
# subtable.
#
# One lookup at a time, and a damaged one costs only itself - the error
# boundary sits inside the loop, not around the walk.
#
# TYPES 4 TO 6 ARE LEFT OUT HERE and that is a division of labour rather than
# a hole: mark attachment answers in an {x y} offset per glyph and is
# markPos.tcl's. What is left for this file is the adjustments that can be
# said in the ONE number a gap between two glyphs holds - which includes the
# horizontal half of cursive attachment, see the head of this file.
proc ::tclpdf::kernGpos::Collect {gpos gdef indices referencesName} {
  variable kinds
  variable extensionType
  upvar 1 $referencesName references
  set types {}
  foreach {type kind} $kinds {
    lappend types $type
  }
  set prepared {}
  foreach entry [::tclpdf::otLayout collectTyped $gpos $indices $types \
      $extensionType] {
    lassign $entry flag markSet typed
    set subtables {}
    foreach pair $typed {
      lassign $pair type offset
      set kind [dict get $kinds $type]
      set one {}
      if {[::tclpdf::otLayout damaged {
          set one [Subtable $gpos $kind $offset]}]} {
        continue
      }
      if {![llength $one]} {
        continue
      }
      if {[lindex $one 0] in {context chain}} {
        lappend references {*}[::tclpdf::gsubContext references [lindex $one 1]]
      }
      lappend subtables $one
    }
    if {[llength $subtables]} {
      lappend prepared [list [::tclpdf::gdef filter $gdef $flag $markSet] \
          $subtables]
    }
  }
  return $prepared
}

# Every lookup the contextual rules can reach, prepared and keyed by its index
# in the lookup list.
#
# A worklist rather than a recursion, and for the reason gsubApply.tcl gives
# in the same place: a lookup may name itself, and a font that does so would
# take a recursive reader down with it. Here the second sight of an index is a
# dict that already has the key, and the walk simply stops.
proc ::tclpdf::kernGpos::Nested {gpos gdef seeds} {
  set nested {}
  set work $seeds
  while {[llength $work]} {
    set index [lindex $work 0]
    set work [lrange $work 1 end]
    if {[dict exists $nested $index]} {
      continue
    }
    set more {}
    # One index, so one lookup or none - and the empty answer is stored too,
    # or a lookup that does not read would be looked for again and again.
    dict set nested $index [lindex [Collect $gpos $gdef [list $index] more] 0]
    lappend work {*}$more
  }
  return $nested
}

# One subtable, read whole: {kind data}, or {} when it says nothing this file
# can use.
proc ::tclpdf::kernGpos::Subtable {gpos kind offset} {
  variable contextTypes
  switch -- $kind {
    single {
      return [SinglePos $gpos $offset]
    }
    pair {
      return [PairPos $gpos $offset]
    }
    cursive {
      set records [::tclpdf::otLayout entryExit $gpos $offset]
      if {![dict size $records]} {
        return {}
      }
      return [list cursive $records]
    }
    context - chain {
      set rules [::tclpdf::gsubContext read $gpos \
          [dict get $contextTypes $kind] $offset]
      if {![dict size $rules]} {
        return {}
      }
      return [list $kind $rules]
    }
  }
  return {}
}

# --- the value record ------------------------------------------------------

# How many bytes one value record occupies. Every set bit means two bytes,
# whether it is a value or a device offset.
proc ::tclpdf::kernGpos::ValueSize {format} {
  set size 0
  for {set bit 0} {$bit < 8} {incr bit} {
    if {$format & (1 << $bit)} {
      incr size 2
    }
  }
  return $size
}

# Where the field marked by BIT sits inside a value record of this format, or
# -1 when the format does not carry it. The fields stand in bit order, two
# bytes each, and only the ones the format names are there at all - which is
# what makes the offset depend on every LOWER bit.
proc ::tclpdf::kernGpos::FieldAt {format bit} {
  if {!($format & $bit)} {
    return -1
  }
  set at 0
  for {set lower 1} {$lower < $bit} {set lower [expr {$lower << 1}]} {
    if {$format & $lower} {
      incr at 2
    }
  }
  return $at
}

# The X placement and the X advance of one value record, as {dx da} in font
# units. Both are 0 for a record that names neither.
#
# X PLACEMENT MOVES THE GLYPH, X ADVANCE MOVES THE ONES AFTER IT, and a face
# regularly sets both to the same number - which is what "kern this letter and
# everything behind it to the left" looks like when it is written as a single
# adjustment rather than as a pair.
proc ::tclpdf::kernGpos::Value {bytes offset format} {
  set values {}
  foreach bit {0x0001 0x0004} {
    set at [FieldAt $format $bit]
    if {$at < 0} {
      lappend values 0
    } else {
      lappend values [::tclpdf::otLayout s16 $bytes [expr {$offset + $at}]]
    }
  }
  return $values
}

# Does a value format carry anything this file reads?
proc ::tclpdf::kernGpos::Horizontal {format} {
  return [expr {($format & 0x0005) != 0}]
}

# --- lookup type 1, single adjustment (S. 218-220) -------------------------
#
# One value record for every glyph of the coverage (format 1) or one per
# coverage index (format 2). This is how a face says "this letter sits 190
# units further left and takes 190 units less room", which no pair can say.
proc ::tclpdf::kernGpos::SinglePos {gpos subtable} {
  set format [::tclpdf::otLayout u16 $gpos $subtable]
  set coverage [expr {$subtable + [::tclpdf::otLayout u16 $gpos \
      [expr {$subtable + 2}]]}]
  set valueFormat [::tclpdf::otLayout u16 $gpos [expr {$subtable + 4}]]
  if {![Horizontal $valueFormat]} {
    return {}
  }
  set glyphs [::tclpdf::otLayout coverage $gpos $coverage]
  set values {}
  switch -- $format {
    1 {
      set value [Value $gpos [expr {$subtable + 6}] $valueFormat]
      if {$value eq {0 0}} {
        return {}
      }
      dict for {glyph index} $glyphs {
        dict set values $glyph $value
      }
    }
    2 {
      set count [::tclpdf::otLayout u16 $gpos [expr {$subtable + 6}]]
      set size [ValueSize $valueFormat]
      dict for {glyph index} $glyphs {
        if {$index >= $count} {
          continue
        }
        set value [Value $gpos [expr {$subtable + 8 + $index * $size}] \
            $valueFormat]
        if {$value eq {0 0}} {
          continue
        }
        dict set values $glyph $value
      }
    }
  }
  if {![dict size $values]} {
    return {}
  }
  return [list single $values]
}

# --- lookup type 2, pair adjustment (S. 220-224) ---------------------------

proc ::tclpdf::kernGpos::PairPos {gpos subtable} {
  set format [::tclpdf::otLayout u16 $gpos $subtable]
  set coverage [expr {$subtable + [::tclpdf::otLayout u16 $gpos \
      [expr {$subtable + 2}]]}]
  set format1 [::tclpdf::otLayout u16 $gpos [expr {$subtable + 4}]]
  set format2 [::tclpdf::otLayout u16 $gpos [expr {$subtable + 6}]]
  # A subtable that adjusts nothing horizontally is of no use here, and
  # skipping it early saves walking a class matrix for nothing.
  if {![Horizontal $format1] && ![Horizontal $format2]} {
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
          set adjust [Pairing $gpos [expr {$record + 2}] $format1 $format2 \
              $size1]
          if {$adjust ne {}} {
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
          set adjust [Pairing $gpos [expr {$row + $two * $stride}] $format1 \
              $format2 $size1]
          if {$adjust ne {}} {
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

# The two value records of one pair, as {dx1 da1 dx2 da2}, or {} when both are
# all zeroes - which is the common case in a class matrix and the reason this
# answers {} rather than four zeroes.
proc ::tclpdf::kernGpos::Pairing {gpos offset format1 format2 size1} {
  set one [Value $gpos $offset $format1]
  set two [Value $gpos [expr {$offset + $size1}] $format2]
  if {$one eq {0 0} && $two eq {0 0}} {
    return {}
  }
  return [list {*}$one {*}$two]
}

# --- applying --------------------------------------------------------------

# The adjustments of a glyph run, in font units: one per GAP between two
# neighbouring glyphs, so the result is one shorter than the run and every
# caller can index it by gap.
#
# PREPARED is what [prepare] answered, or the same shape assembled by kern.tcl
# out of the old "kern" table - which is why there is one evaluator here and
# not one per source.
#
# Lookups are applied one after another and their adjustments add up (S. 217);
# within one lookup the first subtable that applies at a position ends the
# lookup for that position, which is how the specification has subtables
# searched.
#
# Why a run and not a pair: a lookup that sets an ignore bit sees the run
# WITHOUT the glyphs it filters out, so in "A acute V" the pair to look up is
# A V. That question cannot be asked two glyphs at a time.
#
# DIRECTION is the direction the line will be DRAWN in, and it is not a
# refinement - it decides which of the two gaps beside a glyph an adjustment
# belongs in. See [Place].
proc ::tclpdf::kernGpos::run {prepared glyphs {direction ltr}} {
  variable opsFactor
  variable opsFloor
  variable ops
  set gaps [expr {[llength $glyphs] - 1}]
  if {$gaps < 1 || ![llength $prepared]} {
    return [lrepeat [expr {$gaps > 0 ? $gaps + 1 : 0}] 0]
  }
  lassign $prepared lookups nested marks font
  # ONE SLOT PER GLYPH, not one per gap - the last one is the amount that
  # falls off the end. See [Place].
  set result [lrepeat [expr {$gaps + 1}] 0]
  set ops [expr {$opsFactor * [llength $glyphs] + $opsFloor}]
  set clusters {}
  if {$direction eq "rtl"} {
    # The end of every cluster, once for the whole run rather than once per
    # position: which gap moves a glyph depends on it - see [Place].
    set clusters [Clusters $marks $glyphs]
  }
  # Everything the walk needs and none of it per position: the map of nested
  # lookups, the cluster ends (empty for a forward line), and the face, which
  # only cursive attachment asks - it needs the plain advance of a glyph to
  # say by how much the lookup CHANGED it.
  set context [list $nested $clusters $font \
      [expr {$direction eq "rtl"}]]
  foreach lookup $lookups {
    lassign $lookup filter subtables
    set visible [Keep $filter $glyphs]
    set seen [llength $visible]
    for {set at 0} {$at < $seen} {incr at} {
      Lookup $filter $subtables $context $glyphs $visible $at result 0
    }
  }
  return $result
}

# The last position of each glyph's cluster: a base and the marks that follow
# it belong together, and a glyph that is itself a mark answers its own
# position.
#
# {} for a left-to-right line, which is what [Place] tests: there the clusters
# make no difference at all, because the drawn order IS the logical one.
proc ::tclpdf::kernGpos::Clusters {marks glyphs} {
  set count [llength $glyphs]
  set ends [lrepeat $count 0]
  set end [expr {$count - 1}]
  for {set index $end} {$index >= 0} {incr index -1} {
    if {$marks ne {} && $index < $end && [::tclpdf::gdef ignored $marks \
        [lindex $glyphs [expr {$index + 1}]]]} {
      lset ends $index [lindex $ends [expr {$index + 1}]]
    } else {
      lset ends $index $index
    }
  }
  return $ends
}

# The indices of a glyph list one lookup can see, in order. EXEMPT is one
# position the filter may not hide, or -1 for none - what a PosLookupRecord
# needs, and gdef.tcl says in one place what that means and why.
proc ::tclpdf::kernGpos::Keep {filter glyphs {exempt -1}} {
  return [::tclpdf::gdef visible $filter $glyphs $exempt]
}

# One lookup at one position of the visible list: the first subtable that
# applies ends it.
proc ::tclpdf::kernGpos::Lookup {filter subtables context glyphs visible at \
    resultName depth} {
  upvar 1 $resultName result
  foreach subtable $subtables {
    lassign $subtable kind data
    if {[Subst $kind $filter $data $context $glyphs $visible $at result \
        $depth]} {
      return 1
    }
  }
  return 0
}

# What one subtable does at one position: 1 when it applied, 0 when it has
# nothing to say here.
proc ::tclpdf::kernGpos::Subst {kind filter data context glyphs visible at \
    resultName depth} {
  upvar 1 $resultName result
  switch -- $kind {
    single {
      set glyph [lindex $glyphs [lindex $visible $at]]
      if {![dict exists $data $glyph]} {
        return 0
      }
      lassign [dict get $data $glyph] dx da
      Place result $context [lindex $visible $at] \
          [lindex $visible [expr {$at + 1}]] \
          [expr {$at > 0 ? [lindex $visible [expr {$at - 1}]] : {}}] $dx $da
      return 1
    }
    pairs - classes {
      return [PairAt $kind $data $context $glyphs $visible $at result]
    }
    cursive {
      return [CursiveAt $data $context $glyphs $visible $at result]
    }
    context - chain {
      return [ContextAt $filter $data $context $glyphs $visible $at result \
          $depth]
    }
  }
  return 0
}

# WHERE AN ADJUSTMENT LANDS in the list.
#
#   dx  X placement - moves THIS glyph and nothing else
#   da  X advance   - moves everything drawn after this glyph
#
# THE ADVANCE GOES IN THE SAME SLOT IN BOTH DIRECTIONS: slot g sits between
# the LOGICAL neighbours g and g+1, and the amount of a pair stays between the
# same two glyphs however the line runs - which is what text.tcl says of the
# reordering it does ([TextReorder]) and what keeps [FontRunWidth], which
# measures without a direction, measuring the line that is drawn. The slot
# that would be exactly HarfBuzz is the one on the OTHER side in a
# right-to-left line, because there the pen walks the other way; the
# difference is one glyph - the adjusted one - and the price of taking it is
# that the first pair of the line has nowhere to go and the line comes out one
# pair wider than it was measured. Decided for the stable width; what it costs
# is one word of the 78 measured, by one unit, and it is named in the head of
# kern.tcl.
#
# THE PLACEMENT DOES DEPEND ON THE DIRECTION, and that is the one thing about
# this file a reader coming from the specification does not expect: slot g
# moves the glyphs g+1 to the end in a left-to-right line and the glyphs g
# down to 0 in a right-to-left one, so the slot that moves ONE glyph and
# nothing else is the one in front of it forwards and the one behind it back.
# Measured against hb-shape on Noto Sans Arabic: with the forward slot the reh
# of "marhaba" came out 40 units too far right, and every other glyph of the
# word and the width of the line exactly right.
#
# AND ON THE CLUSTER, in a right-to-left line only. text.tcl draws a base and
# the marks hanging on it in LOGICAL order inside one cluster and turns only
# the clusters round ([TextCluster]), so the slot that lands in front of a
# base glyph on the page is the one behind the last MARK of its cluster.
# Without that the same 40 units came back for every vowelled word - measured
# on the harakat words of the same list.
#
# NEXT is the next position THIS LOOKUP can see, and it is not simply the
# neighbour in the run: in "A acute V" a lookup that ignores marks kerns A
# against V, and the amount belongs in the slot beside the V, because taking
# it off the A's advance would drag the accent along with it. For neighbouring
# glyphs - every pair in a face that filters nothing - the two are the same
# slot.
#
# THERE IS ONE SLOT PER GLYPH and the last one is the amount that falls off
# the end: the advance of the last glyph has no glyph behind it to move, and
# it is kept rather than dropped because it is still part of the width. In a
# right-to-left line text.tcl writes that one in front of the first glyph
# drawn ([TextReorder], the "lead"), which is the same width and the same
# line. A PLACEMENT at the first position is the one thing still dropped: it
# would shift the whole line sideways, and no face in reach writes one.
#
# WHAT IS NOT DROPPED WITH IT IS THE ADVANCE, and that distinction had to be
# made rather than assumed. The rest of the line owes the DIFFERENCE between
# the advance and the placement, because the placement has already moved this
# glyph; where the placement was not applied it has moved nothing, and the
# difference is then the whole advance. A single adjustment usually writes the
# same number twice - "pos x <-50 0 -50 0>", which narrows the glyph by moving
# it and its successors alike - so at position 0 the difference came to zero
# and the glyph kept its full width: measured against hb-shape on a face built
# for it, 600 units where HarfBuzz says 550.
#
# PREVIOUS is unused since 2026-08-26 and stays in the signature because the
# alternative reading above needs it and is one line away - see kern.tcl.
proc ::tclpdf::kernGpos::Place {resultName context position next previous \
    dx da} {
  upvar 1 $resultName result
  set clusters [lindex $context 1]
  set slots [llength $result]
  if {[llength $clusters]} {
    set own [lindex $clusters $position]
  } else {
    set own [expr {$position - 1}]
  }
  set rest [expr {($next eq {} ? $position + 1 : $next) - 1}]
  set placed 0
  if {$dx != 0 && $own >= 0 && $own < $slots} {
    lset result $own [expr {[lindex $result $own] + $dx}]
    set placed $dx
  }
  # The advance moves everything drawn after this glyph; the placement has
  # already moved this glyph, so what the rest still owe is the difference -
  # and the difference from what was actually placed, which is nothing at the
  # first position. See the head of this proc.
  set amount [expr {$da - $placed}]
  if {$amount != 0 && $rest >= 0 && $rest < $slots} {
    lset result $rest [expr {[lindex $result $rest] + $amount}]
  }
}

# A pair subtable at one position: this glyph is the LEFT of the pair and the
# next visible one the right.
proc ::tclpdf::kernGpos::PairAt {kind data context glyphs visible at \
    resultName} {
  upvar 1 $resultName result
  set next [lindex $visible [expr {$at + 1}]]
  if {$next eq {}} {
    return 0
  }
  set position [lindex $visible $at]
  set left [lindex $glyphs $position]
  set right [lindex $glyphs $next]
  set adjust {}
  switch -- $kind {
    pairs {
      if {![dict exists $data $left,$right]} {
        return 0
      }
      set adjust [dict get $data $left,$right]
    }
    classes {
      lassign $data coverage first second matrix
      if {![dict exists $coverage $left]} {
        return 0
      }
      # Class 0 is not a hole: it is "everything the class definition does not
      # name", and the matrix has a row and a column for it.
      set one 0
      set two 0
      if {[dict exists $first $left]} {
        set one [dict get $first $left]
      }
      if {[dict exists $second $right]} {
        set two [dict get $second $right]
      }
      # Coverage decides, not the matrix cell: a zero cell is a decision of the
      # font, and the next subtable must not overrule it.
      if {![dict exists $matrix $one,$two]} {
        return 1
      }
      set adjust [dict get $matrix $one,$two]
    }
  }
  lassign $adjust dx1 da1 dx2 da2
  Place result $context $position $next \
      [expr {$at > 0 ? [lindex $visible [expr {$at - 1}]] : {}}] $dx1 $da1
  Place result $context $next [lindex $visible [expr {$at + 2}]] $position \
      $dx2 $da2
  return 1
}

# Cursive attachment (lookup type 3, S. 224-225), horizontal half.
#
# THE RULE, and it is HarfBuzz's [PositionCursive] to the line: the glyph at
# this position needs an ENTRY anchor and the one before it an EXIT anchor,
# and the two are then made to coincide. Which of the two pays for it depends
# on the direction the line runs in, because the pen walks the other way:
#
#   left to right   the first letter's advance is SET to its exit point, and
#                   the second is pulled back to its entry point - which
#                   moves the second glyph and everything after it;
#   right to left   the first letter loses its exit point from BOTH its
#                   advance and its placement, and the second letter's
#                   advance is SET to its entry point.
#
# "SET", not "adjusted": the specification says the anchors coincide, so what
# the lookup asks for is the difference between the anchor and the advance the
# face ships. That is the one thing in this file that needs the face itself.
#
# THE VERTICAL HALF IS NOT HERE - see the head of this file. A cursive lookup
# also lifts one of the two letters onto the other's anchor height, and that
# is an offset per glyph rather than a gap between two.
proc ::tclpdf::kernGpos::CursiveAt {data context glyphs visible at resultName} {
  upvar 1 $resultName result
  if {$at < 1} {
    return 0
  }
  set position [lindex $visible $at]
  set before [lindex $visible [expr {$at - 1}]]
  set glyph [lindex $glyphs $position]
  set previous [lindex $glyphs $before]
  if {![dict exists $data $glyph] || ![dict exists $data $previous]} {
    return 0
  }
  set entry [lindex [dict get $data $glyph] 0]
  set exit [lindex [dict get $data $previous] 1]
  if {$entry eq {} || $exit eq {}} {
    return 0
  }
  set font [lindex $context 2]
  set entryX [lindex $entry 0]
  set exitX [lindex $exit 0]
  if {[lindex $context 3]} {
    Place result $context $before $position \
        [expr {$at > 1 ? [lindex $visible [expr {$at - 2}]] : {}}] \
        [expr {-$exitX}] [expr {-$exitX}]
    Place result $context $position [lindex $visible [expr {$at + 1}]] \
        $before 0 [expr {$entryX - [Advance $font $glyph]}]
  } else {
    Place result $context $before $position \
        [expr {$at > 1 ? [lindex $visible [expr {$at - 2}]] : {}}] \
        0 [expr {$exitX - [Advance $font $previous]}]
    Place result $context $position [lindex $visible [expr {$at + 1}]] \
        $before [expr {-$entryX}] [expr {-$entryX}]
  }
  return 1
}

# The advance the face ships for one glyph, or 0 for a run that arrived
# without a face - which is what the old "kern" table hands in, and which
# carries no cursive lookup to ask.
proc ::tclpdf::kernGpos::Advance {font glyph} {
  if {$font eq {}} {
    return 0
  }
  return [::tclpdf::sfnt advance $font $glyph]
}

# A contextual or chaining contextual subtable at one position: does a rule
# match, and what do its records adjust.
#
# THE POSITIONS DO NOT MOVE HERE, which is the one thing that makes this
# simpler than its GSUB counterpart: a positioning lookup never makes the run
# longer or shorter, so the run index a record names is the one it named
# before the record before it ran.
proc ::tclpdf::kernGpos::ContextAt {filter rules context glyphs visible at \
    resultName depth} {
  upvar 1 $resultName result
  set found [::tclpdf::gsubContext match $rules $glyphs $visible $at]
  if {$found eq {}} {
    return 0
  }
  lassign $found positions records
  foreach record $records {
    lassign $record sequence index
    if {$sequence >= [llength $positions]} {
      continue
    }
    LookupAt $context $index $glyphs [lindex $positions $sequence] result $depth
  }
  return 1
}

# One lookup of the lookup list, applied at one position - what a
# PosLookupRecord asks for.
proc ::tclpdf::kernGpos::LookupAt {context index glyphs position resultName \
    depth} {
  variable maxDepth
  variable ops
  upvar 1 $resultName result
  # THE TWO BOUNDS, in HarfBuzz's order and with its short circuit - see
  # gsubApply.tcl, where the same cycle is bounded by the same two numbers.
  set nested [lindex $context 0]
  if {$depth >= $maxDepth || $ops <= 0 || ![dict exists $nested $index]} {
    return
  }
  incr ops -1
  set lookup [dict get $nested $index]
  if {![llength $lookup]} {
    return
  }
  lassign $lookup filter subtables
  # THE GLYPH AT THIS POSITION IS EXEMPT from the named lookup's own flag -
  # see [Keep].
  set visible [Keep $filter $glyphs $position]
  set at [lsearch -exact -integer -sorted $visible $position]
  if {$at < 0} {
    return
  }
  Lookup $filter $subtables $context $glyphs $visible $at result \
      [expr {$depth + 1}]
}

package provide tclpdf::kernGpos 1.4
