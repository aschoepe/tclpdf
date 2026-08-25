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
# screens are tiling patterns, the targets and rosettes are polygons, lines
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
# THE TWO PAGES, and the reason nothing is mixed between them. The first is
# what a DENSITOMETER reads: flat patches, large enough to put an instrument
# on - tone scales, ramps, colour bars, the slur gauge. The second is what a
# LOUPE reads: figures that only mean something magnified - registration
# marks, screens, rosettes, and the overprint pair.
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

set black {cmyk 0 0 0 1}
set allPlates {cmyk 1 1 1 1}

# ---------------------------------------------------------------------------
# The elements, each one a procedure - a strip is the same few figures
# repeated per plate, and a copy per plate is how two of them come to differ.
# ---------------------------------------------------------------------------

# A tint of one plate: the same colour with every component scaled.
proc plateTint {solid percent} {
    lassign $solid -> c m y k
    return [list cmyk [expr {$c * $percent / 100.0}] \
        [expr {$m * $percent / 100.0}] [expr {$y * $percent / 100.0}] \
        [expr {$k * $percent / 100.0}]]
}

# The page header: the four-square process mark at each end, the title, and a
# rule under it. No filled bar behind the words - a bar in a tint of its own
# is one more thing on the sheet that can print wrong, and the head of a
# control strip should carry nothing an operator has to discount.
proc pageHead {doc title} {
    set squares {{cmyk 1 0 0 0} {cmyk 0 1 0 0} {cmyk 0 0 1 0} {cmyk 0 0 0 1}}
    foreach x {20 182} {
        set index 0
        foreach colour $squares {
            $doc rect -at [list [expr {$x + ($index % 2) * 4}] \
                [expr {17 + ($index / 2) * 4}]] -size {4 4} -fill $colour
            incr index
        }
    }
    $doc font -family helvetica -style bold -size 13 -color black
    $doc text $title -at {105 23} -align center
    $doc line -from {20 27} -to {190 27} -stroke {cmyk 0 0 0 1} -width 0.5
    return
}

# A star rosette: rays from one centre. What it is for is MOIRE - a rosette
# printed through a screen shows a pattern where the ruling and the rays beat
# against each other, and where that pattern sits says what the ruling is.
# Filled wedges rather than lines: a line of a given width is that width
# everywhere, and a ray has to narrow towards the middle.
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

# A wedge from one angle to another - four of them make a quartered target.
# A fan of thin triangles, because PDF has no arc operator and a quarter
# circle out of one polygon would be a triangle.
proc wedge {doc cx cy radius from extent colour {steps 12}} {
    set rad [expr {3.14159265358979 / 180.0}]
    set step [expr {$extent * $rad / $steps}]
    set start [expr {$from * $rad}]
    for {set i 0} {$i < $steps} {incr i} {
        set a0 [expr {$start + $i * $step}]
        set a1 [expr {$start + ($i + 1) * $step}]
        $doc polygon -points [list \
            $cx $cy \
            [expr {$cx + $radius * cos($a0)}] [expr {$cy + $radius * sin($a0)}] \
            [expr {$cx + $radius * cos($a1)}] [expr {$cy + $radius * sin($a1)}]] \
            -fill $colour -close 1
    }
    return
}

# The crosshair every registration figure sits in: two lines through the
# centre, reaching past the figure, in all four plates at once.
proc crosshair {doc cx cy reach} {
    set all {cmyk 1 1 1 1}
    $doc line -from [list [expr {$cx - $reach}] $cy] \
        -to [list [expr {$cx + $reach}] $cy] -stroke $all -width 0.25
    $doc line -from [list $cx [expr {$cy - $reach}]] \
        -to [list $cx [expr {$cy + $reach}]] -stroke $all -width 0.25
    return
}

# The four-square mark with a crosshair through it: C and M above, Y and K
# below. The smallest figure on the sheet that carries all four plates, and
# the first place a missing plate shows. "filled" draws solid squares, the
# other form sets the letter in the plate's own colour on paper - which reads
# at a glance where a filled mark reads only under a loupe.
proc quadMark {doc cx cy {side 4} {filled 1}} {
    set squares {{cmyk 1 0 0 0} {cmyk 0 1 0 0} {cmyk 0 0 1 0} {cmyk 0 0 0 1}}
    set letters {C M Y K}
    set left [expr {$cx - $side}]
    set top [expr {$cy - $side}]
    set index 0
    foreach colour $squares letter $letters {
        set x [expr {$left + ($index % 2) * $side}]
        set y [expr {$top + ($index / 2) * $side}]
        if {$filled} {
            $doc rect -at [list $x $y] -size [list $side $side] -fill $colour
        } else {
            $doc font -family helvetica -style bold \
                -size [expr {$side * 2.6}] -color $colour
            $doc text $letter -at [list [expr {$x + $side / 2.0}] \
                [expr {$y + $side * 0.8}]] -align center
        }
        incr index
    }
    crosshair $doc $cx $cy [expr {$side * 1.6}]
    return
}

# ---------------------------------------------------------------------------
# Page 1 - what a densitometer reads
# ---------------------------------------------------------------------------

set doc [tclpdf new -unit mm]
$doc info Title "A press control strip"
$doc page add

pageHead $doc "Typographical marks and control scales (CMYK)"

$doc font -family helvetica -style {} -size 8 -color black
$doc text "Flat patches, large enough to put an instrument on. Everything is\
    drawn - no picture is embedded and pdfimages lists none. What only means\
    something under a loupe is on page 2." -at {20 33} -width 170

# -- the tone scales --------------------------------------------------------
#
# Ten steps per plate, 100 down to 10 per cent, with the number INSIDE the
# patch: a strip is read at arm's length and a caption underneath would be
# lost. White numerals over the heavy end, black over the light one. The
# solid sits at the end of the row, where an instrument finds it first.
set y 42
foreach {letter solid} $plates {
    $doc font -style bold -size 9 -color black
    $doc text $letter -at [list 20 [expr {$y + 5}]]
    set x 25
    foreach tint {100 90 80 70 60 50 40 30 20 10} {
        $doc rect -at [list $x $y] -size {14.5 11} -fill [plateTint $solid $tint]
        # White numerals over the heavy end - but the decision is about
        # BRIGHTNESS, not about the amount of ink. Yellow at full strength is
        # a light colour, and white numerals on it were unreadable at 90 dpi;
        # cyan, magenta and black go dark enough to carry them. Seen, not
        # reasoned out.
        #
        # An if, not an expr with braces: expr hands back the braces with the
        # value, and "{1 1 1}" is not a colour.
        if {$tint > 50 && $letter ne "Y"} {
            $doc font -size 7 -color white
        } else {
            $doc font -size 7 -color black
        }
        $doc text $tint -at [list [expr {$x + 7.25}] [expr {$y + 4}]] \
            -align center
        set x [expr {$x + 15.5}]
    }
    $doc rect -at [list $x $y] -size {10 11} -fill $solid
    if {$letter eq "Y"} {
        $doc font -size 7 -color black
    } else {
        $doc font -size 7 -color white
    }
    $doc text $letter -at [list [expr {$x + 5}] [expr {$y + 4}]] -align center
    set y [expr {$y + 12}]
}

# -- the ramps ---------------------------------------------------------------
#
# A ramp is a Shading Type 2 from paper to solid, and it shows what ten
# discrete steps cannot: where a screen breaks up at the light end and where
# it fills in at the dark one. ACROSS the sheet rather than down it, so that
# each bar has the length an instrument traverses.
set y [expr {$y + 6}]
$doc font -style bold -size 9 -color black
$doc text "Continuous ramps - paper to solid, one bar per plate" \
    -at [list 20 $y]
set y [expr {$y + 5}]
foreach {letter solid} $plates {
    $doc font -style bold -size 8 -color black
    $doc text $letter -at [list 20 [expr {$y + 5.5}]]
    $doc shading axial -at [list 25 $y] -size {165 8} \
        -colors [list {cmyk 0 0 0 0} $solid] -angle 0
    set y [expr {$y + 10}]
}

# -- the colour bars --------------------------------------------------------
#
# The four inks and the three colours that only exist because two of them
# overlap. One row: an offset second row catches what falls between the
# patches of the first, which matters on a press and says nothing here.
set y [expr {$y + 5}]
$doc font -style bold -size 9 -color black
$doc text "Colour bars - the inks, and what two of them make together" \
    -at [list 20 $y]
set y [expr {$y + 5}]
set bars {}
foreach {letter colour} $plates { lappend bars [list $letter $colour] }
foreach {letter colour} $overprints { lappend bars [list $letter $colour] }
lappend bars [list K $black]
set x 20
foreach pair $bars {
    lassign $pair letter colour
    $doc rect -at [list $x $y] -size {20.5 10} -fill $colour
    # The same brightness rule as the tone scales: yellow carries a black
    # letter, everything else a white one. Written out rather than computed
    # from the ink values - a patch is either dark enough or it is not, and
    # a formula here would have to guess what "dark enough" means on paper.
    if {$letter eq "Y"} {
        $doc font -style bold -size 7 -color black
    } else {
        $doc font -style bold -size 7 -color white
    }
    $doc text $letter -at [list [expr {$x + 10.25}] [expr {$y + 6.5}]] \
        -align center
    set x [expr {$x + 21.25}]
}
set y [expr {$y + 14}]
$doc font -style {} -size 7 -color black
$doc text "C M Y K, then R = M+Y, G = C+Y, B = C+M, and K again." \
    -at [list 20 $y]

# -- slur and doubling ------------------------------------------------------
#
# The gauge nobody guesses from a screen. Fine lines ACROSS the direction of
# travel and fine lines ALONG it, at the same widths: if the sheet slurs, the
# ones across thicken and the ones along do not. Doubling shows as a ghost
# beside every line. The numbers name the ink coverage the block is printed
# at, which is what makes two sheets comparable.
set y [expr {$y + 10}]
$doc font -style bold -size 9 -color black
$doc text "Slur and doubling gauge" -at [list 20 $y]
set y [expr {$y + 8}]
$doc font -style {} -size 6 -color black
$doc text "100/100/100/100" -at [list 105 [expr {$y - 1}]] -align center
foreach width {0.15 0.3 0.6 1.0} {
    $doc line -from [list 20 $y] -to [list 90 $y] -stroke $black -width $width
    $doc line -from [list 120 $y] -to [list 190 $y] -stroke $black -width $width
    set y [expr {$y + 3}]
}
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
# Page 2 - what a loupe reads
# ---------------------------------------------------------------------------

$doc page add
pageHead $doc "Registration, screens and overprint"

$doc font -family helvetica -style {} -size 8 -color black
$doc text "Figures for a loupe. Every registration mark asks the same\
    question a different way: do the four plates land on top of one another?\
    Each row is a pair - a target and a four-square mark - and a misregister\
    shows in both, as a coloured fringe in the one and as a step in the\
    other." -at {20 33} -width 170

# -- registration, four pairs -----------------------------------------------
set y 46
$doc font -style bold -size 9 -color black
$doc text "Registration" -at [list 20 $y]

set left 40
set right 72
set step 21
set cy [expr {$y + 12}]

# 1: one ring per plate. In register they are concentric; out of register the
#    stack opens up, and the direction it opens in names the plate that moved.
set r 8
foreach {letter colour} $plates {
    $doc circle -at [list $left $cy] -radius $r -stroke $colour -width 1.1
    set r [expr {$r - 1.8}]
}
crosshair $doc $left $cy 9.5
quadMark $doc $right $cy 4 0

# 2: a quartered target, one plate per quadrant - a shift shows as a step
#    where two quadrants meet.
set cy [expr {$cy + $step}]
set angle 90
foreach {letter colour} $plates {
    wedge $doc $left $cy 8 $angle 90 $colour
    incr angle 90
}
crosshair $doc $left $cy 9.5
quadMark $doc $right $cy 4 1

# 3: a rosette per plate, one over the other - the moire figure.
set cy [expr {$cy + $step}]
foreach {letter colour} $plates {
    rosette $doc $left $cy 8 $colour 20
}
crosshair $doc $left $cy 9.5
quadMark $doc $right $cy 3 1

# 4: the plain target, every plate drawing the same figure. If they register,
#    the lines coincide and it stays black on white.
set cy [expr {$cy + $step}]
foreach radius {8 5.5 3} {
    $doc circle -at [list $left $cy] -radius $radius -stroke $allPlates \
        -width 0.4
}
$doc circle -at [list $left $cy] -radius 1.4 -fill $allPlates
crosshair $doc $left $cy 9.5
rosette $doc $right $cy 5.5 $allPlates 24

$doc font -style {} -size 7 -color black
$doc text "Top to bottom, on the left: one ring per plate; a quartered\
    target, one plate to a quadrant; four rosettes over one another; and the\
    plain target every plate draws alike. On the right the four-square mark -\
    as outlined letters, then filled - and a rosette in all four plates." \
    -at [list 95 [expr {$y + 6}]] -width 95

set y [expr {$cy + 15}]

# -- the screens ------------------------------------------------------------
#
# Each patch is ONE TILING PATTERN: the tile is drawn once and repeated by
# the reader, so a field of thousands of dots costs the file one small
# stream. A dot screen shows whether the press holds its tones, a line screen
# whether it doubles, a cross screen whether it slurs in one direction.
$doc font -style bold -size 9 -color black
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
        $doc rect -at [list $x $y] -size {11 11} \
            -fill [list pattern $screen$letter]
        set x [expr {$x + 12}]
    }
    $doc font -style bold -size 7 -color black
    $doc text $letter -at [list [expr {$x - 18}] [expr {$y + 15}]] -align center
    set x [expr {$x + 6}]
}
set y [expr {$y + 20}]

# -- a screened ramp --------------------------------------------------------
#
# The one figure that cannot be a tiling pattern: a screen whose DOT GROWS
# across the field. A tile is the same everywhere by definition, so this is
# drawn dot by dot - which is also what a press does.
$doc font -style bold -size 9 -color black
$doc text "Screened ramps - the dot grows, so no tile can do it" \
    -at [list 20 $y]
set y [expr {$y + 5}]
foreach {letter solid} $plates {
    set columns 70
    set rows 4
    for {set column 0} {$column < $columns} {incr column} {
        set coverage [expr {1.0 - double($column) / $columns}]
        set radius [expr {0.85 * sqrt($coverage)}]
        for {set row 0} {$row < $rows} {incr row} {
            # Every other row offset by half a step: that is what makes a
            # screen a screen rather than a grid of dots.
            set shift [expr {$row % 2 ? 1.0 : 0.0}]
            $doc circle -at [list [expr {25 + $column * 2.3 + $shift}] \
                [expr {$y + $row * 1.9 + 1}]] -radius $radius -fill $solid
        }
    }
    $doc font -style bold -size 7 -color black
    $doc text $letter -at [list 20 [expr {$y + 5}]]
    set y [expr {$y + 10}]
}

# -- overprint --------------------------------------------------------------
#
# Two rows of the same three inks. In the first the magenta and yellow bars
# knock the cyan out; in the second they overprint. On screen both rows look
# alike, and that is the finding rather than a defect: no reader shows
# overprinting and no validator reports it. The file differs, and the press
# does.
set y [expr {$y + 4}]
$doc font -style bold -size 10 -color black
$doc text "Overprint: the one thing no reader shows" -at [list 20 $y]
set y [expr {$y + 5}]
$doc font -style {} -size 7.5
$doc text "Both rows are a cyan bar with magenta and yellow across it. The\
    first knocks out, the second overprints - and comes off a press as a\
    different sheet: blue where the magenta crosses the cyan, green where the\
    yellow does, and no white edges where the plates shift." \
    -at [list 20 $y] -width 170
set y [expr {$y + 12}]

foreach {label over} {"knocked out - the default" 0 "overprinted" 1} {
    $doc rect -at [list 20 $y] -size {60 9} -fill {cmyk 1 0 0 0}
    $doc rect -at [list 40 $y] -size {14 9} -fill {cmyk 0 1 0 0} \
        -overprint $over
    $doc rect -at [list 60 $y] -size {14 9} -fill {cmyk 0 0 1 0} \
        -overprint $over
    $doc font -size 7 -color black
    $doc text "-overprint $over - $label" -at [list 86 [expr {$y + 3}]]
    set y [expr {$y + 12}]
}

# The trap in the same figure, said rather than left to be found.
$doc font -size 7 -color {cmyk 0 0.85 0.85 0.2}
$doc text "Overprinting is right for black text and wrong for a light colour:\
    yellow over cyan, overprinted, is green - the yellow was wanted and green\
    comes out. Nothing on a screen will tell you." -at [list 20 $y] -width 170

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
