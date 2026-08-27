#
# tclpdf - PDF generation for Tcl
#
# colorFont - a COLR colour font as a Type 3 font
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
#   package require tclpdf::colorFont
#   $doc colorFont signs signs.ttf -chars "⚠✅"
#   $doc font -family body -size 14 -fallback signs
#   $doc text "⚠ mind the step"
#
# The -fallback is not decoration. A font built here holds the characters that
# were ASKED for and nothing else - not a space, not a letter - because that is
# what -chars says and what a 255-glyph font can hold. So the words come out of
# a face and the symbols out of this one, which is the arrangement a drawn font
# has always been for; [font -family signs] alone is for a line that is nothing
# but symbols.
#
# -chars TAKES TEXT, AND THE PACKAGE FINDS THE SEQUENCES IN IT. An emoji face
# draws a family, a skin tone and a flag as ONE glyph each, and that glyph has
# no character of its own: it is a GSUB ligature over several. So -chars is
# read as text rather than as a bag of characters, the "ccmp" feature of the
# face is applied to it, and every glyph that comes out is one glyph of the
# Type 3 font - carrying the WHOLE sequence as its text. A caller writes
#
#   $doc colorFont emoji NotoColorEmoji-Regular.ttf -chars "👨‍👩‍👧👍🏽🇩🇪"
#
# and gets three glyphs: the family, the thumb with its skin tone, and the
# German flag. Nobody has to take the string apart first, and nobody could:
# which characters belong together is a property of the FACE, not of Unicode
# and not of the caller.
#
# WHY ccmp AND NOTHING ELSE. Measured 2026-08-26: Noto Color Emoji, 25.1 MB
# and 3993 base glyphs of COLR version 1, carries exactly ONE GSUB feature,
# and it is "ccmp" - four lookups, a ligature, a chaining contextual, a
# ligature and a contextual. Every sequence an emoji face forms is under it.
# That is also the right feature on principle: "ccmp" is compose and
# decompose, which is never a typographic option a caller switches on and off,
# while "liga" and its relatives are - a colour font built here would then
# depend on a -ligatures nobody wrote in the call.
#
# WHAT COMES BACK IS COMPARED WITH hb-shape, which is the only oracle worth
# having here: measured over the family emoji, the four-person family, the
# skin tone modifiers, the flags of two countries, the Scottish tag sequence,
# the keycap and the transgender flag, tclpdf picks the same glyph HarfBuzz
# 14.3.1 picks, glyph number for glyph number.
#
# THE VARIATION SELECTORS ARE THE ONE SPECIAL CASE, and they are not one for
# long. U+FE0F, the emoji presentation selector, sits inside half the real
# sequences and Noto's cmap has no glyph for it at all - HarfBuzz replaces
# such a default-ignorable with an invisible glyph and steps over it while
# matching. Here it is DROPPED from the glyph run and ATTACHED to the codes of
# the character before it, which comes to the same match and keeps the text:
# the sequence extracts complete, selector and all, because the ligature that
# follows merges the codes of everything it swallows. A selector with no
# character in front of it attaches to the one behind.
#
# THE JOINT, and nothing else. This file reads no table, decodes no outline
# and writes no PDF object - every one of those exists once, next door:
# colr.tcl reads which layers a version 0 base glyph has and what colour each
# of them names, colrPaint.tcl reads the paint graph of a version 1 one,
# glyfPath.tcl turns an outline into path operators, colorFontPaint.tcl draws
# a paint graph, and type3.tcl takes the finished glyph streams. What is here
# is the DECISION and the version 0 drawing, which is short enough to stay.
#
# THREE KINDS OF GLYPH, and the decision between them is this file's subject.
# Asked in the order the standard gives, because a face may describe some
# glyphs one way and some the other ("a font may use the version 1 structures
# for some base glyphs and the version 0 structures for other base glyphs",
# 5.7.11):
#
#   1. a VERSION 1 paint graph, drawn by colorFontPaint.tcl - a tree of
#      clipped shapes, gradients, transformations and compositions.
#   2. the VERSION 0 layer records, drawn below - flat outlines each filled
#      with one palette colour.
#   3. NEITHER, and then the glyph's own outline in the colour of the text.
#      A colour face carries ordinary glyphs beside its coloured ones, and
#      refusing those would be refusing a face for having a plain arrow in it.
#      What IS refused is one step further on: an empty outline as well, which
#      would put a blank glyph into the font with nothing reporting it.
#
# WHY TYPE 3. PDF has no colour font. A font program goes into a file as an
# outline program and the text operators paint it in ONE colour, whatever the
# face carries beside it - which is why a COLR font embedded as a font file
# comes out blank ([font embed] refuses that since 2026-08-21, error code
# TCLPDF FONT OUTLINES: its base glyphs have empty outlines, measured over all
# 3689 of Twemoji Mozilla's). A Type 3 font (ISO 32000-2, 9.6.4) has no font
# program at all: its glyphs ARE content streams, and a content stream may set
# a colour per layer. So the colour font becomes a drawn font, and from there
# on it is a family like any other - [font -family], [textWidth], a table cell,
# a paragraph. It moves with the line, it scales with -size, it is copied and
# searched through /ToUnicode, and none of that is written here: it comes with
# the road [font define] and [font glyph] already are.
#
# THE ROAD IS NOT AFFECTED BY THE EMBED REFUSAL, and that is checked rather
# than assumed (tests colorFont-1.4 and -1.5 hand the same face to both):
# [FontDrawsNothing] is asked in [FontEmbed] and nowhere else, so a face whose
# every character has an empty outline - which is what a colour font looks
# like from the outside, and therefore exactly this module's material - is
# refused as a font FILE and taken here.
#
# d0, NOT d1. A glyph description beginning with d1 "specifies only shape, not
# colour", and the norm is explicit about what follows: such a description
# "should not execute any operators that set the colour ... any use of such
# operators shall be ignored" (9.6.4, Table 111). A colour glyph is nothing
# BUT colour operators, so d1 would paint every layer of it in the text colour
# and the file would still be valid. d0 is what [font glyph] writes by default
# (-color own), and this module keeps the default rather than restating it.
#
# THE FILL IS NONZERO - "f", never "f*". TrueType winds an outer contour one
# way and an inner one the other, and that is what makes the counter of an "O"
# a hole. Even-odd draws the same "O" and parts company where contours OVERLAP,
# which in a colour font is not the exception: a layer is drawn on top of
# other layers and is free to cross itself. The reasoning stands in full at
# the head of glyfPath.tcl.
#
# EVERY LAYER SITS IN ITS OWN q/Q, and that is a correctness matter rather
# than tidiness. A colour operator holds until it is changed, so a layer that
# sets no colour - the 0xFFFF sentinel below - would inherit the colour of the
# layer UNDER it instead of the colour of the text. The bracket is what makes
# each layer start from the state the glyph was entered in.
#
# THE 0xFFFF SENTINEL is the reason the sentinel case is tested harder than
# the ordinary one. A layer whose palette index is 0xFFFF does not name a
# palette entry; it means "whatever colour the text has" (ISO/IEC 14496-22,
# 5.7.11), and [colr color] answers the empty string for it. Such a layer
# therefore gets NO colour operator at all and is filled with the text colour,
# which under d0 is simply the fill colour in force when the glyph is invoked.
# Measured on 2026-08-21: Twemoji Mozilla, the only real version 0 font on
# this machine, uses the sentinel in NONE of its 33179 layers and has exactly
# one palette - an emoji face has no use for it. A two-colour logo, a warning
# sign, a marker that is to follow the running text has every use for it, and
# that is the kind of font this module is for.
#
# FONT UNITS ALL THE WAY, and one "cm" to keep them. [glyfPath] writes the
# outline in font units and does not scale, because the /FontMatrix of the
# Type 3 font is where that scale belongs - so the matrix is 1/unitsPerEm and
# every number in the stream is the integer the face stores. The one operator
# in the way is type3's own: a glyph script draws through the document unit
# and [Type3Stream] therefore prefixes the stream with a "cm" that scales
# POINTS back to glyph units. These operators are not points, they are glyph
# units already, so the first thing written here is that correction's inverse.
# It is one operator per glyph, and only when the document is not in pt.
#
# ALPHA COSTS AN ExtGState, AND ONLY WHEN THERE IS ANY. A CPAL entry carries
# an alpha byte, and PDF keeps constant alpha nowhere near the colour: /ca
# lives in an ExtGState (11.6.6), so a translucent layer needs a resource and
# a "gs" while an opaque one needs nothing. An opaque entry must therefore
# cost nothing at all, and that is the common case by a wide margin - measured
# over Twemoji Mozilla's 1063 palette entries, 1048 are fully opaque and 15
# are not, so the 1.4 % that carry alpha are real and are honoured rather than
# dropped. The resource comes from [GraphicsOpacity], one per distinct value
# for the whole document, and lands in the Type 3 font's own /Resources
# because [Type3ResourcePairs] collects the names the glyph streams mention.
# PDF/A: parts 2 and 3 permit transparency, part 1 does not and is refused by
# [pdfa] for other reasons anyway.
#
# WHAT IS REFUSED BY NAME, all of it below TCLPDF COLORFONT:
#
#   - a face without COLR and CPAL, before anything is defined. What colr.tcl
#     and colrPaint.tcl refuse on top of that - an unknown version, an empty
#     table, a truncated one, a cycle in the paint graph - keeps its own
#     TCLPDF COLR codes and is passed through unchanged.
#   - a character the face has no glyph for.
#   - a shape that is a COMPOSITE glyph. [glyfPath] refuses those by name,
#     because assembling components is glyfOutline's subject and a second
#     walker would be the same logic twice. Whether that matters was measured
#     rather than assumed: of Twemoji Mozilla's 33179 layer glyphs, 33179 are
#     simple and NONE is a composite, and of Noto Color Emoji's 129823 version
#     1 shapes likewise none - the shapes of a colour glyph are drawn figures,
#     not letters with accents. If a face ever needs it, the way in is a
#     public "points with contour ends, through composites" in glyfOutline,
#     not a resolver here.
#   - a glyph that would draw nothing: layers that are all empty, a paint
#     graph whose every shape is missing, or a plain glyph with an empty
#     outline. That is the blank-page trap of [font embed] one level down, and
#     it is refused for the same reason: the document would be valid,
#     extractable and empty.
#   - more than 255 GLYPHS. A Type 3 font is addressed by single bytes and
#     holds at most 255 of them (9.6.5.3, and [Type3Code]); the limit is
#     checked after the sequences have been found and before the font is
#     defined, so that the 256th glyph is a refusal and not a silent
#     truncation. Counted in glyphs and not in characters, because a sequence
#     of seven characters is one glyph - the two numbers part company as soon
#     as an emoji face is in play.
#   - a character the face takes APART. A "ccmp" lookup may substitute one
#     glyph by several, and one of the pieces then carries the text while the
#     others carry none ([gsubApply MultipleAt]). A Type 3 glyph is one
#     drawing with one advance and cannot be two, so such a face is refused by
#     name rather than drawn with a piece missing. No colour face measured
#     here does it - Noto Color Emoji's ccmp holds ligatures and contextual
#     lookups and no Multiple substitution at all - which is why it is a
#     refusal and not a road.
#
# WHAT IS DELIBERATELY NOT DONE HERE:
#
#   - a second Type 3 font under the hood for a document that wants more than
#     255 glyphs of one colour face. The refusal above is the answer, and the
#     road past it is the one this module was built around: [font -fallback]
#     takes a list of faces, so two calls of [colorFont] with two aliases and
#     both of them in the chain set what one cannot - without this module
#     inventing a font the caller never named and cannot address.
#   - a /FontBBox. [font define] writes four zeros without -bbox, which
#     Table 110 reads as "make no assumptions"; a box computed from the layers
#     would be a claim about glyphs that may still be added to the font.
#   - anything about which characters a face HAS. A caller that wants to know
#     asks [::tclpdf::colr has] and the font's cmap, which is what this does.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::geometry 1.0-
package require tclpdf::io 1.0-
package require tclpdf::color 1.0-
# For [GraphicsOpacity], the ExtGState a translucent layer needs. Named here
# rather than left to the lazy dispatcher in document.tcl: that one maps
# PUBLIC methods to topics and knows nothing of [GraphicsOpacity], so a
# translucent layer used to die with "unknown method" - measured 2026-08-21
# against Twemoji Mozilla's U+1F3AF, whose second layer is at alpha 0.2.
# shape.tcl, image.tcl and xObject.tcl name it the same way.
package require tclpdf::graphics 1.0-
package require tclpdf::sfnt 1.0-
package require tclpdf::colr 1.1-
# The third kind of colour face: a picture per glyph. Read at the top like
# colr.tcl, because [colorFont] has to ASK which of the three a face is before
# it can decide anything - and both answers are a table lookup.
package require tclpdf::sbix 1.0-
# For [morx has], which is asked of every face that has no GSUB - see
# [ColorFontUnits]. The table READER is loaded only where there is a table.
package require tclpdf::morx 1.0-
package require tclpdf::glyfOutline 1.0-
package require tclpdf::glyfPath 1.0-
package require tclpdf::document 1.0-
# 1.3 and not 1.0: a colour font builds a glyph for a character SEQUENCE, and
# [font glyph] takes one only from that version on. The other requirements
# here are unpinned because what this file asks of them has not moved.
package require tclpdf::type3 1.3-

namespace eval ::tclpdf::colorFont {
  # A Type 3 font is addressed by single bytes and code 0 is not used, so 255
  # glyphs is the ceiling. Stated here rather than counted from type3.tcl's
  # loop, and checked against it by a test.
  variable maximum 255
}

oo::define ::tclpdf::document::document {

  # $doc colorFont <alias> ?<path>? ?-data bytes? -chars <string> ?-palette n?
  #
  # Builds a Type 3 font named <alias> holding one glyph per character of
  # -chars, drawn from the colour glyphs of the face. Returns the alias, so
  # that the call can be handed straight to [font -family].
  #
  # The name is FIRST and positional and the file follows it, exactly as
  # [image embed] takes them - and -data replaces the path for the face that
  # never was a file: one built in memory, one out of a database, one out of
  # an archive. The odd/even trick is that module's as well; two commands of
  # one package answering the same question differently is the kind of seam
  # that gets discovered rather than read.
  method colorFont {args} {
    if {![llength $args]} {
      return -code error -errorcode {TCLPDF COLORFONT ALIAS} \
          "tclpdf: colorFont needs a name for the font"
    }
    set alias [lindex $args 0]
    set args [lrange $args 1 end]
    set path {}
    if {[llength $args] % 2} {
      set path [lindex $args 0]
      set args [lrange $args 1 end]
    }
    set options [::tclpdf::option parse \
        {data {} chars {} palette 0 face 0 strike {}} $args "colorFont"]
    set face [my ColorFontFaceNumber [dict get $options face]]
    if {$path ne {}} {
      # READ BY RANGE, NOT WHOLE. [openFace] reads the table directory and
      # everything under a megabyte, and leaves the bitmap table in the file -
      # which is what makes Apple Color Emoji, 192 MB of which 191 are
      # pictures, cost 26 MB of memory and 40 ms instead of the whole file.
      # See the end of sfnt.tcl. An ordinary face is read exactly as [read]
      # reads one, down to the byte.
      set parsed [::tclpdf::sfnt openFace $path $face]
    } elseif {[dict get $options data] ne {}} {
      set parsed [::tclpdf::sfnt parse [dict get $options data] $face]
    } else {
      return -code error -errorcode {TCLPDF COLORFONT SOURCE} \
          "tclpdf: colorFont needs a file name or -data"
    }
    # The face may be an open file handle, and the record of every glyph
    # carries what it needs OUT of it before this returns - see
    # [ColorFontBitmapRead]. Closing a face that was read whole is a no-op.
    try {
      return [my ColorFontBuild $alias $parsed $options]
    } finally {
      ::tclpdf::sfnt closeFace $parsed
    }
  }

  # Which face of a TrueType collection, checked before the file is opened.
  #
  # ZERO IS THE DEFAULT and a file that is not a collection has one face,
  # which is face 0 - so a caller who has never heard of collections writes
  # nothing and gets the face they expect. sfnt.tcl refuses a number the file
  # has not got, with the count in the message.
  method ColorFontFaceNumber {face} {
    if {![string is integer -strict $face] || $face < 0} {
      return -code error -errorcode [list TCLPDF COLORFONT FACE $face] \
          "tclpdf: -face of colorFont is the face inside a TrueType\
          collection, 0 or more, not \"$face\""
    }
    return $face
  }

  # Which of the three kinds of colour face this is, and the font built from
  # it - everything that happens with the face open.
  #
  # THE ORDER IS THE ORDER OF THE STANDARDS. COLR is asked for first because
  # a face carrying both describes the same glyphs twice and the outline
  # description is the one that scales; sbix second; and a face with neither
  # is the refusal it always was, now naming both tables.
  method ColorFontBuild {alias parsed options} {
    set text [my ColorFontChars [dict get $options chars]]
    set strike {}
    if {[::tclpdf::colr has $parsed]} {
      set kind colour
      if {[dict get $options strike] ne {}} {
        return -code error -errorcode [list TCLPDF COLORFONT STRIKE $alias] \
            "tclpdf: -strike is the pixel size of the BITMAPS to draw from,\
            and this face draws its colour glyphs with the \"COLR\" table -\
            paths, at every size"
      }
      # Anything colr refuses on top of that - version 1, an empty table, a
      # truncated one - comes back with its own TCLPDF COLR code and is not
      # dressed up here: a caller trapping TCLPDF COLR gets the same answer
      # whether it read the tables itself or through this.
      set state [::tclpdf::colr build $parsed]
      set palette [my ColorFontPalette $state [dict get $options palette]]
    } elseif {[::tclpdf::sbix has $parsed]} {
      set kind bitmap
      if {[dict get $options palette] != 0} {
        return -code error -errorcode [list TCLPDF COLORFONT PALETTE \
            [dict get $options palette] 0] \
            "tclpdf: -palette is the colour palette to draw with and this\
            face draws its colour glyphs as PICTURES, which carry their own\
            colours - it has no palette at all"
      }
      package require tclpdf::colorFontBitmap 1.0-
      set state [::tclpdf::sbix build $parsed]
      set strike [::tclpdf::sbix strike $state \
          [my ColorFontStrike [dict get $options strike]]]
      set palette 0
    } else {
      return -code error -errorcode [list TCLPDF COLORFONT TABLES $alias] \
          "tclpdf: this face has no \"COLR\" and \"CPAL\" tables and no\
          \"sbix\" table either, and therefore no colour glyphs - it is an\
          ordinary face and goes into the document with \[font embed\]"
    }

    # PASS ONE reads and refuses; nothing about the document is touched. So a
    # call that names one character the face has not got leaves no half-built
    # font behind - not a family that exists with no glyphs in it, and not an
    # ExtGState for a layer that never reached a stream.
    set built {}
    foreach unit [my ColorFontUnits $parsed $text $alias] {
      set common [my ColorFontCommon $parsed $unit]
      if {$kind eq "bitmap"} {
        lappend built \
            [my ColorFontBitmapRead $parsed $state $strike $common $alias]
      } else {
        lappend built [my ColorFontRead $parsed $state $palette $common $alias]
      }
    }
    # PASS TWO builds. The matrix is the face's own em, so the numbers in the
    # glyph streams are the integers the face stores; the ascent is the one
    # from hhea, which is where -anchor top hangs a line from.
    set upem [dict get $parsed unitsPerEm]
    set scale [expr {1.0 / $upem}]
    set ascent [dict get $parsed ascender]
    if {$ascent <= 0} {
      # A face may leave hhea.ascender at zero. Four fifths of the em is what
      # [font define] itself falls back to, and the number has to be positive
      # or the glyph frame has no height.
      set ascent [expr {$upem * 4 / 5}]
    }
    # The glyph streams before [font define], not during the glyph loop after
    # it: [ColorFontStream] resolves every layer's colour through [ColourUsed]
    # and every alpha through [GraphicsOpacity], and both can REFUSE - a PDF/A
    # document whose output intent does not admit the colour, say. Built after
    # [font define] a refusal on the third glyph would leave a family with the
    # alias taken and no glyphs a caller could finish or retry; built here it
    # throws before the family exists.
    set streams {}
    foreach record $built {
      lappend streams [list [dict get $record text] [dict get $record width] \
          [my ColorFontStream $record $alias]]
    }
    my font define $alias -matrix [list $scale 0 0 $scale 0 0] -ascent $ascent
    foreach stream $streams {
      lassign $stream text width body
      my font glyph $alias $text -width $width \
          -script [list my content $body]
    }
    return $alias
  }

  # Which strike of a bitmap face to draw from, checked before the table is
  # read. The empty string is "the face decides", which is [sbix strike]'s
  # rule and stated there.
  method ColorFontStrike {strike} {
    if {$strike eq {}} {
      return {}
    }
    if {![string is integer -strict $strike] || $strike < 1} {
      return -code error -errorcode [list TCLPDF COLORFONT STRIKE $strike] \
          "tclpdf: -strike of colorFont is the size of the bitmaps to draw\
          from, in pixels to the em, and is a positive whole number - not\
          \"$strike\""
    }
    return $strike
  }

  # What every glyph of the font needs whichever kind of face it comes from:
  # the glyph number, the characters it stands for, and its advance.
  #
  # UNIT is {text glyph} out of [ColorFontUnits] - one character or a whole
  # sequence, and the glyph number the face draws it with. The cmap is not
  # asked again here: it was asked there, and a sequence has no cmap entry to
  # ask about.
  method ColorFontCommon {parsed unit} {
    lassign $unit text glyph
    set u [join [lmap char [split $text {}] {
      format U+%04X [scan $char %c]
    }]]
    return [dict create text $text glyph $glyph u $u parsed $parsed \
        width [::tclpdf::sfnt advance $parsed $glyph]]
  }

  # The characters to build glyphs for, as a list of one-character strings.
  #
  # Counted in CODE POINTS: [split $s {}] hands a surrogate pair back as one
  # element under Tcl 8.6 as well as under 9, which is what makes a symbol
  # beyond the BMP reachable at all (the same reason [font glyph] counts that
  # way - measured 2026-08-21, [string length] counts the pair as two).
  #
  # NO SPLITTING AND NO DEDUPLICATION HERE ANY MORE, and that is the whole of
  # what this method lost on 2026-08-26. It used to hand back one character
  # per element, which was right while a glyph was a character; a sequence is
  # a glyph now, and which characters form one is a question only the face can
  # answer - [ColorFontUnits] asks it. What is left is the refusal of an
  # empty -chars, which is worth a method of its own for the same reason it
  # always was: it is the first thing the call checks.
  method ColorFontChars {chars} {
    if {$chars eq {}} {
      return -code error -errorcode {TCLPDF COLORFONT CHARS} \
          "tclpdf: colorFont needs -chars, the characters and character\
          sequences to build colour glyphs for - a Type 3 font holds at most\
          $::tclpdf::colorFont::maximum glyphs, so there is no \"all\""
    }
    return $chars
  }

  # The GLYPHS the face makes of that text, as {text glyph} pairs in the order
  # they first occur - one pair per glyph of the Type 3 font.
  #
  # THIS IS WHERE A SEQUENCE BECOMES A GLYPH. The characters are looked up in
  # the cmap one by one, exactly as [FontRun] does it, and the run is then put
  # through the "ccmp" feature of the face - see the head of this file for why
  # that feature and no other. Every entry that comes out is one glyph and
  # carries the code points it stands for, so the run says both things at
  # once: which glyph to draw, and which characters it is the text of.
  #
  # A GLYPH NAMED TWICE IS BUILT ONCE. That is not a truncation: what comes
  # out is exactly the font that was asked for, and the alternative - letting
  # [font glyph] refuse the repeat - would turn a harmless list into an error.
  # Deduplicated by the TEXT rather than by the glyph: two sequences may well
  # reach the same glyph in a face that has aliases for it, and dropping the
  # second would leave a caller with text they cannot set.
  #
  # THE PRICE IS NAMED RATHER THAN HIDDEN. -chars "\u2705\u2705\uFE0F" - the
  # same mark written with and without its variation selector - fills TWO of
  # the 255 places with byte-for-byte identical glyph streams: measured, both
  # come out 2760 bytes and equal. That is deliberate, and the reason is one
  # place further on: /ToUnicode carries ONE spelling back per character code
  # (bfchar maps a code to a string, not a string to a code), so a single
  # place would have to choose which of the two the reader gets, and every
  # copy of the other spelling would come back as the chosen one. Two places
  # give "\u2705\uFE0F" back as itself and "\u2705" back as itself. A caller
  # who does not need both spellings names one and pays nothing.
  #
  # THE BOUNDARY IS THE CALLER'S TO WATCH, and it is named here rather than
  # discovered: -chars is one string, so two emoji written side by side are
  # offered to the face side by side, and a face free to ligate them will.
  # For every sequence Unicode defines that is what is wanted - a flag IS two
  # regional indicators in a row, and nothing but their order says which flag.
  # A caller who wants two glyphs where the face would make one asks twice,
  # with two aliases.
  method ColorFontUnits {parsed text alias} {
    set cmap [dict get $parsed cmap]
    set gsub [::tclpdf::sfnt table $parsed GSUB]
    set run {}
    set pending {}
    set position 0
    # The character each code point came in as, so that a unit can be spelled
    # back out of the codes a substitution left. [format %c] would be the
    # obvious way and is the wrong one: under Tcl 8.6 it cannot write a
    # character beyond the BMP, which is where most of an emoji face lives.
    # The characters are in hand here anyway.
    set charOf {}
    foreach char [split $text {}] {
      set point [scan $char %c]
      dict set charOf $point $char
      if {![dict exists $cmap $point]} {
        # A variation selector the face has no glyph for rides along with its
        # neighbour instead of being looked up - see the head of this file.
        # Anything else the face has not got is the refusal it always was.
        if {[my ColorFontRides $point]} {
          if {[llength $run]} {
            set last [lindex $run end]
            lset run end [list [lindex $last 0] \
                [concat [lindex $last 1] $point]]
          } else {
            lappend pending $point
          }
          incr position
          continue
        }
        set u U+[format %04X $point]
        return -code error \
            -errorcode [list TCLPDF COLORFONT CHAR $u $alias] \
            "tclpdf: the face has no glyph for character $u (position\
            $position of -chars), so there is no colour glyph to draw for it"
      }
      lappend run [list [dict get $cmap $point] [concat $pending $point]]
      set pending {}
      incr position
    }
    if {[llength $pending]} {
      set u U+[format %04X [lindex $pending 0]]
      return -code error -errorcode [list TCLPDF COLORFONT CHAR $u $alias] \
          "tclpdf: -chars begins with the variation selector $u and the face\
          has no glyph for it - a selector modifies the character in front of\
          it, and there is none"
    }
    if {$gsub ne {}} {
      # Loaded HERE and not at the top of the file, for the reason font.tcl
      # loads its layout modules where it needs them: a face with no GSUB
      # forms no sequences, and a document of such faces should not parse the
      # substitution machinery to find that out.
      package require tclpdf::gsubApply 1.0-
      package require tclpdf::gdef 1.0-
      set run [::tclpdf::gsubApply apply [::tclpdf::gsubApply feature $gsub \
          ccmp [::tclpdf::gdef build $parsed] {}] $run]
    } elseif {[::tclpdf::morx has $parsed]} {
      # AN APPLE FACE FORMS ITS SEQUENCES SOMEWHERE ELSE. There is no GSUB in
      # Apple Color Emoji at all - what joins a base emoji to a skin tone
      # modifier is "morx", a state machine, and without it a family of three
      # reaches the font as three pictures. Asked SECOND and not first: a face
      # carrying both is an OpenType face with an Apple table beside it, and
      # the feature this reads ("ccmp") is the one that says what belongs
      # together.
      #
      # WHICH SUBTABLES RUN is morx.tcl's decision and is the default set -
      # see the head of that file. There is no equivalent of naming "ccmp"
      # here, because an AAT chain has no feature tags: it has flags, and the
      # ones that are on by default are the ones every reader applies.
      package require tclpdf::morx 1.0-
      set run [::tclpdf::morx apply [::tclpdf::morx build $parsed] $run]
    }
    set seen {}
    set units {}
    # WHICH CHARACTER AND WHERE, for the refusal below - the same two facts
    # the sister refusal COLORFONT CHAR names, and for the same reason: a
    # caller reading "glyph 4711 stands for no character" has nothing to look
    # up in the string they wrote. A Multiple substitution gives ALL the
    # characters to the first of its outputs (gsubApply MultipleAt), so the
    # entry that carries the text is the last one before the empty ones, and
    # its place in -chars is what the code points consumed up to it come to.
    set ownerCodes {}
    set ownerAt 0
    set consumed 0
    foreach entry $run {
      lassign $entry glyph codes
      if {![llength $codes]} {
        # A "ccmp" Multiple substitution took a character apart into several
        # glyphs and gave the text to one of them. See the head of this file:
        # a Type 3 glyph is one drawing with one advance and cannot be two.
        set u [join [lmap point $ownerCodes {
          format U+%04X $point
        }]]
        if {$u eq {}} {
          # Nothing carried text before this glyph: the face gave the
          # characters to an output that is not the first, which the format
          # does not allow and nothing here can name.
          set u "U+????"
        }
        return -code error \
            -errorcode [list TCLPDF COLORFONT SPLIT $u $alias] \
            "tclpdf: the glyph forming of this face draws character $u\
            (position $ownerAt of -chars) as SEVERAL glyphs (glyph $glyph is\
            one of them and stands for no character of its own - a \"ccmp\"\
            Multiple substitution, or a \"morx\" insertion) - a Type 3 glyph\
            is one drawing with one advance, so this face cannot be built\
            into a colour font; set it with \[font embed\] instead"
      }
      set ownerCodes $codes
      set ownerAt $consumed
      incr consumed [llength $codes]
      set unitText [join [lmap point $codes {dict get $charOf $point}] {}]
      if {[dict exists $seen $unitText]} {
        continue
      }
      dict set seen $unitText 1
      lappend units [list $unitText $glyph]
    }
    if {![llength $units]} {
      # EVERY CHARACTER WAS DELETED. An AAT state machine marks a glyph as
      # gone by putting 0xFFFF in its place, and Apple Color Emoji's very
      # first subtable does that to the variation selectors and the zero
      # width joiner - so -chars "\u200D" alone comes back as a run of
      # nothing, and the font would be defined with no glyphs in it: a family
      # a caller can name, set text in and measure, that draws and extracts
      # nothing. Refused with the same code an empty glyph gets, because it
      # is the same trap one step earlier.
      set u [join [lmap char [split $text {}] {
        format U+%04X [scan $char %c]
      }]]
      return -code error -errorcode [list TCLPDF COLORFONT EMPTY $u $alias] \
          "tclpdf: the glyph forming of this face deletes every character of\
          -chars ($u) - a joiner, a variation selector or a tag character\
          draws nothing by design and is swallowed by the sequence it belongs\
          to, so on its own it leaves no glyph at all and the font would come\
          out empty"
    }
    if {[llength $units] > $::tclpdf::colorFont::maximum} {
      return -code error \
          -errorcode [list TCLPDF COLORFONT LIMIT [llength $units]] \
          "tclpdf: -chars comes to [llength $units] glyphs and a Type 3 font\
          is addressed by single bytes, so it holds at most\
          $::tclpdf::colorFont::maximum of them (ISO 32000-2, 9.6.5.3) -\
          build a second font for the rest and name both in -fallback"
    }
    return $units
  }

  # Does this character ride along with its neighbour where the face has no
  # glyph for it?
  #
  # The variation selectors and nothing else: U+FE00 to U+FE0F and the
  # supplement at U+E0100 to U+E01EF. They select a presentation of the
  # character in front of them and draw nothing themselves, which is why a
  # face is free to have no glyph for one - and why dropping it from the glyph
  # run is what HarfBuzz does too, in the shape of an invisible glyph its
  # matching steps over. Everything else the face has not got is a refusal:
  # a character that draws nothing and was meant to is the blank-page trap
  # this module refuses by name everywhere else.
  method ColorFontRides {point} {
    return [expr {($point >= 0xFE00 && $point <= 0xFE0F)
        || ($point >= 0xE0100 && $point <= 0xE01EF)}]
  }

  # The palette to resolve the layers through, checked before anything is
  # built. [colr color] would refuse a wrong number too, but only on the first
  # layer that is not the 0xFFFF sentinel - a font whose first glyph takes the
  # text colour throughout would get away with it until the second.
  method ColorFontPalette {state palette} {
    set count [llength [dict get $state palettes]]
    if {![string is integer -strict $palette] || $palette < 0
        || $palette >= $count} {
      return -code error \
          -errorcode [list TCLPDF COLORFONT PALETTE $palette $count] \
          "tclpdf: -palette is the colour palette to draw with, 0 to\
          [expr {$count - 1}] in this face, not \"$palette\""
    }
    return $palette
  }

  # Everything one glyph of a COLR face needs, read out of it: the layers
  # bottom first as {colour alpha operators}, or the paint graph.
  #
  # COMMON is what [ColorFontCommon] read - the glyph, its text and its
  # advance, which is the half both kinds of face answer the same way.
  #
  # The colour is the empty string for the 0xFFFF sentinel and the alpha is
  # then absent as well - a layer that takes the text colour takes its alpha
  # with it.
  method ColorFontRead {parsed state palette common alias} {
    set glyph [dict get $common glyph]
    set u [dict get $common u]
    set common [dict merge $common [dict create state $state palette $palette]]
    # THE ORDER IS THE STANDARD'S, and it is the reason a version 1 face works
    # at all: "a font may use the version 1 structures for some base glyphs
    # and the version 0 structures for other base glyphs" (5.7.11), so the
    # paint graph is asked for first and the flat layer records second. A face
    # that describes a glyph both ways - which the standard permits and calls
    # unnecessary - is drawn from the version 1 description, which is what a
    # version 1 reader is meant to use.
    set tree [::tclpdf::colr paint $state $glyph]
    if {$tree ne {}} {
      package require tclpdf::colorFontPaint 1.0-
      return [dict merge $common [dict create kind version1 tree $tree \
          clip [::tclpdf::colr clip $state $glyph]]]
    }
    set layers [::tclpdf::colr layers $state $glyph]
    if {![llength $layers]} {
      # Neither half of the table says anything about this glyph. That is not
      # a defect and not an error: a colour face carries ordinary glyphs
      # beside its coloured ones - a face of warning signs may well have a
      # plain arrow - and the answer for one of those is its own outline,
      # drawn in the colour of the text like a letter. What IS refused is the
      # case one step further on: an empty outline as well, which would put a
      # blank glyph into the font with nothing reporting it.
      return [dict merge $common [dict create kind outline \
          operators [my ColorFontPlain $parsed $glyph $u $alias]]]
    }
    set drawn {}
    foreach layer $layers {
      lassign $layer layerGlyph entry
      set outline [::tclpdf::glyfOutline parse \
          [my ColorFontGlyphData $parsed $layerGlyph]]
      if {[dict get $outline type] eq "composite"} {
        return -code error \
            -errorcode [list TCLPDF COLORFONT COMPOSITE $u $layerGlyph $alias] \
            "tclpdf: layer glyph $layerGlyph of character $u is a COMPOSITE\
            glyph - it draws other glyphs rather than an outline of its own,\
            and tclpdf assembles those only when a face is embedded. The\
            layers of a colour glyph are normally drawn shapes rather than\
            letters with accents, so this is unusual; set this character with\
            an embedded face instead"
      }
      set operators [::tclpdf::glyfPath operators $outline]
      if {$operators eq {}} {
        # An empty layer. The format allows one and a face may carry it - it
        # draws nothing either way, so it costs no q/Q and no colour.
        continue
      }
      lappend drawn [list [::tclpdf::colr color $state $palette $entry] \
          $operators]
    }
    if {![llength $drawn]} {
      return -code error -errorcode [list TCLPDF COLORFONT EMPTY $u $alias] \
          "tclpdf: every layer of character $u has an empty outline, so the\
          glyph would draw nothing - a font built from it comes out blank\
          with nothing reporting it"
    }
    return [dict merge $common [dict create kind version0 layers $drawn]]
  }

  # The plain outline of a glyph the COLR table says nothing about, as path
  # operators - the monochrome fallback described in [ColorFontRead].
  #
  # THE BLANK-PAGE TRAP, one level down from [font embed]'s: a face whose
  # base glyphs have empty outlines AND no colour layers would produce a
  # document that is valid, extractable and empty, with neither a reader nor
  # a validator reporting it. So an empty outline here is a refusal and not a
  # glyph that advances and draws nothing.
  method ColorFontPlain {parsed glyph u alias} {
    set outline [::tclpdf::glyfOutline parse \
        [my ColorFontGlyphData $parsed $glyph]]
    if {[dict size $outline] && [dict get $outline type] eq "composite"} {
      return -code error \
          -errorcode [list TCLPDF COLORFONT COMPOSITE $u $glyph $alias] \
          "tclpdf: character $u is glyph $glyph of the face, the \"COLR\"\
          table says nothing about it, and its own outline is a COMPOSITE\
          glyph - it draws other glyphs rather than an outline of its own,\
          and tclpdf assembles those only when a face is embedded. Set this\
          character with an embedded face instead"
    }
    set operators {}
    if {[dict size $outline] && [dict get $outline type] eq "simple"} {
      set operators [::tclpdf::glyfPath operators $outline]
    }
    if {$operators eq {}} {
      return -code error \
          -errorcode [list TCLPDF COLORFONT EMPTY $u $alias] \
          "tclpdf: character $u is glyph $glyph of the face, the \"COLR\"\
          table draws no colour layers for it, and its own outline is empty -\
          so the glyph would draw nothing, and a font built from it comes out\
          blank with nothing reporting it. Most glyphs of a colour font are\
          layers or plain outlines; this one is neither"
    }
    return $operators
  }

  # The glyf bytes of one glyph, or the empty string where it has none.
  #
  # loca holds numGlyphs + 1 offsets and glyph n is empty where the offset
  # behind it does not lie behind its own (ISO/IEC 14496-22, 5.3.3). A layer
  # record may name a glyph number the face does not have; that reads as empty
  # here rather than as an error, and the layer is dropped above.
  #
  # THE FOURTH COPY of this slice - [subset::GlyphData], varFont's [all] and
  # the test helper have it too - and it should be one accessor beside
  # [sfnt advance] rather than four. Not made one here: sfnt.tcl belongs to
  # the modules below this one, and reaching into the subsetter for it would
  # load fourteen kilobytes of subsetting to read four bytes of loca in a
  # module that never subsets anything.
  method ColorFontGlyphData {parsed glyph} {
    set loca [dict get $parsed loca]
    if {$glyph + 1 >= [llength $loca]} {
      return {}
    }
    set start [lindex $loca $glyph]
    set stop [lindex $loca [expr {$glyph + 1}]]
    if {$start >= $stop} {
      return {}
    }
    return [string range [::tclpdf::sfnt table $parsed glyf] $start \
        [expr {$stop - 1}]]
  }

  # The content of one glyph: the unit correction, then a q/Q bracket per
  # layer holding its colour, its alpha and its filled path.
  #
  # The operators are written here rather than through [path] and [style] for
  # the sentinel's sake: those two derive the painting operator from whether a
  # colour was named, and a layer that names none on purpose would end in "n"
  # - a path built and not painted. What they do carry over is the colour
  # itself, which goes through [ColourUsed] exactly as a rectangle's does, so
  # that a PDF/A document without a matching output intent refuses a colour
  # glyph as it refuses everything else.
  method ColorFontStream {record alias} {
    set body {}
    # The inverse of [Type3Stream]'s own correction. That one scales POINTS
    # back to glyph units, because a glyph script draws through the document
    # unit; these operators are font units already and the /FontMatrix scales
    # them. See the head of this file.
    set factor [::tclpdf::geometry toPoints 1 [my cget -unit]]
    if {$factor != 1.0} {
      set number [::tclpdf::pdfObj num $factor 6]
      append body "$number 0 0 $number 0 0 cm\n"
    }
    switch -- [dict get $record kind] {
      bitmap {
        # A picture per glyph, placed by colorFontBitmap.tcl. The unit
        # correction above is shared with the two drawing roads below and
        # nothing else is - a placement matrix is not a path.
        return $body[my ColorFontBitmapStream $record $alias]
      }
      version1 {
        # The paint graph, drawn by colorFontPaint.tcl. Everything below this
        # line is version 0's flat layer list, which shares the unit
        # correction above and nothing else.
        return $body[my ColorFontPaintStream $record $alias]
      }
      outline {
        # A glyph the table says nothing about: its own outline, filled in
        # the colour of the text. No colour operator at all, for the same
        # reason the 0xFFFF sentinel gets none, and nonzero winding for the
        # reason at the head of glyfPath.tcl.
        return $body[dict get $record operators]f\n
      }
    }
    set what "a colour glyph of font \"$alias\""
    foreach layer [dict get $record layers] {
      lassign $layer colour operators
      append body "q\n"
      if {$colour ne {}} {
        lassign $colour parsed alpha
        if {$alpha < 1} {
          append body "[::tclpdf::pdfObj name \
              [my GraphicsOpacity $alpha fill]] gs\n"
        }
        # [colr] hands the colour over ALREADY PARSED - {rgb {r g b}} - and
        # [ColourUsed] takes a colour the way a caller writes one, which is
        # not the same list: {rgb {0.2 0.4 0.6}} has one element after the
        # space name where "rgb 0.2 0.4 0.6" has three, and [color parse]
        # says so. So the components are spread back out for the one call
        # that records the space, and the operator is written from what comes
        # back - the same two lines every shape in this package writes.
        set spec [linsert [lindex $parsed 1] 0 [lindex $parsed 0]]
        append body [::tclpdf::color operator \
            [::tclpdf::color parse [my ColourUsed $spec $what]] fill] "\n"
      }
      # Nonzero, always: see the head of this file and of glyfPath.tcl.
      append body $operators "f\nQ\n"
    }
    return $body
  }
}

package provide tclpdf::colorFont 1.5
