#!/usr/bin/env tclsh
#
# tclpdf example 2.8 - embedding an OpenType font with CFF outlines
#
#   tclsh examples/02.08-opentype.tcl ?output.pdf?
#
# An .otf usually carries its outlines as CFF rather than as TrueType, and for
# a long time this package refused those: the subsetter rewrites the loca and
# glyf tables, and a CFF font has neither. Anyone whose house face came as
# .otf had to convert it first.
#
# THE ANSWER TURNED OUT NOT TO BE A CFF PARSER. PDF has an entry for a
# complete OpenType file - /FontFile3 with /Subtype /OpenType - and it takes
# the whole sfnt, cmap and all. So the CFF table never has to be understood,
# only carried. Everything else about such a file is the ordinary sfnt
# structure this package already reads: cmap for the character mapping, hmtx
# for the widths, head for the bounding box.
#
# THE PRICE, stated plainly: the face goes in WHOLE, because subsetting is
# exactly the part that would need the outlines. For the faces here that is
# around 40 KB. Where a document sets two words in one face, the TrueType form
# of the same face is the better choice - it goes in subsetted, and a subset
# of two words is a fraction of that.
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "02.08-opentype.pdf"}]
set here2 [file dirname $here]
set urw [file join $here assets fonts urw-core35-fonts]
set profile [file join $here2 icc sRGB.icc]

set doc [tclpdf new -unit mm]
$doc info Title "OpenType with CFF outlines"
$doc info Author "Alexander Schoepe"
$doc page add

# The same two faces, once as CFF and once as TrueType. Nothing about the
# call says which is which - the file is asked, not the extension.
$doc font embed sans [file join $urw NimbusSans-Regular.otf]
$doc font embed sansBold [file join $urw NimbusSans-Bold.otf]
$doc font embed serif [file join $urw NimbusRoman-Regular.otf]
$doc font embed sansTT [file join $urw NimbusSans-Regular.ttf]

$doc font -family sansBold -size 15 -color {0.20 0.30 0.45}
$doc text "OpenType with CFF outlines" -at {20 22}

$doc font -family sans -size 9 -color {0.35 0.35 0.35}
$doc text "Every face on this page came from an .otf file, and the document is\
    PDF/A-3u - which requires every one of them to be embedded. Until this\
    worked, a house face in that format could not be used at all." \
    -at {20 30} -width 170

# -- how it goes in ----------------------------------------------------------

set y 45
$doc font -family sansBold -size 11 -color black
$doc text "Two roads through the same package" -at [list 20 $y]
set y [expr {$y + 7}]

$doc font -family sans -size 8 -color {0.35 0.35 0.35}
$doc text "The difference is in the descendant font and in which FontFile\
    entry the program lands in. Everything before that - reading the cmap,\
    measuring, encoding, the ToUnicode map - is the same code for both."\
    -at [list 20 $y] -width 170
set y [expr {$y + 12}]

$doc font -family sans -size 8 -color black
set y [$doc table -at [list 20 $y] -width 170 -theme grid \
    -style {family sans size 8} -headStyle {family sansBold size 8} \
    -head {{{} {TrueType outlines} {CFF outlines}}} \
    -body {
      {{Font program} /FontFile2 {/FontFile3, /Subtype /OpenType}}
      {{Descendant} /CIDFontType2 /CIDFontType0}
      {{CID to glyph} {a CIDToGIDMap stream} {the font's own, no map needed}}
      {{Subsetting} {yes, through loca and glyf} {no - the face goes in whole}}
      {{Subset prefix} {yes, six letters} {no - nothing was subsetted}}
    } \
    -columns {{align left} {align left} {align left}}]
set y [expr {$y + 8}]

# -- what that costs ---------------------------------------------------------

$doc font -family sansBold -size 11 -color black
$doc text "What the whole face costs" -at [list 20 $y]
set y [expr {$y + 7}]

$doc font -family sans -size 8 -color {0.35 0.35 0.35}
$doc text "Read off the files themselves. A subset of a few words is a\
    fraction of either - which is the argument for the TrueType form where a\
    face is used for a heading and nothing else." -at [list 20 $y] -width 170
set y [expr {$y + 12}]

set rows {}
foreach base {NimbusSans-Regular NimbusRoman-Regular} {
  lappend rows [list $base \
      [format "%d bytes" [file size [file join $urw $base.otf]]] \
      [format "%d bytes" [file size [file join $urw $base.ttf]]]]
}
$doc font -family sans -size 8 -color black
set y [$doc table -at [list 20 $y] -width 170 -theme grid \
    -style {family sans size 8} -headStyle {family sansBold size 8} \
    -head {{Face {as .otf (embedded whole)} {as .ttf (subsetted on use)}}} \
    -body $rows \
    -columns {{align left} {align right} {align right}}]
set y [expr {$y + 8}]

# -- the check that matters --------------------------------------------------

$doc font -family sansBold -size 11 -color black
$doc text "The same face, from either format" -at [list 20 $y]
set y [expr {$y + 7}]

$doc font -family sans -size 8 -color {0.35 0.35 0.35}
$doc text "Nimbus Sans is in this tree as .otf and as .ttf. The widths come\
    from hmtx either way, but through two different files with different units\
    per em - so agreement is worth measuring rather than assuming."\
    -at [list 20 $y] -width 170
set y [expr {$y + 12}]

$doc font -family sans -size 10 -color black
foreach sample {Rechnung Hamburgefonstiv "AVATAR 12,34 EUR"} {
  set cff [$doc textWidth $sample -family sans -size 10 -kerning 0]
  set ttf [$doc textWidth $sample -family sansTT -size 10 -kerning 0]
  $doc text $sample -at [list 20 $y] -family sans
  $doc font -family sans -size 8 -color {0.45 0.45 0.45}
  $doc text [format "CFF: %.4f mm    TrueType: %.4f mm    difference: %.4f mm" \
      $cff $ttf [expr {abs($cff - $ttf)}]] -at [list 95 $y]
  $doc font -family sans -size 10 -color black
  set y [expr {$y + 7}]
}

set y [expr {$y + 3}]
$doc font -family sans -size 8 -color {0.45 0.45 0.45}
$doc text "The remainder is rounding, and it grows with the line: one file\
    carries 1000 units per em and the other 2048, so every glyph rounds by up\
    to half a unit." -at [list 20 $y] -width 170
set y [expr {$y + 12}]

# -- the faces themselves ----------------------------------------------------

$doc font -family sansBold -size 11 -color black
$doc text "The faces" -at [list 20 $y]
set y [expr {$y + 8}]

foreach {family label} {serif "Nimbus Roman, from NimbusRoman-Regular.otf"
                        sans "Nimbus Sans, from NimbusSans-Regular.otf"
                        sansBold "Nimbus Sans Bold, from NimbusSans-Bold.otf"} {
  $doc font -family $family -size 12 -color black
  $doc text $label -at [list 20 $y]
  set y [expr {$y + 8}]
}

# -- the declaration ---------------------------------------------------------

$doc pdfa -part 3 -conformance U -profile $profile

exampleDone $doc $target sans
