#
# tclpdf - PDF generation for Tcl
#
# forms - the contextual forms of a cursive script, out of GSUB
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# A private sub-module behind the font facade, and the place where the two
# halves of Arabic shaping meet: joining.tcl says which FORM each character
# stands in, this file looks that form up in the GSUB table of one face and
# substitutes it into the glyph run. The machinery of a substitution is
# gsubApply.tcl's, shared with the standard ligatures.
#
# WHAT THE CMAP GIVES AND WHY IT IS NOT ENOUGH. A cmap has one glyph per
# character, and for Arabic that one is the isolated shape. Measured in
# NotoNaskhArabic-Variable.ttf: U+0628 beh maps to glyph 614, and the initial,
# medial and final shapes are other glyphs entirely, reachable only through
# the init, medi and fina features. Drawing the cmap glyphs gives a line of
# disconnected letters - readable by an expert, wrong to everyone else, and
# reported by no validator.
#
# THE ORDER THE FEATURES ARE APPLIED IN is not free and not invented here. It
# is the order HarfBuzz's Arabic shaper uses, and it matters because the
# output of one feature is the input of the next:
#
#   1. ccmp   compose/decompose. In this face it splits a letter into its
#             skeleton and its dots - beh becomes uni066E plus dotbelowar -
#             and everything after it works on the skeleton.
#   2. locl   NOT APPLIED. Localised forms need a language to choose by, and
#             this package has no language API. What is lost is named below.
#   3. isol, fina, medi, init - the positional forms, in that order, and each
#             glyph takes exactly ONE of them: the one joining.tcl assigned to
#             the character it came from. Running all four over the whole run
#             would substitute a final form and then a medial one on top of
#             it.
#   4. rlig   required ligatures - lam-alef and relatives. AFTER the forms,
#             which is why a lam-alef rule matches the joined shapes rather
#             than the isolated letters.
#
# Standard ligatures (liga) come after all of this, in font.tcl, and only when
# the caller asked for them. GPOS mark attachment does not happen at all,
# which is why shaping.tcl still refuses Arabic that carries vowel signs.
#
# WHAT IS NOT REACHED, measured on this face rather than assumed. Of the nine
# lookups its rlig feature names for the default Arabic language system, ONE
# is a plain multiple substitution and the other eight are contextual (type 5)
# or chaining contextual (type 6), which gsubApply.tcl does not read. So:
#
#   - lam + alef comes out as two joined glyphs (uni0644.init, uni0627.fina)
#     rather than the lam-alef pair the face draws for it (…rlig). Visibly
#     different, not wrong: the letters are the right ones and they join.
#   - the "wide" medial variants that widen a joint before certain finals are
#     not selected. Same kind of difference, smaller.
#
# Both are differences from HarfBuzz that tests/forms.test holds on to
# deliberately, so that they cannot change unnoticed.
#

package require Tcl 8.6.11-
package require tclpdf::sfnt 1.0-
package require tclpdf::gdef 1.0-
package require tclpdf::gsubApply 1.0-
package require tclpdf::joining 1.0-

namespace eval ::tclpdf::forms {
  namespace export {[a-z]*}
  namespace ensemble create

  # The features that are read, in the order they are applied. The positional
  # four are marked with the form they belong to; the others apply to every
  # position and carry an empty mark.
  #
  # fin2, fin3 and med2 are missing on purpose: they are the Syriac forms, and
  # Syriac is refused for other reasons (shaping.tcl). Adding them without a
  # Syriac line to measure would be a guess in a table that otherwise is not.
  variable features {
    ccmp {}
    isol isol
    fina fina
    medi medi
    init init
    rlig {}
  }

  # The features without which there is nothing to do. A face may carry ccmp
  # and no forms at all - then this module would decompose letters into
  # skeletons and dots and leave them in their isolated shapes, which is worse
  # than not touching them.
  variable required {init medi fina}
}

# Prepare a face for cursive shaping, or {} when it cannot be shaped.
#
# The empty answer is a real answer and the caller acts on it: font.tcl
# refuses the text rather than drawing isolated forms. It comes back for a
# face with no GSUB, for one whose script or feature list does not read, and
# for one that simply has no positional forms - a Latin face asked to set
# Arabic, which is the case that used to produce a plausible-looking line of
# nonsense.
#
# The result is worth keeping: it reads a part of the table that a face will
# be asked for again with every string set in it.
proc ::tclpdf::forms::build {font {script arab}} {
  variable features
  variable required
  set gsub [::tclpdf::sfnt table $font GSUB]
  if {$gsub eq {}} {
    return {}
  }
  set gdef [::tclpdf::gdef build $font]
  set stages {}
  set have {}
  foreach {tag mark} $features {
    set prepared [::tclpdf::gsubApply feature $gsub $tag $gdef \
        [list $script DFLT]]
    if {[llength $prepared]} {
      lappend stages $tag $mark $prepared
      lappend have $tag
    }
  }
  foreach tag $required {
    if {$tag ni $have} {
      return {}
    }
  }
  # The filter that leaves out mark glyphs, kept for [marks] - built here
  # because this is where GDEF is read, and reading it a second time per
  # string is the kind of thing that turns a check into a cost. 0x0008 is
  # ignoreMarks; the filter it produces is empty for a face whose GDEF does
  # not classify, and then no glyph can be recognised as a mark either.
  return [dict create stages $stages \
      markFilter [::tclpdf::gdef filter $gdef 0x0008]]
}

# Does this run hold glyphs the face means to PLACE rather than to advance?
#
# The question that decides whether the shaping above is enough, and it can
# only be asked afterwards. A face may write beh as an undotted skeleton plus
# a dot glyph of its own - NotoNaskhArabic-Variable does, through ccmp - and
# that dot has a zero advance and an anchor in GPOS. tclpdf does not read
# GPOS mark attachment, so it would draw the dot at the pen position instead
# of at the anchor.
#
# Measured on that face, in font units of 1000: the dot below beh belongs 90
# to the right and 31 down, the two dots of teh marbuta 91 to the right and
# 294 DOWN - a third of an em. Rendered at 28 pt the dots of teh marbuta sit
# above the letter before it, and the word reads as a different word. That is
# a wrong line that looks like a right one, so the caller is told rather than
# served.
#
# A face that carries whole letters - DejaVu Sans, measured - produces no mark
# glyph here and needs none of this.
proc ::tclpdf::forms::marks {prepared run} {
  set filter [dict get $prepared markFilter]
  if {$filter eq {}} {
    return 0
  }
  foreach entry $run {
    if {[::tclpdf::gdef ignored $filter [lindex $entry 0]]} {
      return 1
    }
  }
  return 0
}

# Substitute the contextual forms into a glyph run.
#
# The run is what font.tcl built from the cmap: entries {glyph codes}, one
# character per entry, in LOGICAL order. It comes back longer than it went in
# whenever ccmp split a letter into several glyphs, and the characters stay
# attached to the first of them so the text still extracts.
#
# The FORM of each position is decided once, on the characters, before a
# single substitution has happened - and then travels with the glyphs through
# every one of them. Deciding it later would ask the joining algorithm about
# glyphs that are no longer letters: a detached dot is not a character with a
# joining type.
proc ::tclpdf::forms::apply {prepared run} {
  if {![dict size $prepared] || ![llength $run]} {
    return $run
  }
  set codes {}
  foreach entry $run {
    # One character per entry at this point. A ligature would carry several,
    # but nothing has run yet that could make one.
    lappend codes [lindex $entry 1 0]
  }
  set marked {}
  foreach entry $run form [::tclpdf::joining forms $codes] {
    lappend marked [list [lindex $entry 0] [lindex $entry 1] $form]
  }
  foreach {tag mark lookups} [dict get $prepared stages] {
    set marked [::tclpdf::gsubApply apply $lookups $marked $mark]
  }
  # The form tags leave by the door they came in at: everything downstream -
  # widths, kerning, encoding - takes a run of {glyph codes}, and a third
  # element that means nothing to any of them would travel through the whole
  # chain waiting to be mistaken for something.
  set result {}
  foreach entry $marked {
    lappend result [lrange $entry 0 1]
  }
  return $result
}

package provide tclpdf::forms 1.0
