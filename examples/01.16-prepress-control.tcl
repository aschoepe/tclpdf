#!/usr/bin/env tclsh
#
# tclpdf example 1.16 - a press control strip
#
#   tclsh examples/01.16-prepress-control.tcl ?output.pdf?
#
# The strip that runs along the edge of a printed sheet and is trimmed off
# afterwards. Nobody reads it on a screen; a press operator reads it on paper,
# with a densitometer and a loupe, to answer four questions: is each ink laid
# down at the right density, do the four plates register, does the screen hold
# its tones, and is the sheet slurring or doubling as it runs.
#
# WHY IT IS AN EXAMPLE HERE and not a picture: every element of it is a
# drawing instruction this package already had, except one. The tone scales
# and colour bars are rectangles in CMYK, the ramps are Shading Type 2, the
# screens are tiling patterns, the rosettes and targets are polygons, lines
# and circles - and pdfimages finds no image at all in what comes out.
#
# THE ONE THING THAT HAD TO BE BUILT FOR IT IS OVERPRINT (8.6.7), and it is
# what a control strip is FOR. Two solids side by side say nothing about a
# press; two solids ON TOP OF EACH OTHER say everything - whether the second
# ink knocks the first one out or runs on underneath. The switch has no
# effect a reader can show, which is exactly why it needs a printed strip
# rather than a preview: [$doc overprint -fill 1] writes /op true into the
# graphics state, and from that moment the file MEANS something different
# while looking identical.
#
# WHAT THIS FILE DOES NOT CLAIM. A real strip is a measured object: the
# patches sit at densities a standard names (ISO 12647), the screen ruling is
# the press's own, and the whole thing is supplied by the printer rather than
# invented by the document. This one is built from the arithmetic and shows
# the DRAWING side. Take the geometry, not the values.
#
# Check with:  qpdf --qdf --object-streams=disable out.pdf - | grep -n '/op'
#              pdfimages -list out.pdf          -> no images at all
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "01.16-prepress-control.pdf"}]

# The four process inks, in the order a press lays them down. The letter is
# what an operator writes; the colour is that plate alone at full strength.
set plates {
    C {cmyk 1 0 0 0}
    M {cmyk 0 1 0 0}
    Y {cmyk 0 0 1 0}
    K {cmyk 0 0 0 1}
}

# The three colours that only exist BECAUSE two inks overlap - and the reason
# a strip carries them: they are where a wrong overprint shows first.
set overprints {
    R {cmyk 0 1 1 0}
    G {cmyk 1 0 1 0}
    B {cmyk 1 1 0 0}
}

# ---------------------------------------------------------------------------
# The elements, each one a procedure - a strip is the same few figures
# repeated per plate, and a copy per plate is how two of them come to differ.
# ---------------------------------------------------------------------------

# A tint of one plate: the same colour with every component scaled. Written
# here once because four scales and four ramps want it.
proc plateTint {solid percent} {
    lassign $solid -> c m y k
    return [list cmyk [expr {$c * $percent / 100.0}] \
        [expr {$m * $percent / 100.0}] [expr {$y * $percent / 100.0}] \
        [expr {$k * $percent / 100.0}]]
}

# The four-square mark that sits at each end of the head bar: C and M above,
# Y and K below. It is the smallest thing on the sheet that carries all four
# plates, and the first place a missing plate shows.
proc processMark {doc x y {side 3.2}} {
    set squares {C {cmyk 1 0 0 0} M {cmyk 0 1 0 0}
                 Y {cmyk 0 0 1 0} K {cmyk 0 0 0 1}}
    set index 0
    foreach {letter colour} $squares {
        set column [expr {$index % 2}]
        set row [expr {$index / 2}]
        $doc rect -at [list [expr {$x + $column * $side}] \
            [expr {$y + $row * $side}]] -size [list $side $side] -fill $colour
        incr index
    }
    return [expr {2 * $side}]
}

# A star rosette: rays from one centre. What it is for is MOIRE - a rosette
# printed through a screen shows a pattern where the ruling and the rays beat
# against each other, and where that pattern sits says what the ruling is.
# Drawn as filled wedges rather than as lines, because a line of a given
# width is the same width everywhere and a ray has to narrow towards the
# middle.
proc rosette {doc cx cy radius colour {rays 36}} {
    set step [expr {2 * 3.14159265358979 / $rays}]
    for {set i 0} {$i < $rays} {incr i 2} {
        set a0 [expr {$i * $step}]
        set a1 [expr {($i + 1) * $step}]
        # A FLAT list of coordinates: [polygon] takes {x y x y ...}, while
        # [annot polygon] takes a list of points. Two commands, two shapes of
        # argument, and the refusal names which one it wanted.
        $doc polygon -points [list \
            $cx $cy \
            [expr {$cx + $radius * cos($a0)}] \
            [expr {$cy + $radius * sin($a0)}] \
            [expr {$cx + $radius * cos($a1)}] \
            [expr {$cy + $radius * sin($a1)}]] \
            -fill $colour -close 1
    }
    return
}

# The registration target: crosshair, two rings, and the plate letters around
# it. Drawn ONCE in a colour that is all four plates at full strength, so
# every plate carries the same figure - if they register the lines coincide,
# and if they do not each plate shows its own edge as a coloured fringe.
proc registrationTarget {doc cx cy radius} {
    set all {cmyk 1 1 1 1}
    $doc circle -at [list $cx $cy] -radius $radius -stroke $all -width 0.4
    $doc circle -at [list $cx $cy] -radius [expr {$radius / 2.0}] \
        -stroke $all -width 0.4
    set reach [expr {$radius * 1.5}]
    $doc line -from [list [expr {$cx - $reach}] $cy] \
        -to [list [expr {$cx + $reach}] $cy] -stroke $all -width 0.3
    $doc line -from [list $cx [expr {$cy - $reach}]] \
        -to [list $cx [expr {$cy + $reach}]] -stroke $all -width 0.3
    return
}

# The same target with the four plates drawn SEPARATELY, one ring each. On a
# sheet in register the four rings are concentric; out of register the stack
# opens up, and the direction it opens in names the plate that moved.
proc separationTarget {doc cx cy radius plates} {
    set step [expr {$radius / 4.5}]
    set r $radius
    foreach {letter colour} $plates {
        $doc circle -at [list $cx $cy] -radius $r -stroke $colour -width 0.7
        set r [expr {$r - $step}]
    }
    return
}

# ---------------------------------------------------------------------------
# Page 1: the scales a densitometer reads
# ---------------------------------------------------------------------------

set doc [tclpdf new -unit mm]
$doc info Title "A press control strip"
$doc page add

# -- the head bar, with a process mark at each end --------------------------
$doc rect -at {20 18} -size {170 10} -fill {cmyk 0 0 0 0.45}
processMark $doc 21.5 19.5
processMark $doc 182 19.5
$doc font -family helvetica -style bold -size 11 -color white
$doc text "Typographical marks and control scales (CMYK)" \
    -at {105 24.5} -align center -anchor middle
$doc font -style {} -size 8 -color black
$doc text "Everything below is drawn - no picture is embedded and pdfimages\
    lists none. The one thing this page needed that the package did not have\
    is overprint, which is on page 2." -at {20 33} -width 170

# -- the tone scales, and the four ramps beside them ------------------------
#
# Ten steps per plate, 100 down to 10 per cent, with the number INSIDE the
# patch: a strip is read at arm's length and a caption underneath would be
# lost. White numerals over the heavy end, black over the light one.
set y 44
foreach {letter solid} $plates {
    $doc font -style bold -size 9 -color black
    $doc text $letter -at [list 20 [expr {$y + 5}]]
    set x 25
    foreach tint {100 90 80 70 60 50 40 30 20 10} {
        $doc rect -at [list $x $y] -size {13 11} -fill [plateTint $solid $tint]
        # An if, not an expr with braces: expr hands back the braces with the
        # value, and "{1 1 1}" is not a colour.
        if {$tint > 50} {
            $doc font -size 7 -color white
        } else {
            $doc font -size 7 -color black
        }
        $doc text $tint -at [list [expr {$x + 6.5}] [expr {$y + 4}]] \
            -align center
        set x [expr {$x + 14}]
    }
    # The solid, and then the ramp: a Shading Type 2 from paper to full ink.
    # The ramp shows where a screen breaks up and where it fills in, which
    # ten discrete steps cannot.
    $doc rect -at [list $x $y] -size {11 11} -fill $solid
    $doc font -size 7 -color white
    $doc text $letter -at [list [expr {$x + 5.5}] [expr {$y + 4}]] -align center
    $doc shading axial -at [list [expr {$x + 13}] $y] -size {12 11} \
        -colors [list {cmyk 0 0 0 0} $solid] -angle 0
    set y [expr {$y + 12}]
}

# -- the colour bars --------------------------------------------------------
#
# The four inks and the three colours that only exist because two of them
# overlap. Two rows, the second shifted by half a patch: a bar that is read
# across the sheet finds an ink that runs heavy on one side, and the offset
# row catches what falls between the patches of the first.
set y [expr {$y + 6}]
$doc font -style bold -size 9 -color black
$doc text "Colour bars - the inks, and what two of them make together" \
    -at [list 20 $y]
set y [expr {$y + 5}]
set bars {}
foreach {letter colour} $plates { lappend bars $colour }
foreach {letter colour} $overprints { lappend bars $colour }
lappend bars {cmyk 0 0 0 1}
foreach offset {0 5.5} {
    set x [expr {20 + $offset}]
    for {set repeat 0} {$repeat < 2} {incr repeat} {
        foreach colour $bars {
            $doc rect -at [list $x $y] -size {10 7} -fill $colour
            set x [expr {$x + 10.5}]
        }
    }
    set y [expr {$y + 8}]
}
# Plus the height of the line itself: [text] puts the BASELINE at y, so a
# caption written at the y a bar ended on stands in the bar. Seen at 90 dpi.
set y [expr {$y + 3}]
$doc font -style {} -size 7
$doc text "C M Y K, then R = M+Y, G = C+Y, B = C+M, and K again. The second\
    row is offset by half a patch." -at [list 20 $y] -width 170

# -- slur and doubling ------------------------------------------------------
#
# The gauge nobody guesses from a screen. Fine lines ACROSS the direction of
# travel and fine lines ALONG it, at the same width: if the sheet slurs, the
# ones across thicken and the ones along do not. Doubling shows as a ghost
# beside every line. The numbers name the ink coverage the block is printed
# at, which is what makes two sheets comparable.
set y [expr {$y + 8}]
$doc font -style bold -size 9 -color black
$doc text "Slur and doubling gauge" -at [list 20 $y]
set y [expr {$y + 8}]
$doc font -style {} -size 6 -color black
$doc text "100/100/100/100" -at [list 105 [expr {$y - 0.5}]] -align center
set black {cmyk 0 0 0 1}
foreach width {0.15 0.3 0.6 1.0} {
    $doc line -from [list 20 $y] -to [list 90 $y] -stroke $black -width $width
    $doc line -from [list 120 $y] -to [list 190 $y] -stroke $black \
        -width $width
    set y [expr {$y + 3}]
}
# The same widths turned ninety degrees, so the pair can be compared.
set x 20
foreach width {0.15 0.3 0.6 1.0} {
    for {set i 0} {$i < 14} {incr i} {
        $doc line -from [list $x $y] -to [list $x [expr {$y + 9}]] \
            -stroke $black -width $width
        set x [expr {$x + 2.2}]
    }
    set x [expr {$x + 6}]
}
set y [expr {$y + 15}]
$doc font -size 7
$doc text "Lines across the run and along it, at 0.15, 0.3, 0.6 and 1.0 mm.\
    Slur thickens one direction and not the other; doubling puts a ghost\
    beside every line." -at [list 20 $y] -width 170

exampleFooter $doc

# ---------------------------------------------------------------------------
# Page 2: the marks a loupe reads, and the switch no reader shows
# ---------------------------------------------------------------------------

$doc page add
$doc font -family helvetica -style bold -size 13 -color black
$doc text "Registration, screens, and overprint" -at {20 22}

# -- registration marks, four kinds -----------------------------------------
$doc font -style {} -size 8
$doc text "Four marks, each answering the same question a different way: do\
    the plates land on top of one another?" -at {20 29} -width 170

set y 40
$doc font -style bold -size 9
$doc text "Registration" -at [list 20 $y]
set y [expr {$y + 4}]

# 1: the classic target in all four plates at once
registrationTarget $doc 32 [expr {$y + 10}] 6
# 2: one ring per plate, concentric
separationTarget $doc 70 [expr {$y + 10}] 7 $plates
# 3: the four squares, which is the process mark again at a readable size
processMark $doc 100 [expr {$y + 4}] 6
# 4: a rosette in all four plates
rosette $doc 145 [expr {$y + 10}] 8 {cmyk 1 1 1 1}

$doc font -style {} -size 6.5 -color black
foreach {x label} {32 "cmyk 1 1 1 1" 70 "one ring per plate"
                   106 "the four plates" 145 "rosette, 36 rays"} {
    $doc text $label -at [list $x [expr {$y + 22}]] -align center
}
set y [expr {$y + 28}]

# -- the screens ------------------------------------------------------------
#
# What a loupe is for. Each patch is ONE TILING PATTERN: the tile is drawn
# once and repeated by the reader, so a field of thousands of dots costs the
# file one small stream. A dot screen shows whether the press holds its
# tones, a line screen whether it doubles, a cross screen whether it slurs in
# one direction, and the rosette whether the four rulings beat.
$doc font -style bold -size 9
$doc text "Screens - one tiling pattern per patch" -at [list 20 $y]
set y [expr {$y + 5}]

set x 20
foreach {letter solid} $plates {
    # The names carry the plate letter: a pattern is a document-wide resource
    # and two plates would otherwise share one tile, and its colour with it.
    $doc pattern create dots$letter -size {1.6 1.6} -script [list \
        apply {{doc solid} { $doc circle -at {0.8 0.8} -radius 0.5 -fill $solid }} \
        $doc $solid]
    $doc pattern create lines$letter -size {1.6 1.6} -script [list \
        apply {{doc solid} { $doc rect -at {0 0} -size {1.6 0.7} -fill $solid }} \
        $doc $solid]
    $doc pattern create cross$letter -size {1.6 1.6} -script [list \
        apply {{doc solid} {
            $doc rect -at {0 0} -size {1.6 0.5} -fill $solid
            $doc rect -at {0 0} -size {0.5 1.6} -fill $solid
        }} $doc $solid]
    foreach screen {dots lines cross} {
        $doc rect -at [list $x $y] -size {10 10} \
            -fill [list pattern $screen$letter]
        set x [expr {$x + 10.5}]
    }
    $doc font -style bold -size 7 -color black
    $doc text $letter -at [list [expr {$x - 16}] [expr {$y + 14}]] -align center
    # And a rosette in the plate's own colour beside its three screens. The
    # widths add up: four plates of three patches and a rosette have to fit
    # between 20 and 190 mm, which is 42.5 mm each. Measured, not guessed -
    # the first arrangement put the K rosette off the right edge.
    rosette $doc [expr {$x + 5}] [expr {$y + 5}] 4.5 $solid 24
    set x [expr {$x + 11}]
}
set y [expr {$y + 20}]

# -- a screened ramp --------------------------------------------------------
#
# The one figure that cannot be a tiling pattern: a screen whose DOT GROWS
# across the field. A tile is the same everywhere by definition, so this is
# drawn dot by dot - which is also what a press does, and what the ramp above
# only approximates with continuous tone.
$doc font -style bold -size 9 -color black
$doc text "Screened ramps - the dot grows, so no tile can do it" \
    -at [list 20 $y]
set y [expr {$y + 5}]
foreach {letter solid} $plates {
    set columns 60
    set rows 5
    for {set column 0} {$column < $columns} {incr column} {
        # From nearly closed at the left to nearly open at the right.
        set coverage [expr {1.0 - double($column) / $columns}]
        set radius [expr {0.9 * sqrt($coverage)}]
        for {set row 0} {$row < $rows} {incr row} {
            # Every other row offset by half a step: that is what makes a
            # screen a screen rather than a grid of dots.
            set shift [expr {$row % 2 ? 1.0 : 0.0}]
            $doc circle -at [list [expr {20 + $column * 2.0 + $shift}] \
                [expr {$y + $row * 1.9 + 1}]] -radius $radius -fill $solid
        }
    }
    $doc font -size 7 -color black
    $doc text $letter -at [list 145 [expr {$y + 5}]]
    set y [expr {$y + 12}]
}

# -- overprint, the point of the whole page ---------------------------------
#
# Two rows of the same three inks. In the first the magenta and yellow bars
# knock the cyan out; in the second they overprint. On screen both rows look
# alike, and that is the finding rather than a defect: no reader shows
# overprinting and no validator reports it. The file differs, and the press
# does.
set y [expr {$y + 4}]
$doc font -style bold -size 11 -color black
$doc text "Overprint: the one thing no reader shows" -at [list 20 $y]
set y [expr {$y + 6}]
$doc font -style {} -size 8
$doc text "Both rows are a cyan bar with magenta and yellow across it. The\
    first knocks out, the second overprints - and comes off a press as a\
    different sheet: blue where the magenta crosses the cyan, green where the\
    yellow does, and no white edges where the plates shift." \
    -at [list 20 $y] -width 170
set y [expr {$y + 14}]

foreach {label over} {"knocked out - the default" 0 "overprinted" 1} {
    $doc rect -at [list 20 $y] -size {60 10} -fill {cmyk 1 0 0 0}
    $doc rect -at [list 40 $y] -size {14 10} -fill {cmyk 0 1 0 0} \
        -overprint $over
    $doc rect -at [list 60 $y] -size {14 10} -fill {cmyk 0 0 1 0} \
        -overprint $over
    $doc font -size 7 -color black
    $doc text "-overprint $over - $label" -at [list 86 [expr {$y + 3}]]
    set y [expr {$y + 13}]
}

# And the trap in the same figure, said rather than left to be found: the
# second row is the one a printer wants for black text and the one that
# ruins a light colour.
$doc font -size 7.5 -color {0.55 0.15 0.15}
$doc text "Overprinting is right for black text and wrong for a light\
    colour: yellow over cyan, overprinted, is green - the yellow was wanted\
    and green comes out. Nothing on a screen will tell you." \
    -at [list 20 $y] -width 170

# What the file actually carries, read back out of it rather than asserted.
set states [lsort [dict keys [$doc resource ExtGState]]]
set patterns [llength [$doc pattern names]]

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes), [$doc page count] page(s)"
puts "  graphics states: [join $states {, }]"
puts "  tiling patterns: $patterns, images: none"
puts "  check with: pdfimages -list [file tail $target]"
$doc destroy
