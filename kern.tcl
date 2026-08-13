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
# GPOS side lives in kernGpos.tcl and is reached from here only.
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

package require Tcl 8.6.11-
package require tclpdf::sfnt 1.0-
package require tclpdf::kernGpos 1.0-

namespace eval ::tclpdf::kern {
  namespace export {[a-z]*}
  namespace ensemble create
}

# Prepare a font for kerning. The result is handed back to [value] and is
# worth keeping: it walks the whole table once, which a per-pair lookup must
# not do.
proc ::tclpdf::kern::build {font} {
  set indices [::tclpdf::kernGpos lookups $font]
  if {[llength $indices]} {
    set prepared [::tclpdf::kernGpos subtables $font]
    if {[llength $prepared]} {
      return [list gpos $prepared]
    }
    # Lookups that yielded nothing readable. The specification still says the
    # kern table is out of play in this font, and inventing a fallback here
    # would kern one font differently from every other tool.
    return [list none {}]
  }
  set pairs [KernTable $font]
  if {[dict size $pairs]} {
    return [list kern $pairs]
  }
  return [list none {}]
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

# The adjustment for one glyph pair, in font units. Negative moves the two
# closer together, which is what most pairs do.
proc ::tclpdf::kern::value {state left right} {
  lassign $state kind data
  switch -- $kind {
    gpos {
      return [::tclpdf::kernGpos value $data $left $right]
    }
    kern {
      if {[dict exists $data $left,$right]} {
        return [dict get $data $left,$right]
      }
    }
  }
  return 0
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

package provide tclpdf::kern 1.0
