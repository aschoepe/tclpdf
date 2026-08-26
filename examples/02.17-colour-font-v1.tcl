#!/usr/bin/env tclsh
#
# tclpdf example 2.17 - a COLR version 1 colour font: gradients and compositing
#
#   tclsh examples/02.17-colour-font-v1.tcl ?output.pdf?
#
# Example 2.14 draws a colour font of the older kind: version 0 of the COLR
# table, which is stacked outlines each filled with one flat colour. This page
# is about the newer kind. COLR version 1 replaces that flat list with a
# GRAPH: every colour glyph is a tree of paint records, and the leaves are not
# only solid colours but linear, radial and sweep gradients, while the branches
# clip, transform and composite what hangs below them. Every emoji face made
# since about 2021 is built that way, and so are the display faces that draw
# their letters in gradients.
#
#   $doc colorFont badges badges.ttf -chars "..."
#
# THE CALL DOES NOT CHANGE. [colorFont] reads whichever version the face
# carries - a face may even use version 1 for some glyphs and version 0 for
# others, which the standard explicitly allows - and what comes out is a Type 3
# font either way: a family like any other, measured by [textWidth], moved by
# a paragraph, extracted by pdftotext through /ToUnicode.
#
# WHAT PDF HAS AND WHAT IT HAS NOT, because the interesting half of this is
# the translation:
#
#   - A gradient becomes a SHADING painted through a clipping path ("sh"),
#     never a shading pattern. A pattern is anchored to the page and would
#     stay put while the glyph moved; "sh" paints in the space in force and
#     travels with the letter.
#   - A linear gradient in COLR has THREE points, the third of which rotates
#     the direction the colours are projected in. PDF's axial shading has two,
#     so the third is folded into them by projection - exactly the derivation
#     the standard itself describes.
#   - PDF has no ANGULAR gradient at all. A sweep becomes a fan of Gouraud
#     triangles, one per four degrees plus one per colour stop.
#   - A gradient that FADES cannot be a shading alone, because a PDF shading
#     has no alpha channel. It becomes the same shading painted over and over
#     in NESTED BANDS OF CONSTANT ALPHA - one clip and one /ca per 1/64 step -
#     which is a clip and a number where the exact construction, a luminosity
#     soft mask, is the one thing in a Type 3 glyph that readers disagree
#     about. The mask is what is left where no plainer form exists.
#   - Compositing: fifteen of the twenty-eight modes are PDF blend modes under
#     other names and go into an isolated transparency group; seven more -
#     Source In and its relatives - become a clip path or a constant /ca where
#     the masking side allows it and an alpha soft mask where it does not.
#     One, Plus, has no PDF spelling at all and is refused by name rather than
#     drawn wrongly, and the three that composite BOTH sides - Source Atop,
#     Destination Atop and XOR - go the same way over a side that is neither
#     opaque nor one flat alpha inside one outline (those three are among the
#     seven). The remaining five - clear, src, dest, srcOver and destOver -
#     need no group and no mask at all: one paints nothing, two paint one
#     side alone, and two are the ordinary stacking of the two sides. That is
#     15 + 7 + 5 + 1 = 28.
#
# THE FACE ON THIS PAGE IS BUILT BY THIS SCRIPT, as it is in 2.14 and for the
# same reason: no colour font ships with this package, and every real version 1
# face is megabytes of artwork under a licence of its own. What is built here
# is a set of badges - the sort of thing a colour font is actually useful for
# outside emoji: a status mark that has to sit in a line of text and carry a
# gradient because the house style says so.
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "02.17-colour-font-v1.pdf"}]
set assets [file join $here assets]

# --- the face ---------------------------------------------------------------
#
# Everything down to the next line of dashes builds a TrueType file in memory.
# As in 2.14 it uses two commands that are NOT part of the API -
# [glyfOutline compose] and [subset::Assemble] - because assembling a font is
# not what this package is for. Reach for a font editor instead.

# One glyph as glyf bytes, from contours of {x y} points.
proc faceGlyph {contours} {
    set ends {}
    set flags {}
    set xs {}
    set ys {}
    set count 0
    foreach contour $contours {
        foreach point $contour {
            lassign $point x y
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

proc faceRegular {cx cy radius sides {turn 0}} {
    set points {}
    for {set corner 0} {$corner < $sides} {incr corner} {
        set angle [expr {($corner + $turn) * 2 * acos(-1) / $sides}]
        lappend points [list [expr {round($cx + $radius * cos($angle))}] \
            [expr {round($cy + $radius * sin($angle))}]]
    }
    return $points
}

# --- the COLR version 1 assembler -------------------------------------------
#
# A paint graph is a tree of records joined by FORWARD offsets, and an offset
# counted by hand is an offset that is wrong after the first edit. So a paint
# sub-tree is written as one contiguous blob - the record first and its
# children behind it - and every offset in it is the distance from the record
# to the child, taken from the lengths that were just written.

# F2DOT14 reaches from -2.0 to just under 2.0, and an angle is written as 180
# degrees per 1.0 of it. A ROTATION is written straight; a SWEEP GRADIENT's
# two angles carry a BIAS of 1.0 on top of that - the font stores
# degrees / 180 - 1 - which is exactly what buys the full turn: 360 degrees
# comes out as 1.0 where without the bias it would be 2.0, and 2.0 encodes as
# 32768, which is -2.0 in a signed short and a gradient running backwards.
# The bias belongs to the sweep alone, so it sits at the sweep below and not
# in here.
proc faceF2Dot14 {value} {
    set number [expr {int(round($value * 16384))}]
    if {$number < -32768 || $number > 32767} {
        error "$value is outside the range of an F2DOT14"
    }
    return [binary format S $number]
}

proc faceOffset24 {value} {
    return [binary format c* [list [expr {($value >> 16) & 0xFF}] \
        [expr {($value >> 8) & 0xFF}] [expr {$value & 0xFF}]]]
}

# A ColorLine: the extend mode, then {offset paletteIndex alpha} per stop.
proc faceColorLine {extend stops} {
    set table [binary format cSu \
        [dict get {pad 0 repeat 1 reflect 2} $extend] [llength $stops]]
    foreach stop $stops {
        lassign $stop offset entry alpha
        append table [faceF2Dot14 $offset] [binary format Su $entry] \
            [faceF2Dot14 $alpha]
    }
    return $table
}

# One paint sub-tree. The kinds this page uses, named the way the standard
# names them:
#
#   {solid palette alpha}
#   {linear extend stops {x0 y0} {x1 y1} {x2 y2}}
#   {radial extend stops {x0 y0} r0 {x1 y1} r1}
#   {sweep extend stops {cx cy} startAngle endAngle}
#   {glyph gid paint}     {layers first count}     {colrGlyph gid}
#   {rotateCenter degrees cx cy paint}   {translate dx dy paint}
#   {composite mode source backdrop}
proc facePaint {spec} {
    switch -- [lindex $spec 0] {
        solid {
            return [binary format cSu 2 [lindex $spec 1]][faceF2Dot14 \
                [lindex $spec 2]]
        }
        linear {
            lassign $spec . extend stops p0 p1 p2
            set head [binary format c 4][faceOffset24 16]
            append head [binary format SSSSSS {*}$p0 {*}$p1 {*}$p2]
            return $head[faceColorLine $extend $stops]
        }
        radial {
            lassign $spec . extend stops c0 r0 c1 r1
            set head [binary format c 6][faceOffset24 16]
            append head [binary format SSSuSSSu {*}$c0 $r0 {*}$c1 $r1]
            return $head[faceColorLine $extend $stops]
        }
        sweep {
            lassign $spec . extend stops centre start end
            set head [binary format c 8][faceOffset24 12]
            append head [binary format SS {*}$centre]
            # The bias of 1.0 - see [faceF2Dot14]. Left out, the font asks
            # for a sweep half a circle away from the one written here, and
            # every reader that knows the bias draws it turned round.
            append head [faceF2Dot14 [expr {$start / 180.0 - 1.0}]] \
                [faceF2Dot14 [expr {$end / 180.0 - 1.0}]]
            return $head[faceColorLine $extend $stops]
        }
        glyph {
            return [binary format c 10][faceOffset24 6][binary format Su \
                [lindex $spec 1]][facePaint [lindex $spec 2]]
        }
        colrGlyph {
            return [binary format cSu 11 [lindex $spec 1]]
        }
        layers {
            return [binary format ccIu 1 [lindex $spec 2] [lindex $spec 1]]
        }
        translate {
            return [binary format c 14][faceOffset24 8][binary format SS \
                [lindex $spec 1] [lindex $spec 2]][facePaint [lindex $spec 3]]
        }
        rotateCenter {
            set body [faceF2Dot14 [expr {[lindex $spec 1] / 180.0}]]
            append body [binary format SS [lindex $spec 2] [lindex $spec 3]]
            return [binary format c 26][faceOffset24 \
                [expr {4 + [string length $body]}]]$body[facePaint \
                [lindex $spec 4]]
        }
        composite {
            set source [facePaint [lindex $spec 2]]
            set backdrop [facePaint [lindex $spec 3]]
            return [binary format c 32][faceOffset24 8][binary format c \
                [lindex $spec 1]][faceOffset24 \
                [expr {8 + [string length $source]}]]$source$backdrop
        }
    }
    error "unknown paint \"[lindex $spec 0]\""
}

# The whole COLR table. "base" is the version 1 BaseGlyphList, "layers" the
# LayerList a {layers first count} slices into, "clips" the precomputed bounds,
# and the last two arguments are the VERSION 0 records the same table may carry
# beside the new ones - which is what the glyph at the end of this page uses.
proc faceColr {base layers {clips {}} {v0 {}} {v0Layers {}}} {
    set baseListAt 34
    set records {}
    set blobs {}
    set at [expr {4 + [llength $base] * 6}]
    foreach entry $base {
        lassign $entry glyph paint
        set bytes [facePaint $paint]
        # The paint offset counts from the start of the BaseGlyphList, not
        # from the start of the table.
        append records [binary format SuIu $glyph $at]
        append blobs $bytes
        incr at [string length $bytes]
    }
    set baseList [binary format Iu [llength $base]]$records$blobs
    set layerListAt [expr {$baseListAt + [string length $baseList]}]
    set layerList {}
    if {[llength $layers]} {
        set offsets {}
        set blobs {}
        set at [expr {4 + [llength $layers] * 4}]
        foreach paint $layers {
            set bytes [facePaint $paint]
            append offsets [binary format Iu $at]
            append blobs $bytes
            incr at [string length $bytes]
        }
        set layerList [binary format Iu [llength $layers]]$offsets$blobs
    }
    set clipListAt [expr {$layerListAt + [string length $layerList]}]
    set clipList {}
    if {[llength $clips]} {
        set records {}
        set boxes {}
        set at [expr {5 + [llength $clips] * 7}]
        foreach clip $clips {
            lassign $clip first last box
            append records [binary format SuSu $first $last][faceOffset24 $at]
            append boxes [binary format c 1][binary format SSSS {*}$box]
            incr at 9
        }
        set clipList [binary format cIu 1 [llength $clips]]$records$boxes
    }
    set v0At [expr {$clipListAt + [string length $clipList]}]
    set v0Records {}
    foreach record $v0 {
        append v0Records [binary format SuSuSu {*}$record]
    }
    set v0LayerAt [expr {$v0At + [string length $v0Records]}]
    set v0LayerRecords {}
    foreach record $v0Layers {
        append v0LayerRecords [binary format SuSu {*}$record]
    }
    set header [binary format SuSuIuIuSu 1 [llength $v0] \
        [expr {[llength $v0] ? $v0At : 0}] \
        [expr {[llength $v0Layers] ? $v0LayerAt : 0}] [llength $v0Layers]]
    append header [binary format IuIuIuIuIu $baseListAt \
        [expr {[llength $layers] ? $layerListAt : 0}] \
        [expr {[llength $clips] ? $clipListAt : 0}] 0 0]
    return $header$baseList$layerList$clipList$v0Records$v0LayerRecords
}

# The CPAL table: the colours the paint records point into. A colour record is
# FOUR BYTES IN THE ORDER blue, green, red, alpha - not red first, which is
# the mistake this format invites.
proc faceCpal {colours} {
    set table [binary format SuSuSuSuIu 0 [llength $colours] 1 \
        [llength $colours] 14]
    append table [binary format Su 0]
    foreach colour $colours {
        append table [binary format cccc {*}$colour]
    }
    return $table
}

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

# --- the shapes -------------------------------------------------------------
#
# The SHAPES of a version 1 colour glyph are ordinary outlines, exactly as the
# layers of a version 0 one are - what changed is what may be poured into them.
# None of these is reachable through the cmap.
#
#   1  a rounded badge (a 16-gon)      2  a tick
#   3  an exclamation bar and dot      4  a cross
#   5  a ring (badge with a hole)      6  a wide banner
#   7  a small pentagon                8  a plain arrow, no COLR entry at all
set layerGlyphs [list \
    {} \
    [faceGlyph [list [faceRegular 500 460 430 16 0.5]]] \
    [faceGlyph {{{250 470} {390 330} {760 700} {760 830} {390 460} {250 600}}}] \
    [faceGlyph {{{440 380} {560 380} {560 810} {440 810}} \
                {{440 170} {560 170} {560 290} {440 290}}}] \
    [faceGlyph {{{280 250} {380 150} {720 490} {620 590}} \
                {{620 150} {720 250} {380 590} {280 490}}}] \
    [faceGlyph [list [faceRegular 500 460 430 16 0.5] \
        [lreverse [faceRegular 500 460 250 16 0.5]]]] \
    [faceGlyph {{{60 250} {940 250} {940 670} {60 670}}}] \
    [faceGlyph [list [faceRegular 500 460 140 5 0.25]]] \
    [faceGlyph {{{500 830} {180 500} {380 500} {380 120} {620 120} {620 500} \
                 {820 500}}}]]

# Eleven more empty glyphs: the base glyphs the cmap points at. A colour face
# is built the other way round from an ordinary one - the characters point at
# glyphs that have no outline, and every picture sits in a shape nothing
# addresses directly.
foreach unused {1 2 3 4 5 6 7 8 9 10} {
    lappend layerGlyphs {}
}

# blue, green, red, alpha - the order the format stores them in.
#
#  0 deep blue   1 sky blue    2 green      3 amber     4 red
#  5 white       6 near black  7 violet     8 orange    9 teal
set faceColours {
    {150 60 20 255}
    {235 175 60 255}
    {90 165 40 255}
    {40 175 245 255}
    {60 55 215 255}
    {255 255 255 255}
    {35 30 25 255}
    {190 70 130 255}
    {30 130 250 255}
    {150 150 20 255}
}

# --- the colour glyphs ------------------------------------------------------
#
# Base glyphs 9 to 18, one per character. Each is the ROOT of a paint graph.

set faceBase {}
set faceLayers {}
set faceClips {}

# U+E000 - a flat badge. The simplest well-formed version 1 glyph there is: a
# shape and a solid fill, which is all version 0 could ever express.
lappend faceBase {9 {glyph 1 {solid 0 1.0}}}

# U+E001 - the same badge under a LINEAR gradient. Three points: the colour
# line runs from p0 to p1, and p2 says which way the colours are projected on
# either side of it. Here p0p2 is vertical, so the gradient runs across.
lappend faceBase [list 10 [list glyph 1 [list linear pad \
    {{0.0 0 1.0} {0.5 8 1.0} {1.0 3 1.0}} {70 460} {930 460} {70 890}]]]

# U+E002 - a RADIAL gradient: two circles, a small one inside a large one, so
# the colour radiates outwards from off-centre. PDF's type 3 shading is the
# same construction under another name, circle for circle.
lappend faceBase [list 11 [list glyph 1 [list radial pad \
    {{0.0 5 1.0} {0.35 1 1.0} {1.0 0 1.0}} {350 640} 30 {500 460} 520]]]

# U+E003 - a SWEEP gradient, which PDF has no shading type for at all: the
# colour depends on the ANGLE around a centre. It becomes a fan of Gouraud
# triangles, one per four degrees plus one per colour stop. A WHOLE turn, 0
# to 360, and it fits in the two-byte field because of the bias - see
# [faceF2Dot14].
lappend faceBase [list 12 [list glyph 1 [list sweep pad \
    {{0.0 4 1.0} {0.25 8 1.0} {0.5 2 1.0} {0.75 3 1.0} {1.0 4 1.0}} \
    {500 460} 0 360]]]

# U+E004 - LAYERS. A PaintColrLayers slices the LayerList, bottom of the
# z-order first: an amber badge, a gradient ring over it, and a white tick on
# top. Version 0 could stack layers too; what it could not do is put a
# gradient in one of them.
lappend faceBase {13 {layers 0 3}}
lappend faceLayers {glyph 1 {solid 2 1.0}}
lappend faceLayers [list glyph 5 [list linear pad \
    {{0.0 5 0.75} {1.0 5 0.0}} {500 890} {500 30} {930 890}]]
lappend faceLayers {glyph 2 {solid 5 1.0}}

# U+E005 - a TRANSFORMATION. The whole sub-graph below a PaintRotateAroundCenter
# turns, gradient and all - in PDF one "cm" inside a q/Q bracket.
lappend faceBase [list 14 [list rotateCenter -15 500 460 [list layers 3 2]]]
lappend faceLayers [list glyph 6 [list linear pad \
    {{0.0 7 1.0} {1.0 4 1.0}} {60 460} {940 460} {60 620}]]
lappend faceLayers {glyph 7 {solid 5 1.0}}

# U+E006 - COMPOSITING with a blend mode. Soft Light (mode 20) is one of the
# fifteen modes the CompositeMode enumeration shares with PDF, so it is a /BM
# in an ExtGState - inside an isolated transparency group, because a blend
# mode blends against everything already on the page and this one is meant to
# blend against its own backdrop alone.
lappend faceBase [list 15 [list composite 20 \
    [list glyph 1 [list linear pad {{0.0 5 1.0} {1.0 6 1.0}} \
        {500 890} {500 30} {930 890}]] \
    [list glyph 1 [list radial pad {{0.0 1 1.0} {1.0 0 1.0}} \
        {400 620} 20 {500 460} 500]]]]

# U+E007 - COMPOSITING with Source In (mode 5), which PDF has no operator for:
# the source is painted where the backdrop is OPAQUE. Here a gradient is
# poured into the shape of a cross - and because that backdrop is one opaque
# outline, "where it is opaque" is a CLIP PATH and needs no mask at all. 316
# of Noto Color Emoji's 578 composites are this mode; the alpha soft mask the
# construction started out as is what a backdrop of several outlines that
# wind against each other still gets.
lappend faceBase [list 16 [list composite 5 \
    [list glyph 1 [list linear pad {{0.0 4 1.0} {1.0 8 1.0}} \
        {70 890} {930 30} {930 890}]] \
    {glyph 4 {solid 6 1.0}}]]

# U+E008 - a gradient that FADES OUT. A PDF shading has no alpha channel, so
# this is the same shading painted over and over in nested bands of constant
# alpha, one clip and one /ca per 1/64 step. Nearly half of a real emoji
# face's colour lines are of this kind: a soft edge is drawn by fading, not by
# clipping - and this document holds no soft mask at all.
lappend faceBase [list 17 [list layers 5 2]]
lappend faceLayers {glyph 1 {solid 9 1.0}}
lappend faceLayers [list glyph 1 [list linear pad \
    {{0.0 5 0.9} {1.0 5 0.0}} {500 890} {500 60} {930 890}]]

# U+E009 - RE-USE. A PaintColrGlyph names another base glyph and incorporates
# its whole graph, so one component can serve many symbols; the exclamation
# bar is laid over the badge of U+E001 without a second copy of it anywhere.
lappend faceBase {18 {layers 7 2}}
lappend faceLayers {colrGlyph 10}
lappend faceLayers {glyph 3 {solid 5 1.0}}

# Precomputed bounds for every colour glyph. A version 1 glyph MUST be
# bounded, and a ClipList is the font's own answer to that; without one the
# package walks the graph and unions the shapes it finds. This one is
# deliberately wider than the shapes, so that the fills have somewhere to
# reach.
lappend faceClips {9 18 {-20 -60 1020 920}}

# One more character, U+E00A, described the OLD way in the same table: a
# version 1 font may carry version 0 records beside its paint graphs, and the
# package reads whichever half a glyph is in.
set faceV0 {{19 0 2}}
set faceV0Layers {{1 4} {7 5}}

set faceMap [dict create 0xE000 9 0xE001 10 0xE002 11 0xE003 12 0xE004 13 \
    0xE005 14 0xE006 15 0xE007 16 0xE008 17 0xE009 18 0xE00A 19 0xE00B 8]

set workshop [exampleTempDirectory]
set facePath [file join $workshop badges.ttf]
exampleWriteBinary $facePath [faceFile $layerGlyphs $faceMap \
    [faceColr $faceBase $faceLayers $faceClips $faceV0 $faceV0Layers] \
    [faceCpal $faceColours]]

# --- the document -----------------------------------------------------------

set flat 
set linear 
set radial 
set sweep 
set layers 
set turned 
set blended 
set punched 
set faded 
set reused 
set old 
set plain 

set doc [tclpdf new -unit mm]
$doc info Title "A COLR version 1 colour font"
$doc info Author "tclpdf example 2.17"
$doc page add

$doc font embed body [file join $assets fonts DejaVuSans.ttf]

# THE ONE CALL this page is about, and it is the same call example 2.14 makes.
set badges [$doc colorFont badges $facePath \
    -chars "$flat$linear$radial$sweep$layers$turned$blended$punched$faded$reused$old$plain"]

set y 20
exampleHeading $doc y "A COLR version 1 colour font"
examplePara $doc y "COLR version 0, which example 2.14 draws, describes a\
    colour glyph as a flat list of outlines each filled with one solid colour.\
    VERSION 1 replaces that list with a graph: the leaves are solid colours\
    and linear, radial and sweep gradients, and the branches clip, transform\
    and composite what hangs below them. Every emoji face made since about\
    2021 is built that way, and so is every display face that draws its\
    letters in gradients."
examplePara $doc y "The call does not change. \[colorFont\] reads whichever\
    version the face carries - a face may use version 1 for some glyphs and\
    version 0 for others, which the standard allows - and what comes out is a\
    Type 3 font either way: a family like any other."

set y [expr {$y + 2}]
$doc font -family $badges -size 20 -color {0.1 0.1 0.15}
set x 20
foreach badge [list $flat $linear $radial $sweep $layers $turned $blended \
        $punched $faded $reused $old] {
    $doc text $badge -at [list $x [expr {$y + 8}]]
    set x [expr {$x + [$doc textWidth $badge] + 2}]
}
set y [expr {$y + 15}]
$doc font -family body -size 9 -color {0.45 0.45 0.5}
$doc text "solid, linear, radial, sweep, layers, rotated, soft-light,\
    source-in, faded, re-used - and the last one is a version 0 glyph in the\
    same table" -at [list 20 $y] -width 170
set y [expr {$y + 10}]

# -- what each of them is ----------------------------------------------------

$doc font -family body -size 10 -color {0 0 0}
exampleHeading $doc y "One row per paint kind"
examplePara $doc y "Each mark below is one badge at 16 pt with the paint\
    record it is made of beside it. Nothing here is drawn on the page: it is\
    all inside the glyph, which is why the marks scale, move and measure like\
    letters."

set rows [list \
    $flat "PaintSolid - a shape and one palette colour, all version 0 could do" \
    $linear "PaintLinearGradient - three points, the third one a rotation" \
    $radial "PaintRadialGradient - two circles, PDF's type 3 shading exactly" \
    $sweep "PaintSweepGradient - by angle, and PDF has no such shading at all" \
    $layers "PaintColrLayers - a slice of the layer list, bottom first" \
    $turned "PaintRotateAroundCenter - the sub-graph turns, gradient and all" \
    $blended "PaintComposite, Soft Light - a PDF blend mode in a group" \
    $punched "PaintComposite, Source In - a gradient poured into a shape" \
    $faded "a colour line that fades - one shading in bands of constant alpha" \
    $reused "PaintColrGlyph - another glyph's graph, incorporated here" \
    $old "a version 0 record in the same table, read by the older road"]

set y [expr {$y + 1}]
foreach {badge wording} $rows {
    $doc font -family $badges -size 12
    $doc text $badge -at [list 22 $y]
    $doc font -family body -size 9 -color {0.1 0.1 0.15}
    $doc text $wording -at [list 32 $y]
    set y [expr {$y + 6}]
}
set y [expr {$y + 4}]

# -- it is a font ------------------------------------------------------------

$doc page add
set y 20
$doc font -family body -size 10 -color {0 0 0}
exampleHeading $doc y "It is a font, gradients and all"
examplePara $doc y "The same four badges at five sizes. Nothing is scaled by\
    hand and no gradient is re-computed: the shadings are written in FONT\
    UNITS inside the glyph streams, and the /FontMatrix carries the em. A\
    gradient painted through a shading PATTERN could not do this - a pattern\
    is anchored to the page and would stay put while the glyph moved - which\
    is why every gradient here is a clipping path with an \"sh\" inside it."

set y [expr {$y + 2}]
set x 20
foreach size {7 10 14 20 28} {
    $doc font -family $badges -size $size -color {0 0 0}
    $doc text "$linear$radial$sweep$punched" -at [list $x [expr {$y + 12}]]
    set x [expr {$x + [$doc textWidth "$linear$radial$sweep$punched"] + 3}]
}
set y [expr {$y + 20}]

# -- the glyph without a COLR entry ------------------------------------------

$doc font -family body -size 10 -color {0 0 0}
exampleHeading $doc y "A glyph the table says nothing about"
examplePara $doc y "A colour face carries ordinary glyphs beside its coloured\
    ones, and the answer for one of those is its own outline in the colour of\
    the text - like a letter. The arrow below is such a glyph: it has no\
    entry in either half of the COLR table, so it follows -color while the\
    badge beside it does not."

set y [expr {$y + 2}]
set x 20
foreach colour {{0 0 0} {0.75 0.35 0.10} {0.10 0.55 0.30} {0.35 0.15 0.65}} {
    $doc font -family $badges -size 18 -color $colour
    $doc text "$plain$linear" -at [list $x [expr {$y + 7}]]
    set x [expr {$x + [$doc textWidth "$plain$linear"] + 4}]
}
set y [expr {$y + 14}]
$doc font -family body -size 9 -color {0.45 0.45 0.5}
$doc text "black, orange, green, violet - and the badge keeps its gradient" \
    -at [list 20 $y]
set y [expr {$y + 10}]

# -- in the running text -----------------------------------------------------

$doc font -family body -size 10 -color {0 0 0}
exampleHeading $doc y "In the running text"
examplePara $doc y "One string, one call, two faces: -fallback names the faces\
    that may set what -family cannot, so the package decides per character\
    where each glyph comes from. A gradient badge breaks with the paragraph\
    like any other character."

set y [expr {$y + 2}]
$doc font -family body -size 11 -color {0.1 0.1 0.15} -fallback $badges
set y [expr {[$doc text "$flat Delivery 2026-0414 has left the warehouse.\
    $punched Two of the four pallets were refused at the door $linear and are\
    on their way back; the remaining two were accepted $layers and signed for\
    at 14:20. Please tell us what to do with the returns. $reused" \
    -at [list 20 $y] -width 170] + 6}]
$doc font -family body -size 9 -color {0.45 0.45 0.5} -fallback {}

# -- what is refused ---------------------------------------------------------

$doc font -family body -size 10 -color {0 0 0}
exampleHeading $doc y "What is refused rather than drawn wrongly"
examplePara $doc y "Two things in COLR version 1 have no PDF spelling at all,\
    and both are refused by name instead of coming out as something the font\
    never asked for. The Plus composite mode ADDS the two colours and clamps\
    the sum; PDF has fifteen blend modes and no additive one. And a colour\
    STOP whose palette index is the 0xFFFF sentinel means \"whatever colour\
    the text has\" - which is decided when the glyph is drawn, while a\
    shading's colours stand in the file."

set refusal "it was accepted, which it should not have been"
set brokenColr [faceColr [list [list 9 [list composite 12 \
    {glyph 2 {solid 5 1.0}} {glyph 1 {solid 0 1.0}}]]] {} $faceClips]
try {
    $doc colorFont broken -data [faceFile $layerGlyphs $faceMap $brokenColr \
        [faceCpal $faceColours]] -chars $flat
} trap {TCLPDF COLORFONT COMPOSITE} {message} {
    set refusal $message
}
examplePara $doc y "The message, caught from this very page: $refusal" \
    {0.55 0.15 0.15}

# -- check it yourself -------------------------------------------------------

$doc font -family body -size 10 -color {0 0 0}
exampleHeading $doc y "Check it yourself"
examplePara $doc y "The first command shows the Type 3 font: no font file\
    anywhere, a /CharProcs entry per badge, and the font's own /Resources\
    carrying the shadings and the graphics states the glyphs need. The second\
    prints a glyph stream - a clip, an \"sh\" and the brackets around them.\
    The third counts the shadings in the file, and the fourth is the one that\
    matters for a reader."
exampleCommandBlock $doc y [list \
    "qpdf --qdf --object-streams=disable [file tail $target] - | grep -A24 Type3" \
    "qpdf --qdf --object-streams=disable [file tail $target] - | grep -B2 -A30 ' d0'" \
    "qpdf --qdf --object-streams=disable [file tail $target] - | grep -c ShadingType" \
    "pdftotext [file tail $target] - | head -20"]

exampleFooter $doc body

$doc write $target
puts "  written: $target ([file size $target] bytes)"
set info [$doc font info $badges]
puts "  colour font \"$badges\": [dict get $info glyphs] glyphs,\
    [format %.0f [dict get $info unitsPerEm]] units to the em, built from a\
    [file size $facePath]-byte face"
$doc destroy
file delete -force $workshop
