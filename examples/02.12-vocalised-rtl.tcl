#!/usr/bin/env tclsh
#
# tclpdf example 2.12 - vocalised right-to-left text
#
#   tclsh examples/02.12-vocalised-rtl.tcl ?output.pdf?
#
# Hebrew nikud and Arabic harakat are combining marks: they carry no advance
# of their own and have to be hung under, over or inside the letter in front
# of them. Where they are is not in the character map - it is in the GPOS
# table of the face, as an anchor on the letter and an anchor on the mark.
# tclpdf reads those anchors, so a vocalised line is set rather than refused,
# and this page shows the same words with and without their points.
#
# THE MEASURABLE PART, and it is why both spellings stand side by side: a
# mark has zero advance, so the vocalised line is EXACTLY as wide as the bare
# one. The page prints both widths. A paragraph therefore breaks at the same
# place whether the text is pointed or not, and a table column does not have
# to be widened for the points.
#
# TWO KINDS OF FACE, and only the second one shows the whole feature. DejaVu
# Sans writes an Arabic letter as one finished glyph. Noto Naskh Arabic does
# not: it writes an undotted skeleton and hangs the dots on it as separate
# glyphs, produced by the GSUB feature ccmp and then placed by the same GPOS
# anchors the vowel signs use. A face of the second kind used to be refused
# for exactly that reason. It is not any more - the dots land where the
# anchors put them - and it is the face on which "the marks are placed" means
# something a reader can check with the eye.
#
# THE COUNTER-EXAMPLE BELONGS ON THE PAGE. Tibetan is still refused, and not
# because of mark placement: a Tibetan syllable is not a mark on a letter but
# a STACK, which a shaper builds by substituting letter and mark for one
# precomposed glyph through the GSUB features abvs and blws. An anchor cannot
# produce a glyph the character map does not lead to, so the refusal stands
# and says so. The message is caught and printed on the page - an example
# that shows only what works says something untrue about the release.
#
# WHAT IS NOT CLAIMED HERE. The Thaana fili and the Samaritan points take the
# same road and are no longer refused either, but no face on this machine
# carries either script, so they are not on this page: the decision rests on
# the mechanism, not on a picture anyone has seen.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

# The footer every example draws - shared, because one copy per example is
# how a block starts drifting.
source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "02.12-vocalised-rtl.pdf"}]
set assets [file join $here assets]

set doc [tclpdf new -unit mm]
$doc info Title "Vocalised right-to-left text"
$doc page add

# DejaVu Sans carries Hebrew and Arabic as whole letters; Noto Naskh Arabic
# carries the skeleton-plus-dots kind of Arabic. Both are needed - see the
# header.
$doc font embed body [file join $assets fonts DejaVuSans.ttf]
$doc font embed naskh [file join $assets fonts google NotoNaskhArabic-Variable.ttf]
$doc font embed tibetan [file join $assets fonts google NotoSerifTibetan-Variable.ttf]

set y 25
$doc font -family body -style bold -size 14 -color {0.20 0.30 0.45}
$doc text "Vocalised right-to-left text" -at [list 20 $y]
set y [expr {$y + 9}]

examplePara $doc y "Nikud and harakat are combining marks. They have no width\
    and no place of their own: the face states an anchor on the letter and an\
    anchor on the mark, and the two are brought together by GPOS. tclpdf\
    reads those anchors, so the pointed spelling is set instead of refused -\
    and because a mark carries no advance, it is set in exactly the same room\
    as the bare one." {0.35 0.35 0.35}

# -- Hebrew, pointed and bare ------------------------------------------------

# The right edge, not the left: under -direction rtl, -at marks the edge the
# line STARTS at, which is the right hand one.
set edge 190

set hebrewPointed "שָׁלוֹם"
set hebrewBare "שלום"

$doc font -family body -style bold -size 10 -color black
$doc text "Hebrew" -at [list 20 $y]
set y [expr {$y + 8}]

foreach {string caption} [list \
    $hebrewPointed "with nikud" \
    $hebrewBare "without" ] {
  $doc font -family body -size 24 -color black
  $doc text $string -at [list $edge $y] -direction rtl
  $doc font -family helvetica -style {} -size 8 -color {0.45 0.45 0.45}
  $doc text $caption -at [list 20 $y]
  $doc font -family body -size 8 -color {0.45 0.45 0.45}
  $doc text [format "%d characters, %.3f mm" [string length $string] \
      [$doc textWidth $string -family body -size 24 -direction rtl]] \
      -at [list 45 $y]
  set y [expr {$y + 12}]
}

examplePara $doc y "Seven characters against four, and the same width to the\
    thousandth of a millimetre. The points are drawn where the anchors of\
    DejaVu Sans put them - measured against HarfBuzz, 366 of 366\
    consonant-and-point pairs of that face agree to the unit. Not every face\
    is that clean: in Liberation Sans, Liberation Serif and Arimo, 25 of 1188\
    pairs sit 25 units of 2048 out - a hundredth of an em, all of them the\
    holam, because those faces refine it in a chaining contextual lookup\
    (GPOS type 8) that tclpdf does not read." {0.35 0.35 0.35}

# -- Arabic, in both kinds of face -------------------------------------------

set arabicPointed "مَرْحَبًا"
set arabicBare "مرحبا"

$doc font -family body -style bold -size 10 -color black
$doc text "Arabic, in two faces that are built differently" -at [list 20 $y]
set y [expr {$y + 8}]

foreach {family label} {body {DejaVu Sans - whole letters}
                        naskh {Noto Naskh Arabic - skeleton plus dot glyphs}} {
  $doc font -family helvetica -style {} -size 8 -color {0.45 0.45 0.45}
  $doc text $label -at [list 20 $y]
  set y [expr {$y + 6}]
  foreach string [list $arabicPointed $arabicBare] {
    $doc font -family $family -size 24 -color black
    $doc text $string -at [list $edge $y] -direction rtl
    $doc font -family body -size 8 -color {0.45 0.45 0.45}
    $doc text [format "%d characters, %.3f mm" [string length $string] \
        [$doc textWidth $string -family $family -size 24 -direction rtl]] \
        -at [list 20 $y]
    set y [expr {$y + 11}]
  }
  set y [expr {$y + 1}]
}

examplePara $doc y "Both faces set the word with its harakat, and the second\
    one is the interesting half: every dot under the beh and over the noon of\
    that face is a glyph of its own, made by ccmp and placed by the same\
    anchors. A face of that kind was refused while mark attachment was\
    missing, because its dots would have landed beside their letters rather\
    than on them." {0.35 0.35 0.35}

# -- what is still refused, and why ------------------------------------------

$doc font -family body -style bold -size 10 -color black
$doc text "Tibetan is still refused, for a different reason" -at [list 20 $y]
set y [expr {$y + 8}]

# The letters set - they are one glyph each and stand side by side.
$doc font -family tibetan -size 22 -color black
$doc text "ཀ ཁ ག ང ཅ" -at [list 20 $y]
set y [expr {$y + 12}]

# The stack does not, and the message says what is in the way. Caught rather
# than avoided: what the release refuses is part of what the release is.
set stacked "སྐད"
if {[catch {$doc text $stacked -at [list 20 $y] -family tibetan -size 22} \
    message]} {
  $doc font -family helvetica -style {} -size 8 -color {0.55 0.20 0.20}
  set y [expr {[$doc text $message -at [list 20 $y] -width 170] + 4}]
} else {
  $doc font -family helvetica -style {} -size 8 -color {0.55 0.20 0.20}
  set y [expr {[$doc text "no refusal - the package has changed under this\
      example" -at [list 20 $y] -width 170] + 4}]
}

# And what the escape hatch draws instead: three glyphs in logical order,
# where a shaper builds one. -unshaped 1 is the option for the caller who
# knows that isolated glyphs are better than nothing - it is not an answer to
# the stack, it is a decision to do without it.
$doc font -family helvetica -style {} -size 8 -color {0.45 0.45 0.45}
$doc text "the same syllable with -unshaped 1:" -at [list 20 $y]
$doc font -family tibetan -size 22 -color black
$doc text $stacked -at [list 70 $y] -unshaped 1
set y [expr {$y + 11}]

examplePara $doc y "A single vowel sign on a single letter is placed here\
    exactly as HarfBuzz places it - 160 of 160 pairs of Noto Serif Tibetan.\
    It is the syllable that fails: HarfBuzz replaces letter and mark with one\
    precomposed stack glyph, so \"skad\" is two glyphs there and three here.\
    Anchors cannot supply a glyph the character map does not lead to, which\
    is why the whole block of stacking marks stays refused and the message\
    names GSUB rather than mark placement." {0.35 0.35 0.35}

# -- check it yourself -------------------------------------------------------

exampleHeading $doc y "Check it yourself"
exampleCommandBlock $doc y [list \
    "qpdf --check [file tail $target]" \
    "qpdf --qdf --object-streams=disable [file tail $target] - | grep TJ" \
    "pdftotext [file tail $target] - | head -20"]

exampleFooter $doc body

$doc write $target
puts "  written: $target ([file size $target] bytes)"
$doc destroy
