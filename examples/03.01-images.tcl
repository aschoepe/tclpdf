#!/usr/bin/env tclsh
#
# tclpdf example 3.1 - images, gradients and patterns
#
#   tclsh examples/03.01-images.tcl ?output.pdf?
#
# Shows the four ways a picture can enter a PDF, and why it matters which one
# a file takes:
#
#   JPEG             passed through as /DCTDecode, never decoded
#   PNG without alpha passed through as /FlateDecode with /Predictor 15 - the
#                    reader un-filters, which it has to be able to do anyway
#   PNG palette      /Indexed, with a /Mask array when the transparency is
#                    opaque-or-nothing
#   PNG with alpha   the only computed path: decompress, un-filter, split the
#                    channel out into an /SMask
#
# Only the last one costs anything. Measured on this machine: the 640x480 RGBA
# file below takes about a third of a second, the other three are a file read.
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "03.01-images.pdf"}]
set images [file join $here assets images]

set doc [tclpdf new -unit mm]
$doc info Title "tclpdf example: images, gradients and patterns"
$doc page add

$doc font -family helvetica -style bold -size 14
$doc text "Images, gradients and patterns" -at {20 20}

# -- the four picture paths ------------------------------------------------

$doc font -style {} -size 8
set x 20
foreach {alias file label} [list \
    photo sample-photo.jpg "JPEG, DCTDecode" \
    gray sample-gray.jpg "JPEG, DeviceGray" \
    tile sample-indexed.png "PNG, Indexed + Mask" \
    logo sample-rgba.png "PNG, SMask"] {
  set start [clock milliseconds]
  $doc image embed $alias [file join $images $file]
  $doc image place $alias -at [list $x 30] -width 40
  set spent [expr {[clock milliseconds] - $start}]
  $doc text $label -at [list $x 65]
  $doc text "${spent} ms" -at [list $x 69]
  incr x 43
}

# What the picture says about itself, before anything is drawn with it.
set info [$doc image info logo]
puts "  [dict get $info width]x[dict get $info height],\
    colour type [dict get $info colorType], alpha [dict get $info alpha]"
puts "  natural size: [$doc image size logo] mm"

# -- reuse -----------------------------------------------------------------

# The same picture again: no second copy goes into the file. A logo on five
# pages costs what one costs.
$doc font -style bold -size 9
$doc text "Reuse and rotation" -at {20 82}
$doc font -style {} -size 8
$doc image place photo -at {20 88} -width 25
$doc image place photo -at {55 88} -width 25 -rotate 12
$doc image place photo -at {90 88} -width 25 -opacity 0.35
# By height instead of width: what a picture needs when it has to fit a row
# of a table or a line of text. The width follows from the aspect ratio, so
# neither has to be worked out by hand.
$doc image place photo -at {125 88} -height 18.75
$doc text "embedded once, placed four times - the last one sized by its height" \
    -at {20 118}

# -- gradients -------------------------------------------------------------

$doc font -style bold -size 9
$doc text "Gradients: shading types 2 and 3" -at {20 130}

$doc shading axial -at {20 136} -size {50 20} -colors {white steelblue}
$doc shading axial -at {80 136} -size {50 20} -colors {red yellow green} -angle 90
$doc shading radial -at {140 136} -size {45 20} -colors {white {0.2 0.3 0.6}}

$doc font -style {} -size 7
$doc text "axial, two colours" -at {20 160}
$doc text "axial, three colours (stitched)" -at {80 160}
$doc text "radial" -at {140 160}

# A gradient as a fill: registered as a pattern, then usable on any shape.
$doc shading pattern sky axial -at {20 168} -size {60 30} -colors {lightblue navy}
$doc circle -at {40 183} -radius 14 -fill {pattern sky}
$doc rect -at {60 170} -size {40 26} -fill {pattern sky} -radius 3

# -- tiling ----------------------------------------------------------------

# The tile is drawn the same way a page is - {0 0} is its top left corner, and
# every shape works inside it unchanged.
$doc pattern create hatch -size {3 3} -script {
  $doc line -from {0 3} -to {3 0} -stroke {0.55 0.6 0.72} -width 0.25
}
$doc pattern create dots -size {4 4} -script {
  $doc circle -at {2 2} -radius 0.6 -fill {0.8 0.4 0.2}
}
$doc rect -at {110 170} -size {35 26} -fill {pattern hatch} -stroke gray -width 0.3
$doc rect -at {150 170} -size {35 26} -fill {pattern dots} -stroke gray -width 0.3

$doc font -size 7
$doc text "tiling pattern, 3 mm" -at {110 200}
$doc text "tiling pattern, 4 mm" -at {150 200}

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes)"
puts "  source pictures together: [expr {[file size [file join $images sample-photo.jpg]] +
    [file size [file join $images sample-gray.jpg]] +
    [file size [file join $images sample-indexed.png]] +
    [file size [file join $images sample-rgba.png]]}] bytes"
$doc destroy
