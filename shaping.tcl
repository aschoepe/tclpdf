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
# SINCE THE CURSIVE FORMS EXIST (forms.tcl) the first of those is no longer
# a refusal for Arabic - it is a CONDITION, and one this file cannot check on
# its own: whether the FACE carries init, medi and fina. So a finding of kind
# "forms" is not a verdict but a question passed to the caller, who has the
# face in hand. Everything else about Arabic is unchanged, and the vowel signs
# are the visible half of that: mark placement is GPOS, tclpdf does not read
# it, and a fatha drawn beside its letter instead of above it is exactly the
# kind of wrong-but-plausible line this module exists to prevent.
#
# THE RULE THIS FOLLOWS is the one the package already applies to a missing
# glyph: refuse rather than draw something wrong. A reader shows the wrong
# text, a validator says nothing, and the recipient cannot tell. Only this end
# can. -unshaped 1 turns it off for the caller who knows what they are doing.
#
# WHAT THE ANSWER DISTINGUISHES. Not every refusal is the same refusal, and
# treating them alike refused text this package can set. A script that needs
# nothing but the ORDER of its glyphs reversed - Hebrew letters, Thaana and
# Samaritan bases - is set correctly once the caller says -direction rtl,
# because reversing a run is something this package can actually do. A script
# whose glyph FORMS or MARK POSITIONS are missing is not, and stays refused:
# no option here can produce a shape the cmap does not lead to. That is why a
# finding carries its kind (ordering or shaping) alongside the prose.
#
# WHAT IS DELIBERATELY NOT LISTED. Tibetan LETTERS - measured, they come out
# right: consonants, tsheg, digits are one glyph each and sit side by side.
# What IS listed of Tibetan are its marks: the vowel signs (U+0F71..) and the
# subjoined letters (U+0F90..) are combining marks that a shaper places over
# and under the base through GPOS - and without that they land beside the
# NEXT letter. Measured 2026-08-17 on Noto Serif Tibetan: the o of "bod" over
# the d, the subjoined ka of "skad" under the d; the earlier measurement
# ("stacked consonants are separate code points") had looked at letters only.
# So they are cut out like the Hebrew nikud. CJK, Cuneiform, Egyptian
# Hieroglyphs, Greek, Cyrillic and the Latin range need nothing. The list holds
# what BREAKS, not what a shaper could improve.
#

package require Tcl 8.6.11-

namespace eval ::tclpdf::shaping {
  namespace export {[a-z]*}
  namespace ensemble create

  # What can be missing, as {token {kind prose}}.
  #
  # The KIND is what a caller can act on, the prose is what a message says.
  # Two kinds only:
  #
  #   ordering   the glyphs are the right ones, the line simply runs the other
  #              way. -direction rtl sets it, and the result is correct as
  #              long as the line holds nothing that would need bidi - no
  #              Latin words, no digits.
  #   forms      the glyphs have to be looked up through the GSUB features of
  #              the face as well. tclpdf does that (forms.tcl), so this is
  #              the one kind whose answer depends on something outside this
  #              module: -direction rtl AND a face that carries the features.
  #   shaping    forms or mark positions are missing as well. Nothing here can
  #              produce them; only -unshaped 1 draws it anyway.
  #
  # The prose lives here rather than in the table below, so that the same
  # phrase cannot come out two ways for two blocks that need the same thing.
  variable needs {
    order     {ordering {right-to-left ordering}}
    cursive   {forms    {contextual forms and right-to-left ordering}}
    shape     {shaping  {contextual shaping and right-to-left ordering}}
    conjunct  {shaping  {reordering and conjunct forms}}
    markOrder {shaping  {mark placement and reordering}}
    mark      {shaping  {mark placement}}
  }

  # {first last system token}
  #
  # The ranges are Unicode blocks, taken whole wherever the whole block needs
  # the same thing: a block belongs to one script, and a character in it needs
  # what its script needs.
  #
  # THE EXCEPTION is a block that holds both bases and combining marks, and it
  # is not a refinement but a correctness matter: the bases need ordering and
  # nothing else, the marks need placement this package does not do (GPOS mark
  # attachment is not read). Hebrew nikud, the Thaana fili and the Samaritan
  # points are therefore cut out of their blocks and stay refused, so that
  # -direction rtl cannot quietly produce a line whose points sit beside their
  # letters instead of under them.
  #
  # The Arabic blocks are the exception to the exception: their marks are not
  # a range but a scatter - U+0610..U+061A, U+064B..U+065F, U+0670,
  # U+06D6..U+06ED and more of the same in Arabic Extended-A - and cutting
  # them out by hand is how a list goes quietly out of date. They are found by
  # their Joining_Type instead, which says transparent for exactly those
  # characters and comes out of the Unicode Character Database
  # (joiningData.tcl). Same rule, better source.
  #
  # Syriac, N'Ko and Mandaic are cursive too and stay refused: they need the
  # same forms Arabic needs, nothing here has been measured against a face
  # that sets them, and "it probably works" is not what this module is for.
  variable systems {
    0x0590 0x0590 Hebrew      order
    0x0591 0x05C7 Hebrew      mark
    0x05C8 0x05FF Hebrew      order
    0x0600 0x06FF Arabic      cursive
    0x0700 0x074F Syriac      shape
    0x0750 0x077F Arabic      cursive
    0x0780 0x07A5 Thaana      order
    0x07A6 0x07B0 Thaana      mark
    0x07B1 0x07BF Thaana      order
    0x07C0 0x07FF NKo         shape
    0x0800 0x0815 Samaritan   order
    0x0816 0x082D Samaritan   mark
    0x082E 0x083F Samaritan   order
    0x0840 0x085F Mandaic     shape
    0x08A0 0x08FF Arabic      cursive
    0x0900 0x097F Devanagari  conjunct
    0x0980 0x09FF Bengali     conjunct
    0x0A00 0x0A7F Gurmukhi    conjunct
    0x0A80 0x0AFF Gujarati    conjunct
    0x0B00 0x0B7F Oriya       conjunct
    0x0B80 0x0BFF Tamil       conjunct
    0x0C00 0x0C7F Telugu      conjunct
    0x0C80 0x0CFF Kannada     conjunct
    0x0D00 0x0D7F Malayalam   conjunct
    0x0D80 0x0DFF Sinhala     conjunct
    0x0E00 0x0E7F Thai        markOrder
    0x0E80 0x0EFF Lao         markOrder
    0x0F18 0x0F19 Tibetan     mark
    0x0F35 0x0F35 Tibetan     mark
    0x0F37 0x0F37 Tibetan     mark
    0x0F39 0x0F39 Tibetan     mark
    0x0F3E 0x0F3F Tibetan     mark
    0x0F71 0x0F84 Tibetan     mark
    0x0F86 0x0F87 Tibetan     mark
    0x0F8D 0x0F97 Tibetan     mark
    0x0F99 0x0FBC Tibetan     mark
    0x0FC6 0x0FC6 Tibetan     mark
    0x1000 0x109F Myanmar     conjunct
    0x1780 0x17FF Khmer       conjunct
    0xFB1D 0xFB1D Hebrew      order
    0xFB1E 0xFB1E Hebrew      mark
    0xFB1F 0xFB4F Hebrew      order
    0xFB50 0xFDFF Arabic      cursive
    0xFE70 0xFEFF Arabic      cursive
  }
}

# The first character of a string this package cannot set in the given
# direction, or {} when there is none.
#
# Returns {position codePoint system what kind}, where position counts
# characters from zero - the same counting the missing-glyph message uses, so
# the two messages point at the same place in the same way. The kind is
# appended rather than inserted: a caller that only wants to name the system
# reads the first three elements as it always did.
#
# WHAT THE DIRECTION CHANGES. Under "rtl" a character that needs nothing but
# the order is no longer a finding, because the caller has just said the line
# runs the other way and the run is reversed for it. The walk CONTINUES past
# such a character rather than reporting it, so a Hebrew line with one Arabic
# word in it is still refused - and refused on the Arabic, which is the
# character to look at.
#
# WHAT FORMS CHANGES. Under "rtl" with forms 1 - the caller having established
# that the face carries init, medi and fina - a cursive character is no longer
# a finding either, and the walk continues past it for the same reason. That
# is why the caller asks TWICE: once to learn that the text is cursive at all,
# and once more with the answer, so that a vowel sign further along the line
# is still found. Only the second walk can find it; stopping at the first
# cursive character would report a character the package can now set.
proc ::tclpdf::shaping::needed {text {direction ltr} {forms 0}} {
  variable systems
  variable needs
  set position 0
  foreach char [split $text {}] {
    set code [scan $char %c]
    foreach {first last system token} $systems {
      if {$code < $first || $code > $last} {
        continue
      }
      lassign [dict get $needs $token] kind what
      if {$kind eq "forms"} {
        # A transparent character in a cursive block is a mark, and a mark
        # needs GPOS attachment rather than a form. Asked of the Unicode
        # table rather than of a range list, because the marks of these
        # blocks do not come in ranges.
        package require tclpdf::joining 1.0-
        if {[::tclpdf::joining type $code] eq "T"} {
          lassign [dict get $needs mark] kind what
        }
      }
      if {$direction eq "rtl" && ($kind eq "ordering"
          || ($forms && $kind eq "forms"))} {
        break
      }
      return [list $position $code $system $what $kind]
    }
    incr position
  }
  return {}
}

# The message for such a character - one place, so the wording cannot drift
# between the callers that report it.
#
# The way out differs with the kind, and naming the wrong one is worse than
# naming none: telling someone to set -unshaped 1 for a Hebrew line hands them
# the isolated-glyph escape hatch when what they want is one option that gets
# the line right.
# FACE is named by the caller that got as far as asking a face and was turned
# down by it, and WHY says which of the two ways that happened:
#
#   forms   the face has no positional forms at all - no init, medi or fina.
#   marks   it has them, and writes its letters as a skeleton plus separate
#           dot glyphs that GPOS would place. tclpdf does not place marks, so
#           the shaping is right and the dots would not be.
#
# Both sentences have to say what actually stands in the way rather than
# repeating "tclpdf does not do that", which by then is only half true and
# sends the reader looking in the wrong place. They are composed here all the
# same, so that the half every message shares cannot drift into two wordings.
proc ::tclpdf::shaping::message {finding {face {}} {why forms}} {
  lassign $finding position code system what kind
  set head "tclpdf: U+[format %04X $code] (position $position) belongs to\
      $system, which needs $what"
  set anyway "Set -unshaped 1 to draw it as isolated glyphs in logical order\
      anyway"
  if {$face ne {} && $why eq "marks"} {
    return "$head - the face \"$face\" writes its letters as a skeleton plus\
        separate mark glyphs, and placing those needs the GPOS mark\
        attachment tclpdf does not read: the dots would sit beside their\
        letters. Embed a face whose glyphs carry their own dots, or set\
        -unshaped 1 to draw the isolated glyphs anyway"
  }
  if {$face ne {}} {
    return "$head - the face \"$face\" has no contextual forms: its GSUB\
        table carries no init, medi and fina features. Embed a face that\
        does, or set -unshaped 1 to draw the isolated glyphs anyway"
  }
  if {$kind in {ordering forms}} {
    return "$head - pass -direction rtl to set the line right to left"
  }
  return "$head - tclpdf does not do that. $anyway"
}

package provide tclpdf::shaping 1.0
