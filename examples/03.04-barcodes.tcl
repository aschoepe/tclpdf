#!/usr/bin/env tclsh
#
# tclpdf example 3.4 - barcodes through tzint
#
#   tclsh examples/03.04-barcodes.tcl ?output.pdf?
#
# tclpdf carries no barcode encoder and will not grow one. It does not have to:
# tzint - the Tcl binding for libzint - encodes into SVG, and tclpdf draws SVG
# as real vectors. What arrives in the PDF is paths and text, not a picture:
# a MaxiCode keeps its hexagons and concentric circles, and the digits under an
# EAN stay copyable characters.
#
# tzint IS NOT REQUIRED. It is a C extension and therefore platform bound,
# which is why nothing in tclpdf depends on it - this example skips itself
# where it is absent, and everything else in the package is unaffected.
#
# NO TEMPORARY FILE is involved. The encoder writes its SVG into a Tcl
# variable and [svg -data] takes it from there. Measured with TMPDIR pointing
# at a directory with no write permission: the whole path runs through.
#
# TWO THINGS ABOUT THE ENCODER that cost time if unknown:
#
#   THE STATUS IS THREE-VALUED. 0 is silence, 1 to 4 are WARNINGS with a
#   perfectly good symbol, and only 5 and up mean nothing was produced. Code
#   that tests for "not zero" throws away usable barcodes - and the commonest
#   warning is a character outside the default set, a Euro sign is enough.
#
#   -eci 26 FORCES UTF-8. The EPC dataset behind a GiroCode names its own
#   character set in line 3, and without -eci the encoder picks one itself and
#   warns. The symbol scans either way, but its encoding is then not the one
#   the data claims.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

# The skip has to come before anything is drawn, and it has to be quiet about
# it: "make examples" runs every script and stops at the first failure.
if {[catch {package require tzint 1.3-}]} {
  puts "  skipped: tzint is not installed - this example needs it"
  exit 0
}

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "03.04-barcodes.pdf"}]
set assets [file join $here assets]

# One place for the status rule, so that no call site repeats it.
proc encode {varName data args} {
  upvar 1 $varName markup
  set rc [::tzint::Encode svg markup $data {*}$args -stat info]
  if {$rc >= 5} {
    error "barcode not produced: [dict get $info error]"
  }
  if {$rc != 0} {
    puts "  note: [dict get $info error]"
  }
  return $rc
}

set doc [tclpdf new -unit mm]
$doc info Title "Barcodes"
$doc page add

$doc font embed body [file join $assets fonts DejaVuSans.ttf]
$doc font embed bold [file join $assets fonts DejaVuSans-Bold.ttf]

$doc font -family bold -size 14 -color {0.20 0.30 0.45}
$doc text "Barcodes" -at {20 25}

$doc font -family body -size 9 -color {0.35 0.35 0.35}
$doc text "Encoded by tzint, drawn as vectors. No image, no detour through\
    the file system - the markup sits in a Tcl variable and goes straight\
    into \"svg -data\"." -at {20 33} -width 170

# -- the everyday ones -------------------------------------------------------

set y 50
foreach {label data options} {
    "Code 128"  "tclpdf 1.0"      {-barcode code128}
    "EAN-13"    "123456789012"    {-barcode ean13}
    "QR Code"   "https://fossil.sowaswie.de/tclpdf"  {-barcode qrcode}
    "DataMatrix" "Invoice 2026-114" {-barcode datamatrix}
    "PDF417"    "tclpdf 1.0 - ticket 4711" {-barcode pdf417}} {
  encode markup $data {*}$options
  $doc font -family body -size 8 -color {0.45 0.45 0.45}
  $doc text $label -at [list 20 $y]
  # -alt is not decoration: without it the drawing becomes an artifact and a
  # reader never learns what the symbol holds.
  #
  # PDF417 is a stacked code and comes out wide and flat - about 3.6 to 1. Its
  # height is therefore not what to fix; giving it a width keeps it beside the
  # others instead of towering over them.
  if {$label eq "PDF417"} {
    $doc svg -data $markup -at [list 55 [expr {$y - 6}]] -width 60 \
        -alt "$label: $data"
  } else {
    $doc svg -data $markup -at [list 55 [expr {$y - 6}]] -height 16 \
        -alt "$label: $data"
  }
  set y [expr {$y + 24}]
}

# -- EPC-QR, the one with a rule of its own ----------------------------------

$doc font -family bold -size 10 -color black
$doc text "GiroCode nach EPC069-12" -at [list 20 $y]
set y [expr {$y + 6}]

$doc font -family body -size 8 -color {0.45 0.45 0.45}
$doc text "Zeile 3 des Datensatzes sagt \"1\", also UTF-8. -eci 26 haelt die\
    Kodierung mit dieser Zusage in Deckung; -security 2 ist die von der\
    Spezifikation verlangte Fehlerkorrekturstufe M." -at [list 20 $y] -width 170
set y [expr {$y + 12}]

set epc "BCD\n002\n1\nSCT\nBANKDEFFXXX\nMuster GmbH\n\
    DE89370400440532013000\nEUR12.34\n\n\nRechnung 2026-114"
encode markup $epc -barcode qrcode -security 2 -eci 26
$doc svg -data $markup -at [list 20 $y] -height 30 \
    -alt "GiroCode: Ueberweisung 12,34 Euro an Muster GmbH"

$doc font -family body -size 8 -color black
$doc text "Muster GmbH" -at [list 60 [expr {$y + 8}]]
$doc text "12,34 EUR" -at [list 60 [expr {$y + 13}]]
$doc text "Rechnung 2026-114" -at [list 60 [expr {$y + 18}]]

set y [expr {$y + 40}]

# -- the clear text line, and why it is set here -----------------------------

$doc font -family bold -size 10 -color black
$doc text "The clear text line from the document, not from the encoder" -at [list 20 $y]
set y [expr {$y + 6}]

$doc font -family body -size 8 -color {0.45 0.45 0.45}
$doc text "An archivable document has to embed every font. Text inside an\
    SVG can only use the fourteen standard faces today, and those are not\
    embedded - hence -notext 1 and the digits set with tclpdf." \
    -at [list 20 $y] -width 170
set y [expr {$y + 14}]

encode markup "123456789012" -barcode ean13 -notext 1
$doc svg -data $markup -at [list 20 $y] -height 16 -alt "EAN-13 1234567890128"
$doc font -family body -size 8 -color black
$doc text "1 234567 890128" -at [list 20 [expr {$y + 20}]]

exampleFooter $doc body
$doc write $target
puts "  written: $target"
