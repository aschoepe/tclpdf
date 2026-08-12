#!/usr/bin/env tclsh
#
# tclpdf example 2.1 - embedding a TrueType face
#
#   tclsh examples/02.01-embedding.tcl ?output.pdf?
#
# A conference badge and a short note on what embedding costs. The font file
# on disk is 757 KB; what lands in the PDF is a few kilobytes, because only
# the glyphs actually set are carried over.
#
# What happens under the hood:
#
#   the sfnt tables are parsed, the glyphs used are collected, composites are
#   resolved recursively (an a-umlaut references "a" and "dieresis", and a
#   subset holding only the composite renders as nothing at all), the tables
#   are rebuilt, and the result goes in as Type0/CIDFontType2 with Identity-H.
#
#   A CIDToGIDMap stream maps the glyph numbers in the content stream onto the
#   renumbered ones in the subset. /Identity would claim they are the same;
#   they stop being the same the moment anything is subsetted, and the
#   document then renders with the wrong glyphs while qpdf calls it clean.
#
#   A ToUnicode CMap keeps the text copyable and searchable.
#
# fsType is read and reported but not enforced: no validator and no reader
# enforces it, and a package that silently refuses a licensed face would be
# the more damaging mistake.
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "02.01-embedding.pdf"}]
set assets [file join $here assets]
set regular [file join $assets fonts DejaVuSans.ttf]
set bold [file join $assets fonts DejaVuSans-Bold.ttf]

set doc [tclpdf new -unit mm]
$doc info Title "Conference badge"
$doc page add

$doc font embed face $regular
$doc font embed faceBold $bold

# What the file says about itself, including what the vendor permits.
set info [$doc font info face]
puts "  [dict get $info family]: [dict get $info glyphs] glyphs,\
    [dict get $info characters] characters mapped"
puts "  fsType [dict get $info fsType]: [dict get $info permission]"

# -- the badge -------------------------------------------------------------

$doc rect -at {20 24} -size {90 55} -radius 3 -fill {0.96 0.97 0.99} \
    -stroke {0.35 0.45 0.6} -width 0.5
$doc rect -at {20 24} -size {90 12} -radius 3 -fill {0.20 0.30 0.45}

$doc font -family faceBold -size 9 -color white
$doc text "TYPOGRAPHY CONFERENCE" -at {65 31} -align center
$doc font -family faceBold -size 16 -color black
$doc text "Zofia Krzyzanowska" -at {65 48} -align center
$doc font -family face -size 9
$doc text "Instytut Badan Literackich" -at {65 56} -align center
$doc text "Warszawa" -at {65 62} -align center
$doc font -family faceBold -size 8 -color {0.35 0.45 0.6}
$doc text "SPEAKER" -at {65 72} -align center

# The same badge in a standard font, for comparison.
$doc rect -at {118 24} -size {72 55} -radius 3 -fill {0.98 0.98 0.98} \
    -stroke {0.7 0.7 0.7} -width 0.4
$doc font -family helvetica -style bold -size 12 -color black
$doc text "Zofia Krzyzanowska" -at {154 48} -align center
$doc font -style {} -size 8
$doc text "Helvetica, not embedded" -at {154 58} -align center
$doc font -size 7 -color {0.5 0.5 0.5}
$doc text "reads the same here, because this name" -at {154 66} -align center
$doc text "avoids every character WinAnsi lacks" -at {154 70} -align center

# -- what it costs ---------------------------------------------------------

$doc font -family faceBold -size 11 -color black
$doc text "What embedding costs" -at {20 92}

# The two rules mark the column this paragraph is justified to. They are here
# to be measured against: an embedded face is addressed through Identity-H,
# where the word spacing operator Tw has nothing to act on - it applies to the
# single-byte code 32, and there is no such byte in a two-byte encoding. The
# gaps are therefore opened with TJ, and the proof that they are is that every
# line but the last one ends exactly on the right rule.
$doc line -from {20 96} -to {20 128} -stroke {0.8 0.8 0.85} -width 0.2
$doc line -from {190 96} -to {190 128} -stroke {0.8 0.8 0.85} -width 0.2

$doc font -family face -size 9
set y [$doc text "The face on disk is [file size $regular] bytes. Only the\
    glyphs set on this page go into the document, so the file below is a\
    fraction of that. Subsetting is not an option to switch on - it is the\
    only way a document with two weights stays small enough to send, and\
    justified text like this one reaches the rule on the right because the\
    gaps are widened glyph by glyph rather than by an operator that a\
    two-byte encoding never sees." \
    -at {20 99} -width 170 -align justify -anchor top]

# What subsetting is worth, measured rather than claimed: the same page once
# more, with "-subset 0" - the documented escape hatch for a face that has to
# stay complete, because a form is filled in afterwards or a reader refuses
# subsets. The file is written to a scratch name, weighed and deleted again.
set whole [tclpdf new -unit mm]
$whole page add
$whole font embed face $regular -subset 0
$whole text "Zofia Krzyzanowska" -at {20 20} -family face -size 16
set wholePath [file join [file dirname $target] whole-face.tmp.pdf]
$whole write $wholePath
$whole destroy
set wholeSize [file size $wholePath]
file delete $wholePath

$doc table -at [list 20 [expr {$y + 6}]] -width 130 -theme grid \
    -style {family face} -headStyle {family faceBold} \
    -head {{Item Bytes}} \
    -body [list \
        [list "DejaVuSans.ttf on disk" [file size $regular]] \
        [list "DejaVuSans-Bold.ttf on disk" [file size $bold]] \
        [list "one name, whole face embedded" $wholeSize] \
        [list "this document, both faces embedded" "written below"]] \
    -columns {{} {align right}}

$doc font -family face -size 8
$doc text "Run pdffonts on the result: both faces are reported as embedded\
    and subsetted, with unicode mapping present." -at {20 165} -width 170

exampleFooter $doc

$doc write $target
set size [file size $target]
puts "  written: $target ($size bytes)"
puts "  the two source faces together: [expr {[file size $regular] +
    [file size $bold]}] bytes"
puts "  ratio: [format %.1f [expr {100.0 * $size / ([file size $regular] +
    [file size $bold])}]] %"
$doc destroy
