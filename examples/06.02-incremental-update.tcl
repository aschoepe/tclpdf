#!/usr/bin/env tclsh
#
# tclpdf example 6.2 - continuing an existing file: an incremental update
#
#   tclsh examples/06.02-incremental-update.tcl ?output.pdf?
#
# An incremental update (ISO 32000-2, 7.5.6) appends changes to the END of a
# finished PDF and leaves every byte of it where it was. Three revisions of
# one file come out of this script, one after another, and the point of the
# exercise is what you can check afterwards: the bytes of revision 1 are still
# the first bytes of revision 3, byte for byte.
#
# WHY THAT MATTERS, and why this way of writing exists at all: a digital
# signature covers the bytes of the file it sits in. Anything that rewrites
# the file breaks it. So a second signature - and a document timestamp, and a
# certification - can only be added by appending, which is what happens here.
#
# WHAT IT IS NOT: a PDF editor. The object graph of a foreign file is not in
# memory and cannot be put there - what an object means, and what else points
# at it, is exactly the knowledge a reader does not have. What this offers is
# narrow on purpose: add objects, write a second copy of an object the file
# already has, and set trailer entries. Deletion is not offered at all.
#
# The example is self-contained: it writes revision 1 into the output file
# itself and appends the other two to it in place, so the finished third
# revision is what the file ends up carrying.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf
package require tclpdf::update
package require tclpdf::pdfObj

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "06.02-incremental-update.pdf"}]

# The one line that stands inside the tinted box, on every one of the three
# pages. It is a variable because the three pages are written by two different
# roads - [text] here, hand-written stream operators in [appendPage] - and two
# copies of the sentence would sooner or later be two different sentences.
# Free of parentheses and backslashes, which a literal string in a content
# stream would have to escape.
set boxLine "Every revision of this file ends in its own %%EOF."

# -- revision 1: an ordinary document, written the ordinary way -------------

set doc [tclpdf new -unit pt -format a4]
$doc info Title "tclpdf example: an incremental update"
$doc page add
# tclpdf counts y from the TOP; the raw stream operators that write the two
# appended pages below count from the BOTTOM (PDF's own convention). So this
# first page - written the ordinary way - is placed against the page height,
# so that its heading, paragraph and box land byte-for-place where the raw
# "60 760 Td", "60 730 Td" and "60 640 475 60 re" put them on pages 2 and 3.
lassign [$doc page size] pageWidth pageHeight
$doc font -family helvetica -style bold -size 20
$doc text "Revision 1" -at [list 60 [expr {$pageHeight - 760}]]
$doc font -style {} -size 11
$doc text "This page was written by tclpdf in the ordinary way, in one\
    piece. The two pages behind it were appended afterwards, without a\
    single byte of this one being rewritten." \
    -at [list 60 [expr {$pageHeight - 730}]] -width 475
$doc rect -at [list 60 [expr {$pageHeight - 700}]] -size {475 60} -fill #efe8f6
$doc font -size 10
$doc text $boxLine -at [list 75 [expr {$pageHeight - 670}]]
exampleFooter $doc
$doc write $target
$doc destroy

# The bytes of revision 1, kept for the proof at the end - the file itself is
# continued in place, so this is the only copy of what it looked like then.
set channel [open $target rb]
set first [read $channel]
close $channel
set original [string length $first]
puts "  revision 1: $original bytes"

# -- what the update needs to know about the file it continues --------------
#
# Nothing is passed from above: the numbers below are read out of the finished
# file, the way they would be read out of a foreign one. The trailer names the
# catalog, the catalog names the page tree, the page tree names its kids - and
# the first kid names the resource dictionary the new pages will share, so
# that the appended pages use the font the original already embedded rather
# than a second copy of it.

proc pageTree {upd} {
    regexp {^(\d+)} [$upd trailer Root] -> catalog
    regexp {/Pages (\d+) 0 R} [$upd body $catalog] -> pages
    return $pages
}

proc firstKid {upd pages} {
    regexp {/Kids \[\s*(\d+) 0 R} [$upd body $pages] -> kid
    return $kid
}

# Add one page to the file, with one line of text on it. Four objects change:
# the new page, its content stream, and - because a page tree has to name its
# kids and count them - a second copy of the page tree node.
#
# The sheet is the same sheet page 1 is: heading, paragraph, tinted box and
# the line inside it, at the same coordinates. Only the way it is written
# differs, which is the whole point of the example - so anything that differs
# BESIDES that would be read as a difference the update caused.
proc appendPage {path heading line} {
    set note $::boxLine
    set upd [::tclpdf::update open $path]
    set pages [pageTree $upd]
    set model [$upd body [firstKid $upd $pages]]

    # The boxes and the resources of the first page, taken over as they are.
    regexp {/MediaBox (\[[^\]]*\])} $model -> box
    regexp {/Resources (\d+) 0 R} $model -> resources
    # And the names the resource dictionary gives the two standard faces page 1
    # is set in. "Read rather than assumed" has to cover the ORDER of the keys
    # as well as the names: both are the writer's private business, and this
    # file writes /Font << /FHelveticaBold ... /FHelvetica ... >>, so the FIRST
    # key is the BOLD one. Taking it set the whole of pages 2 and 3 in bold,
    # and a page that does not look like page 1 reads as a difference the
    # update caused - the one thing this example must not show. So every
    # name/reference pair is read and the /BaseFont behind it decides.
    regexp {/Font <<([^>]*)>>} [$upd body $resources] -> fontDict
    array set faceOf {}
    foreach {match name object} \
        [regexp -all -inline {/([A-Za-z0-9]+)\s+(\d+) 0 R} $fontDict] {
      regexp {/BaseFont /([-A-Za-z0-9]+)} [$upd body $object] -> base
      set faceOf($base) $name
    }
    set face $faceOf(Helvetica)
    set faceBold $faceOf(Helvetica-Bold)

    set page [$upd reserve]
    set content [$upd addStream {} \
        "BT /$faceBold 20 Tf 60 760 Td ($heading) Tj ET\n\
        BT /$face 11 Tf 60 730 Td ($line) Tj ET\n\
        0.93 0.91 0.96 rg 60 640 475 60 re f\n\
        BT /$face 10 Tf 0 g 75 670 Td ($note) Tj ET\n"]
    # Built through the same infrastructure the package writes everything
    # with: the keys become names, the values are PDF syntax already.
    $upd put $page [::tclpdf::pdfObj dictionary [list \
        Type /Page Parent [$upd ref $pages] MediaBox $box \
        Resources [$upd ref $resources] Contents [$upd ref $content]]]

    # The page tree node, in its second copy: the old one stays in the file,
    # and the cross-reference section of this update decides which of the two
    # a reader sees.
    set node [$upd body $pages]
    regexp {/Kids \[([^\]]*)\]} $node -> kids
    regexp {/Count (\d+)} $node -> count
    set node [string map [list "\[$kids\]" "\[$kids [$upd ref $page] \]" \
        "/Count $count" "/Count [expr {$count + 1}]"] $node]
    $upd replace $pages $node

    $upd write
    $upd destroy
    return $page
}

# -- revisions 2 and 3 ------------------------------------------------------

set before [file size $target]
appendPage $target "Revision 2" \
    "Appended by an incremental update - the bytes of revision 1 are untouched."
puts "  revision 2: [file size $target] bytes ([expr {[file size $target] - $before}] appended)"

set before [file size $target]
appendPage $target "Revision 3" \
    "And once more: every update chains onto the previous one through /Prev."
puts "  revision 3: [file size $target] bytes ([expr {[file size $target] - $before}] appended)"

# -- the proof, which is the whole point ------------------------------------
#
# Read the finished file and hold its first bytes against the revision that
# wrote them. This is what a signature over revision 1 would still verify
# against - and it is checked with a byte comparison rather than with a
# validator, because a validator answers "this file is fine", not "these
# bytes did not move".

set channel [open $target rb]
set bytes [read $channel]
close $channel

set unchanged [string equal $first [string range $bytes 0 [expr {$original - 1}]]]
puts "  the first $original bytes are byte for byte what revision 1 wrote: $unchanged"
if {!$unchanged} {
    # Never reached, and it says so if it ever is: a file whose beginning
    # moved is not an incremental update, whatever else is right about it.
    return -code error "tclpdf: the original bytes did not survive the update"
}
# Counted on "startxref", not on "%%EOF": the appended pages carry their
# content stream uncompressed, so the sentence printed inside their box - which
# names %%EOF - would be counted as a revision. Five for three, measured.
puts "  trailers in the file: [llength [regexp -all -inline {startxref} $bytes]],\
    each with its own cross-reference section"
puts "  written: $target"

# What to check it with, outside this script:
#
#   qpdf --check 06.02-incremental-update.pdf
#   pdfinfo 06.02-incremental-update.pdf        -> Pages: 3
#   head -c <bytes of revision 1> file | cmp - <revision 1>
