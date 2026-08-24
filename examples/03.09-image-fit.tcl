#!/usr/bin/env tclsh
#
# tclpdf example 3.9 - fitting a picture into a box, and where -at sits on it
#
#   tclsh examples/03.09-image-fit.tcl ?output.pdf?
#
# Four options that add no capability and save a caller a page of arithmetic:
#
#   -fit {w h}     the box the picture goes into, proportions kept
#   -fitMode       contain (the whole picture inside the box, the default) or
#                  cover (the whole box covered, the overhang cut away)
#   -align         left, center or right - which point of the picture the x
#                  of -at names, and where in the box it sits across
#   -valign        top, middle or bottom - the same question down the page
#
# -at names the TOP LEFT CORNER OF THE BOX, exactly as it names the top left
# corner of a [rect]. Without -fit the box has no size, so the two anchors are
# then the plain "which corner is -at": a logo whose right edge is to sit on
# the right margin is -at {190 y} -align right, and nothing has to be measured
# first.
#
# The words are the ones this package already uses for the two axes - [text]
# aligns a line left, center or right on the point it is given, and a table
# cell sits top, middle or bottom in its row. They are deliberately NOT called
# -anchor: [text] has an -anchor and it means baseline or top, one AXIS rather
# than a corner, and a picture's "-anchor top" would have to mean top edge AND
# centred across. One word, two senses, in one package.
#
# The last page shows [initialView], which is not about pictures at all but
# about how the document OPENS: which panel the reader shows beside the page
# (/PageMode), how it arranges the pages (/PageLayout), and where it puts the
# reader first (/OpenAction). This file opens on page 2, in two columns, with
# the bookmark pane out.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "03.09-image-fit.pdf"}]
set images [file join $here assets images]
set photo [file join $images sample-photo.jpg]

set doc [tclpdf new -unit mm]
$doc info Title "tclpdf example: fitting pictures into boxes"
$doc page add
$doc image embed photo $photo

$doc font -family helvetica -style bold -size 14
$doc text "Fitting a picture into a box" -at {20 20}
$doc font -style {} -size 8
lassign [$doc image size photo] naturalWidth naturalHeight
$doc text [format "The photograph is %d by %d pixels and states no\
    resolution, so its natural size is %.1f by %.1f mm - four by three. Every\
    box below is 50 by 50, a square, so contain and cover always differ.\
    The thin rule is the box; the picture is what is inside it." \
    [dict get [$doc image info photo] width] \
    [dict get [$doc image info photo] height] \
    $naturalWidth $naturalHeight] -at {20 27} -width 170

# -- contain: the whole picture inside the box ------------------------------

# A box drawn first, so that the leftover bands are visible. The picture then
# goes into the SAME rectangle, and -align/-valign decide where in it it sits.
proc fitBox {doc x y label args} {
    $doc rect -at [list $x $y] -size {50 50} -stroke {gray 0.75} -width 0.2
    $doc image place photo -at [list $x $y] -fit {50 50} -artifact 1 {*}$args
    $doc font -family helvetica -size 7 -color {gray 0.3}
    $doc text $label -at [list $x [expr {$y + 53}]]
    $doc font -color black
}

$doc font -style bold -size 10
$doc text "contain - the whole picture inside the box" -at {20 45}
$doc font -style {} -size 8
$doc text "The picture is scaled until BOTH edges fit, which leaves a band on\
    the axis that had room to spare. -valign says where the band goes." \
    -at {20 51} -width 170

fitBox $doc 20 58 "-valign top (the default)"
fitBox $doc 80 58 "-valign middle" -valign middle
fitBox $doc 140 58 "-valign bottom" -valign bottom

# -- cover: the whole box covered -------------------------------------------

$doc font -style bold -size 10
$doc text "cover - the whole box covered, the overhang cut away" -at {20 125}
$doc font -style {} -size 8
$doc text "The picture is scaled until NEITHER edge falls short, so it hangs\
    over the box on one axis and is clipped back to it. -align then decides\
    which part of the picture survives - which is the whole point: a portrait\
    is cropped at the sides, not through the face." -at {20 131} -width 170

proc coverBox {doc x y label args} {
    $doc rect -at [list $x $y] -size {50 50} -stroke {gray 0.75} -width 0.2
    $doc image place photo -at [list $x $y] -fit {50 50} -fitMode cover \
        -artifact 1 {*}$args
    $doc font -family helvetica -size 7 -color {gray 0.3}
    $doc text $label -at [list $x [expr {$y + 53}]]
    $doc font -color black
}

coverBox $doc 20 142 "-align left (the default)"
coverBox $doc 80 142 "-align center" -align center
coverBox $doc 140 142 "-align right" -align right

$doc font -size 8
$doc text "A picture that covers its box declares the BOX as its bounding\
    box in a tagged document, not the placement: ISO 32000-2, 14.8.5.4.3 asks\
    for the rectangle that encloses the VISIBLE content, and three quarters of\
    a covering picture is not visible." -at {20 205} -width 170

# -- the anchors without a box ----------------------------------------------

$doc page add
$doc font -family helvetica -style bold -size 14
$doc text "The same two options without a box" -at {20 20}
$doc font -style {} -size 8
$doc text "Without -fit the box has no size, and the same arithmetic is the\
    plain anchor: the corner moves by the fraction times the picture's own\
    extent. The cross marks -at in each case." -at {20 27} -width 170

# The nine positions, each on its own cross - one call apiece, and the caller
# measures nothing.
set row 0
foreach valign {top middle bottom} {
    set column 0
    foreach align {left center right} {
        set x [expr {40 + $column * 60}]
        set y [expr {55 + $row * 60}]
        $doc image place photo -at [list $x $y] -width 30 \
            -align $align -valign $valign -artifact 1
        # The cross: two 6 mm rules crossing exactly on -at.
        $doc line -from [list [expr {$x - 3}] $y] -to [list [expr {$x + 3}] $y] \
            -stroke red -width 0.3
        $doc line -from [list $x [expr {$y - 3}]] -to [list $x [expr {$y + 3}]] \
            -stroke red -width 0.3
        $doc font -family helvetica -size 7 -color {gray 0.3}
        $doc text "-align $align -valign $valign" -at [list [expr {$x - 25}] \
            [expr {$y + 26}]]
        $doc font -color black
        incr column
    }
    incr row
}

$doc font -size 8
$doc text "The right column is what this is for: a logo whose right edge is\
    to sit on the right margin of the type area needs -align right and no\
    arithmetic at all, and it stays right where the logo is replaced by one of\
    another shape." -at {20 245} -width 170

# -- what a box and a turn cannot both be -----------------------------------
#
# -rotate turns the placement about the point -at names, and the three options
# above describe an UPRIGHT box - so a fitted picture turned by 90 degrees
# comes out beside its box, and a covered box is cut by a rectangle standing
# at an angle to the picture. The two are refused together rather than defined
# one way or the other; the way out is one call, and it is what the message
# says.
catch {$doc image place photo -at {20 20} -fit {40 40} -rotate 90} message
$doc font -family courier -size 7 -color {gray 0.3}
$doc text "\$doc image place photo -at {20 20} -fit {40 40} -rotate 90" \
    -at {20 258}
$doc font -family helvetica -size 7
$doc text $message -at {20 263} -width 170
$doc font -size 8 -color black
$doc text "The fitted size is what [$doc image size photo -fit {40 40}] gives,\
    and -size takes it - so a turned picture scaled to a box is one line, and\
    it is the caller who decides where the turn puts it." -at {20 275} \
    -width 170

# -- how the document opens -------------------------------------------------

$doc page add
$doc font -family helvetica -style bold -size 14
$doc text "How the document opens" -at {20 20}
$doc font -style {} -size 8
$doc text "initialView writes the three catalogue entries of ISO 32000-2,\
    Table 28. -pageMode says which panel a reader shows beside the page\
    (UseNone, UseOutlines, UseThumbs, FullScreen, UseOC, UseAttachments),\
    -pageLayout how it arranges the pages (SinglePage, OneColumn,\
    TwoColumnLeft, TwoColumnRight, TwoPageLeft, TwoPageRight), and -page with\
    -to and -zoom where it puts the reader first. They are a command of their\
    own rather than options of viewerPreferences: a viewer preference is a\
    wish a reader may ignore, and these are what it does when the file opens." \
    -at {20 27} -width 170

$doc font -family courier -size 8
$doc text "\$doc initialView -pageMode UseOutlines \\\\" -at {20 62}
$doc text "    -pageLayout TwoColumnLeft -page 1 -to {20 20}" -at {20 66}
$doc font -family helvetica -size 8
$doc text "That is what this file carries, so a reader opens it on page two,\
    in two columns, with the bookmark pane out. An /OpenAction may also be an\
    ACTION rather than a destination, and this command does not write one:\
    measured with veraPDF 1.30, a /Launch and a /JavaScript open action each\
    fail PDF/A clause 6.5.1 - so an -action option would be a promise half of\
    whose values break the moment pdfa is declared. Where one is really\
    wanted, catalogEntry OpenAction takes any dictionary." -at {20 74} -width 170

$doc bookmark "Fitting into a box" -page 0
$doc bookmark "The anchors" -page 1
$doc bookmark "How it opens" -page 2
$doc initialView -pageMode UseOutlines -pageLayout TwoColumnLeft -page 1 \
    -to {20 20}

exampleFooter $doc
$doc write $target
puts "  written: $target ([file size $target] bytes)"
puts "  one picture, [llength [$doc image names]] alias, 21 placements"
$doc destroy
