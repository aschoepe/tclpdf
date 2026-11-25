#!/usr/bin/env tclsh
#
# tclpdf example 4.6 - a numbered appendix between a delivery note and its copy
#
#   tclsh examples/04.06-table-appendix-numbers.tcl ?output.pdf?
#
# One document, three parts: a delivery note whose table runs over two
# pages, an appendix of packing lists, one page per parcel, and a copy sheet
# for the carrier behind them. The note counts its own pages, the appendix
# counts its own from 1 - "Appendix page 2 of 4" -, and the copy sheet
# carries no number at all.
#
# A [pageNumbers] run numbers from -from to the last page, and %n is the
# page's place in the document. That is right for a document of one part and
# wrong for this one: "-from 3" alone printed "Appendix page 3 of 7" on the
# first sheet of the appendix and "7 of 7" on the copy. The way round it was a
# trial document, written only to find out how many pages the note would
# take. Two options make the run a section instead:
#
#   -to is the last page the run numbers, counted from 1 like -from. Pages
#   behind it are left alone. A -to past the last page is refused when the
#   document is written, rather than quietly cut short.
#
#   -start is the number printed on the page -from. Without it the run
#   counts absolutely, as it always has.
#
#   %m is then the number on the run's last page, -start + (-to - -from):
#   4 for an appendix of four pages that starts at 1. -total still states a
#   total of its own, and wins.
#
# The page numbers are drawn when the document is written, but -from and -to
# are known as soon as each part is drawn: [page count] after the table is
# the note's last page, and after the last parcel the appendix's. Nothing is
# counted by hand, and no trial document is needed - the table could break
# onto a third page and the numbers would follow.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "04.06-table-appendix-numbers.pdf"}]

# Fifty-six lines of goods, packed into four parcels - built rather than typed.
set articles {"Hex bolt M8x40" "Washer 8.4" "Hex nut M8" "Threaded rod M8"
    "Wall plug 8 mm" "Angle bracket 60" "Hinge 80 mm" "Wood screw 4x30"}
set rows {}
set parcels {}
for {set line 1} {$line <= 56} {incr line} {
    set article [lindex $articles [expr {$line % [llength $articles]}]]
    set parcel [expr {($line - 1) / 14 + 1}]
    set quantity [expr {($line * 7) % 45 + 5}]
    set row [list $line "4711-[format %03d $line]" $article $quantity "parcel $parcel"]
    lappend rows $row
    dict lappend parcels $parcel $row
}

set doc [tclpdf new -unit mm]
$doc info Title "Delivery note 2026-1125 with packing lists"

# -- part one: the delivery note ---------------------------------------------

$doc page add
$doc font -family helvetica -style bold -size 15
$doc text "Delivery note 2026-1125" -at {20 22}
$doc font -style {} -size 9
$doc text "[llength $rows] lines in [dict size $parcels] parcels; the packing\
    list of each parcel follows as an appendix." -at {20 29}
$doc table -at {20 36} -top 20 -bottom 272 -width 170 -theme striped \
    -head {{Line Article Description Qty Parcel}} \
    -body $rows \
    -columns {{width 14 align right} {width 26} {} {width 16 align right} {width 24}} \
    -repeatHead 1
set noteLast [$doc page count]

# -- part two: the appendix, one packing list per parcel ---------------------

set appendixFirst [expr {$noteLast + 1}]
dict for {parcel lines} $parcels {
    $doc page add
    $doc font -family helvetica -style bold -size 13
    $doc text "Packing list, parcel $parcel" -at {20 22}
    $doc table -at {20 30} -width 170 -theme grid \
        -head {{Line Article Description Qty Parcel}} \
        -body $lines \
        -columns {{width 14 align right} {width 26} {} {width 16 align right} {width 24}}
}
set appendixLast [$doc page count]

# -- part three: the copy for the carrier -------------------------------------

$doc page add
$doc font -family helvetica -style bold -size 13
$doc text "Copy for the carrier" -at {20 22}
$doc font -style {} -size 9
$doc text "Delivery note 2026-1125, [dict size $parcels] parcels. Received in\
    good order:" -at {20 30} -width 170
$doc line -from {20 60} -to {100 60} -stroke {0.5 0.5 0.55} -width 0.2
$doc text "date, signature" -at {20 64}

# -- the numbers ---------------------------------------------------------------
#
# Two runs, one per numbered part. The note: -to ends the run on its last
# page, and %m is that page - "page 2 of 2", not "of 7". The appendix: -from
# and -to are its first and last page, and -start 1 renumbers it, so its
# first sheet reads "Appendix page 1 of 4". The copy sheet lies behind both
# runs and carries neither.
$doc font -family helvetica -style {} -size 8 -color {0.35 0.35 0.4}
$doc pageNumbers -at {190 285} -anchor top -align right -to $noteLast \
    -format "Delivery note, page %n of %m"
$doc pageNumbers -at {190 285} -anchor top -align right \
    -from $appendixFirst -to $appendixLast -start 1 \
    -format "Appendix page %n of %m"

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes), [$doc page count] pages"
puts "  note: pages 1-$noteLast, appendix: pages $appendixFirst-$appendixLast,\
    copy: page [$doc page count]"
$doc destroy
