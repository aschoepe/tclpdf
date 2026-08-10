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
#   Inside the -script the origin is the form's own bottom left corner and y
#   grows upward, because that is the coordinate system a form XObject is
#   defined in (ISO 32000-1, 8.10.2). Everywhere else in tclpdf -at is the TOP
#   left corner and y counts downward. The script below is the one place in
#   this file where the other convention applies.
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

# The footer every example draws - shared, because eighteen copies of it
# is how a block starts drifting.
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

exampleFooter $doc

$doc write $target

# Count what actually stands in the file. Four placements, one object - the
# claim in the header, checked against the bytes rather than asserted.
set writer [$doc writer]
set forms 0
for {set n 1} {$n <= [$writer count]} {incr n} {
  if {[string match {*/Subtype /Form*} [$writer body $n]]} { incr forms }
}
puts "  form XObjects in the file: $forms (placed four times)"
puts "  known forms: [$doc form names]"
$doc destroy
puts "  written: $target ([file size $target] bytes)"
