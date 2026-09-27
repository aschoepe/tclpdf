#!/usr/bin/env tclsh
#
# tclpdf example 2.3 - five families in one document
#
#   tclsh examples/02.03-font-families.tcl ?output.pdf?
#
# Example 2.1 embeds one face and shows how little of it travels. This one
# embeds five and shows what choosing between them costs, because the numbers
# are not where intuition puts them:
#
#   A face's SIZE ON DISK says nothing about what it costs in a document.
#   Bitcount is twice the file Roboto is, and what lands in the document is a
#   subset of the glyphs this page uses and nothing else. The table below
#   prints the file size and the glyph count off the face itself; the subset
#   is not weighed there, because it exists only once the document is written.
#   What the file size does decide is how long the parse takes.
#
#   A face's COVERAGE is what decides whether it can be used at all, and that
#   is a property no file name mentions. Niconne is a fine heading face and
#   cannot set Czech; Bitcount covers 396 characters, which is enough for
#   German and not for much beyond it.
#
#   A face's METRICS are a third thing again. Liberation Sans is drawn to the
#   advances of Arial, which are Helvetica's for all but five symbols: text set
#   in it takes the same room as the standard face - the free stand-in for a
#   layout measured on Helvetica (measured in tests/font.test, font-13.1).
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
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf
# The two modules behind [font embed], asked directly - the same call the
# writer makes when it embeds a face, so the number in the table below is the
# number the document carries and not an estimate. Example 2.16 reaches for
# [sfnt] the same way, to cut a CFF table out of an .otf.
package require tclpdf::sfnt
package require tclpdf::subset

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
    roboto  google/Roboto-Regular.ttf
            "text face, a fifth of the file size"
            "The quick brown fox jumps over the lazy dog."
    bitcount google/BitcountPropSingle-Regular.ttf
            "display face, drawn from dots"
            "SYSTEM READY 08:15 - 23.4 C"
    niconne google/Niconne-Regular.ttf
            "script face, headings only"
            "Menu of the day"
    liberation liberation-fonts/LiberationSans-Regular.ttf
            "text face, the metric twin of Helvetica and Arial"
            "The quick brown fox jumps over the lazy dog."
}

# How many bytes the subset of one line in one face comes to. The glyphs are
# looked up through the face's own cmap, which is what [text] does, and handed
# to the subsetter, which is what [write] does; what comes back is the font
# program the document would carry for that line. The .notdef and the
# components of a composite are added by the subsetter itself.
proc subsetSize {path text} {
    set parsed [::tclpdf::sfnt read $path]
    set glyphs {}
    foreach char [split $text {}] {
        set code [scan $char %c]
        if {[dict exists $parsed cmap $code]} {
            lappend glyphs [dict get $parsed cmap $code]
        }
    }
    return [string length [dict get [::tclpdf::subset build $parsed \
        [lsort -unique -integer $glyphs]] bytes]]
}

set doc [tclpdf new -unit mm]
$doc info Title "tclpdf example: five families in one document"
$doc page add

$doc font -family helvetica -style bold -size 15
$doc text "Five families, one document" -at {20 22}
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
$doc text "What the five cost here" -at [list 20 $y]
$doc font -style {} -size 8
$doc text "The subset carries the glyphs this page uses. The file on disk is\
    what had to be parsed to get there - the two are unrelated, and only the\
    subset ends up in the document. The subset column is the sample line above\
    each face, subsetted by the same call the writer makes." \
    -at [list 20 [expr {$y + 5}]] -width 170

set rows {}
foreach {alias file purpose sample} $families {
    lappend rows [list [dict get [$doc font info $alias] family] \
        [file size [file join $assets fonts $file]] \
        [subsetSize [file join $assets fonts $file] $sample] \
        [dict get [$doc font info $alias] glyphs]]
}
set y [$doc table -at [list 20 [expr {$y + 19}]] -width 170 -theme striped \
    -head {{Family "File on disk, bytes" "Subset of its line, bytes"
            "Glyphs in the face"}} \
    -body $rows \
    -columns {{} {width 36 align decimal} {width 40 align decimal}
              {width 32 align decimal}}]

# The captions on this page are the sixth family: the standard faces, which
# are not embedded and are addressed in one of two ways - by family and
# style, or by their PostScript name outright. "Times-Italic" IS
# "-family times -style italic"; both style words may be given together, and
# "oblique" is read as "italic", because Helvetica and Courier call their
# slanted cut that.
$doc font -family Times-Italic -size 8 -color {0.4 0.4 0.45}
set y [$doc text "The captions on this page are set in the standard faces,\
    which are named by family and style or - as this line, in Times-Italic -\
    by their PostScript name outright." -at [list 20 [expr {$y + 6}]] -width 170]
$doc font -family helvetica -style {bold italic} -size 8
$doc text "Helvetica with -style {bold italic}," -at [list 20 [expr {$y + 1}]]
$doc font -style oblique
$doc text "and with -style oblique, which is read as italic." \
    -at [list 72 [expr {$y + 1}]]

exampleFooter $doc body

$doc write $target
puts "  written: $target ([file size $target] bytes)"
foreach {alias file purpose sample} $families {
    set info [$doc font info $alias]
    puts [format "  %-9s %-22s %5d glyphs, %5d characters,\
        subset %5d bytes" \
        $alias [dict get $info family] [dict get $info glyphs] \
        [dict get $info characters] \
        [subsetSize [file join $assets fonts $file] $sample]]
}
$doc destroy
