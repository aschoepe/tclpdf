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

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes)"
puts "  patterns: [join [$doc pattern names] {, }]"
puts "  shading patterns: [join [$doc shading names] {, }]"
$doc destroy
