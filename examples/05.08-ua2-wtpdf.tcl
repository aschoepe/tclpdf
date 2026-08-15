#!/usr/bin/env tclsh
#
# tclpdf example 5.8 - PDF/UA-2 and Well-Tagged PDF, on the 2.0 path
#
#   tclsh examples/05.08-ua2-wtpdf.tcl ?output.pdf?
#
# Example 5.7 makes the PDF/UA-1 claim on the 1.7 path. This one goes to
# ISO 14289-2, which is a PDF 2.0 format, and adds the WTPDF declaration on
# top of it.
#
# What changes with part 2, and none of it is cosmetic:
#
#   the file version   2.0, set by [ua -part 2] rather than asked for
#                      separately, because everything written afterwards has
#                      to know
#   namespaces         a 2.0 tree may not rely on the default namespace any
#                      more; one Namespace dictionary and /NS on the elements
#   new types          Title, Aside, FENote, Em, Strong, H7 and beyond - and
#                      eleven old ones (Code, Note, Quote, TOC ...) that
#                      exist ONLY in the 1.7 namespace and therefore keep the
#                      default
#   no generic H       H1 to Hn, because H meant "whatever the nesting
#                      implies" and the nesting rarely said what was meant
#   Desc everywhere    every attachment needs a description
#
# And what does NOT change: the structure tree is the same tree. A document
# written for UA-1 needs no redrawing - it needs -part 2.
#
# PDF/A-3 is a 1.7 format, so it cannot be combined with this, and neither can
# ZUGFeRD. tclpdf says so at the call rather than writing a file that claims
# both. For an invoice that has to be accessible, part 1 is the answer.
#
#   verapdf --flavour ua2   examples/out/05.08-ua2-wtpdf.pdf
#   verapdf --flavour wt1a  examples/out/05.08-ua2-wtpdf.pdf
#   verapdf --flavour wt1r  examples/out/05.08-ua2-wtpdf.pdf
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "05.08-ua2-wtpdf.pdf"}]
set assets [file join $here assets]
set regular [file join $assets fonts DejaVuSans.ttf]
set bold [file join $assets fonts DejaVuSans-Bold.ttf]

set doc [tclpdf new -unit mm]
$doc tagged 1
$doc info Title "Handreichung Barrierefreiheit"
$doc info Author "Alexander Schoepe"
$doc language de-DE

# Both levels of WTPDF: reuse says the tagging is good enough to get the
# content back out, accessibility says it is good enough to be read aloud.
# They are not exclusive, and a file that reaches the second has reached the
# first.
$doc ua -part 2 -wtpdf {reuse accessibility}

$doc page add
$doc font embed face $regular
$doc font embed faceBold $bold

# -- Title, which is a 2.0 type ---------------------------------------------

# In 1.7 the document title was an H1 and had to be. 2.0 has a Title element,
# and using it leaves H1 to mean "first heading" rather than "the name of the
# document".
$doc font -family faceBold -size 17
$doc structure Title -script {
  $doc text "Handreichung Barrierefreiheit" -at {20 25}
}

$doc font -family face -size 10
$doc text "Dieses Dokument ist PDF/UA-2 und trägt zusätzlich die\
    WTPDF-Erklärung für beide Stufen. Es ist eine PDF-2.0-Datei - schon\
    deshalb, weil ISO 14289-2 nichts anderes zulässt." -at {20 36} -width 170

# -- the heading levels 2.0 allows ------------------------------------------

$doc font -family faceBold -size 13
$doc text "Was der Strukturbaum trägt" -at {20 54} -tag H1

$doc font -family face -size 10
$doc text "Die Elemente stehen im 2.0-Namensraum, den ein\
    Namespace-Wörterbuch am Wurzelknoten benennt. Elf ältere Typen bleiben\
    ausdrücklich im Vorgabe-Namensraum, weil es sie in 2.0 nicht gibt:" \
    -at {20 62} -width 170

# Code is one of the eleven. It carries no /NS, and that is not an omission -
# naming the 2.0 namespace on a type that does not exist there would be a
# claim about nothing.
$doc font -family face -size 9
$doc structure Code -script {
  $doc text "set doc \[tclpdf new -unit mm\] ;# Code, Note, Quote, TOC ..." \
      -at {24 72}
}

$doc font -family faceBold -size 11
$doc text "Hervorhebung" -at {20 84} -tag H2

# Em and Strong are new in 2.0. In 1.7 both were a Span and the emphasis was
# a matter of the font alone - which a reader cannot hear.
# Inside the P, not beside it: Strong is an inline type, and a tree with a
# Strong directly under Document is rejected - "Document shall not contain
# Strong", Table 5.
$doc structure P -script {
  $doc font -family face -size 10
  $doc text "Betonung war in 1.7 eine Sache der Schrift und damit unhörbar." \
      -at {20 92} -width 170
  $doc structure Strong -script {
    $doc font -family faceBold -size 10
    $doc text "Strong sagt es dem Vorleser." -at {20 99}
  }
}

# -- Aside and FENote, both new in 2.0 -------------------------------------

$doc font -family faceBold -size 11
$doc text "Randbemerkung und Fussnote" -at {20 112} -tag H2

# An Aside is content that belongs to the page but not to the flow of the
# text - a marginal note, a box. In 1.7 it had to be a Div or nothing, and a
# reader could not tell it apart from the argument it stands beside.
$doc font -family face -size 9 -color {0.3 0.3 0.35}
$doc structure Aside -script {
  $doc text "Nebenbei: die Liste in 5.7 zeigt, wie eine geordnete Liste\
      ausgezeichnet wird - hier waere sie eine Wiederholung." \
      -at {20 120} -width 170
}

# FENote is the 2.0 type for a footnote or endnote. Before it there was Note,
# which is one of the eleven types that stayed in the 1.7 namespace - so a
# 2.0 document that wants a footnote uses this one.
$doc font -family face -size 9 -color black
$doc structure FENote -script {
  $doc text "1) Fussnoten sind in 2.0 ein eigener Typ; Note gibt es dort\
      nicht mehr." -at {20 132} -width 170
}

# -- an attachment, which needs a description in part 2 ---------------------

$doc font -family faceBold -size 11
$doc text "Anhang" -at {20 148} -tag H2

$doc font -family face -size 10
$doc text "Der Anhang trägt eine Beschreibung. Unter PDF/UA-2 ist sie\
    Pflicht: ein Dateiname ist keine Beschreibung, und \"factur-x.xml\"\
    vorgelesen sagt niemandem etwas." -at {20 156} -width 170

$doc attach [info script] -name 05.08-ua2-wtpdf.tcl \
    -description "Das Skript, das dieses Dokument erzeugt hat"

$doc line -from {20 176} -to {190 176} -width 0.4 -stroke {0.4 0.4 0.4}

exampleFooter $doc face

$doc write $target
set state [$doc ua state]
puts "  written: $target ([file size $target] bytes), [$doc page count] page(s)"
puts "  PDF/UA-[dict get $state part] rev [dict get $state revision],\
    WTPDF: [join [dict get $state wtpdf] { und }]"
puts "  check it with: verapdf --flavour ua2 $target"
puts "                 verapdf --flavour wt1a $target"
$doc destroy
