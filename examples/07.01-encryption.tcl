#!/usr/bin/env tclsh
#
# tclpdf example 7.1 - encryption
#
#   tclsh examples/07.01-encryption.tcl ?output.pdf?
#
# A document that asks for a password before it opens, and that says what may
# be done with it once it is open. This is the standard security handler of
# ISO 32000-2, revision 6: AES-256, and nothing older - RC4 and AES-128 are
# deprecated in PDF 2.0 and tclpdf does not write them.
#
# Two passwords, and the difference between them is the whole point:
#
#   the user password    opens the document, with the permissions below
#   the owner password   opens it with every permission, and is what a
#                        reader asks for before it lets you change the
#                        security settings
#
# Leaving the user password empty is allowed and often what is wanted: the
# document then opens for everybody, and the owner password is what unlocks
# the restrictions. Leaving the OWNER password empty is not offered - tclpdf
# uses the user password for both, because an empty owner password is the
# first one every reader tries.
#
# Two things this example has to do that the others do not:
#
#   -version 2.0    AESV3 (/V 5 /R 6) is a PDF 2.0 feature (Table 20), and
#                   tclpdf refuses to write it into a file whose header says
#                   otherwise rather than raising the version behind your back
#
#   encrypt first   before any drawing. A stream written before the cipher was
#                   installed would stay in the clear, and tclpdf refuses that
#                   too - the message names the page or the object
#
# Check the result with:
#
#   qpdf --password=full --show-encryption out.pdf
#   qpdf --password=full --decrypt out.pdf plain.pdf
#   pdftotext -upw read out.pdf -
#
# And note what is NOT encrypted, by design: /ID in the trailer (a reader
# compares it before it has a key) and the strings of the encryption
# dictionary itself (7.6.2).
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

# The footer every example draws - shared, because one copy per example is
# how a block starts drifting.
source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "07.01-encryption.pdf"}]

# The passwords are printed on the page on purpose: an example nobody can
# open is an example nobody reads. A real document does not carry them.
set userPassword read
set ownerPassword full

# PDF 2.0, and said at the start rather than raised later.
set doc [tclpdf new -unit mm -version 2.0]

$doc info Title "Encrypted specimen document"
$doc info Author "Alexander Schoepe"
$doc info Subject "The standard security handler, revision 6"

# The one call. It comes before the first page, before the first line of
# text, and before anything else - see the head of this file.
#
# -permissions takes NAMES, out of Table 22 of the standard:
#
#   print      print the document, at low resolution unless highres is given
#   modify     change the contents
#   copy       extract text and graphics
#   annotate   add or change annotations and fill in form fields
#   fill       fill in existing form fields, even without annotate
#   assemble   insert, rotate and delete pages, and make bookmarks
#   highres    print at full quality
#
# The default is "all". An empty list grants nothing - which still leaves a
# document that can be read on screen, since reading is not a permission.
set state [$doc encrypt \
    -user $userPassword \
    -owner $ownerPassword \
    -permissions {print copy}]

puts "  encryption: [dict get $state method], revision [dict get $state revision]"
puts "  permissions: [dict get $state permissions] -> P [dict get $state p]"

$doc page add
lassign [$doc page size] width height

$doc font -family helvetica -style bold -size 18
$doc text "Encrypted specimen document" -at {20 30}

$doc font -family helvetica -style {} -size 10
$doc text "This file is encrypted with AES-256 - the standard security\
    handler of ISO 32000-2, revision 6. It carries two passwords and a set\
    of permissions, and a reader is expected to honour both." \
    -at {20 42} -width 170

$doc font -style bold -size 11
$doc text "The two passwords" -at {20 62}
$doc font -style {} -size 10
$doc text "user password: $userPassword - opens the document with the\
    permissions listed below." -at {20 70} -width 170
$doc text "owner password: $ownerPassword - opens it with every permission,\
    and is what a reader asks for before the security settings may be\
    changed." -at {20 77} -width 170

$doc font -style bold -size 11
$doc text "What this document allows" -at {20 95}
$doc font -style {} -size 10

# The granted permissions come out of the document rather than out of a
# variable next to it: a page that lists what it allows must not be able to
# list something else than the file says.
set granted [dict get $state permissions]
set y 103
foreach {name meaning} {
    print    "print the document"
    modify   "change the contents"
    copy     "extract text and graphics"
    annotate "add annotations and fill in form fields"
    fill     "fill in existing form fields"
    assemble "insert, rotate and delete pages"
    highres  "print at full quality"
} {
    set allowed [expr {$name in $granted}]
    if {$allowed} {
        $doc font -color {0.1 0.45 0.2}
        set mark "yes"
    } else {
        $doc font -color {0.6 0.15 0.15}
        set mark "no"
    }
    $doc text $mark -at [list 20 $y]
    $doc font -color {0 0 0}
    $doc text "$name - $meaning" -at [list 32 $y]
    incr y 7
}

$doc font -style bold -size 11
$doc text "How to check it" -at {20 160}
$doc font -family courier -style {} -size 9
set line 168
foreach command [list \
    "qpdf --password=$ownerPassword --show-encryption out.pdf" \
    "qpdf --password=$ownerPassword --decrypt out.pdf plain.pdf" \
    "pdftotext -upw $userPassword out.pdf -"] {
    $doc text $command -at [list 20 $line]
    incr line 6
}

$doc font -family helvetica -size 10
$doc text "The first of those prints R = 6, the P value shown above, and\
    AESv3 for the streams, the strings and the file. The second writes the\
    document out again without encryption, which is what a reader with the\
    owner password may do. The third reads the text with the user password\
    alone." -at {20 192} -width 170

$doc font -style bold -size 11
$doc text "What stays readable" -at {20 218}
$doc font -style {} -size 10
$doc text "Two things are deliberately not encrypted. The file identifier in\
    the trailer, because a reader compares it before it has a key; and the\
    strings of the encryption dictionary itself, which are what a reader\
    needs to check the password with (7.6.2). Everything else in this file -\
    every content stream, every attachment, the title in the information\
    dictionary - is ciphertext." -at {20 226} -width 170

$doc font -style bold -size 11
$doc text "Where it does not apply" -at {20 254}
$doc font -style {} -size 10
$doc text "PDF/A forbids encryption outright, and a ZUGFeRD invoice is a\
    PDF/A-3 document - so tclpdf refuses to encrypt either. An archived\
    document nobody can open in ten years is not archived, and an invoice\
    the bookkeeping software cannot read is not an invoice." \
    -at {20 262} -width 170

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes)"
puts "  open it with the user password \"$userPassword\" or the owner\
    password \"$ownerPassword\""
$doc destroy
