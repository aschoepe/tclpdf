#!/usr/bin/env tclsh
#
# tclpdf example 8.6 - a document timestamp, the minimal case
#
#   tclsh examples/08.06-doctimestamp.tcl ?output.pdf?
#
# A DOCUMENT TIMESTAMP (ISO 32000-2, 12.8.5) proves that a file existed, byte
# for byte, no later than the moment a timestamp authority says - and it needs
# NOBODY to have signed the file. The authority computes nothing over names or
# keys of yours: it receives the digest of the file's bytes, wraps it with the
# current time in an RFC 3161 TimeStampToken, and signs THAT with its own
# certificate. The token becomes the /Contents of a /DocTimeStamp signature
# field, appended to the finished file as an incremental update, so every
# original byte stays where it was. One ordinary document, one call - that is
# the whole example. 08.07 stamps a PDF/A file and says why an archive wants
# this; 08.08 stamps a SIGNED file.
#
# THE AUTHORITY IS CONFIGURABLE, and the default is a public one:
#
#   ::tclpdf::sign timestamp $file
#       ... asks https://tsr.open-tsa.eu, a free RFC 3161 service (not
#       eIDAS-qualified - fine for proof of existence, not a substitute for
#       a qualified seal where law demands one).
#
#   ::tclpdf::sign timestamp $file -url https://tsa.example.com/rfc3161
#       ... asks any other RFC 3161 authority over HTTP or HTTPS (https
#       needs the tls package).
#
#   ::tclpdf::sign timestamp $file -tsa myTransport
#       ... hands the request bytes to your own command - for an authority
#       that wants authentication, a proxy, or no HTTP at all. The command
#       gets the DER request and answers the DER response; the module still
#       checks that the token answers THIS digest and THIS nonce.
#
# WITHOUT NETWORK the third form carries the example: [exampleTimestampSetup]
# in common.tcl builds a throwaway authority with "openssl ts" and hands its
# transport in through -tsa. The token of an offline build verifies
# technically and vouches for nothing - the console says so when it happens -
# and only a machine that has neither network nor openssl skips this example:
# one line on stdout, no document, exit 0, so "make examples" stays a build
# with one document fewer rather than a failure.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
source [file join $here common.tcl]

package require tclpdf
package require tclpdf::timestamp

set target [expr {[llength $argv] ? [lindex $argv 0] : "08.06-doctimestamp.pdf"}]

lassign [exampleTimestampSetup] tsaDir stamp why
if {$why ne {}} {
    puts "  skipped: $why"
    exit 0
}

# An ordinary document. Nothing about it prepares for the stamp - no
# placeholder, no reserved room, no claim; the update brings everything.
set doc [tclpdf new -format a4]
$doc page add
$doc font -family helvetica -size 16
$doc text "It existed" -at {25 30}
$doc font -size 11
$doc text "One ordinary page, one call afterwards. The timestamp is not in" -at {25 45}
$doc text "here - it is appended to the finished file, an RFC 3161 token over" -at {25 51}
$doc text "every byte, and it proves WHEN, never WHO. See it with pdfsig." -at {25 57}
$doc write $target
$doc destroy

# The one call. The dictionary that comes back names the field, the byte
# range, the token's serial and the authority's time.
exampleStamp $target $stamp $tsaDir
