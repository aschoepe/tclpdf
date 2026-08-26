#!/usr/bin/env tclsh
#
# tclpdf example 9.4 - the same field types, made to look like something else
#
#   tclsh examples/09.04-form-design.tcl ?output.pdf?
#
# 09.02 draws the form everybody has seen: framed boxes, tinted pale, a
# caption beside each one. This is the same six field types on a card that
# looks nothing like it - a feedback card handed out at a design week, with a
# full-bleed masthead, writing lines instead of boxes, a rating grid, and
# answers in coral rather than in a frame.
#
# THE STANDARD DOES NOT FIX WHAT A FIELD LOOKS LIKE, because the appearance
# of a widget is an ordinary Form XObject - a content stream like any other
# (12.5.5) - and what the standard supplies beside it is raw material a
# reader MAY use: /MK for the frame and the fill, /BS for the line, /DA for
# the type, /Q for the alignment. THE LIMIT IS THE KEYSTROKE: the stream in
# the file is what a reader shows, and the moment a user types, the reader
# builds a new appearance out of that raw material and its own ideas. So
# everything that survives typing goes through /MK - which is why -border and
# -background are written there as well as drawn - and everything else on
# this card is page content that no field can lose. MEASURED, not assumed:
# PDFBox rebuilding the appearance of all six text fields of this card leaves
# it looking exactly as it was written - the fills come back out of /MK, and
# the rules under the writing lines were never the fields' to lose.
#
# WHAT IS A FIELD HERE AND WHAT IS NOT is therefore the whole design:
#
#   the writing lines under the personal details are DRAWN, and the fields
#   over them carry -borderWidth 0 and no background at all, so a reader has
#   no frame to rebuild and the line stays where the page put it
#
#   the zebra tint of the rating grid is DRAWN, and the radio buttons on it
#   are white discs with a coral mark - -mark circle with -markSize, both
#   paths rather than a dingbat glyph
#
#   the check boxes are chips: -borderWidth 0 with a blush -background and a
#   coral cross, which is a frame nowhere and a fill in /MK /BG
#
#   the list box takes its selection bar from -highlight rather than the pale
#   blue a reader paints by itself, and the remarks field is a web-style
#   input - a fill, no frame, and a coral rule drawn beside it
#
#   the button is a solid slab: -borderWidth 0, the accent as -background and
#   white as -color, and its caption is the only text on the card that a
#   reader could redraw
#
# NOTHING IS EMBEDDED. The card is set in Helvetica throughout, one of the
# fourteen standard faces, so that what makes it look unlike 09.02 is colour,
# scale and space rather than a font in the file - the point being about the
# appearance of fields, not about type.
#
# THE DATA IS THE PROJECT'S SAMPLE DATA (docs/MUSTERDATEN.md): Erika
# Mustermann, Musterstrasse 12, 12345 Musterstadt. The card asks in English
# and the German address answers it unchanged, exactly as 09.02 does.
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "09.04-form-design.pdf"}]

# What the visitor filled in. The card is written once, filled: an empty one
# would show the writing lines and nothing else, and the marks, the selection
# bar and the coral values are half of what this example is about.
set card [dict create \
    name "Erika Mustermann" \
    street "Musterstrasse 12" \
    postcode 12345 \
    town Musterstadt \
    email "erika.mustermann@example.invalid" \
    heard poster \
    wayfinding 4 \
    programme 5 \
    catering 3 \
    value 4 \
    went {opening workshop market} \
    day Saturday \
    remarks "The type workshop was worth the trip on its own. More seats next\
        year, please."]

# ---------------------------------------------------------------------------
# The card
# ---------------------------------------------------------------------------

# THE PALETTE IN ONE PLACE. Seven colours, and every rule, every mark and
# every field fill on the card names one of them - a design whose accent is
# written out nineteen times is one that drifts at the first change of mind.
proc cardColour {name} {
    return [dict get {
        ink   {0.09 0.10 0.16}
        coral {0.90 0.31 0.20}
        blush {0.99 0.90 0.87}
        paper {0.96 0.95 0.92}
        rule  {0.78 0.76 0.72}
        body  {0.31 0.31 0.34}
        pale  {0.55 0.54 0.52}
    } $name]
}

proc cardFont {doc style size colour} {
    $doc font -family helvetica -style $style -size $size \
        -color [cardColour $colour]
    return
}

# The small coral label ABOVE its field - which is where a label goes when
# the field has no frame to sit beside. Set in capitals and letterspaced,
# because at seven points that is what keeps a two-word label readable.
proc cardLabel {doc x y text} {
    cardFont $doc bold 7 coral
    $doc text [string toupper $text] -at [list $x $y] -spacing 1.1
    return
}

# The writing line: the rule a field with no border of its own stands on.
proc cardRule {doc x y w} {
    $doc line -from [list $x $y] -to [list [expr {$x + $w}] $y] \
        -stroke [cardColour rule] -width 0.5
    return
}

# A text field ON a writing line, which is the whole of the first block: the
# label above, the field with no frame and no fill, the drawn rule below.
# -borderWidth 0 is what makes a reader rebuild no frame when the visitor
# types, and without it the rule would be doubled by one the moment the field
# was touched.
proc cardWrite {doc x y w label name value args} {
    cardLabel $doc $x $y $label
    $doc field text $name -rect [list $x [expr {$y + 1.6}] $w 7.4] \
        -value $value -borderWidth 0 {*}$args
    cardRule $doc $x [expr {$y + 9.6}] $w
    return
}

# A numbered block: the numeral in coral, the title beside it, a hairline
# across the measure. 09.02 bands its sections in a filled bar; this one
# leaves the paper alone and lets the numeral carry the weight.
proc cardBlock {doc yName number title} {
    upvar 1 $yName y
    cardFont $doc bold 15 coral
    $doc text $number -at [list 20 $y]
    cardFont $doc bold 10.5 ink
    $doc text $title -at [list 28.5 [expr {$y - 0.8}]]
    set under [expr {$y + 2.8}]
    $doc line -from [list 20 $under] -to [list 190 $under] \
        -stroke [cardColour ink] -width 0.5
    set y [expr {$y + 9}]
    return
}

set doc [tclpdf new -unit mm -format a4 -typeArea {20 20}]
$doc info Title "Musterstadt Design Week - visitor card"
$doc info Author "tclpdf example 9.4"
$doc info Subject "The same form field types in a different appearance"
$doc language en-GB
$doc page add

# The /DA of the whole card, given ONCE and inheritable, exactly as 09.02
# gives it. Every answer on the sheet is set in it and no field below repeats
# it; the only departures are the two mark colours, the smaller type in the
# two boxes that hold more than one line, and the white caption of the button.
$doc field default -family helvetica -size 11 -color [cardColour ink]

# -- the masthead -----------------------------------------------------------
#
# Full bleed, 0 to 210: a rectangle is page content and knows nothing of the
# type area, so a band may run off both edges where the design wants it to.

$doc rect -at {0 0} -size {210 38} -fill [cardColour ink]
$doc rect -at {0 38} -size {210 2} -fill [cardColour coral]

cardFont $doc bold 8 coral
$doc text "MUSTERSTADT DESIGN WEEK" -at {20 14} -spacing 1.6
cardFont $doc bold 27 ink
$doc font -color white
$doc text "How was it?" -at {20 31}
cardFont $doc {} 8 pale
$doc text "VISITOR CARD" -at {190 14} -align right -spacing 1.2
$doc text "12-19 April 2026" -at {190 31} -align right

# -- the card ---------------------------------------------------------------

set y 50
cardFont $doc {} 9.5 body
set y [expr {[$doc text "Everything you can type into or tick below is a form\
    field and not a drawing - nineteen fields in six kinds, thirty-five widgets\
    between them. Fill the card\
    in on screen, or print it and use a pen." \
    -at [list 20 $y] -width 170] + 6}]

# -- 1 who is writing -------------------------------------------------------

cardBlock $doc y 1 "Who is writing"

cardWrite $doc 20 $y 170 "Name" name [dict get $card name] -required 1 \
    -tooltip "However you want to be addressed"
set y [expr {$y + 14}]

cardWrite $doc 20 $y 82 "Street and number" street [dict get $card street]
# Two fields on one line, and the postcode carries -maxlen 5: a German
# postcode has five digits, and the reader stops at the fifth keystroke.
cardWrite $doc 105 $y 20 "Postcode" postcode [dict get $card postcode] \
    -maxlen 5
cardWrite $doc 128 $y 62 "Town" town [dict get $card town]
set y [expr {$y + 14}]

cardWrite $doc 20 $y 82 "E-mail" email [dict get $card email] \
    -tooltip "Only for the programme next year, and for nothing else"

# THE COMBO BOX ON A WRITING LINE, with a drawn caret beside it rather than a
# frame around it. -options takes {export display} pairs (Table 234) and /V
# holds the DISPLAYED text, so the value below is "A poster in town" and what
# a submission would carry is "poster".
cardLabel $doc 105 $y "How you heard of us"
$doc field combo heard -rect [list 105 [expr {$y + 1.6}] 80 7.4] \
    -options {{poster {A poster in town}} {friend {A friend told me}}
        {press {In the paper}} {web {On the web}} {chance {Walked past}}} \
    -value [dict get $card heard] -borderWidth 0 \
    -tooltip "One answer, whichever comes closest"
$doc polygon -points [list 186.5 [expr {$y + 4.6}] 190 [expr {$y + 4.6}] \
    188.25 [expr {$y + 7.2}]] -close 1 -fill [cardColour coral]
cardRule $doc 105 [expr {$y + 9.6}] 85
set y [expr {$y + 18}]

# -- 2 the rating grid ------------------------------------------------------

cardBlock $doc y 2 "How it went"

# Five columns, and their centres are the one measurement the whole grid is
# built from: the heads, the zebra rows and every button take their x from
# this list, so a column that moves moves once.
set columns {122.5 137.5 152.5 167.5 182.5}

cardFont $doc bold 8 coral
foreach column $columns head {1 2 3 4 5} {
    $doc text $head -at [list $column $y] -align center
}
set y [expr {$y + 3}]

# ONE RADIO FIELD PER ROW, five buttons under it: -buttons takes one
# {value {x y w h}} pair per button and the export value is what stands in
# /V. The buttons are white discs on a tinted row - -background {1 1 1} and a
# hairline -border - and the mark is a coral circle, which is what -mark and
# -markSize draw as a path.
set row 0
foreach {field caption} {
        wayfinding "Finding your way around"
        programme "The talks and the workshops"
        catering "Food and drink"
        value "Value for the ticket price"} {
    set top [expr {$y + $row * 9}]
    if {$row % 2 == 0} {
        $doc rect -at [list 20 $top] -size {170 9} -fill [cardColour paper]
    }
    cardFont $doc {} 9.5 ink
    $doc text $caption -at [list 24 [expr {$top + 5.9}]]
    set buttons {}
    foreach column $columns mark {1 2 3 4 5} {
        lappend buttons [list $mark \
            [list [expr {$column - 2.5}] [expr {$top + 2}] 5 5]]
    }
    $doc field radio $field -buttons $buttons \
        -value [dict get $card $field] -mark circle -markSize 2.8 \
        -color [cardColour coral] -border [cardColour rule] -borderWidth 0.35 \
        -background {1 1 1} -tooltip "$caption, from 1 to 5"
    incr row
}
set y [expr {$y + $row * 9 + 4}]

cardFont $doc {} 7.5 pale
$doc text "1 not at all   ·   5 very much indeed" -at [list 190 $y] -align right
set y [expr {$y + 8}]

# -- 3 what was visited -----------------------------------------------------

cardBlock $doc y 3 "What you went to"

# CHIPS, not boxes: -borderWidth 0 leaves the check box with no frame at all,
# the blush -background is what a reader keeps in /MK /BG, and the cross is
# drawn in the accent. A check box exports the name given as -export, so the
# card comes back saying "opening" rather than six fields all saying "Yes".
set row 0
foreach {field caption} {
        opening "Opening night"
        tours "Studio tours"
        workshop "The type workshop"
        market "Poster market"
        talks "Talks in the hall"
        party "Closing party"} {
    set x [expr {$row % 2 ? 108 : 24}]
    set top [expr {$y + ($row / 2) * 9}]
    $doc field check went[string totitle $field] -rect [list $x $top 6 6] \
        -checked [expr {[lsearch -exact [dict get $card went] $field] >= 0}] \
        -default 0 -export $field -mark cross -markSize 3 \
        -color [cardColour coral] -borderWidth 0 \
        -background [cardColour blush] \
        -tooltip $caption
    cardFont $doc {} 9.5 ink
    $doc text $caption -at [list [expr {$x + 9}] [expr {$top + 4.4}]]
    incr row
}
set y [expr {$y + 3 * 9 + 4}]

# -- 4 the rest -------------------------------------------------------------

cardBlock $doc y 4 "Two last things"

# THE LIST BOX with a selection bar of its own: -highlight is the colour
# behind the selected row, and a reader paints a light blue there where it is
# not given. A blush bar on warm paper, with no frame at all, is a list that
# belongs to this card rather than to the reader's idea of one.
cardLabel $doc 20 $y "Best day for you"
$doc field listbox day -rect [list 20 [expr {$y + 2.5}] 62 22] \
    -options {Thursday Friday Saturday Sunday} \
    -value [dict get $card day] -highlight [cardColour blush] \
    -borderWidth 0 -background [cardColour paper] -size 10 \
    -tooltip "The one day you would come back for"

# THE REMARKS FIELD as a web-style input: a fill, no frame, and a coral rule
# drawn down its left edge - page content beside the field rather than a
# border on it, so nothing about it changes when the visitor types.
cardLabel $doc 92 $y "Anything else"
$doc rect -at [list 89 [expr {$y + 2.5}]] -size {2 22} -fill [cardColour coral]
$doc field text remarks -rect [list 92 [expr {$y + 2.5}] 98 22] -multiline 1 \
    -value [dict get $card remarks] -borderWidth 0 \
    -background [cardColour paper] -size 9 \
    -tooltip "Room for whatever the card has no field for"
set y [expr {$y + 29}]

# -- the button -------------------------------------------------------------

# A SOLID SLAB: no frame, the accent as the fill, white as the type. A push
# button carries no value at all (12.7.5.2.2), so the caption is the whole of
# what it says - and it is the one string on the card that a reader may draw
# again out of /MK /CA.
$doc field button restart -rect [list 20 $y 46 11] -caption "Start over" \
    -action reset -family helvetica -style bold -size 11 -color white \
    -borderWidth 0 -background [cardColour coral] \
    -tooltip "Puts every answer back to the value the card was written with"

cardFont $doc {} 8.5 pale
$doc text "Clears the card, all nineteen fields of it." \
    -at [list 71 [expr {$y + 7.4}]]
set y [expr {$y + 19}]

$doc line -from [list 20 $y] -to [list 190 $y] \
    -stroke [cardColour coral] -width 1
cardFont $doc bold 9.5 ink
$doc text "Thank you. Drop the card in the box by the exit, or mail it back." \
    -at [list 20 [expr {$y + 6}]]

exampleFooter $doc helvetica

# ---------------------------------------------------------------------------
# What is in the file
# ---------------------------------------------------------------------------

$doc page add
$doc rect -at {0 0} -size {210 12} -fill [cardColour ink]
$doc rect -at {0 12} -size {210 1.4} -fill [cardColour coral]
cardFont $doc bold 8 coral
$doc text "HOW WAS IT · WHAT IS IN THE FILE" -at {20 8} -spacing 1.6

set y 30

exampleHeading $doc y "The same six types as 09.02"
examplePara $doc y "Nineteen fields, of six types, in one /AcroForm, and\
    thirty-five widget annotations on the sheet - the four rating rows are\
    four fields with five buttons each, which is why qpdf lists \"programme\"\
    five times. Beside 09.02 the two sheets share\
    every call and agree about nothing that can be seen: the difference is\
    -borderWidth, -background, -mark, -markSize, -highlight and the colours,\
    and the rest of the look is page content drawn around the boxes."\
    {0.31 0.31 0.34}

exampleHeading $doc y "Why a reader cannot take it away"
examplePara $doc y "An appearance stream is an ordinary Form XObject, so\
    there is nothing in the standard that says what a field looks like. What\
    there is is raw material a reader MAY use when it draws one itself:\
    /MK for the frame and the fill, /BS for the line style, /DA for the type\
    and /Q for the alignment. That moment comes at the first keystroke - so\
    everything meant to survive typing is written to /MK as well as drawn,\
    and everything else here is page content, which no field can lose."\
    {0.31 0.31 0.34}

examplePara $doc y "/NeedAppearances is not in this file. Every one of the\
    thirty-five widgets brought an appearance stream of its own, drawn by\
    the package - which is also the only thing that makes a design like this\
    one survive being opened in a reader that draws fields its own way."\
    {0.31 0.31 0.34}

exampleHeading $doc y "Check it yourself"
# The fourth line is the one this example turns on: a validator says the
# fields are sound, and only a rendering says whether the card looks like
# anything. Put the two sheets side by side and the point makes itself.
exampleCommandBlock $doc y [list \
    "qpdf --check [file tail $target]" \
    "qpdf --json --json-key=acroform [file tail $target]" \
    "java -cp tools/Mustang-CLI-2.25.0.jar tools/formcheck.java [file tail $target]" \
    "pdftoppm -r 150 -png -f 1 -l 1 [file tail $target] card"]

exampleFooter $doc helvetica

$doc write $target
set names [$doc field list]
puts "  written: $target ([file size $target] bytes)"
puts "  [llength $names] fields: [join $names {, }]"
# Read back OUT of the document rather than repeated from the calls above -
# the same reason the footer asks the document for its fonts.
set rating [$doc field state programme]
puts "  the rating rows: [dict get $rating type], one field with\
    [llength [dict get $rating widgets]] buttons"
puts "  [llength [$doc font names]] fonts embedded - the card is set in\
    standard faces throughout"
$doc destroy
