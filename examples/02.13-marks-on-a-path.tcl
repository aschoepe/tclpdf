#!/usr/bin/env tclsh
#
# tclpdf example 2.13 - combining marks on a path
#
#   tclsh examples/02.13-marks-on-a-path.tcl ?output.pdf?
#
# Text on a path is set CLUSTER by cluster, not glyph by glyph, and this page
# is the reason the distinction is worth a word. A combining mark has no
# advance and no place of its own: it is set against the glyph it hangs on,
# and GPOS can only do that while the two are in the same run. Handed to the
# path singly, a mark loses its base and lands on the character after it. So
# a base and the marks that follow it travel together: they are turned by the
# tangent as ONE piece, and the path advances by the width of the BASE.
#
# WHAT THIS PAGE MEASURES rather than asserts: the same label, once spelled
# with the precomposed characters and once decomposed into letter and mark,
# is set twice on the same curve. Both come out at the same place, the same
# width and the same length of path. That is the whole claim, and a reader
# can hold the two lines against each other.
#
# THE ONE PLACE THE TWO SPELLINGS DIFFER, and it is visible: -spacing counts
# GLYPHS, not clusters. It is the character spacing of PDF, which the reader
# puts between every pair of glyphs, and a decomposed accent is a glyph. So a
# decomposed string gains one gap per mark - on a straight line and on a path
# alike, because [textWidth] counts it the same way and the path takes its
# step from that same measurement. -align stays exact in both cases, since
# what is drawn and what was measured are then the same number.
#
# WHERE IT STILL GOES WRONG: a face without mark and mkmk lookups has nothing
# to attach with, and its marks sit at the pen position as they did before
# there was any placement at all. That is a property of the face, not of the
# path - the standard fourteen do not even get that far, since a combining
# mark is outside WinAnsiEncoding and is refused by name.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf

# The footer every example draws - shared, because one copy per example is
# how a block starts drifting.
source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "02.13-marks-on-a-path.pdf"}]
set assets [file join $here assets]

set doc [tclpdf new -unit mm]
$doc info Title "Combining marks on a path"
$doc page add

# One face, and it has to be an embedded one: the standard fourteen carry no
# mark anchors and no combining characters either.
$doc font embed body [file join $assets fonts DejaVuSans.ttf]

set y 25
$doc font -family body -style bold -size 14 -color {0.20 0.30 0.45}
$doc text "Combining marks on a path" -at [list 20 $y]
set y [expr {$y + 9}]

examplePara $doc y "The same label twice on the same curve: first spelled\
    with the precomposed characters, then decomposed into letters and\
    combining marks. Text on a path is placed cluster by cluster - a base and\
    the marks hanging on it are one piece, turned once by the tangent - so\
    the two spellings come out at the same place and the same size." \
    {0.35 0.35 0.35}

# -- the curve, and the two spellings on it ----------------------------------

# Measured to carry a label of this length at 20 points with -align center:
# 179.5 mm of arc across a 160 mm span. Shifted 40 mm up the page from where
# it was measured, which changes no length - the shape is the same curve.
set curve {{move 20 80} {curve 60 20 120 140 180 70}}

# Written with escapes rather than as literal text, because the spelling is
# the subject here and a file that only LOOKS like two spellings would prove
# nothing: the first is U+00E9 and U+00E8, the second is a plain e followed
# by U+0301 and U+0300.
set composed "Caf\u00e9 Cr\u00e8me"
set decomposed "Cafe\u0301 Cre\u0300me"

# The path is not drawn by [textPath]; drawing it here is what makes the
# claim checkable - the eye can see that both lines sit on the same line.
$doc save
$doc style -stroke {0.80 0.84 0.90} -width 0.4 -dash {1 1.5}
$doc path -segments $curve
$doc restore

# Same call, same options, two spellings. -offset lifts one off the curve and
# drops the other below it, or they would be drawn on top of each other.
$doc font -family body -size 20 -color black
set length [$doc textPath $composed -segments $curve -align center -offset 2]
$doc font -family body -size 20 -color {0.20 0.35 0.55}
$doc textPath $decomposed -segments $curve -align center -offset -8

$doc font -family helvetica -style {} -size 8 -color {0.45 0.45 0.45}
$doc text "precomposed, above the curve" -at {20 105}
$doc font -family helvetica -style {} -size 8 -color {0.20 0.35 0.55}
$doc text "decomposed, below it" -at {20 110}

set y 118
$doc font -family body -size 8 -color {0.35 0.35 0.35}
$doc text [format "%d characters against %d, width %.4f mm against %.4f mm,\
    path %.4f mm" [string length $composed] [string length $decomposed] \
    [$doc textWidth $composed -size 20] [$doc textWidth $decomposed -size 20] \
    $length] -at [list 20 $y] -width 170
set y [expr {$y + 8}]

examplePara $doc y "Two characters more and the same width to the fourth\
    decimal: a combining mark has an advance of zero, so nothing on the curve\
    moves. The path steps by the width of the base and the marks ride along\
    inside its own text object, which is where GPOS can still reach them." \
    {0.35 0.35 0.35}

# -- where the two spellings do differ ---------------------------------------

$doc font -family body -style bold -size 10 -color black
$doc text "-spacing counts glyphs, not clusters" -at [list 20 $y]
set y [expr {$y + 8}]

set spacing 2
set line [list [list move 20 [expr {$y + 14}]] [list line 180 [expr {$y + 14}]]]

$doc save
$doc style -stroke {0.80 0.84 0.90} -width 0.4 -dash {1 1.5}
$doc path -segments $line
$doc restore

$doc font -family body -size 20 -color black
$doc textPath $composed -segments $line -align center -offset 2 -spacing $spacing
$doc font -family body -size 20 -color {0.20 0.35 0.55}
$doc textPath $decomposed -segments $line -align center -offset -8 -spacing $spacing

set y [expr {$y + 32}]
$doc font -family body -size 8 -color {0.35 0.35 0.35}
$doc text [format "at -spacing %s: %.4f mm against %.4f mm - %.4f mm apart,\
    which is %d points of extra gap, one per mark" $spacing \
    [$doc textWidth $composed -size 20 -spacing $spacing] \
    [$doc textWidth $decomposed -size 20 -spacing $spacing] \
    [expr {[$doc textWidth $decomposed -size 20 -spacing $spacing] \
        - [$doc textWidth $composed -size 20 -spacing $spacing]}] \
    [expr {([string length $decomposed] - [string length $composed]) * $spacing}]] \
    -at [list 20 $y] -width 170
set y [expr {$y + 8}]

examplePara $doc y "The character spacing of PDF sits between every pair of\
    GLYPHS, and a combining mark is a glyph. So the decomposed line is longer\
    by one gap per mark - here two of them - on a straight baseline exactly\
    as on a curve. Both lines are still centred on their path: -align asks\
    textWidth, and textWidth counts the same gaps that are drawn. Where the\
    two spellings must come out identical, letterspacing is the one option\
    that has to be told which spelling it is looking at." {0.35 0.35 0.35}

# -- check it yourself -------------------------------------------------------

exampleHeading $doc y "Check it yourself"
exampleCommandBlock $doc y [list \
    "qpdf --check [file tail $target]" \
    "qpdf --qdf --object-streams=disable [file tail $target] - | grep Tm" \
    "pdftotext [file tail $target] - | head -20"]

exampleFooter $doc body

$doc write $target
puts "  written: $target ([file size $target] bytes)"
$doc destroy
