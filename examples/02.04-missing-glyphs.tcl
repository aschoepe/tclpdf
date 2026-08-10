#!/usr/bin/env tclsh
#
# tclpdf example 2.4 - when the face has no glyph for a character
#
#   tclsh examples/02.04-missing-glyphs.tcl ?output.pdf?
#
# A display face is chosen for how it looks, and it is the coverage that
# decides whether it can be used. Niconne carries 283 characters: all of
# Latin-1, and then a RAGGED handful of Latin Extended-A - measured, it has
# U+0108..0109, U+0127..0129, U+013F..0144 and a dozen more fragments like it.
#
# That raggedness is the point. The gap does not follow a language:
# "Pierogi z lososiem" sets, "Bigos z zurawina" does not, and both are Polish.
# Guessing coverage from the language, or from the file name, or from having
# seen one accent work, is wrong in a way that only shows on the finished page.
#
# tclpdf REFUSES rather than substituting. That is deliberate, and it is the
# point of this example:
#
#   A missing glyph has no good silent answer. Dropping the character loses
#   data, .notdef prints an empty box, and falling back to another face
#   changes the design without asking. Every one of those is discovered by a
#   reader, weeks later, on paper.
#
#   The writer is the last place in the chain that still knows what was meant.
#   So it says so, names the character and the position, and lets the caller
#   decide - which is what the loop below does, in four lines.
#
# The page keeps a record of which line got which face, so the decision is
# visible on the paper rather than buried in the script.
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "02.04-missing-glyphs.pdf"}]
set assets [file join $here assets]

# Non-ASCII as \u escapes: the sources are plain ASCII throughout, because a
# literal beyond the BMP reads differently under Tcl 8.6 and 9.
set dishes {
    "Cr\u00E8me br\u00FBl\u00E9e"               "4,80"
    "Sm\u00F8rrebr\u00F8d"                       "6,20"
    "Gul\u00E1\u0161ov\u00E1 pol\u00E9vka"     "5,50"
    "Pierogi z \u0142ososiem"                    "7,90"
    "\u010Cevap\u010Di\u010Di"                  "8,10"
    "Bigos z \u017Curawin\u0105"                 "6,70"
    "\u015Ei\u015F kebap"                        "9,20"
}

set doc [tclpdf new -unit mm]
$doc info Title "tclpdf example: missing glyphs"
$doc page add

$doc font embed script [file join $assets fonts Niconne-Regular.ttf]
$doc font embed body [file join $assets fonts DejaVuSans.ttf]
$doc font embed bodyBold [file join $assets fonts DejaVuSans-Bold.ttf]

$doc font -family bodyBold -size 15
$doc text "When the face has no glyph" -at {20 22}
$doc font -family body -size 9
$doc text "The menu below is set in Niconne wherever Niconne can set it, and\
    in DejaVu Sans where it cannot. Which line got which is decided by trying,\
    because coverage is a property of the file and not of the language." \
    -at {20 29} -width 170

# The heading in the script face. Plain ASCII, so it is safe.
$doc font -family script -size 20
$doc text "Menu of the day" -at {20 46}

# -- the menu ---------------------------------------------------------------
#
# Try the display face; if tclpdf refuses, take the text face for that line.
# The refusal names the character, so the record below can say WHY.
set record {}
set y 58
foreach {dish price} $dishes {
    $doc font -family script -size 14 -color black
    if {[catch {$doc text $dish -at [list 20 $y]} reason]} {
        $doc font -family body -size 11
        $doc text $dish -at [list 20 $y]
        # The message ends in a sentence; the codepoint is what matters here.
        regexp {U\+[0-9A-F]{4}} $reason codepoint
        lappend record [list $dish "DejaVu Sans" "no glyph for $codepoint"]
    } else {
        lappend record [list $dish Niconne "set as chosen"]
    }
    $doc font -family body -size 11
    # -align decimal belongs to tables, where a column knows what the column
    # below it looks like. A single line of text has no such context, so the
    # prices line up on the right instead.
    $doc text $price -at [list 150 $y] -width 30 -align right
    set y [expr {$y + 10}]
}

# -- the record -------------------------------------------------------------

$doc font -family bodyBold -size 10
$doc text "Which line got which face" -at [list 20 [expr {$y + 6}]]

$doc table -at [list 20 [expr {$y + 12}]] -width 170 -theme striped \
    -style {family body} -headStyle {family bodyBold} \
    -head {{Dish Face Why}} -body $record \
    -columns {{} {width 38} {width 52}}

$doc font -family body -size 8
$doc text "Niconne carries [dict get [$doc font info script] characters]\
    characters against DejaVu Sans with\
    [dict get [$doc font info body] characters]. Both Polish dishes above are\
    Polish; one sets and one does not. Coverage is a property of the file, and\
    the only way to know it is to ask the file." \
    -at [list 20 [expr {$y + 12 + 12 + [llength $record] * 8}]] -width 170

exampleFooter $doc body

$doc write $target
puts "  written: $target ([file size $target] bytes)"
set fallback 0
foreach entry $record {
    if {[lindex $entry 1] ne "Niconne"} { incr fallback }
}
puts "  [llength $record] dishes, $fallback needed the text face"
$doc destroy
