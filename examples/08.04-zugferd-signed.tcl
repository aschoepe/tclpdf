#!/usr/bin/env tclsh
#
# tclpdf example 8.4 - a signed ZUGFeRD invoice
#
#   tclsh examples/08.04-zugferd-signed.tcl ?output.pdf?
#
# The two things this package does that a business document actually needs at
# the same time, in one file: an ELECTRONIC INVOICE that carries its own data
# as XML, and a DIGITAL SIGNATURE over the bytes of the file that carries it.
# Examples 5.2 and 8.1 show each on its own; this one shows that they do not
# get in each other's way, and it measures the claim rather than making it.
#
# WHY IT IS WORTH ITS OWN EXAMPLE. Both sides of the file make a promise about
# every byte of it, and the promises look as if they must collide:
#
#   PDF/A-3B says the file has to stay readable without anything outside it,
#   and veraPDF checks a few thousand things to that effect. Its clause 6.4
#   has rules of its own about signatures - the digest has to cover the whole
#   file, the signer's certificate has to be in the CMS object, there has to be
#   exactly ONE SignerInfo in it. Those rules simply did not apply before.
#
#   A signature says nothing in the file changed since it was made. So the
#   invoice XML, the output intent, the ICC profile and the metadata all have
#   to be in place BEFORE the signing, and none of them may be touched after.
#
# They fit because of the order: the document is written complete - invoice
# attached, profile claimed, metadata written - and only then is it signed.
# The signature is the last thing that happens, and it changes nothing; it
# fills reserved room that was already part of the file when the digest was
# computed. That is what "space for the Contents value shall be allocated
# before the message digest is computed" (12.8.1) is for.
#
# THE SECOND SIGNATURE, and why it is here too. An invoice that has been
# approved by two people is an everyday thing, and the second approval must
# not disturb the first. It is appended as an incremental update (7.5.6) by
# [::tclpdf::sign add]: the original bytes stay where they are, the first
# signature keeps covering its own revision, and the second covers everything.
#
# WHAT IT PROVES, AND WHAT IT DOES NOT. It proves that a ZUGFeRD invoice
# survives one signature and a second one - the checks below say so, not this
# comment. It does not prove that the certificates mean anything: they come
# from a test CA that is thrown away when this script ends, so every reader
# will say the issuer is not trusted, and that is the right answer.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
source [file join $here common.tcl]

package require tclpdf
package require tclpdf::sign

set target [expr {[llength $argv] ? [lindex $argv 0] : "08.04-zugferd-signed.pdf"}]
set assets [file join $here assets]
set invoice [file join $assets xml zugferd-en16931.xml]

# The signer is an "openssl cms -sign" pipeline over a throw-away test CA -
# the same scaffolding examples 8.1 to 8.3 use. Without openssl the document
# is still written, and written completely: it is then a document PREPARED for
# a signature, with the placeholder still in it, which is a state of its own
# and not a failure.
lassign [exampleSigningSetup] workdir signer why

# The page is deliberately thin. What an invoice looks like is example 5.2's
# subject, and copying its layout here would be the same lines twice; what
# this one is about begins below, with [zugferd] and [sign].
set doc [tclpdf new -unit mm]
$doc info Title "Invoice 471113, signed"
$doc info Author "Lieferant GmbH"
$doc info Subject "A ZUGFeRD invoice with a digital signature"

$doc font embed body [file join $assets fonts DejaVuSans.ttf]
$doc font embed bodyBold [file join $assets fonts DejaVuSans-Bold.ttf]

# The signature is declared BEFORE the write, like every other property of the
# document: the call builds nothing, it says what the write has to reserve.
if {$signer ne {}} {
    $doc sign -signer $signer -reason "Approved for payment" \
        -name "Erika Mustermann" -location "Muenchen"
} else {
    $doc sign -reason "Approved for payment" -name "Erika Mustermann"
}

$doc page add

$doc font -family bodyBold -size 15
$doc text "Invoice 471113" -at {20 25}
$doc font -family body -size 9
$doc text "Lieferant GmbH to Kunden AG Mitte, 20 February 2026" -at {20 33}
$doc text "Total including VAT: EUR 23.54" -at {20 39}

$doc font -size 8
$doc text "The same invoice is attached to this file as XML, and the file is\
    signed over every byte it has - the visible page, the attachment, the\
    output intent and the metadata alike. Open the attachment to see the\
    other half; check the signature to see that neither half has moved\
    since." -at {20 52} -width 170

exampleFooter $doc body

# The invoice XML. This claims PDF/A-3B and writes the output intent, the
# metadata and the attachment - everything the archive side of the file needs,
# and all of it before a single byte is signed.
set profile [$doc zugferd $invoice]
puts "  ZUGFeRD profile: $profile"

$doc write $target
puts "  written: $target ([file size $target] bytes)"

set state [$doc sign state]
$doc destroy

if {[dict get $state signed]} {
    puts "  signature 1: [dict get $state length] bytes of CMS in\
        [dict get $state size] reserved"
} else {
    puts "  prepared, not signed: $why"
}

# The second approval, onto the finished file. Nothing of the invoice is
# touched by it - what gets appended is the field, its widget, and a second
# copy of the catalogue and the page that have to name it.
if {$signer ne {}} {
    # A SECOND CERTIFICATE, and it is not a formality: a reader takes the name
    # of a signer from the CERTIFICATE, not from -name. Table 255 asks for
    # /Name only "when it is not possible to extract the name from the
    # signature", and where a certificate is in the CMS object it always is.
    # Signed twice with one certificate, Acrobat shows the same person twice
    # however the dictionaries read - which would make this example teach the
    # opposite of what it is about.
    set countersigner [exampleSigner $workdir second]
    set second [::tclpdf::sign add $target -signer $countersigner \
        -field Signature2 -reason "Countersigned"]
    puts "  signature 2: [dict get $second length] bytes of CMS,\
        [dict get $second appended] bytes appended to the file"
}

# The claim of this example, measured here rather than asserted: the attached
# invoice is still byte for byte the file that went in.
set channel [open $invoice rb]
set original [read $channel]
close $channel
set channel [open $target rb]
set bytes [read $channel]
close $channel
puts "  the attached invoice is unchanged by both signatures:\
    [string first $original $bytes] is where it sits, and it is\
    [expr {[string first $original $bytes] >= 0}] that it is there in full"

exampleSigningEnd $workdir [list $target] {apply {name {
    list "pdfsig $name" \
        "verapdf -f 3b $name" \
        "java -jar tools/Mustang-CLI-2.25.0.jar --action validate --source $name" \
        "qpdf --list-attachments $name"
}}}
