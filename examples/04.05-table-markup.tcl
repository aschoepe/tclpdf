#!/usr/bin/env tclsh
#
# tclpdf example 4.5 - runs and markup in table cells
#
#   tclsh examples/04.05-table-markup.tcl ?output.pdf?
#
# A table cell used to hold ONE face: a bold word inside a cell meant a
# column of its own, or a cell drawn by hand from a willDrawCell hook - a
# copy of the package's own cell drawing outside the package, wrong the day
# the padding or the tagging changed. Since 1.6 a cell carries what a
# paragraph carries (example 1.17): its text in a notation, or the list of
# {text options} pairs of [text -runs 1].
#
# TWO KEYS. "runs" is a content key beside "text": the pairs, as a program
# writes them from data. "markup" is a STYLE key, like hyphenate: it names
# the notation the TEXT of a cell is written in - tags or markdown - and
# like every style key it is said once for a column, a section or the whole
# table, and a cell may say otherwise. The string stays under text. So the
# activity column below is Markdown by its column description, one cell of
# it is tags because it needs an underline, which Markdown cannot say, and
# one cell opts out with "markup plain" and shows its asterisks.
#
# WHAT IS MEASURED. A bold word is wider than the same word regular, and the
# row is as tall as the lines the cell breaks into with its faces; the
# automatic column width measures the runs the same way. The first baseline
# of a cell of runs is the baseline of the plain cell beside it - the row
# on the page proves it by eye, tests/table.test by the Td.
#
# WHAT IS REFUSED, by name and before a cell is drawn: text and runs in one
# cell, a list of an odd length, "markup {markdown ...}" as a pair (markup
# names the notation, not the content), a body cell in a decimal column - a
# line of pieces has no one separator to hang on; a head or foot cell of
# runs over such a column is set flush right like a plain heading -, a
# right-to-left cell, and a heading or
# a list item inside a cell, which are paragraphs of their own size and
# indent. A notation left open is refused as [text -markup] refuses it;
# nothing falls back to plain text in silence. The caller who wants that
# fallback writes it, in the didParseCell hook at the foot of this file.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "04.05-table-markup.pdf"}]

# An activity report: the client in bold, an old estimate struck through, a
# link to the ticket. The column says the notation once.
set rows {
    {"2026-09-01" "**Mueller GmbH** - kick-off, requirements taken down and confirmed in writing" 3.5}
    {"2026-09-02" "**Schmidt AG** - migration of the invoice templates; the estimate of ~~4 h~~ *2 h* held" 2}
    {"2026-09-03" "**Mueller GmbH** - review, see [ticket 4711](https://fossil.sowaswie.de/tclpdf)" 1.5}
}

# The same kind of row written by a PROGRAM: the name comes from a variable,
# and the cell is the list of pairs itself - no notation to escape, nothing
# that could be misread as Markdown. "runs" is the key that makes the cell a
# dictionary.
set client "Weber & Sohn"
lappend rows [list "2026-09-04" [list runs [list $client {style bold} \
    " - on-site training, " {} "invoiced separately" {style italic}]] 4]

# A cell that needs what Markdown cannot say - an underline - says "markup
# tags" for itself, and one that wants its asterisks kept says "markup
# plain" - not an empty value, which on a cell means "not said", as an
# empty align does.
lappend rows [list "2026-09-05" \
    {text "<b>Schmidt AG</b> - <u>final acceptance</u> signed" markup tags} 1]
lappend rows [list "2026-09-06" \
    {text "internal: note the **bold** markers are meant literally here" markup plain} 0.5]

set doc [tclpdf new -unit mm]
$doc info Title "Runs and markup in table cells"
$doc page add

$doc font -family helvetica -style bold -size 13
$doc text "Activity report - a Markdown column, a cell of runs, a cell of tags" -at {20 22}
$doc font -family helvetica -style {} -size 9.5
set y [$doc text "The activity column is Markdown by its column description; the\
    fourth row was written as the list of runs a program builds from data, the\
    fifth says \"markup tags\" for an underline, the sixth \"markup plain\" and\
    keeps its asterisks. The rows are as tall as their bold words make them,\
    and every first line stands on the baseline of the date beside it." \
    -at {20 30} -width 170]

set y [$doc table -at [list 20 [expr {$y + 6}]] -width 170 -theme striped \
    -head {{Date {text "**Activity**" markup markdown} Hours}} -body $rows \
    -foot {{{text Total colSpan 2 align right} 12.5}} \
    -columns {{width 24} {markup markdown} {width 18 align decimal}} \
    -style {family helvetica size 9}]

# What the refusals say. Each is raised before anything is drawn, so the
# page above is untouched by the five calls below.
$doc font -family helvetica -style bold -size 10
$doc text "What a cell of runs is refused for" -at [list 20 [expr {$y + 12}]]
set y [expr {$y + 18}]
foreach {label body columns} {
    "text and runs in one cell" {{{text a runs {b {}}}}} {}
    "markup written as a pair" {{{markup {markdown "a **b**"}}}} {}
    "runs in a decimal column" {{{runs {"1.50" {style bold}}}}} {{align decimal}}
    "a heading inside a cell" {{{text "# Title" markup markdown}}} {{markup markdown}}
    "a notation left open" {{{text "a **b" markup markdown}}} {}
} {
    catch {$doc table -at {20 300} -width 100 -theme plain -body $body \
        -columns $columns -style {family helvetica size 9}} message options
    $doc font -family helvetica -style bold -size 8.5 -color black
    $doc text "$label:" -at [list 20 $y]
    $doc font -family helvetica -style {} -size 8.5 -color {0.3 0.3 0.3}
    set y [$doc text "[dict get $options -errorcode] - $message" \
        -at [list 62 $y] -width 128]
    set y [expr {$y + 2}]
}

# THE FALLBACK, where a caller wants one: a report whose text comes from
# people may hold a lone asterisk, and the package refuses it rather than
# guess. The didParseCell hook runs before anything is measured; it tries
# the translation itself and, where that fails, sets the cell plain, as
# it stands - a decision written by the caller, in the caller's words.
package require tclpdf::markdown
proc plainWhereRefused {cell doc} {
    if {[dict get $cell section] eq "body" && [dict get $cell column] == 1
            && [catch {::tclpdf::markdown::parse [dict get $cell text]} why options]} {
        puts "  fallback: [dict get $cell text] -> set as text ([dict get $options -errorcode])"
        dict set cell markup plain
    }
    return $cell
}
$doc font -family helvetica -style bold -size 10
$doc text "A fallback the caller writes: didParseCell" -at [list 20 [expr {$y + 6}]]
set y [$doc table -at [list 20 [expr {$y + 11}]] -width 170 -theme plain \
    -body {{"2026-09-07" "a **closed** run sets" 1} {"2026-09-08" "an *open run is set as typed" 1}} \
    -columns {{width 24} {markup markdown} {width 18 align decimal}} \
    -style {family helvetica size 9} -didParseCell plainWhereRefused]

exampleFooter $doc
$doc write $target
$doc destroy

puts "  written: $target ([file size $target] bytes)"
puts "  [llength $rows] rows: three in Markdown, one as runs, one in tags, one as it stands"
