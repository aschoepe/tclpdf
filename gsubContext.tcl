#
# tclpdf - PDF generation for Tcl
#
# gsubContext - the GSUB lookups that match a SEQUENCE: types 5, 6 and 8
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Infrastructure below gsubApply.tcl, the way otLayout.tcl and gdef.tcl are
# below both of them. ONE topic: given a subtable of lookup type 5 (Contextual
# Substitution), type 6 (Chaining Contextual Substitution) or type 8 (Reverse
# Chaining Contextual Single Substitution), does a rule of it match at this
# position of a glyph run - and if it does, WHICH positions did it match and
# which lookups does it ask for.
#
# It substitutes nothing. That is deliberate and it is what keeps the two
# files apart: a contextual rule does not carry a substitution at all, it
# carries SequenceLookupRecords - "apply lookup 12 at the third glyph of what
# just matched" - and the lookups those name are the ordinary types 1, 2 and 4
# that gsubApply.tcl already applies. Reading the match here and applying it
# there is the division that keeps either file from holding both halves.
#
# THE SIX FORMATS (ISO/IEC 14496-22:2019, 6.3.5 and 6.3.6, S. 272-289), and
# what they have in common once read:
#
#   5.1  the sequence is written out as GLYPH IDs
#   5.2  as CLASS numbers out of one ClassDef
#   5.3  as one COVERAGE table per position
#   6.1  as glyph IDs, with a backtrack and a lookahead beside the input
#   6.2  as class numbers, with THREE ClassDefs - backtrack, input, lookahead
#   6.3  as coverage tables, three arrays of them
#   8.1  as coverage tables like 6.3, but with ONE input position and the
#        substitutes written beside it instead of records
#
# The three ways of saying "this position matches" are the whole difference.
# Everything else - a coverage that selects which rules to try, rules tried in
# the order the font lists them, a first-glyph position that the coverage has
# already matched - is the same in all six, so they are read into one shape
# and matched by one walk. The shape is described at [read].
#
# THE BACKTRACK RUNS BACKWARDS. Its array is in the order "nearest the input
# first", which is the reverse of text order (S. 280). Reading it forwards
# matches the right glyphs in the wrong places and is silent about it: a rule
# with a one-glyph backtrack behaves identically either way, and those are the
# rules a first test tends to use.
#
# TYPE 8 IS THE SEVENTH FORMAT of the same idea and is read here since
# 2026-08-26. It writes its three arrays exactly as 6.3 does, with one
# difference in each direction: the input is a SINGLE coverage - the one in
# the header, which is why the rule below has an empty input list - and there
# are no SequenceLookupRecords at all. What stands where they would is a
# counted array of substitute glyph IDs, one per coverage index, and the
# caller reads it out of the "subst" field. The other half of the type, that
# the lookup is applied from the END of the run backwards, is a property of
# the WALK and belongs to gsubApply.tcl; nothing here needs to know it.
#
# No face in this tree carries one - measured over the 77 faces in
# examples/assets/fonts and the six fetched to measure this work against
# (Amiri, Noto Kufi Arabic, Noto Nastaliq Urdu, Noto Sans Arabic, Scheherazade
# New, Noto Sans Hebrew) - which is why it went unread for so long. A face
# that has one was shaped differently from every other reader and said nothing
# about it, and that is the reason it is read now rather than counted again.
#
# Type 3, Alternate Substitution, is the case that stays unread: it occurs 39
# times in the tree and every one of them hangs off "aalt" or "ornm", features
# this package does not apply and could not apply without an API for "give me
# the third alternate of this glyph". Measured 2026-08-26.
#

package require Tcl 8.6.11-
package require tclpdf::otLayout 1.0-

namespace eval ::tclpdf::gsubContext {
  namespace export {[a-z]*}
  namespace ensemble create
}

# --- reading a subtable -----------------------------------------------------

# Read one type 5 or type 6 subtable into the shape [match] walks, or {} when
# the format is none of the three the specification defines for that type.
#
# THE SHAPE, and the reason all six formats end up in it:
#
#   style     glyph | class | coverage - how one position is tested
#   coverage  the glyphs that may START a match, as a dict glyph -> index
#   by        index | class - what selects the rule set for a first glyph
#   sets      dict key -> list of rules, where key is the coverage index
#             (by index) or the class of the first glyph (by class)
#   rules     the rules of a format that has exactly one set (style coverage)
#   inputDef, backDef, aheadDef   the ClassDefs of style class
#   refs      every lookup index the records of this subtable name
#
# and one RULE is {backtrack input lookahead records}, where
#
#   backtrack  positions before the match, NEAREST FIRST as the font writes
#              them - see the note at the head of this file
#   input      positions 2..n of the match. The first is not in the list
#              because the coverage has already matched it, which is how the
#              font writes it too (S. 274) and the one place where leaving
#              the format alone is simpler than normalising it
#   lookahead  positions after the match, in text order
#   records    {sequenceIndex lookupListIndex} pairs, in the order the font
#              lists them - which is the order they must be applied in
#
# A type 5 subtable has no backtrack and no lookahead and gets two empty
# lists, so that one matcher serves both types.
proc ::tclpdf::gsubContext::read {gsub type offset} {
  set format [::tclpdf::otLayout u16 $gsub $offset]
  if {$type == 5} {
    switch -- $format {
      1 { return [Format1 $gsub $offset 0] }
      2 { return [Format2 $gsub $offset 0] }
      3 { return [Format3 $gsub $offset 0] }
    }
  } elseif {$type == 6} {
    switch -- $format {
      1 { return [Format1 $gsub $offset 1] }
      2 { return [Format2 $gsub $offset 1] }
      3 { return [Format3 $gsub $offset 1] }
    }
  } elseif {$type == 8} {
    if {$format == 1} {
      return [Reverse $gsub $offset]
    }
  }
  return {}
}

# The lookup indices this subtable's records name, so the caller can prepare
# them before the first string is set. Kept as a field rather than recomputed:
# the caller needs the closure over them and would otherwise walk every rule
# of every subtable a second time to get it.
proc ::tclpdf::gsubContext::references {ruleset} {
  if {![dict exists $ruleset refs]} {
    return {}
  }
  return [dict get $ruleset refs]
}

# Formats 5.1 and 6.1: the sequence is written out as glyph IDs, and the
# coverage index of the first glyph selects the rule set.
proc ::tclpdf::gsubContext::Format1 {gsub offset chained} {
  set coverage [::tclpdf::otLayout coverage $gsub \
      [expr {$offset + [::tclpdf::otLayout u16 $gsub [expr {$offset + 2}]]}]]
  set count [::tclpdf::otLayout u16 $gsub [expr {$offset + 4}]]
  set sets {}
  set refs {}
  for {set index 0} {$index < $count} {incr index} {
    set at [::tclpdf::otLayout u16 $gsub [expr {$offset + 6 + $index * 2}]]
    if {$at == 0} {
      # A NULL rule set offset means "no rule begins with the glyph at this
      # coverage index", which is a thing fonts write rather than a defect.
      continue
    }
    set rules [RuleSet $gsub [expr {$offset + $at}] $chained refs]
    if {[llength $rules]} {
      dict set sets $index $rules
    }
  }
  return [dict create style glyph coverage $coverage by index sets $sets \
      refs [lsort -integer -unique $refs]]
}

# Formats 5.2 and 6.2: the sequence is written as class numbers, and the CLASS
# of the first glyph selects the rule set - not its coverage index. The
# coverage still has to contain the glyph: it is what says a match may begin
# here at all, and a face regularly gives a class to glyphs the coverage does
# not list (they occur in the backtrack of a rule and nowhere else).
#
# Type 6 has three ClassDefs and type 5 has one. The other two are read as
# empty for type 5, which costs nothing: a type 5 rule has no backtrack and no
# lookahead to test with them.
proc ::tclpdf::gsubContext::Format2 {gsub offset chained} {
  set coverage [::tclpdf::otLayout coverage $gsub \
      [expr {$offset + [::tclpdf::otLayout u16 $gsub [expr {$offset + 2}]]}]]
  set backDef {}
  set aheadDef {}
  if {$chained} {
    set backDef [ClassDef $gsub $offset 4]
    set inputDef [ClassDef $gsub $offset 6]
    set aheadDef [ClassDef $gsub $offset 8]
    set countAt [expr {$offset + 10}]
    set arrayAt [expr {$offset + 12}]
  } else {
    set inputDef [ClassDef $gsub $offset 4]
    set countAt [expr {$offset + 6}]
    set arrayAt [expr {$offset + 8}]
  }
  set count [::tclpdf::otLayout u16 $gsub $countAt]
  set sets {}
  set refs {}
  for {set class 0} {$class < $count} {incr class} {
    set at [::tclpdf::otLayout u16 $gsub [expr {$arrayAt + $class * 2}]]
    if {$at == 0} {
      continue
    }
    set rules [RuleSet $gsub [expr {$offset + $at}] $chained refs]
    if {[llength $rules]} {
      dict set sets $class $rules
    }
  }
  return [dict create style class coverage $coverage by class sets $sets \
      inputDef $inputDef backDef $backDef aheadDef $aheadDef \
      refs [lsort -integer -unique $refs]]
}

# One of the ClassDef offsets of a format 2 subtable, or an empty definition
# when the offset is NULL - which puts every glyph in class 0, and is how a
# chaining rule with no backtrack conditions is written.
proc ::tclpdf::gsubContext::ClassDef {gsub offset at} {
  set relative [::tclpdf::otLayout u16 $gsub [expr {$offset + $at}]]
  if {$relative == 0} {
    return {}
  }
  return [::tclpdf::otLayout classDef $gsub [expr {$offset + $relative}]]
}

# Formats 5.3 and 6.3: one coverage table per position and exactly ONE rule,
# written into the subtable itself rather than into a rule set. The first
# input coverage does double duty here - it is both "may a match begin here"
# and the first position of the sequence - so it is lifted out to where the
# other formats keep theirs and the rest stay in the rule.
#
# A subtable with no input coverage at all matches nothing and is left out: it
# would otherwise match at EVERY position and apply its records to a sequence
# of length zero.
proc ::tclpdf::gsubContext::Format3 {gsub offset chained} {
  set refs {}
  if {$chained} {
    # 6.3 writes each array as a count followed by its offsets, three times
    # over, and the record count last.
    set at [expr {$offset + 2}]
    lassign [Coverages $gsub $offset $at] backtrack at
    lassign [Coverages $gsub $offset $at] input at
    lassign [Coverages $gsub $offset $at] lookahead at
    set records [Records $gsub $at refs]
  } else {
    # 5.3 PUTS BOTH COUNTS FIRST and the one coverage array after them, which
    # is not the shape 6.3 has and not the shape it looks like at a glance.
    # Read as though it were 6.3 it takes the record count for the first
    # coverage offset: measured on Noto Naskh Arabic, that turns the two type
    # 5 subtables of its rlig feature into rules over glyphs the face never
    # meant, and the lam-alef pair it is supposed to select comes out
    # unshaped.
    set count [::tclpdf::otLayout u16 $gsub [expr {$offset + 2}]]
    set lookupCount [::tclpdf::otLayout u16 $gsub [expr {$offset + 4}]]
    lassign [CoverageArray $gsub $offset [expr {$offset + 6}] $count] input at
    set backtrack {}
    set lookahead {}
    set records [RecordList $gsub $at $lookupCount refs]
  }
  if {![llength $input]} {
    return {}
  }
  set rule [list $backtrack [lrange $input 1 end] $lookahead $records]
  return [dict create style coverage coverage [lindex $input 0] \
      by rules rules [list $rule] refs [lsort -integer -unique $refs]]
}

# A counted array of coverage offsets, and where the next field starts.
proc ::tclpdf::gsubContext::Coverages {gsub offset at} {
  set count [::tclpdf::otLayout u16 $gsub $at]
  return [CoverageArray $gsub $offset [expr {$at + 2}] $count]
}

# The same where the count was read somewhere else - which is where 5.3 keeps
# it. The offsets are relative to the SUBTABLE and not to the array, which is
# why the subtable offset travels alongside the array offset.
proc ::tclpdf::gsubContext::CoverageArray {gsub offset at count} {
  set coverages {}
  for {set index 0} {$index < $count} {incr index} {
    lappend coverages [::tclpdf::otLayout coverage $gsub \
        [expr {$offset + [::tclpdf::otLayout u16 $gsub $at]}]]
    incr at 2
  }
  return [list $coverages $at]
}

# Format 8.1 (S. 290): the backtrack and the lookahead of 6.3, ONE input
# position - the coverage in the header - and a counted array of substitute
# glyph IDs where the other formats keep their records.
#
# It comes back in the same shape as the rest so that one matcher serves it
# too: style coverage, one rule with an empty input list, and the substitutes
# in a field of their own. The rule therefore matches exactly the covered
# glyph plus its surroundings, which is what the type says.
#
# A subtable whose substitute array is shorter than its coverage is read as
# far as the two agree - the caller checks the index before it reaches into
# the array. Both counts are written down by the font (glyphCount is the
# length of BOTH), so a mismatch is a defect and not a shape to guess at.
proc ::tclpdf::gsubContext::Reverse {gsub offset} {
  set coverage [::tclpdf::otLayout coverage $gsub \
      [expr {$offset + [::tclpdf::otLayout u16 $gsub [expr {$offset + 2}]]}]]
  if {![dict size $coverage]} {
    return {}
  }
  set at [expr {$offset + 4}]
  lassign [Coverages $gsub $offset $at] backtrack at
  lassign [Coverages $gsub $offset $at] lookahead at
  lassign [Values $gsub $at] substitutes at
  if {![llength $substitutes]} {
    return {}
  }
  return [dict create style coverage coverage $coverage by rules \
      rules [list [list $backtrack {} $lookahead {}]] subst $substitutes \
      refs {}]
}

# Every rule of one rule set, in the order the font lists them - which is the
# order they are tried in, and the font's decision (S. 274).
proc ::tclpdf::gsubContext::RuleSet {gsub offset chained refsName} {
  upvar 1 $refsName refs
  set count [::tclpdf::otLayout u16 $gsub $offset]
  set rules {}
  for {set index 0} {$index < $count} {incr index} {
    set at [::tclpdf::otLayout u16 $gsub [expr {$offset + 2 + $index * 2}]]
    if {$at == 0} {
      continue
    }
    set rule [Rule $gsub [expr {$offset + $at}] $chained refs]
    if {[llength $rule]} {
      lappend rules $rule
    }
  }
  return $rules
}

# One rule of a format 1 or format 2 rule set. The two layouts differ only in
# what the numbers MEAN - glyph IDs there, class numbers here - which is why
# one reader serves both and the style is decided by the caller.
#
# The input count includes the first position and the array does not, so a
# count of zero is a rule that matches nothing and is left out. A count of one
# is a rule whose input is the covered glyph alone, which is legitimate and
# common in a chaining lookup: everything it tests is in the backtrack and the
# lookahead.
proc ::tclpdf::gsubContext::Rule {gsub offset chained refsName} {
  upvar 1 $refsName refs
  # THE TWO TYPES DO NOT WRITE A RULE THE SAME WAY, and the difference is not
  # only which numbers stand there. A ChainedSequenceRule interleaves each
  # count with its array; a SequenceRule puts BOTH of its counts first and the
  # input array after them (S. 273 and S. 280). One reader for both, in the
  # chained order, reads the record count of a type 5 rule as its first input
  # glyph - and every field after that at the wrong offset.
  #
  # The other asymmetry is shared: the input count counts the first position
  # and the array leaves it out, because the coverage has already matched that
  # one. A count of zero is therefore a rule that matches nothing at all and
  # is dropped; a count of one is a rule whose input is the covered glyph
  # alone, which is legitimate and common in a chaining lookup - everything it
  # tests is in the backtrack and the lookahead.
  if {$chained} {
    set at $offset
    lassign [Values $gsub $at] backtrack at
    lassign [Input $gsub $at] input at
    if {$input eq {none}} {
      return {}
    }
    lassign [Values $gsub $at] lookahead at
    set records [Records $gsub $at refs]
    return [list $backtrack $input $lookahead $records]
  }
  set count [::tclpdf::otLayout u16 $gsub $offset]
  if {$count == 0} {
    return {}
  }
  set lookupCount [::tclpdf::otLayout u16 $gsub [expr {$offset + 2}]]
  set at [expr {$offset + 4}]
  set input {}
  for {set step 1} {$step < $count} {incr step} {
    lappend input [::tclpdf::otLayout u16 $gsub $at]
    incr at 2
  }
  return [list {} $input {} [RecordList $gsub $at $lookupCount refs]]
}

# The input array of a chained rule, and where the next field starts. The
# answer is "none" for a count of zero, which is a rule the caller drops - an
# empty list cannot say that, because a count of one has an empty array too.
proc ::tclpdf::gsubContext::Input {gsub at} {
  set count [::tclpdf::otLayout u16 $gsub $at]
  incr at 2
  if {$count == 0} {
    return [list none $at]
  }
  set values {}
  for {set step 1} {$step < $count} {incr step} {
    lappend values [::tclpdf::otLayout u16 $gsub $at]
    incr at 2
  }
  return [list $values $at]
}

# A counted array of 16 bit values, and where the next field starts.
proc ::tclpdf::gsubContext::Values {gsub at} {
  set count [::tclpdf::otLayout u16 $gsub $at]
  incr at 2
  set values {}
  for {set index 0} {$index < $count} {incr index} {
    lappend values [::tclpdf::otLayout u16 $gsub $at]
    incr at 2
  }
  return [list $values $at]
}

# The SequenceLookupRecords at the end of a rule: {sequenceIndex lookupIndex}
# pairs in the order the font lists them, which is the order they are applied
# in (S. 273). The indices are collected as they are read so that the caller
# can prepare the lookups they name.
proc ::tclpdf::gsubContext::Records {gsub at refsName} {
  upvar 1 $refsName refs
  return [RecordList $gsub [expr {$at + 2}] \
      [::tclpdf::otLayout u16 $gsub $at] refs]
}

# The same where the count was read somewhere else - which is where the type 5
# formats keep it.
proc ::tclpdf::gsubContext::RecordList {gsub at count refsName} {
  upvar 1 $refsName refs
  set records {}
  for {set index 0} {$index < $count} {incr index} {
    set sequence [::tclpdf::otLayout u16 $gsub $at]
    set lookup [::tclpdf::otLayout u16 $gsub [expr {$at + 2}]]
    lappend records [list $sequence $lookup]
    lappend refs $lookup
    incr at 4
  }
  return $records
}

# --- matching ---------------------------------------------------------------

# Does a rule of this subtable match here?
#
# GLYPHS is the glyph number of every entry of the run, VISIBLE the indices of
# the positions this lookup can see - the lookupFlag has already had its say -
# and AT the index WITHIN VISIBLE of the position to try. The answer is
#
#   {positions records}
#
# with positions the run indices of the input sequence, in order, or {} when
# no rule matches. The caller applies the records; nothing here changes a
# glyph.
#
# The positions come back rather than a length because the input is counted in
# VISIBLE positions and applied at RUN positions, and a mark between two
# letters makes those two different numbers. Handing back the length would
# have every caller do that conversion again.
proc ::tclpdf::gsubContext::match {ruleset glyphs visible at} {
  set start [lindex $visible $at]
  set glyph [lindex $glyphs $start]
  set coverage [dict get $ruleset coverage]
  if {![dict exists $coverage $glyph]} {
    return {}
  }
  switch -- [dict get $ruleset by] {
    index {
      set key [dict get $coverage $glyph]
      if {![dict exists [dict get $ruleset sets] $key]} {
        return {}
      }
      set rules [dict get [dict get $ruleset sets] $key]
    }
    class {
      set key [Class [dict get $ruleset inputDef] $glyph]
      if {![dict exists [dict get $ruleset sets] $key]} {
        return {}
      }
      set rules [dict get [dict get $ruleset sets] $key]
    }
    default {
      set rules [dict get $ruleset rules]
    }
  }
  set style [dict get $ruleset style]
  set inputDef {}
  set backDef {}
  set aheadDef {}
  if {$style eq {class}} {
    set inputDef [dict get $ruleset inputDef]
    set backDef [dict get $ruleset backDef]
    set aheadDef [dict get $ruleset aheadDef]
  }
  set seen [llength $visible]
  foreach rule $rules {
    lassign $rule backtrack input lookahead records
    # The input first, because it is what fails most often and costs least:
    # every rule of a set shares the first glyph, so the sequence after it is
    # the first thing that can tell them apart. A rule that would reach past
    # the end of the run cannot match, and a shorter rule further down the
    # list may still fit - so this skips the rule rather than the position.
    set need [llength $input]
    if {$at + $need >= $seen} {
      continue
    }
    set positions [list $start]
    set matched 1
    for {set step 1} {$step <= $need} {incr step} {
      set index [lindex $visible [expr {$at + $step}]]
      if {![Test $style [lindex $input [expr {$step - 1}]] \
          [lindex $glyphs $index] $inputDef]} {
        set matched 0
        break
      }
      lappend positions $index
    }
    if {!$matched} {
      continue
    }
    # THE BACKTRACK RUNS BACKWARDS: its first entry is the position directly
    # in front of the match, its second the one before that.
    set step 1
    foreach value $backtrack {
      set before [expr {$at - $step}]
      if {$before < 0} {
        set matched 0
        break
      }
      if {![Test $style $value [lindex $glyphs [lindex $visible $before]] \
          $backDef]} {
        set matched 0
        break
      }
      incr step
    }
    if {!$matched} {
      continue
    }
    set step [expr {$at + $need + 1}]
    foreach value $lookahead {
      if {$step >= $seen} {
        set matched 0
        break
      }
      if {![Test $style $value [lindex $glyphs [lindex $visible $step]] \
          $aheadDef]} {
        set matched 0
        break
      }
      incr step
    }
    if {$matched} {
      return [list $positions $records]
    }
  }
  return {}
}

# Does one position of a rule match one glyph? The three styles are the three
# ways a font can say what it wants there and the only difference between the
# six formats.
proc ::tclpdf::gsubContext::Test {style value glyph classes} {
  switch -- $style {
    glyph {
      return [expr {$glyph == $value}]
    }
    class {
      return [expr {[Class $classes $glyph] == $value}]
    }
    coverage {
      return [dict exists $value $glyph]
    }
  }
  return 0
}

# The class of a glyph. Everything a ClassDef does not name is class 0, which
# is not "no class" but a class rules match on - the one that means "any glyph
# the font did not single out".
proc ::tclpdf::gsubContext::Class {classes glyph} {
  if {[dict exists $classes $glyph]} {
    return [dict get $classes $glyph]
  }
  return 0
}

package provide tclpdf::gsubContext 1.1
