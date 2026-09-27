#!/usr/bin/env tclsh
#
# tclpdf example 7.2 - a document that opens for everyone and still says no
#
#   tclsh examples/07.02-permissions.tcl ?output.pdf?
#
# The pattern this shows is the one real invoices use, and it is not the one
# most people expect from the word "encrypted":
#
#   the user password is EMPTY, so no reader ever asks for one - the document
#   opens on a double click, like any other;
#   the owner password is set, and only it lifts the restrictions;
#   printing and copying are granted, changing the document is not.
#
# Measured on a production invoice written by another package: empty user
# password, print and copy allowed, modify and annotate refused. Exactly the
# combination below.
#
# WHAT THIS PROTECTS, AND WHAT IT DOES NOT. Nothing is hidden here. A file
# that opens without a password hands its key to everyone who opens it - the
# content is decrypted either way, and the permission bits are a statement of
# intent that a conforming reader honours. Acrobat and Preview honour them;
# a determined caller strips them in one command. Use this to say what you
# would like, not to enforce what must not happen: for that the user password
# has to be a real one, as in example 7.1.
#
# THE ONE BIT THAT CANNOT BE TAKEN AWAY is accessibility: ISO 32000-2,
# Table 22 says a writer shall always allow extraction for a screen reader,
# whatever else it forbids. The production invoice measured above still
# refuses it - written under the older revision, where that sentence did not
# yet exist. tclpdf cannot write that file: the bit is set, always.
#
# To see what came out:
#
#   qpdf --show-encryption out.pdf          without any password
#   pdftotext out.pdf -                     the text, without any password
#   qpdf --password=full --decrypt out.pdf plain.pdf
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "07.02-permissions.pdf"}]

# Empty on purpose - this is the whole point of the example.
set userPassword ""
set ownerPassword full

set doc [tclpdf new -unit mm -version 2.0]

$doc info Title "Permissions specimen document"
$doc info Author "Alexander Schoepe"
$doc info Subject "Open to read, restricted to change"

# encrypt comes first, before any drawing - a stream written before the
# cipher was installed would stay in the clear.
#
# print   the recipient prints the document
# copy    the recipient extracts text and figures from it
# highres printing at full quality, not the degraded copy
#
# What is NOT in the list is what the restriction is about: modify,
# annotate, fill and assemble stay out, so the content cannot be edited in a
# reader and passed on as if it still were ours.
set state [$doc encrypt \
    -user $userPassword \
    -owner $ownerPassword \
    -permissions {print copy highres}]

puts "  encryption: [dict get $state method], revision [dict get $state revision]"
puts "  permissions: [dict get $state permissions] -> P [dict get $state p]"
puts "  user password: [expr {$userPassword eq "" ? "(empty - opens without asking)" : $userPassword}]"

$doc page add

$doc font -family helvetica -style bold -size 16
$doc text "Open to read, restricted to change" -at {20 25}

$doc font -style {} -size 10
$doc text "This document is encrypted with AES-256, and it opened without\
    asking you for anything. Both statements are true at the same time: the\
    user password is the empty string, and a reader tries that one by itself\
    before it puts up a dialogue (ISO 32000-2 says so in as many words, in\
    the note to algorithm 5)." -at {20 38} -width 170

$doc text "What the file asks of a reader is written into it as a set of\
    permission bits. They are honoured by every conforming viewer, and they\
    are not a lock: whoever can open the document has the key, and the\
    content is decrypted either way. Say what you would like with them - do\
    not rely on them for what must not happen." -at {20 60} -width 170

# The granted permissions are read back out of the document rather than
# repeated from the list above - what the page shows is what the file says.
$doc font -style bold -size 11
$doc text "What this file grants" -at {20 88}

$doc font -style {} -size 10
set granted [dict get $state permissions]
set y 96
foreach {name what} {
    print     "printing"
    highres   "printing at full resolution"
    copy      "extracting text and graphics"
    modify    "changing the content"
    annotate  "annotations and form fields"
    fill      "filling in existing form fields"
    assemble  "inserting, rotating and deleting pages"
} {
    set yes [expr {$name in $granted}]
    $doc text [expr {$yes ? "granted" : "refused"}] -at [list 20 $y] \
        -color [expr {$yes ? "#1a7f37" : "#b3261e"}]
    $doc text $what -at [list 45 $y]
    incr y 6
}

$doc font -size 9
$doc text "Extraction for a screen reader is granted whatever else is\
    refused - a writer shall always allow it (ISO 32000-2, Table 22). The\
    owner password \"$ownerPassword\" lifts every restriction above; it is\
    printed here because an example nobody can open is an example nobody\
    reads, and a real document does not carry it." \
    -at [list 20 [expr {$y + 6}]] -width 170

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes)"
puts "  check it with: qpdf --show-encryption $target"
$doc destroy
