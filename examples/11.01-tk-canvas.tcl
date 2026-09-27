#!/usr/bin/env tclsh
#
# tclpdf example 11.1 - a Tk canvas on paper, as vectors
#
#   tclsh examples/11.01-tk-canvas.tcl ?output.pdf?
#
# What is on a canvas widget goes into the document as PATHS - lines, curves
# and text objects - and not as a picture of the screen. The sheet then zooms
# without going soft, the words in it are still words, and the file is a few
# kilobytes rather than a bitmap of the window.
#
# THE WHOLE MECHANISM IS THREE QUESTIONS. A canvas tells anyone who asks what
# it is holding:
#
#   $c find all           the items, in the order they are drawn
#   $c type $id           line, rectangle, oval, polygon, arc, text, image,
#                         bitmap or window
#   $c coords $id         where it is
#   $c itemcget $id -opt  and what it looks like
#
# and that is everything a drawing call needs. [canvasToPdf] below is the
# whole converter; it is shorter than this comment.
#
# AND THE COORDINATES ALREADY AGREE. This package counts y downwards from the
# top of the page, exactly as a canvas counts it downwards from the top of the
# widget, and in "-unit pt" one canvas pixel is one point. So there is no
# conversion at all: a [transform -translate] puts the canvas origin where it
# belongs on the sheet and every number goes through untouched. The arc angles
# agree too - 0 at three o'clock, growing counter-clockwise as the page is
# read - because that is the canvas convention and this package took it.
#
# THIS IS AN EXAMPLE, NOT A CANVAS RENDERER. It draws the five shape types -
# line, rectangle, oval, arc and polygon - a picture and a piece of text, and
# it passes over anything else by name in one line. What it deliberately does not do is listed on the page it writes.
# Whoever wants all of it can write it.
#
# WITHOUT TK IT SKIPS. Tk is not a prerequisite of tclpdf and need not be
# installed for the rest of the examples to run, so a missing Tk - or a
# missing display - prints one line here and writes no document, the way a
# missing validator is a skip and not a failure.
#
# AND THE PACKAGE STILL NEVER CALLS TK. Three calls in this file do - [package
# require Tk], [winfo rgb] to resolve a colour name the canvas took, and
# [image create photo] to hold the picture the canvas shows - and every one of
# them is on the CANVAS side of the fence. tclpdf itself carries its own colour
# table and its own PNG parser and loads on a machine that has no display at
# all, which is the point of that rule; an example whose subject is a Tk widget
# is where the toolkit belongs.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "11.01-tk-canvas.pdf"}]

# The skip, before anything else is done. [package require Tk] fails on a
# machine without Tk and on one with Tk but no display, and both mean the same
# thing here: there is no canvas to read, so there is nothing to show.
if {[catch {package require Tk} message]} {
    puts "  skipped: Tk is not available - [lindex [split $message \n] 0]"
    exit 0
}

# Nothing is meant to appear on screen during a batch of examples. The main
# window exists as soon as Tk is loaded, so it is withdrawn at once, before
# the first widget can map it.
wm withdraw .

# ---------------------------------------------------------------------------
# The converter
# ---------------------------------------------------------------------------

# A Tk colour as this package takes it, or the empty string for an item that
# does not paint that side at all.
#
# The resolving is left to Tk rather than done here: a canvas takes "navy",
# "#ffd700" and "systemTextColor" alike, and [winfo rgb] is the one place that
# knows all three. It answers three values from 0 to 65535.
proc canvasColour {colour} {
    if {$colour eq {}} {
        return {}
    }
    return [lmap value [winfo rgb . $colour] {expr {$value / 65535.0}}]
}

# The Tk anchor as the two words this package uses.
#
# A canvas item hangs on ONE point and says which corner of itself that point
# is; tclpdf names the two axes separately - -align across, and -anchor (on
# text) or -valign (on a picture) down. A [switch] rather than a match on the
# letters: "center" has an "e" in it and a [string match *e*] read it as east.
proc canvasAnchor {anchor} {
    switch -- $anchor {
        n {return {center top}}
        ne {return {right top}}
        e {return {right middle}}
        se {return {right bottom}}
        s {return {center bottom}}
        sw {return {left bottom}}
        w {return {left middle}}
        nw {return {left top}}
    }
    return {center middle}
}

# The stroke of an item, as options ready to be passed on - or nothing at all
# where the item has no outline. The colour option is a parameter because a
# LINE has none: see [canvasToPdf].
proc canvasOutline {c id {option -outline}} {
    set colour [canvasColour [$c itemcget $id $option]]
    if {$colour eq {}} {
        return {}
    }
    set options [list -stroke $colour -width [$c itemcget $id -width]]
    # Tk also writes a dash as a pattern of dots and dashes ("-." and its
    # relatives), which is not a list of lengths and is passed over here.
    set dash [$c itemcget $id -dash]
    if {[llength $dash] && [string is double -strict [lindex $dash 0]]} {
        lappend options -dash $dash
    }
    return $options
}

proc canvasFill {c id} {
    set colour [canvasColour [$c itemcget $id -fill]]
    if {$colour eq {}} {
        return {}
    }
    return [list -fill $colour]
}

# Draw every item of canvas $c into $doc, at the document's current origin -
# the caller has put that where it wants the canvas to sit. Returns the items
# it did not draw, as "type id" strings.
proc canvasToPdf {doc c} {
    set skipped {}
    foreach id [$c find all] {
        set type [$c type $id]
        set coords [$c coords $id]
        switch -- $type {
            line {
                # On a LINE, -fill is the colour of the STROKE - a line has no
                # inside. That is the one place where the two vocabularies do
                # not line up, and reading it as a fill draws nothing at all.
                set options [canvasOutline $c $id -fill]
                if {[llength $coords] == 4} {
                    $doc line -from [lrange $coords 0 1] \
                        -to [lrange $coords 2 3] {*}$options
                } else {
                    $doc polygon -points $coords -close 0 {*}$options
                }
            }
            rectangle {
                lassign $coords x1 y1 x2 y2
                $doc rect -at [list [expr {min($x1, $x2)}] \
                        [expr {min($y1, $y2)}]] \
                    -size [list [expr {abs($x2 - $x1)}] \
                        [expr {abs($y2 - $y1)}]] \
                    {*}[canvasFill $c $id] {*}[canvasOutline $c $id]
            }
            oval - arc {
                # Both are described by a BOUNDING BOX on the canvas and by a
                # centre with two extents here. That is the only arithmetic in
                # this file.
                lassign $coords x1 y1 x2 y2
                set at [list [expr {($x1 + $x2) / 2.0}] \
                    [expr {($y1 + $y2) / 2.0}]]
                set size [list [expr {abs($x2 - $x1)}] [expr {abs($y2 - $y1)}]]
                if {$type eq "oval"} {
                    $doc ellipse -at $at -size $size \
                        {*}[canvasFill $c $id] {*}[canvasOutline $c $id]
                    continue
                }
                set style [$c itemcget $id -style]
                set options [canvasOutline $c $id]
                # -style arc is an OPEN path, and this package refuses to fill
                # one rather than close it behind the caller's back; Tk
                # ignores the -fill of such an item just as quietly. Dropping
                # it here is what puts on paper what the screen shows.
                if {$style ne "arc"} {
                    lappend options {*}[canvasFill $c $id]
                }
                $doc arc -at $at -size $size -start [$c itemcget $id -start] \
                    -extent [$c itemcget $id -extent] -style $style {*}$options
            }
            polygon {
                # -points is one FLAT list, which is what [coords] answers.
                $doc polygon -points $coords \
                    {*}[canvasFill $c $id] {*}[canvasOutline $c $id]
            }
            text {
                set colour [canvasColour [$c itemcget $id -fill]]
                if {$colour eq {}} {
                    continue
                }
                lassign [canvasAnchor [$c itemcget $id -anchor]] align anchor
                # The SIZE comes from Tk, the FACE does not. TkDefaultFont
                # resolves to ".AppleSystemUIFont" on this machine - a system
                # face with no PDF equivalent and no right to be embedded - so
                # mapping Tk's font names onto files a document may carry is a
                # topic of its own, and this example does not open it. A
                # negative size is Tk's way of saying pixels.
                set size [expr {abs([font actual \
                    [$c itemcget $id -font] -size])}]
                $doc font -family helvetica -size $size -color $colour
                $doc text [$c itemcget $id -text] -at $coords \
                    -align $align -anchor $anchor
            }
            image {
                # A Tk photo needs no file on the way in: [$photo data] hands
                # over the bytes of a PNG, and [image embed -data] takes them.
                set photo [$c itemcget $id -image]
                lassign [canvasAnchor [$c itemcget $id -anchor]] align valign
                $doc image embed canvas$id -data [$photo data -format png]
                $doc image place canvas$id -at $coords \
                    -size [list [image width $photo] [image height $photo]] \
                    -align $align -valign $valign
            }
            default {
                lappend skipped "$type item $id"
            }
        }
    }
    return $skipped
}

# ---------------------------------------------------------------------------
# A canvas to convert
# ---------------------------------------------------------------------------

set width 420
set height 240

canvas .c -width $width -height $height -background #f4f4ee \
    -highlightthickness 0

# The four closed shapes, and a picture.
.c create rectangle 20 20 130 80 -fill lightblue -outline navy -width 2
.c create oval 150 20 230 80 -fill {} -outline #b03030 -width 3 -dash {6 3}
.c create polygon 250 80 290 20 330 80 -fill #7fb069 -outline darkgreen

# A photo, scaled by [copy -subsample] rather than by [configure -width]: the
# second one CROPS the picture to that many pixels, which is not what a reader
# of this file would expect it to mean.
image create photo canvasSource \
    -file [file join $here assets images sample-indexed.png]
image create photo canvasPicture
canvasPicture copy canvasSource -subsample 10 10
.c create image 385 50 -image canvasPicture -anchor center

# The three arc styles side by side, on the same box and the same sweep, so
# that the sheet shows what the three words mean.
foreach {x style colour} {20 pieslice #e0a030 100 chord #9060c0 180 arc {}} {
    .c create arc $x 100 [expr {$x + 60}] 160 -start 35 -extent 250 \
        -style $style -fill $colour -outline black
}

# Two lines: one of two points, one of five. The canvas makes no distinction
# between them and [coords] answers both the same way.
.c create line 260 100 340 160 -fill red -width 3 -dash {4 2}
.c create line 355 160 375 110 395 160 415 115 -fill #305090 -width 2

.c create text 20 205 -anchor w -text "text, anchored west" \
    -font {Helvetica 11} -fill #303030

# One item this example does NOT draw, so that the skip can be seen rather
# than only claimed. A bitmap is a stencil the toolkit ships and a window item
# is a whole widget; neither is a path, and both are somebody else's afternoon.
.c create bitmap 400 205 -bitmap questhead -anchor center

# ---------------------------------------------------------------------------
# The page
# ---------------------------------------------------------------------------

# pt, because that is the unit in which the conversion disappears: a canvas
# pixel is a point, so every coordinate below is the canvas's own.
set doc [tclpdf new -unit pt -format a4]
$doc info Title "A Tk canvas as vectors"
$doc info Author "tclpdf example 11.1"
$doc page add

set left 57
set measure 481

proc heading {doc yName text} {
    upvar 1 $yName y
    $doc font -family helvetica -style bold -size 12 -color {0 0 0}
    $doc text $text -at [list $::left $y] -anchor top
    set y [expr {$y + 20}]
    return
}

proc para {doc yName text {colour {0 0 0}}} {
    upvar 1 $yName y
    $doc font -family helvetica -style {} -size 9.5 -color $colour
    set y [expr {[$doc text $text -at [list $::left $y] -width $::measure \
        -anchor top] + 12}]
    return
}

set y 57
heading $doc y "A Tk canvas as vectors"
para $doc y "Everything in the frame below was read off a Tk canvas widget\
    and drawn again as paths. Three questions are the whole mechanism: \[\$c\
    find all\] hands over the items in drawing order, \[\$c type \$id\] says\
    what each one is, and \[\$c coords\] with \[\$c itemcget\] say where it is\
    and what it looks like."
para $doc y "The conversion itself is almost nothing, and that is the point.\
    This package counts y downwards from the top of the page just as a canvas\
    counts it downwards from the top of the widget, and in -unit pt one canvas\
    pixel is one point - so a transform -translate puts the canvas origin on\
    the sheet and every coordinate goes through untouched. The arc angles need\
    no conversion either: zero at three o'clock, growing counter-clockwise as\
    the page is read, which is the canvas convention. Only an oval and an arc\
    are recomputed at all, because the canvas describes them by their bounding\
    box and this package by a centre and two extents."

heading $doc y "Where this example stops"
para $doc y "It is an example, not a canvas renderer, and it has no claim to\
    completeness. Five shape types - line, rectangle, oval, arc and polygon -\
    a photo and a line of text are drawn; a\
    bitmap and a window item are passed over by name in one line, and the\
    console says so. Stipples, arrows, smoothed lines, tags and states,\
    Tk's dash patterns written as \"-.\", and a faithful mapping of Tk's font\
    names onto embeddable faces are all left out - the last one is a topic of\
    its own, so every piece of text here is set in Helvetica at the size Tk\
    reports. One thing is dropped on purpose: an arc of -style arc is an open\
    path, which this package refuses to fill rather than closing it in\
    silence, and Tk ignores the fill of such an item just as quietly - so the\
    third arc below is an outline on paper as it is on screen."

# -- the canvas itself ------------------------------------------------------

set originX $left
set originY [expr {$y + 4}]

$doc save
$doc transform -translate [list $originX $originY]

# The widget's own background, which is a property of the canvas and not of
# any item: [cget], not [itemcget].
$doc rect -at {0 0} -size [list $width $height] \
    -fill [canvasColour [.c cget -background]] -stroke {0.75 0.75 0.8}

set skipped [canvasToPdf $doc .c]

$doc restore

set y [expr {$originY + $height + 16}]
$doc font -family helvetica -style {} -size 8 -color {0.45 0.45 0.5}
$doc text "[llength [.c find all]] canvas items,\
    [expr {[llength [.c find all]] - [llength $skipped]}] of them drawn;\
    skipped: [expr {[llength $skipped] ? [join $skipped {, }] : "nothing"}]" \
    -at [list $left $y] -anchor top
set y [expr {$y + 20}]

heading $doc y "Check it yourself"
# "grep -a" and not a plain grep: a decompressed PDF still holds the bytes of
# the picture, and BSD grep answers "binary file matches" and no count at all
# for a file with a null byte in it. The answer is 2 - the widget background
# and the one rectangle item.
$doc font -family courier -style {} -size 8.5 -color {0 0 0}
foreach command [list \
        "qpdf --check [file tail $target]" \
        "qpdf --qdf --object-streams=disable [file tail $target] - |\
            grep -ac ' re\$'" \
        "pdftotext [file tail $target] - | grep 'anchored west'"] {
    $doc text $command -at [list $left $y] -anchor top
    set y [expr {$y + 12}]
}

exampleFooter $doc helvetica

$doc write $target
puts "  written: $target ([file size $target] bytes)"
foreach id [.c find all] {
    puts "  [format %-10s [.c type $id]] coords=[.c coords $id]"
}
if {[llength $skipped]} {
    puts "  skipped, not drawn: [join $skipped {, }]"
}
$doc destroy

# THE LAST LINE IS NOT DECORATION. Loading Tk registers a main loop with the
# interpreter, and tclsh then enters it when the script runs out instead of
# returning - measured here: without this line the script never ends, and
# "make examples" would wait for a window that is withdrawn. So the example
# says when it is done, on both roads out.
exit 0
