#!/usr/bin/env tclsh
#
# tclpdf example 2.3 - four families in one document
#
#   tclsh examples/02.03-font-families.tcl ?output.pdf?
#
# Example 2.1 embeds one face and shows how little of it travels. This one
# embeds four and shows what choosing between them costs, because the numbers
# are not where intuition puts them:
#
#   A face's SIZE ON DISK says nothing about what it costs in a document.
#   Bitcount is twice the file Roboto is, and its subset comes out smaller,
#   because a subset carries the glyphs a document uses and nothing else. What
#   the file size does decide is how long the parse takes.
#
#   A face's COVERAGE is what decides whether it can be used at all, and that
#   is a property no file name mentions. Niconne is a fine heading face and
#   cannot set Czech; Bitcount covers 396 characters, which is enough for
#   German and not for much beyond it.
#
# So the order to ask the questions in is: does the face have the characters,
# then does it look right, then what does it cost. This page asks all three,
# and prints the answers it measured rather than claiming them.
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "02.03-font-families.pdf"}]
set assets [file join $here assets]

# alias, file, what it is for, and a line that suits it
set families {
    body    DejaVuSans.ttf
            "text face, the widest coverage here"
            "The quick brown fox jumps over the lazy dog."
    roboto  Roboto-Regular.ttf
            "text face, a fifth of the file size"
            "The quick brown fox jumps over the lazy dog."
    bitcount BitcountPropSingle-Regular.ttf
            "display face, drawn from dots"
            "SYSTEM READY 08:15 - 23.4 C"
    niconne Niconne-Regular.ttf
            "script face, headings only"
            "Menu of the day"
}

set doc [tclpdf new -unit mm]
$doc info Title "tclpdf example: four families in one document"
$doc page add

$doc font -family helvetica -style bold -size 15
$doc text "Four families, one document" -at {20 22}
$doc font -style {} -size 9
$doc text "Each face below is embedded and subsetted separately. The figures\
    are read back out of the document, not written down here." \
    -at {20 29} -width 170

# Embed first, then ask each one what it is. A face that cannot be read fails
# here rather than three pages later.
foreach {alias file purpose sample} $families {
    $doc font embed $alias [file join $assets fonts $file]
}

set y 46
foreach {alias file purpose sample} $families {
    set info [$doc font info $alias]

    $doc font -family helvetica -style bold -size 9 -color {0.15 0.25 0.5}
    $doc text [dict get $info family] -at [list 20 $y]
    $doc font -style {} -size 7 -color {0.4 0.4 0.45}
    $doc text $purpose -at [list 20 [expr {$y + 4}]]
    $doc text "[dict get $info glyphs] glyphs, [dict get $info characters]\
        characters, [dict get $info unitsPerEm] units per em" \
        -at [list 20 [expr {$y + 8}]]

    # The sample, set in the face itself - the only part of this page that
    # shows what the face actually looks like.
    $doc font -family $alias -size 13 -color black
    $doc text $sample -at [list 20 [expr {$y + 16}]] -width 170

    $doc line -from [list 20 [expr {$y + 24}]] -to [list 190 [expr {$y + 24}]] \
        -stroke {0.85 0.85 0.88} -width 0.2
    set y [expr {$y + 32}]
}

# -- what each face costs in THIS document ---------------------------------

$doc font -family helvetica -style bold -size 10 -color black
$doc text "What the four cost here" -at [list 20 $y]
$doc font -style {} -size 8
$doc text "The subset carries the glyphs this page uses. The file on disk is\
    what had to be parsed to get there - the two are unrelated, and only the\
    first one ends up in the document." -at [list 20 [expr {$y + 5}]] -width 170

set rows {}
foreach {alias file purpose sample} $families {
    lappend rows [list [dict get [$doc font info $alias] family] \
        [file size [file join $assets fonts $file]] \
        [dict get [$doc font info $alias] glyphs]]
}
$doc table -at [list 20 [expr {$y + 16}]] -width 170 -theme striped \
    -head {{Family "File on disk, bytes" "Glyphs in the face"}} \
    -body $rows \
    -columns {{} {width 42 align decimal} {width 38 align decimal}}

exampleFooter $doc body

$doc write $target
puts "  written: $target ([file size $target] bytes)"
foreach {alias file purpose sample} $families {
    set info [$doc font info $alias]
    puts [format "  %-9s %-22s %5d glyphs, %5d characters" \
        $alias [dict get $info family] [dict get $info glyphs] \
        [dict get $info characters]]
}
$doc destroy
