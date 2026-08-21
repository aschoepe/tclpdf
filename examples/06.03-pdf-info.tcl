#!/usr/bin/env tclsh
#
# tclpdf example 6.3 - what a finished PDF says about itself
#
#   tclsh examples/06.03-pdf-info.tcl ?output.pdf? ?subject.pdf?
#
# A document that describes another one. [::tclpdf::pdf info] answers what a
# file on disk says about itself - how many pages, in what version, written on
# how often, with which fonts, whether it is encrypted, what it claims in its
# metadata - and this script writes those answers onto a page.
#
# It reads with tclpdf's own parser, the one [pdf import] uses, so nothing has
# to be installed for it: no pdfinfo, no exit status to interpret, no output
# format to parse. That is the whole point of the command - and where poppler
# is at hand, the numbers on this page can be held against pdfinfo and
# pdffonts, which is what the last block of the script prints.
#
# WITHOUT A SECOND ARGUMENT the script writes its own specimen first, into a
# scratch file it deletes again: an archivable document with an attachment,
# an embedded face and two pages of different size - the shape of an invoice,
# so that the page has something to report. WITH one it describes the file you
# name, and any PDF will do.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf
package require tclpdf::importInfo

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "06.03-pdf-info.pdf"}]
set subject [lindex $argv 1]
set specimen {}
# What the page calls the file it describes. The specimen below lives under a
# name [file tempfile] made up, and printing that on the page would be noise.
set label [expr {$subject eq {} ? "the specimen" : [file tail $subject]}]

# -- the file this one describes --------------------------------------------

if {$subject eq {}} {
    set channel [file tempfile specimen tclpdf-specimen.pdf]
    close $channel
    set subject $specimen

    set doc [tclpdf new -unit mm]
    $doc info Title "Rechnung 4711"
    $doc info Author "Musterfirma GmbH"
    $doc info Subject "The document example 6.3 describes"
    $doc font embed haus [file join $here assets fonts DejaVuSans.ttf]
    # An archivable document carries an output intent and a metadata packet,
    # and its attachment is the invoice data - the shape [pdf info] has the
    # most to say about. It needs tdom, so a machine without it gets the same
    # specimen without the claim, and the page below reports what it finds.
    if {![catch {package require tdom}]} {
        $doc pdfa -part 3 -conformance B
    }
    $doc attach -data "<invoice number=\"4711\"/>" -name rechnung.xml \
        -mime text/xml -relationship Data -description "the invoice data"
    $doc page add
    $doc font -family haus -size 11
    $doc text "Rechnung 4711" -at {20 30}
    $doc page add -format a5 -orientation landscape
    $doc text "An appendix, on a smaller sheet" -at {20 30}
    $doc write $subject
    $doc destroy
}

# -- what it says about itself ----------------------------------------------

set facts [::tclpdf::pdf info $subject]
set pages [::tclpdf::pdf pages $subject]
set fonts [::tclpdf::pdf fonts $subject]

# -- the page ---------------------------------------------------------------

set doc [tclpdf new -unit mm]
$doc info Title "tclpdf example: what a PDF says about itself"
$doc page add

set y 20
exampleHeading $doc y "What $label says about itself"
examplePara $doc y "Everything below was read with tclpdf's own parser - the\
    one that takes over a page with \[pdf import\]. Nothing new is read for\
    it, which is why the answer costs a few milliseconds even on a\
    two-hundred-page catalogue."

# One line per fact: the label at the margin, the value at 60 mm.
proc fact {doc yName label value} {
    upvar 1 $yName y
    $doc font -family helvetica -style {} -size 9 -color {0.35 0.35 0.4}
    $doc text $label -at [list 20 $y]
    $doc font -color {0 0 0}
    $doc text $value -at [list 60 $y] -width 130
    set y [expr {$y + 5}]
    return
}

set y [expr {$y + 2}]
fact $doc y "file" "$label, [dict get $facts bytes] bytes"
fact $doc y "version" "PDF [dict get $facts version],\
    cross-reference as a [dict get $facts xref]"
fact $doc y "revisions" "[dict get $facts revisions] ([dict get $facts sections]\
    cross-reference section[expr {[dict get $facts sections] == 1 ? {} : {s}}])"
fact $doc y "pages" [llength $pages]
foreach page $pages {
    fact $doc y "  page [dict get $page number]" \
        "[format %.1f [dict get $page width]] x\
        [format %.1f [dict get $page height]] pt, rotated\
        [dict get $page rotate] degrees"
}
fact $doc y "encrypted" [expr {[dict get $facts encrypted] ? \
    [dict get $facts encryption] : "no"}]
fact $doc y "tagged" [expr {[dict get $facts tagged] ? "yes" : "no"}]
fact $doc y "interactive form" [dict get $facts form]
fact $doc y "XMP metadata" [expr {[dict get $facts xmp] ? "yes" : "no"}]
fact $doc y "claims PDF/A" [expr {[dict get $facts pdfa] ne {} ? \
    "part [dict get $facts pdfa]" : "nothing"}]
foreach intent [dict get $facts outputIntents] {
    fact $doc y "output intent" "[dict get $intent subtype],\
        [dict get $intent identifier][expr {[dict get $intent profile] ?
            {, profile embedded} : {}}]"
}
foreach {key caption} {Title title Author author Producer producer
        CreationDate created} {
    if {[dict exists $facts info $key]} {
        fact $doc y $caption [dict get $facts info $key]
    }
}
foreach annex [dict get $facts attachments] {
    fact $doc y "attachment" "[dict get $annex name] ([dict get $annex mime],\
        [dict get $annex size] bytes, /AFRelationship\
        [dict get $annex relationship])"
}
foreach signature [dict get $facts signatures] {
    fact $doc y "signature" "[dict get $signature field],\
        [dict get $signature subfilter], covers the whole file:\
        [expr {[dict get $signature whole] ? {yes} : {no}}]"
}
foreach face $fonts {
    fact $doc y "font" "[dict get $face basefont] ([dict get $face subtype],\
        [expr {[dict get $face embedded] ? {embedded} : {NOT embedded}}],\
        on page[expr {[llength [dict get $face pages]] == 1 ? {} : {s}}]\
        [join [dict get $face pages] {, }])"
}

set y [expr {$y + 4}]
exampleHeading $doc y "Check it yourself"
examplePara $doc y "poppler answers the same questions, and where the two\
    differ it is worth knowing why: pdfinfo prints the MediaBox of the first\
    page and notes the rotation separately, while the sizes above are what a\
    viewer shows - the crop box, turned. pdffonts lists a face once per place\
    it is used and stops at 36 characters of its name; it also passes over a\
    face that only an annotation's appearance uses."
exampleCommandBlock $doc y [list \
    "tclsh examples/06.03-pdf-info.tcl out.pdf any.pdf" \
    "pdfinfo any.pdf" \
    "pdffonts any.pdf"]

exampleFooter $doc
$doc write $target
$doc destroy

# -- and on the console -----------------------------------------------------

puts "  described: $label ([dict get $facts bytes] bytes)"
puts "  PDF [dict get $facts version], [dict get $facts pages] pages,\
    [dict get $facts revisions] revision[expr {[dict get $facts revisions] == 1
        ? {} : {s}}], [llength $fonts] font[expr {[llength $fonts] == 1
        ? {} : {s}}]"
if {[dict get $facts pdfa] ne {}} {
    puts "  claims PDF/A-[dict get $facts pdfa],\
        [llength [dict get $facts attachments]] attachment(s)"
}
puts "  written: $target"

if {$specimen ne {}} {
    file delete $specimen
}
