#!/usr/bin/env tclsh
#
# tclpdf example 8.5 - a signature a screen reader can find
#
#   tclsh examples/08.05-signature-accessible.tcl ?output.pdf?
#
# 08.01 signs invisibly, 08.02 signs visibly, 05.07 makes a PDF/UA-1 claim.
# This example is the corner where those meet: a tagged document that claims
# PDF/UA-1 AND carries a VISIBLE signature field, which is the one
# combination with something to say.
#
# WHY IT HAS SOMETHING TO SAY. A signature field is a form field, and a
# widget annotation is the only mark on a page that belongs to no content
# stream: it hangs off the page's /Annots array, has no MCID, and cannot be
# reached the way a run of text is reached. PDF/UA therefore asks for it
# twice over - ISO 14289-1, 7.18.1 wants every annotation "represented in the
# structure tree in correct reading order", 7.18.4 wants a Widget "nested
# within a Form tag", and ISO 14289-2, 8.10.1 repeats the second in its own
# words. The join itself is ISO 32000-2, 14.7.5.4: an object reference (/Type
# /OBJR with /Obj) from the structure element to the annotation, and a
# /StructParent key in the annotation pointing back through the parent tree.
# Both halves, or a reader holds an element naming an annotation that cannot
# be found from the other side.
#
# tclpdf writes all of it for [$doc sign] with -rect, out of the very code
# that writes it for [$doc field]: the Form element opens where the sign call
# stands, so the field lands in reading order where the SCRIPT put it and not
# at the end of the tree. Two options fill in what a reader says out loud:
#
#   -tooltip   /TU, the accessible name of the FIELD (ISO 32000-2, 14.9.3) -
#              what is announced instead of the field name, and "Signature1"
#              tells a listener nothing.
#   -contents  /Contents, the description of that one WIDGET (ISO 14289-2,
#              8.10.2.3) - what the mark on the page is.
#
# Both are written wherever they are given. Under a claim they are asked for:
# part 1 wants the /TU, part 2 wants the /Contents besides, and a signature
# without them is refused when the file is written - in the same sentence a
# text field without them is refused, because it is the same check.
#
# THE INVISIBLE SIGNATURE IS THE OPPOSITE CASE, which is why this example
# says so on its page and not only here. ISO 14289-2, 8.9.2.4.13 is plain -
# "a widget annotation of zero height and width shall be an artifact" -
# 8.10.1 exempts an artifact from the Form element, and 8.10.3.5 says it of
# the signature field by name. NOTE 1 gives the workflow it comes from: the
# invisible widgets of document timestamps in a PAdES-B-LTA signature are
# unpredictable in number, and "it is important that invisible widgets be
# exempt from any tagging requirements otherwise imposed by this document".
# So the signature of 08.01 - the default, /Rect [0 0 0 0] - carries no
# /StructParent, sits in no Form element, and is asked for no description at
# all.
#
# THE RECTANGLE DECIDES THAT, NOT THE CLAIM, and deliberately: [$doc ua] may
# stand before the sign call or after it, and a tree that depended on the
# order would make the two orders write two different files. Measured with
# veraPDF 1.30: a Form element around a zero-area widget fails UA-2 rule
# 8.9.2.4.13-1, and a visible signature outside the tree fails UA-1 rules
# 7.18.1-3 and 7.18.4-1.
#
# WHAT THE CLAIM COSTS HERE, next to 08.02: every face in the file is
# embedded, footer and appearance stream included, because PDF/UA rules out
# the standard 14 outright - so the prose helpers of common.tcl, which set
# Helvetica and Courier, cannot be used and this page sets its own type, the
# way 05.07 does. The specimen hand is 08.02's: the signature of the German
# identity card of the Personalausweisverordnung of 1 November 2010, an
# official work and in the public domain under section 5 paragraph 1 of the
# German copyright act. Erika Mustermann is the German Jane Doe, and 08.02
# says at length who she is.
#
# The certificates are made here and thrown away, as in 08.01 and 08.02.
# Without openssl the script still writes the document - with the placeholder
# unfilled, and saying so on its page.
#
# To see what came out:
#
#   verapdf --flavour ua1 08.05-signature-accessible.pdf
#   pdfinfo -struct-text 08.05-signature-accessible.pdf
#   pdfsig 08.05-signature-accessible.pdf
#
# The second one is the interesting one: the Form element and the object
# reference under it stand between the paragraphs, exactly where the sign
# call stands in this file.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] \
    : "08.05-signature-accessible.pdf"}]

set assets [file join $here assets]
set signatureFile [file join $assets images signature-mustermann.svg]

# ---------------------------------------------------------------------------
# openssl, or not
# ---------------------------------------------------------------------------
#
# The same scaffolding as 08.01 and 08.02, out of common.tcl. Nothing in the
# structure tree depends on it: the field, its Form element, the object
# reference and the description are in the file either way, and the claim is
# checked at the write, not at the signing.
lassign [exampleSigningSetup] workdir signer why
if {$signer eq {}} {
    puts "  no signature: $why"
    puts "  the document is written with the placeholder unfilled - the\
        field, its place in the structure tree and its description are there\
        all the same"
}

# ---------------------------------------------------------------------------
# The document
# ---------------------------------------------------------------------------

set doc [tclpdf new -unit mm]
$doc tagged 1

# A title and a language are not decoration under a PDF/UA claim: [ua]
# refuses to write the claim without either.
$doc info Title "Signed notice, accessible - specimen"
$doc info Author "Alexander Schoepe"
$doc info Subject "A visible signature inside the structure tree of a\
    PDF/UA-1 document"
$doc language en-GB

$doc page add

# Three embedded faces, because a PDF/UA document may carry no other kind -
# the standard 14 are ruled out whole, mono included, and the appearance
# stream at the bottom of this page is set in the first of them.
$doc font embed face [file join $assets fonts DejaVuSans.ttf]
$doc font embed faceBold [file join $assets fonts DejaVuSans-Bold.ttf]
$doc font embed mono \
    [file join $assets fonts liberation-fonts LiberationMono-Regular.ttf]

$doc font -family faceBold -size 16
$doc text "A signature in the reading order" -at {20 25} -tag H1

# The two statements this example exists for, on the page and not only in the
# source above: what is shown here, and why the other kind of signature is
# treated the other way round.
$doc font -family face -size 9.5 -color {0 0 0}
set y [$doc text "This document claims PDF/UA-1 and carries a signature you\
    can see. The field at the bottom right stands in the structure tree\
    between these paragraphs: inside a Form element, joined to its widget\
    annotation by an object reference, with an accessible name and a\
    description of its own. ISO 14289-1, 7.18.1 and 7.18.4 ask that of every\
    annotation, and a signature field is not exempt from either." \
    -at {20 36} -width 170]

set y [$doc text "An INVISIBLE signature is exempt, and deliberately so: ISO\
    14289-2, 8.9.2.4.13 makes a widget annotation of zero height and width an\
    artifact, 8.10.1 exempts an artifact from the Form element, and 8.10.3.5\
    repeats it for the signature field by name. So the signature of example\
    08.01 - the default, a rectangle of no area - stands in no element, is\
    asked for no description, and is none the worse for it. The rectangle\
    decides that, not the claim." -at [list 20 [expr {$y + 4}]] -width 170]

$doc font -family faceBold -size 11
$doc text "What a listener is told" -at [list 20 [expr {$y + 8}]] -tag H2

$doc font -family face -size 9.5
set y [$doc text "Two options, answering two different questions. -tooltip\
    writes /TU, the accessible name of the FIELD (ISO 32000-2, 14.9.3): what\
    a reader announces in place of the field name, since \"Signature1\" tells\
    nobody anything. -contents writes /Contents, the description of the\
    WIDGET itself (ISO 14289-2, 8.10.2.3): what the mark on the page is. Part\
    1 asks for the first, part 2 for both, and a claim made without them is\
    refused when the file is written." \
    -at [list 20 [expr {$y + 15}]] -width 170]

$doc font -family faceBold -size 11
$doc text "What the picture cannot do" -at [list 20 [expr {$y + 8}]] -tag H2

$doc font -family face -size 9.5
set y [$doc text "The frame below is a form XObject drawn by the script that\
    wrote this document, and it is a PICTURE of a signature: no structure, no\
    word a screen reader can reach. Everything a listener gets comes from the\
    two options above. The hand in it is the specimen signature of the German\
    identity card, an official work in the public domain - it is nobody's\
    signature, it declares nothing, and the certificate under it comes from a\
    test CA this script makes and throws away again." \
    -at [list 20 [expr {$y + 15}]] -width 170]

$doc font -family faceBold -size 11
$doc text "Check it yourself" -at [list 20 [expr {$y + 8}]] -tag H2

# The check commands belong on the page and not only on the console: the file
# gets mailed on, the console does not travel with it. They are content, so
# they stay in the tree as ordinary paragraphs rather than being declared
# decoration.
$doc font -family mono -size 8.5
set y [expr {$y + 15}]
foreach command [concat \
        [list "verapdf --flavour ua1 [file tail $target]"] \
        [exampleSignatureChecks [file tail $target]] \
        [list "pdfinfo -struct-text [file tail $target]"]] {
    $doc text $command -at [list 20 $y]
    set y [expr {$y + 5}]
}

if {$signer eq {}} {
    $doc font -family faceBold -size 11 -color {0.70 0.15 0.15}
    $doc text "This document is NOT signed" -at [list 20 [expr {$y + 3}]] \
        -tag H2
    $doc font -family face -size 9.5
    $doc text "$why, so the signature dictionary still holds its\
        placeholders. The FIELD is there all the same - its rectangle, its\
        appearance stream and its place in the structure tree. What is\
        missing is the CMS object in the reserved room." \
        -at [list 20 [expr {$y + 11}]] -width 170
}

# ---------------------------------------------------------------------------
# The claim
# ---------------------------------------------------------------------------
#
# It may stand before the sign call or after it: the two orders write the
# same file, which is what makes the rectangle - and not the claim - the
# thing that decides whether the widget is tagged.
$doc ua 1

# ---------------------------------------------------------------------------
# The appearance, drawn here as in 08.02 - and in the document's own faces
# ---------------------------------------------------------------------------
#
# One number is chosen, the width of the field; the height follows from the
# proportions of the drawing (330 by 95 in its viewBox) plus the line of
# small print under it, so the hand is never stretched. The form's size and
# the -rect it is shown in are then the same two numbers, which is what ISO
# 32000-2, 12.5.5 asks for.
#
# The script runs at the global level (see xObject.tcl), which here is this
# file's own level - so it reads the variables above rather than having them
# formatted into it.
#
# What is NOT in the drawing is a word a reader needs, and it carries no time
# either: a form XObject is written when the DOCUMENT is written, so a
# picture naming the moment of signing would name something that has not
# happened. /M holds it and every signature panel shows it; 08.02 has that
# argument in full.
set fieldWidth 72
set pad 2.5
set inkWidth [expr {$fieldWidth - 2 * $pad}]
set ruleY [expr {$pad + $inkWidth * 95.0 / 330.0 + 0.6}]
set fieldHeight [expr {$ruleY + 7.0}]

$doc form create signatureBox -size [list $fieldWidth $fieldHeight] -script {
    $doc rect -at {0.125 0.125} \
        -size [list [expr {$fieldWidth - 0.25}] [expr {$fieldHeight - 0.25}]] \
        -stroke {0.62 0.64 0.68} -width 0.25
    $doc svg $signatureFile -at [list $pad $pad] -width $inkWidth
    $doc line -from [list $pad $ruleY] \
        -to [list [expr {$fieldWidth - $pad}] $ruleY] \
        -stroke {0.62 0.64 0.68} -width 0.25
    $doc font -family face -size 6 -color {0.32 0.32 0.36}
    $doc text "Erika Mustermann - specimen, no declaration of intent" \
        -at [list $pad [expr {$ruleY + 4.2}]]
}

# WHERE THIS CALL STANDS IS WHERE THE FIELD STANDS IN THE TREE. The Form
# element opens here, after the paragraphs above and before the footer, so a
# reader reaches the field after the text explaining it - which is what
# "correct reading order" in 7.18.1 means. Moved to the top of the script,
# the same document would announce its signature before its heading.
set state [$doc sign \
    -rect [list 120 232 $fieldWidth $fieldHeight] \
    -appearance signatureBox \
    -tooltip "Signature of Erika Mustermann, issuing officer" \
    -contents "Specimen signature field, signed with a test certificate" \
    -signer $signer \
    -name "Erika Mustermann" \
    -reason "Specimen signature - not a declaration of intent" \
    -location "Bochum, DE" \
    -field Signature1]

# Read out of the document rather than repeated from the calls above, so the
# lines cannot report something the file does not say.
set part [dict get [$doc ua state] part]
puts "  PDF/UA-$part, field \"[dict get $state field]\" visible at\
    \[[dict get $state rect]\]"
puts "  /TU        [dict get $state tooltip]"
puts "  /Contents  [dict get $state contents]"

# Footer, write, and what the finished file says about its own signature.
exampleSignatureDone $doc $target $workdir

# And the four things this example is about, looked for in the BYTES that
# came out - a document asked about itself agrees with every mistake it
# makes, and the join between element and annotation is exactly the kind of
# thing no validator complains about when half of it is missing.
set data [exampleReadBinary $target]
foreach {pattern what} {
    {/S /Form} "the Form structure element (ISO 14289-1, 7.18.4)"
    {/Type /OBJR} "the object reference to the widget (ISO 32000-2, 14.7.5.4)"
    {/StructParent [0-9]+ >>} "the widget's way back into the parent tree"
    {/Tabs /S} "the page's tab order (ISO 14289-1, 7.18.3)"
} {
    puts "  [expr {[regexp $pattern $data] ? "yes" : "NO "}]  $what"
}

exampleSigningEnd $workdir [list $target] exampleSignatureChecks
