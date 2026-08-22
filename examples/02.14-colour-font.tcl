#!/usr/bin/env tclsh
#
# tclpdf example 2.14 - a colour font, drawn as text
#
#   tclsh examples/02.14-colour-font.tcl ?output.pdf?
#
# PDF has no colour font. A face goes into a file as an outline program and the
# text operators paint it in ONE colour, whatever the designer put beside those
# outlines - which is why a face whose pictures live in a COLR/CPAL table comes
# out BLANK when it is embedded, and why [font embed] refuses such a face by
# name since 2026-08-21. [colorFont] takes the other road: it reads the layers
# and their palette colours out of the face and draws each of them into a Type 3
# glyph, so the symbol becomes a drawn font (see 02.11) and from there on is a
# family like any other.
#
#   $doc colorFont marks marks.ttf -chars "⚠✔✖"
#   $doc font -family body -size 11 -fallback marks
#   $doc text "⚠ mind the step"
#
# WHAT THIS IS FOR, and what it is not for. It is not for emoji: nobody puts a
# family emoji in an invoice, and a face that carries them is 1.5 MB of artwork
# under a licence of its own. It is for the two-colour mark that has to behave
# like a character - a logo in a letterhead, an amber warning sign in a table
# column, a green tick beside a line item. Those move with the line, take the
# font size, are measured by [textWidth], break with the paragraph and come back
# out of [pdftotext] as the characters they stand for, and none of that has to
# be arithmetic in the caller.
#
# THE FACE ON THIS PAGE IS BUILT BY THIS SCRIPT, and that is the one part of it
# you will not write yourself: normally a colour face comes out of a font editor
# as a file, and the call takes that file. It is built here because no colour
# font ships with this package - the only real COLR version 0 face available is
# an emoji face whose artwork is under CC-BY while this package is MIT - and
# because a face built in fifty lines shows what the format actually is: layer
# glyphs that are ordinary outlines, a COLR table saying which of them a symbol
# is made of, and a CPAL table of colours they point into.
#
# THREE THINGS THE PAGE DEMONSTRATES that a single-colour font cannot do:
#
#   - two symbols SHARING a layer. The tick and the cross are drawn from the
#     same octagon glyph, once through a green palette entry and once through a
#     red one. That is what a palette is for.
#   - a layer that takes the TEXT colour. Palette index 0xFFFF is a sentinel,
#     not an index: it means "whatever colour the text has" (ISO/IEC 14496-22,
#     5.7.11), so the right half of the logo below follows [font -color] while
#     its left half stays brand blue. For an emoji face this is a curiosity -
#     Twemoji Mozilla uses it in none of its 33179 layers - and for a logo as a
#     character it is the whole point.
#   - a translucent layer. A CPAL entry carries an alpha byte, and the shadow
#     under the logo is at 25 %. PDF keeps constant alpha in an ExtGState
#     rather than beside the colour, so that one layer costs a resource and an
#     opaque one costs nothing.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf
package require tclpdf::colorFont
package require tclpdf::glyfOutline
package require tclpdf::subset

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "02.14-colour-font.pdf"}]
set assets [file join $here assets]

# --- the face ---------------------------------------------------------------
#
# Everything down to the next line of dashes builds a TrueType file in memory.
# It uses two commands that are NOT part of the API - [glyfOutline compose],
# which writes the point arrays of one glyph, and [subset::Assemble], which puts
# a table directory with checksums around a set of tables - because assembling a
# font is not what this package is for and no caller should have to. Reach for a
# font editor instead; what follows is here so that the page has something to
# draw with.

# One glyph as glyf bytes, from contours of {x y} points. Straight lines only:
# every symbol on this page is a polygon, which keeps the shapes readable in
# the source and costs nothing at this size.
proc faceGlyph {contours} {
    set ends {}
    set flags {}
    set xs {}
    set ys {}
    set count 0
    foreach contour $contours {
        foreach point $contour {
            lassign $point x y
            # 1 is ON_CURVE - a corner the outline passes through.
            lappend flags 1
            lappend xs $x
            lappend ys $y
            incr count
        }
        lappend ends [expr {$count - 1}]
    }
    return [::tclpdf::glyfOutline compose [dict create type simple \
        ends $ends flags $flags x $xs y $ys instructions {} bounds {0 0 0 0}]]
}

# A regular polygon, which is how the round shapes on this page are round.
proc faceRegular {cx cy radius sides {turn 0}} {
    set points {}
    for {set corner 0} {$corner < $sides} {incr corner} {
        set angle [expr {($corner + $turn) * 2 * acos(-1) / $sides}]
        lappend points [list [expr {round($cx + $radius * cos($angle))}] \
            [expr {round($cy + $radius * sin($angle))}]]
    }
    return $points
}

# The COLR table, version 0 (ISO/IEC 14496-22, 5.7.11): a header, one record
# per base glyph naming where its layers begin and how many there are, and the
# layer records themselves - each a glyph number and a palette index, bottom of
# the stack first. Flat arrays of fixed width, which is the whole format.
proc faceColr {records layers} {
    set base [llength $records]
    set table [binary format SuSuIuIuSu 0 $base 14 [expr {14 + $base * 6}] \
        [llength $layers]]
    foreach record $records {
        append table [binary format SuSuSu {*}$record]
    }
    foreach layer $layers {
        append table [binary format SuSu {*}$layer]
    }
    return $table
}

# The CPAL table (5.7.12): the colours the layer records point into. A colour
# record is FOUR BYTES IN THE ORDER blue, green, red, alpha - not red first,
# which is the mistake this format invites.
proc faceCpal {colours} {
    set table [binary format SuSuSuSuIu 0 [llength $colours] 1 \
        [llength $colours] 14]
    append table [binary format Su 0]
    foreach colour $colours {
        append table [binary format cccc {*}$colour]
    }
    return $table
}

# A cmap, format 12: one group per character. Which characters a face has is
# the one question every other module of this package asks it.
proc faceCmap {map} {
    set groups {}
    set count 0
    foreach code [lsort -integer [dict keys $map]] {
        append groups [binary format IuIuIu $code $code [dict get $map $code]]
        incr count
    }
    set subtable [binary format SuSuIuIuIu 12 0 [expr {16 + $count * 12}] 0 \
        $count]
    return [binary format SuSuSuSuIu 0 1 3 10 12]$subtable$groups
}

# The file around all of it: 1000 units to the em, an ascender of 750, and an
# advance of 1000 for every glyph. loca is written 32-bit so no offset has to
# be halved, and every glyph is padded to a four-byte boundary.
proc faceFile {glyphs map colr cpal} {
    set count [llength $glyphs]
    set head [binary format IuIuIuIu 0x00010000 0x00010000 0 0x5F0F3CF5]
    append head [binary format SuSu 0 1000]
    append head [binary format WuWu 0 0]
    append head [binary format SSSS 0 -200 1000 800]
    append head [binary format SuSuSSS 0 8 2 1 0]
    set hhea [binary format Iu 0x00010000]
    append hhea [binary format SSS 750 -250 0]
    append hhea [binary format Su 1000]
    append hhea [binary format SSS 0 0 1000]
    append hhea [binary format SSS 1 0 0]
    append hhea [binary format SSSS 0 0 0 0]
    append hhea [binary format SSu 0 $count]
    set maxp [binary format Iu 0x00010000]
    append maxp [binary format Su $count]
    append maxp [string repeat \x00 26]
    set hmtx {}
    set glyf {}
    set loca {}
    foreach data $glyphs {
        append hmtx [binary format SuS 1000 0]
        append loca [binary format Iu [string length $glyf]]
        append glyf $data
        while {[string length $glyf] % 4} {
            append glyf \x00
        }
    }
    append loca [binary format Iu [string length $glyf]]
    return [::tclpdf::subset::Assemble [dict create head $head hhea $hhea \
        maxp $maxp hmtx $hmtx loca $loca glyf $glyf cmap [faceCmap $map] \
        COLR $colr CPAL $cpal]]
}

# The layer glyphs: ordinary outlines, in no particular order, and NOT reachable
# through the cmap. A colour face is built the other way round from an ordinary
# one - the characters point at base glyphs that have no outline at all, and
# every picture sits in a glyph nothing addresses directly.
set layerGlyphs [list \
    {} \
    [faceGlyph {{{500 715} {900 45} {100 45}}}] \
    [faceGlyph {{{455 240} {545 240} {545 570} {455 570}} \
                {{455 95} {545 95} {545 185} {455 185}}}] \
    [faceGlyph [list [faceRegular 500 370 350 8 0.5]]] \
    [faceGlyph {{{240 380} {410 210} {760 555} {760 690} {410 350} {240 515}}}] \
    [faceGlyph {{{270 205} {365 110} {730 475} {635 570}} \
                {{635 110} {730 205} {365 570} {270 475}}}] \
    [faceGlyph {{{540 660} {860 340} {540 20} {220 340}}}] \
    [faceGlyph {{{500 700} {500 60} {180 380}}}] \
    [faceGlyph {{{500 700} {820 380} {500 60}}}]]

# The base glyphs - one per character, all of them empty - and the records that
# say what each is made of. Glyph 3, the octagon, is used TWICE with different
# palette entries: that is what a layer and a palette are for.
lappend layerGlyphs {} {} {} {}
set faceRecords {{9 0 2} {10 2 2} {11 4 2} {12 6 3}}
set faceLayers {
    {1 0} {2 1}
    {3 2} {4 3}
    {3 4} {5 3}
    {6 6} {7 5} {8 0xFFFF}
}

# blue, green, red, alpha - the order the format stores them in.
set faceColours {
    {0 178 255 255}
    {35 35 40 255}
    {64 140 25 255}
    {255 255 255 255}
    {40 40 200 255}
    {180 90 30 255}
    {70 60 60 64}
}

set faceMap [dict create 0x26A0 9 0x2714 10 0x2716 11 0xE000 12]

# Written to a file, because that is how a caller meets a face and therefore
# how this page should show the call. [colorFont] takes -data for the face that
# never was a file - one out of a database, one out of an archive - and the two
# roads produce the same font.
set workshop [exampleTempDirectory]
set facePath [file join $workshop marks.ttf]
exampleWriteBinary $facePath [faceFile $layerGlyphs $faceMap \
    [faceColr $faceRecords $faceLayers] [faceCpal $faceColours]]

# --- the document -----------------------------------------------------------

set warning ⚠
set tick ✔
set cross ✖
set logo \uE000

set doc [tclpdf new -unit mm]
$doc info Title "A colour font, drawn as text"
$doc info Author "tclpdf example 2.14"
$doc page add

# The words. A colour font holds the symbols that were asked for and nothing
# else - not a letter, not a space - so it always stands beside a real face.
$doc font embed body [file join $assets fonts DejaVuSans.ttf]

# THE ONE CALL this page is about. The alias comes first and the file after it,
# the way [image embed] takes them; -chars names the characters to build glyphs
# for, and what comes back is the alias, so it can be handed straight on.
set marks [$doc colorFont marks $facePath -chars "$warning$tick$cross$logo"]

set y 20
exampleHeading $doc y "A colour font, drawn as text"
examplePara $doc y "The four marks below are not letters of any face and not\
    drawings on this page. They are a COLOUR FONT: a face whose symbols are\
    made of stacked outlines, each one pointing at an entry in a colour\
    palette. PDF cannot embed such a face - the text operators paint an\
    outline in one colour and nothing else - so tclpdf reads the layers and\
    draws them into a Type 3 font, and the symbols become characters of a\
    family this document carries."
examplePara $doc y "From there on nothing knows the difference. They sit on the\
    baseline, they take the font size, \[textWidth\] measures them, a\
    paragraph breaks around them, and they come back out of pdftotext as the\
    characters they stand for."

# -- the marks themselves ----------------------------------------------------

set y [expr {$y + 2}]
$doc font -family $marks -size 22 -color {0 0 0}
set x 20
foreach mark [list $warning $tick $cross $logo] {
    $doc text $mark -at [list $x [expr {$y + 8}]]
    set x [expr {$x + [$doc textWidth $mark] + 4}]
}
set y [expr {$y + 14}]
$doc font -family body -size 9 -color {0.45 0.45 0.5}
$doc text "two layers, two layers, two layers, three - and the tick and the\
    cross share one octagon glyph between them" -at [list 20 $y]
set y [expr {$y + 10}]

# -- what it is for ----------------------------------------------------------

$doc font -family body -size 10 -color {0 0 0}
exampleHeading $doc y "A status column"
examplePara $doc y "The case this exists for. The mark is a character in the\
    line, so the wording behind it starts where \[textWidth\] says and the\
    row needs no arithmetic of its own."

set rows {
    tick    "Invoice 2026-0412 sent, payment received"
    tick    "Invoice 2026-0413 sent, payment received"
    warning "Invoice 2026-0414 sent, 14 days overdue"
    cross   "Invoice 2026-0415 rejected by the recipient"
}
set y [expr {$y + 2}]
foreach {which wording} $rows {
    $doc font -family $marks -size 10
    $doc text [set $which] -at [list 22 $y]
    $doc font -family body -size 10 -color {0.1 0.1 0.15}
    $doc text $wording \
        -at [list [expr {22 + [$doc textWidth [set $which]] + 1.5}] $y]
    set y [expr {$y + 6}]
}
set y [expr {$y + 4}]

# -- a font, not a drawing ---------------------------------------------------

$doc font -family body -size 10 -color {0 0 0}
exampleHeading $doc y "It is a font"
examplePara $doc y "The same four marks at five sizes. Nothing is scaled by\
    hand: the size is the font size, and the glyph streams in the file are the\
    integers the face stores - the FontMatrix carries the em."

set x 20
foreach size {7 10 14 20 28} {
    $doc font -family $marks -size $size -color {0 0 0}
    $doc text "$warning$tick$cross" -at [list $x [expr {$y + 12}]]
    set x [expr {$x + [$doc textWidth "$warning$tick$cross"] + 4}]
}
set y [expr {$y + 18}]

# -- the layer that follows the text -----------------------------------------

$doc font -family body -size 10 -color {0 0 0}
exampleHeading $doc y "A layer in the colour of the text"
examplePara $doc y "The logo mark has three layers: a shadow at 25 % alpha, a\
    left half in brand blue, and a right half whose palette index is the\
    sentinel 0xFFFF - which is not an index but the instruction \"take\
    whatever colour the text has\". So the right half follows -color and the\
    left half does not. A single-colour font can do neither half; a bitmap\
    can do neither."

set y [expr {$y + 2}]
set x 20
foreach colour {{0 0 0} {0.75 0.35 0.10} {0.10 0.55 0.30} {0.55 0.15 0.55}} {
    $doc font -family $marks -size 20 -color $colour
    $doc text $logo -at [list $x [expr {$y + 8}]]
    set x [expr {$x + [$doc textWidth $logo] + 3}]
}
set y [expr {$y + 14}]
$doc font -family body -size 9 -color {0.45 0.45 0.5}
$doc text "black, orange, green, violet - and the blue half stays blue" \
    -at [list 20 $y]
set y [expr {$y + 10}]

# -- both faces in one line --------------------------------------------------

$doc page add
set y 20
$doc font -family body -size 10 -color {0 0 0}
exampleHeading $doc y "In the running text"
examplePara $doc y "One string, one call, two faces: -fallback names the faces\
    that may set what -family cannot, so the package decides per character\
    where each glyph comes from and the paragraph breaks around the marks\
    like any other character."
examplePara $doc y "WHICH WAY ROUND MATTERS, and the two lines below are the\
    same sentence set both ways. The chain is tried IN ORDER, and DejaVu Sans\
    has a warning sign, a tick and a cross of its own - so with the words\
    first the marks come out of DejaVu, in one colour, and only the logo\
    reaches the colour font because nothing else has that character. With the\
    colour font first they come out in colour and the letters fall through to\
    DejaVu, which is what a face of symbols wants. Neither is a defect: a\
    colour font is one face in a chain, and a chain has a direction."

set y [expr {$y + 2}]
foreach {first second label} [list \
        body $marks "the words first: the marks come from DejaVu Sans" \
        $marks body "the colour font first: the marks come from it"] {
    $doc font -family $first -size 11 -color {0.1 0.1 0.15} -fallback $second
    set y [expr {[$doc text "$warning Delivery 2026-0414 is overdue. The goods\
        left the warehouse on the 3rd $tick and were refused at the door on\
        the 9th $cross - please tell us what to do with them. $logo" \
        -at [list 20 $y] -width 170] + 2}]
    $doc font -family body -size 9 -color {0.45 0.45 0.5} -fallback {}
    $doc text $label -at [list 20 $y]
    set y [expr {$y + 8}]
}
set y [expr {$y + 2}]

# -- the refusal that makes this necessary -----------------------------------

$doc font -family body -size 10 -color {0 0 0}
exampleHeading $doc y "Why not just embed it"
set refusal "it was accepted, which it should not have been"
try {
    $doc font embed wrong $facePath
} trap {TCLPDF FONT OUTLINES} {message} {
    set refusal $message
}
examplePara $doc y "The same file handed to \[font embed\] is refused, and the\
    refusal is the point: every character this face covers has an EMPTY\
    outline, because all the drawing sits in the layer glyphs. Embedded, it\
    would produce a document that is valid, extractable and blank, with\
    nothing anywhere reporting it - not the API, not pdftotext, not pdffonts,\
    not qpdf, not veraPDF."
examplePara $doc y "The message, caught from this very page: $refusal" \
    {0.55 0.15 0.15}

# -- check it yourself -------------------------------------------------------

$doc font -family body -size 10 -color {0 0 0}
exampleHeading $doc y "Check it yourself"
examplePara $doc y "The first command shows the font dictionary: no font file\
    anywhere, a /CharProcs entry per symbol, and an /ExtGState in the font's\
    own /Resources - the one the translucent shadow needs. The second prints\
    the glyph stream of the logo: d0, then one q/Q bracket per layer, and the\
    third bracket has no colour operator in it at all, which is the sentinel.\
    The third command is the one that matters for a reader."
exampleCommandBlock $doc y [list \
    "qpdf --qdf --object-streams=disable [file tail $target] - | grep -A20 Type3" \
    "qpdf --qdf --object-streams=disable [file tail $target] - | grep -B2 -A24 ' d0'" \
    "pdftotext [file tail $target] - | head -20" \
    "pdffonts [file tail $target]"]

exampleFooter $doc body

$doc write $target
puts "  written: $target ([file size $target] bytes)"
set info [$doc font info $marks]
puts "  colour font \"$marks\": [dict get $info glyphs] glyphs,\
    [format %.0f [dict get $info unitsPerEm]] units to the em, built from a\
    [file size $facePath]-byte face"
$doc destroy
file delete -force $workshop
