#!/usr/bin/env tclsh
#
# tclpdf example 5.1 - a ZUGFeRD invoice, profile MINIMUM
#
#   tclsh examples/05.01-zugferd-minimum.tcl ?output.pdf?
#
# The same construction as example 5.2 and a deliberately different document,
# because the profile is different in a way that shows on the page:
#
#   MINIMUM CARRIES NO LINE ITEMS. The profile records who invoiced whom, for
#   how much in total, and what tax applies - and nothing about what was sold.
#   So this invoice has no item table. That is not a shortcoming of the
#   example; it is what MINIMUM means, and a document showing items that its
#   own XML does not contain would be exactly the mismatch this whole family
#   of examples exists to avoid.
#
#   MINIMUM is not a complete invoice under German VAT law. It is meant to
#   accompany a document that is complete on its human-readable side - which
#   is why the visible page here has to carry the detail the XML does not.
#
#
# This example and 05.02 deliberately repeat each other. They exist to be read
# SIDE BY SIDE - same construction, different profile - and the repetition is
# what makes the one difference visible. Pulling the shared parts into a
# procedure would hide exactly what the pair is for, so the duplicate-scanner's
# finding on these two files is knowingly left standing.
#
# Every figure below is read out of the attached XML.
#
# Check with:  verapdf -f 3b out.pdf  and  qpdf --list-attachments out.pdf
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

# The footer every example draws - shared, because eighteen copies of it
# is how a block starts drifting.
source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "05.01-zugferd-minimum.pdf"}]
set assets [file join $here assets]
set invoice [file join $assets xml zugferd-minimum.xml]

# What the XML states. Nothing here is invented.
set data {
    number       471102
    date         "5 March 2020"
    sellerName   "Lieferant GmbH"
    sellerTax    "201/113/40209"
    sellerVat    DE123456789
    buyerName    "Kunden AG Frankreich"
    netTotal     "198.00"
    grandTotal   "235.62"
    duePayable   "235.62"
}

set doc [tclpdf new -unit mm]
$doc info Title "Invoice [dict get $data number]"
$doc info Author [dict get $data sellerName]
$doc info Subject "ZUGFeRD invoice, profile MINIMUM"

# PDF/A requires every font embedded; the fourteen standard faces are not.
$doc font embed body [file join $assets fonts DejaVuSans.ttf]
$doc font embed bodyBold [file join $assets fonts DejaVuSans-Bold.ttf]
$doc page add

$doc font -family bodyBold -size 15
$doc text [dict get $data sellerName] -at {20 22}
$doc font -family body -size 8
$doc text "Tax number [dict get $data sellerTax] - VAT ID [dict get $data sellerVat]" \
    -at {20 28}

$doc font -size 9
$doc text [dict get $data buyerName] -at {20 46}

$doc font -family bodyBold -size 13
$doc text "Invoice [dict get $data number]" -at {20 66}
$doc font -family body -size 9
$doc text "Invoice date: [dict get $data date]" -at {20 74}

# The printed page is read by a person, the attachment by a machine, and they
# do not use the same decimal separator: the XML carries 235.62 because
# ISO 20022 and EN 16931 prescribe the point, while a German invoice shows
# 235,62. Only the presentation is localised - the figures themselves stay the
# ones the attachment states, which is the whole promise of a hybrid invoice.
#
# -decimal tells the column which character to line the numbers up on; without
# it the comma would be just another character and the alignment would break.
proc localise {value} {
    return [string map {. ,} $value]
}

# No item table - the XML has none. The totals are all it records.
set y [$doc table -at {20 88} -width 110 -theme striped \
    -style {family body} -headStyle {family bodyBold} -footStyle {family bodyBold} \
    -decimal , \
    -head {{Position Amount}} \
    -body [list \
        [list "Net amount" [localise [dict get $data netTotal]]] \
        [list "Tax" [localise [format %.2f [expr {[dict get $data grandTotal] -
            [dict get $data netTotal]}]]]]] \
    -foot [list [list "Total due" [localise [dict get $data grandTotal]]]] \
    -columns {{} {width 34 align decimal}}]

$doc font -family bodyBold -size 10
$doc text "Why there is no item table" -at [list 20 [expr {$y + 12}]]
$doc font -family body -size 9
$doc text "This document follows the MINIMUM profile, which records the\
    parties, the totals and the tax - and no line items at all. Showing items\
    here would mean the printed page and the attached data disagree, and a\
    recipient checking the attachment would find a different invoice.\
    MINIMUM is intended to accompany a document whose human-readable side is\
    complete on its own; under German VAT law the profile is not a full\
    invoice by itself." -at [list 20 [expr {$y + 18}]] -width 170 -align justify

$doc font -size 8
$doc text "The same invoice is attached as XML. Compare the two." \
    -at [list 20 [expr {$y + 52}]] -width 170

$doc bookmark "Invoice [dict get $data number]" -page 0

# One call sets everything PDF/A-3B needs: the output intent with the sRGB
# profile the package ships, the XMP extension schema, the attachment with
# /AFRelationship /Alternative at document level, and the entry in the names
# tree. Passing -icc here would name the very file the module already finds -
# measured, the two documents come out identical.
set profile [$doc zugferd $invoice]
puts "  profile from BT-24: $profile"
puts "  attachment: [dict get [$doc zugferd state] name],\
    [dict get [$doc zugferd state] bytes] bytes"

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes)"
$doc destroy
