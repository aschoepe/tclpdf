#!/usr/bin/env tclsh
#
# tclpdf example 8.8 - a signed document with a document timestamp on top
#
#   tclsh examples/08.08-signature-doctimestamp.tcl ?output.pdf?
#
# The two answers a reader can want from one file, each from its own
# mechanism: WHO stands behind these bytes - the signature, a CMS object over
# the /ByteRange, made with somebody's key - and SINCE WHEN they provably
# exist - the document timestamp, an RFC 3161 token over every byte of the
# signed file, made with an authority's key. The stamp comes SECOND and that
# order is the point: its range covers the signature, so the token also fixes
# the moment by which the signature itself existed. This is the base pattern
# of long-term validation (12.8.5.3): when the signer's certificate expires,
# the token still says the signature was made while it was valid - and a
# further stamp, years later, covers token and all (08.06 and the manual say
# more; example 08.06 also explains the three ways to name the authority).
#
# TWO INCREMENTAL UPDATES, NO REWRITE. The signature is patched into the
# finished file by the write itself; the stamp is appended by
# [::tclpdf::sign timestamp] afterwards. pdfsig shows both fields and calls
# each range's digest good or bad on its own - flip one byte and both break,
# because both cover it.
#
# THE SCAFFOLDING IS THROWAWAY, twice. The signing CA is generated a moment
# before the document and deleted a moment after, exactly as in 08.01 - every
# reader reports the issuer as untrusted, and that is the correct answer, not
# a defect. The authority is the public one where the network allows and a
# throwaway one where it does not (the trade-off is 08.06's to explain).
# WITHOUT OPENSSL this example skips itself entirely: there is no signature
# to be had, and a timestamp refuses a file whose signature is still waiting
# - a placeholder is a promise, and stamping it would fix a moment for a
# signature that does not exist yet.
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "08.08-signature-doctimestamp.pdf"}]

lassign [exampleSigningSetup] workdir signer why
if {$signer eq {}} {
    puts "  skipped: $why - and a document timestamp refuses a file whose\
        signature is still waiting, so there is nothing here to write"
    exit 0
}
lassign [exampleTimestampSetup] tsaDir stamp tsaWhy
if {$tsaWhy ne {}} {
    # openssl exists (the signer needed it), so the fallback authority
    # cannot have failed for lack of it - this is openssl refusing to build
    # the certificate, which the sentence carries.
    puts "  skipped: $tsaWhy"
    exampleSigningEnd $workdir {} exampleSignatureChecks
    exit 0
}

set doc [tclpdf new -unit mm -version 2.0]

$doc info Title "Signed and timestamped specimen document"
$doc info Author "Alexander Schoepe"
$doc info Subject "A digital signature, then a document timestamp over it"

set state [$doc sign \
    -signer $signer \
    -name "Erika Mustermann" \
    -reason "Specimen signature - not a declaration of intent" \
    -location "Bochum, DE" \
    -field Signature1]

$doc page add

$doc font -family helvetica -style bold -size 16
$doc text "Signed, then stamped" -at {20 25}

set y 36
examplePara $doc y "This file answers two different questions with two\
    different mechanisms. The signature says WHO: a CMS object over the\
    bytes /ByteRange names, made with the signer's key, verifiable against\
    the signer's certificate. The document timestamp says SINCE WHEN: an\
    RFC 3161 token over every byte of the signed file, made with a timestamp\
    authority's key, verifiable against the authority's chain."

exampleHeading $doc y "Why the order matters"
examplePara $doc y "The stamp was appended after the signature, so its range\
    covers the signature itself. The token therefore fixes the moment by\
    which the signature existed - which is what keeps the signature provable\
    after the signer's certificate expires. That is the base pattern of\
    long-term validation, and further stamps may follow years apart, each\
    covering everything before it."

exampleHeading $doc y "Check it yourself"
exampleCommandBlock $doc y [exampleSignatureChecks [file tail $target]]

exampleSignatureDone $doc $target $workdir

# The stamp, onto the signed file - the second incremental update.
exampleStamp $target $stamp $tsaDir

exampleSigningEnd $workdir [list $target] exampleSignatureChecks
