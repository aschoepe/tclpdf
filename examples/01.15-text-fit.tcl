#!/usr/bin/env tclsh
#
# tclpdf example 1.15 - one line into a given box
#
#   tclsh examples/01.15-text-fit.tcl ?output.pdf?
#
# The question a caller has when the text is fixed and the room is fixed too:
# an invoice number in a field of a form, a title in a column, a name on a
# label. [text ... -fit {w h}] answers it, and this page shows what it does
# with the same string in four different boxes.
#
# HOW IT WORKS, and why there is no loop: text width is LINEAR in the font
# size, so one measurement settles the factor. The fitting squeezes the
# letters first - up to -shrinkLimit, 85 per cent by default - and only lowers
# the size for what is still missing. That order is a judgement about reading,
# not about arithmetic: a face narrowed by a few per cent is barely visible in
# a single line, while a smaller size is visible at once beside its
# neighbours. -shrinkLimit 100 forbids narrowing altogether and takes the
# whole reduction out of the size, which is what a caller setting text beside
# other text at the same width wants.
#
# THE ONE CASE WHERE ONE MEASUREMENT IS NOT ENOUGH is -spacing and
# -wordSpacing: those are absolute point values that do NOT shrink with the
# size, so the width is a linear function with a constant term. The page
# below shows the first of the two; -wordSpacing behaves identically and is
# not drawn a second time. A second
# measurement without them separates the flat part, and the size is SOLVED
# for rather than divided out. The page below sets the same string three
# times into the same box, with no spacing, with 1 pt and with 2 pt, and
# prints how much of the box the gaps alone take: divided out rather than
# solved for, the spaced lines would come out too large and run over.
#
# WHAT IT REFUSES, in the package's own words on the page. Three of them a
# standard face can reach, and the page shows all three: a box the flat part
# of the spacing alone is wider than - no size, however small, brings that
# line inside, because the spacing does not shrink with the letters -, -fit
# together with -width, which are two different questions about the same
# rectangle, and a box under the floor of one point (below). A fourth one,
# -fit on a vertical line, is named but not shown: it sits BEHIND another
# refusal, because -direction ttb needs an embedded face and none of the
# fourteen standard ones has a vertical writing mode.
#
# AND THE THIRD ONE A STANDARD FACE CAN REACH: a box too small for anything
# this package can write into it. The floor is one point - the smallest size
# a document can be meant to carry - and -fit {0.0001 0.0001} is nowhere near
# it: it would have come out at two hundred-thousandths of a point (2.223e-05,
# the figure the refusal on the page names), written into
# the file, valid, and invisible to every reader and every printer. A box
# that small came out of an arithmetic that went wrong, and the page says so
# rather than drawing a line nobody can see.
#
# AND THE FOUR ANCHORS, because -fit is where a caller first has to say what
# the y coordinate means. They measure the FACE's line box - ascender above
# the baseline, descender below - and not the ink the string happens to
# carry, which is what makes "Text" and "Type" line up.
#
# The diagonal stamp of example 01.06 is the same question in the other form:
# what it works out is a size for a DIAGONAL, which -fit does not do - the box
# it takes is upright. The two belong side by side.
#
# Check with:  pdftotext -layout out.pdf -
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "01.15-text-fit.pdf"}]

# What the package answers when it will not fit something, read out of it
# rather than written out here: an example that quotes a refusal from memory
# is a copy that goes stale the day the wording changes.
proc fitRefusal {script} {
    if {[catch [list uplevel 1 $script] message]} {
        return $message
    }
    return "not refused - the check did not fire"
}

set doc [tclpdf new -unit mm]
$doc info Title "One line into a given box"
$doc page add

$doc font -family helvetica -style bold -size 15
$doc text "A line fitted into a box" -at {20 22}
$doc font -style {} -size 8
$doc text "Every line below is the same string at the same 20 pt, given a\
    different box. The rectangle is drawn so the fit can be seen; the box asked\
    for and the natural width of the line are printed beside it." \
    -at {20 29} -width 170

set line "Rechnungsnummer 2026-0815"
set y 40
foreach box {{100 8} {90 8} {60 8} {40 8}} {
    $doc rect -at [list 20 $y] -size $box -stroke {0.7 0.7 0.7} -width 0.2
    $doc font -family helvetica -size 20
    $doc text $line -at [list 20 $y] -fit $box -anchor top
    # What the fitting chose, read back the way a caller would: the same
    # arithmetic, asked of [textWidth] before the call.
    $doc font -size 7
    set natural [$doc textWidth $line -size 20]
    $doc text "-fit $box - natural width [format %.1f $natural] mm" \
        -at [list 125 [expr {$y + 4}]]
    incr y 12
}

$doc font -size 8
$doc text "-shrinkLimit 100 forbids narrowing altogether and takes the whole\
    reduction out of the size:" -at [list 20 $y] -width 170
incr y 7
$doc rect -at [list 20 $y] -size {60 8} -stroke {0.7 0.7 0.7} -width 0.2
$doc font -family helvetica -size 20
$doc text $line -at [list 20 $y] -fit {60 8} -shrinkLimit 100 -anchor top

# -- the flat term ---------------------------------------------------------
#
# -spacing is a point value per character and does not shrink with the size,
# so the width is a straight line with a constant term rather than a multiple.
# Three lines into the same box: the more of it the spacing takes, the less is
# left for the letters, and the size has to fall further than the ratio of the
# natural widths alone would say.
incr y 14
$doc font -size 8
$doc text "-spacing adds an absolute amount per character, which does not\
    shrink with the size. All three lines below are fitted into the same 70 by\
    8 box: the wider the spacing, the smaller what is left for the letters." \
    -at [list 20 $y] -width 170
incr y 11
foreach spacing {0 1 2} {
    $doc rect -at [list 20 $y] -size {70 8} -stroke {0.7 0.7 0.7} -width 0.2
    $doc font -family helvetica -size 20
    $doc text $line -at [list 20 $y] -fit {70 8} -anchor top -spacing $spacing
    # What the spacing alone takes: the same measurement the fitting makes, so
    # the number beside the box is the one the arithmetic worked with.
    $doc font -size 7
    set flat [expr {[$doc textWidth $line -size 20 -spacing $spacing] \
        - [$doc textWidth $line -size 20]}]
    $doc text "-spacing $spacing - [format %.1f $flat] mm of the box goes to\
        the gaps" -at [list 95 [expr {$y + 4}]]
    incr y 12
}

# -- what it will not do ---------------------------------------------------

incr y 4
$doc font -family helvetica -style bold -size 9
$doc text "What -fit refuses" -at [list 20 $y]
incr y 6
$doc font -style {} -size 7.5
foreach {what script} [list \
    "the spacing alone is wider than the box: -fit {20 8} -spacing 3" \
        {$doc text $line -at {20 200} -fit {20 8} -spacing 3} \
    "-fit together with -width" \
        {$doc text $line -at {20 200} -fit {60 8} -width 60} \
    "a box under the floor of one point: -fit {0.0001 0.0001}" \
        {$doc text $line -at {20 200} -fit {0.0001 0.0001}}] {
    $doc font -family helvetica -style italic -size 7.5
    $doc text $what -at [list 20 $y]
    $doc font -style {} -family courier -size 7
    # [text ... -width] answers the y under the last line it set, and that is
    # a double - so from here on y is advanced with [expr], not with [incr].
    set y [expr {[$doc text [fitRefusal $script] \
        -at [list 20 [expr {$y + 4}]] -width 170] + 3}]
}

# The third refusal cannot be shown on this page, and saying so is worth more
# than leaving it out: [-fit together with -direction ttb] raises
# TCLPDF TEXT VERTICAL fit, but ttb needs a TrueType or OpenType face embedded
# with [font embed], and this page is set in standard faces - so the refusal
# that answers here is the one about the FACE, not the one about fitting. A
# refusal behind a refusal is a thing to know about: the message a caller sees
# is the first check that fires, not the one the manual describes.
$doc font -family helvetica -style italic -size 7.5
$doc text "-fit on a vertical line: TCLPDF TEXT VERTICAL fit - not shown\
    here, because -direction ttb asks for an embedded face first and this\
    page has none" -at [list 20 $y] -width 170
set y [expr {$y + 12}]

# -- the four anchors ------------------------------------------------------

set y [expr {$y + 4}]
$doc font -family helvetica -style {} -size 8
$doc text "-anchor, measured against the face's line box:" -at [list 20 $y]
set y [expr {$y + 8}]
$doc line -from [list 20 $y] -to [list 190 $y] -stroke {0.8 0.3 0.3} -width 0.2
set x 22
foreach anchor {baseline top middle bottom} {
    $doc font -family helvetica -size 16
    $doc text "Typo" -at [list $x $y] -anchor $anchor
    $doc font -size 6
    $doc text $anchor -at [list $x [expr {$y + 12}]]
    incr x 42
}

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes), [$doc page count] page(s)"
# What the fitting had to work with, asked of the document rather than
# assumed. [textWidth] takes the same options [text] does, so this is the very
# measurement the fitting made - the factor is what it had to make up, first
# by narrowing and then, below -shrinkLimit, by lowering the size.
set natural [$doc textWidth $line -family helvetica -size 20]
foreach box {{100 8} {90 8} {60 8} {40 8}} {
    lassign $box boxWidth boxHeight
    puts [format "  -fit %-8s box %3d mm, natural %.1f mm at 20 pt - factor %.2f" \
        $box $boxWidth $natural [expr {$boxWidth / $natural}]]
}
$doc destroy
