#
# tclpdf - PDF generation for Tcl
#
# fieldText - the text field (ISO 32000-2, 12.7.5.3)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Usage:
#
#   $doc field text customer -rect {20 40 80 8} -value "Erika Mustermann"
#   $doc field text remark   -rect {20 55 80 25} -multiline 1 -align left
#   $doc field text secret   -rect {20 85 80 8} -password 1
#
# WHAT THIS FILE IS. One topic - the field type /FT /Tx - and nothing else:
# the options a text field takes, the /Ff bits of Table 231 they turn into,
# the pairs the field writes and the appearance the reader shows. It attaches
# through the contract at the head of field.tcl and writes no catalogue key
# of its own: /AcroForm, the document-wide /DA, /DR, the widget's object
# number, the page's /Annots and the structure tree are the core's.
#
# THE VALUE IS THE ONE PLACE A TEXT FIELD IS QUIETLY WRONG, and it is wrong
# in three different ways at once:
#
#   A LINE BREAK INSIDE /V IS A CARRIAGE RETURN (12.7.4.3), not the line feed
#   a Tcl script writes. A reader handed \n shows one long line and nothing
#   says why, so the value is mapped on the way into the file.
#
#   A PASSWORD FIELD NEVER CARRIES ONE. Table 231, the NOTE under Password:
#   "it is imperative that PDF processors never store the value of the text
#   field in the PDF file if this flag is set". /V is plain text in a file
#   anyone can open with an editor, so -value and -default are REFUSED for a
#   password field rather than taken and silently dropped - a package that
#   drops what it was given is one whose refusals cannot be trusted either.
#
#   A VALUE LONGER THAN /MaxLen is one a reader truncates the moment the
#   field is touched, and a break in a field that is not multiline is a line
#   the reader will never show. Both are refused at the call that named them.
#
# THE APPEARANCE HAS A SHAPE THE STANDARD PRESCRIBES, and the order in it is
# not free: /Tx BMC ... q ... BT ... ET ... Q ... EMC (12.7.4.3). A reader
# that sets a new value "shall then replace the existing contents of the
# appearance stream from /Tx BMC to the matching EMC", and where the mark is
# missing "the new contents shall be appended to the end of the original
# stream" - the old text then stays standing under the new one. Which is why
# the frame and the background are painted OUTSIDE the bracket: they are not
# the value, and a reader replacing the value must not take them with it.
#
# THE FONT IS SETTLED AT THE DECLARATION and travels with the field. The
# appearance is drawn at write time, where the document's text state is
# whatever the last [font] call left behind - measured 2026-08-23 on the
# example, that was the courier of a command block three paragraphs down the
# page, and every field came out in it. So [FieldFont] answers both halves at
# the call - the /DA string and the values that went into it - and the paint
# names every one of them rather than inheriting any.
#
# NO ECMASCRIPT, NO XFA, NO RICH TEXT. The reasons are the same for every
# field type and stand once, at the head of field.tcl: a value that has to be
# computed is computed here and written as /V with its /AP drawn.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::color 1.0-
package require tclpdf::geometry 1.0-
package require tclpdf::field 1.0-

# Point 1 of the contract at the head of field.tcl.
::tclpdf::field register text tclpdf::fieldText

oo::define ::tclpdf::document::document {

  # $doc field text <name> -rect {x y w h}
  #     ?-page n? ?-value text? ?-default text? ?-maxlen n?
  #     ?-align left|center|right? ?-multiline 0|1? ?-readonly 0|1?
  #     ?-required 0|1? ?-noexport 0|1? ?-password 0|1?
  #     ?-family f? ?-style s? ?-size n? ?-color c?
  #     ?-border c? ?-borderWidth n? ?-background c? ?-tooltip text?
  #
  # -rect counts {x y w h} from the TOP left corner of the page in the unit
  # of the document, exactly as "link -at" with "link -size" and "sign -rect"
  # count. -page is the page INDEX and defaults to the current page.
  #
  # The name is the partial field name (/T, 12.7.4.2) and it is what an
  # exported FDF, a JavaScript in a reader and a filled form all address the
  # field by - so it is the caller's word, not a generated one.
  method FieldText {name args} {
    set options [::tclpdf::option parse {
      rect {} page {} value {} default {} maxlen {} align left
      multiline 0 readonly 0 required 0 noexport 0 password 0
      family {} style {} size {} color {}
      border {} borderWidth 0.4 background {} tooltip {}
      contents {} label {}
    } $args "field text"]

    # A LINE BREAK IS \n HERE, whichever of the three spellings the caller
    # wrote. A Windows script hands over "a\r\nb" and a Mac-era one "a\rb";
    # both used to travel through untouched, and both were wrong further on
    # in different ways - CRLF became TWO carriage returns in /V, an empty
    # line in the reader that nobody typed, and the bare CR reached the
    # appearance stream as a character no face has a glyph for (measured
    # 2026-08-26). Settled here, once, so that everything below - the
    # multiline check, the length against -maxlen, the font, the /V and the
    # picture - sees one spelling. /V gets its carriage returns in
    # [FieldTextBuild], which is where 12.7.4.3 applies, and [pdf fields]
    # answers \n again.
    foreach which {value default} {
      dict set options $which \
          [string map [list \r\n \n \r \n] [dict get $options $which]]
    }

    # EVERYTHING is checked before the field is declared. A refused call has
    # to leave the document exactly as it was - the rule sign.tcl, encrypt.tcl
    # and text.tcl all follow, and the one that keeps a second attempt from
    # tripping over the leavings of the first.
    foreach flag {multiline readonly required noexport password} {
      set value [dict get $options $flag]
      if {![string is boolean -strict $value]} {
        return -code error -errorcode [list TCLPDF FIELD BOOLEAN $flag] \
            "tclpdf: -$flag of field text is a boolean, not \"$value\""
      }
      dict set options $flag [expr {$value ? 1 : 0}]
    }
    if {[dict get $options align] ni {left center right}} {
      return -code error -errorcode \
          [list TCLPDF FIELD ALIGN [dict get $options align]] \
          "tclpdf: -align of field text is left, center or right - the /Q of\
          ISO 32000-2, Table 228 knows those three - not\
          \"[dict get $options align]\""
    }
    set maxlen [dict get $options maxlen]
    if {$maxlen ne {}} {
      if {![string is integer -strict $maxlen] || $maxlen < 1} {
        return -code error -errorcode [list TCLPDF FIELD MAXLEN $maxlen] \
            "tclpdf: -maxlen of field text is the greatest number of\
            characters the field takes and is 1 or more, not \"$maxlen\".\
            Leave the option out for a field of unlimited length"
      }
    }
    # Table 231: Password shall not be set where Multiline is. The two say
    # opposite things about the same field - one echoes nothing, the other
    # holds paragraphs - and a reader given both picks one without saying
    # which.
    if {[dict get $options password] && [dict get $options multiline]} {
      return -code error -errorcode {TCLPDF FIELD COMBINATION} \
          "tclpdf: -password and -multiline cannot both be set on one text\
          field - ISO 32000-2, Table 231 forbids the pair, because a field\
          that echoes nothing has no second line to echo it on. Drop one of\
          the two"
    }
    # Table 231, the NOTE under Password: "it is imperative that PDF
    # processors NEVER STORE THE VALUE of the text field in the PDF file if
    # this flag is set". A password written into /V is a password in a file
    # anyone can read with a text editor, and a package that took the value
    # and quietly dropped it would be one whose refusals cannot be trusted
    # either. So it is refused, and the reason is the reason.
    foreach which {value default} {
      if {[dict get $options password] && [dict get $options $which] ne {}} {
        return -code error -errorcode [list TCLPDF FIELD PASSWORD $which] \
            "tclpdf: -$which cannot be given for a password field - ISO\
            32000-2, Table 231 says of the Password flag that a PDF processor\
            shall never store the value of the field in the file, and /V is\
            plain text in a file anyone can open. Drop -$which, or drop\
            -password"
      }
    }
    foreach which {value default} {
      set text [dict get $options $which]
      if {$text eq {}} continue
      if {!([dict get $options multiline]) && [string first \n $text] >= 0} {
        return -code error -errorcode [list TCLPDF FIELD LINES $which] \
            "tclpdf: -$which of field text \"$name\" holds a line break and\
            the field is not multiline - a single-line field shows one line\
            (ISO 32000-2, 12.7.4.3). Pass -multiline 1, or take the break out"
      }
      if {$maxlen ne {} && [string length $text] > $maxlen} {
        return -code error -errorcode \
            [list TCLPDF FIELD LENGTH $which [string length $text] $maxlen] \
            "tclpdf: -$which of field text \"$name\" is\
            [string length $text] characters long and -maxlen says $maxlen -\
            a value longer than the field admits is one a reader truncates\
            the moment it is touched. Raise -maxlen, or shorten the text"
      }
    }
    # [option finite] rather than [string is double]: NaN is a double to Tcl
    # and compares FALSE against every bound, so "$size <= 0" waved it past
    # and Inf came through the same gap - a /DA reading "/FHelvetica NaN Tf"
    # and a border of infinite width, both refused nowhere (measured
    # 2026-08-26). Same predicate as everywhere else a number is read as a
    # measurement.
    set size [dict get $options size]
    if {$size ne {} && (![::tclpdf::option finite $size] || $size <= 0)} {
      return -code error -errorcode [list TCLPDF FIELD SIZE $size] \
          "tclpdf: -size of field text is a finite font size in points above\
          zero, not \"$size\""
    }
    set borderWidth [dict get $options borderWidth]
    if {![::tclpdf::option finite $borderWidth] || $borderWidth < 0} {
      return -code error -errorcode [list TCLPDF FIELD BORDERWIDTH $borderWidth] \
          "tclpdf: -borderWidth of field text is a finite line width of 0 or\
          more in the unit of the document, not \"$borderWidth\". Use 0 for a\
          field with no frame"
    }
    # The three colours go through the colour module HERE, where the call can
    # still be refused, rather than at write time inside an appearance stream
    # nobody is looking at.
    foreach which {color border background} {
      if {[dict get $options $which] eq {}} continue
      if {[catch {::tclpdf::color parse [dict get $options $which]} parsed]} {
        return -code error -errorcode [list TCLPDF FIELD COLOUR $which] \
            "tclpdf: -$which of field text \"$name\" is not a colour this\
            package reads: $parsed"
      }
    }
    # The default appearance string is built now for the same reason: it
    # names a font, and a family that does not resolve has to be refused at
    # the call that named it.
    set font [my FieldFont [dict get $options family] \
        [dict get $options style] $size [dict get $options color] \
        "field text \"$name\""]

    # The option names and the flag names of Table 227 and Table 231, in one
    # place. "flagName" rather than "name": the field's own name is in scope
    # here, and a loop variable called "name" took it over - measured, the
    # second field of a document was refused as a duplicate of "Password".
    set flagNames {}
    foreach {flag flagName} {readonly ReadOnly required Required
        noexport NoExport multiline Multiline password Password} {
      if {[dict get $options $flag]} {
        lappend flagNames $flagName
      }
    }

    # AND THE FONT HAS TO BE ABLE TO SET WHAT THE FIELD SHOWS. The
    # appearance is drawn at write time ([FieldTextPaint] below), and a
    # character the face has no code for is refused there - inside a form
    # this document is in the middle of writing, by which time the field
    # cannot be taken back: [field text t -value "\u041F..."] in Helvetica
    # was accepted, every [write] afterwards died with "character U+041F is
    # not available in WinAnsiEncoding", and the document was unwritable for
    # good (measured 2026-08-26). The same question asked here, where the
    # answer is a refused call and nothing else.
    #
    # [textWidth] is the ask: it runs the string through the very glyph run
    # the appearance will draw and refuses exactly what that would refuse,
    # in the same words - and the font is settled one line above, so there
    # is nothing to guess at.
    foreach which {value default} {
      my FieldSettable [dict get $options $which] $font $which \
          "field text \"$name\""
    }

    my FieldDeclare $name -type Tx -build FieldTextBuild \
        -rect [dict get $options rect] -page [dict get $options page] \
        -tooltip [dict get $options tooltip] \
        -contents [dict get $options contents] \
        -label [dict get $options label] \
        -flags [::tclpdf::field flags $flagNames] \
        -data [dict create \
            value [dict get $options value] \
            default [dict get $options default] \
            maxlen $maxlen \
            align [dict get $options align] \
            multiline [dict get $options multiline] \
            password [dict get $options password] \
            da [dict get $font da] \
            size [dict get $font size] \
            family [dict get $font family] style [dict get $font style] \
            color [dict get $font colour] \
            border [dict get $options border] \
            borderWidth $borderWidth \
            background [dict get $options background]]
    return $name
  }

  # The pairs of ONE text field, at write time. Point 4 of the contract at
  # the head of field.tcl.
  method FieldTextBuild {name record} {
    set data [dict get $record data]
    set pairs [list FT /Tx DA [my Str [dict get $data da]]]
    if {[dict get $data align] ne "left"} {
      # /Q 0 is the default and is left out where it applies - a key that may
      # only ever hold its own default is one to leave out (Table 228).
      lappend pairs Q [expr {[dict get $data align] eq "center" ? 1 : 2}]
    }
    if {[dict get $data maxlen] ne {}} {
      lappend pairs MaxLen [dict get $data maxlen]
    }
    foreach {key which} {V value DV default} {
      set text [dict get $data $which]
      if {$text eq {}} continue
      # A line break inside a field value is a CARRIAGE RETURN (12.7.4.3),
      # not the line feed a Tcl script writes. Converted here, once, on the
      # way into the file: a reader given \n shows one long line and nothing
      # says why.
      #
      # One map and not two: a break reaches this point as \n whatever the
      # caller wrote, [FieldText] having settled that at the call.
      lappend pairs $key [my Str [string map [list \n \r] $text]]
    }
    lappend pairs {*}[my FieldBorderEntries $data]
    lappend pairs AP [::tclpdf::pdfObj dictionary [list \
        N [my FieldAppearanceStream $record N {my FieldTextPaint $record}]]]
    return $pairs
  }

  # What the field SHOWS. Runs inside the appearance stream's own canvas, so
  # {0 0} is the top left corner of the widget and the document unit is in
  # force - the same system the caller draws a page in.
  method FieldTextPaint {record} {
    set data [dict get $record data]
    lassign [dict get $record extent] width height
    set borderWidth [dict get $data borderWidth]
    set hasBorder [expr {[dict get $data border] ne {} && $borderWidth > 0}]

    # Background and frame first and OUTSIDE the /Tx bracket: the bracket
    # marks the variable text (12.7.4.3), and a frame is not text.
    if {[dict get $data background] ne {}} {
      my rect -at {0 0} -size [list $width $height] \
          -fill [dict get $data background]
    }
    if {$hasBorder} {
      # Inset by half the line width, so the stroke lands INSIDE the widget
      # rather than half outside its bounding box - a stroke straddles the
      # path it follows (8.4.3.2), and the half outside is clipped away by
      # the /BBox with nothing to say it happened.
      set half [expr {$borderWidth / 2.0}]
      my rect -at [list $half $half] \
          -size [list [expr {$width - $borderWidth}] \
              [expr {$height - $borderWidth}]] \
          -stroke [dict get $data border] -width $borderWidth
    }

    # The text. An empty field still gets its stream - a widget annotation
    # without /AP /N is what veraPDF rule 6.3.3-1 fails, and an empty field
    # is the usual state of a blank form.
    # A password field never carries a value (see [FieldText]), so there is
    # never anything to draw in one - which is the appearance a password box
    # is supposed to have.
    set text [dict get $data value]
    if {$text eq {}} {
      return
    }

    # The padding between the frame and the first glyph. One point on top of
    # the border, which is what a reader leaves and what keeps a descender
    # off the rule below it.
    set padding [expr {$borderWidth
        + [::tclpdf::geometry fromPoints 1 [my cget -unit]]}]
    set inner [expr {$width - 2 * $padding}]
    if {$inner <= 0} {
      # A field too narrow to hold anything between its own frames. Nothing
      # is drawn rather than something drawn outside the box: the /BBox would
      # clip it away in any case, and a stream that paints outside its own
      # bounding box is a stream no two readers agree on.
      return
    }
    set size [dict get $data size]
    set sizeUnit [::tclpdf::geometry fromPoints $size [my cget -unit]]
    # EVERY value is named, none inherited. This runs at write time, where
    # the document's text state is whatever the last [font] call left behind
    # - which in the example was the courier of a command block three
    # paragraphs further down the page, and every field came out in it. The
    # appearance has to be set in the font the /DA names, and those are the
    # values [FieldFont] settled when the field was declared.
    set font [list -size $size -family [dict get $data family] \
        -style [dict get $data style] -color [dict get $data color]]

    # 12.7.4.3 prescribes the shape of the stream, and the order in it is
    # not free: /Tx BMC ... q ... BT ... ET ... Q ... EMC. The mark is not
    # cosmetic - a reader that later sets a new value "shall then replace the
    # existing contents of the appearance stream FROM /Tx BMC TO THE MATCHING
    # EMC", and where the mark is missing "the new contents shall be appended
    # to the end of the original stream": the old text then stays standing
    # under the new one. Which is also why the frame and the background are
    # drawn OUTSIDE the bracket, above - they are not the value, and a reader
    # replacing the value must not take them with it.
    my content "/Tx BMC\n"
    # Clipped to the inside of the frame, so a value wider than the field
    # ends at the frame instead of running over it. The clip is a graphics
    # state change and is taken back with the q/Q the norm puts inside the
    # bracket for exactly this reason.
    my save
    my clip -at [list $padding $padding] \
        -size [list $inner [expr {$height - 2 * $padding}]]
    if {[dict get $data multiline]} {
      # From the top down, as a reader fills a multiline field.
      my text $text -at [list $padding $padding] -anchor top \
          -width $inner -align [dict get $data align] {*}$font
    } else {
      # One line, vertically centred in the field. The letters are treated as
      # a box one font size tall - close enough for a form field, exact for
      # none, and the alternative is asking every face for its ascender to
      # place a single line of a widget that a reader will re-centre by its
      # own rule the moment the field is edited.
      set top [expr {($height - $sizeUnit) / 2.0}]
      if {$top < $padding} {
        set top $padding
      }
      switch -- [dict get $data align] {
        center {set x [expr {$width / 2.0}]}
        right {set x [expr {$width - $padding}]}
        default {set x $padding}
      }
      my text $text -at [list $x $top] -anchor top \
          -align [dict get $data align] {*}$font
    }
    my restore
    my content "EMC\n"
    return
  }
}

package provide tclpdf::fieldText 1.1
