#!/usr/bin/env tclsh
#
# tclpdf example 4.1 - a table on one page
#
#   tclsh examples/04.01-table-basics.tcl ?output.pdf?
#
# One page, three themes, and all four column alignments. The interesting one
# is the fourth: decimal.
#
# Right alignment looks identical to decimal alignment as long as every figure
# has the same number of decimals - which is true in a test and false in a
# price list. Put 1234.50 above 7.5 above 0.125 and right alignment stacks the
# last digits; decimal alignment stacks the points, which is what a reader
# needs in order to compare the magnitudes at a glance.
#
# Nothing here embeds a font: the fourteen standard faces are the normal case,
# and a document that does not need an embedded one should not carry one.
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "04.01-table-basics.pdf"}]

set doc [tclpdf new -unit mm]
$doc info Title "Table basics: themes and column alignment"
$doc page add

$doc font -family helvetica -style bold -size 15
$doc text "Tables on one page" -at {20 22}

# -- the four alignments ---------------------------------------------------

$doc font -size 10
$doc text "Four column alignments" -at {20 34}
$doc font -style {} -size 8
$doc text "The last column is aligned on the decimal point, not on the right\
    edge. Hold a ruler against the points." -at {20 39} -width 170

set y [$doc table -at {20 44} -width 170 -theme grid \
    -head {{Part Left Centre Right Mass}} \
    -body {
      {"bracket"  "left" "centre" "right" "1234.50"}
      {"pin"      "left" "centre" "right" "7.5"}
      {"washer"   "left" "centre" "right" "0.125"}
      {"housing"  "left" "centre" "right" "88"}
      {"seal"     "left" "centre" "right" "-1000.05"}
      {"template" "left" "centre" "right" "n/a"}
    } \
    -foot {{{text "Total" colSpan 4 align right} "2330.175"}} \
    -columns {{} {align left} {align center} {align right} {align decimal}}]

# The heading over a decimal column is set flush right: there is nothing in
# "Mass" to align on, and a heading floating in the middle reads as a mistake.
# A cell that is not a number at all - "n/a" - is treated the same way, so the
# column stays a column.

# -- the same data, three themes -------------------------------------------

$doc font -style bold -size 10
$doc text "The three built-in themes" -at [list 20 [expr {$y + 12}]]

set rows {
  {"M4x12" "stainless" "240" "0.35"}
  {"M5x20" "zinc plated" "180" "0.62"}
  {"M6x30" "stainless" "95" "1.40"}
}
set head {{Size Finish Stock Unit}}
set columns {{} {} {align right} {align decimal}}

set y [expr {$y + 18}]
foreach theme {striped grid plain} {
  $doc font -style {} -size 8
  $doc text "-theme $theme" -at [list 20 $y]
  set y [$doc table -at [list 20 [expr {$y + 4}]] -width 110 -theme $theme \
      -head $head -body $rows -columns $columns]
  set y [expr {$y + 10}]
}

# -- what a decimal column is worth ----------------------------------------

$doc font -style bold -size 10
$doc text "Right against decimal, same figures" -at [list 140 [expr {$y - 62}]]
$doc font -style {} -size 8

set figures {{"1234.50"} {"7.5"} {"0.125"} {"88"} {"-1000.05"}}
$doc table -at [list 140 [expr {$y - 56}]] -width 25 -theme plain \
    -head {{"right"}} -body $figures -columns {{align right}}
$doc table -at [list 170 [expr {$y - 56}]] -width 25 -theme plain \
    -head {{"decimal"}} -body $figures -columns {{align decimal}}

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes), [$doc page count] page(s)"
$doc destroy
