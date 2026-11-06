#!/usr/bin/env tclsh
#
# tclpdf example 6.4 - a foreign PDF that writes its numbers with leading zeros
#
#   tclsh examples/06.04-leading-zeros-import.tcl ?output.pdf?
#
# ISO 32000-2, 7.3.3 lets a writer pad a number with zeros - its EXAMPLE 1
# lists 00987 as an integer - and some do: a /Length of 0000001355 is the
# pattern of a real invoice, and a tool that reserves the space for a number
# before it knows it pads it. Tcl 8.6 reads such a number as OCTAL wherever
# it is computed with: /Count 010 is eight pages, a /MediaBox of 0612 is 394
# points wide, 0595 is no number at all. Tcl 9 reads all of them in decimal.
# This package reads them in decimal under both, in the one place where its
# reader turns a token into a number.
#
# The example writes such a file itself, by hand, next to its own output:
# ten pages in a page tree whose /Count is 010 and whose inner node counts
# 08, boxes written as 0595 0842, 0612 0792 and 0420 0595, and /Rotate 090
# and 0270. Then it asks [::tclpdf::pdf info] and [::tclpdf::pdf pages] what
# the file holds, takes three of its pages over with [pdf import], and
# refuses to write anything if a single number differs from what the file
# means. The page it writes shows the three imports and what was compared,
# under which interpreter.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf
package require tclpdf::importInfo

source [file join $here common.tcl]

# Not through an [expr] ternary: that would read a file name made of digits
# as a number - the very trap this example is about.
set target 06.04-leading-zeros-import.pdf
if {[llength $argv]} {
    set target [lindex $argv 0]
}
set foreign [file join [file dirname $target] 06.04-leading-zeros-foreign.pdf]

# -- the foreign file -------------------------------------------------------
#
# Written byte by byte rather than by this package, which never writes a
# leading zero itself: a classic cross-reference table, every number of the
# page tree and the boxes padded. Objects: 1 catalog, 2 the root of the page
# tree, 3 an inner node of eight pages, 4-13 the ten pages, 14 their font,
# 15-24 their content streams.

proc foreignPdf {path} {
    set bodies [dict create]
    dict set bodies 1 "<< /Type /Catalog /Pages 2 0 R >>"
    dict set bodies 2 "<< /Type /Pages /Count 010\
        /Kids \[3 0 R 12 0 R 13 0 R\] >>"
    # The inner node passes its box down to its eight pages (7.7.3.4).
    dict set bodies 3 "<< /Type /Pages /Parent 2 0 R /Count 08\
        /MediaBox \[0 0 0595 0842\]\
        /Kids \[4 0 R 5 0 R 6 0 R 7 0 R 8 0 R 9 0 R 10 0 R 11 0 R\] >>"
    for {set n 1} {$n <= 8} {incr n} {
        dict set bodies [expr {3 + $n}] "<< /Type /Page /Parent 3 0 R\
            /Contents [expr {14 + $n}] 0 R\
            /Resources << /Font << /F1 14 0 R >> >> >>"
    }
    dict set bodies 12 "<< /Type /Page /Parent 2 0 R\
        /MediaBox \[0 0 0612 0792\] /Rotate 090 /Contents 23 0 R\
        /Resources << /Font << /F1 14 0 R >> >> >>"
    dict set bodies 13 "<< /Type /Page /Parent 2 0 R\
        /MediaBox \[0 0 0420 0595\] /Rotate 0270 /Contents 24 0 R\
        /Resources << /Font << /F1 14 0 R >> >> >>"
    dict set bodies 14 "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    for {set n 1} {$n <= 10} {incr n} {
        set stream "0.37 0.02 0.23 rg 40 40 m 160 40 l 160 160 l 40 160 l f\
            BT /F1 72 Tf 60 220 Td (Page $n) Tj ET"
        # The /Length padded to ten digits, the way the invoice pads it.
        set length [format %010d [string length $stream]]
        dict set bodies [expr {14 + $n}] \
            "<< /Length $length >>\nstream\n$stream\nendstream"
    }
    set out "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n"
    set offsets {}
    dict for {number body} $bodies {
        lappend offsets [string length $out]
        append out "$number 0 obj\n$body\nendobj\n"
    }
    set xref [string length $out]
    append out "xref\n0 [expr {[dict size $bodies] + 1}]\n"
    append out [format "%010d %05d f \n" 0 65535]
    foreach offset $offsets {
        append out [format "%010d %05d n \n" $offset 0]
    }
    append out "trailer\n<< /Size [expr {[dict size $bodies] + 1}]\
        /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n"
    set channel [open $path wb]
    puts -nonewline $channel $out
    close $channel
}
foreignPdf $foreign

# -- what the reader makes of it ---------------------------------------------
#
# What the file MEANS, page by page: width, height, rotation. A rotated page
# answers its size as it is seen, so the quarter turns swap the two.

set expected {}
for {set n 1} {$n <= 8} {incr n} {
    lappend expected {595 842 0}
}
lappend expected {792 612 90} {595 420 270}

set count [dict get [::tclpdf::pdf info $foreign] pages]
if {$count ne "10"} {
    error "the foreign file has ten pages, and the reader counted \"$count\""
}
set read {}
foreach page [::tclpdf::pdf pages $foreign] {
    lappend read [list [dict get $page width] [dict get $page height] \
        [dict get $page rotate]]
}
if {$read ne $expected} {
    error "the pages of the foreign file read as \{$read\}, and they are\
        \{$expected\}"
}

# -- taking three of them over -----------------------------------------------

set doc [tclpdf new -unit pt]
$doc info Title "tclpdf example: a foreign PDF with leading zeros"
$doc page add
set imports {}
foreach page {1 9 10} {
    $doc pdf import page$page $foreign -page $page
    set size [$doc form size page$page]
    set want [lrange [lindex $expected [expr {$page - 1}]] 0 1]
    # [form size] answers reals; compared as numbers, not as text.
    foreach got $size need $want {
        if {$got != $need} {
            error "page $page was imported as \{$size\}, and it is \{$want\}"
        }
    }
    lappend imports $page $size
}

# -- the page ------------------------------------------------------------------

$doc font -family helvetica -style bold -size 16
$doc text "A foreign PDF that writes its numbers with leading zeros" \
    -at {50 70}
$doc font -style {} -size 10
$doc text "[file tail $foreign] was written byte by byte next to this file:\
    /Count 010 over an inner node of /Count 08, boxes of 0595 0842, 0612\
    0792 and 0420 0595, /Rotate 090 and 0270, and every /Length padded to\
    ten digits. Under Tcl 8.6 a reader that computes with those numbers\
    reads them as octal; this one read them as the file means them, under\
    Tcl [info patchlevel]:" -at {50 95} -width 495

$doc font -family courier -size 9
set y 165
$doc text "pdf info pages   $count" -at [list 50 $y]
incr y 14
set n 0
foreach line $read {
    incr n
    lassign $line width height rotate
    $doc text [format "page %2d          %4s x %-4s  /Rotate %s" $n $width \
        $height $rotate] -at [list 50 $y]
    incr y 12
}

# The three imports, a fifth of their size, side by side.
$doc font -family helvetica -size 9
set x 50
foreach {page size} $imports {
    lassign $size width height
    $doc text "page $page, imported: $width x $height pt" -at [list $x 340]
    $doc form place page$page -at [list $x 350] -scale 0.2
    $doc rect -at [list $x 350] -size [list [expr {$width * 0.2}] \
        [expr {$height * 0.2}]] -stroke {0.7 0.7 0.7} -width 0.5
    set x [expr {$x + $width * 0.2 + 40}]
}

exampleFooter $doc
$doc write $target
puts "  written: $target"
puts "  foreign file: $foreign"
puts "  ten pages, every box and rotation as the file means them, under\
    Tcl [info patchlevel]"
$doc destroy
