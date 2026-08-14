#!/usr/bin/env tclsh
#
# tclpdf example 3.5 - text inside a drawing, in an embedded face
#
#   tclsh examples/03.05-svg-text.tcl ?output.pdf?
#
# A <text> in an SVG goes through the same font machinery as [text] does. That
# sounds like an internal detail and is not: until it did, a drawing could
# only ever use the fourteen standard faces, and that ruled out three separate
# things.
#
# 1. THE CHARACTERS. The standard faces are measured in WinAnsi, which is 224
#    printable positions. Every place name east of Vienna is outside it -
#    Lodz, Plzen, Istanbul, Moskva as their inhabitants write them - and a
#    drawing containing one did not come out looking wrong, it ABORTED. In an
#    ordinary PDF as much as in an archivable one; this half has nothing to do
#    with PDF/A.
#
# 2. THE FACE. A drawing could not be set in the house face. Worse, naming it
#    was the one thing that failed loudly while an unknown name fell back
#    quietly - so the careful spelling broke and the careless one worked.
#
# 3. ARCHIVING. PDF/A embeds every font it finds. A drawing with one label
#    could not be archived at all, which is every letterhead as SVG, every
#    chart with an axis, and every barcode caption.
#
# All three come from the same place and are gone together. This document is
# PDF/A-3u, which is the proof of the third: it could not have been written
# before.
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "03.05-svg-text.pdf"}]
set assets [file join $here assets]
set regular [file join $assets fonts DejaVuSans.ttf]
set bold [file join $assets fonts DejaVuSans-Bold.ttf]
set mono [file join $assets fonts OCRB.ttf]
set profile [file join [file dirname $here] icc sRGB.icc]

set doc [tclpdf new -unit mm]
$doc info Title "Text inside a drawing"
$doc info Author "Alexander Schoepe"
$doc info Subject "SVG labels set in an embedded face"
$doc page add

# The alias is the name a drawing reaches the face by. It is worth choosing it
# to match what the SVG says - see the barcode at the bottom, where the
# encoder picked the name and this end had only to provide it.
$doc font embed body $regular
$doc font embed bold $bold
$doc font embed OCRB $mono

$doc font -family bold -size 15 -color {0.20 0.30 0.45}
$doc text "Labels in a drawing" -at {20 22}

# -- the characters ----------------------------------------------------------

set y 32
$doc font -family body -size 9 -color {0.35 0.35 0.35}
$doc text "The same five names, drawn inside an SVG. Nothing about them is\
    unusual - they are ordinary spellings of ordinary cities, and each one\
    used to abort the drawing." -at [list 20 $y] -width 170
set y [expr {$y + 12}]

set cities {Lodz Plzen Istanbul Moskva Malmo}
set spelled [list "Łódź" "Plzeň" "İstanbul" \
    "Москва" "Malmö"]

# The drawing is built as markup rather than drawn with [text], because that
# is the point: this is what arrives from a chart tool or a letterhead.
set labels {}
set column 8
foreach name $spelled {
  append labels "<text x=\"$column\" y=\"14\" font-family=\"body\"\
      font-size=\"7\" fill=\"#1a3350\">$name</text>"
  incr column 36
}
$doc svg -data "<svg viewBox=\"0 0 190 20\"><rect x=\"0\" y=\"0\" width=\"190\"\
    height=\"20\" fill=\"#eef2f7\"/>$labels</svg>" -at [list 20 $y] -width 170
set y [expr {$y + 26}]

# What the same drawing does with a standard face, caught rather than
# described - a claim about an error message is worth as much as the message.
set standard [string map {font-family=\"body\" font-family=\"helvetica\"} $labels]
set message ""
if {[catch {
  $doc svg -data "<svg viewBox=\"0 0 190 20\">$standard</svg>" \
      -at [list 20 $y] -width 170
} message]} {
  $doc font -family body -size 8 -color {0.65 0.20 0.20}
  $doc text "With a standard face the same drawing stops: $message" \
      -at [list 20 $y] -width 170
  set y [expr {$y + 10}]
}

# -- the face ----------------------------------------------------------------

$doc font -family bold -size 11 -color black
$doc text "The drawing names the face" -at [list 20 $y]
set y [expr {$y + 7}]

$doc font -family body -size 9 -color {0.35 0.35 0.35}
$doc text "font-family is a wish list and the first name that resolves wins.\
    An embedded face resolves under the alias it was embedded as, so a chart\
    can ask for the house face by name. A list nobody can satisfy at all ends\
    at helvetica rather than failing - which is right for a drawing, and worth\
    knowing in an archivable document, because that face is not embedded and\
    the document would then be refused." -at [list 20 $y] -width 170
set y [expr {$y + 20}]

set sample {<svg viewBox="0 0 190 30">
  <rect x="0" y="0" width="190" height="30" fill="#f7f5ef"/>
  <text x="6" y="10" font-family="bold" font-size="5">house face, by its alias</text>
  <text x="6" y="19" font-family="body" font-size="5">AVATAR - kerned, because the run is the same one [text] builds</text>
  <text x="6" y="27" font-family="Nonesuch, body" font-size="4.5" fill="#7a7a7a">an unknown first name still draws - the list is walked to the end</text>
</svg>}
$doc svg -data $sample -at [list 20 $y] -width 170
set y [expr {$y + 34}]

# -- a chart, which is where this actually turns up --------------------------

$doc font -family bold -size 11 -color black
$doc text "An axis is a row of labels" -at [list 20 $y]
set y [expr {$y + 7}]

set bars {}
set axis {}
set x 14
foreach name $spelled value {62 48 91 77 35} {
  set height [expr {$value * 0.45}]
  append bars "<rect x=\"$x\" y=\"[expr {56 - $height}]\" width=\"22\"\
      height=\"$height\" fill=\"#4a6fa5\"/>"
  append axis "<text x=\"[expr {$x + 11}]\" y=\"63\" font-family=\"body\"\
      font-size=\"5\" text-anchor=\"middle\">$name</text>"
  append axis "<text x=\"[expr {$x + 11}]\" y=\"[expr {53 - $height}]\"\
      font-family=\"body\" font-size=\"5\" text-anchor=\"middle\"\
      fill=\"#4a6fa5\">$value</text>"
  incr x 34
}
$doc svg -data "<svg viewBox=\"0 0 190 68\">$bars<line x1=\"10\" y1=\"56\"\
    x2=\"184\" y2=\"56\" stroke=\"#333333\" stroke-width=\"0.5\"/>$axis</svg>" \
    -at [list 20 $y] -width 170
set y [expr {$y + 66}]

# text-anchor="middle" is what makes this a real test of the measurement: the
# label is centred on the bar by its own width, so a face measured wrong puts
# every caption off centre without anything failing.

# -- the barcode caption, in the face the encoder asked for ------------------

$doc font -family bold -size 11 -color black
$doc text "A caption the encoder wrote" -at [list 20 $y]
set y [expr {$y + 7}]

if {[catch {package require tzint 1.3-}]} {
  $doc font -family body -size 9 -color {0.45 0.45 0.45}
  $doc text "tzint is not installed here, so this part is left out. It draws\
      an EAN-13 whose clear text line is set by the encoder in OCR-B."\
      -at [list 20 $y] -width 170
} else {
  $doc font -family body -size 9 -color {0.35 0.35 0.35}
  $doc text "tzint writes font-family=\"OCRB, monospace\" into its markup and\
      this document embeds a face under exactly that alias. The digits are\
      therefore set in real OCR-B, they are text rather than picture, and the\
      markup was not touched to achieve it - which is what makes an archivable\
      barcode caption a matter of embedding the right face rather than of\
      setting the line by hand." -at [list 20 $y] -width 170
  set y [expr {$y + 20}]

  set markup {}
  # Status 1 to 4 is a warning WITH output; from 5 up nothing is produced and
  # the target variable keeps what it held before. Testing for "not zero"
  # throws usable symbols away, testing the variable draws the previous
  # barcode again.
  set rc [::tzint::Encode svg markup "426000000001" -barcode ean13 -stat info]
  if {$rc >= 5} {
    error "tzint: [dict get $info error]"
  }
  $doc svg -data $markup -at [list 20 $y] -height 22 \
      -alt "EAN-13 4260000000017"
}

# -- the declaration ---------------------------------------------------------

# Every face in this document is embedded, including the ones only a drawing
# ever asks for. That is the whole of what stood in the way.
$doc pdfa -part 3 -conformance U -profile $profile

set state [$doc pdfa state]
exampleFooter $doc body
$doc write $target
puts "  written: $target"
puts "  PDF/A-[dict get $state part][dict get $state conformance],\
    fonts: [join [$doc font names] {, }]"
$doc destroy
