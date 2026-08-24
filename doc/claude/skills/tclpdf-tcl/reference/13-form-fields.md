# Interactive form fields

Six field types, each a subcommand of `field`: `text`, `check`, `radio`, `button`, `listbox` and `combo`. One call declares one field; the package writes the `/AcroForm`, the widget annotation on the page, and - the piece that decides whether a form is worth anything - the **appearance stream per widget**. `/NeedAppearances` is never written, not even as `false`: it is deprecated in PDF 2.0, the standard says nowhere how a reader is to draw from `/DA`, `/DR`, `/MK` and `/Q`, a reader that is not interactive draws nothing at all, and a widget without an appearance dictionary fails PDF/A in every part. What stands in a *finished* form - one this package wrote, or one somebody filled in and sent back - is read with `::tclpdf::pdf fields`, at the end of this chapter.

## Text fields, and the font a form is set in

```tcl
package require tclpdf

set doc [tclpdf new -unit mm]
$doc page add

# THE /DA OF THE FORM, given ONCE. It is inheritable, it is the fallback for
# every field that names no font of its own, and a form whose fields each name
# their own face looks assembled from parts. Helvetica at 10 points in black
# unless it is set - one of the standard 14, so a document that declares a
# field embeds nothing it did not ask for.
$doc field default -family helvetica -size 10 -color {0 0 0.35}
puts "field default: [$doc field default]"

$doc font -family helvetica -style bold -size 14 -color black
$doc text "Schadensmeldung" -at {20 20}

# The label beside a field is ORDINARY PAGE CONTENT. Marking up a field and
# writing its caption are two calls, exactly as drawing a text and laying a
# link over it are.
proc refRow {doc yName label name args} {
    upvar 1 $yName y
    $doc font -family helvetica -style {} -size 9.5 -color {0.25 0.25 0.3}
    $doc text $label -at [list 20 [expr {$y + 1.5}]]
    # The height comes OUT of the argument list: [option parse] lets the last
    # -rect win, so one passed on would override the y worked out here.
    set height 7
    set rest {}
    foreach {option value} $args {
        if {$option eq "-height"} { set height $value ; continue }
        lappend rest $option $value
    }
    # -rect is {x y w h} from the TOP LEFT corner of the page, in the unit of
    # the document - as "link -at" with "link -size" and "sign -rect" count.
    $doc field text $name -rect [list 60 $y 110 $height] \
        -border {0.55 0.55 0.62} -borderWidth 0.3 -background {0.97 0.97 1} \
        {*}$rest
    set y [expr {$y + $height + 4}]
    return
}

set y 34
refRow $doc y "Name" customer -value "Erika Mustermann" \
    -tooltip "Name der versicherten Person"
refRow $doc y "Vertragsnummer" contract -maxlen 12 -value "V-2026-0815" \
    -tooltip "Twelve characters, as on the policy"
refRow $doc y "Schadenhoehe" amount -align right -value "1.284,50" \
    -tooltip "Amount in euro, right aligned"          ;# /Q 2
refRow $doc y "Hergang" story -height 24 -multiline 1 \
    -value "Am Morgen des 12. Maerz stand das Wasser\nbereits im Keller." \
    -tooltip "What happened"                          ;# \n needs -multiline 1
refRow $doc y "Aktenzeichen" reference -value "AZ 2026/4711" -readonly 1 \
    -tooltip "Assigned by the office, not editable"   ;# /Ff 1
refRow $doc y "Kennwort" secret -password 1 \
    -tooltip "Never stored in the file"               ;# /Ff 8192, and no /V

$doc write [file join $out ref-13-text-fields.pdf]
puts "fields: [join [$doc field list] {, }]"
# What was declared, read back out of the document rather than repeated from
# the calls - name, type, page, rect, tooltip, flags, contents, label and the
# type's own data, without the object numbers.
puts "the password field: /Ff [dict get [$doc field state secret] flags],\
    value \"[dict get [$doc field state secret] data value]\""
$doc destroy
```

`-value` is `/V` and `-default` is `/DV`, what a reset button puts back. **`-password` refuses both**: Table 231 says a PDF processor shall "never store the value of the text field in the PDF file", and `/V` is plain text in a file anyone can open - so the value is refused rather than quietly dropped. `-password` with `-multiline` is refused as well, a field that echoes nothing having no second line to echo it on.

## Check boxes, radio buttons, push buttons

```tcl
set doc [tclpdf new -unit mm]
$doc page add
$doc field default -family helvetica -size 9.5 -color {0 0 0.35}
set box {-border {0.45 0.45 0.55} -borderWidth 0.3 -background {0.97 0.97 1}}

$doc font -family helvetica -style bold -size 12 -color black
$doc text "Beitrittserklaerung" -at {20 20}
$doc font -style {} -size 9 -color {0.25 0.25 0.3}

# A CHECK BOX. -export is the name of the ON state and is what an exported
# form carries as the value of the field, so it is the caller's word: a form
# whose boxes all export "Yes" says nothing about which box it was. "Off" is
# reserved for the off state and is refused as an export value. BOTH states
# are drawn - leaving the off appearance out is what makes the frame of an
# unticked box disappear in a reader.
$doc text "Newsletter per E-Mail" -at {28 24}
$doc field check newsletter -rect {20 21 4.5 4.5} -checked 0 -default 0 \
    -export yes -mark check -tooltip "Revocable at any time" {*}$box

$doc text "SEPA-Lastschriftmandat erteilt" -at {28 31}
$doc field check mandate -rect {20 28 4.5 4.5} -checked 1 -default 0 \
    -export yes -mark cross -required 1 \
    -tooltip "Without it nothing can be collected" {*}$box

# A RADIO SET IS ONE FIELD with a widget per button: 12.7.4.2 says a field
# dictionary without a partial field name of its own "shall not be considered
# a field but simply a Widget annotation", so three buttons are three widgets
# and ONE field - which is why the whole set is declared in one call and why
# [field list] shows it once. The third word of an entry is that BUTTON's
# accessible description; -tooltip describes the set.
$doc text "Beitragssatz" -at {20 41}
$doc field radio rate -buttons {
        {full     {20 44 4.5 4.5} "Full rate, 60 euro"}
        {reduced  {60 44 4.5 4.5} "Reduced rate, 30 euro"}
        {support  {110 44 4.5 4.5} "Supporting member, from 120 euro"}
    } -value support -default full -mark circle \
    -tooltip "The rate under section 4 of the contribution rules" {*}$box
foreach {x caption} {26.5 "Voll" 66.5 "Ermaessigt" 116.5 "Foerdernd"} {
    $doc text $caption -at [list $x 47.5] -size 8.5
}

# A PUSH BUTTON carries no value at all (12.7.5.2.2: "shall not use the V and
# DV entries ... because this type of field retains no permanent value"), so
# -caption is the whole of what it says and is required. -action reset is the
# ONE form action this package writes: purely declarative, no script, no
# server. -fields names the ones it resets and leaves the rest alone.
$doc field button clearAll -rect {20 56 40 8} -caption "Formular leeren" \
    -action reset -size 9 -border {0.45 0.45 0.55} -background {0.90 0.91 0.94} \
    -tooltip "Puts every field back to its default"
$doc field button clearBank -rect {64 56 46 8} -caption "Nur Bankdaten" \
    -action reset -fields {mandate} -size 9 \
    -border {0.45 0.45 0.55} -background {0.90 0.91 0.94} \
    -tooltip "Clears the direct debit section only"

$doc write [file join $out ref-13-buttons.pdf]
puts "one field, three buttons: [llength [dict get [$doc field state rate] widgets]] widgets,\
    /Ff [dict get [$doc field state rate] flags]"
$doc destroy
```

`-mark` is `check`, `cross`, `circle` or `square`, drawn as a **path** rather than set in ZapfDingbats - which would put a font into the file for four vector strokes and tie the mark to one face's glyph repertoire. A circular mark gets a round frame; a dot in a square box is a check box drawn wrong. `-unison` is the RadiosInUnison flag (PDF 1.5) and two buttons under one on-state name are refused without it; `-notoggle` ("exactly one radio button shall be selected at all times") needs `-value`, or the set opens in the one state its own flag forbids.

## Choice fields: the two-word rule, and what lands in /V

```tcl
set doc [tclpdf new -unit mm]
$doc page add
$doc field default -family helvetica -size 9.5 -color {0 0 0.35}
set box {-border {0.55 0.55 0.62} -borderWidth 0.3 -background {0.97 0.97 1}}

# -options IS TABLE 234 IN TCL: an entry of ONE word is an option whose export
# value is the text it shows; an entry of TWO is {export display}. So a
# display text that is itself two words needs a brace pair of its own.
$doc field combo salutation -rect {20 20 40 7} \
    -options {{F Frau} {H Herr} {D {Keine Angabe}}} -value Frau \
    -tooltip "Salutation in correspondence" {*}$box

# /V HOLDS THE DISPLAYED TEXT, NOT THE EXPORT VALUE (12.7.5.4) - the one rule
# form writers get wrong. -value names an option by EITHER of the two, the
# export value first, and what lands in /V is the display text: here "Frau",
# while the member register receives "F".
puts "combo: /V is \"[lindex [dict get [$doc field state salutation] data entries] \
    [lindex [dict get [$doc field state salutation] data selection] 0] 1]\""

# A LIST BOX with more than one selection, and export codes behind the texts
# so the register keeps "help" rather than a sentence that may be reworded.
# -multi is the one option that makes -value read its argument as a LIST:
# everywhere else one value is one option, whole.
$doc field listbox interests -rect {20 32 62 21} -multi 1 \
    -options {{books Lesungen} {kids {Kinder und Jugend}}
              {digital {Digitale Angebote}} {help Ehrenamt}} \
    -value {Lesungen Ehrenamt} -top 0 -highlight {0.6 0.76 0.85} \
    -tooltip "Several at once, with Ctrl or Cmd" {*}$box

# -sort REALLY SORTS. Table 233 addresses bit 20 to the writer in so many
# words: "This flag is intended for use by PDF writers, not by PDF readers.
# PDF readers shall display the options in the order in which they occur in
# the Opt array." So the array is sorted by display text and the flag set
# afterwards; a flag over an unsorted array achieves nothing in any reader.
$doc field listbox country -rect {100 32 62 21} -sort 1 \
    -options {{DE Deutschland} {AT Oesterreich} {CH Schweiz} {BE Belgien}} \
    -value CH -tooltip "Country of residence" {*}$box
puts "sorted: [lmap e [dict get [$doc field state country] data entries] {lindex $e 1}]"

# AN EDITABLE COMBO is the one field that takes a value its options do not
# offer - that is what the Edit flag is for. -spellcheck 0 needs it.
$doc field combo colour -rect {20 60 40 7} -editable 1 -spellcheck 0 \
    -options {red green blue} -value "puce" \
    -tooltip "Colour, or one of your own" {*}$box

# -index NAMES THE SELECTION BY POSITION, counting from zero, and is the way
# out where two options show the same text - /V would name both and neither.
# It cannot stand with -value, nor with -sort, which reorders the array.
$doc field listbox rating -rect {100 60 62 14} -index {1} \
    -options {{1 gut} {2 gut} {3 schlecht}} \
    -tooltip "Two options show the same text; /I says which" {*}$box
puts "ambiguous: /I is needed, selection [dict get [$doc field state rating] data selection]"

$doc write [file join $out ref-13-choice.pdf]
$doc destroy
```

`/I` is written **only where it says something `/V` cannot** - a multiple selection, or two options that show the same text - and left out where it would repeat `/V`. `-multi`, `-top` and `-highlight` are list box options and `-editable` and `-spellcheck` combo box ones; each is refused on the other, an option that exists and does nothing being worse than one that is refused.

## Accessibility costs one call

```tcl
# tagged 1 BEFORE anything is drawn, and that is the whole of what the caller
# does for the fields: every widget gets its own Form structure element, made
# at the call that declares the field - so it stands where the field stands in
# reading order - with the object reference (/OBJR) inside it and
# /StructParent on the annotation pointing back. ONE ELEMENT PER WIDGET, not
# per field: a radio set of three buttons is three Form elements and one
# field (ISO 14289-2, 8.10.1).
set doc [tclpdf new -unit mm]
$doc tagged 1
$doc info Title "Membership application"
$doc language de-DE
$doc page add
$doc font embed body $ttf                    ;# UA: every face embedded
$doc font embed bodyBold $ttfBold
$doc field default -family body -size 10 -color {0 0 0.35}

$doc font -family bodyBold -size 14 -color black
$doc text "Beitrittserklaerung" -at {20 20} -tag H1
$doc font -family body -size 9.5 -color {0.25 0.25 0.3}
$doc text "Name, Vorname" -at {20 33}

# -tooltip IS NOT A TOOLTIP under a UA claim: it is /TU, which ISO 32000-2,
# 14.9.3 makes the name "used in place of the actual field name" - the thing a
# screen reader announces. [ua] refuses a document whose fields have none and
# names them; it does not fill in the field name, because a form announcing
# itself as "iban" and "plz2" is the reason the entry exists.
$doc field text name -rect {60 32 110 7} -tooltip "Name as in the register" \
    -border {0.55 0.55 0.62} -borderWidth 0.3

# -contents describes ONE WIDGET (/Contents on the annotation). A radio set
# takes one per button, as the third word of its -buttons entry: a /TU on a
# field with three widgets describes none of the three (8.10.2.4).
$doc text "Beitragssatz" -at {20 45}
$doc field radio rate -buttons {
        {full    {60 44 4.5 4.5} "Full rate"}
        {reduced {90 44 4.5 4.5} "Reduced rate"}
    } -value full -tooltip "The contribution rate" \
    -border {0.55 0.55 0.62} -borderWidth 0.3

$doc ua 1
$doc write [file join $out ref-13-tagged.pdf]
puts "tagged form written, [llength [$doc field list]] fields"
$doc destroy

# WHAT [ua] REFUSES, measured rather than described: a field with no /TU, and
# a field declared before [tagged 1], whose widget then reached no Form
# element at all. Both are reported when the file is WRITTEN, all at once.
set doc [tclpdf new -unit mm]
$doc tagged 1
$doc info Title "Refused"
$doc language de-DE
$doc page add
$doc font embed body $ttf
$doc field default -family body -size 10
$doc field text silent -rect {20 20 80 7}
$doc ua 1
if {[catch {$doc write [file join $out ref-13-refused.pdf]} message]} {
    puts "ua: $message"
}
$doc destroy
```

`-label {script}` draws the widget's own label into its own `Form` element, as the `Lbl` that ISO 14289-2, 8.10.2.2 puts there - "a direct descendent of a Form structure element that also includes the object reference to the widget annotation". It runs in the caller's scope and before the object reference, the order of `/K` being the reading order. **It needs a PDF 2.0 file** (`ua -part 2` gives one): ISO 32000-1, Table 340 gave a `Form` "only one child: an object reference identifying the widget annotation", and veraPDF still holds a 1.7 file to it. A UA-1 document describes its widgets with `-contents` instead, and a label for a whole radio group is a `structure Lbl` beside the field either way.

```tcl
# A PDF 2.0 document, so that -label may be used at all.
set doc [tclpdf new -unit mm -version 2.0]
$doc tagged 1
$doc info Title "Labelled widget"
$doc language en-GB
$doc page add
$doc font embed body $ttf
$doc field default -family body -size 10

# The script draws the label; the package puts what it drew inside the
# widget's own Form element, as a Lbl, before the object reference.
$doc field text email -rect {60 20 110 7} -tooltip "Address for the invitation" \
    -border {0.55 0.55 0.62} -borderWidth 0.3 -label {
        $doc font -family body -size 9.5 -color {0.25 0.25 0.3}
        $doc text "E-Mail" -at {20 21.5}
    }
$doc write [file join $out ref-13-label.pdf]
$doc destroy

# Below 2.0 the same call is refused, naming the version to raise to.
set doc [tclpdf new -unit mm]
$doc tagged 1
$doc page add
if {[catch {$doc field text email -rect {60 20 110 7} -label {
        $doc text "E-Mail" -at {20 21.5}
    }} message options]} {
    puts "label below 2.0: [dict get $options -errorcode]"
}
$doc destroy
```

## A form under PDF/A, and the one thing that is refused there

```tcl
set doc [tclpdf new -unit mm]
$doc info Title "Beitrittserklaerung, Archivexemplar"
$doc language de-DE
$doc page add

# PDF/A EMBEDS EVERY FONT, the field's included: the /DA names a face and
# [field default] starts at Helvetica, so the archival copy says which face
# its fields are set in. A form of nothing but buttons registers no font at
# all - only a field with VARIABLE TEXT (a text or choice field, 12.7.4.3)
# gets a document-level /DA, which is why a button-only form used to drag
# Helvetica into a document that had asked for no font.
$doc font embed body $ttf
$doc field default -family body -size 9.5 -color {0 0 0.35}
$doc font -family body -size 11 -color black
$doc text "Every field read-only: this is the record, not the form." \
    -at {20 20} -width 170

$doc field text name -rect {20 32 170 7} -value "Erika Mustermann" \
    -readonly 1 -tooltip "As in the register" \
    -border {0.55 0.55 0.62} -borderWidth 0.3
$doc field check mandate -rect {20 44 4.5 4.5} -checked 1 -readonly 1 \
    -export yes -tooltip "Direct debit mandate given" \
    -border {0.55 0.55 0.62} -borderWidth 0.3

$doc pdfa -part 3 -conformance B -profile $iccRgb -identifier "sRGB IEC61966-2.1"
$doc write [file join $out ref-13-pdfa.pdf]
puts "PDF/A-3B form written"
$doc destroy

# THE RESET BUTTON AND PDF/A CANNOT BOTH BE HAD, and the refusal comes at the
# WRITE - a document declares its profile and its fields in either order, so
# the check can only be made once both are known. veraPDF fails such a file on
# two rules at once: 6.3.3-3 ("A Widget annotation dictionary shall not
# contain the A or AA keys") and 6.5.1-1, which names ResetForm among the
# actions forbidden outright. An archived document is a record, and a record
# does not reset itself.
set doc [tclpdf new -unit mm]
$doc info Title "Refused"
$doc page add
$doc font embed body $ttf
$doc field default -family body -size 9.5
$doc field button clear -rect {20 20 40 8} -caption "Leeren" -action reset \
    -family body -tooltip "Clears the form"
$doc pdfa -part 3 -conformance B -profile $iccRgb -identifier "sRGB IEC61966-2.1"
if {[catch {$doc write [file join $out ref-13-pdfa-refused.pdf]} message options]} {
    puts "pdfa + reset: [dict get $options -errorcode]"
}
# The refused write leaves NO file behind, so the same script may drop the
# button and write again to the same name.
puts "file written by the refused write: [file exists [file join $out ref-13-pdfa-refused.pdf]]"
$doc destroy
```

## The refusals worth reading once

```tcl
set doc [tclpdf new -unit mm]
$doc page add
foreach {label script} {
    "a name with a period"      {$doc field text a.b -rect {20 20 80 7}}
    "a name already taken"      {$doc field text twice -rect {20 20 80 7}
                                 $doc field text twice -rect {20 40 80 7}}
    "a value in a password box" {$doc field text pw -rect {20 20 80 7} -password 1 -value secret}
    "a line break, no -multiline" {$doc field text one -rect {20 20 80 7} -value "a\nb"}
    "a value past -maxlen"      {$doc field text short -rect {20 20 80 7} -maxlen 3 -value "abcd"}
    "a rectangle of no area"    {$doc field text flat -rect {20 20 80 0}}
    "-contents on a radio field" {$doc field radio r -buttons {{a {20 20 5 5}}} -contents "x"}
    "an on state called Off"    {$doc field check c -rect {20 20 5 5} -export Off}
    "-notoggle without -value"  {$doc field radio n -buttons {{a {20 20 5 5}}} -notoggle 1}
    "-fields without -action"   {$doc field button b -rect {20 20 40 8} -caption "x" -fields {a}}
    "an option outside the list" {$doc field listbox l -rect {20 20 40 20} -options {a b} -value c}
    "-value with -index"        {$doc field combo m -rect {20 20 40 7} -options {a b} -value a -index {1}}
    "-index with -sort"         {$doc field listbox s -rect {20 20 40 20} -options {a b} -sort 1 -index {0}}
    "two options in unison"     {$doc field radio u -buttons {{a {20 20 5 5}} {a {30 20 5 5}}}}
} {
    if {[catch $script message options]} {
        puts "[format %-30s $label] [dict get $options -errorcode]"
    } else {
        puts "[format %-30s $label] NOT REFUSED"
    }
}
# A REFUSED CALL LEAVES THE DOCUMENT EXACTLY AS IT WAS - no half declared
# field, no object number handed out, no version floor raised. The one name
# below is the FIRST of the two calls that tried to take the same name, which
# went through as it should.
puts "after the refusals the document holds: [$doc field list]"
$doc destroy
```

**Three of the field refusals fall at the write rather than at the call**, and they are the ones that depend on something the call cannot know yet: the page a widget names does not exist, the rectangle lies entirely beside that page, and the PDF/A claim above. A `-rect` is checked for being four numbers a PDF can hold and for having an area at the call; where it *lands* is a question for the page, and the page may be added later.

```tcl
set doc [tclpdf new -unit mm]
$doc page add
# Accepted here: the four numbers are numbers and the field has an area.
$doc field text away -rect {900 20 80 7}
$doc field text later -rect {20 20 80 7} -page 4
if {[catch {$doc write [file join $out ref-13-outside.pdf]} message options]} {
    puts "at the write: [dict get $options -errorcode]"
    puts "             [string range $message 0 120]..."
}
$doc destroy
```

## Reading a form back: what stands in a finished file

The other direction, and it is a **package command** addressed by a path rather than a document method: `::tclpdf::pdf fields` answers what somebody filled in. It is the package's own parser - the one `pdf import` uses - so seeing what a returned application says needs no `qpdf --json --json-key=acroform` and no PDFBox behind a Java runtime.

```tcl
package require tclpdf::importInfo      ;# ::tclpdf::pdf fields

# The form that comes back filled in. It is written here so the chapter has
# one to read; any file with an /AcroForm would do - a tax form, an
# application, a returned questionnaire.
set doc [tclpdf new -unit mm]
$doc info Title "A returned application"
$doc page add
$doc field default -family helvetica -size 10
$doc field text customer -rect {20 30 80 7} -value "Erika Mustermann" \
    -tooltip "As held in the register of members" -required 1
$doc field combo salutation -rect {20 45 40 7} -options {{F Frau} {H Herr}} \
    -value F -tooltip "How we address you in writing"
$doc field listbox interests -rect {20 60 60 20} -multi 1 \
    -options {{books Lesungen} {help Ehrenamt}} -value {books help}
$doc field radio rate -buttons {{full {20 90 5 5}} {reduced {40 90 5 5}}} \
    -value reduced -tooltip "The rate under clause 4"
$doc field check news -rect {20 105 5 5} -checked 1 -export yes
$doc field text member -rect {20 115 40 7} -value "M-2026-0117" -readonly 1
$doc field button clear -rect {20 125 40 8} -caption "Clear" -action reset
$doc write [file join $out ref-13-returned.pdf]
$doc destroy

# ONE DICTIONARY PER FIELD, in the order the file lists them - a parent field
# before the children beneath it - and
# EVERY KEY IS ALWAYS THERE - empty where the file says nothing, so a caller
# never has to ask whether a key exists first.
set fields [::tclpdf::pdf fields [file join $out ref-13-returned.pdf]]
puts "keys: [lsort [dict keys [lindex $fields 0]]]"
# "type" carries THE WORDS OF THE WRITING SIDE - text, check, radio, button,
# listbox, combo, signature - not the raw /FT names Tx, Btn and Ch: what comes
# back as "combo" is what [field combo] wrote. And "flags" is a list of NAMES,
# not the /Ff integer.
foreach field $fields {
    puts [format {%-11s %-8s value %-22s selected %-12s flags %s} \
        [dict get $field name] [dict get $field type] \
        [list [dict get $field value]] [list [dict get $field selected]] \
        [list [dict get $field flags]]]
}
```

`/FT` alone would not give the word: three of those seven are one `/FT` told apart by a bit of `/Ff` (Tables 229 and 233), which is why the flags are read before the type. A `/FT` this package does not build travels in the file's own spelling, and a node that names no type at all - legal for one that only groups names (12.7.4.2) - answers the empty string. `signature` is the one word with no `field` subcommand behind it: such a field is written by `sign`, and what its value claims is answered by `pdf info` under `signatures`.

### The three places a naive reader goes wrong

```tcl
set fields [::tclpdf::pdf fields [file join $out ref-13-returned.pdf]]
proc oneField {fields name} {
    foreach field $fields {
        if {[dict get $field name] eq $name} { return $field }
    }
    error "no field named $name"
}

# 1. /V IS A DIFFERENT DATA TYPE IN EVERY FIELD TYPE. Table 226 says only
# "(various)": a text field holds a string, a check box and a radio set a NAME
# (the on state, or the /Off that 12.7.5.2.3 reserves - it comes back without
# its slash and is what the widget's /AS points at), a choice field the
# DISPLAYED text, a signature field a dictionary, and a push button nothing at
# all - "this type of field retains no permanent value" (12.7.5.2.2).
foreach name {customer news rate salutation clear} {
    set field [oneField $fields $name]
    puts "[format %-11s $name] [format %-8s [dict get $field type]]\
        /V -> [list [dict get $field value]]"
}
# A check box with no /V answers EMPTY rather than "Off" - the file said
# nothing, and "selected" says the same thing without the guess.

# 2. THE EXPORT VALUE OF A CHOICE IS NOT IN /V. It is the first half of the
# matching /Opt entry and stands nowhere else in the field: "options" hands
# out the pairs, "selected" the export values in force - out of /I where the
# file writes one, and by matching /V against the display halves otherwise.
foreach name {salutation interests} {
    set field [oneField $fields $name]
    puts "[format %-11s $name] options [dict get $field options],\
        /V [list [dict get $field value]] -> selected\
        [list [dict get $field selected]]"
}
# A value matching no option travels unchanged: an editable combo box may hold
# whatever its user typed, and that IS the value.

# 3. A FIELD IS NOT A WIDGET, and /T alone tells them apart: "a field
# dictionary that does not have a partial field name (T entry) of its own
# shall not be considered a field but simply a Widget annotation" (12.7.4.2).
# So a radio set is ONE record with several widgets, which may sit on
# different pages, and a node that carries only a name is a record with none.
set rate [oneField $fields rate]
puts "rate: [llength [dict get $rate widgets]] widgets, page(s)\
    [dict get $rate pages], appearance [dict get $rate appearance]"
foreach widget [dict get $rate widgets] {
    # "rect" is the file's own /Rect: PDF units from the BOTTOM LEFT corner of
    # the page, not the top-left -rect the writing side counts in. Nothing
    # here converts - the file is anyone's, and its unit is not this
    # document's. "state" is the widget's /AS.
    puts "  page [dict get $widget page], state [dict get $widget state],\
        rect [dict get $widget rect]"
}
# The pages count from 1, as [pdf pages] counts them - not from 0, as -page
# does on the writing side.
```

`/FT`, `/Ff`, `/V` and `/DV` are **inheritable down `/Kids`** (Table 226) and are read as inherited, a parent naming the type while the kids carry the widgets; the fully qualified `name` is the partial names of the chain joined with periods, and `partial` is the `/T` of the one node. Text comes back as Tcl characters however it was written, PDFDocEncoding or UTF-16BE behind a byte-order mark (7.9.2.2) - which is what a reader filling in a form writes.

### What it refuses, and what is simply empty

```tcl
# A file with no /AcroForm is not an error: it answers the EMPTY LIST.
set plain [tclpdf new -unit mm]
$plain page add
$plain font -family helvetica -size 10
$plain text "no form here" -at {20 20}
$plain write [file join $out ref-13-noform.pdf]
$plain destroy
puts "no form: [list [::tclpdf::pdf fields [file join $out ref-13-noform.pdf]]]"

# AN ENCRYPTED FILE IS REFUSED, as every read but [pdf info] refuses one: a
# field name and a text value are STRINGS, and strings are the one thing every
# security handler encrypts (7.6.2). Measured on a 40-bit RC4 form, /FT, /Ff
# and /AS come through - names and numbers are not encrypted - and every /T
# and /V is binary rubbish. Half an answer with no way to tell which half is
# why the refusal stands.
set locked [tclpdf new -unit mm -version 2.0]      ;# AES-256 is PDF 2.0
# [encrypt] comes right after [tclpdf new]: an object already written would
# stay in the clear, and the document refuses rather than let that happen.
$locked encrypt -user {} -owner secret
$locked page add
$locked field text secret -rect {20 20 80 7} -value "Erika Mustermann"
$locked write [file join $out ref-13-locked.pdf]
$locked destroy
try {
    ::tclpdf::pdf fields [file join $out ref-13-locked.pdf]
    puts "went through, which it should not have"
} trap {TCLPDF IMPORT} {message options} {
    puts "encrypted -> [dict get $options -errorcode]"
}
# [pdf info] answers an encrypted file rather than refusing it - but only out
# of the trailer and the cross reference: "form" and every other key that
# would have to be read out of the catalogue stays EMPTY, "none" being what
# the key holds when nothing was read.
set facts [::tclpdf::pdf info [file join $out ref-13-locked.pdf]]
puts "locked: encrypted [dict get $facts encrypted],\
    [dict get $facts encryption], form [dict get $facts form]"
```

An **XFA** form (Table 224, deprecated in PDF 2.0) is refused as well, with `TCLPDF IMPORT XFA`, unless `-xfa 1` asks for it: its data is an XML stream in a format defined outside ISO 32000, and the `/AcroForm` fields beneath it are a shadow copy that need not agree with it - so the file is refused rather than half answered, and the option says "the shadow copy is what I want". `pdf info` reports `form` as `XFA` either way. This package writes no XFA, so the case only ever arrives with a foreign file.

Measured against two other readers over 65 documents and 703 fields - 56 foreign forms plus this package's own examples: name, type, value, tooltip and the widget count agree with Apache PDFBox on every field but one kind, and that one is deliberate (the missing `/V` above, where PDFBox fills in `Off`). `qpdf --json --json-key=acroform` agrees on name, type and flags and differs in what it **counts**: it enumerates widgets, so a radio set of three buttons is three rows there and one record here, and it omits a field that has no widget.

## What to know before promising anything

- **`-rect` is `{x y w h}` from the top left corner**, in the document unit, and `-page` counts from 0 as `page current` counts. The page need not exist yet; it has to exist at the write. A rectangle sticking out over the edge is allowed, one entirely beside the page is refused *at the write* - that is where a *y* counted from the bottom, and millimetres on a document set in points, show up.
- **The name is the partial field name** (`/T`): no period in it, unique in the document, and unique against `sign -field` too. It is what an exported form, a script in a reader and a filled document address the field by, so it is yours to choose.
- **`field default` is the form's `/DA`**, and it is inheritable - set it once rather than per field. A field's font is settled at the call, not at the write, so the appearance and the `/DA` cannot disagree; naming the font also registers it in `/DR`, and a `/DA` naming a font `/DR` does not have passes `qpdf --check` without a word and draws as nothing.
- **`-size 0` is refused.** It is legal PDF and means auto-size, which a package that draws the appearance itself cannot predict a reader's redrawing of.
- **A choice field's `/V` is the displayed text**, never the export value; `/I` appears only where `/V` cannot say which option is meant. `-options` counts words: one is display-and-export, two are `{export display}`.
- **A radio set is one field.** `field list` shows it once, `field state` answers `widgets` with one entry per button, and each button's description is the third word of its `-buttons` entry - `-contents` and `-label` are refused on it.
- **The reset action is the only form action written.** Submit needs a server, import-data a reader's file dialogue, and an ECMAScript action has its effects defined in ISO/DIS 21757-1 rather than in the PDF standard - so calculated fields do not exist here: compute the value in the script and write it as `-value`.
- **Reading a form back is `::tclpdf::pdf fields`**, a package command taking a path rather than a document method, from the module `tclpdf::importInfo`: one dictionary per field, every key always there, `type` in the same words `field` takes (plus `signature`), `flags` as a list of names rather than the `/Ff` integer, `selected` as the export values in force, `widgets` one entry per annotation with the file's own `/Rect`. A file with no `/AcroForm` answers the empty list; an encrypted file and an XFA form without `-xfa 1` are refused with `TCLPDF IMPORT`.
- **Not built, and named rather than half written**: XFA (and `/DS`, `/RV`, RichText), ECMAScript and calculated fields, submit-form and import-data, the icon entries of Table 192, and `/NeedAppearances`.
- **`trap {TCLPDF FIELD}`** catches every field refusal that carries a code (a misspelt option *name* comes from the shared option parser and carries none, here as everywhere); the button types put their word after `TCLPDF FIELD BUTTON`. Most of them fall at the call and leave nothing behind; three fall at the **write** - `TCLPDF FIELD PAGE` for a page that never came, `TCLPDF FIELD RECT OUTSIDE` for a widget entirely beside its page, and `TCLPDF FIELD BUTTON PDFA` - and a refused write leaves no file. A version floor answers `TCLPDF VERSION` with the version to raise the document to.
