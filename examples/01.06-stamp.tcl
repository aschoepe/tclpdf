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

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes), [$doc page count] page(s)"
$doc destroy
