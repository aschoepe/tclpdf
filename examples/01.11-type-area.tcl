#!/usr/bin/env tclsh
#
# tclpdf example 1.11 - the type area, and text that reaches the end of a page
#
#   tclsh examples/01.11-type-area.tcl ?output.pdf?
#
# What happens when flowing text reaches the bottom of the page? Three
# answers, each one on top of the last:
#
#   THE TYPE AREA. [tclpdf new -typeArea {top bottom ?left right?}] gives the
#   document the margins its text and tables keep - one rule for everything
#   that breaks over pages, and one question with one answer: [page typeArea]
#   says where the area is on the page that is current, as {x0 y0 x1 y1}. A
#   breaking table takes its -top and -bottom from it without being told.
#
#   -HEIGHT MAX. [text ... -height max] sets what fits down to the bottom of
#   the area and hands back the rest, exactly as a numeric -height does: y is
#   the last visible line, rest the text for the next page. Nothing is drawn
#   under the area, and the caller keeps the loop.
#
#   -PAGINATE. [text ... -paginate 1] runs the loop itself: what fits goes on
#   this page, a page is added, the text goes on from the top of the area, as
#   often as it takes. pageAdded fires on every page it adds - the running
#   head below hangs on that event and lands on every continuation page - and
#   the answer says where the text ended: {y rest page column}, with rest
#   always empty. In a tagged document the whole run stays ONE paragraph,
#   with a mark on every page it touches.
#
#   -COLUMNS. [text ... -paginate 1 -columns 3 -gutter 6] sets the block in
#   three columns inside -width, each filled to the bottom of the area before
#   the next begins, and the page added only after the last. -balance 1 cuts
#   the columns of the page the text ends on to one height instead of leaving
#   the last one short.
#
#   A PICTURE IN THE COLUMNS. -avoid works as it always did: the picture is
#   placed, its rectangle goes into -avoid, and every column of that page
#   flows round it - the shapes are positions on the page, so a picture that
#   sits between two columns is avoided by both. Only on the first page of a
#   paginated run, and not together with -balance.
#
# Without -height a paragraph does not know about the page and runs on below
# it - as it always did; the returned y says so, and nothing else does.
#
# The dummy text is not Lorem ipsum but "Li Europan lingues" - Occidental, the
# planned language of 1922, in the passage that has been going round as filler
# text since; it has real sentences, capitals, a colon and a full stop, which
# shows a line breaker more than Latin word salad does. "plu sommun paroles"
# is the typo the passage has always carried.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "01.11-type-area.pdf"}]

set europan "Li Europan lingues es membres del sam familie. Lor separat\
    existentie es un myth. Por scientie, musica, sport etc, litot Europa usa li\
    sam vocabular. Li lingues differe solmen in li grammatica, li pronunciation\
    e li plu commun vocabules. Omnicos directe al desirabilite de un nov lingua\
    franca: On refusa continuar payar custosi traductores. At solmen va esser\
    necessi far uniform grammatica, pronunciation e plu sommun paroles. Ma\
    quande lingues coalesce, li grammatica del resultant lingue es plu simplic e\
    regulari quam ti del coalescent lingues. Li nov lingua franca va esser plu\
    simplic e regulari quam li existent Europan lingues. It va esser tam simplic\
    quam Occidental in fact, it va esser Occidental. A un Angleso it va semblar\
    un simplificat Angles, quam un skeptic Cambridge amico dit me que Occidental\
    es."

# -- the document and its type area -----------------------------------------

# 25 mm top and bottom, 20 mm at the sides. Everything that follows keeps
# inside these margins without being told again.
set doc [tclpdf new -unit mm -typeArea {25 25 20 20}]
$doc info Title "The type area"

# A running head on every page. Hung on pageAdded, it is drawn on the pages
# that -paginate adds as well as on the ones added by hand - the handler
# does not know which is which, and does not need to. The first page is
# added below, after the handler is in place, so it gets one too.
$doc on pageAdded [list apply {{doc index} {
    lassign [$doc page typeArea] x0 y0 x1 y1
    $doc font -family helvetica -size 8 -color {0.45 0.45 0.5}
    $doc text "The type area - page [expr {$index + 1}]" \
        -at [list $x0 [expr {$y0 - 6}]]
    $doc text "Li Europan lingues" -at [list $x1 [expr {$y0 - 6}]] -align right
    $doc line -from [list $x0 [expr {$y0 - 3}]] -to [list $x1 [expr {$y0 - 3}]] \
        -stroke {0.7 0.7 0.75} -width 0.2
    $doc font -family helvetica -size 10 -color black
}}]

$doc page add
lassign [$doc page typeArea] x0 y0 x1 y1
set width [expr {$x1 - $x0}]
puts "  type area on A4: [lmap v [$doc page typeArea] {format %.0f $v}] mm"

# -- 1. -height max: the caller keeps the loop --------------------------------

$doc font -family helvetica -style bold -size 14
$doc text "1. -height max" -at [list $x0 [expr {$y0 + 4}]]
$doc font -style {} -size 10
set y [$doc text "The paragraph below is set with -height max: it stops at\
    the bottom of the type area and hands back what did not fit. The caller\
    adds the page and sets the rest - the same loop 01.08 runs for columns,\
    with the limit read off the page instead of typed in." \
    -at [list $x0 [expr {$y0 + 12}]] -width $width -anchor top]

set body [join [lrepeat 9 $europan] "\n"]
set result [$doc text $body -at [list $x0 [expr {$y + 4}]] -width $width \
    -anchor top -align justify -firstIndent 6 -height max]
puts "  page 1: -height max stopped at y = [format %.1f [dict get $result y]] mm\
    (area ends at [format %.0f $y1]), [string length [dict get $result rest]]\
    characters left"

# The rest, on a fresh page, from the top of the area. Its first line is the
# middle of a sentence and would take -firstIndent as if it opened a
# paragraph - the loop below (-paginate) knows that; this one is written out
# in full to show what -paginate does on its own.
$doc page add
lassign [$doc page typeArea] x0 y0 x1 y1
set y [$doc text [dict get $result rest] -at [list $x0 $y0] -width $width \
    -anchor top -align justify -firstIndent 6 -height max]
set y [dict get $y y]

# -- 2. -paginate: the package keeps the loop --------------------------------

$doc font -style bold -size 14
$doc text "2. -paginate 1" -at [list $x0 [expr {$y + 10}]]
$doc font -style {} -size 10
set y [$doc text "From here on the paragraph paginates itself: it adds the\
    pages it needs, starts again at the top of the area on each, keeps the\
    first-line indent for paragraphs rather than pages, and the running head\
    above arrives through pageAdded. The answer names the page it ended on." \
    -at [list $x0 [expr {$y + 18}]] -width $width -anchor top]

set body [join [lrepeat 8 $europan] "\n"]
set result [$doc text $body -at [list $x0 [expr {$y + 4}]] -width $width \
    -anchor top -align justify -firstIndent 6 -paginate 1]
puts "  -paginate: ended on page [expr {[dict get $result page] + 1}] at y =\
    [format %.1f [dict get $result y]] mm, [$doc page count] pages so far"

# -- 3. a table under the same margins ---------------------------------------

# No -top, no -bottom: the table breaks where the area ends and resumes where
# it begins, because that is what the area is for.
lassign [$doc page typeArea] x0 y0 x1 y1
set y [dict get $result y]
$doc font -style bold -size 14
$doc text "3. A table with no -top and no -bottom of its own" \
    -at [list $x0 [expr {$y + 10}]]
$doc font -style {} -size 10
set words [split $europan " "]
set rows {}
for {set i 0} {$i < 40} {incr i} {
    lappend rows [list [expr {$i + 1}] [lindex $words [expr {$i % [llength $words]}]] \
        [format %.2f [expr {($i * 37) % 200 / 10.0}]]]
}
set y [$doc table -at [list $x0 [expr {$y + 16}]] -width $width -theme striped \
    -head {{No. Word Amount}} -body $rows \
    -columns {{width 16 align right} {} {width 30 align decimal}}]
puts "  table: [$doc page count] pages in all, ended at y = [format %.1f $y] mm"

# -- 4. columns, balanced ------------------------------------------------------

# Three columns, filled left to right; the page is added when the third is
# full. -balance evens the page the text ends on - the first page of the
# run is full and stays full, the second is cut so that its three columns
# end together instead of two full ones and a stub.
$doc page add
lassign [$doc page typeArea] x0 y0 x1 y1
$doc font -style bold -size 14
$doc text "4. Three columns, balanced" -at [list $x0 [expr {$y0 + 4}]]
$doc font -style {} -size 9
set body [join [lrepeat 9 $europan] "\n"]
set result [$doc text $body -at [list $x0 [expr {$y0 + 12}]] -width $width \
    -anchor top -align justify -firstIndent 5 -paginate 1 \
    -columns 3 -gutter 6 -balance 1]
puts "  columns: ended in column [expr {[dict get $result column] + 1}] of 3 at y =\
    [format %.1f [dict get $result y]] mm, [$doc page count] pages in all"

# -- 5. a picture between the columns ---------------------------------------

# Placed first, then named to the text: [image size] answers the size the
# placement will have, and the rectangle - with 3 mm of air around it - is
# what the columns keep clear. Both columns pass it, because the shape is a
# place on the page, not a property of a column.
$doc page add
lassign [$doc page typeArea] x0 y0 x1 y1
$doc font -style bold -size 14
$doc text "5. Two columns round a picture" -at [list $x0 [expr {$y0 + 4}]]
$doc font -style {} -size 9
$doc image embed photo [file join $here assets images sample-photo.jpg]
lassign [$doc image size photo -width 64] pw ph
set px [expr {$x0 + ($width - $pw) / 2.0}]
set py [expr {$y0 + 60}]
$doc image place photo -at [list $px $py] -width $pw -alt "A photograph the text flows round"
set body [join [lrepeat 6 $europan] "\n"]
set result [$doc text $body -at [list $x0 [expr {$y0 + 12}]] -width $width \
    -anchor top -align justify -firstIndent 5 -paginate 1 -columns 2 -gutter 6 \
    -avoid [list [list rect [list $px $py] [list $pw $ph] 3]]]
puts "  picture: [format %.0f $pw] x [format %.0f $ph] mm between the columns,\
    text ended on page [expr {[dict get $result page] + 1}]"

# -- 6. a page of another size -----------------------------------------------

# The area is a rule, not a pair of numbers: it is asked of every page. A
# table that starts on a landscape page and runs on to the portrait pages the
# document adds takes its -top and -bottom from each page it lands on - the
# rows stop 25 mm above the foot of the landscape page AND 25 mm above the
# foot of the portrait ones, and the running head sits in each page's own
# margin. Until 2026-08-18 the two distances were read once, from the page
# the table began on, and carried onto the others.
$doc page add -orientation landscape
lassign [$doc page typeArea] x0 y0 x1 y1
$doc font -style bold -size 14
$doc text "6. Started on a landscape page, continued on portrait ones" \
    -at [list $x0 [expr {$y0 + 4}]]
$doc font -style {} -size 10
set y [$doc table -at [list $x0 [expr {$y0 + 12}]] -width $width -theme striped \
    -head {{No. Word Amount}} -body $rows \
    -columns {{width 16 align right} {} {width 30 align decimal}}]
puts "  mixed sizes: the table ended on page [$doc page count] at y =\
    [format %.1f $y] mm, [lmap v [$doc page size] {format %.0f $v}] mm"

exampleFooter $doc helvetica

$doc write $target
puts "  written: $target ([file size $target] bytes), [$doc page count] pages"
$doc destroy
