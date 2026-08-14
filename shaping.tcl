#
# tclpdf - PDF generation for Tcl
#
# shaping - which writing systems need more than a glyph per character
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# A private sub-module behind the font facade. It knows nothing about fonts or
# PDF - it answers one question about a string: does any character in it
# belong to a writing system this package cannot set correctly?
#
# WHY THIS EXISTS. tclpdf maps one character to one glyph and draws them left
# to right. For most of the world's scripts that is the whole job. For some it
# is not, and the result then LOOKS like text while being wrong:
#
#   contextual shaping   the glyph depends on the neighbours. Arabic beh is
#                        four different shapes; the cmap only ever gives the
#                        isolated one, the other three sit behind the GSUB
#                        features init, medi and fina.
#   reordering           the line runs right to left, or a vowel sign is
#                        written before the consonant it follows.
#
# THE RULE THIS FOLLOWS is the one the package already applies to a missing
# glyph: refuse rather than draw something wrong. A reader shows the wrong
# text, a validator says nothing, and the recipient cannot tell. Only this end
# can. -unshaped 1 turns it off for the caller who knows what they are doing.
#
# WHAT IS DELIBERATELY NOT LISTED. Tibetan - measured, it comes out right:
# its stacked consonants are separate code points rather than contextual
# forms. CJK, Cuneiform, Egyptian Hieroglyphs, Greek, Cyrillic and the Latin
# range likewise. The list holds what BREAKS, not what a shaper could improve.
#

package require Tcl 8.6.11-

namespace eval ::tclpdf::shaping {
  namespace export {[a-z]*}
  namespace ensemble create

  # {first last system what-is-missing}
  #
  # The ranges are Unicode blocks, taken whole: a block belongs to one script,
  # and a character in it needs what its script needs. Splitting them finer
  # would be a table that has to be maintained against every Unicode release.
  variable systems {
    0x0590 0x05FF Hebrew      {right-to-left ordering}
    0x0600 0x06FF Arabic      {contextual shaping and right-to-left ordering}
    0x0700 0x074F Syriac      {contextual shaping and right-to-left ordering}
    0x0750 0x077F Arabic      {contextual shaping and right-to-left ordering}
    0x0780 0x07BF Thaana      {right-to-left ordering}
    0x07C0 0x07FF NKo         {contextual shaping and right-to-left ordering}
    0x0800 0x083F Samaritan   {right-to-left ordering}
    0x0840 0x085F Mandaic     {contextual shaping and right-to-left ordering}
    0x08A0 0x08FF Arabic      {contextual shaping and right-to-left ordering}
    0x0900 0x097F Devanagari  {reordering and conjunct forms}
    0x0980 0x09FF Bengali     {reordering and conjunct forms}
    0x0A00 0x0A7F Gurmukhi    {reordering and conjunct forms}
    0x0A80 0x0AFF Gujarati    {reordering and conjunct forms}
    0x0B00 0x0B7F Oriya       {reordering and conjunct forms}
    0x0B80 0x0BFF Tamil       {reordering and conjunct forms}
    0x0C00 0x0C7F Telugu      {reordering and conjunct forms}
    0x0C80 0x0CFF Kannada     {reordering and conjunct forms}
    0x0D00 0x0D7F Malayalam   {reordering and conjunct forms}
    0x0D80 0x0DFF Sinhala     {reordering and conjunct forms}
    0x0E00 0x0E7F Thai        {mark placement and reordering}
    0x0E80 0x0EFF Lao         {mark placement and reordering}
    0x1000 0x109F Myanmar     {reordering and conjunct forms}
    0x1780 0x17FF Khmer       {reordering and conjunct forms}
    0xFB1D 0xFB4F Hebrew      {right-to-left ordering}
    0xFB50 0xFDFF Arabic      {contextual shaping and right-to-left ordering}
    0xFE70 0xFEFF Arabic      {contextual shaping and right-to-left ordering}
  }
}

# The first character of a string that needs shaping, or {} when there is
# none.
#
# Returns {position codePoint system what}, where position counts characters
# from zero - the same counting the missing-glyph message uses, so the two
# messages point at the same place in the same way.
#
# The whole string is walked rather than stopping at the first hit being
# reported: a caller gets the FIRST offender, which is the one to look at.
proc ::tclpdf::shaping::needed {text} {
  variable systems
  set position 0
  foreach char [split $text {}] {
    set code [scan $char %c]
    foreach {first last system what} $systems {
      if {$code >= $first && $code <= $last} {
        return [list $position $code $system $what]
      }
    }
    incr position
  }
  return {}
}

# The message for such a character - one place, so the wording cannot drift
# between the callers that report it.
proc ::tclpdf::shaping::message {finding} {
  lassign $finding position code system what
  return "tclpdf: U+[format %04X $code] (position $position) belongs to\
      $system, which needs $what - tclpdf has neither. Set -unshaped 1 to draw\
      it as isolated glyphs in logical order anyway"
}

package provide tclpdf::shaping 1.0
