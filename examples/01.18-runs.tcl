#!/usr/bin/env tclsh
#
# tclpdf example 1.18 - the list underneath the notations: runs in an
# embedded family
#
#   tclsh examples/01.18-runs.tcl ?output.pdf?
#
# Example 1.17 writes a paragraph with tags and with Markdown. Both are
# notations for ONE thing, and this example writes that thing by hand: the
# list of {text options} pairs that [text -runs 1] takes. The options of a
# run are style (bold, italic, both), underline, strike, url and, for a
# paragraph of its own, heading 1, 2 or 3. The line breaker runs over all
# of it, measures every piece in its own face and sets it with its own Tf.
# A program that assembles a paragraph from data - a name from one column,
# an amount from another - writes this list and needs no notation at all.
#
# WHY A FAMILY. The standard faces know their bold and oblique: -style bold
# on Helvetica is Helvetica-Bold, and 1.17 needed nothing more. An EMBEDDED
# face is one alias and one face; -style bold on it had nothing to reach,
# which is why every example embedded bodyBold beside body and named the
# bold alias itself wherever a heading stood. [font family] ties the faces
# under one name, and from then on -style bold - and with it every bold run
# and every heading - resolves to the bold face, text without a style to the
# regular one.
#
# AND WHY THE REFUSAL IS THE POINT. DejaVu Sans ships here in two faces,
# regular and bold; the family has no italic. A run that asks for italic is
# REFUSED, by name - not set regular in silence, which is what an alias
# without a family did. The refusal stands on the console, and then the
# italic runs are set upright for this page.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "01.18-runs.pdf"}]
set assets [file join $here assets fonts]

# The paragraph as a list, written by hand. A pair is {text options}; a pair
# with empty options is set in the paragraph's face. A heading is a pair of
# its own and ends the paragraph in front of it; a line feed between two
# pairs is a paragraph break, as it is in a plain string.
set runs [list \
    "Runs in flowing text" {heading 1} \
    "The " {} \
    "amount of 1,234.56 EUR" {style bold} \
    " is payable by " {} \
    "31 October" {style italic} \
    "; after that date the price of " {} \
    "980.00 EUR" {strike 1} \
    " no longer applies, and the " {} \
    "late payment surcharge" {underline 1} \
    " becomes due. The conditions are published at " {} \
    "fossil.sowaswie.de/tclpdf" {url https://fossil.sowaswie.de/tclpdf} \
    ", where the " {} \
    "complete" {style bold} \
    " terms can be read at any time." {} \
    "What the breaker does with it" {heading 2} \
    "Every piece is measured in the face it is set in - a bold word is wider\
    than the same word regular - so the line breaks fall where they have to,\
    and a justified line stretches the spaces of every piece by the same\
    amount. A word may cross a run boundary and is still one word to the\
    hyphenator: " {} \
    "Betriebs" {style bold} \
    "kostenabrechnung breaks inside the bold part or after it, wherever the\
    patterns allow." {} \
]

set block {-width 170 -align justify -runs 1 -paragraphSpacing 2}

set doc [tclpdf new -unit mm]
$doc info Title "Runs as a list, set in an embedded family"

# The family: two faces embedded, tied under one name. Embedded because a
# family is only ever needed for embedded faces - the standard ones bring
# their bold and oblique with them.
$doc font embed dejavu [file join $assets DejaVuSans.ttf]
$doc font embed dejavuBold [file join $assets DejaVuSans-Bold.ttf]
$doc font family body -regular dejavu -bold dejavuBold

$doc page add
$doc font -family helvetica -size 14 -style bold -color black
$doc text "The list of runs, set in an embedded family" -at {20 22}
$doc font -family body -size 10 -style {}

# The refusal first: the family has no italic face, and "31 October" asks
# for one.
if {[catch {$doc text $runs -at {20 34} {*}$block} refusal]} {
    puts "  an italic run in a family without an italic face:"
    exampleConsoleParagraph $refusal
}

# Then the same list with the italic taken out of its runs.
set upright {}
foreach {text options} $runs {
    if {[dict exists $options style]} {
        set style [lsearch -all -inline -not [dict get $options style] italic]
        if {[llength $style]} {
            dict set options style $style
        } else {
            dict unset options style
        }
    }
    lappend upright $text $options
}
set y [$doc text $upright -at {20 34} {*}$block]

# And what the two headings cost in the block: measured, not claimed.
# [textHeight] takes the options [text] takes, so the list without its
# heading pairs is measured in the same state.
set plain [lmap {text options} $upright {
    if {[dict exists $options heading]} continue
    list $text $options
}]
set plain [concat {*}$plain]
$doc font -family helvetica -size 8 -color {0.45 0.45 0.45}
$doc text "The block above ends at y = [format %.1f $y] mm; the same runs\
    without their two headings would end at y = [format %.1f [expr {34 + \
    [$doc textHeight $plain {*}$block -family body -size 10]}]] mm." \
    -at [list 20 [expr {$y + 8}]] -width 170

exampleFooter $doc
$doc write $target
$doc destroy

puts "  written: $target ([file size $target] bytes)"
puts "  [expr {[llength $runs] / 2}] runs, two of them headings; the family\
    body = dejavu + dejavuBold, no italic"
