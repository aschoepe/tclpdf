#
# tclpdf - PDF generation for Tcl
#
# gsubApply - applying the substitution lookups of a GSUB table to a glyph run
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Infrastructure below liga.tcl and forms.tcl, the way otLayout.tcl and
# gdef.tcl are. Two topics ask the same question of the same table - standard
# ligatures ask for "liga", cursive forms ask for "init", "medi" and "fina" -
# and the machinery in between is the same to the line: walk the run through
# the positions the lookup can see, find the glyph in a coverage table, put
# something else there. Only WHICH feature and in what order is a decision,
# and that stays with the caller.
#
# THE LOOKUP TYPES THIS READS (ISO/IEC 14496-22:2019, S. 267-289):
#
#   1 Single     one glyph becomes one other glyph
#   2 Multiple   one glyph becomes SEVERAL - the run gets longer
#   4 Ligature   several glyphs become one - the run gets shorter
#   5 Contextual         a SEQUENCE matches, and the substitutions are named
#   6 Chaining contextual   by index rather than written out
#   7 Extension  a 32 bit offset in front of a lookup of any other type
#   8 Reverse chaining single   one glyph becomes one other, matched with a
#                backtrack and a lookahead and applied from the END of the run
#
# Types 5 and 6 substitute nothing themselves. A rule of theirs matches a
# sequence and then names OTHER lookups by their index in the lookup list -
# "apply lookup 12 at the third glyph of what just matched" - and those are
# the ordinary types above. Reading the match is one topic and lives in
# gsubContext.tcl; applying it is this file's, because this file is where the
# types it names are applied. So the recursion goes out to the matcher and
# back in here, and neither half holds a copy of the other.
#
# Type 7 is not a substitution at all. It exists so that a lookup can reach
# past the 64 KiB an Offset16 spans, and otLayout::typedSubtables unwraps it
# before this file ever sees a subtable - which is why the number appears here
# only as a variable to pass down. It is 7 in GSUB where GPOS uses 9, and
# reading the GPOS number would resolve an offset into the middle of a
# subtable and hand back plausible nonsense.
#
# Type 8 RUNS BACKWARDS, and it is the only one that does. Its rule names no
# lookups at all: the substitution stands in the subtable beside the coverage,
# one glyph per coverage index, and the whole lookup is applied from the last
# position of the run to the first. That order is the point of the type - the
# lookahead of a rule has then already been substituted, which is what a face
# uses to resolve a chain of forms from the end of a word backwards. Reading
# the match is gsubContext.tcl's, like types 5 and 6; only the walk is here.
#
# Type 3 (Alternate) is not read, and that is a measurement rather than a
# plan: every one of the 39 type 3 lookups over the 77 faces in
# examples/assets/fonts hangs off "aalt" or "ornm" - features this package
# does not apply, and could not apply without an API for "give me the third
# alternate of this glyph". Measured 2026-08-26.
#
# APPLYING A LOOKUP AT ONE POSITION is the primitive everything here is built
# from, and it is the contextual lookups that made it one. A SequenceLookupRecord
# asks for exactly that - this lookup, this position, once - while an ordinary
# feature asks the same question at every position in turn. The [*At]
# procedures answer it and the [Apply*] walks ask it repeatedly; writing the
# two separately is how they would drift apart.
#
# WHAT A RUN IS, and why every substitution has to maintain it: a list of
# entries {glyph codes ?tag?}, where codes are the CHARACTER code points the
# glyph stands for and tag is what the caller uses to mark a position. The
# codes are the ToUnicode CMap: a ligature carries the characters of all its
# components, and the extra glyphs of a Multiple substitution carry NONE.
#
# That last one is the direction the ligature case does not prepare for and it
# is the one Arabic needs. Noto Naskh Arabic writes beh as two glyphs - the
# undotted skeleton and the dot below - through ccmp, so ONE character becomes
# TWO glyphs. Giving both of them the character would extract every beh twice;
# WHICH of them gets it is measured rather than picked, and the measurement is
# in [MultipleAt]. pdftotext is the only place any of this shows.
#

package require Tcl 8.6.11-
package require tclpdf::otLayout 1.0-
package require tclpdf::gdef 1.0-
package require tclpdf::gsubContext 1.0-

namespace eval ::tclpdf::gsubApply {
  namespace export {[a-z]*}
  namespace ensemble create

  # The lookup type numbers this file understands, and the number an extension
  # lookup carries in GSUB - 7 here, where GPOS uses 9. Reading the GPOS number
  # would resolve an offset into the middle of a subtable and hand back
  # plausible nonsense.
  variable kinds {1 single 2 multiple 4 ligature 5 context 6 chain 8 reverse}
  variable extensionType 7

  # How far a contextual lookup may reach into another one. A lookup may name
  # itself, directly or round a cycle, and the specification says nothing
  # about where that ends - so there has to be a number, and the number is
  # HarfBuzz's: HB_MAX_NESTING_LEVEL is 64, and a font shaped by both should
  # come out the same or the difference is this package's. It said six here
  # until 2026-08-26, on the strength of a comment that named HarfBuzz and
  # got its number wrong; measured with a chain of nested contextual lookups,
  # the two answers parted from depth 7 up to 64 and agreed again beyond it.
  #
  # RAISING IT DOES NOT WIDEN A CYCLE: reading a lookup graph that names
  # itself terminates on the worklist in [Nested], which stores every index
  # once and never reads it twice, whatever this number is. What the number
  # bounds is the recursion at SHAPING time, where the run gets shorter or
  # the position moves on at every step. Measured over the faces in this
  # tree, no lookup nests deeper than two: 18 references out of 12 321 point
  # at a contextual lookup at all, and all 18 are in Noto Serif Tibetan.
  variable maxDepth 64

  # HOW MUCH WORK ONE [apply] MAY SPEND, beside how deep it may go. The depth
  # alone does not bound a cycle: a rule with TWO records that both name the
  # lookup they stand in branches twice at every level, so 64 levels are 2^64
  # calls and the shaping of one word never ends. Measured on a face built for
  # it - one self-reference answers in 0 s, two do not answer at all.
  #
  # The budget is HarfBuzz's and so is what happens when it runs out.
  # HB_MAX_OPS_FACTOR is 64 per glyph and HB_MAX_OPS_MIN 16 384; every
  # recursion into a named lookup spends one, and the recursion that finds the
  # purse empty simply does nothing (hb-ot-layout-gsubgpos.hh, [recurse]:
  # "buffer->max_ops-- <= 0" sets shaping_failed and returns false). The run
  # then comes back as far as it got, which is what this package does too.
  #
  # NOT A REFUSAL, and that is a decision rather than an omission. A cyclic
  # font is not a caller's mistake and there is nothing the caller could do
  # about it: the alternative to a partly shaped word is no document at all,
  # for a defect in a file the caller may not even have made. It is also what
  # every other reader of the same font does, so the page comes out looking
  # like everyone else's.
  variable opsFactor 64
  variable opsFloor 16384

  # The identity of the next ligature this file forms - see [LigatureId].
  variable ligatureSerial 0

  # What is left of that budget. Set by [apply] and spent by [ApplyLookupAt];
  # a namespace variable rather than an argument because it has to be shared
  # by a recursion that goes out through gsubContext.tcl and back in, and
  # threading it through six signatures as an in-out parameter would put a
  # counter in every one of them.
  variable ops 0
}

# Prepare a list of lookups for [apply].
#
# The result is a list of {kind filter rules}, in lookup order, and it is worth
# keeping: it reads part of the table once for a font that will be asked again
# for every string set in it.
#
# WANTED narrows it to the kinds the caller can use - liga.tcl asks for
# ligatures alone. That is not tidiness: a Multiple substitution in a feature
# meant for typographic ligatures would take one glyph apart into several, and
# the rule about which of them carries the text (see [MultipleAt]) was
# measured on cursive faces and holds for those. It narrows the FEATURE only;
# what a contextual rule of it reaches on to is prepared whatever its type,
# because half a substitution is worse than none.
proc ::tclpdf::gsubApply::prepare {gsub indices gdef {wanted {}}} {
  variable kinds
  set types {}
  foreach {type kind} $kinds {
    if {![llength $wanted] || $kind in $wanted} {
      lappend types $type
    }
  }
  set references {}
  set prepared [Lookups $gsub $indices $gdef $types references]
  set nested {}
  if {[llength $references]} {
    # THE NESTED LOOKUPS LIVE ONCE, in a dict every lookup carries with it.
    # They are named by index and one of them may be named by hundreds of
    # rules, so putting a copy of the prepared lookup in every rule would turn
    # a face with three thousand references into three thousand coverage
    # tables. The entries INSIDE the map name their own nested lookups by
    # index too and do not carry the map: it is threaded down the recursion in
    # [ApplyRecords], which is the only way a value can refer to itself in Tcl
    # and stay finite.
    set nested [Nested $gsub $gdef $references]
  }
  set result {}
  foreach entry $prepared {
    lappend result [linsert $entry end $nested]
  }
  return $result
}

# One entry {filter subtables} per LOOKUP, in lookup order, and the lookup
# indices the contextual rules among them name.
#
# PER LOOKUP AND NOT PER SUBTABLE, and that distinction is not bookkeeping.
# The specification applies a lookup to one position by trying its subtables
# in order and stopping at the first that applies (S. 217). Reading them as
# separate lookups instead - each walked over the whole run in turn - lets the
# second subtable act on what the first one left, and that is measurably
# wrong: in Amiri the rlig lookup 69 has a subtable that matches the second
# glyph of a word and another that matches the first and substitutes BOTH. Run
# one after the other, the narrow rule fires first and the wide one no longer
# matches, so the initial letter keeps its plain shape. 30 words of 9952
# measured against HarfBuzz on that face, and every one of them this.
#
# A lookup whose type is none of the wanted ones is left out silently rather
# than reported: a feature may well name a lookup this caller cannot use
# beside one it can, and the caller is not thereby wrong about the rest.
proc ::tclpdf::gsubApply::Lookups {gsub indices gdef types referencesName} {
  variable kinds
  variable extensionType
  upvar 1 $referencesName references
  set prepared {}
  foreach entry [::tclpdf::otLayout collectTyped $gsub $indices \
      $types $extensionType] {
    lassign $entry flag markSet typed
    set filter [::tclpdf::gdef filter $gdef $flag $markSet]
    set subtables {}
    # One subtable at a time, and a damaged one costs only itself - the error
    # boundary sits inside the loop, not around the walk.
    foreach pair $typed {
      lassign $pair type offset
      set kind [dict get $kinds $type]
      set rules {}
      if {[::tclpdf::otLayout damaged {
        set rules [Subtable $gsub $kind $offset $rules]
      }]} {
        continue
      }
      if {![dict size $rules]} {
        continue
      }
      if {$kind in {context chain}} {
        lappend references {*}[::tclpdf::gsubContext references $rules]
      }
      lappend subtables [list $kind $rules]
    }
    if {[llength $subtables]} {
      lappend prepared [list $filter $subtables]
    }
  }
  return $prepared
}

# Every lookup the contextual rules can reach, prepared and keyed by its index
# in the lookup list.
#
# A worklist rather than a recursion, and that is not a style choice: a lookup
# may name itself, and a font that does so would take a recursive reader down
# with it. Here the second sight of an index is a dict that already has the
# key, and the walk simply stops.
#
# Every kind is wanted here whatever the caller narrowed the feature to. WANTED
# says which lookups a FEATURE may contribute - liga.tcl takes ligatures alone,
# for the reason given at [MultipleAt] - but a contextual rule that names a
# lookup names it as part of one substitution, and dropping half of it would
# apply the other half on its own.
proc ::tclpdf::gsubApply::Nested {gsub gdef seeds} {
  variable kinds
  set types {}
  foreach {type kind} $kinds {
    lappend types $type
  }
  set nested {}
  set work $seeds
  while {[llength $work]} {
    set index [lindex $work 0]
    set work [lrange $work 1 end]
    if {[dict exists $nested $index]} {
      continue
    }
    set more {}
    # One index, so one lookup or none - and the empty answer is stored too,
    # or a lookup that does not read would be looked for again and again.
    dict set nested $index \
        [lindex [Lookups $gsub [list $index] $gdef $types more] 0]
    lappend work {*}$more
  }
  return $nested
}

# Everything one feature tag needs, from the table to the prepared lookups.
#
# Both callers arrive here by the same three steps - resolve the tag to lookup
# indices, prepare those, and treat a damaged way in as "this face has not got
# it" - and those three steps were the second thing this file had two copies
# of. PREFERRED is the script order otLayout should resolve the tag under: the
# empty list means the Latin one, which is what a caller who does not know the
# script of the text should ask for.
proc ::tclpdf::gsubApply::feature {gsub tag gdef {preferred {}} {wanted {}}} {
  set prepared {}
  if {[::tclpdf::otLayout damaged {
    set indices [::tclpdf::otLayout featureLookups $gsub $tag $preferred]
    set prepared [prepare $gsub $indices $gdef $wanted]
  }]} {
    # The way in is broken - script list or feature list. Nothing to salvage,
    # and the next tag reads them again for itself.
    return {}
  }
  return $prepared
}

# Prepare a SEQUENCE OF STAGES: one entry of [apply]'s shape per stage, in the
# order they run.
#
# A STAGE is what HarfBuzz pauses between, and it is not the same thing as a
# feature. Several features may share one stage - their lookups are then
# applied in the order of the LOOKUP LIST across all of them - and one feature
# may stand in a stage of its own, which beats any lookup index. TAGLISTS is
# therefore a list of tag LISTS, one per stage, and the stage boundaries are
# the caller's decision: liga.tcl and forms.tcl measure them against hb-shape
# for the script they read, and they do not come out the same.
#
# Here rather than in either of them because both walk it, and a walk written
# twice is the walk one of the two gets wrong.
proc ::tclpdf::gsubApply::stages {gsub tagLists gdef {preferred {}} {wanted {}}} {
  set prepared {}
  foreach tags $tagLists {
    lappend prepared [feature $gsub $tags $gdef $preferred $wanted]
  }
  return $prepared
}

# Apply a sequence of stages to a run, in order. A stage that prepared nothing
# costs a call and changes nothing, which is what keeps the caller from having
# to know which of its stages a face actually has.
proc ::tclpdf::gsubApply::applyStages {stages run {tag {}}} {
  foreach stage $stages {
    set run [apply $stage $run $tag]
  }
  return $run
}

# Substitute in a glyph run.
#
# Lookups are applied one after another over the whole run, because the output
# of one may be the input of the next - which is not a subtlety but the way
# Arabic works: ccmp splits a letter into a skeleton and its dots, and the
# positional feature after it substitutes the skeleton.
#
# TAG restricts a lookup to the positions whose entry carries that tag. It is
# what makes "apply fina to the final letters only" possible without a second
# apply engine: the caller marks every position with the one form it needs,
# and each positional feature then sees only its own. An empty tag - the
# ligature case, and everything before this module existed - matches every
# position, including the entries that carry no tag at all.
proc ::tclpdf::gsubApply::apply {prepared run {tag {}}} {
  variable opsFactor
  variable opsFloor
  variable ops
  if {![llength $prepared] || ![llength $run]} {
    return $run
  }
  # A fresh purse for every call, spent by [ApplyLookupAt] - see the head of
  # this file for what it buys and what happens when it is empty.
  set ops [expr {$opsFactor * [llength $run] + $opsFloor}]
  foreach lookup $prepared {
    lassign $lookup filter subtables nested
    set run [ApplyLookup $filter $subtables $nested $run $tag]
  }
  return $run
}

# --- applying ---------------------------------------------------------------

# The glyph number of every entry of a run, which is all any matching needs.
proc ::tclpdf::gsubApply::Glyphs {run} {
  set glyphs {}
  foreach entry $run {
    lappend glyphs [lindex $entry 0]
  }
  return $glyphs
}

# The indices of a glyph list this lookup sees, in order.
#
# A lookup that ignores marks matches f + acute + i as the pair f i, and the
# acute has to be invisible to the match without disappearing from the text.
# Where a filter is absent - the common case - the visible positions are all
# of them and this is the plain walk it was.
# EXEMPT is one position the filter may not hide, or -1 for none - what a
# SequenceLookupRecord needs, and gdef.tcl says in one place what that means
# and why HarfBuzz reads it so.
proc ::tclpdf::gsubApply::Keep {filter glyphs {exempt -1}} {
  return [::tclpdf::gdef visible $filter $glyphs $exempt]
}

# The same, for a caller that has the run rather than its glyphs.
proc ::tclpdf::gsubApply::Visible {filter run {exempt -1}} {
  return [Keep $filter [Glyphs $run] $exempt]
}

# Does this position take part, given the tag the caller restricted to?
proc ::tclpdf::gsubApply::Tagged {entry tag} {
  return [expr {$tag eq {} || [lindex $entry 2] eq $tag}]
}

# Is this glyph one the lookup flag leaves out of the sequence?
proc ::tclpdf::gsubApply::Ignored {filter glyph} {
  return [expr {$filter ne {} && [::tclpdf::gdef ignored $filter $glyph]}]
}

# A new entry that keeps what the old one carried besides its glyph.
#
# The tag travels with every substitution: an entry marked "medi" that ccmp
# splits in two produces two entries marked "medi", so the positional feature
# afterwards still finds the skeleton. Entries WITHOUT a tag stay without one,
# which is what keeps a run built before this existed exactly two elements
# long.
#
# So do the LIGATURE PROPERTIES in the fourth place, for the same reason and
# with the same care: a run that never met a ligature never grows a fourth
# element. See [Ligature] below for what they are.
#
# ONE OPERATION rather than a cascade over the length. The rule is "the first
# two elements are replaced and whatever else the entry carries stays", and
# [lreplace] is that rule; a cascade spells the entry's width out and has to
# be widened by hand every time the entry grows a place - which is how
# [morx Entry3], the same rule on the Apple road, came to be a place behind.
proc ::tclpdf::gsubApply::Entry {source glyph codes} {
  return [lreplace $source 0 1 $glyph $codes]
}

# --- which component of a ligature a mark belongs to -------------------------
#
# ISO/IEC 14496-22:2019 6.3.3, MarkToLigature (S. 225): "For a given mark
# assigned to a particular class, the appropriate base attachment point is
# determined by which ligature component the mark is associated with. ...
# While a text-layout client is performing ... any glyph-substitution
# operations using the GSUB table, the text-layout client must keep track of
# associations of marks to particular ligature-glyph components."
#
# The association is not in the font and cannot be recovered afterwards: it is
# made HERE, when the ligature swallows the components, and the only thing
# that knows it is the substitution that skipped the mark. Without it every
# mark falls on the last component - the fatha of the Arabic lam-alef then
# sits over the alef instead of over the lam, which is 920 font units off in
# Scheherazade New and the ordinary spelling of the word.
#
# So an entry may carry a fourth element, {id component count}, the same three
# numbers HarfBuzz keeps as lig_id/lig_comp/lig_num_comps:
#
#   a LIGATURE glyph carries {id 0 count}: its own identity and how many
#   components it stands for (a ligature of ligatures counts theirs);
#   a MARK skipped inside one carries {id component 1}, the component being
#   1-based and counted the way the specification counts them;
#   everything else carries nothing, and a mark that never met a ligature
#   keeps falling on the last component, which is what it did before.
#
# The ID exists to answer "is this mark's component index about THIS
# ligature": a mark that came out of one ligature and is placed against
# another has an index that means nothing there. markPos.tcl asks exactly
# that.

# The next ligature identity. A counter rather than a position, because a
# position stops identifying anything as soon as the next lookup moves the
# run; it never resets, and it does not have to - two runs of one document
# never meet.
proc ::tclpdf::gsubApply::LigatureId {} {
  variable ligatureSerial
  return [incr ligatureSerial]
}

# How many components an entry stands for: a ligature's own count, and one for
# every other glyph.
proc ::tclpdf::gsubApply::Components {entry} {
  set properties [lindex $entry 3]
  if {[llength $properties] == 3 && [lindex $properties 1] == 0} {
    return [lindex $properties 2]
  }
  return 1
}

# The same entry with these ligature properties.
proc ::tclpdf::gsubApply::Ligature {entry properties} {
  return [list [lindex $entry 0] [lindex $entry 1] [lindex $entry 2] \
      $properties]
}

# --- one lookup, one position -----------------------------------------------
#
# THE PRIMITIVE the rest of this file is built from. Each of these answers the
# same question for one lookup type - given this run and this position, what
# does the run look like afterwards and where does the walk go on - and each
# is asked from two directions:
#
#   an ordinary feature asks at every position in turn ([ApplyLookup]);
#   a SequenceLookupRecord asks at exactly one ([ApplyLookupAt]).
#
# The answer is {run next}, or {} when the lookup does not apply here. NEXT is
# not always one position on and that is the whole reason it is answered
# rather than counted: a Multiple substitution puts several glyphs where one
# stood and none of them is its own input, a ligature takes the glyphs the
# lookup flag skipped along with it, and a contextual rule consumes the whole
# sequence it matched. The run is never empty at a position that exists, so {}
# is free to mean "not here".

proc ::tclpdf::gsubApply::SingleAt {filter rules run position tag {exempt -1}} {
  set entry [lindex $run $position]
  set glyph [lindex $entry 0]
  if {![dict exists $rules $glyph] || ![Tagged $entry $tag]
      || ($position != $exempt && [Ignored $filter $glyph])} {
    return {}
  }
  return [list [lreplace $run $position $position \
      [Entry $entry [dict get $rules $glyph] [lindex $entry 1]]] \
      [expr {$position + 1}]]
}

# Lookup type 2: one glyph becomes a sequence of glyphs.
#
# The FIRST output keeps the characters and the rest get none - giving them to
# all would extract the letter once per glyph. Which one is not in the
# specification, which has no notion of text, so it was measured both ways:
#
#   on the first  the word extracts as one word. pdftotext returns "...".
#   on the last   pdftotext returns the same word with a SPACE inside it. The
#                 last output of such a rule is a mark with a zero advance,
#                 and a reader that finds the text of a run on a glyph that
#                 does not advance takes the gap in front of it for a word
#                 boundary.
#
# So the characters belong on the glyph that carries the advance, which is the
# base, which is the first.
#
# WHAT THAT USED TO COST was a ToUnicode map in which two letters sharing one
# base glyph could not be told apart, and the comment here said it did not
# arise for the faces this package shapes. It arises constantly: Noto Naskh
# Arabic and Noto Sans Arabic write sin and shin, and beh, teh, theh, nun and
# yeh, as one skeleton plus separate dots, so the skeleton carries whichever
# letter used it first and every other reading of it extracted wrongly -
# measured over 89 Arabic words, 49 of them came out as a different word.
# Mark attachment has nothing to do with it: the dots are placed correctly and
# the map is still wrong.
#
# The fix named here has been built and is in font.tcl: a CID of its own per
# glyph-and-characters pair ([FontRunEncode]), which is what CIDToGIDMap is
# for. Nothing about this file changed with it - the characters still go to
# the first output, and the rest still get none.
proc ::tclpdf::gsubApply::MultipleAt {filter rules run position tag {exempt -1}} {
  set entry [lindex $run $position]
  set glyph [lindex $entry 0]
  if {![dict exists $rules $glyph] || ![Tagged $entry $tag]
      || ($position != $exempt && [Ignored $filter $glyph])} {
    return {}
  }
  set outputs {}
  set codes [lindex $entry 1]
  foreach output [dict get $rules $glyph] {
    lappend outputs [Entry $entry $output $codes]
    # All the characters go to the FIRST of the outputs and none to the rest,
    # so that the ToUnicode CMap spells the glyph the reader has to read back.
    #
    # An [if]-less assignment rather than an [expr] ternary: the characters
    # are DATA, and expr parses its operands - the trap that once turned a
    # glyph named "infinity" into Inf. It held here, because a code point
    # list of one integer survives being parsed; it would not have, had the
    # entry carried names.
    set codes {}
  }
  # Past all of them: they are this lookup's output, not its input.
  return [list [lreplace $run $position $position {*}$outputs] \
      [expr {$position + [llength $outputs]}]]
}

# Lookup type 4: several glyphs become one, and that one stands for all their
# characters - which is exactly what the ToUnicode CMap needs later.
#
# The rules of one glyph are tried in the order the font lists them, and that
# order is the font's decision (S. 270).
#
# A skipped glyph is kept and comes out AFTER the ligature. It belonged to the
# first component, and the components no longer exist to attach it to; putting
# it before would move an accent onto the character in front of it.
#
# VISIBLE is passed in by the walk below, which has it already; a
# SequenceLookupRecord has not, and pays for one pass over the run instead.
proc ::tclpdf::gsubApply::LigatureAt {filter rules run start tag {visible {}} \
    {exempt -1}} {
  if {![llength $visible]} {
    set visible [Visible $filter $run $exempt]
  }
  set at [lsearch -exact -integer -sorted $visible $start]
  if {$at < 0} {
    return {}
  }
  set entry [lindex $run $start]
  set glyph [lindex $entry 0]
  if {![dict exists $rules $glyph] || ![Tagged $entry $tag]} {
    return {}
  }
  set seen [llength $visible]
  foreach rule [dict get $rules $glyph] {
    set ligature [lindex $rule 0]
    set following [lrange $rule 1 end]
    set need [llength $following]
    # The rule needs the $need visible entries after this one. A shorter rule
    # further down the list may still fit, so this skips the rule rather than
    # giving up on the glyph.
    if {$at + $need >= $seen} {
      continue
    }
    set parts [lrange $visible $at [expr {$at + $need}]]
    set matched 1
    for {set step 1} {$step <= $need} {incr step} {
      set part [lindex $run [lindex $parts $step]]
      if {[lindex $part 0] ne [lindex $following [expr {$step - 1}]]
          || ![Tagged $part $tag]} {
        set matched 0
        break
      }
    }
    if {!$matched} {
      continue
    }
    # The codes of every component, in order - the ligature stands for all of
    # them, and dropping any would lose that text on extraction. Only the
    # components: a skipped mark keeps its own codes and its own entry.
    set codes {}
    foreach part $parts {
      lappend codes {*}[lindex [lindex $run $part] 1]
    }
    # WHICH COMPONENT each skipped glyph stands behind, recorded now because
    # nothing afterwards can work it out: the components are about to stop
    # existing. Counted the way HarfBuzz counts in [ligate_input] - components
    # seen so far, and a component that is itself a ligature counts all of the
    # ones it stands for, so that a mark inside a ligature of ligatures keeps
    # pointing at the letter it was written after.
    set identity [LigatureId]
    set soFar [Components $entry]
    set previous $soFar
    set marks {}
    set end [lindex $parts end]
    for {set step 1} {$step <= $need} {incr step} {
      for {set index [expr {[lindex $parts [expr {$step - 1}]] + 1}]
           } {$index < [lindex $parts $step]} {incr index} {
        set own [lindex [lindex $run $index] 3 1]
        if {$own eq {} || $own == 0} {
          set own $previous
        }
        dict set marks $index [expr {$soFar - $previous
            + min($own, $previous)}]
      }
      set previous [Components [lindex $run [lindex $parts $step]]]
      incr soFar $previous
    }
    set replacement [list [Ligature [Entry $entry $ligature $codes] \
        [list $identity 0 $soFar]]]
    for {set index $start} {$index <= $end} {incr index} {
      if {$index ni $parts} {
        lappend replacement [Ligature [lindex $run $index] \
            [list $identity [dict get $marks $index] 1]]
      }
    }
    # Past the ligature AND past the glyphs it took along. Those are the ones
    # the lookup flag skipped, so this lookup cannot see them anyway and a
    # step of one would only walk over them - it saves the turns rather than
    # the answer, and that is worth writing down so the next reader does not
    # take it for a rule.
    return [list [lreplace $run $start $end {*}$replacement] \
        [expr {$start + [llength $replacement]}]]
  }
  return {}
}

# Lookup types 5 and 6 at one position: does a rule match here, and what do
# its records make of the run.
#
# NESTED is the map of prepared lookups the records name. It is threaded down
# rather than carried in RULES because the map holds this very entry: a value
# that contained itself would have no end.
proc ::tclpdf::gsubApply::ContextAt {filter rules run position tag nested depth \
    {glyphs {}} {visible {}} {exempt -1}} {
  if {![llength $visible]} {
    set glyphs [Glyphs $run]
    set visible [Keep $filter $glyphs $exempt]
  }
  set at [lsearch -exact -integer -sorted $visible $position]
  if {$at < 0} {
    return {}
  }
  set found [Matched $rules $glyphs $visible $at $run $tag]
  if {$found eq {}} {
    return {}
  }
  lassign $found positions records
  lassign [ApplyRecords $nested $records $positions $run $tag $depth] \
      run positions
  # Past the whole sequence that matched, which is what keeps a rule from
  # matching inside its own output. Where the records changed nothing - a rule
  # may legitimately name no lookup at all - that is still where it goes on.
  return [list $run [expr {[lindex $positions end] + 1}]]
}

# Lookup type 8 at one position: the rule matches with a backtrack and a
# lookahead exactly as a type 6 format 3 rule does, and the substitution is
# not named by a record but written beside the coverage - one glyph per
# coverage index (ISO/IEC 14496-22:2019, 6.3.7, S. 290).
#
# The answer has the shape of the others, {run next}, so that a
# SequenceLookupRecord may name a reverse lookup like any other. NEXT is one
# position on; the backwards walk of [ApplyReverse] ignores it and steps by
# itself, which is the only place the direction of this type shows.
proc ::tclpdf::gsubApply::ReverseAt {filter rules run position tag {exempt -1} \
    {glyphs {}} {visible {}} {at -1}} {
  set entry [lindex $run $position]
  set glyph [lindex $entry 0]
  set substitutes [dict get $rules subst]
  set coverage [dict get $rules coverage]
  if {![dict exists $coverage $glyph] || ![Tagged $entry $tag]} {
    return {}
  }
  set index [dict get $coverage $glyph]
  if {$index >= [llength $substitutes]} {
    # A coverage that lists more glyphs than the substitute array has entries.
    # The specification counts the two together (glyphCount); a face that does
    # not is read as far as it agrees with itself.
    return {}
  }
  if {$at < 0} {
    set glyphs [Glyphs $run]
    set visible [Keep $filter $glyphs $exempt]
    set at [lsearch -exact -integer -sorted $visible $position]
    if {$at < 0} {
      return {}
    }
  }
  if {[Matched $rules $glyphs $visible $at $run $tag] eq {}} {
    return {}
  }
  return [list [lreplace $run $position $position \
      [Entry $entry [lindex $substitutes $index] [lindex $entry 1]]] \
      [expr {$position + 1}]]
}

# What one lookup of any type does at one position.
proc ::tclpdf::gsubApply::SubstituteAt {kind filter rules run position tag \
    nested depth {glyphs {}} {visible {}} {exempt -1}} {
  switch -- $kind {
    single {
      return [SingleAt $filter $rules $run $position $tag $exempt]
    }
    multiple {
      return [MultipleAt $filter $rules $run $position $tag $exempt]
    }
    ligature {
      return [LigatureAt $filter $rules $run $position $tag $visible $exempt]
    }
    context - chain {
      return [ContextAt $filter $rules $run $position $tag $nested $depth \
          $glyphs $visible $exempt]
    }
    reverse {
      # A reverse lookup named by a record is applied at that one position,
      # exactly like the others. The BACKWARDS walk is a property of the
      # lookup applied on its own ([ApplyReverse]), not of one application.
      return [ReverseAt $filter $rules $run $position $tag $exempt]
    }
  }
  return {}
}

# One lookup of the lookup list, applied at one position - what a
# SequenceLookupRecord asks for. The answer is the run alone: where the walk
# would go on is the caller's business only when the caller IS a walk.
proc ::tclpdf::gsubApply::ApplyLookupAt {nested index run position tag depth} {
  variable maxDepth
  variable ops
  # THE TWO BOUNDS, in HarfBuzz's order and with its short circuit: the depth
  # is not paid for out of the work budget, so a lookup that is merely too
  # deeply nested costs nothing ([recurse], hb-ot-layout-gsubgpos.hh).
  if {$depth >= $maxDepth || $ops <= 0 || ![dict exists $nested $index]} {
    return {}
  }
  incr ops -1
  lassign [dict get $nested $index] filter subtables
  foreach subtable $subtables {
    lassign $subtable kind rules
    # THE GLYPH AT THIS POSITION IS EXEMPT from the named lookup's own flag -
    # see [Keep].
    set answer [SubstituteAt $kind $filter $rules $run $position $tag \
        $nested [expr {$depth + 1}] {} {} $position]
    if {$answer ne {}} {
      return [lindex $answer 0]
    }
  }
  return {}
}

# --- what a contextual match then does --------------------------------------

# Does a rule match here, and may this caller act on it?
#
# The tag is asked of the INPUT positions only. Backtrack and lookahead are
# looked at and not touched, and requiring a form tag of them would refuse a
# rule for the company its neighbours keep - "apply fina to the final letter"
# says nothing about what stands before it.
proc ::tclpdf::gsubApply::Matched {rules glyphs visible at run tag} {
  set found [::tclpdf::gsubContext match $rules $glyphs $visible $at]
  if {$found eq {} || $tag eq {}} {
    return $found
  }
  foreach position [lindex $found 0] {
    if {![Tagged [lindex $run $position] $tag]} {
      return {}
    }
  }
  return $found
}

# Apply the records of one match, in order, and say where the input sequence
# ended up: {run positions}.
#
# THE POSITIONS MOVE WHILE THE RECORDS RUN, and that is the whole difficulty
# of this file. A record names a position of the INPUT SEQUENCE - "the third
# glyph of what matched" - but a lookup applied at the first of them may have
# been a ligature that swallowed the second, or a Multiple that put two more
# glyphs in front of it. The specification says the records are applied in
# order and says nothing about the bookkeeping; HarfBuzz is the reference and
# this follows its arithmetic to the line (hb-ot-layout-gsubgpos.hh,
# apply_lookup):
#
#   a run that grew by n is read as n glyphs inserted directly after the
#   position the lookup was applied at, and they JOIN the input sequence;
#   a run that shrank by n is read as n positions after that one removed.
#
# The second reading is the one HarfBuzz itself calls approximate, and it is
# approximate for a reason no shaper can get round: a ligature says which
# glyphs it consumed only by how many are gone. Following it exactly is what
# makes the output agree with HarfBuzz glyph for glyph, which is the only
# oracle there is.
proc ::tclpdf::gsubApply::ApplyRecords {nested records positions run tag depth} {
  set count [llength $positions]
  foreach record $records {
    lassign $record sequence index
    if {$sequence >= $count} {
      continue
    }
    set position [lindex $positions $sequence]
    if {$position >= [llength $run]} {
      # An earlier record removed the glyph this one names. There is nothing
      # left to substitute and the rest of the records still stand.
      continue
    }
    set before [llength $run]
    set changed [ApplyLookupAt $nested $index $run $position $tag $depth]
    if {$changed eq {}} {
      continue
    }
    set run $changed
    set delta [expr {[llength $run] - $before}]
    if {$delta == 0} {
      continue
    }
    set next [expr {$sequence + 1}]
    if {$delta < 0} {
      # Never remove more input positions than there are after this one.
      if {$delta < $next - $count} {
        set delta [expr {$next - $count}]
      }
      set next [expr {$next - $delta}]
    }
    set moved [lrange $positions $next end]
    set positions [lrange $positions 0 [expr {$next - 1}]]
    incr next $delta
    incr count $delta
    while {[llength $positions] < $next} {
      lappend positions 0
    }
    if {[llength $positions] > $next} {
      set positions [lrange $positions 0 [expr {$next - 1}]]
    }
    lappend positions {*}$moved
    # The positions the substitution created run on from the one it was
    # applied at, one glyph each.
    for {set at [expr {$sequence + 1}]} {$at < $next} {incr at} {
      lset positions $at [expr {[lindex $positions [expr {$at - 1}]] + 1}]
    }
    for {set at $next} {$at < $count} {incr at} {
      lset positions $at [expr {[lindex $positions $at] + $delta}]
    }
  }
  return [list $run $positions]
}

# --- one lookup over a whole run --------------------------------------------

# Apply ONE lookup to every position of the run, in order.
#
# THE SUBTABLES ARE TRIED AT EACH POSITION and the first that applies ends the
# lookup for that position (S. 217) - see [Lookups] for the face that made the
# difference measurable. A position no subtable applies at is stepped over;
# one that a subtable applies at goes on where that subtable says, which is
# past its own output and never inside it.
#
# The glyph numbers and the visible positions are worked out once per change
# rather than once per subtable: a face may name two hundred subtables in one
# lookup - Amiri's rlig does - and reading the run for each of them turns a
# word into a walk of its own.
proc ::tclpdf::gsubApply::ApplyLookup {filter subtables nested run tag} {
  # A LOOKUP HAS ONE TYPE, so the first subtable settles the direction of the
  # walk for all of them.
  if {[lindex $subtables 0 0] eq {reverse}} {
    return [ApplyReverse $filter $subtables $run $tag]
  }
  # WHICH POSITIONS THE LOOKUP CAN SEE is a walk over the whole run, and only
  # a lookup that matches a SEQUENCE ever asks: a Single or a Multiple
  # substitution looks at the one glyph it stands on and answers out of its
  # own rules. Working the list out for a lookup that never asks costs a walk
  # per lookup and per substitution - measured, a quarter of the time of a
  # line of Arabic, and liga.tcl asks for nothing but ligatures.
  set sequenced 0
  foreach subtable $subtables {
    if {[lindex $subtable 0] ni {single multiple}} {
      set sequenced 1
      break
    }
  }
  set glyphs {}
  set visible {}
  if {$sequenced} {
    set glyphs [Glyphs $run]
    set visible [Keep $filter $glyphs]
  }
  set at 0
  while {$at < [llength $run]} {
    set applied 0
    foreach subtable $subtables {
      lassign $subtable kind rules
      set answer [SubstituteAt $kind $filter $rules $run $at $tag $nested 0 \
          $glyphs $visible]
      if {$answer eq {}} {
        continue
      }
      lassign $answer run at
      if {$sequenced} {
        set glyphs [Glyphs $run]
        set visible [Keep $filter $glyphs]
      }
      set applied 1
      break
    }
    if {!$applied} {
      incr at
    }
  }
  return $run
}

# Apply ONE reverse chaining lookup to the whole run, from the LAST position
# to the first (S. 290).
#
# The direction is the whole of this type and it is not a nicety: the
# lookahead of a rule has already been substituted by the time the rule is
# tried, which is what lets a face resolve a chain of forms from the end of a
# word backwards. Walking forwards produces plausible glyphs out of the wrong
# rules and says nothing about it.
#
# The glyph list and the visible positions are rebuilt after a substitution
# because a substituted glyph may fall into another GDEF class and the
# backtrack of the positions still to come reads it. It cannot shift anything:
# type 8 puts exactly one glyph where one stood, so the run keeps its length
# and every position keeps its number - which is why this walks the RUN and
# not the visible list, the way HarfBuzz's [apply_backward] walks the buffer.
proc ::tclpdf::gsubApply::ApplyReverse {filter subtables run tag} {
  set glyphs [Glyphs $run]
  set visible [Keep $filter $glyphs]
  for {set position [expr {[llength $run] - 1}]} {$position >= 0} \
      {incr position -1} {
    set at [lsearch -exact -integer -sorted $visible $position]
    if {$at < 0} {
      continue
    }
    foreach subtable $subtables {
      lassign $subtable kind rules
      set answer [ReverseAt $filter $rules $run $position $tag -1 \
          $glyphs $visible $at]
      if {$answer eq {}} {
        continue
      }
      set run [lindex $answer 0]
      set glyphs [Glyphs $run]
      set visible [Keep $filter $glyphs]
      break
    }
  }
  return $run
}

# --- reading the table ------------------------------------------------------

proc ::tclpdf::gsubApply::Subtable {gsub kind offset rules} {
  switch -- $kind {
    single {
      return [SingleSubst $gsub $offset $rules]
    }
    multiple {
      return [MultipleSubst $gsub $offset $rules]
    }
    ligature {
      return [LigatureSubst $gsub $offset $rules]
    }
    context {
      return [::tclpdf::gsubContext read $gsub 5 $offset]
    }
    chain {
      return [::tclpdf::gsubContext read $gsub 6 $offset]
    }
    reverse {
      return [::tclpdf::gsubContext read $gsub 8 $offset]
    }
  }
  return $rules
}

# Lookup type 1, formats 1 and 2 (S. 267-268).
#
# Format 1 adds a CONSTANT to the glyph number, and the specification takes
# that addition modulo 65536 (S. 267). The modulo is the whole of it: with the
# mask in place it makes no difference whether the delta is read signed or
# unsigned, measured - 100 + (-10) and 100 + 65526 are the same glyph. The
# delta is read as signed because that is what the field IS and what makes the
# line readable; what must not go missing is the mask, and without it a
# backwards substitution near glyph 0 produces a negative glyph number.
proc ::tclpdf::gsubApply::SingleSubst {gsub subtable rules} {
  set format [::tclpdf::otLayout u16 $gsub $subtable]
  set coverage [expr {$subtable + [::tclpdf::otLayout u16 $gsub \
      [expr {$subtable + 2}]]}]
  set glyphs [::tclpdf::otLayout coverage $gsub $coverage]
  switch -- $format {
    1 {
      set delta [::tclpdf::otLayout s16 $gsub [expr {$subtable + 4}]]
      dict for {glyph index} $glyphs {
        dict set rules $glyph [expr {($glyph + $delta) & 0xFFFF}]
      }
    }
    2 {
      set count [::tclpdf::otLayout u16 $gsub [expr {$subtable + 4}]]
      dict for {glyph index} $glyphs {
        if {$index >= $count} {
          continue
        }
        dict set rules $glyph [::tclpdf::otLayout u16 $gsub \
            [expr {$subtable + 6 + $index * 2}]]
      }
    }
  }
  return $rules
}

# Lookup type 2, format 1 (S. 268-269).
#
# The sequence table beside a coverage is ordered BY COVERAGE INDEX, which is
# the index the coverage table itself carries and not a running counter - the
# same rule the ligature sets below follow, and for the same reason.
#
# A sequence of length zero is what the specification calls "not supported"
# (S. 269): it would delete the glyph, and with it the characters the glyph
# stands for, which is text lost out of the ToUnicode map for a rule no shaper
# is meant to follow. Such a rule is left out and the glyph stays as it is.
proc ::tclpdf::gsubApply::MultipleSubst {gsub subtable rules} {
  if {[::tclpdf::otLayout u16 $gsub $subtable] != 1} {
    return $rules
  }
  set coverage [expr {$subtable + [::tclpdf::otLayout u16 $gsub \
      [expr {$subtable + 2}]]}]
  set count [::tclpdf::otLayout u16 $gsub [expr {$subtable + 4}]]
  set glyphs [::tclpdf::otLayout coverage $gsub $coverage]
  dict for {glyph index} $glyphs {
    if {$index >= $count} {
      continue
    }
    set sequence [expr {$subtable + [::tclpdf::otLayout u16 $gsub \
        [expr {$subtable + 6 + $index * 2}]]}]
    set length [::tclpdf::otLayout u16 $gsub $sequence]
    if {$length == 0} {
      continue
    }
    set outputs {}
    for {set at 0} {$at < $length} {incr at} {
      lappend outputs [::tclpdf::otLayout u16 $gsub \
          [expr {$sequence + 2 + $at * 2}]]
    }
    dict set rules $glyph $outputs
  }
  return $rules
}

# Lookup type 4, format 1 (S. 270-271).
#
# Coverage lists only the FIRST component of each ligature; the ligature set
# at the same index holds every ligature starting with that glyph, and each
# ligature names the components from the SECOND one onwards - the first is
# already known from the coverage.
proc ::tclpdf::gsubApply::LigatureSubst {gsub subtable rules} {
  if {[::tclpdf::otLayout u16 $gsub $subtable] != 1} {
    return $rules
  }
  set coverage [expr {$subtable + [::tclpdf::otLayout u16 $gsub \
      [expr {$subtable + 2}]]}]
  set setCount [::tclpdf::otLayout u16 $gsub [expr {$subtable + 4}]]
  set glyphs [::tclpdf::otLayout coverage $gsub $coverage]
  # The array beside a coverage table is ordered BY COVERAGE INDEX, not by
  # the order the glyphs happen to come out of the table (ISO/IEC 14496-22,
  # p. 270). The two coincide for a conforming format 2 coverage, whose
  # ranges must be in glyph id order - which is why a running counter worked
  # everywhere it was tried. A font that breaks that rule would get the
  # wrong set silently, so the index the table already carries is used.
  dict for {first index} $glyphs {
    if {$index >= $setCount} {
      continue
    }
    set ligatureSet [expr {$subtable + [::tclpdf::otLayout u16 $gsub \
        [expr {$subtable + 6 + $index * 2}]]}]
    set count [::tclpdf::otLayout u16 $gsub $ligatureSet]
    for {set at 0} {$at < $count} {incr at} {
      set ligature [expr {$ligatureSet + [::tclpdf::otLayout u16 $gsub \
          [expr {$ligatureSet + 2 + $at * 2}]]}]
      set target [::tclpdf::otLayout u16 $gsub $ligature]
      set components [::tclpdf::otLayout u16 $gsub [expr {$ligature + 2}]]
      if {$components < 2} {
        # A "ligature" of one glyph is a single substitution wearing the wrong
        # hat; taking it would silently replace glyphs on its own.
        continue
      }
      set rule [list $target]
      for {set step 1} {$step < $components} {incr step} {
        lappend rule [::tclpdf::otLayout u16 $gsub \
            [expr {$ligature + 2 + $step * 2}]]
      }
      dict lappend rules $first $rule
    }
  }
  return $rules
}

package provide tclpdf::gsubApply 1.3
