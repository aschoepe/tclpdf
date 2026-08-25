#!/usr/bin/env tclsh
#
# tclpdf example 1.6 - a diagonal stamp
#
#   tclsh examples/01.06-stamp.tcl ?output.pdf?
#
# DRAFT, COPY, PAID - a word set diagonally across the whole page, behind or
# over the content. This is deliberately an example and not a method: the
# recipe is one measurement and one rotated text call, and a recipe that
# short is better shown than wrapped.
#
# The one thing worth taking from it is HOW the size is found: measure the
# text once at an arbitrary size, then scale - text width is linear in the
# font size, so one measurement is enough. No loop, no trial and error.
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "01.06-stamp.pdf"}]

# Set one word diagonally across the current page.
#
#   share    how much of the diagonal the word may take (0..1)
#   opacity  0..1 - a stamp is a remark on the content, not a wall in front
#            of it, so the default keeps the page readable
proc diagonalStamp {doc word args} {
    set options [dict merge {-color {0.85 0.2 0.2} -opacity 0.18 -share 0.65} $args]
    lassign [$doc page size] width height

    # The angle of the page diagonal, rising from the lower left corner to
    # the upper right - measured on the rendered page, not assumed: y grows
    # downwards, and [text -rotate] turns the same way round as the page
    # coordinates, so rising needs the positive angle.
    set pi [expr {acos(-1)}]
    set angle [expr {atan2($height, $width) * 180.0 / $pi}]

    # Width is linear in the font size: measure once, scale once.
    set probe 40
    set measured [$doc textWidth $word -family helvetica -style bold -size $probe]
    set diagonal [expr {sqrt($width * $width + $height * $height)}]
    set size [expr {$probe * [dict get $options -share] * $diagonal / $measured}]

    # Centring the word takes TWO corrections, and only one of them is an
    # option. -align center handles the length of the word along its baseline;
    # across it, -at names the BASELINE, and the letters sit entirely above
    # that line. At stamp sizes - here around 250 pt - the difference is half
    # the cap height, some 30 mm, and the word visibly hangs towards the lower
    # left corner.
    #
    # The cap height is read from the font's own metrics rather than guessed:
    # capitals reach exactly it, and DRAFT has neither descenders nor
    # lower-case letters, so the middle of the capitals IS the optical middle.
    set face [::tclpdf::afm resolve helvetica bold]
    set capHeight [expr {[dict get [::tclpdf::afm descriptor $face] CapHeight]
        / 1000.0 * $size * 25.4 / 72}]

    # The correction runs perpendicular to the baseline, so it turns with the
    # word: at 0 degrees it is straight down the page, at the diagonal it is
    # split between both axes. Measured on the rendered page - the same
    # rotation sense the angle above uses.
    set radians [expr {$angle * $pi / 180.0}]
    set x [expr {$width / 2.0 + $capHeight / 2.0 * sin($radians)}]
    set y [expr {$height / 2.0 + $capHeight / 2.0 * cos($radians)}]

    $doc save
    $doc opacity [dict get $options -opacity]
    $doc text $word -at [list $x $y] \
        -align center -rotate $angle \
        -family helvetica -style bold -size $size \
        -color [dict get $options -color]
    $doc restore
    return
}

set doc [tclpdf new -unit mm]
$doc info Title "Diagonal stamps"
$doc page add

# -- a sheet that looks like a document, stamped DRAFT ---------------------

$doc font -family helvetica -style bold -size 15
$doc text "Quotation 2026-183" -at {20 24}
$doc font -style {} -size 9
$doc text "Valid for thirty days. Prices in EUR, plus shipping." -at {20 31}

set y [$doc table -at {20 44} -width 170 -theme striped \
    -head {{Pos Item Qty Unit Total}} \
    -body {
      {1 "Bearing block, cast" 4 "12.90" "51.60"}
      {2 "Shaft 12 x 400" 2 "8.75" "17.50"}
      {3 "Retaining ring set" 1 "3.20" "3.20"}
    } \
    -foot {{{text "Sum" colSpan 4 align right} "72.30"}} \
    -columns {{width 12} {} {width 18 align right} {width 25 align decimal} {width 25 align decimal}}]

$doc font -size 8
$doc text "This sheet is readable through the stamp - that is what the low\
    opacity is for. The word scales with the page: the same call fits A4,\
    a half letter or a label." -at [list 20 [expr {$y + 8}]] -width 170

diagonalStamp $doc "DRAFT"

# What the stamp actually wrote, read off the page rather than assumed:
# [page content] is the content stream built so far, as text, and its last
# operator has to be the Q that closes the stamp's save - an opacity left in
# force would tint everything drawn after it. Reading the stream is the only
# way to see a graphics state that leaks.
set last [lindex [split [string trim [$doc page content]] \n] end]
puts "  the DRAFT stamp ends on \"$last\" - its opacity does not leak"

# -- the same recipe, other words and colours ------------------------------

# [configure] changes the document defaults from here on: every page added
# without a format of its own is A5 landscape now, while the A4 page above
# keeps the size it was given. [page add -format a5 -orientation landscape]
# would do the same for this one page only.
$doc configure -format a5 -orientation landscape
$doc page add
$doc font -family helvetica -style bold -size 13
$doc text "A5 landscape, same call" -at {15 20}
diagonalStamp $doc "PAID" -color {0.2 0.55 0.25} -opacity 0.25 -share 0.5

# And a label, 88 by 55 mm - a size no format name covers. The names are
# [tclpdf formats]; anything else is a pair of numbers in the document unit,
# and a pair is taken as it stands, so the landscape configured above does
# not turn it. The label printer takes it long side first, and the page is
# stored that way; -rotate 90 is the note to a reader to show it turned.
# /Rotate changes the display, not the content: the stamp is drawn into the
# 88 by 55 mm page as before.
puts "  named formats: [join [tclpdf formats] {, }]"
$doc page add -format {88 55} -rotate 90
diagonalStamp $doc "COPY" -color {0.25 0.35 0.65} -opacity 0.3 -share 0.7

# THE RECIPE ABOVE IS AN OPTION SINCE 2026-08-24, and the stamp keeps doing it
# by hand on purpose: what it works out is a size for a DIAGONAL, which -fit
# does not do - the box it takes is upright. The two belong side by side, so
# here is the same question in the form a caller usually has it: a line that
# has to go into a given rectangle.
#
# -fit squeezes the letters up to -shrinkLimit (85 per cent by default) and
# only then lowers the size, because a face narrowed by a few per cent is
# barely visible in one line while a smaller size is visible at once beside
# its neighbours.

$doc page add
$doc font -family helvetica -size 11
$doc text "A line fitted into a box" -at {20 20}
$doc font -size 8
$doc text "Every line below is the same string at the same 20 pt, given a\
    different box. The rectangle is drawn so the fit can be seen; the size\
    and the narrowing the fitting chose are printed beside it." \
    -at {20 26} -width 170

set line "Rechnungsnummer 2026-0815"
set y 40
foreach box {{100 8} {90 8} {60 8} {40 8}} {
  lassign $box boxWidth boxHeight
  $doc rect -at [list 20 $y] -size $box -stroke {0.7 0.7 0.7} -width 0.2
  $doc font -family helvetica -size 20
  $doc text $line -at [list 20 $y] -fit $box -anchor top
  # What the fitting chose, read back the way a caller would: the same
  # arithmetic, asked of [textWidth] before the call.
  $doc font -size 7
  set natural [$doc textWidth $line -size 20]
  $doc text "-fit $box - natural width [format %.1f $natural] mm" \
      -at [list 125 [expr {$y + 4}]]
  incr y 14
}

$doc font -size 8
$doc text "-shrinkLimit 100 forbids narrowing altogether and takes the whole\
    reduction out of the size - which is what a caller setting text beside\
    other text at the same width wants:" -at [list 20 $y] -width 170
incr y 12
$doc rect -at [list 20 $y] -size {60 8} -stroke {0.7 0.7 0.7} -width 0.2
$doc font -family helvetica -size 20
$doc text $line -at [list 20 $y] -fit {60 8} -shrinkLimit 100 -anchor top

# And the four anchors, which say what the y coordinate means. They measure
# the FACE's line box - ascender above the baseline, descender below - and not
# the ink the string happens to carry, which is what makes "Text" and "Type"
# line up.
incr y 16
$doc font -size 8
$doc text "-anchor, measured against the face's line box:" -at [list 20 $y]
incr y 8
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
# Every page as it came out, read back with an index: [page size] and
# [page content] answer for the current page without one, and for any page
# with one. The stamp sits between save and restore on each of them, so the
# q and Q of every stream have to balance.
for {set i 0} {$i < [$doc page count]} {incr i} {
    lassign [$doc page size $i] width height
    set stream [$doc page content $i]
    set saves [regexp -all -line {^q$} $stream]
    set restores [regexp -all -line {^Q$} $stream]
    puts [format "  page %d: %.0f x %.0f mm, %d save/%d restore" \
        $i $width $height $saves $restores]
}
