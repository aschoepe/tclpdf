#!/usr/bin/env tclsh
#
# tclpdf example 1.18 - the same paragraph in Markdown
#
#   tclsh examples/01.18-markdown.tcl ?output.pdf?
#
# Example 1.17 writes a paragraph with tags. This one writes the same text
# in Markdown - the SECOND notation -markup reads - sets it, sets the tagged
# twin of it underneath, and checks with [textLines] that the two break into
# the same lines, runs and options alike. They cannot differ: both
# translators end in the same list of runs, built by one procedure from one
# vocabulary, and from there on the road is the one of 1.17.
#
# WHAT MARKDOWN SAYS HERE: **strong**, *em*, ***both***, ~~struck~~,
# [text](address) and "# ", "## ", "### " at the start of a line for the
# three headings. That is all of Markdown a run or a heading can be. What it
# cannot say is underline: Markdown has no spelling for it, "_" is emphasis
# in CommonMark and TEXT here - it stands in file names and snake_case far
# more often than around a word - so the underlined term of 1.17 is set
# plain on this page; -markup tags has <u> for a caller who needs one.
# Lists, code, quotes, tables and images are not refused either: they come
# out as they were typed.
#
# AND IT IS STRICT, as the tags are. A "*", "**" or "~~" in front of a space
# is text ("5 * 3"), a closing one has to close the innermost open run, and
# a run left open is refused with its position rather than guessed at - no
# flanking rules to look up. A backslash makes * ~ [ ] # and itself text.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "01.18-markdown.pdf"}]

# The text of 1.17, page one, written in Markdown. A heading stands on a
# line of its own and ends at its line feed, which is the one layout rule
# Markdown adds to the tags.
set markdown {# Runs in flowing text
The **amount of 1,234.56 EUR** is payable by *31 October*; after that date the price of ~~980.00 EUR~~ no longer applies, and the late payment surcharge becomes due. The conditions are published at [fossil.sowaswie.de/tclpdf](https://fossil.sowaswie.de/tclpdf), where the **complete** terms can be read at any time.
## What the breaker does with it
Every piece is measured in the face it is set in - a bold word is wider than the same word regular - so the line breaks fall where they have to, and a justified line stretches the spaces of every piece by the same amount. A word may cross a run boundary and is still one word to the hyphenator: **Betriebs**kostenabrechnung breaks inside the bold part or after it, wherever the patterns allow.
### What it does not do
A run does not change the size or the colour. Both belong to the paragraph; a heading is the one thing that changes the size, and it does so as a paragraph of its own. And a run does not kern with its neighbour: bold and regular have no pair table between them in any face.}

# Its twin in tags. "**" is <strong> and "*" is <em> - not <b> and <i>,
# which set alike but carry no Strong or Em into a tagged document - and
# the term 1.17 underlines is plain here as well.
set tagged {<h1>Runs in flowing text</h1>The <strong>amount of 1,234.56 EUR</strong> is payable by <em>31 October</em>; after that date the price of <s>980.00 EUR</s> no longer applies, and the late payment surcharge becomes due. The conditions are published at <a href="https://fossil.sowaswie.de/tclpdf">fossil.sowaswie.de/tclpdf</a>, where the <strong>complete</strong> terms can be read at any time.
<h2>What the breaker does with it</h2>Every piece is measured in the face it is set in - a bold word is wider than the same word regular - so the line breaks fall where they have to, and a justified line stretches the spaces of every piece by the same amount. A word may cross a run boundary and is still one word to the hyphenator: <strong>Betriebs</strong>kostenabrechnung breaks inside the bold part or after it, wherever the patterns allow.
<h3>What it does not do</h3>A run does not change the size or the colour. Both belong to the paragraph; a heading is the one thing that changes the size, and it does so as a paragraph of its own. And a run does not kern with its neighbour: bold and regular have no pair table between them in any face.}

set block {-width 170 -align justify -paragraphSpacing 2}

set doc [tclpdf new -unit mm]
$doc info Title "The same paragraph in Markdown and in tags"
$doc page add

$doc font -family helvetica -size 14 -style bold -color black
$doc text "Written in Markdown, set in Helvetica" -at {20 22}
$doc font -size 10 -style {}

# The check first, in the state both blocks are set in: the lines each
# notation breaks into, as [textLines] answers them - the runs of every
# line with their options, not only the words.
set fromMarkdown [$doc textLines $markdown {*}$block -markup markdown]
set fromTags [$doc textLines $tagged {*}$block -markup tags]
set same [expr {$fromMarkdown eq $fromTags}]

set y [$doc text $markdown -at {20 34} {*}$block -markup markdown]

$doc font -size 14 -style bold
$doc text "The same text written with tags" -at [list 20 [expr {$y + 12}]]
$doc font -size 10 -style {}
set y [$doc text $tagged -at [list 20 [expr {$y + 24}]] {*}$block -markup tags]

# What the check found, on the page as well: measured, not claimed.
$doc font -size 8 -color {0.45 0.45 0.45}
$doc text "Both blocks break into [llength $fromMarkdown] lines; the lines of\
    the two notations are [expr {$same ? {identical} : {DIFFERENT}}], runs\
    and options alike." -at [list 20 [expr {$y + 8}]] -width 170

exampleFooter $doc
$doc write $target
$doc destroy

puts "  written: $target ([file size $target] bytes)"
puts "  Markdown and tags break into [llength $fromMarkdown] and\
    [llength $fromTags] lines: [expr {$same ? {identical} : {DIFFERENT}}]"
if {!$same} {
    exit 1
}
