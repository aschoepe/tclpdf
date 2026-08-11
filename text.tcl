#
# tclpdf - PDF generation for Tcl
#
# text - font selection and text output (9.4)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Attaches to the document class like the other topical modules. Line breaking
# and alignment live in textBlock.tcl - this file is font state and the single
# line; that one is the paragraph.
#
# The y coordinate of a text call is the BASELINE, not the top of the letters.
# That is what PDF positions on, and pretending otherwise would mean guessing
# an ascent for every font. [text ... -at {x y}] therefore places the baseline
# at y; the block methods do the ascent arithmetic once, in one place.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::afm 1.0-
package require tclpdf::option 1.0-
package require tclpdf::color 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::text {
  # Which options describe the font state rather than one call.
  variable stateOptions {family style size color spacing wordSpacing
      stretch leading rise}
}

oo::define ::tclpdf::document::document {

  # $doc font                                  -> the current state
  # $doc font -family helvetica -style bold -size 12
  #
  # Options:
  #   -family      helvetica, times, courier, symbol, zapfdingbats, or a
  #                font name such as Times-Italic
  #   -style       bold, italic, {bold italic}
  #   -size        in points, always - a font size in millimetres is not a
  #                thing anyone asks for
  #   -color       fill colour for text
  #   -spacing     extra space per character (Tc), in points
  #   -wordSpacing extra space per space character (Tw), in points
  #   -stretch     horizontal scaling in percent (Tz), 100 is normal
  #   -leading     line spacing (TL) in points; default 1.2 * size
  #   -rise        baseline shift (Ts) in points, for super- and subscript
  method font {args} {
    my TextInit
    if {![llength $args]} {
      return [my TextState]
    }
    # "font embed", "font names" and "font info" belong to the TrueType
    # module. Loaded on demand: a caller who only uses the standard fonts
    # never pays for it.
    if {[lindex $args 0] in {embed names info}} {
      package require tclpdf::font
      switch -- [lindex $args 0] {
        embed {return [my FontEmbed {*}[lrange $args 1 end]]}
        names {return [my FontNames]}
        info {return [my FontInfo {*}[lrange $args 1 end]]}
      }
    }
    set defaults {}
    foreach name $::tclpdf::text::stateOptions {
      dict set defaults $name [my TextGet $name]
    }
    foreach {name value} [::tclpdf::option parse $defaults $args "font"] {
      my TextSet $name $value
    }
    # Resolving now rather than at output time means a wrong family is
    # reported where it was written, not three calls later.
    my TextSet resolved [my TextResolve [my TextGet family] [my TextGet style]]
    return [my TextState]
  }

  # The width of a string in the document unit, with the current font or an
  # overriding -family/-style/-size.
  method textWidth {string args} {
    my TextInit
    set state [my TextMerge $args]
    set font [dict get $state resolved]
    if {[my TextEmbedded $font]} {
      set points [my FontWidth $font $string [dict get $state size]]
    } else {
      set points [::tclpdf::afm stringWidth $font $string [dict get $state size]]
    }
    # Character and word spacing widen the run and belong in the measurement,
    # or right-aligned text drifts.
    set count [string length $string]
    if {$count > 1} {
      set points [expr {$points + [dict get $state spacing] * ($count - 1)}]
    }
    set spaces [expr {[llength [split $string { }]] - 1}]
    set points [expr {$points + [dict get $state wordSpacing] * $spaces}]
    set points [expr {$points * [dict get $state stretch] / 100.0}]
    return [::tclpdf::geometry fromPoints $points [my cget -unit]]
  }

  # $doc text "Rechnung" -at {20 30} ?-rotate 90? ?-align right? ?-size 14? ...
  #
  # Without -width this writes ONE line and -align refers to the given point:
  # left starts there, right ends there, center is centred on it. With -width
  # the paragraph methods of textBlock.tcl take over.
  method text {string args} {
    my TextInit
    # Own options plus the font options, which are accepted per call without
    # being stored - partition keeps the two apart instead of merging the
    # dictionaries and losing track of which is which.
    set defaults {at {} rotate 0 align left width {} anchor baseline}
    foreach name $::tclpdf::text::stateOptions {
      dict set defaults $name [my TextGet $name]
    }
    set options [::tclpdf::option parse $defaults $args "text"]
    # Checked rather than left to lassign: writing -at {20 [expr {$y+5}]} is a
    # standing invitation, the braces stop the substitution, and Tcl then
    # reports "list element in braces followed by ]" from somewhere inside the
    # method - which says nothing about the actual mistake.
    set at [dict get $options at]
    if {$at eq {}} {
      return -code error "tclpdf: text needs -at {x y}"
    }
    if {[catch {llength $at} count] || $count != 2
        || ![string is double -strict [lindex $at 0]]
        || ![string is double -strict [lindex $at 1]]} {
      return -code error "tclpdf: -at takes two numbers {x y}, got \"$at\" -\
          for a computed position use \[list \$x \$y\], braces do not substitute"
    }
    if {[dict get $options width] ne {}} {
      # The paragraph half of this topic. Loaded here rather than at the top
      # of the file: textBlock requires text, so requesting it up front would
      # be a cycle. At this point text is fully provided and it is not.
      #
      # This is the facade rule in practice - a caller says "text with a
      # width" and does not need to know that two files are involved.
      package require tclpdf::textBlock
      return [my TextParagraph $string $options]
    }
    set state [my TextMerge $args]
    lassign [dict get $options at] x y

    # Alignment of a single line is a shift of the starting point - there is
    # no PDF operator for it. The shift is passed on rather than applied to x
    # here, because it has to happen ALONG THE BASELINE: with -rotate the
    # baseline is turned, and shifting x beforehand moved the anchor
    # horizontally and then rotated about the wrong point - a rotated
    # centred word drifted off towards the corner instead of staying centred
    # on -at.
    set width [my textWidth $string {*}$args]
    switch -- [dict get $options align] {
      left {set shift 0}
      right {set shift $width}
      center - centre {set shift [expr {$width / 2.0}]}
      justify {
        # Without a -width there is nothing to justify to.
        return -code error "tclpdf: -align justify needs -width"
      }
      default {
        return -code error "tclpdf: -align must be left, right, center or\
            justify, not \"[dict get $options align]\""
      }
    }
    set y [my TextBaseline $state $y [dict get $options anchor]]
    my TextRun $string $state $x $y [dict get $options rotate] $shift
    return
  }

  # -- internals ----------------------------------------------------------

  # The one place that knows there are two kinds of font. An embedded alias
  # passes through unchanged - it has no family/style variants, it IS the
  # face. Everything else goes to the standard-font table.
  method TextResolve {family style} {
    if {[my TextEmbedded $family]} {
      return $family
    }
    return [::tclpdf::afm resolve $family $style]
  }

  # Asked without loading the font module: a document that never embedded
  # anything must not pay for it.
  method TextEmbedded {name} {
    return [dict exists [my state fonts] $name]
  }

  # Bytes for the content stream: WinAnsi for a standard font, two-byte glyph
  # numbers for an embedded one.
  method TextEncode {font string} {
    if {[my TextEmbedded $font]} {
      return [my FontEncode $font $string]
    }
    return [::tclpdf::afm bytes $font $string]
  }

  # Turn the anchor into a baseline. -anchor top means "the top of the letters
  # sits at y", which is what someone laying out a box means; PDF positions on
  # the baseline, one ascent lower. Used by the single line and by the
  # paragraph alike - the two must not drift apart, or a heading and the body
  # under it end up on different grids.
  method TextBaseline {state y anchor} {
    if {$anchor ne "top"} {
      return $y
    }
    set font [dict get $state resolved]
    if {[my TextEmbedded $font]} {
      set parsed [dict get [my state fonts] $font parsed]
      set ascent [expr {double([dict get $parsed ascender]) * [dict get $state size]
          / [dict get $parsed unitsPerEm]}]
    } else {
      set ascent [expr {[dict get [::tclpdf::afm descriptor $font] Ascender]
          * [dict get $state size] / 1000.0}]
    }
    return [expr {$y + [::tclpdf::geometry fromPoints $ascent [my cget -unit]]}]
  }

  # One BT/ET block with one string in it.
  #
  # Character spacing, word spacing, rise and horizontal scaling belong to the
  # TEXT STATE, and the text state is part of the GRAPHICS state (9.3) - it
  # survives ET and applies to every later block until something changes it.
  # Writing them only when they differ from the default therefore leaked: a
  # line set with -spacing 3 left "3 Tc" in force, and the next plain [text]
  # came out letter-spaced with nothing in its own call to explain it.
  # Measured in the content stream, not deduced.
  #
  # So a block that sets any of them is wrapped in q/Q. That is what the
  # graphics state stack is for, it costs nothing when the options are unused,
  # and unlike tracking what was written last it stays correct when the caller
  # does its own save/restore in between.
  # shift is the alignment offset along the baseline, in the document unit:
  # 0 for left, the line width for right, half of it for center.
  method TextRun {string state x y rotate {shift 0}} {
    set font [dict get $state resolved]
    set size [dict get $state size]
    lassign [my coords $x $y] px py
    set shift [::tclpdf::geometry toPoints $shift [my cget -unit]]

    set guarded [expr {[dict get $state spacing] != 0
        || [dict get $state wordSpacing] != 0
        || [dict get $state rise] != 0
        || [dict get $state stretch] != 100}]
    if {$guarded} {
      my content "q\n"
    }
    my content "BT\n"
    my content "[my TextResource $font] [::tclpdf::pdfObj num $size] Tf\n"
    if {[dict get $state color] ne {}} {
      my content [::tclpdf::color operator \
          [::tclpdf::color parse [dict get $state color]] fill]\n
    }
    foreach {key operator} {spacing Tc wordSpacing Tw rise Ts} {
      if {[dict get $state $key] != 0} {
        my content "[::tclpdf::pdfObj num [dict get $state $key]] $operator\n"
      }
    }
    if {[dict get $state stretch] != 100} {
      my content "[::tclpdf::pdfObj num [dict get $state stretch]] Tz\n"
    }
    if {$rotate != 0} {
      # Tm carries position AND rotation; using Td as well would compose them.
      # The alignment shift goes in FIRST, along the text's own baseline -
      # then the rotation, then the move to the anchor. That is what keeps a
      # centred word centred on -at at any angle.
      set matrix [::tclpdf::geometry multiply \
          [::tclpdf::geometry translate [expr {-$shift}] 0] \
          [::tclpdf::geometry multiply [::tclpdf::geometry rotate $rotate] \
              [::tclpdf::geometry translate $px $py]]]
      my content "[join [lmap n $matrix {::tclpdf::pdfObj num $n}] { }] Tm\n"
    } else {
      my content "[::tclpdf::pdfObj num [expr {$px - $shift}]]\
          [::tclpdf::pdfObj num $py] Td\n"
    }
    my content "[::tclpdf::pdfObj bytesStr [my TextEncode $font $string]] Tj\n"
    my content "ET\n"
    if {$guarded} {
      my content "Q\n"
    }
    return
  }

  # Register a font as a page resource and return its name. One resource per
  # font, reused across the document - that is what keeps a 20-page report
  # from carrying 20 identical font objects.
  method TextResource {font} {
    if {[my TextEmbedded $font]} {
      return [my FontResource $font]
    }
    set name F[string map {- {}} $font]
    if {[my resource Font $name] eq {}} {
      set pairs [list Type /Font Subtype /Type1 \
          BaseFont [::tclpdf::pdfObj name $font]]
      if {![::tclpdf::afm isSymbolic $font]} {
        # Symbol and ZapfDingbats must NOT get this - they carry their own
        # encoding, and declaring WinAnsi for them scrambles every glyph.
        lappend pairs Encoding /WinAnsiEncoding
      }
      my resource Font $name \
          [[my writer] ref [[my writer] add [::tclpdf::pdfObj dictionary $pairs]]]
    }
    return [::tclpdf::pdfObj name $name]
  }

  method TextInit {} {
    if {[my state text] eq {}} {
      my state text [dict create \
          family helvetica style {} size 12 color black spacing 0 \
          wordSpacing 0 stretch 100 leading {} rise 0 resolved Helvetica]
    }
    return
  }

  method TextState {} {
    return [my state text]
  }

  method TextGet {key} {
    return [dict get [my TextState] $key]
  }

  method TextSet {key value} {
    set state [my TextState]
    dict set state $key $value
    my state text $state
    return
  }

  # The current state with per-call overrides applied, without storing them.
  method TextMerge {arguments} {
    set state [my TextState]
    set changed 0
    foreach {option value} $arguments {
      set name [string trimleft $option -]
      if {$name in $::tclpdf::text::stateOptions} {
        dict set state $name $value
        if {$name in {family style}} {
          set changed 1
        }
      }
    }
    if {$changed} {
      dict set state resolved \
          [my TextResolve [dict get $state family] [dict get $state style]]
    }
    if {[dict get $state leading] eq {}} {
      dict set state leading [expr {[dict get $state size] * 1.2}]
    }
    return $state
  }
}

package provide tclpdf::text 1.1
