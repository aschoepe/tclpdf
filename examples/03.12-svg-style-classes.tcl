#!/usr/bin/env tclsh
#
# tclpdf example 3.12 - colour from a <style> block: CSS classes in SVG
#
#   tclsh examples/03.12-svg-style-classes.tcl ?output.pdf?
#
# An SVG exporter in the Illustrator manner does not write fill="..." on the
# shapes. It writes class="cls-1" and puts the colours into a <style> block,
# mostly inside <defs>:
#
#   <defs><style>.cls-1 {fill: #0086b3;} .cls-1, .cls-2 {stroke-width: 0px;}</style></defs>
#
# Until 2026-11-25 such a drawing came out in the initial colour - black -
# and the official ZUGFeRD logo, which is built exactly like this, was a
# black rectangle. This example draws the same picture twice, once with its
# colours in class rules and once with them in style="" on every shape, and
# the two have to look the same.
#
# What is read: every <style> block of the drawing, <defs> included, as one
# stylesheet; rules whose selector is a single class, alone or in a comma
# group; the painting properties the attribute and style="" carry as well
# (fill, stroke, stroke-width, the opacities, stop-color and the rest). The
# cascade is SVG 1.1, 6.4: a class rule beats the presentation attribute,
# style="" beats the class rule, and of two class rules the later one wins.
#
# What is NOT read, and [svg info] reports it as "style": @-rules such as
# @font-face, any selector that is not one class (rect, #id, .a .b, :hover),
# a declaration marked !important, and a property a class cannot set, such
# as clip-path. The third drawing on the page shows that report.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "03.12-svg-style-classes.pdf"}]

set doc [tclpdf new -unit mm]
$doc info Title "SVG colours from CSS classes"
$doc page add

$doc font -family helvetica -style bold -size 15
$doc text "Colour from a <style> block" -at {20 24}
$doc font -style {} -size 9
$doc text "Left: the colours sit in class rules of a <style> block inside\
    <defs>, the way an Illustrator export writes them. Right: the same\
    drawing with every colour written into style=\"\" on the shape. The two\
    have to look the same." -at {20 31} -width 170

# The drawing with classes. The gradient's stops take their colours from a
# class as well, and the frame shows a comma group: .frame and .badge share
# a stroke width set once.
set classed {<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"
    viewBox="0 0 120 80">
  <defs>
    <style>
      .back { fill: #f4f6f7; }
      .frame, .badge { stroke-width: 2px; }
      .frame { fill: none; stroke: #34495e; }
      .badge { fill: #0086b3; stroke: #ffffff; }
      .arrow { fill: #e67e22; }
      .faded { opacity: 0.4; }
      .s0 { stop-color: #27ae60; }
      .s1 { stop-color: #f1c40f; }
    </style>
    <linearGradient id="bar" x1="0" y1="0" x2="1" y2="0">
      <stop class="s0" offset="0"/>
      <stop class="s1" offset="1"/>
    </linearGradient>
  </defs>
  <rect class="back" width="120" height="80"/>
  <circle class="badge" cx="34" cy="34" r="22"/>
  <g class="arrow">
    <path d="M64 20 L96 34 L64 48 Z"/>
    <path class="faded" d="M76 20 L108 34 L76 48 Z"/>
  </g>
  <rect x="10" y="62" width="100" height="10" fill="url(#bar)"/>
  <rect class="frame" x="1" y="1" width="118" height="78"/>
</svg>}

# The same drawing with style="" on every shape - what the class rules above
# stand for, written out.
set inline {<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"
    viewBox="0 0 120 80">
  <defs>
    <linearGradient id="bar" x1="0" y1="0" x2="1" y2="0">
      <stop style="stop-color:#27ae60" offset="0"/>
      <stop style="stop-color:#f1c40f" offset="1"/>
    </linearGradient>
  </defs>
  <rect style="fill:#f4f6f7" width="120" height="80"/>
  <circle style="fill:#0086b3;stroke:#ffffff;stroke-width:2px" cx="34" cy="34" r="22"/>
  <g style="fill:#e67e22">
    <path d="M64 20 L96 34 L64 48 Z"/>
    <path style="opacity:0.4" d="M76 20 L108 34 L76 48 Z"/>
  </g>
  <rect x="10" y="62" width="100" height="10" fill="url(#bar)"/>
  <rect style="fill:none;stroke:#34495e;stroke-width:2px" x="1" y="1"
      width="118" height="78"/>
</svg>}

lassign [$doc svg -data $classed -at {20 50} -width 80] -> -> -> drawnHeight
puts "  svg info, classes:  \"[$doc svg info]\" (empty = the block was read in full)"
$doc svg -data $inline -at {110 50} -width 80
puts "  svg info, style=\"\": \"[$doc svg info]\""
set captionY [expr {50 + $drawnHeight + 4}]
$doc font -size 7
$doc text "colours in class rules" -at [list 20 $captionY]
$doc text "colours in style=\"\"" -at [list 110 $captionY]

# -- the cascade -----------------------------------------------------------

set y [expr {$captionY + 14}]
$doc font -style bold -size 10
$doc text "Which one wins" -at [list 20 $y]
$doc font -style {} -size 8
$doc text "Three squares with class=\"blue\" and a rule .blue {fill: #2980b9}.\
    The first has nothing else and is blue. The second also carries\
    fill=\"#c0392b\" - a presentation attribute loses to any class rule, so\
    it stays blue. The third carries style=\"fill:#c0392b\", which beats the\
    class rule, so it is red." -at [list 20 [expr {$y + 6}]] -width 170

$doc svg -data {<svg xmlns="http://www.w3.org/2000/svg" width="120" height="30"
    viewBox="0 0 120 30">
  <style>.blue { fill: #2980b9; }</style>
  <rect class="blue" x="5" y="5" width="20" height="20"/>
  <rect class="blue" fill="#c0392b" x="50" y="5" width="20" height="20"/>
  <rect class="blue" style="fill:#c0392b" x="95" y="5" width="20" height="20"/>
</svg>} -at [list 20 [expr {$y + 24}]] -width 80

# -- what is not read ------------------------------------------------------

set y [expr {$y + 60}]
$doc font -style bold -size 10
$doc text "And what is not read" -at [list 20 $y]
$doc font -style {} -size 8
$doc text "An @font-face and an element selector in the same block. The\
    class rule beside them is applied - the circle is green - and the block\
    is reported, because two of its rules were not." \
    -at [list 20 [expr {$y + 6}]] -width 170

$doc svg -data {<svg xmlns="http://www.w3.org/2000/svg" width="60" height="30"
    viewBox="0 0 60 30">
  <style>
    @font-face { font-family: Brand; src: url(brand.woff2); }
    circle { stroke: #000000; }
    .green { fill: #27ae60; }
  </style>
  <circle class="green" cx="15" cy="15" r="12"/>
</svg>} -at [list 20 [expr {$y + 18}]] -width 40
set report [$doc svg info]
puts "  svg info, @font-face and an element selector: \"$report\""
$doc font -size 7
$doc text "\[svg info\] answers: $report" -at [list 70 [expr {$y + 26}]]

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes), [$doc page count] page(s)"
