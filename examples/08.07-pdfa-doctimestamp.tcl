#!/usr/bin/env tclsh
#
# tclpdf example 8.7 - a PDF/A document with a document timestamp
#
#   tclsh examples/08.07-pdfa-doctimestamp.tcl ?output.pdf?
#
# Example 08.06 shows the call; this one shows why an ARCHIVE wants it. A
# document timestamp proves that a file existed, byte for byte, no later than
# the moment a timestamp authority says - "this report existed before the
# deadline"; "this scan was archived on that day"; "these invoice bytes have
# not changed since March". An archive of PDF/A files with document
# timestamps is evidence with a date on it.
#
# AND PDF/A DOES NOT MIND. The token becomes the /Contents of a /DocTimeStamp
# signature field, appended to the finished file as an incremental update, so
# every original byte stays where it was and the update only ADDS objects.
# veraPDF still calls the stamped file conformant - make check measures that
# on this very document, against the PDF/A-3B profile it claims.
#
# THE AUTHORITY: the public one where the network allows, a throwaway one
# built here where it does not - the trade-offs of that fallback are
# explained in 08.06, which decides it the same way through the same helper.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
source [file join $here common.tcl]

package require tclpdf
package require tclpdf::timestamp

set target [expr {[llength $argv] ? [lindex $argv 0] : "08.07-pdfa-doctimestamp.pdf"}]
set assets [file join $here assets]

lassign [exampleTimestampSetup] tsaDir stamp why
if {$why ne {}} {
    puts "  skipped: $why"
    exit 0
}

# An ordinary PDF/A-3B document - the kind an archive keeps.
set doc [tclpdf new -format a4]
$doc font embed body [file join $assets fonts DejaVuSans.ttf]
$doc pdfa -part 3 -conformance B
$doc page add
$doc font -family body -size 16
$doc text "Timestamped evidence" -at {25 30}
$doc font -size 11
$doc text "This file carries a document timestamp: an RFC 3161 token over" -at {25 45}
$doc text "every byte of it, issued by a timestamp authority. Nobody signed" -at {25 51}
$doc text "this document - the token proves WHEN it existed, not who wrote it." -at {25 57}
$doc text "pdfsig shows the field; openssl ts -verify checks the token; and" -at {25 68}
$doc text "veraPDF still calls the stamped file PDF/A-3B, because the stamp" -at {25 74}
$doc text "is an incremental update that only adds." -at {25 80}
$doc write $target
$doc destroy

# The stamp, onto the finished file. The dictionary that comes back names
# the field, the byte range, the token's serial and the authority's time.
exampleStamp $target $stamp $tsaDir
