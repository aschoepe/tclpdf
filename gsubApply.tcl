#
# tclpdf - PDF generation for Tcl
#
# gsubApply - reading and applying the GSUB lookups that are not contextual
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
# THE THREE LOOKUP TYPES THIS READS (ISO/IEC 14496-22:2019, S. 267-272):
#
#   1 Single     one glyph becomes one other glyph
#   2 Multiple   one glyph becomes SEVERAL - the run gets longer
#   4 Ligature   several glyphs become one - the run gets shorter
#
# Types 3 (Alternate), 5, 6, 7 and 8 are not read. 5 and 6 are contextual and
# chaining substitution: they carry their own sequence matching and reference
# other lookups by index, which is a second machine of a size comparable to
# this whole file. What that costs is measured and named where it is felt -
# forms.tcl for the Arabic case.
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
# in [ApplyMultiple]. pdftotext is the only place any of this shows.
#

package require Tcl 8.6.11-
package require tclpdf::otLayout 1.0-
package require tclpdf::gdef 1.0-

namespace eval ::tclpdf::gsubApply {
  namespace export {[a-z]*}
  namespace ensemble create

  # The lookup type numbers this file understands, and the number an extension
  # lookup carries in GSUB - 7 here, where GPOS uses 9. Reading the GPOS number
  # would resolve an offset into the middle of a subtable and hand back
  # plausible nonsense.
  variable kinds {1 single 2 multiple 4 ligature}
  variable extensionType 7
}

# Prepare a list of lookups for [apply].
#
# The result is a list of {kind filter rules}, in lookup order, and it is worth
# keeping: it reads part of the table once for a font that will be asked again
# for every string set in it.
#
# A lookup whose type is none of the three is left out silently rather than
# reported: a feature may well name a chaining lookup beside a plain one, and
# the caller that cannot follow the chain is not thereby wrong about the rest.
#
# WANTED narrows that further to the kinds the caller can use - liga.tcl asks
# for ligatures alone. That is not tidiness: a Multiple substitution in a
# feature meant for typographic ligatures would take one glyph apart into
# several, and the rule about which of them carries the text (see
# [ApplyMultiple]) was measured on cursive faces and holds for those.
proc ::tclpdf::gsubApply::prepare {gsub indices gdef {wanted {}}} {
  variable kinds
  variable extensionType
  set types {}
  foreach {type kind} $kinds {
    if {![llength $wanted] || $kind in $wanted} {
      lappend types $type
    }
  }
  set prepared {}
  foreach entry [::tclpdf::otLayout collectTyped $gsub $indices \
      $types $extensionType] {
    lassign $entry flag markSet typed
    set filter [::tclpdf::gdef filter $gdef $flag $markSet]
    # One lookup at a time, and a damaged one costs only itself - the error
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
      if {[dict size $rules]} {
        lappend prepared [list $kind $filter $rules]
      }
    }
  }
  return $prepared
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
  if {![llength $prepared] || ![llength $run]} {
    return $run
  }
  foreach lookup $prepared {
    lassign $lookup kind filter rules
    switch -- $kind {
      single {
        set run [ApplySingle $filter $rules $run $tag]
      }
      multiple {
        set run [ApplyMultiple $filter $rules $run $tag]
      }
      ligature {
        set run [ApplyLigature $filter $rules $run $tag]
      }
    }
  }
  return $run
}

# --- applying ---------------------------------------------------------------

# The positions of the run this lookup sees, in order.
#
# A lookup that ignores marks matches f + acute + i as the pair f i, and the
# acute has to be invisible to the match without disappearing from the text.
# Where a filter is absent - the common case - the visible positions are all
# of them and this is the plain walk it was.
proc ::tclpdf::gsubApply::Visible {filter run} {
  set count [llength $run]
  if {$filter eq {}} {
    set visible {}
    for {set index 0} {$index < $count} {incr index} {
      lappend visible $index
    }
    return $visible
  }
  set glyphs {}
  foreach entry $run {
    lappend glyphs [lindex $entry 0]
  }
  return [::tclpdf::gdef keep $filter $glyphs]
}

# Does this position take part, given the tag the caller restricted to?
proc ::tclpdf::gsubApply::Tagged {entry tag} {
  return [expr {$tag eq {} || [lindex $entry 2] eq $tag}]
}

# A new entry that keeps what the old one carried besides its glyph.
#
# The tag travels with every substitution: an entry marked "medi" that ccmp
# splits in two produces two entries marked "medi", so the positional feature
# afterwards still finds the skeleton. Entries WITHOUT a tag stay without one,
# which is what keeps a run built before this existed exactly two elements
# long.
proc ::tclpdf::gsubApply::Entry {source glyph codes} {
  if {[llength $source] > 2} {
    return [list $glyph $codes [lindex $source 2]]
  }
  return [list $glyph $codes]
}

# Lookup type 1: one glyph for one glyph, everything else untouched.
proc ::tclpdf::gsubApply::ApplySingle {filter rules run tag} {
  set seen {}
  foreach index [Visible $filter $run] {
    dict set seen $index 1
  }
  set result {}
  set index 0
  foreach entry $run {
    set glyph [lindex $entry 0]
    if {[dict exists $seen $index] && [Tagged $entry $tag]
        && [dict exists $rules $glyph]} {
      lappend result [Entry $entry [dict get $rules $glyph] [lindex $entry 1]]
    } else {
      lappend result $entry
    }
    incr index
  }
  return $result
}

# Lookup type 2: one glyph becomes a sequence of glyphs.
#
# The FIRST output keeps the characters and the rest get none - giving them to
# all would extract the letter once per glyph. Which one is not in the
# specification, which has no notion of text, so it was measured both ways:
#
#   on the first  the word extracts as one word. pdftotext returns "مرحبا".
#   on the last   pdftotext returns "مرح با" - a SPACE inside the word. The
#                 last output of such a rule is a mark with a zero advance,
#                 and a reader that finds the text of a run on a glyph that
#                 does not advance takes the gap in front of it for a word
#                 boundary.
#
# So the characters belong on the glyph that carries the advance, which is the
# base, which is the first. What that costs is a ToUnicode map in which two
# letters sharing one base glyph cannot be told apart - a per-glyph map cannot
# say "these two glyphs together are one letter". It does not arise for the
# faces this package will shape, because a face that writes a letter as a
# shared skeleton plus a separate dot is refused a step earlier: placing that
# dot needs GPOS mark attachment (forms.tcl). The fix, should a face ever need
# it, is a CID of its own per glyph-and-characters pair, which is a change to
# the font writer and not one to make in passing.
proc ::tclpdf::gsubApply::ApplyMultiple {filter rules run tag} {
  set seen {}
  foreach index [Visible $filter $run] {
    dict set seen $index 1
  }
  set result {}
  set index 0
  foreach entry $run {
    set glyph [lindex $entry 0]
    if {[dict exists $seen $index] && [Tagged $entry $tag]
        && [dict exists $rules $glyph]} {
      set sequence [dict get $rules $glyph]
      set first 1
      foreach output $sequence {
        lappend result [Entry $entry $output \
            [expr {$first ? [lindex $entry 1] : {}}]]
        set first 0
      }
    } else {
      lappend result $entry
    }
    incr index
  }
  return $result
}

# Lookup type 4: several glyphs become one, and that one stands for all their
# characters - which is exactly what the ToUnicode CMap needs later.
#
# The run is walked from the left and the first rule that matches wins; the
# rules of one glyph are in the order the font lists them, and that order is
# the font's decision (S. 270).
#
# A skipped glyph is kept and comes out AFTER the ligature. It belonged to the
# first component, and the components no longer exist to attach it to; putting
# it before would move an accent onto the character in front of it.
proc ::tclpdf::gsubApply::ApplyLigature {filter rules run tag} {
  if {[llength $run] < 2} {
    return $run
  }
  set count [llength $run]
  set visible [Visible $filter $run]
  set seen [llength $visible]
  set result {}
  # The first entry not yet handed on. It trails the match position, because a
  # skipped glyph is written out only once it is known whether the ligature in
  # front of it happened.
  set emitted 0
  set at 0
  while {$at < $seen} {
    set start [lindex $visible $at]
    set taken 0
    set glyph [lindex [lindex $run $start] 0]
    if {[dict exists $rules $glyph] && [Tagged [lindex $run $start] $tag]} {
      foreach rule [dict get $rules $glyph] {
        set ligature [lindex $rule 0]
        set following [lrange $rule 1 end]
        set need [llength $following]
        # The rule needs the $need visible entries after this one. A shorter
        # rule further down the list may still fit, so this skips rather than
        # gives up on the glyph.
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
        while {$emitted < $start} {
          lappend result [lindex $run $emitted]
          incr emitted
        }
        # The codes of every component, in order - the ligature stands for all
        # of them, and dropping any would lose that text on extraction. Only
        # the components: a skipped mark keeps its own codes and its own entry.
        set codes {}
        foreach part $parts {
          lappend codes {*}[lindex [lindex $run $part] 1]
        }
        lappend result [Entry [lindex $run $start] $ligature $codes]
        set end [lindex $parts end]
        for {set index $start} {$index <= $end} {incr index} {
          if {$index ni $parts} {
            lappend result [lindex $run $index]
          }
        }
        set emitted [expr {$end + 1}]
        set at [expr {$at + $need + 1}]
        set taken 1
        break
      }
    }
    if {!$taken} {
      incr at
    }
  }
  while {$emitted < $count} {
    lappend result [lindex $run $emitted]
    incr emitted
  }
  return $result
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

package provide tclpdf::gsubApply 1.0
