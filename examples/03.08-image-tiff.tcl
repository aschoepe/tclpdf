#!/usr/bin/env tclsh
#
# tclpdf example 3.8 - a TIFF, and the strips it is made of
#
#   tclsh examples/03.08-image-tiff.tcl ?output.pdf?
#
# A TIFF is not one block of pixels. It is a directory of tags and a list of
# STRIPS, each a horizontal band of the picture compressed on its own, and
# that is the one thing about the format a caller here can notice: a picture
# whose compression carries state from one row to the next cannot have its
# strips joined, so it reaches the file as several image XObjects, stacked one
# above the other by [image place]. Nothing about the call says so - the
# picture is embedded, sized and placed exactly as a JPEG or a PNG is - but
# [image info] answers "strips", and a reader looking at the file will find
# that many /Do operators where a JPEG has one.
#
# The strips are passed through. Every compression that occurs in the wild has
# a PDF filter that undoes it - Deflate is /FlateDecode, PackBits is
# /RunLengthDecode, CCITT Group 3 and 4 are /CCITTFaxDecode, TIFF 6.0
# Technote 2 JPEG is /DCTDecode - so nothing is decoded to be written out
# again, Group 4 fax data included. LZW is the exception and is unpacked into
# Flate, because PDF/A forbids /LZWDecode outright (ISO 19005-3, 6.1.7.2) and
# a stream that was passed through cannot be repaired once [pdfa] is declared.
#
# TWO THINGS THIS PAGE SHOWS, both of which are easy to get wrong:
#
#   THE SCAN ARRIVES AT ITS OWN SIZE. A TIFF states its resolution, and
#   -dpi auto - the default - uses it. The picture below is 640 pixels wide
#   at 200 dpi, which is 81 mm of paper. Read as 72 dpi it would be 226 mm
#   wide and off the sheet; a 1728-pixel fax page is 219 mm of paper at its
#   own 200 dpi and 610 mm read as 72.
#
#   THE PARTS BUTT TOGETHER SEAMLESSLY. The picture below is thirty XObjects
#   of sixteen rows each. Each part carries the rows it holds and no others,
#   they are placed as thirty cm/Do pairs inside the one q ... Q of the
#   placement, and no row is drawn twice or left out. Rendered at the
#   picture's own resolution the result is byte for byte the samples of the
#   TIFF; the second page enlarges it so that the strip boundaries can be
#   looked for.
#
# What a stack cannot be is a mask, and the script asks for that on purpose
# and prints the refusal on the page: /Mask and /SMask name ONE image XObject.
#
# The archivable twin beside the main document is the point that had to be
# proved rather than asserted: a striped TIFF under PDF/A-3B. <name>-pdfa.pdf
# puts the same picture under an sRGB output intent, and veraPDF says whether
# it holds.
#
# The picture is examples/assets/images/sample-scan.tiff and was drawn for
# this page: greyscale, 200 dpi, Deflate with a horizontal predictor, sixteen
# rows to the strip - what a scanner writes. Its sky is a smooth gradient on
# purpose, because that is where a seam between two parts would show first;
# and it says what it is, so that a page torn out of a printout still names
# the file it came from.
#
# Check it yourself:
#   qpdf --check 03.08-image-tiff.pdf
#   qpdf --qdf --object-streams=disable 03.08-image-tiff.pdf - | grep -c ' Do'
#   pdfimages -list 03.08-image-tiff.pdf
#   pdftoppm -r 200 -png 03.08-image-tiff.pdf page
#   verapdf -f 3b 03.08-image-tiff-pdfa.pdf
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "03.08-image-tiff.pdf"}]
set archival [file rootname $target]-pdfa.pdf
set images [file join $here assets images]
set scan [file join $images sample-scan.tiff]
set regular [file join $here assets fonts DejaVuSans.ttf]
set intent [file join [file dirname $here] icc sRGB.icc]

set doc [tclpdf new -unit mm]
$doc info Title "tclpdf example: a TIFF, and the strips it is made of"
$doc page add

set y 20
exampleHeading $doc y "A TIFF, and the strips it is made of"
examplePara $doc y "A TIFF is a directory of tags and a list of strips - bands\
    of the picture, each compressed on its own. The file below is a 640 by 480\
    greyscale scan at 200 dpi, Deflate-compressed with a horizontal predictor,\
    sixteen rows to the strip. It is embedded and placed like any other\
    picture; what the format costs is visible only in what the file comes out\
    as, and in the two numbers \[image info] adds for it."

$doc image embed scan $scan
set info [$doc image info scan]

# -- the scan at its own size ------------------------------------------------
#
# No -width and no -dpi: the default -dpi auto reads the file's own
# resolution, and 640 pixels at 200 dpi are 81.28 mm.
lassign [$doc image size scan] naturalWidth naturalHeight
$doc image place scan -at [list 20 $y] -artifact 1

$doc font -family helvetica -style {} -size 7.5 -color {0.25 0.25 0.3}
$doc text "placed with neither -width nor -dpi:\
    [format %.2f $naturalWidth] x [format %.2f $naturalHeight] mm" \
    -at [list 20 [expr {$y + $naturalHeight + 4}]]

# What the file says about itself, read back OUT of the document rather than
# repeated from the lines above - a table that states what was asked for
# cannot notice when the file says something else.
set rows {}
foreach key {type width height bitDepth components compression strips
    rowsPerStrip space xResolution resolution} {
    lappend rows [list $key [dict get $info $key]]
}
set y [$doc table -at [list 110 $y] -width 80 -theme striped \
    -head {{{image info} answers}} -body $rows]

set y [expr {$y + 6}]
examplePara $doc y "The resolution is not a comfort entry. A pixel is 1/dpi of\
    an inch, so this picture is [format %.2f $naturalWidth] mm wide; read as\
    72 dpi, which is what a file that states nothing gets, the same 640 pixels\
    would be [format %.0f [lindex [$doc image size scan -dpi 72] 0]] mm and\
    would not fit on the sheet. A scanned fax page - 1728 pixels at the 200\
    dpi of the fax line - is 219 mm of paper and 610 mm at 72."

exampleHeading $doc y "Thirty strips, thirty image XObjects"
examplePara $doc y "Deflate begins afresh in every strip: a zlib stream ends\
    where the strip ends. So the strips cannot be concatenated, and each one\
    becomes an image XObject of its own, [dict get $info strips] of them here,\
    each [dict get $info rowsPerStrip] rows tall. \[image place] puts them\
    back together as [dict get $info strips] cm/Do pairs inside the one q ...\
    Q of the placement - no form XObject around them, so a TIFF of one strip\
    can still be another picture's soft mask. Uncompressed and PackBits\
    strips carry no state and are joined into a single stream, and LZW is\
    stateless once it has been unpacked, so those files arrive as one image."

set y [expr {$y + 1}]
exampleCommandBlock $doc y [list \
    "pdfimages -list [file tail $target]" \
    "qpdf --qdf --object-streams=disable [file tail $target] - | grep -c ' Do'"]

exampleFooter $doc
$doc page add

set y 20
exampleHeading $doc y "Where the strips meet"
examplePara $doc y "The same file again, enlarged to 170 mm - two and an eighth\
    times its own size - so that the boundaries between the parts can be\
    looked for. Every [dict get $info rowsPerStrip] image rows is a new\
    XObject, which on this page is one every [format %.2f [expr {170.0 *\
    [dict get $info rowsPerStrip] / [dict get $info height]}]] mm. Each part\
    carries the rows it holds and no others: no row is drawn twice and none is\
    left out, which is what makes the picture come together rather than drift\
    apart over thirty placements."

$doc image place scan -at [list 20 $y] -width 170 -artifact 1
set y [expr {$y + 170.0 * [dict get $info height] / [dict get $info width] + 6}]

exampleHeading $doc y "What a stack cannot be"
examplePara $doc y "A mask is one image: the Mask and SMask entries of an\
    image dictionary name a single image XObject (ISO 32000-2, Table 87 and\
    Table 143). A picture that is thirty of them therefore cannot be one, and\
    cannot wear one either - the mask would be drawn over each part in turn\
    instead of over the picture. Asked for it anyway, tclpdf refuses by name.\
    The refusal below was caught with try/trap and is printed as it came:"

# Asked for on purpose. The -errorcode is the contract - trap matches it by
# prefix - and the message is what the reader gets to see.
$doc image embed base [file join $images sample-photo.jpg] -mask scan
set refusal "no refusal came back"
set code {}
try {
    $doc image place base -at {20 250} -width 40 -artifact 1
} trap {TCLPDF TIFF STACKED} {message options} {
    set refusal $message
    set code [dict get $options -errorcode]
}

$doc font -family courier -style {} -size 8 -color {0.10 0.28 0.62}
$doc text "-errorcode $code" -at [list 20 $y]
set y [expr {$y + 6}]
$doc font -family helvetica -style {} -size 8.5 -color {0.45 0.15 0.15}
set y [expr {[$doc text $refusal -at [list 20 $y] -width 170] + 5}]

examplePara $doc y "The way out is named in the message and is the same one\
    for all three refusals a stack can produce - the third is a strip count\
    above 256, where the picture is refused rather than stacked: re-save the\
    file with a RowsPerStrip that holds the whole picture, and it becomes one\
    image again."

exampleFooter $doc
$doc write $target
puts "  written: $target ([file size $target] bytes)"
$doc destroy

# -- the archivable twin -----------------------------------------------------
#
# The claim that had to be proved rather than asserted. A striped TIFF is
# thirty streams, and every one of them has to be a filter ISO 19005-3 admits
# - which is why LZW is unpacked into Flate on the way in and never passed
# through: 6.1.7.2 rules /LZWDecode out, and by the time [pdfa] is declared
# the picture's streams have long been written.

set doc [tclpdf new -unit mm]
$doc pdfa -part 3 -conformance B -profile $intent
$doc info Title "A striped TIFF under PDF/A-3B"
$doc font embed body $regular
$doc page add

$doc font -family body -size 12 -color {0 0 0}
$doc text "A striped TIFF under PDF/A-3B" -at {20 20}
$doc font -size 9 -color {0.15 0.15 0.15}
$doc text "PDF/A-3B, output intent [file tail $intent]. The picture is the\
    same scan as on the other pages: [dict get $info strips] image XObjects,\
    every one of them a /FlateDecode stream, and DeviceGray, which every\
    output intent admits (ISO 19005-2, 6.2.4.3). A TIFF whose strips are LZW\
    arrives here as Flate too - the unpacking happens on the way in, because\
    ISO 19005-3, 6.1.7.2 forbids /LZWDecode and a stream already written\
    cannot be repaired." -at {20 28} -width 170

$doc image embed scan $scan
$doc image place scan -at {20 62} -width 100 -artifact 1

exampleDone $doc $archival body
