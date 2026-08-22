#
# tclpdf - PDF generation for Tcl
#
# imageTiff - reading the structure of a TIFF file
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# File in, description out. Nothing is decoded here and no PDF object is
# built: this module reads the IFD chain and the tags, and answers with
# everything the caller needs to write an image - the extent, the colour
# space, the bit depth, the compression, where every strip sits, the
# resolution, an ICC profile, and the handful of facts a PDF filter asks for
# that only the tags know (BlackIs1, K, EncodedByteAlign, FillOrder,
# Predictor, JPEGTables). The strip bytes themselves are never touched.
#
# The line between what can be passed through and what would need a decoder
# does NOT run along the compressions - measured over 194 files, all six that
# occur are passable straight into a PDF filter, CCITT Group 4 included. It
# runs along two other things:
#
#   strips        every stateful compression restarts in every strip. A
#                 50-strip LZW file decodes exactly to line 50 as one
#                 concatenated stream and no further. So the strips are
#                 reported one by one, with their row counts, and the caller
#                 decides whether to concatenate them (stateless: none,
#                 PackBits) or to stack one image per strip.
#
#   ExtraSamples  alpha. PDF carries no alpha inside an image, so the channel
#                 would have to be split out into an /SMask - which means
#                 decoding. Refused by name here; 44 of 194 measured files
#                 have it.
#
# Two traps that are measured, not guessed, and are built in rather than left
# for the next reader to rediscover - see [Ccitt] and [parse] for the detail:
# the BlackIs1 polarity, which is the reverse of what the photometric name
# suggests, and FillOrder 2, which PDF has no parameter for.
#
# Where the bit reversal for FillOrder 2 lives is a decision, and it is NOT
# here: this module reads and describes, it does not rewrite bytes. The
# description carries "fillOrder 2" and the module that builds the streams
# turns the bits round, in the one place that already walks the strip data.
#
# Several IFDs are NOT several pages. Measured over the corpus, 6 files carry
# more than one and not one of them is a stack of scanned sheets - five are
# two icon sizes in one file, the sixth is a 120x160 thumbnail marked
# NewSubfileType 1 behind a 8736x11648 photograph. Laying both out as pages
# prints the thumbnail and the original one after the other. So [parse]
# describes ONE image, the primary one, and reports the whole chain in
# "directories" so a caller can say what else is in the file - or ask for
# another IFD by index, deliberately.
#
# This is a private sub-module behind the [image] facade. Nobody loads it
# directly.
#
# Failures carry an -errorcode beginning {TCLPDF TIFF}: RANGE and DAMAGED for
# a broken file, and one word per refusal (BIGTIFF, TILED, PLANAR, ALPHA,
# COMPRESSION, PHOTOMETRIC, DEPTH, SAMPLES, SAMPLEFORMAT, PREDICTOR, PALETTE,
# ORIENTATION, CCITT, CIRCULAR, DIRECTORY, SIGNATURE). The code is the
# contract, the message text is not.
#

package require Tcl 8.6.11-

namespace eval ::tclpdf::imageTiff {
  namespace export {[a-z]*}
  namespace ensemble create

  # The tags this module reads, by name (TIFF 6.0 section 8, and the CCITT
  # and JPEG additions). Everything else in a directory is skipped - a TIFF
  # carries camera make, artist and copyright, and none of that reaches a
  # PDF image.
  variable tags {
    newSubfileType 254 subfileType 255 imageWidth 256 imageLength 257
    bitsPerSample 258 compression 259 photometric 262 fillOrder 266
    stripOffsets 273 orientation 274 samplesPerPixel 277 rowsPerStrip 278
    stripByteCounts 279 xResolution 282 yResolution 283 planarConfig 284
    t4Options 292 t6Options 293 resolutionUnit 296 predictor 317
    colorMap 320 tileWidth 322 tileLength 323 tileOffsets 324
    tileByteCounts 325 inkSet 332 extraSamples 338 sampleFormat 339
    jpegTables 347 icc 34675
  }

  # Field type -> bytes per value (TIFF 6.0, table 2). Types 11 (FLOAT) and
  # 12 (DOUBLE) are listed so that their size is known and a directory
  # walks past them, but no tag read here uses them.
  variable typeSize {1 1 2 1 3 2 4 4 5 8 6 1 7 1 8 2 9 4 10 8 11 4 12 8 13 4}

  # Compression -> the name this package uses for it. These eight are the
  # ones a PDF filter can be told to undo; anything else is refused with its
  # number.
  variable schemes {
    1 none 2 ccittRle 3 ccittG3 4 ccittG4 5 lzw 7 jpeg 8 deflate
    32773 packBits 32946 deflate
  }
}

# --- byte readers ----------------------------------------------------------
#
# TIFF is the one format in this package that is written in both byte orders,
# so the readers take the order rather than being written twice. The package
# already has bounds-checked readers in otLayout, but they are big-endian
# only and they raise {TCLPDF LAYOUT RANGE} with a message about a font
# table - reaching for them here would report a damaged TIFF as a damaged
# font and would still need a second, little-endian set beside them. One set
# with the order as an argument is fewer readers, not more.

proc ::tclpdf::imageTiff::Range {bytes offset count what} {
  if {$offset < 0 || $count < 0 || $offset + $count > [string length $bytes]} {
    return -code error -errorcode {TCLPDF TIFF RANGE} \
        "tclpdf: damaged TIFF - $what at offset $offset runs past the end of\
        the file ([string length $bytes] bytes)"
  }
  return
}

proc ::tclpdf::imageTiff::u16 {bytes offset order {what {a value}}} {
  Range $bytes $offset 2 $what
  binary scan $bytes @${offset}[expr {$order eq "MM" ? "Su" : "su"}] value
  return $value
}

proc ::tclpdf::imageTiff::u32 {bytes offset order {what {a value}}} {
  Range $bytes $offset 4 $what
  binary scan $bytes @${offset}[expr {$order eq "MM" ? "Iu" : "iu"}] value
  return $value
}

# The byte order of a TIFF, or the empty string when this is not one.
#
# Four bytes decide it, never the file name: in the measured corpus one file
# called ".tif" is a JPEG. BigTIFF answers with its order too, so that a
# caller can say "this is a TIFF" and let [parse] say which kind it is - a
# signature that answered "not a TIFF" would refuse it with the wrong reason.
proc ::tclpdf::imageTiff::signature {bytes} {
  switch -- [string range $bytes 0 3] {
    "II\x2a\x00" - "II\x2b\x00" {return II}
    "MM\x00\x2a" - "MM\x00\x2b" {return MM}
  }
  return {}
}

# --- the directory ---------------------------------------------------------

# One IFD. Returns {entries next}, where entries is a dict tag -> {type count
# location} and next is the offset of the following IFD, or 0.
#
# The values are NOT read here, only located: a directory may point at a 3 MB
# ICC profile, and a walk that read every field would pull it in to find out
# how wide the picture is.
proc ::tclpdf::imageTiff::Directory {bytes offset order} {
  variable typeSize

  set count [u16 $bytes $offset $order "an IFD entry count"]
  # 2 bytes count, 12 per entry, 4 for the next pointer.
  Range $bytes $offset [expr {2 + $count * 12 + 4}] "an IFD of $count entries"
  set entries {}
  for {set index 0} {$index < $count} {incr index} {
    set at [expr {$offset + 2 + $index * 12}]
    set tag [u16 $bytes $at $order "an IFD tag"]
    set type [u16 $bytes [expr {$at + 2}] $order "an IFD field type"]
    set number [u32 $bytes [expr {$at + 4}] $order "an IFD field count"]
    if {![dict exists $typeSize $type]} {
      # An unknown field type has an unknown width, so the entry cannot even
      # be skipped safely - but the entry itself is a fixed 12 bytes, so the
      # WALK is safe. Only this one field is dropped (TIFF 6.0 section 2
      # says a reader shall skip what it does not know).
      continue
    }
    set total [expr {$number * [dict get $typeSize $type]}]
    # Up to four bytes live in the field itself, left-justified, and are read
    # in the file's byte order like everything else; more than four and the
    # field holds an offset (TIFF 6.0, "Value Offset").
    if {$total <= 4} {
      set location [expr {$at + 8}]
    } else {
      set location [u32 $bytes [expr {$at + 8}] $order "the value offset of tag $tag"]
      Range $bytes $location $total "the $total bytes of tag $tag"
    }
    dict set entries $tag [list $type $number $location]
  }
  set next [u32 $bytes [expr {$offset + 2 + $count * 12}] $order \
      "the next-IFD pointer"]
  return [list $entries $next]
}

# The numbers behind a located field.
proc ::tclpdf::imageTiff::Numbers {bytes entry order} {
  lassign $entry type number location
  if {$number == 0} {
    return {}
  }
  set big [expr {$order eq "MM"}]
  switch -- $type {
    1 - 7 {set format cu}
    6 {set format c}
    3 {set format [expr {$big ? "Su" : "su"}]}
    8 {set format [expr {$big ? "S" : "s"}]}
    4 - 13 {set format [expr {$big ? "Iu" : "iu"}]}
    9 {set format [expr {$big ? "I" : "i"}]}
    5 - 10 {
      # A RATIONAL is two LONGs; a denominator of zero is answered as zero
      # rather than raising, since a resolution of 0/0 is a sloppy writer
      # and not a reason to refuse a picture.
      set format [expr {$type == 5 ? ($big ? "Iu" : "iu") : ($big ? "I" : "i")}]
      binary scan $bytes @${location}${format}[expr {$number * 2}] parts
      set result {}
      foreach {top bottom} $parts {
        lappend result [expr {$bottom == 0 ? 0.0 : double($top) / $bottom}]
      }
      return $result
    }
    default {
      return -code error -errorcode {TCLPDF TIFF DAMAGED} \
          "tclpdf: damaged TIFF - field type $type cannot be read as a number"
    }
  }
  binary scan $bytes @${location}${format}${number} values
  return $values
}

# The raw bytes behind a located field - an ICC profile, a JPEGTables block.
proc ::tclpdf::imageTiff::Payload {bytes entry} {
  variable typeSize
  lassign $entry type number location
  set total [expr {$number * [dict get $typeSize $type]}]
  return [string range $bytes $location [expr {$location + $total - 1}]]
}

# One tag as a single number, or the default when it is not there.
proc ::tclpdf::imageTiff::Get {bytes entries order name {default {}}} {
  variable tags
  set tag [dict get $tags $name]
  if {![dict exists $entries $tag]} {
    return $default
  }
  set values [Numbers $bytes [dict get $entries $tag] $order]
  if {[llength $values] == 0} {
    return $default
  }
  return [lindex $values 0]
}

# One tag as the whole list, or the default.
proc ::tclpdf::imageTiff::GetAll {bytes entries order name {default {}}} {
  variable tags
  set tag [dict get $tags $name]
  if {![dict exists $entries $tag]} {
    return $default
  }
  return [Numbers $bytes [dict get $entries $tag] $order]
}

# Does this directory carry that tag at all?
proc ::tclpdf::imageTiff::Has {entries name} {
  variable tags
  return [dict exists $entries [dict get $tags $name]]
}

# --- the chain -------------------------------------------------------------

# Every IFD of the file, in order, as a list of entry dicts.
#
# The chain is walked the way importRead walks the /Prev chain of a
# cross-reference: every offset already seen ends it with a named refusal. A
# file that points its last IFD back at its first is not rare enough to be
# left as an endless loop, and the loop would be silent - it allocates
# nothing and never returns.
proc ::tclpdf::imageTiff::Chain {bytes order} {
  set offset [u32 $bytes 4 $order "the first-IFD pointer"]
  set seen {}
  set chain {}
  while {$offset != 0} {
    if {[dict exists $seen $offset]} {
      return -code error -errorcode {TCLPDF TIFF CIRCULAR} \
          "tclpdf: damaged TIFF - the IFD chain returns to offset $offset and\
          would never end"
    }
    dict set seen $offset 1
    lassign [Directory $bytes $offset $order] entries offset
    lappend chain $entries
  }
  if {[llength $chain] == 0} {
    return -code error -errorcode {TCLPDF TIFF DAMAGED} \
        "tclpdf: damaged TIFF - the file has no IFD"
  }
  return $chain
}

# Is this directory a reduced-resolution version of another image?
#
# Two tags say so: NewSubfileType bit 0 (TIFF 6.0), and the superseded
# SubfileType with the value 2. Both are honoured, because the measured
# thumbnail in the corpus uses the first and old writers use the second.
proc ::tclpdf::imageTiff::Reduced {bytes entries order} {
  if {[Get $bytes $entries $order newSubfileType 0] & 1} {
    return 1
  }
  return [expr {[Get $bytes $entries $order subfileType 0] == 2}]
}

# --- the description -------------------------------------------------------

# Read a TIFF and report what a PDF image needs. See the file header for what
# is deliberately not answered.
#
# "index" picks one IFD by number; left out, the primary image is described -
# the first directory that is not marked as a reduced-resolution copy, which
# for every measured file is directory 0.
proc ::tclpdf::imageTiff::parse {bytes {index {}}} {
  set order [signature $bytes]
  if {$order eq {}} {
    return -code error -errorcode {TCLPDF TIFF SIGNATURE} \
        "tclpdf: not a TIFF file - it begins with neither \"II\" nor \"MM\"\
        followed by the TIFF version word"
  }
  set version [u16 $bytes 2 $order "the version word"]
  if {$version == 43} {
    return -code error -errorcode {TCLPDF TIFF BIGTIFF} \
        "tclpdf: this is a BigTIFF (version 43), which uses 64-bit offsets -\
        tclpdf reads classic TIFF (version 42); save it as a classic TIFF, or\
        as a PNG"
  }
  if {$version != 42} {
    return -code error -errorcode {TCLPDF TIFF SIGNATURE} \
        "tclpdf: this is not a TIFF - the version word is $version, not 42"
  }

  set chain [Chain $bytes $order]
  set directories [Directories $bytes $chain $order]
  set index [Choose $directories $index]
  set entries [lindex $chain $index]

  Structure $bytes $entries $order
  set result [Head $bytes $entries $order]
  set result [dict merge $result \
      [Samples $bytes $entries $order $result] \
      [Resolution $bytes $entries $order] \
      [Extras $bytes $entries $order]]
  set result [dict merge $result [Strips $bytes $entries $order $result]]
  set result [dict merge $result [Ccitt $bytes $entries $order $result]]
  dict set result byteOrder $order
  dict set result directories $directories
  dict set result ifdIndex $index
  dict set result ifdCount [llength $chain]
  # WhiteIsZero read as ordinary samples needs a /Decode array to come out
  # the right way round: 0 has to paint white. On a CCITT stream the same
  # fact travels as BlackIs1 instead - see [Ccitt] - and writing both would
  # invert the picture twice.
  dict set result decode {}
  if {[dict get $result photometric] == 0
      && ![dict exists $result blackIs1]} {
    dict set result decode {1 0}
  }
  return $result
}

# What is in the file besides the picture that is about to be described. Not
# pages: see the file header.
proc ::tclpdf::imageTiff::Directories {bytes chain order} {
  set result {}
  set index 0
  foreach entries $chain {
    lappend result [dict create index $index \
        width [Get $bytes $entries $order imageWidth 0] \
        height [Get $bytes $entries $order imageLength 0] \
        reduced [Reduced $bytes $entries $order]]
    incr index
  }
  return $result
}

# Which IFD is meant: the one asked for, or the primary image.
proc ::tclpdf::imageTiff::Choose {directories index} {
  if {$index eq {}} {
    foreach entry $directories {
      if {![dict get $entry reduced]} {
        return [dict get $entry index]
      }
    }
    return 0
  }
  if {![string is integer -strict $index]
      || $index < 0 || $index >= [llength $directories]} {
    return -code error -errorcode {TCLPDF TIFF DIRECTORY} \
        "tclpdf: this TIFF has [llength $directories] IFD(s), so there is no\
        directory \"$index\""
  }
  return $index
}

# The three ways a TIFF can be laid out that this package does not read.
# Every one of them is refused by name, with what the file is and what the
# package does read - none of the three may be mistaken for something else
# and drawn wrong. Measured over 194 files, none of the three occurs.
proc ::tclpdf::imageTiff::Structure {bytes entries order} {
  if {[Has $entries tileWidth] || [Has $entries tileLength]
      || [Has $entries tileOffsets]} {
    return -code error -errorcode {TCLPDF TIFF TILED} \
        "tclpdf: this TIFF is stored in tiles, not in strips - tclpdf reads\
        striped TIFF files; re-save it without tiling"
  }
  set planar [Get $bytes $entries $order planarConfig 1]
  if {$planar != 1} {
    return -code error -errorcode {TCLPDF TIFF PLANAR} \
        "tclpdf: this TIFF keeps its colour channels in separate planes\
        (PlanarConfiguration $planar) - tclpdf reads files whose samples are\
        interleaved (PlanarConfiguration 1); re-save it as interleaved"
  }
  set extra [GetAll $bytes $entries $order extraSamples]
  if {[llength $extra] > 0} {
    return -code error -errorcode {TCLPDF TIFF ALPHA} \
        "tclpdf: this TIFF has [llength $extra] extra sample(s) per pixel\
        (ExtraSamples), which is an alpha channel - a PDF image carries no\
        alpha of its own and tclpdf does not split one out; flatten the\
        picture onto a background, or save it as a PNG"
  }
  return
}

# Extent, compression and the tags that describe the file rather than its
# samples.
proc ::tclpdf::imageTiff::Head {bytes entries order} {
  variable schemes

  set width [Get $bytes $entries $order imageWidth]
  set height [Get $bytes $entries $order imageLength]
  if {$width eq {} || $height eq {} || $width <= 0 || $height <= 0} {
    return -code error -errorcode {TCLPDF TIFF DAMAGED} \
        "tclpdf: damaged TIFF - the IFD gives no usable image size"
  }
  set compression [Get $bytes $entries $order compression 1]
  if {![dict exists $schemes $compression]} {
    set what [expr {$compression == 6 ?
        "the withdrawn TIFF 6.0 JPEG scheme (6)" : "compression $compression"}]
    return -code error -errorcode [list TCLPDF TIFF COMPRESSION $compression] \
        "tclpdf: this TIFF uses $what - tclpdf reads uncompressed, PackBits,\
        LZW, Deflate, CCITT (Group 3 and 4) and TIFF 6.0 Technote 2 JPEG\
        data; re-save it with one of those"
  }
  set predictor [Get $bytes $entries $order predictor 1]
  if {$predictor ni {1 2}} {
    return -code error -errorcode [list TCLPDF TIFF PREDICTOR $predictor] \
        "tclpdf: this TIFF was written with Predictor $predictor - PDF undoes\
        no predictor but horizontal differencing (2); re-save it without a\
        predictor"
  }
  set photometric [Get $bytes $entries $order photometric]
  if {$photometric eq {}} {
    return -code error -errorcode {TCLPDF TIFF DAMAGED} \
        "tclpdf: damaged TIFF - the IFD has no PhotometricInterpretation"
  }
  # Orientation says where row 0 and column 0 of the samples belong on the
  # paper: 1 is the top left corner and the way every other format this
  # package reads stores its rows, and the other seven turn the picture,
  # mirror it, or both (TIFF 6.0, Orientation). A PDF image is drawn as the
  # rows stand, so a file that says anything else would come out turned or
  # mirrored without a word - the one defect in this module that no
  # validator can see, because the file is perfect either way. Refused by
  # name, like the tiled and planar layouts above: reading it would mean
  # turning the samples round, which for a striped picture means undoing the
  # strips as well. None of the 194 measured files says anything but 1.
  set orientation [Get $bytes $entries $order orientation 1]
  if {$orientation != 1} {
    set names {2 {mirrored left to right} 3 {turned by 180 degrees}
        4 {mirrored top to bottom} 5 {transposed} 6 {turned by 90 degrees}
        7 {transposed the other way} 8 {turned by 270 degrees}}
    set what [expr {[dict exists $names $orientation] ?
        [dict get $names $orientation] : "stored in an unknown orientation"}]
    return -code error -errorcode [list TCLPDF TIFF ORIENTATION $orientation] \
        "tclpdf: this TIFF is $what (Orientation $orientation) - a PDF image\
        draws the rows as they stand, so tclpdf would place it that way\
        without a word; re-save it with the first row at the top (Orientation\
        1)"
  }
  return [dict create \
      width $width \
      height $height \
      photometric $photometric \
      samplesPerPixel [Get $bytes $entries $order samplesPerPixel 1] \
      compression $compression \
      compressionName [dict get $schemes $compression] \
      predictor $predictor \
      orientation $orientation \
      fillOrder [Get $bytes $entries $order fillOrder 1]]
}

# The samples: how many bits each takes, what they mean, and the lookup a
# palette image reads them through.
proc ::tclpdf::imageTiff::Samples {bytes entries order head} {
  set samples [dict get $head samplesPerPixel]
  set photometric [dict get $head photometric]
  lassign [Space $photometric $samples [dict get $head compressionName]] \
      space components

  set depths [GetAll $bytes $entries $order bitsPerSample 1]
  if {[llength $depths] != $samples} {
    # A missing BitsPerSample means 1 bit for every sample (TIFF 6.0); one
    # that is there but does not have an entry per sample is damaged.
    if {![Has $entries bitsPerSample]} {
      set depths [lrepeat $samples 1]
    } else {
      return -code error -errorcode {TCLPDF TIFF DAMAGED} \
          "tclpdf: damaged TIFF - BitsPerSample has [llength $depths] entries\
          for $samples samples per pixel"
    }
  }
  set depth [lindex $depths 0]
  foreach other $depths {
    if {$other != $depth} {
      return -code error -errorcode [list TCLPDF TIFF DEPTH $depths] \
          "tclpdf: this TIFF stores its samples at different bit depths\
          ([join $depths {, }]) - a PDF image has one bit depth for all its\
          components; re-save it with one depth for every sample"
    }
  }
  if {$depth ni {1 2 4 8 16}} {
    return -code error -errorcode [list TCLPDF TIFF DEPTH $depth] \
        "tclpdf: this TIFF stores $depth bits per sample - a PDF image is\
        written at 1, 2, 4, 8 or 16 (ISO 32000-2, table 87); re-save it at\
        one of those"
  }
  foreach kind [GetAll $bytes $entries $order sampleFormat 1] {
    if {$kind != 1} {
      return -code error -errorcode [list TCLPDF TIFF SAMPLEFORMAT $kind] \
          "tclpdf: this TIFF stores its samples as SampleFormat $kind -\
          tclpdf reads unsigned integer samples (SampleFormat 1); re-save it\
          as an ordinary 8-bit or 16-bit image"
    }
  }
  return [dict create space $space components $components \
      bitsPerSample $depths bitsPerComponent $depth \
      palette [Palette $bytes $entries $order $photometric $depth]]
}

# The lookup of a palette image, as 8-bit RGB triples - the same shape the PNG
# side hands on as its PLTE bytes, so that both build the same /Indexed array.
#
# TIFF writes the ramps 16 bits wide and one after the other (all reds, then
# all greens, then all blues), which is neither the order nor the width PDF
# reads. Not one file in the measured corpus of 194 is a palette image, so
# this way is checked against a built fixture and against nothing else.
proc ::tclpdf::imageTiff::Palette {bytes entries order photometric depth} {
  if {$photometric != 3} {
    return {}
  }
  # An /Indexed colour space names its last index, and that number "shall be
  # no greater than 255" (ISO 32000-2, 8.6.6.3) - a palette PDF can write
  # holds at most 256 colours, whatever the samples that index it are. TIFF
  # 6.0 says the same of its own palette images (BitsPerSample 4 or 8), so a
  # 16-bit one is outside both; refused by name here rather than written as
  # "/Indexed /DeviceRGB 65535", which is a colour space no reader accepts -
  # measured with pdfimages: "Bad Indexed color space (invalid indexHigh
  # 65535)". Depths of 1 and 2 stay allowed: they are as far outside TIFF's
  # own list as they are inside PDF's limit, and they draw correctly.
  if {$depth > 8} {
    return -code error -errorcode [list TCLPDF TIFF PALETTE $depth] \
        "tclpdf: this TIFF is a palette image of $depth bits per sample, so\
        its ColorMap holds [expr {1 << $depth}] colours - an /Indexed colour\
        space names at most 256 (ISO 32000-2, 8.6.6.3: hival shall be no\
        greater than 255), and TIFF 6.0 writes palette images at 4 or 8 bits;\
        re-save it as an 8-bit palette image, or as an RGB one"
  }
  set map [GetAll $bytes $entries $order colorMap]
  set count [expr {1 << $depth}]
  if {[llength $map] != 3 * $count} {
    return -code error -errorcode {TCLPDF TIFF DAMAGED} \
        "tclpdf: damaged TIFF - a $depth-bit palette image wants a ColorMap of\
        [expr {3 * $count}] entries, and this one has [llength $map]"
  }
  set palette {}
  for {set index 0} {$index < $count} {incr index} {
    append palette [binary format ccc \
        [expr {[lindex $map $index] >> 8}] \
        [expr {[lindex $map [expr {$count + $index}]] >> 8}] \
        [expr {[lindex $map [expr {2 * $count + $index}]] >> 8}]]
  }
  return $palette
}

# Where every strip sits, how long it is and how many rows it holds.
#
# The row count is not decoration: a CCITTFaxDecode filter is told /Rows, and
# a caller that stacks one image per strip needs to know how tall each one
# is. The last strip is short whenever the height is not a multiple of
# RowsPerStrip.
proc ::tclpdf::imageTiff::Strips {bytes entries order head} {
  set width [dict get $head width]
  set height [dict get $head height]

  set rows [Get $bytes $entries $order rowsPerStrip $height]
  if {$rows <= 0 || $rows > $height} {
    # 0xFFFFFFFF is the documented way of saying "the whole picture in one
    # strip", and a writer that leaves the tag out means the same.
    set rows $height
  }
  set offsets [GetAll $bytes $entries $order stripOffsets]
  set counts [GetAll $bytes $entries $order stripByteCounts]
  if {[llength $offsets] == 0} {
    return -code error -errorcode {TCLPDF TIFF DAMAGED} \
        "tclpdf: damaged TIFF - the IFD has no StripOffsets"
  }
  if {[llength $counts] == 0 && [dict get $head compression] == 1} {
    # StripByteCounts is required by the format, but an uncompressed picture
    # says how long its strips are by saying how big its pixels are - so this
    # one case is worked out rather than refused.
    set rowBytes [expr {($width * [dict get $head samplesPerPixel]
        * [dict get $head bitsPerComponent] + 7) / 8}]
    set counts {}
    for {set index 0} {$index < [llength $offsets]} {incr index} {
      lappend counts [expr {$rowBytes * min($rows, $height - $index * $rows)}]
    }
  }
  if {[llength $counts] != [llength $offsets]} {
    return -code error -errorcode {TCLPDF TIFF DAMAGED} \
        "tclpdf: damaged TIFF - [llength $offsets] StripOffsets against\
        [llength $counts] StripByteCounts"
  }
  set wanted [expr {($height + $rows - 1) / $rows}]
  if {[llength $offsets] != $wanted} {
    return -code error -errorcode {TCLPDF TIFF DAMAGED} \
        "tclpdf: damaged TIFF - $height rows at $rows rows per strip want\
        $wanted strips, and the IFD lists [llength $offsets]"
  }
  set strips {}
  set index 0
  foreach offset $offsets count $counts {
    Range $bytes $offset $count "strip $index"
    lappend strips [list $offset $count \
        [expr {min($rows, $height - $index * $rows)}]]
    incr index
  }
  return [dict create rowsPerStrip $rows strips $strips \
      stripCount [llength $strips]]
}

# How finely the picture is drawn.
#
# Not a comfort entry: the package reads the resolution nowhere else and
# places every picture at 72 dpi, so a 200 dpi scan 1728 pixels wide - 219 mm
# of paper - comes out 610 mm wide.
#
# ResolutionUnit 1 says the two numbers are an aspect ratio and nothing more,
# and a unit outside the three the format defines says nothing at all. There
# is then no dpi to report, and the caller is told so rather than handed a
# made-up one: 72 stands in the field so that arithmetic downstream has a
# number, and "resolutionKnown 0" says not to believe it.
proc ::tclpdf::imageTiff::Resolution {bytes entries order} {
  set unit [Get $bytes $entries $order resolutionUnit 2]
  set x [Get $bytes $entries $order xResolution 0]
  set y [Get $bytes $entries $order yResolution 0]
  # TIFF 6.0 defines three units and no more: 1 (none), 2 (inch), 3 (cm).
  # Only the last two are a measure, so only those give a dpi. A file that
  # writes 0 - or 42 - says nothing this reader can turn into inches, and
  # calling it inches would be a made-up number of exactly the kind
  # "resolutionKnown 0" exists to avoid: it decides how large a placement
  # without -width comes out, so a guess there is millimetres of paper.
  set known [expr {$unit in {2 3} && $x > 0 && $y > 0}]
  # Unit 3 counts per centimetre, unit 2 per inch.
  set factor [expr {$unit == 3 ? 2.54 : 1.0}]
  return [dict create \
      xResolution $x \
      yResolution $y \
      resolutionUnit $unit \
      resolutionKnown [expr {$known ? 1 : 0}] \
      xDpi [expr {$known ? $x * $factor : 72.0}] \
      yDpi [expr {$known ? $y * $factor : 72.0}]]
}

# The two blocks of foreign bytes a TIFF may carry: an ICC profile, and the
# shared Huffman and quantisation tables of a JPEG-compressed one. Both are
# handed on untouched - the profile becomes an /ICCBased stream, the tables
# belong in front of every strip's own JPEG data, and neither is this
# module's business beyond finding it.
proc ::tclpdf::imageTiff::Extras {bytes entries order} {
  variable tags
  set result [dict create icc {} jpegTables {}]
  foreach name {icc jpegTables} {
    if {[Has $entries $name]} {
      dict set result $name \
          [Payload $bytes [dict get $entries [dict get $tags $name]]]
    }
  }
  return $result
}

# The colour space and the number of components, from the photometric
# interpretation. Returns {space components}.
proc ::tclpdf::imageTiff::Space {photometric samples scheme} {
  switch -- $photometric {
    0 - 1 {set space DeviceGray; set wanted 1}
    2 {set space DeviceRGB; set wanted 3}
    3 {set space Indexed; set wanted 1}
    5 {set space DeviceCMYK; set wanted 4}
    6 {
      # YCbCr. Inside a JPEG the conversion to RGB happens in the codec, so
      # /DCTDecode delivers three colour components and nothing here has to
      # convert anything. Outside one it would be a real colour conversion
      # over every pixel, which is a decoder - refused.
      if {$scheme ne "jpeg"} {
        return -code error -errorcode [list TCLPDF TIFF PHOTOMETRIC $photometric] \
            "tclpdf: this TIFF stores YCbCr samples outside a JPEG stream -\
            converting those to RGB means decoding every pixel, which tclpdf\
            does not do; re-save it as an RGB TIFF"
      }
      set space DeviceRGB
      set wanted 3
    }
    default {
      set names {4 {a transparency mask} 8 {CIE L*a*b*} 9 {ICC L*a*b*}
          10 {ITU L*a*b*}}
      set what [expr {[dict exists $names $photometric] ?
          [dict get $names $photometric] : "PhotometricInterpretation $photometric"}]
      return -code error -errorcode [list TCLPDF TIFF PHOTOMETRIC $photometric] \
          "tclpdf: this TIFF holds $what - tclpdf reads greyscale, RGB,\
          palette and CMYK images; re-save it as one of those"
    }
  }
  if {$samples != $wanted} {
    return -code error -errorcode [list TCLPDF TIFF SAMPLES $samples] \
        "tclpdf: this TIFF has $samples samples per pixel where\
        PhotometricInterpretation $photometric wants $wanted, and it does not\
        say what the others are (no ExtraSamples) - re-save it as a plain\
        [expr {$wanted == 1 ? "greyscale" : ($wanted == 3 ? "RGB" : "CMYK")}]\
        image"
  }
  return [list $space $wanted]
}

# What a CCITTFaxDecode filter has to be told, from the tags. Returns an empty
# dict for every other compression.
#
# THE POLARITY IS THE REVERSE OF WHAT THE NAME SUGGESTS. PhotometricInterpretation
# 0 is called WhiteIsZero, which reads like "so a one bit is black, so
# BlackIs1 is true" - and that is wrong. The CCITT code stream carries its own
# idea of white: T.4 and T.6 code runs of white and black, and PDF's
# BlackIs1 = false (the default) makes the decoder put out 0 for the black
# runs and 1 for the white ones, which is exactly what DeviceGray then paints.
# So a plain fax - WhiteIsZero, like both scans in the measured corpus - wants
# BlackIs1 FALSE, and the rule is
#
#     BlackIs1 := (PhotometricInterpretation == 1)
#
# Measured on two files that disagree with each other: white fraction
# 0.876 against a reference 0.876 and 0.4418 against 0.4418; the other way
# round gives 0.5582, which is precisely the negative. Turned round again by
# the next reader, the picture comes out inverted and every checker in the
# house calls the file flawless. Leave it as it stands.
proc ::tclpdf::imageTiff::Ccitt {bytes entries order head} {
  set scheme [dict get $head compressionName]
  if {$scheme ni {ccittRle ccittG3 ccittG4}} {
    return {}
  }
  # A fax is bilevel and nothing else: T.4 and T.6 code runs of white and
  # black, and a CCITTFaxDecode filter puts out one bit per pixel whatever
  # the image dictionary claims (ISO 32000-2, 7.4.6, Table 11 - the filter's
  # own Columns and Rows describe a bitmap). A file that says CCITT and 8
  # bits, or CCITT and RGB, was written by something that meant one of the
  # two; taking the tags at their word gives /BitsPerComponent 8 over a
  # one-bit stream, which every reader draws as a picture 8 times too narrow
  # or as nothing at all. Both scans in the measured corpus are bilevel
  # WhiteIsZero, and no measured file disagrees.
  set depth [dict get $head bitsPerComponent]
  set photometric [dict get $head photometric]
  if {$depth != 1 || $photometric ni {0 1}} {
    return -code error -errorcode [list TCLPDF TIFF CCITT $photometric $depth] \
        "tclpdf: this TIFF says it is $scheme-compressed, which codes runs of\
        black and white, and describes its samples as\
        [expr {$depth != 1 ? "$depth bits per sample" : "PhotometricInterpretation\
        $photometric"}] - a CCITTFaxDecode filter delivers one bit per pixel\
        of a bilevel picture (ISO 32000-2, 7.4.6); the file disagrees with\
        itself, re-save it as a bilevel fax or with another compression"
  }
  set result [dict create \
      blackIs1 [expr {[dict get $head photometric] == 1}] \
      columns [dict get $head width]]
  switch -- $scheme {
    ccittRle {
      # Modified Huffman, one dimension, and every row starts on a byte
      # boundary (TIFF 6.0, compression 2).
      dict set result ccittK 0
      dict set result encodedByteAlign 1
    }
    ccittG3 {
      set options [Get $bytes $entries $order t4Options 0]
      # Bit 0: two-dimensional coding. PDF says K > 0 for the mixed mode,
      # and one 2-D line after each 1-D line is what T.4 allows at most for
      # the vertical resolutions in use.
      dict set result ccittK [expr {($options & 1) ? 1 : 0}]
      # Bit 2: fill bits were added so that every EOL ends on a byte
      # boundary, which is what EncodedByteAlign describes.
      dict set result encodedByteAlign [expr {($options & 4) ? 1 : 0}]
    }
    ccittG4 {
      dict set result ccittK -1
      dict set result encodedByteAlign 0
    }
  }
  return $result
}

# --- what a caller asks afterwards -----------------------------------------

# The bytes of one strip, exactly as they stand in the file. Nothing is
# decoded, nothing is reversed: this only saves every caller from repeating
# the bounds check that [parse] already made.
proc ::tclpdf::imageTiff::strip {bytes parsed index} {
  set strips [dict get $parsed strips]
  if {![string is integer -strict $index] || $index < 0
      || $index >= [llength $strips]} {
    return -code error -errorcode {TCLPDF TIFF RANGE} \
        "tclpdf: this TIFF image has [llength $strips] strip(s), so there is\
        no strip \"$index\""
  }
  lassign [lindex $strips $index] offset count
  return [string range $bytes $offset [expr {$offset + $count - 1}]]
}

# The device colour space of a parsed TIFF - the name without the slash. A
# palette image answers DeviceRGB: that is the space its ColorMap entries are
# in and the base its /Indexed refers to, and it is what PDF/A holds against
# the output intent (ISO 19005-2, 6.2.4.3).
proc ::tclpdf::imageTiff::device {parsed} {
  set space [dict get $parsed space]
  return [expr {$space eq "Indexed" ? "DeviceRGB" : $space}]
}

# Does this picture need every strip as an image of its own?
#
# Only two of the compressions carry no state from one row to the next, and
# only those may have their strips concatenated into a single stream. Every
# other one restarts in every strip: measured on a 50-strip LZW file, the
# concatenated stream decodes exactly to line 50 and no further.
proc ::tclpdf::imageTiff::stateful {parsed} {
  return [expr {[dict get $parsed compressionName] ni {none packBits}}]
}

package provide tclpdf::imageTiff 1.1
