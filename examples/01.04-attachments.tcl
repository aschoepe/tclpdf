#!/usr/bin/env tclsh
#
# tclpdf example 1.4 - attachments
#
#   tclsh examples/01.04-attachments.tcl ?output.pdf?
#
# A PDF can carry other files inside it. This one is a test report that brings
# its own raw measurements along: the reader sees the summary, and whoever
# wants to recalculate opens the attachment.
#
# Attachments are a core feature here, and ZUGFeRD (example 5.1) is a special
# case built on top of them - which is why a document can carry several.
#
# /AFRelationship says WHAT the attachment is to the document:
#
#   Source        the file the document was generated from
#   Data          the data behind what is shown
#   Alternative   the same content in another form - ZUGFeRD uses this one
#   Supplement    additional material
#   Unspecified   the default, and the least useful
#
# Check the result with:  qpdf --list-attachments out.pdf
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "01.04-attachments.pdf"}]

set doc [tclpdf new -unit mm]
$doc info Title "Coating thickness report SR-2026-114"
$doc info Author "Materials laboratory"
$doc info Subject "Test report with the raw measurements attached"
$doc page add

# Standard fonts throughout - nothing here needs an embedded face, and a
# document that does not need one should not carry one.
$doc font -family helvetica -style bold -size 15
$doc text "Coating thickness report" -at {20 22}
$doc font -style {} -size 9
$doc text "Report SR-2026-114  -  specimen batch 7841  -  measured 2026-08-03" -at {20 29}

$doc line -from {20 33} -to {190 33} -stroke {0.6 0.6 0.65} -width 0.3

$doc font -size 10
set y [$doc text "Twenty measurements were taken across the specimen at even\
    spacing. The summary below is what the report states; the individual\
    readings are attached as a comma-separated file so that the calculation\
    can be repeated without asking for them." \
    -at {20 42} -width 170 -align justify -anchor top]

# The numbers shown here are the ones in the attached file - a document whose
# summary disagrees with its own data is worse than one without data.
set readings {41.2 40.8 42.5 41.9 40.1 43.0 41.7 42.2 40.6 41.4
    42.8 41.1 40.9 42.0 41.6 43.2 40.4 41.8 42.3 41.0}
set total 0.0
set lowest [lindex $readings 0]
set highest [lindex $readings 0]
foreach value $readings {
    set total [expr {$total + $value}]
    if {$value < $lowest} { set lowest $value }
    if {$value > $highest} { set highest $value }
}
set mean [expr {$total / [llength $readings]}]

$doc table -at [list 20 [expr {$y + 6}]] -width 90 -theme grid \
    -head {{Quantity Value}} \
    -body [list \
        [list "Readings" [llength $readings]] \
        [list "Mean" [format %.2f $mean]] \
        [list "Lowest" [format %.2f $lowest]] \
        [list "Highest" [format %.2f $highest]] \
        [list "Range" [format %.2f [expr {$highest - $lowest}]]]] \
    -columns {{} {align decimal}}

# The raw data, built here and attached from memory rather than from a file -
# -data exists for exactly this case.
set csv "position_mm,thickness_um\n"
set position 5
foreach value $readings {
    append csv "$position,$value\n"
    incr position 5
}
$doc attach -data $csv -name readings.csv -mime text/csv \
    -relationship Data -description "The twenty individual readings"

# A second attachment, of a different kind: the procedure the report follows.
$doc attach -data "ISO 2360 - eddy current method\nProbe: type N, calibrated\
    2026-07-30\nTemperature: 21.4 C, humidity 44 %\n" \
    -name procedure.txt -mime text/plain -relationship Supplement \
    -description "Method and conditions"

$doc font -size 8
$doc text "Two files are attached to this document: readings.csv with the raw\
    measurements, and procedure.txt with the method." \
    -at {20 250} -width 170

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes)"
puts "  attachments: [join [$doc attachments] {, }]"
$doc destroy
