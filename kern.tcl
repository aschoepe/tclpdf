#
# tclpdf - PDF generation for Tcl
#
# kern - pair kerning: which source a font kerns from, and by how much
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# The one place that decides between the two sources a font can carry. The
# GPOS side - reading the lookups and applying them to a run - lives in
# kernGpos.tcl and is reached from here only. What stays here is the DECISION
# and the old table.
#
# THE OLD TABLE IS HANDED ON IN THE SHAPE OF A GPOS LOOKUP, which is what
# keeps one evaluator for both sources: its pairs have exactly the layout a
# PairPos format 1 subtable produces - one lookup, no filter, one subtable -
# so kernGpos.tcl evaluates them with the same walk. Two copies of that walk
# would drift, and the second one would be the one nobody measured.
#
# Kerning is producer arithmetic. The amounts end up as numbers in a TJ array
# in the content stream, and no reader ever consults the "kern" table or GPOS
# of an embedded font: with Identity-H the PDF addresses glyphs directly and
# places them by the widths in the font dictionary. Neither table is therefore
# copied into the subset - they are read from the source file while writing.
#
# ISO/IEC 14496-22:2019, 8.16 does not offer a choice between the two, it
# prescribes an order:
#
#   - kern feature lookups in the resolved language system of GPOS present
#     -> apply GPOS, "and the kern table data ignored"
#   - none present -> apply the kern table
#   - no GPOS at all -> apply the kern table, whatever the language system
#
# Measured over 873 fonts of one machine, neither path alone is enough: 288
# fonts kern from GPOS without carrying a kern table, 108 the other way round,
# and 135 carry both - among them Arial and the other old Microsoft core
# fonts, where the rule above says the kern table has to be left alone.
#
# THE ONE PLACE THIS PACKAGE KNOWINGLY DIFFERS FROM HarfBuzz, and it is worth
# a paragraph because the difference is a decision and not an oversight. A
# ValueRecord changes the ADVANCE of a glyph, and an advance moves whatever is
# drawn after it - in a right-to-left line that is the logically EARLIER
# glyph, so HarfBuzz's amount belongs in the gap on the other side of the pair
# from where this package puts it (hb-ot-layout-gsubgpos.hh,
# PairPosFormat1::apply, which puts value1 on buffer->cur_pos()).
#
# This package keeps the amount between the SAME two glyphs in both
# directions, and the reason is the width: [FontRunWidth] measures a line
# without knowing which way it will be drawn, and a line whose total depends
# on the direction is a line that frays at the margin when it is justified.
# With HarfBuzz's gap the first pair of a right-to-left line has no gap left
# to go into at all and falls out of the line, which is 42 thousandths of the
# em on "AVATAR" in DejaVu Sans - measured, and visible.
#
# WHAT IT COSTS is one word of the 78 Arabic, Persian and Urdu words this was
# measured against, in one of the five faces, by one unit: Amiri joins two
# letters of "kalima" cursively and sets the second letter's advance to its
# entry point, and with the gap on this side that letter itself moves with it.
# Noto Sans Arabic, Scheherazade New, Noto Kufi Arabic and Amiri otherwise
# match hb-shape glyph for glyph and unit for unit. Turning it round is one
# line in [kernGpos Place]; the trade is named there too.
#

package require Tcl 8.6.11-
package require tclpdf::sfnt 1.0-
package require tclpdf::kernGpos 1.0-
package require tclpdf::gdef 1.0-

namespace eval ::tclpdf::kern {
  namespace export {[a-z]*}
  namespace ensemble create
}

# Prepare a font for kerning. The result is handed back to [run] and is
# worth keeping: it walks the whole table once, which a per-pair lookup must
# not do.
proc ::tclpdf::kern::build {font} {
  set prepared [::tclpdf::kernGpos prepare $font]
  if {[llength [::tclpdf::kernGpos lookups $font]]} {
    if {[llength $prepared]} {
      return [list gpos $prepared]
    }
    # Lookups that yielded nothing readable. The specification still says the
    # kern table is out of play in this font, and inventing a fallback here
    # would kern one font differently from every other tool.
    return [list none {}]
  }
  # NO KERN FEATURE, so the old table decides the kerning - and whatever the
  # GPOS side prepared BESIDES it stays: the precedence rule of 8.16 is about
  # the "kern" feature and nothing else, so a face that joins its letters
  # cursively and kerns from the old table does both. The old lookup goes
  # FIRST, where the kern feature's would have stood in the lookup list.
  set lookups {}
  set pairs [KernTable $font]
  if {[dict size $pairs]} {
    # The old table has neither lookups nor flags, and its pairs carry one
    # number each where a GPOS pair carries two value records - so the amount
    # goes in as the X ADVANCE of the first glyph and the other three fields
    # are zero, which is what a PairPos subtable of that shape would say.
    # Saying it here is what lets both sources be evaluated by the same walk
    # instead of by two copies of it that drift apart.
    set records {}
    dict for {pair adjust} $pairs {
      dict set records $pair [list 0 $adjust 0 0]
    }
    lappend lookups [list {} [list [list pairs $records]]]
  }
  if {![llength $prepared]} {
    if {![llength $lookups]} {
      return [list none {}]
    }
    # Nothing from GPOS at all, so no map of nested lookups, no mark filter
    # and no face: the old table names no lookups and has no anchors.
    return [list kern [list $lookups {} {} {}]]
  }
  lassign $prepared gposLookups nested marks parsed
  return [list [expr {[llength $lookups] ? "kern" : "gpos"}] \
      [list [concat $lookups $gposLookups] $nested $marks $parsed]]
}

# Which source the pairs come from: gpos, kern or none. Diagnostic - the
# drawing path does not need it, but a test that claims the precedence rule
# holds has to be able to see it.
#
# Not called "source": a procedure of that name in this namespace would hide
# the Tcl command of the same name from every later line in this file.
proc ::tclpdf::kern::origin {state} {
  return [lindex $state 0]
}

# The adjustments of a glyph run, in font units: ONE PER GLYPH, so the result
# is exactly as long as the run and every caller can index it by glyph without
# a special case.
#
# The last entry is the amount that falls off the end - the advance of the
# last glyph has no glyph behind it to move - and it is kept rather than
# dropped because it is still part of the width of the line. It was one
# shorter than the run until 2026-08-26, and what that cost showed only in a
# right-to-left line: the first pair of the line had nowhere to go, so the
# line came out one pair wider than [textWidth] measured it.
#
# The walk itself is kernGpos.tcl's, whichever source the pairs came from -
# see the head of this file for why the old table arrives wearing the shape of
# a GPOS lookup.
# DIRECTION is the direction the line will be DRAWN in, and it decides which
# of the two gaps beside a glyph an adjustment belongs in - see
# [kernGpos Place]. It defaults to the left-to-right answer, which is what
# every caller that does not know gets today.
proc ::tclpdf::kern::run {state glyphs {direction ltr}} {
  set gaps [expr {[llength $glyphs] - 1}]
  if {$gaps < 1} {
    return {}
  }
  lassign $state kind prepared
  if {$kind eq "none"} {
    return [lrepeat [expr {$gaps + 1}] 0]
  }
  return [::tclpdf::kernGpos run $prepared $glyphs $direction]
}

# The adjustment for one glyph pair, in font units. Negative moves the two
# closer together, which is what most pairs do.
#
# For the caller that has two glyphs and no run - a test asking what a face
# does with "To". It is [run] over a run of two, so the two cannot answer
# differently.
proc ::tclpdf::kern::value {state left right {direction ltr}} {
  return [lindex [run $state [list $left $right] $direction] 0]
}

# --- the old table ---------------------------------------------------------

# Format 0 of the "kern" table: a sorted list of pairs.
#
# Only the first horizontal format 0 subtable is read, which is what the
# specification says Windows does - it supports "nor multiple tables (only the
# first format 0 table found will be used) nor coverage bits 0 through 4".
# Following the more capable reading would kern differently from the platform
# the font was made for.
#
# Apple writes its own version of this table, recognisable by a 32 bit version
# number, with a different header and different flags. It is skipped rather
# than guessed at: a misread offset would produce plausible numbers.
proc ::tclpdf::kern::KernTable {font} {
  set bytes [::tclpdf::sfnt table $font kern]
  if {[string length $bytes] < 4} {
    return {}
  }
  binary scan $bytes SuSu version count
  if {$version != 0} {
    return {}
  }
  set offset 4
  for {set index 0} {$index < $count} {incr index} {
    if {$offset + 6 > [string length $bytes]} {
      break
    }
    binary scan $bytes @${offset}SuSuSu subVersion length coverage
    if {$length < 6} {
      break
    }
    # Low byte is the format, bit 0 of the high byte marks horizontal data.
    set format [expr {($coverage >> 8) & 0xFF}]
    set horizontal [expr {$coverage & 0x0001}]
    if {$format == 0 && $horizontal} {
      return [KernFormat0 $bytes [expr {$offset + 6}] \
          [expr {$offset + $length}]]
    }
    incr offset $length
  }
  return {}
}

proc ::tclpdf::kern::KernFormat0 {bytes offset limit} {
  if {$offset + 8 > [string length $bytes]} {
    return {}
  }
  binary scan $bytes @${offset}Su pairs
  set at [expr {$offset + 8}]
  set result {}
  for {set index 0} {$index < $pairs} {incr index} {
    if {$at + 6 > $limit || $at + 6 > [string length $bytes]} {
      break
    }
    binary scan $bytes @${at}SuSuS left right adjust
    if {$adjust != 0} {
      dict set result $left,$right $adjust
    }
    incr at 6
  }
  return $result
}

package provide tclpdf::kern 1.1
