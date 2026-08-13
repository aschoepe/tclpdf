#!/usr/bin/env tclsh
#
# tclpdf example 4.1 - table basics
#
#   tclsh examples/04.01-table-basics.tcl ?output.pdf?
#
# Two pages. The first: three themes, four column alignments and the two ways
# of ruling a table. The second: the same figures written the continental way,
# 1.234,50 instead of 1,234.50, aligned with -decimal ,
#
# The interesting alignment is the fourth: decimal.
#
# Right alignment looks identical to decimal alignment as long as every figure
# has the same number of decimals - which is true in a test and false in a
# price list. Put 1,234.50 above 7.5 above 0.125 and right alignment stacks the
# last digits; decimal alignment stacks the points, which is what a reader
# needs in order to compare the magnitudes at a glance.
#
# Both pages carry thousands separators, and they have to: without them the
# two conventions would differ in one character instead of two, and the middle
# column of page two - the one showing what a forgotten -decimal costs - would
# have nothing to go wrong on.
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

# Group a plain number the way a reader of one convention expects it: which
# character separates the thousands, and which one the decimals.
#
#   grouped 1234.5 , .   ->  1,234.50 ... 1,234.5 the English way
#   grouped 1234.5 . ,   ->  1.234,5  ... the continental way
#
# ONE procedure for both pages, not one per page: the two differ in two
# characters, and two copies of this would have drifted apart at the first
# correction. Formatting stays out of the package on purpose - the table is
# told which character to align on, nothing more, and a table that reformatted
# its own figures could not be fed with anything already formatted.
proc grouped {value thousands decimal} {
  if {![string is double -strict $value]} {
    # "n/a" and anything else that is not a number is passed through; the
    # column sets it flush right.
    return $value
  }
  lassign [split $value .] whole fraction
  set sign {}
  if {[string index $whole 0] eq "-"} {
    set sign -
    set whole [string range $whole 1 end]
  }
  # In threes from the right: 1234 -> 1,234 and 1000000 -> 1,000,000.
  set head {}
  while {[string length $whole] > 3} {
    set head $thousands[string range $whole end-2 end]$head
    set whole [string range $whole 0 end-3]
  }
  set head $whole$head
  if {$fraction eq {}} {
    return $sign$head
  }
  return $sign$head$decimal$fraction
}

# The same figures on both pages, written out once. Anything below a thousand
# shows nothing of the grouping, which is why the list has to contain figures
# on both sides of it.
set masses {"1234.50" "7.5" "0.125" "88" "-1000.05"}
set parts {"bracket" "pin" "washer" "housing" "seal" "template"}

proc massRows {thousands decimal} {
  global masses parts
  set rows {}
  foreach part $parts mass [concat $masses [list "n/a"]] {
    lappend rows [list $part "left" "centre" "right" \
        [grouped $mass $thousands $decimal]]
  }
  return $rows
}

set doc [tclpdf new -unit mm]
$doc info Title "Table basics: themes and column alignment"
$doc page add

$doc font -family helvetica -style bold -size 15
$doc text "Themes and column alignment" -at {20 22}

# -- the four alignments ---------------------------------------------------

$doc font -size 10
$doc text "Four column alignments" -at {20 34}
$doc font -style {} -size 8
$doc text "The last column is aligned on the decimal point, not on the right\
    edge. Hold a ruler against the points." -at {20 39} -width 170

set y [$doc table -at {20 44} -width 170 -theme grid \
    -head {{Part Left Centre Right Mass}} \
    -body [massRows , .] \
    -foot [list [list {text "Total" colSpan 4 align right} \
        [grouped 2330.175 , .]]] \
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

set figures {}
foreach mass $masses {
  lappend figures [list [grouped $mass , .]]
}
$doc table -at [list 138 [expr {$y - 56}]] -width 28 -theme plain \
    -head {{"right"}} -body $figures -columns {{align right}}
$doc table -at [list 168 [expr {$y - 56}]] -width 28 -theme plain \
    -head {{"decimal"}} -body $figures -columns {{align decimal}}

# -- one frame instead of a rule per cell ----------------------------------

# The border style takes none, all, horizontal, vertical and outer. The last
# one is not a cell rule at all: the frame belongs to the block, and it is
# drawn once per page. A table running over three pages therefore gets three
# frames, each only as tall as its own part - a single frame around the table
# as a whole would run off the paper at the first break.

$doc font -style bold -size 10
$doc text "-style {border outer}" -at [list 20 [expr {$y + 4}]]
$doc font -style {} -size 8
$doc text "The same rows as above, framed once instead of ruled per cell.\
    Hold it against -theme grid." -at [list 20 [expr {$y + 9}]] -width 110

$doc table -at [list 20 [expr {$y + 16}]] -width 110 -theme grid \
    -style {border outer} -head $head -body $rows -columns $columns

# -- styling the three sections apart --------------------------------------

# -style applies to the whole table; -headStyle, -bodyStyle and -footStyle lay
# over it, section by section. They go ON TOP of the theme rather than beside
# it, so a single key can be changed without restating the rest of it.

$doc font -style bold -size 10
$doc text "-headStyle, -bodyStyle, -footStyle" -at [list 140 [expr {$y + 4}]]
$doc font -style {} -size 8
$doc text "The theme underneath is plain." -at [list 140 [expr {$y + 9}]] \
    -width 55

$doc table -at [list 140 [expr {$y + 16}]] -width 55 -theme plain \
    -head {{Item Sum}} -body {{"parts" "18.20"} {"labour" "45.00"}} \
    -foot {{"total" "63.20"}} \
    -headStyle {fill {0.20 0.30 0.45} color white} \
    -bodyStyle {color {0.25 0.25 0.3}} \
    -footStyle {fill {0.90 0.92 0.96} fontStyle bold} \
    -columns {{} {align decimal}}

# The footer is drawn per page, not once for the document: it names the script
# and the faces, and a page that ends up on a desk on its own has to answer
# that too.
exampleFooter $doc

# == page two: the same figures for a continental reader ====================

$doc page add

# Same figures, same procedure - only the two separator characters swap, and
# the column is told about it with -decimal ,
#
# The footer left the font state on grey at size 6. A new page inherits the
# state, so everything this page sets has to be set - the colour included.
$doc font -family helvetica -style bold -size 15 -color black
$doc text "The same table, set with a comma" -at {20 22}

$doc font -style {} -size 8
$doc text "German, French and most of continental Europe write 1.234,50 where\
    English writes 1,234.50 - the roles of point and comma are swapped. Telling\
    the column which character to line up on is therefore not a nicety: leave\
    it on the point and it finds one anyway, the thousands separator, and lines\
    the figures up on that." -at {20 30} -width 170

# -- the four alignments again ---------------------------------------------

$doc font -style bold -size 10
$doc text "Four column alignments, -decimal ," -at {20 44}
$doc font -style {} -size 8
$doc text "Hold a ruler against the commas." -at {20 49}

set y [$doc table -at {20 54} -width 170 -theme grid -decimal , \
    -head {{Part Left Centre Right Mass}} \
    -body [massRows . ,] \
    -foot [list [list {text "Total" colSpan 4 align right} \
        [grouped 2330.175 . ,]]] \
    -columns {{} {align left} {align center} {align right} {align decimal}}]

# -- what it looks like with the wrong separator ----------------------------

# Measured on the rendered page rather than assumed: the middle column does
# NOT simply fall back to flush right. 1.234,50 does contain a point - the
# THOUSANDS separator - so the column dutifully lines up on that one, and the
# two figures that have thousands separators hang about ten millimetres out to
# the right of the rest. Only the figures without any point at all (7,5 and
# 0,125 and 88) end up flush right. A forgotten -decimal is therefore worse
# than no alignment: it aligns on the wrong character and looks deliberate.

$doc font -style bold -size 10
$doc text "Why the option is needed" -at [list 20 [expr {$y + 12}]]
$doc font -style {} -size 8
$doc text "Three times the same figures. The middle column is what a forgotten\
    -decimal costs, and it is worse than no alignment at all: the point it\
    looks for is the thousands separator, so 1.234,50 and -1.000,05 line up on\
    THAT and stand apart from the rest. Only the figures without a point fall\
    back to flush right." \
    -at [list 20 [expr {$y + 17}]] -width 110

set figures {}
foreach value {"1234.50" "7.5" "0.125" "88" "-1000.05"} {
  lappend figures [list [grouped $value . ,]]
}

set at [expr {$y + 32}]
$doc table -at [list 20 $at] -width 35 -theme plain -decimal , \
    -head {{"-decimal ,"}} -body $figures -columns {{align decimal}}
$doc table -at [list 60 $at] -width 35 -theme plain \
    -head {{"-decimal . (wrong)"}} -body $figures -columns {{align decimal}}
$doc table -at [list 100 $at] -width 35 -theme plain \
    -head {{"align right"}} -body $figures -columns {{align right}}

# -- a footed table in the same style --------------------------------------

$doc font -style bold -size 10
$doc text "A small invoice block" -at [list 140 [expr {$y + 12}]]
$doc font -style {} -size 8
$doc text "The separator applies across head, body and foot alike - the total\
    hangs under the figures it adds up." -at [list 140 [expr {$y + 17}]] \
    -width 55

$doc table -at [list 140 [expr {$y + 32}]] -width 55 -theme plain -decimal , \
    -head {{Item Sum}} \
    -body [list [list "parts" [grouped 18.20 . ,]] \
        [list "labour" [grouped 1045.00 . ,]]] \
    -foot [list [list "total" [grouped 1063.20 . ,]]] \
    -headStyle {fill {0.20 0.30 0.45} color white} \
    -bodyStyle {color {0.25 0.25 0.3}} \
    -footStyle {fill {0.90 0.92 0.96} fontStyle bold} \
    -columns {{} {align decimal}}

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes), [$doc page count] page(s)"
$doc destroy
