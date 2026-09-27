#!/usr/bin/env tclsh
#
# tclpdf example 1.13 - layers, which the standard calls optional content
#
#   tclsh examples/01.13-layers.tcl ?output.pdf?
#
# One sheet that is two documents: a German invoice and an English one, drawn
# on top of each other, and a draft stamp over both. The English layer and
# the stamp start switched OFF, so what a reader shows on opening is the
# German invoice alone and the other two are one click away. Which of them a
# reader shows is a checkbox in its layer panel - Acrobat calls it Layers, Preview
# and poppler pass the groups through, and the file is one file either way.
#
# The standard's word for it is optional content (ISO 32000-2, 8.11) and it
# has three parts. A group (/OCG) is the thing that gets switched. Content in
# the stream says which group it belongs to, with a bracket "/OC /name BDC
# ... EMC" around it. And the catalogue carries /OCProperties, which lists
# every group in the document and says which ones start out on - without that
# entry a reader ignores the brackets entirely.
#
# In tclpdf the three are two calls:
#
#   $doc layer create german -title "German"        the group
#   $doc layer draw german -script { ... }          the bracket
#
# and the catalogue entry is written for you. [layer radio] makes a set of
# groups behave like radio buttons - at most one of them on - which is what
# two language layers want.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "01.13-layers.pdf"}]

set doc [tclpdf new -unit mm]
$doc info Title "Layers"
$doc info Author "tclpdf example 1.13"
$doc page add

set y 24
exampleHeading $doc y "Layers"
examplePara $doc y "Everything below the rule is drawn twice, once in German\
    and once in English, and a draft stamp lies over both. Open the layer\
    panel of a reader and the three can be switched; the two languages are a\
    radio group, so turning one on turns the other off."

$doc line -from [list 20 [expr {$y + 2}]] -to [list 190 [expr {$y + 2}]] \
    -width 0.3 -stroke {0.6 0.6 0.65}
set top [expr {$y + 12}]

# -- the three groups -------------------------------------------------------

# -title is what the reader shows in its panel; without it the alias is used.
# -visible 0 means the group starts out off - the state lives in the default
# configuration, so it can still be changed later with [layer state].
$doc layer create german -title "German"
$doc layer create english -title "English" -visible 0
$doc layer create draft -title "Draft stamp" -visible 0

# At most one of the two languages at a time.
$doc layer radio {german english}

# The name of the default configuration, which a reader may show, and whether
# it lists all groups or only those a visible page uses.
$doc layer configure -title "Invoice, German" -listMode AllPages

# -- the same invoice, twice ------------------------------------------------

# One procedure for both languages: what differs is the words, not the
# layout. The document is a local variable here, and the script of
# [layer draw] runs in the caller's frame, so it can see it.
proc invoice {doc top words} {
    lassign $words heading intro column1 column2 total
    $doc font -family helvetica -style bold -size 16 -color {0.15 0.2 0.35}
    $doc text $heading -at [list 20 $top]
    $doc font -family helvetica -style {} -size 10 -color {0 0 0}
    set y [$doc text $intro -at [list 20 [expr {$top + 10}]] -width 170]
    $doc font -family helvetica -style bold -size 10
    $doc text $column1 -at [list 20 [expr {$y + 6}]]
    $doc text $column2 -at [list 190 [expr {$y + 6}]] -align right
    $doc font -family helvetica -style {} -size 10
    $doc text $total -at [list 20 [expr {$y + 14}]]
    $doc text "1.428,00 EUR" -at [list 190 [expr {$y + 14}]] -align right
    return [expr {$y + 22}]
}

# The script runs in the frame that called [layer draw], so it can both see
# the local variables of this file and leave one behind - "bottom" is where
# the invoice ended, and the paragraph after the layers starts from it.
$doc layer draw german -script {
    set bottom [invoice $doc $top {
        "Rechnung 2026-114"
        "Für die im Juli erbrachten Leistungen berechnen wir Ihnen den unten\
            aufgeführten Betrag. Zahlbar innerhalb von 14 Tagen ohne Abzug."
        "Position" "Betrag" "Beratung, 12 Stunden"
    }]
}

$doc layer draw english -script {
    invoice $doc $top {
        "Invoice 2026-114"
        "For the services rendered in July we charge you the amount shown\
            below. Payable within 14 days net."
        "Item" "Amount" "Consulting, 12 hours"
    }
}

# The stamp is one bracket over one drawing. A form XObject placed inside such
# a bracket works the same way - the invocation is what the layer switches.
$doc layer draw draft -script {
    $doc save
    $doc transform -rotate 20 -at {105 88}
    $doc font -family helvetica -style bold -size 54 -color {0.85 0.35 0.35} \
        -render stroke -stroke {0.85 0.35 0.35} -strokeWidth 0.6
    $doc text "DRAFT" -at {105 88} -align center
    $doc restore
}

# -- what is outside every layer --------------------------------------------

# The stamp left the text state on a stroked outline in red: [font] is a
# property of the document, not of the graphics state, so [save] and [restore]
# do not put it back. Everything after a call that changes it says what it
# wants itself.
$doc font -family helvetica -style {} -size 9 -color {0.35 0.35 0.4} \
    -render fill
set y [expr {$bottom + 8}]
examplePara $doc y "This paragraph is in no layer at all and is therefore\
    always shown. That is the default: content only becomes optional by being\
    put inside a bracket." {0.35 0.35 0.4}

# -- check it yourself ------------------------------------------------------

$doc font -family helvetica -style {} -size 10 -color {0 0 0}
exampleHeading $doc y "Check it yourself"
exampleCommandBlock $doc y [list \
    "qpdf --check [file tail $target]" \
    "qpdf --qdf --object-streams=disable [file tail $target] - | grep -A16 OCProperties" \
    "qpdf --qdf --object-streams=disable [file tail $target] - | grep -n 'BDC\\|EMC'"]

exampleFooter $doc helvetica

$doc write $target
puts "  written: $target ([file size $target] bytes)"
puts "  layers: [join [$doc layer names] {, }] - on at the start:\
    [join [lmap name [$doc layer names] {
        if {![$doc layer state $name]} continue
        set name
    }] {, }]"
$doc destroy
