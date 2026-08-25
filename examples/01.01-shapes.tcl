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

# The footer every example draws - shared, because one copy per example is
# how a block starts drifting.
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
# circle and ellipse are one command under two names: -size on a circle draws
# an ellipse, -radius on an ellipse draws a circle.
$doc circle -at {130 100} -size {12 24} -fill {0.55 0.35 0.65}
$doc ellipse -at {182 100} -radius 8 -fill {1 0.6 0} -stroke black -width 0.3

# -- a Bezier curve ---------------------------------------------------------

$doc curve -from {20 140} -c1 {60 120} -c2 {110 160} -to {150 140} \
    -stroke darkslateblue -width 1.5
# -close joins the end back to the start, and the curve becomes a shape that
# can be filled - a leaf out of one Bezier and a straight line.
$doc curve -from {160 148} -c1 {170 122} -c2 {186 126} -to {190 132} -close 1 \
    -fill {0.75 0.88 0.7} -stroke darkslateblue -width 0.5

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
# The third circle sits at 206, not 210: at 210 its lower edge reached y =
# 232 and the clipped hatch box below starts at 230, so a violet arc stuck
# out of the box and the hatching ran across it. Two demonstrations that
# have nothing to do with each other were touching - seen at 300 dpi.
$doc circle -at {80 206} -radius 22 -fill blue
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

# -- corners and open outlines ----------------------------------------------

# How a corner is mitred only shows on a thick line. The three chevrons use
# the same points and differ in -join alone: miter runs the two edges out to
# their intersection, round arcs across it, bevel cuts it off.
set x 20
foreach join {miter round bevel} {
  $doc polygon -points [list $x 40 [expr {$x + 20}] 20 [expr {$x + 40}] 40] \
      -stroke {0.2 0.35 0.55} -width 6 -join $join -close 0
  $doc text $join -at [list [expr {$x + 20}] 16] -align center -size 8
  incr x 60
}

# -close is what tells a polygon from a polyline: the default joins the last
# point back to the first, and -close 0 leaves the outline open. Filled, the
# two look identical - it is the stroke that differs.
$doc polygon -points {210 20 240 20 225 45} -stroke crimson -width 2
$doc text "closed" -at {225 55} -align center -size 8
$doc polygon -points {250 20 280 20 265 45} -stroke crimson -width 2 -close 0
$doc text "open" -at {265 55} -align center -size 8

# -- transform, one part at a time -----------------------------------------

# The same square five times, each under one option of [transform] and each
# in its own save/restore. The grey outline is where the square would be
# without the transformation. -translate is a displacement; -scale takes one
# factor or {sx sy}; -skew two angles, the second of which is the slant of an
# italic-looking stamp; -matrix takes the six raw cm operands - points, origin
# at the bottom left - and ignores every other option, for a caller who has a
# matrix already. -at is the point to scale, turn or skew about. Several
# parts in one call compose like the same calls in sequence - translate,
# rotate, skew, scale - so the square under "-translate {6 0} -rotate 45"
# is turned about its centre and then moved 6 mm to the right, not moved
# along a turned axis.
$doc font -size 6
set y 62
foreach {label options} [list \
    "-translate {14 0}" {-translate {14 0}} \
    "-scale 0.6" {-scale 0.6} \
    "-scale {1.6 0.5}" {-scale {1.6 0.5}} \
    "-skew {0 25}" {-skew {0 25}} \
    "-translate {6 0} -rotate 45" {-translate {6 0} -rotate 45} \
    "-matrix (a mirror in x)" {matrix}] {
  $doc rect -at [list 12 $y] -size {12 12} -stroke {0.7 0.7 0.7} -width 0.2
  $doc save
  if {$options eq "matrix"} {
    # A mirror about the square's own centre line: x goes to 2c - x, and
    # the two numbers are the centre in points, which [distance] gives.
    $doc transform -matrix [list -1 0 0 1 [expr {2 * [$doc distance 18]}] 0]
  } else {
    $doc transform -at [list 18 [expr {$y + 6}]] {*}$options
  }
  $doc rect -at [list 12 $y] -size {12 12} -fill {0.2 0.45 0.75} -opacity 0.6
  $doc polygon -points [list 15 [expr {$y + 3}] 21 [expr {$y + 6}] 15 [expr {$y + 9}]] \
      -fill white
  $doc restore
  $doc text $label -at [list 34 [expr {$y + 8}]]
  incr y 20
}

# -- paths: a curve segment, the two fill rules, an even-odd clip ------------

# A leaf from -segments: two curves and a close, filled. {curve x1 y1 x2 y2 x y}
# is the segment [curve] draws as a whole shape.
$doc path -segments {{move 220 66} {curve 232 58 246 60 250 70}
    {curve 244 74 230 76 220 66} {close}} \
    -fill {0.75 0.88 0.7} -stroke darkslateblue -width 0.4
$doc text "a curve segment, closed" -at {254 69}

# The same self-intersecting star twice: nonzero (the default) counts the
# centre as inside and fills it, evenodd leaves it open.
foreach {x rule} {222 nonzero 254 evenodd} {
  $doc path -rule $rule -fill {0.85 0.35 0.1} -segments [list \
      [list move [expr {$x + 12}] 84] [list line [expr {$x + 19}] 106] \
      [list line [expr {$x}] 92] [list line [expr {$x + 24}] 92] \
      [list line [expr {$x + 5}] 106] {close}]
  $doc text "-rule $rule" -at [list [expr {$x + 12}] 111] -align center
}
# -close on a path: the last point is joined back to the first before the
# stroke, so the open corner of the triangle is drawn too.
$doc path -segments {{move 222 118} {line 240 118} {line 231 130}} \
    -stroke {0.2 0.35 0.55} -width 1.2 -close 1
$doc text "path -close 1" -at {244 125}

# A clip with -rule evenodd: two nested squares as one path, and the hatch
# is kept between them - the inner square stays open.
$doc save
$doc clip -rule evenodd -segments {
  {move 220 136} {line 250 136} {line 250 162} {line 220 162} {close}
  {move 228 143} {line 242 143} {line 242 155} {line 228 155} {close}
}
foreach offset {0 4 8 12 16 20 24 28 32 36 40 44 48 52} {
  $doc line -from [list [expr {216 + $offset}] 136] \
      -to [list [expr {216 + $offset - 12}] 162] -stroke darkcyan -width 1.2
}
$doc restore
$doc text "clip -rule evenodd" -at {254 150}

# -- line styles: caps, joins, and the two spellings of "solid" ------------

# The three caps on the same thick line, the thin line underneath showing
# where the path really ends: butt stops there, square runs half a width
# beyond it, round rounds it. Then the joins by name, and -miter: the limit
# says how far a pointed join may reach before it is cut to a bevel - 1
# bevels every join, so the second chevron loses its point.
set x 12
foreach cap {butt round square} {
  $doc line -from [list $x 178] -to [list [expr {$x + 14}] 178] \
      -stroke {0.2 0.35 0.55} -width 3 -cap $cap
  $doc line -from [list $x 178] -to [list [expr {$x + 14}] 178] -stroke white -width 0.2
  $doc text "-cap $cap" -at [list $x 186]
  incr x 22
}
set x 84
foreach {label options} {
    "-join miter" {-join miter}
    "-miter 1" {-join miter -miter 1}
    "-join round" {-join round}
    "-join bevel" {-join bevel}} {
  $doc polygon -points [list $x 182 [expr {$x + 6}] 172 [expr {$x + 12}] 182] \
      -stroke {0.2 0.35 0.55} -width 2.5 -close 0 {*}$options
  $doc text $label -at [list [expr {$x - 2}] 189]
  incr x 22
}
# -dash none and -dash solid both mean an unbroken line - and they have to
# say so: a dash set by [style] is graphics state and holds until something
# takes it back. Between the two, a line without -dash comes out dashed -
# and all three come out grey, the stroke [style] set, without naming it.
$doc save
$doc style -dash {2 1} -width 0.6 -stroke gray
$doc line -from {180 174} -to {285 174} -dash none
$doc line -from {180 179} -to {285 179}
$doc line -from {180 184} -to {285 184} -dash solid
$doc restore
$doc text "-dash none / inherited from style -dash {2 1} / -dash solid" -at {180 190}

exampleFooter $doc

$doc write $target
$doc destroy

puts "written: $target"
