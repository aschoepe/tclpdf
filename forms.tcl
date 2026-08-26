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
#   4. rlig   the required ligatures, a stage of their own. AFTER the forms,
#             which is why a lam-alef rule matches the joined shapes rather
#             than the isolated letters.
#   5. rclt, calt - the contextual alternates. Another SHAPE of a letter
#             rather than a ligature, so they run whatever -ligatures says.
#   6. liga, clig - the typographic ligatures, and the last stage.
#
# WHETHER 5 AND 6 ARE ONE STAGE OR TWO DEPENDS ON THE FACE, which is the one
# place in this file where the arrangement is not the same for every font.
# HarfBuzz puts a pause after calt only when the face has NO rclt feature
# (harfbuzz issue 3005): a face WITH rclt has rclt, calt, liga and clig in one
# stage, applied in lookup order across all four, and a face without it has
# calt alone in a stage and liga and clig in the next.
#
# MEASURED BLACK-BOX, the same way the rlig boundary below was. Small faces
# in which liga, calt and rclt each substitute the same glyph, with the lookup
# indices permuted, shaped by hb-shape --script=arab: with all three present
# the LOWEST index wins in all six permutations (one stage); with rclt left
# out, calt wins over liga even from the higher index (two stages); and adding
# an rclt feature that touches a different glyph is enough to flip the answer
# back. The Latin side has no such split - the default shaper never pauses
# there - and liga.tcl reads all four as one stage for that reason.
#
# mset is not read. It is the Syriac closing feature and stands beside fin2,
# fin3 and med2 in the table below: adding it without a Syriac line to measure
# would be a guess.
#
# THAT LAST STAGE IS WHERE THE ARABIC LIGATURES CAME BACK. Until 2026-08-26 it
# held rlig alone and liga.tcl read "liga" under the LATIN language system, so
# a face that keeps its Arabic ligatures under the "arab" script kept them to
# itself - DejaVu Sans draws lam plus alef-with-madda as one glyph, in "liga"
# lookups 17 and 19 of that script, and this package drew two joined letters.
# Resolving the script here costs nothing, because this module knows the
# script: it was asked for it.
#
# WHY rlig STANDS ALONE HERE AND NOT IN liga.tcl. The Arabic shaper pauses
# after rlig and the default shaper does not, so the SAME five features are
# one stage for a Latin run and three for a cursive one. Measured on the same
# little faces both times: with rlig at lookup 1 and liga at lookup 0,
# hb-shape --script=arab answers the rlig glyph and --script=latn the liga
# one. That is why the stages are declared per module and only the machinery
# that walks them is shared ([gsubApply stages], [gsubApply applyStages]).
#
# WHY rlig STANDS ALONE AND liga AND clig SHARE A STAGE, measured in HarfBuzz
# 14.3.1 rather than taken from its documentation. The three sat in ONE stage
# here until 2026-08-26, sorted by lookup index, on the reading that HarfBuzz
# collects them together. It does not: its Arabic shaper puts a pause after
# rlig, so rlig is a stage and liga and clig are the next one, and a stage
# boundary beats a lookup index.
#
# MEASURED BLACK-BOX rather than read off a trace. Noto Naskh Arabic was
# patched with two single substitutions on U+0621, both new lookups at the end
# of the lookup list: index 52, added to liga, turns it into ordfeminine, and
# index 53, added to rlig, turns it into ordmasculine. Whichever runs first
# wins, because after it the other no longer matches. hb-shape --script=arab
# answers ordmasculine - the HIGHER index, from rlig - and answers ordfeminine
# only with --features=-rlig. One sorted stage would have applied 52 first and
# this package did, which is the fault.
#
# In the tree it is invisible, and that is a property of these faces and not
# of the arrangement: DejaVu Sans has rlig at 14, 15, 16 and liga at 17, 19,
# the Bold at 13, 14, 15 and 16, 18, and Noto Naskh Arabic at 28 to 40 and 42
# - in every one of them the required ligatures come first by index anyway, so
# the sort and the stage order agreed. A face that numbers them the other way
# round is shaped wrong by a sort and right by a stage, and the stage is what
# HarfBuzz does.
#
# THE CALLER CAN STILL SWITCH THEM OFF. -ligatures is a typographic option and
# rlig is not: the required ligatures are part of the shaping, and a lam-alef
# set as two letters that the face has a joined shape for is wrong rather than
# plain. So the rlig stage always runs and the liga/clig stage runs only with
# -ligatures on, which is what the two stages buy on top of correctness: the
# switch is now the second stage being skipped rather than a second tag list
# prepared for it. It is bit for bit what HarfBuzz does with
# --features=-liga,-clig. GPOS mark attachment comes after either, out of
# markPos.tcl and on the run this file produced, which is why Arabic that
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
#
# Nothing else HERE. What is left over lies outside this module: two combining
# marks on one letter are taken in the order the caller wrote them rather than
# sorted by combining class, which is font.tcl's decision and is measured
# there.
#
# Nothing else. The one difference this list used to hold - the Arabic
# ligatures of "liga" under the "arab" script - went with the closing stages
# above: measured 2026-08-26 over 7961 Arabic words and the three faces in
# this tree that have positional forms, 0 differ from hb-shape where 66 did
# the hour before, all 66 of them a lam followed by one of the three alef
# forms that carry a hamza or a madda.
#

package require Tcl 8.6.11-
package require tclpdf::sfnt 1.0-
package require tclpdf::otLayout 1.0-
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
  }

  # The closing stages, in the order they run: the required ligatures, then
  # the contextual alternates, then the typographic ligatures - with the last
  # two folded into ONE stage for a face that carries rclt. Each list is read
  # as one tag list, which is what makes the lookups of its features come back
  # sorted by index: they share a stage, and a stage sorts. rlig is a stage of
  # its own and sorts among its own lookups only. See the head of this file
  # for the measurements.
  variable closingRequired rlig
  variable closingContextual {rclt calt}
  variable closingOptional {liga clig}

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
  variable closingRequired
  variable closingOptional
  set gsub [::tclpdf::sfnt table $font GSUB]
  if {$gsub eq {}} {
    return {}
  }
  set gdef [::tclpdf::gdef build $font]
  set order [list $script DFLT]
  set stages {}
  set have {}
  foreach {tag mark} $features {
    set prepared [::tclpdf::gsubApply feature $gsub $tag $gdef $order]
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
  # NO MARK FILTER BESIDE THEM. This used to carry one, so that a caller could
  # ask afterwards whether the shaping had produced glyphs the face means to
  # PLACE rather than to advance - the undotted skeleton and the separate dot
  # that ccmp makes of a beh in NotoNaskhArabic-Variable. That question decided
  # a refusal, because a dot the package could not place landed at the pen
  # position instead of at its anchor. markPos.tcl places it now, font.tcl no
  # longer refuses such a face, and the filter went with the question: it had
  # no other reader.
  lassign [Closing $gsub $gdef $order] closingOn closingOff
  return [dict create stages $stages \
      closingRequired [::tclpdf::gsubApply feature $gsub $closingRequired \
          $gdef $order] \
      closingOn $closingOn closingOff $closingOff]
}

# The stages after the required ligatures, in the two shapes -ligatures asks
# for: {withLigatures withoutLigatures}, each a LIST of prepared stages.
#
# A list of stages rather than one, because how many there are is the face's
# answer and not this module's - see the head of this file. Both shapes are
# built here rather than at drawing time: [build] is what a face is asked once
# for, and a face without calt, rclt or liga pays an empty list for it.
proc ::tclpdf::forms::Closing {gsub gdef order} {
  variable closingContextual
  variable closingOptional
  set indices {}
  if {[::tclpdf::otLayout damaged {
      set indices [::tclpdf::otLayout featureLookups $gsub rclt $order]}]} {
    # A feature list that does not read is a face without rclt as far as the
    # stage boundary goes; the tag is asked for again by [feature] below and
    # answers the same way.
    set indices {}
  }
  set contextual [::tclpdf::gsubApply feature $gsub $closingContextual \
      $gdef $order]
  if {[llength $indices]} {
    # No pause after calt: one stage over all four tags, sorted by lookup
    # index across them.
    return [list [list [::tclpdf::gsubApply feature $gsub \
        [concat $closingContextual $closingOptional] $gdef $order]] \
        [list $contextual]]
  }
  return [list [list $contextual [::tclpdf::gsubApply feature $gsub \
      $closingOptional $gdef $order]] [list $contextual]]
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
# LIGATURES says whether the typographic ligatures of the face take part - the
# -ligatures of the caller, and what the closing stages are for. Off, the
# required ligatures still run, so the lam-alef of rlig stands whatever the
# caller asked for: that one set as two letters is not a plainer setting of
# the word, it is the wrong one. So do rclt and calt, which are contextual
# ALTERNATES rather than ligatures. The forms a face puts in liga instead - in
# DejaVu Sans the three that carry a hamza or a madda - do fall with the
# switch, which is what HarfBuzz answers with --features=-liga,-clig.
proc ::tclpdf::forms::apply {prepared run {ligatures 1}} {
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
  # The closing stages run over every position, whatever form it stands in -
  # a ligature is made of two letters that need not share one - so they take
  # no mark. The required ligatures are part of the shaping and always run;
  # what follows them is the caller's option, and WHICH stages those are was
  # settled for this face at [build] time.
  set marked [::tclpdf::gsubApply apply \
      [dict get $prepared closingRequired] $marked]
  set closing closingOff
  if {$ligatures} {
    set closing closingOn
  }
  set marked [::tclpdf::gsubApply applyStages [dict get $prepared $closing] \
      $marked]
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

package provide tclpdf::forms 1.4
