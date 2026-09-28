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
# forgotten. Both translators end in the same list of {text options} pairs
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
