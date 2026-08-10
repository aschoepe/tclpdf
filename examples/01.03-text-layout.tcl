#!/usr/bin/env tclsh
#
# tclpdf example 1.3 - text layout
#
#   tclsh examples/01.03-text-layout.tcl ?output.pdf?
#
# A page from a field guide. Everything here is set in the fourteen standard
# fonts - no embedding, because none of it needs any character WinAnsi cannot
# hold, and a document that does not need an embedded face should not carry
# one.
#
# What a caller gets: alignment including justification, letter and word
# spacing, horizontal scaling, rotation, superscript and subscript, and the
# two measuring calls that make layout possible at all - [textLines] and
# [textHeight] answer "how much room will this need" without drawing it.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

# The footer every example draws - shared, because eighteen copies of it
# is how a block starts drifting.
source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "01.03-text-layout.pdf"}]

set doc [tclpdf new -unit mm]
$doc info Title "Text layout"
$doc info Author "Field guide to common lichens"
$doc page add

$doc font -family times -style bold -size 18
$doc text "Crustose lichens" -at {20 24}
$doc font -family times -style italic -size 10
$doc text "Chapter four - identification in the field" -at {20 31}
$doc line -from {20 35} -to {190 35} -stroke {0.55 0.5 0.45} -width 0.4

# -- justification ---------------------------------------------------------

set body "A crustose lichen forms a crust that adheres so tightly to the\
    substrate that it cannot be removed without destroying it. The thallus\
    lacks a lower cortex, which distinguishes it from the foliose forms\
    treated in the previous chapter. In the field the distinction is made by\
    attempting to lift an edge with a knife: a foliose thallus gives way, a\
    crustose one does not."

# How tall will this be? Asked before anything is drawn, so the heading below
# can be placed without counting lines.
$doc font -family times -style {} -size 10 -leading 14
set needed [$doc textHeight $body 82]
set lines [llength [$doc textLines $body 82]]

set y [$doc text $body -at {20 44} -width 82 -align justify -anchor top]
$doc text $body -at {108 44} -width 82 -align left -anchor top

$doc font -family helvetica -size 7
$doc text "justified - word spaces stretch" -at [list 20 [expr {$y + 3}]]
$doc text "ragged right - word spaces fixed" -at [list 108 [expr {$y + 3}]]
$doc text "measured before drawing: $lines lines, [format %.1f $needed] mm" \
    -at [list 20 [expr {$y + 8}]]

# -- alignment -------------------------------------------------------------

set y [expr {$y + 18}]
$doc font -family helvetica -style bold -size 10
$doc text "Alignment against a fixed point" -at [list 20 $y]
$doc line -from [list 105 [expr {$y + 4}]] -to [list 105 [expr {$y + 26}]] \
    -stroke {0.8 0.2 0.2} -width 0.3

$doc font -style {} -size 10
foreach {align label offset} {left "left of the mark" 8
        center "centred on it" 15  right "right of the mark" 22} {
    $doc text $label -at [list 105 [expr {$y + $offset}]] -align $align
}

# -- spacing, scaling, rotation --------------------------------------------

set y [expr {$y + 34}]
$doc font -style bold -size 10
$doc text "Spacing, scaling, position" -at [list 20 $y]
$doc font -style {} -size 11

set y [expr {$y + 8}]
$doc text "normal setting" -at [list 20 $y]
$doc text "letter spaced" -at [list 75 $y] -spacing 0.9
$doc text "word  spaced  wide" -at [list 130 $y] -wordSpacing 3

set y [expr {$y + 9}]
$doc text "condensed to 70 %" -at [list 20 $y] -stretch 70
$doc text "stretched to 130 %" -at [list 75 $y] -stretch 130
$doc text "raised" -at [list 130 $y] -rise 1.6
$doc text "lowered" -at [list 148 $y] -rise -1.6

set y [expr {$y + 12}]
$doc text "H" -at [list 20 $y] -size 14
$doc text "2" -at [list 24.6 $y] -size 9 -rise -1
$doc text "O and E = mc" -at [list 27 $y] -size 14
$doc text "2" -at [list 55 $y] -size 9 -rise 3.5
$doc font -family helvetica -size 7
$doc text "subscript and superscript through -rise" -at [list 62 $y]

# -- rotation --------------------------------------------------------------

set y [expr {$y + 16}]
$doc font -family helvetica -style bold -size 10
$doc text "Rotation" -at [list 20 $y]
$doc font -style {} -size 9
foreach angle {0 30 60 90} {
    $doc text "rotated $angle degrees" \
        -at [list [expr {24 + $angle * 0.55}] [expr {$y + 26}]] -rotate $angle
}

# -- the symbol font -------------------------------------------------------

set y [expr {$y + 40}]
$doc font -family helvetica -style bold -size 10
$doc text "Symbol and ZapfDingbats" -at [list 20 $y]
$doc font -style {} -size 7
$doc text "Two of the fourteen carry their own encoding. Declaring WinAnsi\
    for them would scramble every glyph, so tclpdf does not." \
    -at [list 20 [expr {$y + 5}]] -width 170

$doc font -family symbol -size 14
$doc text "abgdepsw \326\254\316 \245\243\263" -at [list 20 [expr {$y + 16}]]
$doc font -family zapfdingbats -size 14
$doc text "34567 nopqr" -at [list 100 [expr {$y + 16}]]

# The family has to be named here: this page ends with ZapfDingbats selected,
# and a footer inheriting it comes out as a row of symbols - present in the
# file, unreadable on the page and invisible to pdftotext.
exampleFooter $doc helvetica

$doc write $target
puts "  written: $target ([file size $target] bytes)"
$doc destroy
