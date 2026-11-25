#!/usr/bin/env tclsh
#
# tclpdf example 1.17 - a paragraph with runs: as typed, as set - in tags
# and in Markdown
#
#   tclsh examples/01.17-markup.tcl ?output.pdf?
#
# Until 1.5 a paragraph was set in ONE face: a bold word inside it meant a
# table cell or a line assembled by hand from [textWidth]. Since 1.5 the
# string of [text] may carry its own bold, italic, underlined and struck
# words, links and headings - written in one of two notations, which is
# what -markup names. This example shows each notation the same way: the
# text as it was typed, set plain in Courier, and underneath the same string
# set with -markup, so that the eye can go from the source to the result.
#
# PAGE ONE, TAGS: -markup tags reads <b>, <i>, <u>, <s>, <em>, <strong>,
# <a href="...">, <h1> to <h3> and <p>, and nothing else between angle
# brackets is a tag - a "<" in front of a space, a digit or the end is text,
# and &lt; writes one in front of a letter. The names are the structure
# vocabulary of ISO 32000-2, 14.8.4: in a tagged document <h1> is an H1
# element, <strong> a Strong, <a> a Link.
#
# PAGE TWO, MARKDOWN: -markup markdown reads **strong**, *em*, ***both***,
# ~~struck~~, [text](address) and "# ", "## ", "### " at the start of a
# line. That is all of Markdown a run or a heading can be. What it cannot
# say is underline - Markdown has no spelling for it, and "_" is TEXT here
# because it stands in file names and snake_case far more often than around
# a word - so the term the tags underline is set plain on page two. Lists,
# code, quotes, tables and images are not refused either: they come out as
# they were typed.
#
# BOTH ARE STRICT. A tag or a delimiter left open is refused with its
# position; a closing one has to close the innermost open run; a "*" in
# front of a space is text ("5 * 3"). No flanking rules to look up, and no
# price that quietly falls back to plain text because one "*" was
# forgotten. Where the text comes from people - a form field, a remark -
# page three shows the way the caller takes on purpose: [repair] writes each
# refused place as text and names it, and the result is set the strict way.
#
# PAGE FOUR, ROOM AROUND A HEADING: a heading takes its own leading and no
# more, so it stands as close to the paragraph above it as to the one it
# heads. -headingSpacing {before after} adds a gap above and below every
# heading - on top of -paragraphSpacing, which stays the gap between the
# other paragraphs - and none above a heading that opens the block. The
# page sets one text twice, side by side, without and with it, and prints
# what [textHeight] measured for each under the column it drew.
#
# Both translators end in the same list of {text options} pairs
# - built by one procedure from one vocabulary - and from there the road is
# one road, which is what the last line of page two measures rather than
# claims: the two notations break into the same lines, runs and options
# alike, the underline apart.
#
# WHAT A RUN MAY NOT DO: change the size or the colour. Those belong to the
# paragraph, which is what keeps every line one height. A heading changes
# the size, and that is why a heading is a paragraph rather than a run: 1.6,
# 1.3 and 1.15 times the block's size, bold, with a leading of its own, and
# never the last line of a page. The list underneath both notations, and
# how a run reaches an EMBEDDED face, is example 1.18.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf
# Named outright, because the console shows what the two notations become;
# [text -markup] loads each translator by itself when it is asked for.
package require tclpdf::markup
package require tclpdf::markdown

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "01.17-markup.pdf"}]

# The text, written with tags. The amount is bold because that is what an
# invoice does with it; the old price is struck through and the term
# underlined - which are the two decorations a paragraph ever needs.
set tagged {<h1>Runs in flowing text</h1>The <strong>amount of 1,234.56 EUR</strong> is payable by <em>31 October</em>; after that date the price of <s>980.00 EUR</s> no longer applies, and the <u>late payment surcharge</u> becomes due. The conditions are published at <a href="https://fossil.sowaswie.de/tclpdf">fossil.sowaswie.de/tclpdf</a>, where the <strong>complete</strong> terms can be read at any time.
<h2>What the breaker does with it</h2>Every piece is measured in the face it is set in - a bold word is wider than the same word regular - so the line breaks fall where they have to, and a justified line stretches the spaces of every piece by the same amount. A word may cross a run boundary and is still one word to the hyphenator: <strong>Betriebs</strong>kostenabrechnung breaks inside the bold part or after it, wherever the patterns allow.
<h3>What it does not do</h3>A run does not change the size or the colour. Both belong to the paragraph; a heading is the one thing that changes the size, and it does so as a paragraph of its own. And a run does not kern with its neighbour: bold and regular have no pair table between them in any face.}

# The same text in Markdown. A heading stands on a line of its own and ends
# at its line feed - the one layout rule Markdown adds - and the underlined
# term of the tags is plain here, because Markdown cannot say it.
set markdown {# Runs in flowing text
The **amount of 1,234.56 EUR** is payable by *31 October*; after that date the price of ~~980.00 EUR~~ no longer applies, and the late payment surcharge becomes due. The conditions are published at [fossil.sowaswie.de/tclpdf](https://fossil.sowaswie.de/tclpdf), where the **complete** terms can be read at any time.
## What the breaker does with it
Every piece is measured in the face it is set in - a bold word is wider than the same word regular - so the line breaks fall where they have to, and a justified line stretches the spaces of every piece by the same amount. A word may cross a run boundary and is still one word to the hyphenator: **Betriebs**kostenabrechnung breaks inside the bold part or after it, wherever the patterns allow.
### What it does not do
A run does not change the size or the colour. Both belong to the paragraph; a heading is the one thing that changes the size, and it does so as a paragraph of its own. And a run does not kern with its neighbour: bold and regular have no pair table between them in any face.}

set block {-width 170 -align justify -paragraphSpacing 2}

# One page per notation, "as typed, as set" - the page is drawn by
# exampleTypedAndSet in common.tcl, shared with example 1.19.

set doc [tclpdf new -unit mm]
$doc info Title "Runs in flowing text: tags and Markdown, as typed and as set"

exampleTypedAndSet $doc "Written with tags" $tagged tags $block
set y [exampleTypedAndSet $doc "Written in Markdown" $markdown markdown $block]

# The proof - the lines each notation breaks into - is measured and drawn
# by exampleSameLines in common.tcl, shared with 1.19.
exampleSameLines $doc $tagged $markdown $block $y

# PAGE THREE, USER INPUT, REPAIRED: a note typed into a form field, with a
# "**" its writer never closed and a "[4711]" that is no link. The strict
# reading refuses the whole paragraph - the first refusal is caught and
# shown. ::tclpdf::markdown::repair writes both places as text, with a
# backslash, and the paragraph is then set the strict way: the two places
# appear as typed, the rest is formatted, and the codes it removed are
# printed underneath, which is what a caller would log.
set typed {Delivery note: please ring at the side door **before noon - the gate code is [4711], and the parcel goes to *Ms Example* at the desk.}
$doc page add
$doc font -family helvetica -size 14 -style bold -color black
$doc text "User input, repaired" -at {20 22}
$doc font -size 8 -style {} -color {0.45 0.45 0.45}
$doc text "As typed:" -at {20 32}
$doc font -family courier -size 7.5 -color black
set y [$doc text $typed -at {20 37} -width 170]
$doc font -family helvetica -size 8 -color {0.45 0.45 0.45}
if {![catch {$doc text $typed -at [list 20 [expr {$y + 8}]] -width 170 -markup markdown} \
        why refusal]} {
    puts "  the note was not refused - the example lost its point"
    exit 1
}
set y [$doc text "With -markup markdown the paragraph is refused:\
    [dict get $refusal -errorcode]" -at [list 20 [expr {$y + 8}]] -width 170]
set repair [::tclpdf::markdown::repair $typed]
$doc text "Set from \[::tclpdf::markdown::repair\] with -markup markdown:" \
    -at [list 20 [expr {$y + 6}]]
$doc font -size 10 -color black
set y [$doc text [dict get $repair text] -at [list 20 [expr {$y + 15}]] {*}$block \
    -markup markdown]
$doc font -size 8 -color {0.45 0.45 0.45}
$doc text "Written as text, in this order:" -at [list 20 [expr {$y + 8}]]
$doc font -family courier -size 7.5 -color black
$doc text [join [dict get $repair faults] \n] -at [list 20 [expr {$y + 13}]] -width 170

# PAGE FOUR, ROOM AROUND A HEADING: the same Markdown in two columns, the
# left one with -paragraphSpacing alone, the right one with -headingSpacing
# beside it - 5 mm above a heading, 1.5 mm under it.
set sectioned {# Terms of payment
The amount is payable within 14 days of the invoice date, without deduction. A payment is on time when the amount has reached our account by the due date.
## Late payment
After the due date the statutory interest applies, and a reminder is charged at a flat 5.00 EUR.
## Retention of title
The goods remain our property until the amount has been paid in full.
### Place of jurisdiction
The place of jurisdiction is the seat of the seller.}
$doc page add
$doc font -family helvetica -size 14 -style bold -color black
$doc text "Room around a heading" -at {20 22}
set columns [list 20 {} 110 {-headingSpacing {5 1.5}}]
foreach {x gaps} $columns {
    $doc font -family helvetica -size 8 -style {} -color {0.45 0.45 0.45}
    set label "-paragraphSpacing 2"
    if {[llength $gaps]} {
        set label "-paragraphSpacing 2 [lindex $gaps 0] [list [lindex $gaps 1]]"
    }
    $doc text $label -at [list $x 32]
    $doc font -size 10 -color black
    set options [list -width 80 -align justify -paragraphSpacing 2 \
        -markup markdown {*}$gaps]
    set height [$doc textHeight $sectioned {*}$options]
    set y [$doc text $sectioned -at [list $x 40] {*}$options]
    $doc font -size 8 -color {0.45 0.45 0.45}
    $doc text [format "textHeight %.2f mm, drawn %.2f mm" $height \
        [expr {$y - 40}]] -at [list $x [expr {$y + 4}]]
}

exampleFooter $doc
$doc write $target
$doc destroy

puts "  written: $target ([file size $target] bytes)"
puts "  the first three runs of each notation:"
foreach notation {markup markdown} source [list $tagged $markdown] {
    puts "    from $notation:"
    foreach {text options} [lrange [::tclpdf::${notation}::parse $source] 0 5] {
        puts "      [format %-40s [list $text]] [list $options]"
    }
}
puts "  the user input: refused as [dict get $refusal -errorcode];\
    repaired, written as text:"
foreach code [dict get $repair faults] {
    puts "    $code"
}
