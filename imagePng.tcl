#
# tclpdf - PDF generation for Tcl
#
# imagePng - reading the structure of a PNG file
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# This module reads the chunk structure and decides which of two ways a file
# takes. Decoding pixels happens in imagePngAlpha.tcl, and only when it cannot
# be avoided.
#
#   pass-through   colour types 0, 2 and 3 (no alpha channel): the IDAT data
#                  goes into the PDF byte for byte as /FlateDecode with
#                  /Predictor 15. The reader does the un-filtering, which it
#                  has to be able to do anyway. Nothing is decompressed here.
#
#   decode         colour types 4 and 6 (with alpha): PDF has no image format
#                  carrying its own alpha, so the channel has to be separated
#                  out into an /SMask - and separating it means decompressing
#                  and un-filtering first.
#
# Measured, and the reason the split is worth having: un-filtering costs 4.3 s
# per megapixel in pure Tcl (the Paeth predictor is sequentially dependent and
# cannot be vectorised), while the pass-through way costs a file read. So it is
# taken only when the picture has an alpha channel that has to be separated
# out; everything else goes in untouched.
#
# This is a private sub-module behind the [image] facade. Nobody loads it
# directly.
#

package require Tcl 8.6.11-
package require tclpdf::pdfObj 1.0-
package require tclpdf::filter 1.0-

namespace eval ::tclpdf::imagePng {
  namespace export {[a-z]*}
  namespace ensemble create
  # The eight-byte signature (PNG 5.2). The high bit in the first byte and the
  # CR/LF pair exist so that a file mangled by a text-mode transfer is caught
  # immediately rather than half-way through decoding.
  variable signature "\x89PNG\r\n\x1a\n"
}

# Read a PNG and return its structure:
#
#   width height bitDepth colorType interlace   from IHDR
#   channels                                    samples per pixel
#   palette                                     PLTE bytes, or {}
#   transparency                                tRNS bytes, or {}
#   idat                                        all IDAT chunks, concatenated
#
# The IDAT data is NOT decompressed. For three of the five colour types it
# never has to be.
proc ::tclpdf::imagePng::parse {bytes} {
  variable signature

  if {[string range $bytes 0 7] ne $signature} {
    return -code error "tclpdf: not a PNG file - the signature does not match"
  }
  set total [string length $bytes]
  set offset 8
  set result [dict create palette {} transparency {} idat {}]
  set seenHeader 0

  while {$offset + 8 <= $total} {
    binary scan [string range $bytes $offset [expr {$offset + 7}]] Ia4 length type
    if {$length < 0 || $offset + 12 + $length > $total} {
      return -code error "tclpdf: damaged PNG - chunk \"$type\" runs past the\
          end of the file"
    }
    set body [string range $bytes [expr {$offset + 8}] \
        [expr {$offset + 8 + $length - 1}]]
    switch -- $type {
      IHDR {
        binary scan $body IIcucucucucu width height bitDepth colorType \
            compression filter interlace
        if {$compression != 0} {
          return -code error "tclpdf: PNG compression method $compression is\
              not defined by the format"
        }
        if {$filter != 0} {
          return -code error "tclpdf: PNG filter method $filter is not defined\
              by the format"
        }
        dict set result width $width
        dict set result height $height
        dict set result bitDepth $bitDepth
        dict set result colorType $colorType
        dict set result interlace $interlace
        dict set result channels [channels $colorType]
        set seenHeader 1
      }
      PLTE {dict set result palette $body}
      tRNS {dict set result transparency $body}
      IDAT {dict append result idat $body}
      IEND {break}
    }
    incr offset [expr {$length + 12}]
  }

  if {!$seenHeader} {
    return -code error "tclpdf: damaged PNG - no IHDR chunk"
  }
  if {[dict get $result idat] eq {}} {
    return -code error "tclpdf: damaged PNG - no image data"
  }
  if {[dict get $result interlace] != 0} {
    # Adam7 rearranges the picture into seven passes, so neither the
    # pass-through way (the reader would un-filter one interleaved block) nor
    # the plain row walk applies. Refused with a name rather than producing a
    # scrambled image.
    return -code error "tclpdf: this PNG is interlaced (Adam7), which tclpdf\
        does not read - re-save it without interlacing"
  }
  if {[dict get $result colorType] == 3 && [dict get $result palette] eq {}} {
    return -code error "tclpdf: damaged PNG - a palette image without a PLTE chunk"
  }
  return $result
}

# Samples per pixel, by colour type (PNG 6.1).
proc ::tclpdf::imagePng::channels {colorType} {
  switch -- $colorType {
    0 {return 1}
    2 {return 3}
    3 {return 1}
    4 {return 2}
    6 {return 4}
  }
  return -code error "tclpdf: PNG colour type $colorType is not defined by the format"
}

# Does this file carry a per-pixel alpha channel in its image data?
proc ::tclpdf::imagePng::hasAlpha {parsed} {
  return [expr {[dict get $parsed colorType] in {4 6}}]
}

# The PDF colour space for a parsed PNG, as PDF syntax. Palette images become
# /Indexed with the PLTE chunk as the lookup string.
proc ::tclpdf::imagePng::space {parsed} {
  switch -- [dict get $parsed colorType] {
    0 - 4 {return /DeviceGray}
    2 - 6 {return /DeviceRGB}
    3 {
      set palette [dict get $parsed palette]
      set last [expr {[string length $palette] / 3 - 1}]
      return "\[/Indexed /DeviceRGB $last [::tclpdf::pdfObj bytesStr $palette]\]"
    }
  }
  return -code error "tclpdf: PNG colour type [dict get $parsed colorType] is\
      not defined by the format"
}

# The /DecodeParms for the pass-through way. The reader is told to reverse
# exactly the filtering the encoder applied; 15 means "PNG optimum", which
# covers all five per-row filter types (Table 10).
proc ::tclpdf::imagePng::decodeParms {parsed} {
  set colors [expr {[dict get $parsed colorType] == 3 ? 1 :
      [dict get $parsed channels]}]
  return [::tclpdf::pdfObj dictionary [list \
      Predictor 15 \
      Colors $colors \
      BitsPerComponent [dict get $parsed bitDepth] \
      Columns [dict get $parsed width]]]
}

# How a palette image carries its transparency - and which of two very
# different ways the caller has to take.
#
# Returns "none", "colourKey" or "softMask":
#
#   none        no tRNS chunk, or every entry fully opaque
#   colourKey   every entry is either 0 or 255. A /Mask array naming the
#               fully transparent indices does the job, and the image data
#               stays a pass-through - nothing is decoded.
#   softMask    at least one entry is partially transparent. That needs a real
#               /SMask built from the index data, so the picture has to be
#               decoded after all.
#
# The distinction is worth making because the common case - a logo with one
# transparent background colour - lands on the cheap side.
proc ::tclpdf::imagePng::paletteTransparency {parsed} {
  if {[dict get $parsed colorType] != 3 || [dict get $parsed transparency] eq {}} {
    return none
  }
  binary scan [dict get $parsed transparency] cu* alphas
  set partial 0
  set transparent 0
  foreach alpha $alphas {
    if {$alpha == 0} {
      incr transparent
    } elseif {$alpha != 255} {
      incr partial
    }
  }
  if {$partial} {
    return softMask
  }
  if {$transparent} {
    return colourKey
  }
  return none
}

# Everything the PDF objects need, decided in one place: the image stream with
# its dictionary entries, and the soft mask when there is one.
#
# Returns a dict with "data" and "pairs", plus "maskData" and "maskPairs" when
# a soft mask is called for. Which of the three ways a file takes is decided
# here and nowhere else - the caller only creates objects.
proc ::tclpdf::imagePng::streams {parsed} {
  set pairs [list ColorSpace [space $parsed] \
      BitsPerComponent [dict get $parsed bitDepth]]

  if {[hasAlpha $parsed]} {
    # The expensive way: decompress, un-filter, split the channels. Both
    # halves are deflated afresh and carry no predictor, because they are
    # raw samples rather than PNG rows.
    package require tclpdf::imagePngAlpha
    set split [::tclpdf::imagePngAlpha separate $parsed]
    lappend pairs Filter /FlateDecode
    return [dict create \
        data [::tclpdf::filter encodeFlate [dict get $split color]] \
        pairs $pairs \
        maskData [::tclpdf::filter encodeFlate [dict get $split alpha]] \
        maskPairs [list ColorSpace /DeviceGray \
            BitsPerComponent [dict get $parsed bitDepth] Filter /FlateDecode]]
  }

  # The cheap way: the IDAT data goes in untouched and the reader un-filters.
  lappend pairs Filter /FlateDecode DecodeParms [decodeParms $parsed]
  set result [dict create data [dict get $parsed idat] pairs $pairs]

  switch -- [paletteTransparency $parsed] {
    colourKey {
      dict set result pairs [linsert $pairs end \
          Mask [::tclpdf::pdfObj arr [colourKey $parsed]]]
    }
    softMask {
      # A partially transparent palette entry cannot be expressed as a colour
      # key, so the index data has to be decoded after all - but only to build
      # the mask. The picture itself still goes in untouched.
      package require tclpdf::imagePngAlpha
      dict set result maskData [::tclpdf::filter encodeFlate \
          [::tclpdf::imagePngAlpha paletteMask $parsed]]
      dict set result maskPairs [list ColorSpace /DeviceGray \
          BitsPerComponent 8 Filter /FlateDecode]
    }
  }
  return $result
}

# The /Mask array for a colour-key palette: one {min max} pair per fully
# transparent index. Adjacent indices are merged into a single range, which is
# what the array wants anyway (8.9.6.4).
proc ::tclpdf::imagePng::colourKey {parsed} {
  binary scan [dict get $parsed transparency] cu* alphas
  set ranges {}
  set index 0
  set start -1
  foreach alpha $alphas {
    if {$alpha == 0} {
      if {$start < 0} {
        set start $index
      }
    } elseif {$start >= 0} {
      lappend ranges $start [expr {$index - 1}]
      set start -1
    }
    incr index
  }
  if {$start >= 0} {
    lappend ranges $start [expr {$index - 1}]
  }
  return $ranges
}

package provide tclpdf::imagePng 1.0
