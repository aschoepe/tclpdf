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
# the caller asked for them. GPOS mark attachment comes after those, out of
# markPos.tcl and on the run this file produced - which is why Arabic that
# carries vowel signs is set rather than refused: the harakat and the dots
# ccmp detached are both marks with anchors, and the anchors are read.
#
# WHAT IS REACHED, measured on this face rather than assumed. Of the nine
# lookups its rlig feature names for the default Arabic language system, one
# is a plain multiple substitution and the other eight are contextual (type 5)
# or chaining contextual (type 6). gsubApply.tcl reads all of them since
# 2026-08-26, and the two differences this comment used to name have gone with
# that: lam + alef now comes out as the two special shapes the face draws for
# the pair rather than as an ordinary initial and final, and the wide medial
# variants before certain finals are selected. Measured against hb-shape of
# HarfBuzz 14.3.1 over 6630 Arabic words with NOTHING switched off in
# HarfBuzz: 0 differ, where 1552 differed the day before. Over thirty faces
# and 135 750 words the count is 0 as well, against 21 543 before.
#
# WHAT IS STILL NOT REACHED is a feature and not a lookup type:
#
#   locl  see above - localised forms need a language to choose by.
#   liga  standard ligatures are not this file's, and liga.tcl reads them
#         under the LATIN language system. DejaVu Sans keeps its Arabic
#         ligatures in "liga" under the "arab" script (lookups 17 and 19,
#         measured), so lam + alef-with-madda comes out as two joined letters
#         where the face draws one glyph - four words of 6415 on that face.
#         tests/forms.test holds that difference deliberately.
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
  # STAGES ALONE. This used to carry a mark filter beside them, so that a
  # caller could ask afterwards whether the shaping had produced glyphs the
  # face means to PLACE rather than to advance - the undotted skeleton and the
  # separate dot that ccmp makes of a beh in NotoNaskhArabic-Variable. That
  # question decided a refusal, because a dot the package could not place
  # landed at the pen position instead of at its anchor. markPos.tcl places it
  # now, font.tcl no longer refuses such a face, and the filter went with the
  # question: it had no other reader.
  return [dict create stages $stages]
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

package provide tclpdf::forms 1.2
