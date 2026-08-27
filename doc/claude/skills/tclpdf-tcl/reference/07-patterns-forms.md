# Gradients, tiling patterns, form XObjects, layers

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
} else {
    puts "a page gradient inside a form: NOT REFUSED"
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

## A colour computed at every point: shading type 1

```tcl
$doc page add

# -expression is the BODY of a PostScript calculator function (ISO 32000-2,
# 7.10.5) without its outer braces, which are written here: x and y arrive on
# the stack in domain coordinates, and what is left when it ends is the
# colour - one number per component, which -space says how many of.
$doc shading function -at {20 20} -size {80 50} -space rgb \
    -expression {exch 720 mul sin 1 add 2 div exch 720 mul sin 1 add 2 div 0.4}

# -domain is the rectangle the calculation is written over ({0 1 0 1} unless
# given, x0 below x1 and y0 below y1); -at and -size say where that rectangle
# goes, so the domain's y runs UP the page, the way a calculation expects.
$doc shading function -at {110 20} -size {80 50} -space gray -domain {-2 2 -2 2} \
    -expression {dup mul exch dup mul add 4 div 1 exch sub}

# Every word is held to Table 42: a misspelt operator is refused naming it,
# and so is a brace that does not close - a reader answers either by painting
# nothing at all.
if {[catch {$doc shading function -at {20 20} -size {10 10} -space gray \
        -expression {x 2 mul}} message]} {
    puts "refused, as it should be: $message"
} else {
    puts "an operator that is not in Table 42: NOT REFUSED"
}
```

What cannot be decided by reading is whether the right *number* of values is left on the stack: `if`, `ifelse` and `roll` make that depend on the values, and a function that leaves too few is a valid file and an empty rectangle.

## The four mesh shadings: colours carried as points

```tcl
# A mesh BOUNDS ITSELF - it paints only where its triangles or patches are, so
# unlike a gradient it needs no rectangle; -at with -size is a clip where one
# is wanted, and half of a rectangle is refused.

# Type 4, free-form: a vertex is {x y colour} with an optional fourth word,
# the edge flag. 0 begins a triangle and wants two more 0s after it; 1 and 2
# each add a SINGLE vertex to the triangle before - 1 keeps its second and
# third corner (a strip), 2 its first and third (a fan round a centre).
set vertices {{60 45 white}}
set hues {{0.85 0.20 0.20} {0.90 0.55 0.15} {0.85 0.80 0.15} {0.35 0.70 0.25}
          {0.15 0.60 0.60} {0.20 0.35 0.80} {0.50 0.25 0.75} {0.80 0.25 0.55}}
set index 0
foreach hue $hues {
    set angle [expr {$index * 3.14159265 / 4.0}]
    lappend vertices [list [expr {60 + 22 * cos($angle)}] \
        [expr {45 + 22 * sin($angle)}] $hue [expr {$index < 2 ? 0 : 2}]]
    incr index
}
$doc shading triangles -vertices $vertices

# Type 5, the lattice: the same vertices WITHOUT flags, read as rows of
# -perRow each - two or more per row and two or more rows. A flag written on a
# lattice vertex is refused rather than ignored: the type cannot express it.
set vertices {}
set palette {{0.10 0.25 0.50} {0.20 0.55 0.65} {0.55 0.80 0.65} {0.95 0.95 0.70}
             {0.30 0.45 0.65} {0.95 0.75 0.35} {0.90 0.45 0.25} {0.65 0.20 0.30}
             {0.15 0.30 0.45} {0.45 0.60 0.55} {0.85 0.60 0.40} {0.35 0.15 0.25}}
set index 0
foreach colour $palette {
    lappend vertices [list [expr {110 + 22 * ($index % 4)}] \
        [expr {24 + 20 * ($index / 4)}] $colour]
    incr index
}
$doc shading lattice -perRow 4 -vertices $vertices

# Types 6 and 7: a patch is {points {...} colors {...}} - twelve control
# points for coons, sixteen for tensor, each {x y}, and four colours, one per
# corner. The points run round the boundary from the first corner, four cubic
# Bezier edges with the corners shared; the corner colours belong to points
# 1, 4, 7 and 10 in the order the boundary passes them.
proc refBoundary {left top width height bulge} {
    set right [expr {$left + $width}]
    set bottom [expr {$top + $height}]
    set thirdX [expr {$width / 3.0}]
    set thirdY [expr {$height / 3.0}]
    return [list \
        [list $left $top] \
        [list [expr {$left + $thirdX}] [expr {$top - $bulge}]] \
        [list [expr {$right - $thirdX}] [expr {$top - $bulge}]] \
        [list $right $top] \
        [list [expr {$right + $bulge}] [expr {$top + $thirdY}]] \
        [list [expr {$right + $bulge}] [expr {$bottom - $thirdY}]] \
        [list $right $bottom] \
        [list [expr {$right - $thirdX}] [expr {$bottom + $bulge}]] \
        [list [expr {$left + $thirdX}] [expr {$bottom + $bulge}]] \
        [list $left $bottom] \
        [list [expr {$left - $bulge}] [expr {$bottom - $thirdY}]] \
        [list [expr {$left - $bulge}] [expr {$top + $thirdY}]]]
}
set corners {{0.95 0.75 0.20} {0.20 0.45 0.75} {0.15 0.55 0.45} {0.85 0.25 0.35}}
$doc shading coons -patches [list [list points [refBoundary 30 95 56 34 7] colors $corners]]

# A tensor patch adds its four INTERIOR points last - left where a Coons patch
# would put them they change nothing, pulled away they shape the inside.
$doc shading tensor -patches [list [list \
    points [concat [refBoundary 120 95 56 34 7] {{160 120} {160 125} {171 125} {171 120}}] \
    colors $corners]]

# The ordinary mistake, and the one no tool reports: four vertices with every
# flag left at 0. It is refused here.
if {[catch {$doc shading triangles -vertices {
        {20 150 red} {40 150 green} {40 170 blue} {20 170 white}}} message]} {
    puts "refused, as it should be: $message"
} else {
    puts "four vertices with every flag at 0: NOT REFUSED"
}
```

All the colours of one mesh share **one** space, exactly as the stops of a gradient do: a grey corner among coloured ones is promoted, and mixing RGB with CMYK is refused. The points are packed as a binary stream, sixteen bits per coordinate over the mesh's own bounding box and eight per colour component, so a vertex is eight bytes in RGB and a tensor patch seventy-seven. A mesh's space counts for PDF/A like a painted colour, and every mesh type registers as a pattern - `shading pattern name triangles -vertices ...` - so any shape can be filled with one.

## Layers: optional content

```tcl
# A layer is an optional content group - what a reader shows as a checkbox in
# its layer panel (PDF 1.5; an older -version is refused). -title is what that
# panel shows; without it the alias stands in. -visible 0 starts it off, and
# the state belongs to the CONFIGURATION, so it can be changed after drawing.
$doc page add
$doc layer create german -title "German"
$doc layer create english -title "English" -visible 0
$doc layer create draft -title "Draft stamp" -visible 0

# -intent is View, Design or both (Table 96). The DEFAULT CONFIGURATION
# considers only groups whose intent it shares and its own is View, so a group
# created with Design alone is not switched by it - which is what the standard
# prescribes, and what makes it the intent for a layer meant for the person
# laying the page out rather than for the reader.
$doc layer create guides -title "Layout guides" -visible 0 -intent Design

# At most one of a radio set is on at a time (/RBGroups): two or more names,
# each a layer of this document. One language per layer is the usual case.
$doc layer radio {german english}

# The default configuration itself. The name may NOT be empty - ISO 19005-2/-3,
# 6.9 requires one, and an empty one fails veraPDF's check 6.9-1.
$doc layer configure -title "Invoice" -listMode AllPages

# layer draw brackets what the script draws with /OC ... BDC ... EMC. The
# script runs in the frame that called it, so $doc is in reach; the bracket is
# closed even when the script fails. Layers nest, and so do their brackets.
$doc font -family helvetica -size 12 -color black
$doc layer draw german -script {
    $doc text "Rechnung 4711" -at {20 30}
}
$doc layer draw english -script {
    $doc text "Invoice 4711" -at {20 30}
}

# Placing a form inside a bracket is how a reusable block is made optional -
# the form is stored once and the LAYER decides whether it is shown.
$doc layer draw draft -script {
    $doc form place stamp -at {150 26}
}

puts "layers: [$doc layer names]"
puts "german on: [$doc layer state german], draft on: [$doc layer state draft]"
$doc layer state draft 1                 ;# read with no value, set with one
puts [$doc layer configure]              ;# title and listMode, read back

# A BRACKET OPENS AND CLOSES IN ONE CONTENT STREAM: a script that adds a page,
# or that otherwise leaves the stream it began in, is refused by name - and
# what it drew before that is still closed properly.
if {[catch {$doc layer draw german -script {$doc page add}} message]} {
    puts "refused, as it should be: $message"
} else {
    puts "page add inside a layer bracket: NOT REFUSED"
}

# An annotation inside a form or a pattern script is refused as well, and for
# a different reason: an annotation belongs to a PAGE and its rectangle is in
# that page's coordinates (ISO 32000-2, 12.5.2), which a content stream of its
# own does not have. Place the form first and lay the annotation over where it
# landed. Inside [layer draw] the same call is TAKEN and lands outside the
# layer - a layer is a bracket in the stream and an annotation is not content.
foreach {label script} [list \
        "a link inside form create"    [list $doc form create linked -size {20 10} \
            -script [list $doc link -at {2 2} -size {10 5} -url https://example.org]] \
        "a note inside pattern create" [list $doc pattern create noted -size {20 10} \
            -script [list $doc annot note -at {2 2} -contents "here"]] \
        "page add inside form create"  [list $doc form create paged -size {20 10} \
            -script [list $doc page add]]] {
    if {[catch $script message options]} {
        puts "[format %-30s $label] [dict get $options -errorcode]"
    } else {
        puts "[format %-30s $label] NOT REFUSED"
    }
}
```

`/OCProperties` is written for you, with every group in `/OCGs` and a default configuration `/D` carrying `/Order`, `/ON`, `/OFF`, `/RBGroups` and `/ListMode`. `/Order` lists every group, which is what ISO 19005-2/-3, 6.9 asks - so a **PDF/A document with layers stays conforming**. What is not offered: an `/OC` entry on an XObject or on an annotation - bracket the placement instead. An `annot` or a `link` written inside `layer draw` is *taken* and lands outside the layer; inside `form create` or `pattern create` it is refused (`TCLPDF ANNOT PLACE form`, `TCLPDF LINK PLACE form`), because there the rectangle would be wrong as well - `page add` is refused in all three (`TCLPDF PAGE CANVAS add`, `TCLPDF LAYER SCRIPT`). A page taken over with `pdf import` keeps the layers it brought (`12-import-update-info.md`).

```tcl
$doc write [file join $out ref-07-patterns-forms.pdf]
$doc destroy
```
