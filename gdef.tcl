#
# tclpdf - PDF generation for Tcl
#
# gdef - the glyph classes a lookup flag filters by
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Infrastructure below kernGpos.tcl and liga.tcl, the way otLayout.tcl is.
# GDEF says what a glyph IS - base, ligature or mark - and the lookupFlag of a
# lookup says which of those it wants left out. Neither half is any use alone,
# which is why they meet here.
#
# ISO/IEC 14496-22:2019, S. 161-162: the ignore bits mean "the other glyphs
# must be processed just as though these glyphs were not present". Ignoring a
# glyph is therefore NOT the same as skipping the pair: A + U+0301 + V is the
# pair A V for a lookup that ignores marks, and the acute has to disappear from
# the sequence rather than break it.
#
# Reading GDEF is optional in the sense that a font without it still kerns -
# but only as long as no lookup filters. Measured on the five faces this
# package ships: Roboto and Bitcount set 0x0008 on BOTH of their kerning
# lookups, DejaVu and Niconne on none. So the flag is not exotic, and a reader
# that ignores it loses the kerning of every accented word in half the fonts
# it meets.
#
# What is deliberately NOT read: LigCaretList and the item variation store.
# Carets are a text editor's business - where to put a cursor inside a
# ligature - and a producer that never edits has no use for them.
#

package require Tcl 8.6.11-
package require tclpdf::sfnt 1.0-
package require tclpdf::otLayout 1.0-

namespace eval ::tclpdf::gdef {
  namespace export {[a-z]*}
  namespace ensemble create

  # The glyph classes the specification fixes (S. 203). Only the mark class is
  # named here because it is the only one the filters ask about by name.
  variable markClass 3

  # The lookupFlag bits that need a class to be answered. Everything outside
  # this mask - rightToLeft, and the reserved bits - leaves the sequence alone,
  # and a lookup that sets nothing else needs no GDEF at all.
  variable filterMask 0xFF1E
}

# Read GDEF, or {} when the font has none or it is unusable.
#
# The three parts are read eagerly because a font that carries them is about to
# be asked for every one of them: the class definition on the first filtered
# lookup, the other two only if a flag names them.
proc ::tclpdf::gdef::build {font} {
  set gdef [::tclpdf::sfnt table $font GDEF]
  if {[string length $gdef] < 12} {
    return {}
  }
  set state {}
  set code [catch {
    set version [::tclpdf::otLayout u32 $gdef 0]
    set classOffset [::tclpdf::otLayout u16 $gdef 4]
    set attachOffset [::tclpdf::otLayout u16 $gdef 10]
    # Every offset in this header may be NULL, and a NULL one means the font
    # does not classify that way - not that the table is broken.
    if {$classOffset != 0} {
      dict set state classes [::tclpdf::otLayout classDef $gdef $classOffset]
    }
    if {$attachOffset != 0} {
      dict set state attach [::tclpdf::otLayout classDef $gdef $attachOffset]
    }
    # Mark glyph sets arrived with header 1.2, and their coverage offsets are
    # 32 bit ones counted from the MarkGlyphSets table (S. 206) - the only
    # place in this format where a coverage is not reached through an
    # Offset16.
    if {$version >= 0x00010002} {
      set setsOffset [::tclpdf::otLayout u16 $gdef 12]
      if {$setsOffset != 0} {
        set count [::tclpdf::otLayout u16 $gdef [expr {$setsOffset + 2}]]
        set sets {}
        for {set index 0} {$index < $count} {incr index} {
          set at [::tclpdf::otLayout u32 $gdef \
              [expr {$setsOffset + 4 + $index * 4}]]
          lappend sets [::tclpdf::otLayout coverage $gdef \
              [expr {$setsOffset + $at}]]
        }
        dict set state sets $sets
      }
    }
  } result options]
  if {$code} {
    # A damaged GDEF costs the filtering, not the document: text then comes out
    # as it did before this module existed. Anything that is not a bounds check
    # of otLayout is a mistake in this file and must surface.
    if {[lrange [dict get $options -errorcode] 0 1] eq {TCLPDF LAYOUT}} {
      return {}
    }
    return -options $options $result
  }
  return $state
}

# The filter one lookup needs, or {} when it filters nothing.
#
# The empty answer is the common one and worth its own path: with it the caller
# walks the run exactly as it did before, without asking about a single glyph.
#
# [markSet] is the markFilteringSet field of the lookup header, which is
# present only when flag 0x0010 is set - otLayout hands back {} otherwise.
proc ::tclpdf::gdef::filter {state flag {markSet {}}} {
  variable filterMask
  variable markClass
  if {$state eq {} || !($flag & $filterMask)} {
    return {}
  }
  if {![dict exists $state classes]} {
    # Without a class definition none of the ignore bits can be answered. The
    # specification has the client derive the classes itself in that case
    # (S. 199-200); guessing them here would filter by a rule the font never
    # agreed to, so nothing is filtered instead.
    return {}
  }
  set classes [dict get $state classes]
  set ignore {}
  foreach {bit class} {0x0002 1 0x0004 2 0x0008 3} {
    if {$flag & $bit} {
      lappend ignore $class
    }
  }
  # Precedence, S. 162: a mark filtering set beats markAttachmentType, and
  # ignoreMarks beats both - once every mark is out, no set can bring one back.
  set allowed {}
  if {$markClass ni $ignore} {
    if {($flag & 0x0010) && $markSet ne {}
        && [dict exists $state sets]
        && $markSet < [llength [dict get $state sets]]} {
      set allowed [lindex [dict get $state sets] $markSet]
    } elseif {($flag & 0xFF00) && [dict exists $state attach]} {
      set wanted [expr {($flag & 0xFF00) >> 8}]
      set allowed {}
      dict for {glyph class} [dict get $state attach] {
        if {$class == $wanted} {
          dict set allowed $glyph 1
        }
      }
      # An attachment type no glyph carries would otherwise ignore every mark
      # in the font, which is a reading of the flag no shaper takes.
      if {![dict size $allowed]} {
        return {}
      }
    }
  }
  if {![llength $ignore] && $allowed eq {}} {
    return {}
  }
  return [list $classes $ignore $allowed]
}

# Does this filter leave the glyph out of the sequence?
#
# Called once per glyph per filtered lookup, so it stays a dict lookup and two
# comparisons. Glyphs GDEF does not name are class 0, which no flag filters.
proc ::tclpdf::gdef::ignored {filter glyph} {
  variable markClass
  lassign $filter classes ignore allowed
  set class 0
  if {[dict exists $classes $glyph]} {
    set class [dict get $classes $glyph]
  }
  if {$class in $ignore} {
    return 1
  }
  if {$allowed ne {} && $class == $markClass
      && ![dict exists $allowed $glyph]} {
    return 1
  }
  return 0
}

# The indices of a glyph list this filter keeps, in order.
#
# Both callers need exactly this and neither needs the glyphs themselves - a
# pair is formed between two INDICES, because the amount has to be attributed
# to a gap in the original run afterwards.
proc ::tclpdf::gdef::keep {filter glyphs} {
  set kept {}
  set count [llength $glyphs]
  for {set index 0} {$index < $count} {incr index} {
    if {![ignored $filter [lindex $glyphs $index]]} {
      lappend kept $index
    }
  }
  return $kept
}

# The same, with ONE position the filter may not hide - or -1 for none, which
# is [keep] again.
#
# EXEMPT is what a SequenceLookupRecord needs, in GSUB and in GPOS alike. The
# lookup a record names is applied AT a position the naming rule chose, and
# HarfBuzz applies it there whatever the named lookup's own flag says: the
# flag is asked in [apply_forward] on the outermost level and in [match_input]
# for the FURTHER components of a sequence, never for the glyph the record
# points at ([recurse] reaches [Lookup::dispatch] without going through
# [check_glyph_property]). Forcing the position into the list says that once,
# for both callers - gsubApply.tcl and kernGpos.tcl - rather than twice.
#
# The position goes in IN ORDER, so that everything downstream may go on
# treating the list as sorted: a backtrack walks it backwards and a lookahead
# forwards.
proc ::tclpdf::gdef::visible {filter glyphs {exempt -1}} {
  if {$filter eq {}} {
    # Every index, and the glob pattern that matches anything is how Tcl
    # counts them out without a loop of its own.
    return [lsearch -all $glyphs *]
  }
  set kept [keep $filter $glyphs]
  if {$exempt < 0 || [lsearch -exact -integer -sorted $kept $exempt] >= 0} {
    return $kept
  }
  return [linsert $kept \
      [expr {[lsearch -integer -sorted -bisect $kept $exempt] + 1}] $exempt]
}

# A filter that answers one question: is this glyph a MARK?
#
# gdef has no command of that name and does not need one - a filter built from
# the ignoreMarks bit alone answers it exactly, through the same [ignored]
# every lookup flag goes through. Two callers ask it (markPos.tcl, to find the
# glyph a mark hangs on; kernGpos.tcl, to find the end of a cluster), which is
# why the bit is named here rather than in either of them.
proc ::tclpdf::gdef::marks {state} {
  return [filter $state 0x0008]
}

package provide tclpdf::gdef 1.1
