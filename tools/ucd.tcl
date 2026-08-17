#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# ucd.tcl - what the generators that read a Unicode Character Database file
# share: reading the file and its edition, parsing a data line and a @missing
# line, filling a block default, sorting and merging ranges, and writing the
# generated module with its header.
#
# This is a BUILD-TIME library. It does not ship and it is not a package; the
# generators source it relative to their own location:
#
#   source [file join [file dirname [info script]] ucd.tcl]
#
# WHY IT EXISTS. mkjoining.tcl and mkbidi.tcl read two files of the same
# family - "first..last ; Value # comment", one property each - and by
# 2026-08-16 the second generator had grown by copying the first: the same
# read, the same field split, the same overlap check, the same header, three
# blocks the duplicate scan named. A third file (a further property, or the
# Bidi_Class rules of UAX #9 rule N1 one day) would have made four. So the
# common part lives here once, and a generator keeps only what its property
# needs: which values it keeps, what it says about them, and whether a block
# default matters to it.
#
# The format is the one every Derived*.txt of the UCD uses (UAX #44 section
# 4.2): a first line "# <File>-<version>.txt", comment lines beginning with #,
# and data lines of a code point or a "first..last" range, a semicolon, the
# property value, and an optional # comment. The @missing lines are comments
# in form and defaults in fact - "# @missing: first..last; Value" gives the
# code points of that range that no data line names their value.
#

namespace eval ::ucd {
}

# The generator's own name, for messages: mkbidi.tcl fails as "mkbidi:", not
# as "ucd:" - the person at the terminal ran the generator, not the library.
proc ::ucd::tool {} {
  return [file rootname [file tail $::argv0]]
}

# Fail as the generators always failed: one line on stderr, exit status 1,
# nothing written to stdout - so that a redirected run cannot leave a half
# table under a "do not edit" header.
proc ::ucd::fail {message} {
  puts stderr "[tool]: $message"
  exit 1
}

# Read the file at $path and return {version lines}: the Unicode version the
# file names itself in its first line, and its lines. $name is the file the
# generator expects - "DerivedBidiClass" - and a file that names itself
# otherwise is refused HERE, before anything is parsed: measured, mkbidi.tcl
# fed DerivedJoiningType.txt read the joining types as bidi classes, kept
# none of them and wrote an empty table with exit status 0. A table that says
# which edition it is can be checked against one; a table read from the wrong
# file cannot be checked against anything.
proc ::ucd::read {path name} {
  set channel [open $path r]
  fconfigure $channel -encoding utf-8
  set text [::read $channel]
  close $channel
  set lines [split $text \n]
  if {![regexp "^#\\s*${name}-(\[0-9.\]+)\\.txt\\s*$" [lindex $lines 0] \
      -> version]} {
    fail "$path does not name itself \"# $name-<version>.txt\" in its first\
        line - wrong file?"
  }
  return [list $version $lines]
}

# One code point or a "first..last" range as {first last}, or a failure that
# quotes the line - the file is machine-written, so a field that does not
# parse means the wrong file or a damaged one, never a variant to cope with.
proc ::ucd::codes {codes line} {
  if {[regexp {^([0-9A-Fa-f]+)\.\.([0-9A-Fa-f]+)$} $codes -> first last]} {
    return [list [scan $first %x] [scan $last %x]]
  } elseif {[regexp {^[0-9A-Fa-f]+$} $codes]} {
    set value [scan $codes %x]
    return [list $value $value]
  }
  fail "cannot read the code point field: $line"
}

# A data line as {first last value}, or {} for a line that carries no data:
# blank, comment, or too short. Field 0 is the code point or range, field 1
# the property value; everything from a # onwards is a comment - which in
# these files carries the General_Category and the character name, neither of
# which a generator needs. A @missing line is a comment to this proc; the
# generator that wants it asks [missing] first.
proc ::ucd::parse {line} {
  set line [string trim [regsub {#.*$} $line {}]]
  if {$line eq {}} {
    return {}
  }
  set fields [split $line \;]
  if {[llength $fields] < 2} {
    return {}
  }
  set codes [string trim [lindex $fields 0]]
  set value [string trim [lindex $fields 1]]
  return [list {*}[codes $codes $line] $value]
}

# A "# @missing: first..last; Value" line as {first last value}, or {} for
# any other line. The value is the LONG property name - the data lines carry
# the short one - and the generator maps it, because only the generator knows
# which values it keeps.
proc ::ucd::missing {line} {
  if {[regexp {^#\s*@missing:\s*([0-9A-Fa-f.]+)\s*;\s*(\S+)} $line -> codes name]} {
    return [list {*}[codes $codes $line] $name]
  }
  return {}
}

# The default of a block applies to the code points that no data line names -
# a data line of ANY value, which is why a generator has to feed [fill] every
# range it read and cut down to the values it keeps only afterwards. Returns
# $ranges plus one {code code value} entry per unnamed code point of every
# default; [merge] turns the singles back into ranges.
proc ::ucd::fill {ranges defaults} {
  set covered {}
  foreach default $defaults {
    lassign $default from to
    foreach range $ranges {
      lassign $range first last
      for {set code [expr {max($first, $from)}]} {$code <= min($last, $to)} \
          {incr code} {
        dict set covered $code 1
      }
    }
  }
  foreach default $defaults {
    lassign $default from to value
    for {set code $from} {$code <= $to} {incr code} {
      if {![dict exists $covered $code]} {
        lappend ranges [list $code $code $value]
      }
    }
  }
  return $ranges
}

# Sorted by first code point, because the module finds a character by halving
# the table, and so that the table reads in the order of the code charts and
# can be checked against them. The files are in order block by block but
# grouped BY VALUE, so as they stand they are not sorted at all. A range that
# overlaps its neighbour would make the search answer by chance which of the
# two it finds; the file cannot contain one - a character has one value of a
# property - but a wrong parse could produce it, and this is the cheap place
# to notice.
proc ::ucd::sort {ranges} {
  set ranges [lsort -integer -index 0 $ranges]
  set previous -1
  foreach range $ranges {
    lassign $range first last value
    if {$first <= $previous} {
      fail "ranges overlap at [format U+%04X $first]"
    }
    set previous $last
  }
  return $ranges
}

# [sort], then a range next to another of the same value is one range - the
# [fill] above adds one entry per code point, and a table of singles would
# say in fifty lines what one says.
proc ::ucd::merge {ranges} {
  set merged {}
  foreach range [sort $ranges] {
    lassign $range first last value
    if {[llength $merged]} {
      lassign [lindex $merged end] before until same
      if {$first == $until + 1 && $value eq $same} {
        lset merged end [list $before $last $value]
        continue
      }
    }
    lappend merged $range
  }
  return $merged
}

# Write the generated module to stdout: the header, the table, the package
# line. Options, all required:
#
#   -module     the module name, bidiData - names the namespace and the package
#   -title      what the table is, one line, after "<module> - "
#   -generator  the generator's file name, mkbidi.tcl
#   -source     the UCD file's name, DerivedBidiClass.txt
#   -edition    the Unicode version [read] found in it
#   -test       the test file that compares the table with a fresh run
#   -notes      what the table holds and what its absence means, as lines
#   -ranges     the {first last value} list, sorted, as [sort] or [merge] left it
#   -version    the MODULE version, 1.0
#
# The module version is written out from what the generator says rather than
# derived from anything: a module version is raised by the author,
# deliberately, and a generator that guessed it would raise it behind their
# back. (The lesson mkafm.tcl records - a generated file that does not write
# its own last line makes its "do not edit" header a lie.)
proc ::ucd::write {args} {
  foreach option {-module -title -generator -source -edition -test -notes \
      -ranges -version} {
    if {![dict exists $args $option]} {
      error "ucd::write: missing $option"
    }
  }
  dict with args {}
  set module ${-module}
  set ranges ${-ranges}
  # Refused before the first line goes out: an empty table under a "do not
  # edit" header would load, answer nothing and look finished.
  if {![llength $ranges]} {
    fail "no ranges to write from tools/ucd/${-source} - empty file?"
  }
  puts "#"
  puts "# tclpdf - PDF generation for Tcl"
  puts "#"
  puts "# $module - ${-title}"
  puts "#"
  puts "# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>"
  puts "#"
  puts "# See the file \"license.terms\" for information on usage and redistribution"
  puts "# of this file (MIT License)."
  puts "#"
  puts "# GENERATED - do not edit. Produced by tools/${-generator} from"
  puts "# tools/ucd/${-source} of the Unicode Character Database,"
  puts "# version ${-edition}, (C) Unicode, Inc. Rerun the generator instead of correcting"
  puts "# an entry here; a hand-fixed value would be lost on the next run and"
  puts "# would no longer match its source - tests/${-test} compares the two."
  puts "#"
  foreach line [split [string trim ${-notes}] \n] {
    puts "# [string trim $line]"
  }
  puts "#"
  puts ""
  puts "package require Tcl 8.6.11-"
  puts ""
  puts "namespace eval ::tclpdf::$module \{"
  puts "  # [llength $ranges] ranges, one to the line."
  puts "  variable ranges \{"
  foreach range $ranges {
    lassign $range first last value
    puts [format "    0x%04X 0x%04X %s" $first $last $value]
  }
  puts "  \}"
  puts "\}"
  puts ""
  puts "package provide tclpdf::$module ${-version}"
}
