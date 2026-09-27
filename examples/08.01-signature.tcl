#!/usr/bin/env tclsh
#
# tclpdf example 8.1 - a digital signature, in one stage and in two
#
#   tclsh examples/08.01-signature.tcl ?output.pdf?
#
# Two documents come out of this script, and they differ only in HOW they
# were signed:
#
#   08.01-signature.pdf             signed while it was being written, by a
#                                   -signer command prefix
#   08.01-signature-two-stage.pdf   written with the placeholder still in it,
#                                   then signed afterwards through
#                                   [::tclpdf::sign digest] and [embed]
#
# and a third part that writes no document at all: it asks for
# "-subfilter cades" with the same openssl signer and shows the refusal that
# comes back, which is a statement about openssl rather than about tclpdf.
#
# THE PAGES SAY LITTLE ON PURPOSE - a heading, a paragraph, what a signature
# proves and the commands to check the file with. The rest of the why is here
# in the source, where the other examples keep it too.
#
# The cut the module is built on is what makes both of them the same picture:
# TCLPDF PREPARES, THE SIGNATURE COMES FROM OUTSIDE. Nothing in the package
# computes a digest, holds a private key or speaks CMS. What it builds is the
# part only a PDF writer can build - the signature dictionary, the field, the
# reserved room and above all the /ByteRange - and the bytes that range covers
# go to whoever holds the key. Here that is an "openssl cms -sign" pipeline;
# elsewhere it is a card reader, an HSM or a signing service, and the code on
# this side does not change.
#
# WHAT THE FILE CARRIES. /ByteRange is an array of two pairs - start and
# length, twice - and together they cover the whole file except one thing: the
# value of /Contents, which is where the signature itself sits. A signature
# cannot cover itself, and the gap between the two ranges is exactly the room
# it gets. That room is reserved BEFORE the file is written and padded out
# with zeros afterwards, because /ByteRange describes offsets into its own
# file and nothing may move once it is written. Measured: a CMS object with an
# RSA-2048 certificate and its issuer in it needs 2599 bytes, one with ECDSA
# P-256 needs 2209. The first document below takes the default of 16384, which
# leaves room for a longer chain and a timestamp; the second asks for 8192, to
# show that the number is a choice. A signature too large for its room is
# refused, never truncated - a truncated one would produce a file every
# validator calls signed and no verifier accepts.
#
# /M, THE TIME OF SIGNING, is in both documents, and how it got there is the
# one thing the two ways do differently. The one-stage document is written and
# signed in the same moment, so the entry states that moment outright. The
# two-stage one went out with a placeholder - a date of nothing but zeros,
# exactly as long as the value that replaces it - and [::tclpdf::sign digest]
# wrote the current time over it before it handed the bytes out; so the entry
# states the moment of SIGNING rather than the moment of writing, and it lies
# inside the range /ByteRange names, which means it is signed along with the
# rest. The entry is there for the reader as much as for the standard: ACROBAT
# TAKES THE SIGNING TIME FROM /M ALONE and reports it as unavailable without
# one, even though the CMS object states it and pdfsig prints it. -date sets a
# fixed time instead, and -date {} leaves the entry out altogether; neither is
# used here, and example 08.02 shows the first of them.
#
# THE CERTIFICATES ARE MADE HERE AND THROWN AWAY. A test CA and one end
# certificate under it, generated into a temporary directory a moment before
# the documents and deleted a moment after. That is deliberate, and it is why
# the pages keep the one section they do: every reader will report the issuer
# as untrusted, and that is the CORRECT answer. A valid signature and a
# trusted signature are two different statements, and only the first one is a
# question about the PDF.
#
# WITHOUT OPENSSL the script does not fail. It writes both documents with the
# placeholder unfilled - which is a legitimate file, /ByteRange and all, and
# exactly what the first stage of the two-stage way hands on - says so on the
# page and on the console, and ends successfully. "make examples" has to run
# on a machine that has no openssl.
#
# To see what came out:
#
#   pdfsig 08.01-signature.pdf
#   qpdf --check 08.01-signature.pdf
#   pdfsig -dump 08.01-signature.pdf
#   openssl cms -verify -inform DER -in 08.01-signature.pdf.sig0 \
#       -content bytes.bin -binary -noverify
#
# The first of those recomputes the digest over the bytes /ByteRange names and
# says whether it still matches, and whether the signature covers the WHOLE
# file or only part of it. Both statements matter: a signature over half a
# document is worth half a document. The third writes the CMS object out as
# "<name>.sig0", and the fourth checks it against the detached content -
# bytes.bin being the bytes [::tclpdf::sign digest] hands out. -noverify asks
# for the digest alone and leaves the chain out of it, which for a CA that no
# longer exists is the only question left to ask. This script runs that last
# command itself on both documents and prints the verdict.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf
# Named outright, because this example calls the two-stage entry points
# directly. [$doc sign] would pull the module in by itself; [::tclpdf::sign
# digest] on a file no document object in this process wrote would not.
package require tclpdf::sign

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "08.01-signature.pdf"}]
set stem [file rootname $target]
set twoStage ${stem}-two-stage.pdf

# ---------------------------------------------------------------------------
# openssl, or not
# ---------------------------------------------------------------------------
#
# The scaffolding is in common.tcl, because 08.02 needs exactly the same one
# and a second copy of it here is how two files start drifting apart: a test
# CA and an end certificate under it, the command prefix that answers a CMS
# object in DER, and the verification afterwards. What stays here is the one
# thing this example decides about it - "-cades", which makes openssl produce
# a CAdES-BES object, because part three below is about the claim that comes
# with it.
#
# The decision is made ONCE, here, and before the first [$doc sign] call -
# not inside the signer. A signer that fails is a write that fails, and by
# then half a document is on disk; a missing openssl has to be known while
# the page is still being laid out, because the page says so.
lassign [exampleSigningSetup -cades] workdir signer why
if {$signer eq {}} {
    puts "  no signature: $why"
    puts "  both documents are written with the placeholder unfilled - which\
        is what the first stage of the two-stage way hands on"
}

# ---------------------------------------------------------------------------
# What this example says for itself
# ---------------------------------------------------------------------------

# The commands every reader can run over the files that come out. The first
# three are the ones common.tcl knows; the two below them belong to this
# example alone, because they check the CMS object by hand against the
# detached content - bytes.bin being the bytes [::tclpdf::sign digest] hands
# out, which only this script keeps.
proc checkCommands {name} {
    return [exampleSignatureChecks $name [list \
        "openssl cms -verify -inform DER -in $name.sig0 \\" \
        "    -content bytes.bin -binary -noverify"]]
}

# What an unfilled placeholder means HERE, which is not what it means for the
# visible field of 08.02 - so the sentence stands in the example and the frame
# around it ([exampleNotSigned]: the heading and the red) is shared.
set unsigned "$why, so the signature dictionary in this file still holds its\
    placeholders: the reserved room is there, filled with zeros, /ByteRange\
    names the bytes to sign, and /M is a date of nothing but zeros - the time\
    of signing, which has not happened. That is a complete and valid PDF and\
    it is precisely what stage one of the two-stage way produces; what is\
    missing is the CMS object that stage two puts into the room, and the\
    moment \[::tclpdf::sign digest\] writes over the zeros on its way there."

# ---------------------------------------------------------------------------
# One stage: signed as it is written
# ---------------------------------------------------------------------------

set doc [tclpdf new -unit mm -version 2.0]

$doc info Title "Signed specimen document"
$doc info Author "Alexander Schoepe"
$doc info Subject "A digital signature made during the write"

# The one call, and it may come before or after the pages - unlike [encrypt],
# which has to be first. Nothing about the signature touches the content
# streams; it is built when the document is written and patched into the
# finished file afterwards.
#
# -signer is the only option that decides anything: with it the document
# comes off the write signed, without it the placeholder stays. Everything
# else is what goes into the signature dictionary (Table 255) and what a
# reader shows the person looking at the file.
set state [$doc sign \
    -signer $signer \
    -name "Erika Mustermann" \
    -reason "Specimen signature - not a declaration of intent" \
    -location "Bochum, DE" \
    -contact "examples@invalid" \
    -field Signature1]

puts "  signature: [dict get $state subFilter], field\
    \"[dict get $state field]\" on page [dict get $state page],\
    [dict get $state size] bytes reserved"

$doc page add

$doc font -family helvetica -style bold -size 16
$doc text "A signed document" -at {20 25}

set y 36
examplePara $doc y "This file carries a digital signature, and what that\
    means in a PDF is narrower than the word suggests. A dictionary in the\
    file names a range of bytes and stores a CMS object made over exactly\
    those bytes. If one byte inside the range changes afterwards, the digest\
    no longer matches, and every reader that looks says so."

exampleHeading $doc y "What it proves, and what it does not"
examplePara $doc y "It proves two things. The bytes /ByteRange names have not\
    changed since they were signed, and whoever signed them held the private\
    key belonging to the certificate inside the CMS object. It proves nothing\
    at all about WHO that was. That answer comes from the certificate chain,\
    and only if the issuer at the end of it is one the reader already trusts."
examplePara $doc y "This document is signed by a test CA that was generated a\
    moment before it, in a temporary directory, and deleted a moment after.\
    Every reader will report the issuer as untrusted - and that is the\
    correct answer, not a defect in the file. A valid signature and a trusted\
    signature are two different statements, and only the first one is a\
    question about the PDF."

exampleHeading $doc y "Check it yourself"
exampleCommandBlock $doc y [checkCommands [file tail $target]]

if {$signer eq {}} {
    exampleNotSigned $doc y $unsigned
}

# Footer, write, and what the finished file says about its own signature -
# read back out of the document, not repeated from the call above.
exampleSignatureDone $doc $target $workdir

# ---------------------------------------------------------------------------
# Two stages: written first, signed afterwards
# ---------------------------------------------------------------------------
#
# The case this is for: the key is not in this process and never will be. It
# is on a card in a reader, in an HSM, or behind a signing service that wants
# a digest and answers with a CMS object.
#
# THREE STEPS. First the document is written WITHOUT a signer: the signature
# dictionary is complete, the room is reserved, and /ByteRange is filled in
# with the real offsets - which is what makes the file useful to hand on,
# because without it nobody on the other side knows which bytes to hash. Then
# [::tclpdf::sign digest] reads the file back and answers the bytes that range
# covers, together with the offsets and the size of the room; those bytes go
# to whoever holds the key and come back as a CMS SignedData object in DER.
# Finally [::tclpdf::sign embed] writes that object over the reserved zeros.
# The edit is length-neutral by construction and checked to be.
#
# WHAT IS THE SAME IN BOTH FILES is everything a reader looks at: same
# /SubFilter, same field name, same invisible widget on the same page, and a
# signature that verifies or does not for exactly the same reasons. The two
# ways differ in WHEN the key is asked, not in what ends up in the file.

set doc [tclpdf new -unit mm -version 2.0]

$doc info Title "Signed specimen document, in two stages"
$doc info Author "Alexander Schoepe"
$doc info Subject "A digital signature applied after the write"

# No -signer. -size is spelled out here to show that it can be: the default
# of 16384 leaves room for a longer chain and a timestamp, and a signature
# that does not fit is refused rather than truncated.
set state [$doc sign \
    -name "Erika Mustermann" \
    -reason "Specimen signature - signed in a second stage" \
    -location "Bochum, DE" \
    -field Signature1 \
    -size 8192]

$doc page add

$doc font -family helvetica -style bold -size 16
$doc text "The same signature, made in two stages" -at {20 25}

set y 36
examplePara $doc y "The document beside this one was signed while it was being\
    written. This one was not: it left tclpdf with the placeholder still in\
    it, and the signature was put in afterwards. That is the way that matters\
    in practice, because the key is usually not in the process that writes\
    the document - it is on a card in a reader, in an HSM, or behind a\
    signing service."

exampleHeading $doc y "What it proves, and what it does not"
examplePara $doc y "It proves two things. The bytes /ByteRange names have not\
    changed since they were signed, and whoever signed them held the private\
    key belonging to the certificate inside the CMS object. It proves nothing\
    at all about WHO that was. That answer comes from the certificate chain,\
    and only if the issuer at the end of it is one the reader already trusts."
examplePara $doc y "And the caveat from the other page holds here too: the\
    issuer is a test CA that was generated a moment before this document, in\
    a temporary directory, and deleted a moment after. Every reader will\
    report it as untrusted, and that is the correct answer, not a defect in\
    the file."

exampleHeading $doc y "Check it yourself"
exampleCommandBlock $doc y [checkCommands [file tail $twoStage]]

if {$signer eq {}} {
    exampleNotSigned $doc y $unsigned
}

exampleFooter $doc

$doc write $twoStage
$doc destroy

puts "  written: $twoStage ([file size $twoStage] bytes),\
    [dict get $state size] bytes reserved instead of the default 16384"

# Stage two, and it needs nothing but the file. No document object is
# involved any more - this is the code that would run on the machine with the
# card in it.
if {$signer ne {}} {
    set job [::tclpdf::sign digest $twoStage]
    puts "  digest: [string length [dict get $job bytes]] bytes to sign,\
        /ByteRange \[[dict get $job byteRange]\],\
        room at [dict get $job offset] for [dict get $job size] bytes"
    set der [{*}$signer [dict get $job bytes]]
    set length [::tclpdf::sign embed $twoStage $der]
    puts "  embedded: $length bytes of DER, file still [file size $twoStage] bytes"
    puts "  [exampleOpensslVerify $workdir]"
}

# ---------------------------------------------------------------------------
# Three: the combination that is refused
# ---------------------------------------------------------------------------
#
# No third document comes out of this, and that is the point of it.
#
# -subfilter chooses what the signature CLAIMS to be. "pkcs7" writes
# /SubFilter /adbe.pkcs7.detached, which is the default and what both
# documents above carry; "cades" writes /ETSI.CAdES.detached and with it the
# claim to be a PAdES signature. ETSI EN 319 142-1, Table 1 says the CMS
# object of such a signature shall carry no signing-time attribute, and
# "openssl cms -sign" puts one into everything it signs, with no switch to
# leave it out. So the two cannot both stand, and tclpdf says so instead of
# writing a file whose label does not hold - the same refusal whether the
# signer runs during the write or the object arrives later through
# [::tclpdf::sign embed]. The default is the one that claims less, this script
# cannot use the other, and the refusal is a statement about openssl:
# pyHanko and the EU DSS library leave the attribute out.
#
# Nothing about this is a defect of the package or of openssl. It is what a
# profile is FOR: it forbids something, and a tool that cannot help doing it
# is a tool for the other profile. Both documents above are signed with
# /adbe.pkcs7.detached, which makes no such claim and asks for the attribute
# rather than forbidding it.

if {$signer ne {}} {
    set doc [tclpdf new -unit mm -version 2.0]
    $doc page add
    $doc text "A PAdES claim openssl cannot keep" -at {20 25}
    $doc sign -subfilter cades -size 8192 -signer $signer \
        -name "Erika Mustermann"
    # Into the temporary directory, because the file IS written - the writer
    # finishes it and the refusal comes afterwards, over the finished bytes,
    # with the placeholder still unfilled. It is deleted with the rest.
    set attempt [file join $workdir cades.pdf]
    if {[catch {$doc write $attempt} message options]} {
        puts "  -subfilter cades with openssl: refused,\
            [dict get $options -errorcode]"
        exampleConsoleParagraph $message
    } else {
        puts "  -subfilter cades with openssl: written, which means this\
            openssl left the signing-time attribute out"
    }
    $doc destroy
}

exampleSigningEnd $workdir [list $target $twoStage] checkCommands
