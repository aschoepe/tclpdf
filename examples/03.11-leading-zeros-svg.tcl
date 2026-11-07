#!/usr/bin/env tclsh
#
# tclpdf example 3.11 - the numbers of a drawing are decimal numbers
#
#   tclsh examples/03.11-leading-zeros-svg.tcl ?output.pdf?
#
# An SVG file is text, and nothing stops it from writing width="020" or
# "M010 010". SVG 1.1, 4.2 knows decimal numbers only, so that is twenty and
# ten - but Tcl 8.6 reads an integer with a leading zero as OCTAL, "010" as
# eight, and "08" as no number at all. Tcl 9 reads both in decimal. The
# package reads every number of a drawing in decimal under both, and the
# same goes for the numbers of a Type 1 font's metrics, of a CFF font, of a
# hyphenation pattern file, and for the components of a colour: {lab 050 0
# 0} is an L* of fifty.
#
# The example makes the same document twice: once from a drawing whose
# numbers carry leading zeros - coordinates, path data, transform, viewBox,
# stroke width, rgb(), a gradient offset, a font size - with a Lab colour
# written {lab 050 0 0} and a paragraph hyphenated by a pattern file that
# says LEFTHYPHENMIN 010; once from the same things without the zeros. Both
# are written uncompressed and compared byte for byte, the random file
# identifier aside, and the example refuses to write its own page if they
# differ. The page then shows the two drawings side by side.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf
package require tclpdf::hyphenate

source [file join $here common.tcl]

# Not through an [expr] ternary: that would read a file name made of digits
# as a number - the very trap this example is about.
set target 03.11-leading-zeros-svg.pdf
if {[llength $argv]} {
    set target [lindex $argv 0]
}

# The drawing with its numbers written with leading zeros. The version
# without them is made from it below by taking the zeros off, so the two
# cannot come to differ in anything else.
set leading {<svg width="0160" height="0100" viewBox="0 0 080 050"
    xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="sky" x1="0" y1="0" x2="0" y2="01">
      <stop offset="010%" stop-color="steelblue"/>
      <stop offset="090%" stop-color="white"/>
    </linearGradient>
  </defs>
  <rect x="00" y="00" width="080" height="050" fill="url(#sky)"/>
  <g transform="translate(010 08) rotate(-010 030 020)">
    <path d="M00 030 L015 010 L030 030 Z M020 030 l010 -015 l010 015 z"
        fill="rgb(060,090,070)" stroke="rgb(030,040,030)" stroke-width="00.8"/>
  </g>
  <polyline points="045,040 055,034 065,038 075,030" fill="none"
      stroke="rgb(0128,040,030)" stroke-width="02" stroke-dasharray="03 01"/>
  <circle cx="068" cy="012" r="06" fill="rgb(0250,0200,060)"/>
  <text x="03" y="047" font-size="04" fill="rgb(020,020,060)">ten is ten</text>
</svg>}

# Every run of zeros in front of a digit taken off - "010" to "10", "00.8"
# to "0.8", "00" to "0" - which is what the package does when it reads
# them. The drawing's own text carries no digit, so nothing but numbers is
# changed.
set plain [regsub -all {(^|[^0-9.])0+([0-9])} $leading {\1\2}]

# A pattern file of one pattern - a break may fall before every "na" - and
# the two minima it states, with and without the zeros. Written to a
# temporary directory, not beside the target, and removed again.
proc patternFile {path left right} {
    set channel [open $path w]
    puts $channel "ISO8859-1\nLEFTHYPHENMIN $left\nRIGHTHYPHENMIN $right\n1na"
    close $channel
    return $path
}
set work [exampleTempDirectory]
try {
    ::tclpdf::hyphenate load en-x-zeros [patternFile [file join $work zeros.dic] 010 02]
    ::tclpdf::hyphenate load en-x-plain [patternFile [file join $work plain.dic] 10 2]
} on error {message options} {
    file delete -force $work
    return -options $options $message
}

# One document of the comparison: the drawing, a Lab swatch and a paragraph
# hyphenated with the pattern file, uncompressed and dated, so that two of
# them made a second apart differ only in the file identifier.
proc comparisonBytes {path svg lab tag} {
    set doc [tclpdf new -unit mm -compress 0]
    $doc info CreationDate "D:20260101000000+01'00'"
    $doc page add
    $doc svg -data $svg -at {20 20} -width 80
    $doc rect -at {110 20} -size {30 20} -fill $lab
    $doc font -family helvetica -size 12
    $doc text "banananananana banananananana" -at {110 50} -width 22 \
        -hyphenate $tag
    $doc write $path
    $doc destroy
    set bytes [exampleReadBinary $path]
    file delete $path
    # /ID is random by design (ISO 32000-2, 14.4) - the one line that may
    # differ between two runs of the same script.
    regsub {/ID \[<[0-9A-Fa-f]+> <[0-9A-Fa-f]+>\]} $bytes {/ID []} bytes
    return $bytes
}
try {
    set first [comparisonBytes [file join $work zeros.pdf] $leading \
        {lab 050 0 0} en-x-zeros]
    set second [comparisonBytes [file join $work plain.pdf] $plain \
        {lab 50 0 0} en-x-plain]
} finally {
    file delete -force $work
}
if {$first ne $second} {
    error "the document made from numbers with leading zeros differs from\
        the one made without them - [string length $first] against\
        [string length $second] bytes"
}

# The page shown: the two drawings side by side, and what was compared.
set doc [tclpdf new -unit mm]
$doc info Title "Numbers with a leading zero in a drawing"
$doc page add
set y 22
$doc font -family helvetica -style bold -size 15
$doc text "The numbers of a drawing are decimal" -at [list 20 $y]
set y 32
examplePara $doc y "The drawing on the left writes width=\"0160\", viewBox=\"0 0\
    080 050\", \"M00 030 L015 010\", translate(010 08), rgb(0128,040,030),\
    offset=\"010%\" and font-size=\"04\"; the one on the right the same numbers\
    without the zeros. Under Tcl 8.6 the left one would otherwise be read in\
    octal - 010 as eight - and refused outright, since 08 and 090 are no\
    numbers to it."
$doc svg -data $leading -at [list 20 $y] -width 80
$doc svg -data $plain -at [list 110 $y] -width 80
$doc font -family helvetica -style {} -size 8 -color {0.35 0.35 0.35}
$doc text "with leading zeros" -at [list 20 [expr {$y + 55}]]
$doc text "without" -at [list 110 [expr {$y + 55}]]
set y [expr {$y + 64}]
$doc rect -at [list 20 $y] -size {30 12} -fill {lab 050 0 0}
$doc rect -at [list 52 $y] -size {30 12} -fill {lab 50 0 0}
$doc font -family helvetica -style {} -size 8 -color {0.35 0.35 0.35}
$doc text "{lab 050 0 0} and {lab 50 0 0}" -at [list 20 [expr {$y + 16}]]
$doc font -family helvetica -style {} -size 10 -color {0 0 0}
$doc text "LEFTHYPHENMIN 010: [join [::tclpdf::hyphenate word en-x-zeros banananananana] -]" \
    -at [list 95 [expr {$y + 4}]]
$doc text "LEFTHYPHENMIN 10: [join [::tclpdf::hyphenate word en-x-plain banananananana] -]" \
    -at [list 95 [expr {$y + 10}]]
set y [expr {$y + 26}]
exampleHeading $doc y "What was compared"
examplePara $doc y "Two documents were made, each with the drawing, a Lab swatch\
    and a paragraph hyphenated by its own pattern file - one from the numbers\
    with leading zeros, one from the numbers without. Written uncompressed\
    with the same date, they are [string length $first] bytes each and\
    identical byte for byte under Tcl [info patchlevel], the random file\
    identifier aside. The same holds for the numbers of an AFM, of a Type 1\
    program and of a CFF font."
exampleFooter $doc

$doc write $target
puts "  written: $target"
puts "  the two comparison documents are identical under Tcl\
    [info patchlevel]: [string length $first] bytes each"
$doc destroy
