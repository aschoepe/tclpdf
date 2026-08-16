#
# tclpdf - PDF generation for Tcl
#
# imageJpeg - reading just enough of a JPEG to embed it unchanged (7.4.8)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# A JPEG goes into a PDF as /DCTDecode with its entropy-coded data untouched.
# Nothing is decoded here and nothing needs to be: the only facts the PDF
# dictionary asks for - width, height, components and bit depth - sit in the
# SOF marker segment, a few hundred bytes into the file.
#
# This is a private sub-module behind the [image] facade. Nobody loads it
# directly.
#
# The marker walk has one trap that has bitten this project before, in
# pdfObj::name: comparing a scanned BYTE against a list of hex STRINGS. Tcl
# scans 0xC4 as the integer 196, and "196 in {0xc4}" is false, so the DHT
# segment would be read as a start-of-frame and the image would come out with
# the dimensions of a Huffman table. Every comparison here is therefore
# decimal, and the SOF constants are named.
#

package require Tcl 8.6.11-

namespace eval ::tclpdf::imageJpeg {
  namespace export {[a-z]*}
  namespace ensemble create
  # Start of frame, by compression method. Only the two Huffman-coded ones are
  # usable: ISO 32000-1 7.4.8 limits DCTDecode to baseline and extended
  # sequential, so progressive and arithmetic-coded files have to be refused
  # rather than written into a document no reader will show.
  variable sofBaseline 0xc0
  variable sofExtended 0xc1
  variable sofProgressive 0xc2
  variable sofLossless 0xc3
  # Markers in the 0xC0..0xCF range that are NOT frame headers.
  variable notFrame {0xc4 0xc8 0xcc}
}

# Read a JPEG and report what the PDF dictionary needs.
#
# Returns a dict: width, height, components, bitsPerComponent, progressive,
# adobe (1 when an APP14 Adobe segment is present) and transform (its colour
# transform code, or -1 when absent).
proc ::tclpdf::imageJpeg::parse {bytes} {
  variable sofBaseline
  variable sofExtended
  variable sofProgressive
  variable sofLossless
  variable notFrame

  set total [string length $bytes]
  if {$total < 4} {
    return -code error "tclpdf: not a JPEG file - too short"
  }
  binary scan $bytes cucu first second
  if {$first != 0xff || $second != 0xd8} {
    return -code error "tclpdf: not a JPEG file - it does not start with SOI"
  }

  set result [dict create adobe 0 transform -1 progressive 0]
  set offset 2
  while {$offset + 1 < $total} {
    binary scan [string range $bytes $offset [expr {$offset + 1}]] cucu pad marker
    if {$pad != 0xff} {
      return -code error "tclpdf: damaged JPEG - expected a marker at offset $offset"
    }
    # Padding: a stream may carry any number of 0xFF bytes before the marker.
    if {$marker == 0xff} {
      incr offset
      continue
    }
    # Standalone markers carry no length field.
    if {$marker == 0xd8 || $marker == 0x01 || ($marker >= 0xd0 && $marker <= 0xd7)} {
      incr offset 2
      continue
    }
    if {$marker == 0xd9} {
      break
    }
    if {$offset + 3 >= $total} {
      return -code error "tclpdf: damaged JPEG - segment header runs past the end"
    }
    binary scan [string range $bytes [expr {$offset + 2}] [expr {$offset + 3}]] Su length
    set body [string range $bytes [expr {$offset + 4}] [expr {$offset + 2 + $length - 1}]]

    if {$marker == 0xda} {
      # Start of scan - the entropy data begins, and there is nothing after it
      # that we need. Scanning on would mean parsing compressed data.
      break
    }
    if {$marker >= 0xc0 && $marker <= 0xcf &&
        $marker != 0xc4 && $marker != 0xc8 && $marker != 0xcc} {
      if {$marker == $sofProgressive} {
        return -code error "tclpdf: this is a progressive JPEG, which\
            DCTDecode does not cover (ISO 32000-1, 7.4.8) - re-save it as a\
            baseline JPEG, or use PNG"
      }
      if {$marker == $sofLossless || $marker >= 0xc9} {
        return -code error "tclpdf: this JPEG uses a coding method DCTDecode\
            does not cover (marker [format 0x%02x $marker]) - re-save it as a\
            baseline JPEG"
      }
      if {$marker != $sofBaseline && $marker != $sofExtended} {
        return -code error "tclpdf: unsupported JPEG frame type\
            [format 0x%02x $marker]"
      }
      binary scan $body cuSuSucu precision height width components
      dict set result width $width
      dict set result height $height
      dict set result components $components
      dict set result bitsPerComponent $precision
      # Keep walking: the APP14 segment may follow the frame header, and its
      # transform flag decides whether a four-component file is inverted.
    }
    if {$marker == 0xee && [string range $body 0 4] eq "Adobe"} {
      dict set result adobe 1
      if {[string length $body] >= 12} {
        binary scan [string index $body 11] cu transform
        dict set result transform $transform
      }
    }
    incr offset [expr {$length + 2}]
  }

  if {![dict exists $result width]} {
    return -code error "tclpdf: damaged JPEG - no start-of-frame marker found"
  }
  if {[dict get $result components] ni {1 3 4}} {
    return -code error "tclpdf: a JPEG with [dict get $result components]\
        components cannot be mapped to a PDF colour space"
  }
  # DCTDecode delivers 8 bits per component and nothing else (Table 89): a
  # 12-bit file - SOF1 with precision 12, which libjpeg writes readily -
  # would go out as /BitsPerComponent 12 over a filter that cannot produce
  # them, and every reader would refuse the picture. Refused here instead,
  # with the reason.
  if {[dict get $result bitsPerComponent] != 8} {
    return -code error "tclpdf: [dict get $result bitsPerComponent]-bit JPEG\
        is not supported by DCTDecode (ISO 32000-1 Table 89) - re-save it\
        with 8 bits per component"
  }
  return $result
}

# The colour space name for a component count.
proc ::tclpdf::imageJpeg::space {components} {
  switch -- $components {
    1 {return DeviceGray}
    3 {return DeviceRGB}
    4 {return DeviceCMYK}
  }
  return -code error "tclpdf: no PDF colour space for $components components"
}

# Does the image need /Decode [1 0 1 0 1 0 1 0]?
#
# Adobe writes CMYK JPEGs with inverted values, and marks them with an APP14
# segment. Without the /Decode array such a file comes out looking like a
# photographic negative - a defect no validator reports, because the file is
# structurally perfect.
proc ::tclpdf::imageJpeg::inverted {parsed} {
  return [expr {[dict get $parsed components] == 4 && [dict get $parsed adobe]}]
}

package provide tclpdf::imageJpeg 1.0
