#!/usr/bin/env tclsh
#
# tclpdf example 9.3 - reading a filled-in form
#
#   tclsh examples/09.03-form-read.tcl ?output.pdf? ?form.pdf?
#
# The other direction. 9.1 and 9.2 build a form; this one is handed a filled
# one back and says what is in it. [::tclpdf::pdf fields] answers a list of
# dictionaries, one per field: the fully qualified name, the type in the same
# words [$doc field] takes, the value, the flags by name, the widgets and the
# pages they sit on.
#
# WITHOUT A SECOND ARGUMENT the script fills a form of its own first, in a
# scratch file it deletes again - one field of every type, with an answer in
# each - so that the page has something to report. WITH one it reads the file
# you name, and any PDF with an interactive form will do: a tax form, an
# application, a returned questionnaire.
#
# WHY THIS IS WORTH A COMMAND. To see what stands in a filled-in form until
# now you needed another program: "qpdf --json --json-key=acroform", or
# PDFBox through a Java runtime. Both are excellent and neither is a
# dependency anyone wants in a Tcl script that only has to read six answers
# out of a returned application. tclpdf has its own parser and was walking the
# field tree anyway - for [pdf info]'s signatures - so the answer costs
# nothing more than the file it was already reading.
#
# THE THREE PLACES A NAIVE READER GOES WRONG, and all three are visible on the
# page this writes:
#
#   /V has a DIFFERENT DATA TYPE per field type - a string in a text field, a
#   name in a check box and a radio set, the DISPLAYED text in a choice, a
#   dictionary in a signature field and nothing at all in a push button.
#
#   The EXPORT VALUE of a choice - what a form submission would carry - is not
#   in /V. It is the first half of the matching /Opt entry, and "selected"
#   answers it.
#
#   A FIELD IS NOT A WIDGET. A radio set is one field with one value and three
#   annotations, which may sit on different pages; a field with no widget at
#   all is a node of the tree that only carries a name.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf
package require tclpdf::importInfo

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "09.03-form-read.pdf"}]
set subject [lindex $argv 1]
set specimen {}
set label [expr {$subject eq {} ? "the specimen" : [file tail $subject]}]

# -- the filled form this one reads -----------------------------------------

if {$subject eq {}} {
    set channel [file tempfile specimen tclpdf-form.pdf]
    close $channel
    set subject $specimen

    set doc [tclpdf new -unit mm -format a4 -typeArea {20 20}]
    $doc info Title "A returned application"
    $doc page add
    $doc font -family helvetica -style bold -size 14
    $doc text "Mitgliedsantrag" -at {20 20}
    $doc field default -family helvetica -size 10

    $doc field text name -rect {20 30 80 7} -value "Erika Mustermann" \
        -tooltip "As held in the register of members" -required 1
    $doc field text remark -rect {20 40 80 20} -multiline 1 \
        -value "Ich kann bei Lesungen aushelfen." \
        -tooltip "Anything the form has no field for"
    $doc field combo salutation -rect {20 65 40 7} \
        -options {{F Frau} {H Herr} {D {Keine Angabe}}} -value F \
        -tooltip "How we address you in writing"
    $doc field listbox interests -rect {20 75 60 20} -multi 1 \
        -options {{books Lesungen} {kids {Kinder und Jugend}}
            {help Ehrenamt}} -value {books help} \
        -tooltip "More than one with Ctrl or Cmd"
    $doc field radio rate -buttons {{full {20 100 5 5}} {reduced {40 100 5 5}}
            {supporting {60 100 5 5}}} -value supporting -default full \
        -tooltip "The rate under clause 4"
    $doc field check newsletter -rect {20 110 5 5} -checked 1 -export yes \
        -tooltip "May be withdrawn at any time"
    $doc field text member -rect {20 120 40 7} -value "M-2026-0117" \
        -readonly 1 -tooltip "Given by the office"
    $doc field button reset -rect {20 130 40 8} -caption "Clear the form" \
        -action reset -tooltip "Puts every field back"
    $doc write $subject
    $doc destroy
}

# -- what stands in it ------------------------------------------------------

set facts [::tclpdf::pdf info $subject]
set fields [::tclpdf::pdf fields $subject]

# -- the page ---------------------------------------------------------------

set doc [tclpdf new -unit mm -format a4]
$doc info Title "tclpdf example: reading a filled-in form"
$doc page add

set y 20
exampleHeading $doc y "What $label was filled in with"
examplePara $doc y "[llength $fields] field[expr {[llength $fields] == 1 ?
        {} : {s}}], read with tclpdf's own parser - the one \[pdf import\]\
    takes a page over with. Nothing is installed for it and nothing is\
    started: no qpdf, no Java, no output format to parse."

# One field per block: the name and type on the left, what stands in it on the
# right, and underneath whatever else the field has to say.
proc formLine {doc yName label value {colour {0 0 0}}} {
    upvar 1 $yName y
    $doc font -family helvetica -style {} -size 8.5 -color {0.4 0.4 0.45}
    $doc text $label -at [list 22 $y]
    $doc font -color $colour
    set y [expr {[$doc text $value -at [list 52 $y] -width 138] + 4.2}]
    return
}

set y [expr {$y + 2}]
foreach field $fields {
    if {$y > 250} {
        $doc page add
        set y 20
    }
    $doc font -family helvetica -style bold -size 9.5 -color {0 0 0}
    $doc text "[dict get $field name]  ([dict get $field type])" -at [list 20 $y]
    set y [expr {$y + 5}]
    # The value, and for a choice the export value beside it - the one thing
    # /V does not say and a form submission carries.
    set value [dict get $field value]
    if {$value eq {}} {
        formLine $doc y "value" "- empty -" {0.55 0.55 0.6}
    } else {
        formLine $doc y "value" $value {0 0 0.5}
    }
    if {[dict get $field selected] ne {} \
            && [dict get $field selected] ne $value} {
        formLine $doc y "exports as" [join [dict get $field selected] {, }] \
            {0 0.35 0}
    }
    if {[dict get $field options] ne {}} {
        set shown {}
        foreach option [dict get $field options] {
            lassign $option export display
            lappend shown [expr {$export eq $display
                ? $display : "$export = $display"}]
        }
        formLine $doc y "options" [join $shown {, }]
    }
    if {[dict get $field default] ne {}} {
        formLine $doc y "default" [dict get $field default]
    }
    if {[dict get $field flags] ne {}} {
        formLine $doc y "flags" [join [dict get $field flags] {, }]
    }
    if {[dict get $field tooltip] ne {}} {
        formLine $doc y "tooltip" [dict get $field tooltip]
    }
    set widgets [llength [dict get $field widgets]]
    formLine $doc y "on the page" [expr {$widgets == 0
        ? "no widget - a node of the tree that only carries a name"
        : "$widgets widget[expr {$widgets == 1 ? {} : {s}}] on\
           page[expr {[llength [dict get $field pages]] == 1 ? {} : {s}}]\
           [join [dict get $field pages] {, }][expr {
               [dict get $field appearance] ? {} :
               {, and one of them has no appearance stream}}]"}]
    set y [expr {$y + 1.5}]
}

if {$y > 210} {
    $doc page add
    set y 20
}
set y [expr {$y + 3}]
exampleHeading $doc y "Check it yourself"
examplePara $doc y "Two other readers answer the same question, and where\
    they differ it is worth knowing why. qpdf enumerates WIDGETS: a radio set\
    of three buttons is three rows there and one field here, a field with no\
    widget does not appear at all, and its \"alternativename\" falls back to\
    the field name where the file writes no /TU. PDFBox enumerates fields, as\
    this does, and agrees with it field for field on every document tested."
exampleCommandBlock $doc y [list \
    "tclsh examples/09.03-form-read.tcl out.pdf any-form.pdf" \
    "qpdf --json --json-key=acroform any-form.pdf" \
    "java -cp tools/Mustang-CLI-2.25.0.jar tools/formcheck.java any-form.pdf"]

examplePara $doc y "Two kinds of file are refused rather than half-answered.\
    An ENCRYPTED one: a field name and a text value are strings, and strings\
    are what a security handler encrypts - measured on a 40-bit RC4 form,\
    /FT and /Ff come through and every /T and /V is binary rubbish. An XFA\
    form: its data lives in an XML stream in a format defined outside the PDF\
    standard, and the /AcroForm fields beneath it are a shadow copy that need\
    not agree with it - \"-xfa 1\" asks for that copy where it is what you\
    want. \[pdf info\] says which of the two you have."

exampleFooter $doc
$doc write $target
$doc destroy

# -- and on the console -----------------------------------------------------

puts "  read: $label ([dict get $facts form], [llength $fields] fields)"
foreach field $fields {
    set value [dict get $field value]
    if {[dict get $field selected] ne {} \
            && [dict get $field selected] ne $value} {
        append value " (exports as [join [dict get $field selected] {, }])"
    }
    puts [format "  %-12s %-10s %s" [dict get $field name] \
        [dict get $field type] $value]
}
puts "  written: $target"

if {$specimen ne {}} {
    file delete $specimen
}
