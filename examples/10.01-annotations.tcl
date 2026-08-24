#!/usr/bin/env tclsh
#
# tclpdf example 10.1 - notes, stamps and marked-up text
#
#   tclsh examples/10.01-annotations.tcl ?output.pdf?
#
# The annotations that say something ABOUT a page rather than doing something
# ON it: a sticky note, a rubber stamp, and the four ways of marking a passage
# of text - highlighted, underlined, struck out, and underlined with a
# squiggle. The clickable rectangle of example 5.3 and the form controls of
# the 9.x series are annotations too, and they are their own topics.
#
# The one thing worth taking from this file is WHO DRAWS THE PICTURE, because
# it decides everything else:
#
#   the note                 the READER draws the symbol, from /Name. That is
#                            what makes a note look like the reader's other
#                            notes - and it is also why a document claiming
#                            PDF/A refuses one: an archived page may not
#                            depend on what a reader happens to draw. The
#                            refusal is shown at the end of this file.
#   the stamp "Draft"        the same, from the fourteen names of ISO 32000-1,
#                            Table 181.
#   the stamp with a form    THIS document draws it, with [form create], and
#                            hands the form to -appearance. Then it looks the
#                            same everywhere and PDF/A takes it.
#   the four markups         the PACKAGE draws them, always, and the caller
#                            asks for nothing: the quadrilaterals and the
#                            colour are the whole picture. Which is why they
#                            are conforming wherever they stand.
#
# AND WHERE THE MARKED WORDS ARE. A markup annotation consists of its
# /QuadPoints - the rectangles of the marked text - and computing them by hand
# means measuring the string, knowing the ascender and remembering where the
# baseline was. So the call repeats what the [text] call said and lets the
# package measure:
#
#   $doc text "the amount due" -at {20 60}
#   $doc annot highlight -text "the amount due" -at {20 60} -contents ...
#
# Anything the measuring road cannot know - a passage broken over lines, a
# table cell, text this package did not set - goes in as rectangles through
# -quads, and the paragraph below shows that road as well.
#
# This document claims PDF/UA-1, so it also shows what accessibility asks of
# an annotation: a description in /Contents, and a place in the structure tree.
# The second one the package does by itself, and the first is one option.
#
#   verapdf --flavour ua1 examples/out/10.01-annotations.pdf
#   qpdf --json examples/out/10.01-annotations.pdf | grep -A4 Annot
#   pdftoppm -r 150 -png examples/out/10.01-annotations.pdf page
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "10.01-annotations.pdf"}]
set assets [file join $here assets]
set regular [file join $assets fonts DejaVuSans.ttf]
set bold [file join $assets fonts DejaVuSans-Bold.ttf]

set doc [tclpdf new -unit mm]
# Tagging comes first, before anything is drawn - and PDF/UA needs it anyway.
$doc tagged 1
$doc info Title "Invoice 2026-114, with annotations"
$doc info Author "Alexander Schoepe"
$doc language en-GB

$doc page add
$doc font embed face $regular
$doc font embed faceBold $bold

# -- the page the remarks are about -----------------------------------------

$doc font -family faceBold -size 16 -color {0.15 0.2 0.35}
$doc structure H1 -script {
  $doc text "Invoice 2026-114" -at {20 25}
}

$doc font -family face -size 11 -color black

# ONE LINE, MARKED. The [text] call and the [annot] call say the same -at and
# the same string, and nothing else has to agree: the width comes from the
# same measurement that set the line, and the height from the face's own
# ascender and descender, so the band covers the capitals and the descenders
# and nothing more.
set line "Payable by 15 September 2026 without deduction."
$doc structure P -script {
  $doc text $line -at {20 45}
  $doc annot highlight -text $line -at {20 45} \
      -contents "Payment date highlighted" -title "Accounts"
}

set old "Previous price: EUR 1,240.00"
$doc structure P -script {
  $doc text $old -at {20 55}
  $doc annot strikeout -text $old -at {20 55} \
      -contents "Price struck out" -title "Accounts"
}

# The misspelling is deliberate - a squiggle marks what a proofreader found,
# so the line has to carry something to find.
set typo "We confirm reciept of your order."
$doc structure P -script {
  $doc text $typo -at {20 65}
  $doc annot squiggly -text $typo -at {20 65} \
      -contents "Spelling mistake in this line" -title "Proofreading"
}

set term "Place of jurisdiction is Bochum."
$doc structure P -script {
  $doc text $term -at {20 75}
  $doc annot underline -text $term -at {20 75} \
      -contents "Place of jurisdiction underlined" -title "Legal"
}

# A RIGHT-ALIGNED LINE takes the same -align the text call took - -at names
# where the line ENDS there, and the band has to end in the same place.
set total "Total: EUR 1,190.00"
$doc font -family faceBold -size 11
$doc structure P -script {
  $doc text $total -at {190 90} -align right
  $doc annot highlight -text $total -at {190 90} -align right \
      -contents "Total highlighted" -title "Accounts"
}
$doc font -family face -size 11

# -- a passage over several lines -------------------------------------------
#
# -text marks ONE line, because [text] without -width sets one. A paragraph is
# broken by [textLines] and marked with -lines: one quadrilateral per line,
# one leading apart, and ONE annotation for the whole passage - which is what
# /QuadPoints is an array for, and what makes a reader announce the remark
# once instead of three times.
#
# The two calls are handed the same broken lines, so the rectangles cannot
# disagree with the text they cover.
set paragraph "Delivery is carriage paid. Complaints are to be notified in\
    writing within twelve working days of receipt of the goods; after that\
    the delivery counts as accepted as contracted. Title to the goods passes\
    on payment in full."
set width 170

$doc structure P -script {
  $doc text $paragraph -at {20 110} -width $width
  $doc annot highlight -at {20 110} -lines [$doc textLines $paragraph -width $width] \
      -contents "Terms of delivery highlighted in full" \
      -title "Legal" -colour {0.55 0.85 1}
}

# -- the note ---------------------------------------------------------------
#
# The reader draws the symbol; /Name says which of the seven of Table 174.
# -open 1 shows the note unfolded when the document is opened.
$doc structure P -script {
  $doc annot note -at {192 44} -icon Comment -colour {1 0.85 0.2} \
      -title "Accounts" \
      -contents "Date confirmed with the customer by telephone on 2 September."
}

# -- two stamps -------------------------------------------------------------
#
# The first is one of the fourteen names every reader knows and draws itself.
$doc structure P -script {
  $doc annot stamp -at {20 140} -size {45 16} -name Draft \
      -contents "Draft - not approved yet"
}

# The second is this document's own, drawn with [form create]. A form is
# stored once and placed as often as wanted; here it is placed nowhere and
# used only as the annotation's appearance, which is what an appearance
# stream is - a form XObject (12.5.5).
$doc form create approval -size {50 18} -script {
  $doc rect -at {0 0} -size {50 18} -radius 2 -stroke {0.15 0.5 0.25} -width 1.2
  $doc font -family faceBold -size 11 -color {0.15 0.5 0.25}
  $doc text "APPROVED" -at {25 8} -align center
  $doc font -family face -size 6 -color {0.15 0.5 0.25}
  $doc text "Bochum, 24 August 2026" -at {25 14} -align center
}
$doc structure P -script {
  $doc annot stamp -at {80 139} -appearance approval \
      -contents "Approved on 24 August 2026" -title "Management"
}

$doc font -family face -size 8 -color {0.35 0.35 0.4}
$doc structure P -script {
  $doc text "The left stamp is drawn by the reader, the right one by this\
      document. Only the right one is archivable." -at {20 165} -width 170
}

# -- what PDF/UA asks of an annotation --------------------------------------
#
# Two things, and the caller does one of them: /Contents, the description a
# reader announces - passed above as -contents on every single annotation -
# and a place in the structure tree, which the package makes by itself. Every
# annotation here sits in an Annot element inside the P it belongs to, which
# is what puts it in reading order.
#
# Read at the end, where everything it checks exists.
$doc ua 1

exampleFooter $doc face

$doc write $target
puts "  written: $target ([file size $target] bytes), [$doc page count] page(s)"
puts "  PDF/UA-[dict get [$doc ua state] part], annotations on page 1:\
    [llength [dict get [$doc state annots] 0]]"
puts "  check it with: verapdf --flavour ua1 $target"
$doc destroy

# -- and the refusal --------------------------------------------------------
#
# A note whose symbol the reader draws has no appearance stream, and ISO
# 32000-2, Table 166 requires one of every annotation. veraPDF fails such a
# file under 6.3.3. So a document that claims PDF/A refuses the note at the
# call rather than writing it and leaving the recipient's validator to find
# it - and the message names the way out.
#
# Nothing is written here; the document is built, refused and thrown away.
if {![catch {package require tdom}]} {
  set demo [tclpdf new -unit mm]
  $demo pdfa -part 3 -conformance B
  $demo page add
  if {[catch {$demo annot note -at {20 20} -contents "Please check"} message]} {
    puts "  PDF/A and a reader-drawn note:"
    foreach part [regexp -all -inline {.{1,68}(?:\s|$)} $message] {
      puts "    [string trim $part]"
    }
  }
  $demo destroy
}
