#!/usr/bin/env tclsh
#
# tclpdf example 5.6 - lists, and what does not belong in the tree
#
#   tclsh examples/05.06-lists-and-artifacts.tcl ?output.pdf?
#
# The companion to 5.5, which shows the plain shape of a tagged document. This
# one is about the two things that are easy to get wrong once the plain shape
# works.
#
# FIRST, lists. A list is the one structure people build wrong, because the
# norm is stricter than it looks: L holds LI, LI holds Lbl and LBody, and
# nothing else goes anywhere. tclpdf refuses the wrong nesting where it is
# written rather than letting a validator find it hours later - and it derives
# the common case, so text drawn straight into an LI becomes its LBody.
#
# SECOND, what stays OUT. A page number, a rule, a decorative gradient, a
# reusable block placed for looks - none of it means anything to someone who
# has the document read to them, and all of it has to say so. Under PDF/UA
# content that is neither tagged nor declared an artifact counts as a defect;
# tclpdf declares it by default and only puts a picture into the tree when
# -alt says what it shows.
#
# Watch for the calls that are NOT there: no -tag on the paragraphs, none on
# the list items, none on the gradient. What a writer can derive, it derives.
#
#   verapdf -f 3a          examples/out/05.06-lists-and-artifacts.pdf
#   verapdf --flavour ua1  examples/out/05.06-lists-and-artifacts.pdf
#   pdfinfo -struct-text   examples/out/05.06-lists-and-artifacts.pdf
#
# The last one is the interesting one: it reads the document the way a screen
# reader does, out of the tree rather than off the page.
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "05.06-lists-and-artifacts.pdf"}]
set assets [file join $here assets]
set regular [file join $assets fonts DejaVuSans.ttf]
set bold [file join $assets fonts DejaVuSans-Bold.ttf]
set profile [file join [file dirname $here] icc sRGB.icc]

set doc [tclpdf new -unit mm]
$doc tagged 1
$doc info Title "Sicherheitsunterweisung 2026"
$doc info Author "Alexander Schoepe"
$doc language de-DE

$doc page add
$doc font embed face $regular
$doc font embed faceBold $bold
$doc pdfa -part 3 -conformance A -profile $profile

# -- a decorative band, which means nothing --------------------------------

# Drawn before anything opens an element, so it becomes an artifact by itself.
# That is the default and the honest one: a coloured band is decoration.
$doc shading axial -at {0 0} -size {210 24} -colors {{0.20 0.30 0.45} {0.35 0.50 0.70}}

$doc font -family faceBold -size 16 -color white
$doc text "Sicherheitsunterweisung" -at {20 15} -tag H1

# -- an ordered list, built the way the norm wants it -----------------------

$doc structure Sect -script {

  $doc font -family faceBold -size 11 -color black
  $doc text "Vor dem Einschalten" -at {20 40} -tag H2

  $doc font -family face -size 10

  # Lbl and LBody explicitly: the label is not part of the sentence, and a
  # reader should be able to skip it. This is the long form, and the one to
  # use when the numbering carries meaning.
  $doc structure L -script {
    set y 48
    foreach {label text} {
      "1." "Schutzhaube auf festen Sitz prüfen."
      "2." "Not-Aus auslösen und zurückstellen."
      "3." "Werkstück spannen, Spannschlüssel abziehen."
    } {
      $doc structure LI -script {
        $doc structure Lbl -script { $doc text $label -at [list 20 $y] }
        $doc structure LBody -script {
          $doc text $text -at [list 27 $y] -width 160
        }
      }
      incr y 6
    }
  }

  $doc font -family faceBold -size 11
  $doc text "Nach der Arbeit" -at {20 74} -tag H2

  $doc font -family face -size 10

  # The short form: text drawn straight into an LI becomes its LBody, because
  # there is nothing else it could be. An unnumbered list needs no Lbl - the
  # bullet would be decoration, and drawing one here would mean declaring it
  # an artifact.
  $doc structure L -script {
    set y 82
    foreach text {
      "Maschine spannungsfrei schalten."
      "Späne mit dem Haken entfernen, nie mit der Hand."
      "Übergabebuch ausfüllen."
    } {
      $doc structure LI -script { $doc text $text -at [list 20 $y] -width 160 }
      incr y 6
    }
  }
}

# -- a reusable block, placed twice ----------------------------------------

$doc structure Sect -script {

  $doc font -family faceBold -size 11
  $doc text "Kennzeichnung" -at {20 108} -tag H2

  $doc font -family face -size 10
  $doc text "Dasselbe Zeichen zweimal gesetzt. Als Form gespeichert wird es\
      einmal eingebettet und zweimal aufgerufen - und weil es hier etwas\
      bedeutet, bekommt es eine Beschreibung." -at {20 114} -width 170

  # Nothing inside the form is marked: a form is a content stream of its own,
  # and a mark number is unique per stream. The INVOCATION carries the
  # marking - once per placement.
  $doc form create warnsign -size {20 18} -script {
    $doc polygon -points {10 0 20 18 0 18} -fill {0.95 0.75 0.10} \
        -stroke black -width 0.4
    $doc font -family faceBold -size 11 -color black
    $doc text "!" -at {10 14} -align center
  }

  $doc form place warnsign -at {20 128} -alt "Warnzeichen: allgemeine Gefahr"

  # The same block again, this time as decoration beside the text - so no
  # -alt, and it becomes an artifact. A reader hears it once, not twice.
  #
  # -artifact 1 SAYS so. Without it the placement would be an artifact just
  # the same, but by default rather than by decision - and an artifact is
  # the one way real content passes a reader entirely, so tclpdf keeps a
  # note of every graphic that fell into it with neither -alt nor
  # -artifact. Written out, the intent is on record and the note is not.
  $doc form place warnsign -at {170 128} -scale 0.6 -artifact 1
}

# -- what a reader hears, and what it does not -----------------------------

$doc structure Sect -script {
  $doc font -family faceBold -size 11
  $doc text "Zur Probe" -at {20 158} -tag H2

  $doc font -family face -size 9
  $doc text "Die Linie unter dieser Zeile, der Farbverlauf oben und die\
      Fußzeile stehen nicht im Baum. Wer das Dokument mit\
      \"pdfinfo -struct-text\" ausliest, findet sie nicht - und genau das ist\
      der Zweck." -at {20 164} -width 170
}

$doc line -from {20 176} -to {190 176} -width 0.4 -stroke {0.4 0.4 0.4}

# The footer names the script and the faces, and is an artifact by nature.
exampleFooter $doc face

$doc write $target
puts "  written: $target ([file size $target] bytes), [$doc page count] page(s)"
puts "  check it with: verapdf -f 3a $target"
puts "  read it with:  pdfinfo -struct-text $target"
$doc destroy
