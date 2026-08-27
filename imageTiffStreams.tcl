#
# tclpdf - PDF generation for Tcl
#
# imageTiffStreams - the strips of a TIFF as the streams of PDF images
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Description in, stream bytes out. imageTiff.tcl says what a file holds and
# where every strip sits; this module turns those strips into what an image
# XObject carries - the bytes, the /Filter that reads them and the
# /DecodeParms that filter needs. Placing the result on a page is the caller's
# business and happens in image.tcl.
#
# THE USUAL ANSWER IS THE FILE'S OWN BYTES. Measured over 194 TIFF files, all
# six compressions that occur have a PDF filter that undoes them - Deflate is
# /FlateDecode, PackBits is /RunLengthDecode, CCITT Group 3 and 4 are
# /CCITTFaxDecode, TIFF 6.0 Technote 2 JPEG is /DCTDecode - so nothing is
# decoded to write it out again. That includes Group 4, which would have been
# the most expensive decoder in the package by far (300 to 400 lines of T.4
# code tables plus reference lines) and is the one that turns out to be free:
# passed straight through, the white fraction of a rendered fax comes out
# 0.876 against a reference of 0.876.
#
# Three things are NOT the file's own bytes, and each one is a measurement:
#
#   LZW           unpacked, always, and written out again as /FlateDecode.
#                 PDF/A forbids /LZWDecode outright (ISO 19005-3, 6.1.7.2 -
#                 the clause veraPDF names when it rejects such a stream),
#                 and the picture's stream is built when the picture is first
#                 placed while [$doc pdfa] may be declared afterwards - so a
#                 stream that was passed through cannot be repaired later.
#                 The price is small and was measured: decoding costs 0.35 to
#                 0.43 s per megapixel, and the Flate that replaces it is
#                 SMALLER than the LZW it replaces - 0.924 of it over four
#                 real files, 7.4 MB against 8.0 MB. Unpacking also makes the
#                 picture stateless, so its strips become one stream instead
#                 of a stack of them.
#
#   uncompressed  deflated. The bytes reach the PDF unchanged in content,
#                 but 71 of the 194 measured files are uncompressed and they
#                 are the big ones: 320 x 240 in RGB is 230 400 bytes raw
#                 against 7 500 deflated. zlib does that in C.
#
#   FillOrder 2   the bits in every byte turned round. PDF has no such
#                 parameter for /CCITTFaxDecode, and the raw stream is not
#                 merely upside down but unreadable: poppler stops with
#                 "CCITTFax row is wrong length (1729)". After the reversal
#                 the same stream decodes without complaint, checked against
#                 a FillOrder 1 file that must not be touched. One of the 194
#                 files has it, and it is a fax.
#
# The polarity of a fax comes from imageTiff as "blackIs1" and is written out
# as it stands. It is the reverse of what the photometric name suggests, it
# is measured, and turning it round again produces the exact negative of the
# picture - which qpdf and veraPDF both call a flawless document. See the
# comment above [::tclpdf::imageTiff::Ccitt] for the reasoning; there is
# nothing to decide here.
#
# WHERE THE LINE RUNS, AND WHY SOME PICTURES BECOME SEVERAL IMAGES. Every
# stateful compression restarts in every strip: measured on a 50-strip LZW
# file, the concatenated stream decodes exactly to line 50 - RowsPerStrip -
# and no further. So the strips of such a file cannot be concatenated, and
# each one becomes an image of its own for the caller to stack. Uncompressed
# and PackBits carry no state and are concatenated into one stream (15 strips
# gave exactly 320 x 240 x 3 = 230 400 bytes), and unpacked LZW is stateless
# by then and joins them.
#
# The predictor travels with the stream rather than being undone, AT EIGHT
# BITS AND BELOW: /Predictor 2 in /DecodeParms IS TIFF Predictor 2 (ISO
# 32000-2, Table 10 - the PNG family is 10 to 15), and 108 of the 194 files
# use it. Rendered through poppler the passed-through predictor comes out pixel
# for pixel identical to what libtiff makes of the same file. It is undone here
# in two cases, both of which need the decoded bytes in hand: a 16-bit
# little-endian file, whose samples PDF reads the wrong way round, and ANY
# 16-bit Predictor-2 file, whose per-component difference no reader undoes
# correctly at that depth - poppler and CoreGraphics render a passed-through
# 16-bit /Predictor 2 as coloured noise (RMSE 0.37 against 0.02 once resolved),
# the same failure the 16-bit colour key is decoded to avoid (doc/tclpdf.md).
# The difference is resolved in the file's own byte order and the samples then
# travel plain.
#
# Predictor 2 alongside no compression or PackBits is refused: PDF undoes a
# predictor only for Flate and LZW data, and neither an uncompressed strip nor
# a RunLengthDecode one has anywhere to carry it.
#
# 16-BIT LITTLE-ENDIAN. PDF reads a 16-bit sample high byte first (8.9.5.2);
# a TIFF says in its header which order it uses, and 5 of the 194 files are
# 16-bit and little-endian. Their samples are swapped here, which means the
# data have to be in hand: free for an uncompressed file, free for LZW (which
# is unpacked anyway), cheap for Deflate (zlib in C both ways) - and refused
# for PackBits, whose only decoder would be a decoder written for this one
# case that no measured file needs.
#
# JPEG-IN-TIFF IS NOT A JPEG FILE. Measured: fifteen separate JPEG streams,
# one per strip, each with its own SOI and its own SOF0 over sixteen rows,
# and one JPEGTables block holding the quantisation and Huffman tables they
# all share. A strip alone has no tables and decodes to nothing; the tables
# alone have no picture. They are put together here - and with an APP14 Adobe
# segment in front, without which the picture comes out green and magenta,
# because a three-component JPEG whose components are numbered 0, 1, 2 rather
# than 1, 2, 3 leaves every decoder to guess whether it is looking at RGB or
# at YCbCr. Fourteen bytes say which.
#
# This is a private sub-module behind the [image] facade. Nobody loads it
# directly.
#
# Failures carry an -errorcode beginning {TCLPDF TIFF}, the same contract
# imageTiff.tcl states: DAMAGED for a file whose strips do not hold what the
# tags promise, FILLORDER and BYTEORDER for the two layouts that would need a
# decoder this package does not have, and JPEG for a strip that is not one.
# The code is the contract, the message text is not.
#

package require Tcl 8.6.11-
package require tclpdf::pdfObj 1.0-
package require tclpdf::filter 1.0-
package require tclpdf::imageTiff 1.0-

namespace eval ::tclpdf::imageTiffStreams {
  namespace export {[a-z]*}
  namespace ensemble create

  # How much is turned round or swapped at a time. Bit reversal goes through
  # a string of eight characters per byte, so a whole 50 MB strip - the
  # largest in the measured corpus - would build a 400 MB intermediate.
  variable chunk 1048576
}

# --- the one thing this module answers -------------------------------------

# The streams of a parsed TIFF. Returns a dict:
#
#   filter        the PDF filter every part uses, without the slash:
#                 FlateDecode, DCTDecode, CCITTFaxDecode or RunLengthDecode
#   passThrough   1 when the strip bytes reach the PDF as they stand in the
#                 file, 0 when they were unpacked, packed, wrapped or turned
#                 round on the way
#   stacked       1 when there is more than one part, so the caller has to
#                 place them one above the other
#   parts         a list of dicts, one per image XObject to write:
#                   data    the bytes of the stream
#                   pairs   the entries that belong in ITS dictionary:
#                           Filter, DecodeParms where the filter takes any,
#                           and Decode where the samples are inverted
#                   rows    how many image rows this part holds - the /Height
#                           of that XObject
#                   row     the first image row it holds, counted from the
#                           top, so the caller knows where to put it
#
# Width, ColorSpace and BitsPerComponent are the caller's: they are the same
# for every part and they come out of the description, not out of the bytes.
# How many image XObjects this picture becomes - answered from the TAGS
# alone, without reading a single strip.
#
# The same answer [streams] arrives at, and this is where the rule lives: a
# compression whose coder restarts in every strip becomes one image per
# strip, and one that carries no state across strips is joined into a single
# stream. The exception is the Deflate file that has to be taken apart
# anyway ([Unpacked]) - it comes back joined too.
#
# It exists because the caller has to know BEFORE anything is written. A
# stack cannot be another picture's mask and cannot exceed the stacking
# limit, and both refusals used to be made after every strip of the picture
# had been decoded - and, when the picture was a mask, after the carrier had
# already put its ICC profile into the file. Asked here they cost a dict
# lookup.
proc ::tclpdf::imageTiffStreams::partCount {parsed} {
  if {[dict get $parsed stripCount] < 2} {
    return 1
  }
  switch -- [dict get $parsed compressionName] {
    deflate {
      return [expr {[Unpacked $parsed] ? 1 : [dict get $parsed stripCount]}]
    }
    jpeg - ccittRle - ccittG3 - ccittG4 {
      return [dict get $parsed stripCount]
    }
  }
  return 1
}

proc ::tclpdf::imageTiffStreams::streams {bytes parsed} {
  switch -- [dict get $parsed compressionName] {
    none {return [Raw $bytes $parsed]}
    packBits {return [PackBits $bytes $parsed]}
    lzw {return [Lzw $bytes $parsed]}
    deflate {return [Deflate $bytes $parsed]}
    jpeg {return [Jpeg $bytes $parsed]}
    ccittRle - ccittG3 - ccittG4 {return [Ccitt $bytes $parsed]}
  }
  # Not reachable through [::tclpdf::imageTiff parse], which refuses every
  # other compression by number before a caller ever gets here.
  return -code error -errorcode [list TCLPDF TIFF COMPRESSION \
      [dict get $parsed compression]] \
      "tclpdf: no PDF filter reads TIFF compression\
      [dict get $parsed compression]"
}

# --- one way per compression -----------------------------------------------

# Uncompressed: the strips are the picture, row by row, and they carry no
# state - so they are joined into one stream. Deflated on the way out, see
# the file header.
proc ::tclpdf::imageTiffStreams::Raw {bytes parsed} {
  NoPredictor $parsed
  set data [Join $bytes $parsed]
  if {[dict get $parsed fillOrder] == 2} {
    set data [Reverse $data]
  }
  set data [Fit $data $parsed]
  if {[Swapped $parsed]} {
    set data [Swap $data]
  }
  return [One $parsed FlateDecode [::tclpdf::filter encodeFlate $data] {} 0]
}

# PackBits is PDF's /RunLengthDecode: the same byte-oriented run coding under
# two names (TIFF 6.0, section 9, against ISO 32000-2, 7.4.5). A control byte
# below 128 announces that many literal bytes plus one, above 128 a run of
# 257 minus itself - identical on both sides.
#
# THE ONE DIFFERENCE IS THE BYTE 128, and it is the reason the data are
# walked rather than copied: TIFF calls it a no-op and skips it, PDF calls it
# EOD and stops there. A file with one in the middle of a strip would lose
# everything after it. The walk drops them, checks that the runs stay inside
# the strip - a cheap validation the format otherwise has nowhere to get -
# and appends the EOD that TIFF does not write and PDF wants.
#
# Stateless, so the strips are joined into one stream. Measured on the file
# in the corpus and on a fixture: not one no-op byte in either, so the walk
# normally copies the strip byte for byte and only proves that it may.
proc ::tclpdf::imageTiffStreams::PackBits {bytes parsed} {
  Reachable $parsed
  NoPredictor $parsed
  set data {}
  # What the runs WOULD decode to, counted while they are walked. The bytes
  # themselves stay coded - this is the one way to hold a PackBits file to
  # its own tags without unpacking it, and [Fit] cannot be used because it
  # wants the samples in hand.
  set decoded 0
  for {set index 0} {$index < [dict get $parsed stripCount]} {incr index} {
    append data [Runs [::tclpdf::imageTiff strip $bytes $parsed $index] \
        $index decoded]
  }
  set wanted [Wanted $parsed]
  if {$decoded < $wanted} {
    return -code error -errorcode {TCLPDF TIFF DAMAGED} \
        "tclpdf: damaged TIFF - [dict get $parsed width] x\
        [dict get $parsed height] pixels want $wanted bytes of samples, and\
        the PackBits runs decode to $decoded"
  }
  # Surplus is not refused, for the reason [Fit] gives: a writer may pad its
  # last strip. Nor is it cut off - a RunLengthDecode stream declares no
  # length, and a reader takes Width x Height samples and stops.
  append data \x80
  return [One $parsed RunLengthDecode $data {} 1]
}

# LZW: unpacked and written out again as Flate, always. The reasoning and the
# measurements are in the file header - in one line, a passed-through LZW
# stream cannot be repaired once [$doc pdfa] is declared, and unpacking is
# cheaper than the picture it produces.
#
# The predictor stays with the stream: the differencing was applied before
# compression and is undone by the reader afterwards, so re-compressing the
# differenced bytes keeps it intact and saves a pass over every pixel in Tcl.
proc ::tclpdf::imageTiffStreams::Lzw {bytes parsed} {
  Reachable $parsed
  set data {}
  for {set index 0} {$index < [dict get $parsed stripCount]} {incr index} {
    append data [::tclpdf::filter decodeLzw \
        [::tclpdf::imageTiff strip $bytes $parsed $index]]
  }
  return [Repacked $parsed [Fit $data $parsed]]
}

# Deflate: the strips are zlib streams and /FlateDecode is the same zlib, so
# they go in as they are - one image per strip, because a zlib stream ends
# where the strip ends and the next one starts a new one.
#
# The exception is a 16-bit little-endian file: its samples have to be turned
# round, which means having them, which for zlib is cheap in both directions.
proc ::tclpdf::imageTiffStreams::Deflate {bytes parsed} {
  Reachable $parsed
  if {[Unpacked $parsed]} {
    set data {}
    for {set index 0} {$index < [dict get $parsed stripCount]} {incr index} {
      append data [::tclpdf::filter decodeFlate \
          [::tclpdf::imageTiff strip $bytes $parsed $index]]
    }
    return [Repacked $parsed [Fit $data $parsed]]
  }
  set parms [Predictor $parsed]
  set parts {}
  set row 0
  set index 0
  foreach strip [dict get $parsed strips] {
    lassign $strip offset count rows
    lappend parts [Part [::tclpdf::imageTiff strip $bytes $parsed $index] \
        [Pairs $parsed FlateDecode $parms] $row $rows]
    incr row $rows
    incr index
  }
  return [Result FlateDecode 1 $parts]
}

# TIFF 6.0 Technote 2 JPEG: one JPEG stream per strip, all of them sharing
# the tables in the JPEGTables tag, and none of them a file a decoder would
# accept on its own. Each strip becomes an image of its own - which is what
# it already is, down to its own SOF0 with its own height.
proc ::tclpdf::imageTiffStreams::Jpeg {bytes parsed} {
  Reachable $parsed
  set tables [Tables $parsed]
  set adobe [Adobe $parsed]
  set parts {}
  set row 0
  set index 0
  foreach strip [dict get $parsed strips] {
    lassign $strip offset count rows
    set data [::tclpdf::imageTiff strip $bytes $parsed $index]
    if {[string range $data 0 1] ne "\xff\xd8"} {
      return -code error -errorcode {TCLPDF TIFF DAMAGED jpeg} \
          "tclpdf: damaged TIFF - strip $index does not begin with a JPEG\
          start-of-image marker"
    }
    lappend parts [Part "\xff\xd8$adobe$tables[string range $data 2 end]" \
        [Pairs $parsed DCTDecode {}] $row $rows]
    incr row $rows
    incr index
  }
  return [Result DCTDecode 0 $parts]
}

# CCITT Group 3 and Group 4: passed through into /CCITTFaxDecode, one image
# per strip, because the coder restarts in every strip and a Group 4 stream
# codes each row against the one above it.
#
# Everything the filter is told comes from the tags and was worked out in
# imageTiff.tcl: K, EncodedByteAlign and - the trap - BlackIs1, which is
# written exactly as it arrives. The only thing decided here is FillOrder 2,
# which PDF cannot express and which is therefore undone in the bytes.
proc ::tclpdf::imageTiffStreams::Ccitt {bytes parsed} {
  set reverse [expr {[dict get $parsed fillOrder] == 2}]
  set parts {}
  set row 0
  set index 0
  foreach strip [dict get $parsed strips] {
    lassign $strip offset count rows
    set data [::tclpdf::imageTiff strip $bytes $parsed $index]
    if {$reverse} {
      set data [Reverse $data]
    }
    set parms [list K [dict get $parsed ccittK] \
        Columns [dict get $parsed columns] Rows $rows]
    if {[dict get $parsed blackIs1]} {
      lappend parms BlackIs1 true
    }
    if {[dict get $parsed encodedByteAlign]} {
      lappend parms EncodedByteAlign true
    }
    lappend parts [Part $data [Pairs $parsed CCITTFaxDecode $parms] $row $rows]
    incr row $rows
    incr index
  }
  return [Result CCITTFaxDecode [expr {!$reverse}] $parts]
}

# --- what the ways have in common ------------------------------------------

# The result of a compression that ends up as one deflated stream of samples:
# unpacked LZW, and Deflate that had to be taken apart for its byte order or
# its 16-bit predictor.
#
# The predictor is undone here and only here, and only at 16 bits. TIFF
# Predictor 2 at 16 bits takes the difference per component in the file's own
# byte order, and no reader undoes it there: poppler and CoreGraphics render a
# passed-through 16-bit /Predictor 2 as coloured noise (measured RMSE 0.37
# against 0.02 once it is resolved), the same failure the 16-bit colour key is
# decoded to avoid (doc/tclpdf.md). So it is resolved in the file's order here,
# after which the samples are ordinary and travel without a predictor. At eight
# bits and below the predictor travels with the stream as before - the reader
# undoes it correctly and re-differencing every pixel in Tcl is avoided.
proc ::tclpdf::imageTiffStreams::Repacked {parsed data} {
  set parms [Predictor $parsed]
  if {[llength $parms] && [dict get $parsed bitsPerComponent] == 16} {
    set data [::tclpdf::filter decodePredictor $data -predictor 2 \
        -colors [dict get $parsed components] -bitspercomponent 16 \
        -columns [dict get $parsed width] \
        -byteorder [expr {[dict get $parsed byteOrder] eq "MM" ? "big" : "little"}]]
    set parms {}
  }
  # A little-endian file's 16-bit samples are then turned into the order PDF
  # reads (high byte first, 8.9.5.2); a big-endian file is already in it.
  if {[Swapped $parsed]} {
    set data [Swap $data]
  }
  return [One $parsed FlateDecode [::tclpdf::filter encodeFlate $data] \
      $parms 0]
}

# A picture that is one image: the whole height in one part.
proc ::tclpdf::imageTiffStreams::One {parsed filter data parms through} {
  return [Result $filter $through [list [Part $data \
      [Pairs $parsed $filter $parms] 0 [dict get $parsed height]]]]
}

proc ::tclpdf::imageTiffStreams::Result {filter through parts} {
  return [dict create filter $filter passThrough $through \
      stacked [expr {[llength $parts] > 1}] parts $parts]
}

proc ::tclpdf::imageTiffStreams::Part {data pairs row rows} {
  return [dict create data $data pairs $pairs row $row rows $rows]
}

# The dictionary entries one part needs of its own: which filter reads it,
# what that filter has to be told, and whether its samples mean the opposite
# of what they say.
#
# The /Decode array comes from the description rather than from anything
# decided here, and it is empty for every CCITT picture however white it is -
# there the same fact travels as BlackIs1, and writing both would invert the
# picture twice.
proc ::tclpdf::imageTiffStreams::Pairs {parsed filter parms} {
  set pairs [list Filter /$filter]
  if {[llength $parms]} {
    lappend pairs DecodeParms [::tclpdf::pdfObj dictionary $parms]
  }
  if {[dict exists $parsed decode] && [dict get $parsed decode] ne {}} {
    lappend pairs Decode [::tclpdf::pdfObj arr [dict get $parsed decode]]
  }
  return $pairs
}

# The /DecodeParms of a predictor, or nothing when the file was written
# without one. /Predictor 2 is TIFF Predictor 2 in PDF too (ISO 32000-2,
# Table 10); the geometry it needs is the picture's own.
proc ::tclpdf::imageTiffStreams::Predictor {parsed} {
  if {[dict get $parsed predictor] != 2} {
    return {}
  }
  return [list Predictor 2 Colors [dict get $parsed components] \
      BitsPerComponent [dict get $parsed bitsPerComponent] \
      Columns [dict get $parsed width]]
}

# All the strips one after the other. Only ever called for a compression that
# carries no state from one strip to the next.
proc ::tclpdf::imageTiffStreams::Join {bytes parsed} {
  set data {}
  foreach strip [dict get $parsed strips] {
    lassign $strip offset count
    append data [string range $bytes $offset [expr {$offset + $count - 1}]]
  }
  return $data
}

# How many bytes of samples the picture is. A row occupies a whole number of
# bytes on both sides (TIFF 6.0 and ISO 32000-2, 8.9.5.2 agree), so this is
# arithmetic and not a guess. Two callers ask, and a second copy of the
# expression is how they would come to disagree about a 1-bit row: [Fit],
# which holds the samples, and [PackBits], which only ever counts what its
# runs would produce.
proc ::tclpdf::imageTiffStreams::Wanted {parsed} {
  set rowBytes [expr {([dict get $parsed width]
      * [dict get $parsed samplesPerPixel]
      * [dict get $parsed bitsPerComponent] + 7) / 8}]
  return [expr {$rowBytes * [dict get $parsed height]}]
}

# The check that the strips hold the samples the tags promise, for the ways
# that have the samples in hand: uncompressed, unpacked LZW, and Deflate
# taken apart for its byte order or its predictor. The three that pass their
# strips through cannot be held to it at any price worth paying - a Deflate
# strip would have to be inflated, which is what passing it through avoids, a
# JPEG strip decoded, and a CCITT strip is a run-length code whose length
# says nothing about the picture; PackBits is the one that CAN be counted
# without unpacking, and is, in [PackBits] itself.
#
# Too few is a damaged file and is refused. Too many is not: a writer may pad
# its last strip to a full RowsPerStrip, and a decoder that was asked for a
# strip gives back what it decoded - the surplus is cut off rather than
# shifting the picture.
proc ::tclpdf::imageTiffStreams::Fit {data parsed} {
  set wanted [Wanted $parsed]
  set have [string length $data]
  if {$have < $wanted} {
    return -code error -errorcode {TCLPDF TIFF DAMAGED} \
        "tclpdf: damaged TIFF - [dict get $parsed width] x\
        [dict get $parsed height] pixels want $wanted bytes of samples, and\
        the strips hold $have"
  }
  if {$have > $wanted} {
    return [string range $data 0 [expr {$wanted - 1}]]
  }
  return $data
}

# Are this file's samples in the wrong byte order for PDF? Only 16-bit
# components have a byte order at all, and only a little-endian file has the
# wrong one.
proc ::tclpdf::imageTiffStreams::Swapped {parsed} {
  return [expr {[dict get $parsed bitsPerComponent] == 16
      && [dict get $parsed byteOrder] eq "II"}]
}

# Must the samples be taken apart and re-deflated here rather than passed
# through with the strip's own bytes? Two reasons, and both need the decoded
# bytes in hand: a little-endian 16-bit file, whose samples PDF reads the wrong
# way round, and a 16-bit Predictor-2 file of EITHER byte order, whose
# per-component differencing no reader undoes correctly at that depth (see
# [Repacked]). LZW is always taken apart anyway; this decides it for Deflate.
proc ::tclpdf::imageTiffStreams::Unpacked {parsed} {
  return [expr {[dict get $parsed bitsPerComponent] == 16
      && ([dict get $parsed byteOrder] eq "II"
          || [dict get $parsed predictor] == 2)}]
}

# The two layouts that cannot be passed through and would need a decoder this
# package does not have. Neither occurs in the measured corpus; both are
# refused by name rather than drawn wrong.
#
# FillOrder 2 outside CCITT is the odder of the two: the reversal would have
# to happen to the CODED bytes, before LZW or zlib ever sees them, which is a
# different thing from the reversal in [Ccitt] and is not the same for two
# compressions. TIFF 6.0 recommends the tag only for bilevel data, and 193 of
# the 194 measured files say FillOrder 1 - the one that does not is a fax.
# Predictor 2 belongs with a compression that undoes it: PDF resolves the
# difference only for Flate and LZW data (Table 8), and both are the
# compressions differencing was meant to help. An uncompressed or PackBits
# strip that also carries Predictor 2 has nowhere to say so - RunLengthDecode
# takes no Predictor parameter, and undoing it in the bytes would be a decoder
# written for a case no measured file is. Refused by name rather than written
# as the differenced samples it would otherwise become. Called from [Raw] and
# [PackBits] only; LZW and Deflate carry the predictor themselves.
proc ::tclpdf::imageTiffStreams::NoPredictor {parsed} {
  if {[dict get $parsed predictor] == 2} {
    return -code error -errorcode {TCLPDF TIFF PREDICTOR} \
        "tclpdf: this TIFF is [dict get $parsed compressionName]-compressed and\
        carries Predictor 2 - PDF undoes a predictor only for Flate and LZW\
        data; re-save it without a predictor, or with LZW or Deflate"
  }
  return
}

proc ::tclpdf::imageTiffStreams::Reachable {parsed} {
  if {[dict get $parsed fillOrder] == 2} {
    return -code error -errorcode {TCLPDF TIFF FILLORDER} \
        "tclpdf: this TIFF is [dict get $parsed compressionName]-compressed\
        and reverses the bits in every byte (FillOrder 2) - tclpdf undoes\
        that for CCITT data and for uncompressed data; re-save it with\
        FillOrder 1"
  }
  if {[dict get $parsed compressionName] eq "packBits" && [Swapped $parsed]} {
    return -code error -errorcode {TCLPDF TIFF BYTEORDER} \
        "tclpdf: this TIFF holds 16-bit samples in a little-endian file and\
        packs them with PackBits - PDF reads a 16-bit sample high byte first,\
        and turning these round would mean decoding the packing; re-save it\
        big-endian (MM), at 8 bits, or with another compression"
  }
  return
}

# --- bytes ------------------------------------------------------------------

# The bits in every byte turned round - what FillOrder 2 asks for, and what
# PDF has no parameter to ask a filter for.
#
# "binary scan b*" reads a byte low bit first and "binary format B*" writes it
# high bit first, so the pair of them IS the reversal, in C and without a
# table. In chunks because the intermediate is eight characters per byte.
proc ::tclpdf::imageTiffStreams::Reverse {data} {
  variable chunk
  set out {}
  set total [string length $data]
  for {set at 0} {$at < $total} {incr at $chunk} {
    binary scan [string range $data $at [expr {$at + $chunk - 1}]] b* bits
    append out [binary format B* $bits]
  }
  return $out
}

# 16-bit samples from a little-endian file into the order PDF reads them in
# (8.9.5.2, high byte first). Chunked for the same reason [Reverse] is: the
# intermediate is one integer per sample.
proc ::tclpdf::imageTiffStreams::Swap {data} {
  variable chunk
  set out {}
  set total [string length $data]
  for {set at 0} {$at < $total} {incr at $chunk} {
    binary scan [string range $data $at [expr {$at + $chunk - 1}]] su* values
    append out [binary format Su* $values]
  }
  return $out
}

# One PackBits strip, walked: the no-op bytes dropped and the runs checked
# against the length of the strip. See [PackBits] for why the walk exists.
proc ::tclpdf::imageTiffStreams::Runs {data index decodedVar} {
  upvar 1 $decodedVar decoded
  set out {}
  set at 0
  set total [string length $data]
  while {$at < $total} {
    binary scan [string index $data $at] cu control
    if {$control == 128} {
      # A no-op in TIFF, EOD in PDF - so it goes.
      incr at
    } elseif {$control < 128} {
      set end [expr {$at + $control + 1}]
      if {$end > $total - 1} {
        return -code error -errorcode {TCLPDF TIFF DAMAGED} \
            "tclpdf: damaged TIFF - a literal run in PackBits strip $index\
            reaches past the end of the strip"
      }
      append out [string range $data $at $end]
      incr decoded [expr {$control + 1}]
      set at [expr {$end + 1}]
    } else {
      if {$at + 1 >= $total} {
        return -code error -errorcode {TCLPDF TIFF DAMAGED} \
            "tclpdf: damaged TIFF - a repeat run in PackBits strip $index has\
            no byte to repeat"
      }
      append out [string range $data $at [expr {$at + 1}]]
      incr decoded [expr {257 - $control}]
      incr at 2
    }
  }
  return $out
}

# --- JPEG -------------------------------------------------------------------

# The shared tables, without the SOI and EOI that make them look like a file
# of their own. A TIFF that has none - which is allowed, every strip then
# carries its own - contributes nothing here.
proc ::tclpdf::imageTiffStreams::Tables {parsed} {
  set tables [dict get $parsed jpegTables]
  if {$tables eq {}} {
    return {}
  }
  if {[string range $tables 0 1] ne "\xff\xd8"} {
    return -code error -errorcode {TCLPDF TIFF DAMAGED jpeg} \
        "tclpdf: damaged TIFF - the JPEGTables tag does not begin with a JPEG\
        start-of-image marker"
  }
  if {[string range $tables end-1 end] eq "\xff\xd9"} {
    return [string range $tables 2 end-2]
  }
  return [string range $tables 2 end]
}

# The APP14 Adobe segment that says how the three components are to be read.
#
# Without it the picture comes out green and magenta, and the reason is that
# the component identifiers in a TIFF strip are 0, 1 and 2 where a JFIF file
# writes 1, 2 and 3 - so a decoder cannot tell RGB from YCbCr and guesses.
# The segment says it outright: transform 0 for the components as they are,
# 1 for YCbCr. Fourteen bytes, of which one is the answer.
#
# Written for three-component pictures only. A four-component one would be
# CMYK, where the same marker means something further - Adobe's writers store
# such data inverted - and no measured file is one, so nothing is claimed
# about it.
proc ::tclpdf::imageTiffStreams::Adobe {parsed} {
  if {[dict get $parsed components] != 3} {
    return {}
  }
  set transform [expr {[dict get $parsed photometric] == 6 ? 1 : 0}]
  return [binary format a2Sa5SSSc "\xff\xee" 14 Adobe 100 0 0 $transform]
}

package provide tclpdf::imageTiffStreams 1.3
