#!/usr/bin/env tclsh
#
# tclpdf example 2.16 - a CFF font program with no sfnt around it
#
#   tclsh examples/02.16-bare-cff.tcl ?output.pdf?
#
# An .otf keeps its outlines in a table called "CFF " inside an sfnt wrapper,
# and everything a PDF wants BESIDE the outlines is read out of the other
# tables around it: which character reaches which glyph from cmap, how wide a
# glyph is from hmtx, what the face is called from name, how big the em is
# from head, what the vendor permits from OS/2.
#
# A BARE CFF is that one table on its own. None of the others is there. It is
# what falls out of a font compiler, what sits inside another PDF as a
# /FontFile3, and what a font service hands back over the network - and every
# one of those answers is nevertheless in it, in structures of its own: the
# Name INDEX, the Top DICT, the charset, the Encoding, the Private DICT and
# the charstrings themselves.
#
# THE WIDTHS ARE THE WORK. There is no width table in a CFF. Each glyph's
# advance is an OPTIONAL extra operand in front of the first hint, move or
# endchar operator of its charstring, and whether it is there is decided by
# counting what stands before that operator. Read wrong, every glyph gets the
# font's stated default width - a plausible number, so the document looks
# right everywhere except in the length of its lines.
#
# NO BARE CFF IS SHIPPED WITH THIS PACKAGE, and this example does not need
# one: it cuts the table out of NimbusSans-Regular.otf and embeds the bytes,
# which is exactly what a bare CFF is. That also shows -data, the option for
# a face that never was a file.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf
package require tclpdf::sfnt

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "02.16-bare-cff.pdf"}]
set assets [file join $here assets]
set urw [file join $assets fonts urw-core35-fonts]
set profile [file join [file dirname $here] icc sRGB.icc]

# The cut. [sfnt table] hands back one table's bytes; those bytes are a font
# program in their own right, and nothing of the sfnt goes with them.
set otf [file join $urw NimbusSans-Regular.otf]
set parsed [::tclpdf::sfnt read $otf]
set bare [::tclpdf::sfnt table $parsed "CFF "]

set doc [tclpdf new -unit mm]
$doc info Title "A CFF font program with no sfnt around it"
$doc info Author "Alexander Schoepe"
$doc page add

# -data takes the bytes where a path would have stood. No temporary file, and
# nothing to remember to delete afterwards.
$doc font embed bare -data $bare
# The same face in its other two containers, for the comparison below.
$doc font embed whole $otf
$doc font embed program [file join $urw NimbusSans-Regular.t1]

$doc font -family bare -size 15
$doc text "A CFF font program with no sfnt around it" -at {20 22}

$doc font -family bare -size 9 -color {0.35 0.35 0.35}
$doc text "This heading is set in [file tail $otf] with its wrapper removed -\
    [string length $bare] bytes of CFF table, embedded with -data. The file on\
    disk is [file size $otf] bytes; what is left after the cut has no cmap, no\
    hmtx, no name, no head and no OS/2." -at {20 30} -width 170

# -- what the program says about itself --------------------------------------

set facts [::tclpdf::sfnt cffFont $bare]

set y 46
$doc font -family bare -size 11 -color black
$doc text "What is left, and where it is read from" -at [list 20 $y]
set y [expr {$y + 7}]

$doc font -family bare -size 8 -color {0.35 0.35 0.35}
$doc text "The left column is what the bare program answers; the right one is\
    the table of the .otf that used to answer the same question and is no\
    longer there." -at [list 20 $y] -width 170
set y [expr {$y + 10}]

$doc font -family bare -size 8 -color black
set y [$doc table -at [list 20 $y] -width 170 -theme grid \
    -style {family bare size 8} -headStyle {family bare size 8} \
    -head {{Question {The bare CFF answers} {Read from} {The sfnt read}}} \
    -body [list \
        [list "PostScript name" [dict get $facts name] "Name INDEX" name] \
        [list "Family" [dict get $facts family] "Top DICT FamilyName" name] \
        [list "Glyphs" [dict get $facts numGlyphs] "CharStrings INDEX" maxp] \
        [list "Units per em" [dict get $facts unitsPerEm] \
            "Top DICT FontMatrix" head] \
        [list "Italic angle" [dict get $facts italicAngle] \
            "Top DICT ItalicAngle" post] \
        [list "Stem width" [dict get $facts stemV] \
            "Private DICT StdVW" "estimated"] \
        [list "Glyph names" [dict size [dict get $facts charset]] charset post] \
        [list "Widths" [dict size [dict get $facts widths]] \
            "the charstrings" hmtx] \
        [list "Own encoding" [dict size [dict get $facts encoding]] \
            Encoding cmap] \
        [list "Embedding permission" "none stated" "-" OS/2]] \
    -columns {{align left} {align left} {align left} {align left}}]
set y [expr {$y + 5}]

$doc font -family bare -size 8 -color {0.45 0.45 0.45}
$doc text "The stem width is the one number the TrueType road cannot read and\
    has to estimate from the weight class; a CFF states it. The embedding\
    permission is the one this format has nowhere to put, so font info answers\
    it as not stated rather than as permission 0 - an absent permission is not\
    permission." -at [list 20 $y] -width 170
set y [expr {$y + 16}]

# -- the check that matters --------------------------------------------------

$doc font -family bare -size 11 -color black
$doc text "One face, three containers, one measurement" -at [list 20 $y]
set y [expr {$y + 7}]

$doc font -family bare -size 8 -color {0.35 0.35 0.35}
$doc text "Nimbus Sans Regular is here three times over: as an .otf, whose\
    widths come from hmtx by glyph number; as a .t1, whose widths come from\
    the AFM beside it by glyph name; and as the bare CFF, whose widths come\
    from nowhere but the charstrings. Three readers, one face - so the three\
    numbers have to agree, and a charstring read wrongly is the only thing\
    that could separate them." -at [list 20 $y] -width 170
set y [expr {$y + 18}]

$doc font -family bare -size 10 -color black
foreach sample {"Rechnung" "Hamburgefonstiv" "AVATAR 12,34 EUR"} {
  $doc text $sample -at [list 20 $y] -family bare
  set numbers {}
  foreach alias {bare whole program} {
    lappend numbers [format %.4f \
        [$doc textWidth $sample -family $alias -size 10 -kerning 0]]
  }
  $doc font -family bare -size 8 -color {0.45 0.45 0.45}
  $doc text "bare CFF [lindex $numbers 0] mm    .otf [lindex $numbers 1] mm   \
      .t1 [lindex $numbers 2] mm" -at [list 95 $y]
  $doc font -family bare -size 10 -color black
  set y [expr {$y + 7}]
}
set y [expr {$y + 3}]

# -- what it costs -----------------------------------------------------------

$doc font -family bare -size 11 -color black
$doc text "What the missing wrapper costs" -at [list 20 $y]
set y [expr {$y + 7}]

$doc font -family bare -size 8 -color {0.35 0.35 0.35}
$doc text "A bare CFF goes into the file as /FontFile3 with /Subtype /Type1C -\
    a Type 1-equivalent font program, which is addressed by single bytes\
    through WinAnsiEncoding, exactly as a .pfb is. That reaches\
    [dict get [$doc font info bare] characters] byte positions. The same\
    outlines inside the .otf are addressed by glyph number and reach\
    [dict get [$doc font info whole] characters] characters. The face has the\
    glyphs either way; what the bare file lost is the table that says which\
    character they belong to. Where the .otf exists, embed the .otf." \
    -at [list 20 $y] -width 170
set y [expr {$y + 20}]

$doc font -family bare -size 10 -color black
$doc text "Große Wäsche kostet 12 € - Café, Fußnote, Œuvre, Ångström" \
    -at [list 20 $y]
set y [expr {$y + 6}]
$doc font -family bare -size 8 -color {0.45 0.45 0.45}
$doc text "Set in the bare CFF, and half of it outside ASCII. Copy the line\
    because the /Encoding written beside the program says which glyph name\
    each byte stands for, which is the job the missing cmap used to do." \
    -at [list 20 $y] -width 170

# -- what a refusal says, and why the class matters --------------------------
#
# The readers behind "font embed" refuse in classes, and the class is the part
# a script can act on: SOURCE says "wrong format, try another reader", DAMAGED
# says "right format, broken file - stop", UNSUPPORTED says "sound file, this
# package does not read it", SUBSET says "sound face, it just cannot be cut
# down". Until 2026-08-24 all four arrived as no code at all, so a script had
# to read the message - which the manual says is not a contract.

set y [expr {$y + 22}]
$doc font -family bare -size 11 -color black
$doc text "What a refusal answers with" -at [list 20 $y]
set y [expr {$y + 7}]

$doc font -family bare -size 8 -color {0.35 0.35 0.35}

# The class of the refusal, or the word "accepted" where none came. Written
# out rather than trapped, because the point here is to SHOW the code.
proc refusalClass {script} {
  if {[catch {uplevel 1 $script} message options]} {
    return [lindex [dict get $options -errorcode] 2]
  }
  return "accepted"
}

set cff2 "\x02\x00\x05\x02\x00\x00\x00\x00"
foreach {what class} [list \
    "a text file offered as a font" \
        [refusalClass {$doc font embed no1 -data "not a font at all, really"}] \
    "a CFF2, the variable-font format" \
        [refusalClass {$doc font embed no2 -data $cff2}] \
    "a TrueType collection" \
        [refusalClass {$doc font embed no3 -data \
            "ttcf\x00\x01\x00\x00\x00\x00\x00\x02[string repeat \x00 60]"}]] {
  $doc text "$what  ->  $class" -at [list 20 $y] -width 170
  set y [expr {$y + 5}]
}

$doc font -family bare -size 8 -color {0.45 0.45 0.45}
$doc text "A script that tries a file through several readers retries on\
    SOURCE and gives up on DAMAGED. That is the whole reason the two do not\
    share a code." -at [list 20 $y] -width 170
set y [expr {$y + 10}]

# -- the declaration ---------------------------------------------------------

$doc pdfa -part 3 -conformance U -profile $profile

exampleDone $doc $target bare
