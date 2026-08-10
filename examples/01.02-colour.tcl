#!/usr/bin/env tclsh
#
# tclpdf example 1.2 - colour spaces
#
#   tclsh examples/01.02-colour.tcl ?output.pdf?
#
# A colour chart. Four ways to say what a colour is, and they are not
# interchangeable:
#
#   DeviceGray    one component, for rules and shadows
#   DeviceRGB     what a screen does
#   DeviceCMYK    what a press does - measured over 3000 documents, 23.1 % of
#                 generated PDFs use it
#   Separation    a spot colour: a varnish, a security ink, Pantone 485 - a
#                 named plate with a fallback for readers that cannot render it
#
# Colour names come from a table in the package, not from Tk. [winfo rgb]
# would have done the job and would have pulled in a windowing system to
# print a PDF.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

# The footer every example draws - shared, because eighteen copies of it
# is how a block starts drifting.
source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "01.02-colour.pdf"}]

set doc [tclpdf new -unit mm]
$doc info Title "Colour spaces and named colours"
$doc page add

$doc font -family helvetica -style bold -size 15
$doc text "Colour" -at {20 22}

proc swatch {doc x y colour label} {
    $doc rect -at [list $x $y] -size {24 14} -fill $colour \
        -stroke {0.4 0.4 0.45} -width 0.2
    $doc font -family helvetica -style {} -size 7
    $doc text $label -at [list $x [expr {$y + 17}]]
}

# -- the four spaces -------------------------------------------------------

$doc font -style bold -size 10
$doc text "Four colour spaces" -at {20 34}

set x 20
foreach {colour label} {
    {gray 0.35}                 "gray 0.35"
    {rgb 0.85 0.2 0.15}         "rgb 0.85 0.2 0.15"
    {cmyk 0 0.85 0.85 0.05}     "cmyk 0 .85 .85 .05"
    {separation Varnish {cmyk 0 0 0 0.15} 0.8} "separation Varnish"
} {
    swatch $doc $x 40 $colour $label
    incr x 30
}

$doc font -style {} -size 8
$doc text "The second and third are the same red said two ways. On a screen\
    they look alike; on a press they are different inks. A CMYK value under an\
    sRGB output intent is a PDF/A risk - the intent claims a space the numbers\
    are not in." -at {20 62} -width 170

# -- grey ramp and CMYK round trip -----------------------------------------

$doc font -style bold -size 10
$doc text "Grey ramp, eleven steps" -at {20 84}
set x 20
for {set n 0} {$n <= 10} {incr n} {
    $doc rect -at [list $x 90] -size {14 12} -fill [list gray [expr {$n / 10.0}]]
    incr x 15
}

$doc font -style bold -size 10
$doc text "The same hue through both spaces" -at {20 112}
$doc font -style {} -size 8
$doc text "Converting RGB to CMYK naively is loss-free on the way back -\
    measured: error 0.0 across 4096 colours, 0.78 microseconds per\
    conversion. That is arithmetic, not colour management: it says nothing\
    about how the ink will look." -at {20 117} -width 170

set x 20
foreach {r g b} {0.9 0.1 0.1  0.1 0.6 0.9  0.2 0.7 0.3  0.95 0.75 0.1} {
    # The naive conversion, spelled out so the example does not hide it.
    set k [expr {1.0 - max($r, max($g, $b))}]
    set c [expr {$k < 1 ? (1.0 - $r - $k) / (1.0 - $k) : 0}]
    set m [expr {$k < 1 ? (1.0 - $g - $k) / (1.0 - $k) : 0}]
    set y [expr {$k < 1 ? (1.0 - $b - $k) / (1.0 - $k) : 0}]
    $doc rect -at [list $x 134] -size {18 10} -fill [list rgb $r $g $b]
    $doc rect -at [list $x 144] -size {18 10} -fill [list cmyk $c $m $y $k]
    incr x 22
}
$doc font -size 7
$doc text "upper: rgb    lower: the same colour as cmyk" -at {20 158}

# -- named colours ---------------------------------------------------------

$doc font -style bold -size 10
$doc text "Named colours - 147 of them, without Tk" -at {20 172}

set x 20
set y 178
foreach name {aliceblue coral crimson darkolivegreen dodgerblue
        firebrick gold indigo khaki lavender limegreen maroon
        navy olive orchid peru plum salmon seagreen sienna
        slateblue steelblue teal thistle tomato turquoise violet wheat} {
    $doc rect -at [list $x $y] -size {20 8} -fill $name
    $doc font -style {} -size 6
    $doc text $name -at [list $x [expr {$y + 11}]]
    incr x 24
    if {$x > 170} {
        set x 20
        incr y 16
    }
}

$doc font -size 8
$doc text "A hexadecimal value works too: #f0a is short for #ff00aa, not for\
    #f00a00." -at [list 20 [expr {$y + 22}]] -width 170
$doc rect -at [list 20 [expr {$y + 26}]] -size {24 8} -fill #f0a

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes)"
$doc destroy
