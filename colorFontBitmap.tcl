#
# tclpdf - PDF generation for Tcl
#
# colorFontBitmap - a bitmap colour glyph as a Type 3 glyph
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# The third road out of [colorFont], beside the flat layers of COLR version 0
# in colorFont.tcl and the paint graph of version 1 in colorFontPaint.tcl.
# Where those two DRAW - paths, gradients, clips - this one PLACES: an sbix
# glyph is a PNG file, and a PNG file goes into a PDF as an image XObject.
#
#   $doc colorFont emoji "/System/Library/Fonts/Apple Color Emoji.ttc" \
#       -chars "👨‍👩‍👧👍🏽🇩🇪"
#
# WHAT A GLYPH BECOMES:
#
#   q  w 0 0 h x y cm  /Im12 Do  Q
#
# and that is the whole of it. The four numbers are the em box in glyph units
# - see below - the name is the picture, and the q/Q keeps the matrix out of
# whatever the reader does next.
#
# THE NUMBERS. An sbix strike is drawn for a fixed number of PIXELS PER EM,
# and the record says where the picture's bottom left corner sits in those
# same pixels. So one pixel is unitsPerEm/ppem glyph units, and everything
# follows from that: a picture of w by h pixels is w and h times that wide and
# tall, and the origin offsets are scaled the same way. Measured on Apple
# Color Emoji: unitsPerEm 800, every strike square, every picture ppem by ppem
# pixels and every origin 0,0 - so a glyph is 800 by 800 units with its bottom
# edge ON THE BASELINE and its advance is 800, the whole em. That is not
# assumed anywhere below; it is what the arithmetic comes to for that face.
#
# THE PICTURE IS NOT SCALED AND NOT DECODED. It goes into the document as the
# PNG it is, through the same [image embed] a caller uses for a photograph -
# so the pass-through of imagePng.tcl carries it, and the alpha channel every
# emoji has becomes an /SMask exactly as it does for any other picture with
# transparency. Measured 2026-08-26: 61 glyphs of the 160 pixel strike, 713666
# bytes of PNG, 1.5 s to separate the alpha of all of them and 900 KB in the
# file.
#
# A MIRRORED PICTURE COSTS NO SECOND COPY. sbix has a record type "flip" whose
# data is another glyph's number, and whose picture is that glyph's drawn left
# to right - Apple uses it 108 times, for the runner and the walker facing the
# other way. Both glyphs then place the SAME image XObject and the mirrored
# one negates the horizontal scale of its matrix. What that saves is real:
# those 108 pictures are 20 KB each at the largest strike.
#
# WHY A PICTURE AND NOT AN OUTLINE. An sbix face has outlines - Apple Color
# Emoji's "glyf" holds 3844 of them - and they are EMPTY BOXES: 129 868 bytes
# of bounding rectangles with no contours in them, there so that a renderer
# ignorant of sbix still gets the right advance. Embedding such a face as a
# font program therefore gives a document that is valid, extractable and
# blank, which is the trap [font embed] refuses by name - TCLPDF FONT
# OUTLINES, whose message names the bitmap table where the face carries one.
# There is no TCLPDF FONT BITMAPS code and there never was; this comment
# invented one. This module is the road past the refusal.
#
# WHICH SIZE IS DRAWN is [sbix strike]'s decision and the reason stands there:
# the largest, because nothing here knows the point size the font will be set
# at. -strike names another.
#
# WHAT IS REFUSED BY NAME:
#
#   - a character whose glyph has no picture in the chosen strike, and no
#     colour anywhere else in the face: TCLPDF COLORFONT EMPTY, the same
#     refusal a COLR glyph with nothing but empty layers gets, and for the
#     same reason - a glyph that advances and draws nothing makes a document
#     that is valid and blank with nothing reporting it.
#   - a picture in "jpg " or "tiff" (TCLPDF SBIX FORMAT, in sbix.tcl).
#   - an image alias already taken, which is the one way a caller can collide
#     with the names built here.
#
# WHAT IS DELIBERATELY NOT DONE:
#
#   - CBDT/CBLC, the OTHER bitmap colour format - Android's, and Noto Color
#     Emoji shipped in it before it moved to COLR version 1. It is a different
#     table pair with its own index format and its own metrics, and no face on
#     this machine uses it. Naming it here is cheaper than a road nobody runs.
#   - the "draw outlines as well" flag of the sbix header (bit 1). It asks for
#     the glyph's own outline to be drawn UNDER the picture, and the faces
#     that set it carry empty outlines, so what it would add is nothing.
#   - choosing a strike per glyph. One font, one strike: a Type 3 font is one
#     /Widths array and one set of glyph streams, and mixing resolutions
#     inside it would make the same character come out sharp or soft
#     depending on which one it is.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::sfnt 1.0-
package require tclpdf::sbix 1.0-
# For [ImageWrite] and the picture's colour space: the picture is embedded
# with the public [image embed] and then written out at once, because a glyph
# stream names its XObject by the RESOURCE name and a picture has none until
# it has been written. [ImagePlace] does the same three lines for the same
# reason - see the comment there.
package require tclpdf::image 1.0-
package require tclpdf::document 1.0-
package require tclpdf::type3 1.3-

oo::define ::tclpdf::document::document {

  # Everything one bitmap glyph needs, read out of the face - the sister of
  # [ColorFontRead] and the same contract: it READS AND REFUSES and touches
  # nothing about the document, so that a call naming one character the face
  # has no picture for leaves no half-built font behind.
  #
  # The PNG is taken out of the file HERE rather than at drawing time, and
  # that is not tidiness: the face may be an open channel into a 192 MB file
  # (see the end of sfnt.tcl), and it is closed as soon as [colorFont]
  # returns. What the record carries has to be the bytes themselves.
  method ColorFontBitmapRead {parsed state strike common alias} {
    set glyph [dict get $common glyph]
    set picture [::tclpdf::sbix graphic $parsed $state $strike $glyph]
    if {$picture eq {}} {
      # NO PICTURE IS NOT THE SAME AS NOTHING, and this is the same rule the
      # COLR road follows one file over: a colour face carries ORDINARY
      # glyphs beside its pictures, and the answer for one of those is its
      # own outline, drawn in the colour of the text like a letter. Measured
      # on Apple Color Emoji: U+2640, the female sign, has no bitmap at any
      # of the nine strikes and a 43 point outline - it is a text character
      # in an emoji face, and refusing it would refuse the equation that has
      # it as a component. What IS refused is one step further on, and
      # [ColorFontPlain] refuses it: an empty outline as well, which would
      # put a blank glyph into the font with nothing reporting it.
      return [dict merge $common [dict create kind outline \
          operators [my ColorFontPlain $parsed $glyph \
              [dict get $common u] $alias]]]
    }
    return [dict merge $common [dict create kind bitmap picture $picture \
        ppem [lindex $strike 0]]]
  }

  # The content of one bitmap glyph: the placement matrix and the picture.
  method ColorFontBitmapStream {record alias} {
    set picture [dict get $record picture]
    set units [expr {double([dict get $record parsed unitsPerEm])
        / [dict get $record ppem]}]
    set width [expr {[dict get $picture width] * $units}]
    set height [expr {[dict get $picture height] * $units}]
    set x [expr {[dict get $picture originX] * $units}]
    set y [expr {[dict get $picture originY] * $units}]
    # LEFT TO RIGHT OR RIGHT TO LEFT. A mirrored picture is the same XObject
    # with a negative horizontal scale, and the translation then has to name
    # the RIGHT edge - a matrix of {-w 0 0 h x y} draws the picture off to the
    # left of where it belongs, which is the kind of mistake that shows only
    # on the 108 glyphs that use it.
    if {[dict get $picture mirror]} {
      set matrix [list [expr {-$width}] 0 0 $height \
          [expr {$x + $width}] $y]
    } else {
      set matrix [list $width 0 0 $height $x $y]
    }
    set resource [my ColorFontBitmapPicture $record $alias]
    my ColorFontBitmapCount $alias
    return "q\n[join [lmap number $matrix {
      ::tclpdf::pdfObj num $number 4
    }] { }] cm\n[::tclpdf::pdfObj name $resource] Do\nQ\n"
  }

  # The picture as an image XObject, embedded once per SOURCE glyph and named
  # by its resource.
  #
  # Named after the source and not after the character: a "flip" record draws
  # another glyph's picture, and two Type 3 glyphs sharing one XObject is the
  # whole saving that record type is for.
  method ColorFontBitmapPicture {record alias} {
    set picture [dict get $record picture]
    set name "$alias#sbix[dict get $picture source]"
    set made [my ColorFontBitmapMade $alias]
    if {[dict exists $made $name]} {
      return [dict get $made $name]
    }
    if {[dict exists [my state images] $name]} {
      # The one collision a caller can make: an image of their own already
      # carries the name this module builds for the picture. Refused rather
      # than reused - what would otherwise reach the page is their picture in
      # place of the glyph.
      return -code error -errorcode [list TCLPDF COLORFONT IMAGE $name] \
          "tclpdf: an image named \"$name\" is already embedded, and that is\
          the name the colour font \"$alias\" gives the picture of glyph\
          [dict get $picture source] - embed that one under another name"
    }
    my image embed $name -data [dict get $picture data]
    set image [dict get [my state images] $name]
    # [ImageWrite] registers the resource in the state itself, so the entry
    # has to be read back - the same three lines [ImagePlace] writes, and for
    # the same reason: a glyph stream names an XObject by its RESOURCE name,
    # and a picture has none until it has been written.
    my ImageWrite $name $image
    set image [dict get [my state images] $name]
    # A picture's colour space counts like a painted colour for the PDF/A
    # intent check, exactly as it does at a placement (ISO 19005-2, 6.2.4.3).
    # Recorded where the object is made and not per placement: a colour glyph
    # is placed by the text that sets it, and there is no one page to name.
    if {[dict exists $image space] && [dict get $image space] ne {}} {
      my ColourSpaceUsed [dict get $image space] \
          "a colour glyph of font \"$alias\""
    }
    set resource [dict get $image resource]
    my ColorFontBitmapRecord $alias pictures \
        [dict replace $made $name $resource]
    return $resource
  }

  # The pictures this font has already embedded, as a dict of image name to
  # resource name.
  #
  # KEPT HERE AND NOT IN THE IMAGE ENTRY: the shape of an image entry belongs
  # to image.tcl, and a key added to it from outside is the kind of thing that
  # gets discovered rather than read. The counts colour fonts keep already
  # live under the document's "colorFont" state, and this goes beside them.
  method ColorFontBitmapMade {alias} {
    set counts [my state colorFont]
    if {![dict exists $counts $alias pictures]} {
      return {}
    }
    return [dict get $counts $alias pictures]
  }

  # One key of a font's entry in the "colorFont" state, set without disturbing
  # the four counts colorFontPaint.tcl keeps there.
  method ColorFontBitmapRecord {alias key value} {
    set counts [my state colorFont]
    if {![dict exists $counts $alias]} {
      dict set counts $alias [dict create bands 0 clip 0 constant 0 mask 0]
    }
    dict set counts $alias $key $value
    my state colorFont $counts
    return
  }

  # HOW MANY GLYPHS OF A COLOUR FACE ARE PICTURES, counted per font and
  # reported by [font info] as "bitmaps" - the sister of the "masks" count
  # colorFontPaint.tcl keeps, and the one thing about a drawn colour font that
  # decides how it behaves under magnification: a path is sharp at every size
  # and a picture is not.
  method ColorFontBitmapCount {alias} {
    set counts [my state colorFont]
    set already 0
    if {[dict exists $counts $alias bitmaps]} {
      set already [dict get $counts $alias bitmaps]
    }
    my ColorFontBitmapRecord $alias bitmaps [expr {$already + 1}]
    return
  }
}

package provide tclpdf::colorFontBitmap 1.1
