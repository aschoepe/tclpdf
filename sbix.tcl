#
# tclpdf - PDF generation for Tcl
#
# sbix - the standard bitmap graphics table
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# A private sub-module behind colorFontBitmap.tcl, exactly where colr.tcl sits
# behind colorFontPaint.tcl: it knows the file format and nothing about PDF.
#
# THE THIRD KIND OF COLOUR FONT. COLR version 0 stacks outlines and paints
# each one in a palette colour; COLR version 1 draws a graph of gradients and
# clips; "sbix" carries a PICTURE per glyph - a PNG, one file per glyph and
# per size. Apple Color Emoji is the face that matters: 3844 glyphs, nine
# sizes and 191 MB of PNG, which is 99.5 % of the file.
#
# THE TABLE (Apple, "TrueType Reference Manual", sbix; ISO/IEC 14496-22, 5.7):
#
#   uint16 version         1
#   uint16 flags           bit 0 always set, bit 1 "draw outlines as well"
#   uint32 numStrikes
#   uint32 strikeOffsets[] from the start of the table
#
# and a STRIKE - one size of the whole face - is
#
#   uint16 ppem            the pixels per em this strike was drawn for
#   uint16 ppi             the resolution it was drawn at, which nothing reads
#   uint32 glyphDataOffsets[numGlyphs + 1]   from the start of the strike
#
# A glyph is EMPTY in a strike where the offset behind it does not lie behind
# its own - the same convention "loca" uses, and it is not a defect: a face
# has ordinary glyphs beside its pictures, and 136 of Apple Color Emoji's 3844
# are empty in every strike.
#
# THE RECORD of a glyph that has one:
#
#   int16 originOffsetX    where the left edge of the picture sits, in PIXELS
#   int16 originOffsetY    where its bottom edge sits, in pixels, both of them
#                          measured from the glyph origin
#   Tag   graphicType      "png ", "jpg ", "tiff", "dupe" or "flip"
#   ...   data
#
# WHAT THIS READS AND WHAT IT REFUSES. "png " is read; "jpg " and "tiff" are
# refused BY NAME, because they exist in the format and no face on this
# machine uses them - a refusal that says which format the face used is worth
# more than a road that has never been run. "dupe" and "flip" are not pictures
# at all: their data is a two byte glyph number, and the picture is that
# glyph's - unchanged for "dupe", MIRRORED left to right for "flip". Apple
# Color Emoji uses "flip" 108 times at its largest strike, for the runner and
# the walker facing the other way; it does not use "dupe" at all.
#
# THE PIXELS ARE NOT DECODED HERE and never are: a PNG goes into a PDF as a
# PNG (imagePng.tcl's pass-through, or its alpha path where it carries one),
# and this module hands the file over byte for byte. What it does read out of
# it is the width and height in IHDR, which is what the placement needs and
# what the sbix record does not state.
#
# READ BY RANGE. Every read goes through [sfnt slice], which reaches into the
# file rather than into a string - see the end of sfnt.tcl. That is what makes
# a 192 MB face cost a few kilobytes: a document setting sixty emoji reads
# sixty PNGs and the strike directory, and nothing else.
#

package require Tcl 8.6.11-
package require tclpdf::sfnt 1.0-

namespace eval ::tclpdf::sbix {
  namespace export {[a-z]*}
  namespace ensemble create

  # How far a "dupe" or "flip" chain may reach before it is called a cycle. A
  # reference names a glyph whose record may be a reference in turn, and the
  # format says nothing about where that ends.
  variable maximumChain 8
}

# Has this face bitmap colour glyphs?
proc ::tclpdf::sbix::has {font} {
  return [expr {[::tclpdf::sfnt extent $font sbix] >= 8}]
}

# The strikes of the face, smallest first: one {ppem ppi offset} per strike.
proc ::tclpdf::sbix::build {font} {
  set extent [::tclpdf::sfnt extent $font sbix]
  if {$extent < 8} {
    return -code error -errorcode {TCLPDF SBIX DAMAGED header} \
        "tclpdf: damaged font - the \"sbix\" table is $extent bytes long and\
        an sbix header is 8"
  }
  binary scan [::tclpdf::sfnt slice $font sbix 0 8] SuSuIu version flags count
  if {$version != 1} {
    return -code error -errorcode [list TCLPDF SBIX VERSION $version] \
        "tclpdf: the \"sbix\" table of this face is version $version, and the\
        format defines version 1 (Apple, TrueType Reference Manual, sbix)"
  }
  if {$count < 1} {
    return -code error -errorcode {TCLPDF SBIX DAMAGED header} \
        "tclpdf: damaged font - the \"sbix\" table announces $count strikes,\
        so the face has bitmap glyphs at no size at all"
  }
  set offsets [::tclpdf::sfnt slice $font sbix 8 [expr {$count * 4}]]
  if {[string length $offsets] < $count * 4} {
    return -code error -errorcode {TCLPDF SBIX DAMAGED header} \
        "tclpdf: damaged font - the \"sbix\" table announces $count strikes\
        and ends inside their offsets"
  }
  binary scan $offsets Iu$count positions
  set strikes {}
  foreach position $positions {
    if {$position + 4 > $extent} {
      return -code error -errorcode {TCLPDF SBIX DAMAGED strike} \
          "tclpdf: damaged font - a strike of the \"sbix\" table is declared\
          at $position and the table is only $extent bytes long"
    }
    binary scan [::tclpdf::sfnt slice $font sbix $position 4] SuSu ppem ppi
    if {$ppem < 1} {
      return -code error -errorcode {TCLPDF SBIX DAMAGED strike} \
          "tclpdf: damaged font - a strike of the \"sbix\" table is drawn for\
          $ppem pixels to the em, and a picture of no pixels is no picture"
    }
    lappend strikes [list $ppem $ppi $position]
  }
  # Sorted by ppem so that "the largest" and "the smallest" mean what they
  # say whatever order the file keeps them in. Apple's are already in order;
  # the format does not require it.
  set strikes [lsort -integer -index 0 $strikes]
  return [dict create strikes $strikes flags $flags \
      numGlyphs [dict get $font numGlyphs]]
}

# The ppem of every strike, smallest first - what a caller chooses between.
proc ::tclpdf::sbix::sizes {state} {
  return [lmap strike [dict get $state strikes] {lindex $strike 0}]
}

# The strike to draw from: the one with this ppem, or the LARGEST where none
# was named.
#
# THE LARGEST IS THE DEFAULT, and the reason is that nothing here knows the
# point size. A Type 3 font is built once and set at every size the document
# uses - 10 pt in a table cell and 36 pt in a heading - so a strike chosen for
# one of them is wrong for the other, and of the two ways to be wrong only one
# is visible: a picture drawn larger than its pixels goes soft, a picture
# drawn smaller is scaled down by the reader and looks right. What it costs is
# file size, and that is what -strike is for.
proc ::tclpdf::sbix::strike {state ppem} {
  set strikes [dict get $state strikes]
  if {$ppem eq {}} {
    return [lindex $strikes end]
  }
  foreach strike $strikes {
    if {[lindex $strike 0] == $ppem} {
      return $strike
    }
  }
  return -code error -errorcode [list TCLPDF SBIX STRIKE $ppem] \
      "tclpdf: -strike is the size of the bitmaps to draw from, in pixels to\
      the em, and this face carries [join [sizes $state] {, }] - not \"$ppem\""
}

# The picture of one glyph in one strike, or {} where it has none.
#
#   kind      png
#   data      the PNG file, byte for byte
#   width     its width in pixels, out of IHDR
#   height    its height
#   originX   where its left edge sits, in pixels from the glyph origin
#   originY   where its bottom edge sits
#   mirror    1 where the picture is another glyph's, drawn left to right
#   source    the glyph the picture actually came from
#
proc ::tclpdf::sbix::graphic {font state strike glyph} {
  variable maximumChain
  set mirror 0
  set source $glyph
  set seen {}
  for {set step 0} {$step <= $maximumChain} {incr step} {
    if {[dict exists $seen $source]} {
      return -code error -errorcode [list TCLPDF SBIX CYCLE $glyph] \
          "tclpdf: damaged font - the \"sbix\" picture of glyph $glyph names\
          glyph $source, which names its way back to one it has already been\
          through"
    }
    dict set seen $source 1
    set record [Record $font $state $strike $source]
    if {$record eq {}} {
      return {}
    }
    lassign $record originX originY type data
    switch -- $type {
      "png " {
        lassign [Header $data $source] width height
        return [dict create kind png data $data width $width height $height \
            originX $originX originY $originY mirror $mirror source $source]
      }
      dupe - flip {
        if {[binary scan $data Su next] != 1} {
          return -code error -errorcode [list TCLPDF SBIX DAMAGED $type] \
              "tclpdf: damaged font - the \"$type\" record of glyph $source\
              names another glyph in two bytes and carries\
              [string length $data]"
        }
        if {$type eq "flip"} {
          set mirror [expr {!$mirror}]
        }
        set source $next
      }
      default {
        return -code error -errorcode [list TCLPDF SBIX FORMAT $type] \
            "tclpdf: the \"sbix\" picture of glyph $source is a\
            \"[string trim $type]\" and tclpdf reads the PNG of an sbix face\
            - a picture in another format would have to be decoded to reach\
            the file, which is what a PNG never needs"
      }
    }
  }
  return -code error -errorcode [list TCLPDF SBIX CYCLE $glyph] \
      "tclpdf: damaged font - the \"sbix\" picture of glyph $glyph is reached\
      through more than $maximumChain references"
}

# The raw record of one glyph in one strike, or {} where it has none.
proc ::tclpdf::sbix::Record {font state strike glyph} {
  set numGlyphs [dict get $state numGlyphs]
  if {$glyph < 0 || $glyph >= $numGlyphs} {
    return {}
  }
  set base [lindex $strike 2]
  set offsets [::tclpdf::sfnt slice $font sbix \
      [expr {$base + 4 + $glyph * 4}] 8]
  if {[string length $offsets] < 8} {
    return -code error -errorcode {TCLPDF SBIX DAMAGED strike} \
        "tclpdf: damaged font - the [lindex $strike 0] pixel strike of the\
        \"sbix\" table ends inside the offsets of glyph $glyph"
  }
  binary scan $offsets IuIu from to
  # THE EMPTY GLYPH, and it is not an error: a colour face carries ordinary
  # glyphs beside its pictures - the space, the zero width joiner, the tag
  # characters a flag is spelled with - and none of them has a bitmap.
  if {$to <= $from || $to - $from < 9} {
    return {}
  }
  set record [::tclpdf::sfnt slice $font sbix [expr {$base + $from}] \
      [expr {$to - $from}]]
  if {[string length $record] < $to - $from} {
    return -code error -errorcode {TCLPDF SBIX DAMAGED record} \
        "tclpdf: damaged font - the \"sbix\" record of glyph $glyph is\
        declared as [expr {$to - $from}] bytes and the file ends inside it"
  }
  binary scan $record SSa4 originX originY type
  return [list $originX $originY $type [string range $record 8 end]]
}

# The width and height of a PNG, out of its IHDR chunk.
#
# Read here rather than left to imagePng.tcl, and the two do not overlap: that
# one reads a picture in order to WRITE it and answers everything a PDF image
# needs, this one answers the two numbers a PLACEMENT needs and answers them
# for a picture that has not been embedded yet. The size of a glyph's box is
# settled before any picture reaches the document, which is what lets a face
# be refused without leaving half a font behind.
proc ::tclpdf::sbix::Header {data glyph} {
  if {[string length $data] < 24
      || [string range $data 0 7] ne "\x89PNG\r\n\x1A\n"} {
    return -code error -errorcode [list TCLPDF SBIX DAMAGED png] \
        "tclpdf: damaged font - the \"sbix\" record of glyph $glyph says it\
        holds a PNG and does not begin with one"
  }
  binary scan $data @12a4IuIu tag width height
  if {$tag ne "IHDR" || $width < 1 || $height < 1} {
    return -code error -errorcode [list TCLPDF SBIX DAMAGED png] \
        "tclpdf: damaged font - the PNG of glyph $glyph has no IHDR chunk at\
        its head, or declares a size of ${width}x${height}"
  }
  return [list $width $height]
}

package provide tclpdf::sbix 1.0
