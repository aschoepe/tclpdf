#!/usr/bin/env tclsh
#
# tclpdf example 0.2 - the smallest complete program that draws a picture
#
#   tclsh examples/00.02-hello-world-svg.tcl ?output.pdf?
#
# The same shape as 00.01 - no common.tcl, no footer, no font call - with one
# line more: a drawing on the page.
#
# WHAT THE ONE LINE DOES. [$doc svg] reads the file and writes its shapes as
# PDF path operators: curves stay curves, and the logo is as sharp at 400 per
# cent as it is at 100. Nothing is rasterised, no picture is embedded, and
# "pdfimages -list" on the result lists nothing at all. That is the whole
# difference between this and pasting a PNG, and it is why it is worth an
# example of its own at the very beginning.
#
# -width scales the drawing to that width and takes the height from the
# drawing's own proportions - the logo is 500 by 250 units, so 80 mm wide
# makes it 40 mm high. Giving both would let a caller stretch it, which for a
# logo is the one thing nobody wants.
#
# WHAT IS NOT HERE, as in 00.01: no font, no colour, no unit - the defaults
# are A4 in millimetres, and the text state starts at Helvetica 12 pt. The
# auto_path line makes the package findable in an unbuilt source tree; after
# "make install" it is unnecessary.
#
# The drawing is examples/assets/images/Tcl9logo.svg. What a drawing holds,
# and what of it this package could not draw, is what [svg info] answers -
# but that is a question for 03.03, not for the shortest program that draws
# one. Nothing is asked here, and nothing is claimed about the file beyond
# what the page shows.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

set target [expr {[llength $argv] ? [lindex $argv 0] : "00.02-hello-world-svg.pdf"}]
set logo [file join $here assets images Tcl9logo.svg]

set doc [tclpdf new -format a4 -unit mm]
$doc page add
$doc svg $logo -at {20 20} -width 80
$doc text "Vectors, not pixels - the same file at any size." -at {20 70}
$doc write $target
$doc destroy

puts "  written: $target"
