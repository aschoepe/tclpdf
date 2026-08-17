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
#   change the matrix the form is drawn through. The object itself stays
#   exactly one object, which is what the count at the end demonstrates.
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
$doc form create seal -size {25 25} -script {
  $doc circle -at {10 10} -radius 10 -fill {0.15 0.35 0.6}
  $doc rect -at {8 8} -size {17 17} -fill {0.85 0.3 0.2}
}
$doc form place seal -at {120 115}
$doc form place seal -at {150 115} -opacity 0.5
$doc font -size 8
$doc text "the same form opaque and at -opacity 0.5:" -at {120 145}
$doc text "the square hides the disc in both" -at {120 149}

exampleFooter $doc

$doc write $target

# Count what actually stands in the file. Seven placements, three objects -
# the claim in the header, checked against the bytes rather than asserted.
set writer [$doc writer]
set forms 0
for {set n 1} {$n <= [$writer count]} {incr n} {
  if {[string match {*/Subtype /Form*} [$writer body $n]]} { incr forms }
}
puts "  form XObjects in the file: $forms (placed seven times)"
puts "  known forms: [$doc form names]"
$doc destroy
puts "  written: $target ([file size $target] bytes)"
