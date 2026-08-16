#
# tclpdf - PDF generation for Tcl
#
# joining - which positional form a character needs in a cursive script
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# ONE question, and nothing about fonts or PDF in it: given the characters of
# a line in LOGICAL order, which of the four shapes does each of them stand
# in - isolated, initial, medial or final? The answer is a property of the
# text, the same for every face, and it is what forms.tcl then looks up in the
# GSUB table of one particular font.
#
# THE ALGORITHM is the cursive joining of The Unicode Standard, section 9.2,
# table 9-4, and it is four lines long once the joining types are known:
#
#   R  joins to the character BEFORE it in logical order (alef, ra, waw)
#   L  joins to the character AFTER it (no Arabic letter, but Mongolian has)
#   D  joins in both directions (beh, lam, ain - most letters)
#   C  causes joining without shaping itself (tatweel, ZWJ)
#   U  joins in neither direction and BREAKS the connection (space, digits)
#   T  transparent - skipped when the neighbours are looked for, and given no
#      form of its own (every vowel sign, every combining mark)
#
# A letter is INITIAL when it joins forward and not back, FINAL when it joins
# back and not forward, MEDIAL when it does both, ISOLATED when it does
# neither. That is the whole of it.
#
# WHY LOGICAL AND NOT VISUAL. Arabic is written right to left, so "the
# character before" sits to the RIGHT on the page, and the standard's own
# names - right-joining for R - are visual ones. Reading them as visual here
# would reverse the whole table. The run this package builds is logical in
# both directions (font.tcl), the reversal happens once when the line is
# written (text.tcl), and this module never sees it.
#
# WHY TRANSPARENT MATTERS MORE THAN IT LOOKS. A vowel sign between two letters
# must not break their connection. Treating one as a plain non-joiner turns
# every vowelled word into a row of isolated letters - which still LOOKS like
# text, which is the failure mode this package exists to avoid. The joining
# types come from the Unicode Character Database through tools/mkjoining.tcl,
# not from a hand-written list, for exactly that reason.
#
# WHAT THIS DOES NOT DO: it does not know which script a character belongs to
# and does not need to. Arabic, Syriac, N'Ko, Mandaic, Manichaean, Adlam,
# Mongolian and the rest share one property and one algorithm; whether this
# package can actually SET a given script is settled in shaping.tcl, and
# whether a face has the forms is settled in forms.tcl.
#

package require Tcl 8.6.11-
package require tclpdf::joiningData 1.0-

namespace eval ::tclpdf::joining {
  namespace export {[a-z]*}
  namespace ensemble create

  # The types that let a character connect to the one before it in logical
  # order, and the types that let it connect to the one after. C is in both
  # because a join-causing character connects on both sides without having a
  # shape of its own.
  variable joinsBack {R D C}
  variable joinsForward {L D C}
}

# The Joining_Type of one character: R, L, D, C, T or U.
#
# Found by halving the range table rather than walking it: the table has 532
# ranges and a line of text asks once per character, twice more per character
# while the neighbours are searched.
proc ::tclpdf::joining::type {code} {
  upvar 0 ::tclpdf::joiningData::ranges ranges
  set low 0
  set high [expr {[llength $ranges] / 3 - 1}]
  while {$low <= $high} {
    set middle [expr {($low + $high) / 2}]
    set at [expr {$middle * 3}]
    if {$code < [lindex $ranges $at]} {
      set high [expr {$middle - 1}]
    } elseif {$code > [lindex $ranges [expr {$at + 1}]]} {
      set low [expr {$middle + 1}]
    } else {
      return [lindex $ranges [expr {$at + 2}]]
    }
  }
  # Not listed is not a gap: the source file says every code point it does not
  # name is Non_Joining.
  return U
}

# The form each character of a line stands in, as a list as long as the input:
# isol, init, medi, fina - or "none" for a character that has no cursive form
# at all, which is every U and every T.
#
# The input is a list of code points in LOGICAL order. A line, not a word: a
# space is type U and breaks the connection by itself, so word boundaries need
# no separate treatment and text passed in piece by piece would join wrongly
# across the seam that is not there.
proc ::tclpdf::joining::forms {codes} {
  variable joinsBack
  variable joinsForward
  set count [llength $codes]
  set types {}
  foreach code $codes {
    lappend types [type $code]
  }
  set result {}
  for {set index 0} {$index < $count} {incr index} {
    set own [lindex $types $index]
    if {$own in {T U}} {
      lappend result none
      continue
    }
    # The neighbours, with every transparent character in between skipped -
    # not stopped at. Two marks in a row are as invisible as one.
    set before U
    for {set at [expr {$index - 1}]} {$at >= 0} {incr at -1} {
      if {[lindex $types $at] ne "T"} {
        set before [lindex $types $at]
        break
      }
    }
    set after U
    for {set at [expr {$index + 1}]} {$at < $count} {incr at} {
      if {[lindex $types $at] ne "T"} {
        set after [lindex $types $at]
        break
      }
    }
    # Joining takes two: this character must be able to reach in that
    # direction AND the neighbour must be able to reach back.
    set back [expr {$own in $joinsBack && $before in $joinsForward}]
    set forward [expr {$own in $joinsForward && $after in $joinsBack}]
    if {$back && $forward} {
      lappend result medi
    } elseif {$back} {
      lappend result fina
    } elseif {$forward} {
      lappend result init
    } else {
      lappend result isol
    }
  }
  return $result
}

package provide tclpdf::joining 1.0
