#
# tclpdf - PDF generation for Tcl
#
# field - interactive form fields (ISO 32000-2, 12.7)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Usage:
#
#   $doc field text customer -rect {20 40 80 8} -value "Erika Mustermann"
#   $doc field list                          ;# the names, in declaration order
#   $doc field state customer                ;# what was declared
#   $doc field default -family times -size 9 ;# the document-wide /DA
#
# WHAT THIS FILE IS. The core of the form topic and NO FIELD TYPE AT ALL: the
# field tree (/AcroForm with /Fields), the widget annotation on the page, the
# default appearance string (/DA), the default resources (/DR), the structure
# tree the widgets hang in, and the write-time machinery that keeps all of it
# idempotent. Every type - text field, check box, radio button, list box,
# combo box, push button - is a MODULE OF ITS OWN (fieldText.tcl,
# fieldButton.tcl, fieldChoice.tcl) and attaches through the contract below.
# This file does not grow by one of them.
#
# The text field lived here while there was only one type, because a core
# with no field in it cannot be measured. It moved out to fieldText.tcl once
# there were three, and what the move brought to light is written down in
# point 5 below: three methods that every type already called - [FieldFont],
# [FieldBorderEntries] and [FieldColourArray] - and that the contract had
# never named, because while the text field was in this file they looked like
# its own rather than like the core's.
#
# EVERY FIELD DRAWS ITS OWN /AP, AND /NeedAppearances IS NEVER WRITTEN. That
# is the one decision the whole module is built around, and both halves of it
# are requirements rather than taste:
#
#   ISO 32000-2, 12.5.2, Table 166 under /AP: "A PDF writer shall include an
#   appearance dictionary ... Every annotation (including those whose Subtype
#   value is Widget, as used for form fields) ... shall have at least one
#   appearance dictionary." The two exceptions are a /Rect degenerate in BOTH
#   axes and the subtypes Popup, Projection and Link - a visible widget is
#   under none of them. veraPDF fails a file without one in every PDF/A part
#   (clause 6.3.3, measured 2026-08-23), and the message is "An annotation
#   does not contain an appearance dictionary".
#
#   /NeedAppearances is the flag that asks the READER to draw instead, and
#   Table 224 marks it DEPRECATED IN PDF 2.0. Not written at all - not even
#   as false. Three reasons, and the first is enough: the standard says what
#   the ingredients are (/DA, /DR, /MK, /Q) and nowhere how a reader is to
#   combine them, so the result is unpredictable; a reader that is not
#   interactive does not do it at all (Table 275, /AcroFormInteract); and the
#   flag FIRES FIELD EVENTS on opening (12.6.3), which on a signed document
#   is the last thing anyone wants. A key that is absent means false, and
#   that is what a reader is told: measured, "qpdf --json
#   --json-key=acroform" over a file written here answers
#   "needappearances": false with the key nowhere in it.
#
# WHAT IS DELIBERATELY NOT BUILT, and named rather than half-written: XFA
# (Table 224, deprecated in PDF 2.0, and forbidden outright by ISO 14289-2,
# 8.10.1) and with it /DS, /RV and the RichText flag, which are all defined
# in the XFA format rather than in the PDF standard; ECMAScript actions
# (12.6.4.17 defines their contents in ISO/DIS 21757-1, another standard
# entirely) and therefore calculated fields, whose /C action is an ECMAScript
# action by Table 199; the submit-form and import-data actions (12.7.6.2 and
# 12.7.6.4), which need a server and a reader's file dialogue. A value that
# has to be computed is computed HERE and written as /V with its /AP drawn -
# which is what a document produced by a script can do and a script inside
# the document cannot be measured doing. The reset action (12.7.6.3) is the
# one form action that is purely declarative and would be admissible.
#
# PDF/UA, AND THE CALLER DOES NOTHING FOR IT BEYOND [$doc tagged 1]. Six
# pieces, and every one of them is the CORE's - a field type knows nothing
# about the structure tree, which is the whole point of point 6:
#
#   Form         one structure element PER WIDGET, made by [FieldStructure]
#                at the call that declares the field, inside whatever element
#                is open there - which is what puts it in reading order. ISO
#                14289-2, 8.10.1 is emphatic that it is not one per field:
#                "A Form structure element shall enclose at most one widget
#                annotation ... a Form structure element does not semantically
#                equate to a form field", so four radio buttons are four
#                elements and one field. ISO 14289-1, 7.18.4 says the same in
#                one sentence, and veraPDF checks it by name.
#   OBJR         the element reaches the annotation through
#                << /Type /OBJR /Obj ... /Pg ... >> in its /K, written by
#                structureWrite.tcl for every annotation alike.
#   StructParent the annotation reaches the element back through the parent
#                tree (14.7.5.4), and [FieldWidgetPairs] writes the key.
#   TU           the accessible name of the FIELD (14.9.3), from -tooltip.
#                Required under a UA claim and refused without: see
#                [fieldsWithoutDescription], which ua.tcl judges.
#   Contents     the accessible name of ONE WIDGET, from -contents, and only
#                a field with several has one to give (ISO 14289-2, 8.10.2.4).
#   Lbl          the VISIBLE caption of one widget, drawn by a script the
#                caller gives: -label where the field has one widget, one
#                script per widget in -labels where it has several. It lands
#                inside that widget's own Form element and nowhere else
#                (8.10.2.2), and it needs PDF 2.0 - see [FieldDeclare].
#
# /Tabs /S on every page carrying annotations is output.tcl's and was there
# before this module: it writes it for every page that has any, and /S
# satisfies UA-1 (7.18.3, where it is the only admissible value) and UA-2
# (8.9.3.3, which also takes A and W) alike.
#
# THE LABEL OF A GROUP IS NOT THAT Lbl, and it is the caller's to arrange:
# 8.10.2.2 wants that one in the parent element which holds every Form of the
# set, and [$doc structure Lbl] beside the field does it - the one place where
# the two have to be arranged rather than derived, because the package draws
# no field label of its own. The push button's -caption is neither: it is
# painted INTO the widget's appearance, and 8.10.3.2.1 asks for a /Contents
# reflecting the intent of /MK /CA instead.
#
# ---------------------------------------------------------------------------
# THE CONTRACT FOR A FURTHER FIELD TYPE
# ---------------------------------------------------------------------------
#
# A field type is a topical module - fieldText.tcl, fieldButton.tcl,
# fieldChoice.tcl - that requires this one and adds ONE public method to the
# document class. Six points, and nothing outside them is this file's
# business:
#
# 1. REGISTER. At load time:
#
#      ::tclpdf::field::register check tclpdf::fieldCheck
#
#    The first word is the subcommand of [$doc field], the second the package
#    that provides it. The table this writes into is also carried in this
#    file with one line per type shipped in the tree, so that "$doc field
#    check" loads the module without the caller requiring it by hand. Both
#    roads lead to the same table; a type outside the tree uses [register]
#    alone. The words list, names, state and default belong to the core and
#    are refused.
#
# 2. THE ENTRY. The method is Field<Subcommand> with the subcommand's first
#    letter capitalised - "check" is [FieldCheck] - and it takes the field's
#    name and -options, exactly as [FieldText] in fieldText.tcl does. It
#    parses its own options, refuses what it cannot build, and then declares
#    the field.
#
# 3. DECLARE. One call, and it is what makes the field exist:
#
#      my FieldDeclare $name -type Btn -build FieldCheckBuild \
#          -rect {x y w h} ?-page n? ?-tooltip text? ?-flags n? ?-data dict?
#
#    -type is the /FT value without the slash (Tx, Btn, Ch, Sig). -build is
#    the method called at write time (point 4). -flags is the /Ff integer;
#    build it with [::tclpdf::field::flags], never by hand. -data is the
#    type's own record - anything it needs again at write time - and comes
#    back untouched. The call answers the name.
#
#    A FIELD WITH SEVERAL WIDGETS says -widgets instead of -rect, and names
#    the method that builds one of them:
#
#      my FieldDeclare $name -type Btn -build FieldRadioBuild \
#          -kid FieldRadioKid -widgets {{rect ?page? ?data?} ...} \
#          ?-contents {text ...}? ?-labels {script ...}? \
#          ?-page n? ?-tooltip text? ?-flags n? ?-data dict?
#
#    That is the shape of 12.7.5.2.4 - ONE field carrying /Kids, and the
#    buttons of the set widget annotations beneath it - and it is not a
#    convenience. 12.7.4.2: "A field dictionary that does not have a partial
#    field name (T entry) of its own shall not be considered a field but
#    simply a Widget annotation" - so four radio buttons ARE four widgets and
#    one field, and there is no way to say that with one merged object. A
#    type that built the arrangement itself would be a second writer of the
#    page's /Annots and a field the core cannot see, and what reads the core's
#    table is "field list", "field state" and the refusal of a name already
#    taken.
#
#    -rect and -widgets are exclusive and one of them is required. -kid
#    belongs with -widgets and to nothing else. Each entry of -widgets is
#    {rect ?page? ?data?}: the rectangle as -rect counts it, the page it sits
#    on - the field's -page where it is left empty, so a set may span pages -
#    and a dictionary of that widget's own, which comes back untouched in the
#    kid's record under "entry".
#
#    -contents belongs with -widgets too, and is a list running in step with
#    it: the accessible description of each widget, written as /Contents on
#    that annotation. It is the answer to ISO 14289-2, 8.10.2.4 - one /TU on
#    a field with four widgets describes none of the four - and a type that
#    lets its caller name them passes them straight through. A field with one
#    widget has -tooltip for the same job and -contents is refused for it.
#
#    -labels is the SECOND list running in step with -widgets, and it is to
#    -label what -contents is to -tooltip: one script per widget, drawn into
#    the Lbl inside THAT widget's own Form structure element. 8.10.2.4 names
#    the two in one breath - "a label, a Contents entry, or both, shall be
#    present for each annotation" - so the visible caption beside one button
#    of a set has the same place to go as the invisible description does. A
#    field with one widget says -label, and -labels is refused for it; the
#    two are never both given, because a field has either one widget or
#    several. Every script runs in the caller's scope, at the level [field]
#    recorded, exactly as -label does - see [FieldStructureElement].
#
#    A LABEL FOR THE GROUP IS NEITHER OF THEM. 8.10.2.2 puts it in the
#    element that holds all the widgets, which is the caller's own, and it is
#    written as [$doc structure Lbl] beside the field. That is why -label on
#    a field with several widgets stays refused: there are as many Form
#    elements as widgets and no one of them is the group's.
#
#    What it does: checks the name against 12.7.4.2 (a partial field name
#    holds no period), refuses a name already taken - by another field OR by
#    the signature field - reserves the object number of every widget and, for
#    a field with -widgets, of the parent field, pins the PDF version floor,
#    and hooks the write events. It writes nothing.
#
# 4. BUILD. At write time, once per write and per field, the core calls
#
#      my <build> $name $record   ->  a list of PDF dictionary pairs
#
#    $record is what was declared plus three keys the core adds: "rectangle"
#    (the /Rect array, ready to write), "size" ({width height} in POINTS, for
#    a bounding box) and "extent" ({width height} in the DOCUMENT UNIT, for
#    drawing).
#
#    A field declared with -widgets has none of those three - it has no
#    rectangle of its own - and carries "widgets" instead: the records of its
#    kids, in the order -widgets named them. Each of those is a record of the
#    shape above with "index", "entry" (that widget's own dictionary) and
#    "contents" in it, and with the FIELD's "data", so an appearance script
#    reads the same thing either way. The -kid method is called once per
#    widget with it:
#
#      my <kid> $name $kidRecord   ->  a list of PDF dictionary pairs
#
#    THE ANSWER IS THE SAME KIND OF THING in both cases, and goes through the
#    same check: the pairs that are SPECIFIC to the type. That list is
#    EXHAUSTIVE and it is this one -
#
#      FT V DV Q MaxLen Opt I TI AS MK DA AP A BS
#
#    - and a key outside it is refused by name, exactly as one the core writes
#    is: Type, Subtype, Rect, F, P, T, TU, Ff, Parent, Kids, Contents and
#    StructParent. Two writers
#    over one key is how a widget ends up on the wrong page with nobody able
#    to say which call did it; a key that is neither the core's nor on the
#    list is a misspelling, and a misspelt key lands in the file and no
#    validator mentions it. A type that needs a further key of Tables 226 to
#    234 adds it to [ownKeys] in one line - the list is meant to be added to,
#    not to be worked around.
#
# 5. APPEARANCE. A type that shows something calls
#
#      my FieldAppearanceStream $record <slot> {script}
#
#    <slot> is a word unique within the field - N for the normal appearance,
#    Off and Yes for the two states of a check box - and the answer is the
#    indirect reference to a form XObject with the right /BBox and the
#    document's own /Resources. Inside the script the drawing methods work
#    unchanged and {0 0} is the TOP LEFT corner of the widget, y downwards,
#    in the document unit, exactly as on a page. The object is reserved per
#    field and slot, so the second write fills the same one rather than
#    adding a copy.
#
#    THREE MORE METHODS ARE THE CORE'S AND EVERY TYPE USES THEM, and they are
#    named here because they were not: while the text field stood in this
#    file they read like its own, and each of the other two types found them
#    only by reading it.
#
#      my FieldFont $family $style $size $colour $what
#
#    answers the /DA of ONE field - the dict has "da" in it - and the values
#    that went into it, so the appearance can be painted in the very font the
#    /DA names. Anything left empty falls back to [field default]. It is also
#    the check: a family that does not resolve, or a colour with no /DA
#    spelling, is refused HERE, at the call that named it, and $what is the
#    wording the refusal uses.
#
#      my FieldBorderEntries $data ?pairs?
#
#    answers the /MK and /BS of Table 192 out of the three keys "border",
#    "borderWidth" and "background" of the type's own record, and puts the
#    type's own characteristics - the push button's /CA - inside the same /MK
#    behind the frame. There is ONE /MK per widget, so a type that assembled
#    it itself would be the second writer of a key it shares.
#
#      my FieldColourArray $spec
#
#    is the colour ARRAY /BC and /BG take, where the count of the numbers is
#    what says which space it is in - not an operator, and the one place that
#    refuses a space with no spelling there.
#
# 6. WHAT IS NOT THE TYPE'S. /AcroForm, /Fields, /SigFlags, /DA and /DR at
#    the document level, /NeedAppearances, the page's /Annots, the object
#    numbers of the field and of every widget under it, the version floor and
#    the idempotence of all of it are the core's. A field type never writes a
#    catalogue key.
#
#    THE STRUCTURE TREE IS THE CORE'S AS WELL, and a field type is not told
#    that it exists: the Form element per widget, the OBJR inside it, the
#    /StructParent on the annotation and the /Contents beside it are all made
#    by [FieldStructure] and [FieldWidgetPairs] from what was declared. A
#    type gets accessibility by declaring its field and nothing else - which
#    is why the radio field, the one type with several widgets, has not a
#    line about tagging in it.
#
#    THE DOCUMENT-LEVEL /DA IS WRITTEN FOR A DOCUMENT THAT HAS A FIELD WITH
#    VARIABLE TEXT, and by 12.7.4.3 that is a text field or a choice field -
#    /FT Tx and /FT Ch - and nothing else: "A default appearance string (DA)
#    containing a sequence of valid page-content graphics ... operators that
#    define such properties as the field's text size and colour" is required
#    of those two, and a button has no text a reader sets. It used to be
#    written for every field alike, and the cost was not cosmetic: the string
#    names a font, naming a font REGISTERS it, and a form of nothing but
#    buttons thereby put Helvetica into a document that had asked for no font
#    at all - which under a PDF/A declaration is not a fault at the validator
#    but a refusal at the write ("PDF/A requires every font to be embedded,
#    but Helvetica is a standard font"), for a font the caller never named.
#    /DR follows the /DA, and follows a type that answers a /DA of its OWN as
#    well - the push button does, because /MK /CA gives a reader something to
#    rebuild the appearance from, and a /DA naming a font that /DR does not
#    have is the silent break [FieldFont] describes below.
#
# ---------------------------------------------------------------------------
# THE SEAM WITH sign.tcl
# ---------------------------------------------------------------------------
#
# A signature field is a form field (12.7.5.5) and sign.tcl built one before
# this module existed: field and widget in a single object, listed in an
# /AcroForm of its own with /SigFlags 3. Two modules writing the catalogue
# key /AcroForm each from their own state is one document with two field
# trees, of which a reader sees the last one written - so the key has ONE
# writer, and it is here. sign.tcl hands its widget over with
#
#   my FieldEnlist $reference -sigflags 3
#
# and that is the whole of its change. [FieldCatalog] collects whatever was
# enlisted - the signature widget, every field declared here - and writes the
# single /AcroForm. A document with a signature and no field of this module's
# own comes out byte for byte as it did before: /DA, /DR and /NeedAppearances
# are written only where there is a field that needs them, because a
# signature field has no variable text and nothing to draw them for.
#
# The rectangle arithmetic moved here for the same reason: sign.tcl and this
# module both turn {x y w h} counted from the top left of the page into the
# four numbers of /Rect, and both have to refuse one that lies entirely
# beside the page. [FieldRectangle] is that one place; sign.tcl calls it with
# its own wording.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::color 1.0-
package require tclpdf::geometry 1.0-
package require tclpdf::document 1.0-
# The default appearance string names a font resource, and the appearance
# stream sets the value in it - so the text topic is not optional here the
# way it is for a document that only draws rectangles.
package require tclpdf::text 1.0-

namespace eval ::tclpdf::field {
  namespace export {[a-z]*}
  namespace ensemble create

  # Subcommand of [$doc field] -> the package that provides it. One line per
  # field type shipped in this tree; a type from outside adds its line with
  # [register]. Same arrangement as the topic table in document.tcl, and for
  # the same reason: the caller says what it wants, not which file it lives
  # in.
  variable types {
    text tclpdf::fieldText
    check tclpdf::fieldButton
    radio tclpdf::fieldButton
    button tclpdf::fieldButton
    listbox tclpdf::fieldChoice
    combo tclpdf::fieldChoice
  }

  # THE KEYS A BUILD MAY ANSWER, and the list is exhaustive - point 4 of the
  # contract at the head of this file. Tables 226 (FT, V, DV), 228 (DA, Q),
  # 232 (MaxLen), 234 (Opt, TI, I) and 192/166 (AS, MK, AP, BS) - plus /A,
  # which is the reset action of a push button and the one form action of
  # 12.7.6 that is declarative.
  #
  # A whitelist rather than a list of the core's own keys, and for the reason
  # [flagBits] is one: a misspelt key is written into the file, behaves
  # plausibly and wrongly, and no validator on this machine says a word about
  # it. A type that needs a further key adds it here, in one line.
  variable ownKeys {FT V DV Q MaxLen Opt I TI AS MK DA AP A BS}

  # The keys the CORE writes, refused by name rather than through the list
  # above, because the answer to /Rect from a build is not "spell it right"
  # but "that one is not yours".
  variable coreKeys {Type Subtype Rect F P T TU Ff Parent Kids
    Contents StructParent}

  # The words the core answers itself. A field type may not take one of them
  # - the switch below would never reach it, and a type that is silently
  # unreachable is worse than one refused at load time.
  variable reserved {list names state default}

  # The field flags of /Ff, by NAME and by the bit position the standard
  # gives them (12.7.4.1, Table 227; the type-specific ones in Table 229 for
  # buttons, Table 231 for text and Table 233 for choices). Position 1 is the
  # LOW bit, which is the trap in the table:
  # /Ff 1 is ReadOnly, not bit 1 of a zero-based count.
  #
  # Here rather than in each type module because the first three are common
  # to every type, and because a package that spells one bit wrong writes a
  # field that behaves like another one with nothing to say why.
  variable flagBits {
    ReadOnly 1 Required 2 NoExport 3
    Multiline 13 Password 14 NoToggleToOff 15 Radio 16 Pushbutton 17
    Combo 18 Edit 19 Sort 20 FileSelect 21 MultiSelect 22
    DoNotSpellCheck 23 DoNotScroll 24 Comb 25 RichText 26
    RadiosInUnison 26 CommitOnSelChange 27
  }
}

# Add a field type. See point 1 of the contract at the head of this file.
proc ::tclpdf::field::register {subcommand package} {
  variable types
  variable reserved
  if {$subcommand eq {}} {
    return -code error -errorcode {TCLPDF FIELD REGISTER NAME} \
        "tclpdf: a field type needs a subcommand - it is the word after\
        \"field\" in \"\$doc field <type> <name> ...\""
  }
  if {$subcommand in $reserved} {
    return -code error -errorcode [list TCLPDF FIELD REGISTER RESERVED $subcommand] \
        "tclpdf: \"$subcommand\" is a subcommand of the field core and cannot\
        be a field type - the core answers [join $reserved {, }] itself, so a\
        type registered under one of them would never be reached. Choose\
        another word"
  }
  if {[dict exists $types $subcommand]
      && [dict get $types $subcommand] ne $package} {
    return -code error -errorcode [list TCLPDF FIELD REGISTER TAKEN $subcommand] \
        "tclpdf: the field type \"$subcommand\" is already provided by\
        [dict get $types $subcommand] and cannot be taken over by $package -\
        two modules under one subcommand is one of them writing fields the\
        other believes it wrote. Register under another word"
  }
  dict set types $subcommand $package
  return $subcommand
}

# The /Ff integer for a list of flag names. See [flagBits] above for the
# names; an unknown one is refused with the list, because a misspelt flag is
# a field that behaves plausibly and wrongly.
proc ::tclpdf::field::flags {names} {
  variable flagBits
  set value 0
  foreach name $names {
    if {![dict exists $flagBits $name]} {
      return -code error -errorcode [list TCLPDF FIELD FLAG $name] \
          "tclpdf: unknown field flag \"$name\" - known are:\
          [join [lsort [dict keys $flagBits]] {, }] (ISO 32000-2, Tables 227,\
          229, 231 and 233)"
    }
    set value [expr {$value | (1 << ([dict get $flagBits $name] - 1))}]
  }
  return $value
}

oo::define ::tclpdf::document::document {

  # $doc field <type> <name> ...      a field, in the module registered for
  #                                   <type> - text, check, radio, button,
  #                                   listbox, combo
  # $doc field list                   the names, in declaration order
  # $doc field state <name>           what was declared for one field
  # $doc field default ?-family f? ?-style s? ?-size n? ?-color c?
  method field {args} {
    if {![llength $args]} {
      return -code error -errorcode {TCLPDF FIELD SUBCOMMAND} \
          "tclpdf: field needs a subcommand - [my FieldKnown]"
    }
    set subcommand [lindex $args 0]
    set args [lrange $args 1 end]
    # NOT a [switch]: one of the core's own subcommands is called "default",
    # and as the last pattern of a switch that word IS the catch-all clause -
    # every unknown subcommand would have run [FieldDefault] and answered a
    # font instead of a refusal. The trap is invisible in the switch and
    # obvious here, which is why the three are written out.
    if {$subcommand in {list names}} {
      return [dict keys [my state fields]]
    }
    if {$subcommand eq "state"} {
      return [my FieldState {*}$args]
    }
    if {$subcommand eq "default"} {
      return [my FieldDefault {*}$args]
    }
    variable ::tclpdf::field::types
    if {![dict exists $types $subcommand]} {
      return -code error -errorcode [list TCLPDF FIELD SUBCOMMAND $subcommand] \
          "tclpdf: unknown field subcommand \"$subcommand\" - [my FieldKnown]"
    }
    package require [dict get $types $subcommand]
    # -private matters: a field type may be built entirely out of private
    # methods, and [info object methods -all] lists only the exported ones.
    # Same check document.tcl makes for a topic, and for the same reason -
    # without it a module that loads but provides nothing looks like a typo
    # in the caller's script.
    set method Field[string toupper $subcommand 0 0]
    if {$method ni [info object methods [self] -all -private]} {
      return -code error -errorcode [list TCLPDF FIELD TYPE $subcommand] \
          "tclpdf: the field type \"$subcommand\" is registered for\
          [dict get $types $subcommand], and that package does not provide\
          \"$method\" - a field type adds exactly that method to the document\
          class (see the contract at the head of field.tcl)"
    }
    # THE CALLER'S SCOPE, taken here and nowhere else. A -label script is run
    # by the core, inside the Form structure element it makes for the widget
    # (see [FieldStructureElement]), and by then the stack holds the field
    # type's own method and [FieldDeclare] between the two - so the level the
    # script has to run at is this method's CALLER, and only this method can
    # read it. [info level] answers the absolute level, which is what
    # "uplevel #n" takes.
    #
    # Not simply one level up, and the reason is the FIRST call in a script.
    # A document's methods are loaded per topic on demand, so "$doc field
    # text ..." on a document that has not seen a field yet arrives through
    # [unknown] in document.tcl, which loads this file and dispatches again
    # with "my field ..." - one frame that is not there on the second call.
    # A fixed count would put a -label script one frame too deep exactly
    # once per script, which is the kind of fault that looks like a typo in
    # the caller's own code. So the internal re-dispatches are walked off:
    # they are the frames whose command word is "my".
    #
    # Saved and put back rather than simply set: a -label script may declare
    # a field of its own, and the inner call would otherwise leave its level
    # behind for the outer one to finish its label at.
    set level [info level]
    while {$level > 1 && [lindex [info level $level] 0] eq "my"} {
      incr level -1
    }
    set outer [my state fieldScope]
    my state fieldScope [expr {$level - 1}]
    set code [catch {my $method {*}$args} result outcome]
    my state fieldScope $outer
    return -options $outcome $result
  }

  # The subcommands there are, for a refusal - the core's own and every
  # registered type, so a caller who mistyped one gets the list rather than
  # only a no.
  method FieldKnown {} {
    variable ::tclpdf::field::types
    variable ::tclpdf::field::reserved
    return "known are: [join [lsort [concat $reserved [dict keys $types]]] {, }]"
  }

  # -- the core -------------------------------------------------------------

  # /MK, the appearance characteristics (Table 192) - the border colour in
  # /BC and the background in /BG. Written beside the /AP rather than instead
  # of it: the stream is what a reader SHOWS, and /MK is what it uses when it
  # regenerates one, which it does the moment a user types in the field.
  # Without /MK a field with a drawn frame loses the frame at the first
  # keystroke.
  #
  # A TYPE WITH A CHARACTERISTIC OF ITS OWN passes it in and gets it inside
  # the same /MK: the push button's /CA, the caption "a reader uses in
  # constructing a dynamic appearance stream" (Table 192). There is one /MK
  # per widget, so a type that needed one more key had to reassemble the
  # whole dictionary - and did, in fieldButton.tcl, until this argument
  # existed. The pairs go in AFTER the frame, so the order of a widget that
  # passes none is the byte the file had before.
  method FieldBorderEntries {data {characteristics {}}} {
    set entries {}
    if {[dict get $data border] ne {} && [dict get $data borderWidth] > 0} {
      lappend entries BC [my FieldColourArray [dict get $data border]]
    }
    if {[dict get $data background] ne {}} {
      lappend entries BG [my FieldColourArray [dict get $data background]]
    }
    lappend entries {*}$characteristics
    if {![llength $entries]} {
      return {}
    }
    set pairs [list MK [::tclpdf::pdfObj dictionary $entries]]
    if {[dict get $data border] ne {} && [dict get $data borderWidth] > 0} {
      # /BS, the border style (Table 168): the width in the unit a PDF
      # measures annotation borders in, which is points, and /S /S for a
      # solid line. Written only with a colour, because a width without one
      # is a border no reader draws.
      lappend pairs BS [::tclpdf::pdfObj dictionary [list \
          W [::tclpdf::pdfObj num [::tclpdf::geometry toPoints \
              [dict get $data borderWidth] [my cget -unit]]] \
          S /S]]
    }
    return $pairs
  }

  # A colour as the ARRAY /MK takes (Table 192): zero, one, three or four
  # numbers, and the count is what says which space it is in. Not an
  # operator - /BC and /BG hold components, not content stream syntax.
  method FieldColourArray {spec} {
    lassign [::tclpdf::color parse $spec] space values
    if {$space ni {gray rgb cmyk}} {
      return -code error -errorcode [list TCLPDF FIELD COLOURSPACE $space] \
          "tclpdf: the border and background of a field are given in grey,\
          RGB or CMYK - ISO 32000-2, Table 192 admits one, three or four\
          numbers and tells the space apart by counting them, so a $space\
          colour has no spelling there. Name the colour as {r g b}, {c m y k}\
          or a single grey value"
    }
    return [::tclpdf::pdfObj arr [lmap value $values {
      ::tclpdf::pdfObj num $value
    }]]
  }

  # Declare a field. Point 3 of the contract at the head of this file.
  method FieldDeclare {name args} {
    set options [::tclpdf::option parse {
      type {} build {} kid {} rect {} widgets {} contents {} label {}
      labels {} page {} tooltip {} flags 0 data {}
    } $args "field declare"]
    if {$name eq {}} {
      return -code error -errorcode {TCLPDF FIELD NAME} \
          "tclpdf: a form field needs a name - it is the partial field name\
          (/T, ISO 32000-2, 12.7.4.2) that an exported form, a script in a\
          reader and a filled document all address the field by, and a field\
          dictionary without one is not a field at all"
    }
    # 12.7.4.2: the fully qualified name is the partial names of the field and
    # its parents joined by periods, so a period INSIDE one splits the name
    # into two nobody meant.
    if {[string first . $name] >= 0} {
      return -code error -errorcode [list TCLPDF FIELD NAME $name] \
          "tclpdf: a field name holds no period - \"$name\". ISO 32000-2,\
          12.7.4.2 joins the fully qualified name out of the partial names\
          with periods between them, so a period in one of them names a\
          parent field that does not exist. Use another separator"
    }
    if {[dict get $options type] ni {Tx Btn Ch Sig}} {
      return -code error -errorcode \
          [list TCLPDF FIELD DECLARE TYPE [dict get $options type]] \
          "tclpdf: -type of field declare is the field type of ISO 32000-2,\
          Table 226 without its slash - Tx, Btn, Ch or Sig - not\
          \"[dict get $options type]\""
    }
    if {[dict get $options build] eq {}} {
      return -code error -errorcode {TCLPDF FIELD DECLARE BUILD} \
          "tclpdf: -build of field declare names the method that builds the\
          field's own dictionary pairs at write time - see the contract at the\
          head of field.tcl, point 4. Without it there is nothing to write"
    }
    set rect [dict get $options rect]
    set widgets [dict get $options widgets]
    if {$rect ne {} && $widgets ne {}} {
      return -code error -errorcode {TCLPDF FIELD DECLARE WIDGETS} \
          "tclpdf: field declare takes -rect {x y w h} for a field with ONE\
          widget or -widgets {{rect ?page? ?data?} ...} for a field with\
          several, and not both - two answers to where a field sits is one\
          the writer picks between (see the contract at the head of field.tcl,\
          point 3). A field with NEITHER is refused by the -rect check below,\
          which is the message the caller of a one-widget type needs"
    }
    # /Contents describes ONE WIDGET (ISO 32000-2, Table 166: "an alternative
    # description of the annotation's contents in human-readable form"), so a
    # field with several widgets needs one per widget and the two lists run in
    # step. A field with one widget takes one string.
    if {$widgets ne {}
        && [llength [dict get $options contents]] != [llength $widgets]
        && [dict get $options contents] ne {}} {
      return -code error -errorcode {TCLPDF FIELD DECLARE CONTENTS} \
          "tclpdf: -contents of field \"$name\" has\
          [llength [dict get $options contents]] description(s) and -widgets\
          names [llength $widgets] widget(s) - the two lists run in step, one\
          description per widget (ISO 14289-2, 8.10.2.4). Give every widget\
          its own, or leave -contents out altogether"
    }
    # -label is a SCRIPT, and what it draws becomes the widget's label: a Lbl
    # structure element that ISO 14289-2, 8.10.2.2 puts in one exact place -
    # "which shall in turn be a direct descendent of a Form structure element
    # that also includes the object reference to the widget annotation". The
    # core owns that element, so the core has to run the script; there is no
    # way for the caller to reach into it afterwards.
    #
    # Which is also why a field with SEVERAL widgets has none. The second
    # paragraph of 8.10.2.2 makes a group's label something else entirely -
    # "the Lbl structure element(s) shall be contained within the parent
    # structure element that also contains, directly or indirectly, the Form
    # structure element for each widget" - and that element is the caller's,
    # not this one's. It is written as [$doc structure Lbl], beside the field.
    if {[dict get $options label] ne {} && $widgets ne {}} {
      return -code error -errorcode {TCLPDF FIELD DECLARE LABEL} \
          "tclpdf: -label of field \"$name\" labels ONE widget and this field\
          has [llength $widgets] - ISO 14289-2, 8.10.2.2 puts a widget's label\
          inside that widget's own Form structure element, and a label for the\
          whole group inside the element that holds all of them, which is the\
          one you opened. Draw the group's label in \[\$doc structure Lbl\]\
          beside the field, label each widget with its own script in -labels,\
          and describe each of them with its own -contents"
    }
    # -labels is the same thing per widget, and the two options are the two
    # shapes of one field: a field with one widget has -label, a field with
    # several has -labels, and neither ever answers for the other.
    if {[dict get $options labels] ne {} && $widgets eq {}} {
      return -code error -errorcode {TCLPDF FIELD DECLARE LABELS} \
          "tclpdf: -labels of field \"$name\" is one label script per widget\
          and this field was declared with -rect, which is ONE widget - the\
          field object itself (ISO 32000-2, 12.5.6.19). Its label is -label,\
          in the singular, and it goes into the one Form structure element\
          there is"
    }
    if {$widgets ne {}
        && [llength [dict get $options labels]] != [llength $widgets]
        && [dict get $options labels] ne {}} {
      return -code error -errorcode {TCLPDF FIELD DECLARE LABELS} \
          "tclpdf: -labels of field \"$name\" has\
          [llength [dict get $options labels]] label script(s) and -widgets\
          names [llength $widgets] widget(s) - the two lists run in step, one\
          script per widget (ISO 14289-2, 8.10.2.2). Give every widget its\
          own, empty where it has none, or leave -labels out altogether"
    }
    # AND IT IS A PDF 2.0 FEATURE, which is not pedantry but the difference
    # between the two editions of the standard. ISO 32000-2, Table 368 says of
    # Form: "NOTE Form structure elements often include Lbl structure elements
    # to mark up a form field's label (if any)." ISO 32000-1, Table 340 said
    # the opposite - a Form without a Role attribute of the PrintField class
    # "shall have only one child: an object reference identifying the widget
    # annotation" - and veraPDF still holds a 1.7 file to it (rule 7.18.4-2,
    # measured: "The Form element omits a Role attribute and doesn't have only
    # one child identifying the widget annotation").
    #
    # The Role attribute is not the way out of that. ISO 32000-2, 14.8.5.6 is
    # explicit about what PrintField attributes are for - "the accessibility
    # mechanism for NON-INTERACTIVE PDF forms ... Since the form's fields
    # cannot be determined from interactive elements" - and writing one onto
    # a widget's Form element to quiet a validator would be a false statement
    # about the document. So the floor is pinned instead, and a PDF/UA-1
    # document describes its widgets with -contents.
    #
    # A widget of a SET is under the same rule and the floor is the same one:
    # the Lbl sits inside a Form element there as well, and 7.18.4-2 does not
    # ask how many widgets the field has.
    set labelled [expr {[dict get $options label] ne {}}]
    foreach script [dict get $options labels] {
      if {$script ne {}} {
        set labelled 1
        break
      }
    }
    if {$labelled} {
      my RequireVersion 2.0 "-label of a form field (the Lbl inside its Form\
          structure element, ISO 32000-2, Table 368)"
    }
    if {($widgets ne {}) != ([dict get $options kid] ne {})} {
      return -code error -errorcode {TCLPDF FIELD DECLARE KID} \
          "tclpdf: -kid and -widgets of field declare belong together and to\
          nothing else - -kid names the method that builds ONE widget's\
          dictionary pairs at write time, and a field declared with -rect has\
          exactly one widget which is the field object itself (ISO 32000-2,\
          12.5.6.19), so there is no kid for it to build (see the contract at\
          the head of field.tcl, point 4)"
    }
    my FieldTaken $name
    set page [my FieldPageCheck [dict get $options page]]
    # EVERY widget is checked before the first object number is reserved: a
    # refused call has to leave the document exactly as it was, and a
    # reservation is an object number handed out for a field that is not there.
    set entries {}
    if {$widgets eq {}} {
      set rect [my FieldRectCheck $name $rect]
    } else {
      set index 0
      foreach entry $widgets {
        if {![llength $entry] || [llength $entry] > 3} {
          return -code error -errorcode \
              [list TCLPDF FIELD DECLARE WIDGET $entry] \
              "tclpdf: each entry of -widgets of field \"$name\" is {rect\
              ?page? ?data?} - the rectangle of one widget, the page it sits\
              on (the field's own -page where it is left empty) and a\
              dictionary of that widget's own - not \"$entry\""
        }
        lassign $entry entryRect entryPage entryData
        if {$entryPage eq {}} {
          set entryPage $page
        } else {
          set entryPage [my FieldPageCheck $entryPage]
        }
        lappend entries [dict create index $index \
            rect [my FieldRectCheck $name $entryRect] \
            page $entryPage entry $entryData \
            label [lindex [dict get $options labels] $index] \
            contents [lindex [dict get $options contents] $index]]
        incr index
      }
    }
    # Interactive forms are PDF 1.2 (ISO 32000-1, Table 28 - /AcroForm), and
    # so is the widget annotation that carries them.
    my RequireVersion 1.2 "an interactive form field"

    set record [dict create \
        name $name \
        type [dict get $options type] \
        build [dict get $options build] \
        kid [dict get $options kid] \
        page $page \
        tooltip [dict get $options tooltip] \
        flags [dict get $options flags] \
        data [dict get $options data]]
    if {$widgets eq {}} {
      dict set record rect $rect
      dict set record contents [dict get $options contents]
      dict set record label [dict get $options label]
      dict set record widget [my reservation field.widget.$name]
    } else {
      # The parent first, so that the field object a reader reaches through
      # /Fields carries the lower number of the two - which is what makes the
      # file read in the order the tree does.
      dict set record field [my reservation field.field.$name]
      dict set record widgets [lmap entry $entries {
        dict set entry widget \
            [my reservation field.widget.$name.[dict get $entry index]]
      }]
    }
    set record [my FieldStructure $record]
    set fields [my state fields]
    dict set fields $name $record
    my state fields $fields
    if {[my state fieldHooked] eq {}} {
      my state fieldHooked 1
      my onSelf beforeWrite FieldWrite
    }
    return $name
  }

  # -- the structure tree ---------------------------------------------------

  # ONE Form STRUCTURE ELEMENT PER WIDGET, made HERE and by nothing else.
  #
  # It is the core's because it is the same question for every field type,
  # and because a field type that had to make it would have to know where in
  # the tree it stands, which page its widget sits on and what object number
  # it was given - three things point 6 of the contract keeps away from it.
  # A type does nothing at all for this; the caller does nothing beyond
  # [$doc tagged 1], which [$doc ua 1] needs anyway.
  #
  # PER WIDGET, not per field, and that is the one thing a naive reading gets
  # wrong. ISO 14289-2, 8.10.1: "Each widget annotation shall be enclosed by a
  # Form structure element ... A Form structure element shall enclose at most
  # one widget annotation", with the NOTE that says why in so many words -
  # "Form structure elements include individual widgets, several of which can
  # together comprise a single field. As such, a Form structure element does
  # not semantically equate to a form field." A radio field of four buttons is
  # therefore FOUR Form elements and ONE field. ISO 14289-1, 7.18.4 asks for
  # the same thing in one sentence and veraPDF checks it by name.
  #
  # WHERE IN THE TREE: inside whatever element is open at the call. That is
  # what puts the widget in reading order (7.18.1, "Annotations shall be
  # represented in the structure tree in correct reading order") - the field
  # is declared where it belongs on the page, and the tree follows the script.
  # Nothing open means the top level, which a Form is allowed at.
  #
  # WHEN: while the document is drawn, not at write time. The tree is built in
  # document order and turned into objects afterwards (see structure.tcl), so
  # an element made on beforeWrite would land after everything else - every
  # field of the form in a heap at the end of the tree, which is the reading
  # order nobody has.
  method FieldStructure {record} {
    if {![my tagged]} {
      return $record
    }
    if {[dict exists $record widgets]} {
      dict set record widgets [lmap entry [dict get $record widgets] {
        dict set entry structParent [my FieldStructureElement \
            [dict get $record name] [dict get $entry widget] \
            [dict get $entry page] [dict get $entry label]]
      }]
      return $record
    }
    dict set record structParent [my FieldStructureElement \
        [dict get $record name] [dict get $record widget] \
        [dict get $record page] [dict get $record label]]
    return $record
  }

  # One Form element around one widget, the Lbl the caller drew into it, and
  # the /StructParent key that points back. The two halves of 14.7.5.4: the
  # element reaches the annotation through an object reference
  # << /Type /OBJR /Obj ... /Pg ... >> in its /K, and the annotation reaches
  # the element through the parent tree - "content items that are entire PDF
  # objects ... shall also use the parent tree to refer to their parent
  # structure elements". [StructureAnnotation] writes the OBJR and answers the
  # key; what is written into the annotation is [FieldWidgetPairs]'s.
  #
  # THE LABEL GOES IN FIRST, before the object reference, and that is not
  # cosmetic: the order of /K is the reading order, and a label read out after
  # the control it names arrives too late to be a label.
  #
  # The script runs in the scope of the [$doc field ...] call, not in this
  # one - the level is taken at that call by [field] and reached here through
  # the state, because between the two lie a field type's own method and
  # [FieldDeclare], and a script that says "$doc text $heading -at [list 20
  # $y]" means the caller's $y.
  #
  # The refusal is rewrapped rather than passed on: [StructureOpen] answers
  # about a structure type the caller never named, and the call that has to
  # change is the [$doc field ...] this came from.
  method FieldStructureElement {name number page {label {}}} {
    if {[catch {my StructureOpen Form} id options]} {
      if {[dict get $options -errorcode] ne "NONE"} {
        return -options $options $id
      }
      return -code error -errorcode [list TCLPDF FIELD STRUCTURE $name] \
          "tclpdf: the widget of field \"$name\" cannot go into the structure\
          tree here - [string trim [string map {tclpdf: {}} $id]]. Every\
          widget annotation of a tagged document is enclosed by a Form\
          structure element (ISO 14289-2, 8.10.1; ISO 14289-1, 7.18.4), so a\
          field has to be declared somewhere a Form may stand"
    }
    if {$label ne {}} {
      # The global level when nothing recorded a scope, which happens only
      # where [FieldDeclare] was called directly rather than through
      # [$doc field ...] - a test standing in for a field type. A script has
      # to run somewhere, and the global level is where a caller who never
      # went through the public entry can be reached.
      set scope [my state fieldScope]
      if {$scope eq {}} {
        set scope 0
      }
      set labelId [my StructureOpen Lbl]
      set code [catch {uplevel #$scope $label} result outcome]
      my StructureClose $labelId
      if {$code} {
        # The Form is closed too, or the tree stays half open in a document
        # the caller may still write: the bracket rule of [structure], one
        # level further in.
        my StructureClose $id
        return -options $outcome $result
      }
    }
    set key [my StructureAnnotation $number $page]
    my StructureClose $id
    return $key
  }

  # -- what ua.tcl asks -----------------------------------------------------

  # THE FACTS, JUDGED BY ua.tcl. Same division of labour link.tcl and
  # font.tcl are on: this file knows what was declared, and PDF/UA is the one
  # that objects - a form without a description is perfectly legal in a
  # document that makes no claim.

  # The fields with no /TU, by name. /TU is the accessible name of a field:
  # ISO 32000-2, 14.9.3 - "An alternative name may be specified for an
  # interactive form field which, if present, shall be used in place of the
  # actual field name ... shall be specified using the TU entry" - and ISO
  # 14289-1, 7.18.1 makes an alternative description mandatory for every
  # annotation that carries no /Contents.
  method fieldsWithoutDescription {} {
    set missing {}
    dict for {name record} [my state fields] {
      if {[dict get $record tooltip] eq {}} {
        lappend missing $name
      }
    }
    return $missing
  }

  # The widgets that carry NEITHER a label NOR a /Contents, as {field index}
  # pairs - the index counting from zero, and {} where the field has a single
  # widget. ISO 14289-2, 8.10.2.3: "If a label for a widget annotation is not
  # present, or if the label is insufficient, a Contents entry shall be
  # provided to supply description and context for the widget", and 8.10.2.4
  # adds why a field's /TU does not stand in for it once there are several -
  # "a TU entry is often insufficient to provide full context for each
  # annotation, thus, a label, a Contents entry, or both, shall be present for
  # each annotation".
  #
  # The label counted here is the widget's OWN - the Lbl inside its Form
  # element, from -label on a field with one widget and from -labels on one
  # of a set. A group's label sits in the element around the whole field and
  # 8.10.2.2 keeps the two apart, so it does not answer this question for any
  # single widget.
  method fieldWidgetsWithoutDescription {} {
    set missing {}
    dict for {name record} [my state fields] {
      if {![dict exists $record widgets]} {
        if {[dict get $record contents] eq {}
            && [dict get $record label] eq {}} {
          lappend missing [list $name {}]
        }
        continue
      }
      foreach entry [dict get $record widgets] {
        if {[dict get $entry contents] eq {}
            && [dict get $entry label] eq {}} {
          lappend missing [list $name [dict get $entry index]]
        }
      }
    }
    return $missing
  }

  # The fields whose widgets reached no Form structure element, by name -
  # a field declared before [$doc tagged 1], which is the one way it happens.
  method fieldsOutsideStructure {} {
    set outside {}
    dict for {name record} [my state fields] {
      set keys {}
      if {[dict exists $record widgets]} {
        foreach entry [dict get $record widgets] {
          lappend keys [expr {[dict exists $entry structParent] ?
              [dict get $entry structParent] : {}}]
        }
      } else {
        lappend keys [expr {[dict exists $record structParent] ?
            [dict get $record structParent] : {}}]
      }
      if {{} in $keys} {
        lappend outside $name
      }
    }
    return $outside
  }

  # What was declared for one field - the record without the object numbers
  # and the two build methods, which are a writer's business and change
  # nothing a caller can act on. A field with several widgets answers its
  # kids the same way: what was declared for each of them, and no numbers.
  method FieldState {name} {
    set fields [my state fields]
    if {![dict exists $fields $name]} {
      set known "none - this document has no field at all"
      if {[dict size $fields]} {
        set known [join [dict keys $fields] {, }]
      }
      return -code error -errorcode [list TCLPDF FIELD UNKNOWN $name] \
          "tclpdf: no form field named \"$name\" - known are: $known"
    }
    set record [dict remove [dict get $fields $name] \
        widget build kid field structParent]
    if {[dict exists $record widgets]} {
      dict set record widgets [lmap entry [dict get $record widgets] {
        dict remove $entry widget structParent
      }]
    }
    return $record
  }

  # -page, checked at the call that gave it: a page index counting from zero,
  # or the current page where none was named - and [PageIndex] refuses a
  # document that has no page at all, here at the call that wanted one rather
  # than at the write. Whether the page EXISTS when the file is written is a
  # second question and is asked in [FieldMeasure].
  method FieldPageCheck {page} {
    if {$page eq {}} {
      return [my PageIndex {}]
    }
    if {![string is integer -strict $page] || $page < 0} {
      return -code error -errorcode [list TCLPDF FIELD PAGE $page] \
          "tclpdf: -page of a form field is a page index counting from zero,\
          not \"$page\" - \"page current\" answers the one being drawn on"
    }
    return $page
  }

  # The name is free - against the fields of this module AND against the
  # signature field, which sign.tcl builds without going through here.
  #
  # Two fields with one partial field name at the same level of the tree are
  # two entries a reader resolves to one (12.7.4.2): whichever it finds first
  # answers for both, the second one's value is unreachable, and no validator
  # says a word.
  method FieldTaken {name} {
    set fields [my state fields]
    if {[dict exists $fields $name]} {
      return -code error -errorcode [list TCLPDF FIELD TAKEN $name] \
          "tclpdf: this document already has a field named \"$name\" - a\
          partial field name is what a form is addressed by (ISO 32000-2,\
          12.7.4.2) and two fields under one name resolve to one. Give the\
          second field another name"
    }
    set signature [my state sign]
    if {$signature ne {} && [dict get $signature field] eq $name} {
      return -code error -errorcode [list TCLPDF FIELD TAKEN $name] \
          "tclpdf: \"$name\" is the name of this document's signature field\
          and cannot be a second field as well - both would stand in the same\
          /Fields array under one partial field name (ISO 32000-2, 12.7.4.2).\
          Rename this field, or pass \"sign -field\" another name"
    }
    return
  }

  # -rect, checked at the call that gave it. Where it lands on the page is a
  # question for the write - the page may not exist yet - but whether the
  # four numbers ARE four numbers a PDF can hold is a question for now.
  method FieldRectCheck {name rect} {
    if {[llength $rect] != 4} {
      return -code error -errorcode [list TCLPDF FIELD RECT $rect] \
          "tclpdf: a form field needs -rect {x y w h} - the top left corner of\
          the field and its size, in the unit of the document, as \"link -at\"\
          and \"rect -at\" count - not \"$rect\" (field \"$name\")"
    }
    # A NUMBER A PDF CAN HOLD, which is more than [string is double] asks:
    # NaN and an infinity pass that test and fail no comparison either, so
    # the width check below would wave them through and the write would fail
    # with a raw Tcl sentence about a non-numeric floating-point value.
    foreach value $rect {
      if {![string is double -strict $value]
          || [catch {::tclpdf::pdfObj num $value}]} {
        return -code error -errorcode [list TCLPDF FIELD RECT $rect] \
            "tclpdf: -rect of field \"$name\" is {x y w h} in numbers a PDF\
            can hold - not \"$rect\". NaN, an infinity and anything beyond\
            about +/-3.403e38 have no PDF spelling (ISO 32000-1, Annex C.2)"
      }
    }
    lassign $rect -> -> width height
    if {$width <= 0 || $height <= 0} {
      return -code error -errorcode [list TCLPDF FIELD RECT $rect] \
          "tclpdf: -rect {$rect} of field \"$name\" has a width of $width and\
          a height of $height - a field needs both above zero, or there is no\
          area for its appearance to be painted into"
    }
    return $rect
  }

  # The four numbers of /Rect for a {x y w h} counted from the TOP left
  # corner of a page, in the unit of the document.
  #
  # THE ONE THING THIS METHOD IS FOR IS THE ORIGIN. A caller counts y from
  # the top of the page and a PDF counts it from the bottom, so both corners
  # go through [coords] - the single place in this package where the unit and
  # the origin are converted, and the one link.tcl sends an annotation's
  # rectangle through for exactly this reason.
  #
  # The page is passed rather than left to default: [coords] without an index
  # takes the CURRENT page, which at write time is the last one added, while
  # a widget sits on the page it was given.
  #
  # Shared with sign.tcl, which had it first and calls it with its own
  # wording in "what" - the visible signature field asks the same question of
  # the same page, and two copies of it are two answers waiting to differ.
  method FieldRectangle {page rect what} {
    lassign $rect left top width height
    lassign [my coords $left [expr {$top + $height}] $page] x0 y0
    lassign [my coords [expr {$left + $width}] $top $page] x1 y1
    # A rectangle STICKING OUT is allowed - nothing else in this package
    # takes the page edge for a boundary, a MediaBox need not start at zero,
    # and a field at the very edge is the caller's business. One entirely
    # BESIDE the page is refused: it is an appearance nothing ever paints.
    # This is the case where the two most likely mistakes show up - a y
    # counted from the bottom, or a -rect in millimetres on a document set to
    # points.
    lassign [dict get [my Page $page] boxes media] mediaX0 mediaY0 \
        mediaX1 mediaY1
    if {$x1 <= $mediaX0 || $x0 >= $mediaX1
        || $y1 <= $mediaY0 || $y0 >= $mediaY1} {
      # Both rectangles in the message, and both in points: the numbers the
      # caller wrote are in the message as well, so the comparison that
      # explains the mistake is there to be made.
      set where [join [lmap number [list $x0 $y0 $x1 $y1] {
        ::tclpdf::pdfObj num $number
      }]]
      set box [join [lmap number [list $mediaX0 $mediaY0 $mediaX1 $mediaY1] {
        ::tclpdf::pdfObj num $number
      }]]
      return -code error -errorcode [list TCLPDF FIELD RECT OUTSIDE $page] \
          "tclpdf: $what {$rect} puts the field at $where in points, which is\
          entirely outside page $page - its media box is $box. A field has to\
          have area on the page it names: -rect counts {x y w h} from the TOP\
          left corner of the page, in the unit of the document"
    }
    return [::tclpdf::pdfObj arr [list \
        [::tclpdf::pdfObj num $x0] [::tclpdf::pdfObj num $y0] \
        [::tclpdf::pdfObj num $x1] [::tclpdf::pdfObj num $y1]]]
  }

  # Every field, on beforeWrite. Runs on EVERY write and is idempotent: every
  # object number - the field's, each widget's, each appearance stream's -
  # comes from [reservation] and is written over, the annotation is registered
  # once per page, and the catalogue entry is rebuilt from the same state each
  # time.
  method FieldWrite {} {
    set writer [my writer]
    # The /AcroForm's own /DA, built HERE rather than in [FieldCatalog].
    # It names a font resource and registering one is what puts the font
    # into the shared resource dictionary - and that dictionary is written
    # BETWEEN the two events (see [OutputBuild] in output.tcl): a font first
    # asked for on the catalog event lands in no resource dictionary at all,
    # and the /DA then names a resource that is not there.
    #
    # AND IT IS BUILT ONLY WHERE A FIELD HAS VARIABLE TEXT - a text field or a
    # choice field, 12.7.4.3 - because registering a font is not free: see
    # point 6 of the contract at the head of this file for the form of nothing
    # but buttons that could not be written as PDF/A on account of a Helvetica
    # nobody had asked for.
    set variable 0
    dict for {name record} [my state fields] {
      if {[dict get $record type] in {Tx Ch}} {
        set variable 1
        break
      }
    }
    my state fieldDa [expr {$variable ? [my FieldDaDefault] : {}}]
    # /DR is what a /DA is resolved against, so it follows the document's own
    # /DA - and it follows a TYPE that answers a /DA of its own just as much.
    set resources $variable

    dict for {name record} [my state fields] {
      if {[dict exists $record widgets]} {
        set own [my FieldWriteKids $name $record]
      } else {
        set own [my FieldWriteMerged $name $record]
      }
      if {[dict exists $own DA]} {
        set resources 1
      }
    }
    my state fieldResources $resources
    return
  }

  # ONE field with ONE widget, in ONE object. 12.5.6.19 permits the merge
  # where a field has exactly one widget, and it is what sign.tcl does for the
  # signature field - one arrangement in one document rather than two.
  #
  # Answers the pairs the type built, so that [FieldWrite] can see whether a
  # /DA of the type's own went into the file.
  method FieldWriteMerged {name record} {
    set writer [my writer]
    set record [my FieldMeasure $name $record "field \"$name\" -rect"]

    # The type's own half. Called before anything is written, so a build that
    # refuses leaves the document as it was.
    set own [my [dict get $record build] $name $record]
    my FieldOwnPairs $name $own

    set page [dict get $record page]
    set pairs [my FieldWidgetPairs $record {}]
    lappend pairs T [my Str $name]
    lappend pairs {*}[my FieldCommonPairs $record]
    lappend pairs {*}$own
    $writer put [dict get $record widget] [::tclpdf::pdfObj dictionary $pairs]

    set reference [$writer ref [dict get $record widget]]
    my AnnotationOnPage $page $reference
    my FieldEnlist $reference
    return $own
  }

  # ONE field with SEVERAL widgets: the field object with /Kids, and one
  # widget annotation per kid beneath it. The shape of the example in
  # 12.7.5.2.4, and the only one 12.7.4.2 leaves open - "a field dictionary
  # that does not have a partial field name (T entry) of its own shall not be
  # considered a field but simply a Widget annotation", so /T is on the parent
  # and on none of the kids.
  #
  # The parent is NOT an annotation: no /Subtype, no /Rect, no /P, and it does
  # not go into any page's /Annots. The kids do, each on the page it names.
  method FieldWriteKids {name record} {
    set writer [my writer]
    set entries [lmap entry [dict get $record widgets] {
      dict set entry name $name
      dict set entry data [dict get $record data]
      my FieldMeasure $name $entry "field \"$name\" -widgets"
    }]
    dict set record widgets $entries

    # Both halves of the type are called before anything is written, for the
    # reason the merged field calls its one: a build that refuses has to leave
    # the document as it was.
    set own [my [dict get $record build] $name $record]
    my FieldOwnPairs $name $own
    set kidPairs [lmap entry $entries {
      set pairs [my [dict get $record kid] $name $entry]
      my FieldOwnPairs $name $pairs
      set pairs
    }]

    set parent [$writer ref [dict get $record field]]
    set kids {}
    foreach entry $entries pairs $kidPairs {
      set page [dict get $entry page]
      # The annotation half comes from the same place the merged field's does.
      # /T, /TU and /Ff are NOT in it: they belong to the field and stand on
      # the parent, where a kid inherits them from (12.7.4.2).
      set widget [my FieldWidgetPairs $entry $parent]
      lappend widget {*}$pairs
      $writer put [dict get $entry widget] [::tclpdf::pdfObj dictionary $widget]
      set reference [$writer ref [dict get $entry widget]]
      my AnnotationOnPage $page $reference
      lappend kids $reference
    }

    set pairs [list T [my Str $name]]
    lappend pairs {*}[my FieldCommonPairs $record]
    lappend pairs Kids [::tclpdf::pdfObj arr $kids]
    lappend pairs {*}$own
    $writer put [dict get $record field] [::tclpdf::pdfObj dictionary $pairs]
    my FieldEnlist $parent
    foreach pairs $kidPairs {
      if {[dict exists $pairs DA]} {
        dict set own DA [dict get $pairs DA]
      }
    }
    return $own
  }

  # THE ANNOTATION HALF OF A WIDGET, and the ONE place it is built. A field
  # with one widget merges it into the field dictionary (12.5.6.19) and a
  # field with several puts it on every kid, but both are widget annotations
  # and both need the same keys, so there is one writer of them and a change
  # to one is a change to both.
  #
  # It was two writers for the length of one afternoon and the price was
  # measured on the spot: /F fell out of the merged half while the kids kept
  # it, veraPDF failed the file on 6.3.2-1 - "all annotation dictionaries
  # shall contain the F key" - and the whole test suite stayed green, because
  # nothing had ever asked for that key on its own. tests/field.test does now.
  #
  # /F 4 is Print (Table 167). An archived document has to look the same
  # printed as on screen, and a validator rejects a widget that could differ -
  # the same reason link.tcl sets it on every link.
  method FieldWidgetPairs {record parent} {
    set pairs [list Type /Annot Subtype /Widget \
        Rect [dict get $record rectangle] \
        P [[my writer] ref \
            [dict get [my Page [dict get $record page]] number]]]
    if {$parent ne {}} {
      lappend pairs Parent $parent
    }
    lappend pairs F 4
    # /Contents is this WIDGET's description, and only a field with several
    # of them has one to give: ISO 14289-2, 8.10.2.4. See [FieldDeclare] for
    # why -contents goes with -widgets and nowhere else.
    if {[dict exists $record contents] && [dict get $record contents] ne {}} {
      lappend pairs Contents [my Str [dict get $record contents]]
    }
    # /StructParent, the annotation's half of the join to its Form element
    # (14.7.5.4). Empty in a document that is not tagged, where there is no
    # element to point at - and a key pointing into a parent tree that does
    # not exist is worse than none.
    if {[dict exists $record structParent]
        && [dict get $record structParent] ne {}} {
      lappend pairs StructParent [dict get $record structParent]
    }
    return $pairs
  }

  # /TU and /Ff - the keys the core writes for every FIELD alike, in the order
  # both objects put them in. They are the field's rather than the widget's,
  # which is why they are not in [FieldWidgetPairs]: a field with kids carries
  # them on the parent, and the parent is no annotation.
  method FieldCommonPairs {record} {
    set pairs {}
    if {[dict get $record tooltip] ne {}} {
      # /TU is the alternate description, and PDF/UA makes it the text a
      # screen reader announces for the field (ISO 14289-1, 7.18.1). Left
      # out where nothing was said rather than filled with the field name,
      # which would be a description that describes nothing.
      lappend pairs TU [my Str [dict get $record tooltip]]
    }
    if {[dict get $record flags]} {
      lappend pairs Ff [dict get $record flags]
    }
    return $pairs
  }

  # The three keys the core adds to a record before a build sees it, and the
  # check that the page it names is there to put a widget on. One place,
  # because a field with one widget and a widget of a field with several ask
  # the same question of the same page, and two copies of the question are two
  # answers waiting to differ.
  method FieldMeasure {name record what} {
    set page [dict get $record page]
    if {$page >= [my page count]} {
      return -code error -errorcode [list TCLPDF FIELD PAGE $page] \
          "tclpdf: field \"$name\" names page $page and this document has\
          [my page count] page(s) - a widget annotation sits on a page, and\
          that page has to exist when the file is written"
    }
    dict set record rectangle \
        [my FieldRectangle $page [dict get $record rect] $what]
    lassign [dict get $record rect] -> -> width height
    set unit [my cget -unit]
    dict set record extent [list $width $height]
    dict set record size [list [::tclpdf::geometry toPoints $width $unit] \
        [::tclpdf::geometry toPoints $height $unit]]
    return $record
  }

  # Into the page's /Annots, the same scratch state link.tcl and sign.tcl use
  # - once, however often the document is written.

  # What a build may and may not answer - point 4 of the contract at the head
  # of this file, and the same check for the field's pairs and for a kid's.
  # Two things are refused, and for two different reasons: a key the core
  # writes, because two writers over one key is a widget on the wrong page, a
  # field under the wrong name or a flag set twice and none of the three says
  # which call did it; and a key on neither list, because the list IS
  # exhaustive and what is not on it is a misspelling that lands in the file
  # and that no validator here mentions.
  method FieldOwnPairs {name pairs} {
    variable ::tclpdf::field::ownKeys
    variable ::tclpdf::field::coreKeys
    if {[llength $pairs] % 2} {
      return -code error -errorcode [list TCLPDF FIELD BUILD $name] \
          "tclpdf: the build of field \"$name\" answered an odd number of\
          items - it answers PDF dictionary pairs, key and value (see the\
          contract at the head of field.tcl, point 4)"
    }
    foreach {key value} $pairs {
      if {$key in $coreKeys} {
        return -code error -errorcode [list TCLPDF FIELD BUILD $name $key] \
            "tclpdf: the build of field \"$name\" answered /$key, and that\
            key belongs to the field core - [join $coreKeys {, }] are written\
            for every field alike. A field type answers only what is its own:\
            [join $ownKeys {, }] (see the contract at the head of field.tcl,\
            point 4)"
      }
      if {$key ni $ownKeys} {
        return -code error -errorcode [list TCLPDF FIELD BUILD $name $key] \
            "tclpdf: the build of field \"$name\" answered /$key, and a field\
            type answers only the keys point 4 of the contract at the head of\
            field.tcl names: [join $ownKeys {, }]. That list is exhaustive,\
            because a key outside it is either a misspelling - which lands in\
            the file and which no validator on this machine mentions - or a\
            key of ISO 32000-2 this package has not built yet, and the place\
            to add one is the list itself"
      }
    }
    return
  }

  # An appearance stream for one field and one state. Point 5 of the
  # contract.
  #
  # The script draws into a canvas the size of the widget, so every drawing
  # method works unchanged and {0 0} is the top left corner - the arrangement
  # [form create] uses, down to the same two methods, because an appearance
  # stream IS a form XObject with a bounding box (12.5.5, 12.7.4.3).
  #
  # It is NOT registered as an /XObject resource: an appearance is reached
  # through /AP and through nothing else, and a name in the resource
  # dictionary would offer it to any content stream that cared to say Do.
  method FieldAppearanceStream {record slot script} {
    lassign [dict get $record size] width height
    set number [my reservation field.ap.[dict get $record name].$slot]
    my FormBegin $width $height
    # ONE frame up, not the global one: the script is the field type's own -
    # written inside its build method - so it says [my] and it reads the
    # build's variables. [form create] runs the CALLER's script at #0 and
    # pays for it to this day (see xObject.tcl); here the script belongs to
    # the module, and the frame it was written in is the only one it makes
    # sense in.
    set failed [catch {uplevel 1 $script} result info]
    set content [my FormEnd]
    if {$failed} {
      return -options $info $result
    }
    set pairs [list Type /XObject Subtype /Form FormType 1 \
        BBox [::tclpdf::pdfObj arr [list 0 0 \
            [::tclpdf::pdfObj num $width] [::tclpdf::pdfObj num $height]]]]
    # PDF/A 6.2.2: a content stream that references another object - a font -
    # must have its OWN Resources dictionary; inheriting is valid PDF and
    # forbidden there. The same one indirect object every page points at, so
    # nothing is embedded twice.
    lappend pairs Resources [[my writer] ref [my reservation output.resources]]
    my streamObject $pairs $content $number
    return [[my writer] ref $number]
  }

  # Put a widget into the document's field tree. The ONE road to /AcroForm -
  # sign.tcl travels it as well, with -sigflags 3 for its signature field.
  #
  # Idempotent by construction: the same reference twice is one entry, and
  # the flags are OR-ed rather than replaced, so the order the two modules
  # write in decides nothing.
  method FieldEnlist {reference args} {
    set options [::tclpdf::option parse {sigflags 0} $args "field enlist"]
    if {![string is integer -strict [dict get $options sigflags]]
        || [dict get $options sigflags] < 0} {
      return -code error -errorcode \
          [list TCLPDF FIELD SIGFLAGS [dict get $options sigflags]] \
          "tclpdf: -sigflags of field enlist is the /SigFlags integer of ISO\
          32000-2, Table 225 - 1 for SignaturesExist, 3 with AppendOnly - not\
          \"[dict get $options sigflags]\""
    }
    set entries [my state fieldEntries]
    if {$reference ni $entries} {
      lappend entries $reference
      my state fieldEntries $entries
    }
    set flags [my state fieldSigFlags]
    if {$flags eq {}} {
      set flags 0
    }
    my state fieldSigFlags [expr {$flags | [dict get $options sigflags]}]
    if {[my state fieldCatalogHooked] eq {}} {
      my state fieldCatalogHooked 1
      my onSelf catalog FieldCatalog
    }
    return $reference
  }

  # /AcroForm (Table 224). Runs on the catalog event and is idempotent: it
  # creates nothing, it rewrites one catalogue key out of the state.
  #
  # /DA and /DR are written only where there is something to resolve them for:
  # a field with variable text, or a type that answered a /DA of its own. A
  # document whose only field is the signature has neither - and comes out
  # exactly as it did before this module existed, which is what tests/sign.test
  # measures - and neither has a form of nothing but buttons, which is the
  # point 6 of the contract at the head of this file goes into.
  method FieldCatalog {} {
    set entries [my state fieldEntries]
    if {![llength $entries]} {
      return
    }
    set pairs [list Fields [::tclpdf::pdfObj arr $entries]]
    set flags [my state fieldSigFlags]
    if {$flags ne {} && $flags} {
      lappend pairs SigFlags $flags
    }
    # NO /NeedAppearances - see the head of this file. The key is deprecated
    # in PDF 2.0 (Table 224), its absence means false, and false is what a
    # reader is told either way.
    #
    # /DA, the document-wide default appearance (Table 224). Required on every
    # field with VARIABLE TEXT and inheritable, so a fallback at the form
    # level is what covers a field that ever comes without one - and written
    # for a document that has such a field and for no other, see [FieldWrite].
    if {[my state fieldDa] ne {}} {
      lappend pairs DA [my Str [my state fieldDa]]
    }
    # /DR, the default resources a field's /DA is resolved against (Table
    # 224). The document's own resource dictionary, which is where the fonts
    # named in every /DA were registered - one object, not a second copy of
    # the same font entries. Written wherever there is a /DA to resolve, the
    # document's own or a type's.
    if {[my state fieldResources] ne {} && [my state fieldResources]} {
      lappend pairs DR [[my writer] ref [my reservation output.resources]]
    }
    my catalogEntry AcroForm [::tclpdf::pdfObj dictionary $pairs]
    return
  }

  # -- the default appearance -----------------------------------------------

  # $doc field default ?-family f? ?-style s? ?-size n? ?-color c?
  #
  # The font a field is set in when it names none, and the /DA of the
  # /AcroForm itself. Read with no arguments - which is also how the text
  # field asks for it, so the defaults exist in one place rather than one
  # here and one there.
  method FieldDefault {args} {
    set current [my state fieldDefault]
    if {$current eq {}} {
      # Helvetica at 10 points in black: the font a form is set in unless
      # someone says otherwise, and one of the fourteen standard faces, so a
      # document that declares a field embeds nothing it did not ask for.
      set current [dict create family helvetica style {} size 10 color black]
    }
    if {![llength $args]} {
      return $current
    }
    set options [::tclpdf::option parse $current $args "field default"]
    if {![string is double -strict [dict get $options size]]
        || [dict get $options size] <= 0} {
      return -code error -errorcode \
          [list TCLPDF FIELD SIZE [dict get $options size]] \
          "tclpdf: -size of field default is a font size in points above\
          zero, not \"[dict get $options size]\""
    }
    # Both are checked by building the string they will produce - a family
    # that does not resolve or a colour with no /DA spelling has to be
    # refused here, at the call that named it, and not inside a catalogue
    # entry at write time.
    my FieldFont [dict get $options family] [dict get $options style] \
        [dict get $options size] [dict get $options color] "field default"
    my state fieldDefault $options
    return $options
  }

  # The /AcroForm's own default appearance string.
  method FieldDaDefault {} {
    set current [my FieldDefault]
    return [dict get [my FieldFont [dict get $current family] \
        [dict get $current style] [dict get $current size] \
        [dict get $current color] "field default"] da]
  }

  # A default appearance string (12.7.4.3): the font operator and the colour
  # operator, in the content stream syntax of 9.3 and 8.6, as one text
  # string. Anything left empty falls back to [field default].
  #
  # 12.7.4.3 on what it has to contain: "At a minimum, the string shall
  # include a Tf (text font) operator along with its two operands, font and
  # size. The specified font value shall match a resource name in the Font
  # entry of the default resource dictionary" - which is /DR. So the font
  # resource is registered on the way through: [TextResource] puts it into
  # the document's own resource dictionary, and that dictionary IS /DR.
  #
  # THIS IS THE SEAM WHERE A FORM BREAKS, and it breaks silently. A /DA that
  # names a font /DR does not have passes "qpdf --check" without a word and
  # is even given an /AP by "qpdf --generate-appearances" - one that calls a
  # font that is not there, which Acrobat draws as nothing. Measured
  # 2026-08-23; the one tool on this machine that catches it is PDFBox, whose
  # setValue throws "Could not find font: /Xyzz". Asking the text module for
  # the name rather than spelling one is what keeps the two ends together,
  # and it is also what makes an embedded face usable in a field:
  # [TextResource] answers for either kind.
  #
  # A size of zero is never written. It is legal and it means auto-size -
  # "its size shall be computed as an implementation dependent function"
  # (12.7.4.3) - and a package that draws the appearance itself would then
  # not know what a reader redrawing it will do. [FieldDefault] and
  # [FieldText] in fieldText.tcl both refuse a size of zero for this reason.
  method FieldFont {family style size colour what} {
    set current [my state fieldDefault]
    if {$current eq {}} {
      set current [dict create family helvetica style {} size 10 color black]
    }
    if {$family eq {}} {
      set family [dict get $current family]
      if {$style eq {}} {
        set style [dict get $current style]
      }
    }
    if {$size eq {}} {
      set size [dict get $current size]
    }
    if {$colour eq {}} {
      set colour [dict get $current color]
    }
    # [TextInit] has to have run before the text state can be resolved, and
    # [font] with no arguments is the one call that does it and says so.
    my font
    if {[catch {my TextResolve $family $style} resolved]} {
      return -code error -errorcode [list TCLPDF FIELD FONT $family] \
          "tclpdf: the font of $what cannot be resolved: $resolved. A field is\
          set in one of the fourteen standard faces or in a face embedded\
          with \"font embed\", and the name goes into the /DA of ISO 32000-2,\
          12.7.4.3"
    }
    set parsed [::tclpdf::color parse $colour]
    if {[lindex $parsed 0] ni {gray rgb cmyk}} {
      return -code error -errorcode \
          [list TCLPDF FIELD COLOURSPACE [lindex $parsed 0]] \
          "tclpdf: the colour of $what is a [lindex $parsed 0] colour, and a\
          default appearance string holds no colour space resource - /DA is\
          read outside any content stream (ISO 32000-2, 12.7.4.3), so the\
          name of a space would resolve against nothing. Name the text colour\
          in grey, RGB or CMYK"
    }
    # BOTH halves come back: the string for the /DA, and the values that went
    # into it. The appearance stream has to be drawn in the very font the /DA
    # names, and reading it back out of the document's text state at write
    # time is what made a field come out in courier because the last [font]
    # call before the write happened to say so - measured 2026-08-23 on the
    # example. So the values are settled HERE, at the declaration, and
    # travel with the field.
    return [dict create \
        da "[my TextResource $resolved] [::tclpdf::pdfObj num $size] Tf\
            [::tclpdf::color operator $parsed fill]" \
        family $family style $style size $size colour $colour]
  }
}

package provide tclpdf::field 1.0
