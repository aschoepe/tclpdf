#!/usr/bin/env tclsh
#
# tclpdf example 2.18 - two colour emoji faces, and the character SEQUENCES
# they draw: Noto Color Emoji (COLR version 1, paths) and Apple Color Emoji
# (sbix, pictures)
#
#   tclsh examples/02.18-noto-color-emoji.tcl ?output.pdf?
#
# THE SAME DOCUMENT TWICE, out of ONE procedure. Examples 2.14 and 2.17 both
# BUILD the colour face they show, because a page about a file format is
# clearer when the file is on the page beside it. This one does the opposite
# and takes two faces off the shelf - and sets the same three pages from both,
# the same rows, the same equations, the same measurements, so that what
# differs is the FACE and nothing else:
#
#   02.18-noto-color-emoji.pdf    Noto Color Emoji, 25 MB, 3993 colour glyphs
#                                 of COLR version 1 - every mark on the page
#                                 is a PATH in a Type 3 glyph description
#   02.18-apple-color-emoji.pdf   Apple Color Emoji, 192 MB, 3844 glyphs whose
#                                 pictures are PNG files in an "sbix" table -
#                                 every mark is an image XObject
#
# Either half skips itself where its face is not on the machine, the way a
# missing validator is a skip and not a failure: Noto's 25 MB of artwork are
# excluded from the source archive, and Apple's face exists on macOS and
# nowhere else. So this script writes two documents, one, or none.
#
# THE SUBJECT IS THE SEQUENCE. An emoji face does not draw one picture per
# character. It draws one picture per SEQUENCE, and which characters form one
# is a property of the face rather than of Unicode:
#
#   family        five characters - three people and two zero width joiners
#   thumb+tone    two - a thumb and a skin tone modifier
#   flag          two regional indicators, and nothing but their order says
#                 which country
#   trans flag    five, two of them variation selectors
#   Scottish flag seven, six of which are invisible tag characters spelling
#                 "gbsct"
#   builder+tone  five - a base emoji, a skin tone modifier, a zero width
#                 joiner, the female sign and a presentation selector
#
# Every one of those is ONE glyph in either face, and one glyph is what it
# becomes here: one Type 3 glyph, with one advance width, whose /ToUnicode
# carries the WHOLE sequence back out again.
#
#   $doc colorFont emoji NotoColorEmoji-Regular.ttf -chars "..."
#
# -chars TAKES TEXT, not a bag of characters, and that is the only way it can
# work. A caller cannot take the string apart first, because a caller does not
# know where the pieces are: the same five characters are one picture in this
# face and five in the next one. So the string goes to the face whole, the
# face says where the joins are, and what comes back is the font.
#
# WHERE THE JOINS COME FROM IS NOT THE SAME QUESTION IN THE TWO FACES, and
# that is the reason both are here. Noto is an OpenType face: its sequences
# are ligatures under the "ccmp" feature of GSUB, and gsubApply.tcl applies
# them. Apple's face has NO GSUB AT ALL. What joins a thumb to a skin tone
# there is "morx", Apple's extended glyph metamorphosis table - a chain of
# finite state machines, 475 KB of them, with 25 subtables of which 16 are on
# by default. morx.tcl runs them, and the glyph it picks for every unit on
# these pages was compared with hb-shape, one call per unit: 0 differ, over
# the 61 units of this document and 3196 further sequences the two faces have
# in common.
#
# WHAT THE APPLE FACE IS, measured 2026-08-26: 192 123 488 bytes, a TrueType
# COLLECTION of two faces that share their tables, unitsPerEm 800, 3844
# glyphs, OS/2 fsType 4 (preview and print embedding). Its "sbix" table is
# 191 134 508 of those bytes - 99.5 % of the file - and holds a PNG per glyph
# at nine sizes: 20, 26, 32, 40, 48, 52, 64, 96 and 160 pixels to the em. So
# the face is never read whole: [colorFont] opens it, reads the table
# directory and the 757 KB that are not pictures, and takes the sixty-odd PNGs
# it needs out of the file by range. Measured on this document: 0.7 s and
# 50 MB of memory, against 13.2 s and 4.3 GB for a naive read.
#
# THE PDF THEREFORE CARRIES APPLE'S BITMAPS, one image XObject per glyph, each
# with the alpha channel of the PNG as its /SMask. That is a licence question
# rather than a technical one and the file answers it itself: fsType 4 is
# "preview and print embedding", which is what this is.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf
package require tclpdf::colorFont

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "02.18-noto-color-emoji.pdf"}]
set assets [file join $here assets]

# The two faces, and the two documents. The Apple document is written BESIDE
# the one that was asked for, under the name of its own face - so that
# [make examples] collects both and the caller who named an output file gets
# the one they named.
set notoPath [file join $assets fonts google NotoColorEmoji-Regular.ttf]
set applePath "/System/Library/Fonts/Apple Color Emoji.ttc"
set appleTarget [file join [file dirname $target] 02.18-apple-color-emoji.pdf]
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

# THE PARTS ON THEIR OWN, for the equation under each ramp: the modifier by
# itself (this face draws it as a swatch of the tone), the bare builder, the
# female sign with its presentation selector, the bare person and the sheaf.
# Each is a unit of its own here; joined, they are the sequences above.
set toneMid "🏽"
set builder "👷"
set female "♀️"
set person "🧑"
set sheaf "🌾"
set parts [list $toneMid $builder $female $person $sheaf]

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

# ---------------------------------------------------------------------------
# The three drawing procedures
# ---------------------------------------------------------------------------

# One row of emoji at $size POINTS, left to right, and the y below it in
# millimetres. The two units are the reason this is a procedure rather than
# three lines in place: -size is in points whatever the document unit is and
# the page is laid out in millimetres, so the row was first written with the
# point size used as a millimetre offset - which drew the caption through the
# middle of the emoji. 25.4/72 is the conversion.
#
# ASCENT IS HOW FAR THE FACE DRAWS ABOVE THE BASELINE, as a fraction of the
# em, and it is a parameter because the two faces differ: measured at 36 pt on
# a rule, Noto draws from 0.92 of the em above the baseline to 0.08 below it,
# while an Apple bitmap fills the em box exactly - its bottom edge is ON the
# baseline and its top is a whole em above. So a baseline put that fraction of
# an em under y makes the row start exactly at y in either face. -at is a
# BASELINE - that is what -anchor baseline, the default, means - and a Type 3
# face has no descender for -anchor top to hang a line from.
proc emojiRow {doc yName family ascent size marks} {
    upvar 1 $yName y
    set height [expr {$size * 25.4 / 72.0}]
    set x 20
    foreach mark $marks {
        $doc font -family $family -size $size
        $doc text $mark -at [list $x [expr {$y + $height * $ascent}]]
        set x [expr {$x + [$doc textWidth $mark] + 1.5}]
    }
    set y [expr {$y + $height + 6}]
    return
}

# One equation under a ramp: the parts of a sequence, a plus sign between
# them, an equals sign, and the sequence - "base + tone = toned base". The
# signs are set in the body face at the same y, so the reader sees what the
# face was handed and what it drew for it; a viewer that re-sets the text from
# its code points shows the left side twice and never the right.
proc emojiEquation {doc yName family ascent size parts result} {
    upvar 1 $yName y
    set height [expr {$size * 25.4 / 72.0}]
    set y [expr {$y + 1}]
    set baseline [expr {$y + $height * $ascent}]
    set x 20
    set first 1
    foreach part $parts {
        if {!$first} {
            $doc font -family body -size [expr {$size * 0.75}] -color {0.45 0.45 0.5}
            $doc text "+" -at [list $x $baseline]
            set x [expr {$x + [$doc textWidth "+"] + 2}]
        }
        set first 0
        $doc font -family $family -size $size
        $doc text $part -at [list $x $baseline]
        set x [expr {$x + [$doc textWidth $part] + 2}]
    }
    $doc font -family body -size [expr {$size * 0.75}] -color {0.45 0.45 0.5}
    $doc text "=" -at [list $x $baseline]
    set x [expr {$x + [$doc textWidth "="] + 2}]
    $doc font -family $family -size $size
    $doc text $result -at [list $x $baseline]
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
# The document - ONE procedure, run twice
# ---------------------------------------------------------------------------
#
# KIND is "noto" or "apple", and it decides four things and no more: what the
# pages are CALLED, which numbers the prose states, how far above the baseline
# the face draws, and what the last page tells the reader to check. Everything
# else - the rows, the equations, the width table, the running text, the
# refusal caught from the page itself - is written once and set from both
# faces. Copying the pages would have been shorter to write and would have
# drifted apart at the first correction.
proc emojiDocument {kind facePath target} {
    global assets gallery singles sequences working tones workers farmers
    global parts grin dart rainbow clover ball globe heart
    global family3 family4 flagDe flagFr flagTrans flagScotland
    global thumb toneMid builder female person sheaf
    global thumbMid farmerMid workerMid crate lorry tick warn

    # The face's own name, and how far up it draws - see [emojiRow].
    if {$kind eq "apple"} {
        set faceName "Apple Color Emoji"
        set ascent 1.0
    } else {
        set faceName "Noto Color Emoji"
        set ascent 0.92
    }

    set doc [tclpdf new -unit mm]
    $doc info Title "$faceName, and the sequences it draws"
    $doc info Author "tclpdf example 2.18"
    $doc page add

    $doc font embed body [file join $assets fonts DejaVuSans.ttf]

    # THE ONE CALL these pages are about. Sixty-one units go in as one string
    # and sixty-one glyphs come out - not the hundred-odd characters they are
    # written with, and not the seven the Scottish flag alone would be. The
    # call is the SAME for both faces: -face 0 is the default and names the
    # first face of a TrueType collection, which is what the Apple file is.
    set emoji [$doc colorFont emoji $facePath \
        -chars [join [concat [list $gallery] $singles $sequences $working \
            $tones $workers $farmers $parts] {}]]

    # -- the first page ------------------------------------------------------

    set y 20
    exampleHeading $doc y "$faceName, and the sequences it draws"
    if {$kind eq "apple"} {
        examplePara $doc y "Apple Color Emoji is 192 MB, a TrueType\
            COLLECTION of two faces that share their tables, and 99.5 per\
            cent of it is one table: \"sbix\", a PNG file per glyph at nine\
            sizes from 20 to 160 pixels to the em. So every mark on these\
            pages is a PICTURE - an image XObject placed by a Type 3 glyph\
            description, with the alpha channel of the PNG as its soft mask.\
            The page overleaf is the same page in Noto Color Emoji, where\
            every mark is a path."
        examplePara $doc y "An emoji face does not draw one picture per\
            character. It draws one picture per SEQUENCE, and which\
            characters make one up is a property of the FACE rather than of\
            Unicode. This face has no GSUB table at all: what joins a thumb\
            to a skin tone is \"morx\", a chain of finite state machines, and\
            every glyph it picks was compared with hb-shape - one call per\
            unit, 0 differ."
    } else {
        examplePara $doc y "Examples 2.14 and 2.17 build the colour face they\
            show, because a page about a file format reads better with the\
            file on it. This one takes a face off the shelf instead: Noto\
            Color Emoji, 25 MB of artwork, 3993 colour glyphs of COLR version\
            1, and the face nearly every colour font measurement in this\
            package was taken against."
        examplePara $doc y "An emoji face does not draw one picture per\
            character. It draws one picture per SEQUENCE, and which\
            characters make one up is a property of the FACE rather than of\
            Unicode. So -chars takes text: the string goes to the face whole,\
            the \"ccmp\" feature of the face says where the joins are, and\
            every glyph that comes back is one glyph of the Type 3 font -\
            with one advance width, and with the whole sequence in its\
            /ToUnicode."
    }

    set y [expr {$y + 2}]
    # The gallery goes in as ONE string rather than as a list of marks, which
    # is how example 02.09 sets the same row in the monochrome face: the
    # advances between the pictures are then the face's own and the two rows
    # can be laid side by side.
    emojiRow $doc y $emoji $ascent 14 [list $gallery]
    if {$kind eq "apple"} {
        emojiCaption $doc y "The row example 02.09 sets in Noto Emoji, the\
            MONOCHROME face, set here in $faceName - the same\
            twenty-one marks, character for character. Twenty-three code\
            points make twenty-one pictures: the desert island carries U+FE0F\
            and the chilli U+FE0E, the TEXT presentation selector, and this\
            face has a glyph for neither - each rides along with the mark in\
            front of it and comes back out of the /ToUnicode."
    } else {
        emojiCaption $doc y "The row example 02.09 sets in Noto Emoji, the\
            MONOCHROME face of the same family, set here in the colour one -\
            the same twenty-one marks, character for character. Twenty-three\
            code points make twenty-one pictures: the desert island carries\
            U+FE0F and the chilli U+FE0E, the text presentation selector, and\
            this face has a glyph for neither - each rides along with the mark\
            in front of it and comes back out of the /ToUnicode."
    }

    emojiRow $doc y $emoji $ascent 18 $singles
    emojiCaption $doc y "One character each - and the last one is two, because\
        a heart carries the emoji presentation selector U+FE0F behind it."

    emojiRow $doc y $emoji $ascent 36 $singles
    if {$kind eq "apple"} {
        emojiCaption $doc y "The same seven at twice the size. Every mark on\
            these pages is a PICTURE - a PNG out of the face's 160 pixel\
            strike, placed by a Type 3 glyph description - so it is sharp up\
            to its own resolution and no further, which is the one thing a\
            drawn colour font does better. Measured off this document:\
            [format %.3f [$doc textWidth $grin -family $emoji -size 18]] mm\
            at 18 pt against [format %.3f [$doc textWidth $grin \
                -family $emoji -size 36]] mm at 36 pt, which is exactly\
            twice - the advance comes out of the face's hmtx either way.\
            \[pdfimages -list\] finds nothing in the file all the same, and\
            that is worth knowing rather than surprising: it walks PAGE\
            content streams, and every picture here sits inside a Type 3\
            glyph description."
    } else {
        emojiCaption $doc y "The same seven at twice the size. Every mark on\
            these pages is a PATH - a Type 3 glyph description of clipped\
            shapes and shadings, not a picture - so it scales without losing\
            anything, and the only difference between this row and the one\
            above it is the text matrix. Measured off this document:\
            [format %.3f [$doc textWidth $grin -family $emoji -size 18]] mm\
            at 18 pt against [format %.3f [$doc textWidth $grin \
                -family $emoji -size 36]] mm at 36 pt, which is exactly\
            twice. \[pdfimages -list\] on the finished file lists nothing at\
            all."
    }

    emojiRow $doc y $emoji $ascent 18 $sequences
    emojiCaption $doc y "Two to seven characters each: two families, two flags\
        of regional indicator pairs, the transgender flag with its joiner and\
        its two selectors, and the Scottish flag - a black flag and six\
        invisible tag characters spelling \"gbsct\". The skin tones have a\
        page of their own overleaf."

    # -- one sequence, one glyph, one width ----------------------------------

    exampleHeading $doc y "One sequence, one glyph, one width"
    examplePara $doc y "The measurement below is the whole claim of this page,\
        and it is read off the document rather than asserted: \[textWidth\]\
        answers the same number for a sequence of seven characters as for a\
        single emoji, because in the font they are the same thing - one\
        glyph, one entry in the /Widths array, one byte in the string that\
        sets it. A font that had taken the sequence apart would measure seven\
        times as wide and draw seven pictures."

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
    emojiCaption $doc y "Ten units, one to seven characters each, and one\
        width for all of them: [format %.3f $unitWidth] mm at 10 pt. The last\
        row is seven characters wide and one glyph big, and the two in the\
        middle carry a skin tone and a joiner at once."

    # -- the skin tones ------------------------------------------------------

    $doc page add
    set y 20
    exampleHeading $doc y "The skin tones, one icon at a time"
    examplePara $doc y "A skin tone is not a picture. U+1F3FB to U+1F3FF are\
        the five Fitzpatrick MODIFIERS, and a modifier changes the mark in\
        front of it: the base emoji and the modifier are one sequence, one\
        glyph in the face and one glyph here, with one advance and one\
        /ToUnicode entry carrying both code points back. The three rows below\
        are the same icon through the whole ramp, so that what the modifier\
        does is visible rather than described."

    set y [expr {$y + 2}]
    emojiRow $doc y $emoji $ascent 24 $tones
    emojiEquation $doc y $emoji $ascent 24 [list $thumb $toneMid] $thumbMid
    emojiCaption $doc y "The base on its own, then the same base through all\
        five modifiers: U+1F44D, and U+1F44D followed by U+1F3FB, U+1F3FC,\
        U+1F3FD, U+1F3FE, U+1F3FF. Six units, eleven code points, six glyphs -\
        every one of them the same width, because a modifier adds nothing to\
        the advance."

    emojiRow $doc y $emoji $ascent 24 $workers
    emojiEquation $doc y $emoji $ascent 24 [list $builder $toneMid $female] \
        $workerMid
    emojiCaption $doc y "The same ramp on a ZWJ SEQUENCE, which is the case\
        that matters: the builder is U+1F477, a zero width joiner, the female\
        sign U+2640 and a presentation selector, and the modifier goes in as\
        the SECOND code point rather than at the end. Six units - four code\
        points for the first and five for the other five - six glyphs, one\
        width. A match that took the base and the tone and then stopped would\
        draw a toned builder and then refuse the joiner; one that matched\
        neither would draw five pictures where the face draws one."

    emojiRow $doc y $emoji $ascent 24 $farmers
    emojiEquation $doc y $emoji $ascent 24 [list $person $toneMid $sheaf] \
        $farmerMid
    emojiCaption $doc y "And once more with a shorter sequence around the\
        tone: a person, a sheaf of rice and the joiner between them. Six units\
        of three and four code points, six glyphs, one width. Every unit on\
        this page was checked against hb-shape - the glyph this package picks\
        for a sequence is the glyph HarfBuzz picks."

    # -- what the face is made of --------------------------------------------

    if {$kind eq "apple"} {
        exampleHeading $doc y "What this face carries"
        examplePara $doc y "Measured over the whole file on 2026-08-26:\
            192 123 488 bytes, of which the \"sbix\" table is 191 134 508 -\
            99.5 per cent. It holds NINE STRIKES, one per size: 20, 26, 32,\
            40, 48, 52, 64, 96 and 160 pixels to the em, and 3 706 433,\
            5 583 528, 7 261 741, 9 766 787, 12 755 001, 15 308 789,\
            20 159 534, 36 665 254 and 79 788 940 bytes of PNG in them. At\
            the largest strike 3600 of the 3844 glyphs carry a picture, 136\
            carry none - the space, the joiner, the tag characters - and 108\
            carry a \"flip\" record, which is not a picture at all but\
            another glyph's number: the runner and the walker facing the\
            other way are the same PNG with a negative horizontal scale, and\
            two Type 3 glyphs then share one image XObject."
        examplePara $doc y "This document draws from the 160 pixel strike,\
            which is what \[colorFont\] takes where -strike names none: a\
            Type 3 font is built once and set at every size the document\
            uses, so nothing at build time knows which size to choose, and of\
            the two ways to be wrong only one is visible. -strike 64 makes\
            the same document a quarter of the size."
        set y [expr {$y + 1}]
        foreach {mark wording} [list \
                $dart "a picture out of the face and nothing else - which is\
                    every mark on these pages" \
                $grin "160 by 160 pixels, RGBA, and the alpha channel becomes\
                    the /SMask of the image XObject" \
                $globe "the same picture at nine resolutions in the file, of\
                    which exactly one reaches the document" \
                $ball "an image XObject per glyph, placed by a Type 3 glyph\
                    description with one \"cm\" and one \"Do\"" \
                $flagDe "no gradient, no shading, no blend mode - a bitmap\
                    face needs none of the machinery a COLR version 1 face\
                    needs" \
                $flagScotland "the same, reached through six invisible tag\
                    characters"] {
            $doc font -family emoji -size 11
            $doc text $mark -at [list 22 $y]
            $doc font -family body -size 9 -color {0.1 0.1 0.15}
            set y [expr {[$doc text $wording -at [list 32 $y] -width 158] + 3}]
        }
    } else {
        exampleHeading $doc y "What this face paints with"
        examplePara $doc y "Measured over all 3993 colour glyphs of this face:\
            129823 clipped shapes, 111668 solid fills, 35981 transformations,\
            9844 radial gradients, 8627 linear ones, 578 composites - and NOT\
            ONE SWEEP. The angular gradient that costs example 2.17 a fan of\
            Gouraud triangles, because PDF has no shading type for it, does\
            not occur in this face at all. The composites are of two modes\
            only, and both of them sit in a flag: Source In, which pours a\
            gradient into the shape of something else, and Soft Light, which\
            is a PDF blend mode under another name."
        set y [expr {$y + 1}]
        foreach {mark wording} [list \
                $dart "layers of solid fills and nothing else - the common\
                    case, by a wide margin" \
                $grin "a radial gradient in the face, and PDF's type 3\
                    shading on the way out" \
                $globe "four radial gradients under four transformations" \
                $ball "five linear gradients and two radial ones in one\
                    glyph" \
                $flagDe "a linear gradient, a Source In and a Soft Light -\
                    both of this face's composite modes in two characters" \
                $flagScotland "the same three, reached through six invisible\
                    tag characters"] {
            $doc font -family emoji -size 11
            $doc text $mark -at [list 22 $y]
            $doc font -family body -size 9 -color {0.1 0.1 0.15}
            set y [expr {[$doc text $wording -at [list 32 $y] -width 158] + 3}]
        }
    }
    set y [expr {$y + 3}]

    # -- in the running text -------------------------------------------------

    $doc page add
    set y 20
    exampleHeading $doc y "In the running text"
    examplePara $doc y "One string, one call, two faces: -fallback names the\
        faces that may set what -family cannot, and the chain offers a\
        SEQUENCE as one unit - longest match first - rather than a character\
        at a time. That is what lets a family emoji stand in the middle of a\
        sentence instead of breaking apart at its joiners, and it is why the\
        marks below need no space around them: a sequence glued to the word in\
        front of it is still one glyph."

    set y [expr {$y + 2}]
    $doc font -family body -size 11 -color {0.1 0.1 0.15} -fallback $emoji
    set y [expr {[$doc text "The crate$crate left the depot$lorry on Tuesday\
        and reached the family$family3 in $flagDe on Thursday, who signed for\
        it$thumbMid at 14:20$tick. Two pallets went back$warn - the $flagFr\
        consignment is still on the water, and the $flagScotland one has not\
        left the yard." -at [list 20 $y] -width 170] + 6}]
    $doc font -family body -size 10 -color {0 0 0} -fallback {}

    # -- the characters that draw nothing ------------------------------------

    exampleHeading $doc y "The characters that draw nothing"
    if {$kind eq "apple"} {
        examplePara $doc y "Of the 1469 characters this face's cmap maps, a\
            good many draw nothing at all: the space, the zero width joiner,\
            and the tag characters a flag like the Scottish one is spelled\
            with. They are real entries in the cmap and they have real glyph\
            numbers, and at every one of the nine strikes their picture is\
            EMPTY - 136 glyphs of 3844 at the largest. So a font built from\
            one would be valid, extractable and blank, with nothing reporting\
            it. That is refused by name, and only where such a character is\
            asked for ALONE: inside a sequence the joiner and the tags are\
            swallowed by the state machine and come back out through the\
            /ToUnicode, which is what the last row of the width table on the\
            first page shows."
    } else {
        examplePara $doc y "Of the 1499 characters this face's cmap maps, 39\
            draw nothing at all: the space, the zero width joiner, and the 37\
            tag characters a flag like the Scottish one is spelled with. They\
            are real entries in the cmap and they have real glyph numbers,\
            but their outlines are empty and the COLR table says nothing\
            about them - so a font built from one would be valid, extractable\
            and blank, with nothing reporting it. That is refused by name, and\
            only where such a character is asked for ALONE: inside a sequence\
            the joiner and the tags are swallowed by the ligature and come\
            back out through the /ToUnicode, which is what the last row of\
            the width table on the first page shows."
    }

    # The refusal, caught from this very page rather than quoted: the zero
    # width joiner on its own is the shortest way to ask for a glyph that
    # would draw nothing - both faces have one, numbered like any other, and
    # in both it is empty.
    #
    # Written as "\u200D" and not as the character itself, which is the one
    # place on this page where the escape is the clearer spelling: a literal
    # joiner is INVISIBLE in the source, and an invisible argument is what the
    # next person to edit this file would delete by accident. The escape is
    # safe here because the joiner is inside the BMP - for a character beyond
    # it, \U is broken under Tcl 8.6 and the literal is the only road, which
    # is why every emoji above is written out.
    set refusal "it was accepted, which it should not have been"
    try {
        $doc colorFont blank $facePath -chars "\u200D"
    } trap {TCLPDF COLORFONT EMPTY} {message} {
        set refusal $message
    }
    examplePara $doc y "The message, caught from this very page: $refusal" \
        {0.55 0.15 0.15}

    # One character the cmap has NOT got, and it is the one that matters most:
    # U+FE0F, the emoji presentation selector, sits inside half the real
    # sequences and neither face has a glyph for it. It is not refused - a
    # selector modifies the character in front of it and draws nothing by
    # design, so it rides along with its neighbour and its code point is kept,
    # which is why the heart above extracts as two characters rather than one.

    # -- check it yourself ---------------------------------------------------

    exampleHeading $doc y "Check it yourself"
    if {$kind eq "apple"} {
        examplePara $doc y "The first command hands the sequences back\
            unchanged - joiners, skin tones, selectors and tag characters\
            included - which is the /ToUnicode of a Type 3 font doing its\
            work. The second counts the image XObjects: 120, which is one\
            picture and one soft mask for each of the sixty glyphs that have\
            one. \[pdfimages -list\] finds none of them, because it walks\
            page content streams and these sit inside glyph descriptions. The\
            third is the font's own table of glyph procedures, and its keys\
            spell the sequences out one code point at a time - one procedure\
            for all seven characters of the Scottish flag. The fourth counts\
            the placements, one per glyph drawn."
    } else {
        examplePara $doc y "The first command hands the sequences back\
            unchanged - joiners, skin tones, selectors and tag characters\
            included - which is the /ToUnicode of a Type 3 font doing its\
            work. The second lists the pictures in the file and prints a\
            header with nothing under it: every emoji on these pages is a\
            path in a glyph stream, and there is no bitmap anywhere in the\
            document. The third is the font's own table of glyph procedures,\
            and its keys spell the sequences out one code point at a time -\
            one procedure for all seven characters of the Scottish flag. The\
            fourth counts the shadings the gradients became."
    }
    # "grep -a", never a plain grep, and it is not a nicety: a decompressed
    # PDF still holds binary bytes, and BSD grep then answers "binary file
    # matches" for -A and NO COUNT AT ALL for -c.
    if {$kind eq "apple"} {
        # ANCHORED, and the anchor is not decoration: the command itself
        # stands on the page above, so a plain grep for the string finds one
        # more than there are pictures - its own line. Measured: 121 without
        # the anchor, 120 with it.
        set second "qpdf --qdf --object-streams=disable [file tail $target] -\
            | grep -ac \"^ */Subtype /Image\""
        set last "grep -ac \" Do\""
    } else {
        set second "pdfimages -list [file tail $target]"
        set last "grep -ac ShadingType"
    }
    exampleCommandBlock $doc y [list \
        "pdftotext [file tail $target] - | head -20" \
        $second \
        "qpdf --qdf --object-streams=disable [file tail $target] - |\
            grep -a -A22 /CharProcs" \
        "qpdf --qdf --object-streams=disable [file tail $target] - |\
            $last"]

    exampleFooter $doc body

    $doc write $target
    puts "  written: $target ([file size $target] bytes)"
    # The same list the font was built from, so the two numbers cannot drift
    # apart: what the console prints is the check on the pages above it.
    set info [$doc font info $emoji]
    puts "  colour font \"$emoji\" from $faceName: [dict get $info glyphs]\
        glyphs out of [llength [split [join [concat [list $gallery] $singles \
            $sequences $working $tones $workers $farmers] {}] {}]]\
        characters, [format %.0f [dict get $info unitsPerEm]] units to the\
        em, [dict get $info bitmaps] of them bitmaps, from a\
        [file size $facePath]-byte face"
    $doc destroy
    return
}

# ---------------------------------------------------------------------------
# The two runs
# ---------------------------------------------------------------------------
#
# Each half skips itself, and neither skip is a failure - the same rule
# [make check] follows for a validator that is not installed. Noto's 25 MB of
# somebody else's artwork does not belong in a package tarball and is excluded
# from it and from the repository alike; Apple's face is part of macOS and
# exists nowhere else.

if {[file exists $notoPath]} {
    emojiDocument noto $notoPath $target
} else {
    puts "  skipped: [file tail $notoPath] is not in the tree - 25 MB of\
        artwork is excluded from the source archive; fetch it from Google\
        Fonts <https://fonts.google.com/noto/specimen/Noto+Color+Emoji> or\
        from <https://github.com/googlefonts/noto-emoji> (SIL Open Font\
        License 1.1) and put it in [file dirname $notoPath]"
}

if {[file exists $applePath]} {
    emojiDocument apple $applePath $appleTarget
} else {
    puts "  skipped: $applePath is not on this machine - Apple Color Emoji\
        ships with macOS and is not redistributable, so the second document\
        is written where the file is and nowhere else"
}
