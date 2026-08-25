#!/usr/bin/env tclsh
#
# tclpdf example 2.15 - vertical writing, the Japanese way down the page
#
#   tclsh examples/02.15-vertical-writing.tcl ?output.pdf?
#
# -direction ttb sets a line that runs DOWNWARDS, in the Identity-V writing
# mode of ISO 32000-2, 9.7.4.3. It is the third value of the option that
# already carries ltr and rtl, because the direction is a property of the
# line and not of the face: the same Noto Sans JP sets the columns on this
# page and the horizontal notes beside them.
#
# THE ONE LINE EVERYONE EXPECTS IT TO BE is the CMap name - Identity-V instead
# of Identity-H in the Type 0 font. That line is written and it is the smaller
# half. The larger half is that THE METRIC IS A DIFFERENT ONE. Horizontally a
# glyph advances by its width, out of hmtx; vertically it advances by its
# HEIGHT and hangs from a vertical origin, and neither number is anywhere in
# hmtx. They live in vhea/vmtx (and, for an OpenType/CFF face, VORG), and PDF
# wants them restated in the CID font as /W2 and /DW2.
#
# What that is worth is on the page: U+3031, the vertical kana repeat mark, is
# 1000 units wide and 2000 units TALL. A vertical line built from the
# horizontal advances puts it in half the room it needs, the glyph below it
# overlaps it, and the file passes qpdf, veraPDF and pdftotext without a word.
#
# AND THE GLYPHS ARE PARTLY OTHER GLYPHS. A bracket, a comma, a full stop and
# an ellipsis have vertical forms - the comma moves from the bottom left of
# its square to the top right, the brackets turn - and a face names them in
# the GSUB feature "vert". They are a lookup, not a rotation: drawing the
# horizontal glyph turned by ninety degrees gives a bracket that leans the
# wrong way. tclpdf applies the feature through the same GSUB machinery the
# ligatures and the Arabic forms use.
#
# WHAT THIS DOES NOT DO, said here rather than left to be discovered. It sets
# ONE column per call. There is no vertical line breaker, no leading between
# columns, no vertical table: -width, -columns and -paginate belong to the
# horizontal block road and are refused with -direction ttb rather than drawn
# into a horizontal paragraph's positions. A page of columns is a loop, and
# the loop is on this page. Pair kerning is off in a vertical line as well -
# the pairs in GPOS "kern" are horizontal, and a face that kerns vertically
# names the feature "vkrn", which this package does not read.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "02.15-vertical-writing.pdf"}]
set fonts [file join $here assets fonts]

set doc [tclpdf new -unit mm]
$doc info Title "Vertical writing"
$doc info Author "tclpdf example 2.15"
$doc page add

# Noto Sans JP is the face in this tree that has vertical metrics - measured,
# its vhea announces 16776 long vertical metrics over 17103 glyphs. A face
# without them is not refused: PDF defines the case and gives it a default of
# one em per glyph, which is what the last block on this page shows.
$doc font embed jp [file join $fonts google NotoSansJP-Regular.ttf]
$doc font embed body [file join $fonts DejaVuSans.ttf]

set y 20
exampleHeading $doc y "Vertical writing"
examplePara $doc y "Everything below the rule is set with one option:\
    -direction ttb. The columns run down the page and, being Japanese, they\
    are placed right to left - which the caller does, one \[text\] call per\
    column, because tclpdf sets one column and does not break a paragraph\
    into several."

# -- the page of columns -----------------------------------------------------
#
# A poem, one column per line, placed from the right. Nothing here is
# arithmetic about the glyphs: the column starts where -at says and the font's
# own vertical advances carry it down.

set poem {
    "秋の田のかりほの庵の苫をあらみ"
    "わが衣手は露にぬれつつ"
    "春過ぎて夏来にけらし白妙の"
    "衣ほすてふ天の香具山"
}

set top [expr {$y + 4}]
set x 175
foreach line $poem {
    $doc text $line -at [list $x $top] -family jp -size 13 -direction ttb
    set x [expr {$x - 9}]
}

# The note beside them, horizontal, in the same face - which is the point of
# the direction being a property of the LINE.
$doc font -family jp -size 8 -color {0.45 0.45 0.5}
$doc text "同じ書体、横書き" -at [list 20 [expr {$top + 6}]]
$doc font -family body -size 9 -color {0.45 0.45 0.5}
$doc text "the same face, set horizontally" -at [list 20 [expr {$top + 11}]]

set y [expr {$top + 80}]

# -- the metric --------------------------------------------------------------

$doc font -family body -size 10 -color {0 0 0}
exampleHeading $doc y "The metric is a different one"
examplePara $doc y "U+3031, the vertical kana repeat mark, is 1000 units wide\
    and 2000 units tall. Below, the same two characters are set once across\
    and once down, both at 14 pt. \[textWidth\] answers the extent ALONG the\
    line in both directions, so it says 28 pt for the row and 42 pt for the\
    column - and the mark takes two cells there, which is what vmtx says and\
    what no reading of hmtx could have told."

set sample "〱日"
# In POINTS, because that is the unit the font size is given in and the one
# the numbers in the paragraph above are quoted in. [textWidth] answers in the
# document unit, which here is the millimetre.
set across [expr {[$doc textWidth $sample -family jp -size 14] * 72 / 25.4}]
set down [expr {[$doc textWidth $sample -family jp -size 14 -direction ttb]
    * 72 / 25.4}]

$doc font -family jp -size 14 -color {0 0 0}
$doc text $sample -at [list 22 [expr {$y + 6}]] -direction ttb
$doc text $sample -at [list 45 [expr {$y + 6}]]

$doc font -family body -size 9 -color {0.45 0.45 0.5}
$doc text [format "down: %.1f pt - across: %.1f pt" $down $across] \
    -at [list 80 [expr {$y + 6}]]
$doc text "the mark takes two cells going down and one going across" \
    -at [list 80 [expr {$y + 11}]]
# The column below is 42 pt long - 14.8 mm - and the heading that follows has
# to clear it. Written as the measurement rather than as a number picked by
# eye, so a change of size or string moves it too.
set y [expr {$y + 13 + $down * 25.4 / 72}]

# -- the glyphs --------------------------------------------------------------

$doc font -family body -size 10 -color {0 0 0}
exampleHeading $doc y "Some of the glyphs are other glyphs"
examplePara $doc y "The same string twice, across and down. The brackets turn,\
    the ideographic comma and full stop move from the bottom left of their\
    square to the top right, and the ellipsis stands up. None of it is a\
    rotation applied by tclpdf - each is a different glyph in the face,\
    reached through the GSUB feature \"vert\"."

set forms "「引用」、…。"
$doc font -family jp -size 14 -color {0 0 0}
$doc text $forms -at [list 22 [expr {$y + 6}]] -direction ttb
$doc text $forms -at [list 45 [expr {$y + 12}]]

$doc font -family body -size 9 -color {0.45 0.45 0.5}
$doc text "down at the left, across beside it" -at [list 95 [expr {$y + 8}]]
$doc text "- same characters, same face" -at [list 95 [expr {$y + 13}]]

# -- the second page ---------------------------------------------------------

$doc page add
set y 20
$doc font -family body -size 10 -color {0 0 0}
exampleHeading $doc y "Where -at sits on the column"
examplePara $doc y "-align says where the given point falls ON the line, and\
    for a vertical line that is its own axis: left begins at -at, right ends\
    there, center is centred on it. The three columns below are drawn at the\
    same y, marked by the rule, and differ only in -align."

set rule [expr {$y + 20}]
$doc line -from [list 18 $rule] -to [list 120 $rule] \
    -stroke {0.75 0.3 0.3} -width 0.2

set x 30
foreach align {left center right} {
    $doc text "縦書き" -at [list $x $rule] -family jp -size 12 \
        -direction ttb -align $align
    $doc font -family body -size 8 -color {0.45 0.45 0.5}
    $doc text $align -at [list [expr {$x - 5}] [expr {$rule + 22}]]
    set x [expr {$x + 22}]
}
set y [expr {$rule + 30}]

# -- a face without vertical metrics -----------------------------------------

$doc font -family body -size 10 -color {0 0 0}
exampleHeading $doc y "A face that has no vertical metric"
examplePara $doc y "DejaVu Sans carries neither vhea nor vmtx, and a vertical\
    line in it is not refused for that. ISO 32000-2 defines the case and gives\
    it a default of one em per glyph, so the letters come out in a column of\
    square cells - which is the only defined answer, and the file then says\
    /DW2 and no /W2 at all, because every glyph in it wants exactly the\
    default."

$doc font -family body -size 13 -color {0 0 0}
$doc text "Bochum" -at [list 25 [expr {$y + 4}]] -direction ttb
$doc font -family body -size 9 -color {0.45 0.45 0.5}
$doc text "one em per glyph, from /DW2" -at [list 40 [expr {$y + 8}]]
set y [expr {$y + 40}]

# -- what is refused ---------------------------------------------------------

$doc font -family body -size 10 -color {0 0 0}
exampleHeading $doc y "What a vertical line will not do"
set blocked "it was accepted, which it should not have been"
try {
    $doc text "日本語の縦書き" -at {20 20} -family jp -size 12 \
        -direction ttb -width 60
} trap {TCLPDF TEXT VERTICAL} {message} {
    set blocked $message
}
set unsuited "it was accepted, which it should not have been"
try {
    $doc text "Bochum" -at {20 20} -family helvetica -size 12 -direction ttb
} trap {TCLPDF FONT VERTICAL} {message} {
    set unsuited $message
}
examplePara $doc y "Both messages below were caught from this very page. The\
    first is the block road: -width breaks lines by width and steps them down\
    by the leading, which is the direction a vertical line already runs in, so\
    it is refused by name rather than drawn. The second is the writing mode\
    itself - it lives in the Type 0 font's CMap, and a standard face is\
    addressed through WinAnsiEncoding, which has none."
examplePara $doc y $blocked {0.55 0.15 0.15}
examplePara $doc y $unsuited {0.55 0.15 0.15}

# -- check it yourself -------------------------------------------------------

$doc font -family body -size 10 -color {0 0 0}
exampleHeading $doc y "Check it yourself"
examplePara $doc y "The first command shows the two Type 0 fonts: one\
    Identity-H and one Identity-V over the SAME descendant, the same\
    descriptor and one embedded font file - the writing mode is a property of\
    the CMap, not a second copy of the face. The second shows /DW2 at the\
    standard's own default and the /W2 entries for the glyphs that differ from\
    it, three numbers each. The third is the one that matters for a reader:\
    the columns have to come back in the order they were written, which is\
    what says the ToUnicode map was not turned round with the glyphs. The\
    fourth renders the page, because a column whose characters are each right\
    and whose spacing is wrong looks correct until it is looked at."
exampleCommandBlock $doc y [list \
    "qpdf --qdf --object-streams=disable [file tail $target] - | grep -B4 Identity-" \
    "qpdf --qdf --object-streams=disable [file tail $target] - | grep -A12 DW2" \
    "pdftotext -f 1 -l 1 [file tail $target] - | sed -n 1,6p" \
    "pdftoppm -f 1 -l 1 -r 150 -png [file tail $target] page"]

# -- a prose text broken into columns ---------------------------------------
#
# The poem above is one column per LINE, because a poem has lines. A prose
# text has none, and until 2026-08-25 the caller had to break it himself:
# [text -width -direction ttb] was refused outright, since the block road
# places its lines DOWN the page and a vertical text needs them placed LEFT.
#
# Breaking and placing are two questions, and the first one is answered now:
# [textLines -direction ttb] returns the columns, with -width read as the
# column HEIGHT - what the breaker asks of a candidate is "how far does this
# reach", and that is answered along whichever axis the text writes. Placing
# them is the loop below, which is also what decides that the columns run
# right to left.

$doc page add
$doc font -family body -size 12 -color {0.20 0.30 0.45}
$doc text "Prose, broken into columns" -at {20 25}
$doc font -size 8 -color {0.40 0.40 0.45}
$doc text "One call breaks it, one loop places it. -width is the column\
    height; the columns come back in reading order and are set from the\
    right. What is deliberately NOT built is the placing - see the manual\
    under \"Vertical writing\" for why half of it would be worse than this\
    loop." -at {20 32} -width 170

set prose "日本語の縦書きでは、行は上から下へ進み、列は右から左へ並びます。\
これは散文の例で、列の高さを指定すると、必要なだけの列に分かれます。"

set columnHeight 90
set columns [$doc textLines $prose -width $columnHeight -family jp -size 12 \
    -direction ttb]

set x 175
foreach column $columns {
    $doc text $column -at [list $x 50] -family jp -size 12 -direction ttb
    set x [expr {$x - 9}]
}

$doc font -family body -size 8 -color {0.45 0.45 0.5}
$doc text "[llength $columns] columns at a column height of $columnHeight mm.\
    The same text at half that height needs\
    [llength [$doc textLines $prose -width [expr {$columnHeight / 2}] \
        -family jp -size 12 -direction ttb]] - which is the measurement that\
    says -width is being read along the writing direction and not across it." \
    -at [list 20 150] -width 170

exampleFooter $doc body

$doc write $target
puts "  written: $target ([file size $target] bytes)"
set info [$doc font info jp]
puts "  \"jp\": [dict get $info glyphs] glyphs, vertical metrics:\
    [expr {[dict get $info vertical] ? {yes} : {no}}]"
puts "  \"body\": vertical metrics:\
    [expr {[dict get [$doc font info body] vertical] ? {yes} : {no}}]"
puts "  [format {%s down, %.1f pt - across, %.1f pt} $sample $down $across]"
$doc destroy
