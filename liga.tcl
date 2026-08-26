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
# TWO features are read - "liga" and "clig" - because the registry has both of
# them on by default and a shaper applies both without being asked. Not read,
# and each for a reason:
#
#   rlig  required ligatures - Arabic lam-alef and relatives. They belong to
#         the shaping of a cursive script rather than to a typographic option
#         a caller switches on, and forms.tcl applies them for the scripts it
#         sets. Reading them HERE would apply them to a run nobody shaped.
#   dlig  discretionary, hlig historical - both off by default in the
#         registry, so a writer that switched them on would be overruling the
#         type designer rather than following them.
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
# -ligatures SWITCHES BOTH, and that is not a shortcut. The registry gives the
# two the same default and the same job; a caller who says "set this line
# without ligatures" means the letters are to stand apart, and leaving the
# contextual half on would leave an fi in the middle of it.
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
}

# Prepare a font for ligature substitution. The result is handed to [apply]
# and is worth keeping: it walks the whole table once.
#
# BOTH TAGS IN ONE CALL, not one call each. A feature does not own its
# lookups: two of them may name the same one, and the specification applies
# lookups in the order of the LOOKUP LIST rather than feature by feature
# (S. 217). [otLayout featureLookups] takes the list of tags and sorts the
# union, which is the same thing HarfBuzz's map does with a stage - so asking
# twice and joining the answers afterwards would be a second, private ordering
# and a second chance to get it wrong.
#
# No script is named, so the lookups come out of the Latin language system -
# which is the right one for a typographic option a caller switched on for
# text this package does not otherwise identify. What that used to cost is
# gone: DejaVu Sans keeps its Arabic ligatures under the "arab" script, and
# forms.tcl now reads liga and clig under the script it was asked for, so a
# cursive run never comes through here at all (font.tcl, [FontRun]).
#
# THE KINDS ASKED FOR are the ligature lookups and the two contextual ones.
# Single and Multiple substitutions are still left out of the FEATURE, for the
# reason at [gsubApply MultipleAt]: a Multiple substitution takes one glyph
# apart into several, and the rule about which of the pieces carries the text
# was measured on cursive faces. What a contextual rule reaches ON to is
# prepared whatever its type - that is [prepare]'s doing and not a hole here -
# because half a substitution is worse than none, and a contextual ligature is
# exactly a chaining lookup naming an ordinary one.
proc ::tclpdf::liga::build {font} {
  set gsub [::tclpdf::sfnt table $font GSUB]
  if {$gsub eq {}} {
    return {}
  }
  return [::tclpdf::gsubApply feature $gsub {liga clig} \
      [::tclpdf::gdef build $font] {} {ligature context chain}]
}

# Substitute in a glyph run.
#
# The run is a list of entries {glyph codes}, where codes are the character
# code points that glyph stands for. A ligature replaces several entries by
# one whose codes are all of theirs, in order.
proc ::tclpdf::liga::apply {prepared run} {
  if {[llength $run] < 2} {
    return $run
  }
  return [::tclpdf::gsubApply apply $prepared $run]
}

package provide tclpdf::liga 1.4
