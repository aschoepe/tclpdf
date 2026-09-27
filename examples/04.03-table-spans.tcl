#!/usr/bin/env tclsh
#
# tclpdf example 4.3 - spans, column widths, horizontal breaking
#
#   tclsh examples/04.03-table-spans.tcl ?output.pdf?
#
# A timetable and a wide measurement series. Three things that only show up
# once a table stops being a simple grid:
#
#   Spans follow the HTML model rather than a new one: a cell spanning two
#   rows occupies a place in the row below, and that place is NOT written out
#   again. An occupancy grid keeps track, which is what lets spans and
#   automatic column widths coexist.
#
#   Column widths come in three kinds, resolved in this order because each
#   constrains the next: fixed take what they ask for, weighted share what is
#   left in proportion, automatic share the rest according to how wide their
#   content actually is. Without the last part the article column ends up two
#   millimetres wide because it happened to come last.
#
#   -horizontalBreak deals a table too wide for the page out over several
#   pages, repeating the leading columns so the rows stay identifiable.
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "04.03-table-spans.pdf"}]

set doc [tclpdf new -unit mm]
$doc info Title "Spans and column widths"
$doc page add

$doc font -family helvetica -style bold -size 15
$doc text "Spans and widths" -at {20 22}

# -- a timetable: both kinds of span ---------------------------------------

$doc font -size 10
$doc text "A timetable" -at {20 34}
$doc font -style {} -size 8
$doc text "The ferry runs on two lines. The season heading spans four columns;\
    the vessel name spans the rows it applies to." -at {20 39} -width 170

set y [$doc table -at {20 47} -width 170 -theme grid \
    -head [list \
        [list [list text "Summer timetable, 1 May to 30 September" colSpan 5 align center]] \
        {Vessel Departure Arrival Line Fare}] \
    -body {
        {{text "MS Nordwind" rowSpan 3} "07:15" "08:40" "Harbour - Island" "12.50"}
        {"11:30" "12:55" "Harbour - Island" "12.50"}
        {"16:45" "18:10" "Harbour - Island" "12.50"}
        {{text "MS Suedwind" rowSpan 2} "09:00" "09:50" "Island - Lighthouse" "6.00"}
        {"14:20" "15:10" "Island - Lighthouse" "6.00"}
        {{text "Replacement bus on 12 August" colSpan 4} "free"}
    } \
    -foot [list [list [list text "Day pass, both lines" colSpan 4 align right] "16.00"]] \
    -columns {{width 34} {width 24 align center} {width 24 align center} {} \
        {width 22 align decimal}}]

$doc font -style {} -size 7
$doc text "The second and third rows carry no vessel cell at all - the span\
    from above occupies that position, exactly as in HTML." \
    -at [list 20 [expr {$y + 4}]] -width 170

# -- column widths: three kinds --------------------------------------------

$doc font -style bold -size 10
$doc text "Fixed, weighted, automatic" -at [list 20 [expr {$y + 14}]]

set y2 [$doc table -at [list 20 [expr {$y + 20}]] -width 170 -theme striped \
    -head {{Code Description Note Qty}} \
    -body {
        {"A-1" "Short" "one" 3}
        {"B-22" "A description long enough that the column has to be given room for it" "two" 14}
        {"C-333" "Medium length text here" "three" 7}
    } \
    -columns {{width 20} {} {weight 1} {width 16 align right}}]

$doc font -style {} -size 7
$doc text "Column 1 is fixed at 20 mm, column 4 at 16 mm. Column 3 carries a\
    weight, column 2 is automatic - and gets the larger share because its\
    content needs it." -at [list 20 [expr {$y2 + 4}]] -width 170

# -- horizontal breaking ---------------------------------------------------

$doc font -style bold -size 10
$doc text "Too wide for the page" -at [list 20 [expr {$y2 + 14}]]
$doc font -style {} -size 8
$doc text "Twelve columns - 26 mm each but for the 24 mm date column - are\
    310 mm wide. With -horizontalBreak the\
    table is dealt out over further pages, and -repeatColumns 2 keeps the\
    station and the date on every one of them." \
    -at [list 20 [expr {$y2 + 19}]] -width 170

set head {Station Date}
set columns {{width 26} {width 24}}
for {set n 1} {$n <= 10} {incr n} {
    lappend head "Probe $n"
    lappend columns {width 26 align decimal}
}
set body {}
set stationDay 13
foreach station {North East South West} {
    set row [list $station "2026-07-[format %02d $stationDay]"]
    incr stationDay
    for {set n 1} {$n <= 10} {incr n} {
        lappend row [format %.2f [expr {12.0 + $n * 1.37 +
            [string length $station]}]]
    }
    lappend body $row
}

$doc table -at [list 20 [expr {$y2 + 32}]] -width 170 \
    -theme grid -horizontalBreak 1 -repeatColumns 2 \
    -head [list $head] -body $body -columns $columns

# -- a span across a page break --------------------------------------------

# The case that has no good answer and had a bad one until it was fixed: a
# rowSpan cell is drawn over the FULL height of the rows it covers, so if the
# page break falls between those rows, the cell is drawn past the bottom
# margin. Nothing reports it - the file opens, no validator objects, and the
# only witness is the printed page.
#
# tclpdf therefore treats the rows a span binds as ONE unit for the break:
# either the whole group fits, or the whole group moves. The price is visible
# below - the last page starts with a gap where the group did not fit.
#
# The alternative, splitting the cell and repeating it at the top, is what
# HTML does. It needs a second drawing pass with clipping and is not built.

$doc page add
$doc font -family helvetica -style bold -size 14
$doc text "A span across a page break" -at {20 22}
$doc font -style {} -size 8
$doc text "The shift roster below is long enough that the break falls right\
    where the two-day block starts. Watch the bottom of this page: the block\
    is not started here, it is moved whole to the next one." \
    -at {20 29} -width 170

# Thirty single rows before the block. The number is measured, not guessed:
# below it the break falls before the block and above it after, and either way
# the page would look the same whether the fix is there or not.
set roster {}
# The three shifts of a day, each with its own hours - the Night shift runs
# over midnight, as it does on a real roster.
set shiftHours {Early "6:00 - 14:00" Late "14:00 - 22:00" Night "22:00 - 6:00"}
# One day per NAME: the week turns after seven days. Counted per shift it
# turned after seven SHIFTS, and Wednesday afternoon was already week 2.
set day 0
foreach name {Monday Tuesday Wednesday Thursday Friday Saturday Sunday
              Monday Tuesday Wednesday} {
    incr day
    foreach shift {Early Late Night} {
        lappend roster [list "$name, week [expr {($day - 1) / 7 + 1}]" $shift \
            "R. Neumann" [dict get $shiftHours $shift]]
    }
}
# The block that must not be torn: one name covering a weekend of six shifts.
lappend roster [list {text "Weekend cover" rowSpan 6} Early "K. Wagner" \
    [dict get $shiftHours Early]]
foreach shift {Late Night Early Late Night} {
    lappend roster [list $shift "K. Wagner" [dict get $shiftHours $shift]]
}

$doc table -at {20 40} -width 170 -theme grid \
    -head {{Day Shift Staff Hours}} -body $roster \
    -columns {{width 34} {width 26} {} {width 34 align center}} \
    -didDrawCell {apply {{cell doc} {
        if {[dict get $cell text] eq "Weekend cover"} {
            set ::coverPage [$doc page current]
        }
    }}}

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes), [$doc page count] pages"
if {[info exists ::coverPage]} {
    puts "  the six-shift block was drawn whole on page [expr {$::coverPage + 1}]"
}
$doc destroy
