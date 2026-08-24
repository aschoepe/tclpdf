#!/usr/bin/env tclsh
#
# tclpdf example 4.4 - hyphenating a table cell
#
#   tclsh examples/04.04-table-hyphenation.tcl ?output.pdf?
#
# One page, one question: what does a narrow column of German prose cost when
# its words cannot be broken.
#
# A table is the only place in the package that wraps text the caller never
# opened a text block for - every other paragraph is a [$doc text -width]
# call, which takes -hyphenate itself. So the table takes it as a STYLE key,
# `hyphenate`, and a style key can be said wherever a style can: for the whole
# table with -style, for a section, for one column in -columns, or for a
# single cell. That is what makes a German description column beside an
# English note possible, and it is the reason this is not a -hyphenate option
# beside -theme.
#
# THE PAGE SHOWS THE SAME TABLE TWICE, once without the key and once with it,
# and prints underneath what the two came out as - read back from
# [$doc table layout] rather than written here, so the page cannot claim a
# number the document does not have. The second measurement is the one a
# layout actually turns on: how narrow the description column may be before
# the rows need a fourth line. It is searched for, half a millimetre at a
# time, under both settings.
#
# NO PATTERNS ARE SHIPPED with tclpdf, which is a licence decision - every
# published pattern set carries terms of its own and the package is MIT. On a
# machine without hyph_de_DE.dic this script sets both tables unhyphenated,
# says so on the page and on the console, and still writes its file. See the
# README in examples/assets/languages for where the file comes from.
#
# hyph_de_DE.dic states COMPOUNDLEFTHYPHENMIN and COMPOUNDRIGHTHYPHENMIN but
# neither LEFTHYPHENMIN nor RIGHTHYPHENMIN, so German is loaded with -left 2
# -right 2 here. Without them the module falls back to the plain TeX 2 and 3,
# and a right minimum of 3 refuses the two letter endings German breaks off
# every day - "-ung" would break, "-en" would not.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "04.04-table-hyphenation.pdf"}]
set patterns [file join $here assets languages hyph_de_DE.dic]

# Whether this run can hyphenate at all, decided once and before a cell is
# measured: a table that refuses halfway leaves nothing on the page, and the
# page has to say which of the two settings it is showing.
#
# Answers {tag why}: the language tag to put in the style, or {} and one
# sentence saying why not.
proc germanPatterns {path} {
    if {[catch {package require tclpdf::hyphenate}]} {
        return [list {} "this build has no tclpdf::hyphenate module"]
    }
    if {![file exists $path]} {
        return [list {} "no [file tail $path] under examples/assets/languages\
            - see the README there"]
    }
    if {[catch {::tclpdf::hyphenate load de-DE $path -left 2 -right 2} message]} {
        return [list {} [lindex [split $message \n] 0]]
    }
    return [list de-DE {}]
}

lassign [germanPatterns $patterns] language why

# Three sentences of the kind a position list is full of: each carries one
# compound long enough to leave a hole when it will not break, and short
# enough that the column is still wider than the word itself - so what is
# being shown is the WRAPPING and not the character fallback, which is what
# catches a word wider than its whole cell.
set rows {
    {"Die Betriebskostenabrechnung wird nach der Wohnflaeche umgelegt." "12"}
    {"Der Grundstuecksverkehr braucht die Genehmigung der Gemeinde." "3"}
    {"Die Wirtschaftspruefungsgesellschaft bestaetigt den Abschluss." "7"}
}
set columnWidth 40

# The two tables differ in ONE word, and the whole option list is built here
# so that the page cannot show one setting and describe the other: the same
# list goes to [table layout] for the numbers and to [table] for the drawing.
proc tableOptions {language {width 40}} {
    set description [list width $width]
    if {$language ne {}} {
        lappend description hyphenate $language
    }
    return [list -width [expr {$width + 15}] -theme plain -style {size 9} \
        -columns [list $description {width 15 align right}]]
}

set doc [tclpdf new -unit mm]
$doc page add
$doc language de-DE

$doc font -family helvetica -style bold -size 13 -color {0 0 0}
$doc text "Hyphenating a table cell" -at {20 25}

$doc font -family helvetica -style {} -size 9.5
set y [$doc text "The same three rows in the same 40 mm column. On the left\
    the description column as it has always been set; on the right the one\
    word {hyphenate de-DE} in its column description. Everything else about\
    the two calls is identical." -at {20 33} -width 170]

# What each setting comes out as, MEASURED rather than drawn and counted.
# [table layout] answers exactly what [table] would put on the page - the
# column widths, every cell with its broken lines, and the height - which is
# the whole reason a caller can ask before deciding.
set measured {}
foreach setting [list {} $language] {
    lappend measured [$doc table layout -body $rows \
        {*}[tableOptions $setting $columnWidth]]
}
lassign $measured plainLayout brokenLayout

set y [expr {$y + 4}]
foreach setting [list {} $language] label {"without" "with"} left {20 110} {
    $doc font -family helvetica -style bold -size 9
    $doc text "$label hyphenation" -at [list $left $y]
    $doc table -at [list $left [expr {$y + 5}]] -body $rows \
        {*}[tableOptions $setting $columnWidth]
}

# The line under the tables. Both numbers come out of the layouts above.
set below [expr {$y + 8 + [dict get $plainLayout height]}]
$doc font -family helvetica -style {} -size 9 -color {0 0 0}

# How many lines the first cell of each table needed, and how tall the whole
# table came out. A cell's "lines" is the text as it was broken - which is
# also, cell for cell, what the drawing puts on the page.
proc firstCellLines {layout} {
    return [dict get [lindex [dict get $layout body] 0 0] lines]
}

set plainLines [llength [firstCellLines $plainLayout]]
set brokenLines [llength [firstCellLines $brokenLayout]]
set plainHeight [dict get $plainLayout height]
set brokenHeight [dict get $brokenLayout height]

# THE SECOND MEASUREMENT, and the one a layout turns on: not "how tall is the
# table" but "how narrow may the column be". Searched rather than asserted,
# half a millimetre at a time, and under both settings with the same loop.
proc narrowestFor {doc rows setting lines} {
    for {set width 25.0} {$width <= 80.0} {set width [expr {$width + 0.5}]} {
        set layout [$doc table layout -body $rows \
            {*}[tableOptions $setting $width]]
        set tallest 0
        foreach row [dict get $layout body] {
            set count [llength [dict get [lindex $row 0] lines]]
            if {$count > $tallest} {
                set tallest $count
            }
        }
        if {$tallest <= $lines} {
            return $width
        }
    }
    return {}
}

set plainNarrowest [narrowestFor $doc $rows {} 3]
set brokenNarrowest [expr {$language eq {} ? {} : [narrowestFor $doc $rows $language 3]}]

set report {}
lappend report "Left: the first row takes $plainLines lines, the table\
    [format %.2f $plainHeight] mm."
if {$language eq {}} {
    lappend report "Right: the same, because there are no patterns on this\
        machine - $why. Both tables above are the left one."
} else {
    lappend report "Right: $brokenLines lines and [format %.2f $brokenHeight]\
        mm, which is [format %.2f [expr {$plainHeight - $brokenHeight}]] mm\
        less for the same three rows. The compound is wider than what is left\
        of the line it meets, so without the patterns it can only be split\
        between two characters: the left cell's second line reads\
        \"[lindex [firstCellLines $plainLayout] 1]\", and the fragment that\
        opens the line after it is the rest of that word. The right cell\
        breaks the same word where the dictionary does, and its first line\
        ends \"[lindex [firstCellLines $brokenLayout] 0]\"."
    lappend report "Read the other way round - the number a layout actually\
        turns on: three lines per row need a description column of\
        [format %.1f $plainNarrowest] mm without the patterns and\
        [format %.1f $brokenNarrowest] mm with them,\
        [format %.1f [expr {$plainNarrowest - $brokenNarrowest}]] mm of table\
        width for one word in the column description."
}
lappend report "The patterns are not part of tclpdf and are loaded by the\
    caller with \[::tclpdf::hyphenate load de-DE <path> -left 2 -right 2\];\
    a language nobody loaded refuses the whole table by name rather than\
    setting it unhyphenated in silence."
lappend report "One thing a cell does not do that a \[text -width\] paragraph\
    does: its break hyphen is a plain U+002D and carries no empty ActualText\
    in a tagged document, so extracting a broken cell gives the word with the\
    hyphen in it. The table draws its cells line by line from what it\
    measured, which is what makes it impossible for the measuring and the\
    drawing to disagree about where the breaks fall."

foreach paragraph $report {
    set below [expr {[$doc text $paragraph -at [list 20 $below] -width 170] + 3}]
}

exampleFooter $doc
$doc write $target
$doc destroy

puts "  written: $target"
if {$language eq {}} {
    puts "  unhyphenated: $why"
} else {
    puts "  first row: $plainLines lines / [format %.2f $plainHeight] mm plain,\
        $brokenLines lines / [format %.2f $brokenHeight] mm hyphenated"
    puts "  three lines per row need [format %.1f $plainNarrowest] mm of\
        column plain, [format %.1f $brokenNarrowest] mm hyphenated"
}
