#!/usr/bin/env tclsh
#
# tclpdf example 5.14 - the generic H: a weakly structured document
#
#   tclsh examples/05.14-weakly-structured.tcl ?output.pdf?
#
# Every other tagged example numbers its headings: H1 for the title, H2 for
# a section. That is the STRONGLY structured form, and the one to write when
# the levels are known. ISO 32000-1 (14.8.4.4.2) knows a second form: the
# generic H, a heading at whatever level its NESTING implies. One Sect
# inside another, each opening with an H - the depth of the element is the
# level. That is the WEAKLY structured form, and it is what a converter
# honestly writes when its source nests sections without numbering them, the
# way a DocBook or LaTeX section tree does: the source has nesting
# everywhere and levels nowhere, and inventing the numbers would mean
# deriving what the nesting already says.
#
# The two forms do not mix. A tree carrying both H and H1 answers the
# question "how deep am I?" twice, and where the answers disagree no reader
# can choose - so the Matterhorn protocol fails the mixture (14-006).
# Measured with veraPDF 1.30.2 against ua1: a document mixing H with H1
# fails with two checks under clause 7.4.4 ("all documents shall be either
# strongly or weakly structured, but not both"); this document, generic H
# throughout, passes with zero. tclpdf draws the same line where it is
# cheap to fix: a UA claim over a mixed tree is refused when the file is
# written, shown below on a document that is asked and thrown away. PDF/UA-2
# has no generic H at all - a document that wants part 2 numbers its
# headings, and the 2.0 namespace is also why H keeps the 1.7 namespace
# inside a 2.0 tree.
#
#   verapdf --flavour ua1  examples/out/05.14-weakly-structured.pdf
#   pdfinfo -struct-text   examples/out/05.14-weakly-structured.pdf
#
# The second line shows what a reader gets from the nesting: every heading
# is an H, and the depth of its Sect says how deep it sits.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "05.14-weakly-structured.pdf"}]
set assets [file join $here assets]
set regular [file join $assets fonts DejaVuSans.ttf]
set bold [file join $assets fonts DejaVuSans-Bold.ttf]

set doc [tclpdf new -unit mm]
$doc tagged 1

# The claim below refuses to go out without a title and a language, as in
# 5.7 - a weakly structured document is under the same rules as a strongly
# structured one in everything but its headings. The text is Spanish, so
# the tag says so - as in 5.5, where the same line carries Italian.
$doc info Title "Reglamento interno, extracto"
$doc info Author "Alexander Schoepe"
$doc language es-ES

$doc page add
$doc font embed face $regular
$doc font embed faceBold $bold

# -- nested sections, every heading a generic H -----------------------------

# The pattern is the same at every level: a Sect, an H first, then the text.
# Nothing in the H says "level 1" or "level 2" - the surrounding Sects do.
$doc structure Sect -script {

  $doc structure H -script {
    $doc font -family faceBold -size 16
    $doc text "Reglamento interno" -at {20 25}
  }

  $doc font -family face -size 10
  $doc text "Este extracto conserva la estructura de la fuente tal cual:\
      secciones dentro de secciones, sin niveles numerados. Cada título es\
      una H genérica: ¿a qué profundidad está? Lo dice el anidamiento, sin\
      ambigüedad." \
      -at {20 34} -width 170

  # One level down: a Sect inside the Sect, its H an H2 in effect - said by
  # the depth, not by the type.
  $doc structure Sect -script {

    $doc structure H -script {
      $doc font -family faceBold -size 13
      $doc text "Acceso" -at {20 52}
    }

    $doc font -family face -size 10
    $doc text "Al recinto de la fábrica solo accede quien está registrado.\
        Los visitantes llevan la acreditación visible y van siempre\
        acompañados." -at {20 60} -width 170

    # And a third level, nested in the second.
    $doc structure Sect -script {

      $doc structure H -script {
        $doc font -family faceBold -size 11
        $doc text "Tráfico de reparto" -at {20 76}
      }

      $doc font -family face -size 10
      $doc text "Las entregas se presentan en la puerta 2. Por la nave solo\
          se circula después de recibir instrucciones." -at {20 83} -width 170
    }
  }

  # Back up to the second level: a sibling of "Zutritt", at its depth.
  $doc structure Sect -script {

    $doc structure H -script {
      $doc font -family faceBold -size 13
      $doc text "Actuación en caso de alarma" -at {20 102}
    }

    $doc font -family face -size 10
    $doc text "En caso de alarma, apague las máquinas y diríjase a los puntos\
        de reunión. ¡No utilice ningún ascensor!" -at {20 110} -width 170
  }
}

# -- the claim, and the mixture it refuses ----------------------------------

# The document above may claim PDF/UA-1: its headings are one form, used
# throughout. What it may NOT do is also use a numbered one - shown on a
# second document that is built, asked, and destroyed unwritten. The write
# refuses before the first byte, so there is no file to throw away.
$doc ua 1

set mixed [tclpdf new -unit mm]
$mixed tagged 1
$mixed info Title "Forma mixta"
$mixed language es-ES
$mixed page add
$mixed font embed face $regular
$mixed font -family face -size 12
$mixed text "Numerado" -at {20 25} -tag H1
$mixed structure H -script {$mixed text "Genérico" -at {20 40}}
$mixed ua 1
catch {$mixed write [file join [file dirname $target] never-written.pdf]} refusal
$mixed destroy
puts "  refused: $refusal"

# The footer is an artifact, as everywhere - outside the tree, whichever
# form the tree has.
exampleFooter $doc face

$doc write $target
puts "  written: $target ([file size $target] bytes), [$doc page count] page(s)"
puts "  check it with: verapdf --flavour ua1 $target"
puts "  read it with:  pdfinfo -struct-text $target"
$doc destroy
