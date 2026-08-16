#
# tclpdf - PDF generation for Tcl
#
# bidi - which way a character runs inside a line
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# A private sub-module behind the font facade, like shaping.tcl beside it. It
# knows nothing about fonts or PDF and answers three questions about single
# characters:
#
#   which direction does this character run in
#   which characters of a line belong to one NUMBER
#   what does this character look like when the line runs the other way
#
# WHY IT IS NOT PART OF shaping.tcl. That module answers "does this character
# need glyph work this package cannot do" - it is about SHAPES, and its list
# is a list of scripts that break, holding left-to-right ones (Devanagari,
# Thai, Khmer) and splitting blocks at their combining marks. This one is
# about DIRECTION, its list is the right-to-left blocks taken whole, and it
# has to classify every other character in the world as well - which shaping
# never does, because a character no script list mentions needs nothing.
# Two questions, two answers, two files. tests/bidi.test checks that the two
# lists agree about the blocks they share, so the separation cannot drift into
# a contradiction.
#
# WHAT THIS IS NOT. It is not the Unicode bidirectional algorithm (UAX #9).
# That algorithm resolves a paragraph of mixed runs into a display order, and
# it needs the full character database plus the embedding levels. This is its
# smallest useful corner, and the corner is chosen so that what is left over
# is REFUSED rather than set wrong:
#
#   digits inside a right-to-left line keep their own order - the number 4711
#   reads 4711 in an Arabic invoice, not 1174. That is rules W2..W7 of UAX #9
#   applied to one run of digits and nothing else.
#
#   a paired bracket is mirrored - U+0028 is drawn with the glyph of U+0029
#   in a right-to-left line (UAX #9 section 3.4, BidiMirroring.txt).
#
#   a character that is strongly LEFT-TO-RIGHT in a right-to-left line makes
#   the line mixed, and a mixed line is exactly what the full algorithm is
#   for. It is refused, and the message says so.
#

package require Tcl 8.6.11-

namespace eval ::tclpdf::bidi {
  namespace export {[a-z]*}
  namespace ensemble create

  # Every list below is written in HEXADECIMAL, because that is how Unicode
  # names a character and a list in decimal cannot be read against the
  # standard. They are compared as numbers, and [dict exists] and the [in]
  # operator compare STRINGS: "0x0028" is not "40", and a list left as
  # written answers "not mirrored" for every character in it. So each is
  # turned into numbers once, here, rather than at every lookup.
  proc Numbers {list} {
    return [lmap code $list {expr {$code}}]
  }

  # The right-to-left blocks, taken whole: every character in them runs right
  # to left, whether or not this package can set its script. Hebrew, Arabic,
  # Syriac, Thaana, N'Ko, Samaritan, Mandaic and the Arabic presentation
  # forms, plus the right-to-left planes above the BMP - the archaic scripts
  # of U+10800..U+10FFF and Adlam and the Arabic mathematical alphabets in
  # U+1E800..U+1EFFF.
  #
  # The scripts this package REFUSES are in here too, and on purpose: whether
  # Syriac can be drawn is shaping.tcl's answer, and it must not be reached
  # through a wrong one about its direction.
  variable rtlRanges [Numbers {
    0x0590 0x08FF
    0xFB1D 0xFDFF
    0xFE70 0xFEFF
    0x10800 0x10FFF
    0x1E800 0x1EFFF
  }]

  # What counts as a digit for the island rule: European, Arabic-Indic and
  # Extended Arabic-Indic. Unicode calls the first and third EN and the second
  # AN; the difference decides how they interact with a sign or a currency
  # symbol in the full algorithm, and it decides nothing here, because a run
  # of digits keeps its order either way.
  variable digitRanges [Numbers {
    0x0030 0x0039
    0x0660 0x0669
    0x06F0 0x06F9
  }]

  # Common Separators - they belong to the number only BETWEEN two digits.
  # "1.234,50" is one number; a full stop at the end of a sentence is not part
  # of one, and treating it as such would drag the sentence's punctuation into
  # the island.
  #
  # U+066B and U+066C are the Arabic decimal and thousands separators, the
  # counterparts of the full stop and the comma for Arabic-Indic digits. They
  # are not in UAX #9's CS class - they are AN, which is to say they are part
  # of the number rather than a separator inside it - and the effect here is
  # the same, so they are listed with the rule that produces it.
  variable separators [Numbers {0x002C 0x002E 0x003A 0x002F 0x00A0 0x066B 0x066C}]

  # European Terminators - part of the number when they stand DIRECTLY beside
  # one: a percent sign, a plus or minus, a currency symbol. Deliberately a
  # short list: every character named here is one that appears in an amount.
  #
  # U+002B, U+002D and U+2212 are formally ES (European Separator) rather than
  # ET, and UAX #9 rule W4 only makes an ES part of the number between two
  # digits. They are treated with the ET rule instead, so that "-5" and "+3%"
  # stay whole. What the two rules would produce differs only in where a
  # LEADING sign ends up, and a leading sign that is not part of its number is
  # the reading nobody wants.
  #
  # U+066A is the Arabic percent sign, listed for the same reason U+066B is.
  variable terminators [Numbers {0x0025 0x002B 0x002D 0x2212 0x20AC 0x0024 0x066A}]

  # Everything that is neither strongly left-to-right nor right-to-left:
  # spaces, punctuation, symbols, currency, arrows, emoji. A character in here
  # takes the direction of the line it stands in, so it may appear in a
  # right-to-left line without making it mixed.
  #
  # The list is a POSITIVE one and everything outside it counts as
  # left-to-right, which is the safe way round: an unlisted neutral is refused
  # with a message that overstates the case, an unlisted left-to-right letter
  # would be drawn backwards in silence. Refusing too much is a complaint,
  # drawing too much is a wrong invoice.
  #
  # Read off the Unicode character database rather than chosen by eye. The
  # gaps are the characters in these blocks that are strongly left-to-right:
  # U+00AA and U+00BA, the ordinal indicators, and U+00B5, micro sign.
  variable neutralRanges [Numbers {
    0x0009 0x000D
    0x0020 0x002F
    0x003A 0x0040
    0x005B 0x0060
    0x007B 0x007E
    0x00A0 0x00A9
    0x00AB 0x00B4
    0x00B6 0x00B9
    0x00BB 0x00BF
    0x00D7 0x00D7
    0x00F7 0x00F7
    0x2000 0x206F
    0x20A0 0x20CF
    0x2190 0x2BFF
    0x2E00 0x2E7F
    0x1F000 0x1FBFF
  }]

  # The mirrored pairs (UAX #9 section 3.4, BidiMirroring.txt), as the pairs
  # that occur in text this package is asked to set: the four ASCII brackets
  # and the two guillemets. Both halves of each pair are listed, because the
  # swap runs in both directions.
  #
  # WHAT IS NOT HERE, and it is the mistake that suggests itself: the German
  # quotation marks U+201A and U+2018 look like a pair and are NOT mirrored -
  # measured against HarfBuzz, which returns them unswapped in a right-to-left
  # run while it swaps every pair below. Neither are the slash and the
  # backslash. The list is the Unicode property, not a list of characters that
  # come in twos.
  variable mirrors [Numbers {
    0x0028 0x0029  0x0029 0x0028
    0x003C 0x003E  0x003E 0x003C
    0x005B 0x005D  0x005D 0x005B
    0x007B 0x007D  0x007D 0x007B
    0x00AB 0x00BB  0x00BB 0x00AB
    0x2039 0x203A  0x203A 0x2039
  }]
}

# The direction class of one character, reduced to what this package acts on:
#
#   rtl          runs right to left
#   digit        keeps its own order inside a right-to-left line
#   separator    joins a number BETWEEN two digits
#   terminator   joins a number DIRECTLY beside one
#   neutral      takes the direction of the line
#   ltr          runs left to right
#
# The order of the tests is the answer to an overlap: the Arabic-Indic digits
# and the Arabic separators sit INSIDE the Arabic block, so they have to be
# recognised before the block is.
proc ::tclpdf::bidi::class {code} {
  # As a NUMBER, once. The lists below are asked in two ways - a range by
  # comparison, a membership by [in] - and the two disagree about "0x05D0":
  # the comparison reads it as 1488 and the membership as a seven character
  # string that equals nothing. One conversion here settles it for all of
  # them, and for [mirror] below, which has the same two ways in one.
  set code [expr {int($code)}]
  variable digitRanges
  variable separators
  variable terminators
  variable neutralRanges
  variable rtlRanges
  foreach {first last} $digitRanges {
    if {$code >= $first && $code <= $last} {
      return digit
    }
  }
  if {$code in $separators} {
    return separator
  }
  if {$code in $terminators} {
    return terminator
  }
  foreach {first last} $rtlRanges {
    if {$code >= $first && $code <= $last} {
      return rtl
    }
  }
  foreach {first last} $neutralRanges {
    if {$code >= $first && $code <= $last} {
      return neutral
    }
  }
  return ltr
}

# The mirrored form of a character, or the character itself.
proc ::tclpdf::bidi::mirror {code} {
  set code [expr {int($code)}]
  variable mirrors
  if {[dict exists $mirrors $code]} {
    return [dict get $mirrors $code]
  }
  return $code
}

# The first character that runs against the direction the caller named, as
# {position codePoint}, or {} when there is none. Position counts characters
# from zero - the same counting shaping.tcl uses, so the two messages point at
# the same place in the same way.
#
# Only "rtl" has an answer here. The other way round is shaping.tcl's: a
# right-to-left script in a left-to-right line is refused there, with a
# message that names -direction rtl as the way out, and finding it twice would
# mean two wordings for one mistake.
proc ::tclpdf::bidi::opposite {text {direction ltr}} {
  if {$direction ne "rtl"} {
    return {}
  }
  set position 0
  foreach char [split $text {}] {
    set code [scan $char %c]
    if {[class $code] eq "ltr"} {
      return [list $position $code]
    }
    incr position
  }
  return {}
}

# The message for such a character - one place, so that the wording cannot
# drift between the callers that report it.
proc ::tclpdf::bidi::message {finding} {
  lassign $finding position code
  return "tclpdf: U+[format %04X $code] (position $position) is left-to-right\
      in a -direction rtl line - a mixed line needs the bidi algorithm, which\
      tclpdf does not have; set the runs as separate calls, one per direction"
}

# How a line breaks into pieces that each keep their own order, as a list of
# {first last} index pairs covering the whole input in LOGICAL order.
#
# Every position is its own piece except a NUMBER, which is one piece however
# many characters it has. Reversing the list of pieces - rather than the list
# of characters - is what sets a right-to-left line with its numbers the right
# way round, and it is why this returns pieces instead of a flag per position:
# the caller that draws and the caller that walks a path both need the same
# order, and building it twice is how the two come to disagree.
#
# The input is one code point per position. A position that is not a single
# character - a ligature glyph standing for several - is written as an empty
# element or a negative number and can never be part of a number: no face
# ligates digits, measured against HarfBuzz with DejaVu Sans, and a ligature
# that did would be one glyph and one piece anyway.
proc ::tclpdf::bidi::segments {codes} {
  set count [llength $codes]
  set classes {}
  foreach code $codes {
    if {![string is integer -strict $code] || $code < 0} {
      lappend classes ltr
    } else {
      lappend classes [class $code]
    }
  }
  # The digits themselves, then what may join them. Written as three passes
  # over the same flags rather than one walk with lookahead: the terminator
  # rule needs the whole run of terminators before it can say whether any of
  # them touches a digit, and a single walk that tried would have to look both
  # ways at once.
  set member [lrepeat $count 0]
  for {set index 0} {$index < $count} {incr index} {
    if {[lindex $classes $index] eq "digit"} {
      lset member $index 1
    }
  }
  for {set index 1} {$index < $count - 1} {incr index} {
    if {[lindex $classes $index] eq "separator"
        && [lindex $classes $index-1] eq "digit"
        && [lindex $classes $index+1] eq "digit"} {
      lset member $index 1
    }
  }
  for {set index 0} {$index < $count} {incr index} {
    if {[lindex $classes $index] ne "terminator"} {
      continue
    }
    set last $index
    while {$last + 1 < $count
        && [lindex $classes $last+1] eq "terminator"} {
      incr last
    }
    if {($index > 0 && [lindex $classes $index-1] eq "digit")
        || ($last + 1 < $count && [lindex $classes $last+1] eq "digit")} {
      for {set at $index} {$at <= $last} {incr at} {
        lset member $at 1
      }
    }
    set index $last
  }
  set segments {}
  set index 0
  while {$index < $count} {
    if {![lindex $member $index]} {
      lappend segments [list $index $index]
      incr index
      continue
    }
    set last $index
    while {$last + 1 < $count && [lindex $member $last+1]} {
      incr last
    }
    lappend segments [list $index $last]
    set index [expr {$last + 1}]
  }
  return $segments
}

package provide tclpdf::bidi 1.0
