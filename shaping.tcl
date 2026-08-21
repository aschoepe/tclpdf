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
# face in hand.
#
# SINCE MARK ATTACHMENT EXISTS (markPos.tcl, GPOS lookup types 4, 5 and 6) a
# combining mark is no longer drawn at the pen position either, and the
# refusals that said so have gone with the reason for them. Measured against
# hb-shape of HarfBuzz 14.3.1 on 2026-08-21:
#
#   Hebrew nikud   1163 of 1163 consonant-and-point pairs of Liberation Sans,
#                  Liberation Serif and Arimo land where HarfBuzz puts them,
#                  and 366 of 366 in DejaVu Sans and DejaVu Sans Bold. The 25
#                  that differ in the Liberation faces are the holam U+05B9,
#                  25 units of 2048 out because those faces refine it in a
#                  chaining contextual lookup (GPOS type 8) that markPos.tcl
#                  does not read.
#   Arabic harakat 5909 of 5909 letter-and-harakah pairs of Noto Naskh Arabic
#                  that the face gives an anchor for. 4150 more pairs are the
#                  Quranic annotation signs U+0610..U+0619, U+06D6..U+06DC and
#                  U+06E8, which that face anchors nowhere and HarfBuzz leaves
#                  unplaced too.
#
# What that leaves refused is a mark that has to MOVE before it can be placed,
# and no anchor helps with that: see the Tibetan paragraph below.
#
# THE RULE THIS FOLLOWS is the one the package already applies to a missing
# glyph: refuse rather than draw something wrong. A reader shows the wrong
# text, a validator says nothing, and the recipient cannot tell. Only this end
# can. -unshaped 1 turns it off for the caller who knows what they are doing.
#
# WHAT THE ANSWER DISTINGUISHES. Not every refusal is the same refusal, and
# treating them alike refused text this package can set. A script that needs
# nothing but the ORDER of its glyphs reversed - Hebrew, Thaana and Samaritan
# with their marks, and the non-cursive right-to-left scripts of the
# supplementary planes from Phoenician to Old Hungarian - is set correctly
# once the caller says -direction rtl, because reversing a run is something
# this package can actually do. A script whose glyph FORMS are missing is not,
# and stays refused: no option here can produce a shape the cmap does not lead
# to. That is why a finding carries its kind (ordering or shaping) alongside
# the prose.
#
# TIBETAN IS THE MEASURED "NO". Its letters come out right - consonants,
# tsheg, digits are one glyph each and sit side by side - and so, now, does a
# single vowel sign on a single letter: 160 of 160 letter-and-mark pairs of
# Noto Serif Tibetan agree with hb-shape to the unit. It stays refused all the
# same, because a Tibetan syllable is not one mark on one letter, measured on
# the same face and the same day:
#
#   - the subjoined consonants U+0F90..U+0FBC and the vowels U+0F71, U+0F73
#     to U+0F79 and U+0F81 are not placed by HarfBuzz at all. It substitutes
#     the letter and the mark for ONE precomposed stack glyph through GSUB
#     (abvs, blws), which this package does not apply: "skad" comes out of
#     hb-shape as two glyphs and out of tclpdf as three. 57 of the 77 marks
#     of the block are of that kind.
#   - two marks on one letter diverge in 384 of 1200 combinations even among
#     the twenty that agree singly, because the stacking substitutes there
#     too. So does OM, U+0F68 U+0F7C U+0F7E, which is one glyph in HarfBuzz
#     and three here.
#
# Anchors cannot supply a glyph the cmap does not lead to, so the whole block
# of marks stays where it was. CJK, Cuneiform, Egyptian Hieroglyphs, Greek,
# Cyrillic and the Latin range need nothing. The list holds what BREAKS, not
# what a shaper could improve.
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
    join      {shaping  {contextual shaping}}
    conjunct  {shaping  {reordering and conjunct forms}}
    markOrder {shaping  {mark placement and reordering}}
    mark      {shaping  {mark reordering}}
    stack     {shaping  {stacked forms out of GSUB}}
  }

  # The scripts whose LETTERS take the ordering road but whose combining marks
  # do not, although mark attachment exists.
  #
  # Named by script rather than cut out of the block by range, because their
  # marks are a scatter and a hand-written range list is how such a list goes
  # quietly out of date: they are found by their Joining_Type instead, which
  # says transparent for exactly those characters and comes out of the Unicode
  # Character Database (joiningData.tcl). Measured 2026-08-21, these four are
  # the only blocks of the ordering road that hold any: 13 characters in
  # Kharoshthi, 5 in Garay, 2 in Yezidi and 7 in Mende Kikakui.
  #
  # NOT MEASURED against a face, and it cannot be: no font on this machine
  # carries any of the four. They stay refused for the reason Tibetan does -
  # a shaper reorders these marks before it places them, and reordering is
  # what this package does not have - and that reason is the same one that
  # kept them out before mark attachment existed. Lifting a refusal on a
  # script nothing can be measured on is the guess this module exists to
  # avoid.
  variable reorderedMarks {Kharoshthi Garay Yezidi {Mende Kikakui}}

  # {first last system token}
  #
  # The ranges are Unicode blocks, taken whole wherever the whole block needs
  # the same thing: a block belongs to one script, and a character in it needs
  # what its script needs.
  #
  # THE HEBREW, THAANA AND SAMARITAN BLOCKS were once cut in three, because
  # their bases needed ordering and their marks needed a placement this
  # package did not do. Mark attachment does it now (markPos.tcl), so each of
  # the three is one line again and the points, the fili and the nikud travel
  # with their letters. The measurement that says so is in the file header;
  # what stays refused of them is nothing.
  #
  # The one block that is still cut is Tibetan, and it is cut by hand because
  # what is refused there is not "the marks" but the ones a shaper STACKS -
  # see the header. Its letters, tsheg and digits are not in the list at all.
  #
  # Syriac, N'Ko and Mandaic are cursive too and stay refused: they need the
  # same forms Arabic needs, nothing here has been measured against a face
  # that sets them, and "it probably works" is not what this module is for.
  # The same goes for the joining scripts beyond them, which the list used to
  # miss although the joining table (joiningData.tcl) knows every one of
  # them: Syriac Supplement, and in the supplementary planes Manichaean,
  # Psalter Pahlavi, Hanifi Rohingya, Sogdian, Old Uyghur, Chorasmian and
  # Adlam - all right-to-left and cursive - and, running the other way,
  # Mongolian and Phags-pa, whose letters join without any question of
  # direction. Measured 2026-08-18: U+0860, U+1820, U+1E900, U+10D00, U+10F30
  # and U+10AC0 all passed as if they needed nothing. The two Arabic
  # extensions B and C are Arabic and take the cursive road with the rest of
  # it: forms.tcl finds their shapes through the same joining types and the
  # same GSUB features.
  #
  # THE NON-CURSIVE RIGHT-TO-LEFT SCRIPTS of the supplementary planes stood
  # in neither list and were set left to right in silence - measured
  # 2026-08-18: U+10900 (Phoenician), U+10A10 (Kharoshthi) and U+1EE01
  # passed as needing nothing, and a word of Arabic mathematical letters
  # drawn in DejaVu Sans came back out of pdftotext in logical order, from
  # the left. They are the R and AL blocks of DerivedBidiClass.txt that the
  # joining table does NOT know - no forms to look up, like Hebrew - so they
  # take the order road: Cypriot through Old Hungarian, Garay, Yezidi, Old
  # Sogdian, Elymaic, Mende Kikakui, the two Siyaq number blocks and the
  # Arabic mathematical alphabets, each block taken whole. Four of them hold
  # combining marks that stay refused - Kharoshthi, Garay, Yezidi and Mende
  # Kikakui - and those are found by Joining_Type in [needed] rather than cut
  # out by hand; see [reorderedMarks] above for why they are still refused
  # and what could not be measured about them. Meroitic Cursive is cursive in
  # name only: the joining table has no entry for it, measured against
  # DerivedJoiningType.txt.
  #
  # Deliberately NOT listed beside them: the Rumi numeral symbols
  # (U+10E60..U+10E7E). They are AN digits, and a run of digits keeps its
  # own order in either direction - listing the block would refuse text this
  # package sets correctly. The unassigned stretches between the blocks
  # (U+108B0.., U+10960.. and the like) belong to no script and stay out
  # with them.
  #
  # The Arabic presentation forms end at U+FEFE. U+FEFF is the byte order
  # mark, ZERO WIDTH NO-BREAK SPACE - no Arabic, no mark, nothing to draw -
  # and taken with the block it was refused as needing mark placement, in a
  # left-to-right line of Latin text as well. It is dropped where it is met
  # instead, like U+200B (font.tcl, FontRun).
  variable systems {
    0x0590 0x05FF Hebrew      order
    0x0600 0x06FF Arabic      cursive
    0x0700 0x074F Syriac      shape
    0x0750 0x077F Arabic      cursive
    0x0780 0x07BF Thaana      order
    0x07C0 0x07FF NKo         shape
    0x0800 0x083F Samaritan   order
    0x0840 0x085F Mandaic     shape
    0x0860 0x086F Syriac      shape
    0x0870 0x089F Arabic      cursive
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
    0x0F18 0x0F19 Tibetan     stack
    0x0F35 0x0F35 Tibetan     stack
    0x0F37 0x0F37 Tibetan     stack
    0x0F39 0x0F39 Tibetan     stack
    0x0F3E 0x0F3F Tibetan     stack
    0x0F71 0x0F84 Tibetan     stack
    0x0F86 0x0F87 Tibetan     stack
    0x0F8D 0x0F97 Tibetan     stack
    0x0F99 0x0FBC Tibetan     stack
    0x0FC6 0x0FC6 Tibetan     stack
    0x1000 0x109F Myanmar     conjunct
    0x1780 0x17FF Khmer       conjunct
    0x1800 0x18AF Mongolian   join
    0xA840 0xA87F Phags-pa    join
    0xFB1D 0xFB4F Hebrew      order
    0xFB50 0xFDFF Arabic      cursive
    0xFE70 0xFEFE Arabic      cursive
    0x10800 0x1083F Cypriot    order
    0x10840 0x1085F {Imperial Aramaic} order
    0x10860 0x1087F Palmyrene  order
    0x10880 0x108AF Nabataean  order
    0x108E0 0x108FF Hatran     order
    0x10900 0x1091F Phoenician order
    0x10920 0x1093F Lydian     order
    0x10940 0x1095F Sidetic    order
    0x10980 0x1099F {Meroitic Hieroglyphs} order
    0x109A0 0x109FF {Meroitic Cursive} order
    0x10A00 0x10A5F Kharoshthi order
    0x10A60 0x10A7F {Old South Arabian} order
    0x10A80 0x10A9F {Old North Arabian} order
    0x10AC0 0x10AFF Manichaean shape
    0x10B00 0x10B3F Avestan    order
    0x10B40 0x10B5F {Inscriptional Parthian} order
    0x10B60 0x10B7F {Inscriptional Pahlavi} order
    0x10B80 0x10BAF {Psalter Pahlavi} shape
    0x10C00 0x10C4F {Old Turkic} order
    0x10C80 0x10CFF {Old Hungarian} order
    0x10D00 0x10D3F {Hanifi Rohingya} shape
    0x10D40 0x10D8F Garay      order
    0x10E80 0x10EBF Yezidi     order
    0x10EC0 0x10EFF Arabic     cursive
    0x10F00 0x10F2F {Old Sogdian} order
    0x10F30 0x10F6F Sogdian    shape
    0x10F70 0x10FAF {Old Uyghur} shape
    0x10FB0 0x10FDF Chorasmian shape
    0x10FE0 0x10FFF Elymaic    order
    0x1E800 0x1E8DF {Mende Kikakui} order
    0x1E900 0x1E95F Adlam      shape
    0x1EC70 0x1ECBF {Indic Siyaq Numbers} order
    0x1ED00 0x1ED4F {Ottoman Siyaq Numbers} order
    0x1EE00 0x1EEFF {Arabic Mathematical Alphabetic Symbols} order
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
# and once more with the answer, so that a character further along the line -
# a Syriac word among the Arabic, a Kharoshthi vowel sign - is still found.
# Only the second walk can find it; stopping at the first cursive character
# would report a character the package can now set. The Arabic vowel signs
# used to be what the second walk was for; they are no longer a finding at
# all, and the second walk stays for everything else it can still reach.
proc ::tclpdf::shaping::needed {text {direction ltr} {forms 0}} {
  variable systems
  variable needs
  variable reorderedMarks
  set position 0
  foreach char [split $text {}] {
    set code [scan $char %c]
    foreach {first last system token} $systems {
      if {$code < $first || $code > $last} {
        continue
      }
      lassign [dict get $needs $token] kind what
      if {$kind eq "ordering" && $system in $reorderedMarks} {
        # A transparent character is a combining mark, and in these four
        # scripts a mark has to be REORDERED before it can be placed - which
        # mark attachment does not do. Asked of the Unicode table rather than
        # of a range list, because their marks do not come in ranges: the
        # Kharoshthi vowel signs and virama are a scatter, and so are the
        # Garay, Yezidi and Mende Kikakui marks.
        #
        # Every other block of the list answers for its marks as a whole, and
        # answers YES: the Arabic harakat, the Hebrew nikud, the Thaana fili
        # and the Samaritan points are placed by markPos.tcl and travel with
        # their letters. The Tibetan marks are cut out of their block above
        # and never reach this question.
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
# down by it, and there is now only one way that happens: the face has no
# positional forms at all - no init, medi, fina.
#
# There used to be a second, for a face that has the forms and writes its
# letters as a skeleton plus separate dot glyphs. That message named GPOS mark
# attachment as what stood in the way, and it no longer does (markPos.tcl):
# such a face is now set with its dots where the anchors put them, so the
# refusal and the sentence that explained it are both gone.
#
# The sentence has to say what actually stands in the way rather than
# repeating "tclpdf does not do that", which by then is only half true and
# sends the reader looking in the wrong place. It is composed here all the
# same, so that the half every message shares cannot drift into two wordings.
proc ::tclpdf::shaping::message {finding {face {}}} {
  lassign $finding position code system what kind
  set head "tclpdf: U+[format %04X $code] (position $position) belongs to\
      $system, which needs $what"
  set anyway "Set -unshaped 1 to draw it as isolated glyphs in logical order\
      anyway"
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

package provide tclpdf::shaping 1.4
