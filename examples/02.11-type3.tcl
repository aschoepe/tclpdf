#!/usr/bin/env tclsh
#
# tclpdf example 2.11 - a font whose glyphs are drawn
#
#   tclsh examples/02.11-type3.tcl ?output.pdf?
#
# A Type 3 font (ISO 32000-2, 9.6.4) has no font program. Its glyphs are
# CONTENT STREAMS - the same operators a page is drawn with - so a glyph can be
# anything this package can draw: a filled shape, a gradient, a picture, a
# rounded box with a rule through it. No outline format can do that, and no
# font editor is needed to make one.
#
# What it buys, on this page: a checklist whose boxes are TEXT. They sit on the
# baseline, they take the font size, they are measured by [textWidth], they
# break with the line, and they are copied and searched as the characters they
# stand for - because /ToUnicode maps them back. Drawn as rectangles beside the
# text instead, every one of those would be arithmetic in the caller.
#
# The two calls:
#
#   $doc font define ballot -ascent 750       the font and its glyph space
#   $doc font glyph ballot ☐ -width 900 -script { ... }   one glyph
#
# Inside the -script, {0 0} is the top left of the glyph's frame and y grows
# downwards, exactly as on a page and in a form; the baseline sits at y = the
# ascent. The numbers are GLYPH UNITS - 1000 to the em by default - so the same
# script draws the same glyph whatever unit the document is in.
#
# -color decides which of the two width operators the glyph starts with:
#
#   own  (the default)  d0 - the glyph brings its own colours, and every
#                       drawing method of this package sets one
#   text                d1 - the glyph describes only its shape and is painted
#                       in the colour of the text, like a letter. The norm then
#                       IGNORES any colour the script sets, so -bbox is
#                       required: that box is binding.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf
package require tclpdf::type3

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "02.11-type3.pdf"}]

set doc [tclpdf new -unit mm]
$doc info Title "A font whose glyphs are drawn"
$doc info Author "tclpdf example 2.11"
$doc page add

set y 20
exampleHeading $doc y "A font whose glyphs are drawn"
examplePara $doc y "The three marks in the list below are not letters of any\
    face. They are a Type 3 font: each glyph is a little content stream in this\
    file, drawn with the same calls that draw the page. They set as text,\
    measure as text and extract as text."

# -- the font ---------------------------------------------------------------
#
# One frame for all three glyphs: 1000 units to the em (the default matrix),
# 750 of them above the baseline. A box drawn from y = 50 to y = 750 therefore
# stands from the baseline up to a little under the cap height.

$doc font define ballot -ascent 750

# The empty box: an outline in the colour of the TEXT, so a heading in blue
# gets blue boxes. That is what -color text is for - d1, "the glyph description
# specifies only shape, not colour". Its bounding box has to be stated, and
# has to hold everything the script paints, the width of the stroke included.
$doc font glyph ballot ☐ -width 900 -color text -bbox {30 20 700 700} -script {
  $doc rect -at {60 50} -size {640 640} -stroke black -width 60 -radius 60
}

# The ticked box: the same outline with a tick through it, and the tick in a
# colour of its own - so this one is d0, the default, and brings its colours
# with it. A glyph like this is the case no outline format has an answer for.
$doc font glyph ballot ☑ -width 900 -script {
  $doc rect -at {60 50} -size {640 640} -stroke {0.25 0.25 0.3} -width 60 \
      -radius 60
  $doc path -segments {{move 170 380} {line 330 540} {line 620 190}} \
      -stroke {0.10 0.55 0.25} -width 130 -cap round -join round
}

# The crossed box, likewise coloured.
$doc font glyph ballot ☒ -width 900 -script {
  $doc rect -at {60 50} -size {640 640} -stroke {0.25 0.25 0.3} -width 60 \
      -radius 60
  $doc path -segments {{move 200 190} {line 560 550} {move 560 190} {line 200 550}} \
      -stroke {0.70 0.15 0.15} -width 130 -cap round
}

# -- the list ---------------------------------------------------------------
#
# The mark and the wording are ONE line of text, in two faces: the box comes
# from the drawn font, the words from Helvetica. [textWidth] measures the mark
# in the drawn font exactly as it measures a letter, so the wording starts at
# the same distance behind every mark without a number in the script.

set rows {
  ☑ "Kern: pages, streams, graphics primitives, the standard faces"
  ☑ "TrueType: subsetting, Identity-H, ToUnicode"
  ☑ "Type 1 and OpenType, embedded whole"
  ☑ "Type 3: this page"
  ☐ "SVG fonts - there is no such thing in PDF"
  ☒ "A font editor, to get any of this"
}

set y [expr {$y + 4}]
foreach {mark wording} $rows {
  $doc font -family ballot -size 11 -color {0 0 0}
  $doc text $mark -at [list 20 $y]
  set gap [$doc textWidth $mark]
  $doc font -family helvetica -style {} -size 11 -color {0.1 0.1 0.15}
  $doc text $wording -at [list [expr {20 + $gap + 2}] $y]
  set y [expr {$y + 7}]
}

set y [expr {$y + 4}]
$doc font -family helvetica -style {} -size 11
examplePara $doc y "The same three glyphs at four sizes - a font, not a\
    drawing, so the size is the font size and nothing is scaled by hand:"

set x 20
foreach size {8 12 18 28} {
  $doc font -family ballot -size $size -color {0 0 0}
  $doc text "☐☑☒" -at [list $x [expr {$y + 12}]]
  set x [expr {$x + [$doc textWidth "☐☑☒"] + 6}]
}
set y [expr {$y + 20}]

examplePara $doc y "The colour of the empty box follows the text, because that\
    glyph is written with the d1 operator: it describes shape only, and the\
    reader paints it in whatever colour the text has. The two coloured ones use\
    d0 and bring their own."

$doc font -family ballot -size 14 -color {0.15 0.35 0.75}
$doc text "☐" -at [list 20 [expr {$y + 6}]]
$doc font -family ballot -size 14 -color {0.75 0.35 0.15}
$doc text "☐" -at [list 30 [expr {$y + 6}]]
$doc font -family ballot -size 14 -color {0.15 0.35 0.75}
$doc text "☑" -at [list 40 [expr {$y + 6}]]
$doc font -family ballot -size 14 -color {0.75 0.35 0.15}
$doc text "☑" -at [list 50 [expr {$y + 6}]]
set y [expr {$y + 14}]
$doc font -family helvetica -style {} -size 9 -color {0.45 0.45 0.5}
$doc text "blue, orange, blue, orange - the tick keeps its green either way" \
    -at [list 20 $y]
set y [expr {$y + 10}]

# -- check it yourself ------------------------------------------------------

$doc font -family helvetica -style {} -size 10 -color {0 0 0}
exampleHeading $doc y "Check it yourself"
examplePara $doc y "The first command shows the font dictionary: no font file\
    anywhere, a /CharProcs entry per glyph, and a /Widths array in glyph units\
    rather than in thousandths of the em. The second prints one of those glyph\
    streams - the d0 or d1 line first, then ordinary drawing operators. The\
    third is the one that matters for a reader: the marks come back out as the\
    characters they stand for, which is what /ToUnicode is written for."
exampleCommandBlock $doc y [list \
    "qpdf --qdf --object-streams=disable [file tail $target] - | grep -A12 Type3" \
    "qpdf --qdf --object-streams=disable [file tail $target] - | grep -B2 -A8 ' d0'" \
    "pdftotext [file tail $target] - | head -12" \
    "pdffonts [file tail $target]"]

# The footer asks the document for its fonts, and it has to set its own line -
# the drawn font has three glyphs and no letters.
exampleFooter $doc helvetica

$doc write $target
puts "  written: $target ([file size $target] bytes)"
set info [$doc font info ballot]
puts "  drawn font \"ballot\": [dict get $info glyphs] glyphs,\
    [format %.0f [dict get $info unitsPerEm]] units to the em,\
    [dict get $info permission]"
$doc destroy
