#!/bin/sh
#\
exec tclsh "$0" "$@"

#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# Generate bidiData.tcl - the Unicode Bidi_Class of every character that takes
# part in a NUMBER - from the Unicode Character Database.
#
# Usage: mkbidi.tcl tools/ucd/DerivedBidiClass.txt > bidiData.tcl
#
# This is a BUILD-TIME tool. It does not ship and it is not needed to use the
# package; it exists so that the table in bidiData.tcl can be reproduced and
# checked against its source rather than being trusted - tests/bidi.test runs
# it and compares.
#
# WHY A GENERATOR AND NOT A HAND LIST. bidi.tcl used to name the number
# characters by hand - the percent sign, the euro, the dollar, a plus and a
# minus - and the list was as short as the author's imagination on the day:
# measured 2026-08-16 with DejaVu Sans, "5°", "£3" and "7‰" in a -direction
# rtl line came back out of the file as "°5", "3£" and "‰7", because the
# degree sign, the pound sign and the per mille sign are European Terminators
# in UAX #9 (rule W5) and the hand list did not know it. Every such gap is a
# reversed amount that looks like an amount, so the list is read off the
# database instead of being remembered.
#
# WHICH CLASSES. Only the five that UAX #9's weak-type rules W1..W7 fold into
# a number: EN and AN (the digits), ES and CS (the separators, W4), ET (the
# terminators, W5). Everything else - the strong types L, R, AL and the
# neutrals - stays out on purpose: bidi.tcl treats the right-to-left blocks
# whole and refuses what it does not know, and a table of every ON and NSM
# would turn that refusal into acceptance without the rules (W1, N1, N2) that
# make acceptance right.
#
# THE @missing LINES. Unlike DerivedJoiningType.txt, this file gives some
# blocks a default that is not the global one, and one of those defaults is a
# class kept here: "@missing: 20A0..20CF; European_Terminator" - every
# UNASSIGNED code point of the Currency Symbols block is ET, so that a
# currency sign added in a later Unicode is a terminator before any table
# has heard of it. The generator honours it: the code points of such a
# @missing range that no explicit line names are added with the default class,
# and touching entries of one class are merged.
#
# tools/ucd/DerivedBidiClass.txt is the file itself, verbatim from the
# Unicode Character Database (version 17.0.0, 2025-07-24), (C) 2025 Unicode,
# Inc. Terms of use: https://www.unicode.org/terms_of_use.html - it may be
# redistributed with the notice it carries, which is why it is copied in
# unedited rather than trimmed to the classes this package uses. It is one
# edition NEWER than DerivedJoiningType.txt beside it (16.0.0): the two tables
# are read for different properties, and neither the joining types nor the
# number classes of the characters this package meets changed between the two.
#

if {[llength $argv] != 1} {
  puts stderr "usage: [file tail [info script]] <DerivedBidiClass.txt>"
  exit 1
}

lassign $argv source

set channel [open $source r]
fconfigure $channel -encoding utf-8
set text [read $channel]
close $channel

# The version the file names itself, so the generated table can say which
# Unicode it is - a table that does not name its edition cannot be checked
# against one.
set version {}
if {[regexp {DerivedBidiClass-([0-9.]+)\.txt} $text -> found]} {
  set version $found
}

# The classes that are kept, and the long names the @missing lines use for
# them - the data lines carry the short ones.
set kept {EN AN ES CS ET}
set longNames {
  European_Number EN
  Arabic_Number AN
  European_Separator ES
  Common_Separator CS
  European_Terminator ET
}

# One code point or a "first..last" range, as {first last}.
proc codeRange {codes line} {
  if {[regexp {^([0-9A-Fa-f]+)\.\.([0-9A-Fa-f]+)$} $codes -> first last]} {
    return [list [scan $first %x] [scan $last %x]]
  } elseif {[regexp {^[0-9A-Fa-f]+$} $codes]} {
    set value [scan $codes %x]
    return [list $value $value]
  }
  puts stderr "mkbidi: cannot read the code point field: $line"
  exit 1
}

# Field 0 is a code point or a range, field 1 the Bidi_Class. Everything from
# a # onwards is a comment - except the @missing lines, which are comments in
# form and defaults in fact, so they are read before the comment is cut off.
set ranges {}
set defaults {}
foreach line [split $text \n] {
  if {[regexp {^#\s*@missing:\s*([0-9A-Fa-f.]+)\s*;\s*(\S+)} $line -> codes name]} {
    if {[dict exists $longNames $name]} {
      lappend defaults [list {*}[codeRange $codes $line] [dict get $longNames $name]]
    }
    continue
  }
  set line [string trim [regsub {#.*$} $line {}]]
  if {$line eq {}} {
    continue
  }
  set fields [split $line \;]
  if {[llength $fields] < 2} {
    continue
  }
  set codes [string trim [lindex $fields 0]]
  set class [string trim [lindex $fields 1]]
  if {![regexp {^[A-Z]{1,3}$} $class]} {
    puts stderr "mkbidi: unknown bidi class \"$class\" in: $line"
    exit 1
  }
  lappend ranges [list {*}[codeRange $codes $line] $class]
}

if {![llength $ranges]} {
  puts stderr "mkbidi: no data in $source - wrong file?"
  exit 1
}

# The default of a block applies to the code points no explicit line names -
# of ANY class, which is why every class was read above and is only now cut
# down to the kept ones.
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
  lassign $default from to class
  for {set code $from} {$code <= $to} {incr code} {
    if {![dict exists $covered $code]} {
      lappend ranges [list $code $code $class]
    }
  }
}
set ranges [lmap range $ranges {
  expr {[lindex $range 2] in $kept ? $range : [continue]}
}]

# Sorted by first code point, so that the table reads in the order of the
# code charts and can be checked against them, and so that a search may stop
# or halve - the file groups its lines BY CLASS, so it is not sorted as it
# stands. Then merged: the @missing fill above adds one entry per code point,
# and a range next to another of the same class is one range.
set ranges [lsort -integer -index 0 $ranges]
set merged {}
foreach range $ranges {
  lassign $range first last class
  if {[llength $merged]} {
    lassign [lindex $merged end] before until same
    if {$first <= $until} {
      puts stderr "mkbidi: ranges overlap at [format U+%04X $first]"
      exit 1
    }
    if {$first == $until + 1 && $class eq $same} {
      lset merged end [list $before $last $class]
      continue
    }
  }
  lappend merged $range
}
set ranges $merged

puts "#"
puts "# tclpdf - PDF generation for Tcl"
puts "#"
puts "# bidiData - the Unicode Bidi_Class table of the number characters"
puts "#"
puts "# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>"
puts "#"
puts "# See the file \"license.terms\" for information on usage and redistribution"
puts "# of this file (MIT License)."
puts "#"
if {$version eq {}} {
  set edition "of unnamed version"
} else {
  set edition "version $version"
}
puts "# GENERATED - do not edit. Produced by tools/mkbidi.tcl from"
puts "# tools/ucd/DerivedBidiClass.txt of the Unicode Character Database,"
puts "# $edition, (C) Unicode, Inc. Rerun the generator instead of correcting"
puts "# an entry here; a hand-fixed value would be lost on the next run and"
puts "# would no longer match its source - tests/bidi.test compares the two."
puts "#"
puts "# Ranges of {first last class}, sorted by first and free of overlap, with"
puts "# the classes EN, AN, ES, CS and ET - the weak types UAX #9 rules W1..W7"
puts "# fold into a number. A character that is not in the table is one of the"
puts "# strong types or a neutral, and which of those it is stays bidi.tcl's"
puts "# answer: this table says who belongs to a number, not who runs which way."
puts "#"
puts ""
puts "package require Tcl 8.6.11-"
puts ""
puts "namespace eval ::tclpdf::bidiData \{"
puts "  # [llength $ranges] ranges, one to the line."
puts "  variable ranges \{"
foreach range $ranges {
  lassign $range first last class
  puts [format "    0x%04X 0x%04X %s" $first $last $class]
}
puts "  \}"
puts "\}"
puts ""
# The module version is written out here rather than derived from anything: a
# module version is raised by the author, deliberately, and a generator that
# guessed it would raise it behind their back.
puts "package provide tclpdf::bidiData 1.0"
