#!/usr/bin/env tclsh
#
# tclpdf example 9.1 - interactive form fields, the text field
#
#   tclsh examples/09.01-form-fields.tcl ?output.pdf?
#
# A form to fill in on screen: five text fields, one of them multiline, one
# right-aligned, one with a length limit, one read-only and one for a
# password. Open the file in any reader that knows forms and type into it.
#
# The standard calls this an interactive form (ISO 32000-2, 12.7). Three
# pieces make one: an /AcroForm entry in the catalogue listing the fields, a
# widget annotation per field on the page it sits on, and - the piece that
# decides whether the form is worth anything - an appearance stream per
# widget, which is what a reader actually shows.
#
# THAT LAST PIECE IS WHERE FORM WRITERS GO WRONG, and the way out is a flag
# called /NeedAppearances that asks the reader to draw the fields instead.
# tclpdf does not take it: the flag is deprecated in PDF 2.0, the standard
# says nowhere HOW a reader is to draw, a reader that is not interactive does
# not draw at all, and the flag fires field events on opening. Every /AP here
# is drawn by the package, which is also the only way a form passes PDF/A -
# every widget annotation shall have an appearance dictionary (12.5.2, Table
# 166), and veraPDF fails a file without one.
#
# In tclpdf a field is one call:
#
#   $doc field text customer -rect {20 40 80 8} -value "Erika Mustermann"
#
# -rect counts {x y w h} from the TOP left corner of the page, in the unit of
# the document, exactly as "link -at" with "link -size" and "sign -rect" do.
#
# The other five field types, and a whole form built out of all six, are in
# 09.02 - which also shows why an archivable copy of a form cannot carry a
# reset button.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "09.01-form-fields.pdf"}]

set doc [tclpdf new -unit mm -format a4 -typeArea {20 20}]
$doc info Title "Interactive form fields"
$doc info Author "tclpdf example 9.1"
$doc page add

set y 20
$doc font -family helvetica -style bold -size 16 -color {0 0 0}
$doc text "Schadensmeldung" -at [list 20 $y]
set y [expr {$y + 10}]

examplePara $doc y "The boxes below are real form fields, not drawings. Open\
    this file in a reader that knows forms and type into them; what you type\
    replaces the appearance stream tclpdf drew, from the /Tx marked-content\
    mark to its matching EMC." {0.35 0.35 0.4}

# The font every field is set in, and the /DA of the form itself. Given once
# rather than per field: /DA is inheritable, and a form whose fields disagree
# about their type is a form that looks assembled from parts.
$doc field default -family helvetica -size 10 -color {0 0 0.35}

# One label and one field, at a fixed grid. The label is ordinary page
# content - marking up a field and writing its caption are two calls, exactly
# as drawing a text and laying a link over it are.
proc formRow {doc yName label name args} {
    upvar 1 $yName y
    $doc font -family helvetica -style {} -size 9.5 -color {0.25 0.25 0.3}
    $doc text $label -at [list 20 [expr {$y + 1.5}]]
    # A row is one line high unless the caller asked for more. The height is
    # taken OUT of the argument list rather than left in it: [option parse]
    # lets the last -rect win, so one passed on would have overridden the y
    # this proc works out and put the field at the top of the page.
    set height 7
    set rest {}
    foreach {option value} $args {
        if {$option eq "-height"} {
            set height $value
            continue
        }
        lappend rest $option $value
    }
    $doc field text $name -rect [list 60 $y 110 $height] \
        -border {0.55 0.55 0.62} -borderWidth 0.3 \
        -background {0.97 0.97 1} {*}$rest
    set y [expr {$y + $height + 4}]
    return
}

set y [expr {$y + 4}]

formRow $doc y "Name" customer -value "Erika Mustermann" \
    -tooltip "Name der versicherten Person"
formRow $doc y "Vertragsnummer" contract -maxlen 12 -value "V-2026-0815" \
    -tooltip "Zwoelf Zeichen, wie auf der Police"
formRow $doc y "Schadenhoehe" amount -align right -value "1.284,50" \
    -tooltip "Betrag in Euro, rechtsbuendig"
formRow $doc y "Hergang" story -height 24 -multiline 1 \
    -value "Am Morgen des 12. Maerz stand das Wasser\nbereits im Keller." \
    -tooltip "Was geschehen ist"
formRow $doc y "Aktenzeichen" reference -value "AZ 2026/4711" -readonly 1 \
    -tooltip "Vom Sachbearbeiter vergeben, nicht aenderbar"
formRow $doc y "Kennwort" secret -password 1 \
    -tooltip "Wird nicht in der Datei gespeichert"

set y [expr {$y + 4}]

# -- what stands in the file ------------------------------------------------

exampleHeading $doc y "What stands in the file"
examplePara $doc y "The read-only field carries /Ff 1, the multiline one /Ff\
    4096, and the right-aligned one /Q 2. The password field carries /Ff 8192\
    and NO value at all: Table 231 says a PDF processor shall never store the\
    value of a password field in the file, so tclpdf refuses -value there\
    rather than writing a password into a file anyone can open with a text\
    editor." {0.35 0.35 0.4}
examplePara $doc y "/NeedAppearances is not in this file. Its absence means\
    false, which is what qpdf reports below - and every field brought its own\
    appearance stream instead." {0.35 0.35 0.4}

exampleHeading $doc y "Check it yourself"
exampleCommandBlock $doc y [list \
    "qpdf --json --json-key=acroform [file tail $target]" \
    "qpdf --qdf --object-streams=disable [file tail $target] - | grep -B2 -A12 Widget" \
    "qpdf --qdf --object-streams=disable [file tail $target] - | grep -n 'Tx BMC'"]

exampleFooter $doc helvetica

$doc write $target
puts "  written: $target ([file size $target] bytes)"
puts "  fields: [join [$doc field list] {, }]"
$doc destroy
