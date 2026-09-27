#!/usr/bin/env tclsh
#
# tclpdf example 3.7 - a picture as a stencil, and a picture as a mask
#
#   tclsh examples/03.07-image-masks.tcl ?output.pdf?
#
# Two ways a picture can stop being a picture.
#
# A STENCIL MASK (ISO 32000-2, 8.9.6.2) is a one-bit image whose samples do not
# carry colour at all: they "designate places on the page that should either be
# marked with the current colour or masked out". What reaches the paper is the
# fill colour in force, through the bits of the file - "like applying paint in
# the current colour through a cut-out stencil". That is the way in for a
# single-colour logo or a stamp that has to take the colour of the document it
# lands in, and it is one option: [image embed -stencil 1].
#
# A MASK THE CALLER NAMES is the other half. Until now a mask only ever came
# out of a PNG's own alpha channel; [image embed -mask <alias>] names a SECOND
# embedded picture as the mask of this one. What that becomes in the file
# depends on what the named picture is, and the difference is not cosmetic: a
# stencil is all-or-nothing and becomes /Mask (8.9.6.3, explicit masking), a
# greyscale picture is coverage and becomes /SMask (11.6.5.2, soft-mask
# images) - which is what makes the photograph below fade out at its edges
# instead of ending at them.
#
# -interpolate 1 comes with them, because Table 87 puts it in the same
# dictionary: a hint that the picture "might render better if interpolation is
# used" (8.9.5.3). It is a hint and nothing more - "a PDF processor may ignore
# it" - so this page shows where it lands in the file rather than claiming an
# effect on screen.
#
# The archivable twin beside the main document is the point that needed
# proving: a stencil has no colour space AT ALL (Table 87 - with ImageMask true
# ColorSpace "shall not be specified"), so there is nothing for a PDF/A output
# intent to judge. <name>-pdfa.pdf puts a stencil and a soft-masked photograph
# under a GREY intent, and veraPDF says whether that holds.
#
# Check it yourself:
#   qpdf --check 03.07-image-masks.pdf
#   qpdf --qdf --object-streams=disable 03.07-image-masks.pdf - | grep -n ImageMask
#   pdftoppm -r 150 -png 03.07-image-masks.pdf page
#   verapdf -f 3b 03.07-image-masks-pdfa.pdf
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "03.07-image-masks.pdf"}]
set archival [file rootname $target]-pdfa.pdf
set images [file join $here assets images]
set stencil [file join $images sample-stencil.png]
set vignette [file join $images sample-vignette.png]
set photo [file join $images sample-photo.jpg]
set grey [file join $images sample-gray.jpg]
set regular [file join $here assets fonts DejaVuSans.ttf]
set intent [file join [file dirname $here] icc ISOcoated_v2_grey1c_bas.ICC]

set doc [tclpdf new -unit mm]
$doc info Title "tclpdf example: a picture as a stencil, and a picture as a mask"
$doc page add

$doc font -family helvetica -style bold -size 14
$doc text "A picture as a stencil, and a picture as a mask" -at {20 20}

$doc font -style {} -size 9
$doc text "The same 300 x 300 pixel file four times below. It carries one bit\
    per sample and is embedded with -stencil 1, so it has no colour of its\
    own: each placement paints the fill colour that stands in the graphics\
    state through the bits of the file. The fourth is the same file with\
    -invert 1, which reverses which of the two bits is the ink." \
    -at {20 28} -width 170

# -- the stencil ------------------------------------------------------------
#
# One embedding, one object in the file, four placements in four colours. The
# colour is [style -fill], which is the graphics state - the stencil has no
# say in it, which is the whole point of 8.9.6.2.
$doc image embed stamp $stencil -stencil 1
$doc image embed cutout $stencil -stencil 1 -invert 1

set x 20
foreach {alias colour label} {
    stamp {0.72 0.11 0.13} {style -fill red}
    stamp {0.10 0.28 0.62} {style -fill blue}
    stamp {gray 0.55} {style -fill grey}
    cutout {0.10 0.42 0.22} {-invert 1}
} {
    $doc style -fill $colour
    $doc image place $alias -at [list $x 46] -size {32 32} -artifact 1
    $doc font -family helvetica -style {} -size 7.5 -color {0.25 0.25 0.3}
    $doc text $label -at [list $x 81]
    incr x 40
}

# -- a picture masked by a picture ------------------------------------------

$doc font -family helvetica -style bold -size 10 -color {0 0 0}
$doc text "A mask the caller names" -at {20 92}

$doc font -style {} -size 9
set y [$doc text "The photograph on the right is embedded with -mask fade,\
    naming a second embedded picture - a 640 x 480 greyscale PNG that is white\
    in the middle and black at the rim. It reaches the file as the /SMask of\
    the photograph, and the coloured band shows through wherever the mask is\
    dark. The one on the left is the same JPEG without it." \
    -at {20 98} -width 170]

# The band both pictures sit on, so that what the mask lets through is
# visible as something rather than as white paper.
$doc rect -at {20 118} -size {170 56} -fill {0.93 0.80 0.35}

$doc image embed fade $vignette
$doc image embed plain $photo
$doc image embed faded $photo -mask fade -interpolate 1
$doc image place plain -at {20 118} -size {82 56} -artifact 1
$doc image place faded -at {108 118} -size {82 56} -artifact 1

$doc font -size 7.5 -color {0.25 0.25 0.3}
$doc text "the JPEG as it is" -at {20 177}
$doc text "-mask fade -interpolate 1" -at {108 177}

# -- what the file says -----------------------------------------------------
#
# Read back OUT of the document rather than repeated from the calls above -
# the same rule the footer follows. A line that states what was asked for
# cannot notice when the file says something else.
$doc font -family helvetica -style {} -size 9 -color {0 0 0}
set rows {}
foreach alias {stamp cutout fade faded} {
    set info [$doc image info $alias]
    lappend rows [list $alias [dict get $info stencil] \
        [expr {[dict get $info mask] eq {} ? "-" : [dict get $info mask]}] \
        [dict get $info interpolate] \
        [expr {[dict get $info type] eq "png"
            ? [dict get $info transparency] : "-"}]]
}
set y [$doc table -at {20 184} -width 170 -theme striped \
    -head {{alias stencil mask interpolate transparency}} -body $rows]

$doc font -size 9
set y [$doc text "-interpolate 1 is a hint and Table 87 gives it the default\
    false, so it is written only where it is asked for; 8.9.5.3 says outright\
    that a processor may ignore it. Where it is honoured on a stencil the\
    effect is to smooth the edges of the MASK rather than the colour it lets\
    through (8.9.6.2). What can be checked is the file, and that is what the\
    commands below do." -at [list 20 [expr {$y + 6}]] -width 170]

set y [expr {$y + 4}]
exampleCommandBlock $doc y [list \
    "qpdf --qdf --object-streams=disable [file tail $target] - | grep -n ImageMask" \
    "pdftoppm -r 150 -png [file tail $target] page" \
    "verapdf -f 3b [file tail $archival]"]

exampleFooter $doc
$doc write $target
puts "  written: $target ([file size $target] bytes)"
$doc destroy

# -- the archivable twin ----------------------------------------------------
#
# The claim that had to be proved rather than asserted: a stencil mask brings
# no colour space into the document, so an output intent has nothing to hold
# against it - what it paints is the fill colour, and that colour is judged
# where it is set. Under a GREY intent, therefore, a grey fill and a grey
# photograph pass, and so does the soft mask, which is DeviceGray by Table 143.

set doc [tclpdf new -unit mm]
$doc pdfa -part 3 -conformance B -profile $intent
$doc info Title "A stencil mask and a soft mask under a grey output intent"
$doc font embed body $regular
$doc page add

$doc font -family body -size 12 -color {gray 0}
$doc text "A stencil mask under a grey output intent" -at {20 20}
$doc font -size 9 -color {gray 0.15}
$doc text "PDF/A-3B, output intent [file tail $intent]. The stamp below is the\
    same one-bit file as on the other page. It carries no colour space at all\
    (ISO 32000-2, Table 87: with ImageMask true ColorSpace shall not be\
    specified), so ISO 19005-2, 6.2.4.3 has nothing to judge it by - what is\
    judged is the DeviceGray fill it is painted with. The photograph beside it\
    is the greyscale JPEG under the same soft mask, and a soft-mask image is\
    DeviceGray by Table 143." -at {20 28} -width 170

$doc image embed stamp $stencil -stencil 1
$doc image embed fade $vignette
# -interpolate does NOT come along into the archivable twin, and that is the
# point of this block rather than an omission: ISO 19005-2, 6.2.8 says the
# Interpolate key "shall not be present, or shall have a value of false", and
# veraPDF reports it. The refusal is measured here rather than described,
# under both orders, since a script may declare the profile before or after
# it places its pictures.
set refused {}
foreach order {declared-first placed-first} {
  set probe [tclpdf new -unit mm]
  $probe page add
  if {$order eq "declared-first"} {
    $probe pdfa -part 3 -conformance B -profile $intent
  }
  if {[catch {
    $probe image embed smooth $grey -interpolate 1
    $probe image place smooth -at {20 20} -width 30
    if {$order eq "placed-first"} {
      $probe pdfa -part 3 -conformance B -profile $intent
    }
  } message options]} {
    lappend refused "$order: [lindex [dict get $options -errorcode] 2]"
  } else {
    lappend refused "$order: accepted, which this example did not expect"
  }
  $probe destroy
}

$doc image embed portrait $grey -mask fade
$doc style -fill {gray 0.15}
$doc font -family body -size 8 -color {gray 0.35}
$doc text "What this document may not carry: -interpolate 1. ISO 19005-2,\
    6.2.8 says the Interpolate key shall not be present or shall be false,\
    and both orders are refused - [join $refused {; }]. Smoothing is the\
    reader's decision, and an archive format takes it away so that the same\
    file looks the same in twenty years." -at {20 108} -width 170

$doc image place stamp -at {20 62} -size {40 40} -artifact 1
$doc image place portrait -at {70 62} -size {53 40} -artifact 1

exampleDone $doc $archival body {gray 0.45}
