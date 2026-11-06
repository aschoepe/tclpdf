#!/usr/bin/env tclsh
#
# tclpdf example 0.4 - a number with a leading zero is a decimal number
#
#   tclsh examples/00.04-leading-zeros.tcl ?output.pdf?
#
# Tcl 8.6 reads an integer with a leading zero as OCTAL: to [expr] "010" is
# eight, and "08" is no number at all. Tcl 9 reads both in decimal. A caller
# who writes -at {010 20} means ten, whatever the interpreter - nobody
# measures a page in octal - and that is how this package reads the
# coordinates, lengths, sizes, counts and indices it takes: 010 is ten, 08 is eight, 0012.5 is twelve and a half,
# under Tcl 8.6 as under Tcl 9. 0x1A stays hexadecimal, because that is what
# the prefix says.
#
# The example draws the same page twice: once with every number written with
# leading zeros, once without. Then it compares the two content streams and
# the two page sizes, and refuses to write a file if they differ - the
# measurement is the point, not the drawing. A third page says what was
# compared, under which interpreter.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf

source [file join $here common.tcl]

# Not through an [expr] ternary: that would read a file name such as 0012
# as a number and hand back 10 under Tcl 8.6 - the trap this example is
# about.
set target 00.04-leading-zeros.pdf
if {[llength $argv]} {
    set target [lindex $argv 0]
}

# The same drawing, with the numbers handed in as the caller wrote them. The
# values are TEXT here - the dictionary carries the spelling - so nothing in
# this script reads them before the package does.
proc samplePage {doc v} {
    $doc page add -format [list [dict get $v pageWidth] [dict get $v pageHeight]] \
        -rotate [dict get $v rotate]
    $doc font -family helvetica -style bold -size [dict get $v size] -color {0 0 0}
    $doc text "One page, drawn twice" -at [list [dict get $v left] [dict get $v top]]
    $doc font -family helvetica -style {} -size [dict get $v small]
    $doc text "Every measurement on this page was handed to the package once\
        with leading zeros and once without. The two content streams are compared\
        before the file is written." \
        -at [list [dict get $v left] [dict get $v line]] \
        -width [dict get $v width] -indent [dict get $v indent]
    $doc rect -at [list [dict get $v left] [dict get $v box]] \
        -size [list [dict get $v width] [dict get $v boxHeight]] \
        -fill {0.92 0.93 0.97} -stroke {0.3 0.3 0.45} -width [dict get $v stroke]
    $doc line -from [list [dict get $v left] [dict get $v rule]] \
        -to [list [dict get $v right] [dict get $v rule]] \
        -stroke {0.3 0.3 0.45} -width [dict get $v stroke] -dash [dict get $v dash]
    $doc circle -at [list [dict get $v right] [dict get $v box]] \
        -radius [dict get $v radius] -fill {0.85 0.2 0.2}
    $doc polygon -points [dict get $v points] -fill {0.2 0.5 0.3}
}

set leading {
    pageWidth 0210 pageHeight 0297 rotate 000 size 016 small 010
    left 020 top 030 line 040 width 0170 indent 0012.5
    box 070 boxHeight 08 stroke 00.4 rule 090 right 0190 dash {02 01}
    radius 08 points {020 0120 040 0100 060 0120}
}
set plain {
    pageWidth 210 pageHeight 297 rotate 0 size 16 small 10
    left 20 top 30 line 40 width 170 indent 12.5
    box 70 boxHeight 8 stroke 0.4 rule 90 right 190 dash {2 1}
    radius 8 points {20 120 40 100 60 120}
}

set doc [tclpdf new -unit mm]
$doc info Title "Numbers with a leading zero"
samplePage $doc $leading
samplePage $doc $plain

# The measurement. A page content stream is what a reader draws, and the size
# is what it draws on; both have to be the same bytes.
set first [$doc page content 0]
set second [$doc page content 1]
if {$first ne $second} {
    error "the page drawn with leading zeros differs from the page drawn\
        without - [string length $first] against [string length $second] bytes\
        of content"
}
if {[$doc page size 0] ne [$doc page size 1]} {
    error "the two pages differ in size: [$doc page size 0] against\
        [$doc page size 1]"
}

$doc page add
set y 30
exampleHeading $doc y "What was compared"
examplePara $doc y "Pages 1 and 2 were drawn by the same procedure. Page 1 was\
    handed 0210 by 0297 for the format, 000 for the rotation, 016 and 010 for\
    the type sizes, 020, 030 and 0190 for positions, 0012.5 for an indent,\
    00.4 for a line width, {02 01} for a dash and 08 for a radius; page 2 the\
    same numbers without the zeros."
examplePara $doc y "Their content streams are [string length $first] bytes each\
    and identical, byte for byte, under Tcl [info patchlevel]. Under Tcl 8.6 a\
    leading zero would otherwise make 010 the octal number eight and refuse 08\
    altogether; the package reads the coordinates, lengths, sizes, angles,\
    scale factors, opacities, counts and indices a caller hands to a command in\
    decimal, and 0x1A stays hexadecimal."
exampleFooter $doc

$doc write $target
puts "  written: $target"
puts "  pages 1 and 2 identical under Tcl [info patchlevel]:\
    [string length $first] bytes of content each"
$doc destroy
