#!/usr/bin/env tclsh
#
# tclpdf example 1.7 - extending the package from outside
#
#   tclsh examples/01.07-extension.tcl ?output.pdf?
#
# Everything the topical modules do, a package of your own can do too: they
# have no privileges the document class does not offer to everybody. This
# example is a small extension that uses all four ways in:
#
#   THE EVENT BUS. The document announces what it is doing - a page was added,
#   the resources are being built, the catalog is being written. A subscriber
#   hangs its own work off that instead of the caller having to remember it.
#
#   OO::DEFINE. A method added to the document class is called like any other
#   one, which is how "$doc letterhead" below can exist without the package
#   knowing anything about letterheads.
#
#   RESERVATIONS. Write-time events fire on EVERY write, and a document may be
#   written more than once. An extension that allocates fresh object numbers
#   per run grows the file each time and leaves the earlier objects stranded -
#   so it reserves a number once per key and writes over it.
#
#   CATALOG KEYS. A reader ignores catalog keys it does not know, so a private
#   entry travels with the document without making it invalid anywhere.
#
# The name of that key is not free: ISO 32000-2 Annex E reserves unprefixed
# names for the standard itself. A private key carries either a registered
# prefix or "XX" - hence XXExampleRecord below.
#
# The full contract is doc/PLUGINS.md in the source distribution.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf
# The document CLASS, not just the facade: [tclpdf new] loads it on the way,
# but an extension that runs [oo::define] before the first document exists has
# to ask for it itself - otherwise the class it wants to extend is not there
# yet, and the error says so in a way that takes a while to read.
package require tclpdf::document

# The footer every example draws - shared, because one copy per example is
# how a block starts drifting.
source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "01.07-extension.pdf"}]

# -- the extension ----------------------------------------------------------

namespace eval ::example {}

# A method on the document class. It draws in document coordinates like any
# built-in one, and it asks the document for its own page size rather than
# assuming A4 - an extension that hardcodes the format works until someone
# passes -format a5.
oo::define ::tclpdf::document::document {
  method letterhead {} {
    lassign [my page size] width height
    my save
    my rect -at {0 0} -size [list $width 16] -fill {0.20 0.30 0.45}
    my font -family helvetica -style bold -size 10 -color white
    my text "EXAMPLE LABORATORIES" -at {12 10}
    my font -style {} -size 7
    my text "44 Example Road, Bochum" -at [list [expr {$width - 12}] 10] \
        -align right
    my restore
    my font -family helvetica -style {} -size 10 -color black
  }
}

# Every new page gets the letterhead, without the caller having to remember
# it. The bus passes the document as the first argument, so the subscriber
# never has to capture it from its surroundings.
proc ::example::pageAdded {doc args} {
    $doc letterhead
    # Per-document state that does NOT go into the PDF. Handing this to
    # [resource] instead would write a Tcl value into the page resources and
    # produce a structurally broken file. An unset key reads as the empty
    # string, so the first page has to start the count rather than add to it.
    set seen [$doc state examplePages]
    $doc state examplePages [expr {$seen eq {} ? 1 : $seen + 1}]
}

# A private record, written as a stream object the catalog points at. This
# runs on every write, which is exactly why the object number comes from
# [reservation]: the same key gives the same number, so the second write
# overwrites the first record instead of adding another one.
proc ::example::write {doc} {
    set number [$doc reservation example::record]
    # What the document says about itself, asked with [cget] rather than
    # remembered from the call that created it - a [configure] in between
    # would have changed the answer.
    set record "pages=[$doc state examplePages] unit=[$doc cget -unit]\
        format=[join [$doc cget -format] x] orientation=[$doc cget -orientation]\
        version=[$doc cget -version] compress=[$doc cget -compress]"
    $doc streamObject {Type /XXExampleRecord} $record $number
    $doc catalogEntry XXExampleRecord "$number 0 R"
}

# The other write-time events, listened to rather than used. Each subscriber
# gets the document; afterWrite gets the path as well - or an empty string
# when the document went into a channel, since there is no file to name.
# They fire on EVERY write, which the console shows: two writes below, two
# lines each.
proc ::example::resources {doc} {
    puts "  resources: [dict size [$doc resource Font]] font(s) go into the file"
}
proc ::example::catalog {doc} {
    puts "  catalog: the record is at [$doc catalogEntry XXExampleRecord]"
}
proc ::example::afterWrite {doc path} {
    puts "  afterWrite: [expr {$path eq {} ? {into a channel} : $path}]"
}

# -- a document that uses it ------------------------------------------------

# Every option said, so that the record has something to read back. A4 is
# given as its two numbers - a size without a name goes in the same way -
# and "hoch" is the German spelling of portrait, accepted next to it. The
# version is the default, said anyway. -compress 0 leaves every stream plain,
# the record included: open the file in a text editor and the record is
# there to read.
set doc [tclpdf new -unit mm -format {210 297} -orientation hoch \
    -version 1.7 -compress 0]
$doc info Title "Extending tclpdf"

set pageToken [$doc on pageAdded ::example::pageAdded]
$doc on beforeWrite ::example::write
$doc on resources ::example::resources
$doc on catalog ::example::catalog
$doc on afterWrite ::example::afterWrite

$doc page add

$doc font -family helvetica -style bold -size 13
$doc text "Extending tclpdf from outside" -at {20 30}

$doc font -style {} -size 10
set y [$doc text "The blue band at the top of this page was not drawn by the\
    script. It was drawn by a subscriber to the pageAdded event, which calls a\
    method that this example added to the document class - neither of them\
    known to the package itself." -at {20 40} -width 170 -align justify \
    -anchor top]

# The measuring surface an extension draws through. A plugin that writes into
# the content stream itself needs these: [coords] mirrors the y axis onto the
# PDF system, [distance] converts one length, [extent] a pair of them.
$doc font -family courier -size 8
# [text] returns the y below the block it set, which is a fraction - so the
# rows below are stepped with expr, not with incr.
set y [expr {$y + 8}]
# The unit is the document's, and [configure -unit] can change it between two
# calls - so an extension asks per call rather than assuming millimetres.
# Here the same questions are put in inches and the answers kept, before the
# unit goes back to mm for the drawing below.
$doc configure -unit in
set inches [list \
        "page size, in inches" [lmap n [$doc page size] {format %.2f $n}] \
        "distance 1 in -> pt" [format %.2f [$doc distance 1]]]
$doc configure -unit mm
foreach {label value} [list \
        "page size, in mm" [$doc page size] \
        "coords 20 30 -> pt" [lmap n [$doc coords 20 30] {format %.2f $n}] \
        "distance 20 mm -> pt" [format %.2f [$doc distance 20]] \
        "extent {20 10} -> pt" [lmap n [$doc extent {20 10}] {format %.2f $n}] \
        {*}$inches] {
    $doc text "$label = $value" -at [list 20 $y]
    set y [expr {$y + 5}]
}

# What the document is subscribed to, asked rather than assumed - and one of
# them cancelled again with the token [on] returned. From here on new pages
# get no letterhead.
$doc font -family helvetica -size 10
set y [expr {$y + 6}]
$doc text "subscribers to pageAdded: [llength [$doc subscribers pageAdded]],\
    to beforeWrite: [llength [$doc subscribers beforeWrite]]" -at [list 20 $y]
$doc off $pageToken
set y [expr {$y + 6}]
$doc text "after \[off\]: [llength [$doc subscribers pageAdded]] - so the next\
    page comes without the band" -at [list 20 $y]

exampleFooter $doc

$doc page add

# The footer left the state on small grey type - the font state survives a
# page break like every other graphics state, so a new page starts where the
# last one left off rather than at some default.
$doc font -family helvetica -style bold -size 13 -color black
$doc text "The second page, without the subscriber" -at {20 30}
$doc font -style {} -size 10
$doc text "The band is missing here because the subscription was cancelled\
    before this page was added - not because this page was drawn any\
    differently." -at {20 40} -width 170 -align justify -anchor top

$doc write $target

# Written a second time, into a channel this time: the same document has to
# come out byte for byte identical, or the extension is allocating something
# fresh on every run. This is the check doc/PLUGINS.md asks every extension to
# make, and it is two lines.
set scratch [file join [file dirname $target] extension-second.tmp.pdf]
set channel [open $scratch wb]
$doc writeChannel $channel
close $channel

set first [open $target rb]
set second [open $scratch rb]
set bytes [read $first]
set same [expr {$bytes eq [read $second]}]
close $first
close $second
file delete $scratch

$doc destroy

puts "  written: $target ([file size $target] bytes)"
puts "  second write byte-identical: [expr {$same ? {yes} : {NO - the extension is not idempotent}}]"
# The record as it stands in the file - readable because the document is
# written with -compress 0.
puts "  the record in the file: [lindex [regexp -inline {pages=[^\n]*} $bytes] 0]"
