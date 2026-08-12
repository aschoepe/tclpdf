#!/usr/bin/env tclsh
#
# tclpdf example 1.8 - text that flows
#
#   tclsh examples/01.08-textflow.tcl ?output.pdf?
#
# Three things a paragraph needs once it is longer than its box:
#
#   A HEIGHT LIMIT WITH A REST. [text ... -height h] sets what fits and hands
#   back what does not. That single return value is what makes columns and
#   "continued on page 2" ordinary code instead of a special case - the caller
#   decides where the rest goes, and the package does not have to know.
#
#   INDENTS. Left, right, and a first line of its own - positive for the
#   classic paragraph opening, negative for the hanging indent of a numbered
#   list, where the number stands out to the left of the text block.
#
#   FLOWING AROUND SHAPES. -avoid narrows each line by whatever reaches into
#   it. A rectangle blocks its own width; a circle blocks a chord that grows
#   towards its middle, so the text follows the round edge rather than a box
#   drawn around it.
#
# The mechanism underneath all three is the same: the line breaker asks, for
# every single line, how wide that line may be and where it starts.
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "01.08-textflow.pdf"}]

set doc [tclpdf new -unit mm]
$doc info Title "Text that flows"
$doc page add

set body "Ein Fliesstext wird an der Spaltenbreite umbrochen, und sobald eine\
    Hoehe im Spiel ist, auch an ihr. Was nicht mehr in die Spalte passt, kommt\
    als Rest zurueck - eine Zeichenkette, kein Zwischenzustand, den man\
    weiterreichen muesste. Der Aufrufer setzt sie in die naechste Spalte, auf\
    die naechste Seite oder in einen Kasten am Rand.

    Der zweite Absatz zeigt den Erstzeileneinzug und den Absatzabstand. Beide\
    sind Eigenschaften des Blocks, nicht der einzelnen Zeile, und sie gelten\
    fuer jeden Absatz im selben Aufruf.

    Der dritte Absatz laeuft weiter, damit fuer die zweite Spalte genug uebrig\
    bleibt und man sieht, dass der Umbruch dort neu gerechnet wird: eine\
    schmalere Spalte bricht anders, und genau deshalb gibt der Rest Text\
    zurueck und keine fertigen Zeilen."

# -- two columns from one call, twice ---------------------------------------

$doc font -family helvetica -style bold -size 13
$doc text "Two columns from one string" -at {20 24}

$doc font -style {} -size 8 -color {0.4 0.4 0.45}
$doc text "The rule under each column marks the height limit. What crosses it\
    goes to the next column." -at {20 31} -width 170

$doc font -size 9 -color black
set left [$doc text $body -at {20 42} -width 80 -height 55 \
    -align justify -firstIndent 6 -paragraphSpacing 3]
$doc line -from {20 99} -to {100 99} -stroke {0.85 0.85 0.9} -width 0.2

# The rest, set in the second column - narrower, so it breaks differently.
set right [$doc text [dict get $left rest] -at {110 42} -width 70 -height 55 \
    -align justify -paragraphSpacing 3]
$doc line -from {110 99} -to {180 99} -stroke {0.85 0.85 0.9} -width 0.2

puts "  column one returned [string length [dict get $left rest]] characters"
puts "  column two returned [string length [dict get $right rest]] characters"

# -- hanging indents --------------------------------------------------------

$doc font -style bold -size 11
$doc text "A hanging indent" -at {20 112}

$doc font -style {} -size 8 -color {0.4 0.4 0.45}
$doc text "-indent moves the whole block, -firstIndent moves its first line.\
    A negative first indent leaves the number standing to the left." \
    -at {20 118} -width 170

$doc font -size 9 -color black
set y 128
foreach {number clause} {
    "1." "Die Lieferung erfolgt frei Haus innerhalb von zehn Werktagen nach\
        Eingang der Bestellung, sofern die Ware vorraetig ist."
    "2." "Beanstandungen sind innerhalb von acht Tagen nach Erhalt schriftlich\
        anzuzeigen; danach gilt die Lieferung als genehmigt."
} {
    $doc text "$number $clause" -at [list 20 $y] -width 170 \
        -indent 8 -firstIndent -8 -align justify
    set y [expr {$y + 14}]
}

# -- flowing around shapes --------------------------------------------------

$doc font -style bold -size 11
$doc text "Flowing around a picture" -at {20 160}

$doc font -style {} -size 8 -color {0.4 0.4 0.45}
$doc text "The shapes are drawn first and named again in -avoid. A circle is\
    treated as a circle: the lines beside its middle are pushed furthest.\
    -avoidMargin holds the text off; the circle asks for more than the block\
    gives, as its own fourth value." -at {20 166} -width 170

# Drawn and avoided - the two are separate on purpose. A caller may want text
# to keep clear of something that is not drawn at all, a die line or the area
# a label will be stuck onto later.
#
# The picture starts a line lower than the text: the paragraph opens across
# the full column and only then runs beside it, which is how a picture set
# into running text is placed.
$doc rect -at {20 183} -size {45 26} -fill {0.87 0.90 0.95} \
    -stroke {0.55 0.62 0.75} -width 0.3
$doc text "Abbildung 1" -at {42.5 197} -align center -size 7 \
    -color {0.35 0.42 0.55}
$doc circle -at {148 205} -radius 21 -fill {0.97 0.90 0.88} \
    -stroke {0.80 0.62 0.58} -width 0.3

set around "Der Satz laeuft an den Formen vorbei. Solange eine Zeile das\
    Rechteck schneidet, wird sie kuerzer gesetzt und beginnt rechts daneben;\
    unterhalb laeuft sie wieder ueber die volle Spalte. Beim Kreis aendert\
    sich die Einrueckung von Zeile zu Zeile, weil die Sehne des Zeilenbandes\
    zur Mitte hin laenger wird - der Text folgt der Rundung statt dem Kasten\
    um sie herum. Beides zusammen ist eine einzige Rechnung je Zeile: das\
    Band gegen die Formen geschnitten, das breiteste freie Stueck gewinnt.\
    Mehr braucht ein Satzspiegel mit Bildern nicht, und weniger reicht nicht,\
    sobald eine Abbildung nicht rechteckig ist. Der Rest des Absatzes laeuft\
    unter beiden Formen hindurch und nimmt wieder die volle Spaltenbreite\
    ein, ohne dass dafuer etwas anzugeben waere."

# -avoidMargin keeps the text off the shapes - without it the words touch the
# picture, which reads as a mistake however exact the geometry is. A shape may
# carry its own margin as a fourth element, and then that one wins: the circle
# here gets more room than the framed rectangle, because round shapes leave
# their corners empty and look tighter at the same distance.
$doc font -size 9 -color black
$doc text $around -at {20 174} -width 170 -align justify -avoidMargin 4 \
    -avoid {{rect {20 183} {45 26}} {circle {148 205} 21 7}}

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes)"
$doc destroy
