#!/usr/bin/env tclsh
#
# tclpdf example 1.9 - text along a path
#
#   tclsh examples/01.09-text-on-path.tcl ?output.pdf?
#
# A seal, a banner, a label following a road: text that does not sit on a
# straight baseline.
#
# PDF has no operator for it. What it has is one text matrix per show
# operation, and that is enough: the path is flattened into short straight
# pieces, the arc length is walked, and every glyph is placed where its own
# width falls and turned by the direction the path takes there.
#
# Two consequences worth knowing before using it:
#
#   THE PATH IS NOT DRAWN. -segments only says where the text runs. Whether a
#   line is visible there is a separate call - which is what lets a caption
#   follow the edge of a picture that has no line at all.
#
#   GLYPHS THAT DO NOT FIT ARE DROPPED, not squeezed in at the end. A string
#   longer than its path comes out short, and the return value - the length of
#   the path - is what a caller measures against beforehand.
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "01.09-text-on-path.pdf"}]

set doc [tclpdf new -unit mm]
$doc info Title "Text along a path"
$doc page add

$doc font -family helvetica -style bold -size 13
$doc text "Text along a path" -at {20 22}
$doc font -style {} -size 8 -color {0.4 0.4 0.45}
$doc text "The grey lines are drawn separately - -segments only says where the\
    text runs." -at {20 29} -width 170

# -- a seal ------------------------------------------------------------------

# A circular arc as Bezier segments. A quarter circle needs one segment with
# its control points at 0.5523 of the radius - the same constant [circle] uses
# internally, and the reason an arc drawn this way sits exactly on the circle
# instead of near it. Angles count clockwise from twelve o'clock, because that
# is how one describes a seal.
proc arcSegments {cx cy radius fromClock toClock} {
    set kappa 0.5522847498307936
    set pi [expr {acos(-1)}]
    set steps [expr {int(ceil(abs($toClock - $fromClock) / 90.0))}]
    set step [expr {($toClock - $fromClock) / double($steps)}]
    set segments {}
    set angle $fromClock
    # Twelve o'clock is straight up, and y grows downwards on the page.
    set point [list [expr {$cx + $radius * sin($angle * $pi / 180)}] \
        [expr {$cy - $radius * cos($angle * $pi / 180)}]]
    lappend segments [list move {*}$point]
    for {set n 0} {$n < $steps} {incr n} {
        set next [expr {$angle + $step}]
        # The sign of the step travels with the tangents: an arc running
        # backwards needs them reversed, or the curve folds into a loop and
        # every glyph lands on the same spot.
        set handle [expr {$kappa * $radius * $step / 90.0}]
        # The tangent at each end, in the direction of travel.
        set t1 [list [expr {[lindex $point 0] + $handle * cos($angle * $pi / 180)}] \
            [expr {[lindex $point 1] + $handle * sin($angle * $pi / 180)}]]
        set end [list [expr {$cx + $radius * sin($next * $pi / 180)}] \
            [expr {$cy - $radius * cos($next * $pi / 180)}]]
        set t2 [list [expr {[lindex $end 0] - $handle * cos($next * $pi / 180)}] \
            [expr {[lindex $end 1] - $handle * sin($next * $pi / 180)}]]
        lappend segments [list curve {*}$t1 {*}$t2 {*}$end]
        set angle $next
        set point $end
    }
    return $segments
}

# The classic case, and the reason -align center exists: the words have to sit
# centred on the arc, not start at one end of it.
set cx 55
set cy 75
set radius 26

$doc circle -at [list $cx $cy] -radius $radius -stroke {0.55 0.62 0.75} -width 0.4
$doc circle -at [list $cx $cy] -radius [expr {$radius - 5}] \
    -stroke {0.80 0.84 0.90} -width 0.2

# The upper half, from nine o'clock to three: left to right over the top.
$doc font -family helvetica -style bold -size 8 -color {0.20 0.30 0.45}
$doc textPath "PRUEFSTELLE BOCHUM" \
    -segments [arcSegments $cx $cy [expr {$radius - 3}] -90 90] -align center

# The lower half runs left to right as well, along an arc BELOW the words, so
# they stay upright: a path from seven to five o'clock would put them on their
# heads. -offset then pushes them off that arc, towards the rim.
$doc font -size 7
$doc textPath "ZERTIFIZIERT 2026" \
    -segments [arcSegments $cx $cy [expr {$radius - 8}] 270 90] \
    -align center -offset -3

$doc font -family helvetica -style {} -size 7 -color {0.4 0.4 0.45}
$doc text "two arcs, -align center" -at [list $cx 112] -align center

# -- a wave ------------------------------------------------------------------

set wave {{move 105 70} {curve 130 45 160 95 185 70}}
$doc path -segments $wave -stroke {0.85 0.85 0.9} -width 0.3
$doc font -family helvetica -style {} -size 10 -color black
set length [$doc textPath "auf einer Kurve gesetzt" -segments $wave -align center]
$doc font -size 7 -color {0.4 0.4 0.45}
$doc text "one curve, [format %.0f $length] mm long" -at {145 112} -align center

# -- an offset, and a label on a shape ---------------------------------------

$doc font -family helvetica -style bold -size 11 -color black
$doc text "Offset from the path" -at {20 130}
$doc font -style {} -size 8 -color {0.4 0.4 0.45}
$doc text "-offset moves the baseline off the path without changing the path\
    itself: positive above, negative below." -at {20 136} -width 170

set arc {{move 25 175} {curve 60 140 120 140 155 175}}
$doc path -segments $arc -stroke {0.85 0.85 0.9} -width 0.3
$doc font -size 9 -color black
foreach {offset colour label} {
    4 {0.20 0.45 0.30} "offset 4, above the line"
    -6 {0.60 0.25 0.25} "offset -6, below it"
} {
    $doc textPath $label -segments $arc -align center -offset $offset \
        -color $colour
}

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes)"
$doc destroy
