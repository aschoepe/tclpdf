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
  # Start of frame, by compression method. Only the two sequential
  # Huffman-coded ones are embedded. DCTDecode itself (ISO 32000-1, 7.4.8)
  # covers baseline, extended sequential and - since PDF 1.3 - progressive
  # JPEG; what it does not cover is the lossless and the arithmetic-coded
  # processes, and those are refused with that reason. Progressive is
  # refused for a reason of this package's own: the data goes into the file
  # exactly as it is, nothing is decoded or re-encoded here, and only the
  # sequential processes are what this module embeds - so the caller is
  # told to re-save, not told the format forbids it. (Measured before
  # 2026-08-18 the message blamed the clause, which says the opposite.)
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
# adobe (1 when an APP14 Adobe segment is present), transform (its colour
# transform code, or -1 when absent), and what the file says about its
# resolution: jfif as {xDensity yDensity units} from APP0 and exif as
# {xResolution yResolution unit} from APP1, either of them empty when the
# segment is absent or says nothing. [resolution] below reads the two.
# Plus orientation, the Exif tag 274: REPORTED, never applied - see
# [ExifTags].
proc ::tclpdf::imageJpeg::parse {bytes} {
  variable sofBaseline
  variable sofExtended
  variable sofProgressive
  variable sofLossless
  variable notFrame

  set total [string length $bytes]
  if {$total < 4} {
    return -code error -errorcode [list TCLPDF IMAGE JPEG signature] \
        "tclpdf: not a JPEG file - too short"
  }
  binary scan $bytes cucu first second
  if {$first != 0xff || $second != 0xd8} {
    return -code error -errorcode [list TCLPDF IMAGE JPEG signature] \
        "tclpdf: not a JPEG file - it does not start with SOI"
  }

  set result [dict create adobe 0 transform -1 progressive 0 icc {} \
      jfif {} exif {} orientation 1]
  # An embedded ICC profile travels in APP2 segments marked "ICC_PROFILE"
  # (ICC.1, Annex B.4). A segment body holds at most 64 KB, so a profile is
  # split over several, each carrying its sequence number and the total
  # count - collected here by number and assembled after the walk, because
  # nothing says they arrive in order.
  set iccChunks {}
  set iccCount 0
  set offset 2
  while {$offset + 1 < $total} {
    binary scan [string range $bytes $offset [expr {$offset + 1}]] cucu pad marker
    if {$pad != 0xff} {
      return -code error -errorcode [list TCLPDF IMAGE JPEG DAMAGED marker] \
          "tclpdf: damaged JPEG - expected a marker at offset $offset"
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
      return -code error -errorcode [list TCLPDF IMAGE JPEG DAMAGED segment] \
          "tclpdf: damaged JPEG - segment header runs past the end"
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
        return -code error -errorcode [list TCLPDF IMAGE JPEG progressive] \
            "tclpdf: this is a progressive JPEG - tclpdf\
            passes JPEG data through as it is and embeds only baseline and\
            extended sequential files; re-save it as a baseline JPEG, or\
            use PNG"
      }
      if {$marker == $sofLossless || $marker >= 0xc9} {
        return -code error -errorcode [list TCLPDF IMAGE JPEG coding] \
            "tclpdf: this JPEG uses a coding method DCTDecode\
            does not cover (marker [format 0x%02x $marker]) - re-save it as a\
            baseline JPEG"
      }
      if {$marker != $sofBaseline && $marker != $sofExtended} {
        return -code error -errorcode [list TCLPDF IMAGE JPEG frame] \
            "tclpdf: unsupported JPEG frame type\
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
    # The JFIF APP0 segment (JFIF 1.02, Annex A): identifier, two version
    # bytes, the density unit and the two densities. Unit 0 means the pair
    # is a pixel aspect ratio and nothing else - kept as it stands, and
    # sorted out in [resolution].
    if {$marker == 0xe0 && [string range $body 0 4] eq "JFIF\0"
        && [string length $body] >= 12 && [dict get $result jfif] eq {}} {
      binary scan $body @7cuSuSu units xDensity yDensity
      dict set result jfif [list $xDensity $yDensity $units]
    }
    # The Exif APP1 segment carries a whole TIFF header, and the resolution
    # sits in three of its first directory's tags. It is read because it is
    # what most files that state a resolution at all state it in: measured
    # over 7452 JPEG files under ~/src and ~/Downloads on 2026-08-21, 2777
    # of them (37 %) name a resolution ONLY here, and 2236 of those name
    # something other than 72 dpi. APP1 also carries XMP, which begins with
    # a different identifier and is passed over by the same test.
    if {$marker == 0xe1 && [string range $body 0 5] eq "Exif\0\0"
        && [dict get $result exif] eq {}} {
      set tags [ExifTags [string range $body 6 end]]
      dict set result exif [ExifResolution $tags]
      if {[dict exists $tags orientation]} {
        dict set result orientation [dict get $tags orientation]
      }
    }
    if {$marker == 0xe2 && [string range $body 0 11] eq "ICC_PROFILE\0"
        && [string length $body] >= 14} {
      binary scan $body @12cucu seq count
      if {$iccCount == 0} {
        set iccCount $count
      }
      # Every segment repeats the count, and each number appears once.
      # A file that disagrees with itself is damaged - said with the
      # numbers rather than assembling a profile with a hole in it. A
      # repeated number is its own mistake and is called one: "disagree
      # (segment 1 of 2 after 2 announced)" points at figures that agree.
      if {[dict exists $iccChunks $seq]} {
        return -code error -errorcode [list TCLPDF IMAGE JPEG DAMAGED icc] \
            "tclpdf: damaged JPEG - ICC profile segment $seq\
            of $iccCount appears twice"
      }
      if {$count != $iccCount || $seq < 1 || $seq > $iccCount} {
        return -code error -errorcode [list TCLPDF IMAGE JPEG DAMAGED icc] \
            "tclpdf: damaged JPEG - the ICC profile segments\
            disagree (segment $seq of $count after $iccCount announced)"
      }
      dict set iccChunks $seq [string range $body 14 end]
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
    return -code error -errorcode [list TCLPDF IMAGE JPEG DAMAGED frame] \
        "tclpdf: damaged JPEG - no start-of-frame marker found"
  }
  if {$iccCount} {
    set profile {}
    for {set seq 1} {$seq <= $iccCount} {incr seq} {
      if {![dict exists $iccChunks $seq]} {
        return -code error -errorcode [list TCLPDF IMAGE JPEG DAMAGED icc] \
            "tclpdf: damaged JPEG - the ICC profile is split\
            over $iccCount APP2 segments and segment $seq is missing"
      }
      append profile [dict get $iccChunks $seq]
    }
    dict set result icc $profile
  }
  # A picture of no width or no height went out as /Width 0 (Table 89
  # wants a positive integer): a frame header saying so is a damaged file,
  # or one whose height is to be defined by a DNL marker after the first
  # scan - which this module does not read either.
  if {[dict get $result width] <= 0 || [dict get $result height] <= 0} {
    return -code error -errorcode [list TCLPDF IMAGE JPEG DAMAGED frame] \
        "tclpdf: damaged JPEG - the frame header says\
        [dict get $result width] x [dict get $result height] pixels"
  }
  if {[dict get $result components] ni {1 3 4}} {
    return -code error -errorcode [list TCLPDF IMAGE JPEG components] \
        "tclpdf: a JPEG with [dict get $result components]\
        components cannot be mapped to a PDF colour space"
  }
  # DCTDecode delivers 8 bits per component and nothing else (Table 89): a
  # 12-bit file - SOF1 with precision 12, which libjpeg writes readily -
  # would go out as /BitsPerComponent 12 over a filter that cannot produce
  # them, and every reader would refuse the picture. Refused here instead,
  # with the reason.
  if {[dict get $result bitsPerComponent] != 8} {
    return -code error -errorcode [list TCLPDF IMAGE JPEG depth] \
        "tclpdf: [dict get $result bitsPerComponent]-bit JPEG\
        is not supported by DCTDecode (ISO 32000-1 Table 89) - re-save it\
        with 8 bits per component"
  }
  return $result
}

# What the file says about how large its pixels are, as
#
#   source   JFIF, Exif, or none when the file says nothing
#   x y      dots per inch, or two empty strings when no ABSOLUTE measure
#            was given - which is not the same as 72
#   aspect   the width of one pixel divided by its height, 1.0 unless the
#            file says otherwise
#
# The empty x and y are the point of this shape. A file with no APP0 and no
# Exif does not claim to be 72 dpi; it claims nothing, and the 72 a placement
# then falls back on is this package's assumption, not the file's statement.
# JFIF units 0 and Exif unit 1 are that same distinction inside the segment:
# the densities are then a ratio between the axes and carry no measure. It
# matters here more than in a PNG, because the pair a file writes with unit 0
# is usually {1 1} - both sample JPEGs in examples/assets/images do - and
# reading that as "one dot per inch" would place a 640-pixel picture sixteen
# metres wide.
#
# WHICH of the two segments wins when both carry an absolute measure: Exif.
# Measured on 2026-08-21 over the 4586 JFIF-bearing files under ~/src and
# ~/Downloads, the two disagree in 77 of them, and ImageMagick's [identify]
# answers with the Exif figure in every disagreement looked at (JFIF 72 dpi
# against Exif 300 dpi is the recurring shape - an encoder's default left
# standing beside a figure somebody meant). A segment that gives only a
# ratio never displaces one that gives a measure.
proc ::tclpdf::imageJpeg::resolution {parsed} {
  set answer [dict create source none x {} y {} aspect 1.0]
  # JFIF first, Exif second, so that an absolute Exif measure lands last.
  foreach {source key inch centimetre} {JFIF jfif 1 2 Exif exif 2 3} {
    if {![dict exists $parsed $key] || [dict get $parsed $key] eq {}} {
      continue
    }
    lassign [dict get $parsed $key] xDensity yDensity unit
    if {$xDensity <= 0 || $yDensity <= 0} {
      continue
    }
    set candidate [dict create source $source x {} y {} \
        aspect [expr {double($yDensity) / $xDensity}]]
    if {$unit == $inch} {
      dict set candidate x [expr {double($xDensity)}]
      dict set candidate y [expr {double($yDensity)}]
    } elseif {$unit == $centimetre} {
      dict set candidate x [expr {$xDensity * 2.54}]
      dict set candidate y [expr {$yDensity * 2.54}]
    }
    if {[dict get $candidate x] ne {} || [dict get $answer source] eq "none"} {
      set answer $candidate
    }
  }
  return $answer
}

# XResolution, YResolution, ResolutionUnit and Orientation out of the TIFF
# header an Exif APP1 segment begins with (Exif 2.32, 4.6.4; TIFF 6.0,
# section 2). Only the first directory is walked and only four tags are read
# - none of the sub directories are entered, because none of the four is in
# them.
#
# Answers a dict with whichever of the keys x, y, unit and orientation the
# directory named, empty when the segment cannot be read at all. Empty rather
# than an error: this is metadata beside a picture that is perfectly
# embeddable, and a file that is wrong about its own metadata must not become
# a file that cannot be placed.
#
# ORIENTATION (tag 274) IS READ AND NOT OBEYED. Applying it would mean
# turning the samples, and this package decodes no pixels on the JPEG road at
# all - the compressed data passes into the file as it stands, which is the
# whole point of the DCTDecode path. What it must not do is stay silent about
# it, the way it did until 2026-08-26: [image info] now answers "orientation"
# for every picture, 1 meaning "the rows are as they are stored", and a
# caller who wants the turn asks for it with [transform]. TIFF refuses the
# same tag (imageTiff.tcl) because there the rows ARE re-assembled here and a
# wrong answer would be this package's own.
proc ::tclpdf::imageJpeg::ExifTags {tiff} {
  set total [string length $tiff]
  if {$total < 8} {
    return {}
  }
  # The byte order is written in the first two bytes and everything after
  # it - including the offsets - follows it.
  switch -- [string range $tiff 0 1] {
    II {set short su; set long iu}
    MM {set short Su; set long Iu}
    default {return {}}
  }
  binary scan $tiff "@2 $short $long" magic offset
  if {$magic != 42 || $offset + 2 > $total} {
    return {}
  }
  binary scan $tiff "@$offset $short" count
  set values {}
  for {set index 0} {$index < $count} {incr index} {
    set entry [expr {$offset + 2 + $index * 12}]
    if {$entry + 12 > $total} {
      break
    }
    binary scan $tiff "@$entry $short $short $long" tag type number
    # Decimal, and named - the same trap this file's header describes for
    # the marker walk: [binary scan] hands back the integer 282, and
    # "282 eq 0x011a" is false.
    switch -- $tag {
      282 - 283 {
        # RATIONAL: two 32-bit values, and never inline - eight bytes do
        # not fit in the four an entry holds, so the entry holds an offset.
        if {$type != 5 || $number < 1} {
          continue
        }
        binary scan $tiff "@[expr {$entry + 8}] $long" where
        if {$where + 8 > $total} {
          continue
        }
        binary scan $tiff "@$where $long $long" numerator denominator
        if {$denominator == 0} {
          continue
        }
        dict set values [expr {$tag == 282 ? "x" : "y"}] \
            [expr {double($numerator) / $denominator}]
      }
      274 - 296 {
        # SHORT, and short enough to sit in the entry itself.
        if {$type != 3} {
          continue
        }
        binary scan $tiff "@[expr {$entry + 8}] $short" number
        # Exif 2.32, 4.6.4: Orientation is 1..8, and anything else is a
        # file saying something nobody can act on. Passed over rather than
        # refused - the picture is embeddable either way, and [image info]
        # then answers the 1 that means "as stored".
        if {$tag == 274 && ($number < 1 || $number > 8)} {
          continue
        }
        dict set values [expr {$tag == 274 ? "orientation" : "unit"}] $number
      }
    }
  }
  return $values
}

# The three resolution tags out of that dict, in the shape [resolution]
# reads: {x y unit} with unit 1 (none), 2 (inch) or 3 (centimetre), or an
# empty string when the directory named no resolution at all.
proc ::tclpdf::imageJpeg::ExifResolution {values} {
  if {![dict exists $values x]} {
    return {}
  }
  set x [dict get $values x]
  # A file that names only one of the two axes is saying its pixels are
  # square, which is what the missing tag would have said as well.
  set y [expr {[dict exists $values y] ? [dict get $values y] : $x}]
  # The inch is the default the standard names for a missing ResolutionUnit.
  return [list $x $y [expr {[dict exists $values unit] ?
      [dict get $values unit] : 2}]]
}

# The colour space name for a component count.
proc ::tclpdf::imageJpeg::space {components} {
  switch -- $components {
    1 {return DeviceGray}
    3 {return DeviceRGB}
    4 {return DeviceCMYK}
  }
  return -code error -errorcode [list TCLPDF IMAGE JPEG components] \
      "tclpdf: no PDF colour space for $components components"
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

package provide tclpdf::imageJpeg 1.7