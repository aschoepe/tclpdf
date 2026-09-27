#!/usr/bin/env tclsh
#
# tclpdf example 6.1 - a page of an existing PDF, taken over as a form
#
#   tclsh examples/06.01-pdf-import.tcl ?output.pdf?
#
# The classic use: a letterhead exists as a PDF - from the print shop, from
# a designer, from an old system - and the document is written ON it instead
# of rebuilding it. [pdf import] reads the page and registers it as a form;
# [form place] puts it down like any other form, as often as wanted, scaled
# and rotated, stored once in the file.
#
# The example is self-contained: it first WRITES the letterhead it then
# imports, into a scratch file that is deleted at the end - so what happens
# here is exactly what happens with a foreign file, without shipping one.
#
# What the import reads and what it refuses is in the manual: both
# cross-reference flavours of ISO 32000 (the classic table and, since PDF
# 1.5, cross-reference streams with object streams), pages picked by
# -page n, boxes and /Rotate honoured; encrypted files are refused by name.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "06.01-pdf-import.pdf"}]

# -- the letterhead this example imports -----------------------------------
#
# Any PDF would do; this one is written here so the example carries no
# foreign file. Note it uses its own unit and its own faces - nothing of
# that leaks into the importing document.

set channel [file tempfile letterhead tclpdf-letterhead.pdf]
close $channel

set doc [tclpdf new -unit mm]
$doc page add
$doc rect -at {0 0} -size {210 26} -fill #5e053b
$doc font -family helvetica -style bold -size 16
$doc text "MUSTERFIRMA" -at {20 16} -color white
$doc font -style {} -size 8
$doc text "Musterstrasse 1 - 44795 Bochum - musterfirma.example" \
    -at {20 22} -color white
$doc line -from {20 270} -to {190 270} -width 0.2
$doc text "Bank: DE02 1203 0000 0000 2020 51 - Registergericht Bochum" \
    -at {20 276} -color {0.4 0.4 0.4}
$doc write $letterhead
$doc destroy

# -- taking it over ---------------------------------------------------------

set doc [tclpdf new -unit mm]
$doc info Title "tclpdf example: importing a PDF page"
$doc page add

# The page becomes a form named like any created one; the size it reports
# is the imported page's size, in this document's unit.
$doc pdf import briefbogen $letterhead
lassign [$doc form size briefbogen] width height

# Under everything else: place it first, write over it - the letterhead
# workflow.
$doc form place briefbogen -at {0 0}

$doc font -family helvetica -size 11
$doc text "Musterfirma GmbH - Musterstrasse 1 - 44795 Bochum" -at {20 45} -size 7
$doc text "Frau\nErika Mustermann\nMusterstrasse 12\n12345 Musterstadt" -at {20 52} \
    -width 80
$doc font -style bold -size 13
$doc text "This letter is written ON the imported page" -at {20 95}
$doc font -style {} -size 10
$doc text "The letterhead above and the footer below come from another PDF\
    file: written by whoever designed them, imported with one call, placed\
    like a form. The page was imported once and is stored once, however\
    often it is placed." -at {20 105} -width 170

# The same import, placed again as a miniature - the form mechanics come
# for free: -scale, -rotate, -opacity.
$doc font -size 8
$doc text "the same import at 20 %:" -at {130 130}
$doc form place briefbogen -at {130 135} -scale 0.2
$doc rect -at {130 135} -size [list [expr {$width * 0.2}] \
    [expr {$height * 0.2}]] -stroke {0.7 0.7 0.7} -width 0.2

exampleFooter $doc
$doc write $target
puts "  written: $target"
$doc destroy

file delete $letterhead
