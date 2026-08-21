#!/usr/bin/env tclsh
#
# tclpdf example 1.12 - text rendering modes
#
#   tclsh examples/01.12-render-modes.tcl ?output.pdf?
#
# How the glyphs are painted, rather than which glyphs they are. PDF calls it
# the text rendering mode (ISO 32000-2, 9.3.6, Table 104) and gives it eight
# values; tclpdf writes the four that paint and refuses the four that clip:
#
#   -render fill          the outlines are filled - the default, and what
#                         every text of every other example does
#   -render stroke        only the outlines are drawn, in -stroke and
#                         -strokeWidth: an outline face made from a solid one
#   -render fillStroke    filled AND outlined, which is how a heading is given
#                         a contrasting edge without a second text call
#   -render invisible     positioned, measured, extractable - and not painted.
#                         This is the mode a scanned page uses to carry its
#                         recognised text under the picture of itself.
#
# -stroke and -strokeWidth are the ordinary colour and line width of this
# package - the same values [style] and [rect] take, through the same road -
# and the width is a LINE width, read in user space (9.3.6): 0.4 mm is 0.4 mm
# whether the face is set at 12 or at 40 points.
#
# The four clipping modes are refused, and the refusal says why: a clipping
# mode turns the glyph outlines into a clipping path that takes effect at ET
# and stays in force until the next Q, while tclpdf sets one BT/ET per line -
# the second line of a paragraph would be clipped to its intersection with the
# first, which is empty. The message is printed on the page below.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "01.12-render-modes.pdf"}]

set doc [tclpdf new -unit mm]
$doc info Title "Text rendering modes"
$doc info Author "tclpdf example 1.12"
$doc page add

set y 24
exampleHeading $doc y "Text rendering modes"
examplePara $doc y "The PDF operator behind this is Tr, and it says what\
    showing a text does to the glyph outlines: fill them, stroke them, both,\
    or neither. tclpdf writes it as -render, with a word for each mode."

# -- the four modes ---------------------------------------------------------

set demo "Rechnung"
foreach {mode note} {
    fill        "the default - the outlines are filled with -color"
    stroke      "only the outline, in -stroke and -strokeWidth"
    fillStroke  "filled first, then stroked - one call, two colours"
    invisible   "drawn nowhere, and still in the file: select the line"
} {
    # A light grey fill and a dark outline, which is how the standard itself
    # illustrates the modes (9.3.6, NOTE 1): with one colour for both, filling
    # and stroking are impossible to tell apart on the page.
    $doc font -family helvetica -style bold -size 28 -color {0.74 0.78 0.86} \
        -render $mode -stroke {0.15 0.25 0.55} -strokeWidth 0.35
    $doc text $demo -at [list 20 $y] -anchor top
    $doc font -family helvetica -style {} -size 9 -color {0.3 0.3 0.35} \
        -render fill
    $doc text "-render $mode" -at [list 92 [expr {$y + 3}]] -anchor top
    $doc text $note -at [list 92 [expr {$y + 8}]] -width 98 -anchor top
    set y [expr {$y + 16}]
}

# The invisible line is there - this is what a reader gets back out of it.
$doc font -family helvetica -style italic -size 9 -color {0.45 0.45 0.5}
set y [expr {[$doc text "The fourth line above is set with -render invisible.\
    It is in the content stream, it advances the text matrix like any other\
    (9.3.6), and pdftotext gives it back - which is exactly what a scanned\
    page needs under its own picture." -at [list 20 $y] -width 170] + 6}]

# -- the width is a line width ----------------------------------------------

exampleHeading $doc y "-strokeWidth is a line width, not a font weight"
examplePara $doc y "The graphics state parameters of a stroking mode are read\
    in user space rather than in text space (9.3.6). The same 0.3 mm outline\
    is therefore the same 0.3 mm at every size - it does not grow with the\
    face, which is what makes it a rule and not a weight."

$doc font -family helvetica -style bold -color {} -render stroke \
    -stroke {0.55 0.15 0.2} -strokeWidth 0.3
set x 20
foreach size {14 22 34} {
    $doc font -size $size
    $doc text "Abc" -at [list $x $y] -anchor top
    set x [expr {$x + 12 + $size}]
}
set y [expr {$y + 16}]

# -- what is refused --------------------------------------------------------

$doc font -family helvetica -style {} -size 10 -color {0 0 0} -render fill
exampleHeading $doc y "The clipping modes are refused, by name"
catch {$doc text "x" -at {20 20} -render clip} refusal
$doc font -family courier -style {} -size 8 -color {0.5 0.15 0.15}
set y [expr {[$doc text $refusal -at [list 20 $y] -width 170 -leading 10] + 6}]

# -- check it yourself ------------------------------------------------------

$doc font -family helvetica -style {} -size 10 -color {0 0 0}
exampleHeading $doc y "Check it yourself"
exampleCommandBlock $doc y [list \
    "qpdf --check [file tail $target]" \
    "qpdf --qdf --object-streams=disable [file tail $target] - | grep Tr" \
    "pdftotext [file tail $target] - | head"]

exampleFooter $doc helvetica

$doc write $target
puts "  written: $target ([file size $target] bytes)"
$doc destroy
