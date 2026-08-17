#!/usr/bin/env tclsh
#
# tclpdf example 5.12 - the same page under the ICC's sRGB2014 profile
#
#   tclsh examples/05.12-pdfa-srgb2014.tcl ?output.pdf?
#
# One of a pair. 05.11 writes this page with the sRGB profile the package
# uses by default (icc/sRGB.icc, OpenICC 2004, Zlib), 05.12 writes the very
# same page with the ICC's own sRGB profile (icc/sRGB2014.icc, International
# Color Consortium 2015, successor of sRGB_IEC61966-2-1_black_scaled). The two
# scripts repeat each other on purpose - they are meant to be read and viewed
# side by side, and the one line that differs is the profile.
#
# What to compare, and where the difference actually is:
#
#   ON THE PAGE, nothing - the same primaries, the same 1024-point tone curve
#   (measured, icc/README.md); a viewer rendering relative to the intent shows
#   identical colours. Set a viewer to absolute colorimetric output preview
#   and the two can drift: the old profile carries a D65 white point and no
#   chromatic adaptation tag, the new one D50 with a Bradford 'chad' tag, as
#   the ICC recommends since v4.
#
#   IN THE FILE, plenty: a different white point tag, a black point tag,
#   four more v2 display tags, and whose copyright line sits in the PDF. Not
#   the size, though it looks that way on disk - 6 922 against 3 024 bytes -
#   because the profile goes into the PDF Flate-compressed and the old one's
#   1024-point curves compress well: 2 449 against 2 553 bytes in the file,
#   measured. The table below prints those facts read off the profile bytes
#   at run time (exampleIccFacts in common.tcl), so the page cannot claim
#   what the file does not carry.
#
# THIS SCRIPT: icc/sRGB2014.icc, the ICC's own profile - given with -profile, and the identifier then comes from its desc tag.
#
# Check with:  verapdf -f 3u out.pdf
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "05.12-pdfa-srgb2014.pdf"}]
set assets [file join $here assets]
set regular [file join $assets fonts DejaVuSans.ttf]
set bold [file join $assets fonts DejaVuSans-Bold.ttf]
set profile [file join [file dirname $here] icc sRGB2014.icc]

set doc [tclpdf new -unit mm]

$doc info Title "The same page under the ICC's sRGB2014 profile"
$doc info Author "Alexander Schoepe"
$doc info Subject "sRGB output intents compared - the ICC's sRGB2014 profile"
$doc info Keywords "sRGB, ICC, output intent, PDF/A"
$doc language en-GB

$doc page add
$doc font embed face $regular
$doc font embed faceBold $bold

set facts [exampleIccFacts $profile]

# -- the page --------------------------------------------------------------

$doc font -family faceBold -size 14 -color black
$doc text "The same page under the ICC's sRGB2014 profile" -at {20 25}
$doc font -family face -size 9 -color {0.35 0.35 0.35}
$doc text "Example 5.12 - its twin is 05.11, byte for byte the same script but for the profile." -at {20 32}

$doc font -family face -size 10 -color black
set y [$doc text "This document declares PDF/A-3U with [file tail $profile] as its\
    output intent. The strip below is the same in both documents of the pair:\
    the six sRGB primaries and secondaries, eight greys and a photograph. Seen\
    relative to the intent, as viewers show it, the two pages are the same;\
    what differs is in the file, and the table under the strip prints it from\
    the profile's own bytes." -at {20 42} -width 170 -align justify -anchor top]

# The strip: primaries and secondaries as sRGB triples, greys as single
# values (DeviceGray, admitted by every intent), then the photograph.
set x 20
foreach colour {{1 0 0} {0 1 0} {0 0 1} {0 1 1} {1 0 1} {1 1 0}} {
    $doc rect -at [list $x [expr {$y + 6}]] -size {12 12} -fill $colour
    set x [expr {$x + 13}]
}
foreach grey {0 0.14 0.29 0.43 0.57 0.71 0.86 1} {
    $doc rect -at [list $x [expr {$y + 6}]] -size {8 12} -fill $grey -stroke 0.6 -width 0.1
    set x [expr {$x + 9}]
}
$doc image draw [file join $assets images sample-photo.jpg] \
    -at [list [expr {$x + 4}] [expr {$y + 6}]] -width 22 \
    -alt "A landscape photograph, for the colour comparison"
$doc font -family face -size 7 -color {0.45 0.45 0.45}
$doc text "sRGB primaries and secondaries - greys 0 to 1 - a photograph (JPEG, RGB)" \
    -at [list 20 [expr {$y + 22}]]

# What the profile says about itself.
set y [expr {$y + 30}]
$doc font -family faceBold -size 11 -color black
$doc text "The output intent, read from the profile bytes" -at [list 20 $y]
set rows [list \
    [list "File" [file tail $profile]] \
    [list "Size" "[dict get $facts size] bytes on disk, [dict get $facts flate] bytes as the Flate stream in this document"] \
    [list "ICC version, class, space" "[dict get $facts version], [dict get $facts class], [dict get $facts space]"] \
    [list "Description (desc)" [dict get $facts desc]] \
    [list "Copyright (cprt)" [dict get $facts cprt]] \
    [list "White point tag (wtpt)" "[join [dict get $facts wtpt] {  }] - [expr {[lindex [dict get $facts wtpt] 2] > 1 ? "D65, the display white" : "D50, the PCS white"}]"] \
    [list "Chromatic adaptation (chad)" [expr {[dict get $facts chad] ? "present - Bradford D65 to D50" : "absent"}]] \
    [list "Black point tag (bkpt)" [expr {[dict get $facts bkpt] eq {} ? "absent" : "[join [dict get $facts bkpt] {  }] - scaled to zero"}]] \
    [list "Tags ([llength [dict get $facts tags]])" [join [dict get $facts tags] { }]] \
]
set y [$doc table -at [list 20 [expr {$y + 6}]] -width 170 -theme grid \
    -style {family face size 9} -headStyle {family faceBold} \
    -head {{What Value}} -body $rows -columns {{width 52} {}}]

$doc font -family face -size 9 -color {0.35 0.35 0.35}
$doc text "Both profiles carry the same primaries and the same tone curve\
    (measured, icc/README.md); the ICC profile is the newer one and half the\
    file on disk, though not in the PDF, where both compress to much the same;\
    the OpenICC profile is the one without a copyright line. The identifier\
    written to the output intent is 'sRGB2014' - the profile's own desc tag, as for every profile given with -profile." \
    -at [list 20 [expr {$y + 8}]] -width 170

# -- the declaration ------------------------------------------------------

$doc pdfa -part 3 -conformance U -profile $profile

set state [$doc pdfa state]
puts "  PDF/A-[dict get $state part][dict get $state conformance],\
    intent from [file tail [dict get $state profile]] ([dict get $facts size] bytes)"

exampleDone $doc $target face
