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
#   Data          the data behind what is shown - ZUGFeRD's MINIMUM and
#                 BASIC WL profiles use this one
#   Alternative   the same content in another form - ZUGFeRD's fuller
#                 profiles (BASIC and up) use this one
#   Supplement    additional material
#   Unspecified   the default, and the least useful
#
# All five appear here, each on the file it fits. Alongside them the two other
# things of the same manual section: a link with -zoom, and a bookmark branch
# folded shut with -open 0.
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

# The footer every example draws - shared, because one copy per example is
# how a block starts drifting.
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

set summaryTop [expr {$y + 6}]
set summary [list \
    [list "Readings" [llength $readings]] \
    [list "Mean" [format %.2f $mean]] \
    [list "Lowest" [format %.2f $lowest]] \
    [list "Highest" [format %.2f $highest]] \
    [list "Range" [format %.2f [expr {$highest - $lowest}]]]]
set summaryBottom [$doc table -at [list 20 $summaryTop] -width 90 -theme grid \
    -head {{Quantity Value}} -body $summary -columns {{} {align decimal}}]

# A link over the summary that lands on the same table magnified: -to is the
# point the reader is taken to, -zoom the magnification it applies there (2 is
# 200 %). Without -zoom the reader keeps whatever it has. Drawn as nothing -
# the table above is what the reader sees and clicks.
$doc link -at [list 20 $summaryTop] \
    -size [list 90 [expr {$summaryBottom - $summaryTop}]] \
    -page 0 -to [list 20 $summaryTop] -zoom 2 -tooltip "The summary, magnified"

# The outline of a one-page report is short, and its branch is folded shut:
# -open 0 keeps the children hidden until the reader unfolds the entry, which
# is what an outline of many reports in one viewer wants.
set report [$doc bookmark "Report SR-2026-114" -open 0]
$doc bookmark "Summary" -at [list 20 $summaryTop] -parent $report

# The raw data, built here and attached from memory rather than from a file -
# -data exists for exactly this case.
set csv "position_mm,thickness_um\n"
set position 5
foreach value $readings {
    append csv "$position,$value\n"
    incr position 5
}
# -date is when the DATA was recorded, not when this PDF was written. An
# archive that keeps the report for ten years reads it off the attachment, and
# a value nobody sets is left out rather than invented - which is also what
# keeps two runs of the same document byte-identical.
$doc attach -data $csv -name readings.csv -mime text/csv \
    -relationship Data -description "The twenty individual readings" \
    -date "D:20260730081500+02'00'"

# A second attachment, of a different kind: the procedure the report follows.
$doc attach -data "ISO 2360 - eddy current method\nProbe: type N, calibrated\
    2026-07-30\nTemperature: 21.4 C, humidity 44 %\n" \
    -name procedure.txt -mime text/plain -relationship Supplement \
    -description "Method and conditions"

# The other three relationships, each on the file it describes. Source is the
# file the document was generated from - here that is this very script.
# Alternative is the same content in another form: the summary table as plain
# text, attached uncompressed (-compress 0) so that it can be read straight out
# of the PDF with a text editor. Unspecified is the default and says nothing;
# it is written out here so that the choice is visible rather than silent.
$doc attach [info script] -name [file tail [info script]] -mime text/plain \
    -relationship Source -description "The script this report was made with"

set text "Coating thickness report SR-2026-114\n"
foreach row $summary {
    append text [format "%-10s %s\n" {*}$row]
}
$doc attach -data $text -name summary.txt -mime text/plain \
    -relationship Alternative -compress 0 \
    -description "The summary table as plain text"

$doc attach -data "Specimen batch 7841 was stored at room temperature for\
    48 h before measuring.\n" -name note.txt -mime text/plain \
    -relationship Unspecified -description "A note on the specimen"

exampleFooter $doc

# ---------------------------------------------------------------------------
# Page 2: what is attached, and under which relationship
# ---------------------------------------------------------------------------
#
# A page of its own, because the list belongs to the reader rather than to the
# report: a viewer shows attachments in a pane the reader has to know about,
# and a document that carries five files without ever saying so on paper is
# one printout away from losing them.

$doc page add
$doc bookmark "Attachments" -at {20 22} -parent $report

$doc font -family helvetica -style bold -size 15
$doc text "Attached files" -at {20 22}
$doc font -style {} -size 9
$doc text "Five files travel with this report" -at {20 29}
$doc line -from {20 33} -to {190 33} -stroke {0.6 0.6 0.65} -width 0.3

$doc font -size 10
set y [$doc text "Every attachment names a RELATIONSHIP - what the file is to\
    the document it rides in. The five values below are the whole vocabulary\
    ISO 32000-2 gives for it (Table 43), and a reader that sorts attachments\
    goes by them rather than by the file name." \
    -at {20 42} -width 170 -align justify -anchor top]

# The rows carry what was written above; the check below is what makes them
# trustworthy. A list beside the data always drifts - so it is measured
# against the document rather than believed.
set listed {
    {readings.csv Data "The twenty individual readings"}
    {procedure.txt Supplement "Method and conditions"}
    {01.04-attachments.tcl Source "The script this report was made with"}
    {summary.txt Alternative "The summary table as plain text"}
    {note.txt Unspecified "A note on the specimen"}
}
set named {}
foreach row $listed {
    lappend named [lindex $row 0]
}
if {[lsort $named] ne [lsort [$doc attachments]]} {
    # Never reached, and it says so if it ever is: the table on this page
    # would then be describing a document other than this one.
    return -code error "the table lists [join [lsort $named] {, }] but the\
        document carries [join [lsort [$doc attachments]] {, }]"
}

$doc table -at [list 20 [expr {$y + 6}]] -width 170 -theme grid \
    -head {{File Relationship "What it holds"}} -body $listed \
    -columns {{width 45} {width 35} {}}

$doc font -size 8
$doc text "summary.txt is attached uncompressed, so it can be read straight\
    out of the PDF with a text editor - open this file in one and search for\
    the word Readings." -at {20 250} -width 170

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes)"
puts "  attachments: [join [$doc attachments] {, }]"
$doc destroy
