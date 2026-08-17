#!/usr/bin/env tclsh
#
# tclpdf example 2.7 - embedding a Type 1 font
#
#   tclsh examples/02.07-type1.tcl ?output.pdf?
#
# Type 1 is the older of the two font formats a PDF can carry, and embedding
# one is the cheapest thing this package does: the file already consists of
# the three pieces PDF asks for as Length1, Length2 and Length3 - a PostScript
# header in the clear, the eexec-encrypted body, and a closing block of zeros.
# Finding the two boundaries and copying the bytes is the whole of it. Nothing
# is decrypted and no outline is read.
#
# THE PRICE, stated plainly: the face goes in WHOLE. Subsetting a Type 1
# program would mean decrypting eexec and understanding Type 1 charstrings,
# which is the work this way exists to avoid. For the faces here that is 25 to
# 105 KB - fine for a form or a label, and the reason to prefer TrueType where
# a document uses one face for two words.
#
# WHERE THE WIDTHS COME FROM. Not from the font: they sit in its charstrings,
# behind the encryption. They come from the AFM beside it, addressed by glyph
# NAME rather than by code - which is why this example also shows the check
# that matters, the same face measured on both roads.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf
package require tclpdf::type1

# The footer every example draws - shared, because one copy per example is
# how a block starts drifting.
source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "02.07-type1.pdf"}]
set assets [file join $here assets]
set urw [file join $assets fonts urw-core35-fonts]
set profile [file join [file dirname $here] icc sRGB.icc]

set doc [tclpdf new -unit mm]
$doc info Title "A Type 1 face, embedded whole"
$doc info Author "Alexander Schoepe"
$doc page add

# Two containers of the same format. A .pfb wraps the three pieces in segment
# markers that state their lengths; a .t1 carries them raw, and the lengths
# are found in the content. Both arrive here as the same thing.
$doc font embed ocrb [file join $assets fonts tsukurimashou OCRB.pfb]
$doc font embed sans [file join $urw NimbusSans-Regular.t1]
$doc font embed serif [file join $urw NimbusRoman-Regular.t1]

# The same face as TrueType, for the comparison further down.
$doc font embed sansTT [file join $urw NimbusSans-Regular.ttf]

$doc font -family sans -size 15
$doc text "A Type 1 face, embedded whole" -at {20 22}

$doc font -family sans -size 9 -color {0.35 0.35 0.35}
$doc text "Every line on this page is set in a face that was embedded from a\
    Type 1 program. None of it is a standard font, and the document is\
    PDF/A-3u - which requires every face to be embedded." \
    -at {20 30} -width 170

# -- what the file consists of ----------------------------------------------

set y 45
$doc font -family sans -size 11 -color black
$doc text "The three pieces" -at [list 20 $y]
set y [expr {$y + 7}]

$doc font -family sans -size 8 -color {0.35 0.35 0.35}
$doc text "Read out of the files themselves, not written down here: the clear\
    header, the encrypted body, the closing zeros. They become Length1,\
    Length2 and Length3 of the embedded stream." -at [list 20 $y] -width 170
set y [expr {$y + 12}]

set rows {}
foreach {label file} [list \
    OCRB.pfb [file join $assets fonts tsukurimashou OCRB.pfb] \
    NimbusSans-Regular.t1 [file join $urw NimbusSans-Regular.t1] \
    NimbusRoman-Regular.t1 [file join $urw NimbusRoman-Regular.t1]] {
  set program [::tclpdf::type1 read $file]
  lappend rows [list $label [dict get $program name] \
      [dict get $program length1] [dict get $program length2] \
      [dict get $program length3] [file size $file]]
}

# A table does not inherit the font state, it has one of its own - and in an
# archivable document that matters twice, because the default is a standard
# face and PDF/A refuses those.
$doc font -family sans -size 8 -color black
set y [$doc table -at [list 20 $y] -width 170 -theme grid \
    -style {family sans size 8} -headStyle {family sans size 8} \
    -head {{File {PostScript name} Length1 Length2 Length3 {File size}}} \
    -body $rows \
    -columns {{align left} {align left} {align right} {align right}
        {align right} {align right}}]
set y [expr {$y + 6}]

$doc font -family sans -size 8 -color {0.45 0.45 0.45}
$doc text "The three lengths of a .pfb add up to the file size less 20 bytes -\
    six per segment marker and two for the end marker. In a .t1 there are no\
    markers and they add up exactly." -at [list 20 $y] -width 170
set y [expr {$y + 12}]

# -- the check that matters --------------------------------------------------

$doc font -family sans -size 11 -color black
$doc text "The same face, measured on both roads" -at [list 20 $y]
set y [expr {$y + 7}]

$doc font -family sans -size 8 -color {0.35 0.35 0.35}
$doc text "The widths of a Type 1 face come from its AFM, by glyph name; the\
    widths of a TrueType face come from hmtx, by glyph number. Nimbus Sans is\
    here in both forms, so the two can be asked the same question - and a\
    name chosen wrongly would show up as nothing else." \
    -at [list 20 $y] -width 170
set y [expr {$y + 14}]

$doc font -family sans -size 10 -color black
foreach sample {Rechnung "Hamburgefonstiv" "AVATAR 12,34 EUR"} {
  set t1 [$doc textWidth $sample -family sans -size 10]
  set tt [$doc textWidth $sample -family sansTT -size 10 -kerning 0]
  $doc text $sample -at [list 20 $y] -family sans
  $doc font -family sans -size 8 -color {0.45 0.45 0.45}
  $doc text [format "Type 1: %.4f mm    TrueType: %.4f mm    difference: %.4f mm" \
      $t1 $tt [expr {abs($t1 - $tt)}]] -at [list 95 $y]
  $doc font -family sans -size 10 -color black
  set y [expr {$y + 7}]
}

# Kerning is off on the TrueType side for the comparison, and it has to be: a
# Type 1 face gets none here. The program carries no GPOS, and while an AFM
# does list kern pairs, reading them is a separate matter - the manual says so
# at the option.

set y [expr {$y + 4}]

# -- what it looks like ------------------------------------------------------

$doc font -family sans -size 11 -color black
$doc text "The faces themselves" -at [list 20 $y]
set y [expr {$y + 8}]

foreach {family label} {serif "Nimbus Roman, from NimbusRoman-Regular.t1"
                        sans "Nimbus Sans, from NimbusSans-Regular.t1"} {
  $doc font -family $family -size 12 -color black
  $doc text $label -at [list 20 $y]
  set y [expr {$y + 8}]
}

$doc font -family ocrb -size 12
$doc text "OCR-B 0123456789, from OCRB.pfb" -at [list 20 $y]
set y [expr {$y + 10}]

$doc font -family sans -size 8 -color {0.45 0.45 0.45}
$doc text "OCR-B is the face a barcode caption asks for - see 03.05-svg-text,\
    where it arrives through an SVG. There it is embedded as TrueType; here it\
    is the same design as a Type 1 program." -at [list 20 $y] -width 170

# -- the declaration ---------------------------------------------------------

$doc pdfa -part 3 -conformance U -profile $profile

exampleDone $doc $target sans
