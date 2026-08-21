#!/usr/bin/env tclsh
#
# tclpdf example 8.3 - a second signature on a finished file
#
#   tclsh examples/08.03-second-signature.tcl ?output.pdf?
#
# One document comes out of this script and it carries TWO signatures. The
# first is made the ordinary way, while the document is written; the second is
# appended afterwards, onto the finished file, by [::tclpdf::sign add].
#
# WHY THE SECOND ONE CANNOT BE MADE THE SAME WAY. A signature covers the bytes
# of the file it sits in - that is what /ByteRange says and what a reader
# recomputes. So writing the document again to add a field to it would move
# every byte behind that field and break the signature already there. The only
# way is the one ISO 32000-2, 7.5.6 provides: an INCREMENTAL UPDATE. The
# original bytes stay exactly where they are, and everything new is appended
# behind the last %%EOF, with a cross-reference section and a trailer of its
# own. This script proves that at the end, byte for byte, rather than asking
# you to believe it.
#
# WHAT GETS APPENDED, and it is more than the signature dictionary: the field
# and its widget, a second copy of the CATALOG - because /AcroForm /Fields has
# to list the new field - and a second copy of the PAGE the widget sits on,
# because its /Annots has to name it. Both old copies stay in the file, under
# the bytes the first signature covers, and the appended cross-reference
# section decides which of the two a reader sees.
#
# HOW FAR THE NEW SIGNATURE REACHES. 12.8.1 is exact about it: the range runs
# "from the '%PDF-' comment at the beginning of the PDF document to the end of
# the '%%EOF' comment, possibly followed by an optional EOL marker,
# terminating the incremental update that adds the digital signature
# dictionary". So the second signature covers the whole file, the first
# signature included; the first one still covers its own revision, which is
# everything up to the first %%EOF.
#
# WHAT pdfsig SAYS ABOUT THAT, and why one of its lines looks like a complaint
# and is not:
#
#   Signature #1  ...  Not total document signed
#   Signature #2  ...  Total document signed
#
# The first signature covers a revision the file has grown past. That is what
# "Not total document signed" means here, and it is the CORRECT answer for an
# older signature - not a defect and not something to fix. Both signatures are
# valid, and both say so on the line below it.
#
# WITHOUT OPENSSL the script does not fail. It writes the document with the
# placeholder unfilled, says so on the page and on the console, and then shows
# the refusal that comes back from [::tclpdf::sign add] - because a second
# signature cannot be appended over a first one that is still waiting for its
# value. "make examples" has to run on a machine that has no openssl.
#
# To see what came out:
#
#   pdfsig 08.03-second-signature.pdf
#   qpdf --check 08.03-second-signature.pdf
#   pdfsig -dump 08.03-second-signature.pdf
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf
# Named outright, because the second signature is put on by a package command
# and not by a document method: at that point there is no document object left
# in this process, only a file on disk.
package require tclpdf::sign

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "08.03-second-signature.pdf"}]

# The default profile, /adbe.pkcs7.detached, for both signatures: "openssl cms
# -sign" writes a signing-time attribute into everything it makes, and a PAdES
# claim would be refused for it - which is what 08.01 shows.
lassign [exampleSigningSetup] workdir signer why
if {$signer eq {}} {
    puts "  no signature: $why"
}

proc checkCommands {name} {
    return [exampleSignatureChecks $name]
}

# ---------------------------------------------------------------------------
# Revision 1: the document, signed as it is written
# ---------------------------------------------------------------------------

set doc [tclpdf new -unit mm -version 2.0]

$doc info Title "A document signed twice"
$doc info Author "Alexander Schoepe"
$doc info Subject "A second signature, appended as an incremental update"

$doc sign \
    -signer $signer \
    -name "Erika Mustermann" \
    -reason "Approved" \
    -location "Bochum, DE" \
    -field Signature1

$doc page add

$doc font -family helvetica -style bold -size 16
$doc text "Two signatures, one file" -at {20 25}

set y 36
examplePara $doc y "This file was signed twice. The first signature was made\
    while the document was being written. The second was added afterwards,\
    to the finished file, without a single byte of the first revision being\
    rewritten - which is the only way it can be done, because a signature\
    covers the bytes of the file it sits in."

exampleHeading $doc y "How the second one got in"
examplePara $doc y "As an incremental update (ISO 32000-2, 7.5.6). Everything\
    new - the signature dictionary, the field, its widget, a second copy of\
    the catalog and a second copy of this page - is appended behind the\
    %%EOF of the first revision, together with a cross-reference section and\
    a trailer of its own. The old copies stay in the file, underneath the\
    bytes the first signature covers, and the appended cross-reference\
    section decides which of the two a reader sees."
examplePara $doc y "The new signature covers the whole file, the first\
    signature included, up to the end of the %%EOF that closes its own\
    update. The first one covers its own revision and nothing else."

exampleHeading $doc y "What a reader will tell you about it"
examplePara $doc y "pdfsig reports both signatures and says \"Signature is\
    Valid\" for each. For the older one it also says \"Not total document\
    signed\", and that line is the correct answer rather than a complaint:\
    the file has grown since that signature was made, and it says so. The\
    newer one gets \"Total document signed\"."
examplePara $doc y "Both certificates come from a test CA that was made a\
    moment before this document and deleted a moment after, so every reader\
    will report the issuer as untrusted. That too is the correct answer. A\
    valid signature and a trusted signature are two different statements,\
    and only the first one is a question about the PDF."

exampleHeading $doc y "Check it yourself"
exampleCommandBlock $doc y [checkCommands [file tail $target]]

if {$signer eq {}} {
    exampleNotSigned $doc y "$why, so this file carries ONE signature\
        dictionary with its placeholders still in it and no second signature\
        at all: a further signature cannot be appended over one that is\
        still waiting for its value, because the two-stage way reaches the\
        newest signature of a file and the older one could then never be\
        filled. tclpdf refuses that rather than writing it - the console\
        output of this script shows the sentence it refuses with."
}

exampleSignatureDone $doc $target $workdir

# The bytes of revision 1, kept for the proof at the end. The file is
# continued in place, so this is the only copy of what it looked like now.
set first [exampleReadBinary $target]
set original [string length $first]

# ---------------------------------------------------------------------------
# Revision 2: the second signature, on the file
# ---------------------------------------------------------------------------
#
# No document object is involved any more, and there cannot be one: what the
# objects of a finished file mean, and what else points at them, is exactly
# the knowledge a reader does not have. The call takes a path, as
# [::tclpdf::sign digest] and [::tclpdf::sign embed] do.
#
# -field is left out on purpose. A partial field name has to be unique among
# its siblings (12.7.4.2), and the name the first signature took is the one a
# second call would otherwise take as well - so without -field the first free
# name of the form Signature<n> is used, which here is Signature2.

if {$signer eq {}} {
    if {[catch {::tclpdf::sign add $target} message]} {
        puts "  no second signature, and this is the sentence why:"
        exampleConsoleParagraph $message
    }
} else {
    # The same name as the first signature, because there is only one test
    # certificate here and a /Name naming somebody else than the certificate
    # inside the CMS object would be a picture of nothing. A real second
    # signature is a second key - the second reviewer, the second signatory -
    # and nothing about this call would change for it.
    set state [::tclpdf::sign add $target \
        -signer $signer \
        -name "Erika Mustermann" \
        -reason "Countersigned after review" \
        -location "Bochum, DE"]
    puts "  second signature: field \"[dict get $state field]\" on page\
        [dict get $state page], [dict get $state length] bytes of DER in\
        [dict get $state size] reserved"
    puts "  appended: [dict get $state appended] bytes,\
        /ByteRange \[[dict get $state byteRange]\]"
    puts "  [exampleOpensslVerify $workdir]"

    # The proof, and it is the whole point of writing it this way: the file
    # now ends somewhere else entirely, and its first bytes are byte for byte
    # what the first signature was made over.
    set bytes [exampleReadBinary $target]
    set unchanged [string equal $first \
        [string range $bytes 0 [expr {$original - 1}]]]
    puts "  the first $original bytes are byte for byte what revision 1\
        wrote: $unchanged"
    if {!$unchanged} {
        # Never reached, and it says so if it ever is: a file whose beginning
        # moved is not an incremental update, and the first signature is
        # broken whatever else is right about it.
        return -code error "tclpdf: the original bytes did not survive the\
            second signature"
    }
    puts "  [file size $target] bytes now,\
        [llength [regexp -all -inline {%%EOF} $bytes]] revisions,\
        [llength [regexp -all -inline {/ByteRange} $bytes]] signatures"
}

exampleSigningEnd $workdir [list $target] checkCommands

# What pdfsig will say, and what each line of it means:
#
#   Signature #1 ... Not total document signed ... Signature is Valid.
#   Signature #2 ... Total document signed     ... Signature is Valid.
#
# The first line is not a defect. The older signature covers the revision it
# was made over, and the file has grown past it - which is exactly what an
# incremental update is for.
