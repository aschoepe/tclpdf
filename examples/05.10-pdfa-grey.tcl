#!/usr/bin/env tclsh
#
# tclpdf example 5.10 - PDF/A with a grey output intent
#
#   tclsh examples/05.10-pdfa-grey.tcl ?output.pdf?
#
# The third of the shipped intents. 5.4 anchors its colours to sRGB, 5.9 to a
# CMYK press condition; this one has no colour at all - a monochrome archival
# copy, the kind of document a scanner or a fax used to produce - and says so
# with a grey output intent: icc/ISOcoated_v2_grey1c_bas.ICC, the grey
# component of the same FOGRA39 characterisation as the CMYK profile.
#
# What the intent buys, and what it costs:
#
#   ONE COMPONENT. The intent goes out with /N 1, and ISO 19005-2 (6.2.4.3)
#   then admits DeviceGray alone: a single number, black, white, silver and
#   the other achromatic names. Everything painted here is that. An RGB or a
#   CMYK value anywhere on the page - a coloured line, a picture in colour -
#   would be refused by [pdfa] at the write, naming the call; try it by
#   changing the rule below to {0.4 0.4 0.5}.
#
#   THE REST is 5.4: every font embedded, XMP with the level, level U for the
#   searchable text.
#
# Check with:  verapdf -f 3u out.pdf
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "05.10-pdfa-grey.pdf"}]
set assets [file join $here assets]
set regular [file join $assets fonts DejaVuSans.ttf]
set bold [file join $assets fonts DejaVuSans-Bold.ttf]
set profile [file join [file dirname $here] icc ISOcoated_v2_grey1c_bas.ICC]

set doc [tclpdf new -unit mm]

$doc info Title "Delivery note 2026-0311 – archive copy"
$doc info Author "Alexander Schoepe"
$doc info Subject "Monochrome archival copy of a delivery note"
$doc info Keywords "archive, grey, monochrome, delivery note"
$doc language en-GB

$doc page add
$doc font embed face $regular
$doc font embed faceBold $bold

# Everything is a grey value: the head bar a dark one, the rules a light one,
# the text black. Not one triple, not one CMYK quadruple on the page.
set dark 0.25
set rule 0.6

# -- the note ---------------------------------------------------------------

$doc rect -at {20 20} -size {170 16} -fill $dark
$doc font -family faceBold -size 14 -color white
$doc text "Delivery note" -at {26 31}
$doc font -family face -size 9 -color white
$doc text "No. 2026-0311" -at {184 31} -align right

$doc font -family face -size 10 -color black
set y [$doc text "Archive copy. The original went out on paper with the goods;\
    this is the copy the archive keeps, written as PDF/A-3U with a grey output\
    intent because it has no colour to keep - and a document that declares\
    grey may carry nothing but grey." \
    -at {20 44} -width 170 -align justify -anchor top]

$doc table -at [list 20 [expr {$y + 6}]] -width 170 -theme grid \
    -style {family face} -headStyle {family faceBold} \
    -head {{Pos. Item Quantity}} \
    -body {
        {1 "Folding boxes, 120 x 80 x 40 mm, printed 4/0" "12 500"}
        {2 "Pallets, EUR, exchanged" "9"}
        {3 "Delivery note copies for the archive" "1"}
    } \
    -columns {{width 14 align right} {} {width 30 align right}}

set y [expr {$y + 52}]
$doc font -family faceBold -size 10 -color black
$doc text "Received in good order" -at [list 20 $y]
$doc font -family face -size 9
$doc text "Goods inward, Bochum" -at [list 20 [expr {$y + 7}]]
$doc line -from [list 20 [expr {$y + 18}]] -to [list 90 [expr {$y + 18}]] \
    -stroke $rule -width 0.3

# A stamp, grey too - a form placed at half opacity is a transparency group
# without a colour space of its own, and composites in the page's grey.
$doc form create stamp -size {40 40} -script {
    $doc circle -at {20 20} -radius 18 -stroke $dark -width 1.5
    $doc font -family faceBold -size 8 -color $dark
    $doc text "RECEIVED" -at {20 22} -align center
    $doc font -family face -size 6 -color $dark
    $doc text "17.08.2026" -at {20 27} -align center
}
$doc form place stamp -at [list 140 [expr {$y - 10}]] -opacity 0.6

# -- the declaration ------------------------------------------------------

$doc pdfa -part 3 -conformance U -profile $profile

set state [$doc pdfa state]
puts "  PDF/A-[dict get $state part][dict get $state conformance],\
    intent from [file tail [dict get $state profile]]"

# The footer paints in grey as well - it takes a colour for exactly this.
exampleDone $doc $target face $rule
