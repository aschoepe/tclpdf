#!/usr/bin/env tclsh
#
# tclpdf example 3.10 - what stays visible: clip paths, masks, and fitting
#
#   tclsh examples/03.10-svg-clip.tcl ?output.pdf?
#
# Four things a drawing can say that this package did not read until
# 2026-08-25, and each of them fails DIFFERENTLY when it is ignored:
#
#   clip-path              the shape comes out whole instead of cut
#   mask                   the shape comes out opaque instead of faded
#   preserveAspectRatio    the drawing is centred where the file said cover
#   font-weight            the text comes out light
#
# The first two are visible at a glance. The last two are the dangerous
# ones: nothing is missing from the page, it is simply not what the file
# said - and [svg info] cannot report an attribute nobody looked at.
#
# Both clipping and masking are EXACT here, not approximations: a clip path
# is a PDF clipping path, and a mask is a luminosity soft mask, where the
# grey value IS the alpha. Nothing is rasterised on the way.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "03.10-svg-clip.pdf"}]

set doc [tclpdf new -unit mm]
$doc info Title "SVG clip paths, masks and fitting"
$doc page add

$doc font -family helvetica -style bold -size 15
$doc text "What stays visible" -at {20 24}
$doc font -style {} -size 9
$doc text "Each pair below is the same drawing twice: once as the file says\
    it, once with the property taken out. The difference is what the package\
    reads." -at {20 31} -width 170

# -- clip-path -------------------------------------------------------------

# The clipping shape and the shape being clipped, in one drawing. The
# clipPath itself is never drawn - it only says which part of everything
# after it reaches the page.
set clipped {<svg xmlns="http://www.w3.org/2000/svg" width="100" height="60"
    viewBox="0 0 100 60">
  <defs>
    <clipPath id="window">
      <rect x="0" y="0" width="46" height="60"/>
      <rect x="54" y="0" width="46" height="60"/>
    </clipPath>
  </defs>
  <g clip-path="url(#window)">
    <circle cx="30" cy="30" r="28" fill="#c0392b"/>
    <circle cx="70" cy="30" r="28" fill="#2980b9"/>
  </g>
</svg>}

$doc font -style bold -size 10
$doc text "clip-path" -at {20 46}
$doc font -style {} -size 8
$doc text "Two rectangles in one clipPath are ONE path with two subpaths -\
    which is what makes their union the window. Two W operators would narrow\
    it to the overlap instead, and PDF has no operator that widens one\
    again." -at {20 52} -width 170

# WHERE THE CAPTION GOES IS READ BACK, not counted out. [svg] answers the
# rectangle the drawing actually ended up in - {x y width height} - and a
# caption two millimetres under its lower edge sits right whatever the
# drawing's proportions turn out to be. Written by hand, the two captions
# below sat at y = 106 while the drawing reached to 108, and the words stood
# in the dark red circle. That is the whole reason [svg] returns the box.
lassign [$doc svg -data $clipped -at {20 66} -width 70] -> -> -> drawnHeight
$doc svg -data [string map {{clip-path="url(#window)"} {}} $clipped] \
    -at {110 66} -width 70
set captionY [expr {66 + $drawnHeight + 4}]
$doc font -size 7
$doc text "as the file says it" -at [list 20 $captionY]
$doc text "with the property removed" -at [list 110 $captionY]

# -- mask ------------------------------------------------------------------

# The mask is drawn in greys, and the grey is read as an alpha: white shows
# the shape, black hides it, and everything between fades. Here it is a
# gradient, so the bar fades out to the right - a thing no single opacity
# value can do.
set masked {<svg xmlns="http://www.w3.org/2000/svg" width="100" height="30"
    viewBox="0 0 100 30">
  <defs>
    <linearGradient id="ramp" x1="0" y1="0" x2="100" y2="0"
        gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#ffffff"/>
      <stop offset="1" stop-color="#000000"/>
    </linearGradient>
    <mask id="fade" maskUnits="userSpaceOnUse">
      <rect x="0" y="0" width="100" height="30" fill="url(#ramp)"/>
    </mask>
  </defs>
  <rect x="0" y="0" width="100" height="30" fill="#16a085" mask="url(#fade)"/>
</svg>}

$doc font -style bold -size 10
$doc text "mask" -at {20 118}
$doc font -style {} -size 8
$doc text "The mask is painted in greys and read as an alpha. White shows,\
    black hides - so a gradient in the mask fades the bar, which no single\
    opacity value can do." -at {20 124} -width 170

$doc svg -data $masked -at {20 136} -width 70
$doc svg -data [string map {{mask="url(#fade)"} {}} $masked] -at {110 136} -width 70
$doc font -size 7
$doc text "as the file says it" -at {20 161}
$doc text "with the property removed" -at {110 161}

# What the drawing reports it lost - empty here, and that is the point of
# printing it: the two properties above are drawn, not skipped.
puts "  svg info after the mask: \"[$doc svg info]\" (empty = nothing lost)"

# -- what cannot be honoured is said out loud ------------------------------

$doc font -style bold -size 10
$doc text "and what is not built" -at {20 175}
$doc font -style {} -size 8
$doc text "A filter is not drawn, and the drawing says so rather than\
    quietly coming out unfiltered. Measured over every SVG on this machine:\
    two files carry one, and the only primitive in either is feColorMatrix -\
    a per-pixel operation PDF has no operator for." -at {20 181} -width 170

$doc svg -data {<svg xmlns="http://www.w3.org/2000/svg" width="60" height="30"
    viewBox="0 0 60 30">
  <defs>
    <filter id="blur"><feGaussianBlur stdDeviation="2"/></filter>
  </defs>
  <rect x="2" y="2" width="56" height="26" fill="#8e44ad" filter="url(#blur)"/>
</svg>} -at {20 196} -width 50
puts "  svg info after the filter: \"[$doc svg info]\""

exampleFooter $doc

# -- preserveAspectRatio ---------------------------------------------------

$doc page add
$doc font -family helvetica -style bold -size 15
$doc text "preserveAspectRatio" -at {20 24}
$doc font -style {} -size 9
$doc text "A wide drawing put into a square box, once for each spelling. The\
    grey rectangle is the box asked for; the drawing is the same 2:1 picture\
    every time. meet fits it inside, slice covers the box and is cut back to\
    it, none stretches - and the alignment says which edge is kept." \
    -at {20 31} -width 170

# The picture: a 2:1 rectangle with a circle in it, so that stretching is
# visible at once - a stretched circle is an ellipse and nothing else.
proc aspectDrawing {attribute} {
  return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"200\"\
      height=\"100\" viewBox=\"0 0 200 100\" $attribute>
    <rect x=\"0\" y=\"0\" width=\"200\" height=\"100\" fill=\"#ecf0f1\"/>
    <circle cx=\"100\" cy=\"50\" r=\"45\" fill=\"#e67e22\"/>
    <rect x=\"0\" y=\"0\" width=\"200\" height=\"100\" fill=\"none\"
        stroke=\"#7f8c8d\" stroke-width=\"2\"/>
  </svg>"
}

set y 46
foreach {label attribute} {
  {xMidYMid meet (the default)} {preserveAspectRatio="xMidYMid meet"}
  {xMinYMin meet}               {preserveAspectRatio="xMinYMin meet"}
  {xMaxYMax meet}               {preserveAspectRatio="xMaxYMax meet"}
  {xMidYMid slice}              {preserveAspectRatio="xMidYMid slice"}
  {none}                        {preserveAspectRatio="none"}
} {
  # The box asked for, drawn so the fitting can be seen.
  $doc rect -at [list 20 $y] -size {40 40} -stroke {0.75 0.75 0.75} -width 0.2
  set area [$doc svg -data [aspectDrawing $attribute] -at [list 20 $y] -size {40 40}]
  $doc font -size 8
  $doc text $label -at [list 70 [expr {$y + 14}]]
  $doc font -size 7
  $doc text "drawn at [lmap n $area {format %.1f $n}]" \
      -at [list 70 [expr {$y + 20}]]
  incr y 46
}

exampleFooter $doc

# -- font-weight -----------------------------------------------------------

$doc page add
$doc font -family helvetica -style bold -size 15
$doc text "font-weight" -at {20 24}
$doc font -style {} -size 9
$doc text "SVG spells the weight as a word or as a number from 100 to 900,\
    and 600 is where bold begins. A family with no bold cut of its own -\
    every embedded one, which has a single cut per alias - is reported\
    through \[svg info\] instead of quietly coming out light." \
    -at {20 31} -width 170

$doc svg -data {<svg xmlns="http://www.w3.org/2000/svg" width="150" height="60"
    viewBox="0 0 150 60">
  <text x="4" y="14" font-family="helvetica" font-size="11">font-weight normal</text>
  <text x="4" y="30" font-family="helvetica" font-size="11"
      font-weight="bold">font-weight bold</text>
  <text x="4" y="46" font-family="helvetica" font-size="11"
      font-weight="700">font-weight 700</text>
  <g font-weight="bold">
    <text x="4" y="58" font-family="helvetica" font-size="9">inherited from the group</text>
  </g>
</svg>} -at {20 50} -width 120

puts "  svg info after the weights: \"[$doc svg info]\" (empty = every cut was there)"

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes), [$doc page count] page(s)"
