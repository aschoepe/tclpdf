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
#   The four hooks: didParseCell runs before measuring (so a change of font
#   size still affects the wrap), willDrawCell can suppress a cell,
#   didDrawCell overlays one, didDrawPage runs once per page.
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

set y [$doc table -at {20 38} -width 170 -theme striped \
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
        $doc text "page [expr {[dict get $payload page] + 1}]" \
            -at {190 287} -align right
        $doc line -from {20 283} -to {190 283} -stroke {0.8 0.8 0.85} -width 0.2
    }}}]

# finalY: continue below the table, on whatever page it ended on.
$doc font -family helvetica -style bold -size 9 -color black
$doc text "Notes" -at [list 20 [expr {$y + 10}]]
$doc font -style {} -size 8
$doc text "The head above repeats on every page; the total appears once, at\
    the end. Sheets over 80 g are marked - the mark was applied while the\
    table was being parsed, before any row was measured, which is the only\
    point at which a change of font size still affects how the text wraps." \
    -at [list 20 [expr {$y + 15}]] -width 170

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes), [$doc page count] pages"
puts "  rows: [llength $rows], finalY: [format %.1f $y] mm"
$doc destroy
