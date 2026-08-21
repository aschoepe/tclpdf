#
# tclpdf - PDF generation for Tcl
#
# colorFont - a COLR version 0 colour font as a Type 3 font
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
#   package require tclpdf::colorFont
#   $doc colorFont signs signs.ttf -chars "⚠✅"
#   $doc font -family signs -size 14
#   $doc text "⚠ mind the step"
#
# THE JOINT, and nothing else. Three modules make a colour font a document,
# and this is the third: colr.tcl reads which layers a base glyph has and what
# colour each of them names, glyfPath.tcl turns one layer's outline into path
# operators, and this file puts the two together and hands the result to
# type3.tcl. It reads no table, decodes no outline and writes no PDF object -
# every one of those exists once, next door.
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
#     refuses on top of that - version 1, an empty table, a truncated one -
#     keeps its own TCLPDF COLR codes and is passed through unchanged.
#   - a character the face has no glyph for, and a character whose glyph is
#     not a base glyph. The second is the interesting one: most glyphs of a
#     colour font are layers or plain outlines, and asking for one of those
#     would produce a blank glyph rather than an error.
#   - a layer that is a COMPOSITE glyph. [glyfPath] refuses those by name,
#     because assembling components is glyfOutline's subject and a second
#     walker would be the same logic twice. Whether that matters was measured
#     rather than assumed: of Twemoji Mozilla's 33179 layer glyphs, 33179 are
#     simple and NONE is a composite - the layers of a colour glyph are drawn
#     shapes, not letters with accents. If a face ever needs it, the way in is
#     a public "points with contour ends, through composites" in glyfOutline,
#     not a resolver here.
#   - a base glyph whose layers all draw nothing. That is the blank-page trap
#     of [font embed] one level down, and it is refused for the same reason:
#     the document would be valid, extractable and empty.
#   - more than 255 characters. A Type 3 font is addressed by single bytes and
#     holds at most 255 glyphs (9.6.5.3, and [Type3Code]); the limit is
#     checked before the font is defined, so that the 256th character is a
#     refusal and not a silent truncation.
#
# WHAT IS DELIBERATELY NOT DONE HERE:
#
#   - COLR version 1. A different format - a paint graph per base glyph with
#     gradients, transforms and composition - and a piece of its own.
#   - the ZWJ sequences of an emoji face. A family emoji is one base glyph
#     reached through a GSUB ligature, and [gsubApply] reads the lookup type
#     it needs; what is missing is the feature wiring, not this module.
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
package require tclpdf::sfnt 1.0-
package require tclpdf::colr 1.0-
package require tclpdf::glyfOutline 1.0-
package require tclpdf::glyfPath 1.0-
package require tclpdf::document 1.0-
package require tclpdf::type3 1.0-

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
      return -code error "tclpdf: colorFont needs a name for the font"
    }
    set alias [lindex $args 0]
    set args [lrange $args 1 end]
    set path {}
    if {[llength $args] % 2} {
      set path [lindex $args 0]
      set args [lrange $args 1 end]
    }
    set options [::tclpdf::option parse {data {} chars {} palette 0} $args \
        "colorFont"]
    if {$path ne {}} {
      set bytes [::tclpdf::io read $path]
    } elseif {[dict get $options data] ne {}} {
      set bytes [dict get $options data]
    } else {
      return -code error "tclpdf: colorFont needs a file name or -data"
    }
    set chars [my ColorFontChars [dict get $options chars]]
    set parsed [::tclpdf::sfnt parse $bytes]
    if {![::tclpdf::colr has $parsed]} {
      return -code error -errorcode [list TCLPDF COLORFONT TABLES $alias] \
          "tclpdf: this face has no \"COLR\" and \"CPAL\" tables and therefore\
          no colour glyphs - it is an ordinary face and goes into the document\
          with \[font embed\]"
    }
    # Anything colr refuses on top of that - version 1, an empty table, a
    # truncated one - comes back with its own TCLPDF COLR code and is not
    # dressed up here: a caller trapping TCLPDF COLR gets the same answer
    # whether it read the tables itself or through this.
    set state [::tclpdf::colr build $parsed]
    set palette [my ColorFontPalette $state [dict get $options palette]]

    # PASS ONE reads and refuses; nothing about the document is touched. So a
    # call that names one character the face has not got leaves no half-built
    # font behind - not a family that exists with no glyphs in it, and not an
    # ExtGState for a layer that never reached a stream.
    set built {}
    foreach char $chars {
      lappend built [my ColorFontRead $parsed $state $palette $char $alias]
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
    my font define $alias -matrix [list $scale 0 0 $scale 0 0] -ascent $ascent
    foreach record $built {
      my font glyph $alias [dict get $record char] \
          -width [dict get $record width] \
          -script [list my content [my ColorFontStream $record $alias]]
    }
    return $alias
  }

  # The characters to build glyphs for, as a list of one-character strings.
  #
  # Counted in CODE POINTS: [split $s {}] hands a surrogate pair back as one
  # element under Tcl 8.6 as well as under 9, which is what makes a symbol
  # beyond the BMP reachable at all (the same reason [font glyph] counts that
  # way - measured 2026-08-21, [string length] counts the pair as two).
  #
  # A character named twice is built once. That is not a truncation: what
  # comes out is exactly the font that was asked for, and the alternative -
  # letting [font glyph] refuse the repeat - would turn a harmless list into
  # an error.
  method ColorFontChars {chars} {
    if {$chars eq {}} {
      return -code error "tclpdf: colorFont needs -chars, the characters to\
          build colour glyphs for - a Type 3 font holds at most\
          $::tclpdf::colorFont::maximum of them, so there is no \"all\""
    }
    set seen {}
    set result {}
    foreach char [split $chars {}] {
      if {[dict exists $seen $char]} {
        continue
      }
      dict set seen $char 1
      lappend result $char
    }
    if {[llength $result] > $::tclpdf::colorFont::maximum} {
      return -code error \
          -errorcode [list TCLPDF COLORFONT LIMIT [llength $result]] \
          "tclpdf: -chars names [llength $result] characters and a Type 3\
          font is addressed by single bytes, so it holds at most\
          $::tclpdf::colorFont::maximum glyphs (ISO 32000-2, 9.6.5.3) - build\
          a second font for the rest"
    }
    return $result
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

  # Everything one character needs, read out of the face: the base glyph, its
  # advance, and its layers bottom first as {colour alpha operators}.
  #
  # The colour is the empty string for the 0xFFFF sentinel and the alpha is
  # then absent as well - a layer that takes the text colour takes its alpha
  # with it.
  method ColorFontRead {parsed state palette char alias} {
    set point [scan $char %c]
    set u U+[format %04X $point]
    set cmap [dict get $parsed cmap]
    if {![dict exists $cmap $point]} {
      return -code error -errorcode [list TCLPDF COLORFONT CHAR $u $alias] \
          "tclpdf: the face has no glyph for character $u, so there is no\
          colour glyph to draw for it"
    }
    set glyph [dict get $cmap $point]
    set layers [::tclpdf::colr layers $state $glyph]
    if {![llength $layers]} {
      return -code error \
          -errorcode [list TCLPDF COLORFONT BASE $u $glyph $alias] \
          "tclpdf: character $u is glyph $glyph of the face and that glyph is\
          not a colour base glyph - it has no entry in the \"COLR\" table.\
          Most glyphs of a colour font are layers or plain outlines; set this\
          one with an embedded face instead"
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
            and tclpdf assembles those only when a face is embedded. Measured\
            over the 33179 layers of Twemoji Mozilla, none is a composite;\
            a face that needs it cannot be drawn as a colour font here"
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
    return [dict create char $char glyph $glyph \
        width [::tclpdf::sfnt advance $parsed $glyph] layers $drawn]
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

package provide tclpdf::colorFont 1.0
