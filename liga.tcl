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
# ONLY the "liga" feature is read: standard ligatures, which the registry has
# on by default. Not read, and each for a reason:
#
#   rlig  required ligatures - Arabic lam-alef and relatives. They belong to
#         the shaping of a cursive script rather than to a typographic option
#         a caller switches on, and forms.tcl applies them for the scripts it
#         sets. Reading them HERE would apply them to a run nobody shaped.
#   dlig  discretionary, hlig historical - both off by default in the
#         registry, so a writer that switched them on would be overruling the
#         type designer rather than following them.
#   clig  contextual ligatures. The mechanism - lookup types 5 and 6 - is read
#         since 2026-08-26, so the reason this line used to give is gone and
#         the decision is now an open one rather than a settled one. What is
#         known: of the 77 faces in examples/assets/fonts exactly four carry a
#         clig feature (the HelveticaLTStd family), measured 2026-08-26, so
#         nothing here can be measured against a face this package ships.
#         Turning it on is a change to WHICH features are read and belongs
#         with whoever decides that.
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
# No script is named, so the lookups come out of the Latin language system -
# which is the right one for a typographic option a caller switched on for
# text this package does not otherwise identify. What it costs is measured:
# DejaVu Sans keeps its Arabic ligatures under the "arab" script, so lam plus
# alef-with-madda stays two glyphs where the face draws one. Four words of the
# 6415 measured on that face; tests/forms.test holds the difference.
#
# ONLY LIGATURE LOOKUPS are asked for, which since the chaining lookups exist
# is a narrowing rather than a description: a contextual lookup in "liga"
# would not be prepared here. No face in this tree has one - measured
# 2026-08-26, all 51 liga subtables of the 25 faces that carry the feature are
# type 4 - so the narrowing costs nothing that can be shown, and lifting it
# would let a Multiple substitution into a feature the rule at
# [gsubApply MultipleAt] was not measured for.
proc ::tclpdf::liga::build {font} {
  set gsub [::tclpdf::sfnt table $font GSUB]
  if {$gsub eq {}} {
    return {}
  }
  return [::tclpdf::gsubApply feature $gsub liga [::tclpdf::gdef build $font] \
      {} ligature]
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

package provide tclpdf::liga 1.3
