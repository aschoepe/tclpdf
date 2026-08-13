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
      stretch leading rise kerning ligatures}
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
  #   -spacing     extra space between glyphs (Tc), in points
  #   -wordSpacing extra space per space character (Tw), in points
  #   -stretch     horizontal scaling in percent (Tz), 100 is normal
  #   -leading     line spacing (TL) in points; default 1.2 * size
  #   -rise        baseline shift (Ts) in points, for super- and subscript
  #   -kerning     apply the pair kerning of an embedded font, 0 or 1
  #   -ligatures   apply the standard ligatures of an embedded font, 0 or 1
  #
  # Both are ON by default: they are what the type designer intended, and a
  # package that leaves them off ships worse typography than the font offers.
  # Set them to 0 where a document has to come out exactly as an older release
  # produced it - kerning changes the width of every line it touches, and a
  # ligature replaces several glyphs by one. Both affect embedded faces only;
  # the metrics shipped for the standard fourteen carry widths per byte value,
  # neither kerning pairs nor ligatures.
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
    # A string with line breaks in it is not one line, and measuring it as one
    # was wrong in both directions. It used to add the lines together - a table
    # cell of two lines asked for a column wide enough to hold both side by
    # side - and since the glyph run became the single source of truth it threw
    # instead, because a line feed has no glyph. What a caller wants here is
    # the width the widest line needs.
    #
    # Drawing still refuses a line feed, and rightly: [text] sets ONE line.
    # Splitting belongs to whoever draws several - textBlock and the table both
    # do it through [textLines], which breaks paragraphs at \n exactly like
    # this.
    if {[string first \n $string] >= 0} {
      set widest 0
      foreach line [split $string \n] {
        set width [my textWidth $line {*}$args]
        if {$width > $widest} {
          set widest $width
        }
      }
      return $widest
    }
    set state [my TextMerge $args]
    set font [dict get $state resolved]
    if {[my TextEmbedded $font]} {
      # The run is held here rather than left to a helper, because -spacing
      # needs to know how many GLYPHS there are. Tc adds its space after every
      # glyph drawn, and with ligatures that is no longer the number of
      # characters: "office" is six characters and, in a face that has the ffi
      # ligature, four glyphs. Counting characters charged for five gaps where
      # three get drawn, and the line came out narrower than measured - visible
      # as a frayed right edge in justified text.
      set run [my FontRun $font $string [dict get $state ligatures]]
      set points [my FontRunWidth $font $run [dict get $state size] \
          [dict get $state kerning]]
      set count [llength $run]
    } else {
      # No kerning and no ligatures for the standard fourteen: the metrics this
      # package ships carry widths per byte value, not the AFM kerning pairs.
      # Asking for either with a standard font is therefore not an error but
      # has no effect - and measuring it here differently from drawing it would
      # be the worse answer. One glyph per character, so the two counts agree.
      set points [::tclpdf::afm stringWidth $font $string [dict get $state size]]
      set count [string length $string]
    }
    # Character and word spacing widen the run and belong in the measurement,
    # or right-aligned text drifts.
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
    set defaults {at {} rotate 0 align left width {} anchor baseline
        height {} indent 0 indentRight 0 firstIndent 0 paragraphSpacing 0
        avoid {} avoidMargin 0}
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
    my TextRun $string $state $x $y [dict get $options rotate] $shift \
        [my TextLift $state [dict get $options anchor]]
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
  # Bytes for a standard face. An embedded one never comes through here:
  # [TextShow] takes its own road for those, because it needs the glyph run,
  # and it decides before it calls. This used to test for that a second time
  # and hand an embedded font to [FontEncode] WITHOUT the ligature flag - a
  # branch nothing reached, and one that would have drawn a different glyph
  # sequence than [textWidth] measured if anything ever had.
  method TextEncode {font string} {
    return [::tclpdf::afm bytes $font $string]
  }

  # How far the baseline sits BELOW the anchor point, in the document unit.
  # -anchor top means "the top of the letters sits at y", which is what someone
  # laying out a box means; PDF positions on the baseline, one ascent lower.
  # Used by the single line and by the paragraph alike - the two must not drift
  # apart, or a heading and the body under it end up on different grids.
  #
  # Returned rather than added to y, and that is the whole point: the offset
  # runs perpendicular to the BASELINE, and the baseline turns with -rotate.
  # Adding it to y first and rotating afterwards moved the text a whole
  # ascender away from where -at said - measured with -anchor top -rotate 90,
  # where the anchor came out identical to the unrotated one although the
  # offset has to act on x at that angle. Same defect the alignment shift had,
  # one axis over, and the same cure: hand it to TextRun and let the text
  # matrix carry it.
  method TextLift {state anchor} {
    if {$anchor ne "top"} {
      return 0
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
    return [::tclpdf::geometry fromPoints $ascent [my cget -unit]]
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
  # Two offsets from the anchor, both in the document unit and both applied in
  # TEXT SPACE, so that -rotate turns them along with the text:
  #
  #   shift  ALONG the baseline - 0 for left, the line width for right, half of
  #          it for center
  #   lift   ACROSS it, downwards - the ascender for -anchor top, and the
  #          running line advance inside a paragraph
  #
  # Doing either of them on x or y before the rotation is the same mistake
  # twice: the text then turns about a point that is no longer -at.
  method TextRun {string state x y rotate {shift 0} {lift 0}} {
    set font [dict get $state resolved]
    set size [dict get $state size]
    lassign [my coords $x $y] px py
    set shift [::tclpdf::geometry toPoints $shift [my cget -unit]]
    set lift [::tclpdf::geometry toPoints $lift [my cget -unit]]

    # Where the word spacing comes from decides what has to be written and
    # what has to be taken back again: with TJ there is no Tw in the stream,
    # so a run that sets nothing else needs no guard either.
    set byTJ [my TextTJ $font $state]
    set guarded [expr {[dict get $state spacing] != 0
        || ([dict get $state wordSpacing] != 0 && !$byTJ)
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
      if {$key eq "wordSpacing" && $byTJ} {
        continue
      }
      if {[dict get $state $key] != 0} {
        my content "[::tclpdf::pdfObj num [dict get $state $key]] $operator\n"
      }
    }
    if {[dict get $state stretch] != 100} {
      my content "[::tclpdf::pdfObj num [dict get $state stretch]] Tz\n"
    }
    if {$rotate != 0} {
      # Tm carries position AND rotation; using Td as well would compose them.
      # Both offsets go in FIRST, in the text's own frame - then the rotation,
      # then the move to the anchor. That is what keeps a centred word centred
      # on -at at any angle, and what makes the lines of a rotated paragraph
      # run across the page instead of piling up on each other.
      #
      # The lift is negative in text space: y grows upwards there, and the
      # baseline of a line has to end up BELOW the anchor.
      set matrix [::tclpdf::geometry multiply \
          [::tclpdf::geometry translate [expr {-$shift}] [expr {-$lift}]] \
          [::tclpdf::geometry multiply [::tclpdf::geometry rotate $rotate] \
              [::tclpdf::geometry translate $px $py]]]
      my content "[join [lmap n $matrix {::tclpdf::pdfObj num $n}] { }] Tm\n"
    } else {
      my content "[::tclpdf::pdfObj num [expr {$px - $shift}]]\
          [::tclpdf::pdfObj num [expr {$py - $lift}]] Td\n"
    }
    my content [my TextShow $font $state $string $byTJ]
    my content "ET\n"
    if {$guarded} {
      my content "Q\n"
    }
    return
  }

  # Does this run have to produce its word spacing by hand?
  #
  # Tw applies to the single-byte code 32 and to nothing else (9.3.3). An
  # embedded face is addressed through Identity-H, where every code is TWO
  # bytes - a space is 0x0000-something, no byte 32 stands alone, and Tw is
  # written, is valid, and does nothing at all.
  #
  # Measured: the same paragraph stretches to the right margin with Helvetica
  # and does not with an embedded DejaVu, with "1.07 Tw" in the stream both
  # times. Since PDF/A requires every font to be embedded, justified text in an
  # archival document was never justified - and nothing reported it, because
  # the file is valid either way and the difference is a few millimetres at the
  # end of each line.
  method TextTJ {font state} {
    return [expr {[dict get $state wordSpacing] != 0
        && [dict get $state size] > 0 && [my TextEmbedded $font]}]
  }

  # What has to be written after each character, in thousandths of the text
  # space - the unit of a TJ number. Empty when the run needs no TJ array at
  # all, which keeps the common case a plain "(bytes) Tj".
  #
  # Two sources meet here and are added, because they can occur at the same
  # place: the word spacing after a space, and the kerning between a pair.
  #
  # SIGNS: a TJ number is SUBTRACTED from the advance, so a positive one pulls
  # the next glyph closer and a negative one opens a gap. Word spacing wants a
  # gap and therefore enters negative; a kerning pair is stored negative when
  # it tightens and therefore enters with its sign turned round.
  # The adjustments are indexed by GLYPH, not by character. With ligatures the
  # two are no longer the same list: "office" is six characters and, in a font
  # that has the ffi ligature, four glyphs.
  method TextAdjust {font state run byTJ} {
    set count [llength $run]
    if {$count < 1} {
      return {}
    }
    set kick 0
    if {$byTJ} {
      set kick [expr {-1000.0 * [dict get $state wordSpacing]
          / [dict get $state size]}]
    }
    set kern {}
    if {[dict get $state kerning] && [dict get $state size] > 0} {
      set kern [my FontRunKern $font $run]
    }
    if {$kick == 0 && ![llength $kern]} {
      return {}
    }
    set adjustments {}
    set any 0
    for {set index 0} {$index < $count} {incr index} {
      set value 0
      # The space keeps its own width and is drawn; the adjustment follows it.
      # A run ending in a space is adjusted as well, exactly as Tw would have
      # done - and as [textWidth] counts it when it measures the line.
      #
      # A glyph IS a space when it stands for exactly the one character U+0020.
      # No ligature ever does, so this cannot be tripped by one.
      if {[lindex [lindex $run $index] 1] eq {32}} {
        set value $kick
      }
      # The last glyph has no successor, so there is no pair to kern.
      if {$index < $count - 1 && [llength $kern]} {
        set value [expr {$value - [lindex $kern $index]}]
      }
      lappend adjustments $value
      if {$value != 0} {
        set any 1
      }
    }
    if {!$any} {
      return {}
    }
    return $adjustments
  }

  # The show operator for one run: "(bytes) Tj", or a TJ array when something
  # has to be adjusted by hand between the glyphs.
  #
  # The horizontal scale (Tz) multiplies the advance and the adjustment alike,
  # exactly as it does with Tw, so it needs no second thought here.
  #
  # Only an embedded face takes the TJ road at all: word spacing through Tw is
  # what a standard face uses, and neither kerning nor ligatures exist for the
  # metrics shipped with this package. That is why the branch is here and not
  # threaded through everything below it.
  method TextShow {font state string byTJ} {
    if {![my TextEmbedded $font]} {
      return "[::tclpdf::pdfObj bytesStr [my TextEncode $font $string]] Tj\n"
    }
    set run [my FontRun $font $string [dict get $state ligatures]]
    set adjustments [my TextAdjust $font $state $run $byTJ]
    if {![llength $adjustments]} {
      return "[::tclpdf::pdfObj bytesStr [my FontRunEncode $font $run]] Tj\n"
    }
    set parts {}
    set piece {}
    set count [llength $run]
    for {set index 0} {$index < $count} {incr index} {
      lappend piece [lindex $run $index]
      set value [lindex $adjustments $index]
      if {$value != 0} {
        lappend parts [::tclpdf::pdfObj bytesStr [my FontRunEncode $font $piece]]
        lappend parts [::tclpdf::pdfObj num $value]
        set piece {}
      }
    }
    if {[llength $piece]} {
      lappend parts [::tclpdf::pdfObj bytesStr [my FontRunEncode $font $piece]]
    }
    return "\[[join $parts { }]\] TJ\n"
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
          wordSpacing 0 stretch 100 leading {} rise 0 kerning 1 \
          ligatures 1 resolved Helvetica]
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

package provide tclpdf::text 1.5
