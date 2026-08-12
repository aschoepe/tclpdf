#!/usr/bin/env tclsh
#
# tclpdf example 5.4 - PDF/A on its own, without an invoice
#
#   tclsh examples/05.04-pdfa.tcl ?output.pdf?
#
# PDF/A was reachable only through [zugferd] in these examples, which made an
# archival document look like an invoice feature. It is not: a contract, a
# report, a certificate - anything that has to be readable in fifteen years
# without the machine that wrote it - is made the same way, and this is the
# whole recipe.
#
# What the declaration asks of the document, and what this file therefore does:
#
#   EVERY FONT EMBEDDED. A standard face is a reference to something the
#   reader is expected to have, which is precisely the assumption PDF/A
#   removes. [pdfa] refuses the document rather than writing one that says
#   PDF/A and is not - try it by dropping "-family face" from a text call.
#
#   COLOUR ANCHORED. An output intent names the colour space the numbers in
#   the file refer to, so that a grey printed today and one printed in 2041
#   mean the same thing. The sRGB profile in icc/ is used here.
#
#   THE METADATA IN XMP. Title, author and the conformance level go into the
#   XMP packet, not only into the document information dictionary - which is
#   the part a reader is allowed to ignore.
#
# Part 3 conformance B is what this writes: part 1 forbids the transparency
# tclpdf writes without ceremony, part 4 needs PDF 2.0. Level B is "readable
# the same way forever"; level A additionally needs a tagged structure tree,
# which is a separate piece of work.
#
# Check with:  verapdf -f 3b out.pdf
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

# The footer every example draws - shared, because eighteen copies of it
# is how a block starts drifting.
source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "05.04-pdfa.pdf"}]
set assets [file join $here assets]
set regular [file join $assets fonts DejaVuSans.ttf]
set bold [file join $assets fonts DejaVuSans-Bold.ttf]
set profile [file join [file dirname $here] icc sRGB.icc]

set doc [tclpdf new -unit mm]

# The document information dictionary. It is written as well - a reader that
# shows the title in its window title bar reads it here - but for PDF/A it is
# the XMP packet that counts, and [pdfa] keeps the two in agreement.
$doc info Title "Calibration certificate 2026-114"
$doc info Author "Alexander Schoepe"
$doc info Subject "Thickness gauge, annual calibration"
$doc info Keywords "calibration, ISO 2360, archival"

# The language belongs to an archival document as much as the fonts do: it is
# what tells a reader how to pronounce the text and how to hyphenate it.
$doc language en-GB

$doc page add

$doc font embed face $regular
$doc font embed faceBold $bold

# -- the certificate --------------------------------------------------------

$doc rect -at {20 20} -size {170 18} -fill {0.20 0.30 0.45}
$doc font -family faceBold -size 14 -color white
$doc text "Calibration certificate" -at {26 32}
$doc font -family face -size 9 -color white
$doc text "No. 2026-114" -at {184 32} -align right

$doc font -family face -size 10 -color black
set y [$doc text "This certificate records the annual calibration of the\
    thickness gauge below. It is written as PDF/A-3B so that it can be read,\
    and read the same way, for as long as it has to be kept - which for a\
    calibration record is the lifetime of the instrument plus five years." \
    -at {20 48} -width 170 -align justify -anchor top]

$doc table -at [list 20 [expr {$y + 8}]] -width 170 -theme grid \
    -style {family face} -headStyle {family faceBold} \
    -head {{Property Value}} \
    -body {
        {"Instrument" "Eddy current gauge, type N"}
        {"Serial number" "N-4471"}
        {"Calibrated on" "30 July 2026"}
        {"Reference standard" "Foil set, ISO 2360, traceable"}
        {"Deviation found" "0.4 um"}
        {"Next calibration due" "30 July 2027"}
    } \
    -columns {{width 60} {}}

# A picture and a bit of transparency, both of which are allowed here and are
# the reason part 1 is not: level B keeps them, part 1 would have to refuse.
$doc save
$doc opacity 0.12
$doc circle -at {160 150} -radius 22 -fill {0.20 0.30 0.45}
$doc restore

$doc font -family faceBold -size 10
$doc text "Signed" -at {20 160}
$doc font -family face -size 9
$doc text "Calibration laboratory, Bochum" -at {20 167}
$doc line -from {20 178} -to {90 178} -stroke {0.4 0.4 0.4} -width 0.3

# -- the declaration --------------------------------------------------------

# One call: it writes the output intent with the profile, raises the file
# version to match and produces the XMP packet. Everything it needs about the
# document - which fonts were used, which title was set - it reads back out of
# the document itself rather than being told twice.
$doc pdfa -part 3 -conformance B -profile $profile

# What was declared, read back rather than repeated from above.
set state [$doc pdfa state]
puts "  PDF/A-[dict get $state part][dict get $state conformance],\
    intent from [file tail [dict get $state profile]]"

exampleFooter $doc face

$doc write $target
$doc destroy

# The XMP packet is built during [write], not before it - so this is where it
# can be looked at. Reading it back out of the finished file is also the only
# check that does not simply believe the writer.
set channel [open $target rb]
set bytes [read $channel]
close $channel
regexp {<x:xmpmeta.*?</x:xmpmeta>} $bytes packet
puts "  XMP packet: [string length $packet] bytes,\
    conformance [expr {[regexp {pdfaid:conformance>(\w)<} $bytes -> level] ?
        $level : {not found}}]"

puts "  written: $target ([file size $target] bytes)"
puts "  check it with: verapdf -f 3b $target"
