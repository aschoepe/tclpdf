#!/usr/bin/env tclsh
#
# tclpdf example 5.5 - a tagged document
#
#   tclsh examples/05.05-tagged.tcl ?output.pdf?
#
# The same page twice would look identical here, and that is the point: a
# tagged document carries a second, invisible layer saying what the marks on
# the page ARE - a heading, a paragraph, a table cell - rather than how they
# look. Nothing moves by a point.
#
# Who needs it: reading software. Without the tree it follows the order the
# content stream happens to have, which on a two column page runs across both
# columns. From that follow PDF/UA and PDF/A level A, and with them the
# accessibility rules public bodies increasingly have to meet.
#
# Two things are worth watching in the source below.
#
# FIRST, most of it is not marked up at all. A table knows it is a table and a
# paragraph knows it is a paragraph, so those tag themselves; -tag is only for
# what a writer cannot know, and there is one thing it never knows: whether a
# line of text is a heading.
#
# SECOND, what is NOT in the tree matters as much as what is. A page number
# means nothing to a reader and is declared an artifact; so is the rule under
# the heading, and so is a picture without a description. Saying so is not a
# formality - under PDF/UA anything left unmarked counts as a defect.
#
# The document is written as PDF/A-3a, which is level B plus reliable text
# plus this tree. Its text is Italian - the language tag says so, and the
# example shows that the structure carries a language like it carries a
# heading: as a fact about the text, not as a look. Check it with:
#
#   verapdf -f 3a examples/out/05.05-tagged.pdf
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "05.05-tagged.pdf"}]
set assets [file join $here assets]
set regular [file join $assets fonts DejaVuSans.ttf]
set bold [file join $assets fonts DejaVuSans-Bold.ttf]
set profile [file join [file dirname $here] icc sRGB.icc]

set doc [tclpdf new -unit mm]

# Before anything is drawn. The brackets go into the content stream as it is
# written, so switching this on afterwards would tag the rest of the document
# and not the start of it.
$doc tagged 1

$doc info Title "Rapporto d'officina 2026-114"
$doc info Author "Alexander Schoepe"
$doc info Subject "Manutenzione straordinaria, rapporto annuale"

# A tagged document without a language is only half accessible: the tree says
# what a passage is, the language says how to pronounce it. The text is
# Italian, so the tag says so - a screen reader set to German would read
# "manutenzione" with German vowels otherwise.
$doc language it-IT

$doc page add
$doc font embed face $regular
$doc font embed faceBold $bold

# The order matters and is not obvious: [pdfa] checks at write time that every
# font is embedded, and it looks at the objects the font module has written by
# then. Declaring the conformance after the faces is what the other examples
# do as well.
$doc pdfa -part 3 -conformance A -profile $profile

# -- a section with a heading and two paragraphs ---------------------------

# Sect groups; it does not hold content itself. Text drawn inside it becomes a
# paragraph WITHIN it, which is what the norm's nesting rules ask for - a Sect
# carrying a line of text directly renders the same and fails validation.
$doc structure Sect -script {

  $doc font -family faceBold -size 16
  # Nothing in the call says "heading" - not the size, not the weight. A
  # reader cannot infer it from either, so it is stated.
  $doc text "Rapporto d'officina 2026" -at {20 30} -tag H1

  $doc line -from {20 33} -to {190 33} -width 0.4 -stroke {0.4 0.4 0.4}

  $doc font -family face -size 10
  # No -tag: a paragraph is what this becomes, and the writer knows it.
  $doc text "La manutenzione straordinaria della pressa 3 è stata completata\
      nell'anno di riferimento. L'azionamento è stato sostituito, il comando\
      è passato al nuovo regolatore e il collaudo da parte del perito è stato\
      eseguito." \
      -at {20 42} -width 170

  $doc text "Il rapporto elenca i costi per ciascun lotto di lavori. Il totale\
      si scosta dalla stima dell'anno precedente di meno del cinque per cento." \
      -at {20 60} -width 170
}

# -- a table, which tags itself -------------------------------------------

$doc structure Sect -script {

  $doc font -family faceBold -size 12
  $doc text "Costi per lotto di lavori" -at {20 82} -tag H2

  $doc font -family face -size 9
  # Not one -tag in this call. The sections and the grid are known here, so
  # the Table with its TR and TH and TD follows from them - and the fill and
  # the rules of every cell become artifacts, because they mean nothing.
  #
  # -style {family face} is NOT optional here, and the reason is worth a line:
  # a table does not inherit the font state, it has one of its own, and that
  # one defaults to Helvetica. In an archival document that is a standard face
  # nobody embedded, and the whole write fails at the last moment - which is
  # exactly the "forgotten -family" the PDF/A check was built to catch.
  $doc table -at {20 88} -width 170 -theme striped \
      -style {family face} -headStyle {family faceBold} \
      -head {{Lotto Ditta Importo}} \
      -body {
        {"Azionamento" "Meccanica Rossi S.r.l." "18.400,00"}
        {"Comando" "Elettrotecnica Bianchi" "9.250,50"}
        {"Montaggio" "officina interna" "3.180,00"}
      } \
      -foot {{{text "Totale" colSpan 2 align right} "30.830,50"}} \
      -columns {{} {} {align decimal}} -decimal ,
}

# -- pictures: one that means something, one that does not ----------------

$doc structure Sect -script {

  $doc font -family faceBold -size 12
  $doc text "Allegati" -at {20 140} -tag H3

  $doc font -family face -size 9
  $doc text "A sinistra la pressa dopo la manutenzione. A destra un motivo\
      senza significato - sta lì come esempio di ciò che diventa un'immagine\
      senza descrizione." -at {20 146} -width 170

  # -alt makes it a Figure and provides the description a Figure must have.
  # What belongs in there is what someone would say who describes the page to
  # a person who cannot see it - not "foto" and not the file name.
  $doc image draw [file join $assets images sample-photo.jpg] \
      -at {20 158} -width 70 \
      -alt "La pressa 3 dopo la sostituzione dell'azionamento, vista dal lato operatore"

  # No -alt, so an artifact. That is the honest default: most pictures in a
  # document are decoration, and a Figure without a description would fail
  # validation rather than help anyone.
  $doc image draw [file join $assets images sample-gray.jpg] \
      -at {100 158} -width 70
}

# The footer is an artifact by nature - a page number is a fact about the
# paper, not about the text. exampleFooter draws it with -tag Artifact, and
# takes the embedded face because PDF/A leaves no font unembedded.
exampleFooter $doc face

$doc write $target
puts "  written: $target ([file size $target] bytes), [$doc page count] page(s)"
puts "  check it with: verapdf -f 3a $target"
$doc destroy
