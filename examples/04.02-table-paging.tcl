#!/usr/bin/env tclsh
#
# tclpdf example 4.2 - a table across pages
#
#   tclsh examples/04.02-table-paging.tcl ?output.pdf?
#
# A herbarium index long enough to break. What that costs to get right:
#
#   The head repeats on every page, so a reader landing on page three knows
#   what the columns are. The foot can repeat too, or appear once at the end -
#   -repeatFoot decides, and a running total wants the former while a grand
#   total wants the latter.
#
#   A row is never split. That is why measuring comes before drawing: a row
#   can only be placed once its height is known, and its height depends on how
#   its text wraps, which depends on the column widths, which depend on the
#   content of every row in the table.
#
#   finalY - the return value - is the y below the table on the page it ended
#   on. Without it a caller has to count rows to know where to continue.
#
#   -at and -top answer two different questions. -at is where THIS table
#   starts, below the heading; -top is where it resumes on the pages after
#   the first, and defaults to the same margin -bottom is derived from. Here
#   it is pushed down to 26 mm to clear the running head, which only appears
#   from page two onwards.
#
#   Two of the four hooks are used here: didParseCell, which runs before
#   measuring, so a change of font size still affects the wrap, and
#   didDrawPage, which runs once per page and is where the running head goes.
#   The other two are willDrawCell, which can suppress a cell, and
#   didDrawCell, which overlays one.
#
#   pageNumbers puts "Page n of m" on every sheet, including the ones the
#   table adds while it breaks - the numbers are drawn when the document is
#   written, which is the only moment the total is known.
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "04.02-table-paging.pdf"}]

# A plausible index, built rather than typed out.
set genera {Acer Betula Carex Dryopteris Equisetum Fagus Galium Hedera
    Iris Juncus Lamium Melica Nardus Oxalis Poa Quercus Rumex Salix
    Trifolium Ulmus Veronica}
set species {alba nigra vulgaris palustris montana sylvatica repens
    officinalis maritima alpina}
set places {"Hoher Meissner" "Kaiserstuhl" "Luneburger Heide" "Spessart"
    "Rhoen" "Eifel" "Altmuehltal" "Darss"}

set rows {}
set number 1000
foreach genus $genera {
    foreach epithet [lrange $species 0 3] {
        incr number
        lappend rows [list $number "$genus $epithet" \
            [lindex $places [expr {$number % [llength $places]}]] \
            "20[expr {12 + $number % 14}]-0[expr {1 + $number % 9}]-1[expr {$number % 9}]" \
            [format %.2f [expr {(($number * 37) % 900) / 10.0}]]]
    }
}

set doc [tclpdf new -unit mm]
$doc info Title "Herbarium index"
$doc page add

$doc font -family helvetica -style bold -size 15
$doc text "Herbarium index" -at {20 22}
$doc font -style {} -size 9
$doc text "[llength $rows] sheets, ordered by accession number" -at {20 29}

set total 0.0
foreach row $rows {
    set total [expr {$total + [lindex $row 4]}]
}

# Measured before it is drawn: [table layout] takes the same options and
# answers with the column widths and the height the whole table would need -
# what a caller looks at to decide whether it still fits under a heading, or
# has to start on a fresh page. Nothing is drawn by this call.
set plan [$doc table layout -width 170 \
    -head {{No. Taxon Locality Collected "Mass g"}} \
    -body $rows \
    -columns {{width 16 align right} {} {} {width 26} {width 22 align decimal}}]
puts "  layout: [format %.0f [dict get $plan height]] mm for [llength $rows] rows,\
    columns [lmap w [dict get $plan widths] {format %.1f $w}] mm"

# -bottom is the margin the table keeps at the foot of every page; the default
# comes from the type area, 272 asks for a little more room for the page number.
set y [$doc table -at {20 38} -top 26 -bottom 272 -width 170 -theme striped \
    -head {{No. Taxon Locality Collected "Mass g"}} \
    -body $rows \
    -foot [list [list [list text "Total mass of all sheets" colSpan 4 align right] \
        [format %.2f $total]]] \
    -columns {{width 16 align right} {} {} {width 26} {width 22 align decimal}} \
    -repeatHead 1 -repeatFoot 0 \
    -didParseCell {apply {{cell doc} {
        # A sheet over 80 g needs a reinforced folder - marked while parsing,
        # so the change is in place before anything is measured.
        if {[dict get $cell section] eq "body" && [dict get $cell column] == 4
            && [dict get $cell text] > 80} {
            dict set cell style {color {0.70 0.15 0.10} fontStyle bold}
        }
        return $cell
    }}} \
    -didDrawPage {apply {{payload doc} {
        $doc font -family helvetica -style {} -size 7 -color {0.45 0.45 0.5}
        $doc text "Herbarium index" -at {20 287}
        $doc line -from {20 283} -to {190 283} -stroke {0.8 0.8 0.85} -width 0.2
        # A running head, but only from page two: page one has the real
        # heading, and -at puts the table below it. -top 26 keeps the
        # continuation clear of this line on every page after that.
        if {[dict get $payload page] > 0} {
            $doc text "Herbarium index, continued" -at {20 20}
            $doc line -from {20 22} -to {190 22} -stroke {0.8 0.8 0.85} -width 0.2
        }
    }}}]

# The running head above can say everything the page knows about itself - but
# not how many pages there will be. While page three is drawn, nobody knows
# there will be seven; the hook cannot answer it, and no amount of ordering
# helps. [pageNumbers] states the wish and draws it at write time, when the
# document is complete and the total is simply the page count.
$doc font -family helvetica -style {} -size 8 -color {0.35 0.35 0.4}
$doc pageNumbers -at {190 287} -align right -format "page %n of %m"

# Several calls are independent of each other, and each takes the font options
# on its own - a family, style, size and colour of its own rather than the
# state left by the last [font]. This index is the first part of a bound
# volume that goes on with the collector's register, five pages more: -total
# names the total of the set, and %n stays what it is because this part comes
# first. -from 2 leaves the title page out; -align left - the default, written
# out here - starts the line on -at, beside the running head the hook draws,
# and -align center centres the volume mark on the middle of the foot.
set volume [expr {[$doc page count] + 5}]
$doc pageNumbers -at {60 20} -align left -from 2 -total $volume \
    -format "sheet %n of %m in the bound volume" \
    -family times -style italic -size 7 -color {0.45 0.45 0.5}
$doc pageNumbers -at {105 287} -align center -format "vol. 1" \
    -family helvetica -style bold -size 7 -color {0.35 0.35 0.4}

# finalY: continue below the table, on whatever page it ended on.
$doc font -family helvetica -style bold -size 9 -color black
$doc text "Notes" -at [list 20 [expr {$y + 10}]]
$doc font -style {} -size 8
$doc text "The head above repeats on every page; the total appears once, at\
    the end. Sheets over 80 g are marked - the mark was applied while the\
    table was being parsed, before any row was measured, which is the only\
    point at which a change of font size still affects how the text wraps.\
    The page numbers in the corner know how many pages there are because they\
    are drawn last, after the table has decided how far it runs." \
    -at [list 20 [expr {$y + 15}]] -width 170

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes), [$doc page count] pages"
puts "  rows: [llength $rows], finalY: [format %.1f $y] mm"
$doc destroy
