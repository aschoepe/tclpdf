#!/usr/bin/env tclsh
#
# tclpdf example 1.5 - form XObjects: draw once, place many times
#
#   tclsh examples/01.05-forms.tcl ?output.pdf?
#
# A letterhead is the case this exists for. Drawn as a form XObject it becomes
# ONE object in the file, and every page that carries it costs a reference -
# not a copy. The same drawing repeated on eighty pages of a report is the
# difference between a file that mails and one that does not.
#
# Two things about a form are easy to get wrong:
#
#   Inside the -script the origin is the form's own TOP left corner and y
#   counts downward - the same convention as everywhere else in tclpdf, and
#   NOT the bottom-left system a form XObject is defined in (ISO 32000-1,
#   8.10.2). The package converts against the form's own height exactly as it
#   converts against the page height, so nothing here is a special case. This
#   comment claimed the opposite until it was measured: a rect at {0 0} in a
#   100 pt form comes out as "0 90 10 10 re", which is the top.
#
#   Placing is a transformation, not a redraw: -scale, -rotate and -opacity
#   change the matrix the form is drawn through, and -fit with -fitMode names
#   a box instead of a factor and works the factor out from it. The object
#   itself stays exactly one object, which is what the count at the end
#   demonstrates.
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "01.05-forms.pdf"}]

set doc [tclpdf new -unit mm]
$doc info Title "tclpdf example: form XObjects"
$doc page add

# The letterhead, drawn once. Inside here {0 0} is the BOTTOM left corner of
# the form and y grows upward - see the note in the header.
$doc form create letterhead -size {170 30} -script {
  $doc rect -at {0 0} -size {170 30} -fill {0.92 0.94 0.98}
  $doc rect -at {0 28} -size {170 2} -fill {0.15 0.35 0.6}
  $doc font -family helvetica -size 14 -style bold
  $doc text "Northgate Pottery" -at {6 12}
  $doc font -size 8 -style {}
  $doc text "14 Kiln Lane - Northgate - www.example.invalid" -at {6 19}
  $doc circle -at {155 15} -radius 8 -fill {0.15 0.35 0.6} -opacity 0.6
}
puts "  form size: [$doc form size letterhead] mm"

# A stamp defined in points, in a millimetre document: -unit reads -size in
# another unit than the document's - the size a print shop or a legacy
# template states. Inside the script the document unit applies as always,
# and [form size] answers in it: 72 by 36 points are 25.4 by 12.7 mm.
$doc form create stamp -size {72 36} -unit pt -script {
  $doc rect -at {0 0} -size {25.4 12.7} -stroke {0.7 0.15 0.1} -width 0.6 -radius 2
  $doc font -family helvetica -size 7 -style bold -color {0.7 0.15 0.1}
  $doc text "RECEIVED" -at {12.7 8} -align center
}
puts "  stamp size: [lmap v [$doc form size stamp] {format %.1f $v}] mm (defined as 72 x 36 pt)"
$doc form place stamp -at {160 50} -rotate -12
# The font is document state, not part of the form: the stamp's colour would
# stay in force for the page text below, so it is taken back here.
$doc font -color black

$doc form place letterhead -at {20 15}
$doc font -family helvetica -size 10
$doc text "First page" -at {20 60}

# Second page: the same form again. No second object enters the file.
$doc page add
$doc form place letterhead -at {20 15}
$doc form place letterhead -at {20 120} -scale 0.5 -opacity 0.4
$doc form place letterhead -at {20 200} -rotate 5
$doc text "Second page - the same object three times, scaled, faded and turned" \
    -at {20 60}

# A form is a transparency group (ISO 32000-1, 11.6.6), so -opacity fades it
# as ONE object. That shows where shapes inside the form overlap: the square
# is drawn over the disc, and at -opacity 0.5 the disc must not show through
# it - faded per object it would, and the overlap would come out darker than
# either. The disc's own -opacity 0.6 in the letterhead above is the other
# half of the same rule: inside a group the alpha starts at 1, so the faded
# placement fades the disc too, instead of the disc's 0.6 replacing the 0.4.
# A BOX INSTEAD OF A FACTOR, built on 2026-08-24. Until then [form place]
# knew -scale alone, so a caller with a letterhead and a box had to work the
# factor out by hand from [form size] - the arithmetic that already stood in
# the package for pictures. -fit takes the box and does it; contain puts the
# whole form inside, cover covers the whole box and clips what hangs over.
#
# The seal below is 25 by 25 and the boxes are 30 by 18, so the two modes
# differ visibly: contain leaves bands left and right, cover fills the box and
# loses the top and bottom of the seal.
$doc page add
$doc font -family helvetica -size 10
$doc text "A form fitted into a box" -at {20 20}
$doc font -size 8
$doc text "The box is drawn so the difference can be seen. Both placements\
    name the same rectangle; only -fitMode differs." -at {20 26} -width 170

$doc form create fitted -size {50 16} -script {
  $doc rect -at {0 0} -size {50 16} -fill {0.15 0.35 0.6}
  $doc circle -at {8 8} -radius 5 -fill {0.95 0.8 0.2}
}
set y 36
foreach {mode label} {contain "-fitMode contain: the whole form is inside"
    cover "-fitMode cover: the box is covered, the rest cut off"} {
  $doc rect -at [list 20 $y] -size {30 18} -stroke {0.6 0.6 0.6} -width 0.2
  $doc form place fitted -at [list 20 $y] -fit {30 18} -fitMode $mode \
      -artifact 1
  $doc text $label -at [list 56 [expr {$y + 8}]]
  incr y 26
}

# The anchors, which only have something to move where the fitted form is
# smaller than the box on one axis - which is what contain leaves.
$doc text "-align and -valign, in the same 30 by 18 box:" -at [list 20 $y]
incr y 6
foreach {align valign} {left top center middle right bottom} {
  $doc rect -at [list 20 $y] -size {30 18} -stroke {0.6 0.6 0.6} -width 0.2
  $doc form place fitted -at [list 20 $y] -fit {30 18} -align $align \
      -valign $valign -artifact 1
  $doc text "-align $align -valign $valign" -at [list 56 [expr {$y + 8}]]
  incr y 22
}

$doc form create seal -size {25 25} -script {
  $doc circle -at {10 10} -radius 10 -fill {0.15 0.35 0.6}
  $doc rect -at {8 8} -size {17 17} -fill {0.85 0.3 0.2}
}
$doc form place seal -at {120 115}
$doc form place seal -at {150 115} -opacity 0.5
$doc font -size 8
$doc text "the same form opaque and at -opacity 0.5:" -at {120 145}
$doc text "the square hides the disc in both" -at {120 149}

# A pattern belongs to the space of the stream that carries it (ISO 32000-2,
# 8.7.2): on a page that is the page, inside a form it is the form's own
# space. So a gradient a form fills with is created INSIDE the form - then
# every placement carries it, and the two below match although they stand
# in different places. A gradient placed on the page and used in here
# would be refused, and that refusal is the point: the matrix that would put
# it right depends on where the form is painted, and a form may be painted
# more than once. Give -matrix if the numbers are meant in another space.
$doc form create badge -size {36 14} -script {
  $doc shading pattern sheen axial -at {0 0} -size {36 14} \
      -colors {{0.20 0.35 0.60} {0.45 0.70 0.90}} -angle 20
  $doc rect -at {0 0} -size {36 14} -radius 2 -fill {pattern sheen}
  $doc font -family helvetica -size 7 -style bold -color white
  $doc text "PAID" -at {13 9}
}
$doc form place badge -at {20 160}
$doc form place badge -at {120 160}
$doc font -family helvetica -size 8 -style {} -color black
$doc text "one form, its gradient created inside it, placed twice" -at {20 180}

exampleFooter $doc

$doc write $target

# Count what actually stands in the file. Nine placements, four objects -
# the claim in the header, checked against the bytes rather than asserted.
set writer [$doc writer]
set forms 0
for {set n 1} {$n <= [$writer count]} {incr n} {
  if {[string match {*/Subtype /Form*} [$writer body $n]]} { incr forms }
}
puts "  form XObjects in the file: $forms (placed nine times)"
puts "  known forms: [$doc form names]"
$doc destroy
puts "  written: $target ([file size $target] bytes)"
