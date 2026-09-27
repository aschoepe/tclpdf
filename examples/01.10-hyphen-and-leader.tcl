#!/usr/bin/env tclsh
#
# tclpdf example 1.10 - soft hyphens and leader rows
#
#   tclsh examples/01.10-hyphen-and-leader.tcl ?output.pdf?
#
# Two small things that decide whether a narrow column and a table of contents
# look finished or homemade.
#
# SOFT HYPHENS. U+00AD is not a character, it is a permission: "this word may
# be broken here". tclpdf does not hyphenate by itself - that needs language
# data and is a feature of its own - but text arriving from a database, an
# XML file or an editor often carries the marks already, and then the offer is
# taken: the line is filled up to the last break point that leaves room for
# the hyphen, and a real hyphen is set there. Everywhere else the mark stays
# invisible, so the same string can be set in any width.
#
# LEADER ROWS. A row with two ends and a run of dots between them, so that the
# eye keeps the line from a heading to its page number. The dots are counted,
# not guessed: both ends are measured and as many whole copies of the fill as
# fit go in between.
#
# In a tagged document the row is ONE element and the dots are an artifact - a
# reader that spelled them out would say "dot dot dot dot" between every entry
# and its number. That is why the fill is not simply text.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "01.10-hyphen-and-leader.pdf"}]
set assets [file join $here assets]

# The marks are written as \u00AD rather than pasted in: a soft hyphen is
# invisible in an editor, and a file that travels through a normalising tool
# loses it without a trace.
set soft "Die Sil\u00ADben\u00ADtren\u00ADnung ist eine Ver\u00ADbes\u00ADse\u00ADrung\
    fuer jede schmale Spalte, weil ein zu langes Wort sonst zeichen\u00ADweise\
    umbricht oder eine Zeile halb leer laesst."
set hard [string map [list "\u00AD" {}] $soft]

set doc [tclpdf new -unit mm]
$doc info Title "Soft hyphens and leader rows"
$doc page add

$doc font embed body [file join $assets fonts DejaVuSans.ttf]
$doc font embed bold [file join $assets fonts DejaVuSans-Bold.ttf]

$doc font -family bold -size 14 -color {0.20 0.30 0.45}
$doc text "Break points and leader rows" -at {20 25}

# -- the same paragraph twice ------------------------------------------------

$doc font -family body -size 9 -color {0.35 0.35 0.35}
$doc text "The same paragraph in the same column: without break points on\
    the left, with them on the right. The two strings are identical but for\
    the invisible marks. The text itself stays German - the word being\
    broken is the point of the example." -at {20 33} -width 170

set y 50
$doc font -family body -size 8 -color {0.45 0.45 0.45}
$doc text "no break points" -at [list 20 $y]
$doc text "with break points" -at [list 110 $y]

$doc font -family body -size 10 -color black
$doc text $hard -at [list 20 [expr {$y + 6}]] -width 70 -align justify
$doc text $soft -at [list 110 [expr {$y + 6}]] -width 70 -align justify

# The measurement follows: a hyphen that is drawn is a hyphen that was counted,
# so the justified right edge stays flush in both columns.

set y 100

# -- a table of contents -----------------------------------------------------

$doc font -family bold -size 10 -color black
$doc text "Contents" -at [list 20 $y]
set y [expr {$y + 8}]

$doc font -family body -size 10
foreach {entry page} {
    "1. What this is for" 3
    "2. How a document is put together" 11
    "3. Embedding fonts" 24
    "4. Tables that run over pages" 38
    "5. ZUGFeRD and PDF/A" 57} {
  set y [$doc leader $entry $page -at [list 20 $y] -width 120]
}

# -- and a total -------------------------------------------------------------

set y [expr {$y + 12}]
$doc font -family bold -size 10
$doc text "Invoice total" -at [list 20 $y]
set y [expr {$y + 8}]

$doc font -family body -size 10
foreach {item amount} {
    "Consulting, 12 hours" "1,428.00"
    "Travel" "213.60"
    "Materials" "47.90"} {
  set y [$doc leader $item $amount -at [list 20 $y] -width 120]
}

# -fill "" draws no dots at all - the row is then just two ends, which is what
# a sum line under a rule wants.
$doc line -from [list 20 [expr {$y - 1}]] -to [list 140 [expr {$y - 1}]] \
    -width 0.3
$doc font -family bold -size 10
set y [$doc leader "Total" "1,689.50" -at [list 20 [expr {$y + 4}]] \
    -width 120 -fill ""]

# -- what the fill may be ----------------------------------------------------

set y [expr {$y + 10}]
$doc font -family body -size 8 -color {0.45 0.45 0.45}
$doc text "The fill string is free to choose, and -gap keeps the distance\
    to both ends." -at [list 20 $y] -width 170
set y [expr {$y + 6}]

$doc font -family body -size 10 -color black
foreach {left right fill gap} {
    "with dashes" "A" "-" 1
    "with dots and more room" "B" "." 4
    "with a repeating run" "C" "·· " 2} {
  set y [$doc leader $left $right -at [list 20 $y] -width 120 \
      -fill $fill -gap $gap]
}

# -- the options a row takes ---------------------------------------------------
#
# A row is set with the font options of the call, like a line of [text]: the
# face and its style, the size, the colour, letter and word spacing - the
# last one counted between the copies of a fill that has a space in it. It
# takes the two line options as well. -tag names what the row IS in a tagged
# document, P unless said otherwise, and Artifact takes it out of the tree
# altogether, which is what a running head wants; this document is not
# tagged, so both are accepted here and change nothing. -direction rtl turns
# the row round: the first argument is the LEADING end and belongs at the
# right edge, the figure at the left. Set beside the contents, in the column
# the rows above leave free.
set x 145
set ry 100
$doc font -family bold -size 10 -color black
$doc text "Options on the row" -at [list $x $ry]
set ry [expr {$ry + 8}]
$doc font -family body -size 10
set ry [$doc leader "in Helvetica" "1" -at [list $x $ry] -width 45 \
    -family helvetica -style italic -size 9]
set ry [$doc leader "in a colour" "2" -at [list $x $ry] -width 45 \
    -color {0.60 0.25 0.25}]
set ry [$doc leader "letter spaced" "3" -at [list $x $ry] -width 45 -spacing 0.4]
set ry [$doc leader "word spaced" "4" -at [list $x $ry] -width 45 \
    -fill ". " -wordSpacing 2]
set ry [$doc leader "as a heading" "5" -at [list $x $ry] -width 45 -tag H2]
set ry [$doc leader "as an artifact" "6" -at [list $x $ry] -width 45 -tag Artifact]
# "total" and its amount, right to left: the word ends at the right edge.
set ry [$doc leader "סך הכל" "1.234,50" -at [list $x $ry] -width 45 -direction rtl]

# -- the spaces of Unicode as break points ------------------------------------
#
# The same amounts twice, in the same narrow column. On the left a no-break
# space stands between each number and its unit (U+00A0, UAX #14 class GL):
# the two never part, so "60 EUR" and "90 EUR" go to the next line together.
# On the right it is a thin space (U+2009, class BA): the line may end after
# it, so it does - "60" and "90" close their lines and the euro sign opens the
# next one, and the thin space at the break is not set at all. Inside a line
# the thin space is a character like any other, set with its own width, and
# stays that width when the line is justified: only the word spaces stretch
# (ISO 32000-1 9.3.3). The standard fourteen have no thin space and would
# refuse the right hand column, which is why it takes an embedded face.
set y [expr {$y + 12}]
$doc font -family body -size 8 -color {0.45 0.45 0.45}
$doc text "Two spaces between a number and its unit: the no-break space keeps\
    the two together, the thin space lets the line end between them." \
    -at [list 20 $y] -width 170
set y [expr {$y + 8}]
$doc text "no-break space, U+00A0" -at [list 20 $y]
$doc text "thin space, U+2009" -at [list 65 $y]

set amounts "Rent 1,200%1\$s\u20AC, deposit 2,400%1\$s\u20AC, key 50%1\$s\u20AC,\
    cleaning 120%1\$s\u20AC, parking 60%1\$s\u20AC and heating 90%1\$s\u20AC a\
    month - the space between each number and its unit decides whether the\
    two may part at the end of a line."
$doc font -family body -size 10 -color black
$doc text [format $amounts "\u00A0"] -at [list 20 [expr {$y + 6}]] -width 33 \
    -align justify
$doc text [format $amounts "\u2009"] -at [list 65 [expr {$y + 6}]] -width 33 \
    -align justify

exampleFooter $doc body
$doc write $target
puts "  written: $target"
