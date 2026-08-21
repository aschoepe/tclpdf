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
      stretch leading rise kerning ligatures unshaped render stroke
      strokeWidth}

  # The text rendering mode (ISO 32000-2, 9.3.6, "Text rendering mode",
  # Table 104 - Table 106 in ISO 32000-1) by the word a caller writes for it.
  # The number is what goes into the stream as "N Tr" (Table 103 - Text state
  # operators, initial value 0); it is a text state parameter, Tmode
  # (Table 102), so it survives ET like Tc and Ts and has to be guarded the
  # same way - see TextRun.
  #
  # Words rather than the numbers themselves, for the reason every other value
  # list in this package has words: "3" says nothing at the call site and
  # nothing in a diff, "invisible" says both. The mapping is one way only -
  # the numbers never appear in the API.
  variable renderModes {
    fill 0 stroke 1 fillStroke 2 invisible 3
    fillClip 4 strokeClip 5 fillStrokeClip 6 clip 7
  }

  # The four modes this package REFUSES, by name rather than by silence, and
  # the reason - which is a property of the mode, not of the effort spent on
  # it (measured against 9.3.6):
  #
  #   1. A clipping mode does not paint into the page, it turns the glyph
  #      outlines into a CLIPPING PATH that takes effect at ET and "remains
  #      in effect until a previous clipping path is restored by an
  #      invocation of the Q operator" (9.3.6). So the clip outlives the text
  #      call by design, and the caller has to say where it ends.
  #   2. Every text run of this package sits in its own BT/ET, and one that
  #      sets any text state of its own sits in its own q/Q as well (TextRun,
  #      below). The Q would throw the clip away in the same breath that made
  #      it; leaving the q/Q out instead would leak the mode - "7 Tr" is text
  #      state and would clip every later text on the page to nothing.
  #   3. And a paragraph cannot work at all: the clipping path at ET is "the
  #      intersection of this path with the previous clipping path" (9.3.6),
  #      and a block writes one BT/ET per LINE. Two lines would intersect to
  #      the empty set, which paints nothing and reports nothing.
  #
  # Half of that - a single line, unguarded, with the caller wrapping its own
  # [save]/[restore] around it - would be a feature that works for [text]
  # without -width and silently produces an empty page for every other text
  # call. So it is refused where the word is written, with the reason named.
  variable renderClipModes {fillClip strokeClip fillStrokeClip clip}

  # The modes that stroke the outlines (Table 104, modes 1 and 2), which are
  # the ones -stroke and -strokeWidth reach: "if it calls for stroking, the
  # current stroking colour shall be used" (9.3.6).
  variable renderStrokeModes {1 2}

  # Options that describe ONE LINE, with their defaults. They travel with the
  # text wherever it is measured, broken or drawn - so they are carried in the
  # same dictionary as the font state - but they never enter the STORED state:
  # every call starts them at their default again.
  #
  # -direction is one of these rather than a font option because the direction
  # is a property of the line, not of the face: the same Hebrew face sets a
  # right-to-left line and a left-to-right heading beside it.
  variable runOptions {direction ltr}

  # Both lists together: everything a line has to take with it when a
  # paragraph hands one of its lines on to be measured or drawn. Named once
  # because two places rebuild a -name value list from it, and a list rebuilt
  # from the shorter one silently drops the direction of a paragraph.
  variable lineOptions [concat $stateOptions [dict keys $runOptions]]
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
  #   -render      how the glyphs are painted (9.3.6): fill, stroke,
  #                fillStroke or invisible
  #   -stroke      the outline colour of the stroking modes
  #   -strokeWidth the outline width of the stroking modes, in the document
  #                unit - a line width, and read in USER space (9.3.6), so it
  #                does not scale with the font size
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
    # Checked through before anything is stored: a call refused on its
    # third option must not have set the first two - "-family times -size 0"
    # left the family changed and the size where it was.
    set parsed [::tclpdf::option parse $defaults $args "font"]
    foreach {name value} $parsed {
      my TextCheck $name $value
    }
    foreach {name value} $parsed {
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
    lassign [my TextPoints $state $string] points count
    # Character and word spacing widen the run and belong in the measurement,
    # or right-aligned text drifts.
    if {$count > 1} {
      set points [expr {$points + [dict get $state spacing] * ($count - 1)}]
    }
    # max(0, ...): an empty string splits into one empty element, so the
    # count came out -1 and the width went NEGATIVE - measured at
    # -wordSpacing 3: -1.0583 mm. Nothing complains, and a table column takes
    # its natural width from it, so an empty cell asked for less room than no
    # room at all.
    set spaces [expr {max(0, [llength [split $string { }]] - 1)}]
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
        height {} paginate 0 columns 1 gutter {} balance 0
        indent 0 indentRight 0 firstIndent 0 paragraphSpacing 0
        avoid {} avoidMargin 0 tag P expansion {}}
    foreach name $::tclpdf::text::stateOptions {
      dict set defaults $name [my TextGet $name]
    }
    # Listed among the defaults so that [option parse] knows the option
    # exists; the value itself is read out of the state that TextMerge builds,
    # which is where it is checked.
    set defaults [dict merge $defaults $::tclpdf::text::runOptions]
    set options [::tclpdf::option parse $defaults $args "text"]
    # Checked rather than left to lassign: writing -at {20 [expr {$y+5}]} is a
    # standing invitation, the braces stop the substitution, and Tcl then
    # reports "list element in braces followed by ]" from somewhere inside the
    # method - which says nothing about the actual mistake.
    set at [::tclpdf::option point [dict get $options at] -at text]
    if {![string is boolean -strict [dict get $options paginate]]} {
      return -code error "tclpdf: -paginate takes a boolean, not\
          \"[dict get $options paginate]\""
    }
    # Checked here, before the mark below is opened - a wrong value used to
    # act as baseline in silence, so -anchor middle drew a baseline block and
    # nobody was told. See TextAnchor for the two values there are.
    my TextAnchor [dict get $options anchor]
    if {![string is double -strict [dict get $options rotate]]} {
      return -code error "tclpdf: -rotate takes an angle in degrees, not\
          \"[dict get $options rotate]\""
    }
    # EVERYTHING that can be refused is refused HERE, before a byte reaches
    # the stream or a mark the tree - the font state with its per-call
    # overrides, the alignment of a line, the options of a paragraph. The
    # mark used to be opened first and the checks came after it, so a refused
    # -align left the BDC standing in the stream with no EMC, a leaf with an
    # empty MCID in the tree, and, for -tag Artifact, the whole document
    # believing it was still inside an artifact: every later mark was
    # suppressed. Measured, not deduced (2026-08-18). After a refused call
    # the stream, the tree and the state have to look as if the call never
    # happened - so the order is: check, then mark, then draw.
    set state [my TextMerge $args]
    set width [dict get $options width]
    if {[dict get $options paginate] && $width eq {}} {
      return -code error "tclpdf: -paginate breaks a paragraph over pages, and\
          a paragraph needs -width"
    }
    if {$width ne {}} {
      # The paragraph half of this topic. Loaded here rather than at the top
      # of the file: textBlock requires text, so requesting it up front would
      # be a cycle. At this point text is fully provided and it is not.
      #
      # This is the facade rule in practice - a caller says "text with a
      # width" and does not need to know that two files are involved.
      package require tclpdf::textBlock
      set options [my TextBlockCheck $options]
    } else {
      # Alignment of a single line is a shift of the starting point - there
      # is no PDF operator for it. The shift is passed on rather than applied
      # to x here, because it has to happen ALONG THE BASELINE: with -rotate
      # the baseline is turned, and shifting x beforehand moved the anchor
      # horizontally and then rotated about the wrong point - a rotated
      # centred word drifted off towards the corner instead of staying
      # centred on -at.
      #
      # A line feed is refused here, by name: [text] sets ONE line, and a
      # paragraph is asked for with -width. It used to be refused as well -
      # as a character the face has no glyph for, from inside the drawing,
      # which said nothing about the mistake and came after the mark.
      if {[string first \n $string] >= 0} {
        return -code error "tclpdf: text sets one line, and the string has a\
            line feed at position [string first \n $string] - give -width to\
            set a paragraph, which breaks at line feeds"
      }
      # Measured before the mark as well: the width is where a character the
      # face has no glyph for is reported, and the drawing below meets the
      # same glyph run and cannot fail on it afterwards.
      set lineWidth [my textWidth $string {*}$args]
      switch -- [my TextAlign [dict get $options align] $state] {
        left {set shift 0}
        right {set shift $lineWidth}
        center - centre {set shift [expr {$lineWidth / 2.0}]}
        justify {
          # Without a -width there is nothing to justify to.
          return -code error "tclpdf: -align justify needs -width"
        }
        default {
          return -code error "tclpdf: -align must be left, right, center or\
              justify, not \"[dict get $options align]\""
        }
      }
    }
    # Tagged PDF: ONE call is one piece of marked content, so a paragraph of
    # five lines becomes one P holding one mark rather than five. The bracket
    # sits outside everything the call writes - BDC before the q and EMC after
    # the Q - because BMC/BDC...EMC and BT...ET have to nest cleanly rather
    # than overlap (14.6.1), and a bracket per line would also split a
    # sentence into five leaves for a reader.
    #
    # [my state tagged] rather than [my tagged]: the latter is a method of the
    # structure module, so asking it would load that module for every document
    # whether or not it ever wanted a tree.
    # -expansion: the string is an abbreviation and this is its expanded form
    # (14.9.5) - "EU", "European Union". It goes into the tree as a Span
    # carrying /E, and the mark below lands in that Span; the structure module
    # opens it, and what it opened is closed again after the mark, in
    # reverse. Asked before the tagged check on purpose: without a tree an
    # expansion has nowhere to go, and that is refused there rather than
    # ignored here.
    # A height-limited block that admits not one line draws nothing and
    # answers y as given with the whole string as the rest - decided here,
    # BEFORE the mark and the expansion, so that nothing is marked and no
    # element opened for what is not drawn: measured, a -height max block
    # placed under the type area left an empty BDC..EMC in the stream and a P
    # with a mark of nothing in the tree. The paginating road decides the
    # same way in advance (TextPaginate); -paginate itself never takes this
    # exit, its answer to no room is the next page.
    if {$width ne {} && ![dict get $options paginate]
        && [dict get $options columns] == 1 && [my TextBlockNoRoom $options]} {
      return [dict create y [lindex $at 1] rest $string]
    }
    set opened {}
    if {[dict get $options expansion] ne {}} {
      set opened [my StructureExpansion [dict get $options tag] \
          [dict get $options expansion]]
    }
    # A block that runs page by page or column by column marks per PAGE,
    # inside TextPaginate - a mark cannot straddle the page break that call
    # makes, and every page brackets its own share. Both roads take that
    # exit, -paginate and -columns alike: bracketing here as well put a
    # second BDC inside the first, two P elements for one paragraph and
    # nested MCIDs, which 14.7.4.2 does not allow. Everything else is
    # bracketed here.
    set perPage [expr {$width ne {} && ([dict get $options paginate]
        || [dict get $options columns] > 1)}]
    set mark {}
    if {[my state tagged] eq "1" && !$perPage} {
      # The mark is told where the text BEGINS - its top edge, which is -at
      # for -anchor top and one ascent above the baseline otherwise - so
      # that a destination at the element can name the place on the page.
      set top [lindex $at 1]
      if {[dict get $options anchor] ne "top"} {
        set top [expr {$top - [my TextLift $state top]}]
      }
      set mark [my StructureMark [dict get $options tag] Layout $top]
      my content [my StructureBegin $mark]
    }
    # What is left to fail now is what only the drawing meets - a glyph the
    # face lacks, deep in the line breaker of a paragraph. Caught, so that
    # the bracket is closed and the elements opened for it are closed too,
    # and then rethrown as it was: the alternative is a document that goes
    # on believing it is inside an artifact, or a Span left open on the
    # stack.
    lassign $at x y
    set failed [catch {
      if {$width ne {}} {
        my TextParagraph $string $options
      } else {
        # Answers nothing, as a single line always has: the y under a
        # paragraph is what the block road returns.
        my TextRun $string $state $x $y [dict get $options rotate] $shift \
            [my TextLift $state [dict get $options anchor]]
      }
    } result info]
    if {[llength $mark]} {
      my content [my StructureEnd $mark]
    }
    foreach id [lreverse $opened] {
      my StructureClose $id
    }
    if {$failed} {
      return -options $info $result
    }
    return $result
  }

  # -- internals ----------------------------------------------------------

  # The alignment as the page sees it.
  #
  # -align names the edge the text starts at IN READING ORDER, so in a
  # right-to-left line "left" is the right hand edge and "right" the left one.
  # That is what makes the default work out: left is the natural edge either
  # way, and a caller who sets -direction rtl and nothing else gets a line
  # flush right, which is where a right-to-left line starts.
  #
  # Mirrored here, in front of the branch, rather than inside it: the two
  # alignment switches - one line here, one line per paragraph in textBlock -
  # would otherwise both grow a direction case, and the two would drift.
  # center and justify mean the same thing in both directions and pass
  # through, as does an unknown value, which has to reach the branch to be
  # reported with the word the caller wrote.
  method TextAlign {align state} {
    if {[dict get $state direction] ne "rtl"} {
      return $align
    }
    switch -- $align {
      left {return right}
      right {return left}
    }
    return $align
  }

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

  # The two meanings a y coordinate can have, and nothing else: the manual
  # says "baseline or top", and a value outside the two is refused rather
  # than read as baseline. Returns the anchor, so a caller can test it in the
  # same breath.
  method TextAnchor {anchor} {
    if {$anchor ni {baseline top}} {
      return -code error "tclpdf: -anchor must be baseline or top, not\
          \"$anchor\""
    }
    return $anchor
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
    if {[my TextAnchor $anchor] ne "top"} {
      return 0
    }
    set font [dict get $state resolved]
    if {[my TextEmbedded $font]} {
      set ascent [my FontAscender $font [dict get $state size]]
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
  method TextRun {string state x y rotate {shift 0} {lift 0} {hyphen 0}} {
    set font [dict get $state resolved]
    set size [dict get $state size]
    lassign [my coords $x $y] px py
    set shift [::tclpdf::geometry toPoints $shift [my cget -unit]]
    set lift [::tclpdf::geometry toPoints $lift [my cget -unit]]

    # Where the word spacing comes from decides what has to be written and
    # what has to be taken back again: with TJ there is no Tw in the stream,
    # so a run that sets nothing else needs no guard either.
    #
    # The colour is guarded on the same terms. The fill colour of the text
    # is graphics state as well, and [style -fill] remembers a colour for
    # every shape that names none: a text between the two painted its own
    # colour and left it in force, so the bare rect after "style -fill red;
    # text ..." came out black while the stream state still said red.
    # Only when a style colour IS in force - a document without [style]
    # keeps its bytes.
    set byTJ [my TextTJ $font $state]
    # The rendering mode is text state (Tmode, Table 102), so it leaks past ET
    # exactly as Tc and Ts do and belongs in the guard beside them: a heading
    # set with -render stroke would otherwise leave "1 Tr" in force and the
    # body under it would come out hollow, with nothing in its own call to
    # explain it. The stroke colour and the stroke width leak the same way -
    # they are graphics state - and they only ever go out in a stroking mode,
    # which is guarded already, so the mode alone decides.
    set mode [dict get $::tclpdf::text::renderModes [dict get $state render]]
    set guarded [expr {[dict get $state spacing] != 0
        || ([dict get $state wordSpacing] != 0 && !$byTJ)
        || [dict get $state rise] != 0
        || [dict get $state stretch] != 100
        || $mode != 0
        || ([dict get $state color] ne {} && [my streamState styleFill] ne {})}]
    # Everything that can still refuse is resolved BEFORE the first byte goes
    # into the stream. The colour used to be resolved after "q" and "BT" were
    # already written, so a late refusal - an unknown ICC alias, a wrong
    # component count, an unknown pattern name - left both brackets open in
    # the page stream: BT does not nest (Table 105), and in a tagged document
    # the dangling BT crossed the BDC bracket (14.6.1). GraphicsStyle does it
    # right for the shapes - check everything, then write - and this is the
    # same order. The font resource is resolved first, as it was written
    # first, so the registration order and with it every generated resource
    # name stays what it was.
    set resource [my TextResource $font]
    set colour {}
    if {[dict get $state color] ne {}} {
      # Through GraphicsColour, the road every shape takes: a spot colour
      # gets its colour space resource written and its space recorded for
      # the PDF/A intent check, and a {pattern name} is translated from the
      # caller's alias into the RESOURCE name. It went through ColourUsed
      # alone once, which records but does not translate - a text coloured
      # with a pattern then wrote "/sunset scn", a name no resource dictionary
      # carried; qpdf and veraPDF said nothing, poppler "Unknown pattern".
      set colour [::tclpdf::color operator [::tclpdf::color parse \
          [my GraphicsColour [dict get $state color] text]] fill]\n
    }
    # The outline of the stroking modes, through the road every shape takes
    # rather than a second implementation of it: [GraphicsStyle] checks the
    # colour and the width, translates a {pattern name}, records the colour
    # space for the PDF/A intent check and produces the operators [style]
    # produces - "RG" and "w", the same bytes a stroked rectangle gets. Asked
    # with guard 0, so it writes nothing itself and takes no marked-content
    # bracket: that is what [style] passes, and a text run is not a shape.
    #
    # Only in a mode that strokes. In the others the operators would be dead
    # bytes that still change the graphics state, and 9.3.6 is explicit about
    # which colour is consulted: the stroking colour when the mode calls for
    # stroking, the nonstroking one when it calls for filling.
    #
    # graphics is required HERE and not at the head of the file, like
    # textBlock further up: a document that never strokes its text never
    # loads it.
    set stroking {}
    if {$mode in $::tclpdf::text::renderStrokeModes
        && ([dict get $state stroke] ne {}
            || [dict get $state strokeWidth] ne {})} {
      package require tclpdf::graphics
      set stroking [my GraphicsStyle [list stroke [dict get $state stroke] \
          width [dict get $state strokeWidth]] 0 text]
    }
    if {$guarded} {
      my content "q\n"
    }
    my content "BT\n"
    my content "$resource [::tclpdf::pdfObj num $size] Tf\n"
    # "N Tr" (Table 103). Written only when it differs from the initial value
    # of 0, which is what keeps the bytes of every document that never asks
    # for a mode exactly as they were.
    if {$mode != 0} {
      my content "$mode Tr\n"
    }
    if {$colour ne {}} {
      my content $colour
    }
    # Inside the text object, beside the fill colour that has always stood
    # there: 9.4.1 lets the general graphics state and the colour operators
    # appear in a text object, and "w" is one of the general ones (Table 50).
    if {$stroking ne {}} {
      my content $stroking
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
    # A hyphen that marks a BREAK is not a character of the text: extracting
    # the line has to give the word back whole (14.8.2.6). So it is drawn in
    # a Span of its own carrying an EMPTY ActualText, which is how a reader is
    # told to skip it - the alternative, telling the two apart by ToUnicode,
    # cannot work here because one glyph would have to mean two things.
    #
    # No position has to be computed for the second run, and that is the whole
    # reason this is cheap: both shows sit inside ONE text object, so the text
    # cursor is already where the first one left it. Alignment, centring and
    # the stretched word spacing of a justified line are untouched.
    #
    # The break hyphen is the last character of the drawn string, except on a
    # line that had the word space appended - hence the split rather than a
    # fixed position.
    # Only in a tagged document: the bracket means nothing without a tree,
    # and writing it anyway would change the bytes of every existing document
    # that happens to hyphenate.
    if {$hyphen && [my state tagged] eq "1" && [string first "-" $string] >= 0} {
      set at [string last "-" $string]
      set first [string range $string 0 $at-1]
      set second [string range $string $at+1 end]
      # The three pieces are drawn in the order the text cursor moves, and
      # that is always left to right. In a right-to-left line the piece BEHIND
      # the break hyphen is the one that sits on the left, so the two swap -
      # each piece is still reversed inside itself by TextShow.
      if {[dict get $state direction] eq "rtl"} {
        lassign [list $second $first] first second
      }
      my content [my TextShow $font $state $first $byTJ]
      # The empty ActualText is UTF-16 with nothing after the byte order mark.
      my content "/Span <</ActualText <FEFF>>> BDC\n"
      my content [my TextShow $font $state "-" $byTJ]
      my content "EMC\n"
      if {$second ne {}} {
        my content [my TextShow $font $state $second $byTJ]
      }
    } else {
      my content [my TextShow $font $state $string $byTJ]
    }
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

  # The plain width of a string in points, and how many GLYPHS it is.
  #
  # This is the one place that knows the difference between an embedded face
  # and the standard fourteen while measuring, and [TextShow] below is its
  # counterpart while drawing. The two belong together: a caller that measures
  # here and draws there cannot end up with a width that was never set.
  #
  # Both numbers come out of the same run, and the second one is not a
  # convenience. -spacing charges per glyph, because Tc adds its space after
  # every glyph DRAWN; with ligatures that stops being the number of
  # characters - "office" is six characters and, in a face that has the ffi
  # ligature, four glyphs. Counting characters charged for five gaps where
  # three get drawn, and the line came out narrower than measured, visible as
  # a frayed right edge in justified text.
  #
  # Plain: no -spacing, no -wordSpacing, no -stretch. Those widen a line, they
  # do not change what the glyphs measure, and the caller that wants them adds
  # them - [textWidth] does, an SVG drawing does not, because SVG says nothing
  # about them.
  method TextPoints {state string} {
    set font [dict get $state resolved]
    if {![my TextEmbedded $font]} {
      # No kerning and no ligatures for the standard fourteen: the metrics this
      # package ships carry widths per byte value, not the AFM kerning pairs.
      # Asking for either with a standard font is therefore not an error but
      # has no effect - and measuring it here differently from drawing it would
      # be the worse answer. One glyph per character, so the two counts agree.
      return [list [::tclpdf::afm stringWidth $font $string \
          [dict get $state size]] [string length $string]]
    }
    # A Type 1 face is embedded but single-byte: its widths are in the AFM
    # beside it, one per code, and there is no glyph run to build. Kerning and
    # ligatures do not apply - a Type 1 program carries neither GPOS nor GSUB.
    # (An AFM does carry kern pairs; reading them is a separate matter and is
    # named as such in the manual.)
    if {[my FontKind $font] eq "type1"} {
      set codes [my FontType1Encode $font $string]
      set widths [dict get [my state fonts] $font widths]
      set total 0
      foreach code $codes {
        incr total [lindex $widths $code]
      }
      return [list [expr {$total * [dict get $state size] / 1000.0}] \
          [llength $codes]]
    }
    # The LOGICAL run, in both directions. A width is a sum and does not care
    # about the order, and the kerning inside it must not: the pairs are
    # directed - A V is not V A - and measuring a reversed run would answer a
    # width the drawing never produces. So -direction reaches this call only
    # to say which scripts may pass at all.
    set run [my FontRun $font $string [dict get $state ligatures] \
        [dict get $state unshaped] [dict get $state direction]]
    return [list [my FontRunWidth $font $run [dict get $state size] \
        [dict get $state kerning]] [llength $run]]
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
  #
  # The strings built here and in [TextEmit] go to pdfObj DIRECTLY, not
  # through the document's string constructors, and they are the only place
  # in the package that does. They sit INSIDE a content stream, and a
  # content stream is encrypted as a whole (ISO 32000-2, 7.6.2): the strings
  # in it are already covered by that and must not be encrypted a second
  # time, which would leave the file unreadable with no reader able to say
  # why. The rule is the object boundary - a string in an object dictionary
  # is encrypted on its own, a string in a stream travels with the stream.
  method TextShow {font state string byTJ} {
    if {![my TextEmbedded $font]} {
      return "[::tclpdf::pdfObj bytesStr [my TextEncode $font $string]] Tj\n"
    }
    # An embedded Type 1 face goes out as single bytes, like a standard face,
    # and for the same reason: it is addressed through an encoding rather than
    # by glyph number. Word spacing reaches it through Tw as it does there.
    if {[my FontKind $font] eq "type1"} {
      # Inside the content stream - see the head of this method.
      return "[::tclpdf::pdfObj bytesStr [binary format cu* \
          [my FontType1Encode $font $string]]] Tj\n"
    }
    set run [my FontRun $font $string [dict get $state ligatures] \
        [dict get $state unshaped] [dict get $state direction]]
    set adjustments [my TextAdjust $font $state $run $byTJ]
    # THE REORDERING, and this is the only place it happens: after the run has
    # been built and after everything that reads it in logical order - the
    # ligatures inside FontRun, the kerning inside TextAdjust - and before a
    # single byte is written. The glyphs themselves are right either way; what
    # a right-to-left line needs is the ORDER they are shown in.
    set lead 0
    set mirrored {}
    if {[dict get $state direction] eq "rtl"} {
      lassign [my TextReorder $run $adjustments] run adjustments lead
      set mirrored [my TextMirrored $run]
    }
    return [my TextEmit $font $run $adjustments $lead $mirrored]
  }

  # The run and its adjustments in the order they are DRAWN, for a
  # right-to-left line, plus the adjustment that has to be written before the
  # first glyph.
  #
  # Not a plain reversal, and that is the whole content of this method: a run
  # of DIGITS keeps its own order inside the reversed line. The number 4711 in
  # an Arabic invoice reads 4711, not 1174 - digits are written left to right
  # in every script that uses them, which is rules W2 to W7 of UAX #9 applied
  # to one run and nothing else. bidi.tcl says where those runs are; here they
  # are pieces that keep their order while the LIST of pieces is turned round.
  #
  # THE ADJUSTMENTS travel with the glyphs, and not by being reversed with
  # them. An adjustment is written AFTER the glyph it belongs to and closes
  # the gap to the NEXT one, so what has to be written after a drawn glyph is
  # the gap between it and whatever now follows it:
  #
  #   inside a piece   the glyphs still run forwards, so it is the gap after
  #                    the glyph itself - the same as in a left-to-right line
  #   at its end       the next piece is the one BEFORE it logically, so it is
  #                    the gap in front of the piece just drawn
  #
  # Both cases are the same rule seen from two sides, and the plain reversal
  # this replaces is what it reduces to when every piece is one glyph. What
  # falls off the front is the gap after the LAST logical glyph - a word space
  # at the end of the line - and it goes in front of the first glyph drawn,
  # which is where the end of a right-to-left line is.
  #
  # EVERY gap is written exactly once, which is what keeps the drawn line as
  # wide as [textWidth] measured it: the pieces contribute the gaps inside
  # them, the boundaries contribute the gaps between them, and the lead
  # contributes the last. The one place this is a compromise rather than an
  # answer is the boundary itself - the two glyphs that end up beside each
  # other there were not neighbours in the logical run, so the kerning written
  # between them is the one the logical pair had. A shaper avoids the question
  # by shaping each run separately and kerning across none of them; doing that
  # here would change the width of the line after it was measured.
  method TextReorder {run adjustments} {
    # One code point per glyph, and for a glyph that stands for several - a
    # ligature - the list of them: bidi.tcl treats the list as a letter of
    # its last code point's kind and never as a number. It used to be handed
    # -1, and a lam-alef that ended the word before a number was then no
    # letter at all for W2: measured, "\u0644\u0627 12%" set a European
    # 12% where fribidi --rtl sets the Arabic "%12".
    set codes [lmap item $run {lindex $item 1}]
    set order {}
    set gaps {}
    foreach piece [my TextPieces $codes rtl] {
      lassign $piece from to
      for {set index $from} {$index <= $to} {incr index} {
        lappend order $index
        lappend gaps [expr {$index < $to ? $index : $from - 1}]
      }
    }
    set drawn {}
    foreach index $order {
      lappend drawn [lindex $run $index]
    }
    set moved {}
    set lead 0
    if {[llength $adjustments]} {
      set lead [lindex $adjustments end]
      foreach gap $gaps {
        # The last drawn glyph has nothing after it: its "gap" is the one in
        # front of logical position 0, which does not exist.
        lappend moved [expr {$gap < 0 ? 0 : [lindex $adjustments $gap]}]
      }
    }
    return [list $drawn $moved $lead]
  }

  # The pieces of a line in the order they are DRAWN, as {first last} index
  # pairs over the positions given.
  #
  # Two callers, one answer: [TextShow] reorders a glyph run in one go,
  # [textPath] walks a path placing one glyph at a time, and if the two built
  # this order separately a number would come out one way along a straight
  # baseline and the other way along a curve.
  method TextPieces {codes direction} {
    if {$direction ne "rtl"} {
      set pieces {}
      set count [llength $codes]
      for {set index 0} {$index < $count} {incr index} {
        lappend pieces [list $index $index]
      }
      return $pieces
    }
    package require tclpdf::bidi 1.0-
    return [lreverse [::tclpdf::bidi segments $codes]]
  }

  # Which of the drawn glyphs stand for a MIRRORED character, as
  # {index originalCodePoint}.
  #
  # Asked of the run rather than remembered from FontRun, because the answer
  # is in it: mirroring is applied to every occurrence in a right-to-left
  # line, and the pairs are symmetrical, so a glyph whose code point has a
  # mirror IS one, and the character the caller wrote is that mirror.
  method TextMirrored {run} {
    package require tclpdf::bidi 1.0-
    set mirrored {}
    set index 0
    foreach item $run {
      set codes [lindex $item 1]
      if {[llength $codes] == 1} {
        set code [lindex $codes 0]
        set original [::tclpdf::bidi mirror $code]
        if {$original != $code} {
          dict set mirrored $index $original
        }
      }
      incr index
    }
    return $mirrored
  }

  # The show operators for a run that is already in drawing order.
  #
  # A mirrored glyph is drawn inside a Span of its own carrying the character
  # it stands for as ActualText (14.9.4), and that is not decoration: the
  # ToUnicode map is per GLYPH, and the glyph of ")" is the glyph of ")"
  # wherever it is used, so a line holding a mirrored bracket would otherwise
  # extract with the brackets swapped. Measured with poppler 26.08.0: without
  # the span "(שלום)" comes back as ")שלום(", with it as it was written. Same
  # device as the break hyphen above, and for the same reason - the drawn
  # glyph and the character are not the same thing.
  method TextEmit {font run adjustments lead mirrored} {
    if {![llength $run]} {
      # An empty line still writes its show operator: it is what an empty
      # paragraph line has always produced, and leaving it out would change
      # the bytes of every document that has one. Straight to pdfObj, like
      # every string inside a content stream - see [TextShow].
      return "[::tclpdf::pdfObj bytesStr [my FontRunEncode $font {}]] Tj\n"
    }
    # {actualText tokens} per piece, where a token is {glyph item} or
    # {gap number}. The gap AFTER a mirrored glyph opens the next piece,
    # which a TJ array takes as its first element.
    set segments {}
    set tokens {}
    if {$lead != 0} {
      lappend tokens [list gap $lead]
    }
    set count [llength $run]
    for {set index 0} {$index < $count} {incr index} {
      if {[dict exists $mirrored $index]} {
        lappend segments [list {} $tokens]
        set tokens {}
        lappend segments [list [dict get $mirrored $index] \
            [list [list glyph [lindex $run $index]]]]
      } else {
        lappend tokens [list glyph [lindex $run $index]]
      }
      set value [lindex $adjustments $index]
      if {$value ne {} && $value != 0} {
        lappend tokens [list gap $value]
      }
    }
    lappend segments [list {} $tokens]
    set result {}
    foreach segment $segments {
      lassign $segment actual tokens
      set body [my TextTokens $font $tokens]
      if {$body eq {}} {
        continue
      }
      if {$actual eq {}} {
        append result $body
        continue
      }
      append result "/Span <</ActualText\
          <FEFF[format %04X $actual]>>> BDC\n" $body "EMC\n"
    }
    return $result
  }

  # One show operator for a list of tokens: "(bytes) Tj" when nothing has to
  # be adjusted between the glyphs, a TJ array when something has.
  method TextTokens {font tokens} {
    set parts {}
    set piece {}
    set numbers 0
    foreach token $tokens {
      lassign $token kind value
      if {$kind eq "glyph"} {
        lappend piece $value
        continue
      }
      if {[llength $piece]} {
        # In the content stream, so not through the document - see [TextShow].
        lappend parts [::tclpdf::pdfObj bytesStr [my FontRunEncode $font $piece]]
        set piece {}
      }
      lappend parts [::tclpdf::pdfObj num $value]
      incr numbers
    }
    if {[llength $piece]} {
      # In the content stream, so not through the document - see [TextShow].
      lappend parts [::tclpdf::pdfObj bytesStr [my FontRunEncode $font $piece]]
    }
    if {![llength $parts]} {
      return {}
    }
    if {!$numbers} {
      return "[lindex $parts 0] Tj\n"
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

  # Every value the font state takes is refused HERE, where it arrives - in
  # [font] for the state, in TextMerge for a value given per call - so the
  # message names the call that wrote it. Only the family is left to its own
  # resolver and the direction to the gate in TextMerge; both refuse with
  # their own message at the same moment.
  #
  # Checking only where a value is USED was the previous state, and what it
  # did was measured (2026-08-18): "-leading 120%" set a single line in
  # silence and blew a paragraph up with a raw "can't use non-numeric string
  # as operand" from the block arithmetic; "font -spacing foo" was stored
  # without a word and the raw error came from the NEXT text call, which
  # named nothing the caller had written there; and the three booleans took
  # any string at all, because the standard-font road never reads them.
  #
  # Size and stretch refuse zero as well: a size of zero draws nothing and
  # measures nothing, a stretch of zero the same, and a negative one of
  # either draws it backwards or not at all. The leading refuses zero for
  # the same reason - every line of a block would land on the first one -
  # but keeps the empty string, which stands for the default of 1.2 times
  # the size (decided in TextMerge, where the size is known). Spacing, word
  # spacing and rise take any number: negative spacing tightens, a negative
  # rise is a subscript.
  method TextCheck {name value} {
    switch -- $name {
      style {
        # The words the manual names, split the way they are read: any
        # order, any case, joined by spaces, commas or hyphens. Anything
        # else used to be dropped in silence - "-style foo" set the regular
        # face and "{bold foo}" the bold one, and a typo in a style was a
        # heading in the wrong weight with nothing to say why.
        foreach word [split [string tolower [join $value " "]] " ,-"] {
          if {$word ne {} && $word ni {bold italic oblique}} {
            return -code error "tclpdf: -style takes bold, italic or oblique,\
                alone or together, not \"$value\""
          }
        }
      }
      size {
        if {![string is double -strict $value] || $value <= 0} {
          return -code error "tclpdf: -size must be a positive number of\
              points, not \"$value\""
        }
      }
      stretch {
        if {![string is double -strict $value] || $value <= 0} {
          return -code error "tclpdf: -stretch is a percentage above zero,\
              100 being normal, not \"$value\""
        }
      }
      leading {
        if {$value ne {} && (![string is double -strict $value]
            || $value <= 0)} {
          return -code error "tclpdf: -leading is a line spacing in points\
              above zero - or empty for the default of 1.2 times the size -\
              not \"$value\""
        }
      }
      spacing - wordSpacing - rise {
        if {![string is double -strict $value]} {
          return -code error "tclpdf: -$name takes a number of points, not\
              \"$value\""
        }
      }
      kerning - ligatures - unshaped {
        if {![string is boolean -strict $value]} {
          return -code error "tclpdf: -$name takes a boolean, not \"$value\""
        }
      }
      color - stroke {
        # The empty string leaves the colour of the stream in force - that is
        # what TextRun reads it as - so only a non-empty value has to parse.
        # The parser's own message is the one the drawing would have raised;
        # it only comes at the call that wrote the colour now, not at the
        # next text.
        if {$value ne {}} {
          ::tclpdf::color parse $value
        }
      }
      strokeWidth {
        # The empty string means "whatever line width is in force", which is
        # the initial value of 1.0 user space unit (Table 51 - device-
        # independent graphics state parameters) unless a [style] set one.
        # Zero is a width and means the thinnest line the device can render,
        # one device pixel (8.4.3.2); below zero is not a width at all - the
        # parameter "shall be a non-negative number". Same rule and same
        # numbers as -width in [style], said here because the option is
        # written here and a caller must not have to run a text call to find
        # out that the value was refused.
        if {$value ne {} && (![string is double -strict $value]
            || $value < 0)} {
          return -code error "tclpdf: -strokeWidth is a line width of 0 or\
              more in the document unit, not \"$value\""
        }
      }
      render {
        # The clipping modes first, so that the word a caller wrote is
        # answered with the reason it cannot have it rather than with a list
        # it is already in. See renderClipModes at the head of this file.
        if {$value in $::tclpdf::text::renderClipModes} {
          return -code error "tclpdf: -render $value is a clipping mode\
              (9.3.6, modes 4 to 7), and tclpdf does not write those: the\
              glyph outlines become a clipping path at ET that stays in\
              force until the next Q, this package sets one BT/ET per line\
              inside its own q/Q, and a second line would be clipped to the\
              intersection with the first, which is empty - available are\
              fill, stroke, fillStroke and invisible"
        }
        if {![dict exists $::tclpdf::text::renderModes $value]} {
          return -code error "tclpdf: -render is fill, stroke, fillStroke or\
              invisible, not \"$value\""
        }
      }
    }
    return
  }

  method TextInit {} {
    if {[my state text] eq {}} {
      my state text [dict create \
          family helvetica style {} size 12 color black spacing 0 \
          wordSpacing 0 stretch 100 leading {} rise 0 kerning 1 \
          ligatures 1 unshaped 0 render fill stroke {} strokeWidth {} \
          resolved Helvetica]
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
  #
  # The per-call options are merged in first at their defaults and then read
  # from the arguments like the font options, which is what makes them reach
  # every road at once: [textWidth], the line breaker and the drawing all come
  # through here, and a direction that only [text] knew about would measure a
  # line one way and set it another.
  method TextMerge {arguments} {
    set state [dict merge [my TextState] $::tclpdf::text::runOptions]
    set changed 0
    foreach {option value} $arguments {
      set name [string trimleft $option -]
      if {[dict exists $::tclpdf::text::runOptions $name]} {
        dict set state $name $value
      }
      if {$name in $::tclpdf::text::stateOptions} {
        my TextCheck $name $value
        dict set state $name $value
        if {$name in {family style}} {
          set changed 1
        }
      }
    }
    # Checked here rather than at each call: this is the one gate every
    # measuring and drawing road passes, and a misspelt direction that reached
    # the drawing would simply set the line the other way round in silence.
    if {[dict get $state direction] ni {ltr rtl}} {
      return -code error "tclpdf: -direction must be ltr or rtl, not\
          \"[dict get $state direction]\""
    }
    # A right-to-left line needs a face that has right-to-left letters, and
    # the standard fourteen have none: WinAnsi. Refused rather than accepted,
    # because accepted it did nothing - the reordering lives on the glyph
    # road, which a standard face never takes, so "-direction rtl" on
    # Helvetica set the line left to right in silence, alignment mirrored and
    # nothing else. Same for an embedded Type 1 face, which is addressed
    # through the same encoding.
    if {[dict get $state direction] eq "rtl"} {
      set family [dict get $state family]
      if {![my TextEmbedded $family] || [my FontKind $family] eq "type1"} {
        return -code error "tclpdf: -direction rtl needs a TrueType or\
            OpenType face embedded with \[font embed\] - \"$family\" is\
            addressed through WinAnsiEncoding, which has no right-to-left\
            letters"
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

package provide tclpdf::text 1.13