#!/usr/bin/env tclsh
#
# tclpdf example 2.5 - pair kerning
#
#   tclsh examples/02.05-kerning.tcl ?output.pdf?
#
# Kerning is the small correction between two letters whose shapes leave a
# hole the metrics do not account for: the classic ones are AV, To, Ta, LT.
# Without it the hole stays, and it shows most where it hurts - in a headline,
# at a large size.
#
# WHERE THE NUMBERS COME FROM. A font can record kerning in two places, and
# which of the two counts is not a matter of taste: ISO/IEC 14496-22, 8.16
# prescribes the order. If GPOS has kerning lookups for the resolved language
# system, GPOS applies "and the kern table data ignored"; only when it has
# none does the old kern table come into play. tclpdf reads both and follows
# that rule - DejaVu Sans below carries both and is therefore kerned from
# GPOS, Roboto carries only GPOS.
#
# WHERE THEY END UP. Nowhere in the font. Kerning is producer arithmetic: the
# amounts are written as numbers in the TJ array of the content stream, and no
# reader ever consults the font for them. The embedded subset therefore
# carries neither table.
#
# IT IS ON BY DEFAULT. Kerning is what the type designer intended, so leaving
# it off would ship worse typography than the font offers. -kerning 0 turns it
# back off where a document has to come out exactly as an older release
# produced it - the pairs change the width of every line they touch.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "02.05-kerning.pdf"}]
set assets [file join $here assets]

set doc [tclpdf new -unit mm]
$doc info Title "Pair kerning"
$doc page add

$doc font embed serif [file join $assets fonts DejaVuSans.ttf]
$doc font embed serifBold [file join $assets fonts DejaVuSans-Bold.ttf]
$doc font embed sans [file join $assets fonts Roboto-Regular.ttf]

$doc font -family serifBold -size 14 -color {0.20 0.30 0.45}
$doc text "Pair kerning" -at {20 25}

$doc font -family serif -size 9 -color {0.35 0.35 0.35}
$doc text "The same line twice: once as the metrics have it, once with the\
    pairs applied." -at {20 32} -width 170

# -- the pairs, large enough to see -----------------------------------------
#
# Note the [list 20 $y]: writing -at {20 $y} would pass the dollar sign
# through unsubstituted, because braces stop substitution.

set pairs "AV To Ta LT Yo We"
set y 50

foreach {face caption} {serifBold {DejaVu Sans Bold - GPOS and a kern table}
    sans {Roboto - GPOS only}} {
  $doc font -family serif -size 8 -color {0.45 0.45 0.45}
  $doc text $caption -at [list 20 [expr {$y - 9}]]

  foreach kerning {0 1} {
    set at [expr {$y + $kerning * 12}]
    $doc font -family $face -size 24 -color black -kerning $kerning
    $doc text $pairs -at [list 20 $at]
    $doc font -family serif -size 7 -color {0.6 0.6 0.6}
    $doc text [expr {$kerning ? "on" : "off"}] -at [list 150 $at]
  }

  # The difference in width is what the line breaker sees as well: measuring
  # and drawing go through the same numbers, or the two drift apart.
  #
  # -kerning 0 has to be written out: the loop above left the font state on
  # -kerning 1, and textWidth merges the per-call options onto that state.
  # Leaving it off here would measure the same thing twice and report a
  # difference of zero - which is exactly what this line did at first.
  set plain [$doc textWidth $pairs -family $face -size 24 -kerning 0]
  set kerned [$doc textWidth $pairs -family $face -size 24 -kerning 1]
  $doc font -family serif -size 7 -color {0.45 0.45 0.45}
  $doc text [format "%.2f mm narrower" [expr {$plain - $kerned}]] \
      -at [list 150 [expr {$y + 18}]]

  set y [expr {$y + 44}]
}

# -- and in running text ----------------------------------------------------

$doc font -family serif -size 8 -color {0.45 0.45 0.45}
$doc text "In running text the effect is small per pair and adds up per line,\
    which is why the measurement has to know about it too - otherwise the\
    line breaks land in the wrong place." -at [list 20 $y] -width 170
set y [expr {$y + 14}]

set sample "AVATAR: To the Tower. LT Wave, Yo-Yo, PAWN takes VALLEY."
foreach kerning {0 1} {
  $doc font -family serifBold -size 11 -color black -kerning $kerning
  $doc text $sample -at [list 20 $y] -width 115 -align justify
  $doc font -family serif -size 7 -color {0.6 0.6 0.6}
  $doc text [expr {$kerning ? "kerning on" : "kerning off"}] \
      -at [list 145 $y]
  set y [expr {$y + 20}]
}

# -- an accent between the two ----------------------------------------------
#
# A lookup can tell the reader to leave some glyphs out of the sequence while
# it works: Roboto sets "ignore marks" on both of its kerning lookups, and 51
# of the 73 faces on the machine this was written on do the same. Which glyph
# is a mark comes out of a third table, GDEF - so a reader that skips GDEF
# cannot follow the instruction and quietly stops kerning wherever a combining
# accent stands between two letters.
#
# That is only visible with DECOMPOSED text: A + U+0301 rather than the single
# character U+00C1. Both spell the same word, both are valid, and the second
# one was never affected.
#
# What tclpdf does NOT do is place the mark: GPOS mark attachment is not read,
# so the accent is drawn at the pen position with whatever side bearing the
# font gives it. The kerning of the letters around it is a separate question,
# and that one is answered.

$doc font -family serif -size 8 -color {0.45 0.45 0.45}
$doc text "Kerning across a combining accent. The pair is A and V in both\
    lines; in the second one a combining acute stands between them." \
    -at [list 20 $y] -width 170
set y [expr {$y + 18}]

foreach {label sample} [list "precomposed  U+00C1 V" "ÁV" \
    "decomposed   A U+0301 V" "A\u0301V"] {
  foreach kerning {0 1} {
    $doc font -family sans -size 28 -color black -kerning $kerning
    $doc text $sample -at [list [expr {20 + $kerning * 30}] $y]
  }
  $doc font -family serif -size 7 -color {0.45 0.45 0.45}
  $doc text $label -at [list 90 $y]
  $doc text [format "off %.2f mm / on %.2f mm" \
      [$doc textWidth $sample -family sans -size 28 -kerning 0] \
      [$doc textWidth $sample -family sans -size 28 -kerning 1]] \
      -at [list 90 [expr {$y + 4}]]
  set y [expr {$y + 16}]
}

# The page ends on an embedded face; the footer keeps it.
exampleFooter $doc serif
$doc write $target
puts "  written: $target"
