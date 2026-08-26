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
#   Ref on a TOCI      a table of contents says which element each entry
#                      points at (8.2.5.8) - page 3, and the one thing here
#                      that is an entry rather than a type
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
$doc info Title "A guide to accessible documents"
$doc info Author "Alexander Schoepe"
$doc language en-GB

# Both levels of WTPDF: reuse says the tagging is good enough to get the
# content back out, accessibility says it is good enough to be read aloud.
# They are not exclusive, and a file that reaches the second has reached the
# first. -revision is the year of the ISO 14289-2 edition claimed and goes
# into the packet as pdfuaid:rev; 2024 is the first edition and the default,
# said here so that the claim names it rather than inheriting it.
$doc ua -part 2 -revision 2024 -wtpdf {reuse accessibility}

$doc page add
$doc font embed face $regular
$doc font embed faceBold $bold

# -- Title, which is a 2.0 type ---------------------------------------------

# In 1.7 the document title was an H1 and had to be. 2.0 has a Title element,
# and using it leaves H1 to mean "first heading" rather than "the name of the
# document".
$doc font -family faceBold -size 17
$doc structure Title -script {
  $doc text "A guide to accessible documents" -at {20 25}
}

$doc font -family face -size 10
$doc text "This document claims PDF/UA-2 and carries the WTPDF declaration\
    for both conformance levels. It is a PDF 2.0 file - it has to be, because\
    ISO 14289-2 allows nothing else." -at {20 36} -width 170

# -- the heading levels 2.0 allows ------------------------------------------

# -name makes the element referable - see the link at the end of the page.
$doc font -family faceBold -size 13
$doc structure Sect -name baum -script {
  $doc text "What the structure tree carries" -at {20 54} -tag H1
}

$doc font -family face -size 10
$doc text "The elements sit in the 2.0 namespace, which a Namespace\
    dictionary at the root of the tree names. Eleven older types deliberately\
    keep the default namespace, because 2.0 does not have them:" \
    -at {20 62} -width 170

# Code is one of the eleven. It carries no /NS, and that is not an omission -
# naming the 2.0 namespace on a type that does not exist there would be a
# claim about nothing.
$doc font -family face -size 9
$doc structure Code -script {
  # 77, not 72: the paragraph above runs to three lines at this width, and
  # its last baseline sits at 71 - the code line used to be drawn through it
  # (seen in Preview, 2026-08-17).
  $doc text "set doc \[tclpdf new -unit mm\] ;# Code, Note, Quote, TOC ..." \
      -at {24 77}
}

$doc font -family faceBold -size 11
$doc text "Emphasis" -at {20 84} -tag H2

# Em and Strong are new in 2.0. In 1.7 both were a Span and the emphasis was
# a matter of the font alone - which a reader cannot hear.
# Inside the P, not beside it: Strong is an inline type, and a tree with a
# Strong directly under Document is rejected - "Document shall not contain
# Strong", Table 5.
$doc structure P -script {
  $doc font -family face -size 10
  $doc text "In 1.7 emphasis was a matter of the typeface alone, and so it\
      could not be heard." -at {20 92} -width 170
  $doc structure Strong -script {
    $doc font -family faceBold -size 10
    $doc text "Strong says it to a reader out loud." -at {20 99}
  }
}

# -- Aside and FENote, both new in 2.0 -------------------------------------

$doc font -family faceBold -size 11
$doc text "Aside and footnote" -at {20 112} -tag H2

# An Aside is content that belongs to the page but not to the flow of the
# text - a marginal note, a box. In 1.7 it had to be a Div or nothing, and a
# reader could not tell it apart from the argument it stands beside.
$doc font -family face -size 9 -color {0.3 0.3 0.35}
$doc structure Aside -script {
  $doc text "By the way: example 5.7 shows how an ordered list is marked\
      up - repeating it here would show nothing new." \
      -at {20 120} -width 170
}

# FENote is the 2.0 type for a footnote or endnote. Before it there was Note,
# which is one of the eleven types that stayed in the 1.7 namespace - so a
# 2.0 document that wants a footnote uses this one.
$doc font -family face -size 9 -color black
$doc structure FENote -script {
  $doc text "1) A footnote is a type of its own in 2.0; Note is gone from\
      that namespace." -at {20 132} -width 170
}

# -- an attachment, which needs a description in part 2 ---------------------

$doc font -family faceBold -size 11
$doc text "Attachment" -at {20 148} -tag H2

$doc font -family face -size 10
$doc text "The attachment carries a description. PDF/UA-2 makes it\
    mandatory: a file name is not a description, and \"factur-x.xml\" read\
    out loud tells nobody anything." -at {20 156} -width 170

$doc attach [info script] -name 05.08-ua2-wtpdf.tcl \
    -description "The script that produced this document"

# -- a link that points at an element, not at a page -----------------------

$doc font -family faceBold -size 11
$doc text "A link" -at {20 168} -tag H2

# A structure destination names the ELEMENT (12.3.2.3). A page destination
# says "page 1, 168 mm down"; this one says "the section called wtpdf" and
# still lands there after the content above it has grown by a paragraph.
# PDF/UA-2 asks for internal targets to be written this way.
$doc structure Link -script {
  $doc font -family face -size 10 -color {0.1 0.2 0.6}
  $doc text "Back to the section on the structure tree" -at {20 176}
  $doc link -at {20 172} -size {90 6} -structure baum \
      -tooltip "To the section on the structure tree"
}

$doc line -from {20 186} -to {190 186} -width 0.4 -stroke {0.4 0.4 0.4}

exampleFooter $doc face

# -- a second page: the rest of what 2.0 added ------------------------------

# Title, Aside, FENote, Strong and Code are on page 1. What is left of the
# 2.0 vocabulary is here, each on a [structure] call of its own: the heading
# levels past six, Em beside Strong, Sub for a subscript, and
# DocumentFragment for a piece of another document carried inside this one.
$doc page add

# -- H7 to H10 --------------------------------------------------------------

# 1.7 stopped at H6. 2.0 lifted the limit, and a deep document may say so -
# but no level may be skipped on the way down (UA-1 7.4.2, and the write
# checks it), so the ladder starts where page 1 stopped, at H2, and takes
# every step to H10. The type is named on the call; the size is only how it
# looks.
$doc font -family faceBold -size 11 -color black
$doc text "Ten heading levels" -at {20 25} -tag H2

$doc font -family face -size 10
$doc text "A heading level is the one thing a listener has to tell how deep\
    in the document they are. Six were enough for most documents and are\
    still what page 1 uses; a standard with parts, clauses, subclauses and\
    numbered paragraphs runs out of them." -at {20 33} -width 170

$doc font -family faceBold -size 10
$doc structure H3 -script { $doc text "Part 1 - H3" -at {20 50} }
$doc structure H4 -script { $doc text "Clause 1.2 - H4" -at {24 56} }
$doc font -size 9
$doc structure H5 -script { $doc text "Subclause 1.2.3 - H5" -at {28 62} }
$doc structure H6 -script { $doc text "Paragraph 1.2.3.4 - H6" -at {32 68} }
$doc font -size 8
$doc structure H7 -script {
  $doc text "Item 1.2.3.4.5 - H7, the first level 1.7 did not have" -at {36 74}
}
$doc structure H8 -script { $doc text "Point 1.2.3.4.5.6 - H8" -at {40 80} }
$doc structure H9 -script { $doc text "Note 1.2.3.4.5.6.7 - H9" -at {44 86} }
$doc structure H10 -script {
  $doc text "Example 1.2.3.4.5.6.7.8 - H10, the last one" -at {48 92}
}

# -- Em and Sub, both inline ------------------------------------------------

$doc font -family faceBold -size 11
$doc text "Em and Sub" -at {20 108} -tag H2

# Em is emphasis, Strong is importance - two words a reader says differently.
# Both are inline and sit inside the paragraph, never beside it. Sub is a
# subscript; the -rise on the text call lowers the glyph, the Sub says what
# the lowering means, and without it "H2O" is read out as a number.
$doc structure P -script {
  $doc font -family face -size 10 -color black
  set lead "Emphasis is a matter of tone: this word is "
  $doc text $lead -at {20 116}
  $doc structure Em -script {
    $doc text "emphasised" -at [list [expr {20 + [$doc textWidth $lead]}] 116]
  }
  $doc text ", and Strong on page 1 was important." \
      -at [list [expr {20 + [$doc textWidth "${lead}emphasised"]}] 116]
}
$doc structure P -script {
  $doc font -family face -size 10
  set lead "The coolant is plain water, H"
  $doc text $lead -at {20 124}
  $doc structure Sub -script {
    $doc text "2" -at [list [expr {20 + [$doc textWidth $lead]}] 124] \
        -size 7 -rise -1.5
  }
  $doc text "O, and nothing else." \
      -at [list [expr {20 + [$doc textWidth $lead] + [$doc textWidth "2" -size 7]}] 124]
}

# -- DocumentFragment ------------------------------------------------------

$doc font -family faceBold -size 11
$doc text "A fragment of another document" -at {20 140} -tag H2

$doc font -family face -size 10
$doc text "A quotation is part of the argument; a DocumentFragment is a piece\
    of another document carried along whole - an excerpt from example 5.7,\
    here, in its own language. The frame around it is decoration and an\
    artifact; the fragment holds a paragraph, not the frame." \
    -at {20 148} -width 170

$doc rect -at {20 164} -size {170 18} -stroke {0.6 0.6 0.65} -width 0.3
$doc structure DocumentFragment -name auszug -lang de-DE \
    -title "Aus Beispiel 5.7" -script {
  $doc structure P -script {
    $doc font -family face -size 9 -color {0.25 0.25 0.3}
    $doc text "Titel, Sprache, Schrifteinbettung, Überschriftenfolge,\
        Tabellenform und die Beschreibung jedes Verweises. Die Prüfung läuft\
        einmal und meldet alles, was fehlt - nicht den ersten Punkt und dann\
        wieder von vorn." -at {23 170} -width 164
  }
}
$doc font -family face -size 10 -color black

exampleFooter $doc face

# -- a table of contents, which part 2 asks a question about ---------------

# A third page for the one element of the 2.0 vocabulary that is not a type
# but an ENTRY: Ref (Table 355), what a structure element points at.
#
# PDF/UA-2 8.2.5.8 is the reason it matters here: "Each TOCI in the table of
# contents shall identify the target of the reference using the Ref entry,
# either directly on the TOCI structure element itself or on one of its
# child structure elements". A table of contents without it is a list of
# headings a reader cannot follow, and the write refuses the claim by name -
# so this page is also what that refusal looks like when it is answered.
#
# -ref names the target by the -name it was given, exactly as [link
# -structure] does, and it may point forward: the entries below are written
# before nothing, but a real table of contents stands on page 1 and names
# sections that come later.
$doc page add

$doc font -family faceBold -size 11
$doc text "A table of contents" -at {20 25} -tag H2

$doc font -family face -size 10
$doc text "Each entry names the element it stands for, so that a reader can\
    follow it without a page number. The two below point at the section on\
    page 1 and at the fragment on page 2 - by name, not by position."\
    -at {20 33} -width 170

$doc structure TOC -script {
  $doc structure TOCI -ref baum -script {
    $doc text "What the structure tree carries" -at {24 48}
  }
  $doc structure TOCI -ref auszug -script {
    $doc text "A fragment of another document" -at {24 55}
  }
}

exampleFooter $doc face

$doc write $target
set state [$doc ua state]
puts "  written: $target ([file size $target] bytes), [$doc page count] page(s)"
puts "  PDF/UA-[dict get $state part] rev [dict get $state revision],\
    WTPDF: [join [dict get $state wtpdf] { and }],\
    registered: [dict get $state registered]"
puts "  check it with: verapdf --flavour ua2 $target"
puts "                 verapdf --flavour wt1a $target"
$doc destroy
