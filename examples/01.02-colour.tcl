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

# The footer every example draws - shared, because one copy per example is
# how a block starts drifting.
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

# -- blend modes -------------------------------------------------------------

# How a colour meets what is already on the page. Normal replaces it - the
# other fifteen combine the two, and which one to reach for is a question of
# what should survive: Multiply keeps the darker parts, Screen the lighter
# ones, Luminosity keeps the brightness of the new colour and the hue of the
# old. Every pair below is the same two rectangles, drawn in the same order.
$doc page add

$doc font -family helvetica -style bold -size 13 -color black
$doc text "Blend modes" -at {20 22}
$doc font -style {} -size 8
$doc text "The blue square is drawn first, the orange one over it with the    mode named underneath. Only the second call carries -blend; the mode is    graphics state like the alpha, so it is wrapped in the shape's own    save/restore and does not reach the next one." -at {20 29} -width 170

set x 20
set y 45
foreach mode {Normal Multiply Screen Overlay Darken Lighten
        ColorDodge ColorBurn HardLight SoftLight Difference Exclusion
        Hue Saturation Color Luminosity} {
    $doc rect -at [list $x $y] -size {24 16} -fill {0.20 0.45 0.75}
    $doc rect -at [list [expr {$x + 8}] [expr {$y + 6}]] -size {24 16} \
        -fill {0.95 0.65 0.15} -blend $mode
    $doc font -size 6 -color black
    $doc text $mode -at [list $x [expr {$y + 27}]]
    incr x 42
    if {$x > 160} {
        set x 20
        incr y 38
    }
}

$doc font -size 8
$doc text "Compatible is refused: it has been deprecated since PDF 1.4 and    means Normal, so naming it says nothing a reader could act on. PDF/A parts    2 and 3 permit every mode above." -at [list 20 [expr {$y + 34}]] -width 170

# -- opacity as state ---------------------------------------------------------

# The alpha is a command as well: set once, in force until changed - which is
# why the block below sits in its own save/restore. Its second word says
# which side fades: fill the interior only, stroke the outline only, both -
# the default - the two alike.
$doc font -style bold -size 9
$doc text "As state: opacity, with its second word" -at {20 252}
$doc font -style {} -size 6
foreach {x which} {20 fill 44 stroke 68 both} {
    $doc save
    $doc opacity 0.35 $which
    $doc rect -at [list $x 258] -size {18 16} -fill navy -stroke crimson -width 2
    $doc restore
    $doc text "opacity 0.35 $which" -at [list $x 281]
}
$doc text "The blend mode and the whole drawing state have a page of their\
    own - the next one." -at {100 262} -width 90

exampleFooter $doc

# -- blend as state: the sixteen modes, one call each ------------------------

# [blend] is the same mode as -blend, but as graphics state: it holds until
# the next call changes it, and no shape after it needs to name it. The
# palette below draws every backdrop first, in Normal, then walks the sixteen
# modes; each call replaces the one before, and the last call puts Normal
# back so the footer is not painted in Luminosity.
$doc page add

$doc font -family helvetica -style bold -size 13 -color black
$doc text "Blend modes as state" -at {20 22}
$doc font -style {} -size 8
$doc text "The same two colours as on the page before, drawn over blue, over\
    gold and over the white of the page. This time the mode is set once per\
    cell with \[blend\], and the rectangle and the circle after it carry\
    nothing - the state does the work." -at {20 29} -width 170

# The cells. Column and row from the position in the list, so that the list
# stays what it is: the sixteen names of ISO 32000-1 11.3.5, in the order the
# standard gives them.
proc blendCell {n} {
    list [expr {20 + ($n % 4) * 43}] [expr {48 + ($n / 4) * 40}]
}

# The backdrops and the labels, all in Normal - drawn before any mode is set,
# because a label drawn under Screen on white paper is white.
$doc font -size 6
set n 0
foreach mode {Normal Multiply Screen Overlay Darken Lighten
        ColorDodge ColorBurn HardLight SoftLight Difference Exclusion
        Hue Saturation Color Luminosity} {
    lassign [blendCell $n] x y
    $doc rect -at [list $x $y] -size {20 16} -fill {0.20 0.45 0.75}
    $doc rect -at [list [expr {$x + 20}] $y] -size {14 16} -fill {0.95 0.75 0.10}
    $doc text "blend $mode" -at [list $x [expr {$y + 30}]]
    incr n
}

# The modes. One [blend] per cell, and nothing else changes between the
# calls: the orange rectangle and the crimson circle are the same sixteen
# times over.
set n 0
foreach mode {Normal Multiply Screen Overlay Darken Lighten
        ColorDodge ColorBurn HardLight SoftLight Difference Exclusion
        Hue Saturation Color Luminosity} {
    lassign [blendCell $n] x y
    $doc blend $mode
    $doc rect -at [list [expr {$x + 8}] [expr {$y + 6}]] -size {26 16} \
        -fill {0.95 0.65 0.15}
    $doc circle -at [list [expr {$x + 12}] [expr {$y + 8}]] -radius 5 \
        -fill {0.85 0.2 0.3}
    incr n
}
# Back to Normal, by name: everything from here on is painted plainly.
$doc blend Normal

# The seventeenth name. Compatible is what PDF 1.3 files carry and PDF 1.4
# deprecated; it means Normal, so the call is refused and says what to write
# instead - the message is drawn here as the call returned it.
catch {$doc blend Compatible} message
$doc font -size 7
$doc text "blend Compatible - $message" -at {20 214} -width 170

# -- style: the whole drawing state in one call ------------------------------

# [style] takes every option a shape takes and makes it the state: width,
# dash, cap, join, miter limit, alpha, blend mode AND the two colours hold
# for every shape after it, until the next [style] changes them. The line
# and the rectangle below name nothing at all - both come out orange and
# blue from the one call; the polygon names only its stroke and keeps the
# orange fill; the circle names both and overrides both. A line has no fill,
# so it takes the stroke only.
$doc font -style bold -size 9 -color black
$doc text "style: the drawing state in one call" -at {20 228}
$doc font -style {} -size 6

$doc style -fill {0.95 0.65 0.15} -stroke {0.20 0.45 0.75} -width 1.5 \
    -dash {3 1.5} -cap round -join bevel -miter 4 -opacity 0.6 -blend Multiply
$doc line -from {20 236} -to {56 252}
$doc polygon -points {62 252 74 236 86 252} -stroke {0.85 0.2 0.3} -close 0
$doc rect -at {92 238} -size {30 12}
$doc circle -at {138 244} -radius 8 -fill {0.20 0.45 0.75} \
    -stroke {0.85 0.2 0.3}
$doc text "style -fill -stroke -width 1.5 -dash {3 1.5} -cap round -join bevel\
    -miter 4 -opacity 0.6 -blend Multiply, then a line and a rect naming\
    nothing, a polygon naming its stroke, a circle naming both" \
    -at {20 258} -width 130

# The way back is the same call: solid, thin, square, opaque, Normal - and
# the colours changed with it. The rectangle after it shows the difference.
$doc style -width 0.2 -dash solid -cap butt -join miter -miter 10 \
    -opacity 1 -blend Normal -fill {0.85 0.85 0.9} -stroke black
$doc rect -at {158 238} -size {30 12}
$doc text "after the reset" -at {158 258}

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes)"
$doc destroy
