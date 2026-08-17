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
# it and compares. The reading, sorting and writing it shares with
# mkjoining.tcl live in tools/ucd.tcl.
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

source [file join [file dirname [info script]] ucd.tcl]

lassign [::ucd::read [lindex $argv 0] DerivedBidiClass] version lines

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

# Every class is read, not only the kept ones: the default of a block applies
# to the code points no explicit line names - of ANY class - so the cut to
# the kept classes has to wait until the defaults are filled in.
set ranges {}
set defaults {}
foreach line $lines {
  set default [::ucd::missing $line]
  if {$default ne {}} {
    lassign $default first last name
    if {[dict exists $longNames $name]} {
      lappend defaults [list $first $last [dict get $longNames $name]]
    }
    continue
  }
  set parsed [::ucd::parse $line]
  if {$parsed eq {}} {
    continue
  }
  set class [lindex $parsed 2]
  if {![regexp {^[A-Z]{1,3}$} $class]} {
    ::ucd::fail "unknown bidi class \"$class\" in: $line"
  }
  lappend ranges $parsed
}

set ranges [lmap range [::ucd::fill $ranges $defaults] {
  expr {[lindex $range 2] in $kept ? $range : [continue]}
}]

::ucd::write \
    -module bidiData \
    -title "the Unicode Bidi_Class table of the number characters" \
    -generator mkbidi.tcl \
    -source DerivedBidiClass.txt \
    -edition $version \
    -test bidi.test \
    -notes {
      Ranges of {first last class}, sorted by first and free of overlap, with
      the classes EN, AN, ES, CS and ET - the weak types UAX #9 rules W1..W7
      fold into a number. A character that is not in the table is one of the
      strong types or a neutral, and which of those it is stays bidi.tcl's
      answer: this table says who belongs to a number, not who runs which way.
    } \
    -ranges [::ucd::merge $ranges] \
    -version 1.0
