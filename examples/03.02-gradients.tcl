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
#             expresses a multi-stop gradient at all. Page 2 shows the other
#             five types: type 1, whose colour at a point is what a function
#             returns for it, and the four meshes (4 to 7), which carry their
#             colours as points, with what each of them costs in the file.
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
set auto_path [linsert $auto_path 0 [file dirname $here]]
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

# A pattern is a colour, and text takes a colour: the label's own gradient
# fills its letters, through -color like every other text colour. It used to
# write the alias into the stream instead of the resource name - poppler said
# "Unknown pattern" and drew nothing, qpdf and veraPDF said nothing at all.
$doc shading pattern ink axial -at {20 88} -size {70 8} \
    -colors {{0.55 0.35 0.15} {0.93 0.66 0.30}}
$doc font -family helvetica -style bold -size 16 -color {pattern ink}
$doc text "APRICOT" -at {55 95} -align center

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

# -- page two: the five other shading types --------------------------------
#
# Types 2 and 3 above say where a colour run GOES and let the reader work out
# every point between the stops. The five here say it differently: type 1 as a
# calculation over a rectangle, types 4 to 7 as the points themselves - a
# stream of vertices or patches with a colour at each, packed as binary
# numbers. A mesh paints only where its triangles are, so unlike a gradient it
# needs no rectangle to be clipped to.

$doc page add
$doc font -family helvetica -style bold -size 15 -color black
$doc text "Shading types 1 and 4 to 7" -at {20 22}
$doc font -style {} -size 9
$doc text "A gradient runs between stops. These five hold their colours\
    themselves: one as a calculation over the area, four as a mesh of points -\
    triangles, a lattice of rows, and the two kinds of curved patch." \
    -at {20 30} -width 170

# A caption under a panel, and the frame around it - three lines that would
# otherwise stand six times.
proc shadingPanel {doc x y w h title note} {
    $doc rect -at [list $x $y] -size [list $w $h] \
        -stroke {0.75 0.75 0.8} -width 0.3
    $doc font -family helvetica -style bold -size 7 -color black
    $doc text $title -at [list $x [expr {$y + $h + 5}]]
    $doc font -style {} -size 6.5 -color {0.35 0.35 0.4}
    $doc text $note -at [list $x [expr {$y + $h + 9}]] -width $w
}

# -- type 1: the colour as a calculation ------------------------------------
#
# The function is a PostScript calculator (ISO 32000-2, 7.10.5): x and y
# arrive on the stack in domain coordinates, and what is left when it ends is
# the colour. This one is a ripple in each direction - sin over both axes,
# which is a picture no run between stops can make.
$doc shading function -at {20 44} -size {80 50} -space rgb \
    -expression {exch 720 mul sin 1 add 2 div exch 720 mul sin 1 add 2 div 0.4}
shadingPanel $doc 20 44 80 50 "type 1, function-based" \
    "-expression is the body of a PostScript calculator function: it takes x\
    and y and leaves one number per component."

# -- type 4: free-form triangles, as a fan ----------------------------------
#
# An edge flag of 2 keeps the FIRST vertex of the previous triangle and adds
# one new one, which is exactly a fan around a common centre: three vertices
# for the first triangle and one for each after it.
set vertices {{150 69 white}}
set hues {{0.85 0.20 0.20} {0.90 0.55 0.15} {0.85 0.80 0.15}
          {0.35 0.70 0.25} {0.15 0.60 0.60} {0.20 0.35 0.80}
          {0.50 0.25 0.75} {0.80 0.25 0.55}}
set index 0
foreach hue $hues {
    set angle [expr {$index * 360.0 / [llength $hues]}]
    set radians [expr {$angle * acos(-1) / 180.0}]
    set point [list [expr {150 + 38 * cos($radians)}] \
        [expr {69 + 23 * sin($radians)}] $hue]
    # The first two rim points complete the first triangle and carry flag 0;
    # every one after them continues the fan with flag 2.
    lappend vertices [expr {$index < 2 ? $point : [linsert $point end 2]}]
    incr index
}
# The fan has to close: the last triangle runs back to the first rim point.
lappend vertices [linsert [lindex $vertices 1] end 2]
$doc shading triangles -vertices $vertices
shadingPanel $doc 110 44 80 50 "type 4, free-form Gouraud triangles" \
    "A vertex is {x y colour}; a fourth word is the edge flag - 2 keeps the\
    centre and makes the strip a fan."

# -- type 5: the lattice ----------------------------------------------------
#
# The same vertices without the flags, read as rows of a fixed width. A grid
# is what most meshes are, and this is the type that says so in one number.
set vertices {}
set palette {{0.10 0.25 0.50} {0.20 0.55 0.65} {0.55 0.80 0.65} {0.95 0.95 0.70}
             {0.30 0.45 0.65} {0.95 0.75 0.35} {0.90 0.45 0.25} {0.65 0.20 0.30}
             {0.15 0.30 0.45} {0.45 0.60 0.55} {0.85 0.60 0.40} {0.35 0.15 0.25}}
set index 0
foreach colour $palette {
    set column [expr {$index % 4}]
    set row [expr {$index / 4}]
    # The middle row is drawn in, so the lattice is a grid rather than a
    # rectangle - the rows are what it is made of, not the corners.
    set inset [expr {$row == 1 ? 9 : 0}]
    lappend vertices [list \
        [expr {20 + $inset + $column * (80 - 2 * $inset) / 3.0}] \
        [expr {109 + $row * 25}] $colour]
    incr index
}
$doc shading lattice -perRow 4 -vertices $vertices
shadingPanel $doc 20 109 80 50 "type 5, lattice-form Gouraud triangles" \
    "-perRow says how many vertices a row holds; the reader makes the\
    triangles between two rows itself."

# -- types 6 and 7: the two kinds of patch ----------------------------------
#
# Twelve control points run round the boundary, four cubic edges with the
# corners shared, and one colour per corner. A tensor patch adds four INTERIOR
# points, which is the whole of the difference between the two - the same
# boundary, and the inside shaped rather than interpolated.
#
# The boundary below bulges: the two middle points of each edge are pushed out
# of the straight line, which a Coons patch follows and no gradient can.
proc shadingPatchBoundary {left top width height bulge} {
    set right [expr {$left + $width}]
    set bottom [expr {$top + $height}]
    set midX [expr {$left + $width / 2.0}]
    set midY [expr {$top + $height / 2.0}]
    return [list \
        [list $left $top] \
        [list [expr {$left - $bulge}] [expr {$top + $height / 3.0}]] \
        [list [expr {$left - $bulge}] [expr {$top + 2 * $height / 3.0}]] \
        [list $left $bottom] \
        [list [expr {$left + $width / 3.0}] [expr {$bottom + $bulge}]] \
        [list [expr {$left + 2 * $width / 3.0}] [expr {$bottom + $bulge}]] \
        [list $right $bottom] \
        [list [expr {$right + $bulge}] [expr {$top + 2 * $height / 3.0}]] \
        [list [expr {$right + $bulge}] [expr {$top + $height / 3.0}]] \
        [list $right $top] \
        [list [expr {$left + 2 * $width / 3.0}] [expr {$top - $bulge}]] \
        [list [expr {$left + $width / 3.0}] [expr {$top - $bulge}]]]
}

set corners {{0.95 0.85 0.30} {0.85 0.25 0.25} {0.20 0.30 0.65} {0.25 0.65 0.45}}
$doc shading coons -patches [list [list \
    points [shadingPatchBoundary 122 117 56 34 7] colors $corners]]
shadingPanel $doc 110 109 80 50 "type 6, Coons patch" \
    "Twelve control points round the boundary - four cubic edges - and one\
    colour per corner."

# The same boundary and the same corner colours; only the four interior points
# differ, and they are what the four extra numbers of a tensor patch buy. Left
# where a Coons patch would put them - at the thirds - they change nothing;
# pulled together towards one corner, as here, they squeeze the colour field
# that way. Measured with poppler: the effect is real but wants a real
# displacement, and interior points near their natural places are invisible.
$doc shading tensor -patches [list [list \
    points [concat [shadingPatchBoundary 32 182 56 34 7] \
        {{72 207} {72 212} {83 212} {83 207}}] colors $corners]]
shadingPanel $doc 20 174 80 50 "type 7, tensor-product patch" \
    "The same boundary and the same corners; the four interior points are\
    pulled to one corner, and the field is squeezed with them."

# -- a mesh as a pattern ----------------------------------------------------
#
# Every shading type can be registered as a pattern, and then any shape can be
# filled with it - the mesh is cut to the shape instead of the other way
# round.
$doc shading pattern wing triangles -vertices {
    {110 174 {0.95 0.75 0.20}} {190 174 {0.20 0.45 0.75}} {110 224 {0.85 0.25 0.35}}
    {190 224 {0.15 0.55 0.45} 1}}
$doc circle -at {150 199} -radius 24 -fill {pattern wing} \
    -stroke {0.35 0.35 0.4} -width 0.4
shadingPanel $doc 110 174 80 50 "a mesh as a pattern" \
    "shading pattern registers any of the seven; the shape is then filled\
    with it, mesh and all."

$doc font -family helvetica -style bold -size 10 -color black
$doc text "What the mesh types cost" -at {20 244}
$doc font -style {} -size 8
$doc text "The four mesh types write their points as a binary stream: two\
    bytes per coordinate over the bounding box of the mesh itself, one byte\
    per colour component, one for the edge flag. A vertex is eight bytes in\
    RGB, a Coons patch sixty-one - so a mesh of a thousand triangles is a few\
    kilobytes, deflated with everything else. The colours share one space, the\
    way the stops of a gradient do: a grey corner among coloured ones is\
    promoted rather than refused." -at {20 250} -width 170

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
