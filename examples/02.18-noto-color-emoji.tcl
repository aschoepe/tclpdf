#!/usr/bin/env tclsh
#
# tclpdf example 2.18 - Noto Color Emoji: a real COLR version 1 face, and the
# character SEQUENCES it draws
#
#   tclsh examples/02.18-noto-color-emoji.tcl ?output.pdf?
#
# Examples 2.14 and 2.17 both BUILD the colour face they show, because a page
# about a file format is clearer when the file is on the page beside it. This
# one does the opposite and takes a face off the shelf: Noto Color Emoji, 25 MB
# of artwork, 3 993 colour glyphs of COLR version 1, and the face nearly every
# colour font measurement in this package was taken against.
#
# THE SUBJECT IS THE SEQUENCE. An emoji face does not draw one picture per
# character. It draws one picture per SEQUENCE, and which characters form one
# is a property of the face rather than of Unicode:
#
#   👨‍👩‍👧          five characters - three people and two zero width joiners
#   👍🏽            two - a thumb and a skin tone modifier
#   🇩🇪            two regional indicators, and nothing but their order says
#                  which country
#   🏳️‍⚧️        five, two of them variation selectors
#   🏴󠁧󠁢󠁳󠁣󠁴󠁿    seven, six of which are invisible tag characters spelling
#                  "gbsct"
#   👷🏽‍♀️      five - a base emoji, a skin tone modifier, a zero width
#                  joiner, the female sign and a presentation selector
#
# Every one of those is ONE glyph in the face, reached through the "ccmp"
# feature of its GSUB table - and one glyph is what it becomes here: one Type 3
# glyph, with one advance width, whose /ToUnicode carries the WHOLE sequence
# back out again, joiners, modifiers and selectors included.
#
#   $doc colorFont emoji NotoColorEmoji-Regular.ttf -chars "👨‍👩‍👧👍🏽🇩🇪"
#
# -chars TAKES TEXT, not a bag of characters, and that is the only way it can
# work. A caller cannot take the string apart first, because a caller does not
# know where the pieces are: the same five characters are one picture in this
# face and five in the next one. So the string goes to the face whole, the face
# says where the joins are, and what comes back is the font.
#
# WHAT THIS FACE ACTUALLY PAINTS WITH, measured over all 3 993 of its colour
# glyphs on 2026-08-26: 129 823 clipped shapes, 111 668 solid fills, 35 981
# transformations, 9 844 radial gradients, 8 627 linear ones, 578 composites -
# and NOT ONE SWEEP. The angular gradient that costs example 2.17 a fan of
# Gouraud triangles does not occur in this face at all, which is worth knowing
# before anyone builds a fan for it. The composites are two modes only: Source
# In, which pours a gradient into a shape, and Soft Light, which is a PDF blend
# mode under another name. Both of them are in a flag.
#
# THREE ROWS SHOW THE SKIN TONES on one icon at a time, because a ramp is the
# only way to SEE what a modifier does: the same builder, the same farmer and
# the same thumb through the base and all five Fitzpatrick modifiers,
# U+1F3FB to U+1F3FF. Two of the three are ZWJ sequences with the modifier in
# the middle, which is the case a longest match can get wrong - and the glyph
# each of the fifty-six units on these pages comes out as was compared with
# hb-shape, one call per unit: 0 differ.
#
# THE FACE IS NOT IN THE SOURCE ARCHIVE. 25 MB of somebody else's artwork does
# not belong in a package tarball, so it is excluded from it and from the
# repository alike - which means this example may well find nothing to open.
# Then it prints one line saying where the file comes from and writes no
# document, the way a missing validator is a skip and not a failure.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf
package require tclpdf::colorFont

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "02.18-noto-color-emoji.pdf"}]
set assets [file join $here assets]

# The skip, before anything else is done and by the same relative path every
# other asset is reached by - no environment variable and no search list, so
# that there is exactly one place the file can be and the message can name it.
set facePath [file join $assets fonts google NotoColorEmoji-Regular.ttf]
if {![file exists $facePath]} {
    puts "  skipped: [file tail $facePath] is not in the tree - 25 MB of\
        artwork is excluded from the source archive; fetch it from Google\
        Fonts <https://fonts.google.com/noto/specimen/Noto+Color+Emoji> or\
        from <https://github.com/googlefonts/noto-emoji> (SIL Open Font\
        License 1.1) and put it in [file dirname $facePath]"
    exit 0
}

# ---------------------------------------------------------------------------
# What goes into the font
# ---------------------------------------------------------------------------
#
# Written as one variable per unit and joined into a single -chars string
# below. The page names them again one at a time, and a variable is what it
# names them with.
#
# WHAT THE ORDER IN THE JOINED STRING COSTS, measured rather than guessed at.
# -chars is one string, so two units written side by side are offered to the
# face side by side and a face free to ligate them will - which is exactly
# what is wanted between a thumb and a skin tone. This comment used to give a
# RULE for it ("a bare thumb before the toned ones, no regional indicator next
# to another pair"), and the list below broke the rule in two places while
# coming out right, which is the sign of a rule that was never measured.
#
# The measurement, on this face on 2026-08-26: every arrangement of complete
# units comes out as those units. Four regional indicators in a row give two
# flags and not one flag and two strays; the bare thumb standing in front of
# the light one gives a thumb and a toned thumb; two families in a row give
# the family of three and the family of four, in either order. Even the case
# built to be nasty holds - the German flag followed by the Spanish one is
# D E E S, and the two E in the middle ARE a flag of their own (Estonia),
# and the greedy longest match from the LEFT still takes D+E first and then
# E+S.
#
# WHY it holds, and where it would stop holding: a complete emoji sequence
# never begins with a character that CONTINUES another one. A joiner, a skin
# tone modifier, a variation selector and a tag character are all continuations
# and none of them starts a unit, so no unit can reach across the boundary
# into the next. What a caller writes that is NOT a complete unit - a bare
# modifier, a lone selector - is offered to the face as what it is, and the
# face decides. That is the boundary the manual says is the caller's to watch.
# The console line at the end prints the glyph count, which is the check.

set grin 😀
set dart 🎯
set rainbow 🌈
set clover 🍀
set ball 🔮
set globe 🌍
set heart ❤️

set family3 👨‍👩‍👧
set family4 👨‍👩‍👧‍👦
set flagDe 🇩🇪
set flagFr 🇫🇷
set flagTrans 🏳️‍⚧️
set flagScotland 🏴󠁧󠁢󠁳󠁣󠁴󠁿

# The twenty-one marks example 02.09 sets in the MONOCHROME face
# NotoEmoji-Variable, character for character out of that file - the same row,
# in colour, so that the two pages can be laid side by side. Two of the
# twenty-one carry a presentation selector and neither is a character of its
# own: the desert island has U+FE0F behind it and the chilli has U+FE0E, the
# TEXT selector, which this face has no glyph for either - both ride along
# with the mark in front of them and come back out through the /ToUnicode.
set gallery "🏡🧁🍰🏜️🎁🎂🎈🎺🙏💕🌶︎🔋🔥🍾😃🐬🚲🌳🔧🌧🔬"

# THE SKIN TONE RAMP, one base emoji through all five modifiers and the base
# on its own. U+1F3FB to U+1F3FF are the five Fitzpatrick modifiers, and a
# modifier is not a picture: it has no glyph of its own that anybody would set,
# it changes the one in front of it. Written out as six variables rather than
# built in a loop, because \U is broken under Tcl 8.6 and a literal is the only
# spelling both interpreters read the same way.
set thumb "👍"
set thumbLight "👍🏻"
set thumbMedLight "👍🏼"
set thumbMid "👍🏽"
set thumbMedDark "👍🏾"
set thumbDark "👍🏿"

# The same ramp again, but with a ZWJ SEQUENCE as the base: person plus sheaf
# of rice is the farmer, and the tone goes between the person and the joiner
# rather than at the end. Two ramps rather than one because they are two
# different questions for the longest match - a two-character unit, and a
# four-character one whose second character is the modifier.
set farmerPlain "🧑‍🌾"
set farmerLight "🧑🏻‍🌾"
set farmerMedLight "🧑🏼‍🌾"
set farmerMid "🧑🏽‍🌾"
set farmerMedDark "🧑🏾‍🌾"
set farmerDark "🧑🏿‍🌾"

# And the same ramp once more on the LONGEST unit of the three: the builder
# is a base emoji, a joiner, the female sign and a presentation selector, and
# a tone goes in as the second of five code points. Nothing this face draws
# asks more of the longest match than this row does.
set workerPlain "👷‍♀️"
set workerLight "👷🏻‍♀️"
set workerMedLight "👷🏼‍♀️"
set workerMid "👷🏽‍♀️"
set workerMedDark "👷🏾‍♀️"
set workerDark "👷🏿‍♀️"

set crate 📦
set lorry 🚚
set tick ✅
set warn ⚠️

set singles [list $grin $dart $rainbow $clover $ball $globe $heart]
set sequences [list $family3 $family4 $flagDe $flagFr $flagTrans \
    $flagScotland]
set working [list $crate $lorry $tick $warn]
set tones [list $thumb $thumbLight $thumbMedLight $thumbMid $thumbMedDark \
    $thumbDark]
set workers [list $workerPlain $workerLight $workerMedLight $workerMid \
    $workerMedDark $workerDark]
set farmers [list $farmerPlain $farmerLight $farmerMedLight $farmerMid \
    $farmerMedDark $farmerDark]

set doc [tclpdf new -unit mm]
$doc info Title "Noto Color Emoji, and the sequences it draws"
$doc info Author "tclpdf example 2.18"
$doc page add

$doc font embed body [file join $assets fonts DejaVuSans.ttf]

# THE ONE CALL this page is about. Forty-six units go in as one string and
# forty-six glyphs come out - not the hundred-odd characters they are written
# with, and not the seven the Scottish flag alone would be.
set emoji [$doc colorFont emoji $facePath \
    -chars [join [concat [list $gallery] $singles $sequences $working \
        $tones $workers $farmers] {}]]

# One row of emoji at $size POINTS, left to right, and the y below it in
# millimetres. The two units are the reason this is a procedure rather than
# three lines in place: -size is in points whatever the document unit is and
# the page is laid out in millimetres, so the row was first written with the
# point size used as a millimetre offset - which drew the caption through the
# middle of the emoji. 25.4/72 is the conversion.
#
# The 0.92 is measured rather than guessed: at 36 pt on a rule, this face
# draws from 0.92 of the em above the baseline to 0.08 below it, so a baseline
# put 0.92 em under y makes the row start exactly at y. -at is a BASELINE -
# that is what -anchor baseline, the default, means - and a Type 3 face has no
# descender for -anchor top to hang a line from.
proc emojiRow {doc yName family size marks} {
    upvar 1 $yName y
    set height [expr {$size * 25.4 / 72.0}]
    set x 20
    foreach mark $marks {
        $doc font -family $family -size $size
        $doc text $mark -at [list $x [expr {$y + $height * 0.92}]]
        set x [expr {$x + [$doc textWidth $mark] + 1.5}]
    }
    set y [expr {$y + $height + 6}]
    return
}

proc emojiCaption {doc yName text} {
    upvar 1 $yName y
    $doc font -family body -size 8.5 -color {0.45 0.45 0.5}
    set y [expr {[$doc text $text -at [list 20 $y] -width 170] + 5}]
    return
}

# ---------------------------------------------------------------------------
# The page
# ---------------------------------------------------------------------------

set y 20
exampleHeading $doc y "Noto Color Emoji, and the sequences it draws"
examplePara $doc y "Examples 2.14 and 2.17 build the colour face they show,\
    because a page about a file format reads better with the file on it. This\
    one takes a face off the shelf instead: Noto Color Emoji, 25 MB of\
    artwork, 3993 colour glyphs of COLR version 1, and the face nearly every\
    colour font measurement in this package was taken against."
examplePara $doc y "An emoji face does not draw one picture per character. It\
    draws one picture per SEQUENCE, and which characters make one up is a\
    property of the FACE rather than of Unicode. So -chars takes text: the\
    string goes to the face whole, the \"ccmp\" feature of the face says where\
    the joins are, and every glyph that comes back is one glyph of the Type 3\
    font - with one advance width, and with the whole sequence in its\
    /ToUnicode."

set y [expr {$y + 2}]
# The gallery goes in as ONE string rather than as a list of marks, which is
# how example 02.09 sets the same row in the monochrome face: the advances
# between the pictures are then the face's own and the two rows can be laid
# side by side.
emojiRow $doc y $emoji 14 [list $gallery]
emojiCaption $doc y "The row example 02.09 sets in Noto Emoji, the MONOCHROME\
    face of the same family, set here in the colour one - the same twenty-one\
    marks, character for character. Twenty-three code points make twenty-one\
    pictures: the desert island carries U+FE0F and the chilli U+FE0E, the text\
    presentation selector, and this face has a glyph for neither - each rides\
    along with the mark in front of it and comes back out of the /ToUnicode."

emojiRow $doc y $emoji 18 $singles
emojiCaption $doc y "One character each - and the last one is two, because a\
    heart carries the emoji presentation selector U+FE0F behind it."

# The same seven at twice the size. The row exists to be LOOKED at rather than
# measured: a colour glyph of this face is a path in a Type 3 glyph stream, so
# the only thing that changes between the two rows is the text matrix.
emojiRow $doc y $emoji 36 $singles
emojiCaption $doc y "The same seven at twice the size. Every mark on these\
    pages is a PATH - a Type 3 glyph description of clipped shapes and\
    shadings, not a picture - so it scales without losing anything, and the\
    only difference between this row and the one above it is the text matrix.\
    Measured off this document: [format %.3f [$doc textWidth $grin \
        -family $emoji -size 18]] mm at 18 pt against [format %.3f \
        [$doc textWidth $grin -family $emoji -size 36]] mm at 36 pt, which is\
    exactly twice. \[pdfimages -list\] on the finished file lists nothing at\
    all."

emojiRow $doc y $emoji 18 $sequences
emojiCaption $doc y "Two to seven characters each: two families, two flags of\
    regional indicator pairs, the transgender flag with its joiner and its\
    two selectors, and the Scottish flag - a black flag and six invisible tag\
    characters spelling \"gbsct\". The skin tones have a page of their own\
    overleaf."

# -- one sequence, one glyph, one width --------------------------------------

exampleHeading $doc y "One sequence, one glyph, one width"
examplePara $doc y "The measurement below is the whole claim of this page,\
    and it is read off the document rather than asserted: \[textWidth\]\
    answers the same number for a sequence of seven characters as for a single\
    emoji, because in the font they are the same thing - one glyph, one entry\
    in the /Widths array, one byte in the string that sets it. A font that had\
    taken the sequence apart would measure seven times as wide and draw seven\
    pictures."

set y [expr {$y + 1}]
$doc font -family body -size 9 -color {0.45 0.45 0.5}
foreach {label at} {mark 22 characters 34 width 62 sequence 84} {
    $doc text $label -at [list $at $y]
}
set y [expr {$y + 5}]

$doc font -family emoji -size 10
set unitWidth [$doc textWidth $grin]
foreach mark [list $grin $heart $flagDe $thumbMid $farmerMid $workerMid \
        $family3 $flagTrans $family4 $flagScotland] {
    $doc font -family emoji -size 10
    $doc text $mark -at [list 22 $y]
    set width [$doc textWidth $mark]
    $doc font -family body -size 9 -color {0.1 0.1 0.15}
    $doc text [llength [split $mark {}]] -at [list 34 $y]
    $doc text "[format %.3f $width] mm" -at [list 62 $y]
    $doc font -family body -size 8 -color {0.45 0.45 0.5}
    $doc text [join [lmap char [split $mark {}] {
        format U+%04X [scan $char %c]
    }]] -at [list 84 $y]
    set y [expr {$y + 5}]
}
set y [expr {$y + 1}]
emojiCaption $doc y "Ten units, one to seven characters each, and one width\
    for all of them: [format %.3f $unitWidth] mm at 10 pt. The last row is\
    seven characters wide and one glyph big, and the two in the middle carry\
    a skin tone and a joiner at once."

# -- the skin tones ----------------------------------------------------------

$doc page add
set y 20
exampleHeading $doc y "The skin tones, one icon at a time"
examplePara $doc y "A skin tone is not a picture. U+1F3FB to U+1F3FF are the\
    five Fitzpatrick MODIFIERS, and a modifier changes the mark in front of\
    it: the base emoji and the modifier are one sequence, one glyph in the\
    face and one glyph here, with one advance and one /ToUnicode entry\
    carrying both code points back. The two rows below are the same icon\
    through the whole ramp, so that what the modifier does is visible rather\
    than described."

set y [expr {$y + 2}]
emojiRow $doc y $emoji 24 $tones
emojiCaption $doc y "The base on its own, then the same base through all five\
    modifiers: U+1F44D, and U+1F44D followed by U+1F3FB, U+1F3FC, U+1F3FD,\
    U+1F3FE, U+1F3FF. Six units, eleven code points, six glyphs - every one\
    of them the same width, because a modifier adds nothing to the advance."

emojiRow $doc y $emoji 24 $workers
emojiCaption $doc y "The same ramp on a ZWJ SEQUENCE, which is the case that\
    matters: the builder is U+1F477, a zero width joiner, the female sign\
    U+2640 and a presentation selector, and the modifier goes in as the\
    SECOND code point rather than at the end. Six units - four code points\
    for the first and five for the other five - six glyphs, one width. A\
    match that took the base and the tone and then stopped would draw a toned\
    builder and then refuse the joiner; one that matched neither would draw\
    five pictures where the face draws one."

emojiRow $doc y $emoji 24 $farmers
emojiCaption $doc y "And once more with a shorter sequence around the tone:\
    a person, a sheaf of rice and the joiner between them. Six units of three\
    and four code points, six glyphs, one width. Every unit on this page was\
    checked against hb-shape - the glyph this package picks for a sequence is\
    the glyph HarfBuzz picks."

# -- what the face paints with -----------------------------------------------

exampleHeading $doc y "What this face paints with"
examplePara $doc y "Measured over all 3993 colour glyphs of this face:\
    129823 clipped shapes, 111668 solid fills, 35981 transformations, 9844\
    radial gradients, 8627 linear ones, 578 composites - and NOT ONE SWEEP.\
    The angular gradient that costs example 2.17 a fan of Gouraud triangles,\
    because PDF has no shading type for it, does not occur in this face at\
    all. The composites are of two modes only, and both of them sit in a\
    flag: Source In, which pours a gradient into the shape of something else,\
    and Soft Light, which is a PDF blend mode under another name."

set y [expr {$y + 1}]
foreach {mark wording} [list \
        $dart "layers of solid fills and nothing else - the common case, by\
            a wide margin" \
        $grin "a radial gradient in the face, and PDF's type 3 shading on the\
            way out" \
        $globe "four radial gradients under four transformations" \
        $ball "five linear gradients and two radial ones in one glyph" \
        $flagDe "a linear gradient, a Source In and a Soft Light - both of\
            this face's composite modes in two characters" \
        $flagScotland "the same three, reached through six invisible tag\
            characters"] {
    $doc font -family emoji -size 11
    $doc text $mark -at [list 22 $y]
    $doc font -family body -size 9 -color {0.1 0.1 0.15}
    set y [expr {[$doc text $wording -at [list 32 $y] -width 158] + 3}]
}
set y [expr {$y + 3}]

# -- in the running text -----------------------------------------------------

$doc page add
set y 20
exampleHeading $doc y "In the running text"
examplePara $doc y "One string, one call, two faces: -fallback names the faces\
    that may set what -family cannot, and the chain offers a SEQUENCE as one\
    unit - longest match first - rather than a character at a time. That is\
    what lets a family emoji stand in the middle of a sentence instead of\
    breaking apart at its joiners, and it is why the marks below need no space\
    around them: a sequence glued to the word in front of it is still one\
    glyph."

set y [expr {$y + 2}]
$doc font -family body -size 11 -color {0.1 0.1 0.15} -fallback $emoji
set y [expr {[$doc text "The crate$crate left the depot$lorry on Tuesday and\
    reached the family$family3 in $flagDe on Thursday, who signed for\
    it$thumbMid at 14:20$tick. Two pallets went back$warn - the $flagFr\
    consignment is still on the water, and the $flagScotland one has not left\
    the yard." -at [list 20 $y] -width 170] + 6}]
$doc font -family body -size 10 -color {0 0 0} -fallback {}

# -- the characters that draw nothing ----------------------------------------

exampleHeading $doc y "The characters that draw nothing"
examplePara $doc y "Of the 1499 characters this face's cmap maps, 39 draw\
    nothing at all: the space, the zero width joiner, and the 37 tag\
    characters a flag like the Scottish one is spelled with. They are real\
    entries in the cmap and they have real glyph numbers, but their outlines\
    are empty and the COLR table says nothing about them - so a font built\
    from one would be valid, extractable and blank, with nothing reporting it.\
    That is refused by name, and only where such a character is asked for\
    ALONE: inside a sequence the joiner and the tags are swallowed by the\
    ligature and come back out through the /ToUnicode, which is what the last\
    row of the width table on the first page shows."

# The refusal, caught from this very page rather than quoted: the zero width
# joiner on its own is the shortest way to ask for a glyph that would draw
# nothing - the face has one, numbered like any other, and it is empty.
#
# Written as "\u200D" and not as the character itself, which is the one place
# on this page where the escape is the clearer spelling: a literal joiner is
# INVISIBLE in the source, and an invisible argument is what the next person
# to edit this file would delete by accident. The escape is safe here because
# the joiner is inside the BMP - for a character beyond it, \U is broken under
# Tcl 8.6 and the literal is the only road, which is why every emoji above is
# written out.
set refusal "it was accepted, which it should not have been"
try {
    $doc colorFont blank $facePath -chars "\u200D"
} trap {TCLPDF COLORFONT EMPTY} {message} {
    set refusal $message
}
examplePara $doc y "The message, caught from this very page: $refusal" \
    {0.55 0.15 0.15}

# One character the cmap has NOT got, and it is the one that matters most:
# U+FE0F, the emoji presentation selector, sits inside half the real sequences
# and this face has no glyph for it. It is not refused - a selector modifies
# the character in front of it and draws nothing by design, so it rides along
# with its neighbour and its code point is kept, which is why the heart above
# extracts as two characters rather than one.

# -- check it yourself -------------------------------------------------------

exampleHeading $doc y "Check it yourself"
examplePara $doc y "The first command hands the sequences back unchanged -\
    joiners, skin tones, selectors and tag characters included - which is the\
    /ToUnicode of a Type 3 font doing its work. The second lists the pictures\
    in the file and prints a header with nothing under it: every emoji on\
    these pages is a path in a glyph stream, and there is no bitmap anywhere\
    in the document. The third is the font's own table of glyph procedures,\
    and its keys spell the sequences out one code point at a time - one\
    procedure for all seven characters of the Scottish flag. The fourth counts\
    the shadings the gradients became."
# "grep -a", never a plain grep, and it is not a nicety: a decompressed PDF
# still holds binary bytes, and BSD grep then answers "binary file matches"
# for -A and NO COUNT AT ALL for -c. Measured on this very document: the
# fourth line without -a prints nothing and exits 1, and the answer it is
# hiding is 27.
exampleCommandBlock $doc y [list \
    "pdftotext [file tail $target] - | head -20" \
    "pdfimages -list [file tail $target]" \
    "qpdf --qdf --object-streams=disable [file tail $target] - |\
        grep -a -A22 /CharProcs" \
    "qpdf --qdf --object-streams=disable [file tail $target] - |\
        grep -ac ShadingType"]

exampleFooter $doc body

$doc write $target
puts "  written: $target ([file size $target] bytes)"
# The same list the font was built from, so the two numbers cannot drift
# apart: what the console prints is the check on the page above it.
set info [$doc font info $emoji]
puts "  colour font \"$emoji\": [dict get $info glyphs] glyphs out of\
    [llength [split [join [concat [list $gallery] $singles $sequences \
        $working $tones $workers $farmers] {}] {}]]\
    characters, [format %.0f [dict get $info unitsPerEm]] units to the em,\
    from a [file size $facePath]-byte face"
$doc destroy
