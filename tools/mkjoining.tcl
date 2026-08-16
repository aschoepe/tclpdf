#!/bin/sh
#\
exec tclsh "$0" "$@"

#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# Generate joiningData.tcl - the Unicode Joining_Type of every character that
# has one - from the Unicode Character Database.
#
# Usage: mkjoining.tcl tools/ucd/DerivedJoiningType.txt > joiningData.tcl
#
# This is a BUILD-TIME tool. It does not ship and it is not needed to use the
# package; it exists so that the table in joiningData.tcl can be reproduced
# and checked against its source rather than being trusted.
#
# WHY THIS FILE AND NOT ArabicShaping.txt. ArabicShaping.txt is the file the
# standard points at, and it is not enough on its own: it lists R, L, D, C and
# U, but only four characters of type T. Every other transparent character -
# every Arabic vowel sign, every combining mark that may sit inside a word -
# is transparent BY RULE, and the rule needs a property ArabicShaping.txt does
# not carry. Its own header says so:
#
#   "For an implementation that needs to parse for the values of
#    Joining_Type, it is recommended to use DerivedJoiningType.txt
#    instead of ArabicShaping.txt, to avoid the separate required step of
#    calculating the set for Joining_Type=T based on General_Category values."
#
# Transparency is not a detail here: a transparent character is SKIPPED when
# the neighbours of a letter are looked for, so getting it wrong breaks the
# join across every vowelled word - the letters fall apart into isolated
# forms and the line still looks like text.
#
# tools/ucd/DerivedJoiningType.txt is the file itself, verbatim from the
# Unicode Character Database (version 16.0.0, 2024-04-30), (C) 2024 Unicode,
# Inc. Terms of use: https://www.unicode.org/terms_of_use.html - it may be
# redistributed with the notice it carries, which is why it is copied in
# unedited rather than trimmed to the ranges this package uses.
#
# WHAT IS DROPPED. Type U - the value every unlisted character has anyway
# ("@missing: 0000..10FFFF; Non_Joining" in the file header). Writing it out
# would double the table to say what its absence already says. The 50 U
# entries the file does list are ranges INSIDE the joining blocks, and they
# are exactly as non-joining as the unlisted rest.
#

if {[llength $argv] != 1} {
  puts stderr "usage: [file tail [info script]] <DerivedJoiningType.txt>"
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
if {[regexp {DerivedJoiningType-([0-9.]+)\.txt} $text -> found]} {
  set version $found
}

# Field 0 is a code point or a "first..last" range, field 1 the Joining_Type.
# Everything from a # onwards is a comment - which in this file carries the
# General_Category and the character name, neither of which is needed here.
set ranges {}
foreach line [split $text \n] {
  set line [string trim [regsub {#.*$} $line {}]]
  if {$line eq {}} {
    continue
  }
  set fields [split $line \;]
  if {[llength $fields] < 2} {
    continue
  }
  set codes [string trim [lindex $fields 0]]
  set type [string trim [lindex $fields 1]]
  if {$type eq "U"} {
    continue
  }
  if {$type ni {R L D C T}} {
    puts stderr "mkjoining: unknown joining type \"$type\" in: $line"
    exit 1
  }
  if {[regexp {^([0-9A-Fa-f]+)\.\.([0-9A-Fa-f]+)$} $codes -> first last]} {
    lappend ranges [list [scan $first %x] [scan $last %x] $type]
  } elseif {[regexp {^[0-9A-Fa-f]+$} $codes]} {
    set value [scan $codes %x]
    lappend ranges [list $value $value $type]
  } else {
    puts stderr "mkjoining: cannot read the code point field: $line"
    exit 1
  }
}

if {![llength $ranges]} {
  puts stderr "mkjoining: no data in $source - wrong file?"
  exit 1
}

# Sorted by first code point, because the module finds a character by halving
# the table. The file is already in order block by block, but it is grouped BY
# TYPE, so the C ranges come before the D ones and the whole thing is not
# sorted at all as it stands.
set ranges [lsort -integer -index 0 $ranges]

# A range that overlaps its neighbour would make the search answer by chance
# which of the two it finds. The Unicode file cannot contain one - a character
# has one Joining_Type - but a wrong parse above could produce it, and this is
# the cheap place to notice.
set previous -1
foreach range $ranges {
  lassign $range first last type
  if {$first <= $previous} {
    puts stderr "mkjoining: ranges overlap at [format U+%04X $first]"
    exit 1
  }
  set previous $last
}

puts "#"
puts "# tclpdf - PDF generation for Tcl"
puts "#"
puts "# joiningData - the Unicode Joining_Type table"
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
puts "# GENERATED - do not edit. Produced by tools/mkjoining.tcl from"
puts "# tools/ucd/DerivedJoiningType.txt of the Unicode Character Database,"
puts "# $edition, (C) Unicode, Inc. Rerun the generator instead of correcting"
puts "# an entry here; a hand-fixed value would be lost on the next run and"
puts "# would no longer match its source."
puts "#"
puts "# Ranges of {first last type}, sorted by first and free of overlap, with"
puts "# the types R, L, D, C and T. A character that is not in the table is"
puts "# Non_Joining (U) - which is what the source file says about every code"
puts "# point it does not list, so the absence is the answer and not a gap."
puts "#"
puts ""
puts "package require Tcl 8.6.11-"
puts ""
puts "namespace eval ::tclpdf::joiningData \{"
puts "  # [llength $ranges] ranges, one to the line."
puts "  variable ranges \{"
foreach range $ranges {
  lassign $range first last type
  puts [format "    0x%04X 0x%04X %s" $first $last $type]
}
puts "  \}"
puts "\}"
puts ""
# The module version is written out here rather than derived from anything: a
# module version is raised by the author, deliberately, and a generator that
# guessed it would raise it behind their back. (The same lesson mkafm.tcl
# records - a generated file that does not write its own last line makes its
# "do not edit" header a lie.)
puts "package provide tclpdf::joiningData 1.0"
