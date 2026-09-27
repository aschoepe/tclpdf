#!/usr/bin/env tclsh
#
# tclpdf example 1.17 - a bold word in flowing text: runs, headings and tags
#
#   tclsh examples/01.17-markup.tcl ?output.pdf?
#
# Until 1.4 a paragraph was set in ONE face: a bold word inside it meant a
# table cell or a line assembled by hand from [textWidth]. This example sets
# the same page twice - once written with tags, once as the list of runs the
# tags become - and the two blocks come out of the same code, because the
# tags are only a notation for the list.
#
# THE LIST IS THE PRIMITIVE. [text -runs 1] takes pairs of {text options}:
# the options of a run are -style (bold, italic, both), -underline,
# -strike, -url and, for a paragraph of its own, -heading 1, 2 or 3. The
# line breaker runs over all of it, measures every piece in its own face and
# sets it with its own Tf. What a run may NOT change is the size and the
# colour - those belong to the paragraph, which is what keeps every line one
# height and the whole road one road. A heading changes the size, and that
# is why a heading is a paragraph rather than a run: 1.6, 1.3 and 1.15 times
# the block's size, bold, with a leading of its own, and never the last line
# of a page.
#
# THE TAGS ARE THE NOTATION: -markup tags reads <b>, <i>, <u>, <s>, <em>,
# <strong>, <a href="...">, <h1> to <h3> and <p>, and nothing else between
# angle brackets is a tag - a "<" in front of a space, a digit or the end is
# text, and &lt; writes one in front of a letter. Tags rather than Markdown,
# because the vocabulary is closed (so the one character to watch is "<"),
# opening and closing are explicit (so a fault is refused with a position),
# and the names are the structure vocabulary of ISO 32000-2, 14.8.4: in a
# tagged document <h1> is an H1 element, <strong> a Strong, <a> a Link.
#
# WHAT THE FACES ARE. The first page sets the standard Helvetica, whose bold
# and oblique the package knows. The second page embeds DejaVu Sans and its
# bold face and registers them as one family with [font family] - which is
# what lets -style bold, and with it <b>, reach an embedded face at all: an
# embedded alias is one face, and before this a caller named the bold alias
# himself wherever a heading stood.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf
# Named outright, because this example calls the translator directly to show
# what the tags become; [text -markup tags] loads it by itself.
package require tclpdf::markup

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "01.17-markup.pdf"}]
set assets [file join $here assets fonts]

# The text, written once with tags. The link goes to the project's site; the
# amount is bold because that is what an invoice does with it; the old price
# is struck through and the term underlined - which are the two decorations
# a paragraph ever needs.
set tagged {<h1>Runs in flowing text</h1>The <b>amount of 1,234.56 EUR</b> is payable by <i>31 October</i>; after that date the price of <s>980.00 EUR</s> no longer applies, and the <u>late payment surcharge</u> becomes due. The conditions are published at <a href="https://fossil.sowaswie.de/tclpdf">fossil.sowaswie.de/tclpdf</a>, where the <strong>complete</strong> terms can be read at any time.
<h2>What the breaker does with it</h2>Every piece is measured in the face it is set in - a bold word is wider than the same word regular - so the line breaks fall where they have to, and a justified line stretches the spaces of every piece by the same amount. A word may cross a run boundary and is still one word to the hyphenator: <b>Betriebs</b>kostenabrechnung breaks inside the bold part or after it, wherever the patterns allow.
<h3>What it does not do</h3>A run does not change the size or the colour. Both belong to the paragraph; a heading is the one thing that changes the size, and it does so as a paragraph of its own. And a run does not kern with its neighbour: bold and regular have no pair table between them in any face.}

# The same text as the list a caller could write by hand: what the tags
# become, and what the package sets in both cases.
set runs [::tclpdf::markup::parse $tagged]

proc page {doc title body args} {
    $doc page add
    $doc font -family helvetica -size 14 -style bold -color black
    $doc text $title -at {20 22}
    $doc font -size 10 -style {}
    $doc text $body -at {20 34} -width 170 -align justify -paragraphSpacing 2 {*}$args
}

set doc [tclpdf new -unit mm]
$doc info Title "Runs, headings and tags in flowing text"

# Page one: Helvetica, written with tags, justified over 170 mm.
page $doc "Written with tags, set in Helvetica" $tagged -markup tags

# Page two: the list form, in an embedded family. [font family] ties the
# regular and the bold face under one name, so that -style bold - and with
# it every <b> and every heading - resolves to the bold face instead of
# being refused, and text without a style resolves to the regular one.
$doc font embed dejavu [file join $assets DejaVuSans.ttf]
$doc font embed dejavuBold [file join $assets DejaVuSans-Bold.ttf]
$doc font family body -regular dejavu -bold dejavuBold
$doc page add
$doc font -family helvetica -size 14 -style bold
$doc text "The same runs as a list, set in an embedded family" -at {20 22}
$doc font -family body -size 10 -style {}

# The family has no italic face - DejaVu Sans ships here in two faces - and
# a run that asks for one is REFUSED, by name, rather than set regular in
# silence: that refusal is the whole point of registering a family. Shown on
# the console, and then the italic runs are set upright for this page.
if {[catch {$doc text $runs -at {20 34} -width 170 -align justify -runs 1 \
        -paragraphSpacing 2} refusal]} {
    puts "  an italic run in a family without an italic face:"
    exampleConsoleParagraph $refusal
}
set upright {}
foreach {text options} $runs {
    if {[dict exists $options style]} {
        set style [lsearch -all -inline -not [dict get $options style] italic]
        if {[llength $style]} {
            dict set options style $style
        } else {
            dict unset options style
        }
    }
    lappend upright $text $options
}
set y [$doc text $upright -at {20 34} -width 170 -align justify -runs 1 \
    -paragraphSpacing 2]

# And what a heading costs in the block: measured, not claimed.
$doc font -family helvetica -size 8 -color {0.45 0.45 0.45}
$doc text "The block above ends at y = [format %.1f $y] mm; the same text\
    without its three headings would end at y = [format %.1f [expr {34 + \
    [$doc textHeight [lrange $upright 4 end] -width 170 -align justify -runs 1 \
    -paragraphSpacing 2 -family body -size 10]}]] mm." -at [list 20 [expr {$y + 8}]] -width 170

exampleFooter $doc
$doc write $target
$doc destroy

puts "  written: $target ([file size $target] bytes)"
puts "  the tags became [expr {[llength $runs] / 2}] runs; the first three:"
foreach {text options} [lrange $runs 0 5] {
    puts "    [format %-40s [list $text]] [list $options]"
}
