#!/usr/bin/env tclsh
#
# tclpdf example 1.2 - colour spaces
#
#   tclsh examples/01.02-colour.tcl ?output.pdf?
#
# A colour chart. Seven ways to say what a colour is, and they are not
# interchangeable:
#
#   DeviceGray    one component, for rules and shadows
#   DeviceRGB     what a screen does
#   DeviceCMYK    what a press does - measured over 3000 documents, 23.1 % of
#                 generated PDFs use it
#   Separation    a spot colour: a varnish, a security ink, Pantone 485 - a
#                 named plate with a fallback for readers that cannot render it
#   ICCBased      numbers anchored to an ICC profile instead of to the device -
#                 measured over 539 foreign PDFs, 302 carry one; the profile is
#                 registered once under an alias and travels in the file once
#   Lab           a colour as it was MEASURED, anchored to a white point - the
#                 space the pressroom asks for, and the way to give a spot
#                 colour its real value instead of a CMYK guess (page 2)
#   DeviceN       several named plates at once, with one function that says
#                 what they look like together - the space high-fidelity
#                 printing is done in (page 3)
#
# Two more pages follow the chart: the blend modes, once per call as -blend
# and once as graphics state, and a page on why there are two colour models
# at all.
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
set auto_path [linsert $auto_path 0 [file dirname $here]]
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

# -- the five spaces -------------------------------------------------------

# The ICC based space wants its profile registered first: once per document,
# under an alias every later fill, stroke and text colour uses. The profile
# stream is written on first use and stands in the file exactly once.
$doc icc embed chart [file join [file dirname $here] icc sRGB2014.icc]

$doc font -style bold -size 10
$doc text "Five colour spaces" -at {20 34}

set x 20
foreach {colour label} {
    {gray 0.35}                 "gray 0.35"
    {rgb 0.85 0.2 0.15}         "rgb 0.85 0.2 0.15"
    {cmyk 0 0.85 0.85 0.05}     "cmyk 0 .85 .85 .05"
    {separation Varnish {cmyk 0 0 0 0.15} 0.8} "separation Varnish"
    {icc chart 0.85 0.2 0.15}   "icc chart (sRGB)"
} {
    swatch $doc $x 40 $colour $label
    incr x 30
}

$doc font -style {} -size 8
$doc text "The second and third are the same red said two ways. On a screen\
    they look alike; on a press they are different inks. A CMYK value under an\
    sRGB output intent is a PDF/A risk - the intent claims a space the numbers\
    are not in. The fifth is the same red a third way: the numbers of the\
    second, anchored to the sRGB2014 profile - device independent, so it\
    passes under any PDF/A output intent." -at {20 62} -width 170

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
$doc text "Named colours - 148 of them, without Tk" -at {20 172}

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

# -- Lab: the colour as it was measured --------------------------------------
#
# Its own page rather than a sixth swatch on the one before, because Lab is
# the only space here whose PARAMETERS are worth showing: the same three
# numbers are a different colour under a different white point, and a value
# outside the range is pulled back into it without a word. Both are visible
# further down.
#
# This is also where the decision NOT to ship a colour catalogue is paid for.
# The named colours of a spot colour system are licensed data; what the
# pressroom actually needs is the measurement behind the name, and that is
# three numbers the caller has - out of a colour book, or off a
# spectrophotometer.
$doc page add

$doc font -family helvetica -style bold -size 13 -color black
$doc text "Lab" -at {20 22}
$doc font -style {} -size 8
$doc text "L* runs from 0 to 100, a* from green to red and b* from blue to\
    yellow; both of those run over the range the space names, -100 to 100\
    unless -range says otherwise (ISO 32000-2, 8.6.5.4). The numbers are not\
    0..1 like every other space on the page before - a Lab colour clamped to\
    that range would come out black." -at {20 29} -width 170

# -- the two axes ------------------------------------------------------------

$doc font -style bold -size 10
$doc text "L*, at a* 0 and b* 0" -at {20 48}
set x 20
foreach L {0 10 20 30 40 50 60 70 80 90 100} {
    $doc rect -at [list $x 53] -size {14 12} -fill [list lab $L 0 0]
    incr x 15
}

$doc font -style bold -size 10
$doc text "a* and b* at L* 60" -at {20 78}
set x 20
foreach {a b label} {-60 0 "a -60" -30 0 "a -30" 0 0 "0 0" 30 0 "a 30" 60 0 "a 60"
        0 -60 "b -60" 0 -30 "b -30" 0 30 "b 30" 0 60 "b 60"} {
    $doc rect -at [list $x 83] -size {17 12} -fill [list lab 60 $a $b]
    $doc font -style {} -size 6
    $doc text $label -at [list $x 99]
    incr x 19
}

# -- the white point ---------------------------------------------------------

# WhitePoint is required by Table 64 and constrained by it: Xw and Zw
# positive, Yw exactly 1.0. The package defaults to D50, the illuminant of
# the ICC profile connection space and of every printed measurement (ISO
# 13655) - which is what a colour book gives. The example in 8.6.5.4 uses the
# D65 point instead, right for a value converted out of sRGB, and -whitePoint
# takes it.
$doc font -style bold -size 10
$doc text "The same three numbers under two white points" -at {20 114}
$doc font -style {} -size 8
$doc text "Left the default D50, right the D65 point of the example in\
    8.6.5.4. Nothing about the colour changed - only the light it is measured\
    under, and that is a property of the SPACE, not of the value."\
    -at {20 119} -width 170

set x 20
foreach {L a b} {54.29 80.82 69.88  87.82 -79.28 80.98  29.57 68.30 -112.05} {
    $doc rect -at [list $x 132] -size {24 14} -fill [list lab $L $a $b]
    $doc rect -at [list [expr {$x + 26}] 132] -size {24 14} \
        -fill [list lab $L $a $b -whitePoint {0.9505 1.0 1.0890}]
    $doc font -size 6
    $doc text "D50 / D65" -at [list $x 149]
    incr x 58
}

# -- what the range does -----------------------------------------------------

$doc font -style bold -size 10
$doc text "Outside the range, and the way past it" -at {20 162}
$doc font -style {} -size 8
$doc text "The third pair above is sRGB blue, whose b* is -112.05 - outside\
    the default range, so it is pulled back to -100. The standard says to do\
    that silently: \"Component values falling outside the specified range\
    shall be adjusted to the nearest valid value without error indication\".\
    The wider range of the example in 8.6.5.4 lets it through."\
    -at {20 167} -width 170

$doc rect -at {20 186} -size {24 14} -fill {lab 29.57 68.30 -112.05}
$doc rect -at {46 186} -size {24 14} \
    -fill {lab 29.57 68.30 -112.05 -range {-128 127 -128 127}}
$doc font -size 6
$doc text "default range / -range {-128 127 -128 127}" -at {20 203}

# -- the spot colour ---------------------------------------------------------

# The point of the whole page. A separation says WHICH plate; its alternate
# says what a reader without that ink should paint instead - and a measured
# Lab value is a far better answer there than a CMYK guess. Tint 0 is no ink
# at all, which in Lab is L* 100: paper, not black.
$doc font -style bold -size 10
$doc text "A spot colour with a Lab alternate" -at {20 216}
$doc font -style {} -size 8
$doc text "One plate, eleven coverages. The name is what the pressroom will\
    call it; the three numbers are what it measured. No colour catalogue is\
    shipped with this package - the data is licensed - and this is the way\
    that needs none." -at {20 221} -width 170

set x 20
for {set n 0} {$n <= 10} {incr n} {
    $doc rect -at [list $x 238] -size {14 12} \
        -fill [list separation "Spot Red" {lab 48.3 68.5 47.3} [expr {$n / 10.0}]]
    incr x 15
}
$doc font -size 6
$doc text "separation \"Spot Red\" {lab 48.3 68.5 47.3}, tint 0 to 1" -at {20 255}

$doc font -style {} -size 8
$doc text "Lab is device independent like an ICC based colour, so PDF/A\
    admits it under every output intent - measured with veraPDF: the page\
    above passes 3B under an sRGB, a grey and a CMYK intent alike, where the\
    same colours as {rgb ...} are refused under the CMYK one. A gradient\
    cannot take a Lab colour: a shading names its space by family in its\
    dictionary, and a Lab space is an array." -at {20 264} -width 170

# -- DeviceN: several plates at once -----------------------------------------

# A separation is one plate. A DeviceN colour space is n of them, and it is
# not the same thing said n times: the space carries ONE function that turns
# n tints into the alternate colour space, so what it describes is how the
# inks look TOGETHER. Six colourants is the real case - PANTONE Hexachrome,
# CMYK plus orange and green - and two is enough to see it.
$doc page add

$doc font -family helvetica -style bold -size 15 -color black
$doc text "DeviceN" -at {20 22}

$doc font -style {} -size 8
$doc text "Each colourant is written the way a separation is: the name of the\
    plate and the colour it paints at full tint. The tints follow in the same\
    order, one per name. Below, an orange and a green plate crossed - the top\
    row and the left column are each plate on its own, and every other square\
    is the two of them overprinting." -at {20 29} -width 170

set inks {{Orange {cmyk 0 0.45 1 0}} {Green {cmyk 0.8 0 0.7 0.1}}}

$doc font -size 6
$doc text "Green" -at {20 46}
set x 32
foreach tint {0 0.2 0.4 0.6 0.8 1} {
    $doc text "Orange $tint" -at [list $x 46]
    incr x 24
}

set y 48
foreach green {0 0.2 0.4 0.6 0.8 1} {
    $doc font -size 6
    $doc text $green -at [list 20 [expr {$y + 9}]]
    set x 32
    foreach orange {0 0.2 0.4 0.6 0.8 1} {
        $doc rect -at [list $x $y] -size {22 14} \
            -fill [list devicen $inks [list $orange $green]]
        incr x 24
    }
    incr y 18
}

# The guideline of 8.6.6.5: a colourant should look the same whether it is
# painted through a separation or as one component of a DeviceN space. It
# does here, because both transforms are built from the same colour - the
# left square below is the separation, the right one the DeviceN space with
# the other plate at zero.
$doc font -style bold -size 10
$doc text "One plate, two ways" -at {20 164}
$doc rect -at {20 170} -size {24 14} -fill {separation Orange {cmyk 0 0.45 1 0} 1}
$doc rect -at {48 170} -size {24 14} -fill [list devicen $inks {1 0}]
$doc rect -at {80 170} -size {24 14} \
    -fill {devicen {{Orange {cmyk 0 0.45 1 0}} {None} {Green {cmyk 0.8 0 0.7 0.1}}} {1 1 0}}
$doc font -style {} -size 6
$doc text "separation Orange" -at {20 188}
$doc text "devicen, green 0" -at {48 188}
$doc text "with a None plate at 1" -at {80 188}

$doc font -style {} -size 8
$doc text "None is the third colourant of the square on the right, at full\
    tint - and it changes nothing: a component named None is never painted\
    (ISO 32000-2, 8.6.6.5) and this writer keeps it out of the fallback\
    colour as well. All, which a separation may be, is refused here: it means\
    every plate at once and cannot be one component among several. Both are\
    the standard's rules, and they differ from the ones for a separation."\
    -at {20 196} -width 170

$doc text "The tint transform is a type 4 function - PostScript calculator\
    code - because a type 2 or type 3 function takes ONE input by definition\
    and this one needs n. Ink amounts add and are clipped by the function's\
    own /Range; in an RGB or grey alternate, where the numbers count light\
    rather than ink, they multiply instead, so no ink at all leaves paper.\
    The space also carries a /Colorants attribute holding each plate on its\
    own - the one thing a combined transform cannot say - which is why a\
    DeviceN colour is written as PDF 1.6 here. Under PDF/A the alternate\
    space is what the output intent judges: these plates fall back to CMYK,\
    so the document needs a CMYK intent, exactly as a separation with a CMYK\
    alternate does." -at {20 218} -width 170

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

# ---------------------------------------------------------------------------
# Page 6: why there are two colour models at all
# ---------------------------------------------------------------------------
#
# The two diagrams every colour chapter opens with, drawn with the blend modes
# rather than with pre-computed overlaps: three circles, one call each, and
# the intersections come out of the arithmetic.
#
# WHAT THE TWO GROUNDS MEAN, and it is the whole lesson: additive mixing is
# LIGHT and starts from BLACK - no light at all - so the diagram needs a black
# panel under it and Screen to add. Subtractive mixing is INK and starts from
# WHITE - bare paper - so its diagram stands on the page as it is and
# Multiply takes away. Put the RGB circles on white paper and Screen paints
# everything white, which is not a drawing error but the model saying that
# there is nothing left to add.
$doc page add
$doc font -family helvetica -style bold -size 15 -color black
$doc text "Why there are two colour models" -at {20 22}
$doc font -style {} -size 9
$doc text "Both diagrams are three circles and nothing else. What differs is\
    the ground they stand on and the blend mode: light adds up from black,\
    ink takes away from white." -at {20 29} -width 170

# -- additive: light, from black --------------------------------------------
$doc font -style bold -size 11
$doc text "RGB - additive, light" -at {20 46}
$doc font -style {} -size 8
$doc text "Screen on a black panel. Where two lights overlap the result is\
    brighter; all three make white." -at {20 52} -width 78

$doc rect -at {20 58} -size {78 74} -fill black
foreach {colour cx cy} {
    {1 0 0}  59 82
    {0 1 0}  70 102
    {0 0 1}  48 102
} {
    $doc circle -at [list $cx $cy] -radius 20 -fill $colour -blend Screen
}

# -- subtractive: ink, from white -------------------------------------------
$doc font -style bold -size 11
$doc text "CMYK - subtractive, ink" -at {112 46}
$doc font -style {} -size 8
$doc text "Multiply on bare paper. Where two inks overlap less light comes\
    back; all three make near black." -at {112 52} -width 78

$doc rect -at {112 58} -size {78 74} -stroke {0.8 0.8 0.85} -width 0.2
foreach {colour cx cy} {
    {cmyk 1 0 0 0}  151 82
    {cmyk 0 1 0 0}  162 102
    {cmyk 0 0 1 0}  140 102
} {
    $doc circle -at [list $cx $cy] -radius 20 -fill $colour -blend Multiply
}

# -- and why the K is there -------------------------------------------------
#
# The one thing the diagram cannot show: the middle of the CMYK circles is a
# muddy dark brown on paper, not black - three inks at full strength are 300
# per cent coverage and still not neutral. That is what the fourth plate is
# for, and it is worth a rule of real black beside the mixed one.
$doc font -style bold -size 11
$doc text "And why there is a fourth plate" -at {20 145}
$doc font -style {} -size 8
$doc text "The middle above is where C, M and Y meet at full strength. On\
    paper that is not black but a dark muddy brown, at 300 per cent ink\
    coverage - which no press will lay down on ordinary stock. The K plate\
    gives a neutral black with one ink instead of three." -at {20 151} -width 170

$doc rect -at {20 168} -size {40 14} -fill {cmyk 1 1 1 0}
$doc rect -at {65 168} -size {40 14} -fill {cmyk 0 0 0 1}
$doc font -size 7
$doc text "cmyk 1 1 1 0 - three inks" -at {20 187}
$doc text "cmyk 0 0 0 1 - one ink" -at {65 187}

# AND THE TWO PATCHES LOOK ALIKE ON SCREEN, which is not a fault of the
# drawing: a reader has no inks, so it converts both to RGB and lands on much
# the same grey. Said on the page rather than left for the reader to wonder
# about - a document that shows two swatches and claims they differ, while
# they plainly do not, teaches the wrong thing.
$doc font -size 8 -color {0.45 0.45 0.5}
$doc text "On screen these two look alike, and that is the honest answer: a\
    reader has no inks. It converts both to RGB and lands on much the same\
    grey. The difference is on paper, and it is the reason a control strip is\
    printed rather than previewed - see example 01.16." \
    -at {20 196} -width 170
$doc font -color black

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes)"
$doc destroy
