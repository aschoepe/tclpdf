#!/usr/bin/env tclsh
#
# tclpdf example 1.1 - shapes, lines and clipping
#
# Run it from anywhere:
#
#   tclsh examples/01.01-shapes.tcl ?output.pdf?
#
# Shows what stage 1 provides: page setup, the drawing primitives, the three
# colour spaces, the graphics state stack and constant alpha.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

# Find the package next to this example when it has not been installed yet.
set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

# The footer every example draws - shared, because eighteen copies of it
# is how a block starts drifting.
source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "01.01-shapes.pdf"}]

# Millimetres and a page counted from the TOP left corner - PDF itself counts
# from the bottom, tclpdf converts.
set doc [tclpdf new -format a4 -orientation portrait -unit mm]

$doc info Title "tclpdf example: shapes"
$doc info Author "Alexander Schoepe"
$doc info Subject "What stage 1 can draw"

$doc page add

# -- a heading rule ---------------------------------------------------------

$doc line -from {20 20} -to {190 20} -stroke {0.15 0.35 0.6} -width 1.2

# -- rectangles: filled, stroked, both, rounded -----------------------------

$doc rect -at {20 30} -size {35 20} -fill steelblue
$doc rect -at {62 30} -size {35 20} -stroke black -width 0.4
$doc rect -at {104 30} -size {35 20} -fill #ffd700 -stroke {0.4 0.3 0} -width 0.8
$doc rect -at {146 30} -size {35 20} -fill lightseagreen -radius 4

# -- the three colour spaces, side by side ----------------------------------

# Grey, RGB and CMYK. CMYK is offered because 23.1 % of the measured corpus
# uses it - it is not colorimetric, and with an sRGB output intent it is a
# PDF/A risk, so it is a deliberate choice rather than a default.
$doc rect -at {20 60} -size {50 12} -fill 0.6
$doc rect -at {76 60} -size {50 12} -fill {rgb 0.85 0.2 0.3}
$doc rect -at {132 60} -size {50 12} -fill {cmyk 0.9 0.2 0 0.05}

# -- circles, ellipses, polygons -------------------------------------------

$doc circle -at {40 100} -radius 15 -fill {1 0.6 0} -stroke black -width 0.3
$doc ellipse -at {95 100} -size {50 30} -fill plum
$doc polygon -points {140 115 155 85 170 115} -fill crimson -stroke black -width 0.5

# -- a Bezier curve ---------------------------------------------------------

$doc curve -from {20 140} -c1 {60 120} -c2 {110 160} -to {150 140} \
    -stroke darkslateblue -width 1.5

# -- dashes and line ends ---------------------------------------------------

# In save/restore: the dash pattern is part of the graphics state and stays in
# force until something resets it - the shapes further down would come out
# dotted otherwise. That is correct PDF behaviour, not a defect, and this is
# how one deals with it.
$doc save
$doc line -from {20 155} -to {190 155} -stroke gray -width 0.6 -dash {3 2}
$doc line -from {20 162} -to {190 162} -stroke gray -width 2 -dash {0.1 4} -cap round
$doc restore

# -- transparency: the most frequent feature of the whole corpus (62.5 %) ----

$doc save
$doc opacity 0.45
$doc circle -at {70 195} -radius 22 -fill red
$doc circle -at {90 195} -radius 22 -fill green
$doc circle -at {80 210} -radius 22 -fill blue
$doc restore

# -- transformation: rotated stamp ------------------------------------------

# -at names the point to rotate ABOUT, and everything after it keeps using
# ordinary document coordinates - so the stamp really sits at 150/205.
# -translate would be a delta instead and put the shape somewhere else.
#
# Save and restore around it: a transformation stays in force for the rest of
# the page otherwise.
$doc save
$doc transform -at {150 205} -rotate 20
$doc opacity 0.35
$doc rect -at {125 197} -size {50 16} -fill {0.8 0 0}
$doc restore

# -- clipping ---------------------------------------------------------------

$doc save
$doc clip -at {20 230} -size {80 30}
foreach offset {0 6 12 18 24 30 36 42 48 54 60 66 72 78} {
  $doc line -from [list [expr {20 + $offset}] 230] \
      -to [list [expr {20 + $offset - 20}] 260] -stroke darkcyan -width 2
}
$doc restore
$doc rect -at {20 230} -size {80 30} -stroke black -width 0.3

# The same thing with an arbitrary path instead of a rectangle. The outline
# itself is never drawn - it ends in "W n" rather than in a painting operator,
# so it only decides what of the hatching below stays visible. The thin star
# drawn afterwards shows where the mask ran.
$doc save
$doc clip -segments {
  {move 130 230} {line 141 251} {line 164 254} {line 147 270}
  {line 151 293} {line 130 282} {line 109 293} {line 113 270}
  {line 96 254} {line 119 251} {close}
}
foreach offset {0 5 10 15 20 25 30 35 40 45 50 55 60 65} {
  $doc line -from [list [expr {96 + $offset}] 230] \
      -to [list [expr {96 + $offset + 24}] 295] -stroke {0.85 0.35 0} -width 2.5
}
$doc restore
$doc path -stroke {0.4 0.4 0.4} -width 0.3 -segments {
  {move 130 230} {line 141 251} {line 164 254} {line 147 270}
  {line 151 293} {line 130 282} {line 109 293} {line 113 270}
  {line 96 254} {line 119 251} {close}
}

# -- a second page, landscape, with its own boxes ---------------------------

$doc page add -orientation landscape
$doc page box crop {5 5 292 205}
$doc rect -at {10 10} -size {277 190} -stroke {0.7 0.7 0.7} -width 0.3 -dash {2 2}
$doc circle -at {148.5 105} -radius 60 -fill {cmyk 0 0.15 0.9 0} -stroke black -width 0.5

exampleFooter $doc

$doc write $target
$doc destroy

puts "written: $target"
