#!/usr/bin/env tclsh
#
# tclpdf example 3.3 - SVG as real vectors
#
#   tclsh examples/03.03-svg.tcl ?output.pdf?
#
# A drawing that stays a drawing. Every path in the SVG becomes PDF path
# operators, so it is sharp at any zoom and costs a fraction of a picture.
#
#
# What is covered was decided by measurement over 14995 SVG files on this
# machine rather than by reading the standard front to back. In a sample of
# 300, <filter> and <animate> occur zero times; the elliptical arc is the most
# frequent path command of all, ahead of moveto - and PDF has no arc operator,
# so every one of them becomes up to four Bezier segments.
#
# Whatever is not covered is skipped and counted, and [$doc svg info] reports
# it. Silence would be the wrong answer twice over: the format expects unknown
# elements to be ignored, but a caller still has to be able to find out.
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "03.03-svg.pdf"}]
set images [file join $here assets images]

set doc [tclpdf new -unit mm]
$doc info Title "SVG as vectors"
$doc page add

$doc font -family helvetica -style bold -size 15
$doc text "SVG stays vector" -at {20 22}

# -- the same drawing at four sizes ----------------------------------------

$doc font -style {} -size 9
$doc text "One file, four sizes. A raster image would blur; these are paths." \
    -at {20 30} -width 170

set drawing [file join $images sample-vector.svg]
if {[file exists $drawing]} {
    puts "  natural size: [$doc svg size $drawing] mm"
    set x 20
    foreach width {70 45 28 16} {
        $doc svg $drawing -at [list $x 38] -width $width
        $doc font -size 6
        $doc text "$width mm" -at [list $x [expr {38 + $width * 0.75 + 3}]]
        incr x [expr {$width + 6}]
    }
}

# -- the test drawings -----------------------------------------------------

$doc font -style bold -size 10
$doc text "The test drawings" -at {20 96}
$doc font -style {} -size 8
$doc text "Built so that a translation error is visible without reading the\
    source: every shape is labelled with what it must look like, and several\
    appear twice by different routes so they check themselves." \
    -at {20 101} -width 170

set y 112
set x 20
set skipped {}
foreach name {svg-paths svg-arcs svg-shapes svg-transform} {
    set file [file join $images $name.svg]
    if {![file exists $file]} {
        continue
    }
    $doc rect -at [list $x $y] -size {40 56} -stroke {0.75 0.75 0.8} -width 0.2
    $doc svg $file -at [list [expr {$x + 1}] [expr {$y + 1}]] -size {38 54}
    set info [$doc svg info]
    if {[dict size $info]} {
        dict set skipped $name $info
    }
    $doc font -size 6
    $doc text $name -at [list $x [expr {$y + 60}]]
    incr x 44
}

# -- inline markup ---------------------------------------------------------

$doc font -style bold -size 10
$doc text "Markup passed in directly" -at {20 182}
$doc font -style {} -size 8
$doc text "-data takes a string instead of a file: a chart, a sparkline or a\
    signature built at run time never has to touch the disk." \
    -at {20 187} -width 170

set bars {}
set x 5
foreach value {34 58 41 72 29 63} {
    set height [expr {$value * 0.9}]
    append bars "<rect x=\"$x\" y=\"[expr {70 - $height}]\" width=\"12\"\
        height=\"$height\" fill=\"#4a6fa5\"/>"
    incr x 15
}
$doc svg -data "<svg viewBox=\"0 0 95 75\" xmlns=\"http://www.w3.org/2000/svg\">
    <line x1=\"0\" y1=\"70\" x2=\"95\" y2=\"70\" stroke=\"#333\" stroke-width=\"0.8\"/>
    $bars
    <text x=\"47\" y=\"8\" font-size=\"7\" text-anchor=\"middle\">built in Tcl</text>
  </svg>" -at {20 196} -width 60

$doc font -size 7
$doc text "The same numbers as a table, for comparison:" -at {90 200}
$doc table -at {90 204} -width 60 -theme plain \
    -head {{Month Value}} \
    -body {{Jan 34} {Feb 58} {Mar 41} {Apr 72} {May 29} {Jun 63}} \
    -columns {{} {align right}}

$doc font -size 7
$doc text "Skipped while drawing: [expr {[dict size $skipped] ?
    $skipped : {nothing}}]" -at {20 268} -width 170

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes)"
if {[dict size $skipped]} {
    puts "  skipped: $skipped"
}
$doc destroy
