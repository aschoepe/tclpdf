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
# and checked against its source rather than being trusted - tests/joining.test
# runs it and compares. The reading, sorting and writing it shares with
# mkbidi.tcl live in tools/ucd.tcl.
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
# are exactly as non-joining as the unlisted rest. And with U dropped the
# @missing line is dropped too - it names nothing but U.
#
# WHAT IS NOT MERGED. Two ranges of one type side by side stay two lines -
# the file lists them so, and the table is meant to be read against it.
#

if {[llength $argv] != 1} {
  puts stderr "usage: [file tail [info script]] <DerivedJoiningType.txt>"
  exit 1
}

source [file join [file dirname [info script]] ucd.tcl]

lassign [::ucd::read [lindex $argv 0] DerivedJoiningType] version lines

set ranges {}
foreach line $lines {
  set parsed [::ucd::parse $line]
  if {$parsed eq {}} {
    continue
  }
  lassign $parsed first last type
  if {$type eq "U"} {
    continue
  }
  if {$type ni {R L D C T}} {
    ::ucd::fail "unknown joining type \"$type\" in: $line"
  }
  lappend ranges $parsed
}

::ucd::write \
    -module joiningData \
    -title "the Unicode Joining_Type table" \
    -generator mkjoining.tcl \
    -source DerivedJoiningType.txt \
    -edition $version \
    -test joining.test \
    -notes {
      Ranges of {first last type}, sorted by first and free of overlap, with
      the types R, L, D, C and T. A character that is not in the table is
      Non_Joining (U) - which is what the source file says about every code
      point it does not list, so the absence is the answer and not a gap.
    } \
    -ranges [::ucd::sort $ranges] \
    -version 1.0
