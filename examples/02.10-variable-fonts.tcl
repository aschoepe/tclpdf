#!/usr/bin/env tclsh
#
# tclpdf example 2.10 - one variable font, many instances
#
#   tclsh examples/02.10-variable-fonts.tcl ?output.pdf?
#
# A variable font is not a family of files - it is ONE set of outlines plus a
# rule for bending them. fvar names the axes, gvar holds the deltas that belong
# to each region of the axis space, and what sits in glyf is the point where
# every axis is at its default.
#
# PDF HAS NOWHERE TO PUT AN AXIS VALUE. Not in the font dictionary, not in the
# descriptor. So the outlines are computed here, at embedding time, and go into
# the file as a fixed instance - a reader never learns that the face could
# vary. That is why -axes belongs to [font embed] and not to the text state:
# every point on the axes is its own embedded font.
#
#   -instance "Bold"     a point the designer named and stood behind
#   -axes {wght 620}     a point nobody has looked at, which is the whole
#                        reason a variable font is variable
#
# The two combine: -instance sets the starting point, -axes overrides single
# axes of it.
#
# WHAT THIS COSTS. Every instance is a separate subset in the document, so a
# page showing nine weights carries nine fonts. Using two weights of a variable
# font is not cheaper than embedding two static cuts - it is cheaper in what
# has to be shipped and installed, and it buys the values in between, which no
# static family offers.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "02.10-variable-fonts.pdf"}]
set fonts [file join $here assets fonts]

set doc [tclpdf new -unit mm]
$doc info Title "Variable fonts"
$doc info Author "tclpdf"
$doc page add

$doc font -family helvetica -style bold -size 16
$doc text "One file, many weights" -at {20 22}
$doc font -style {} -size 9
$doc text "Roboto Variable carries two axes: wght from 100 to 900 and wdth\
    from 75 to 100. Each line below is the same file embedded at a different\
    point on those axes - the shapes in between are computed, not looked up." \
    -at {20 30} -width 170

# -- the weight axis, in steps the family does not ship -------------------

set y 46
foreach weight {100 200 300 400 500 600 700 800 900} {
    set alias w$weight
    $doc font embed $alias [file join $fonts google Roboto-Variable.ttf] \
        -axes [list wght $weight]
    $doc font -family helvetica -style {} -size 7 -color {0.45 0.45 0.5}
    $doc text "wght $weight" -at [list 20 $y]
    $doc font -family $alias -size 13 -color black
    $doc text "Hamburgefonstiv 0123" -at [list 42 $y]
    incr y 9
}

# 150 and 450 are NOT among the nine named instances - they are points on the
# axis that no static cut of the family offers. That is the difference between
# picking a file and picking a value.
$doc font -family helvetica -style bold -size 10
$doc text "Values the family does not ship" -at {20 133}
$doc font -style {} -size 8
$doc text "The nine steps above are the named instances. These two are not:\
    they lie between them, and a static family has nothing to offer there." \
    -at {20 139} -width 170

set y 150
foreach weight {150 450} {
    set alias between$weight
    $doc font embed $alias [file join $fonts google Roboto-Variable.ttf] \
        -axes [list wght $weight]
    $doc font -family helvetica -style {} -size 7 -color {0.45 0.45 0.5}
    $doc text "wght $weight" -at [list 20 $y]
    $doc font -family $alias -size 13 -color black
    $doc text "Hamburgefonstiv 0123" -at [list 42 $y]
    incr y 9
}

# -- the second axis, and both together -----------------------------------

$doc font -family helvetica -style bold -size 10 -color black
$doc text "A second axis, and both at once" -at {20 176}
$doc font -style {} -size 8
$doc text "wdth narrows the letters without thinning the strokes. Combined\
    with wght it gives a grid of shapes rather than a list of files." \
    -at {20 182} -width 170

set y 193
foreach {label axes} {
    "wdth 100" {wdth 100}
    "wdth 87" {wdth 87}
    "wdth 75" {wdth 75}
    "wght 700 wdth 75" {wght 700 wdth 75}
} {
    set alias [string map {" " _} d$label]
    $doc font embed $alias [file join $fonts google Roboto-Variable.ttf] -axes $axes
    $doc font -family helvetica -style {} -size 7 -color {0.45 0.45 0.5}
    $doc text $label -at [list 20 $y]
    $doc font -family $alias -size 13 -color black
    $doc text "Hamburgefonstiv 0123" -at [list 55 $y]
    incr y 9
}

exampleFooter $doc

# -- named instances, and what they are worth -----------------------------

$doc page add

$doc font -family helvetica -style bold -size 16 -color black
$doc text "Named instances" -at {20 22}
$doc font -style {} -size 9
$doc text "A named instance is a point the designer thought worth naming - what\
    a static family would ship as a separate file. -instance takes the name the\
    font itself gives it, which is the name a font menu would show. Passing a\
    name the font does not have is an error that lists the ones it does." \
    -at {20 30} -width 170

set y 48
foreach name {"Thin" "Light" "Regular" "Medium" "Bold" "Black"
        "Condensed Light" "Condensed Bold"} {
    set alias [string map {" " _} n$name]
    $doc font embed $alias [file join $fonts google Roboto-Variable.ttf] -instance $name
    $doc font -family helvetica -style {} -size 7 -color {0.45 0.45 0.5}
    $doc text $name -at [list 20 $y]
    $doc font -family $alias -size 13 -color black
    $doc text "Hamburgefonstiv 0123" -at [list 55 $y]
    incr y 9
}

$doc font -family helvetica -style bold -size 10 -color black
$doc text "Starting from a name and moving on" -at {20 124}
$doc font -style {} -size 8
$doc text "-axes overrides single axes of the instance it starts from, so\
    \"Bold, but narrower\" is one call rather than a lookup by hand." \
    -at {20 130} -width 170

$doc font embed refined [file join $fonts google Roboto-Variable.ttf] \
    -instance "Bold" -axes {wdth 80}
$doc font -family helvetica -style {} -size 7 -color {0.45 0.45 0.5}
$doc text "-instance Bold -axes {wdth 80}" -at {20 141}
$doc font -family refined -size 13 -color black
$doc text "Hamburgefonstiv 0123" -at {75 141}

# -- what the widths do ---------------------------------------------------

# The advances vary with the axes, and they have to: a heavier letter needs
# more room. tclpdf reads them from the phantom points of gvar - the four
# points appended to every glyph, whose spacing IS the advance width - so the
# measurement follows the outline instead of the default instance.
$doc font -family helvetica -style bold -size 10 -color black
$doc text "The widths move with the weight" -at {20 158}
$doc font -style {} -size 8
$doc text "The same string measured at three weights. If the advances came\
    from the default instance the three numbers would be equal, the line\
    breaker would break in the wrong place and the table columns would come\
    out too narrow." -at {20 164} -width 170

set rows {}
foreach weight {100 400 900} {
    $doc font -family w$weight -size 13
    lappend rows [list "wght $weight" \
        [format "%.2f mm" [$doc textWidth "Hamburgefonstiv 0123"]]]
}
$doc font -family helvetica -style {} -size 9
$doc table -at {20 180} -width 90 -theme plain \
    -head {{"Instance" "Width at 13 pt"}} -body $rows \
    -columns {{width 30} {align right}}

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes), [$doc page count] page(s)"
puts "  fonts embedded: [llength [$doc font names]] instances of one file"
$doc destroy
