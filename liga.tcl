#
# tclpdf - PDF generation for Tcl
#
# liga - standard ligatures out of the GSUB table
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# What is left in this file is a DECISION, not machinery: which feature is
# read, and which is not. The walk to the lookups is shared with kerning and
# lives in otLayout.tcl; reading a substitution subtable and applying it to a
# glyph run is shared with the cursive forms and lives in gsubApply.tcl. Both
# arrived there the same way - the second reader of the same bytes made the
# first one a copy.
#
# FIVE features are read - "rlig", "liga", "clig", "calt" and "rclt" - because
# the registry has all five on by default and a shaper applies them without
# being asked. Not read, and each for a reason:
#
#   ccmp, locl  ccmp takes characters apart and locl picks a localised form by
#         LANGUAGE, and this package has no language API to choose by.
#         forms.tcl applies ccmp for the cursive scripts, where the shaping
#         needs it.
#   dlig  discretionary, hlig historical - both off by default in the
#         registry, so a writer that switched them on would be overruling the
#         type designer rather than following them.
#
# rlig CAME IN ON 2026-08-26 and it is a decision rather than a measurement:
# HarfBuzz enables the required ligatures for EVERY script, and required is
# what they are - a face that draws two characters as one shape because the
# script demands it is not offering a typographic option. This file used to
# leave them to forms.tcl on the reading that they belong to cursive shaping,
# which is where they matter most and not where they are defined.
#
# calt AND rclt CAME IN ON 2026-08-26, and what let them in is the same
# lookup type that let clig in: contextual alternates are written as chaining
# lookups, and until the contextual machine existed switching them on would
# have prepared a feature whose every lookup was dropped. In this tree they
# are rare - measured, two faces of the Bitcount family carry calt (ligature
# lookups) and Noto Serif Tibetan one (a chaining lookup), and no face carries
# rclt at all - but a face that has one was set differently from every other
# reader and said nothing about it.
#
# ONE STAGE FOR ALL FIVE, and that is measured rather than assumed - it is
# also where the Latin side parts company with the Arabic one. HarfBuzz's
# DEFAULT shaper puts no pause anywhere among them, so their lookups are
# applied in LOOKUP ORDER across the five features; its ARABIC shaper pauses
# after rlig, which is why forms.tcl runs rlig as a stage of its own.
#
# Built as little faces in which two of the five substitute the same glyph and
# the lookup indices are permuted, shaped by hb-shape --script=latn:
#
#   liga at 0, rlig at 1  -> the liga glyph      rlig does NOT come first
#   rlig at 0, liga at 1  -> the rlig glyph
#   calt at 0, rlig at 1  -> the calt glyph
#   rlig at 0, calt at 1  -> the rlig glyph
#
# and the lowest index wins in all six permutations of liga, calt and rclt as
# well. The same four faces under --script=arab answer the rlig glyph every
# time, whatever the index - which is the pause, and the reason the stages are
# declared per module rather than shared as a table. Asking per tag and
# joining afterwards would be a second, private ordering - see [build].
#
# clig CAME IN ON 2026-08-26, and what let it in is a lookup type. A
# contextual ligature is a ligature with a rule about its surroundings, so it
# is written as a chaining lookup that names an ordinary one; those were not
# read before the contextual machine was built, and until then switching clig
# on would have prepared a feature whose every lookup was dropped. Now it is
# measured instead: of the 77 faces in examples/assets/fonts exactly four
# carry a clig feature - the HelveticaLTStd family - and in all four it is one
# chaining lookup, index 3, with four subtables. What it does there is the
# case the feature exists for: f + i becomes the fi ligature and f + l the fl
# one, EXCEPT after another f, where two of the four subtables match and
# substitute nothing so that "ffi" keeps its letters. Those faces carry no
# "liga" at all, so before this the fi of "acetifier" was two glyphs where
# every other reader draws one - 5721 words of the 235 974 in
# /usr/share/dict/words on the Roman alone. Measured against hb-shape over the
# whole word list and every face in this tree that carries either feature: 29
# faces, 6 843 246 word comparisons, 22 884 differences before and 0 after,
# and all 22 884 of them the fi and fl of those four faces. Not one NEW
# difference anywhere, which is what a before and an after are for.
#
# -ligatures SWITCHES liga AND clig, and that is not a shortcut. The registry
# gives the two the same default and the same job; a caller who says "set this
# line without ligatures" means the letters are to stand apart, and leaving
# the contextual half on would leave an fi in the middle of it.
#
# IT DOES NOT SWITCH rlig, calt OR rclt, and that is HarfBuzz's answer rather
# than a preference: --features=-liga,-clig leaves all three applied.
#
#   rlig is REQUIRED - the face draws the pair as one shape because the script
#        demands it, and set as two letters it is not a plainer setting of the
#        word but the wrong one. The manual says exactly this of -ligatures 0
#        for a cursive script; it is no less true of a Latin one.
#   calt, rclt are not ligatures at all - a contextual alternate is another
#        SHAPE of the same letter, the swash that only starts a word or the
#        connecting form of a script that has one - and a caller who wanted
#        the letters to stand apart did not ask for a different letter.
#
# So the option drops one of the two prepared stage lists rather than the
# stage, and the lookups that are left keep their place in the lookup order.
#
# The one thing this file still knows about the format is that a ligature
# breaks the assumption every other part of the package was built on - that a
# character has a glyph and a glyph has a character. Three characters become
# one glyph, and that glyph has to map back to three characters or the text
# stops being copyable. The glyph run is therefore built ONCE, in font.tcl,
# and carries with every glyph the characters it stands for.
#

package require Tcl 8.6.11-
package require tclpdf::sfnt 1.0-
package require tclpdf::gdef 1.0-
package require tclpdf::gsubApply 1.0-

namespace eval ::tclpdf::liga {
  namespace export {[a-z]*}
  namespace ensemble create

  # The STAGES, as a list of tag lists - one entry per stage, in the order
  # they run, which is the shape [gsubApply stages] takes. There is exactly
  # one of them here and that is the measurement, not a simplification: the
  # default shaper pauses nowhere among the five, so their lookups are applied
  # in lookup order across all of them. See the head of this file.
  #
  # The second list is what stays standing when -ligatures is off: the same
  # stage without the two typographic tags.
  variable stagesOn {{rlig liga clig calt rclt}}
  variable stagesOff {{rlig calt rclt}}

  # WHICH LOOKUP KINDS a feature of these stages may contribute: all of them.
  #
  # It was the ligature and contextual ones alone until 2026-08-26, on the
  # reading of [gsubApply MultipleAt] that a Multiple substitution takes one
  # glyph apart into several and the rule about which piece carries the text
  # was measured on cursive faces. rlig is what ended that: a required
  # ligature is regularly written as a Single or a Multiple substitution -
  # measured over the tree, its rlig features reach lookup types 1, 2, 4, 5
  # and 6 - so narrowing the kinds would read the feature and drop half of it,
  # which is worse than not reading it. HarfBuzz applies whatever a feature
  # names, and so does forms.tcl, which has passed every kind since it was
  # written. Measured after widening it here: 4019 words in eight Latin faces
  # against hb-shape with nothing switched off but ccmp and locl, unchanged.
  variable kinds {}
}

# Prepare a font for ligature substitution. The result is handed to [apply]
# and is worth keeping: it walks the whole table once.
#
# EVERY TAG OF A STAGE IN ONE CALL, not one call each. A feature does not own
# its lookups: two of them may name the same one, and the specification
# applies lookups in the order of the LOOKUP LIST rather than feature by
# feature (S. 217). [otLayout featureLookups] takes the list of tags and sorts
# the union, which is the same thing HarfBuzz's map does with a stage - so
# asking per tag and joining the answers afterwards would be a second, private
# ordering and a second chance to get it wrong.
#
# TWO PREPARED STAGE LISTS, and the second one is what -ligatures 0 leaves
# standing. Prepared here rather than at drawing time because [build] is what
# the face is asked once for; a face without rlig, calt or rclt gets an empty
# second list and pays nothing.
#
# No script is named, so the lookups come out of the Latin language system -
# which is the right one for a typographic option a caller switched on for
# text this package does not otherwise identify. What that used to cost is
# gone: DejaVu Sans keeps its Arabic ligatures under the "arab" script, and
# forms.tcl now reads liga and clig under the script it was asked for, so a
# cursive run never comes through here at all (font.tcl, [FontRun]).
#
# THE KINDS ASKED FOR are the ligature lookups, the two contextual ones and
# the reverse chaining one. Single and Multiple substitutions are still left
# out of the FEATURE, for the reason at [gsubApply MultipleAt]: a Multiple
# substitution takes one glyph apart into several, and the rule about which of
# the pieces carries the text was measured on cursive faces. What a contextual
# rule reaches ON to is prepared whatever its type - that is [prepare]'s doing
# and not a hole here - because half a substitution is worse than none, and a
# contextual ligature is exactly a chaining lookup naming an ordinary one.
proc ::tclpdf::liga::build {font} {
  variable stagesOn
  variable stagesOff
  variable kinds
  set gsub [::tclpdf::sfnt table $font GSUB]
  if {$gsub eq {}} {
    return {}
  }
  set gdef [::tclpdf::gdef build $font]
  set on [::tclpdf::gsubApply stages $gsub $stagesOn $gdef {} $kinds]
  set anything 0
  foreach stage $on {
    if {[llength $stage]} {
      set anything 1
      break
    }
  }
  if {!$anything} {
    # Nothing to do at all, and that is an answer the caller caches: a face
    # with none of the five features is asked once. It has to stay the EMPTY
    # list rather than a pair of empty ones, or every test for "has this face
    # anything" would have to learn the shape of the pair.
    return {}
  }
  return [list $on \
      [::tclpdf::gsubApply stages $gsub $stagesOff $gdef {} $kinds]]
}

# Substitute in a glyph run.
#
# The run is a list of entries {glyph codes}, where codes are the character
# code points that glyph stands for. A ligature replaces several entries by
# one whose codes are all of theirs, in order.
#
# LIGATURES is the -ligatures of the caller. Off, the contextual alternates
# still run - see the head of this file for why HarfBuzz leaves them on.
#
# NO SHORTCUT ON THE LENGTH OF THE RUN. It said "fewer than two glyphs,
# nothing to ligate" until 2026-08-26, which was true while a ligature needed
# two glyphs and stopped being true with the contextual machine: a chaining
# rule may have an input of exactly ONE position, with everything it tests in
# the backtrack and the lookahead, and a rule with no context at all is then a
# single substitution wearing a chain. Measured against hb-shape on a face
# built for it - "b" alone, a rule "sub b' lookup TOZ": hb answers Z, this
# answered b. [gsubApply apply] answers an empty run and an unprepared face
# for itself, so there is nothing left to say here.
proc ::tclpdf::liga::apply {prepared run {ligatures 1}} {
  return [::tclpdf::gsubApply applyStages \
      [lindex $prepared [expr {$ligatures ? 0 : 1}]] $run]
}

package provide tclpdf::liga 1.5
