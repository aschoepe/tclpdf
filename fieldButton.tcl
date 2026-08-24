#
# tclpdf - PDF generation for Tcl
#
# fieldButton - the three button field types (ISO 32000-2, 12.7.5.2)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Usage:
#
#   $doc field check paid   -rect {20 40 5 5} -checked 1
#   $doc field radio ship   -buttons {{air {20 60 5 5} "By air freight"}
#                                      {sea {20 70 5 5} "By sea freight"}} \
#       -value air
#   $doc field button clear -rect {150 260 30 8} -caption "Clear" \
#       -action reset
#
# WHAT THIS FILE IS. One topic - the button field of 12.7.5.2 - in its three
# shapes. They are one topic because they are one /FT: "For button fields,
# bits 15, 16, 17, and 26 shall indicate the intended behaviour of the button
# field" (12.7.5.2.1). Check box, radio button and push button differ in /Ff
# and in nothing else that a reader looks at first, so splitting them over
# three files would be three copies of the same flag table, the same frame,
# the same /MK and the same refusals.
#
#   check box    Pushbutton clear, Radio clear
#   radio button Radio set, Pushbutton clear, optionally NoToggleToOff
#                and RadiosInUnison
#   push button  Pushbutton set - and by 12.7.5.2.2 no /V and no /DV,
#                "because this type of field retains no permanent value"
#
# THE VALUE OF A BUTTON IS A NAME, NOT A STRING. 12.7.5.2.3: "The V entry ...
# holds a name object representing the check box's appearance state, which
# shall be used to select the appropriate appearance from the appearance
# dictionary. The value of the V key shall also be the value of the AS key.
# If they are not equal, then the value of the AS key shall be used instead
# of the V key to determine which appearance to use." So /V and /AS are
# written from ONE source here and can never drift apart, and the off state
# is /Off - the one name the standard reserves.
#
# BOTH STATES ARE DRAWN, ALWAYS. /AP /N of a check box or a radio button is a
# SUBDICTIONARY with one entry per state (12.5.5, Table 170), and where it is
# one, /AS is required by Table 166. The off entry is optional by the letter
# of 12.7.5.2.3 - and leaving it out is what makes the frame of an unticked
# box disappear, because "PDF processors shall also attempt to provide
# reasonable behaviour (such as displaying nothing) if an annotation's AS
# entry designates an appearance state for which no appearance is defined"
# (12.5.5), and displaying nothing is exactly what happens. Both states are
# written, so nothing is ever regenerated: a reader toggling a check box
# switches /AS between two streams that are already in the file. That is also
# why /MK carries no /CA here - see [FieldButtonCharacteristics].
#
# THE MARK IS DRAWN, NOT SET IN ZAPFDINGBATS. The examples in 12.7.5.2.3 and
# 12.7.5.2.4 draw the tick and the dot with "/ZaDb 12 Tf" and the characters
# (4) and (8). Nothing requires it, and doing it would put a font into the
# file for four vector strokes, tie the mark to the glyph repertoire of one
# face, and make a check box depend on the text topic. The four marks are
# paths - and -mark square and -mark cross are then no harder than -mark
# check.
#
# WHAT IS DELIBERATELY NOT BUILT. Of the form actions (12.7.6) the push
# button takes ONE: the reset action (12.7.6.3), which is purely declarative
# - it puts /V back to /DV and removes /V where there is no /DV - and needs
# no script and no server. The submit action (12.7.6.2) needs a server, the
# import action (12.7.6.4) needs a reader's file dialogue and reads a format
# this package does not write, and an ECMAScript action (12.6.4.17) has its
# contents and effects defined in ISO/DIS 21757-1 rather than in the PDF
# standard - there is no tool on this machine that could measure whether one
# of the three does what it claims. Also not built, and for the same reason
# as in field.tcl: the icon entries of Table 192 (/I, /RI, /IX, /IF, /TP) and
# the rollover and down captions /RC and /AC - a push button that shows a
# different face while the mouse is over it is a state no validator inspects.
#
# ALL THREE GO THROUGH THE CONTRACT OF field.tcl, and the radio field is why
# point 3 of it has a second shape. 12.7.5.2.4 puts the buttons of a set in
# "an array of widget annotations" under /Kids of ONE field, and 12.7.4.2 is
# why they cannot be fields of their own: "A field dictionary that does not
# have a partial field name (T entry) of its own shall not be considered a
# field but simply a Widget annotation" - a set of four radio buttons is four
# widgets and one field, and no merged object can say that. So the radio
# field declares itself with -widgets and -kid: the core reserves the parent
# and every button, writes the field object and the annotations, puts each
# button on the page it names, and this module answers only the pairs -
# [FieldRadioBuild] for the field, [FieldRadioKid] for one button.
#
# It was built the other way first - the seam sign.tcl travels, where a module
# assembles its own objects and hands the parent to [FieldEnlist] - and the
# price is worth recording, because it is what the second shape of point 3
# bought back: the page check and the entry in the page's /Annots stood here
# a second time, copied out of [FieldWrite]; a radio field appeared in
# neither "$doc field list" nor "$doc field state", because the core had
# never heard of it; and the refusal of a name already taken worked in one
# direction only - "text" then "radio" was caught by [FieldTaken], "radio"
# then "text" was not, because the core could not see this module's table.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::color 1.0-
package require tclpdf::geometry 1.0-
package require tclpdf::document 1.0-
package require tclpdf::field 1.0-

::tclpdf::field::register check tclpdf::fieldButton
::tclpdf::field::register radio tclpdf::fieldButton
::tclpdf::field::register button tclpdf::fieldButton

namespace eval ::tclpdf::fieldButton {
  namespace export {[a-z]*}
  namespace ensemble create

  # The name the off state is stored under, and the one export name a button
  # may not use for an on state: 12.7.5.2.3, "The appearance for the off
  # state is optional but, if present, shall be stored in the appearance
  # dictionary under the name Off."
  variable off Off

  # The marks a check box or a radio button can show. Paths, not glyphs -
  # see the head of this file.
  variable marks {check cross circle square}
}

oo::define ::tclpdf::document::document {

  # -- the check box --------------------------------------------------------

  # $doc field check <name> -rect {x y w h}
  #     ?-page n? ?-checked 0|1? ?-default 0|1? ?-export name?
  #     ?-mark check|cross|circle|square? ?-markSize n? ?-color c?
  #     ?-border c? ?-borderWidth n? ?-background c?
  #     ?-readonly 0|1? ?-required 0|1? ?-noexport 0|1? ?-tooltip text?
  #
  # -rect counts {x y w h} from the TOP left corner of the page in the unit
  # of the document, exactly as "field text -rect" and "link -at" count.
  #
  # -export is the name of the ON state (12.7.5.2.3 uses /Yes in its
  # example). It is what an exported form carries as the value of the field,
  # so it is the caller's word: a form whose boxes all export "Yes" says
  # nothing about which box it was.
  method FieldCheck {name args} {
    set options [::tclpdf::option parse {
      rect {} page {} checked 0 default {} export Yes
      mark check markSize {} color black
      border black borderWidth 0.4 background {}
      readonly 0 required 0 noexport 0 tooltip {} contents {} label {}
    } $args "field check"]

    # EVERYTHING is checked before the field is declared - the rule field.tcl,
    # sign.tcl and encrypt.tcl all follow: a refused call leaves the document
    # exactly as it was, so a second attempt does not trip over the leavings
    # of the first.
    set options [my FieldButtonBooleans $options {checked readonly required
        noexport} "field check"]
    set options [my FieldButtonCommon $options "field check \"$name\""]
    set export [my FieldButtonExport [dict get $options export] \
        "-export of field check \"$name\""]
    set default [dict get $options default]
    if {$default ne {}} {
      if {![string is boolean -strict $default]} {
        return -code error -errorcode {TCLPDF FIELD BUTTON BOOLEAN default} \
            "tclpdf: -default of field check is a boolean - the state the\
            reset action of ISO 32000-2, 12.7.6.3 puts the box back into -\
            not \"$default\". Leave it out for a box that has no /DV"
      }
      set default [expr {$default ? $export : $::tclpdf::fieldButton::off}]
    }

    my FieldDeclare $name -type Btn -build FieldCheckBuild \
        -rect [dict get $options rect] -page [dict get $options page] \
        -tooltip [dict get $options tooltip] \
        -contents [dict get $options contents] \
        -label [dict get $options label] \
        -flags [::tclpdf::field flags [my FieldButtonFlagNames $options {}]] \
        -data [dict merge $options [dict create \
            export $export default $default \
            state [expr {[dict get $options checked]
                ? $export : $::tclpdf::fieldButton::off}]]]
    return $name
  }

  # The pairs of ONE check box, at write time. Point 4 of the contract in
  # field.tcl: the type's own keys and nothing the core writes.
  method FieldCheckBuild {name record} {
    set data [dict get $record data]
    set state [dict get $data state]
    # /V and /AS out of ONE value. 12.7.5.2.3: "The value of the V key shall
    # also be the value of the AS key. If they are not equal, then the value
    # of the AS key shall be used instead of the V key" - a reader that
    # silently prefers one of two disagreeing keys is a reader nobody can
    # debug, so the two cannot disagree here.
    set pairs [list FT /Btn \
        V [::tclpdf::pdfObj name $state] \
        AS [::tclpdf::pdfObj name $state]]
    if {[dict get $data default] ne {}} {
      lappend pairs DV [::tclpdf::pdfObj name [dict get $data default]]
    }
    lappend pairs {*}[my FieldButtonCharacteristics $data]
    lappend pairs AP [my FieldButtonStates $record N \
        [my FieldButtonTwoStates [dict get $data export]]]
    return $pairs
  }

  # -- the radio button -----------------------------------------------------

  # $doc field radio <name> -buttons {{value {x y w h} ?description?} ...}
  #     ?-page n? ?-value name? ?-default name?
  #     ?-unison 0|1? ?-notoggle 0|1?
  #     ?-mark check|cross|circle|square? ?-markSize n? ?-color c?
  #     ?-border c? ?-borderWidth n? ?-background c?
  #     ?-readonly 0|1? ?-required 0|1? ?-noexport 0|1? ?-tooltip text?
  #
  # -buttons is the whole set: one {value {x y w h} ?description?} entry per
  # button, in the order they are to stand in /Kids. The value is the name of
  # that button's ON state and what an exported form carries when it is the
  # one selected; the rectangle counts from the top left corner of the page
  # like every other -rect in this package.
  #
  # The third word is the one thing PDF/UA needs and no other field type has
  # to give: the description of THAT BUTTON, written as /Contents on its
  # widget annotation. -tooltip describes the set - "How shall we ship it" -
  # and ISO 14289-2, 8.10.2.4 says that a /TU on a field with several widgets
  # "is often insufficient ... thus, a label, a Contents entry, or both,
  # shall be present for each annotation", which is exactly the case here:
  # one description for four buttons tells a listener nothing about which one
  # is which. The export value will not do it either - 8.10.3.2.3 NOTE:
  # "Export values are intended for processing and are not intended to be
  # descriptive." Left out where nothing is claimed; [$doc ua] refuses the
  # claim and names the button that has none.
  #
  # It is called -buttons rather than -options because "options" in this
  # package means the -name value pairs of a call, in every error message
  # option.tcl produces - and because 12.7.5.2.4 calls them buttons: "an
  # array of widget annotations representing the individual buttons in the
  # set".
  method FieldRadio {name args} {
    set options [::tclpdf::option parse {
      buttons {} page {} value {} default {} unison 0 notoggle 0
      mark circle markSize {} color black
      border black borderWidth 0.4 background {}
      readonly 0 required 0 noexport 0 tooltip {} contents {} label {}
    } $args "field radio"]

    set options [my FieldButtonBooleans $options {unison notoggle readonly
        required noexport} "field radio"]
    set options [my FieldButtonCommon $options "field radio \"$name\""]
    # -contents describes ONE widget and a radio field is the whole set, so
    # there is one per button and it is the third word of -buttons. The
    # option is taken all the same rather than left to fall through as an
    # unknown one: every other field type has it, and "unknown option" would
    # be a true sentence about the wrong thing.
    if {[dict get $options contents] ne {}} {
      return -code error -errorcode {TCLPDF FIELD BUTTON CONTENTS} \
          "tclpdf: field radio \"$name\" takes no -contents - the description\
          belongs to ONE button and a radio field is the whole set (ISO\
          32000-2, 12.7.5.2.4), so it is the third word of that button's entry\
          in -buttons: {value {x y w h} description}. -tooltip describes the\
          set itself"
    }

    # The name has to be free before anything else is settled. [FieldDeclare]
    # asks the same question again at the end of this method and is the one
    # that counts - a radio field stands in the core's own table like every
    # other, so "text" then "radio" and "radio" then "text" are refused alike.
    # It is asked HERE as well because the version floor for -unison is raised
    # further down, and a call that is going to be refused must not have
    # raised it: a refused call leaves the document exactly as it was.
    my FieldTaken $name

    set buttons [dict get $options buttons]
    if {![llength $buttons]} {
      return -code error -errorcode {TCLPDF FIELD BUTTON BUTTONS} \
          "tclpdf: field radio \"$name\" needs -buttons {{value {x y w h}}\
          ...} - a radio field is the SET (ISO 32000-2, 12.7.5.2.4: /Kids\
          \"holds an array of widget annotations representing the individual\
          buttons\"), so the whole set is declared in one call. A single\
          switch that is on or off is \"field check\""
    }
    set seen {}
    set checked {}
    foreach button $buttons {
      if {[llength $button] < 2 || [llength $button] > 3} {
        return -code error -errorcode [list TCLPDF FIELD BUTTON BUTTONS $button] \
            "tclpdf: each entry of -buttons of field radio \"$name\" is\
            {value {x y w h} ?description?} - the name of that button's on\
            state, where it sits and what it is called for someone who cannot\
            see it - not \"$button\""
      }
      lassign $button value rect description
      set value [my FieldButtonExport $value \
          "the value \"$value\" in -buttons of field radio \"$name\""]
      # Two buttons under one on-state name is not a mistake by itself - it
      # is what RadiosInUnison is for (Table 229, PDF 1.5: "a group of radio
      # buttons within a radio button field that use the same value for the
      # on state will turn on and off in unison"). Without the flag it is a
      # set in which two buttons light up together and nothing says why.
      if {[dict exists $seen $value] && ![dict get $options unison]} {
        return -code error -errorcode [list TCLPDF FIELD BUTTON UNISON $value] \
            "tclpdf: two buttons of field radio \"$name\" carry the on-state\
            name \"$value\", and -unison is not set - ISO 32000-2, Table 229\
            makes buttons sharing an on-state name switch together only when\
            RadiosInUnison is set, so without it they are two buttons a\
            reader turns on at once for no stated reason. Pass -unison 1, or\
            give the second button its own name"
      }
      dict set seen $value 1
      lappend checked [list $value [my FieldRectCheck $name $rect] $description]
    }
    foreach which {value default} {
      set wanted [dict get $options $which]
      if {$wanted eq {} || $wanted eq $::tclpdf::fieldButton::off} continue
      if {![dict exists $seen $wanted]} {
        return -code error -errorcode \
            [list TCLPDF FIELD BUTTON VALUE $which $wanted] \
            "tclpdf: -$which of field radio \"$name\" is \"$wanted\" and no\
            button of the set carries that on-state name - known are:\
            [join [dict keys $seen] {, }]. /V of a radio field is \"a name\
            object corresponding to the appearance state of whichever child\
            field is currently in the on state\" (ISO 32000-2, 12.7.5.2.4),\
            so a value no button answers to selects nothing"
      }
    }
    # Table 229 on NoToggleToOff: "(Radio buttons only) If set, exactly one
    # radio button shall be selected at all times." A set written with the
    # flag and nothing selected opens in the one state the flag says cannot
    # exist - and no reader will let the user out of it, because the way out
    # is the click that turns a button off.
    if {[dict get $options notoggle] && [dict get $options value] eq {}} {
      return -code error -errorcode {TCLPDF FIELD BUTTON NOTOGGLE} \
          "tclpdf: field radio \"$name\" is -notoggle 1 and has no -value -\
          ISO 32000-2, Table 229 says of NoToggleToOff that \"exactly one\
          radio button shall be selected at all times\", so a set that starts\
          with none selected starts in a state its own flag forbids. Pass\
          -value, or drop -notoggle"
    }
    # NoToggleToOff without Radio is a bit Table 229 does not define - it is
    # marked "(Radio buttons only)" - and this field always sets Radio, so
    # the pair can never come apart here. RadiosInUnison is PDF 1.5 and says
    # so; the version floor is raised where it is asked for and nowhere else.
    # The floor of 1.2 that every form field has is [FieldDeclare]'s.
    if {[dict get $options unison]} {
      my RequireVersion 1.5 "the RadiosInUnison flag of a radio button field"
    }

    set flagNames [my FieldButtonFlagNames $options Radio]
    if {[dict get $options notoggle]} {
      lappend flagNames NoToggleToOff
    }
    if {[dict get $options unison]} {
      lappend flagNames RadiosInUnison
    }
    # ONE field, N widgets - point 3 of the contract at the head of field.tcl,
    # in its second shape. Each entry of -widgets is {rect page data}: the
    # button's rectangle, the field's page (empty, so the core takes -page)
    # and the one thing that is the BUTTON's rather than the set's, its
    # on-state name.
    my FieldDeclare $name -type Btn \
        -build FieldRadioBuild -kid FieldRadioKid \
        -widgets [lmap button $checked {
          lassign $button value rect
          list $rect {} [dict create value $value]
        }] \
        -contents [lmap button $checked {lindex $button 2}] \
        -page [dict get $options page] \
        -tooltip [dict get $options tooltip] \
        -label [dict get $options label] \
        -flags [::tclpdf::field flags $flagNames] \
        -data [dict merge $options [dict create \
            buttons $checked \
            state [expr {[dict get $options value] eq {}
                ? $::tclpdf::fieldButton::off : [dict get $options value]}]]]
    return $name
  }

  # The pairs of the radio FIELD - the parent of 12.7.5.2.4, which carries
  # /FT, /T, /V, /Ff and /Kids and not one annotation key. /T, /Ff and /Kids
  # are the core's; what is left is these.
  method FieldRadioBuild {name record} {
    set data [dict get $record data]
    # /V is "a name object corresponding to the appearance state of whichever
    # child field is currently in the on state" (12.7.5.2.4) - the SET's
    # value, on the set's object, and the kids answer /AS to it.
    set pairs [list FT /Btn V [::tclpdf::pdfObj name [dict get $data state]]]
    if {[dict get $data default] ne {}} {
      lappend pairs DV [::tclpdf::pdfObj name [dict get $data default]]
    }
    return $pairs
  }

  # The pairs of ONE button of the set. A KID CARRIES NO /T - 12.7.4.2: "A
  # field dictionary that does not have a partial field name (T entry) of its
  # own shall not be considered a field but simply a Widget annotation",
  # which is exactly what these are, and giving each button a /T would turn
  # one radio field into four fields that all believe they are the set. The
  # core writes /Type, /Subtype, /Rect, /F, /P and /Parent; the /T it does
  # NOT write here is the whole point of the shape.
  method FieldRadioKid {name record} {
    set data [dict get $record data]
    set value [dict get $record entry value]
    # /AS says which appearance THIS button shows, and only the one whose
    # on-state name is the set's /V shows it (12.7.5.2.4).
    set state [expr {$value eq [dict get $data state]
        ? $value : $::tclpdf::fieldButton::off}]
    set pairs [list AS [::tclpdf::pdfObj name $state]]
    lappend pairs {*}[my FieldButtonCharacteristics $data]
    # The slot is the button's index, so two buttons of one set never reserve
    # the same appearance object.
    lappend pairs AP [my FieldButtonStates $record [dict get $record index] \
        [my FieldButtonTwoStates $value]]
    return $pairs
  }

  # -- the push button ------------------------------------------------------

  # $doc field button <name> -rect {x y w h} -caption text
  #     ?-page n? ?-action reset? ?-fields {name ...}?
  #     ?-family f? ?-style s? ?-size n? ?-color c?
  #     ?-border c? ?-borderWidth n? ?-background c?
  #     ?-readonly 0|1? ?-tooltip text?
  #
  # No -checked, no -value, no -default: 12.7.5.2.2 says of a push button
  # that it "shall not use the V and DV entries in the field dictionary",
  # "because this type of field retains no permanent value". And no -required
  # and no -noexport either - both of Table 227 speak about a value the field
  # does not have.
  #
  # -family, -style, -size and -color are the CAPTION's font and are named as
  # "field text" names them, because they mean the same thing there.
  method FieldButton {name args} {
    set options [::tclpdf::option parse {
      rect {} page {} caption {} action {} fields {}
      family {} style {} size {} color {}
      border black borderWidth 0.4 background {}
      readonly 0 tooltip {} contents {} label {}
    } $args "field button"]

    set options [my FieldButtonBooleans $options readonly "field button"]
    # The push button has no mark: the two keys the shared check reads are
    # filled with what a push button behaves like - a rectangular frame.
    set options [my FieldButtonCommon \
        [dict merge $options {mark square markSize {}}] \
        "field button \"$name\""]
    if {[dict get $options caption] eq {}} {
      return -code error -errorcode {TCLPDF FIELD BUTTON CAPTION} \
          "tclpdf: field button \"$name\" needs -caption - a push button\
          carries no value (ISO 32000-2, 12.7.5.2.2), so its caption is the\
          only thing that says what it does. Pass -caption \"...\""
    }
    if {[string first \n [dict get $options caption]] >= 0} {
      return -code error -errorcode {TCLPDF FIELD BUTTON CAPTION} \
          "tclpdf: -caption of field button \"$name\" holds a line break -\
          /MK /CA is one text string (ISO 32000-2, Table 192) and a push\
          button shows one line. Take the break out"
    }
    if {[dict get $options action] ni {{} reset}} {
      return -code error -errorcode \
          [list TCLPDF FIELD BUTTON ACTION [dict get $options action]] \
          "tclpdf: -action of field button is \"reset\" or nothing, not\
          \"[dict get $options action]\" - the reset action (ISO 32000-2,\
          12.7.6.3) is the one form action that is purely declarative. The\
          submit action needs a server, the import action a reader's file\
          dialogue, and an ECMAScript action has its effects defined in\
          ISO/DIS 21757-1 rather than in the PDF standard; none of the three\
          can be measured here, so none is built. Leave -action out for a\
          button that only looks like one"
    }
    if {[llength [dict get $options fields]] && [dict get $options action] eq {}} {
      return -code error -errorcode {TCLPDF FIELD BUTTON FIELDS} \
          "tclpdf: -fields of field button \"$name\" names the fields the\
          reset action puts back (ISO 32000-2, Table 242), and -action is not\
          set - so there is no action for the list to belong to. Pass -action\
          reset, or drop -fields"
    }
    foreach which [dict get $options fields] {
      if {$which eq {} || [string first . $which] >= 0} {
        return -code error -errorcode [list TCLPDF FIELD BUTTON FIELDS $which] \
            "tclpdf: \"$which\" is not a field name -fields of field button\
            \"$name\" can hold: a partial field name holds no period (ISO\
            32000-2, 12.7.4.2) and is not empty"
      }
    }
    # The caption's font, settled HERE. [FieldFont] refuses a family that
    # does not resolve, registers the resource so the appearance stream and
    # the /DA name the same thing, and hands back both halves - the same
    # reason field.tcl gives for doing it at the declaration rather than at
    # the write: at write time the document's text state is whatever the last
    # [font] call left behind.
    set font [my FieldFont [dict get $options family] \
        [dict get $options style] [dict get $options size] \
        [dict get $options color] "field button \"$name\""]

    my FieldDeclare $name -type Btn -build FieldButtonBuild \
        -rect [dict get $options rect] -page [dict get $options page] \
        -tooltip [dict get $options tooltip] \
        -contents [dict get $options contents] \
        -label [dict get $options label] \
        -flags [::tclpdf::field flags \
            [my FieldButtonFlagNames $options Pushbutton]] \
        -data [dict merge $options [dict create \
            da [dict get $font da] size [dict get $font size] \
            family [dict get $font family] style [dict get $font style] \
            color [dict get $font colour]]]
    return $name
  }

  # The pairs of ONE push button, at write time.
  method FieldButtonBuild {name record} {
    set data [dict get $record data]
    # No /V and no /DV - 12.7.5.2.2. /DA is written because /MK /CA is: the
    # caption is drawn here, but a reader that builds a dynamic appearance of
    # its own reads the caption out of /MK and needs a font for it, and a /DA
    # naming a font /DR does not have is the silent break field.tcl describes.
    set pairs [list FT /Btn DA [my Str [dict get $data da]]]
    lappend pairs {*}[my FieldButtonCharacteristics $data]
    # /AP /N IS A SUBDICTIONARY HERE TOO, although a push button has exactly
    # one appearance and 12.5.5 would take the stream directly. PDF/A does
    # not: measured 2026-08-23, veraPDF fails rule 6.4.1-1 over a push button
    # whose /N is a stream - "If an annotation dictionary's Subtype key has a
    # value of Widget and its FT key has a value of Btn, the value of the N
    # key shall be an appearance subdictionary". A subdictionary with one
    # entry is valid PDF for every reader and conforming for the profile, so
    # it is written that way always rather than in two shapes depending on
    # what the document claims. The one entry is /Off because a push button
    # has no on state to file it under, and /AS goes with it: Table 166 makes
    # /AS required wherever /N is a subdictionary.
    lappend pairs AS [::tclpdf::pdfObj name $::tclpdf::fieldButton::off]
    lappend pairs AP [my FieldButtonStates $record N \
        [list [list $::tclpdf::fieldButton::off 1]]]
    if {[dict get $data action] eq "reset"} {
      # PDF/A AND AN ACTION DO NOT GO TOGETHER, and the file would say so
      # only at the validator. Measured 2026-08-23, veraPDF fails a PDF/A-3B
      # file carrying this button on TWO rules at once: 6.5.1-1, "The Launch,
      # Sound, Movie, ResetForm, ImportData, Hide, SetOCGState, Rendition,
      # Trans, GoTo3DView and JavaScript actions shall not be permitted", and
      # 6.3.3-3, "A Widget annotation dictionary shall not contain the A or
      # AA keys". Refused here, at the write, because a document declares
      # PDF/A and its fields in either order.
      if {[my state pdfa] ne {}} {
        return -code error -errorcode [list TCLPDF FIELD BUTTON PDFA $name] \
            "tclpdf: field button \"$name\" carries the reset action and this\
            document claims PDF/A-[dict get [my state pdfa] part][dict get \
            [my state pdfa] conformance] - the profile admits no action on a\
            widget at all (veraPDF 6.3.3-3, \"A Widget annotation dictionary\
            shall not contain the A or AA keys\") and names ResetForm among\
            the actions it forbids outright (veraPDF 6.5.1-1). An archived\
            document is a record, and a record does not reset itself. Drop\
            -action, or drop the pdfa declaration"
      }
      # Table 241/242. /Flags is left out: bit 1 clear means "the Fields
      # array specifies which fields to reset", which is what -fields says,
      # and a key that may only ever hold its own default is one to leave out.
      set action [list Type /Action S /ResetForm]
      if {[llength [dict get $data fields]]} {
        lappend action Fields [::tclpdf::pdfObj arr [lmap which \
            [dict get $data fields] {my Str $which}]]
      }
      lappend pairs A [::tclpdf::pdfObj dictionary $action]
    }
    return $pairs
  }

  # -- what the three have in common ----------------------------------------

  # The booleans of one call, checked and normalised to 0 or 1.
  method FieldButtonBooleans {options names what} {
    foreach flag $names {
      set value [dict get $options $flag]
      if {![string is boolean -strict $value]} {
        return -code error -errorcode [list TCLPDF FIELD BUTTON BOOLEAN $flag] \
            "tclpdf: -$flag of $what is a boolean, not \"$value\""
      }
      dict set options $flag [expr {$value ? 1 : 0}]
    }
    return $options
  }

  # The frame, the mark and the colours - the options every button type has,
  # checked at the call that gave them rather than inside an appearance
  # stream at write time that nobody is looking at.
  method FieldButtonCommon {options what} {
    variable ::tclpdf::fieldButton::marks
    if {[dict get $options mark] ni $marks} {
      return -code error -errorcode \
          [list TCLPDF FIELD BUTTON MARK [dict get $options mark]] \
          "tclpdf: -mark of $what is [join $marks {, }] - not\
          \"[dict get $options mark]\". It is the shape drawn inside the box,\
          and it is drawn as a path rather than set in ZapfDingbats, so the\
          four are all there is"
    }
    set markSize [dict get $options markSize]
    if {$markSize ne {}
        && (![string is double -strict $markSize] || $markSize <= 0)} {
      return -code error -errorcode [list TCLPDF FIELD BUTTON MARKSIZE $markSize] \
          "tclpdf: -markSize of $what is the size of the mark in the unit of\
          the document and is above zero, not \"$markSize\". Leave it out for\
          a mark that fits itself to the box"
    }
    set borderWidth [dict get $options borderWidth]
    if {![string is double -strict $borderWidth] || $borderWidth < 0} {
      return -code error -errorcode \
          [list TCLPDF FIELD BUTTON BORDERWIDTH $borderWidth] \
          "tclpdf: -borderWidth of $what is a line width of 0 or more in the\
          unit of the document, not \"$borderWidth\". Use 0 for a field with\
          no frame"
    }
    foreach which {color border background} {
      if {![dict exists $options $which] || [dict get $options $which] eq {}} continue
      if {[catch {::tclpdf::color parse [dict get $options $which]} parsed]} {
        return -code error -errorcode [list TCLPDF FIELD BUTTON COLOUR $which] \
            "tclpdf: -$which of $what is not a colour this package reads:\
            $parsed"
      }
    }
    return $options
  }

  # An on-state name, checked. /Off is the one name reserved (12.7.5.2.3) and
  # an empty one would be the name "/" - a name a reader can hold and nobody
  # can type into an FDF.
  method FieldButtonExport {value what} {
    if {$value eq {}} {
      return -code error -errorcode {TCLPDF FIELD BUTTON EXPORT} \
          "tclpdf: $what is empty - the on state of a button is a name object\
          (ISO 32000-2, 12.7.5.2.3) and it is what an exported form carries\
          as the value of the field. Name it, /Yes for want of anything\
          better"
    }
    if {$value eq $::tclpdf::fieldButton::off} {
      return -code error -errorcode [list TCLPDF FIELD BUTTON EXPORT $value] \
          "tclpdf: $what is \"$::tclpdf::fieldButton::off\", and that name is\
          the OFF state - ISO 32000-2, 12.7.5.2.3 stores the off appearance\
          \"under the name Off\", so a button whose on state is called Off is\
          a button that is on and off at once. Choose another name"
    }
    if {[catch {::tclpdf::pdfObj name $value} message]} {
      return -code error -errorcode [list TCLPDF FIELD BUTTON EXPORT $value] \
          "tclpdf: $what has no PDF spelling: $message"
    }
    return $value
  }

  # The /Ff flag NAMES of a call: the three of Table 227 that every field
  # type has, plus the one that says which button this is.
  method FieldButtonFlagNames {options subtype} {
    set names {}
    foreach {flag flagName} {readonly ReadOnly required Required
        noexport NoExport} {
      if {[dict exists $options $flag] && [dict get $options $flag]} {
        lappend names $flagName
      }
    }
    if {$subtype ne {}} {
      lappend names $subtype
    }
    return $names
  }

  # /MK, the appearance characteristics (Table 192), and /BS beside it.
  #
  # /CA IS NOT WRITTEN FOR A CHECK BOX OR A RADIO BUTTON, although Table 192
  # allows it there - "the CA entry may be used with any type of button
  # field". It is the caption a reader uses "in constructing a dynamic
  # appearance stream", and neither of those two ever needs one built: both
  # of their states are in the file and toggling is a change of /AS. Writing
  # a ZapfDingbats character into /CA would mean writing a /DA naming
  # ZapfDingbats to go with it, and that is a font in /DR for a picture this
  # module has already drawn. The push button is the other case - it has one
  # state, a reader may well rebuild it, and then /CA and /DA are what it has
  # to work from.
  #
  # The frame and the background are the core's [FieldBorderEntries], and the
  # caption is what this module has to add INSIDE the same /MK - there is one
  # /MK per widget. It used to be the whole dictionary reassembled here for
  # the sake of that one key; the core takes the extra pairs now.
  method FieldButtonCharacteristics {data} {
    set characteristics {}
    if {[dict exists $data caption] && [dict get $data caption] ne {}} {
      set characteristics [list CA [my Str [dict get $data caption]]]
    }
    return [my FieldBorderEntries $data $characteristics]
  }

  # The /AP of a button: /N is a SUBDICTIONARY with one entry per state
  # (12.5.5, Table 170), and where it is one, /AS is required by Table 166.
  # All three types come through here - a check box and a radio button with
  # their on state and /Off, a push button with the one entry PDF/A wants
  # (see [FieldButtonBuild]) - because the same dictionary written in three
  # places is the one that gets fixed in two.
  #
  # "states" is a list of {name on}: the name the entry is filed under and
  # whether that state shows the mark. "slot" makes the reservation keys
  # unique within the field - the widget for a check box or a push button,
  # the button's index for one of a radio set.
  method FieldButtonStates {record slot states} {
    set entries {}
    foreach state $states {
      lassign $state name on
      lappend entries $name [my FieldAppearanceStream $record $slot.$name \
          {my FieldButtonPaint $record $on}]
    }
    return [::tclpdf::pdfObj dictionary [list \
        N [::tclpdf::pdfObj dictionary $entries]]]
  }

  # The two states of a check box or a radio button, for [FieldButtonStates]:
  # the on state under its own name, the off state under /Off. BOTH are always
  # written - see the head of this file.
  method FieldButtonTwoStates {export} {
    return [list [list $export 1] [list $::tclpdf::fieldButton::off 0]]
  }

  # What a button SHOWS in one state. Runs inside the appearance stream's own
  # canvas, so {0 0} is the top left corner of the widget and the document
  # unit is in force - the same system the caller draws a page in.
  #
  # NO /Tx BMC BRACKET. 12.7.4.3 prescribes it for VARIABLE TEXT, which by
  # 12.7.4.3 is what text fields and choice fields have; a button's
  # appearance is not a value a reader replaces from /V, and the marked
  # content that tells it where to cut would be an invitation to do so.
  method FieldButtonPaint {record on} {
    set data [dict get $record data]
    lassign [dict get $record extent] width height
    set round [expr {[dict get $data mark] eq "circle"
        && ![dict exists $data caption]}]
    my FieldButtonFrame $data $width $height $round
    if {!$on} {
      return
    }
    if {[dict exists $data caption]} {
      my FieldButtonCaption $data $width $height
    } else {
      my FieldButtonMark $data $width $height
    }
    return
  }

  # The background and the frame. A ROUND frame where the mark is a dot,
  # because that is the shape a radio button has had since before there were
  # readers to draw it - and because a dot in a square box is a check box
  # drawn wrong.
  method FieldButtonFrame {data width height round} {
    set borderWidth [dict get $data borderWidth]
    set hasBorder [expr {[dict get $data border] ne {} && $borderWidth > 0}]
    set background [dict get $data background]
    if {$round} {
      set centre [list [expr {$width / 2.0}] [expr {$height / 2.0}]]
      # Inset by half the line width for the same reason the rectangular
      # frame is: a stroke straddles the path it follows (8.4.3.2), and the
      # half outside would be clipped away by the /BBox with nothing to say
      # it happened.
      set radius [expr {(min($width, $height) - $borderWidth) / 2.0}]
      if {$radius <= 0} {
        return
      }
      if {$background ne {}} {
        my circle -at $centre \
            -radius [expr {$radius + $borderWidth / 2.0}] -fill $background
      }
      if {$hasBorder} {
        my circle -at $centre -radius $radius \
            -stroke [dict get $data border] -width $borderWidth
      }
      return
    }
    if {$background ne {}} {
      my rect -at {0 0} -size [list $width $height] -fill $background
    }
    if {$hasBorder && $width > $borderWidth && $height > $borderWidth} {
      set half [expr {$borderWidth / 2.0}]
      my rect -at [list $half $half] \
          -size [list [expr {$width - $borderWidth}] \
              [expr {$height - $borderWidth}]] \
          -stroke [dict get $data border] -width $borderWidth
    }
    return
  }

  # The mark of a ticked box or a selected button, centred in the widget.
  # Four paths - see the head of this file for why they are not glyphs.
  method FieldButtonMark {data width height} {
    set span [expr {min($width, $height)}]
    set size [dict get $data markSize]
    if {$size eq {}} {
      # Two thirds of the shorter side: enough that the mark reads as a mark
      # at eight points, little enough that it does not touch the frame.
      set size [expr {$span * 0.62}]
    }
    set limit [expr {$span - 2.0 * [dict get $data borderWidth]}]
    if {$size > $limit} {
      set size $limit
    }
    if {$size <= 0} {
      # A box too small to hold anything between its own frames. Nothing is
      # drawn rather than something drawn outside the box: the /BBox would
      # clip it away in any case, and a stream that paints outside its own
      # bounding box is a stream no two readers agree on.
      return
    }
    set left [expr {($width - $size) / 2.0}]
    set top [expr {($height - $size) / 2.0}]
    set colour [dict get $data color]
    set stroke [expr {$size * 0.16}]
    switch -- [dict get $data mark] {
      check {
        # Three points, two segments, open: the short down-stroke and the
        # long up-stroke of a tick. -close 0, or the path would be a triangle.
        my polygon -points [list \
            [expr {$left + 0.10 * $size}] [expr {$top + 0.54 * $size}] \
            [expr {$left + 0.38 * $size}] [expr {$top + 0.82 * $size}] \
            [expr {$left + 0.90 * $size}] [expr {$top + 0.16 * $size}]] \
            -close 0 -stroke $colour -width $stroke -cap round -join round
      }
      cross {
        my line -from [list $left $top] \
            -to [list [expr {$left + $size}] [expr {$top + $size}]] \
            -stroke $colour -width $stroke -cap round
        my line -from [list [expr {$left + $size}] $top] \
            -to [list $left [expr {$top + $size}]] \
            -stroke $colour -width $stroke -cap round
      }
      circle {
        my circle -at [list [expr {$width / 2.0}] [expr {$height / 2.0}]] \
            -radius [expr {$size / 2.0}] -fill $colour
      }
      square {
        my rect -at [list $left $top] -size [list $size $size] -fill $colour
      }
    }
    return
  }

  # The caption of a push button, centred in both directions.
  #
  # EVERY value is named, none inherited - the same trap field.tcl documents:
  # this runs at write time, where the document's text state is whatever the
  # last [font] call left behind, and a caption drawn in it comes out in the
  # font of some unrelated paragraph.
  method FieldButtonCaption {data width height} {
    set padding [expr {[dict get $data borderWidth]
        + [::tclpdf::geometry fromPoints 1 [my cget -unit]]}]
    set inner [expr {$width - 2 * $padding}]
    if {$inner <= 0} {
      return
    }
    set sizeUnit [::tclpdf::geometry fromPoints [dict get $data size] \
        [my cget -unit]]
    set top [expr {($height - $sizeUnit) / 2.0}]
    if {$top < $padding} {
      set top $padding
    }
    my save
    my clip -at [list $padding $padding] \
        -size [list $inner [expr {$height - 2 * $padding}]]
    my text [dict get $data caption] -at [list [expr {$width / 2.0}] $top] \
        -anchor top -align center \
        -size [dict get $data size] -family [dict get $data family] \
        -style [dict get $data style] -color [dict get $data color]
    my restore
    return
  }
}

package provide tclpdf::fieldButton 1.0
