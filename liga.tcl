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
# The walk to the lookups is shared with kerning and lives in otLayout.tcl.
# What stays here is lookup type 4, which the specification describes as
# "Replace multiple glyphs with one glyph" (ISO/IEC 14496-22:2019, S. 266).
#
# That sentence is the whole difficulty. Everywhere else in this package a
# character has a glyph and a glyph has a character; a ligature breaks that in
# both directions - three characters become one glyph, and that glyph has to
# map back to three characters or the text stops being copyable. The glyph run
# is therefore built ONCE, in font.tcl, and carries with every glyph the
# characters it stands for.
#
# ONLY the "liga" feature is read: standard ligatures, which the registry has
# on by default. Not read, and each for a reason:
#
#   rlig  required ligatures - Arabic lam-alef and relatives. Reading them
#         without cursive joining and reordering would be half a shaper, and
#         half a shaper sets Arabic wrongly with more confidence than none.
#   dlig  discretionary, hlig historical - both off by default in the
#         registry, so a writer that switched them on would be overruling the
#         type designer rather than following them.
#   clig  contextual ligatures - lookup types 5 to 8, a different mechanism.
#
# The ligatures of one glyph are tried in the order the font lists them, and
# that order is the font's decision, not a rule of the format. The
# specification says only "The order in the Ligature offset array defines the
# preference for using the ligatures" and offers ffl-before-ff as an example,
# conditional on ffl being preferable (S. 270). So the list is walked as it
# stands and never sorted - sorting it would overrule the type designer.
#

package require Tcl 8.6.11-
package require tclpdf::sfnt 1.0-
package require tclpdf::otLayout 1.0-
package require tclpdf::gdef 1.0-

namespace eval ::tclpdf::liga {
  namespace export {[a-z]*}
  namespace ensemble create

  # Ligature substitution, and the number an extension lookup carries in GSUB
  # - 7 here, where GPOS uses 9. Reading the GPOS number would resolve an
  # offset into the middle of a subtable and hand back plausible nonsense.
  variable ligatureType 4
  variable extensionType 7
}

# Prepare a font for ligature substitution. The result is handed to [apply]
# and is worth keeping: it walks the whole table once.
#
# Shape: a list of lookups, each {filter rules}, where rules is a dict of first
# glyph -> list of rules, each rule {ligatureGlyph followingGlyph ...}. The
# rules of one glyph stay in font order, and the filter is {} for a lookup that
# ignores nothing.
proc ::tclpdf::liga::build {font} {
  set gsub [::tclpdf::sfnt table $font GSUB]
  if {$gsub eq {}} {
    return {}
  }
  if {[::tclpdf::otLayout damaged {
      set indices [::tclpdf::otLayout featureLookups $gsub liga]}]} {
    # The way in is broken - script list or feature list. Nothing to salvage.
    return {}
  }
  return [Collect $gsub $indices [::tclpdf::gdef build $font]]
}

# Substitute in a glyph run.
#
# The run is a list of entries {glyph codes}, where codes are the character
# code points that glyph stands for. A ligature replaces several entries by
# one whose codes are all of theirs, in order - which is exactly what the
# ToUnicode CMap needs later.
#
# Lookups are applied one after another over the whole run, because the output
# of one may be the input of the next. Within one lookup the run is walked
# from the left and the first rule that matches wins.
proc ::tclpdf::liga::apply {prepared run} {
  if {![llength $prepared] || [llength $run] < 2} {
    return $run
  }
  foreach lookup $prepared {
    lassign $lookup filter rules
    set run [ApplyOne $filter $rules $run]
  }
  return $run
}

# One lookup over the whole run.
#
# The run is walked through the POSITIONS this lookup sees: a lookup that
# ignores marks matches f + acute + i as the pair f i, and the acute has to be
# invisible to the match without disappearing from the text. Where a filter is
# absent - the common case, and every lookup of the faces this package ships -
# the visible positions are all of them and this is the plain walk it was.
#
# A skipped glyph is kept and comes out AFTER the ligature. It belonged to the
# first component, and the components no longer exist to attach it to; putting
# it before would move an accent onto the character in front of it.
proc ::tclpdf::liga::ApplyOne {filter rules run} {
  set count [llength $run]
  if {$filter eq {}} {
    set visible {}
    for {set index 0} {$index < $count} {incr index} {
      lappend visible $index
    }
  } else {
    set glyphs {}
    foreach entry $run {
      lappend glyphs [lindex $entry 0]
    }
    set visible [::tclpdf::gdef keep $filter $glyphs]
  }
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
    if {[dict exists $rules $glyph]} {
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
          if {[lindex [lindex $run [lindex $parts $step]] 0]
              ne [lindex $following [expr {$step - 1}]]} {
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
        lappend result [list $ligature $codes]
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

# --- reading the table -----------------------------------------------------

# One lookup at a time, and a damaged one costs only itself - the error
# boundary sits inside the loop, not around the walk.
proc ::tclpdf::liga::Collect {gsub indices gdef} {
  variable ligatureType
  variable extensionType
  set prepared {}
  foreach entry [::tclpdf::otLayout collect $gsub $indices $ligatureType \
      $extensionType] {
    lassign $entry flag markSet offsets
    set rules {}
    if {[::tclpdf::otLayout damaged {
      foreach offset $offsets {
        set rules [LigatureSubst $gsub $offset $rules]
      }
    }]} {
      continue
    }
    if {[dict size $rules]} {
      lappend prepared [list [::tclpdf::gdef filter $gdef $flag $markSet] \
          $rules]
    }
  }
  return $prepared
}

# Lookup type 4, format 1 (S. 270-271).
#
# Coverage lists only the FIRST component of each ligature; the ligature set
# at the same index holds every ligature starting with that glyph, and each
# ligature names the components from the SECOND one onwards - the first is
# already known from the coverage.
proc ::tclpdf::liga::LigatureSubst {gsub subtable rules} {
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

package provide tclpdf::liga 1.1
