#!/usr/bin/env tclsh
#
# tclpdf example 1.19 - lists in flowing text: bullets and numbers, in tags
# and in Markdown
#
#   tclsh examples/01.19-lists.tcl ?output.pdf?
#
# A list item is a paragraph with an indent and a label in front of its first
# line - a bullet, or a number the package counts - and the runs of 1.17 are
# allowed inside it: a bold word in a list item is nothing special. Like the
# headings, the item is a state of the PARAGRAPH, not of a run: every run of
# the item carries "item bullet" or "item number", consecutive items of one
# kind are one list, and a paragraph without the option ends it.
#
# The two notations, each on its own page, as typed and as set - the page is
# the one 1.17 draws: <ul> and <ol> with <li> for the tags; a line beginning
# with "- " (or "* ", "+ ") or with "1. " for Markdown, where the number in
# the source does not matter, because the package counts the items itself.
# Both become the same list of runs, which the last line of page two measures
# with [textLines] rather than claims. What neither notation has: nesting -
# a list has one level here.
#
# In a tagged document a list is an L element holding an LI per item, and
# the LI holds the label as Lbl and the text as LBody - the structure ISO
# 32000-2 asks for and the one a reader announces as a list.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "01.19-lists.pdf"}]

# A checklist and a procedure: what a delivery note carries, and the steps
# of a return, each with a run inside an item. The runs are <strong> and
# <em>, not <b> and <i>: ** and * in Markdown are strong and em, and the
# proof at the end compares the runs with their options. A list ends its paragraph the
# way </p> does, so what follows </ul> starts right there - a line feed
# after it would be a paragraph of its own.
set tagged {<h2>What the parcel carries</h2>The delivery note lists every item, and the items are checked against it on arrival:
<ul><li>the <strong>invoice</strong>, printed and as PDF on the enclosed card</li><li>the <em>packing list</em>, one line per carton</li><li>the return label, valid for <u>thirty days</u></li></ul><h2>How to return a carton</h2>Three steps, in this order:
<ol><li>write the reason on the return form - a word is enough</li><li>put the form on top and close the carton with the <strong>original tape</strong></li><li>hand the carton to the carrier named at <a href="https://fossil.sowaswie.de/tclpdf">the project page</a></li></ol>A carton returned any other way is not accepted.}

set markdown {## What the parcel carries
The delivery note lists every item, and the items are checked against it on arrival:
- the **invoice**, printed and as PDF on the enclosed card
- the *packing list*, one line per carton
- the return label, valid for thirty days
## How to return a carton
Three steps, in this order:
1. write the reason on the return form - a word is enough
1. put the form on top and close the carton with the **original tape**
1. hand the carton to the carrier named at [the project page](https://fossil.sowaswie.de/tclpdf)
A carton returned any other way is not accepted.}

set block {-width 170 -align justify -paragraphSpacing 2}

set doc [tclpdf new -unit mm]
$doc info Title "Lists in flowing text: tags and Markdown, as typed and as set"

exampleTypedAndSet $doc "Lists written with tags" $tagged tags $block
set y [exampleTypedAndSet $doc "Lists written in Markdown" $markdown markdown $block]

# The proof - both notations break into the same lines - is measured and
# drawn by exampleSameLines in common.tcl, shared with 1.17.
exampleSameLines $doc $tagged $markdown $block $y " The numbers in the Markdown\
    source are all 1.; the package counts."

exampleFooter $doc
$doc write $target
$doc destroy

puts "  written: $target ([file size $target] bytes)"
