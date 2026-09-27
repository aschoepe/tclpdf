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
#   ASKED FOR, it is a different matter, and that is what -fallback is: a
#   chain of faces written into the call, so the change of design is a
#   decision of the document rather than a repair the writer made behind the
#   caller's back. The two answers stand on the page below, one under the
#   other - the trap swaps the WHOLE LINE to the text face over one missing
#   letter, the chain swaps the CHARACTER and leaves the rest in the display
#   face. Which is right is a question about the document; what is wrong is
#   only the silent version of either.
#
#   The writer is the last place in the chain that still knows what was meant.
#   So it says so, names the character and the position, and lets the caller
#   decide - which is what the loop below does, in four lines. The same facts
#   travel machine-readable in the error's -errorcode - the list
#   {TCLPDF FONT GLYPH codepoint position fontname}, see "Error codes" in the
#   manual - so the loop traps by prefix instead of parsing the message.
#
# Do not take a font viewer's word for the coverage: a viewer that is asked
# for a character the face lacks substitutes the glyph from another face and
# shows it without saying so - FreeSans has no U+2714, its viewer window shows
# the check mark all the same, and hb-shape answers .notdef. A PDF has no such
# fallback; the embedded font is all a reader has. The file tells the truth,
# and so does the message below.
#
# The page keeps a record of which line got which face, so the decision is
# visible on the paper rather than buried in the script.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf

# The footer every example draws - shared, because one copy per example is
# how a block starts drifting.
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

$doc font embed script [file join $assets fonts google Niconne-Regular.ttf]
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
#
# The lines it cannot set are kept: the same ones are set again further down,
# with a chain, and the two halves of the page are then the same sentences
# decided twice.
set mixed {}
set record {}
set y 58
foreach {dish price} $dishes {
    $doc font -family script -size 14 -color black
    try {
        $doc text $dish -at [list 20 $y]
        lappend record [list $dish Niconne "set as chosen"]
    } trap {TCLPDF FONT GLYPH} {reason opts} {
        # Trapped by the errorcode's prefix, not by parsing the message: the
        # list behind it carries the codepoint, the position and the face,
        # and its shape is a documented contract while the wording is not.
        set codepoint [lindex [dict get $opts -errorcode] 3]
        $doc font -family body -size 11
        $doc text $dish -at [list 20 $y]
        lappend record [list $dish "DejaVu Sans" "no glyph for $codepoint"]
        lappend mixed $dish
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
# The y a paragraph returns is the one under its last line, so what follows
# does not have to be placed by counting rows by hand.
set y [$doc text "Niconne carries [dict get [$doc font info script] characters]\
    characters against DejaVu Sans with\
    [dict get [$doc font info body] characters]. Both Polish dishes above are\
    Polish; one sets and one does not. Coverage is a property of the file, and\
    the only way to know it is to ask the file." \
    -at [list 20 [expr {$y + 24 + [llength $record] * 8}]] -width 170]

# -- the same menu, decided per character ------------------------------------
#
# [font -fallback] names the faces that may set what the family cannot. Each
# character goes to the first face in the chain that has it, so Niconne keeps
# every letter it carries and DejaVu Sans supplies the two or three it does
# not - the line stays a display line with a few borrowed letters instead of
# turning into body text.
#
# The chain is consulted ONLY where the family has no glyph, so a line that
# Niconne can set whole is set exactly as it is above: same face, same bytes.
# And what no face in the chain has is refused as before, which is why this is
# an addition to this example rather than a contradiction of it.
#
# Measured on this page: the line is drawn in two faces, so the file carries
# two font resources for it and a reader sees two designs in one word. Look at
# "Bigos z zurawina" below and above - the same sentence, decided twice.
$doc font -family bodyBold -size 10
$doc text "The same lines, decided per character" -at [list 20 [expr {$y + 10}]]

$doc font -family body -size 8
set y [$doc text "Above, one missing letter costs the whole line its face.\
    With -fallback the display face keeps everything it has, and only the\
    letters it lacks come from DejaVu Sans." \
    -at [list 20 [expr {$y + 15}]] -width 170]

set chainY [expr {$y + 8}]
foreach dish $mixed {
    # The chain travels with the font state like -size or -kerning, so it
    # reaches [textWidth], the line breaker and a table cell as well.
    $doc font -family script -size 14 -fallback body
    $doc text $dish -at [list 20 $chainY]
    set chainY [expr {$chainY + 10}]
}

exampleFooter $doc body

$doc write $target
puts "  written: $target ([file size $target] bytes)"
set fallback 0
foreach entry $record {
    if {[lindex $entry 1] ne "Niconne"} { incr fallback }
}
puts "  [llength $record] dishes, $fallback needed the text face"
puts "  the same [llength $mixed] set again with -fallback: the display face\
    keeps every letter it has"
$doc destroy
