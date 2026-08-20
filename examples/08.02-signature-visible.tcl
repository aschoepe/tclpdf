#!/usr/bin/env tclsh
#
# tclpdf example 8.2 - a VISIBLE digital signature, in one stage and in two
#
#   tclsh examples/08.02-signature-visible.tcl ?output.pdf?
#
# Two documents come out of this script, and they carry the same signature as
# 08.01 does - the difference is that this one can be SEEN:
#
#   08.02-signature-visible.pdf             signed while it was being
#                                           written, by a -signer prefix
#   08.02-signature-visible-two-stage.pdf   written with the placeholder
#                                           still in it, then signed through
#                                           [::tclpdf::sign digest] and
#                                           [embed]
#
# THE PAGES SAY LITTLE ON PURPOSE - a heading, a paragraph, the commands to
# check the file with, and the field itself, which is what the example is
# about. The why is here in the source, where the other examples keep it too.
#
# WHAT MAKES A SIGNATURE VISIBLE is two options and nothing else. -rect gives
# the field a place on the page - {x y w h}, counted from the TOP left corner
# as every other coordinate in this package is - and -appearance names a form
# XObject to show there. That form is drawn HERE, by this script, with
# [form create] and the ordinary drawing methods; the signature module hangs
# it into the widget as /AP << /N ... >> and draws nothing itself.
#
# That cut is deliberate and it is what this example is really about. A
# signature appearance is a mark with a name and a date under it - which is
# layout, and the document doing the layout is the one that should decide the
# font, the wording and the arrangement. A drawing engine inside the signature
# module would decide all three for everybody, and no caller could overrule
# it. So what you see below is a plain [form create] script: change it, and
# the signature looks different.
#
# THE MARK ITSELF is assets/images/signature-mustermann.svg, drawn with [svg]
# and therefore real vectors in the file. It is the specimen signature of
# "Erika Mustermann" from the German identity card of the
# Personalausweisverordnung of 1 November 2010 - an official work and public
# domain under section 5 paragraph 1 of the German copyright act; the file's
# own header and examples/assets/README.md say the rest.
#
# BOTH HALVES ARE REQUIRED TOGETHER, and each without the other is refused.
# -rect without -appearance is a visible annotation with no appearance
# dictionary, which veraPDF rule 6.3.3-1 fails ("Every annotation ... shall
# have at least one appearance dictionary") and which a reader draws as
# nothing at all; -appearance without -rect is a drawing on a rectangle of no
# area, which nothing ever paints - and no validator would have caught that
# one, because the file is perfectly valid and the picture simply never
# appears. Leave both out and the signature is the invisible one of ISO
# 32000-2, 12.8.5.3, which is what 08.01 shows and which is exempt from rule
# 6.3.3-1 because its rectangle has no area at all. The flags are the same
# either way: /F 4, Print set and Hidden, Invisible, NoView and ToggleNoView
# clear, which veraPDF rule 6.3.2-2 asks of EVERY annotation.
#
# WHAT IS THE SAME AS IN 08.01, and between the two documents here, is
# everything a reader looks at: the same field name, the same rectangle in the
# same place, the same appearance stream mechanism, the same /SubFilter. The
# two ways of signing differ in WHEN the key is asked, not in what ends up in
# the file - and, in the one respect below, in what the picture can honestly
# claim.
#
# THE HONEST LIMIT, and the reason the two appearances below read differently:
# THE PICTURE IS DRAWN BEFORE THE SIGNATURE EXISTS. A form XObject is part of
# the document, so it is written when the document is written; the
# time of signing is known at that moment only where the signing happens at
# that moment. In the one-stage document below it does, so the appearance
# shows the time and -date puts the very same value into /M. In the two-stage
# one it does not - the file is handed on and signed later, possibly days
# later and on another machine - so the appearance says where the time is to
# be found instead of stating one it cannot know. An appearance that named a
# time there would be a picture of something that had not happened, and a
# reader believes what it is shown. The time itself is in that file all the
# same and in the right place: /M went out as a placeholder of nothing but
# zeros and [::tclpdf::sign digest] wrote the real moment over it, in exactly
# its room, before it handed the bytes out - so it states the moment of
# signing, it lies inside the bytes the signature covers, and any reader with
# a signature panel shows it. What is missing is only the copy of it in the
# picture. There are two ways round that for whoever needs the time in the
# frame, and both cost something: sign in one stage, as the first document
# does, or let the second stage write the file again with a new appearance -
# which means the document is no longer the one that was handed out, and has
# to be signed after that, not before. tclpdf does neither behind the
# caller's back.
#
# THE CERTIFICATES ARE MADE HERE AND THROWN AWAY, exactly as in 08.01: a test
# CA and one end certificate under it, in a temporary directory, deleted a
# moment later. Every reader will report the issuer as untrusted, and that is
# the CORRECT answer.
#
# WITHOUT OPENSSL the script does not fail. It writes both documents with the
# placeholder unfilled - a legitimate file, /ByteRange and all - says so on
# the page and on the console, and ends successfully.
#
# To see what came out:
#
#   pdfsig 08.02-signature-visible.pdf
#   qpdf --check 08.02-signature-visible.pdf
#   qpdf --show-object=trailer --json 08.02-signature-visible.pdf
#
# pdfsig recomputes the digest over the bytes /ByteRange names and says
# whether the signature is valid and whether it covers the whole file. What it
# does NOT say is where the field sits: a reader that shows signature panels -
# Acrobat among them - names the page for a visible field where it says
# "invisible signature" for the other kind. To see the rectangle itself, look
# at the widget annotation with qpdf, or simply open the file.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf
# Named outright, because this example calls the two-stage entry points
# directly - see 08.01.
package require tclpdf::sign

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] \
    : "08.02-signature-visible.pdf"}]
set stem [file rootname $target]
set twoStage ${stem}-two-stage.pdf

# ---------------------------------------------------------------------------
# openssl, or not
# ---------------------------------------------------------------------------
#
# The same scaffolding 08.01 uses, and it stands in common.tcl rather than
# twice: a test CA and an end certificate under it, the command prefix that
# is handed the bytes and answers a CMS object in DER, and the verification
# afterwards. Nothing extra is asked of openssl here - both documents are
# written with the default /SubFilter /adbe.pkcs7.detached, which makes no
# PAdES claim, and 08.01 shows what that claim would cost.
lassign [exampleSigningSetup] workdir signer why
if {$signer eq {}} {
    puts "  no signature: $why"
    puts "  both documents are written with the placeholder unfilled - the\
        field and its appearance are there either way"
}

# ---------------------------------------------------------------------------
# The time, in the two spellings this script needs
# ---------------------------------------------------------------------------
#
# A PDF date as 7.9.4 spells it, built here rather than taken from the
# package: -date is a caller's option and a caller has to be able to produce
# one. ISO 32000-2 struck the apostrophe after the offset minutes, and both
# documents below are written as 2.0, so it is left off.

proc pdfDate {seconds} {
    set zone [clock format $seconds -format %z]
    return "[clock format $seconds -format D:%Y%m%d%H%M%S][string index $zone 0][string range $zone 1 2]'[string range $zone 3 4]"
}

# And the same moment for a human being, which is what goes into the picture.
proc humanDate {seconds} {
    return [clock format $seconds -format "%Y-%m-%d %H:%M:%S %Z"]
}

# ---------------------------------------------------------------------------
# The appearance - drawn by this script, not by the module
# ---------------------------------------------------------------------------
#
# An ordinary [form create], and what it draws is a SIGNATURE: the specimen
# hand of Erika Mustermann, from assets/images, put down with [svg] as real
# vectors - paths, not a picture of paths. Under it a rule and three lines of
# small print, which is the arrangement a reader knows from every
# signature panel: the mark is the content, the machine type says who and why.
#
# THE SIZE IS NOT GUESSED, and this is the one calculation in the file. The
# drawing measures 330 by 95 units, so the room it needs has that ratio - a
# hand written into a rectangle of another shape is a different hand, and
# nothing about a signature survives being stretched. So one number is chosen,
# the WIDTH of the field, and every other length follows from it: the drawing
# gets the width less two margins, its height comes out of the ratio, and the
# height of the whole form is that plus the lines below it. The form's size
# and the -rect it is shown in are then the same two numbers, which is what
# 12.5.5 asks for - a form 70 by 26 mm shown in a rectangle 35 by 13 comes out
# at half size, letters and all.
#
# Everything about the look is decided right here: the margins, the faces, the
# wording, what is left out. That is the whole point of the cut - nothing
# below this line is the signature module's business.
#
# "when" is the one line that differs between the two documents, and it is
# where the honest limit sits: a time in the one-stage case, a sentence
# saying where to find it in the two-stage one.
#
# Returns the size of the form, so that the caller hands the very same pair to
# -rect instead of writing it out a second time.

# The drawing and its own proportions, read off its viewBox: 330 by 95.
set signatureFile [file join $here assets images signature-mustermann.svg]
set signatureRatio [expr {95.0 / 330.0}]

proc signatureAppearance {doc name file who reason when {width 72}} {
    global signatureRatio

    # Margin round the drawing, the drawing itself, and the three baselines
    # under it. Only "width" is free; everything else is derived.
    set pad 2.5
    set inkWidth [expr {$width - 2 * $pad}]
    set inkHeight [expr {$inkWidth * $signatureRatio}]
    set ruleY [expr {$pad + $inkHeight + 0.6}]
    set height [expr {$ruleY + 11.0}]

    $doc form create $name -size [list $width $height] -script [format {
        set doc %s
        set width %s
        set height %s
        set pad %s
        set inkWidth %s
        set ruleY %s

        # A hairline round the field, the way a reader draws one, and no
        # more: the picture is the signature, not the box round it. It is
        # set in by half its own weight, because a form is clipped to its
        # box and a line ON the edge would come out at half thickness.
        $doc rect -at {0.125 0.125} \
            -size [list [expr {$width - 0.25}] [expr {$height - 0.25}]] \
            -stroke {0.62 0.64 0.68} -width 0.25

        # The signature. -width fits it to the room and keeps the ratio, so
        # the height it takes is the height reckoned above.
        $doc svg %s -at [list $pad $pad] -width $inkWidth

        # The line it is written on, and the small print beneath.
        $doc line -from [list $pad $ruleY] \
            -to [list [expr {$width - $pad}] $ruleY] \
            -stroke {0.62 0.64 0.68} -width 0.25
        $doc font -family helvetica -style bold -size 7.5 \
            -color {0.10 0.10 0.12}
        $doc text %s -at [list $pad [expr {$ruleY + 3.6}]]
        $doc font -family helvetica -style {} -size 6 \
            -color {0.32 0.32 0.36}
        $doc text %s -at [list $pad [expr {$ruleY + 6.6}]]
        $doc text %s -at [list $pad [expr {$ruleY + 9.4}]]
    } [list $doc] [list $width] [list $height] [list $pad] [list $inkWidth] \
        [list $ruleY] [list $file] [list $who] [list $reason] [list $when]]

    return [list $width $height]
}

# ---------------------------------------------------------------------------
# What this example says for itself
# ---------------------------------------------------------------------------
#
# The running text, the block of check commands and the frame around a
# missing signature are in common.tcl. What is left here is the sentence
# inside that frame, because an unfilled placeholder does not mean the same
# thing for a VISIBLE field as for the invisible one of 08.01: the frame is
# drawn either way, and a reader shows it.
set unsigned "$why, so the signature dictionary in this file still holds its\
    placeholders. The FIELD is there all the same, with its rectangle and its\
    appearance stream - what is missing is the CMS object in the reserved\
    room. A visible field on an unsigned document is exactly what the first\
    stage of the two-stage way hands on, and a reader shows the frame and\
    reports the signature as unfinished."

# Where the field sits on both pages: the same corner and, because both call
# [signatureAppearance] with the same width, the same rectangle - so the two
# documents can be laid side by side.
set fieldAt {120 240}
set fieldWidth 72

# ---------------------------------------------------------------------------
# One stage: signed as it is written, and the picture may say when
# ---------------------------------------------------------------------------

set moment [clock seconds]

set doc [tclpdf new -unit mm -version 2.0]

$doc info Title "Signed specimen document, with a visible field"
$doc info Author "Alexander Schoepe"
$doc info Subject "A visible digital signature made during the write"

$doc page add

$doc font -family helvetica -style bold -size 16
$doc text "A signature you can see" -at {20 25}

set y 36
examplePara $doc y "The signature in this file is the same one 08.01 makes: a\
    dictionary naming a range of bytes, and a CMS object made over exactly\
    those bytes. What is different is that the field has a place on the page\
    and something to show there - the frame at the bottom right of this\
    page."

exampleHeading $doc y "Check it yourself"
exampleCommandBlock $doc y [exampleSignatureChecks [file tail $target]]

if {$signer eq {}} {
    exampleNotSigned $doc y $unsigned
}

# The appearance, and then the call that uses it. Both come AFTER the page
# has been laid out, which is allowed and worth showing: nothing about a
# signature touches the content streams, so the call may stand anywhere
# before the write - and the form it names may be created after it.
# The size comes back out of the call and goes straight into -rect: the form
# and the rectangle are the same two numbers, so nothing is scaled.
set fieldRect [concat $fieldAt [signatureAppearance $doc signatureBox \
    $signatureFile "Erika Mustermann" \
    "Specimen signature - not a declaration of intent" \
    "Signed [humanDate $moment]" $fieldWidth]]

# The order of options is free, and this example groups them: what the field
# IS first - where it sits, what it shows, who signs it and when - and who it
# says signed it after that. -rect and -appearance lead because they are the
# two this example exists for.
set state [$doc sign \
    -rect $fieldRect \
    -appearance signatureBox \
    -signer $signer \
    -date [pdfDate $moment] \
    -name "Erika Mustermann" \
    -reason "Specimen signature - not a declaration of intent" \
    -location "Bochum, DE" \
    -field Signature1]

puts "  signature: [dict get $state subFilter], field\
    \"[dict get $state field]\" on page [dict get $state page], visible at\
    \[[dict get $state rect]\] showing form\
    \"[dict get $state appearance]\""

# Footer, write, and what the finished file says about its own signature -
# read back out of the document, not repeated from the call above.
exampleSignatureDone $doc $target $workdir

# ---------------------------------------------------------------------------
# Two stages: written first, signed afterwards - and the picture cannot know
# ---------------------------------------------------------------------------

set doc [tclpdf new -unit mm -version 2.0]

$doc info Title "Signed specimen document, visible, in two stages"
$doc info Author "Alexander Schoepe"
$doc info Subject "A visible digital signature applied after the write"

$doc page add

$doc font -family helvetica -style bold -size 16
$doc text "The same field, signed later" -at {20 25}

set y 36
examplePara $doc y "This document left tclpdf with the placeholder still in\
    it and was signed afterwards, through \[::tclpdf::sign digest\] and\
    \[::tclpdf::sign embed\]. That is the way that matters in practice,\
    because the key is usually not in the process that writes the document -\
    it is on a card in a reader, in an HSM, or behind a signing service."

exampleHeading $doc y "Check it yourself"
exampleCommandBlock $doc y [exampleSignatureChecks [file tail $twoStage]]

if {$signer eq {}} {
    exampleNotSigned $doc y $unsigned
}

set fieldRect [concat $fieldAt [signatureAppearance $doc signatureBox \
    $signatureFile "Erika Mustermann" \
    "Specimen signature - signed in a second stage" \
    "Signing time: see the signature panel (/M)" $fieldWidth]]

set state [$doc sign \
    -rect $fieldRect \
    -appearance signatureBox \
    -size 8192 \
    -name "Erika Mustermann" \
    -reason "Specimen signature - signed in a second stage" \
    -location "Bochum, DE" \
    -field Signature1]

exampleFooter $doc

$doc write $twoStage
$doc destroy

puts "  written: $twoStage ([file size $twoStage] bytes), field visible at\
    \[[dict get $state rect]\]"

# Stage two, and it needs nothing but the file.
if {$signer ne {}} {
    set job [::tclpdf::sign digest $twoStage]
    puts "  digest: [string length [dict get $job bytes]] bytes to sign,\
        /ByteRange \[[dict get $job byteRange]\], /M written as\
        [dict get $job date]"
    set der [{*}$signer [dict get $job bytes]]
    set length [::tclpdf::sign embed $twoStage $der]
    puts "  embedded: $length bytes of DER, file still\
        [file size $twoStage] bytes"
    puts "  [exampleOpensslVerify $workdir]"
}

exampleSigningEnd $workdir [list $target $twoStage] exampleSignatureChecks
