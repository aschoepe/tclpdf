#!/usr/bin/env tclsh
#
# tclpdf example 9.2 - a whole form, of every field type there is
#
#   tclsh examples/09.02-form-application.tcl ?output.pdf?
#
# 09.01 shows the text field on its own. This is what a form looks like when
# it has a job to do: an application for membership of an association, the
# kind that comes with the annual report and goes back by post or by mail.
# Every field type the package has is on it - text, check box, radio group,
# list box, combo box and push button - and each is there because that line
# of the form needs it, not to fill a list.
#
# TWO DOCUMENTS come out of the same procedure:
#
#   09.02-form-application.pdf          the blank form, to fill in on screen,
#                                       with a reset button on it
#   09.02-form-application-record.pdf   the same form filled in and locked,
#                                       as PDF/A-3B, which is what an
#                                       association keeps in its files
#
# and between them a write that IS REFUSED and prints why: PDF/A admits no
# action on a widget annotation, so the reset button and the archival claim
# cannot both be had. The script asks for both on purpose, catches the
# refusal and only then writes the record without the button - because a
# rule you can read in a message is worth more than one described in a
# comment.
#
# WHAT MAKES A FORM WORK is the appearance stream per widget, and tclpdf
# draws every one of them rather than setting /NeedAppearances - the reasons
# stand in the header of 09.01. What this example adds is the second half of
# the job: the /DA of the document, the export values behind the displayed
# texts, the default values a reset puts back, and the fact that a form is
# mostly ordinary page content with boxes laid into it. The labels, the rules
# and the signature line here are drawn, not fields; only the boxes are.
#
# THE DATA IS THE PROJECT'S SAMPLE DATA (docs/MUSTERDATEN.md): Erika
# Mustermann, Musterstrasse 12, 12345 Musterstadt, and an IBAN whose check
# digits are right and whose account does not exist. The sheet asks in
# English and the sample data answers in German, which is what an applicant
# with a German address writes into an English form - the name, the street,
# the postcode, the IBAN and the BIC are left exactly as that page has them.
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "09.02-form-application.pdf"}]
set stem [file rootname $target]
set record ${stem}-record.pdf
set assets [file join $here assets]
set profile [file join [file dirname $here] icc sRGB.icc]

# What the applicant wrote. The blank form is the same call with nothing in
# it, so the two documents differ in this dictionary and in two switches -
# there is no second copy of the form anywhere in this file.
set application [dict create \
    salutation Ms \
    name "Erika Mustermann" \
    street "Musterstrasse 12" \
    postcode 12345 \
    city Musterstadt \
    email "erika.mustermann@example.invalid" \
    rate supporting \
    donation 120.00 \
    interests {Readings Volunteering} \
    newsletter 1 \
    holder "Erika Mustermann" \
    iban DE02120300000000202051 \
    bic BYLADEM1001 \
    mandate 1 \
    remarks "I can help out at readings at the weekend." \
    membership "M-2026-0117"]

# ---------------------------------------------------------------------------
# The form
# ---------------------------------------------------------------------------

# A face and a style as ONE value, so that the form does not need to know
# which document it is drawing on. The blank form is set in Helvetica, a
# standard face; the archival copy may not use one and is set in an embedded
# DejaVu, whose bold is a family of its own rather than a style.
proc applicationFont {doc face size colour} {
    $doc font -family [lindex $face 0] -style [lindex $face 1] \
        -size $size -color $colour
    return
}

# What the applicant answered, or nothing - the blank form passes an empty
# dictionary and every field then falls back to what it is given here.
proc applicationAnswer {answers key {none {}}} {
    if {[dict exists $answers $key]} {
        return [dict get $answers $key]
    }
    return $none
}

# A caption BESIDE its box. The baseline goes at the middle of the box plus
# half a cap height, which is what makes a label look attached to its field;
# set at the top of the box - the obvious thing to write - it floats above it
# and the form reads as two columns that have nothing to do with each other.
# 0.72 em is the cap height of every face in this example, and 25.4/72 turns
# the point size into the millimetres the document counts in.
proc applicationLabel {doc face x y height text {size 9}} {
    applicationFont $doc $face $size {0.25 0.25 0.3}
    $doc text $text -at [list $x [expr {$y + $height / 2.0 + $size * 0.72 * 0.1764}]]
    return
}

# A numbered band across the measure. A form is read in blocks, and the blocks
# are what tell the reader where the bank details stop and the remarks begin.
proc applicationSection {doc yName face number title} {
    upvar 1 $yName y
    $doc rect -at [list 20 $y] -size {170 6.5} -fill {0.89 0.91 0.96}
    applicationFont $doc $face 9.5 {0.13 0.2 0.36}
    $doc text "$number   $title" -at [list 22 [expr {$y + 4.6}]]
    set y [expr {$y + 10}]
    return
}

# THE FORM ITSELF, drawn once and used twice.
#
#   -text     {family style} for the body and the field values
#   -head     {family style} for the headings and the labels in bold
#   -answers  what the applicant wrote, empty for a blank form
#   -reset    whether the two push buttons go on the sheet
#   -locked   whether every field is read-only, which is what an archived
#             copy of a signed application is
#
# It returns the y it ended at, so the caller can go on writing below it.
#
# THE BOX COLUMN STARTS AT 60 rather than at the 58 an earlier draft used:
# "Membership number" is the longest label on the sheet and measures 33 mm in
# the embedded face of the record, so at 58 it came within 5 mm of its own
# box. Two millimetres of the field width buy the gap back, and the rows the
# label column governs are the ones that had to move with it.
proc applicationForm {doc args} {
    set options [dict merge {
        -text {helvetica {}} -head {helvetica bold}
        -answers {} -reset 1 -locked 0
    } $args]
    set text [dict get $options -text]
    set head [dict get $options -head]
    set answers [dict get $options -answers]
    set locked [dict get $options -locked]

    # The three switch groups every field in this form carries. Written once:
    # sixteen fields that repeat a border colour are sixteen places for it to
    # drift, and a form whose boxes disagree about their frame looks assembled
    # from parts.
    set box {-border {0.55 0.55 0.62} -borderWidth 0.3 -background {0.97 0.97 1}}
    set lock [list -readonly $locked]
    set h 6.5

    # -- the letterhead ------------------------------------------------------

    $doc rect -at {20 18} -size {170 17} -fill {0.13 0.2 0.36}
    applicationFont $doc $head 14 white
    $doc text "Application for membership" -at {25 28}
    applicationFont $doc $text 8 {0.78 0.83 0.92}
    $doc text "Friends of Musterstadt City Library" -at {185 28} -align right

    set y 42
    applicationFont $doc $text 9.5 {0.35 0.35 0.4}
    set y [expr {[$doc text "Please fill the sheet in on screen. The boxes are\
        form fields: what you type into one takes the place of the appearance\
        that tclpdf drew into it." \
        -at [list 20 $y] -width 170] + 6}]

    # -- 1 the member --------------------------------------------------------

    applicationSection $doc y $head 1 "Member details"

    # The combo box, and the one place where the standard is easy to get
    # wrong: -options takes {export display} pairs (Table 234), and /V holds
    # the DISPLAYED text, not the export value. So the value below is "Ms"
    # and what leaves the form for the member register is "F".
    applicationLabel $doc $text 20 $y $h "Salutation"
    $doc field combo salutation -rect [list 60 $y 34 $h] \
        -options {{F Ms} {M Mr} {X {Prefer not to say}}} \
        -value [applicationAnswer $answers salutation] \
        -tooltip "How we address you in writing" {*}$box {*}$lock
    set y [expr {$y + $h + 3}]

    applicationLabel $doc $text 20 $y $h "Name in full"
    $doc field text name -rect [list 60 $y 130 $h] \
        -value [applicationAnswer $answers name] -required 1 \
        -tooltip "As it stands in the member register" {*}$box {*}$lock
    set y [expr {$y + $h + 3}]

    applicationLabel $doc $text 20 $y $h "Street and number"
    $doc field text street -rect [list 60 $y 130 $h] \
        -value [applicationAnswer $answers street] -required 1 {*}$box {*}$lock
    set y [expr {$y + $h + 3}]

    # Two fields on one line, because a postcode and a town are one line on
    # every form there has ever been. -maxlen is the German postcode: five
    # digits and no sixth, which the reader enforces while typing.
    applicationLabel $doc $text 20 $y $h "Postcode, town"
    $doc field text postcode -rect [list 60 $y 17 $h] -maxlen 5 \
        -value [applicationAnswer $answers postcode] -required 1 \
        -tooltip "Five digits" {*}$box {*}$lock
    $doc field text city -rect [list 80 $y 110 $h] \
        -value [applicationAnswer $answers city] -required 1 {*}$box {*}$lock
    set y [expr {$y + $h + 3}]

    applicationLabel $doc $text 20 $y $h "E-mail"
    $doc field text email -rect [list 60 $y 130 $h] \
        -value [applicationAnswer $answers email] \
        -tooltip "For the invitation to the annual general meeting" \
        {*}$box {*}$lock
    set y [expr {$y + $h + 6}]

    # -- 2 the membership ----------------------------------------------------

    applicationSection $doc y $head 2 "Membership"

    # THE RADIO GROUP IS ONE FIELD with three buttons, which is what -buttons
    # says: one {value {x y w h}} pair per button, and the export value is
    # what stands in /V - there is no display text on a radio button, the
    # caption beside it is drawn page content like every other label here.
    #
    # The three buttons sit at 60, 96 and 138, closer together than the even
    # thirds a German sheet could afford: "Supporting, from EUR 120" is the
    # widest of the three captions by a good 13 mm, and it is the one with the
    # margin behind it. Measured in the embedded face, the last caption now
    # ends at 184 mm - inside the 190 the measure allows.
    applicationLabel $doc $text 20 $y 4.5 "Subscription rate"
    $doc field radio rate -buttons [list \
            [list full [list 60 $y 4.5 4.5]] \
            [list reduced [list 96 $y 4.5 4.5]] \
            [list supporting [list 138 $y 4.5 4.5]]] \
        -value [applicationAnswer $answers rate full] -default full \
        -tooltip "The rate under clause 4 of the subscription rules" \
        {*}$box {*}$lock
    foreach {x caption} [list \
            66.5 "Full, EUR 60" \
            102.5 "Reduced, EUR 30" \
            144.5 "Supporting, from EUR 120"] {
        applicationLabel $doc $text $x $y 4.5 $caption 8.5
    }
    set y [expr {$y + 4.5 + 4.5}]

    # Money, right-aligned, the way an amount stands on every form: /Q 2.
    applicationLabel $doc $text 20 $y $h "Annual amount"
    $doc field text donation -rect [list 60 $y 26 $h] -align right \
        -value [applicationAnswer $answers donation] \
        -tooltip "To be filled in for the supporting rate only" {*}$box {*}$lock
    applicationLabel $doc $text 88 $y $h "EUR"
    set y [expr {$y + $h + 3}]

    # The list box holds what a member can be interested in, more than one at
    # a time - and its options carry export codes, so the register keeps
    # "kids" rather than a sentence that may be reworded next year.
    applicationLabel $doc $text 20 $y 5 "Interests"
    $doc field listbox interests -rect [list 60 $y 62 21] -multi 1 \
        -options {{books Readings} {kids {Children and young people}}
            {digital {Digital services}} {stock {Building the collection}}
            {help Volunteering}} \
        -value [applicationAnswer $answers interests] \
        -tooltip "Select more than one with Ctrl or Cmd" {*}$box {*}$lock

    # A consent box starts EMPTY and has a default of 0: whatever the reset
    # button puts back, it may not be a consent nobody gave.
    $doc field check newsletter -rect [list 132 $y 4.5 4.5] \
        -checked [applicationAnswer $answers newsletter 0] -default 0 \
        -export yes -tooltip "May be withdrawn at any time" {*}$box {*}$lock
    applicationLabel $doc $text 138.5 $y 4.5 "Newsletter by e-mail" 8.5
    set y [expr {$y + 21 + 6}]

    # -- 3 the direct debit mandate ------------------------------------------

    applicationSection $doc y $head 3 "SEPA direct debit mandate"

    applicationLabel $doc $text 20 $y $h "Account holder"
    $doc field text holder -rect [list 60 $y 130 $h] \
        -value [applicationAnswer $answers holder] {*}$box {*}$lock
    set y [expr {$y + $h + 3}]

    # 22 characters is the German IBAN, and -maxlen is where the form says so.
    applicationLabel $doc $text 20 $y $h "IBAN"
    $doc field text iban -rect [list 60 $y 62 $h] -maxlen 22 \
        -value [applicationAnswer $answers iban] \
        -tooltip "22 characters, no spaces" {*}$box {*}$lock
    applicationLabel $doc $text 128 $y $h "BIC"
    $doc field text bic -rect [list 138 $y 52 $h] -maxlen 11 \
        -value [applicationAnswer $answers bic] {*}$box {*}$lock
    set y [expr {$y + $h + 3}]

    $doc field check mandate -rect [list 60 $y 4.5 4.5] \
        -checked [applicationAnswer $answers mandate 0] -default 0 \
        -required 1 -export yes \
        -tooltip "Nothing can be collected without this consent" \
        {*}$box {*}$lock
    applicationFont $doc $text 8.5 {0.25 0.25 0.3}
    set y [expr {[$doc text "I authorise the association to collect the annual\
        subscription from my account by direct debit, and instruct my bank to\
        honour the direct debits drawn on it." \
        -at [list 67 [expr {$y + 3.3}]] -width 123] + 4}]

    # -- 4 remarks -----------------------------------------------------------

    applicationSection $doc y $head 4 "Remarks"

    $doc field text remarks -rect [list 20 $y 170 18] -multiline 1 \
        -value [applicationAnswer $answers remarks] \
        -tooltip "Room for whatever the sheet has no field for" \
        {*}$box {*}$lock
    set y [expr {$y + 18 + 6}]

    # -- what the office fills in --------------------------------------------

    # The read-only field of every application form there is. It is a FIELD
    # and not a drawn line because the number belongs to the record the form
    # becomes; /Ff 1 is what keeps it out of the applicant's reach.
    applicationLabel $doc $text 20 $y $h "Membership number"
    $doc field text membership -rect [list 60 $y 40 $h] -readonly 1 \
        -value [applicationAnswer $answers membership "to be assigned"] \
        -color {0.45 0.45 0.5} -tooltip "Assigned by the office" \
        -border {0.55 0.55 0.62} -borderWidth 0.3 -background {0.93 0.93 0.94}
    set y [expr {$y + $h + 8}]

    # -- the two push buttons ------------------------------------------------

    if {[dict get $options -reset]} {
        # A push button carries no value at all (12.7.5.2.2), so its caption
        # is the whole of what it says. The first one resets the form; the
        # second names the fields it resets and leaves the rest alone, which
        # is what -fields is for - the bank block is the part a member wants
        # to clear without typing his address again.
        $doc field button clearAll -rect [list 20 $y 44 8] \
            -caption "Clear the form" -action reset -size 9 \
            -border {0.45 0.45 0.55} -borderWidth 0.4 \
            -background {0.90 0.91 0.94} \
            -tooltip "Puts every field back to the value it started with"
        $doc field button clearBank -rect [list 68 $y 48 8] \
            -caption "Clear the bank details" -action reset \
            -fields {holder iban bic mandate} -size 9 \
            -border {0.45 0.45 0.55} -borderWidth 0.4 \
            -background {0.90 0.91 0.94} \
            -tooltip "Clears the SEPA direct debit mandate block only"
        set y [expr {$y + 8 + 8}]
    }

    # The signature line is drawn, not a field: what a form asks for by hand
    # it cannot take on screen, and a box that looks like a field and is not
    # one is the worse of the two lies.
    $doc line -from [list 20 $y] -to [list 105 $y] -stroke {0.55 0.55 0.62} \
        -width 0.3
    $doc line -from [list 115 $y] -to [list 190 $y] -stroke {0.55 0.55 0.62} \
        -width 0.3
    applicationFont $doc $text 8 {0.45 0.45 0.5}
    $doc text "Place, date" -at [list 20 [expr {$y + 4}]]
    $doc text "Signature" -at [list 115 [expr {$y + 4}]]
    return [expr {$y + 8}]
}

# ---------------------------------------------------------------------------
# The blank form
# ---------------------------------------------------------------------------

set doc [tclpdf new -unit mm -format a4 -typeArea {20 20}]
$doc info Title "Application for membership"
$doc info Author "tclpdf example 9.2"
$doc info Subject "An interactive form of every field type there is"
$doc language en-GB
$doc page add

# The /DA of the form, given ONCE. It is inheritable, and a document whose
# fields each name their own face is a form that looks assembled from parts.
# Every field below overrides it only where it has a reason to - the
# read-only number is set in grey, and nothing else departs from this line.
$doc field default -family helvetica -size 9.5 -color {0 0 0.35}

applicationForm $doc

# The second page says what is in the file and how to look at it. It carries
# no fields at all, which is worth showing: /Annots is per page, and a form
# does not have to be on every sheet of the document it belongs to.
$doc page add
set y 20

exampleHeading $doc y "What stands in the file"
examplePara $doc y "Eighteen fields, of six types, in one /AcroForm, and\
    twenty widget annotations on the sheet - the radio group is ONE field\
    with three widgets under it, which is why qpdf lists \"rate\" three\
    times and why the register receives one value however many buttons a\
    reader draws. The combo box and the list box carry /Opt arrays of pairs:\
    what is displayed and what is exported are two different strings, and /V\
    holds the displayed one (ISO 32000-2, Table 234)." {0.35 0.35 0.4}
examplePara $doc y "The two push buttons carry a /ResetForm action, and the\
    second one a /Fields array naming the four fields of the mandate block.\
    Neither carries a value: a push button \"shall not use the V and DV\
    entries\" (12.7.5.2.2), because it retains nothing." {0.35 0.35 0.4}
examplePara $doc y "/NeedAppearances is not in this file - every one of the\
    twenty widgets brought an appearance stream of its own, drawn by the\
    package." {0.35 0.35 0.4}

exampleHeading $doc y "The same form as a record"
examplePara $doc y "Beside this file the script writes\
    [file tail $record], which is the same form filled in, locked with /Ff 1\
    throughout and declared PDF/A-3B. It has no reset button, and not by\
    choice: the profile admits no action on a widget annotation at all, so\
    the write is refused as long as the button is on the sheet. The script\
    asks for both, catches the refusal and prints it." {0.35 0.35 0.4}

exampleHeading $doc y "Check it yourself"
exampleCommandBlock $doc y [list \
    "qpdf --check [file tail $target]" \
    "qpdf --json --json-key=acroform [file tail $target]" \
    "verapdf -f 3b [file tail $record]" \
    "java -cp tools/Mustang-CLI-2.25.0.jar tools/formcheck.java [file tail $target]"]

exampleFooter $doc helvetica

$doc write $target
set names [$doc field list]
puts "  written: $target ([file size $target] bytes)"
puts "  [llength $names] fields: [join $names {, }]"
# What two of them say about themselves, read back out of the document rather
# than repeated from the calls above - the same reason the footer asks the
# document for its fonts. The radio group answers ONE field with three
# widgets, which is the line qpdf shows three times.
puts "  the mandate box: [dict get [$doc field state mandate] type],\
    /Ff [dict get [$doc field state mandate] flags]"
puts "  the rate group: [dict get [$doc field state rate] type],\
    /Ff [dict get [$doc field state rate] flags] - one field, three buttons"
$doc destroy

# ---------------------------------------------------------------------------
# The same form as an archived record
# ---------------------------------------------------------------------------

# The record is built TWICE - once with the reset button on it, to be
# refused, and once without - so what sets it up stands in a procedure. Two
# copies of ten lines is how the second one starts drifting from the first,
# and then the refusal would be about a document nobody wrote.
#
# PDF/A refuses a standard face, so the record is set in an embedded one -
# two files, because DejaVu's bold is a face of its own and not a style of
# the regular.
proc applicationRecord {assets} {
    set doc [tclpdf new -unit mm -format a4 -typeArea {20 20}]
    $doc info Title "Application for membership - Erika Mustermann"
    $doc info Author "Friends of Musterstadt City Library"
    $doc info Subject "Admitted on 17 January 2026"
    $doc language en-GB
    $doc page add
    $doc font embed face [file join $assets fonts DejaVuSans.ttf]
    $doc font embed faceBold [file join $assets fonts DejaVuSans-Bold.ttf]
    $doc field default -family face -size 9.5 -color {0 0 0.35}
    return $doc
}

# THE SAME PROCEDURE as the blank form, with the answers in it and every
# field locked - and the reset button still asked for, because the refusal is
# what this half of the example is about.
set doc [applicationRecord $assets]
applicationForm $doc -text {face {}} -head {faceBold {}} \
    -answers $application -reset 1 -locked 1
exampleFooter $doc face
$doc pdfa -part 3 -conformance B -profile $profile \
    -identifier "sRGB IEC61966-2.1"

# The refusal comes at the WRITE, not at the [field button] call: a document
# declares its profile and its fields in either order, so the check can only
# be made when both are known. Measured: the refused write opens no file at
# all, which is why the second attempt below can write to the same name.
puts "  the record, first attempt:"
if {[catch {$doc write $record} message]} {
    exampleConsoleParagraph $message
    puts "  errorCode: $::errorCode"
}
$doc destroy

# Second attempt, one switch different.
set doc [applicationRecord $assets]
set y [applicationForm $doc -text {face {}} -head {faceBold {}} \
    -answers $application -reset 0 -locked 1]
applicationFont $doc {face {}} 8 {0.45 0.45 0.5}
$doc text "Archive copy, PDF/A-3B. Every field is read-only, and the buttons\
    of the sheet are not part of it." \
    -at [list 20 [expr {$y + 6}]] -width 170
$doc pdfa -part 3 -conformance B -profile $profile \
    -identifier "sRGB IEC61966-2.1"
exampleDone $doc $record face
