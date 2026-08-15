#!/usr/bin/env tclsh
#
# tclpdf example 5.7 - a document that may call itself accessible
#
#   tclsh examples/05.07-accessible.tcl ?output.pdf?
#
# Examples 5.5 and 5.6 build the structure tree. This one makes the CLAIM -
# PDF/UA-1, ISO 14289-1 - and the interesting part is not the two lines that
# write it but everything the writer refuses to let past first.
#
# What [$doc ua 1] insists on, and what each refusal saves:
#
#   a title          the window shows it instead of the file name; someone
#                    listening to "rg-2026-114-v3-final.pdf" learns nothing
#   a language       the reader picks its pronunciation from it
#   every font       embedded, the standard 14 included - stricter than
#                    PDF/A, and it rules out Symbol and ZapfDingbats
#                    entirely, because neither has an embeddable face
#   headings         H1 first, no level skipped
#   regular tables   every row the same number of cells, which is why this
#                    example has no colSpan anywhere
#   links            a description on every one
#   lists            an ordered list names its numbering AND its items carry
#                    a Lbl - one without the other is refused either way
#   graphics         a picture, drawing or form placement is described with
#                    -alt or declared decoration with -artifact 1; one that
#                    fell into artifact by default was never judged
#
# All of them are checked when the file is written, all at once rather than
# one per run, and each message names the call to change. A validator finds
# the same problems - at the recipient, against an object number.
#
# What the writer contributes by itself: the pdfuaid schema in the metadata
# and ViewerPreferences with DisplayDocTitle. Neither moves a mark on a page,
# so asking for them would be ceremony. DisplayDocTitle is checked all the
# same, because a later [viewerPreferences -displayDocTitle 0] can take it
# back - and then the write refuses, naming that call.
#
# PDF/UA and PDF/A are independent claims about different things - one about
# being readable by everyone, one about being readable in fifty years - and a
# document may make both, as this one does.
#
#   verapdf --flavour ua1  examples/out/05.07-accessible.pdf
#   verapdf -f 3a          examples/out/05.07-accessible.pdf
#   pdfinfo -struct-text   examples/out/05.07-accessible.pdf
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "05.07-accessible.pdf"}]
set assets [file join $here assets]
set regular [file join $assets fonts DejaVuSans.ttf]
set bold [file join $assets fonts DejaVuSans-Bold.ttf]
set profile [file join [file dirname $here] icc sRGB.icc]

set doc [tclpdf new -unit mm]
$doc tagged 1

# The title is not decoration here, it is a requirement: [ua] refuses to
# write the claim without one.
$doc info Title "Barrierefreier Bescheid 2026-114"
$doc info Author "Alexander Schoepe"
$doc language de-DE

$doc page add
$doc font embed face $regular
$doc font embed faceBold $bold
$doc pdfa -part 3 -conformance A -profile $profile

# -- the heading levels, in order ------------------------------------------

# H1 first and no level skipped. It reads as pedantry until one remembers
# what a heading level IS to someone who cannot see the page: the only way to
# tell how deep in the document they are.
$doc font -family faceBold -size 16
$doc text "Barrierefreier Bescheid" -at {20 25} -tag H1

$doc font -family face -size 10
# An abbreviation says what it stands for: UA-1 7.20 asks for it, and ISO
# 32000-1 14.9.5 provides the place - the element carries /E with the
# expanded form, and a reader that is asked can read it out. -expansion on
# [text] puts the word into a Span with that entry; the [structure P] around
# the three calls keeps them one paragraph, and the Span sits inside it.
$doc structure P -script {
  set lead "Dieses Dokument beansprucht "
  $doc text $lead -at {20 34}
  $doc text "PDF/UA" -at [list [expr {20 + [$doc textWidth $lead]}] 34] \
      -expansion "PDF Universal Accessibility, ISO 14289"
  $doc text "-1. Der Anspruch steht in den Metadaten, und tclpdf schreibt\
      ihn nur, wenn die Bedingungen dafür beim Schreiben erfüllt sind - sonst\
      bricht der Aufruf ab und nennt die Stelle, die zu ändern ist." \
      -at {20 34} -width 170 -firstIndent [$doc textWidth "${lead}PDF/UA"]
}

$doc font -family faceBold -size 12
$doc text "Was geprüft wird" -at {20 52} -tag H2

$doc font -family face -size 10
$doc text "Titel, Sprache, Schrifteinbettung, Überschriftenfolge,\
    Tabellenform und die Beschreibung jedes Verweises. Die Prüfung läuft\
    einmal und meldet alles, was fehlt - nicht den ersten Punkt und dann\
    wieder von vorn." -at {20 60} -width 170

# -- a regular table -------------------------------------------------------

$doc font -family faceBold -size 12
$doc text "Fristen" -at {20 82} -tag H2

# Three columns in every row. PDF/UA needs that, and colSpan cannot deliver
# it - so a document that has to make the claim states its spans as separate
# tables or leaves the claim off. Here there is nothing to span.
#
# -style is not optional: a table has a font state of its own and it defaults
# to Helvetica, which no UA document may use.
$doc table -at {20 88} -width 170 -theme striped \
    -style {family face} -headStyle {family faceBold} \
    -head {{Vorgang Frist Stelle}} \
    -body {
      {"Widerspruch" "1 Monat" "Ausgangsbehörde"}
      {"Klage" "1 Monat" "Verwaltungsgericht"}
      {"Akteneinsicht" "jederzeit" "Ausgangsbehörde"}
    }

# The head cells carry Scope Column, written by the table itself: a head row
# heads columns, and that is the one case a writer can be sure of.

# -- a link that says where it goes ----------------------------------------

$doc font -family faceBold -size 12
$doc text "Weitere Auskunft" -at {20 128} -tag H2

$doc font -family face -size 10
$doc text "Die Rechtsgrundlagen stehen im Netz:" -at {20 136} -width 170

# The Link element wraps both calls - the text and the annotation - so the
# tree holds them together. The annotation joins it as an OBJR, because it is
# not part of any content stream and cannot have an MCID.
#
# -tooltip is what becomes Contents, and without it the write fails: a reader
# announces a link by that text, and "link" on its own tells nobody anything.
$doc structure Link -script {
  $doc font -family face -size 10 -color {0.1 0.2 0.6}
  $doc text "Verwaltungsverfahrensgesetz beim Bundesamt für Justiz" \
      -at {20 144}
  $doc link -at {20 140} -size {110 6} \
      -url https://www.gesetze-im-internet.de/vwvfg/ \
      -tooltip "Verwaltungsverfahrensgesetz, Volltext beim Bundesamt für Justiz"
}

# -- an ordered list says HOW it is numbered -------------------------------

$doc font -family faceBold -size 12
$doc text "Vorgehen" -at {20 160} -tag H2

# -numbering is mandatory on an ordered list (UA-1 7.6) and can never be
# derived: the label is drawn text, and "1." and "-" look the same to a
# writer. The write checks that the two agree - a list numbered Decimal whose
# items carry no Lbl is refused, and so is a list whose items carry a Lbl
# while the list says nothing about its numbering. Here every LI holds its
# number in a Lbl and the L says Decimal, which is the shape a reader can
# announce as "1 of 3".
$doc structure L -numbering Decimal -script {
  set y 168
  foreach {label body} {
    "1." "Widerspruch schriftlich einlegen, Frist beachten."
    "2." "Eingangsbestätigung abwarten."
    "3." "Bei Bedarf Akteneinsicht beantragen."
  } {
    $doc structure LI -script {
      $doc structure Lbl -script {
        $doc font -family faceBold -size 10 -color black
        $doc text $label -at [list 20 $y]
      }
      $doc structure LBody -script {
        $doc font -family face -size 10 -color black
        $doc text $body -at [list 28 $y] -width 162
      }
    }
    incr y 7
  }
}

# -- the claim ------------------------------------------------------------

# Last, deliberately: it is a statement about the finished document, and
# everything it checks has to exist by now. Called earlier it would work just
# as well - the checking happens at write time either way - but reading it
# here says what it is.
$doc ua 1

$doc line -from {20 194} -to {190 194} -width 0.4 -stroke {0.4 0.4 0.4}
$doc font -family face -size 9 -color black
$doc text "Der Farbverlauf gibt es hier nicht, die Linie darüber schon - und\
    sie steht nicht im Baum. Was nichts bedeutet, wird als Artefakt\
    ausgezeichnet; unter PDF/UA ist ungekennzeichneter Inhalt ein Mangel." \
    -at {20 200} -width 170

exampleFooter $doc face

$doc write $target
puts "  written: $target ([file size $target] bytes), [$doc page count] page(s)"
puts "  [exampleArchival $doc], PDF/UA-[dict get [$doc ua state] part]"
puts "  check it with: verapdf --flavour ua1 $target"
puts "  read it with:  pdfinfo -struct-text $target"
$doc destroy
