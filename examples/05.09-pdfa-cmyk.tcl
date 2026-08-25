#!/usr/bin/env tclsh
#
# tclpdf example 5.9 - PDF/A with a CMYK output intent
#
#   tclsh examples/05.09-pdfa-cmyk.tcl ?output.pdf?
#
# Example 5.4 anchors its colours to sRGB, which is what a document that lives
# on screens wants. A print job is different: its colours are ink - cyan,
# magenta, yellow, black - and an archival copy of it should say which press
# condition those four numbers were meant for. That is what a CMYK output
# intent does, and this is the same recipe as 5.4 with the profile swapped.
#
# What changes, and what does not:
#
#   THE INTENT. [pdfa -profile icc/ISOcoated_v2_bas.ICC] names basICColor's
#   ISO Coated v2 (FOGRA39, coated paper) - the second profile the package
#   ships, under the zlib licence (icc/README.md). Its four components go
#   into the intent as /N 4, and the identifier is read from the profile's
#   own description tag.
#
#   THE COLOURS. Everything here is {cmyk c m y k}: fills, strokes, text.
#   ISO 19005-2 (6.2.4.3) lets a document use DeviceCMYK only when the intent
#   describes CMYK, DeviceRGB only under an RGB intent - so a red given as
#   {1 0 0} in this file would be a validation error, not a colour. Grey as
#   {cmyk 0 0 0 k} is fine; a bare 0.5 would be DeviceGray, which every
#   intent allows.
#
#   THE FORM. A form XObject placed with -opacity is a transparency group, and
#   the group names no colour space of its own: it composites in the page's,
#   which under this intent is CMYK. A group that declared DeviceRGB would be
#   the same error as the red above - measured with veraPDF, and the reason
#   the group is written without one.
#
#   THE REST is 5.4: every font embedded, XMP with the level, level U because
#   the text is searchable anyway.
#
# The second page is the sheet a printer gets: the A5 job imposed on A4 with
# trim and registration marks, a colour control strip and a grey wedge - all
# outside the trimmed page - and /TrimBox and /BleedBox set so that a reader
# shows the page and a RIP cuts by it (14.11.2). Its text is French, as the
# job's would be - the marks and the strip speak the language of the press
# that prints it (CMJN: cyan, magenta, jaune, noir).
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "05.09-pdfa-cmyk.pdf"}]
set assets [file join $here assets]
set regular [file join $assets fonts DejaVuSans.ttf]
set bold [file join $assets fonts DejaVuSans-Bold.ttf]
set profile [file join [file dirname $here] icc ISOcoated_v2_bas.ICC]

set doc [tclpdf new -unit mm]

$doc info Title "Print order 2026-0815 – Kartonagen Bochum"
$doc info Author "Alexander Schoepe"
$doc info Subject "Folding box, four-colour offset, coated board"
$doc info Keywords "print, CMYK, FOGRA39, archival"
$doc language en-GB

$doc page add
$doc font embed face $regular
$doc font embed faceBold $bold

# The process colours, as they will be printed. Rich black for the head bar,
# a plain K for the running text.
set ink(head) {cmyk 1 0.6 0 0.4}
set ink(text) {cmyk 0 0 0 1}
set ink(rule) {cmyk 0 0 0 0.5}

# -- the order sheet ------------------------------------------------------

$doc rect -at {20 20} -size {170 18} -fill $ink(head)
$doc font -family faceBold -size 14 -color {cmyk 0 0 0 0}
$doc text "Print order" -at {26 32}
$doc font -family face -size 9 -color {cmyk 0 0 0 0}
$doc text "No. 2026-0815" -at {184 32} -align right

$doc font -family face -size 10 -color $ink(text)
set y [$doc text "This order sheet is archived with the job. It is written as\
    PDF/A-3U with a CMYK output intent, so that the four numbers behind every\
    colour on this page keep meaning the same ink on the same coated board -\
    the profile is FOGRA39, ISO Coated v2 - and the sheet can be read and\
    searched for as long as the job has to be kept." \
    -at {20 48} -width 170 -align justify -anchor top]

# The colour bar a printer reads at the edge of a sheet: the four process
# colours solid and at fifty percent, each one named by its numbers.
set x 20
foreach {name value} {
    C {cmyk 1 0 0 0}  M {cmyk 0 1 0 0}  Y {cmyk 0 0 1 0}  K {cmyk 0 0 0 1}
} {
    lassign $value _ c m yy k
    $doc rect -at [list $x [expr {$y + 8}]] -size {20 12} -fill $value
    $doc rect -at [list [expr {$x + 20}] [expr {$y + 8}]] -size {20 12} \
        -fill [list cmyk [expr {$c / 2.0}] [expr {$m / 2.0}] \
            [expr {$yy / 2.0}] [expr {$k / 2.0}]]
    $doc font -family face -size 7 -color $ink(text)
    $doc text "$name  100 % / 50 %" -at [list $x [expr {$y + 24}]]
    incr x 42
}

$doc font -family face -size 10 -color $ink(text)
$doc table -at [list 20 [expr {$y + 32}]] -width 170 -theme grid \
    -style [list family face color $ink(text) lineColor $ink(rule)] \
    -headStyle {family faceBold} \
    -head {{Item Specification}} \
    -body {
        {"Product" "Folding box, 120 x 80 x 40 mm"}
        {"Board" "GC1, 300 g/m², coated one side"}
        {"Colours" "4/0, CMYK, ISO Coated v2 (FOGRA39)"}
        {"Quantity" "12 500"}
        {"Finishing" "Dispersion varnish, die-cut, glued"}
        {"Delivery" "Week 36, one address"}
    } \
    -columns {{width 60} {}}

# A stamp placed twice, once solid and once at half opacity: the form is a
# transparency group without a colour space of its own, so under this intent
# it composites in CMYK and the file stays valid.
$doc form create stamp -size {40 40} -script {
    $doc circle -at {20 20} -radius 18 -stroke {cmyk 0 1 1 0} -width 1.5
    $doc font -family faceBold -size 8 -color {cmyk 0 1 1 0}
    $doc text "APPROVED" -at {20 22} -align center
    $doc font -family face -size 6 -color {cmyk 0 1 1 0}
    $doc text "for press" -at {20 27} -align center
}
$doc form place stamp -at {130 175}
# Offset far enough that the two words stay readable. At {150 185} the two
# 40 mm stamps overlapped by half, the first circle's ring ran straight
# through the second word, and one read "A|PROVED". The point of the pair is
# the half opacity, and that shows just as well where only the rims meet.
$doc form place stamp -at {162 192} -opacity 0.5

$doc font -family faceBold -size 10 -color $ink(text)
$doc text "Released for print" -at {20 190}
$doc font -family face -size 9
$doc text "Prepress, Bochum" -at {20 197}
$doc line -from {20 208} -to {90 208} -stroke $ink(rule) -width 0.3

# -- page two: an A5 sheet imposed on A4, with the marks a printer expects --

# The job itself is A5. What goes to the press is a larger sheet carrying the
# A5 page plus what the press needs around it: the trim marks that say where
# the guillotine cuts, registration marks to align the four plates, and a
# colour control strip the operator reads with a densitometer. All of it lies
# OUTSIDE the trimmed page and is cut away - which is what the page boxes are
# for: /MediaBox is the A4 sheet, /TrimBox the A5 page, /BleedBox the page
# plus 3 mm of bleed, so that a colour meant to run off the edge is printed
# a little beyond the cut and no white sliver appears when the knife is off
# by half a millimetre (ISO 32000-1, 14.11.2). A reader that knows the boxes
# shows the A5 page; a RIP imposes by them.
$doc page add

set trimW 148.0
set trimH 210.0
set bleed 3.0
# The sheet is whatever the media box says - read off the page rather than
# repeated as 210 by 297, so the imposition follows a document that was
# configured for another sheet. A box is two corners, so the size is the
# difference.
lassign [$doc page box media] sheetX0 sheetY0 sheetX1 sheetY1
set x0 [expr {($sheetX1 - $sheetX0 - $trimW) / 2}]     ;# 31 mm - the A5 page sits centred
set y0 [expr {($sheetY1 - $sheetY0 - $trimH) / 2}]     ;# 43.5 mm
set x1 [expr {$x0 + $trimW}]
set y1 [expr {$y0 + $trimH}]

# The boxes: A4 sheet stays the media box; the trim box is the A5 page, the
# bleed box the page grown by the bleed. Both are checked to lie inside the
# media box, and both are PDF 1.3 features - a 1.7 file has them.
$doc page box trim [list $x0 $y0 $x1 $y1]
$doc page box bleed [list [expr {$x0 - $bleed}] [expr {$y0 - $bleed}] \
    [expr {$x1 + $bleed}] [expr {$y1 + $bleed}]]
# The art box is the page's meaningful content as its maker sees it - here
# the A5 page inside its 10 mm margins. A layout program that places this
# page into another document takes that, not the sheet (14.11.2 again).
$doc page box art [list [expr {$x0 + 10}] [expr {$y0 + 10}] \
    [expr {$x1 - 10}] [expr {$y1 - 10}]]

# Registration black - all four inks - is what marks are printed in, so that
# every plate carries them and a misregistered plate shows as a doubled mark.
set reg {cmyk 1 1 1 1}

# The page content, with a colour band running off the top edge into the
# bleed: it starts 3 mm above the trim and 3 mm left and right of it.
$doc rect -at [list [expr {$x0 - $bleed}] [expr {$y0 - $bleed}]] \
    -size [list [expr {$trimW + 2 * $bleed}] [expr {40 + $bleed}]] \
    -fill {cmyk 1 0.6 0 0.4}
$doc font -family faceBold -size 16 -color {cmyk 0 0 0 0}
$doc text "Cartonnages Lefèvre & Fils – Lyon" -at [list [expr {$x0 + 10}] [expr {$y0 + 24}]]
$doc font -family face -size 9 -color {cmyk 0 0 0 0}
$doc text "Boîtes pliantes – imprimées selon ISO Coated v2" \
    -at [list [expr {$x0 + 10}] [expr {$y0 + 32}]]
$doc font -family face -size 10 -color $ink(text)
$doc text "Voici la page A5 telle qu'elle sera rognée. Tout ce qui se trouve\
    au-delà des traits de coupe est massicoté : le fond perdu du bandeau\
    ci-dessus, les croix de repérage, la bande de contrôle. Le lecteur affiche\
    la page selon son /TrimBox ; la feuille est le /MediaBox." \
    -at [list [expr {$x0 + 10}] [expr {$y0 + 60}]] -width [expr {$trimW - 20}] \
    -align justify -anchor top
$doc rect -at [list [expr {$x0 + 10}] [expr {$y1 - 30}]] -size [list [expr {$trimW - 20}] 0.3] \
    -fill $ink(rule)
$doc font -family face -size 7 -color $ink(text)
$doc text "format fini [expr {int($trimW)}] × [expr {int($trimH)}] mm, fond perdu [expr {int($bleed)}] mm" \
    -at [list [expr {$x0 + 10}] [expr {$y1 - 24}]]

# Trim marks: at each corner two short lines, one horizontal, one vertical,
# in line with the trim edges but starting outside the bleed - a mark that
# reached the trim would be printed on the page. 5 mm long, hairline.
set gap [expr {$bleed + 1}]      ;# from the trim edge to the near end
set len 5.0
foreach {cx cy sx sy} [list $x0 $y0 -1 -1  $x1 $y0 1 -1  $x0 $y1 -1 1  $x1 $y1 1 1] {
    # horizontal mark, in line with the top/bottom trim edge
    $doc line -from [list [expr {$cx + $sx * $gap}] $cy] \
        -to [list [expr {$cx + $sx * ($gap + $len)}] $cy] -stroke $reg -width 0.25
    # vertical mark, in line with the left/right trim edge
    $doc line -from [list $cx [expr {$cy + $sy * $gap}]] \
        -to [list $cx [expr {$cy + $sy * ($gap + $len)}]] -stroke $reg -width 0.25
}

# Registration marks: a circle with a cross, centred on each side of the
# page, 8 mm outside the trim. The four plates have to put them on top of
# each other; where they do not, the mark shows the offset.
foreach {mx my} [list [expr {($x0 + $x1) / 2}] [expr {$y0 - 8}] \
                      [expr {($x0 + $x1) / 2}] [expr {$y1 + 8}] \
                      [expr {$x0 - 8}] [expr {($y0 + $y1) / 2}] \
                      [expr {$x1 + 8}] [expr {($y0 + $y1) / 2}]] {
    $doc circle -at [list $mx $my] -radius 2 -stroke $reg -width 0.25
    $doc line -from [list [expr {$mx - 3}] $my] -to [list [expr {$mx + 3}] $my] \
        -stroke $reg -width 0.25
    $doc line -from [list $mx [expr {$my - 3}]] -to [list $mx [expr {$my + 3}]] \
        -stroke $reg -width 0.25
}

# The colour control strip, below the page in the bottom margin: solids and
# tints of the four inks, the two- and three-colour overprints, and a grey
# balance patch - the patches an operator measures to hold the run to the
# proof. Each 6 x 5 mm, labelled underneath in the language of the press.
set patches {
    "C"    {cmyk 1 0 0 0}      "C 80"  {cmyk 0.8 0 0 0}   "C 40"  {cmyk 0.4 0 0 0}
    "M"    {cmyk 0 1 0 0}      "M 80"  {cmyk 0 0.8 0 0}   "M 40"  {cmyk 0 0.4 0 0}
    "J"    {cmyk 0 0 1 0}      "J 80"  {cmyk 0 0 0.8 0}   "J 40"  {cmyk 0 0 0.4 0}
    "N"    {cmyk 0 0 0 1}      "N 80"  {cmyk 0 0 0 0.8}   "N 40"  {cmyk 0 0 0 0.4}
    "C+M"  {cmyk 1 1 0 0}      "C+J"   {cmyk 1 0 1 0}     "M+J"   {cmyk 0 1 1 0}
    "C+M+J" {cmyk 1 1 1 0}     "gris"  {cmyk 0.5 0.4 0.4 0} "papier" {cmyk 0 0 0 0}
}
set px [expr {$x0 - $bleed - 1}]
set py [expr {$y1 + 14}]
$doc font -family face -size 4.5 -color $ink(text)
foreach {label value} $patches {
    $doc rect -at [list $px $py] -size {6 5} -fill $value -stroke $reg -width 0.1
    $doc text $label -at [list [expr {$px + 3}] [expr {$py + 8}]] -align center
    set px [expr {$px + 6.5}]
}
$doc font -family face -size 6 -color $ink(text)
$doc text "bande de contrôle – ISO Coated v2 (FOGRA39), fond perdu 3 mm, repères hors du fond perdu" \
    -at [list [expr {$x0 - $bleed - 1}] [expr {$py + 13}]]

# A grey wedge down the right margin: black in ten steps, the tone value
# increase is read off it.
set gy [expr {$y0 + 20}]
foreach k {0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0} {
    $doc rect -at [list [expr {$x1 + 14}] $gy] -size {6 6} -fill [list cmyk 0 0 0 $k] \
        -stroke $reg -width 0.1
    set gy [expr {$gy + 6.5}]
}
$doc font -family face -size 4.5 -color $ink(text)
$doc text "N 10–100" -at [list [expr {$x1 + 17}] [expr {$gy + 3}]] -align center

# -- the declaration ------------------------------------------------------

$doc pdfa -part 3 -conformance U -profile $profile

set state [$doc pdfa state]
puts "  PDF/A-[dict get $state part][dict get $state conformance],\
    intent from [file tail [dict get $state profile]]"

# The boxes each page carries, read back with an index - the order sheet has
# only its media box, the print sheet all four. [page box name {} index]
# reads on any page, whichever is current.
for {set i 0} {$i < [$doc page count]} {incr i} {
    set boxes {}
    foreach name {media bleed trim art} {
        if {[$doc page box $name {} $i] ne {}} {
            lappend boxes $name
        }
    }
    puts "  page $i boxes: [join $boxes {, }]"
}

# The footer too paints in ink: a DeviceRGB grey under a CMYK intent would be
# the one validation error on the page.
exampleDone $doc $target face $ink(rule)
