# Gradients, tiling patterns, form XObjects

## Gradients drawn directly

```tcl
package require tclpdf
set doc [tclpdf new -unit mm]
$doc page add

# Axial (type 2), clipped to the rectangle; -angle 0 = left to right, 90 = top to bottom.
$doc shading axial -at {20 20} -size {50 20} -colors {white steelblue} -angle 90
# More than two colours are stitched; -stops positions them (0..1, ascending, inner values count).
$doc shading axial -at {75 20} -size {50 20} -colors {{0.85 0.15 0.15} {0.95 0.85 0.2} {0.15 0.55 0.25}} \
    -stops {0 0.3 1}
# -from/-to name the end points and win over -angle; -extend {1 0} stops the last colour at its end.
$doc shading axial -at {130 20} -size {50 20} -colors {navy white} -from {130 20} -to {160 40} -extend {1 0}

# Radial (type 3): -center/-radius describe the outer circle (default: middle, half the
# longer side), -innerRadius the inner one, -focus moves the highlight off the middle.
$doc shading radial -at {20 50} -size {40 20} -colors {white {0.35 0.55 0.9} {0.05 0.1 0.4}} \
    -stops {0 0.45 1} -center {40 60} -radius 9.5 -innerRadius 0.5 -focus {36 56} -extend {0 0}
```

Stops of a shading share one space: a grey stop is promoted to the space of the coloured ones. An ICC colour is not accepted here.

## Gradients as patterns - fills for any shape

```tcl
# Registered by name, usable as {pattern name} in any -fill.
$doc shading pattern sunset axial -at {80 50} -size {50 20} \
    -colors {{0.99 0.93 0.80} {0.93 0.66 0.30}} -angle 90
$doc rect -at {80 50} -size {50 20} -radius 3 -fill {pattern sunset} -stroke {0.55 0.35 0.15} -width 0.4
$doc circle -at {150 60} -radius 9 -fill {pattern sunset}
$doc font -family helvetica -style bold -size 14 -color {pattern sunset}   ;# text takes it too
$doc text "SUNSET" -at {165 65}
$doc font -color black -style {}
puts "gradients: [$doc shading names]"
```

A pattern is a colour wherever a fill is taken - `-fill {pattern name}` on the shapes, a table cell's `fill`, `font -color` and a text call's `-color`.

## Tiling patterns

```tcl
# The tile is drawn like a small page: origin top left, y down, every shape works.
$doc pattern create hatch -size {3 3} -script {
    $doc line -from {0 3} -to {3 0} -stroke {0.25 0.35 0.55} -width 0.35
}
$doc pattern create dots -size {3.5 3.5} -script {
    $doc circle -at {1.75 1.75} -radius 0.55 -fill {0.30 0.50 0.35}
}
# -step: distance between tiles; larger than the size and the background shows through.
$doc pattern create sparse -size {2 2} -step {5 5} -script {
    $doc circle -at {1 1} -radius 0.8 -fill {0.6 0.3 0.2}
}
# -unit reads -size and -step in another unit: a quarter-inch grid.
$doc pattern create quarterInch -size {0.25 0.25} -unit in -script {
    $doc rect -at {0 0} -size {6.35 6.35} -stroke {0.45 0.45 0.5} -width 0.2
}
set x 20
foreach name {hatch dots sparse quarterInch} {
    $doc rect -at [list $x 80] -size {35 20} -fill [list pattern $name] -stroke {0.4 0.4 0.45} -width 0.3
    incr x 40
}
puts "patterns: [$doc pattern names], hatch tile: [$doc pattern size hatch]"

# -origin anchors the tile grid at a document point - the corner of the shape,
# and the first tile sits square in it (without it tiles run from the page's
# bottom left and are cut at whatever phase falls on the edge).
$doc pattern create anchored -size {4 4} -origin {20 110} -script {
    $doc rect -at {0 0} -size {2 2} -fill {0.2 0.45 0.75}
}
$doc rect -at {20 110} -size {35 20} -fill {pattern anchored} -stroke black -width 0.3
```

## The rule that costs an afternoon: a pattern belongs to its content stream

A pattern - gradient or tile - is bound to the **default space of the content stream that carries it** and ignores the transformation in force when the shape is painted (ISO 32000-2, 8.7.2). Two consequences:

```tcl
# 1. Under a transform, hand the same matrix to the pattern and give its
#    coordinates in that space (coords/extent/distance convert for you).
$doc save
set turn [$doc transform -at {100 120} -rotate -15]
$doc shading pattern orb radial -matrix $turn \
    -at [$doc coords 80 110] -size [$doc extent {40 20}] \
    -center [$doc coords 100 120] -radius [$doc distance 10] \
    -colors {white {0.95 0.6 0.2} {0.5 0.15 0.05}} -stops {0 0.45 1}
$doc ellipse -at {100 120} -size {40 20} -fill {pattern orb}
$doc restore

# 2. A gradient placed on the page cannot fill inside a form, nor the other way
#    round: define it INSIDE the form. (A tile with neither -origin nor -matrix
#    has no place of its own and crosses freely - that is what a hatch is for.)
$doc form create badge -size {36 14} -script {
    $doc shading pattern sheen axial -at {0 0} -size {36 14} \
        -colors {{0.20 0.35 0.60} {0.45 0.70 0.90}} -angle 20
    $doc rect -at {0 0} -size {36 14} -radius 2 -fill {pattern sheen}
    $doc font -family helvetica -size 7 -style bold -color white
    $doc text "PAID" -at {18 9} -align center
}
$doc form place badge -at {140 110}
$doc form place badge -at {140 130} -rotate -8 -opacity 0.6

if {[catch {$doc form create wrong -size {20 10} -script {
    $doc rect -at {0 0} -size {20 10} -fill {pattern sunset}   ;# a page gradient inside a form
}} message]} {
    puts "refused, as it should be: $message"
}
```

## Form XObjects: draw once, place many times

```tcl
# One object in the file however often it is placed; placing is a transformation.
$doc form create letterhead -size {170 30} -script {
    $doc rect -at {0 0} -size {170 30} -fill {0.92 0.94 0.98}
    $doc rect -at {0 28} -size {170 2} -fill {0.15 0.35 0.6}
    $doc font -family helvetica -size 14 -style bold -color black
    $doc text "Northgate Pottery" -at {6 12}
    $doc font -size 8 -style {}
    $doc text "14 Kiln Lane - Northgate" -at {6 19}
}
puts "letterhead: [$doc form size letterhead] mm, forms: [$doc form names]"
$doc form place letterhead -at {20 150}
$doc form place letterhead -at {20 190} -scale 0.5 -opacity 0.4
$doc form place letterhead -at {20 220} -rotate 3

# A stamp defined in points inside a millimetre document.
$doc form create stamp -size {72 36} -unit pt -script {
    $doc rect -at {0 0} -size {25.4 12.7} -stroke {0.7 0.15 0.1} -width 0.6 -radius 2
    $doc font -family helvetica -size 7 -style bold -color {0.7 0.15 0.1}
    $doc text "RECEIVED" -at {12.7 8} -align center
}
$doc form place stamp -at {150 250} -rotate -12
$doc font -color black -style {}      ;# the font state is document state, not part of the form
```

Every form is an isolated transparency group: `-opacity` on the placement fades it as **one** object, and shapes overlapping inside it do not add up. The group names no colour space, so a form stays valid under any PDF/A output intent. Below `-version 1.4` there are no groups. `-alt`/`-artifact` on the placement matter in tagged documents.

```tcl
$doc write [file join $out ref-07-patterns-forms.pdf]
$doc destroy
```
