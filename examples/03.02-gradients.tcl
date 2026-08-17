#!/usr/bin/env tclsh
#
# tclpdf example 3.2 - gradients and tiling patterns
#
#   tclsh examples/03.02-gradients.tcl ?output.pdf?
#
# A jam label and a small chart. Both are the same two mechanisms:
#
#   shading   type 2 is axial (a direction), type 3 is radial (a centre).
#             Two colours become one exponential function; more than two are
#             stitched together, one function per segment - which is how PDF
#             expresses a multi-stop gradient at all.
#
#   pattern   a shading registered as a fill, so any shape can use it; or a
#             tile of ordinary drawing repeated across a surface.
#
# The tile is drawn exactly the way a page is - {0 0} is its top left corner.
# That works because the canvas stack lives in the core, so [line] and [rect]
# need no line of their own to draw inside a pattern.
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "03.02-gradients.pdf"}]

set doc [tclpdf new -unit mm]
$doc info Title "Gradients and patterns"
$doc page add

$doc font -family helvetica -style bold -size 15
$doc text "Gradients and patterns" -at {20 22}

# -- a label ---------------------------------------------------------------

$doc font -size 10
$doc text "A label, built from both" -at {20 34}

# The tile first, so the label can use it as a background.
$doc pattern create linen -size {2.5 2.5} -script {
    $doc line -from {0 2.5} -to {2.5 0} -stroke {0.90 0.86 0.78} -width 0.25
}
$doc shading pattern sunset axial -at {20 40} -size {70 46} \
    -colors {{0.99 0.93 0.80} {0.93 0.66 0.30}} -angle 90

$doc rect -at {20 40} -size {70 46} -radius 4 -fill {pattern sunset} \
    -stroke {0.55 0.35 0.15} -width 0.6
$doc rect -at {24 44} -size {62 38} -radius 3 -fill {pattern linen} \
    -stroke {0.75 0.60 0.35} -width 0.3

$doc font -family times -style bold -size 15 -color {0.35 0.20 0.05}
$doc text "Apricot" -at {55 58} -align center
$doc font -family times -style italic -size 9
$doc text "with vanilla, no pectin" -at {55 65} -align center
$doc font -family helvetica -style {} -size 6 -color {0.45 0.30 0.12}
$doc text "340 g  -  harvested 2026  -  keep cool after opening" \
    -at {55 76} -align center

# -- the shading types -----------------------------------------------------

$doc font -family helvetica -style bold -size 10 -color black
$doc text "Shading types 2 and 3" -at {105 34}

$doc shading axial -at {105 40} -size {40 20} -colors {white steelblue}
$doc shading axial -at {150 40} -size {40 20} \
    -colors {{0.85 0.15 0.15} {0.95 0.85 0.2} {0.15 0.55 0.25}}
$doc shading radial -at {105 66} -size {40 20} -colors {white {0.15 0.2 0.45}}
$doc shading axial -at {150 66} -size {40 20} \
    -colors {navy white} -angle 90 -extend {1 0}

$doc font -style {} -size 6
foreach {x y label} {105 63 "type 2, two colours" 150 63 "type 2, stitched"
        105 89 "type 3, radial" 150 89 "type 2, -extend {1 0}"} {
    $doc text $label -at [list $x $y]
}

# -- a chart from patterns -------------------------------------------------

$doc font -style bold -size 10
$doc text "A chart: patterns instead of colours" -at {20 102}
$doc font -style {} -size 7
$doc text "Distinguishable in monochrome, which colour alone is not." \
    -at {20 107} -width 170

$doc pattern create hatchUp -size {3 3} -script {
    $doc line -from {0 3} -to {3 0} -stroke {0.25 0.35 0.55} -width 0.35
}
$doc pattern create hatchDown -size {3 3} -script {
    $doc line -from {0 0} -to {3 3} -stroke {0.60 0.35 0.20} -width 0.35
}
$doc pattern create dots -size {3.5 3.5} -script {
    $doc circle -at {1.75 1.75} -radius 0.55 -fill {0.30 0.50 0.35}
}
$doc pattern create grid3 -size {3 3} -script {
    $doc rect -at {0 0} -size {3 3} -stroke {0.45 0.45 0.5} -width 0.25
}

set values {42 68 55 31}
set fills {{pattern hatchUp} {pattern hatchDown} {pattern dots} {pattern grid3}}
set labels {Spring Summer Autumn Winter}
set x 24
foreach value $values fill $fills label $labels {
    set height [expr {$value * 0.55}]
    $doc rect -at [list $x [expr {170 - $height}]] -size [list 26 $height] \
        -fill $fill -stroke {0.4 0.4 0.45} -width 0.3
    $doc font -size 7
    $doc text $label -at [list [expr {$x + 13}] 175] -align center
    $doc text $value -at [list [expr {$x + 13}] [expr {166 - $height}]] -align center
    incr x 34
}
$doc line -from {20 170} -to {170 170} -stroke {0.4 0.4 0.45} -width 0.4

$doc font -size 8
$doc text "A tiling pattern is a piece of content the reader repeats. It is\
    stored once, however large the area it covers - the file does not grow\
    with the surface." -at {20 186} -width 170

# -- the options ----------------------------------------------------------

$doc font -style bold -size 10
$doc text "Where a gradient runs, and how a pattern is laid" -at {20 202}

# -from and -to name the end points directly and win over -angle: a run that
# starts inside the rectangle. -stops positions the colours - only the inner
# values matter, so it takes three colours to show.
$doc shading axial -at {20 208} -size {40 20} \
    -colors {white {0.99 0.85 0.4} {0.85 0.45 0.1}} -stops {0 0.75 1} \
    -from {30 218} -to {56 218}

# A radial gradient as a sphere: -center and -radius are the outer circle,
# -innerRadius and -focus the inner one, moved off the middle so the
# highlight sits where the light comes from. -extend {0 0} stops the last
# colour at the outer circle instead of flooding the rectangle with it.
$doc shading radial -at {65 208} -size {40 20} \
    -colors {white {0.35 0.55 0.9} {0.05 0.1 0.4}} -stops {0 0.45 1} \
    -center {85 218} -radius 9.5 -innerRadius 0.5 -focus {81.5 214.5} -extend {0 0}

# Under a transformation. The direct form writes no matrix: -at and -size
# still name the rectangle in millimetres and are turned with it, and
# -matrix says that -from and -to are given as they stand - the raw operands
# of the turned space, points and y upwards, which [coords] answers.
$doc save
set turn [$doc transform -at {130 218} -rotate 15]
$doc shading axial -at {112 210} -size {36 16} -colors {white steelblue} \
    -matrix $turn -from [$doc coords 112 218] -to [$doc coords 148 218]
$doc restore

# A pattern is bound to the page and ignores the transformation in force when
# the shape is painted (ISO 32000-1 8.7.3.1): under a turn the ellipse lands
# turned and the gradient inside it would not. -matrix hands the turn to the
# pattern, and its coordinates are then read in that space - the same raw
# operands as above, [distance] for the radii. A radial pattern this time.
$doc save
set turn [$doc transform -at {175 218} -rotate -15]
$doc shading pattern orb radial -matrix $turn \
    -at [$doc coords 155 208] -size [$doc extent {40 20}] \
    -center [$doc coords 175 218] -radius [$doc distance 10] \
    -focus [$doc coords 171 214] -innerRadius [$doc distance 0.5] \
    -colors {white {0.95 0.6 0.2} {0.5 0.15 0.05}} -stops {0 0.45 1}
$doc ellipse -at {175 218} -size {40 20} -fill {pattern orb}
$doc restore

$doc font -style {} -size 6
foreach {x label} {20 "-from, -to, -stops" 65 "-center, -focus, -extend {0 0}"
        110 "direct form, -matrix" 155 "radial pattern, -matrix"} {
    $doc text $label -at [list $x 234]
}

# -step is how far apart the tiles sit: larger than the tile, and the ground
# shows through between them - a sparse dot rather than a hatch. -unit reads
# -size and -step in another unit than the document's: a quarter-inch grid.
$doc pattern create sparse -size {2 2} -step {5 5} -script {
    $doc circle -at {1 1} -radius 0.8 -fill {0.30 0.50 0.35}
}
$doc pattern create quarterInch -size {0.25 0.25} -unit in -script {
    $doc rect -at {0 0} -size {6.35 6.35} -stroke {0.45 0.45 0.5} -width 0.2
}
$doc rect -at {20 240} -size {40 20} -fill {pattern sparse} -stroke {0.4 0.4 0.45} -width 0.3
$doc rect -at {65 240} -size {40 20} -fill {pattern quarterInch} -stroke {0.4 0.4 0.45} -width 0.3
foreach {x label} {20 "-step {5 5} on a 2 mm tile" 65 "-size {0.25 0.25} -unit in"} {
    $doc text $label -at [list $x 266]
}

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes)"
puts "  patterns: [join [$doc pattern names] {, }]"
# [pattern size] answers the tile in the document unit, whatever unit it was
# given in - the quarter inch comes back as millimetres.
puts "  tile of linen: [$doc pattern size linen] mm,\
    of quarterInch: [lmap v [$doc pattern size quarterInch] {format %.2f $v}] mm"
puts "  shading patterns: [join [$doc shading names] {, }]"
$doc destroy
