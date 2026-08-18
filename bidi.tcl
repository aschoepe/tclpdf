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
#   reads 4711 in an Arabic invoice, not 1174. That is rules W2, W4 and W5 of
#   UAX #9 applied to one run of digits and nothing else: after an Arabic
#   letter a European digit counts as an Arabic one (W2), a separator joins
#   two digits of the same kind (W4), and a terminator joins a European digit
#   it stands beside (W5). One bend, on purpose and documented: a plus or
#   minus beside a European digit joins it as if it were a terminator, so
#   that "-5" keeps its sign in a Hebrew line.
#
#   a paired bracket is mirrored - U+0028 is drawn with the glyph of U+0029
#   in a right-to-left line (UAX #9 section 3.4, BidiMirroring.txt).
#
#   a character that is strongly LEFT-TO-RIGHT in a right-to-left line makes
#   the line mixed, and a mixed line is exactly what the full algorithm is
#   for. It is refused, and the message says so.
#

package require Tcl 8.6.11-
package require tclpdf::bidiData 1.0-

namespace eval ::tclpdf::bidi {
  namespace export {[a-z]*}
  namespace ensemble create

  # Every list below is written in HEXADECIMAL, because that is how Unicode
  # names a character and a list in decimal cannot be read against the
  # standard. The ranges are compared as numbers and that reads "0x0028" as
  # 40; [dict exists] compares STRINGS, and a mirror list left as written
  # answers "not mirrored" for every character in it. So each is turned into
  # numbers once, here, rather than at every lookup.
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
  #
  # U+FEFF is not in here although the presentation forms block runs to it:
  # it is the byte order mark, ZERO WIDTH NO-BREAK SPACE, BN in the database
  # and no Arabic at all. It is in the neutral list below instead, and
  # shaping.tcl ends its Arabic range at U+FEFE for the same reason.
  variable rtlRanges [Numbers {
    0x0590 0x08FF
    0xFB1D 0xFDFF
    0xFE70 0xFEFE
    0x10800 0x10FFF
    0x1E800 0x1EFFF
  }]

  # The ARABIC LETTER blocks among them, again taken whole - the block
  # defaults of DerivedBidiClass.txt for AL, less the number characters the
  # table above claims first. What sets them apart from Hebrew, N'Ko or
  # Samaritan is rule W2: a European digit after an Arabic letter counts as
  # an Arabic one, and after a Hebrew letter it does not, and the difference
  # shows in what may join the number (see [segments]).
  variable arabicRanges [Numbers {
    0x0600 0x07BF
    0x0860 0x08FF
    0xFB50 0xFDFF
    0xFE70 0xFEFE
    0x10D00 0x10D3F
    0x10EC0 0x10EFF
    0x10F30 0x10F6F
    0x1EC70 0x1ECBF
    0x1ED00 0x1ED4F
    0x1EE00 0x1EEFF
  }]

  # WHO BELONGS TO A NUMBER is not decided here but read off the Unicode
  # Character Database: bidiData.tcl carries the Bidi_Class of every
  # character UAX #9 folds into a number - EN and AN, the digits (rules W2,
  # W3); ES and CS, the separators (W4); ET, the terminators (W5) - generated
  # from tools/ucd/DerivedBidiClass.txt (Unicode 17.0.0) by tools/mkbidi.tcl.
  #
  # It used to be a hand list, "deliberately short: every character named
  # here is one that appears in an amount", and the shortness was the defect:
  # measured 2026-08-16 with DejaVu Sans, "5°", "£3" and "7‰" in a -direction
  # rtl line came out of the file as "°5", "3£" and "‰7". The degree sign, the
  # pound sign and the per mille sign are ET in UAX #9, and a terminator the
  # list does not know is a neutral that turns round with the line - a wrong
  # amount that looks like an amount. The database knows 31 ET ranges; a hand
  # list that named them all would be a copy of it with the risk of drift.
  #
  # The five classes are reduced to the three [class] answers with - digit,
  # separator, terminator - and that reduction is what the callers see.
  # [segments] keeps the five apart, because UAX #9 does: EN and AN are both
  # digits, but a terminator joins EN only (W5) and a separator joins two
  # digits of the SAME class (W4). One place the rules are bent, on purpose:
  #
  #   ES is treated as ET beside a European digit. Rule W4 makes an ES part
  #   of the number only BETWEEN two digits, W5 makes an ET part of it
  #   whenever it touches one. The plus, the minus and the hyphen-minus are
  #   ES, and under W4 alone the sign of "-5" would not be part of its number
  #   and would come out on the wrong side of it. That is the reading nobody
  #   wants, so "-5" and "+3%" stay whole here. What the two rules produce
  #   differs ONLY in where a leading or trailing sign ends up - and only for
  #   European digits: after an Arabic letter the digits are AN (W2), and no
  #   terminator or sign joins an AN, which is what UAX #9 and fribidi do
  #   with "-17,5" in an Arabic line.
  #
  # AN is a digit, and so are the Arabic decimal and thousands separators
  # U+066B and U+066C: they are AN in the database, not CS - Unicode counts
  # them as part of the number rather than as a separator inside it, so they
  # belong to the number wherever they stand beside its digits, where a CS
  # belongs to it only between two of them. Their Latin counterparts, the
  # full stop and the comma, ARE CS, so "1.234,50" is one number and the
  # full stop closing a sentence is not part of the number before it.
  #
  # U+00A0 NO-BREAK SPACE is CS in the database - the space that groups
  # thousands in "1 234,50" - so it joins a number between two digits without
  # being named here, and it stays a neutral everywhere else, which is what
  # the neutral list below says about it too.
  variable numberClasses {
    EN digit
    AN digit
    CS separator
    ET terminator
    ES terminator
  }

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
  # U+FEFF, the byte order mark, is BN - no direction of its own, like the
  # zero width space at U+200B that the general punctuation range holds.
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
    0xFEFF 0xFEFF
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

# The bidi type of one character, as far as this module tells them apart:
# the five number classes of the table by their UAX #9 names - EN AN CS ET
# ES - and beyond them AL for an Arabic letter, R for the other right-to-left
# blocks, neutral, and ltr for everything else. [class] below reduces this
# to what the callers act on; [segments] needs the finer answer, because W2
# turns on AL against R and W4/W5 on EN against AN.
#
# The order of the tests is the answer to an overlap: the Arabic-Indic digits
# and the Arabic separators sit INSIDE the Arabic block, so the number table
# has to be asked before the block is; and the Arabic blocks sit inside the
# right-to-left list, so they are asked before it.
proc ::tclpdf::bidi::Type {code} {
  # As a NUMBER, once. The lists below are asked by comparison, and a
  # comparison reads "0x05D0" as 1488 where a string lookup would read it as
  # seven characters that equal nothing. One conversion here settles it for
  # all of them, and for [mirror] below, which asks a dict.
  set code [expr {int($code)}]
  variable neutralRanges
  variable arabicRanges
  variable rtlRanges
  # The number table first - a digit inside the Arabic block is a digit. It
  # is walked like the block lists under it rather than halved the way
  # joining.tcl reads its table: 69 ranges against 532 there, and one search
  # written twice is one search that drifts.
  foreach {first last kind} $::tclpdf::bidiData::ranges {
    if {$code >= $first && $code <= $last} {
      return $kind
    }
  }
  foreach {first last} $arabicRanges {
    if {$code >= $first && $code <= $last} {
      return AL
    }
  }
  foreach {first last} $rtlRanges {
    if {$code >= $first && $code <= $last} {
      return R
    }
  }
  foreach {first last} $neutralRanges {
    if {$code >= $first && $code <= $last} {
      return neutral
    }
  }
  return ltr
}

# The direction class of one character, reduced to what this package acts on:
#
#   rtl          runs right to left
#   digit        keeps its own order inside a right-to-left line
#   separator    joins a number BETWEEN two digits
#   terminator   joins a number DIRECTLY beside one
#   neutral      takes the direction of the line
#   ltr          runs left to right
proc ::tclpdf::bidi::class {code} {
  variable numberClasses
  set type [Type $code]
  if {[dict exists $numberClasses $type]} {
    return [dict get $numberClasses $type]
  }
  if {$type in {AL R}} {
    return rtl
  }
  return $type
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
# character - a ligature glyph standing for several - is written as the list
# of the code points it stands for, or as an empty element or a negative
# number where the caller has no such list. It can never be part of a number:
# no face ligates digits, measured against HarfBuzz with DejaVu Sans, and a
# ligature that did would be one glyph and one piece anyway. But the LETTERS
# it is made of are still letters: a lam-alef is the last strong character
# before a number as much as a plain alef is, and a list keeps that type
# (the one of its last code point, if strong) where a bare -1 lost it -
# measured, "\u0644\u0627 12%" set 12% as a European number where fribidi
# --rtl has an Arabic one, "%12", because the search of W2 looked past the
# ligature and found nothing.
#
# The rules are the W rules of UAX #9 in their order, over the types [Type]
# gives, and a position that is no single character and no list is nothing
# - neither strong nor a number - so the search of W2 looks past it:
#
#   W2   a European digit after an Arabic letter is an Arabic digit. "After"
#        means the last strong character before it - AL, R, or a left-to-right
#        one - and where there is none the line's own direction counts, which
#        for a right-to-left line is R (sos). So digits after Hebrew stay
#        European, digits after Arabic become Arabic, and digits that open
#        the line stay European. What that changes is not the digits, which
#        keep their order either way, but what W4 and W5 let join them.
#   W4   a single separator BETWEEN two digits of the same class joins them:
#        "1.234,50" is one number, and so is "٤,٥"; "٤,5" is two digits with
#        a comma between them, as UAX #9 and fribidi have it.
#   W5   a run of terminators - and, the documented bend, of plus and minus
#        signs - joins the EUROPEAN digit it stands beside. An Arabic digit
#        takes no terminator and no sign: "٥٪" is a digit and a percent sign,
#        and "-17,5°" after an Arabic word is a sign, a number and a degree
#        sign - three pieces, where after a Hebrew word it is one.
#
# What is left over - W1, W3, W6, W7 - either does nothing here (W3 renames
# AL to R once W2 has used it, W6 makes the unjoined ones neutral, which
# they are) or needs a character this package refuses before it gets here
# (W1, the marks; W7, a left-to-right letter in the line).
proc ::tclpdf::bidi::segments {codes} {
  set count [llength $codes]
  set types {}
  foreach code $codes {
    if {[llength $code] > 1} {
      # A ligature: strong if its letters are, never a number or a piece of
      # one - so anything but a strong type is dropped to nothing.
      set type [Type [lindex $code end]]
      lappend types [expr {$type in {AL R ltr} ? $type : "none"}]
    } elseif {![string is integer -strict $code] || $code < 0} {
      lappend types none
    } else {
      lappend types [Type $code]
    }
  }
  # W2, in one walk with the last strong type in hand.
  set strong R
  for {set index 0} {$index < $count} {incr index} {
    switch -- [lindex $types $index] {
      AL - R - ltr {
        set strong [lindex $types $index]
      }
      EN {
        if {$strong eq "AL"} {
          lset types $index AN
        }
      }
    }
  }
  # The digits themselves, then what may join them. Written as three passes
  # over the same flags rather than one walk with lookahead: the terminator
  # rule needs the whole run of terminators before it can say whether any of
  # them touches a digit, and a single walk that tried would have to look both
  # ways at once.
  set member [lrepeat $count 0]
  for {set index 0} {$index < $count} {incr index} {
    if {[lindex $types $index] in {EN AN}} {
      lset member $index 1
    }
  }
  # W4: a separator between two digits of the SAME class.
  for {set index 1} {$index < $count - 1} {incr index} {
    if {[lindex $types $index] eq "CS"
        && [lindex $types $index-1] in {EN AN}
        && [lindex $types $index+1] eq [lindex $types $index-1]} {
      lset member $index 1
    }
  }
  # W5, and the sign with it: a run of ET/ES beside a EUROPEAN digit.
  for {set index 0} {$index < $count} {incr index} {
    if {[lindex $types $index] ni {ET ES}} {
      continue
    }
    set last $index
    while {$last + 1 < $count
        && [lindex $types $last+1] in {ET ES}} {
      incr last
    }
    if {($index > 0 && [lindex $types $index-1] eq "EN")
        || ($last + 1 < $count && [lindex $types $last+1] eq "EN")} {
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

package provide tclpdf::bidi 1.1
