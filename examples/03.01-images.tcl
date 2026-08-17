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
#   PNG colour key   a greyscale or truecolor file whose tRNS chunk names one
#                    transparent colour: the same /Mask array, still passed
#                    through - the reader keys the colour out
#   PNG with alpha   the only computed path: decompress, un-filter, split the
#                    channel out into an /SMask
#
# Only the last one costs anything. Measured on this machine: the 640x480 RGBA
# file below takes about a third of a second, the other three are a file read.
#
# The second page shows the same pictures arriving as BYTES rather than as file
# names - the shape a web backend sees, where the image was never a file.
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

# -type names the parser: auto, the default, decides by the leading bytes;
# jpeg and png force one, and a file whose bytes disagree is then refused
# rather than guessed at.
$doc font -style {} -size 8
set x 20
foreach {alias file type label} [list \
    photo sample-photo.jpg jpeg "JPEG, DCTDecode" \
    gray sample-gray.jpg auto "JPEG, DeviceGray" \
    tile sample-indexed.png auto "PNG, Indexed + Mask" \
    logo sample-rgba.png png "PNG, SMask"] {
  set start [clock milliseconds]
  $doc image embed $alias [file join $images $file] -type $type
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
# [image size] takes the sizing options of [image place] and answers what a
# placement would come out at - for laying out around a picture.
puts "  -width 40: [$doc image size logo -width 40] mm,\
    -height 30: [$doc image size logo -height 30] mm"
puts "  -size {30 20}: [$doc image size logo -size {30 20}] mm,\
    -scale 0.1: [$doc image size logo -scale 0.1] mm,\
    -dpi 300: [$doc image size logo -dpi 300] mm"

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
# -size sets both extents and keeps no ratio - squeezed on purpose here.
# -alt is what a tagged document reads out for the picture, -artifact 1 the
# opposite: decoration on purpose. This document is untagged, so both are
# accepted and change nothing (05.07 shows them at work).
$doc image place photo -at {160 88} -size {25 12} -alt "the same photo, squeezed"
# Without any extent the natural size applies, and -dpi decides it: a pixel
# is 1/dpi of an inch, so 640 pixels at 1200 dpi are 13.5 mm - the size a
# scan would be placed at. -scale multiplies that natural size.
$doc image place photo -at {160 102} -dpi 1200 -artifact 1
$doc image place photo -at {176 102} -dpi 1200 -scale 0.7
$doc text "embedded once, placed seven times - by width, turned, faded, by height,\
    squeezed by -size, and at 1200 dpi with and without -scale 0.7" \
    -at {20 118} -width 130

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
# Pattern space hangs off the page, not off the shape (ISO 32000-1 8.7.3.1):
# without a matrix the tiles are laid from the page's bottom left corner, and
# a rectangle gets them cut at whatever phase falls on its edge - the dots
# below are halved at the left edge. -matrix takes the six raw numbers, here a
# turn by 45 degrees; -origin anchors the grid at a document point, here the
# corner of the rectangle, so the first tile sits flush in it. Both belong to
# the pattern object: the same dots anchored elsewhere are a second pattern.
set angle [expr {45 * acos(-1) / 180.0}]
$doc pattern create hatchTurned -size {3 3} \
    -matrix [list [expr {cos($angle)}] [expr {sin($angle)}] \
        [expr {-sin($angle)}] [expr {cos($angle)}] 0 0] -script {
  $doc line -from {0 3} -to {3 0} -stroke {0.55 0.6 0.72} -width 0.25
}
$doc pattern create dotsAnchored -size {4 4} -origin {171 170} -script {
  $doc circle -at {2 2} -radius 0.6 -fill {0.8 0.4 0.2}
}
$doc rect -at {108 170} -size {19 26} -fill {pattern hatch} -stroke gray -width 0.3
$doc rect -at {129 170} -size {19 26} -fill {pattern hatchTurned} -stroke gray -width 0.3
$doc rect -at {150 170} -size {19 26} -fill {pattern dots} -stroke gray -width 0.3
$doc rect -at {171 170} -size {19 26} -fill {pattern dotsAnchored} -stroke gray -width 0.3

$doc font -size 7
$doc text "hatch, 3 mm" -at {108 200}
$doc text "-matrix, turned 45" -at {129 200}
$doc text "dots, 4 mm" -at {150 200}
$doc text "-origin at the corner" -at {171 200}
$doc text "tiling patterns; the tiles hang off the page - the third is cut at its left\
    edge, the fourth begins flush at the corner it was anchored to" -at {108 204} -width 82

# -- colour key --------------------------------------------------------------

# A truecolor PNG whose tRNS chunk names one colour as transparent - the way
# a GIF-era logo carries its cut-out, and what many converters write for
# "transparent background" without an alpha channel. The magenta ground of
# this file is keyed out by the reader, so whatever is under the picture
# shows through: here a coloured field and one of the tiling patterns. The
# picture still travels untouched; only a /Mask array is added.
#
# The same file at 16 bits per sample takes another way: readers were
# measured to ignore a /Mask array at that depth (poppler compares the ranges
# as if the image were 8-bit, CoreGraphics renders it opaque too), so the key
# is decoded once and written as an /SMask of 0 and 255 - the picture itself
# still passes through at 16 bits. That decode is what the second timing
# shows; a 96x96 file costs a few milliseconds.
$doc font -style bold -size 9
$doc text "Colour key: one transparent colour, no alpha channel" -at {20 212}
$doc rect -at {20 218} -size {60 34} -fill {0.93 0.55 0.2}
$doc rect -at {85 218} -size {60 34} -fill {pattern hatch} -stroke gray -width 0.3
set start [clock milliseconds]
$doc image embed keyed [file join $images sample-keyed.png]
$doc image place keyed -at {33 220} -height 30
set spent [expr {[clock milliseconds] - $start}]
set start [clock milliseconds]
$doc image embed keyed16 [file join $images sample-keyed16.png]
$doc image place keyed16 -at {98 220} -height 30
set spent16 [expr {[clock milliseconds] - $start}]
$doc image place keyed -at {150 220} -height 30
$doc font -style {} -size 7
$doc text "8 bit: DeviceRGB + Mask, the ground shows through where the file said magenta\
    (${spent} ms, a pass-through)" -at {20 257} -width 62
$doc text "16 bit: DeviceRGB at 16 bits + SMask - a 16-bit /Mask is ignored by readers,\
    so the key becomes a mask (${spent16} ms, decoded once)" -at {85 257} -width 62
$doc text "the 8-bit file on white" -at {150 257}

# What [image info] says about the transparency of each - how it reaches the
# file: none, colourKey (a /Mask array, passed through) or softMask (an
# /SMask: the logo's alpha channel, or a computed mask) - and for the JPEGs
# the component count and bit depth, which is all a JPEG has to say.
foreach alias {tile keyed keyed16 logo} {
  set info [$doc image info $alias]
  puts "  $alias: transparency [dict get $info transparency],\
      alpha [dict get $info alpha], [dict get $info bitDepth] bit"
}
foreach alias {photo gray} {
  set info [$doc image info $alias]
  puts "  $alias: [dict get $info components] components,\
      [dict get $info bitDepth] bit"
}

exampleFooter $doc

# -- the image that never was a file ---------------------------------------

# A backend behind a web page gets its pictures as bytes: a canvas posted with
# toDataURL, a chart from a subprocess, a value out of a database. -data takes
# them as they are.
#
# The format is decided by the leading bytes in both cases, so the file name
# never took part in it - which is why passing none changes nothing about the
# result. Shown here by embedding the same picture both ways and reading back
# what the document says about the two.

$doc page add

$doc font -family helvetica -style bold -size 15 -color black
$doc text "Pictures that arrive as bytes" -at {20 22}
$doc font -style {} -size 8
$doc text "A web backend never sees a file: a canvas posted from a browser, a    chart from a subprocess, a BLOB out of a database. -data takes the bytes    themselves. Below, the same JPEG is embedded twice - once by name, once as    bytes - and the two describe themselves identically."     -at {20 30} -width 170

# Read here only to have something to pass: in the real case the bytes arrive
# over the wire and this line is a form field or a query result.
set channel [open [file join $images sample-photo.jpg] rb]
set data [read $channel]
close $channel

$doc image embed fromPath [file join $images sample-photo.jpg]
$doc image embed fromData -data $data

$doc image place fromPath -at {20 46} -width 60
$doc image place fromData -at {90 46} -width 60

$doc font -size 7 -color {0.35 0.35 0.4}
$doc text "embedded by file name" -at {20 94}
$doc text "embedded with -data" -at {90 94}

# What the two entries say about themselves, side by side. Everything but the
# path is the same, and the path is empty for the one that had none.
set rows {}
foreach key {type width height components bitDepth alpha} {
  lappend rows [list $key [dict get [$doc image info fromPath] $key]       [dict get [$doc image info fromData] $key]]
}
lappend rows [list path "sample-photo.jpg"     "(empty)"]

$doc font -family helvetica -style {} -size 9 -color black
set y [$doc table -at {20 104} -width 170 -theme striped     -head {{"what the file says" "by name" "with -data"}} -body $rows     -columns {{width 60} {} {}}]

$doc font -size 8
$doc text "The bytes are stored once even when they arrive twice: with no file    name to key the cache on, the bytes themselves are the key. Two draws of    the same picture below share one image object."     -at [list 20 [expr {$y + 8}]] -width 170

$doc image draw -data $data -at [list 20 [expr {$y + 24}]] -width 40
$doc image draw -data $data -at [list 65 [expr {$y + 24}]] -width 40
# [image draw] takes the options of [image place] as well: fitted by height
# and marked as decoration, squeezed by -size and faded, scaled and turned,
# and at its natural size for 1200 dpi.
$doc image draw -data $data -at [list 110 [expr {$y + 24}]] -height 15 -artifact 1
$doc image draw -data $data -at [list 135 [expr {$y + 24}]] -size {20 10} -opacity 0.5
$doc image draw -data $data -at [list 160 [expr {$y + 24}]] -scale 0.08 -rotate 10
$doc image draw -data $data -at [list 110 [expr {$y + 42}]] -dpi 1200

$doc font -size 7 -color {0.35 0.35 0.4}
$doc text "[llength [$doc image names]] images embedded on this page and the last"     -at [list 20 [expr {$y + 60}]]

# WHAT IT COSTS, and the one decision a backend has to make. A PNG carrying an
# alpha channel is the expensive way in - the channel is split out in pure Tcl.
# Where transparency is not needed, and for a chart on white it is not,
# toDataURL("image/jpeg") is the cheaper call.
$doc font -family helvetica -style bold -size 10 -color black
$doc text "Which format to ask the browser for" -at [list 20 [expr {$y + 72}]]
$doc font -style {} -size 8
$doc text "canvas.toDataURL() gives PNG with an alpha channel, which is the    only path that has to be computed rather than passed through. For a chart    on a white ground the channel carries nothing, and asking for image/jpeg    instead turns the most expensive way in into the cheapest."     -at [list 20 [expr {$y + 78}]] -width 170

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes)"
puts "  source pictures together: [expr {[file size [file join $images sample-photo.jpg]] +
    [file size [file join $images sample-gray.jpg]] +
    [file size [file join $images sample-indexed.png]] +
    [file size [file join $images sample-keyed.png]] +
    [file size [file join $images sample-keyed16.png]] +
    [file size [file join $images sample-rgba.png]]}] bytes"
$doc destroy
