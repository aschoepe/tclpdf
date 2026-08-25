#
# tclpdf - PDF generation for Tcl
#
# annot - the annotations that say something about a page (ISO 32000-2, 12.5.6)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Usage:
#
#   $doc annot note -at {20 30} -contents "Please check this figure"
#   $doc annot stamp -at {20 40} -name Approved -contents "Approved"
#   $doc annot highlight -text "the amount due" -at {20 60} \
#       -contents "the amount due"
#   $doc annot underline -quads {{20 70 40 5}} -contents "the term"
#
# WHAT THIS FILE IS. The CORE of the annotations that carry a remark rather
# than a behaviour, and two of the kinds: the sticky note (/Text) and the
# rubber stamp (/Stamp). The core is the annotation dictionary itself - the
# rectangle, the flags, the colour, the description, the appearance, the
# structure element, and the conformance every claim asks of all of them.
#
# The four TEXT MARKUPS - /Highlight, /Underline, /StrikeOut, /Squiggly - are
# a module of their own, annotMark.tcl, and attach through the table of kinds
# below. They mark a passage that is already on the page, which brings two
# questions this file does not have: where the marked words stand, and how
# the band over them is drawn. The note and the stamp have neither.
#
# The two annotations that DO something - the link and the widget of a form
# field - are topics of their own and stay there: link.tcl and field.tcl.
# What all of them share is one line of state, [state annots], which
# output.tcl reads when it writes a page; nothing else is common between a
# clickable rectangle and a note in the margin.
#
# THE APPEARANCE IS THE WHOLE QUESTION, and it is answered differently per
# kind because the kinds differ in whether this package can know what the
# picture is:
#
#   note, stamp -name    THE VIEWER DRAWS IT. /Name picks one of a fixed set
#                        of symbols (Table 174 for the note, Table 181 for the
#                        stamp) and the standard leaves the drawing to the
#                        reader on purpose: a note looks like the reader's
#                        other notes. This package does not invent a comment
#                        balloon of its own, because a drawn balloon is this
#                        package's balloon on every reader and no longer the
#                        reader's own.
#   -appearance <form>   THE CALLER DRAWS IT, with [form create], and the form
#                        XObject becomes /AP /N. That is what a house stamp
#                        is, and it is the same road the visible signature
#                        travels (sign.tcl, -appearance) - down to naming a
#                        form rather than taking a script, because an
#                        appearance stream IS a form XObject (12.5.5).
#   text markup          THIS PACKAGE DRAWS IT, always, and no caller ever
#                        asks for it. It can: the quadrilaterals and the
#                        colour are the whole picture, and a highlight is one
#                        filled rectangle per quad under the Multiply blend
#                        mode. That is annotMark.tcl's, and it is why the
#                        four markups are the one kind here that no claim
#                        ever refuses.
#
# AND THAT IS WHY A DOCUMENT WITH A CLAIM REFUSES THE FIRST OF THE THREE.
# ISO 32000-2, 12.5.2, Table 166 under /AP: "A PDF writer shall include an
# appearance dictionary ... Every annotation ... shall have at least one
# appearance dictionary", with Popup, Projection and Link the only exceptions.
# veraPDF fails a PDF/A file without one under clause 6.3.3, "An annotation
# does not contain an appearance dictionary" - measured 2026-08-24 on a
# PDF/A-3B document carrying one note. So a note or a stamp WITHOUT
# -appearance is refused where the document claims PDF/A, by name and with
# the way out - it is not written and left for the recipient's validator to
# find. The text markups need no such refusal, having drawn their own.
#
# UNDER PDF/A AND NOWHERE ELSE, which is a measurement rather than a reading.
# Table 166 belongs to the base standard and speaks of every PDF 2.0 file, not
# of a claim; ISO 32000-1, Table 164 has /AP as optional outright. So a note
# in a plain document is written as it always was, and so is one in a PDF/UA
# document of either part - measured, veraPDF's ua1 and ua2 profiles both
# pass a note without an appearance, 0 failed checks. What PDF/UA does ask
# for is below, and it is something else entirely.
#
# The refusal is made TWICE, from one method: at the call, where the message
# can name the call that has to change, and again on beforeWrite, because a
# document declares its conformance and its annotations in either order and
# only the write sees both. Same reason fieldButton.tcl checks its reset
# action at the write.
#
# PDF/UA, AND THE CALLER DOES NOTHING FOR IT BEYOND [$doc tagged 1]. Two
# halves, both the same shape as the form's (field.tcl, [FieldStructure]):
#
#   Annot        one structure element per annotation, opened inside whatever
#                element is open at the call - which is what puts it in
#                reading order (ISO 32000-1, 14.8.4.2, Table 337: "Annot - an
#                annotation, other than a link or a widget"; a link goes in a
#                Link and a widget in a Form, which is why those two live
#                elsewhere).
#   StructParent the annotation reaches its element back through the parent
#                tree (14.7.5.4); [StructureAnnotation] writes the OBJR into
#                the element and answers the key.
#
# and /Contents, the description a reader announces, which is the caller's
# word and cannot be derived: required under a PDF/UA claim, refused without,
# and named at the write.
#
# WHAT IS DELIBERATELY NOT BUILT: the popup window (/Popup, Table 172) and
# the reply chain (/IRT, /RT), which are a review workflow rather than a
# document; the rich-text /RC of Table 170, whose contents are an XFA
# fragment and therefore forbidden by ISO 14289-2, 8.10.1 wherever it would
# matter; and /Name values outside the tables, which are legal - 12.5.6.12
# admits further names - and which no two readers agree on. A stamp that is
# not one of the fourteen is a stamp the caller draws, and -appearance is
# how.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::color 1.0-
package require tclpdf::geometry 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::annot {
  # The symbols a note may carry (ISO 32000-2, 12.5.6.4, Table 174). The
  # reader draws whichever of them it has; the list is closed here because a
  # name outside it means nothing to a reader and shows as nothing at all.
  variable icons {Comment Key Note Help NewParagraph Paragraph Insert}

  # The rubber stamps of ISO 32000-1, Table 181, in the order the table has
  # them. ISO 32000-2 admits further names and no reader on this machine
  # draws them, so the list stays at the fourteen every reader knows; a stamp
  # of one's own goes through -appearance.
  variable stamps {Approved Experimental NotApproved AsIs Expired \
      NotForPublicRelease Confidential Final Sold Departmental ForComment \
      TopSecret Draft ForPublicRelease}

  # THE TABLE OF FURTHER KINDS, one line per module shipped in the tree, so
  # that [$doc annot highlight] loads the module that provides it without the
  # caller requiring it by hand - the same arrangement field.tcl keeps for
  # its field types, and for the same reason: the dispatcher has to know the
  # word before the file that answers it is loaded.
  variable kinds {
    highlight  tclpdf::annotMark
    underline  tclpdf::annotMark
    strikeout  tclpdf::annotMark
    squiggly   tclpdf::annotMark
    line       tclpdf::annotShape
    square     tclpdf::annotShape
    circle     tclpdf::annotShape
    polygon    tclpdf::annotShape
    polyline   tclpdf::annotShape
    attachment tclpdf::annotShape
  }

  # Which method each module answers with. annotMark provides [AnnotMarkup]
  # and annotShape [AnnotShape]; the dispatcher checks that the method is
  # there before it calls, so a module that does not keep its side of the
  # bargain says so by name rather than failing three frames down.
  variable entries {
    tclpdf::annotMark  AnnotMarkup
    tclpdf::annotShape AnnotShape
  }
}

oo::define ::tclpdf::document::document {

  # $doc annot note      -at {x y} -contents text ?-icon Note? ...
  # $doc annot stamp     -at {x y} -name Approved | -appearance form ...
  # $doc annot highlight -text "..." -at {x y} ?-align right? ...
  # $doc annot highlight -at {x y} -lines [$doc textLines $text -width 170] ...
  # $doc annot highlight -quads {{x y w h} ...} ...
  # $doc annot underline | strikeout | squiggly - the same options
  #
  # Answers the object number of the annotation, as [link] does.
  method annot {kind args} {
    variable ::tclpdf::annot::kinds
    switch -- $kind {
      note {return [my AnnotNote {*}$args]}
      stamp {return [my AnnotStamp {*}$args]}
      default {
        if {[dict exists $kinds $kind]} {
          variable ::tclpdf::annot::entries
          set module [dict get $kinds $kind]
          package require $module
          # Named rather than assumed: a module that answers the word it was
          # registered for is the whole contract, and one that does not has
          # to say so here rather than fail as an unknown method three frames
          # down. -private matters - the entry is not an exported method.
          set entry [dict get $entries $module]
          if {$entry ni [info object methods [self] -all -private]} {
            return -code error -errorcode [list TCLPDF ANNOT MODULE $kind] \
                "tclpdf: the module $module does not provide \"annot $kind\""
          }
          return [my $entry $kind {*}$args]
        }
        return -code error -errorcode [list TCLPDF ANNOT KIND $kind] \
            "tclpdf: unknown annotation \"$kind\" - known are: note, stamp,\
            [join [dict keys $kinds] {, }]. A clickable rectangle is\
            \[\$doc link\] and a form control is \[\$doc field\]; both are\
            annotations too and both are topics of their own"
      }
    }
  }

  # -- the note (12.5.6.4) --------------------------------------------------

  # A closed sticky note: a symbol on the page, and the text behind it.
  #
  # -contents is required and is not decoration - it IS the note. An empty
  # note is a symbol that says nothing when it is opened, and under a PDF/UA
  # claim it is the description as well.
  method AnnotNote {args} {
    variable ::tclpdf::annot::icons
    set options [::tclpdf::option parse {
      at {} size {} contents {} title {} icon Note colour {} color {}
      open 0 opacity {} appearance {} date {}
    } $args "annot note"]
    set options [my AnnotColourOption $options "annot note"]
    if {[dict get $options at] eq {}} {
      return -code error -errorcode {TCLPDF ANNOT NOTE AT} \
          "tclpdf: annot note needs -at {x y} - the top left corner of the\
          box the symbol is drawn in"
    }
    if {[dict get $options contents] eq {}} {
      return -code error -errorcode {TCLPDF ANNOT NOTE CONTENTS} \
          "tclpdf: annot note needs -contents - the text of the note is what\
          /Contents holds (ISO 32000-2, Table 168), and a note without it is\
          a symbol that opens onto nothing"
    }
    if {[dict get $options icon] ni $icons} {
      return -code error -errorcode \
          [list TCLPDF ANNOT NOTE ICON [dict get $options icon]] \
          "tclpdf: -icon of annot note names the symbol a reader draws (ISO\
          32000-2, Table 174) - known are: [join $icons {, }] - not\
          \"[dict get $options icon]\". A symbol of your own is not one of\
          these: draw it with \[\$doc form create\] and pass -appearance"
    }
    if {![string is boolean -strict [dict get $options open]]} {
      return -code error -errorcode \
          [list TCLPDF ANNOT NOTE OPEN [dict get $options open]] \
          "tclpdf: -open of annot note takes a boolean - whether the note is\
          shown unfolded (/Open, Table 178) - not \"[dict get $options open]\""
    }
    # /Open and /Name are PDF 1.0, so nothing is required beyond what a
    # document already is; the annotation flags below are 1.1, as they are
    # for a link.
    my RequireVersion 1.1 "annot note"
    # The default box is the 20 by 20 points every reader draws its note
    # symbol in - the /Rect of a Text annotation does not scale the symbol
    # (12.5.6.4: "the annotation ... shall be drawn at a fixed size"), so the
    # number matters only for where the symbol sits and what a reader
    # highlights when the note is selected.
    set size [dict get $options size]
    if {$size eq {}} {
      set edge [::tclpdf::geometry fromPoints 20 [my cget -unit]]
      set size [list $edge $edge]
    }
    set rect [my AnnotRectangle [dict get $options at] $size "annot note"]
    set pairs [list Name [::tclpdf::pdfObj name [dict get $options icon]]]
    if {[dict get $options open]} {
      lappend pairs Open true
    }
    # Print, NoZoom and NoRotate - 4 + 8 + 16 of Table 167. The last two are
    # what a fixed-size symbol means: a note that grew with the zoom or turned
    # with the page would be the only thing on the page that did. Acrobat
    # writes the same 28, and ISO 19005-1, 6.5.2 required it outright of a
    # Text annotation; parts 2 and 3 dropped the sentence and the behaviour is
    # right either way.
    return [my AnnotWrite Text $rect $options $pairs 28]
  }

  # -- the stamp (12.5.6.12) ------------------------------------------------

  # A rubber stamp: one of the fourteen names every reader knows, or a form
  # XObject the caller drew.
  method AnnotStamp {args} {
    variable ::tclpdf::annot::stamps
    set options [::tclpdf::option parse {
      at {} size {} name {} contents {} title {} colour {} color {}
      opacity {} appearance {} date {}
    } $args "annot stamp"]
    set options [my AnnotColourOption $options "annot stamp"]
    if {[dict get $options at] eq {}} {
      return -code error -errorcode {TCLPDF ANNOT STAMP AT} \
          "tclpdf: annot stamp needs -at {x y} - the top left corner of the\
          rectangle the stamp is laid in"
    }
    # The two roads are exclusive, and saying both is a caller who has not
    # decided which picture is meant: /Name is the reader's stamp, /AP is
    # this one, and Table 166 makes /AP win - so the /Name would be written
    # and never seen.
    if {[dict get $options name] ne {} && [dict get $options appearance] ne {}} {
      return -code error -errorcode {TCLPDF ANNOT STAMP BOTH} \
          "tclpdf: annot stamp takes -name or -appearance, not both - with an\
          appearance stream present a reader draws that and never looks at\
          /Name (ISO 32000-2, Table 166)"
    }
    if {[dict get $options name] eq {} && [dict get $options appearance] eq {}} {
      return -code error -errorcode {TCLPDF ANNOT STAMP NAME} \
          "tclpdf: annot stamp needs -name or -appearance - either one of the\
          stamps a reader draws itself ([join $stamps {, }]), or the name of a\
          form built with \[\$doc form create\], which is what a house stamp\
          is"
    }
    if {[dict get $options name] ne {} && [dict get $options name] ni $stamps} {
      return -code error -errorcode \
          [list TCLPDF ANNOT STAMP NAME [dict get $options name]] \
          "tclpdf: -name of annot stamp is one of the stamps of ISO 32000-1,\
          Table 181 - [join $stamps {, }] - not \"[dict get $options name]\".\
          A stamp of your own is drawn with \[\$doc form create\] and named to\
          -appearance; ISO 32000-2 admits further /Name values and no reader\
          here draws one"
    }
    # The stamp's own size where the caller drew one and named no size: the
    # form knows how big it is, and repeating the numbers is how the two come
    # to disagree. [form create] keeps them in points.
    set size [dict get $options size]
    if {$size eq {} && [dict get $options appearance] ne {}} {
      set form [my AnnotForm [dict get $options appearance] "annot stamp"]
      set size [list \
          [::tclpdf::geometry fromPoints [dict get $form width] [my cget -unit]] \
          [::tclpdf::geometry fromPoints [dict get $form height] [my cget -unit]]]
    }
    if {$size eq {}} {
      return -code error -errorcode {TCLPDF ANNOT STAMP SIZE} \
          "tclpdf: annot stamp needs -size {w h} - a stamp a reader draws\
          itself is stretched into the rectangle it is given, and there is\
          nothing to derive one from. With -appearance the form's own size is\
          used where none is named"
    }
    set rect [my AnnotRectangle [dict get $options at] $size "annot stamp"]
    # 1.3 is where the stamp appears (Reference 1.7, Table 8.20).
    my RequireVersion 1.3 "annot stamp"
    set pairs {}
    if {[dict get $options name] ne {}} {
      lappend pairs Name [::tclpdf::pdfObj name [dict get $options name]]
    }
    return [my AnnotWrite Stamp $rect $options $pairs 4]
  }


  # -- what every annotation here has in common -----------------------------

  # -colour and -color are the same option, and one of them wins. Written out
  # here rather than in three parsers: the package spells its options in
  # British English and the American spelling is taken everywhere it is
  # offered, but a caller who writes both has said two things.
  method AnnotColourOption {options context} {
    if {[dict get $options color] eq {}} {
      return $options
    }
    if {[dict get $options colour] ne {}} {
      return -code error -errorcode [list TCLPDF ANNOT COLOUR $context] \
          "tclpdf: $context was given -colour and -color, which are the same\
          option spelled two ways - pass one of them"
    }
    dict set options colour [dict get $options color]
    return $options
  }

  # The /Rect of an annotation, from {x y} and {w h} in the caller's unit and
  # counted from the top left corner - the same arithmetic [link] does, and
  # the same one [rect] does, because a caller who can place a rectangle can
  # place an annotation over it.
  method AnnotRectangle {at size context} {
    if {[llength $at] != 2} {
      return -code error -errorcode [list TCLPDF ANNOT RECT AT $at] \
          "tclpdf: -at of $context is {x y}, not \"$at\""
    }
    if {[llength $size] != 2} {
      return -code error -errorcode [list TCLPDF ANNOT RECT SIZE $size] \
          "tclpdf: -size of $context is {width height}, not \"$size\""
    }
    lassign $at left top
    lassign $size width height
    foreach value [list $left $top $width $height] {
      if {![string is double -strict $value]} {
        return -code error -errorcode [list TCLPDF ANNOT RECT NUMBER $value] \
            "tclpdf: $context takes numbers for -at and -size, not \"$value\""
      }
    }
    if {$width <= 0 || $height <= 0} {
      return -code error -errorcode [list TCLPDF ANNOT RECT EMPTY $size] \
          "tclpdf: -size of $context is {$size} - an annotation needs a width\
          and a height above zero, or no reader shows it"
    }
    lassign [my coords $left [expr {$top + $height}]] x0 y0
    lassign [my coords [expr {$left + $width}] $top] x1 y1
    return [dict create left $left top $top width $width height $height \
        array [::tclpdf::pdfObj arr [list \
            [::tclpdf::pdfObj num $x0] [::tclpdf::pdfObj num $y0] \
            [::tclpdf::pdfObj num $x1] [::tclpdf::pdfObj num $y1]]]]
  }

  # Build the dictionary, write it, hang it in the tree, and remember what
  # was written for the conformance check. The one road out of this file.
  #
  # EVERYTHING THAT CAN BE REFUSED IS REFUSED FIRST, before a byte reaches
  # the writer and before an element reaches the tree: after a refused call
  # the document has to look as if the call never happened. The three
  # refusals of [AnnotCheck] all rest on facts that are known before anything
  # is written - whether there will be an appearance, whether a description
  # was given, whether the document is tagged - so the record is built up
  # front and checked twice, once here and once at the write.
  #
  # The object number is reserved BEFORE the dictionary is written, because
  # the /StructParent that goes into it can only be asked for once the object
  # has a number - the same order [link] keeps, and for the same reason.
  # "builder", where it is given, is the name of a method and its leading
  # arguments; [AnnotWrite] appends the appearance's own name, the rectangle
  # and the options and calls it to get the /AP /N reference.
  #
  # THE APPEARANCE IS BUILT BEFORE THE NUMBER IS RESERVED, and that order is
  # the fix of 2026-08-25 rather than a preference. It used to be the other
  # way round, because the appearance was written under a reservation named
  # after the annotation's object number - and a drawing script that raised
  # then left that number reserved and never filled, so the NEXT [write] of
  # the whole document died with "object(s) reserved but never written",
  # although the caller had caught the error and carried on. Measured at
  # "annot polygon" with a malformed colour and reproduced at "annot
  # highlight", which had carried the defect since the markups were built;
  # [annot note] and [annot stamp] were never affected, because everything
  # they can refuse stands before the reservation.
  #
  # What the appearance needs is not the object number but a name that is the
  # SAME on a second [write] of the same document - otherwise a rerun writes
  # a second copy beside the first. A counter of its own gives that: the
  # calls come in the same order every time, which is exactly what makes the
  # object numbers stable too.
  method AnnotWrite {subtype rect options pairs flags {quads {}} {builder {}}} {
    set record [dict create subtype $subtype number {} \
        page [my page current] contents [dict get $options contents] \
        appearance [expr {[dict get $options appearance] ne {}
            || [llength $quads] > 0 || [llength $builder] > 0}] \
        structured [expr {[my state tagged] eq "1"}]]
    my AnnotCheck $record
    set serial [my state annotSerial]
    if {$serial eq {}} {
      set serial 0
    }
    my state annotSerial [incr serial]
    set appearance {}
    if {[dict get $options appearance] ne {}} {
      set appearance [my AnnotAppearance [dict get $options appearance] \
          "annot [string tolower $subtype]"]
    } elseif {[llength $quads]} {
      set appearance [my AnnotMarkupAppearance $subtype $serial $rect $quads \
          [dict get $options colour]]
    } elseif {[llength $builder]} {
      set appearance [my {*}$builder $serial $rect $options]
    }
    # Nothing is reserved until here, so a refusal above leaves the writer as
    # it was and the document still writes.
    set number [[my writer] reserve]
    set all [list Type /Annot Subtype [::tclpdf::pdfObj name $subtype] \
        Rect [dict get $rect array] \
        Border [::tclpdf::pdfObj arr {0 0 0}] \
        F $flags]
    if {[dict get $options contents] ne {}} {
      lappend all Contents [my Str [dict get $options contents]]
    }
    if {[dict get $options title] ne {}} {
      # /T is the annotation's OWNER - the person the remark is from
      # (Table 170) - and a reader puts it in the title bar of the note.
      lappend all T [my Str [dict get $options title]]
    }
    if {[dict get $options colour] ne {}} {
      lappend all C [my AnnotColourArray [dict get $options colour]]
    }
    if {[dict get $options opacity] ne {}} {
      # /CA fades the WHOLE annotation, appearance and all (12.5.5), which is
      # why the appearance streams are drawn opaque: an alpha in both places
      # multiplies, and a highlight asked for at 0.5 came out at 0.25.
      lappend all CA [my AnnotOpacity [dict get $options opacity]]
      my RequireVersion 1.4 "-opacity of an annotation"
    }
    if {[dict get $options date] ne {}} {
      set stamp [my AnnotDate [dict get $options date]]
      lappend all M $stamp CreationDate $stamp
    }
    if {$appearance ne {}} {
      lappend all AP [::tclpdf::pdfObj dictionary [list N $appearance]]
    }
    lappend all {*}$pairs
    if {[dict get $record structured]} {
      set key [my AnnotStructure $number]
      if {$key ne {}} {
        lappend all StructParent $key
      }
    }
    [my writer] put $number [::tclpdf::pdfObj dictionary $all]
    my AnnotationOnPage [my page current] [[my writer] ref $number]
    my AnnotRemember [dict set record number $number]
    return $number
  }

  # AN APPEARANCE STREAM, drawn by a script, in the annotation's own
  # rectangle. The one place that builds one - three modules wanted it and
  # each had written its own: annotMark for the bands, annotShape for the
  # geometry, and the shape of it again in field.tcl and xObject.tcl.
  #
  # WHAT IT ARRANGES, and why it is not two lines at each call site:
  #
  #   the space    [FormBegin] mirrors [coords] against the form's height, so
  #                every drawing method of the package works unchanged inside
  #                the script and the geometry only has to move from the
  #                page's origin to the rectangle's top left corner
  #   the failure  a script that raises has to leave the form CLOSED, or the
  #                next content written goes into a stream nobody will emit -
  #                which is a page that silently loses everything after the
  #                annotation
  #   /Resources   PDF/A 6.2.2: a content stream that references another
  #                object must carry its own, and inheriting is valid PDF and
  #                forbidden there. The same one indirect object every page
  #                points at, so nothing is written twice
  #   the object   through the reservation named, so that a document written
  #                twice writes over its own appearance instead of adding a
  #                second one
  #
  # NOT registered as an /XObject resource: an appearance is reached through
  # /AP and through nothing else, and a name in the resource dictionary would
  # offer the picture to any content stream that cared to say Do. The same
  # rule [FieldAppearanceStream] follows.
  #
  # Returns the reference to put under /AP /N.
  method AnnotAppearanceForm {rect reservation script} {
    lassign [my extent [list [dict get $rect width] [dict get $rect height]]] \
        widthPoints heightPoints
    my FormBegin $widthPoints $heightPoints
    set failed [catch {uplevel 1 $script} result info]
    set content [my FormEnd]
    if {$failed} {
      return -options $info $result
    }
    set pairs [list Type /XObject Subtype /Form FormType 1 \
        BBox [::tclpdf::pdfObj arr [list 0 0 \
            [::tclpdf::pdfObj num $widthPoints] \
            [::tclpdf::pdfObj num $heightPoints]]] \
        Resources [[my writer] ref [my reservation output.resources]]]
    return [[my writer] ref \
        [my streamObject $pairs $content [my reservation $reservation]]]
  }

  # One Annot structure element around one annotation, inside whatever
  # element is open at the call - which is what puts it in reading order
  # (ISO 14289-1, 7.18.1: "Annotations shall be represented in the structure
  # tree in correct reading order"). The shape is [FieldStructureElement]'s,
  # one type further out: a widget goes in a Form, a link in a Link, and
  # everything else in an Annot (ISO 32000-1, 14.8.4.2, Table 337).
  #
  # The refusal is rewrapped rather than passed on: [StructureOpen] answers
  # about a structure type the caller never named, and the call that has to
  # change is the [$doc annot ...] this came from.
  method AnnotStructure {number} {
    if {[catch {my StructureOpen Annot} id info]} {
      if {[dict get $info -errorcode] ne "NONE"} {
        return -options $info $id
      }
      return -code error -errorcode {TCLPDF ANNOT STRUCTURE} \
          "tclpdf: this annotation cannot go into the structure tree here -\
          [string trim [string map {tclpdf: {}} $id]]. Every annotation of a\
          tagged document sits in the tree in reading order (ISO 14289-1,\
          7.18.1), and this package puts it in an Annot element (ISO 32000-1,\
          Table 337), so it has to be drawn somewhere an Annot may stand"
    }
    set key [my StructureAnnotation $number]
    my StructureClose $id
    return $key
  }

  # A colour as the ARRAY /C takes (Table 166): one, three or four numbers,
  # and the count is what says which space it is in. The conversion itself is
  # [::tclpdf::color parse]'s, as everywhere; what is this method's is the
  # wording, because a caller who wrote -colour on an annotation has to read
  # about an annotation. field.tcl has the same three lines for /MK under
  # Table 192 - two tables, two messages, one parser.
  method AnnotColourArray {spec} {
    lassign [::tclpdf::color parse $spec] space values
    if {$space ni {gray rgb cmyk}} {
      return -code error -errorcode [list TCLPDF ANNOT COLOURSPACE $space] \
          "tclpdf: the colour of an annotation is given in grey, RGB or CMYK -\
          ISO 32000-2, Table 166 admits one, three or four numbers under /C\
          and tells the space apart by counting them, so a $space colour has\
          no spelling there. Name the colour as {r g b}, {c m y k} or a single\
          grey value"
    }
    return [::tclpdf::pdfObj arr [lmap value $values {
      ::tclpdf::pdfObj num $value
    }]]
  }

  method AnnotOpacity {value} {
    if {![string is double -strict $value] || $value < 0 || $value > 1} {
      return -code error -errorcode [list TCLPDF ANNOT OPACITY $value] \
          "tclpdf: -opacity of an annotation is a number from 0 to 1 (/CA,\
          ISO 32000-2, Table 170), not \"$value\""
    }
    return [::tclpdf::pdfObj num $value]
  }

  method AnnotDate {value} {
    if {![string is entier -strict $value]} {
      return -code error -errorcode [list TCLPDF ANNOT DATE $value] \
          "tclpdf: -date of an annotation is a time in seconds since the\
          epoch, as \[clock seconds\] answers - not \"$value\". It is written\
          to /M and /CreationDate (ISO 32000-2, Table 170); without it the\
          annotation carries no date at all, so that the same script writes\
          the same bytes twice"
    }
    return [my Str [::tclpdf::pdfObj date $value [[my writer] version]]]
  }

  # -- appearances ----------------------------------------------------------

  # The form the caller drew, looked up by name.
  #
  # An appearance stream IS a form XObject with a bounding box (12.5.5,
  # Table 168), which is what [form create] writes - so nothing is built
  # here, and none of the decisions in the picture are this file's. The same
  # road [SignAppearance] travels for a visible signature; the wording is its
  # own, because a caller who wrote "annot stamp -appearance" has to read
  # that back.
  method AnnotForm {name context} {
    set forms [my state forms]
    if {![dict exists $forms $name]} {
      set known [dict keys $forms]
      if {![llength $known]} {
        set known "none - this document has no form at all"
      } else {
        set known [join $known {, }]
      }
      return -code error -errorcode [list TCLPDF ANNOT APPEARANCE $name] \
          "tclpdf: -appearance of $context names no form of this document:\
          \"$name\" - known are: $known. What an annotation with an\
          appearance of its own shows is a form XObject drawn beforehand with\
          \[\$doc form create\], under the name passed here"
    }
    return [dict get $forms $name]
  }

  method AnnotAppearance {name context} {
    return [my resource XObject [dict get [my AnnotForm $name $context] resource]]
  }

  # -- the conformance the claims ask for ----------------------------------

  # Annotations are collected per page and picked up when the page is
  # written; output.tcl reads [state annots] and writes the /Annots array.
  # Kept in the scratch state rather than pushed into output.tcl, so that a
  # document without annotations costs nothing.
  #
  # These six lines are [LinkRegister] in link.tcl as well, and that is one
  # copy too many: what they write is output.tcl's contract, not this
  # module's, and the method belongs there with both callers on it.

  # Remember what was written, for the check at the write.
  #
  # The hook is subscribed on the first annotation and never again: a
  # document without one costs nothing, and a document with fifty has one
  # subscriber. Same arrangement field.tcl keeps for its own write.
  method AnnotRemember {record} {
    set records [my state annotations]
    lappend records $record
    my state annotations $records
    if {[my state annotHooked] eq {}} {
      my state annotHooked 1
      my onSelf beforeWrite AnnotBeforeWrite
    }
    return
  }

  # And again at the write, because a document declares its conformance and
  # its annotations in either order, and only the write has seen both.
  method AnnotBeforeWrite {} {
    foreach record [my state annotations] {
      my AnnotCheck $record
    }
    return
  }

  # THE THREE REFUSALS. All of them are about the same thing: a document
  # that makes a claim has to keep it, and a validator at the recipient is
  # the wrong place to find out that it does not.
  #
  # Every one of them was measured against veraPDF 1.30 on 2026-08-24, in
  # both directions - the file this package writes, and the same file with
  # the one entry taken out again. What the counter-probes answered is
  # written beside each.
  method AnnotCheck {record} {
    dict with record {}
    set where "the $subtype annotation on page [expr {$page + 1}]"
    set pdfa [my state pdfa]
    set ua [my state ua]
    # 1. NO APPEARANCE, AND AN ARCHIVE THAT REQUIRES ONE. ISO 32000-2, Table
    # 166: "Every annotation ... shall have at least one appearance
    # dictionary", with Popup, Projection and Link the only exceptions.
    # veraPDF fails a PDF/A file without one under 6.3.3-1 - measured, and
    # the description it prints is that very sentence.
    #
    # PDF/A AND NOTHING ELSE, and that is a measurement rather than a
    # reading. Table 166 is the base standard's and applies to every PDF 2.0
    # file, not to a claim: refusing it under PDF/UA-2 alone would draw a
    # boundary neither the format nor the profile draws, and veraPDF's ua2
    # profile passes a note without an appearance (0 failed checks). ISO
    # 32000-1, Table 164 has /AP as optional outright, so a 1.7 file - a
    # PDF/UA-1 document among them - is not refused either.
    if {!$appearance && $pdfa ne {}} {
      return -code error -errorcode [list TCLPDF ANNOT PDFA $subtype] \
          "tclpdf: $where has no appearance stream and this document claims\
          PDF/A-[dict get $pdfa part][dict get $pdfa conformance] - ISO\
          32000-2, Table 166 requires one of every annotation, and veraPDF\
          fails the file under 6.3.3 (\"An annotation does not contain an\
          appearance dictionary\"). The symbol of a note and the fourteen\
          rubber stamps are the READER's drawing, and an archived document\
          may not depend on the reader: draw the picture with \[\$doc form\
          create\] and pass -appearance, or drop the pdfa claim"
    }
    if {$ua eq {}} {
      return
    }
    # 2. NO DESCRIPTION. ISO 14289-1, 7.18.1: an annotation carries an
    # alternative description. veraPDF fails one without under 7.18.1 test 2,
    # "An annotation ... shall have either Contents key or an Alt entry in
    # the enclosing structure element" - measured. The Alt half of that
    # sentence is no road here: the enclosing element is the Annot this
    # package makes for the annotation alone, and an Alt on it would be a
    # second way to say the one thing /Contents says.
    #
    # Kept for part 2 as well, where veraPDF 1.30 flags nothing - measured,
    # a UA-2 file with a description-less stamp passes its ua2 profile. That
    # is the profile being younger than the standard, not the requirement
    # being lifted: ISO 14289-2 keeps the annotations in clause 8.9, and a
    # part 2 document is not permitted to be less usable than a part 1 one.
    # The refusal costs a caller one option and the way out is named.
    if {$contents eq {}} {
      my AnnotUaMessage $subtype CONTENTS \
          "$where carries no description" \
          "PDF/UA reads /Contents as what a reader announces for an\
          annotation (ISO 14289-1, 7.18.1; ISO 14289-2, 8.9), and\
          \"annotation\" is what it says without one. Pass -contents"
    }
    # 3. NOT IN THE TREE. An annotation outside the structure tree is
    # invisible to a reader that follows it, however visible it is on the
    # page - veraPDF 7.18.1 test 1, "An annotation ... shall be nested within
    # an Annot tag", which is the clause that decided the element type in
    # [AnnotStructure]. The element is made at the call, so the only way
    # here is an annotation written while the document was not yet tagged.
    if {!$structured} {
      my AnnotUaMessage $subtype STRUCTURE \
          "$where is not in the structure tree" \
          "PDF/UA wants every annotation represented there, in reading order\
          (ISO 14289-1, 7.18.1; ISO 14289-2, 8.9); this package puts one in\
          an Annot element by itself, and the only way to miss it is to draw\
          the annotation before \[\$doc tagged 1\], which has to be the\
          first call on the document anyway. Turn tagging on first"
    }
    return
  }

  # One wording for the two UA refusals, so that they cannot drift apart in
  # everything but the sentence that differs.
  method AnnotUaMessage {subtype code what why} {
    return -code error -errorcode [list TCLPDF ANNOT UA $code $subtype] \
        "tclpdf: $what and this document claims PDF/UA-[dict get \
        [my state ua] part] - $why"
  }
}

package provide tclpdf::annot 1.1
