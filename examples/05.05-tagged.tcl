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

# -- a second page: the rest of the 1.7 vocabulary --------------------------

# Everything above needed four types said out loud - Sect, H1 to H3 - and
# derived the rest. The page below is the appendix, and it exists to show
# the types a report like this one reaches for less often, each on a
# [structure] call of its own: a table built by hand, a formula, a figure
# with its caption, a table of contents, a quotation, a note, an index, a
# bibliography. Nothing here is needed for the document above; all of it is
# refused where the nesting is wrong, at the call rather than at the
# recipient (ISO 32000-2 Annex L).
$doc page add

# Art is an article: a self-contained piece within the document, and the
# right container for an appendix. Like Sect it groups and holds nothing
# itself - the heading and the paragraphs become its children.
$doc structure Art -script {

  # -color black, because the footer of page 1 left the state grey: font
  # colour is document state like the rest, and a new page does not reset it.
  $doc font -family faceBold -size 12 -color black
  $doc text "Appendice: il resto del vocabolario" -at {20 25} -tag H2

  # A Div with a language of its own. The document is Italian; this summary
  # is English, and a reader has to switch pronunciation for the length of it
  # - -lang says where. -title names the division, which a reader can offer
  # in an outline of the tree.
  $doc structure Div -lang en-GB -title "Summary in English" -script {
    $doc font -family face -size 9
    $doc text "Summary. The extraordinary maintenance of press 3 was completed\
        in the reporting year; the drive was replaced, the control moved to\
        the new regulator, and the acceptance test was carried out by the\
        assessor. Costs per work package are on page 1." -at {20 33} -width 170
  }

  # A table of contents is a TOC of TOCI entries; the text of an entry that
  # points somewhere is a Reference. Drawn by hand here, because the writer
  # cannot know which lines of a page are its contents list.
  $doc font -family faceBold -size 10
  $doc text "Indice" -at {20 54} -tag H3
  $doc font -family face -size 9
  $doc structure TOC -script {
    set y 61
    foreach entry {
      "1  Rapporto d'officina 2026 . . . . . . 1"
      "2  Costi per lotto di lavori . . . . . . . 1"
      "3  Allegati . . . . . . . . . . . . . . . . 1"
    } {
      $doc structure TOCI -script {
        $doc structure Reference -script { $doc text $entry -at [list 20 $y] }
      }
      incr y 5
    }
  }

  # A formula holds its marks itself - the three text calls and the fraction
  # rule are one Formula, not four elements. -actualText is what the marks
  # stand for, in a form that can be read out in one piece; the layout of a
  # fraction says nothing to a reader. -bbox is where it is on the page.
  $doc font -family faceBold -size 10
  $doc text "Formula" -at {115 54} -tag H3
  $doc font -family face -size 10
  $doc structure Formula -id formula-1 -bbox {115 57 40 14} -actualText "t = (t1 + t2) / 2" -script {
    $doc text "t  =" -at {115 66}
    $doc font -size 8
    $doc text "t1 + t2" -at {126 62} -width 16 -align center
    $doc line -from {126 63.5} -to {142 63.5} -width 0.3 -stroke black
    $doc text "2" -at {126 68.5} -width 16 -align center
  }
  $doc font -family face -size 9

  # A table built by hand, for the case a grid of cells does not cover: a
  # cell that spans, a row that heads. The rules are drawn first and outside
  # the Table, so they stay artifacts; inside a TD they would become the
  # cell's content. Then the elements: a Caption first, one TR per row, TH
  # for the heading cells with the side they head - Column across the top,
  # Row down the left, Both for the corner that heads its row and its column
  # alike - and TD for the data, with -colSpan and -rowSpan where a cell
  # covers more than one place in the grid.
  $doc font -family faceBold -size 10
  $doc text "Tabella a mano" -at {20 84} -tag H3
  $doc font -family face -size 9
  foreach {x0 y0 x1 y1} {
    20 88 94 88   20 94 94 94   20 100 94 100   20 106 50 106   20 112 94 112
    20 88 20 112  50 88 50 112  72 88 72 100    94 88 94 112
  } {
    $doc line -from [list $x0 $y0] -to [list $x1 $y1] -width 0.2 \
        -stroke {0.6 0.6 0.6}
  }
  $doc structure Table -bbox {20 88 74 24} -script {
    $doc structure Caption -script {
      $doc font -family face -size 7
      $doc text "Tabella 2 - ore per lotto, previste ed effettive" -at {20 116}
      $doc font -family face -size 9
    }
    $doc structure TR -script {
      $doc structure TH -scope Both -script { $doc text "Lotto" -at {21 92.5} }
      $doc structure TH -scope Column -script { $doc text "previste" -at {51 92.5} }
      $doc structure TH -scope Column -script { $doc text "effettive" -at {73 92.5} }
    }
    $doc structure TR -script {
      $doc structure TH -scope Row -script { $doc text "Azionamento" -at {21 98.5} }
      $doc structure TD -script { $doc text "120" -at {51 98.5} }
      $doc structure TD -script { $doc text "131" -at {73 98.5} }
    }
    $doc structure TR -script {
      $doc structure TH -scope Row -script { $doc text "Comando" -at {21 104.5} }
      $doc structure TD -colSpan 2 -rowSpan 2 -script {
        $doc text "in corso, senza consuntivo" -at {51 107.5}
      }
    }
    $doc structure TR -script {
      $doc structure TH -scope Row -script { $doc text "Montaggio" -at {21 110.5} }
    }
  }

  # A figure drawn from shapes, with a caption of its own. Inside an open
  # Figure a rectangle is part of the picture, not decoration - the same call
  # outside it would be an artifact. -alt describes it, -bbox places it, and
  # the Caption is its first child, as it is for a table.
  $doc font -family faceBold -size 10
  $doc text "Figura" -at {115 84} -tag H3
  $doc structure Figure -alt "Diagramma a barre: ore previste ed effettive\
      per l'azionamento, 120 contro 131" -bbox {115 88 75 30} -script {
    $doc structure Caption -script {
      $doc font -family face -size 7
      $doc text "Figura 1 - ore per l'azionamento" -at {115 116}
      $doc font -family face -size 9
    }
    $doc rect -at {115 96} -size {48 5} -fill {0.6 0.6 0.65}
    $doc rect -at {115 103} -size {52.4 5} -fill {0.2 0.45 0.75}
    $doc font -family face -size 7
    $doc text "120" -at {165 100}
    $doc text "131" -at {169 107}
  }
  $doc font -family face -size 9

  # A block quotation is a BlockQuote holding paragraphs; a quotation inside
  # a sentence is a Quote, an inline type inside the P. The bracketed number
  # is a Reference to the bibliography below, and the two Latin words are a
  # Span with their own language.
  $doc font -family faceBold -size 10
  $doc text "Citazione e nota" -at {20 128} -tag H3
  $doc font -family face -size 9
  $doc structure BlockQuote -script {
    $doc structure P -script {
      set lead "Il perito ha scritto nel verbale: "
      $doc text $lead -at {24 135}
      $doc structure Quote -script {
        $doc text "«impianto conforme, collaudo superato»" \
            -at [list [expr {24 + [$doc textWidth $lead]}] 135]
      }
      set lead2 "e rimanda al manuale "
      $doc text $lead2 -at {24 140}
      $doc structure Reference -script {
        $doc text "\[1\]" -at [list [expr {24 + [$doc textWidth $lead2]}] 140]
      }
      set lead3 "$lead2\[1\]; la verifica è stata fatta "
      $doc text "; la verifica è stata fatta " \
          -at [list [expr {24 + [$doc textWidth "$lead2\[1\]"]}] 140]
      $doc structure Span -lang la -script {
        $doc text "in situ" -at [list [expr {24 + [$doc textWidth $lead3]}] 140]
      }
      $doc text "." -at [list [expr {24 + [$doc textWidth "${lead3}in situ"]}] 140]
    }
  }

  # A Note carries its own label - the footnote number is a Lbl inside it,
  # as in a list item - and then the text of the note. PDF/UA-1 asks a Note
  # for an element identifier as well (7.9): a Note gets one on its own
  # (/ID, and the root's IDTree with it), and -id names one for any element -
  # the Formula above carries "formula-1". 5.8 uses FENote, the 2.0
  # successor.
  $doc font -family face -size 8
  $doc structure Note -script {
    $doc structure Lbl -script { $doc text "1)" -at {20 149} }
    $doc text "Il verbale di collaudo è allegato al fascicolo dell'officina." \
        -at {26 149}
  }

  # An Index groups its entries; each line becomes a P of it. Private is
  # for content that has meaning to a program and none to a reader - an
  # internal reference the archive system uses.
  $doc font -family faceBold -size 10
  $doc text "Indice analitico" -at {20 160} -tag H3
  $doc font -family face -size 9
  $doc structure Index -script {
    set y 167
    foreach entry {"azionamento, 1" "collaudo, 1, 2" "regolatore, 1"} {
      $doc text $entry -at [list 20 $y]
      incr y 5
    }
  }
  $doc structure Private -script {
    $doc font -family face -size 7 -color {0.5 0.5 0.5}
    $doc text "arch: RO-2026-114/A" -at {115 167}
    $doc font -family face -size 9 -color black
  }

  # The bibliography: one BibEntry per work. The Reference above points here.
  $doc font -family faceBold -size 10
  $doc text "Bibliografia" -at {20 190} -tag H3
  $doc font -family face -size 9
  $doc structure BibEntry -script {
    $doc text "\[1\] Manuale d'uso della pressa 3, edizione 2024, cap. 7." \
        -at {20 197}
  }
  $doc structure BibEntry -script {
    $doc text "\[2\] Norma interna di manutenzione MI-12, revisione 3." \
        -at {20 202}
  }
}

exampleFooter $doc face

$doc write $target
puts "  written: $target ([file size $target] bytes), [$doc page count] page(s)"
puts "  check it with: verapdf -f 3a $target"
$doc destroy
