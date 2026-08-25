#!/usr/bin/env tclsh
#
# tclpdf example 1.3 - text layout
#
#   tclsh examples/01.03-text-layout.tcl ?output.pdf?
#
# A page from a field guide. Everything here is set in the fourteen standard
# fonts - no embedding, because none of it needs any character WinAnsi cannot
# hold, and a document that does not need an embedded face should not carry
# one.
#
# What a caller gets: alignment including justification, letter and word
# spacing, horizontal scaling, rotation, superscript and subscript, and the
# two measuring calls that make layout possible at all - [textLines] and
# [textHeight] answer "how much room will this need" without drawing it.
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "01.03-text-layout.pdf"}]

set doc [tclpdf new -unit mm]
$doc info Title "Text layout"
$doc info Author "Field guide to common lichens"
$doc page add

$doc font -family times -style bold -size 18
$doc text "Crustose lichens" -at {20 24}
$doc font -family times -style italic -size 10
$doc text "Chapter four - identification in the field" -at {20 31}
$doc line -from {20 35} -to {190 35} -stroke {0.55 0.5 0.45} -width 0.4

# -- justification ---------------------------------------------------------

set body "A crustose lichen forms a crust that adheres so tightly to the\
    substrate that it cannot be removed without destroying it. The thallus\
    lacks a lower cortex, which distinguishes it from the foliose forms\
    treated in the previous chapter. In the field the distinction is made by\
    attempting to lift an edge with a knife: a foliose thallus gives way, a\
    crustose one does not."

# How tall will this be? Asked before anything is drawn, so the heading below
# can be placed without counting lines.
$doc font -family times -style {} -size 10 -leading 14
set needed [$doc textHeight $body 82]
set lines [llength [$doc textLines $body 82]]

set y [$doc text $body -at {20 44} -width 82 -align justify -anchor top]
$doc text $body -at {108 44} -width 82 -align left -anchor top

$doc font -family helvetica -size 7
$doc text "justified - word spaces stretch" -at [list 20 [expr {$y + 3}]]
$doc text "ragged right - word spaces fixed" -at [list 108 [expr {$y + 3}]]
$doc text "measured before drawing: $lines lines, [format %.1f $needed] mm" \
    -at [list 20 [expr {$y + 8}]]

# -- alignment -------------------------------------------------------------

set y [expr {$y + 18}]
$doc font -family helvetica -style bold -size 10
$doc text "Alignment against a fixed point" -at [list 20 $y]
$doc line -from [list 105 [expr {$y + 4}]] -to [list 105 [expr {$y + 26}]] \
    -stroke {0.8 0.2 0.2} -width 0.3

# "centre" is accepted for "center", so the option can be spelt the way the
# rest of a program spells it. The other two options are the defaults, said
# out loud once: the y of -at is the baseline, and the line runs left to
# right.
$doc font -style {} -size 10
foreach {align label offset} {left "left of the mark" 8
        centre "centred on it" 15  right "right of the mark" 22} {
    $doc text $label -at [list 105 [expr {$y + $offset}]] -align $align \
        -anchor baseline -direction ltr
}

# -- spacing, scaling, rotation --------------------------------------------

set y [expr {$y + 34}]
$doc font -style bold -size 10
$doc text "Spacing, scaling, position" -at [list 20 $y]
$doc font -style {} -size 11

set y [expr {$y + 8}]
$doc text "normal setting" -at [list 20 $y]
$doc text "letter spaced" -at [list 75 $y] -spacing 0.9
$doc text "word  spaced  wide" -at [list 130 $y] -wordSpacing 3

# The row above sets the four per call. They are font STATE as well: set on
# [font] they stay in force until changed - which is how a whole caption is
# condensed without saying so on every line - and are taken back the same
# way. This row sets them that way.
set y [expr {$y + 9}]
$doc font -stretch 70 -wordSpacing 1
$doc text "condensed to 70 %" -at [list 20 $y]
$doc font -stretch 130 -wordSpacing 0 -spacing 0.3
$doc text "stretched to 130 %" -at [list 75 $y]
$doc font -stretch 100 -spacing 0 -rise 1.6
$doc text "raised" -at [list 130 $y]
$doc font -rise -1.6
$doc text "lowered" -at [list 148 $y]
$doc font -rise 0

# EVERY PIECE STARTS WHERE THE ONE BEFORE IT ENDS, measured rather than
# written down. The subscript used to sit on a fixed 24.6 and the O on a
# fixed 27, which left about a millimetre of air on either side of the 2 -
# "H 2 O" instead of "H2O", visible at 300 dpi. The comment below the
# superscript already said that a fixed x had parked the other 2 on the c;
# the same lesson had simply not been carried up two lines.
set y [expr {$y + 12}]
set x 20
$doc text "H" -at [list $x $y] -size 14
set x [expr {$x + [$doc textWidth "H" -size 14]}]
$doc text "2" -at [list $x $y] -size 9 -rise -1
set x [expr {$x + [$doc textWidth "2" -size 9]}]
$doc text "O and E = mc" -at [list $x $y] -size 14
set x [expr {$x + [$doc textWidth "O and E = mc" -size 14]}]
$doc text "2" -at [list $x $y] -size 9 -rise 3.5
$doc font -family helvetica -size 7
$doc text "subscript and superscript through -rise" -at [list 62 $y]

# A no-break space (U+00A0) between a number and its unit. WinAnsiEncoding
# has it at 0xA0 as a second code for the space glyph (ISO 32000-1 Annex D),
# so the standard fourteen set it - as wide as a space, and still a no-break
# space when the text is extracted.
$doc font -size 11
$doc text "12\u00A0\u20AC and 5\u00A0kg" -at [list 130 $y]
$doc font -size 7
$doc text "no-break space, U+00A0, in Helvetica" -at [list 130 [expr {$y + 4}]]

# The same inside a paragraph. A line never breaks at a no-break space - the
# amount goes to the next line WITH its unit, "the key" ends the second line
# and "5 EUR" opens the third - and a justified line stretches only the word
# spaces: the gap between "34" and its euro sign stays the width of a space
# while the ones around it grow (UAX #14 class GL; ISO 32000-1 9.3.3).
$doc font -size 8
$doc text "The rent is 12\u00A0\u20AC, the deposit 34\u00A0\u20AC and the key\
    5\u00A0\u20AC: an amount keeps its unit at the end of a line, and only the\
    word spaces stretch." -at [list 130 [expr {$y + 10}]] -width 34 -align justify

# -- rotation --------------------------------------------------------------

set y [expr {$y + 16}]
$doc font -family helvetica -style bold -size 10
$doc text "Rotation" -at [list 20 $y]
$doc font -style {} -size 9
foreach angle {0 30 60 90} {
    $doc text "rotated $angle degrees" \
        -at [list [expr {24 + $angle * 1.15}] [expr {$y + 26}]] -rotate $angle
}

# A whole PARAGRAPH turned, not just a line: -width and -rotate together. The
# lines run across the page at the given angle, one leading apart, because the
# advance is applied in the text's own frame rather than down the page - which
# is what makes a side note like this one possible at all.
#
# -90 rather than 90 so that it reads from the top down, the way a note in the
# right-hand margin is set; the lines then step to the LEFT, away from the
# edge.
$doc font -size 7
$doc text "A rotated paragraph in the margin: the column is 40 mm wide,\
    measured along the turned baseline, and the lines step sideways rather\
    than down the page." \
    -at [list 192 [expr {$y - 8}]] -width 40 -rotate -90 -align justify

# -- the symbol font -------------------------------------------------------

set y [expr {$y + 40}]
$doc font -family helvetica -style bold -size 10
$doc text "Symbol and ZapfDingbats" -at [list 20 $y]
$doc font -style {} -size 7
$doc text "Two of the fourteen carry their own encoding. Declaring WinAnsi\
    for them would scramble every glyph, so tclpdf does not." \
    -at [list 20 [expr {$y + 5}]] -width 170

$doc font -family symbol -size 14
$doc text "abgdepsw \326\254\316 \245\243\263" -at [list 20 [expr {$y + 16}]]
$doc font -family zapfdingbats -size 14
$doc text "34567 nopqr" -at [list 100 [expr {$y + 16}]]

# -- measuring with every option the drawing takes -------------------------
#
# [textHeight] and [textLines] take the option list [text] takes, so ONE list
# serves the measurement and the drawing. What only the drawing uses -
# -align, -rotate, -tag - is accepted and changes nothing; -height is
# ignored, because the height of the whole block is what the call answers.
# The list below is deliberately the long one: two indents and a first-line
# indent, paragraph spacing, an avoided shape with a margin, -anchor top, the
# leading and the four glyph options per call, the direction - and the answer
# is exactly what [text] then advances by.
set y [expr {$y + 27}]
$doc font -family helvetica -style bold -size 10
$doc text "Measured before drawing, with the same options" -at [list 20 $y]
set y [expr {$y + 5}]

set note "Measured with the same list the drawing takes: indents on both\
    sides, a first-line indent, room between the paragraphs, a shape the\
    text keeps clear of, and the top edge as the anchor.\n\nThe second\
    paragraph is there for the paragraph spacing to have something to space."
set options [list -width 100 -align justify -anchor top -indent 3 \
    -indentRight 3 -firstIndent 5 -paragraphSpacing 1.5 -leading 9 -tag P \
    -rotate 0 -at [list 20 $y] -avoid [list [list rect [list 20 $y] {16 8}]] \
    -avoidMargin 1.5 -spacing 0.1 -wordSpacing 0.3 -stretch 96 -direction ltr]
$doc font -style {} -size 7
set needed [$doc textHeight $note {*}$options]
set lines [llength [$doc textLines $note {*}$options]]
# -height is ignored by the measurement: the answer is the whole block.
set same [$doc textHeight $note {*}$options -height 5]

$doc rect -at [list 20 $y] -size {16 8} -fill {0.9 0.92 0.95} \
    -stroke {0.7 0.75 0.85} -width 0.2
set below [$doc text $note {*}$options]

# The width of a line, with the options that change it: letter spacing, word
# spacing, horizontal scaling - and the direction, which does not, because a
# line is as wide whichever way it runs.
$doc font -size 7
set plain [$doc textWidth "Crustose lichens"]
set spaced [$doc textWidth "Crustose lichens" -spacing 0.5 -wordSpacing 2]
set narrow [$doc textWidth "Crustose lichens" -stretch 80 -direction ltr]
set y [$doc text "textHeight said [format %.1f $needed] mm ([format %.1f $same]\
    with -height, which it ignores), textLines counted $lines lines, and text\
    advanced by [format %.1f [expr {$below - $y}]] mm." \
    -at [list 128 $y] -width 62 -anchor top -leading 8.5]
$doc text "textWidth: [format %.1f $plain] mm plain, [format %.1f $spaced]\
    with -spacing 0.5 -wordSpacing 2, [format %.1f $narrow] at -stretch 80 -\
    and the same in either -direction." \
    -at [list 128 [expr {$y + 2}]] -width 62 -anchor top -leading 8.5

# The family has to be named here: this page ends with ZapfDingbats selected,
# and a footer inheriting it comes out as a row of symbols - present in the
# file, unreadable on the page and invisible to pdftotext.
exampleFooter $doc helvetica

$doc write $target
puts "  written: $target ([file size $target] bytes)"
$doc destroy
