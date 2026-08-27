#
# tclpdf - PDF generation for Tcl
#
# morx - the AAT glyph metamorphosis table
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Infrastructure below colorFont.tcl, exactly where gsubApply.tcl sits: it
# takes a glyph run and gives back a glyph run, it knows the file format and
# nothing about PDF, and the decision of WHEN to use it stays with the caller.
#
# WHY IT EXISTS. A colour font builds one Type 3 glyph per character SEQUENCE,
# and which characters form a sequence is a property of the FACE. On an
# OpenType face that property is in GSUB and gsubApply.tcl reads it. On an
# APPLE face there is no GSUB at all: Apple Color Emoji, 192 MB and 3844
# glyphs, carries no GSUB and forms its sequences in "morx", and without that
# the six characters of a family emoji reach the font as six pictures instead
# of one. It is not the only layout table it carries, and saying so used to
# mislead: measured over its table directory, face 0 also has GPOS (1086
# bytes, a "mark" feature with one MarkBasePos lookup, which stacks the second
# half of a two-glyph sequence on the first - colorFont.tcl reads it), GDEF,
# "trak", "feat", "meta" and "bgcl", and face 1 a "cntr" beside them.
#
# MEASURED 2026-08-26 on /System/Library/Fonts/Apple Color Emoji.ttc, face 0:
# no GSUB table; one morx chain with 13 feature entries and 25 subtables, of
# which 16 are on by default - thirteen ligature subtables, two contextual and
# one noncontextual. The rearrangement and insertion subtables of that face
# are all behind features that are off by default. Both kinds are read here
# all the same, because a chain is applied in ORDER and a reader that skips a
# kind it has not built gives the wrong answer for the ones after it.
#
# WHAT AAT IS AND WHY IT LOOKS NOTHING LIKE GSUB. OpenType layout matches
# PATTERNS: a coverage table says where a rule may start and the rule lists
# what has to follow. AAT runs a FINITE STATE MACHINE over the glyphs: every
# glyph is put into a class, the class and the current state index a table of
# entries, and an entry says what to do and which state to go to next. There
# is no rule to read out of the file - the rules ARE the state table, and the
# only way to know what a face does is to run it.
#
# THE FIVE SUBTABLE TYPES (Apple, "TrueType Reference Manual", morx):
#
#   0 Rearrangement   moves up to two glyphs from each end of a marked range
#                     to the other end, optionally reversing them - sixteen
#                     verbs, and Indic reordering is what they are for
#   1 Contextual      substitutes the current glyph, the MARKED glyph, or
#                     both, through a lookup named by the entry
#   2 Ligature        several glyphs become one, driven by a stack of marked
#                     positions and a list of ligature ACTIONS
#   4 Noncontextual   a plain lookup applied to every glyph, no state at all
#   5 Insertion       puts up to 31 glyphs in front of or behind the current
#                     or the marked position
#
# Type 3 does not exist. The numbers are the format's.
#
# THE ORACLE IS hb-shape, as it is for GSUB, and for the same reason: an
# implementation of a state machine is right or wrong by what it produces,
# and there is nothing in between to inspect. Every unit of example 02.18 and
# 546 further emoji sequences are compared against
#
#   hb-shape "Apple Color Emoji.ttc" --face-index=0 --no-positions --no-clusters
#
# glyph for glyph (tests morx-3.*).
#
# WHAT IS DELIBERATELY NOT BUILT:
#
#   - FEATURE SELECTION. A chain carries feature entries that turn subtables
#     on and off, and only the DEFAULT set is applied - which is what
#     HarfBuzz does when no feature is requested, and what every caller of
#     this package asks for. Building the selection would mean an API for
#     "give me AAT feature type 37 setting 2", and no caller has one.
#   - VERTICAL subtables. A subtable marked vertical-only is skipped, as it
#     is in a horizontal HarfBuzz run. The package sets vertical text through
#     the "vert" feature of GSUB, which is a different road entirely.
#   - the "feat" table. It names the features a chain switches on in words a
#     user interface would show. Nothing here has a user interface.
#   - kerning. AAT puts it in "kerx", which is positioning and not
#     substitution; this file substitutes.
#
# THE BUFFER MODEL, and it is the one thing worth reading before the code.
# HarfBuzz drives these machines over a buffer split in two - an OUTPUT part
# that has been dealt with and an INPUT part that has not, with "out_len" and
# "idx" pointing into them. Deleting a glyph advances idx without advancing
# out_len; inserting one advances out_len without advancing idx.
#
# Here the two parts are ONE list with a cursor: the output is everything
# before the cursor and the input everything from it on. That is the same
# thing said differently - out_len IS the cursor, and idx is where the cursor
# points - and it makes every operation a list operation:
#
#   next_glyph      the cursor moves on              incr cursor
#   replace_glyph   the glyph changes, cursor on     lset / incr cursor
#   skip_glyph      the glyph is dropped             lreplace, cursor stays
#   output_glyph    a glyph appears, cursor on       linsert, incr cursor
#   copy_glyph      the current glyph appears twice  linsert, incr cursor
#   move_to(n)      the cursor goes to n             set cursor n
#
# and "idx == len", the condition the driver ends on, becomes "the cursor is
# at the end of the list".
#

package require Tcl 8.6.11-
package require tclpdf::sfnt 1.0-

namespace eval ::tclpdf::morx {
  namespace export {[a-z]*}
  namespace ensemble create

  # The four reserved glyph CLASSES of a state table and the two reserved
  # STATES. Every other class is the face's own.
  variable classEndOfText 0
  variable classOutOfBounds 1
  variable classDeletedGlyph 2

  # The glyph number a machine deletes with. It is not a glyph: AAT marks a
  # position as gone by putting 0xFFFF there, and the run is swept at the end
  # (Apple, morx, "Deleted glyphs").
  variable deletedGlyph 0xFFFF

  # The coverage bits of a chain subtable, in the 32 bit field morx uses.
  variable coverVertical 0x80000000
  variable coverBackwards 0x40000000
  variable coverAllDirections 0x20000000
  variable coverLogical 0x10000000
  variable coverType 0x000000FF

  # HOW MUCH WORK ONE [apply] MAY SPEND. A state machine with DontAdvance set
  # on a transition that leads back to itself never ends, and nothing in the
  # format forbids one. The budget and its numbers are gsubApply's - 64 per
  # glyph over a floor of 16384 - and so is what happens when it runs out:
  # the machine advances anyway and the run comes back as far as it got. A
  # cyclic font is not a caller's mistake and there is nothing they could do
  # about it, so it is not a refusal.
  variable opsFactor 64
  variable opsFloor 16384
  variable ops 0
}

# Has this face a morx table worth reading?
proc ::tclpdf::morx::has {font} {
  return [expr {[::tclpdf::sfnt extent $font morx] >= 8}]
}

# Read the table and prepare every subtable that is on by DEFAULT, in the
# order a chain applies them.
#
# Read once per face and kept, exactly as [gsubApply prepare] is: a document
# that sets sixty emoji reads these 475 KB once.
proc ::tclpdf::morx::build {font} {
  variable coverVertical
  variable coverAllDirections
  variable coverBackwards
  variable coverType
  set bytes [::tclpdf::sfnt table $font morx]
  set numGlyphs [dict get $font numGlyphs]
  if {[string length $bytes] < 8} {
    return -code error -errorcode {TCLPDF MORX DAMAGED header} \
        "tclpdf: damaged font - the \"morx\" table is\
        [string length $bytes] bytes long and a morx header is 8"
  }
  binary scan $bytes SuSuIu version unused chains
  # Version 1 is "mort", a different table with a different name. 2 and 3 are
  # morx and differ in nothing this file reads (3 added the subtable flags
  # field that 2 already had room for).
  if {$version < 2 || $version > 3} {
    return -code error -errorcode [list TCLPDF MORX VERSION $version] \
        "tclpdf: the \"morx\" table of this face is version $version, and\
        tclpdf reads versions 2 and 3 (Apple, TrueType Reference Manual,\
        morx)"
  }
  set total [string length $bytes]
  set prepared {}
  set at 8
  for {set chain 0} {$chain < $chains} {incr chain} {
    if {[binary scan $bytes @${at}IuIuIuIu flags length features subtables] != 4} {
      return -code error -errorcode {TCLPDF MORX DAMAGED chain} \
          "tclpdf: damaged font - the \"morx\" table announces $chains chains\
          and ends inside the header of chain [expr {$chain + 1}]"
    }
    if {$length < 16 || $at + $length > $total} {
      return -code error -errorcode {TCLPDF MORX DAMAGED chain} \
          "tclpdf: damaged font - chain [expr {$chain + 1}] of the \"morx\"\
          table is declared at $at for $length bytes and the table is only\
          $total bytes long"
    }
    # THE DEFAULT FLAGS AND NOTHING ELSE. A feature entry would change them -
    # see the head of this file for why no caller can ask for one.
    set position [expr {$at + 16 + $features * 12}]
    for {set index 0} {$index < $subtables} {incr index} {
      if {[binary scan $bytes @${position}IuIuIu \
              size coverage selector] != 3} {
        return -code error -errorcode {TCLPDF MORX DAMAGED subtable} \
            "tclpdf: damaged font - chain [expr {$chain + 1}] of the \"morx\"\
            table announces $subtables subtables and ends inside the header\
            of subtable [expr {$index + 1}]"
      }
      if {$size < 12 || $position + $size > $at + $length} {
        return -code error -errorcode {TCLPDF MORX DAMAGED subtable} \
            "tclpdf: damaged font - subtable [expr {$index + 1}] of chain\
            [expr {$chain + 1}] of the \"morx\" table is declared as $size\
            bytes and reaches past the chain"
      }
      set body [string range $bytes [expr {$position + 12}] \
          [expr {$position + $size - 1}]]
      incr position $size
      if {!($flags & $selector)} {
        continue
      }
      # A subtable for VERTICAL text only. Skipped exactly as a horizontal
      # HarfBuzz run skips it.
      if {!($coverage & $coverAllDirections) && ($coverage & $coverVertical)} {
        continue
      }
      set subtable [Subtable [expr {$coverage & $coverType}] $body $numGlyphs]
      if {$subtable eq {}} {
        continue
      }
      # WHICH WAY THE MACHINE RUNS. Bit 28 says whether the subtable works in
      # logical or in layout order and bit 30 whether it works forwards or
      # backwards within that order; for a left-to-right run in logical order
      # - which is what this package hands over - the two collapse into the
      # one bit. Applied by reversing the run and reversing it back, which is
      # what HarfBuzz does and keeps the machine itself in one direction.
      dict set subtable reverse \
          [expr {($coverage & $coverBackwards) ? 1 : 0}]
      lappend prepared $subtable
    }
    incr at $length
  }
  return [dict create numGlyphs $numGlyphs subtables $prepared]
}

# One subtable, prepared - or {} for a type this file does not read.
proc ::tclpdf::morx::Subtable {type body numGlyphs} {
  switch -- $type {
    0 {return [State rearrangement $body $numGlyphs 0]}
    1 {return [Contextual $body $numGlyphs]}
    2 {return [Ligature $body $numGlyphs]}
    4 {return [dict create kind noncontextual body $body \
          lookup [Lookup $body 0 $numGlyphs]]}
    5 {return [Insertion $body $numGlyphs]}
  }
  # A type the format does not define, or one Apple adds later. Skipped and
  # not refused: a chain is a list of independent steps, and a face is not
  # unusable because one of them is unknown - HarfBuzz skips it too.
  return {}
}

# -- the extended state table ------------------------------------------------
#
# STX, the 32 bit form morx uses:
#
#   uint32 nClasses          how wide a row of the state array is
#   uint32 classTable        offset to a lookup, glyph -> class
#   uint32 stateArray        offset to nStates rows of nClasses uint16, each
#                            of them an INDEX into the entry table
#   uint32 entryTable        offset to the entries
#
# All three offsets are from the start of the state table, which is the start
# of the subtable's body. An entry is
#
#   uint16 newState          the state to go to - an INDEX, not a byte offset,
#                            which is the whole difference between morx and
#                            the "mort" table it replaced
#   uint16 flags             what to do, per subtable type
#   ...                      0, 2 or 4 further bytes, per subtable type
#
# CLASSES 0 TO 3 ARE RESERVED: 0 is end of text, 1 out of bounds, 2 a deleted
# glyph, 3 end of line. STATES 0 and 1 are start of text and start of line. A
# glyph the class lookup says nothing about is class 1, and that default is
# not a detail - it is how a machine notices that a sequence has ended.

proc ::tclpdf::morx::State {kind body numGlyphs extra} {
  if {[string length $body] < 16} {
    return -code error -errorcode {TCLPDF MORX DAMAGED state} \
        "tclpdf: damaged font - a \"morx\" state table header is 16 bytes and\
        this subtable holds [string length $body]"
  }
  binary scan $body IuIuIuIu classes classTable stateArray entryTable
  if {$classes < 4} {
    return -code error -errorcode {TCLPDF MORX DAMAGED state} \
        "tclpdf: damaged font - a \"morx\" state table declares $classes\
        glyph classes and the first four are reserved by the format"
  }
  return [dict create kind $kind body $body classes $classes \
      lookup [Lookup $body $classTable $numGlyphs] \
      stateArray $stateArray entryTable $entryTable \
      entrySize [expr {4 + $extra}]]
}

proc ::tclpdf::morx::Ligature {body numGlyphs} {
  set subtable [State ligature $body $numGlyphs 2]
  if {[string length $body] < 28} {
    return -code error -errorcode {TCLPDF MORX DAMAGED ligature} \
        "tclpdf: damaged font - a \"morx\" ligature subtable header is 28\
        bytes and this one holds [string length $body]"
  }
  binary scan $body @16IuIuIu action components ligatures
  return [dict merge $subtable [dict create action $action \
      components $components ligatures $ligatures]]
}

proc ::tclpdf::morx::Contextual {body numGlyphs} {
  set subtable [State contextual $body $numGlyphs 4]
  if {[string length $body] < 20} {
    return -code error -errorcode {TCLPDF MORX DAMAGED contextual} \
        "tclpdf: damaged font - a \"morx\" contextual subtable header is 20\
        bytes and this one holds [string length $body]"
  }
  binary scan $body @16Iu tables
  # A list of uint32 offsets, each of them from the START OF THE LIST, to a
  # lookup of glyph -> glyph. HOW MANY THERE ARE IS NOWHERE STATED, which is
  # why they are collected out of the ENTRIES instead: every entry names at
  # most two of them, so the entries that the state array can reach name
  # every table this subtable can use. Resolved here, once, rather than at
  # every transition - a lookup of format 0 is an array over the whole face
  # and parsing it per glyph would be the same work three thousand times.
  dict set subtable tables $tables
  set lookups {}
  foreach index [Referenced $subtable] {
    set at [expr {$tables + $index * 4}]
    if {[binary scan $body @${at}Iu offset] != 1} {
      return -code error -errorcode {TCLPDF MORX DAMAGED contextual} \
          "tclpdf: damaged font - a \"morx\" contextual entry names\
          substitution table $index and the subtable ends before it"
    }
    dict set lookups $index [Lookup $body [expr {$tables + $offset}] $numGlyphs]
  }
  return [dict merge $subtable [dict create lookups $lookups]]
}

# The substitution tables the entries of a contextual subtable name.
#
# Read off the STATE ARRAY rather than off the entry table's length: the entry
# table has no length of its own, and taking everything from its offset to the
# end of the subtable would read the substitution tables themselves as entries
# and ask for lookups that are not there.
proc ::tclpdf::morx::Referenced {subtable} {
  set body [dict get $subtable body]
  set stateArray [dict get $subtable stateArray]
  set entryTable [dict get $subtable entryTable]
  set until [expr {$entryTable > $stateArray
      ? $entryTable : [string length $body]}]
  set count [expr {($until - $stateArray) / 2}]
  if {$count <= 0} {
    return {}
  }
  binary scan $body @${stateArray}Su$count states
  set highest -1
  foreach state $states {
    if {$state > $highest} {
      set highest $state
    }
  }
  set size [dict get $subtable entrySize]
  set referenced {}
  for {set index 0} {$index <= $highest} {incr index} {
    set at [expr {$entryTable + $index * $size + 4}]
    if {[binary scan $body @${at}SuSu mark current] != 2} {
      break
    }
    foreach value [list $mark $current] {
      if {$value != 0xFFFF} {
        dict set referenced $value 1
      }
    }
  }
  return [dict keys $referenced]
}

proc ::tclpdf::morx::Insertion {body numGlyphs} {
  set subtable [State insertion $body $numGlyphs 4]
  if {[string length $body] < 20} {
    return -code error -errorcode {TCLPDF MORX DAMAGED insertion} \
        "tclpdf: damaged font - a \"morx\" insertion subtable header is 20\
        bytes and this one holds [string length $body]"
  }
  binary scan $body @16Iu action
  return [dict merge $subtable [dict create action $action]]
}

# The entry at {state, class}: {newState flags data}, where data is the
# subtable type's own two or four bytes as a list of uint16.
proc ::tclpdf::morx::Entry {subtable state class} {
  variable classOutOfBounds
  set body [dict get $subtable body]
  set classes [dict get $subtable classes]
  if {$class >= $classes} {
    set class $classOutOfBounds
  }
  set at [expr {[dict get $subtable stateArray] + ($state * $classes + $class) * 2}]
  if {[binary scan $body @${at}Su index] != 1} {
    return -code error -errorcode {TCLPDF MORX DAMAGED state} \
        "tclpdf: damaged font - a \"morx\" state table asks for state $state\
        class $class and its state array ends before that"
  }
  set size [dict get $subtable entrySize]
  set at [expr {[dict get $subtable entryTable] + $index * $size}]
  if {[binary scan $body @${at}SuSu newState flags] != 2} {
    return -code error -errorcode {TCLPDF MORX DAMAGED state} \
        "tclpdf: damaged font - a \"morx\" state table names entry $index and\
        its entry table ends before that"
  }
  set data {}
  if {$size > 4} {
    binary scan $body @[expr {$at + 4}]Su[expr {($size - 4) / 2}] data
  }
  return [list $newState $flags $data]
}

# The class of one glyph - the reserved 1 where the lookup says nothing.
proc ::tclpdf::morx::Class {subtable glyph} {
  variable classOutOfBounds
  variable classDeletedGlyph
  variable deletedGlyph
  if {$glyph == $deletedGlyph} {
    return $classDeletedGlyph
  }
  set value [LookupValue [dict get $subtable lookup] $glyph]
  if {$value eq {}} {
    return $classOutOfBounds
  }
  return $value
}

# -- AAT lookup tables -------------------------------------------------------
#
# The six formats a lookup comes in, and every one of them answers the same
# question: what value does this glyph carry? A class table is a lookup whose
# values are classes, a contextual substitution table is a lookup whose values
# are glyph numbers, and a noncontextual subtable is nothing BUT a lookup.
#
#   0  an array over every glyph of the face
#   2  segments of {last, first, value} - one value for a whole range
#   4  segments of {last, first, offset} - the offset names an array of one
#      value per glyph of the range, measured from the start of the LOOKUP
#   6  pairs of {glyph, value}
#   8  a trimmed array: first glyph, count, values
#  10  a trimmed array whose values are 1, 2 or 4 bytes wide
#
# Formats 2, 4 and 6 carry a binary search header of five uint16 in front of
# their units and usually a terminating unit of 0xFFFF behind them. Neither is
# read here: the header restates the length that is already in nUnits, and a
# terminator whose first glyph is above its last matches nothing.

proc ::tclpdf::morx::Lookup {body at numGlyphs} {
  if {[binary scan $body @${at}Su format] != 1} {
    return -code error -errorcode {TCLPDF MORX DAMAGED lookup} \
        "tclpdf: damaged font - a \"morx\" lookup is declared at $at and the\
        subtable is only [string length $body] bytes long"
  }
  switch -- $format {
    0 {
      # One value per glyph OF THE FACE, and the table is trusted to be that
      # long only as far as it reaches - a face that ends its format 0 lookup
      # early leaves the glyphs behind it without a value, which is the same
      # answer as "this lookup says nothing about them".
      set room [expr {([string length $body] - $at - 2) / 2}]
      set count [expr {min($numGlyphs, $room)}]
      set values {}
      if {$count > 0} {
        binary scan $body @[expr {$at + 2}]Su$count values
      }
      return [list 0 $values]
    }
    2 - 4 - 6 {
      # The binary search header is unitSize, nUnits and three numbers that
      # restate what nUnits already says. THE STRIDE IS THE FILE'S OWN
      # unitSize and not the size of the record: a face is free to leave room
      # behind each unit, and reading the records back to back would then walk
      # into the middle of the next one. The record is 4 bytes in format 6 and
      # 6 in formats 2 and 4, and a unitSize below that is a damaged table.
      binary scan $body @[expr {$at + 2}]SuSu width units
      set least [expr {$format == 6 ? 4 : 6}]
      if {$width < $least} {
        return -code error -errorcode {TCLPDF MORX DAMAGED lookup} \
            "tclpdf: damaged font - a format $format \"morx\" lookup declares\
            a unit of $width bytes and its units are $least"
      }
      set data [string range $body [expr {$at + 12}] \
          [expr {$at + 12 + $units * $width - 1}]]
      return [list $format $data $units $body $at $width]
    }
    8 {
      binary scan $body @[expr {$at + 2}]SuSu first count
      binary scan $body @[expr {$at + 6}]Su$count values
      return [list 8 $first $values]
    }
    10 {
      binary scan $body @[expr {$at + 2}]SuSuSu size first count
      if {$size ni {1 2 4}} {
        return -code error -errorcode {TCLPDF MORX DAMAGED lookup} \
            "tclpdf: damaged font - a format 10 \"morx\" lookup declares a\
            value size of $size bytes, and the format holds 1, 2 or 4"
      }
      set code [dict get {1 cu 2 Su 4 Iu} $size]
      binary scan $body @[expr {$at + 8}]$code$count values
      return [list 8 $first $values]
    }
  }
  return -code error -errorcode [list TCLPDF MORX LOOKUP $format] \
      "tclpdf: a \"morx\" lookup of this face is in format $format, and the\
      format defines 0, 2, 4, 6, 8 and 10 (Apple, TrueType Reference Manual,\
      \"Lookup Tables\")"
}

# What this lookup says about one glyph, or {} for "nothing".
proc ::tclpdf::morx::LookupValue {lookup glyph} {
  switch -- [lindex $lookup 0] {
    0 {
      set values [lindex $lookup 1]
      if {$glyph < 0 || $glyph >= [llength $values]} {
        return {}
      }
      return [lindex $values $glyph]
    }
    8 {
      set first [lindex $lookup 1]
      set values [lindex $lookup 2]
      if {$glyph < $first || $glyph >= $first + [llength $values]} {
        return {}
      }
      return [lindex $values [expr {$glyph - $first}]]
    }
    6 {
      lassign $lookup - data units body at width
      for {set index 0} {$index < $units} {incr index} {
        binary scan $data @[expr {$index * $width}]SuSu key value
        if {$key == $glyph} {
          return $value
        }
      }
      return {}
    }
    2 {
      lassign $lookup - data units body at width
      for {set index 0} {$index < $units} {incr index} {
        binary scan $data @[expr {$index * $width}]SuSuSu last first value
        if {$glyph >= $first && $glyph <= $last} {
          return $value
        }
      }
      return {}
    }
    4 {
      lassign $lookup - data units body at width
      for {set index 0} {$index < $units} {incr index} {
        binary scan $data @[expr {$index * $width}]SuSuSu last first offset
        if {$glyph >= $first && $glyph <= $last} {
          # The offset is measured from the start of the LOOKUP, not from the
          # segment and not from the subtable - reading it as either of those
          # gives a plausible glyph number out of the wrong array, which is
          # the kind of mistake that shows as one wrong emoji in fifty.
          set from [expr {$at + $offset + ($glyph - $first) * 2}]
          if {[binary scan $body @${from}Su value] != 1} {
            return {}
          }
          return $value
        }
      }
      return {}
    }
  }
  return {}
}

# -- applying ----------------------------------------------------------------

# Substitute in a glyph run - a list of {glyph codes ?tag?} entries, the shape
# gsubApply.tcl uses, in logical order.
proc ::tclpdf::morx::apply {state run} {
  variable opsFactor
  variable opsFloor
  variable ops
  if {![llength $run] || ![llength [dict get $state subtables]]} {
    return $run
  }
  set ops [expr {$opsFactor * [llength $run] + $opsFloor}]
  foreach subtable [dict get $state subtables] {
    if {[dict get $subtable reverse]} {
      set run [lreverse $run]
    }
    switch -- [dict get $subtable kind] {
      noncontextual {set run [Noncontextual $subtable $run]}
      default {set run [Drive $subtable $run]}
    }
    if {[dict get $subtable reverse]} {
      set run [lreverse $run]
    }
    # AFTER EVERY SUBTABLE AND NOT ONCE AT THE END: a glyph that was just
    # marked as deleted still stands in the run, and the subtable after this
    # one may ligate ACROSS it - which is exactly what Apple's face does with
    # the transgender flag, where the first subtable deletes both variation
    # selectors and the twelfth joins what is left. Left where it was until
    # the end, such a marker's characters would come back out of the
    # /ToUnicode BEHIND the ligature that jumped over them: the flag
    # extracted as U+1F3F3 U+200D U+26A7 U+FE0F U+FE0F instead of U+1F3F3
    # U+FE0F U+200D U+26A7 U+FE0F. Handed over here, they keep their place.
    set run [Deleted $run]
  }
  return [Sweep $run]
}

# The characters of a glyph that has just been deleted, handed to the glyph
# beside it.
#
# TO THE ONE IN FRONT, or to the one behind where there is none: a deleted
# glyph is a character that draws nothing - a variation selector, a joiner, a
# tag - and such a character belongs to the mark it modifies, which is the
# mark before it. The same rule [ColorFontUnits] follows for a selector the
# face has no glyph for at all.
#
# The marker itself STAYS, with no characters left on it. [Sweep] takes it out
# after the last subtable; until then it is a glyph of class 2 that the state
# machines see and step over.
proc ::tclpdf::morx::Deleted {run} {
  variable deletedGlyph
  set count [llength $run]
  for {set index 0} {$index < $count} {incr index} {
    set entry [lindex $run $index]
    if {[lindex $entry 0] != $deletedGlyph || ![llength [lindex $entry 1]]} {
      continue
    }
    set at [Neighbour $run $index]
    if {$at < 0} {
      # Nothing but deleted glyphs in the run. The characters stay where they
      # are and [Sweep] moves them at the end - or, where everything is
      # deleted, they are lost with the run, which is a face that drew
      # nothing out of what it was given.
      continue
    }
    set codes [lindex $entry 1]
    lset run $index [Entry3 $entry $deletedGlyph {}]
    set target [lindex $run $at]
    if {$at < $index} {
      lset run $at [Entry3 $target [lindex $target 0] \
          [concat [lindex $target 1] $codes]]
    } else {
      lset run $at [Entry3 $target [lindex $target 0] \
          [concat $codes [lindex $target 1]]]
    }
  }
  return $run
}

# The nearest position that is not a deleted glyph - looking back first, then
# forward - or -1 where the run holds nothing else.
proc ::tclpdf::morx::Neighbour {run index} {
  variable deletedGlyph
  for {set at [expr {$index - 1}]} {$at >= 0} {incr at -1} {
    if {[lindex $run $at 0] != $deletedGlyph} {
      return $at
    }
  }
  for {set at [expr {$index + 1}]} {$at < [llength $run]} {incr at} {
    if {[lindex $run $at 0] != $deletedGlyph} {
      return $at
    }
  }
  return -1
}

# The positions AAT marked as gone, taken out of the run.
#
# A machine deletes by writing 0xFFFF and not by shortening the run, because
# the state array is indexed by position and a position that vanished would
# move every mark behind it. The codes of a deleted glyph are NOT lost with
# it: they go to its neighbour, so that the text of the run is the text that
# went in - the same rule a ligature follows.
proc ::tclpdf::morx::Sweep {run} {
  variable deletedGlyph
  set swept {}
  set pending {}
  foreach entry $run {
    if {[lindex $entry 0] == $deletedGlyph} {
      lappend pending {*}[lindex $entry 1]
      continue
    }
    if {[llength $pending]} {
      if {[llength $swept]} {
        set previous [lindex $swept end]
        lset swept end [Entry3 $previous [lindex $previous 0] \
            [concat [lindex $previous 1] $pending]]
      } else {
        set entry [Entry3 $entry [lindex $entry 0] \
            [concat $pending [lindex $entry 1]]]
      }
      set pending {}
    }
    lappend swept $entry
  }
  if {[llength $pending] && [llength $swept]} {
    set previous [lindex $swept end]
    lset swept end [Entry3 $previous [lindex $previous 0] \
        [concat [lindex $previous 1] $pending]]
  }
  return $swept
}

# A new run entry that keeps what the old one carried besides its glyph - the
# same rule as [gsubApply Entry], and named apart because the two roads into a
# run must agree about what an entry carries and neither file is below the
# other.
#
# It is one operation and not a cascade over the length for that very reason:
# spelled out place by place, this copy stayed two-or-three while the
# OpenType road grew a fourth place for the ligature component of a mark, and
# a run that crossed both roads lost it silently.
proc ::tclpdf::morx::Entry3 {source glyph codes} {
  return [lreplace $source 0 1 $glyph $codes]
}

# Type 4: a lookup over every glyph, no state and no order.
proc ::tclpdf::morx::Noncontextual {subtable run} {
  set lookup [dict get $subtable lookup]
  set result {}
  foreach entry $run {
    set value [LookupValue $lookup [lindex $entry 0]]
    if {$value eq {}} {
      lappend result $entry
    } else {
      lappend result [Entry3 $entry $value [lindex $entry 1]]
    }
  }
  return $result
}

# The state machine driver - the loop every stateful subtable type runs under.
#
# It is HarfBuzz's [StateTableDriver::drive] line for line, with the two-part
# buffer written as one list and a cursor (see the head of this file). What
# each type DOES at a transition is the [Transition*] procedure below; what
# the loop does is ask for the entry, hand it over, and move on.
proc ::tclpdf::morx::Drive {subtable run} {
  variable ops
  variable classEndOfText
  set kind [dict get $subtable kind]
  set state 0
  set cursor 0
  set context [dict create mark 0 marked 0 positions {} start 0 end 0]
  while {1} {
    if {$cursor < [llength $run]} {
      set class [Class $subtable [lindex $run $cursor 0]]
    } else {
      set class $classEndOfText
    }
    lassign [Entry $subtable $state $class] newState flags data
    switch -- $kind {
      rearrangement {
        set context [TransitionRearrangement run cursor $flags $context]
      }
      contextual {
        set context [TransitionContextual $subtable run cursor $flags $data \
            $context]
      }
      ligature {
        set context [TransitionLigature $subtable run cursor $flags $data \
            $context]
      }
      insertion {
        set context [TransitionInsertion $subtable run cursor $flags $data \
            $context]
      }
    }
    set state $newState
    if {$cursor >= [llength $run]} {
      break
    }
    # DontAdvance is bit 14 in every one of the four types, which is why it is
    # read here rather than in each of them. A machine that sets it forever is
    # what the budget is for.
    if {!($flags & 0x4000) || [incr ops -1] <= 0} {
      incr cursor
    }
  }
  return $run
}

# Type 0: move up to two glyphs from one end of the marked range to the other.
#
# MarkFirst (0x8000) and MarkLast (0x2000) set the range; the low four bits
# are the VERB, and the sixteen of them are a table rather than a rule. Each
# verb is two nibbles - how many glyphs move from the start to the end and how
# many from the end to the start - where 3 means "two, and reversed".
proc ::tclpdf::morx::TransitionRearrangement {runName cursorName flags context} {
  upvar 1 $runName run
  upvar 1 $cursorName cursor
  # Ax => xA, xD => Dx, AxD => DxA, ABx => xAB, ABx => xBA, xCD => CDx ...
  set verbs {0x00 0x10 0x01 0x11 0x20 0x30 0x02 0x03 0x12 0x13 0x21 0x31
      0x22 0x32 0x23 0x33}
  set count [llength $run]
  if {$flags & 0x8000} {
    dict set context start $cursor
  }
  if {$flags & 0x2000} {
    dict set context end [expr {min($cursor + 1, $count)}]
  }
  set verb [expr {$flags & 0x000F}]
  set start [dict get $context start]
  set end [dict get $context end]
  if {!$verb || $start >= $end} {
    return $context
  }
  set map [lindex $verbs $verb]
  set left [expr {min(2, ($map >> 4) & 0x0F)}]
  set right [expr {min(2, $map & 0x0F)}]
  set reverseLeft [expr {(($map >> 4) & 0x0F) == 3}]
  set reverseRight [expr {($map & 0x0F) == 3}]
  # HarfBuzz stops at 64 glyphs (HB_MAX_CONTEXT_LENGTH) and so does this, so
  # that a face whose machine marks a whole paragraph comes out the same in
  # both.
  if {$end - $start < $left + $right || $end - $start > 64} {
    return $context
  }
  set head [lrange $run $start [expr {$start + $left - 1}]]
  set tail [lrange $run [expr {$end - $right}] [expr {$end - 1}]]
  if {$reverseLeft} {
    set head [lreverse $head]
  }
  if {$reverseRight} {
    set tail [lreverse $tail]
  }
  set middle [lrange $run [expr {$start + $left}] [expr {$end - $right - 1}]]
  set run [concat [lrange $run 0 [expr {$start - 1}]] $tail $middle $head \
      [lrange $run $end end]]
  return $context
}

# Type 1: substitute the current glyph, the marked one, or both.
proc ::tclpdf::morx::TransitionContextual {subtable runName cursorName flags \
    data context} {
  upvar 1 $runName run
  upvar 1 $cursorName cursor
  set count [llength $run]
  lassign $data markIndex currentIndex
  # AT THE END OF THE TEXT NOTHING HAPPENS UNLESS A MARK WAS SET, which is
  # what CoreText does and what HarfBuzz copied from it: the machine gets its
  # end-of-text transition either way, but a substitution written for the
  # glyph after the last one has no glyph to work on.
  if {$cursor >= $count && ![dict get $context marked]} {
    return $context
  }
  if {$count} {
    set lookups [dict get $subtable lookups]
    set mark [dict get $context mark]
    if {$markIndex != 0xFFFF && $mark < $count && [dict exists $lookups $markIndex]} {
      set value [LookupValue [dict get $lookups $markIndex] \
          [lindex $run $mark 0]]
      if {$value ne {}} {
        lset run $mark [Entry3 [lindex $run $mark] $value \
            [lindex $run $mark 1]]
      }
    }
    set at [expr {min($cursor, $count - 1)}]
    if {$currentIndex != 0xFFFF && [dict exists $lookups $currentIndex]} {
      set value [LookupValue [dict get $lookups $currentIndex] \
          [lindex $run $at 0]]
      if {$value ne {}} {
        lset run $at [Entry3 [lindex $run $at] $value [lindex $run $at 1]]
      }
    }
  }
  if {$flags & 0x8000} {
    dict set context marked 1
    dict set context mark $cursor
  }
  return $context
}

# Type 2: several glyphs become one.
#
# TWO FLAGS AND A STACK. SetComponent (0x8000) pushes the current position on
# a stack of marked positions; PerformAction (0x2000) walks that stack from
# the top down, one LIGATURE ACTION per position. Each action adds a number
# out of the component table to a running index, and an action with Store or
# Last set turns the index into a glyph from the ligature table and puts it at
# the position it is standing on. Every other position is deleted.
#
# The index is built by ADDING, so the same two actions reach a different
# ligature for every pair of glyphs - which is how one state machine encodes
# thousands of ligatures without one rule each.
proc ::tclpdf::morx::TransitionLigature {subtable runName cursorName flags \
    data context} {
  upvar 1 $runName run
  upvar 1 $cursorName cursor
  set positions [dict get $context positions]
  if {$flags & 0x8000} {
    # NEVER THE SAME POSITION TWICE. With DontAdvance set a machine may pass
    # the same glyph again, and pushing it twice would make the ligature one
    # component too long.
    if {[llength $positions] && [lindex $positions end] == $cursor} {
      set positions [lrange $positions 0 end-1]
    }
    lappend positions $cursor
    dict set context positions $positions
  }
  if {!($flags & 0x2000)} {
    return $context
  }
  if {![llength $positions] || $cursor >= [llength $run]} {
    return $context
  }
  set body [dict get $subtable body]
  set actionAt [dict get $subtable action]
  set componentAt [dict get $subtable components]
  set ligatureAt [dict get $subtable ligatures]
  set end $cursor
  set index [lindex $data 0]
  set ligature 0
  set pending {}
  # THE STACK IS WALKED, NOT EMPTIED. The slot cursor runs from the top down
  # while the stack itself keeps its depth - which is what HarfBuzz does, and
  # it matters: a machine may perform a second action over the same marked
  # positions before it marks anything new.
  set slot [llength $positions]
  while {1} {
    if {$slot <= 0} {
      # Stack underflow: the actions asked for more components than were
      # marked. The stack is cleared and the run is left as it stands.
      set positions {}
      break
    }
    incr slot -1
    set cursor [lindex $positions $slot]
    if {[binary scan $body @[expr {$actionAt + $index * 4}]Iu action] != 1} {
      break
    }
    incr index
    # A THIRTY BIT SIGNED OFFSET, added to the glyph number to reach into the
    # component table. Sign-extended by hand because Tcl has no 30 bit
    # integer: bit 29 set means the number is negative.
    set offset [expr {$action & 0x3FFFFFFF}]
    if {$offset & 0x20000000} {
      set offset [expr {$offset - 0x40000000}]
    }
    set at [expr {$componentAt + ([lindex $run $cursor 0] + $offset) * 2}]
    if {$at < 0 || [binary scan $body @${at}Su component] != 1} {
      break
    }
    incr ligature $component
    set entry [lindex $run $cursor]
    if {$action & 0xC0000000} {
      set at [expr {$ligatureAt + $ligature * 2}]
      if {$at < 0 || [binary scan $body @${at}Su glyph] != 1} {
        break
      }
      lset positions $slot $cursor
      lset run $cursor [Entry3 $entry $glyph \
          [concat [lindex $entry 1] $pending]]
      set pending {}
      incr cursor
      set ligature 0
    } else {
      # The glyph goes away and its characters go to the ligature that is
      # about to be written - the walk runs from the right, so what has been
      # collected so far stands to the right of the position that will carry
      # it.
      set pending [concat [lindex $entry 1] $pending]
      set run [lreplace $run $cursor $cursor]
      incr end -1
    }
    if {$action & 0x80000000} {
      break
    }
  }
  dict set context positions $positions
  set cursor $end
  return $context
}

# Type 5: put glyphs in front of or behind the current or the marked position.
#
# The count is in the FLAGS - five bits for each of the two - and the entry
# holds where in the insertion glyph table the run of glyphs starts. An
# inserted glyph carries NO characters: it is a shape the face adds, and
# giving it the text of its neighbour would extract that text twice.
proc ::tclpdf::morx::TransitionInsertion {subtable runName cursorName flags \
    data context} {
  upvar 1 $runName run
  upvar 1 $cursorName cursor
  lassign $data currentIndex markedIndex
  set here $cursor
  if {$markedIndex != 0xFFFF} {
    set count [expr {$flags & 0x001F}]
    set glyphs [Inserted $subtable $markedIndex $count]
    set end $cursor
    set cursor [dict get $context mark]
    set moved [Insert run cursor $glyphs [expr {$flags & 0x0400}]]
    set cursor [expr {$end + $moved}]
  }
  if {$flags & 0x8000} {
    dict set context mark $here
  }
  if {$currentIndex != 0xFFFF} {
    set count [expr {($flags & 0x03E0) >> 5}]
    set glyphs [Inserted $subtable $currentIndex $count]
    set end $cursor
    set moved [Insert run cursor $glyphs [expr {$flags & 0x0800}]]
    # WHERE THE CURSOR LANDS depends on DontAdvance, and the format says so in
    # words rather than in a number: "If you have made insertions immediately
    # downstream of the current glyph, the next glyph processed would in fact
    # be the first one inserted." So with DontAdvance the machine goes back to
    # the first inserted glyph and without it past all of them.
    set cursor [expr {($flags & 0x4000) ? $end : $end + $moved}]
  }
  return $context
}

# The glyphs one insertion names, out of the subtable's insertion table.
proc ::tclpdf::morx::Inserted {subtable index count} {
  if {$count <= 0} {
    return {}
  }
  set at [expr {[dict get $subtable action] + $index * 2}]
  set glyphs {}
  if {[binary scan [dict get $subtable body] @${at}Su$count glyphs] != 1} {
    return {}
  }
  return $glyphs
}

# Put glyphs in at the cursor, before or after the glyph standing there, and
# answer how many were put in.
proc ::tclpdf::morx::Insert {runName cursorName glyphs before} {
  upvar 1 $runName run
  upvar 1 $cursorName cursor
  if {![llength $glyphs]} {
    return 0
  }
  set entries {}
  foreach glyph $glyphs {
    lappend entries [list $glyph {}]
  }
  if {$before || $cursor >= [llength $run]} {
    set run [linsert $run $cursor {*}$entries]
  } else {
    set run [linsert $run [expr {$cursor + 1}] {*}$entries]
    incr cursor
  }
  incr cursor [llength $entries]
  return [llength $entries]
}

package provide tclpdf::morx 1.1
